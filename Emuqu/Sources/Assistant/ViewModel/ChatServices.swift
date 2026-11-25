/// The services the chat view model and its router and tool runner read,
/// and nothing else.
///
/// The view model is handed one at construction; its router and tool runner
/// read through `owner.services`. Each accessor resolves on use, as the
/// container's do, and a test substitutes one by building the view model
/// from a container with that override set.
struct ChatServices: Sendable {
    private let container: AppDependencies

    init(_ container: AppDependencies) { self.container = container }

    /// The services the fact registry this view model builds is handed.
    var facts: FactServices { FactServices(container) }

    /// The services the system prompt this view model sends is composed from.
    var prompt: PromptServices { PromptServices(container) }

    var analysisSummaryCache: AnalysisSummaryCache { container.assistant.analysisSummaryCache }
    @MainActor
    var appleToolDispatcher: AppleToolDispatcher { container.providers.appleToolDispatcher }
    var assistantContextSource: AssistantContextSource { container.assistant.assistantContextSource }
    var conversationStore: ConversationStore { container.assistant.conversationStore }
    var featureFlags: FeatureFlags { container.app.featureFlags }
    var keyboardPerfSignpost: KeyboardPerfSignpost { container.app.keyboardPerfSignpost }
    var liveWorkoutBroker: LiveWorkoutBroker { container.assistant.liveWorkoutBroker }
    @MainActor
    var llmCacheTelemetry: LLMCacheTelemetry { container.providers.llmCacheTelemetry }
    @MainActor
    var llmRequestAudit: LLMRequestAudit { container.providers.llmRequestAudit }
    @MainActor
    var providerConsentTracker: ProviderConsentTracker { container.providers.providerConsentTracker }
    @MainActor
    var providerRegistry: ProviderRegistry { container.providers.providerRegistry }
    var sessionArchive: SessionArchive { container.storage.sessionArchive }
    var settingsManager: SettingsManager { container.app.settingsManager }
    @MainActor
    var smartProviderRouter: SmartProviderRouter { container.providers.smartProviderRouter }
    @MainActor
    var trainingMetricsCache: TrainingMetricsCache { container.analysis.trainingMetricsCache }
    var userFactsStore: UserFactsStore { container.assistant.userFactsStore }
    /// The values the metrics verifier checks a reply's app-state claims against.
    @MainActor
    var verifiedAppState: MetricsVerifier.AppState {
        MetricsVerifier.AppState(settings: settingsManager.settings, trainingMetricsCache: trainingMetricsCache, archive: sessionArchive)
    }
    @MainActor
    var voiceConversationController: VoiceConversationController { container.assistant.voiceConversationController }
}
