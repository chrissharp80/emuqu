import Foundation
import os
import SwiftUI

/// The app's long-lived services, in one place, grouped by layer.
///
/// Reaching services as `Type.shared` from wherever they are needed makes
/// the middle of the app impossible to test with a substitute and impossible
/// to read for who depends on what. So:
///
/// - This file is the composition root: `Type.shared` is read here and
///   nowhere else (`scripts/check_no_shared_outside_root.sh` enforces it).
/// - Every accessor resolves lazily, so nothing is constructed until it is
///   asked for and no service's initialiser can recurse into the container.
/// - Views read `@Environment(\.dependencies)`; the root injects `.current`.
/// - Static helpers read `AppDependencies.current`.
/// - A test makes a fresh container, sets the substitute on its `overrides`,
///   assigns it to `current` in `setUp`, and calls `reset()` in `tearDown`.
///
/// Accessors for main-actor classes are main-actor isolated, exactly as their
/// `shared` statics are; nonisolated code could not reach those before and
/// cannot now.
struct AppDependencies: Sendable {
    /// Substitutes, if any. One box for the whole container so the groups
    /// stay plain `Sendable` values.
    let overrides = Overrides()

    var app: UtilityServices { UtilityServices(overrides: overrides) }
    var analysis: AnalysisServices { AnalysisServices(overrides: overrides) }
    var assistant: AssistantServices { AssistantServices(overrides: overrides) }
    var collection: CollectionServices { CollectionServices(overrides: overrides) }
    var location: LocationServices { LocationServices(overrides: overrides) }
    var providers: ProviderServices { ProviderServices(overrides: overrides) }
    var services: AppServices { AppServices(overrides: overrides) }
    var storage: StorageServices { StorageServices(overrides: overrides) }

    init() {}

    /// The container in force. The app never sets it; a test swaps it and
    /// restores it. Reads happen from any thread — the fact resolvers run off
    /// the main actor — which is why the storage is a lock.
    static var current: AppDependencies {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    /// Back to the live services. Tests that swapped `current` call this from `tearDown`.
    static func reset() { storage.withLock { $0 = AppDependencies() } }

    private static let storage = OSAllocatedUnfairLock<AppDependencies>(initialState: AppDependencies())

    /// Test substitutes for the services below. The values sit behind a lock so
    /// a test can install one from any isolation and the accessors stay
    /// `Sendable` without an unchecked conformance.
    final class Overrides: Sendable {
        private struct Values: Sendable {
            var alpha1StatsCache: Alpha1StatsCache?
            var crashLogManager: CrashLogManager?
            var debugLogger: DebugLogger?
            var emailContactStore: EmailContactStore?
            var featureFlags: FeatureFlags?
            var globalKeyboardDismissal: GlobalKeyboardDismissal?
            var keyboardPerfSignpost: KeyboardPerfSignpost?
            var launchCoordinator: LaunchCoordinator?
            var organizedZonesCache: OrganizedZonesCache?
            var recorderBox: RecorderBox?
            var settingsManager: SettingsManager?
            var systemDiagnosticsManager: SystemDiagnosticsManager?
            var beatConsistencyPriorsCache: BeatConsistencyPriorsCache?
            var heatAcclimationCache: HeatAcclimationCache?
            var trainingMetricsCache: TrainingMetricsCache?
            var analysisSummaryCache: AnalysisSummaryCache?
            var assistantArtifactStore: AssistantArtifactStore?
            var assistantContextSource: AssistantContextSource?
            var assistantEmailBridge: AssistantEmailBridge?
            var assistantInbox: AssistantInbox?
            var assistantViewModel: AssistantViewModel?
            var conversationStore: ConversationStore?
            var liveHRVBroker: LiveHRVBroker?
            var liveWorkoutBroker: LiveWorkoutBroker?
            var userFactsStore: UserFactsStore?
            var voiceConversationController: VoiceConversationController?
            var backgroundAudioManager: BackgroundAudioManager?
            var concept2Manager: Concept2Manager?
            var footPodManager: FootPodManager?
            var healthKitManager: HealthKitManager?
            var workoutStartLatencyTracker: WorkoutStartLatencyTracker?
            var zwiftPeripheralBroadcaster: ZwiftPeripheralBroadcaster?
            var activeRouteSession: ActiveRouteSession?
            var ambientLocationService: AmbientLocationService?
            var breadcrumbRecorder: BreadcrumbRecorder?
            var breadcrumbStore: BreadcrumbStore?
            var locationFinder: LocationFinder?
            var roadGeocodingService: RoadGeocodingService?
            var roadGraphService: RoadGraphService?
            var savedRouteStore: SavedRouteStore?
            var surroundingsPOIService: SurroundingsPOIService?
            var trailDiscoveryService: TrailDiscoveryService?
            var weatherService: WeatherService?
            var apiKeyStore: APIKeyStore?
            var appleToolDispatcher: AppleToolDispatcher?
            var capabilityClassifier: CapabilityClassifier?
            var llmCacheTelemetry: LLMCacheTelemetry?
            var llmRequestAudit: LLMRequestAudit?
            var providerConsentTracker: ProviderConsentTracker?
            var providerRegistry: ProviderRegistry?
            var smartProviderRouter: SmartProviderRouter?
            var webSearchService: WebSearchService?
            var whisperKitSTTBridge: WhisperKitSTTBridge?
            var audioSessionCoordinator: AudioSessionCoordinator?
            var languageManager: LanguageManager?
            var morningNotificationScheduler: MorningNotificationScheduler?
            var powerStatePolicy: PowerStatePolicy?
            var preScorePromptTelemetry: PreScorePromptTelemetry?
            var recoveryScoreFeedbackStore: RecoveryScoreFeedbackStore?
            var storeKitManager: StoreKitManager?
            var validationTelemetry: ValidationTelemetry?
            var watchConnectivityBridge: WatchConnectivityBridge?
            var cloudKitSettingsSync: CloudKitSettingsSync?
            var cloudKitSyncManager: CloudKitSyncManager?
            var encryptionManager: EncryptionManager?
            var sessionArchive: SessionArchive?
            var uiStateCache: UIStateCache?
            var workoutTrackBackup: WorkoutTrackBackup?
        }

        private let values = OSAllocatedUnfairLock(initialState: Values())

        var alpha1StatsCache: Alpha1StatsCache? {
            get { values.withLock { $0.alpha1StatsCache } }
            set { values.withLock { $0.alpha1StatsCache = newValue } }
        }
        var crashLogManager: CrashLogManager? {
            get { values.withLock { $0.crashLogManager } }
            set { values.withLock { $0.crashLogManager = newValue } }
        }
        var debugLogger: DebugLogger? {
            get { values.withLock { $0.debugLogger } }
            set { values.withLock { $0.debugLogger = newValue } }
        }
        var emailContactStore: EmailContactStore? {
            get { values.withLock { $0.emailContactStore } }
            set { values.withLock { $0.emailContactStore = newValue } }
        }
        var featureFlags: FeatureFlags? {
            get { values.withLock { $0.featureFlags } }
            set { values.withLock { $0.featureFlags = newValue } }
        }
        var globalKeyboardDismissal: GlobalKeyboardDismissal? {
            get { values.withLock { $0.globalKeyboardDismissal } }
            set { values.withLock { $0.globalKeyboardDismissal = newValue } }
        }
        var keyboardPerfSignpost: KeyboardPerfSignpost? {
            get { values.withLock { $0.keyboardPerfSignpost } }
            set { values.withLock { $0.keyboardPerfSignpost = newValue } }
        }
        var launchCoordinator: LaunchCoordinator? {
            get { values.withLock { $0.launchCoordinator } }
            set { values.withLock { $0.launchCoordinator = newValue } }
        }
        var organizedZonesCache: OrganizedZonesCache? {
            get { values.withLock { $0.organizedZonesCache } }
            set { values.withLock { $0.organizedZonesCache = newValue } }
        }
        var recorderBox: RecorderBox? {
            get { values.withLock { $0.recorderBox } }
            set { values.withLock { $0.recorderBox = newValue } }
        }
        var settingsManager: SettingsManager? {
            get { values.withLock { $0.settingsManager } }
            set { values.withLock { $0.settingsManager = newValue } }
        }
        var systemDiagnosticsManager: SystemDiagnosticsManager? {
            get { values.withLock { $0.systemDiagnosticsManager } }
            set { values.withLock { $0.systemDiagnosticsManager = newValue } }
        }
        var beatConsistencyPriorsCache: BeatConsistencyPriorsCache? {
            get { values.withLock { $0.beatConsistencyPriorsCache } }
            set { values.withLock { $0.beatConsistencyPriorsCache = newValue } }
        }
        var heatAcclimationCache: HeatAcclimationCache? {
            get { values.withLock { $0.heatAcclimationCache } }
            set { values.withLock { $0.heatAcclimationCache = newValue } }
        }
        var trainingMetricsCache: TrainingMetricsCache? {
            get { values.withLock { $0.trainingMetricsCache } }
            set { values.withLock { $0.trainingMetricsCache = newValue } }
        }
        var analysisSummaryCache: AnalysisSummaryCache? {
            get { values.withLock { $0.analysisSummaryCache } }
            set { values.withLock { $0.analysisSummaryCache = newValue } }
        }
        var assistantArtifactStore: AssistantArtifactStore? {
            get { values.withLock { $0.assistantArtifactStore } }
            set { values.withLock { $0.assistantArtifactStore = newValue } }
        }
        var assistantContextSource: AssistantContextSource? {
            get { values.withLock { $0.assistantContextSource } }
            set { values.withLock { $0.assistantContextSource = newValue } }
        }
        var assistantEmailBridge: AssistantEmailBridge? {
            get { values.withLock { $0.assistantEmailBridge } }
            set { values.withLock { $0.assistantEmailBridge = newValue } }
        }
        var assistantInbox: AssistantInbox? {
            get { values.withLock { $0.assistantInbox } }
            set { values.withLock { $0.assistantInbox = newValue } }
        }
        var assistantViewModel: AssistantViewModel? {
            get { values.withLock { $0.assistantViewModel } }
            set { values.withLock { $0.assistantViewModel = newValue } }
        }
        var conversationStore: ConversationStore? {
            get { values.withLock { $0.conversationStore } }
            set { values.withLock { $0.conversationStore = newValue } }
        }
        var liveHRVBroker: LiveHRVBroker? {
            get { values.withLock { $0.liveHRVBroker } }
            set { values.withLock { $0.liveHRVBroker = newValue } }
        }
        var liveWorkoutBroker: LiveWorkoutBroker? {
            get { values.withLock { $0.liveWorkoutBroker } }
            set { values.withLock { $0.liveWorkoutBroker = newValue } }
        }
        var userFactsStore: UserFactsStore? {
            get { values.withLock { $0.userFactsStore } }
            set { values.withLock { $0.userFactsStore = newValue } }
        }
        var voiceConversationController: VoiceConversationController? {
            get { values.withLock { $0.voiceConversationController } }
            set { values.withLock { $0.voiceConversationController = newValue } }
        }
        var backgroundAudioManager: BackgroundAudioManager? {
            get { values.withLock { $0.backgroundAudioManager } }
            set { values.withLock { $0.backgroundAudioManager = newValue } }
        }
        var concept2Manager: Concept2Manager? {
            get { values.withLock { $0.concept2Manager } }
            set { values.withLock { $0.concept2Manager = newValue } }
        }
        var footPodManager: FootPodManager? {
            get { values.withLock { $0.footPodManager } }
            set { values.withLock { $0.footPodManager = newValue } }
        }
        var healthKitManager: HealthKitManager? {
            get { values.withLock { $0.healthKitManager } }
            set { values.withLock { $0.healthKitManager = newValue } }
        }
        var workoutStartLatencyTracker: WorkoutStartLatencyTracker? {
            get { values.withLock { $0.workoutStartLatencyTracker } }
            set { values.withLock { $0.workoutStartLatencyTracker = newValue } }
        }
        var zwiftPeripheralBroadcaster: ZwiftPeripheralBroadcaster? {
            get { values.withLock { $0.zwiftPeripheralBroadcaster } }
            set { values.withLock { $0.zwiftPeripheralBroadcaster = newValue } }
        }
        var activeRouteSession: ActiveRouteSession? {
            get { values.withLock { $0.activeRouteSession } }
            set { values.withLock { $0.activeRouteSession = newValue } }
        }
        var ambientLocationService: AmbientLocationService? {
            get { values.withLock { $0.ambientLocationService } }
            set { values.withLock { $0.ambientLocationService = newValue } }
        }
        var breadcrumbRecorder: BreadcrumbRecorder? {
            get { values.withLock { $0.breadcrumbRecorder } }
            set { values.withLock { $0.breadcrumbRecorder = newValue } }
        }
        var breadcrumbStore: BreadcrumbStore? {
            get { values.withLock { $0.breadcrumbStore } }
            set { values.withLock { $0.breadcrumbStore = newValue } }
        }
        var locationFinder: LocationFinder? {
            get { values.withLock { $0.locationFinder } }
            set { values.withLock { $0.locationFinder = newValue } }
        }
        var roadGeocodingService: RoadGeocodingService? {
            get { values.withLock { $0.roadGeocodingService } }
            set { values.withLock { $0.roadGeocodingService = newValue } }
        }
        var roadGraphService: RoadGraphService? {
            get { values.withLock { $0.roadGraphService } }
            set { values.withLock { $0.roadGraphService = newValue } }
        }
        var savedRouteStore: SavedRouteStore? {
            get { values.withLock { $0.savedRouteStore } }
            set { values.withLock { $0.savedRouteStore = newValue } }
        }
        var surroundingsPOIService: SurroundingsPOIService? {
            get { values.withLock { $0.surroundingsPOIService } }
            set { values.withLock { $0.surroundingsPOIService = newValue } }
        }
        var trailDiscoveryService: TrailDiscoveryService? {
            get { values.withLock { $0.trailDiscoveryService } }
            set { values.withLock { $0.trailDiscoveryService = newValue } }
        }
        var weatherService: WeatherService? {
            get { values.withLock { $0.weatherService } }
            set { values.withLock { $0.weatherService = newValue } }
        }
        var apiKeyStore: APIKeyStore? {
            get { values.withLock { $0.apiKeyStore } }
            set { values.withLock { $0.apiKeyStore = newValue } }
        }
        var appleToolDispatcher: AppleToolDispatcher? {
            get { values.withLock { $0.appleToolDispatcher } }
            set { values.withLock { $0.appleToolDispatcher = newValue } }
        }
        var capabilityClassifier: CapabilityClassifier? {
            get { values.withLock { $0.capabilityClassifier } }
            set { values.withLock { $0.capabilityClassifier = newValue } }
        }
        var llmCacheTelemetry: LLMCacheTelemetry? {
            get { values.withLock { $0.llmCacheTelemetry } }
            set { values.withLock { $0.llmCacheTelemetry = newValue } }
        }
        var llmRequestAudit: LLMRequestAudit? {
            get { values.withLock { $0.llmRequestAudit } }
            set { values.withLock { $0.llmRequestAudit = newValue } }
        }
        var providerConsentTracker: ProviderConsentTracker? {
            get { values.withLock { $0.providerConsentTracker } }
            set { values.withLock { $0.providerConsentTracker = newValue } }
        }
        var providerRegistry: ProviderRegistry? {
            get { values.withLock { $0.providerRegistry } }
            set { values.withLock { $0.providerRegistry = newValue } }
        }
        var smartProviderRouter: SmartProviderRouter? {
            get { values.withLock { $0.smartProviderRouter } }
            set { values.withLock { $0.smartProviderRouter = newValue } }
        }
        var webSearchService: WebSearchService? {
            get { values.withLock { $0.webSearchService } }
            set { values.withLock { $0.webSearchService = newValue } }
        }
        var whisperKitSTTBridge: WhisperKitSTTBridge? {
            get { values.withLock { $0.whisperKitSTTBridge } }
            set { values.withLock { $0.whisperKitSTTBridge = newValue } }
        }
        var audioSessionCoordinator: AudioSessionCoordinator? {
            get { values.withLock { $0.audioSessionCoordinator } }
            set { values.withLock { $0.audioSessionCoordinator = newValue } }
        }
        var languageManager: LanguageManager? {
            get { values.withLock { $0.languageManager } }
            set { values.withLock { $0.languageManager = newValue } }
        }
        var morningNotificationScheduler: MorningNotificationScheduler? {
            get { values.withLock { $0.morningNotificationScheduler } }
            set { values.withLock { $0.morningNotificationScheduler = newValue } }
        }
        var powerStatePolicy: PowerStatePolicy? {
            get { values.withLock { $0.powerStatePolicy } }
            set { values.withLock { $0.powerStatePolicy = newValue } }
        }
        var preScorePromptTelemetry: PreScorePromptTelemetry? {
            get { values.withLock { $0.preScorePromptTelemetry } }
            set { values.withLock { $0.preScorePromptTelemetry = newValue } }
        }
        var recoveryScoreFeedbackStore: RecoveryScoreFeedbackStore? {
            get { values.withLock { $0.recoveryScoreFeedbackStore } }
            set { values.withLock { $0.recoveryScoreFeedbackStore = newValue } }
        }
        var storeKitManager: StoreKitManager? {
            get { values.withLock { $0.storeKitManager } }
            set { values.withLock { $0.storeKitManager = newValue } }
        }
        var validationTelemetry: ValidationTelemetry? {
            get { values.withLock { $0.validationTelemetry } }
            set { values.withLock { $0.validationTelemetry = newValue } }
        }
        var watchConnectivityBridge: WatchConnectivityBridge? {
            get { values.withLock { $0.watchConnectivityBridge } }
            set { values.withLock { $0.watchConnectivityBridge = newValue } }
        }
        var cloudKitSettingsSync: CloudKitSettingsSync? {
            get { values.withLock { $0.cloudKitSettingsSync } }
            set { values.withLock { $0.cloudKitSettingsSync = newValue } }
        }
        var cloudKitSyncManager: CloudKitSyncManager? {
            get { values.withLock { $0.cloudKitSyncManager } }
            set { values.withLock { $0.cloudKitSyncManager = newValue } }
        }
        var encryptionManager: EncryptionManager? {
            get { values.withLock { $0.encryptionManager } }
            set { values.withLock { $0.encryptionManager = newValue } }
        }
        var sessionArchive: SessionArchive? {
            get { values.withLock { $0.sessionArchive } }
            set { values.withLock { $0.sessionArchive = newValue } }
        }
        var uiStateCache: UIStateCache? {
            get { values.withLock { $0.uiStateCache } }
            set { values.withLock { $0.uiStateCache = newValue } }
        }
        var workoutTrackBackup: WorkoutTrackBackup? {
            get { values.withLock { $0.workoutTrackBackup } }
            set { values.withLock { $0.workoutTrackBackup = newValue } }
        }
    }
}

/// Utilities, models, view-level caches and launch plumbing.
struct UtilityServices: Sendable {
    let overrides: AppDependencies.Overrides

    @MainActor
    var alpha1StatsCache: Alpha1StatsCache {
        if let substitute = overrides.alpha1StatsCache { return substitute }
        return Alpha1StatsCache.shared
    }
    var crashLogManager: CrashLogManager {
        if let substitute = overrides.crashLogManager { return substitute }
        return CrashLogManager.shared
    }
    var debugLogger: DebugLogger {
        if let substitute = overrides.debugLogger { return substitute }
        return DebugLogger.shared
    }
    @MainActor
    var emailContactStore: EmailContactStore {
        if let substitute = overrides.emailContactStore { return substitute }
        return EmailContactStore.shared
    }
    var featureFlags: FeatureFlags {
        if let substitute = overrides.featureFlags { return substitute }
        return FeatureFlags.shared
    }
    @MainActor
    var globalKeyboardDismissal: GlobalKeyboardDismissal {
        if let substitute = overrides.globalKeyboardDismissal { return substitute }
        return GlobalKeyboardDismissal.shared
    }
    var keyboardPerfSignpost: KeyboardPerfSignpost {
        if let substitute = overrides.keyboardPerfSignpost { return substitute }
        return KeyboardPerfSignpost.shared
    }
    @MainActor
    var launchCoordinator: LaunchCoordinator {
        if let substitute = overrides.launchCoordinator { return substitute }
        return LaunchCoordinator.shared
    }
    var organizedZonesCache: OrganizedZonesCache {
        if let substitute = overrides.organizedZonesCache { return substitute }
        return OrganizedZonesCache.shared
    }
    @MainActor
    var recorderBox: RecorderBox {
        if let substitute = overrides.recorderBox { return substitute }
        return RecorderBox.shared
    }
    var settingsManager: SettingsManager {
        if let substitute = overrides.settingsManager { return substitute }
        return SettingsManager.shared
    }
    var systemDiagnosticsManager: SystemDiagnosticsManager {
        if let substitute = overrides.systemDiagnosticsManager { return substitute }
        return SystemDiagnosticsManager.shared
    }
}

/// Analysis caches.
struct AnalysisServices: Sendable {
    let overrides: AppDependencies.Overrides

    @MainActor
    var beatConsistencyPriorsCache: BeatConsistencyPriorsCache {
        if let substitute = overrides.beatConsistencyPriorsCache { return substitute }
        return BeatConsistencyPriorsCache.shared
    }
    @MainActor
    var heatAcclimationCache: HeatAcclimationCache {
        if let substitute = overrides.heatAcclimationCache { return substitute }
        return HeatAcclimationCache.shared
    }
    @MainActor
    var trainingMetricsCache: TrainingMetricsCache {
        if let substitute = overrides.trainingMetricsCache { return substitute }
        return TrainingMetricsCache.shared
    }
}

/// The assistant: chat, memory, voice, inbox.
struct AssistantServices: Sendable {
    let overrides: AppDependencies.Overrides

    var analysisSummaryCache: AnalysisSummaryCache {
        if let substitute = overrides.analysisSummaryCache { return substitute }
        return AnalysisSummaryCache.shared
    }
    @MainActor
    var assistantArtifactStore: AssistantArtifactStore {
        if let substitute = overrides.assistantArtifactStore { return substitute }
        return AssistantArtifactStore.shared
    }
    var assistantContextSource: AssistantContextSource {
        if let substitute = overrides.assistantContextSource { return substitute }
        return AssistantContextSource.shared
    }
    @MainActor
    var assistantEmailBridge: AssistantEmailBridge {
        if let substitute = overrides.assistantEmailBridge { return substitute }
        return AssistantEmailBridge.shared
    }
    @MainActor
    var assistantInbox: AssistantInbox {
        if let substitute = overrides.assistantInbox { return substitute }
        return AssistantInbox.shared
    }
    @MainActor
    var assistantViewModel: AssistantViewModel {
        if let substitute = overrides.assistantViewModel { return substitute }
        return AssistantViewModel.shared
    }
    var conversationStore: ConversationStore {
        if let substitute = overrides.conversationStore { return substitute }
        return ConversationStore.shared
    }
    var liveHRVBroker: LiveHRVBroker {
        if let substitute = overrides.liveHRVBroker { return substitute }
        return LiveHRVBroker.shared
    }
    var liveWorkoutBroker: LiveWorkoutBroker {
        if let substitute = overrides.liveWorkoutBroker { return substitute }
        return LiveWorkoutBroker.shared
    }
    var userFactsStore: UserFactsStore {
        if let substitute = overrides.userFactsStore { return substitute }
        return UserFactsStore.shared
    }
    @MainActor
    var voiceConversationController: VoiceConversationController {
        if let substitute = overrides.voiceConversationController { return substitute }
        return VoiceConversationController.shared
    }
}

/// Sensors and recording.
struct CollectionServices: Sendable {
    let overrides: AppDependencies.Overrides

    @MainActor
    var backgroundAudioManager: BackgroundAudioManager {
        if let substitute = overrides.backgroundAudioManager { return substitute }
        return BackgroundAudioManager.shared
    }
    @MainActor
    var concept2Manager: Concept2Manager {
        if let substitute = overrides.concept2Manager { return substitute }
        return Concept2Manager.shared
    }
    @MainActor
    var footPodManager: FootPodManager {
        if let substitute = overrides.footPodManager { return substitute }
        return FootPodManager.shared
    }
    var healthKitManager: HealthKitManager {
        if let substitute = overrides.healthKitManager { return substitute }
        return HealthKitManager.shared
    }
    @MainActor
    var workoutStartLatencyTracker: WorkoutStartLatencyTracker {
        if let substitute = overrides.workoutStartLatencyTracker { return substitute }
        return WorkoutStartLatencyTracker.shared
    }
    @MainActor
    var zwiftPeripheralBroadcaster: ZwiftPeripheralBroadcaster {
        if let substitute = overrides.zwiftPeripheralBroadcaster { return substitute }
        return ZwiftPeripheralBroadcaster.shared
    }
}

/// Location, routes, trails and weather.
struct LocationServices: Sendable {
    let overrides: AppDependencies.Overrides

    var activeRouteSession: ActiveRouteSession {
        if let substitute = overrides.activeRouteSession { return substitute }
        return ActiveRouteSession.shared
    }
    var ambientLocationService: AmbientLocationService {
        if let substitute = overrides.ambientLocationService { return substitute }
        return AmbientLocationService.shared
    }
    @MainActor
    var breadcrumbRecorder: BreadcrumbRecorder {
        if let substitute = overrides.breadcrumbRecorder { return substitute }
        return BreadcrumbRecorder.shared
    }
    var breadcrumbStore: BreadcrumbStore {
        if let substitute = overrides.breadcrumbStore { return substitute }
        return BreadcrumbStore.shared
    }
    @MainActor
    var locationFinder: LocationFinder {
        if let substitute = overrides.locationFinder { return substitute }
        return LocationFinder.shared
    }
    @MainActor
    var roadGeocodingService: RoadGeocodingService {
        if let substitute = overrides.roadGeocodingService { return substitute }
        return RoadGeocodingService.shared
    }
    var roadGraphService: RoadGraphService {
        if let substitute = overrides.roadGraphService { return substitute }
        return OverpassServices.roadGraph
    }
    @MainActor
    var savedRouteStore: SavedRouteStore {
        if let substitute = overrides.savedRouteStore { return substitute }
        return SavedRouteStore.shared
    }
    @MainActor
    var surroundingsPOIService: SurroundingsPOIService {
        if let substitute = overrides.surroundingsPOIService { return substitute }
        return SurroundingsPOIService.shared
    }
    var trailDiscoveryService: TrailDiscoveryService {
        if let substitute = overrides.trailDiscoveryService { return substitute }
        return OverpassServices.trailDiscovery
    }
    @MainActor
    var weatherService: WeatherService {
        if let substitute = overrides.weatherService { return substitute }
        return WeatherService.shared
    }
}

/// The two services that query OpenStreetMap's Overpass API, built around one
/// `OverpassClient` so its request spacing, back-off and reply cache apply to
/// the whole app rather than to each service. Each is built on first use.
private enum OverpassServices {
    static let client = OverpassClient()
    static let roadGraph = RoadGraphService(overpass: client)
    static let trailDiscovery = TrailDiscoveryService(overpass: client)
}

/// AI providers, keys, routing and their telemetry.
struct ProviderServices: Sendable {
    let overrides: AppDependencies.Overrides

    var apiKeyStore: APIKeyStore {
        if let substitute = overrides.apiKeyStore { return substitute }
        return APIKeyStore.shared
    }
    @MainActor
    var appleToolDispatcher: AppleToolDispatcher {
        if let substitute = overrides.appleToolDispatcher { return substitute }
        return AppleToolDispatcher.shared
    }
    @MainActor
    var capabilityClassifier: CapabilityClassifier {
        if let substitute = overrides.capabilityClassifier { return substitute }
        return CapabilityClassifier.shared
    }
    @MainActor
    var llmCacheTelemetry: LLMCacheTelemetry {
        if let substitute = overrides.llmCacheTelemetry { return substitute }
        return LLMCacheTelemetry.shared
    }
    @MainActor
    var llmRequestAudit: LLMRequestAudit {
        if let substitute = overrides.llmRequestAudit { return substitute }
        return LLMRequestAudit.shared
    }
    @MainActor
    var providerConsentTracker: ProviderConsentTracker {
        if let substitute = overrides.providerConsentTracker { return substitute }
        return ProviderConsentTracker.shared
    }
    @MainActor
    var providerRegistry: ProviderRegistry {
        if let substitute = overrides.providerRegistry { return substitute }
        return ProviderRegistry.shared
    }
    @MainActor
    var smartProviderRouter: SmartProviderRouter {
        if let substitute = overrides.smartProviderRouter { return substitute }
        return SmartProviderRouter.shared
    }
    @MainActor
    var webSearchService: WebSearchService {
        if let substitute = overrides.webSearchService { return substitute }
        return WebSearchService.shared
    }
    @MainActor
    var whisperKitSTTBridge: WhisperKitSTTBridge {
        if let substitute = overrides.whisperKitSTTBridge { return substitute }
        return WhisperKitSTTBridge.shared
    }
}

/// App services: sync, store, notifications, diagnostics.
struct AppServices: Sendable {
    let overrides: AppDependencies.Overrides

    var audioSessionCoordinator: AudioSessionCoordinator {
        if let substitute = overrides.audioSessionCoordinator { return substitute }
        return AudioSessionCoordinator.shared
    }
    var languageManager: LanguageManager {
        if let substitute = overrides.languageManager { return substitute }
        return LanguageManager.shared
    }
    @MainActor
    var morningNotificationScheduler: MorningNotificationScheduler {
        if let substitute = overrides.morningNotificationScheduler { return substitute }
        return MorningNotificationScheduler.shared
    }
    @MainActor
    var powerStatePolicy: PowerStatePolicy {
        if let substitute = overrides.powerStatePolicy { return substitute }
        return PowerStatePolicy.shared
    }
    @MainActor
    var preScorePromptTelemetry: PreScorePromptTelemetry {
        if let substitute = overrides.preScorePromptTelemetry { return substitute }
        return PreScorePromptTelemetry.shared
    }
    @MainActor
    var recoveryScoreFeedbackStore: RecoveryScoreFeedbackStore {
        if let substitute = overrides.recoveryScoreFeedbackStore { return substitute }
        return RecoveryScoreFeedbackStore.shared
    }
    @MainActor
    var storeKitManager: StoreKitManager {
        if let substitute = overrides.storeKitManager { return substitute }
        return StoreKitManager.shared
    }
    @MainActor
    var validationTelemetry: ValidationTelemetry {
        if let substitute = overrides.validationTelemetry { return substitute }
        return ValidationTelemetry.shared
    }
    @MainActor
    var watchConnectivityBridge: WatchConnectivityBridge {
        if let substitute = overrides.watchConnectivityBridge { return substitute }
        return WatchConnectivityBridge.shared
    }
}

/// Persistence and cloud sync.
struct StorageServices: Sendable {
    let overrides: AppDependencies.Overrides

    @MainActor
    var cloudKitSettingsSync: CloudKitSettingsSync {
        if let substitute = overrides.cloudKitSettingsSync { return substitute }
        return CloudKitSettingsSync.shared
    }
    @MainActor
    var cloudKitSyncManager: CloudKitSyncManager {
        if let substitute = overrides.cloudKitSyncManager { return substitute }
        return CloudKitSyncManager.shared
    }
    var encryptionManager: EncryptionManager {
        if let substitute = overrides.encryptionManager { return substitute }
        return EncryptionManager.shared
    }
    var sessionArchive: SessionArchive {
        if let substitute = overrides.sessionArchive { return substitute }
        return SessionArchive.shared
    }
    @MainActor
    var uiStateCache: UIStateCache {
        if let substitute = overrides.uiStateCache { return substitute }
        return UIStateCache.shared
    }
    var workoutTrackBackup: WorkoutTrackBackup {
        if let substitute = overrides.workoutTrackBackup { return substitute }
        return WorkoutTrackBackup.shared
    }
}

// MARK: - SwiftUI environment

private struct DependenciesKey: EnvironmentKey {
    static let defaultValue = AppDependencies.current
}

extension EnvironmentValues {
    /// The services a view reads. Injected once at the root; previews and
    /// tests can override it with `.environment(\.dependencies, ...)`.
    var dependencies: AppDependencies {
        get { self[DependenciesKey.self] }
        set { self[DependenciesKey.self] = newValue }
    }
}
