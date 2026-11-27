import Foundation

// The composition root's saved-session reanalysis: the instances it shares
// with the recording collector, and the factory that builds the reanalysis
// from explicit parts. `CollectionServices` in `AppDependencies.swift`
// serves them.

/// Saved-session reanalysis and what it shares with the recording collector,
/// one instance each, built on first use. `RRCollector.makeDefault()` is given
/// the same baseline tracker, archive signal and scoring context, so a rescore
/// updates the baseline the collector scores against and bumps the signal its
/// views observe. The reanalysis instance starts its listeners when built;
/// `EmuquApp` builds it at launch.
@MainActor
enum SessionReanalysisRoot {
    static let baselineTracker: BaselineTracker = {
        let settingsManager = AppDependencies.current.app.settingsManager
        return BaselineTracker(onBaselineUpdated: { rmssd, hr in
            settingsManager.updateBaseline(rmssd: rmssd, hr: hr)
        })
    }()
    static let archiveSignal = ArchiveSignal()
    static let scoring: SessionScoringContext = {
        let dependencies = AppDependencies.current
        return SessionScoringContext(
            settingsManager: dependencies.app.settingsManager,
            healthKit: dependencies.collection.healthKitManager.service,
            baselineTracker: dependencies.collection.baselineTracker
        )
    }()
    static let reanalysis: SessionReanalysisCoordinator = {
        let coordinator = AppDependencies.makeSessionReanalysis(.fromContainer(AppDependencies.current))
        coordinator.startListening()
        return coordinator
    }()
}

/// What saved-session reanalysis is built from.
struct SessionReanalysisParts {
    let archive: SessionArchive
    let healthKit: HealthKitManager
    let scoring: SessionScoringContext
    let archiveSignal: ArchiveSignal
    let cloudSync: CloudKitSyncManager
    /// Resolved on first use, so building the reanalysis at launch does not
    /// load the cache's snapshot.
    let trainingMetricsCache: @MainActor () -> TrainingMetricsCache
    /// Drops a rewritten session's cached chart zones.
    let invalidateZones: @MainActor (UUID) -> Void

    /// The container's archive, HealthKit, scoring context, archive signal,
    /// iCloud sync, a resolver for its training-metrics cache, and its chart
    /// zones cache's invalidation, resolved when first called.
    @MainActor
    static func fromContainer(_ dependencies: AppDependencies) -> SessionReanalysisParts {
        SessionReanalysisParts(
            archive: dependencies.storage.sessionArchive,
            healthKit: dependencies.collection.healthKitManager,
            scoring: dependencies.collection.sessionScoring,
            archiveSignal: dependencies.collection.archiveSignal,
            cloudSync: dependencies.storage.cloudKitSyncManager,
            trainingMetricsCache: { dependencies.analysis.trainingMetricsCache },
            invalidateZones: { dependencies.app.organizedZonesCache.invalidate($0) }
        )
    }
}

extension AppDependencies {
    /// Saved-session reanalysis built from `parts`, its listeners not
    /// started. The app's instance is `collection.sessionReanalysis`; a test
    /// builds its own around a private archive.
    @MainActor
    static func makeSessionReanalysis(_ parts: SessionReanalysisParts) -> SessionReanalysisCoordinator {
        SessionReanalysisCoordinator(
            service: makeReanalysisService(parts),
            archive: parts.archive,
            healthKit: parts.healthKit.service,
            healthObservation: parts.healthKit.observation,
            sleepQueries: parts.healthKit.sleepQueries,
            scoring: parts.scoring,
            archiveSignal: parts.archiveSignal,
            trainingMetricsCache: parts.trainingMetricsCache
        )
    }

    /// The reanalysis engine over `parts`: its own analysis pipeline (the
    /// default artifact detector and window selector, which hold only their
    /// default configuration), settings, configuration and training context
    /// from the scoring context, archive changes to the archive signal, and
    /// each rewritten session re-uploaded to iCloud with the edit stamp the
    /// archive gave it (`CloudKitSyncManager.reuploadRewrite`).
    @MainActor
    private static func makeReanalysisService(_ parts: SessionReanalysisParts) -> ReanalysisService {
        let scoring = parts.scoring
        let pipeline = defaultAnalysisPipeline(healthKit: parts.healthKit)
        return ReanalysisService(
            archive: parts.archive, healthKit: parts.healthKit.service, analysisPipeline: pipeline,
            windowSelector: pipeline.windowSelector, artifactDetector: pipeline.artifactDetector,
            baselineTracker: scoring.baselineTracker,
            settingsProvider: { scoring.settingsManager.settings },
            scoringConfigProvider: { scoring.currentScoringConfig },
            ansConfigProvider: { scoring.ansConfig(for: $0) },
            trainingContextProvider: { scoring.createTrainingContext(relativeTo: $0) },
            analyzeWithWindow: { await scoring.analyze($0, window: $1, flags: $2, peakCapacity: $3, pipeline: pipeline) },
            analyzeFullSession: { await scoring.analyze($0, peakCapacity: $1, pipeline: pipeline) },
            onArchiveChanged: { [archiveSignal = parts.archiveSignal] in archiveSignal.notifyChanged() },
            onSessionUploaded: { [cloudSync = parts.cloudSync] session in
                Task { await cloudSync.reuploadRewrite(session) }
            },
            onZonesStale: parts.invalidateZones
        )
    }

    /// An analysis pipeline over a default artifact detector and window
    /// selector, which hold only their default configuration.
    @MainActor
    private static func defaultAnalysisPipeline(healthKit: HealthKitManager) -> HRVAnalysisPipeline {
        HRVAnalysisPipeline(artifactDetector: ArtifactDetector(), windowSelector: WindowSelector(), healthKit: healthKit.service)
    }
}
