/// The services the assistant's context is built from, and nothing else.
///
/// `AssistantContextSource` is built with one and hands it to
/// `ContextBuilder.build`. Each accessor resolves on use, as the container's
/// do, and a test substitutes one by building these from a container with
/// that override set.
struct ContextServices: Sendable {
    private let container: AppDependencies

    init(_ container: AppDependencies) { self.container = container }

    var ambientLocationService: AmbientLocationService { container.location.ambientLocationService }
    var analysisSummaryCache: AnalysisSummaryCache { container.assistant.analysisSummaryCache }
    var liveHRVBroker: LiveHRVBroker { container.assistant.liveHRVBroker }
    var liveWorkoutBroker: LiveWorkoutBroker { container.assistant.liveWorkoutBroker }
    var sessionArchive: SessionArchive { container.storage.sessionArchive }
    var settingsManager: SettingsManager { container.app.settingsManager }
    @MainActor
    var trainingMetricsCache: TrainingMetricsCache { container.analysis.trainingMetricsCache }
}
