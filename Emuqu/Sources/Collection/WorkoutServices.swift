/// The services a live workout reads, and nothing else.
///
/// The recorder is handed one at construction and its parts (ticker,
/// lifecycle, finalizer, AI-context builder) read through
/// `recorder.services`, so what a workout touches is this list rather than
/// any read of `AppDependencies.current`. Each accessor resolves on use, as
/// the container's do: constructing a recorder starts no PM5, Zwift or
/// weather service, and a test substitutes one by building the recorder from
/// a container with that override set.
struct WorkoutServices: Sendable {
    private let container: AppDependencies

    init(_ container: AppDependencies) { self.container = container }

    var activeRouteSession: ActiveRouteSession { container.location.activeRouteSession }
    var ambientLocationService: AmbientLocationService { container.location.ambientLocationService }
    @MainActor
    var assistantEmailBridge: AssistantEmailBridge { container.assistant.assistantEmailBridge }
    @MainActor
    var backgroundAudioManager: BackgroundAudioManager { container.collection.backgroundAudioManager }
    var breadcrumbStore: BreadcrumbStore { container.location.breadcrumbStore }
    @MainActor
    var concept2Manager: Concept2Manager { container.collection.concept2Manager }
    @MainActor
    var footPodManager: FootPodManager { container.collection.footPodManager }
    var liveWorkoutBroker: LiveWorkoutBroker { container.assistant.liveWorkoutBroker }
    @MainActor
    var roadGeocodingService: RoadGeocodingService { container.location.roadGeocodingService }
    @MainActor
    var savedRouteStore: SavedRouteStore { container.location.savedRouteStore }
    var sessionArchive: SessionArchive { container.storage.sessionArchive }
    var settingsManager: SettingsManager { container.app.settingsManager }
    var systemDiagnosticsManager: SystemDiagnosticsManager { container.app.systemDiagnosticsManager }
    @MainActor
    var trainingMetricsCache: TrainingMetricsCache { container.analysis.trainingMetricsCache }
    @MainActor
    var watchConnectivityBridge: WatchConnectivityBridge { container.services.watchConnectivityBridge }
    @MainActor
    var weatherService: WeatherService { container.location.weatherService }
    @MainActor
    var workoutStartLatencyTracker: WorkoutStartLatencyTracker { container.collection.workoutStartLatencyTracker }
    var workoutTrackBackup: WorkoutTrackBackup { container.storage.workoutTrackBackup }
    @MainActor
    var zwiftPeripheralBroadcaster: ZwiftPeripheralBroadcaster { container.collection.zwiftPeripheralBroadcaster }
}
