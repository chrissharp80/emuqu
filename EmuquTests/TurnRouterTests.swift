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

    /// Mirrors ProviderRegistry.allProviders enumeration order — the
    /// "first consented cloud" branches are order-sensitive.
    private let registryOrder: [ProviderID] = [
        .apple, .anthropic, .openai, .gemini, .grok, .deepseek
    ]

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

    /// Apple on-device: consent-exempt, and `providerSupportsTools` is
    /// false (AppleFoundationProvider discards the tools array).
    private func appleState(available: Bool = true) -> TurnRouter.ProviderState {
        TurnRouter.ProviderState(
            isAvailable: available,
            isConsented: true,
            supportsTools: false,
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
            supportsTools: true,
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
            providerOrder: registryOrder,
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
            messageRequiresTools: false
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

    // MARK: - Action intent overrides Apple-routed turn

    func testActionIntent_AppleRouted_OverridesToConsentedCloud() {
        // Bug report: "Coach incorrectly denied having
        // email capability." AppleFoundationProvider discards the
        // tools array, so an action-verb turn that resolved to Apple
        // must fall over to a tool-capable cloud — restricted to
        // CONSENTED clouds.
        let stage = TurnRouter.TierStage(
            proposedTier: .quick,
            tier3CapReached: false,
            mappings: [
                .quick: TurnRouter.MappingSnapshot(providerID: .apple, model: appleModel, collapsed: false)
            ],
            messageRequiresTools: true
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
            decision.logLines.last?.contains("action intent — apple lacks tools; overriding to anthropic:") ?? false,
            "Override must be logged: \(decision.logLines)"
        )
    }

    // MARK: - Action intent + only unconsented clouds

    func testActionIntent_OnlyUnconsentedClouds_NoOverride() {
        // The action-intent override runs when the active
        // provider is Apple, so an unconsented vendor would never have
        // shown its disclosure sheet — a key on file is not consent.
        // With no consented cloud, the turn stays on the Apple mapping
        // even though Apple can't call tools.
        let stage = TurnRouter.TierStage(
            proposedTier: .quick,
            tier3CapReached: false,
            mappings: [
                .quick: TurnRouter.MappingSnapshot(providerID: .apple, model: appleModel, collapsed: false)
            ],
            messageRequiresTools: true
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
            decision.logLines.contains(where: { $0.contains("action intent") }),
            "No override log line may be emitted: \(decision.logLines)"
        )
    }
}
