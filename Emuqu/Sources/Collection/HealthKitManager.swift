import Foundation
// `@preconcurrency`: HealthKit query and predicate types predate Sendable.
@preconcurrency import HealthKit

/// HealthKit integration for sleep data and HRV export
///
/// `@MainActor`-isolated. It is `@Observable` and read by SwiftUI, so its
/// state is required to change on the main
/// actor; the annotation makes the class Sendable,
/// which is what HealthKit's `@Sendable` query callbacks need in order to
/// capture it. Query bodies that run on HealthKit's own queues stay
/// `nonisolated` and hop explicitly.
@Observable
@MainActor
final class HealthKitManager {
    /// Canonical shared instance used across the app.
    ///
    /// A second `HealthKitManager()` would allocate its own
    /// `HKHealthStore`, hold its own anchor tokens, and publish its own
    /// observed state; views downstream of it would never see updates
    /// the shared one picked up (and vice versa). Route through this
    /// accessor so every consumer sees the
    /// same store, the same anchors, and the same observer notifications.
    /// `nonisolated` so default arguments can name it — Swift evaluates those
    /// in the caller's isolation. The isolation protects state, not the pointer.
    nonisolated static let shared = HealthKitManager()

    // MARK: - Properties

    // Bumped from `private` to `internal` so extensions in HealthKitManager+*.swift
    // files (e.g. +Sleep, +Vitals, +HeartRate, +Training, +HRV) can reach the
    // shared HealthKit store and settings provider.
    let healthStore = HKHealthStore()

    /// Heart-rate reads, stats and exports — and the bounded-query plumbing the
    /// other query classes reach through the forwarders below.
    var heartRate: HeartRateHealthQueries {
        HeartRateHealthQueries(manager: self)
    }

    /// Exports, deletes and observer queries.
    var writes: HealthWriteAndObserve {
        HealthWriteAndObserve(manager: self)
    }
    nonisolated let settingsProvider: @Sendable () -> UserSettings

    /// IMPORTANT: This flag only indicates authorization was REQUESTED, not that it was granted.
    /// HealthKit deliberately doesn't reveal if read access was denied to protect user privacy.
    ///
    /// Callers MUST:
    /// - Handle empty results gracefully (user may have denied access)
    /// - Never assume data will be available just because this flag is true
    /// - Provide appropriate fallback UI when sleep/HR data is unavailable
    var authorizationRequested = false

    /// HealthKit deliberately doesn't reveal whether
    /// read access was denied (privacy shield). After `requestAuthorization`
    /// returns, we run a probe query for sleep + HRV samples over the last
    /// 14 days. If both come back empty we infer denial (or no history —
    /// the fix is the same) and surface a banner pointing to Settings → Health.
    /// True = "user appears to have denied at least one critical scope —
    /// show the banner". Reset by `clearInferredDenial()` after the user
    /// returns from the Settings deep-link.
    var inferredAuthorizationDenied = false

    /// Single in-flight authorization Task. Prevents concurrent
    /// `requestAuthorization` calls from racing each other — iOS times
    /// out the permission prompt when two arrive simultaneously
    /// (first-install bug: one call from the app's
    /// `loadDataAndContinue`, another from `OnboardingView.task`,
    /// fired ~ms apart, prompt timed out, user couldn't grant
    /// permissions). A second caller awaits the in-flight task instead
    /// of starting its own.
    @ObservationIgnored private var pendingAuthTask: Task<Void, Error>?
    /// The Workouts-write warning has been logged this launch.
    @ObservationIgnored private var hasReportedWorkoutWriteDenied = false

    /// Current sleep schedule from user settings. Used to derive overnight windows,
    /// morning cutoffs, and daytime HR query windows instead of hardcoded clock times.
    /// Bumped from `private` to `internal` so extension files can derive overnight
    /// windows when querying HealthKit (e.g. HealthKitManager+Sleep.swift).
    var sleepSchedule: SleepSchedule {
        settingsProvider().sleepSchedule
    }

    // MARK: - Init

    nonisolated init(settingsProvider: @escaping @Sendable () -> UserSettings = { AppDependencies.current.app.settingsManager.settingsSnapshot }) {
        self.settingsProvider = settingsProvider
    }

    // MARK: - Types

    // Sleep domain types live in `Models/SleepDomain.swift` so the
    // analysis layer stops naming this I/O class in its signatures. Aliases keep
    // every existing `HealthKitManager.SleepStage` call site compiling, the same
    // way `SleepData` has been handled since it moved.
    typealias SleepBoundarySource = Emuqu.SleepBoundarySource
    typealias SleepBoundaryValidation = Emuqu.SleepBoundaryValidation
    typealias HRSleepQuality = Emuqu.HRSleepQuality
    typealias SleepSegment = Emuqu.SleepSegment
    typealias SleepStage = Emuqu.SleepStage
    typealias SleepStageProvenance = Emuqu.SleepStageProvenance
    typealias SleepStageInterval = Emuqu.SleepStageInterval
    typealias SleepData = Emuqu.SleepData

    // MARK: - Authorization

    /// Check if HealthKit is available on this device
    /// `nonisolated`: a framework capability predicate, not instance state.
    nonisolated var isHealthKitAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// The user chose "Skip for now" on onboarding's Apple Health page and has
    /// not asked for access since. Requests nobody tapped for respect it; any
    /// request the user makes clears it.
    nonisolated var isAccessSkipped: Bool {
        UserDefaults.standard.bool(forKey: UserDefaultsKeys.healthAccessSkipped)
    }

    /// Request authorization to read sleep data.
    ///
    /// Concurrency-safe: a second call while an existing request is
    /// in flight awaits the existing one rather than firing a parallel
    /// `HKHealthStore.requestAuthorization` (which iOS responds to by
    /// timing out the permission prompt — see the `pendingAuthTask`
    /// docs above for the first-install bug this guards against).
    func requestAuthorization() async throws {
        // Asking for access, from anywhere, ends onboarding's "Skip for now".
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.healthAccessSkipped)
        // Already requested this process — no work to do. Re-prompting
        // is a no-op for granted/denied types anyway, so save the round
        // trip and avoid the race window.
        if await MainActor.run(body: { authorizationRequested }) {
            return
        }
        // Coalesce parallel callers onto the same in-flight task.
        if let existing = pendingAuthTask {
            try await existing.value
            return
        }
        let task = Task<Void, Error> { [weak self] in
            try await self?.performAuthorization()
        }
        pendingAuthTask = task
        defer { pendingAuthTask = nil }
        try await task.value
    }

    /// Returns the names of read scopes that are at least nominally
    /// granted. Used by `OnboardingHealthPage` to drive its post-sheet
    /// status card. Empty set ⇒ user denied everything (or HK is off);
    /// 4+ entries ⇒ confirmation card; partial ⇒ warning card.
    func grantedScopeSummary() async -> Set<String> {
        guard isHealthKitAvailable else { return [] }
        var granted: Set<String> = []
        let last30Days = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        if await sampleExists(type: HKObjectType.categoryType(forIdentifier: .sleepAnalysis), since: last30Days) {
            granted.insert("sleep")
        }
        if await sampleExists(type: HKObjectType.quantityType(forIdentifier: .heartRate), since: last30Days) {
            granted.insert("heartRate")
        }
        if await anyVitalsSampleExists(since: last30Days) {
            granted.insert("vitals")
        }
        if await sampleExists(type: HKObjectType.workoutType(), since: last30Days) {
            granted.insert("workouts")
        }
        return granted
    }

    /// Any of resp / SpO2 / temp counts as "vitals". Short-circuits so a user
    /// with respiratory data never pays for the other two probes.
    private func anyVitalsSampleExists(since date: Date) async -> Bool {
        let ids: [HKQuantityTypeIdentifier] = [.respiratoryRate, .oxygenSaturation, .appleSleepingWristTemperature]
        for id in ids where await sampleExists(type: HKObjectType.quantityType(forIdentifier: id), since: date) {
            return true
        }
        return false
    }

    private func sampleExists(type: HKSampleType?, since: Date) async -> Bool {
        guard let type else { return false }
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil)
        return await runBoundedQuery(timeout: Self.vitalsQueryTimeoutSec) { resolve in
            HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: nil) { _, results, _ in
                resolve(!(results?.isEmpty ?? true))
            }
        } ?? false // timeout → treat as "not present" (fail-safe for the auth probe)
    }

    /// Auto-recover from the "stale auth set"
    /// trap. A user's debug log showed "HealthKit export failed:
    /// Authorization is not determined" because new write types
    /// (workoutType, activeEnergy, distance) were added to the request
    /// set in a release AFTER the user's original onboarding. The
    /// in-memory `authorizationRequested` flag flips to true after
    /// onboarding's single prompt and never re-fires; new types
    /// silently stay `.notDetermined` forever.
    ///
    /// This method probes `authorizationStatus(for:)` for every write
    /// type we care about. If ANY are `.notDetermined`, fire the auth
    /// prompt — iOS shows only the undecided types, so previously-
    /// answered types don't pester the user. Idempotent + safe to call
    /// on every cold start. Read types can't be probed (Apple withholds
    /// the answer for privacy), so this only catches write gaps —
    /// which is exactly the workout-export case the user hit.
    func ensureWriteAuthorizationFresh() async {
        guard isHealthKitAvailable, !isAccessSkipped else { return }
        let undecided = Self.probeableWriteTypes().filter {
            healthStore.authorizationStatus(for: $0) == .notDetermined
        }
        guard !undecided.isEmpty else { return }
        debugLog("[HealthKitManager] re-requesting auth — \(undecided.count) write types stale (.notDetermined)")
        // Force a re-prompt by clearing the in-process flag and going
        // through the full performAuthorization path.
        await MainActor.run { authorizationRequested = false }
        do {
            try await performAuthorization()
        } catch {
            debugLog("[HealthKitManager] ensureWriteAuthorizationFresh failed: \(error.localizedDescription)", level: .warning)
        }
    }

    nonisolated private static func probeableWriteTypes() -> [HKSampleType] {
        [
            HKObjectType.workoutType(),
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
            HKObjectType.quantityType(forIdentifier: .heartRate),
            HKObjectType.quantityType(forIdentifier: .restingHeartRate),
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
            HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning),
            HKObjectType.quantityType(forIdentifier: .distanceCycling),
            HKSeriesType.workoutRoute()
        ].compactMap { $0 }
    }

    /// Force a full re-authorization prompt regardless of the in-memory
    /// `authorizationRequested` flag. iOS re-prompts ONLY for types the user
    /// hasn't decided on THIS device — most importantly Sleep / HR **read**
    /// permissions that often DON'T carry over to a new iPhone. That's the
    /// classic "Apple Health has the sleep but Emuqu reads nothing" case: a
    /// never-granted read returns zero samples with no error, and iOS hides read
    /// status so `ensureWriteAuthorizationFresh` (which can only probe WRITE
    /// gaps) never re-fires for it. Already-decided types don't re-pester. A
    /// hard read DENIAL can only be re-enabled in iOS Settings; this covers the
    /// far more common "never asked on this device" case (e.g. after migration).
    func forceReauthorize() async {
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.healthAccessSkipped)
        await MainActor.run { authorizationRequested = false }
        do {
            try await performAuthorization()
        } catch {
            debugLog("[HealthKitManager] forceReauthorize failed: \(error.localizedDescription)", level: .warning)
        }
    }

    /// A read-only snapshot of WRITE-permission status per key type, for the
    /// Permissions screen. Read permissions are intentionally omitted — Apple
    /// withholds read-authorization status for privacy, so writes are the only
    /// thing we can honestly show (and the workout-export gap a user hit is a
    /// write gap). `.sharingAuthorized` = allowed, `.sharingDenied` = the user
    /// declined it in the Health prompt (only fixable in iOS Settings — the
    /// system won't re-prompt), `.notDetermined` = never asked (re-promptable).
    struct WritePermission: Identifiable {
        var id: String { label }
        let label: String
        let status: HKAuthorizationStatus
    }

    func writePermissionSummary() -> [WritePermission] {
        guard isHealthKitAvailable else { return [] }
        func status(_ type: HKObjectType?) -> HKAuthorizationStatus {
            guard let type else { return .notDetermined }
            return healthStore.authorizationStatus(for: type)
        }
        let bundle = LanguageManager.appBundle
        return [
            WritePermission(label: String(localized: "Workouts", bundle: bundle), status: status(HKObjectType.workoutType())),
            WritePermission(label: String(localized: "Heart rate variability", bundle: bundle), status: status(HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN))),
            WritePermission(label: String(localized: "Heart rate", bundle: bundle), status: status(HKObjectType.quantityType(forIdentifier: .heartRate))),
            WritePermission(label: String(localized: "Resting heart rate", bundle: bundle), status: status(HKObjectType.quantityType(forIdentifier: .restingHeartRate))),
            WritePermission(label: String(localized: "Sleep", bundle: bundle), status: status(HKObjectType.categoryType(forIdentifier: .sleepAnalysis))),
            WritePermission(label: String(localized: "Active energy", bundle: bundle), status: status(HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)))
        ]
    }

    /// Back-publish past workouts to Apple Health.
    ///
    /// Users who onboarded before workoutType was added to the auth
    /// set (or who initially denied) ended up with a long history of
    /// archived workouts that never reached HealthKit. Once they grant
    /// the supplementary permission (`ensureWriteAuthorizationFresh`
    /// re-prompts at launch), this method walks the archive, exports anything still flagged
    /// `healthKitExportedAt == nil`, and stamps each one on success
    /// so a follow-up call doesn't duplicate. Idempotent.
    ///
    /// Runs serially with a small delay between writes so HealthKit's
    /// rate limiter doesn't bounce the batch — observed limit on iOS
    /// 17 is ~1 workout/sec sustained. A one-year archive of 4
    /// workouts/week takes ~3 minutes; we yield to the runloop on
    /// each iteration so the UI stays responsive.
    ///
    /// This runs on EVERY foreground and, without the watermark
    /// gate, would do a full `archive.retrieve` (disk + AES-GCM decrypt + JSON
    /// decode) for every workout just to read the `healthKitExportedAt` flag —
    /// dozens of decrypts per foreground even when everything is already
    /// exported. The whole scan is skipped when the workout set is unchanged
    /// since the last clean (failed==0) backfill, judged by the count AND the
    /// newest workout's date: deleting one workout and recording another
    /// leaves the count alone, but not the newest date.
    @discardableResult
    func backfillWorkoutsToHealthKit(
        archive: SessionArchive,
        bodyWeightKg: Double
    ) async -> (exported: Int, skipped: Int, failed: Int) {
        guard isHealthKitAvailable, workoutWriteAuthorized else { return (0, 0, 0) }
        let candidates = archive.entries.filter { $0.sessionType == .workout }
        let defaults = UserDefaults.standard
        let watermark = Self.backfillWatermark(candidates)
        if defaults.string(forKey: Self.backfillWatermarkKey) == watermark {
            return (0, candidates.count, 0)
        }
        reportDeniedWorkoutSampleTypes()
        var tally = (exported: 0, skipped: 0, failed: 0)
        for entry in candidates {
            await Task.yield()
            await backfillOne(entry: entry, archive: archive, bodyWeightKg: bodyWeightKg, tally: &tally)
        }
        // Advance the watermark only when nothing failed, so failed sessions
        // are retried next foreground (until the retry ceiling skips them).
        if tally.failed == 0 {
            defaults.set(watermark, forKey: Self.backfillWatermarkKey)
        }
        debugLog("[HealthKitManager] backfill complete — exported=\(tally.exported) skipped=\(tally.skipped) failed=\(tally.failed) of \(candidates.count) candidates")
        return tally
    }

    /// Only proceed if the user has granted workout-write — otherwise every
    /// export throws and we'd burn battery.
    ///
    /// Workouts is the one permission an export cannot do without. The sample
    /// types it attaches (heart rate, distance, energy, route) are each
    /// optional: `HealthKitWorkoutExport` leaves off any the user has switched
    /// off, so they are named for the user but never block the export.
    ///
    /// `.warning`, not `debugLogExternal`: this has to reach the user-facing
    /// problems list. Logged as an external event it stayed invisible while
    /// every workout failed to reach Apple Health — and the training load,
    /// which is built only from HealthKit workouts, was computed without them.
    /// Once per launch, because backfill checks on every foreground.
    private var workoutWriteAuthorized: Bool {
        guard healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
            if !hasReportedWorkoutWriteDenied {
                hasReportedWorkoutWriteDenied = true
                debugLog(
                    "[HealthKitManager] Workouts can't be written to Apple Health — writing is off for Workouts. Turn it on in Settings → Health → Data Access & Devices → Emuqu. Until then workouts stay in Emuqu only and the training load will not include them.",
                    level: .warning
                )
            }
            return false
        }
        return true
    }

    /// Say which optional workout data will be left off, once per backfill
    /// that has something to export.
    private func reportDeniedWorkoutSampleTypes() {
        let denied = Self.workoutExportSampleTypes.compactMap { type, name in
            healthStore.authorizationStatus(for: type) == .sharingAuthorized ? nil : name
        }
        guard !denied.isEmpty else { return }
        debugLog(
            "[HealthKitManager] Workouts reach Apple Health without: \(denied.joined(separator: ", ")) — writing is off for them in Settings → Health → Data Access & Devices → Emuqu.",
            level: .warning
        )
    }

    /// The optional sample types `HealthKitWorkoutExport` attaches to a
    /// workout, paired with the label each one carries in the iOS Health
    /// permission list.
    nonisolated static let workoutExportSampleTypes: [(HKSampleType, String)] = [
        (HKQuantityType(.heartRate), "Heart Rate"),
        (HKQuantityType(.activeEnergyBurned), "Active Energy"),
        (HKQuantityType(.distanceWalkingRunning), "Walking + Running Distance"),
        (HKQuantityType(.distanceCycling), "Cycling Distance"),
        (HKSeriesType.workoutRoute(), "Workout Routes")
    ]

    nonisolated private static let backfillWatermarkKey = "hkBackfillExportedWatermark"

    /// "count-newestDate" for the workout entries; see `backfillWorkoutsToHealthKit`.
    nonisolated private static func backfillWatermark(_ entries: [SessionArchiveEntry]) -> String {
        let newest = entries.map(\.date).max()?.timeIntervalSince1970 ?? 0
        return "\(entries.count)-\(Int(newest))"
    }

    /// Gives up after N failed attempts. Without this gate, the
    /// same 2 sessions failing every backfill cycle log `failed=2 of 27` every
    /// minute forever and burn battery retrying writes HealthKit has already
    /// rejected (typically because a sub-permission like active-energy was
    /// never granted). After `healthKitExportRetryCeiling` they're marked
    /// giving-up and skipped; granting the missing permission later won't
    /// auto-retry these, but the user can use the Settings "Re-export to
    /// Health" action to clear the failure counter.
    private func backfillOne(
        entry: SessionArchiveEntry,
        archive: SessionArchive,
        bodyWeightKg: Double,
        tally: inout (exported: Int, skipped: Int, failed: Int)
    ) async {
        // Another export of this session is in flight. Counted as not done,
        // so the watermark holds and the next pass checks it again in case
        // that export failed. The session is read only once the claim is
        // held: read before it, a workout the recorder exported and stamped
        // in between looked unexported and went to Health twice.
        guard HealthExportClaims.claim(entry.sessionId) else { return tally.failed += 1 }
        defer { HealthExportClaims.release(entry.sessionId) }
        guard var session = try? archive.retrieve(entry.sessionId) else { return tally.failed += 1 }
        guard Self.needsBackfill(session) else { return tally.skipped += 1 }
        await exportClaimed(&session, entry: entry, archive: archive, bodyWeightKg: bodyWeightKg, tally: &tally)
    }

    private func exportClaimed(
        _ session: inout HRVSession,
        entry: SessionArchiveEntry,
        archive: SessionArchive,
        bodyWeightKg: Double,
        tally: inout (exported: Int, skipped: Int, failed: Int)
    ) async {
        do {
            try await exportAndStamp(&session, archive: archive, bodyWeightKg: bodyWeightKg)
            tally.exported += 1
        } catch {
            tally.failed += 1
            recordBackfillFailure(error, session: &session, archive: archive, sessionId: entry.sessionId)
        }
    }

    /// Polite pacing after each write — HealthKit's writer accepts ~1/sec
    /// sustained without throwing, so sleeping ~250 ms keeps us safely below.
    private func exportAndStamp(_ session: inout HRVSession, archive: SessionArchive, bodyWeightKg: Double) async throws {
        try await HealthKitWorkoutExport.export(session: session, store: healthStore, bodyWeightKg: bodyWeightKg)
        let exportedAt = Date()
        session.healthKitExportedAt = exportedAt
        session.healthKitExportFailureCount = nil
        do {
            // Only the stamp, onto the copy as stored now: the export takes a
            // moment, and writing back the copy read before it undid an edit
            // or a heart-rate-recovery save made meanwhile.
            try archive.update(session.id, requestingReupload: false) {
                $0.healthKitExportedAt = exportedAt
                $0.healthKitExportFailureCount = nil
            }
        } catch {
            // The export itself succeeded; only the "already exported" stamp
            // failed to persist. Backfill will re-export this session on the
            // next pass, which is safe but wasteful — and silent, until now.
            debugLog("[HealthKit] Export stamp not persisted for \(session.id.uuidString.prefix(8)): \(error.localizedDescription)", level: .warning)
        }
        await sleepQuietly(250_000_000, context: "exportAndStamp")
    }

    /// A workout with no forward duration can never be exported.
    ///
    /// HealthKit rejects a builder whose collection ends where it began —
    /// "endDate must be after startDate" — and it will reject it identically
    /// every time. Without this guard such a session stays eligible, so every
    /// foreground retries the same doomed write until the retry ceiling burns
    /// through, and each failure re-archives the session to record the count.
    /// A field log shows exactly one candidate failing this way out of 112: the
    /// one-second stub a crashed recording left behind.
    nonisolated static func needsBackfill(_ session: HRVSession) -> Bool {
        guard session.healthKitExportedAt == nil,
              (session.healthKitExportFailureCount ?? 0) < HRVSession.healthKitExportRetryCeiling,
              session.workoutMetadata != nil,
              let endDate = session.endDate,
              endDate > session.startDate
        else { return false }
        return true
    }

    private func recordBackfillFailure(_ error: Error, session: inout HRVSession, archive: SessionArchive, sessionId: UUID) {
        let newFails = (session.healthKitExportFailureCount ?? 0) + 1
        session.healthKitExportFailureCount = newFails
        do {
            try archive.update(sessionId, requestingReupload: false) { $0.healthKitExportFailureCount = newFails }
        } catch let archiveError {
            // Bound explicitly: a bare `catch` would shadow this function's own
            // `error` parameter, and the two are different failures — that one
            // is the HealthKit export, this one is the archive write recording
            // that it failed. If this write is lost the retry counter never
            // advances and the session retries export forever against the
            // retry ceiling.
            debugLog("[HealthKit] Backfill failure count not persisted for \(sessionId.uuidString.prefix(8)): \(archiveError.localizedDescription)", level: .warning)
        }
        Self.logBackfillFailure(error, sessionId: sessionId, attempt: newFails)
    }

    /// Quiet "Authorization is not determined" by default. Most
    /// "failed" counts come from this and it's an auth-completeness issue, not
    /// a code bug. But: log a ONE-TIME warning on the very first failure per
    /// session so the user / log reader can see why backfill is short, AND log
    /// on the final failure (hitting the retry ceiling) so it's clear we're
    /// giving up.
    nonisolated private static func logBackfillFailure(_ error: Error, sessionId: UUID, attempt newFails: Int) {
        let ceilingHit = newFails >= HRVSession.healthKitExportRetryCeiling
        guard newFails == 1 || ceilingHit else { return }
        let desc = error.localizedDescription
        let isAuthNotDetermined = desc.contains("Authorization is not determined")
        guard !isAuthNotDetermined || ceilingHit else { return }
        let suffix = ceilingHit ? " — giving up after \(newFails) attempts" : ""
        debugLog("[HealthKitManager] backfill export failed for \(sessionId.uuidString.prefix(8)): \(desc)\(suffix)", level: .warning)
    }

    /// The actual authorization work. Invoked through the
    /// concurrency-coalescing wrapper above — never call directly.
    ///
    /// After the prompt, probe whether reads actually
    /// returned anything. We can't ask HK directly ("did the user deny?"), but
    /// we can see whether ANY sleep or HRV samples come back over a wide
    /// window. If the user has had the device 24h+ and both probes are empty,
    /// infer denial. False-positive cost is showing the banner to a brand-new
    /// user who hasn't synced yet — acceptable, because the banner copy is
    /// informational ("if data is missing, check Settings → Health → Emuqu"),
    /// not accusatory.
    private func performAuthorization() async throws {
        guard isHealthKitAvailable else { throw HealthKitError.notAvailable }
        guard let core = Self.coreAuthorizationTypes() else {
            debugLog("[HealthKitManager] Required HealthKit type unavailable for authorization")
            throw HealthKitError.notAvailable
        }
        try await healthStore.requestAuthorization(
            toShare: Self.writeTypes(core: core),
            read: Self.readTypes(core: core)
        )
        await MainActor.run { self.authorizationRequested = true }
        Task { [weak self] in
            await self?.probeAuthorizationGranted(sleepType: core.sleep, hrvType: core.hrv)
        }
    }

    /// The types the app cannot function without. A nil return means one of
    /// them is unavailable on this device and authorization can't proceed.
    private struct CoreAuthTypes {
        let sleep: HKCategoryType
        let mindful: HKCategoryType
        let hrv: HKQuantityType
        let heartRate: HKQuantityType
        let vo2: HKQuantityType
        let activeEnergy: HKQuantityType
        let respiratory: HKQuantityType
        let oxygenSaturation: HKQuantityType
        let restingHeartRate: HKQuantityType
    }

    nonisolated private static func coreAuthorizationTypes() -> CoreAuthTypes? {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
              let mindfulType = HKObjectType.categoryType(forIdentifier: .mindfulSession),
              let hrvType = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
              let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate),
              let vo2Type = HKObjectType.quantityType(forIdentifier: .vo2Max),
              let activeEnergyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
              let respiratoryType = HKObjectType.quantityType(forIdentifier: .respiratoryRate),
              let oxygenSaturationType = HKObjectType.quantityType(forIdentifier: .oxygenSaturation),
              let restingHeartRateType = HKObjectType.quantityType(forIdentifier: .restingHeartRate)
        else { return nil }
        return CoreAuthTypes(
            sleep: sleepType, mindful: mindfulType, hrv: hrvType, heartRate: heartRateType,
            vo2: vo2Type, activeEnergy: activeEnergyType, respiratory: respiratoryType,
            oxygenSaturation: oxygenSaturationType, restingHeartRate: restingHeartRateType
        )
    }

    /// The passive-activity aggregates are included so the
    /// Fitness tab's daily totals cover EVERY source (iPhone, Apple Watch,
    /// third-party apps), not just the iPhone-side CMPedometer. A user who
    /// walks with the Watch but leaves the phone at home was getting
    /// underreported; HealthKit sums across sources.
    ///
    /// Biometric profile reads — body mass, date of birth, biological sex —
    /// back the "Fill from Apple Health" button on the Biometrics settings page
    /// so users don't have to retype values they've already entered into Apple
    /// Health. Reads are permission-scoped: the user can deny without affecting
    /// the rest of the app.
    ///
    /// `forIdentifier:` results are inserted as explicit optionals rather than
    /// force-unwrapped. `biologicalSex` / `dateOfBirth` are stable SDK
    /// identifiers — the unwrap would be effectively safe — but the codebase
    /// treats every `!` as a finding.
    nonisolated private static func readTypes(core: CoreAuthTypes) -> Set<HKObjectType> {
        var readTypes: Set<HKObjectType> = [
            core.sleep, core.mindful, core.hrv, core.heartRate, core.vo2,
            HKObjectType.workoutType(), core.activeEnergy, core.respiratory,
            core.oxygenSaturation, core.restingHeartRate,
            // Workout GPS route — lets us recover the FULL route of a workout
            // whose phone-side GPS died mid-session (e.g. an app crash) by
            // reading the Apple Watch's recording of the same workout.
            HKSeriesType.workoutRoute()
        ]
        readTypes.formUnion(Self.optionalReadTypes())
        return readTypes
    }

    /// `appleExerciseTime`, `walkingSpeed`, `runningSpeed` and
    /// `distanceCycling` are here for reconstruction, not for display.
    ///
    /// `distanceCycling` is authorized for WRITE further down, and a write
    /// grant reads back as no data at all: a rebuilt ride asked Health how far
    /// it went, was told nothing, and showed the user 0 km.
    ///
    /// Apple Health records all three continuously, with no workout running.
    /// Exercise time is Apple's own minute-by-minute judgement that the user
    /// was working out, which is a far better answer to "when did the walk
    /// end" than counting steps — steps keep accruing around the house.
    /// Walking and running speed give pace on a rebuild that has no GPS track
    /// to derive it from, and `flightsClimbed` (already here) is the only
    /// terrain signal the passive record carries.
    nonisolated private static func optionalReadTypes() -> Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        let quantities: [HKQuantityTypeIdentifier] = [
            .stepCount, .distanceWalkingRunning, .distanceCycling, .flightsClimbed, .bodyMass,
            .appleExerciseTime, .walkingSpeed, .runningSpeed, .physicalEffort
        ]
        for id in quantities {
            if let type = HKObjectType.quantityType(forIdentifier: id) { types.insert(type) }
        }
        for id in [HKCharacteristicTypeIdentifier.biologicalSex, .dateOfBirth] {
            if let type = HKObjectType.characteristicType(forIdentifier: id) { types.insert(type) }
        }
        if let wristTemperature = HKObjectType.quantityType(forIdentifier: .appleSleepingWristTemperature) {
            types.insert(wristTemperature)
        }
        return types
    }

    /// HRV, HR, resting HR, sleep export, workouts — plus the walking/running
    /// and cycling distance types workouts need.
    nonisolated private static func writeTypes(core: CoreAuthTypes) -> Set<HKSampleType> {
        // The workout route is written after each GPS workout is saved; without
        // share permission for it the route is left off.
        var writeTypes: Set<HKSampleType> = [
            core.hrv, core.heartRate, core.restingHeartRate, core.sleep,
            HKObjectType.workoutType(), core.activeEnergy, HKSeriesType.workoutRoute()
        ]
        for id in [HKQuantityTypeIdentifier.distanceWalkingRunning, .distanceCycling] {
            if let type = HKObjectType.quantityType(forIdentifier: id) { writeTypes.insert(type) }
        }
        return writeTypes
    }

    /// Run a wide-window probe for sleep + HRV samples. If both return
    /// zero results and the device clock indicates we're past the
    /// install window, set `inferredAuthorizationDenied = true` so the
    /// UI can surface a Settings deep-link.
    ///
    /// Heuristic: if BOTH come back empty over 14 days, the user probably
    /// denied access OR has never recorded sleep / HRV. We can't distinguish
    /// those two from inside the app — but the user-action for both is the same
    /// (visit Settings → Health → Emuqu to check). So surface the banner.
    private func probeAuthorizationGranted(
        sleepType: HKCategoryType,
        hrvType: HKQuantityType
    ) async {
        let now = Date()
        // 14-day window — overshoots typical sleep + HRV cadence; if the
        // user has any history at all, at least one sample lands.
        let windowStart = Calendar.current.date(byAdding: .day, value: -14, to: now) ?? now
        async let sleepCount = sampleCount(for: sleepType, from: windowStart, to: now)
        async let hrvCount = sampleCount(for: hrvType, from: windowStart, to: now)
        let (sleeps, hrvs) = await (sleepCount, hrvCount)
        let appearsDenied = (sleeps == 0 && hrvs == 0)
        await MainActor.run {
            self.inferredAuthorizationDenied = appearsDenied
            if appearsDenied {
                debugLog("[HealthKitManager] probe: 0 sleep + 0 HRV samples in 14d → inferring denial / no history; banner armed", level: .warning)
            }
        }
    }

    /// Sample-count helper used by the auth probe. Wraps `HKSampleQuery`
    /// in async/await; returns 0 on any error so the probe defaults to
    /// "appears denied" — fail-safe for the banner.
    /// Takes dates rather than a built `NSPredicate` so nothing non-Sendable
    /// crosses into the child task; the predicate is built where it is used.
    private func sampleCount(for type: HKSampleType, from start: Date, to end: Date) async -> Int {
        await runBoundedQuery(timeout: Self.vitalsQueryTimeoutSec) { resolve in
            HKSampleQuery(
                sampleType: type,
                predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: []),
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, _ in
                resolve(samples?.count ?? 0)
            }
        } ?? 0 // timeout → 0 (probe defaults to "appears denied" — fail-safe)
    }

    /// Call after the user returns from the Settings deep-link. Only clears
    /// the flag, so the banner goes away; the next probe (after the next
    /// authorization request) sets it again if nothing is readable.
    func clearInferredDenial() {
        Task { @MainActor in
            self.inferredAuthorizationDenied = false
        }
    }
    /// Latest diagnostics from HealthKit — published so UI can display.
    var breatheDiagnostics: BreatheDiagnostics?
    // The five stored properties below were `private`. Bumped to `internal`
    // so HealthKitManager+HRV.swift's Breathe-observer methods can read/write
    // them across files (Swift extensions cannot add stored properties).
    /// Active HKAnchoredObjectQuery instances for Breathe detection
    var breatheObserverQueries: [HKQuery] = []
    /// Slow-poll safety net timer (in case observer queries miss an edge case)
    @ObservationIgnored var breathePollTimer: Timer?
    /// The UUID of the most recent SDNN sample when we started listening,
    /// so we can detect when a genuinely new one appears.
    var baselineSDNNSampleUUID: UUID?
    /// Callback for delivering the detected reading
    var breatheCallback: ((BreatheHRVReading) -> Void)?
    /// Called when listening gives up after 5 minutes with no reading
    var breatheTimeoutCallback: (() -> Void)?
    /// Guard against delivering the reading more than once
    var breatheDetected = false
    /// When we started listening for a Breathe session
    var breatheListenStartDate: Date?
    /// Active observer query for sleep data arrival.
    /// Bumped from `private` to `internal` so the start/stop methods in
    /// HealthKitManager+SleepTrends.swift can manage it across files.
    var sleepObserverQuery: HKQuery?
    /// Incremented each time new sleep data arrives in HealthKit.
    /// Views can observe this to trigger a re-fetch.
    var sleepDataVersion: Int = 0
    /// Pending cache-warm task. Apple Watch syncs sleep
    /// samples in bursts of a dozen within a few seconds; without
    /// debouncing, each burst kicked off its own `fetchLastNightSleep`
    /// (full HKSampleQuery + full SleepMergingPipeline + classifier).
    /// Holding the task lets the observer cancel the prior in-flight warm
    /// when a fresh burst arrives, so only the last batch's value lands in
    /// the cache.
    @ObservationIgnored var sleepCacheWarmTask: Task<Void, Never>?
    /// Active observer queries for the four overnight vitals (respiratory
    /// rate, SpO2, wrist temperature, resting HR). Apple Watch writes these
    /// MINUTES to HOURS after sleep ends — long after the user accepts the
    /// session and the initial vitalsSnapshot is captured. Without this
    /// observer, the SleepDetail card stays empty until the user manually
    /// re-opens the app on the next launch.
    var vitalsObserverQueries: [HKQuery] = []
    /// Incremented each time new vitals samples arrive in HealthKit. Views
    /// observe to trigger a re-fetch of `RecoveryVitals` and an in-place
    /// re-archive of the session snapshot.
    var vitalsDataVersion: Int = 0
}
