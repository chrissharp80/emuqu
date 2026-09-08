import Foundation

/// In-memory audit log of the last N LLM requests so we
/// can answer "what did the AI actually see?" without hoping. Every
/// provider's stream entry point pushes a record here right before
/// `URLSession.bytes(for:)` (or, for Apple Foundation, before the
/// `LanguageModelSession.send` call). The audit captures the system
/// prompt, the messages array, the tools schema, the live_state
/// block (when sliced out for cloud providers), and — once the stream
/// finishes — token counts and the response text.
///
/// **Not persisted.** The audit lives only in memory and rolls a 10-
/// entry FIFO. PHI/PII shows up in prompts (sleep, HRV, locations,
/// user notes), so we deliberately don't write this to disk. Users
/// reading the Troubleshooting page see the most recent N requests
/// from THIS launch only; quitting the app drops the log.
///
/// Storage cost is bounded: ~10 × ~50 KB = ~500 KB resident worst
/// case (large coaching turn with a big tool catalog). Pruned with
/// a hard limit so a tool-storm in a single turn can't blow the cap.
@Observable
@MainActor
final class LLMRequestAudit {
    static let shared = LLMRequestAudit()

    /// Hard FIFO cap. Older entries are dropped automatically as new
    /// requests arrive.
    static let maxEntries = 10

    /// Per-string size cap. Tool catalogs can balloon to 30 KB+ and
    /// we don't want one runaway entry to occupy a multi-megabyte
    /// slice of the audit window.
    private static let maxPayloadCharacters = 60_000

    /// Captures everything we know about one outbound LLM call.
    struct Entry: Identifiable {
        let id: UUID
        let provider: String
        let model: String
        let sentAt: Date
        /// The full system prompt as composed (stable + variable). For
        /// providers that split (Anthropic, the OpenAI-compat streamer
        /// after the May 15 fix), this is the COMBINED text — easier
        /// to read end-to-end than reassembling the parts mentally.
        let systemPrompt: String
        /// JSON dump of the messages array as serialised for the
        /// provider (with `<live_state>` blocks spliced in for cloud
        /// providers, with `cache_control` markers for Anthropic, etc.).
        /// Captured AFTER all per-provider mutations so what you read
        /// here is what the provider's API actually saw.
        let messagesJSON: String
        /// JSON dump of the tools array, when tool-mode was enabled.
        /// Empty string when toolless (Apple non-tool-mode, etc.).
        let toolsJSON: String
        /// Counts the model returned, populated once the stream completes.
        var usage: Usage?
        /// Concatenated text deltas the model emitted, populated as the
        /// stream runs. Capped at `maxPayloadCharacters` (older bytes
        /// dropped) so a runaway response doesn't blow the cap.
        var responseText: String
        /// Filled in when the stream errored out so the page can show
        /// "why did this turn fail" alongside what was sent.
        var errorDescription: String?

        struct Usage: Equatable {
            let inputTokens: Int
            let outputTokens: Int
            let cachedReadTokens: Int
            let cacheCreateTokens: Int
        }
    }

    private(set) var entries: [Entry] = []

    private init() {}

    /// Record a request and return its ID so the streaming code can
    /// later attach usage / response text via `update(...)`.
    @discardableResult
    func record(
        provider: String,
        model: String,
        systemPrompt: String,
        messagesJSON: String,
        toolsJSON: String
    ) -> UUID {
        let entry = Entry(
            id: UUID(),
            provider: provider,
            model: model,
            sentAt: Date(),
            systemPrompt: Self.cap(systemPrompt),
            messagesJSON: Self.cap(messagesJSON),
            toolsJSON: Self.cap(toolsJSON),
            usage: nil,
            responseText: ""
        )
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        return entry.id
    }

    /// Append a streamed text delta to the in-flight entry. Cheap;
    /// fired on every text chunk so we end up with the full response.
    func append(textDelta: String, to id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        var e = entries[idx]
        e.responseText.append(textDelta)
        if e.responseText.count > Self.maxPayloadCharacters {
            e.responseText = String(e.responseText.suffix(Self.maxPayloadCharacters))
        }
        entries[idx] = e
    }

    /// Stamp the final usage block (token counts) on the entry.
    /// Called from each provider when it sees the SSE `usage` event
    /// (Anthropic / OpenAI / Gemini all report this).
    func setUsage(_ usage: Entry.Usage, for id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        var e = entries[idx]
        e.usage = usage
        entries[idx] = e
    }

    /// Mark a turn as errored. Page will surface the message alongside
    /// what was sent so the user can self-triage (auth failure vs.
    /// network blip vs. provider 4xx).
    func setError(_ description: String, for id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        var e = entries[idx]
        e.errorDescription = description
        entries[idx] = e
    }

    /// Drop every record. Wired into the Troubleshooting page so the
    /// user can scrub the buffer (e.g. before sharing screenshots).
    func clear() {
        entries.removeAll()
    }

    // MARK: - Helpers

    private static func cap(_ s: String) -> String {
        guard s.count > maxPayloadCharacters else { return s }
        let dropped = s.count - maxPayloadCharacters
        return String(s.prefix(maxPayloadCharacters)) + "\n\n[…truncated \(dropped) chars]"
    }
}
