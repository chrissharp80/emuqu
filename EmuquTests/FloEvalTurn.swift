@testable import Emuqu
import Foundation

/// What one question's turn did: the reply the user would see, every tool
/// call, and which of the tool loop's checks stepped in.
struct FloEvalTranscript: Sendable {
    struct ToolCall: Sendable, Encodable {
        let name: String
        let arguments: String
        let resultBytes: Int
        /// The result itself; written for dev questions only.
        let result: String
    }

    var reply = ""
    var toolCalls: [ToolCall] = []
    /// Tool results the model was given, for telling an app value from an invented one.
    var toolResults: [String] = []
    /// The refusal-without-a-lookup re-ask (`BlindRefusalPolicy`) fired.
    var refusalReasked = false
    /// The ungrounded-number re-ask (`ReplyGroundingCheck`) fired.
    var numbersReasked = false
    /// The numbers stayed after the re-ask and their sentences were cut.
    var sentencesCut = false
    /// Grok's announce-without-call nudge (`GrokQuirkPolicy`) fired.
    var grokNudged = false
    /// The medical-query guard answered on the device; no provider was asked.
    var answeredOnDevice = false
    var requestCount = 0
    var error: String?
}

/// Everything the provider was sent and streamed back during one turn.
@MainActor
final class FloEvalTurnLog {
    private(set) var requests: [[ChatTurn]] = []
    private(set) var latestRounds: [ToolExchange] = []
    private(set) var streamedText: [String] = []

    func begin(messages: [ChatTurn], toolRounds: [[ToolExchange]]) {
        requests.append(messages)
        latestRounds = toolRounds.flatMap { $0 }
        streamedText.append("")
    }

    func append(_ text: String) {
        guard !streamedText.isEmpty else { return }
        streamedText[streamedText.count - 1] += text
    }
}

/// The real provider, with every request and streamed reply written to a
/// log on the way through. It keeps the real provider's id, so the tool
/// loop treats it exactly as that provider (Grok's quirk handling included).
struct FloEvalRecordingProvider: AIProvider {
    let base: any AIProvider
    let log: FloEvalTurnLog

    var id: ProviderID { base.id }
    var availableModels: [ModelOption] { base.availableModels }
    var requiresKey: Bool { base.requiresKey }
    var isAvailable: Bool { base.isAvailable }
    var maxToolSchemaCount: Int? { base.maxToolSchemaCount }

    func send(
        messages: [ChatTurn], model: ModelOption, contextRendered: String, systemPrompt: String,
        tools: [ToolSpec], toolRounds: [[ToolExchange]]
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let upstream = base.send(
            messages: messages, model: model, contextRendered: contextRendered, systemPrompt: systemPrompt, tools: tools, toolRounds: toolRounds
        )
        let log = log
        return AsyncThrowingStream { continuation in
            let relay = Task { @MainActor in
                log.begin(messages: messages, toolRounds: toolRounds)
                await Self.relay(upstream, to: continuation, log: log)
            }
            continuation.onTermination = { _ in relay.cancel() }
        }
    }

    @MainActor
    private static func relay(
        _ upstream: AsyncThrowingStream<AIStreamEvent, Error>, to continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation, log: FloEvalTurnLog
    ) async {
        do {
            for try await event in upstream {
                if case let .textDelta(text) = event { log.append(text) }
                continuation.yield(event)
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}

/// Asks one question the way the chat screen does after the user taps Send:
/// the medical-query guard, then the dispatch body (`AssistantTurnRouter`'s
/// pre-flight metrics, context and tool assembly over the app's fact
/// registry and compact schema, system-prompt composition, and the tool loop
/// under its error policy), on a fresh conversation. Routing is skipped: the
/// provider and model are the ones the eval names.
@MainActor
struct FloEvalTurnDriver {
    let services: ChatServices
    let provider: any AIProvider
    let model: ModelOption
    let directory: URL

    func ask(_ question: String) async -> FloEvalTranscript {
        if let reply = medicalGuardReply(question) {
            return FloEvalTranscript(reply: reply, answeredOnDevice: true)
        }
        let viewModel = makeViewModel()
        let log = FloEvalTurnLog()
        let recording = FloEvalRecordingProvider(base: provider, log: log)
        viewModel.turns = [ChatTurn(role: .user, text: question)]
        let router = AssistantTurnRouter(owner: viewModel)
        let turnID = router.reserveAssistantPlaceholderTurn(provider: recording, model: model, tier: nil).id
        await runDispatchBody(router, provider: recording, turnID: turnID)
        return transcript(of: viewModel, turnID: turnID, log: log)
    }

    private func runDispatchBody(_ router: AssistantTurnRouter, provider: any AIProvider, turnID: UUID) async {
        await router.refreshPreFlightMetrics()
        let assembled = await router.assembleContextAndTools(provider: provider, model: model, turnID: turnID)
        let prompt = await router.composeSystemPromptForTurn(
            rendered: assembled.rendered, voiceMode: false, toolMode: !assembled.tools.isEmpty
        )
        _ = await router.runStreamWithErrorPolicy(AssistantTurnRouter.StreamAttempt(
            provider: provider, model: model, outbound: assembled.outbound, systemPrompt: prompt,
            tools: assembled.tools, factRegistry: assembled.factRegistry, turnID: turnID, voiceMode: false
        ))
    }

    /// The guard's own reply when it would answer instead of a provider,
    /// under the same rule `AssistantViewModel.send` applies.
    private func medicalGuardReply(_ question: String) -> String? {
        let enabled = services.featureFlags.value(for: .medicalGuardEnabled)
        guard enabled || MedicalQueryGuard.classify(question) == .selfHarm,
              case let .refuse(reply) = MedicalQueryGuard.evaluate(question) else { return nil }
        return reply
    }

    private func makeViewModel() -> AssistantViewModel {
        let folder = directory.appendingPathComponent("chat-\(UUID().uuidString)", isDirectory: true)
        return AssistantViewModel(
            services: services,
            store: ConversationStore(fileURL: folder.appendingPathComponent("conversation.json")),
            factsStore: UserFactsStore(fileURL: folder.appendingPathComponent("user_facts.json"))
        )
    }

    private func transcript(of viewModel: AssistantViewModel, turnID: UUID, log: FloEvalTurnLog) -> FloEvalTranscript {
        var result = FloEvalTranscript()
        result.reply = viewModel.turns.first { $0.id == turnID }?.text ?? ""
        result.error = viewModel.errorMessage
        result.requestCount = log.requests.count
        result.toolCalls = log.latestRounds.map { .init(name: $0.toolName, arguments: $0.inputJSON, resultBytes: $0.resultJSON.utf8.count, result: $0.resultJSON) }
        result.toolResults = log.latestRounds.map(\.resultJSON)
        let nudges = (log.requests.last ?? []).filter { $0.role == .user }.map(\.text)
        result.refusalReasked = nudges.contains { $0.hasPrefix(Self.refusalReaskPrefix) }
        result.numbersReasked = nudges.contains { $0.hasPrefix(Self.numbersReaskPrefix) }
        result.grokNudged = nudges.contains { $0.hasPrefix(Self.grokNudgePrefix) }
        let lastRound = (log.streamedText.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        result.sentencesCut = result.numbersReasked && !result.reply.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(lastRound)
        return result
    }

    /// The opening words of each nudge the tool loop sends as a user turn.
    private static var numbersReaskPrefix: String {
        String(ReplyGroundingCheck.reask(naming: []).text.prefix(48))
    }
    private static let refusalReaskPrefix = "You said you don't have that data without calling any tool"
    private static let grokNudgePrefix = "Your previous reply said you'd call a tool but didn't emit"
}

/// A provider that calls `get_today` once and then answers without
/// numbers, for checking the seed, the tool loop, the grader and the output
/// without a network call (`EMUQU_EVAL_DRY_RUN=1`).
struct FloEvalDryRunProvider: AIProvider {
    var id: ProviderID { .openai }
    var availableModels: [ModelOption] { [AppleFoundationProvider.model] }
    var requiresKey: Bool { false }
    var isAvailable: Bool { true }

    func send(
        messages _: [ChatTurn], model _: ModelOption, contextRendered _: String, systemPrompt _: String,
        tools _: [ToolSpec], toolRounds: [[ToolExchange]]
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let events: [AIStreamEvent] = toolRounds.isEmpty
            ? [.toolUse(id: "dry-run-1", name: "get_today", inputJSON: "{}"), .done]
            : [.textDelta("Dry run: the tools were called and no answer is given."), .done]
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
