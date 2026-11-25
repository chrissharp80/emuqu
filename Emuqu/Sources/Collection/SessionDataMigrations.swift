import Foundation

/// One-shot repairs to already-archived sessions, run once per install.
///
/// These migrations open sessions archived long ago, recompute a field an
/// earlier release got wrong, and write them back. They share nothing with
/// recording: they read only the dependencies injected below —
/// `archive`, `healthKit`, `sleepQueries`, `settingsManager`,
/// `baselineTracker` and `reanalysisService` — and call no method of
/// `RRCollector`.
///
/// ## Ordering
///
/// Each migration self-terminates through its own `UserDefaults` flag, so extra
/// calls are cheap no-ops. The order does decide one thing: the training
/// recalibration and the TRIMP repair both rewrite a night's training
/// snapshot (and the readiness derived from it), each with its own anchor,
/// and the TRIMP repair runs second, so its context is the one the archive
/// keeps. Neither moves the recovery score, which does not read training. The
/// stagger spreads the archive reads past the dashboard's first render so the
/// user sees a populated screen before the disk work starts; a cancelled
/// launch stops the chain, and the rest run on a later launch.
@MainActor
final class SessionDataMigrations {
    let archive: SessionArchive
    let healthKit: any HealthKitServiceProtocol
    /// The nap read the nap repair makes.
    let sleepQueries: SleepHealthQueries
    let settingsManager: SettingsManager
    let baselineTracker: BaselineTracker

    /// The reanalysis engine (`SessionReanalysisCoordinator.service`).
    /// Injected rather than rebuilt here, so the migrations' rescores update
    /// the same baseline tracker and archive signal as the rest of the app.
    let reanalysisService: ReanalysisService

    init(
        archive: SessionArchive,
        healthKit: any HealthKitServiceProtocol,
        sleepQueries: SleepHealthQueries,
        settingsManager: SettingsManager,
        baselineTracker: BaselineTracker,
        reanalysisService: ReanalysisService
    ) {
        self.archive = archive
        self.healthKit = healthKit
        self.sleepQueries = sleepQueries
        self.settingsManager = settingsManager
        self.baselineTracker = baselineTracker
        self.reanalysisService = reanalysisService
    }

    /// One archived session in full, read off the main actor, for the
    /// migrations that walk the archive a session at a time.
    func retrieveOffMain(_ sessionId: UUID, caller: String) async -> HRVSession? {
        let archive = self.archive
        return await Task.detached(priority: .utility) {
            archive.retrieveOrLog(sessionId, caller: caller)
        }.value
    }

    /// Every archived session, newest first, decoded in full one at a time off
    /// the main actor. Taken afresh by each migration, so later migrations see
    /// what earlier ones wrote. Full sessions, not lightweight ones: a
    /// migration writes them back, and a copy without its beats would erase
    /// them.
    var archivedSessions: ArchivedSessions {
        ArchivedSessions(archive: archive, caller: "SessionDataMigrations")
    }

    /// Run every deferred repair from background priority, staggered so they do
    /// not all contend for the archive lock at once.
    ///
    /// Timings are tuned against cold-launch traces.
    func runAllIfNeeded() async {
        for step in migrationSchedule {
            await sleepQuietly(step.delay, context: "SessionDataMigrations")
            // `sleepQuietly` swallows a cancellation; the chain stops on it.
            guard !Task.isCancelled else { return }
            await step.run()
        }
    }

    /// Each migration with the pause before it.
    private var migrationSchedule: [(delay: UInt64, run: @MainActor () async -> Void)] {
        [
            (1_500_000_000, { await self.runInsufficientDataMigrationIfNeeded() }),
            (1_000_000_000, { await self.runTrainingRecalibrationIfNeeded() }),
            (500_000_000, { await self.runTrimpRepairMigrationIfNeeded() }),
            (500_000_000, { await self.runWorkoutSleepCleanupIfNeeded() }),
            (500_000_000, { await self.runNapRepairMigrationIfNeeded() }),
            (500_000_000, { await self.runTimeInBedRepairIfNeeded() })
        ]
    }
}
