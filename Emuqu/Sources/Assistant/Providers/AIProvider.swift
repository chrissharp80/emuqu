import Foundation

// MARK: - Provider identity

enum ProviderID: String, Codable, CaseIterable, Identifiable {
    case apple
    case anthropic
    case openai
    case gemini
    case grok
    case deepseek

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .anthropic: "Claude"
        case .openai: "ChatGPT"
        case .gemini: "Gemini"
        case .grok: "Grok"
        case .deepseek: "DeepSeek"
        }
    }

    /// SF Symbol name suitable for a provider chip
    var symbolName: String {
        switch self {
        case .apple: "iphone"
        case .anthropic: "sparkles"
        case .openai: "circle.dashed"
        case .gemini: "diamond"
        case .grok: "x.circle"
        case .deepseek: "fish"
        }
    }

    /// Human-readable vendor for disclaimer/privacy text
    var vendorName: String {
        switch self {
        case .apple: "Apple"
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .gemini: "Google"
        case .grok: "xAI"
        case .deepseek: "DeepSeek"
        }
    }

    /// Privacy-policy URL surfaced in the disclaimer sheet
    var privacyPolicyURL: URL? {
        switch self {
        case .apple: URL(string: "https://www.apple.com/legal/privacy/")
        case .anthropic: URL(string: "https://www.anthropic.com/legal/privacy")
        case .openai: URL(string: "https://openai.com/policies/privacy-policy")
        case .gemini: URL(string: "https://policies.google.com/privacy")
        case .grok: URL(string: "https://x.ai/legal/privacy-policy")
        case .deepseek: URL(string: "https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html")
        }
    }
}

// MARK: - Model option

/// One selectable model for a given provider.
/// Pricing is per million tokens; nil means free (e.g., Apple on-device).
struct ModelOption: Codable, Hashable, Identifiable, Sendable {
    let providerID: ProviderID
    let apiID: String
    let displayName: String
    let blurb: String // "Fast & cheap", "Best reasoning", etc.
    let contextWindow: Int // tokens
    let inputPricePerMTok: Decimal?
    let outputPricePerMTok: Decimal?
    let isDefault: Bool

    var id: String {
        "\(providerID.rawValue):\(apiID)"
    }

    var isFree: Bool {
        inputPricePerMTok == nil && outputPricePerMTok == nil
    }
}

// MARK: - Chat turn

/// There are multiple AI mouths in the
/// app (chat tab, mid-workout voice triggers, voice-chat overlay,
/// daily Coach Report email). The user needs to know which one is
/// talking — at a glance via UI label, AND audibly when a voice
/// subsystem speaks. Each utterance carries its subsystem so the
/// rendering surface (bubble or TTS) can announce it.
enum AssistantSubsystem: String, Codable, Hashable {
    /// Main conversational chat (Flo tab). The user is actively
    /// talking with the assistant.
    case coach
    /// Mid-workout observational trigger announcements, fired by
    /// WorkoutTriggerEngine and dispatched via WorkoutVoiceCoach.
    /// One-way; the user isn't asking a question, the system is
    /// surfacing an observation.
    case workoutVoiceCoach
    /// Bidirectional voice-chat overlay (Talk button + AirPods).
    /// Same model + history as the chat tab, but the speech path is
    /// the user's only interface.
    case voiceConversation
    /// Daily / Coach Report email content.
    case coachReport

    /// Human-readable subsystem name. Shown on chat bubbles and
    /// announced verbally on first utterance of each session by the
    /// voice subsystems.
    ///
    /// Naming: the main conversational AI is "Flo"; the
    /// mid-workout observational trigger keeps "Coach" so the user
    /// can audibly distinguish them ("Flo here vs Coach here"). The
    /// auto-generated email also goes out as a Flo Report.
    var displayName: String {
        switch self {
        case .coach: "Flo"
        case .workoutVoiceCoach: "Coach"
        case .voiceConversation: "Flo"
        case .coachReport: "Flo Report"
        }
    }

    /// SF Symbol glyph for the subsystem chip.
    var glyph: String {
        switch self {
        case .coach: "sparkles"
        case .workoutVoiceCoach: "figure.run.circle.fill"
        case .voiceConversation: "waveform"
        case .coachReport: "envelope.fill"
        }
    }

    /// Audible self-announcement spoken on the first utterance of each
    /// session by the voice subsystems. Plain English, no honorifics —
    /// the goal is to set the user's expectation of who's about to
    /// talk, not to be cute. Subsequent utterances within the same
    /// session skip the prefix.
    var voiceAnnouncement: String {
        switch self {
        case .coach: "Flo here."
        case .workoutVoiceCoach: "Coach here."
        case .voiceConversation: "Flo here."
        case .coachReport: "Flo Report."
        }
    }
}

struct ChatTurn: Codable, Identifiable, Hashable, Sendable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    let createdAt: Date
    /// Provider that produced this turn (assistant turns only). Lets the UI
    /// show which model said what when the user switches mid-conversation.
    /// `var`, not `let`, so the chat layer can rewrite
    /// these fields after a fallback or escalation answers from a
    /// different provider than the one originally selected. Without
    /// this the bubble's "Apple Intelligence" badge stays even when
    /// Claude actually answered. The displayed provider must match
    /// what produced the visible text.
    var providerID: ProviderID?
    var modelID: String?
    /// Which AI subsystem produced this turn. Defaults to `.coach` for
    /// turns generated by the main chat pipeline; voice-coach lines and
    /// auto-report drafts mark themselves explicitly.
    let subsystem: AssistantSubsystem?
    /// Abstract routing tier used for this turn (1=Quick,
    /// 2=Auto-cloud, 3=Deep). Stored as a raw Int so the spec's tier
    /// identity survives even if the provider/model later change. nil
    /// for legacy turns from before adaptive routing existed and for
    /// Manual-mode turns where tiers don't apply.
    let routedTierRaw: Int?

    /// Whether this turn may ever leave the device.
    ///
    /// `MedicalQueryGuard` refuses a medical question
    /// without contacting a provider, and SECURITY.md promises such questions
    /// never reach the network. If the refused turn were persisted like any
    /// other, the NEXT ordinary message would assemble it into the outbound
    /// history and send it to the hosted provider — the guard would prevent
    /// one request and the transcript would leak it on the following one.
    ///
    /// A flag on the turn rather than a filter at the send site because there
    /// is more than one send site — history assembly, summarisation, and any
    /// future export — and a policy that has to be re-applied at each is a
    /// policy that will be missed at one. The data carries its own rule.
    ///
    /// Defaults to `false` and decodes to `false` when absent, so transcripts
    /// written before this existed still load. Those turns predate the guard's
    /// persistence path or were already sent; marking them retroactively would
    /// be a claim this cannot support.
    var localOnly: Bool = false

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date(),
        providerID: ProviderID? = nil,
        modelID: String? = nil,
        subsystem: AssistantSubsystem? = nil,
        routedTierRaw: Int? = nil,
        localOnly: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.providerID = providerID
        self.modelID = modelID
        self.subsystem = subsystem
        self.routedTierRaw = routedTierRaw
        self.localOnly = localOnly
    }

    /// Decoded by hand so a missing `localOnly` means `false` rather than a
    /// decode failure.
    ///
    /// A default value on a stored property does NOT make Swift's synthesised
    /// `Codable` tolerate a missing key — the synthesised decoder still
    /// requires it. Adding the field with a default therefore looked safe and
    /// would have made every transcript written before it undecodable, taking
    /// the user's entire chat history with it on upgrade. Caught by
    /// `LocalOnlyTurnTests.testTranscriptsWrittenBeforeTheFieldDecodeAsSendable`.
    ///
    /// Absent means sendable, deliberately. Those turns predate the exposure
    /// policy; marking them local-only retroactively would assert something
    /// about their history that is not known.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        providerID = try container.decodeIfPresent(ProviderID.self, forKey: .providerID)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        subsystem = try container.decodeIfPresent(AssistantSubsystem.self, forKey: .subsystem)
        routedTierRaw = try container.decodeIfPresent(Int.self, forKey: .routedTierRaw)
        localOnly = try container.decodeIfPresent(Bool.self, forKey: .localOnly) ?? false
    }
}

// MARK: - Tool use

/// Declarative tool schema presented to the model. One per FactEntry in the
/// Fact Catalog. Serialised deterministically (sorted by name, stable keys)
/// before being sent so the provider's prompt cache hits every turn.
struct ToolSpec: Hashable, Codable, Sendable {
    let name: String              // Tool name, e.g. "session_by_date"
    let description: String       // Human-readable; the model reads this
    let inputSchema: InputSchema

    struct InputSchema: Hashable, Codable {
        let type: String // always "object" for top-level
        let properties: [String: Property]
        let required: [String]

        init(properties: [String: Property] = [:], required: [String] = []) {
            type = "object"
            self.properties = properties
            self.required = required
        }
    }

    struct Property: Hashable, Codable {
        let type: String        // "string", "integer", "number", "boolean"
        let description: String
    }
}

/// A completed tool round-trip: the tool_use the model emitted, plus the
/// resolved result JSON we sent back. Carried across provider calls so the
/// continuation request includes the full exchange history.
struct ToolExchange: Hashable, Sendable {
    let toolUseID: String
    let toolName: String
    let inputJSON: String   // as emitted by the model
    let resultJSON: String  // serialised FactValue
}

// MARK: - Stream events

/// Discrete events a provider emits while streaming a response.
enum AIStreamEvent: Sendable {
    case textDelta(String)
    /// The model requested a tool call. `inputJSON` is the complete args
    /// object as a JSON string. Providers accumulate partial input deltas
    /// internally and emit this event only once per call, fully formed.
    case toolUse(id: String, name: String, inputJSON: String)
    /// Usage accounting. `cachedInputTokens` and `cacheCreationInputTokens`
    /// are provider-aware fields used for cache-hit telemetry (spec §5.4):
    ///   • Anthropic: `cache_read_input_tokens` / `cache_creation_input_tokens`
    ///   • OpenAI: `prompt_tokens_details.cached_tokens` (creation not reported)
    ///   • DeepSeek: `prompt_cache_hit_tokens` / no creation reporting
    ///   • Gemini: cached count via implicit caching
    /// Providers emit 0 for fields they don't report. Dispatch computes
    /// hit_ratio = cachedInputTokens / (inputTokens + cachedInputTokens
    /// + cacheCreationInputTokens), i.e. cached over total prompt
    /// processed, and warns on <0.8 at turn 2+ which is "our cache
    /// strategy broke." (The denominator must not be
    /// `inputTokens` alone — that produces >100% nonsense values.)
    case usage(
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0
    )
    case done
}

// MARK: - API key redaction

/// Remove anything that looks like an API key from an arbitrary string
/// (usually an HTTP response body we're about to log / surface). Providers
/// occasionally echo part of the request back in an error body; if that
/// string ever includes an `Authorization:` header or a raw key prefix,
/// this scrub keeps it out of logs + UI. The redaction is intentionally
/// conservative — broad regex, fail-safe.
func redactAPIKeys(_ text: String) -> String {
    var scrubbed = text
    let patterns = [
        #"sk-ant-[A-Za-z0-9_-]{20,}"#,   // Anthropic
        #"sk-(?:proj-)?[A-Za-z0-9_-]{20,}"#,  // OpenAI (incl. project keys)
        #"AIza[A-Za-z0-9_-]{20,}"#,      // Google / Gemini
        #"xai-[A-Za-z0-9_-]{20,}"#,      // xAI (Grok)
        #"Bearer\s+[A-Za-z0-9._-]{20,}"#,
        #"(?i)authorization:\s*[^\s\"']+"#,
        #"(?i)x-api-key:\s*[^\s\"']+"#,
        #"(?i)x-goog-api-key:\s*[^\s\"']+"#
    ]
    for pattern in patterns {
        scrubbed = scrubbed.replacingOccurrences(
            of: pattern, with: "[redacted]", options: .regularExpression
        )
    }
    return scrubbed
}

// MARK: - Errors

enum AIProviderError: LocalizedError {
    case missingKey(ProviderID)
    case unsupportedOS(required: String)
    case guardrailViolation
    case rateLimited
    case authFailed
    case network(String)
    case invalidResponse(String)
    case modelUnavailable(String)
    case cancelled
    case unknown(String)

    /// True when this error came from Apple Intelligence's safety
    /// filter. Used by `AssistantViewModel.escalateOnAppleRefusal` to
    /// decide whether to retry on a paid provider rather than surface
    /// the refusal. Currently only `.guardrailViolation` qualifies; if
    /// future Apple-specific error cases are added, mark them here.
    var isAppleGuardrail: Bool {
        if case .guardrailViolation = self { return true }
        return false
    }

    /// True when this error is something the user can
    /// reasonably expect another provider to handle. Auth / credit /
    /// rate-limit / model-not-found / network failures all qualify
    /// (the issue is with the provider, not the request). Cancellation
    /// and guardrail violations don't (cancellation is intentional;
    /// guardrails go through their own escalation path). Used by the
    /// generic fallback chain in `AssistantViewModel.send`.
    var isFallbackable: Bool {
        switch self {
        case .missingKey, .authFailed, .rateLimited, .network, .modelUnavailable:
            return true
        case .invalidResponse, .unsupportedOS, .unknown:
            // These could go either way; treat as fallbackable so
            // a single provider misconfiguration doesn't dead-end
            // the chat. If the same error comes back from all
            // fallbacks, the user sees the original.
            return true
        case .guardrailViolation, .cancelled:
            return false
        }
    }

    private static let guardrailMessage = """
        Apple Intelligence declined to answer this. Try asking it another way.
        """

    var errorDescription: String? {
        switch self {
        case let .missingKey(p): "No \(p.vendorName) API key set. Add one in Settings → Flo."
        case let .unsupportedOS(req): "This model requires \(req)."
        case .guardrailViolation: Self.guardrailMessage
        case .rateLimited: "Rate limited. Wait a moment and try again."
        case .authFailed: "Authentication failed. Check your API key in Settings."
        case let .network(msg): "Network error: \(msg)"
        case let .invalidResponse(msg): "Unexpected response: \(msg)"
        case let .modelUnavailable(msg): "Model unavailable: \(msg)"
        case .cancelled: "Request cancelled."
        case let .unknown(msg): msg
        }
    }
}

// MARK: - Provider protocol

/// One backend that can produce an assistant response.
///
/// Implementations: `AppleFoundationProvider`, `AnthropicProvider`,
/// `OpenAIProvider`, `GeminiProvider`. All four are interchangeable from
/// the chat layer's perspective — switch the active provider and the
/// conversation continues seamlessly.
protocol AIProvider {
    var id: ProviderID { get }
    var availableModels: [ModelOption] { get }
    var requiresKey: Bool { get }

    /// True when this provider is callable right now (key present, OS supports it).
    var isAvailable: Bool { get }

    /// Optional cap on how many tool schemas this provider's API will accept
    /// in a single call. nil = no cap. Grok 4.1 Fast (and some other xAI
    /// models) error 400 with "Maximum tools limit reached" past 200; we
    /// trim the Fact Catalog by namespace priority before dispatch when the
    /// cap is exceeded. See AssistantViewModel.factRegistryAndTools.
    var maxToolSchemaCount: Int? { get }

    /// Stream a response. The provider receives:
    ///   - `messages`: the full conversation so far (alternating user/assistant)
    ///   - `model`: which of `availableModels` to use
    ///   - `contextRendered`: pre-rendered `AssistantContext` text (compact for
    ///     Apple, full for paid models — caller chooses)
    ///   - `systemPrompt`: persona/guardrails text (without context appended)
    ///   - `tools`: optional tool catalog. When non-empty, the model may emit
    ///     `.toolUse` events instead of (or in addition to) `.textDelta`.
    ///     Providers that don't support tool use should ignore this and
    ///     stream text as usual.
    ///   - `toolRounds`: prior tool-use rounds in THIS turn chain. Each
    ///     INNER array is one round the model ran (possibly with multiple
    ///     parallel tool calls batched together); each OUTER element is
    ///     one full back-and-forth (assistant emits N tool_uses → we
    ///     resolve → one user message with N tool_results). Providers
    ///     format these into their message history for the continuation.
    ///
    /// The returned stream emits `.textDelta` or `.toolUse` chunks as they
    /// arrive, then optionally a `.usage` event, then `.done` (or throws).
    func send(
        messages: [ChatTurn],
        model: ModelOption,
        contextRendered: String,
        systemPrompt: String,
        tools: [ToolSpec],
        toolRounds: [[ToolExchange]]
    ) -> AsyncThrowingStream<AIStreamEvent, Error>
}

extension AIProvider {
    /// Default: no cap. Concrete providers override when the API rejects
    /// large tool catalogs.
    var maxToolSchemaCount: Int? { nil }

    /// Back-compat call site for the pre-tool-use era. Forwards with empty
    /// tools/rounds so existing callers (summarizer, auto-fact extractor)
    /// keep working without change. The main chat dispatch path uses the
    /// full signature with a populated tool catalog.
    func send(
        messages: [ChatTurn],
        model: ModelOption,
        contextRendered: String,
        systemPrompt: String
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        send(
            messages: messages,
            model: model,
            contextRendered: contextRendered,
            systemPrompt: systemPrompt,
            tools: [],
            toolRounds: []
        )
    }
}

// MARK: - AnyJSON

/// Tiny encodable wrapper so a provider can re-encode an already-decoded JSON
/// object dictionary (from the model's tool-call arguments string) without
/// losing structure. Handles strings, numbers, bools, arrays, and nested
/// dicts — everything `JSONSerialization` can hand back — and emits them via
/// Codable so `JSONEncoder`'s `.sortedKeys` handles nested dicts uniformly.
/// Shared by the Anthropic and Gemini request bodies.
struct AnyJSON: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let s as String: try c.encode(s)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let b as Bool: try c.encode(b)
        case let arr as [Any]: try c.encode(arr.map(AnyJSON.init))
        case let dict as [String: Any]:
            try c.encode(dict.mapValues(AnyJSON.init))
        case is NSNull: try c.encodeNil()
        default: try c.encodeNil()
        }
    }
}
