/// The services the voice conversation reads, and nothing else.
///
/// The controller is built with one; its audio pipeline reads through
/// `controller.services`. Each accessor resolves on use, as the container's
/// do, and a test substitutes one by building these from a container with
/// that override set.
struct VoiceServices: Sendable {
    private let container: AppDependencies

    init(_ container: AppDependencies) { self.container = container }

    @MainActor
    var assistantInbox: AssistantInbox { container.assistant.assistantInbox }
    @MainActor
    var assistantViewModel: AssistantViewModel { container.assistant.assistantViewModel }
    var audioSessionCoordinator: AudioSessionCoordinator { container.services.audioSessionCoordinator }
    @MainActor
    var backgroundAudioManager: BackgroundAudioManager { container.collection.backgroundAudioManager }
    @MainActor
    var providerConsentTracker: ProviderConsentTracker { container.providers.providerConsentTracker }
    @MainActor
    var providerRegistry: ProviderRegistry { container.providers.providerRegistry }
    var settingsManager: SettingsManager { container.app.settingsManager }
    @MainActor
    var watchConnectivityBridge: WatchConnectivityBridge { container.services.watchConnectivityBridge }
    @MainActor
    var whisperKitSTTBridge: WhisperKitSTTBridge { container.providers.whisperKitSTTBridge }
}
