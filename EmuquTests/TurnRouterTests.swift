//
//  TurnRouterTests.swift
//  EmuquTests
//
//  Parity contract for TurnRouter, the pure routing core
//  behind AssistantViewModel.resolveProviderForThisTurn().
//  One test per documented routing scenario; each cites the
//  production comment it locks in. These are behavior-parity tests: every
//  expected output is shipped behavior, not aspirational
//  behavior. If one of these fails, a shipped bug fix regressed.
//

@testable import Emuqu
import XCTest

@MainActor
final class TurnRouterTests: XCTestCase {

    // MARK: - Fixtures

    private func model(_ provider: ProviderID, _ apiID: String) -> ModelOption {
        ModelOption(
            providerID: provider,
            apiID: apiID,
            displayName: apiID,
            blurb: "",
            contextWindow: 128_000,
            inputPricePerMTok: nil,
            outputPricePerMTok: nil,
            isDefault: true
        )
    }

    private var appleModel: ModelOption { model(.apple, "apple-on-device") }

    private func defaultAPIID(_ id: ProviderID) -> String {
        "\(id.rawValue)-default-model"
    }

    /// Apple on-device: consent-exempt, and `providerCanSearchWeb` is
    /// false (`AppleToolDispatcher` refuses `web_search`).
    private func appleState(available: Bool = true) -> TurnRouter.ProviderState {
        TurnRouter.ProviderState(
            isAvailable: available,
            isConsented: true,
            canSearchWeb: false,
            defaultOrFirstModel: appleModel
        )
    }

    private func cloudState(
        _ id: ProviderID,
        available: Bool = true,
        consented: Bool
    ) -> TurnRouter.ProviderState {
        TurnRouter.ProviderState(
            isAvailable: available,
            isConsented: consented,
            canSearchWeb: true,
            defaultOrFirstModel: model(id, defaultAPIID(id))
        )
    }

    private func makeInputs(
        mode: RoutingMode,
        selected: ProviderID,
        selectedAvailable: Bool = true,
        selectedModel: ModelOption,
        voice: Bool = false,
        providers: [ProviderID: TurnRouter.ProviderState],
        tierStage: TurnRouter.TierStage? = nil
    ) -> TurnRouter.Inputs {
        TurnRouter.Inputs(
            routingMode: mode,
            selectedProviderID: selected,
            selectedProviderIsAvailable: selectedAvailable,
            selectedModel: selectedModel,
            isVoiceTurn: voice,
            providerOrder: ProviderRegistry.providerOrder,
            providers: providers,
            tierStage: tierStage
        )
    }

    // MARK: - User's non-Apple pick rules, period

    func testUserPickedNonAppleCloud_SmartRoutingOn_TheirPickWins() {
        // Routing is never tied to one provider. Smart routing (Auto)
        // is ON, but the user picked a
        // non-Apple cloud in the model picker — the smart router must
        // not engage at all, and no classifier side effects may run.
        let grokModel = model(.grok, "grok-4")
        let inputs = makeInputs(
            mode: .auto,
            selected: .grok,
            selectedModel: grokModel,
            providers: [
                .apple: appleState(),
                .anthropic: cloudState(.anthropic, consented: true),
                .grok: cloudState(.grok, consented: true)
            ]
        )
        XCTAssertFalse(
            TurnRouter.needsTierProposal(inputs: inputs),
            "Non-Apple pick must skip the tier stage entirely (smart router is opt-in)"
        )
        let decision = TurnRouter.route(inputs: inputs)
        XCTAssertEqual(decision.providerID, .grok)
        XCTAssertEqual(
            decision.model, grokModel,
            "Early return keeps the user's SELECTED model, not the provider default"
        )
        XCTAssertNil(decision.tier)
        XCTAssertTrue(decision.logLines.isEmpty)
    }

    // MARK: - Voice + user on Grok → Grok

    func testVoiceTurn_UserOnGrok_RoutesToGrokNotFirstInRegistry() {
        // The user picked Grok in Settings, but every voice
        // turn routed to Anthropic because Anthropic came first in
        // ProviderRegistry's enumeration order. The user heard "Grok
        // here" but got Anthropic. Fix: the user's pick rules; the
        // first-in-registry fallback applies only when the user is
        // on Apple.
        let grokModel = model(.grok, "grok-4")
        let inputs = makeInputs(
            mode: .auto,
            selected: .grok,
            selectedModel: grokModel,
            voice: true,
            providers: [
                .apple: appleState(),
                // The first-in-registry trap: available AND consented.
                .anthropic: cloudState(.anthropic, consented: true),
                .grok: cloudState(.grok, consented: true)
            ]
        )
        let decision = TurnRouter.route(inputs: inputs)
        XCTAssertEqual(
            decision.providerID, .grok,
            "Voice must use the user's selected provider, not whatever enumerates first"
        )
        XCTAssertNil(decision.tier)
    }

    // MARK: - Voice + Apple + unconsented cloud stays Apple

    func testVoiceTurn_OnApple_UnconsentedCloudKey_StaysOnApple() {
        // Entering an API key is NOT consent under the
        // app's own model (ProviderConsentSheet). A voice bypass that
        // ships voice turns (with health + location context) to the
        // first cloud with a key sends them to a vendor whose disclosure
        // the user never saw. No consented cloud → stay on
        // Apple (on-device).
        let inputs = makeInputs(
            mode: .auto,
            selected: .apple,
            selectedModel: appleModel,
            voice: true,
            providers: [
                .apple: appleState(),
                // Keys on file, disclosure never acknowledged:
                .anthropic: cloudState(.anthropic, consented: false),
                .openai: cloudState(.openai, consented: false)
            ]
        )
        let decision = TurnRouter.route(inputs: inputs)
        XCTAssertEqual(decision.providerID, .apple)
        XCTAssertEqual(decision.model, appleModel)
        XCTAssertNil(decision.tier)
        XCTAssertEqual(
            decision.logLines,
            ["[SmartRouter] voice-mode bypass: no consented cloud available — staying on Apple (on-device)"]
        )
    }

    // MARK: - Voice + Apple + consented cloud → that cloud

    func testVoiceTurn_OnApple_ConsentedCloud_RoutesToThatCloud() {
        // Companion to the consent filter: a cloud the user
        // HAS consented to absorbs the voice turn (Apple-on-voice is
        // sub-par per the research rationale). With several
        // consented clouds, registry enumeration order picks the first.
        let inputs = makeInputs(
            mode: .auto,
            selected: .apple,
            selectedModel: appleModel,
            voice: true,
            providers: [
                .apple: appleState(),
                .anthropic: cloudState(.anthropic, consented: true),
                .grok: cloudState(.grok, consented: true)
            ]
        )
        let decision = TurnRouter.route(inputs: inputs)
        XCTAssertEqual(
            decision.providerID, .anthropic,
            "First consented cloud in registry order takes the voice turn"
        )
        XCTAssertEqual(decision.model, model(.anthropic, defaultAPIID(.anthropic)))
        XCTAssertNil(decision.tier)
        XCTAssertEqual(decision.logLines.count, 1)
        XCTAssertTrue(
            decision.logLines[0].contains("(Apple selected → routing to first consented cloud)"),
            "Voice bypass must log the Apple→cloud handoff: \(decision.logLines)"
        )
    }

    // MARK: - Manual mode → pick

    func testManualMode_OnApple_UsersPickPeriod() {
        // Manual mode is the escape hatch (adaptive-routing
        // spec): every turn goes to the picker selection — even on
        // Apple with consented clouds configured. No tier, no logs,
        // no classifier side effects.
        let inputs = makeInputs(
            mode: .manual,
            selected: .apple,
            selectedModel: appleModel,
            providers: [
                .apple: appleState(),
                .anthropic: cloudState(.anthropic, consented: true)
            ]
        )
        XCTAssertFalse(TurnRouter.needsTierProposal(inputs: inputs))
        let decision = TurnRouter.route(inputs: inputs)
        XCTAssertEqual(decision.providerID, .apple)
        XCTAssertEqual(decision.model, appleModel)
        XCTAssertNil(decision.tier)
        XCTAssertTrue(decision.logLines.isEmpty)
    }

    // MARK: - Tier-3 daily cap → downgrade

    func testTier3DailyCapReached_DowngradesDeepToAuto() {
        // Adversarial-spend cap (Shafran 2025): when
        // the daily Tier 3 budget is exhausted, a Deep proposal
        // downgrades to Auto and resolves through the AUTO mapping,
        // not the Deep one.
        let sonnet = model(.anthropic, "claude-sonnet")
        let grokFast = model(.grok, "grok-fast")
        let stage = TurnRouter.TierStage(
            proposedTier: .deep,
            tier3CapReached: true,
            mappings: [
                .deep: TurnRouter.MappingSnapshot(providerID: .anthropic, model: sonnet, collapsed: false),
                .auto: TurnRouter.MappingSnapshot(providerID: .grok, model: grokFast, collapsed: false)
            ],
            messageNeedsWebSearch: false
        )
        let inputs = makeInputs(
            mode: .deep,
            selected: .apple,
            selectedModel: appleModel,
            providers: [
                .apple: appleState(),
                .anthropic: cloudState(.anthropic, consented: true),
                .grok: cloudState(.grok, consented: true)
            ],
            tierStage: stage
        )
        XCTAssertTrue(
            TurnRouter.needsTierProposal(inputs: inputs.with(tierStage: nil)),
            "Apple-selected + Deep mode + typed turn must reach the tier stage"
        )
        let decision = TurnRouter.route(inputs: inputs)
        XCTAssertEqual(decision.tier, .auto, "Deep must downgrade to Auto when the cap is hit")
        XCTAssertEqual(decision.providerID, .grok, "Downgraded turn resolves through the Auto mapping")
        XCTAssertEqual(decision.model, grokFast)
        XCTAssertEqual(
            decision.logLines.first,
            "[SmartRouter] daily Tier 3 cap reached — downgrading to Auto for the rest of the day"
        )
    }

    // MARK: - Web search overrides Apple-routed turn

    func testWebSearch_AppleRouted_OverridesToConsentedCloud() {
        // Apple Intelligence calls every app tool but `web_search`, so a
        // web-search turn that resolved to Apple goes to a consented cloud.
        let stage = TurnRouter.TierStage(
            proposedTier: .quick,
            tier3CapReached: false,
            mappings: [
                .quick: TurnRouter.MappingSnapshot(providerID: .apple, model: appleModel, collapsed: false)
            ],
            messageNeedsWebSearch: true
        )
        let inputs = makeInputs(
            mode: .quick,
            selected: .apple,
            selectedModel: appleModel,
            providers: [
                .apple: appleState(),
                .anthropic: cloudState(.anthropic, consented: true)
            ],
            tierStage: stage
        )
        let decision = TurnRouter.route(inputs: inputs)
        XCTAssertEqual(decision.providerID, .anthropic)
        XCTAssertEqual(decision.model, model(.anthropic, defaultAPIID(.anthropic)))
        XCTAssertEqual(
            decision.tier, .quick,
            "Override keeps the resolved tier so the chat bubble's tier indicator shows the swap"
        )
        XCTAssertTrue(
            decision.logLines.last?.contains("web search: apple can't search the web; overriding to anthropic:") ?? false,
            "Override must be logged: \(decision.logLines)"
        )
    }

    // MARK: - Web search + only unconsented clouds

    func testWebSearch_OnlyUnconsentedClouds_NoOverride() {
        // The web-search override runs when the active
        // provider is Apple, so an unconsented vendor would never have
        // shown its disclosure sheet — a key on file is not consent.
        // With no consented cloud, the turn stays on the Apple mapping
        // even though Apple can't search the web.
        let stage = TurnRouter.TierStage(
            proposedTier: .quick,
            tier3CapReached: false,
            mappings: [
                .quick: TurnRouter.MappingSnapshot(providerID: .apple, model: appleModel, collapsed: false)
            ],
            messageNeedsWebSearch: true
        )
        let inputs = makeInputs(
            mode: .quick,
            selected: .apple,
            selectedModel: appleModel,
            providers: [
                .apple: appleState(),
                .anthropic: cloudState(.anthropic, consented: false),
                .grok: cloudState(.grok, consented: false)
            ],
            tierStage: stage
        )
        let decision = TurnRouter.route(inputs: inputs)
        XCTAssertEqual(
            decision.providerID, .apple,
            "No consented cloud → no override; the Apple mapping stands"
        )
        XCTAssertEqual(decision.model, appleModel)
        XCTAssertEqual(decision.tier, .quick)
        XCTAssertFalse(
            decision.logLines.contains(where: { $0.contains("web search:") }),
            "No override log line may be emitted: \(decision.logLines)"
        )
    }

    // MARK: - Which requests leave Apple

    /// Apple Intelligence carries out email, contacts, directions and route
    /// requests itself; only a web search is one it can't run.
    func testOnlyAWebSearchCountsAsARequestAppleCantServe() {
        for text in ["Email me today's recovery report", "lead me back to the car", "save this route as Sunset Loop", "add contact Sam"] {
            XCTAssertFalse(AssistantTurnRouter.messageNeedsWebSearch(text), "\(text) would leave Apple")
        }
        for text in ["Search the web for marathon plans", "look up the trailhead hours", "what's the latest news on HRV"] {
            XCTAssertTrue(AssistantTurnRouter.messageNeedsWebSearch(text), "\(text) would stay on Apple")
        }
    }
}

// MARK: - Failure fallback

/// When the model a turn went to fails, another model may answer only where
/// the routing promise allows it. Manual, and any cloud model selected,
/// promise "every turn goes to" the pick; Quick promises typed questions stay
/// on this iPhone.
extension TurnRouterTests {
    func testManualModeNeverFallsBack() {
        for selected in ProviderID.allCases {
            XCTAssertEqual(TurnRouter.failureFallback(mode: .manual, selectedProviderID: selected), .none, "\(selected)")
        }
    }

    func testCloudPickNeverFallsBackWhateverTheMode() {
        for mode in RoutingMode.allCases {
            XCTAssertEqual(TurnRouter.failureFallback(mode: mode, selectedProviderID: .anthropic), .none, "\(mode)")
        }
    }

    func testRoutingModesOnAppleKeepTheirFallback() {
        XCTAssertEqual(TurnRouter.failureFallback(mode: .quick, selectedProviderID: .apple), .onDeviceOnly)
        XCTAssertEqual(TurnRouter.failureFallback(mode: .auto, selectedProviderID: .apple), .anyAccepted)
        XCTAssertEqual(TurnRouter.failureFallback(mode: .deep, selectedProviderID: .apple), .anyAccepted)
    }

    func testAllowedFallbacksFollowThePolicy() {
        let chain: [(AIProvider, ModelOption)] = [
            (DeepSeekProvider(services: AIProviderServices(.current)), model(.deepseek, "deepseek-chat")),
            (AppleFoundationProvider(services: AIProviderServices(.current)), AppleFoundationProvider.model)
        ]
        XCTAssertTrue(TurnRouter.allowedFallbacks(chain, under: .none).isEmpty)
        XCTAssertEqual(TurnRouter.allowedFallbacks(chain, under: .onDeviceOnly).map(\.0.id), [.apple])
        XCTAssertEqual(TurnRouter.allowedFallbacks(chain, under: .anyAccepted).map(\.0.id), [.deepseek, .apple])
    }

    /// The error names the model that failed, keeps its reason, and says the
    /// turn was not handed on.
    func testPickedModelFailureExplainsItself() {
        let message = PickedModelFailure(providerID: .anthropic, underlying: .rateLimited).errorDescription ?? ""
        let reason = AIProviderError.rateLimited.errorDescription ?? "?"
        XCTAssertTrue(message.contains(ProviderID.anthropic.displayName), message)
        XCTAssertTrue(message.contains(reason), message)
        XCTAssertGreaterThan(message.count, reason.count + ProviderID.anthropic.displayName.count, message)
    }
}

// MARK: - Fallback to Apple

/// A turn that fails over to Apple Intelligence keeps the tools it would have
/// on an Apple turn of its own, and a failure after Apple ran a mutating tool
/// is not handed on to another model.
@MainActor
final class AppleFallbackToolTests: XCTestCase {
    private func makeViewModel() -> AssistantViewModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleFallbackToolTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // swallow-ok: the folder is temporary and may never have been created.
            }
        }
        return AssistantViewModel(
            services: ChatServices(.current),
            store: ConversationStore(fileURL: directory.appendingPathComponent("conversation.json")),
            factsStore: UserFactsStore(fileURL: directory.appendingPathComponent("user_facts.json"))
        )
    }

    /// The reserved reply's id, after a question and an empty reply.
    private func reserveTurn(in viewModel: AssistantViewModel) -> UUID {
        let reply = ChatTurn(role: .assistant, text: "")
        viewModel.turns = [ChatTurn(role: .user, text: "Email me today's recovery report"), reply]
        return reply.id
    }

    func testAnAppleFallbackGetsTheTurnsToolsAndCanCallThem() async {
        let viewModel = makeViewModel()
        let turnID = reserveTurn(in: viewModel)
        let (registry, tools) = viewModel.factRegistryAndTools()
        let recorder = FallbackRecorder()
        let apple = ScriptedProvider(id: .apple, recorder: recorder, toolCall: ("get_recovery", "{}"), failure: nil)

        let ending = await viewModel.tools.tryFallbacks(
            [(apple, AppleFoundationProvider.model)], outbound: viewModel.turns, tools: tools,
            factRegistry: registry, turnID: turnID, voiceMode: false
        )

        XCTAssertEqual(ending, .answered)
        XCTAssertEqual(recorder.sentTools, tools.count, "Apple fell back without the turn's tools")
        XCTAssertTrue(recorder.sentDataBlock, "Apple fell back without its data block")
        XCTAssertFalse(recorder.toolResult?.contains("has no registry") ?? true, "Apple's tool call had no registry: \(recorder.toolResult ?? "none")")
    }

    func testAFailureAfterAppleRanAMutatingToolEndsTheChain() async {
        let viewModel = makeViewModel()
        let turnID = reserveTurn(in: viewModel)
        let (registry, tools) = viewModel.factRegistryAndTools()
        let recorder = FallbackRecorder()
        let apple = ScriptedProvider(
            id: .apple, recorder: recorder, toolCall: ("assistant_memory_add", "not json"), failure: .network("offline")
        )
        let next = ScriptedProvider(id: .anthropic, recorder: FallbackRecorder(), toolCall: nil, failure: nil)

        let ending = await viewModel.tools.tryFallbacks(
            [(apple, AppleFoundationProvider.model), (next, AppleFoundationProvider.model)], outbound: viewModel.turns,
            tools: tools, factRegistry: registry, turnID: turnID, voiceMode: false
        )

        XCTAssertEqual(ending, .blocked, "a turn that ran a mutating tool was handed on")
        XCTAssertEqual(next.recorder.sends, 0)
    }
}

/// What a scripted provider was sent, and what its tool call returned.
@MainActor
private final class FallbackRecorder {
    var sends = 0
    var sentTools = 0
    var sentDataBlock = false
    var toolResult: String?
}

/// A provider that records its send, optionally calls one tool through
/// `AppleToolDispatcher`, then fails or answers "Done.".
private struct ScriptedProvider: AIProvider {
    let id: ProviderID
    let recorder: FallbackRecorder
    let toolCall: (name: String, args: String)?
    let failure: AIProviderError?
    var availableModels: [ModelOption] { [AppleFoundationProvider.model] }
    var requiresKey: Bool { false }
    var isAvailable: Bool { true }

    func send(
        messages _: [ChatTurn], model _: ModelOption, contextRendered _: String, systemPrompt: String,
        tools: [ToolSpec], toolRounds _: [[ToolExchange]]
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let (recorder, call, failure) = (recorder, toolCall, failure)
        let toolCount = tools.count
        let hasDataBlock = systemPrompt.contains("# Current data")
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                recorder.sends += 1
                recorder.sentTools = toolCount
                recorder.sentDataBlock = hasDataBlock
                if let call { recorder.toolResult = await Self.dispatch(call) }
                if let failure { return continuation.finish(throwing: failure) }
                continuation.yield(.textDelta("Done."))
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }

    @MainActor
    private static func dispatch(_ call: (name: String, args: String)) async -> String {
        do {
            return try await AppDependencies.current.providers.appleToolDispatcher.dispatch(name: call.name, argumentsJSON: call.args)
        } catch {
            return "threw: \(error)"
        }
    }
}
