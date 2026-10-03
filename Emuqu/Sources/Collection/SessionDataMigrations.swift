import Foundation

/// One-shot repairs to already-archived sessions, run once per install.
///
/// ## Why this is not on `RRCollector`
///
/// It was. `RRCollector` is the recording pipeline — it owns
/// the strap connection, the streaming buffers, pause/resume, and the handoff
/// of a finished session to the archive. These five migrations do none of that.
/// They open sessions that were archived months ago, recompute a field that a
/// past release got wrong, and write them back.
///
/// They lived on the collector for the ordinary reason: the collector already
/// had an `archive` reference, so putting them there needed no plumbing. The
/// cost was that `RRCollector` measured 6,619 lines across 23 files and read as
/// a type with no boundary. 504 of those lines were this, which shares
/// nothing with recording
/// but a dependency.
///
/// The seam is exact rather than convenient: these five files call **no** other
/// method of `RRCollector` — verified before the move, not assumed — and read
/// only `archive`, `healthKit` and `settingsManager`. So this is a boundary
/// that already existed and was not written down, which is the only kind worth
/// cutting on in a recording path nobody wants to break.
///
/// ## Ordering
///
/// Each migration self-terminates through its own `UserDefaults` flag, so extra
/// calls are cheap no-ops and the order is not a correctness constraint. The
/// stagger is: it spreads the archive reads past the dashboard's first render
/// so the user sees a populated screen before the disk work starts.
@MainActor
final class SessionDataMigrations {
    let archive: SessionArchive
    let healthKit: HealthKitManager
    let settingsManager: SettingsManager
    let baselineTracker: BaselineTracker

    /// The reanalysis engine. Injected rather than rebuilt here — `RRCollector`
    /// caches one and its providers close over the collector's settings
    /// snapshot, so constructing a second would quietly diverge from the one
    /// the rest of the app uses.
    let reanalysisService: ReanalysisService

    init(
        archive: SessionArchive,
        healthKit: HealthKitManager,
        settingsManager: SettingsManager,
        baselineTracker: BaselineTracker,
        reanalysisService: ReanalysisService
    ) {
        self.archive = archive
        self.healthKit = healthKit
        self.settingsManager = settingsManager
        self.baselineTracker = baselineTracker
        self.reanalysisService = reanalysisService
    }

    /// The baseline a stored night is rescored against: the nights before it,
    /// as when it was first scored. Nil when no earlier night qualifies; the
    /// night is then left as it is.
    func scoringBaseline(for session: HRVSession) -> BaselineTracker.RecoveryBaselineStats? {
        baselineTracker.recoveryBaselineStats(
            excludingNightOf: session, sleepSchedule: settingsManager.settings.sleepSchedule
        )
    }

    /// Reads every archived session in full, newest first, off the main actor:
    /// decrypting and decoding a large archive held the first screen for
    /// seconds. Read afresh on each call, because later migrations must see
    /// what earlier ones wrote. Full sessions, not lightweight ones: a
    /// migration writes them back, and a copy without its beats would erase
    /// them.
    func loadArchivedSessions() async -> [HRVSession] {
        let archive = self.archive
        return await Task.detached(priority: .utility) {
            archive.entries.compactMap { archive.retrieveOrLog($0.sessionId, caller: "SessionDataMigrations") }
        }.value
    }

    /// Run every deferred repair from background priority, staggered so they do
    /// not all contend for the archive lock at once.
    ///
    /// Timings are carried over unchanged from `RRCollector+Lifecycle`, where
    /// they were tuned against cold-launch traces.
    func runAllIfNeeded() async {
        await sleepQuietly(1_500_000_000, context: "SessionDataMigrations")
        await runInsufficientDataMigrationIfNeeded()

        await sleepQuietly(1_000_000_000, context: "SessionDataMigrations")
        await runTrainingRecalibrationIfNeeded()

        await sleepQuietly(500_000_000, context: "SessionDataMigrations")
        await runTrimpRepairMigrationIfNeeded()

        await sleepQuietly(500_000_000, context: "SessionDataMigrations")
        await runWorkoutSleepCleanupIfNeeded()

        await sleepQuietly(500_000_000, context: "SessionDataMigrations")
        await runNapRepairMigrationIfNeeded()
    }
}
