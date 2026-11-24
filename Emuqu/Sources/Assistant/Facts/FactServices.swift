/// The services fact code reads, and nothing else.
///
/// The factory hands one of these to every namespace that needs a service,
/// so a namespace's dependencies are this list rather than any read of
/// `AppDependencies.current`. Each accessor resolves on use, as the
/// container's do: building the registry constructs no Bluetooth, location
/// or HealthKit manager, and a test substitutes a service by building the
/// registry from a container with that override set.
struct FactServices: Sendable {
    private let container: AppDependencies

    init(_ container: AppDependencies) { self.container = container }

    var activeRouteSession: ActiveRouteSession { container.location.activeRouteSession }
    var ambientLocationService: AmbientLocationService { container.location.ambientLocationService }
    var apiKeyStore: APIKeyStore { container.providers.apiKeyStore }
    @MainActor
    var assistantArtifactStore: AssistantArtifactStore { container.assistant.assistantArtifactStore }
    @MainActor
    var assistantEmailBridge: AssistantEmailBridge { container.assistant.assistantEmailBridge }
    @MainActor
    var assistantViewModel: AssistantViewModel { container.assistant.assistantViewModel }
    @MainActor
    var breadcrumbRecorder: BreadcrumbRecorder { container.location.breadcrumbRecorder }
    var breadcrumbStore: BreadcrumbStore { container.location.breadcrumbStore }
    @MainActor
    var capabilityClassifier: CapabilityClassifier { container.providers.capabilityClassifier }
    @MainActor
    var concept2Manager: Concept2Manager { container.collection.concept2Manager }
    @MainActor
    var emailContactStore: EmailContactStore { container.app.emailContactStore }
    @MainActor
    var footPodManager: FootPodManager { container.collection.footPodManager }
    var healthKitManager: HealthKitManager { container.collection.healthKitManager }
    @MainActor
    var heatAcclimationCache: HeatAcclimationCache { container.analysis.heatAcclimationCache }
    var liveHRVBroker: LiveHRVBroker { container.assistant.liveHRVBroker }
    var liveWorkoutBroker: LiveWorkoutBroker { container.assistant.liveWorkoutBroker }
    @MainActor
    var providerConsentTracker: ProviderConsentTracker { container.providers.providerConsentTracker }
    @MainActor
    var providerRegistry: ProviderRegistry { container.providers.providerRegistry }
    @MainActor
    var roadGeocodingService: RoadGeocodingService { container.location.roadGeocodingService }
    @MainActor
    var savedRouteStore: SavedRouteStore { container.location.savedRouteStore }
    var sessionArchive: SessionArchive { container.storage.sessionArchive }
    var settingsManager: SettingsManager { container.app.settingsManager }
    @MainActor
    var smartProviderRouter: SmartProviderRouter { container.providers.smartProviderRouter }
    @MainActor
    var surroundingsPOIService: SurroundingsPOIService { container.location.surroundingsPOIService }
    @MainActor
    var trainingMetricsCache: TrainingMetricsCache { container.analysis.trainingMetricsCache }
    var userFactsStore: UserFactsStore { container.assistant.userFactsStore }
    @MainActor
    var webSearchService: WebSearchService { container.providers.webSearchService }
    @MainActor
    var zwiftPeripheralBroadcaster: ZwiftPeripheralBroadcaster { container.collection.zwiftPeripheralBroadcaster }
}
