import Foundation
// `@preconcurrency`: HealthKit query and predicate types predate Sendable.
@preconcurrency import HealthKit

/// Apple Health authorization: the coalesced permission request, the
/// granted-scope and write-permission summaries, and the probe that infers a
/// denied read.
///
/// `@Observable` and `@MainActor`: the views read `authorizationRequested`
/// and `inferredAuthorizationDenied`, so they change on the main actor.
@Observable
@MainActor
final class HealthKitAuthorization {
    /// The Health store the prompt and the probes go through.
    nonisolated let access: HealthKitAccess

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
    /// out the permission prompt when two arrive simultaneously (on a
    /// first install, `loadDataAndContinue` and `OnboardingView.task` can
    /// call milliseconds apart, and the user then cannot grant
    /// permissions). A second caller awaits the in-flight task instead
    /// of starting its own.
    @ObservationIgnored private var pendingAuthTask: Task<Void, Error>?

    nonisolated init(access: HealthKitAccess) {
        self.access = access
    }

    /// Check if HealthKit is available on this device
    /// `nonisolated`: a framework capability predicate, not instance state.
    nonisolated var isHealthKitAvailable: Bool {
        access.isAvailable
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
    /// timing out the permission prompt — see `pendingAuthTask`).
    func requestAuthorization() async throws {
        // Asking for access, from anywhere, ends onboarding's "Skip for now".
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.healthAccessSkipped)
        // Already requested this process — no work to do. Re-prompting
        // is a no-op for granted/denied types anyway, so save the round
        // trip and avoid the race window.
        if await MainActor.run(body: { authorizationRequested }) {
            return
        }
        try await runCoalescedAuthorization()
    }

    /// Run `performAuthorization`, or join the request already in flight:
    /// every prompt goes through here, so two callers ms apart (a scene
    /// activation and the launch task) never send two requests at once.
    private func runCoalescedAuthorization() async throws {
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
    ///
    /// iOS never says whether a read was granted, so a scope counts when
    /// another source's sample can be read from the last 30 days. This
    /// app's own writes (heart rate, sleep, workouts) are left out — an app
    /// can always read what it wrote, so counting them shows a denied scope as
    /// granted. A granted scope with no other data in 30 days still reads as
    /// not granted; nothing in HealthKit can tell those apart.
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
        let predicate = Self.otherSourcesSamples(from: since, to: nil)
        return await access.runBoundedQuery(timeout: HealthKitAccess.vitalsQueryTimeoutSec) { resolve in
            HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: nil) { _, results, _ in
                resolve(!(results?.isEmpty ?? true))
            }
        } ?? false // timeout → treat as "not present" (fail-safe for the auth probe)
    }

    /// Samples in the date range written by any source but this app. The
    /// read-authorization probes use it: an app can always read its own
    /// writes, so counting them reports access the user denied.
    nonisolated private static func otherSourcesSamples(from start: Date, to end: Date?) -> NSPredicate {
        let range = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let ours = HKQuery.predicateForObjects(from: Set([HKSource.default()]))
        return NSCompoundPredicate(andPredicateWithSubpredicates: [range, NSCompoundPredicate(notPredicateWithSubpredicate: ours)])
    }

    /// Auto-recover from a "stale auth set": write types added to the request
    /// set in a release after the user's onboarding stay `.notDetermined`
    /// forever, because the in-memory `authorizationRequested` flag flips to
    /// true after onboarding's single prompt and never re-fires. Exports of
    /// those types then fail with "Authorization is not determined".
    ///
    /// This method probes `authorizationStatus(for:)` for every write
    /// type we care about. If ANY are `.notDetermined`, fire the auth
    /// prompt — iOS shows only the undecided types, so previously-
    /// answered types don't pester the user. Idempotent + safe to call
    /// on every cold start. Read types can't be probed (Apple withholds
    /// the answer for privacy), so this only catches write gaps —
    /// which is exactly the workout-export case.
    func ensureWriteAuthorizationFresh() async {
        guard isHealthKitAvailable, !isAccessSkipped else { return }
        let undecided = Self.probeableWriteTypes().filter {
            access.store.authorizationStatus(for: $0) == .notDetermined
        }
        guard !undecided.isEmpty else { return }
        debugLog("[HealthKitManager] re-requesting auth — \(undecided.count) write types stale (.notDetermined)")
        // Force a re-prompt by clearing the in-process flag and going
        // through the coalesced authorization path.
        await MainActor.run { authorizationRequested = false }
        do {
            try await runCoalescedAuthorization()
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
            try await runCoalescedAuthorization()
        } catch {
            debugLog("[HealthKitManager] forceReauthorize failed: \(error.localizedDescription)", level: .warning)
        }
    }

    /// A read-only snapshot of WRITE-permission status per key type, for the
    /// Permissions screen. Read permissions are intentionally omitted — Apple
    /// withholds read-authorization status for privacy, so writes are the only
    /// thing we can honestly show (and a missing workout export is a write
    /// gap). `.sharingAuthorized` = allowed, `.sharingDenied` = the user
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
            return access.store.authorizationStatus(for: type)
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

    /// The actual authorization work. Invoked only through
    /// `runCoalescedAuthorization` — never call directly.
    ///
    /// After the prompt, probe whether reads actually
    /// returned anything. We can't ask HK directly ("did the user deny?"), but
    /// we can see whether ANY sleep or HRV samples come back over the last 14
    /// days. When both probes are empty, infer denial. False-positive cost is
    /// showing the banner to a brand-new user who hasn't synced yet —
    /// acceptable, because the banner copy is informational ("if data is
    /// missing, check Settings → Health → Emuqu"), not accusatory.
    private func performAuthorization() async throws {
        guard isHealthKitAvailable else { throw HealthStoreError.notAvailable }
        guard let core = Self.coreAuthorizationTypes() else {
            debugLog("[HealthKitManager] Required HealthKit type unavailable for authorization")
            throw HealthStoreError.notAvailable
        }
        try await access.store.requestAuthorization(
            toShare: Self.writeTypes(core: core),
            read: Self.readTypes(core: core)
        )
        await MainActor.run { self.authorizationRequested = true }
        Task { [weak self] in
            await self?.probeAuthorizationGranted(sleepType: core.sleep, hrvType: core.hrv)
        }
    }

    /// Whether the user has already answered Apple Health's permission sheet
    /// for the app's types on this device, in this launch or an earlier one.
    /// `authorizationRequested` only covers this process; HealthKit keeps the
    /// answer (`.unnecessary`: nothing left to ask). False when HealthKit is
    /// unavailable or the status cannot be read.
    func authorizationWasEverRequested() async -> Bool {
        guard isHealthKitAvailable, let core = Self.coreAuthorizationTypes() else { return false }
        do {
            let status = try await access.store.statusForAuthorizationRequest(
                toShare: Self.writeTypes(core: core),
                read: Self.readTypes(core: core)
            )
            return status == .unnecessary
        } catch {
            debugLog("[HealthKitManager] Authorization request status unavailable: \(error)", level: .warning)
            return false
        }
    }

    /// The types the app cannot function without. A nil return means one of
    /// them is unavailable on this device and authorization can't proceed.
    private struct CoreAuthTypes {
        let sleep: HKCategoryType
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
              let hrvType = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
              let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate),
              let vo2Type = HKObjectType.quantityType(forIdentifier: .vo2Max),
              let activeEnergyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
              let respiratoryType = HKObjectType.quantityType(forIdentifier: .respiratoryRate),
              let oxygenSaturationType = HKObjectType.quantityType(forIdentifier: .oxygenSaturation),
              let restingHeartRateType = HKObjectType.quantityType(forIdentifier: .restingHeartRate)
        else { return nil }
        return CoreAuthTypes(
            sleep: sleepType, hrv: hrvType, heartRate: heartRateType,
            vo2: vo2Type, activeEnergy: activeEnergyType, respiratory: respiratoryType,
            oxygenSaturation: oxygenSaturationType, restingHeartRate: restingHeartRateType
        )
    }

    /// The passive-activity aggregates are included so the
    /// Fitness tab's daily totals cover EVERY source (iPhone, Apple Watch,
    /// third-party apps), not just the iPhone-side CMPedometer: a user who
    /// walks with the Watch but leaves the phone at home would otherwise be
    /// underreported. HealthKit sums across sources.
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
            core.sleep, core.hrv, core.heartRate, core.vo2,
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
    /// grant alone reads back as no data at all: a rebuilt ride would ask Health
    /// how far it went, be told nothing, and show the user 0 km.
    ///
    /// Apple Health records all three continuously, with no workout running.
    /// Exercise time is Apple's own minute-by-minute judgement that the user
    /// was working out, which is a far better answer to "when did the walk
    /// end" than counting steps — steps keep accruing around the house.
    /// Walking and running speed give pace on a rebuild that has no GPS track
    /// to derive it from, and `flightsClimbed` (already here) is the only
    /// terrain signal the passive record carries.
    ///
    /// `heartRateRecoveryOneMinute` is Apple's own one-minute heart-rate
    /// recovery, which a Watch workout writes; `HRRCaptureService` falls back to
    /// it (tier 3) when the strap gave nothing after a workout. `distanceRowing`
    /// (iOS 18 and later) gives an imported rowing workout its distance.
    nonisolated private static func optionalReadTypes() -> Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        var quantities: [HKQuantityTypeIdentifier] = [
            .stepCount, .distanceWalkingRunning, .distanceCycling, .flightsClimbed, .bodyMass,
            .appleExerciseTime, .walkingSpeed, .runningSpeed, .physicalEffort, .heartRateRecoveryOneMinute
        ]
        if #available(iOS 18.0, *) { quantities.append(.distanceRowing) }
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

    /// Run a wide-window probe for sleep + HRV samples from other sources
    /// (this app's own SDNN and sleep exports are left out: an app can
    /// always read its own writes). If both return zero results, set
    /// `inferredAuthorizationDenied = true` so the UI can surface a
    /// Settings deep-link; otherwise clear it.
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

    /// Sample-count helper used by the auth probe: samples from sources
    /// other than this app. Wraps `HKSampleQuery` in async/await; returns 0
    /// on any error so the probe defaults to "appears denied" — fail-safe
    /// for the banner.
    /// Takes dates rather than a built `NSPredicate` so nothing non-Sendable
    /// crosses into the child task; the predicate is built where it is used.
    private func sampleCount(for type: HKSampleType, from start: Date, to end: Date) async -> Int {
        await access.runBoundedQuery(timeout: HealthKitAccess.vitalsQueryTimeoutSec) { resolve in
            HKSampleQuery(
                sampleType: type,
                predicate: Self.otherSourcesSamples(from: start, to: end),
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
}
