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
/// keeps. Both leave a night HealthKit did not answer for as stored and run
/// again on a later launch (`finishTrainingMigration`); the TRIMP repair is
/// not marked done before the recalibration is, so it still runs last.
/// Neither moves the recovery score, which does not read training. The
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
        // An index that did not load lists no sessions: each pass would find
        // nothing to do and set its flag having read nothing.
        guard archive.hasCompleteIndex else {
            debugLog("[SessionDataMigrations] Index not loaded this launch: migrations wait for a launch that reads it", level: .warning)
            return
        }
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

// MARK: - One-shot training migrations that HealthKit has to answer

extension SessionDataMigrations {
    /// Launches a training migration retries while HealthKit leaves some of
    /// its nights unanswered (the store locked before first unlock, a
    /// timeout). Those nights are left as stored on every pass, so giving up
    /// after this many only stops the retries; nothing is rewritten from an
    /// unanswered query.
    nonisolated static let maxTrainingMigrationAttempts = 5

    /// Ends a pass of the one-shot migration under `key`. Its flag is set
    /// when the pass covered every candidate (`complete`: each one read,
    /// answered and written), or once it has run
    /// `maxTrainingMigrationAttempts` times; otherwise it runs again on a
    /// later launch. True when the flag was set.
    @discardableResult
    nonisolated static func finishTrainingMigration(key: String, complete: Bool, defaults: UserDefaults = .standard) -> Bool {
        let attemptsKey = key + "_attempts"
        let attempts = defaults.integer(forKey: attemptsKey) + 1
        guard complete || attempts >= maxTrainingMigrationAttempts else {
            defaults.set(attempts, forKey: attemptsKey)
            return false
        }
        defaults.set(true, forKey: key)
        defaults.removeObject(forKey: attemptsKey)
        return true
    }
}
