import Foundation

/// Loads and removes the sample nights for the screens that offer them: the
/// Dashboard's first-run card and Settings → Troubleshooting.
///
/// `DemoSessionSeeder` makes the nights; this is the part that knows the app.
/// It hands the seeder the real analysis pipeline, scores each night the way a
/// morning is scored, and — the half that matters more — undoes everything a
/// sample night touched when the user is done with them:
///
/// - the archive entries, through the ordinary delete, which tombstones each
///   id so no sync pull can bring it back;
/// - the iCloud copies, through the same `uploadDeletion` every other delete
///   path uses;
/// - the rolling HRV baseline the nights fed, rebuilt from the recordings
///   that remain, and the settings baseline it mirrors, put back to what it
///   was before the first sample night if no recording remains to rebuild it.
///
/// Real sessions are never candidates. Removal selects by the sample tag's
/// fixed id and by the ids this device seeded (`Ledger`); a real recording
/// carries neither.
@MainActor
struct SampleDataLibrary {
    let collector: RRCollector
    /// Sends one deletion to iCloud. Production passes
    /// `CloudKitSyncManager.uploadDeletion`, the call every delete path makes.
    let deleteFromCloud: @Sendable (UUID) async -> Void
    var defaults: UserDefaults = .standard

    /// Loading and removal both take seconds; two at once, from the Dashboard
    /// card and the Settings row, would seed everything twice or remove while
    /// seeding.
    private static var isBusy = false

    /// Where the ledger lives in `defaults`.
    static let ledgerKey = "sampleData.ledger.v1"

    init(collector: RRCollector, cloudSync: CloudKitSyncManager) {
        self.init(collector: collector) { await cloudSync.uploadDeletion($0) }
    }

    init(collector: RRCollector, deleteFromCloud: @escaping @Sendable (UUID) async -> Void) {
        self.collector = collector
        self.deleteFromCloud = deleteFromCloud
    }

    /// Whether any sample night is in the archive.
    var isPresent: Bool {
        !sampleIds.isEmpty
    }

    private var sampleIds: [UUID] {
        DemoSessionSeeder.sampleSessionIds(in: collector.archive.entries, seededIds: Set(loadLedger().sessionIds))
    }

    // MARK: - Load

    /// Seed the sample nights. `progress` reports nights built so far and the total.
    /// Returns the number of nights added.
    @discardableResult
    func load(
        nights: Int = DemoSessionSeeder.defaultNightCount, progress: @MainActor (Int, Int) -> Void
    ) async throws -> Int {
        guard !Self.isBusy else { throw SampleDataError.busy }
        Self.isBusy = true
        defer { Self.isBusy = false }
        recordPriorBaselineIfNeeded()
        do {
            let ids = try await DemoSessionSeeder.seed(
                DemoSessionSeeder.nightPlans(count: nights, now: Date()), into: collector.archive,
                pipeline: pipeline, finalize: finalize, progress: progress
            )
            guard !ids.isEmpty else { throw SampleDataError.noOpenNights }
            appendToLedger(ids)
            collector.notifyArchiveChanged()
            return ids.count
        } catch {
            await rebuildBaseline()
            throw error
        }
    }

    /// The app's own analysis: window selection within the estimated sleep,
    /// as a morning with no Apple Watch data runs it. Falls back to the whole
    /// night when no window qualifies, as streaming does.
    ///
    /// Each night gets its own window selector, configured as the collector's
    /// is: the selector remembers the last night's organized-recovery zones,
    /// and nights analysed side by side would otherwise read each other's.
    private var pipeline: DemoSessionSeeder.NightPipeline {
        let shared = collector.analysisPipeline
        let ansConfig = collector.currentANSConfig
        return DemoSessionSeeder.NightPipeline(analyze: { session in
            let analysis = HRVAnalysisPipeline(
                artifactDetector: shared.artifactDetector, windowSelector: WindowSelector(), healthKit: shared.healthKit
            )
            let windowed = await analysis.analyzeWithAutoWindow(
                session: session, sleepStartMs: session.sleepStartMs, wakeTimeMs: session.sleepEndMs,
                trainingContext: nil, ansConfig: ansConfig
            )
            guard windowed == nil, let series = session.rrSeries else { return windowed }
            let flags = analysis.artifactDetector.detectArtifacts(in: series)
            return analysis.analyzeFullSeries(series: series, flags: flags, ansConfig: ansConfig)
        })
    }

    /// Score one night as acceptance does — quality gate, composite score
    /// against the baseline so far, frozen readiness — then let it into the
    /// baseline so the next night is scored against it.
    private func finalize(_ night: HRVSession) async -> HRVSession {
        var session = night
        session.notes = Self.sampleNote
        guard let result = night.analysisResult else { return session }
        session.hrvDataQuality = SessionAcceptanceService.classifyHRVQuality(
            result: result, sleepData: night.sleepSnapshot,
            baselineStats: collector.baselineTracker.recoveryBaselineStats,
            recordingStart: night.startDate, recordingEnd: night.endDate ?? night.startDate
        ).dataQuality
        if let outcome = await collector.computeRecoveryScore(for: session, from: result) {
            session.recoveryScore = outcome.score
            session.scoreBreakdown = outcome.breakdown
            session.frozenReadiness = ReanalysisService.computeFrozenReadiness(
                compositeScore: outcome.breakdown.compositeScore, trainingContext: result.trainingContext
            )
        }
        collector.baselineTracker.update(with: session, sleepSchedule: collector.settingsManager.settings.sleepSchedule)
        return session
    }

    /// Shown in the session's notes, so a sample night explains itself
    /// wherever it is opened.
    static var sampleNote: String {
        String(localized: "Sample night: synthetic data generated by Emuqu, not a real recording.", bundle: LanguageManager.appBundle)
    }

    // MARK: - Remove

    /// Remove every sample night and what it fed. Returns the number removed.
    @discardableResult
    func remove() async throws -> Int {
        guard !Self.isBusy else { throw SampleDataError.busy }
        Self.isBusy = true
        defer { Self.isBusy = false }
        let ids = sampleIds
        let archive = collector.archive
        let removed = await Task.detached(priority: .userInitiated) {
            DemoSessionSeeder.remove(ids, from: archive)
        }.value
        collector.notifyArchiveChanged()
        sendCloudDeletions(removed)
        await rebuildBaseline()
        guard removed.count == ids.count else { throw SampleDataError.incompleteRemoval(remaining: ids.count - removed.count) }
        restoreSettingsBaselineIfNeeded()
        defaults.removeObject(forKey: Self.ledgerKey)
        return removed.count
    }

    /// The same deletion every other delete path sends. A no-op when iCloud
    /// sync is off; a tombstone record when the night was never uploaded.
    private func sendCloudDeletions(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let deleteOne = deleteFromCloud
        Task {
            for id in ids {
                await deleteOne(id)
            }
        }
    }

    // MARK: - Baseline

    /// Rebuild the rolling baseline from what is left in the archive.
    ///
    /// Recomputed rather than subtracted: the tracker keeps one point per day
    /// with replacement rules, so "remove the sample nights' points" has no
    /// exact inverse. The archive is the source the tracker is always rebuilt
    /// from after a reinstall; the same rebuild here gives the same answer a
    /// device that never saw the sample nights would have.
    private func rebuildBaseline() async {
        let archive = collector.archive
        let entries = archive.entries
        let sessions = await Task.detached(priority: .userInitiated) {
            entries.compactMap { archive.retrieveLightweightOrLog($0.sessionId, caller: "sampleDataBaseline") }
        }.value
        collector.baselineTracker.reset()
        collector.baselineTracker.rebuildFromSessions(sessions, sleepSchedule: collector.settingsManager.settings.sleepSchedule)
    }

    private func recordPriorBaselineIfNeeded() {
        var ledger = loadLedger()
        guard !ledger.hasPriorBaseline else { return }
        let settings = collector.settingsManager.settings
        ledger.priorBaselineRMSSD = settings.baselineRMSSD
        ledger.priorBaselineHR = settings.baselineHR
        ledger.hasPriorBaseline = true
        saveLedger(ledger)
    }

    /// With three or more real nights left the rebuild has already written a
    /// fresh baseline into settings; with fewer it writes nothing, and the
    /// sample nights' value would otherwise stay behind.
    private func restoreSettingsBaselineIfNeeded() {
        let ledger = loadLedger()
        guard ledger.hasPriorBaseline, !collector.baselineTracker.hasValidBaseline else { return }
        var settings = collector.settingsManager.settings
        settings.baselineRMSSD = ledger.priorBaselineRMSSD
        settings.baselineHR = ledger.priorBaselineHR
        collector.settingsManager.settings = settings
    }

    // MARK: - Ledger

    /// What this device seeded, and the settings baseline from before it did.
    struct Ledger: Codable, Equatable {
        var sessionIds: [UUID] = []
        var priorBaselineRMSSD: Double?
        var priorBaselineHR: Double?
        var hasPriorBaseline = false
    }

    func loadLedger() -> Ledger {
        guard let data = defaults.data(forKey: Self.ledgerKey) else { return Ledger() }
        do {
            return try JSONDecoder().decode(Ledger.self, from: data)
        } catch {
            debugLog("[SampleData] Ledger unreadable, starting a new one: \(error.localizedDescription)", level: .warning)
            return Ledger()
        }
    }

    private func saveLedger(_ ledger: Ledger) {
        do {
            defaults.set(try JSONEncoder().encode(ledger), forKey: Self.ledgerKey)
        } catch {
            debugLog("[SampleData] Ledger not saved: \(error.localizedDescription)", level: .warning)
        }
    }

    private func appendToLedger(_ ids: [UUID]) {
        var ledger = loadLedger()
        ledger.sessionIds += ids
        saveLedger(ledger)
    }
}

/// Why loading or removing sample data did not complete.
enum SampleDataError: LocalizedError, Equatable {
    case busy
    case noOpenNights
    case incompleteRemoval(remaining: Int)

    var errorDescription: String? {
        switch self {
        case .busy:
            String(localized: "Sample data is already being updated. Try again in a moment.", bundle: LanguageManager.appBundle)
        case .noOpenNights:
            String(localized: "Every recent night already has a recording, so no sample nights were added.", bundle: LanguageManager.appBundle)
        case let .incompleteRemoval(remaining):
            String(localized: "\(remaining) sample nights could not be removed. Try again.", bundle: LanguageManager.appBundle)
        }
    }
}
