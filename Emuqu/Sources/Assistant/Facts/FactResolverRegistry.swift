import CryptoKit
import Foundation
import os

// `FactResolverRegistry` and its supporting timeout/result types, split out of
// `FactCatalog.swift`. The catalog defines what a fact *is*; the
// registry is the thing that aggregates namespaces and resolves one.

// MARK: - Aggregating registry

/// Aggregates every registered namespace into one address space. The
/// resolver fans out by the first token in the key. New namespace =
/// one register() call in the `AppFactResolver` init — the catalog
/// and lookup come along for free.
final class FactResolverRegistry: Sendable {
    var namespaces: [FactNamespaceResolver] { namespacesBox.withLock { $0 } }
    private let namespacesBox = OSAllocatedUnfairLock<[FactNamespaceResolver]>(initialState: [])

    func register(_ resolver: FactNamespaceResolver) {
        namespacesBox.withLock { $0.append(resolver) }
    }

    // MARK: - Correctness safety rails

    /// Per-tool-call signature tracker for the rate limiter. Keyed by
    /// `(toolName, argsJSON)` so identical retries are detected but
    /// legitimate different-arg retries are not. The registry itself is
    /// cached across turns, so the tracker is cleared by `beginTurn()`
    /// at the start of each user turn.
    private let callCountsThisTurn = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

    /// After the 2nd consecutive missing-result for the same tuple, the
    /// 3rd call short-circuits to `.rateLimited`. Stops the "model keeps
    /// retrying the same failing call" loop pattern.
    private static let rateLimitMissRetries = 2

    /// Conservative per-response byte cap. OpenAI / Anthropic tool output
    /// limits are ~1 MB, but billing scales with size and the model has a
    /// harder time summarising huge payloads than narrow ones. Refuse
    /// ahead of the provider limit so the model gets a clean
    /// `.tooMuchData` signal and can narrow its query.
    private static let outputSizeCapBytes = 80_000

    /// Final gate before handing a resolver result back to the dispatch
    /// loop. Enforces:
    ///   1. Rate limiting — stop loops on repeat missing-result calls.
    ///   2. Output-size cap — refuse oversized composites with a signal
    ///      the model can act on.
    ///
    /// Runs for every tool call (atomic AND composite) so the safety
    /// contract is uniform.
    private func postResolveGates(toolName: String, argsJSON: String, value: FactValue) -> FactValue {
        guard !value.isMissing else {
            return rateLimited(signature: "\(toolName)::\(argsJSON)") ?? value
        }
        // The size cap applies to non-missing values only.
        let payloadSize = value.toolResultJSON.utf8.count
        guard payloadSize > Self.outputSizeCapBytes else { return value }
        return .missing(
            reason: .tooMuchData,
            detail: "Response ~\(payloadSize) bytes exceeds \(Self.outputSizeCapBytes)-byte per-call cap. Ask a narrower query (shorter period, specific date)."
        )
    }

    /// Clears the rate limiter's miss counts. Call once at the start of
    /// each user turn so misses from an earlier turn don't short-circuit
    /// a fresh question.
    func beginTurn() {
        callCountsThisTurn.withLock { $0.removeAll() }
    }

    /// Gates for results produced outside `resolveTool` (the compact read
    /// tools in `CompactToolRouter`): the same rate limiter and size cap.
    /// The time budget only logs here — compact read tools include
    /// HealthKit and network-backed composites whose legitimate waits can
    /// pass 2 s, and discarding a finished answer would be worse than a
    /// slow one.
    func gatedReadResult(toolName: String, argsJSON: String, value: FactValue, elapsed: TimeInterval) -> FactValue {
        if elapsed > Self.resolveWarnBudgetSec {
            debugLog("[FactRegistry] read tool \(toolName) slow: \(String(format: "%.2f", elapsed))s (warn >\(Self.resolveWarnBudgetSec)s)", level: .warning)
        }
        return postResolveGates(toolName: toolName, argsJSON: argsJSON, value: value)
    }

    /// Track missing-result occurrences for one tool+args signature and
    /// short-circuit the third with a rate-limited envelope.
    private func rateLimited(signature sig: String) -> FactValue? {
        let count = callCountsThisTurn.withLock { counts in
            let next = (counts[sig] ?? 0) + 1
            counts[sig] = next
            return next
        }
        guard count > Self.rateLimitMissRetries else { return nil }
        return .missing(
            reason: .rateLimited,
            detail: "Same tool+args returned missing \(Self.rateLimitMissRetries) times this turn. Stop retrying; tell the user what's missing."
        )
    }

    /// O(1) on the namespace (first token), O(n) within a namespace's
    /// entries — fast enough at typical scale.
    ///
    /// Primary path: every namespace registered under the key's head
    /// token, in registration order. Multiple namespaces legally share
    /// a head — six register as "app" (capabilities / now / devices /
    /// settings / subscription / healthkit) and "workout" hosts both
    /// the historical and the live-coaching resolvers — so stopping at
    /// the FIRST head match would strand every entry in the 2nd+
    /// namespaces behind a "no such key".
    ///
    /// Fallback path: composites often live in a shared `composites`
    /// namespace but their keys read naturally as other namespaces'
    /// (e.g. `user.profile.snapshot` is a composite but the head token
    /// is "user"). We scan the remaining namespaces for an entry that
    /// matches the full key; first hit wins. O(N) across namespaces
    /// but N is small (<15) and composites are cheap to check.
    func resolve(_ rawKey: String) -> FactValue {
        if let prefetched = prefetchedChildren.withLock({ $0[rawKey] }) { return prefetched }
        guard let key = FactKey.parse(rawKey) else {
            return .missing(reason: .invalidParameter, detail: "malformed key")
        }
        guard let head = key.tokens.first else {
            return .missing(reason: .invalidParameter, detail: "empty key")
        }
        for ns in namespaces where ns.namespace == head.name {
            if let value = ns.resolve(key, registry: self) { return value }
        }
        for ns in namespaces where ns.namespace != head.name {
            if let value = ns.resolve(key, registry: self) { return value }
        }
        return .missing(reason: .notRecorded, detail: "no such key '\(rawKey)'")
    }

    /// Async twin of `resolve(_:)`, used by the tool-dispatch path.
    /// Structural copy — same namespace fan-out, same fallback scan,
    /// same missing envelopes — so the sync and async paths can never
    /// disagree on dispatch. `@MainActor` because the sync resolver
    /// closures it walks assume main-actor isolation (see the
    /// concurrency contract in AppFactResolver.swift); `.awaitable`
    /// bodies suspend the actor instead of blocking it.
    @MainActor
    func resolveAsync(_ rawKey: String) async -> FactValue {
        guard let key = FactKey.parse(rawKey) else {
            return .missing(reason: .invalidParameter, detail: "malformed key")
        }
        guard let head = key.tokens.first else {
            return .missing(reason: .invalidParameter, detail: "empty key")
        }

        // Primary path — same head-token scan (and same shared-head
        // rationale) as `resolve(_:)`: try EVERY namespace registered
        // under the head, in registration order.
        for ns in namespaces where ns.namespace == head.name {
            if let value = await ns.resolveAsync(key, registry: self) { return value }
        }

        // Fallback path — same scan (and same caveats) as `resolve(_:)`.
        for ns in namespaces where ns.namespace != head.name {
            if let value = await ns.resolveAsync(key, registry: self) { return value }
        }

        return .missing(reason: .notRecorded, detail: "no such key '\(rawKey)'")
    }

    // MARK: - Composite children

    /// Child values a composite's synchronous body reads through `resolve(_:)`.
    /// Filled by `withPrefetchedChildren(_:run:)` just before the body runs and
    /// restored right after, so async children (HealthKit-backed sleep, vitals,
    /// profile reads) reach the composite instead of `syncPathUnavailable`.
    private let prefetchedChildren = OSAllocatedUnfairLock<[String: FactValue]>(initialState: [:])

    /// Awaits each child key, then runs `body` with those values visible to
    /// `resolve(_:)`. Nothing suspends between filling and restoring the map,
    /// so no other resolve can observe it.
    @MainActor
    func withPrefetchedChildren(_ keys: [String], run body: () -> FactValue?) async -> FactValue? {
        var values: [String: FactValue] = [:]
        for key in keys where values[key] == nil {
            values[key] = await resolveAsync(key)
        }
        let fetched = values
        let previous = prefetchedChildren.withLock { map in
            let old = map
            map.merge(fetched) { _, new in new }
            return old
        }
        defer { prefetchedChildren.withLock { $0 = previous } }
        return body()
    }

    // MARK: - Tool-use schema

    /// Emit a deterministic `[ToolSpec]` for the provider tool-use API. One
    /// tool per FactEntry. Sorted by tool name so the serialised payload is
    /// byte-identical turn-to-turn — the prompt cache hinges on this.
    ///
    /// Tool name = the catalog key with dots replaced by underscores, and any
    /// `($param)` stripped (the placeholder becomes a named argument on the
    /// tool instead). For example:
    ///   `user.profile.max_hr`               → tool `user_profile_max_hr`, no args.
    ///   `session.by_date($date)`            → tool `session_by_date(date)`.
    ///   `walks.hardest($period)`            → tool `walks_hardest(period)`.
    ///
    /// Availability filter: entries the user has no data for are dropped
    /// before the model ever sees them. Closes the "ask-miss-pivot" round-trip
    /// loop for facts that can be known-absent at schema-build time (empty
    /// archive, feature disabled, sensor never calibrated, etc.).
    /// See docs/FLO_ARCHITECTURE.md §6.
    func toolSchema() -> [ToolSpec] {
        namespaces
            .flatMap(\.entries)
            .filter { $0.currentAvailability.hasData }
            .map(Self.toolSpec(for:))
            .sorted { $0.name < $1.name }
    }

    /// SHA256 of the deterministically-serialised tool schema. Stable
    /// across turns unless the catalog content genuinely changed
    /// (new entry, description edit, availability flip). Used by the
    /// debug-build byte-identity assertion in `PromptEnvelopeAdapter`
    /// and logged with every request for cache-drift diagnostics.
    ///
    /// Note this DOES change when availability flips a validRange month
    /// boundary (because the parameter description inlines "January 2026"
    /// → "February 2026"). That's expected — at most once
    /// per entry per month.
    func catalogHash() -> String {
        let specs = toolSchema()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = attempt("factCatalog.specs.encode", { try encoder.encode(specs) }) else { return "unknown" }
        return FactResolverRegistry.sha256Hex(data)
    }

    /// SHA256 → lowercase hex. Used for catalog versioning + byte-identity
    /// checks. Foundation's CommonCrypto is available everywhere; the
    /// wrapper lives here so we don't drag the import into every caller.
    static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
            // CryptoKit path (iOS 13+, mac 10.15+). Fast, no ObjC shim.
            return _sha256HexCrypto(data)
        #else
            // Foundation fallback — hash a copy through CC_SHA256 if
            // CryptoKit isn't present (unusual at current deployment
            // target but keeps the API total).
            return "hash-unavailable"
        #endif
    }

    /// Default per-resolver budget. Resolvers that routinely exceed
    /// this should either be broken into smaller facts, moved into a
    /// background refresh path that populates cached metadata, or
    /// explicitly opted into a higher budget (not wired today — the
    /// override path from the spec's FactEntry-v2 `timeoutSeconds`
    /// field is a post-MVP addition).
    ///
    /// The timeout is wall-clock-only — we time the call and warn on
    /// overshoot but don't cancel it. The resolve chain
    /// IS async (resolveTool / resolveAsync), but this budget
    /// keeps wall-clock semantics: read entries that overshoot have
    /// their value discarded in favour of an `.internalError`
    /// envelope. Per-wait cancellation budgets live
    /// inside the `.awaitable` resolvers via
    /// `FactResolveTimeout.withTimeout(seconds:)`.
    private static let defaultResolveBudgetSec: Double = 2.0
    /// Anything over this on a single resolution is a
    /// real iOS App Watchdog risk because resolvers run on
    /// @MainActor (the @MainActor-annotated AssistantViewModel
    /// hosts runToolUseLoop). 4 s leaves comfortable margin
    /// against iOS's ~10 s foreground watchdog. Set up so the log
    /// is grep-able from production debug exports.
    private static let watchdogWarnSec: Double = 4.0
    private static let resolveWarnBudgetSec: Double = 0.5

    /// Dispatch for `.action` entries.
    ///
    /// Actions are dispatched directly, without the key-rewrite step the read
    /// entries use: their args arrive as a `[String: String]` dict parsed
    /// straight from the provider's `tool_use` input. Required parameters are
    /// validated here so a malformed call reports the missing argument by name
    /// rather than failing somewhere inside the action body.
    ///
    /// `async` + `@MainActor`. Both production call sites
    /// (AssistantViewModel's tool loop, AppleToolDispatcher) are
    /// async on the main actor; the signature says so.
    /// Sync entries run inline (microseconds); `.awaitable`
    /// entries suspend the actor while their network / HealthKit /
    /// geocoding waits run — rather than parking the main thread
    /// behind a DispatchSemaphore bridge.
    @MainActor
    private func resolveActionTool(
        name: String,
        argsJSON: String,
        entry: FactEntry
    ) async -> FactValue {
        guard case .action(_, _, let params, _, let executeBody) = entry else {
            return postResolveGates(
                toolName: name, argsJSON: argsJSON,
                value: .missing(reason: .invalidParameter, detail: "action '\(name)' could not be dispatched")
            )
        }
        let parsedArgs = Self.parseActionArgs(argsJSON, expecting: params)
        for p in params where p.required && parsedArgs[p.name] == nil {
            let missing: FactValue = .missing(reason: .invalidParameter, detail: "action '\(name)' missing required arg '\(p.name)'")
            return postResolveGates(toolName: name, argsJSON: argsJSON, value: missing)
        }
        let startedAt = Date()
        let value: FactValue
        switch executeBody {
        case .sync(let execute): value = execute(parsedArgs)
        case .awaitable(let execute): value = await execute(parsedArgs)
        }
        logActionDuration(name: name, elapsed: Date().timeIntervalSince(startedAt))
        return postResolveGates(toolName: name, argsJSON: argsJSON, value: value)
    }

    /// App Watchdog warning. iOS kills foreground
    /// apps at ~10s of unresponsive main thread. Resolvers
    /// here run on @MainActor (via runToolUseLoop). A 4s
    /// single-action overrun is an early-warning signal —
    /// log loudly so future regressions surface even when
    /// they don't trip the budget warning. A real-user
    /// termination report attributed a workout-mid kill to
    /// exactly this pattern.
    ///
    /// `.awaitable` actions SUSPEND the actor
    /// rather than blocking the thread, so for them `elapsed`
    /// measures await-duration; same threshold, same log
    /// text. A trip here still means a sync action (or a sync
    /// stretch inside an async one) held main too long.
    private func logActionDuration(name: String, elapsed: TimeInterval) {
        if elapsed > Self.defaultResolveBudgetSec {
            debugLog("[FactRegistry] action \(name) exceeded \(Self.defaultResolveBudgetSec)s budget — took \(String(format: "%.2f", elapsed))s", level: .warning)
        }
        guard elapsed > Self.watchdogWarnSec else { return }
        debugLog(
            "[FactRegistry] ⚠️ WATCHDOG-WARN action \(name) blocked for \(String(format: "%.2f", elapsed))s — over the \(Self.watchdogWarnSec)s ceiling that risks an iOS App Watchdog kill",
            level: .warning
        )
    }

    /// Resolve a tool call emitted by the model back to a `FactValue`.
    /// `argsJSON` is the `input` string from the provider's tool_use block —
    /// an object whose keys are the parameter names we declared in the schema.
    /// Unknown tool / bad JSON / unparseable args all flow through as
    /// `.missing(reason:)` so the LLM sees the failure rather than us throwing.
    func resolveTool(name: String, argsJSON: String) async -> FactValue {
        guard let entry = findEntry(forToolName: name) else {
            return .missing(reason: .invalidParameter, detail: "unknown tool '\(name)'")
        }
        if case .action = entry {
            return await resolveActionTool(name: name, argsJSON: argsJSON, entry: entry)
        }
        let key: String
        switch resolvedKey(for: entry, toolName: name, argsJSON: argsJSON) {
        case .success(let k): key = k
        case .failure(let value): return value
        }
        let startedAt = Date() // wall-clock budget; see `budgetOverrun`
        let value = await resolveAsync(key)
        let elapsed = Date().timeIntervalSince(startedAt)
        // Rate limiter + output-size cap run here so every tool-call path
        // (atomics AND composites) is gated uniformly.
        let gated = budgetOverrun(name: name, elapsed: elapsed) ?? value
        return postResolveGates(toolName: name, argsJSON: argsJSON, value: gated)
    }

    /// Either the fact key to resolve, or the `.missing` envelope explaining
    /// why the tool's arguments couldn't produce one.
    private enum KeyResolution {
        case success(String)
        case failure(FactValue)
    }

    /// Fill the entry's placeholder from the call's arguments.
    private func resolvedKey(for entry: FactEntry, toolName name: String, argsJSON: String) -> KeyResolution {
        switch entry {
        case .fixed(let k, _, _, _, _):
            return .success(k)
        case .parameterized(let pattern, _, _, _, _):
            return substituted(pattern, kind: "tool", toolName: name, argsJSON: argsJSON)
        case .composite(let k, _, _, _, _, _):
            // Literal composite key: no placeholder to fill.
            guard k.contains("(") else { return .success(k) }
            return substituted(k, kind: "composite", toolName: name, argsJSON: argsJSON)
        case .action:
            // Already handled by the caller; unreachable.
            return .failure(.missing(reason: .internalError, detail: "action dispatch fell through"))
        }
    }

    /// Replace `$param` in `pattern` with the call's single string argument.
    private func substituted(_ pattern: String, kind: String, toolName name: String, argsJSON: String) -> KeyResolution {
        guard let paramName = Self.placeholderName(in: pattern) else {
            return .failure(.missing(reason: .internalError, detail: "\(kind) '\(name)' has no parameter placeholder"))
        }
        guard let value = Self.parseSingleStringArg(argsJSON, key: paramName) else {
            return .failure(.missing(reason: .invalidParameter, detail: "\(kind) '\(name)' missing or bad arg '\(paramName)'"))
        }
        return .success(pattern.replacingOccurrences(of: "$\(paramName)", with: value))
    }

    /// Wall-clock timer around the resolver. Warns on >500ms, returns
    /// `.internalError` on >2s (default budget). A cheap resolver that
    /// suddenly takes 500ms+ is a regression — either the archive
    /// got large enough that scans are hurting, or a resolver started
    /// doing I/O it shouldn't. Either way, surfaced in warnings.
    ///
    /// (For `.awaitable` entries `elapsed` is await-duration — main
    /// is free while they suspend — but the budget semantics are
    /// unchanged: overshoot discards the value, same envelope.)
    private func budgetOverrun(name: String, elapsed: TimeInterval) -> FactValue? {
        if elapsed > Self.defaultResolveBudgetSec {
            debugLog("[FactRegistry] resolver \(name) exceeded \(Self.defaultResolveBudgetSec)s budget — took \(String(format: "%.2f", elapsed))s — returning .internalError", level: .warning)
            return .missing(
                reason: .internalError,
                detail: "resolver timed out after \(String(format: "%.2f", elapsed))s (budget \(Self.defaultResolveBudgetSec)s)"
            )
        }
        if elapsed > Self.resolveWarnBudgetSec {
            debugLog("[FactRegistry] resolver \(name) slow: \(String(format: "%.2f", elapsed))s (warn >\(Self.resolveWarnBudgetSec)s)", level: .warning)
        }
        return nil
    }

    private func findEntry(forToolName name: String) -> FactEntry? {
        for ns in namespaces {
            for entry in ns.entries where Self.toolName(for: entry) == name {
                return entry
            }
        }
        return nil
    }

    // MARK: Private helpers (deterministic schema derivation)

    fileprivate static func toolName(for entry: FactEntry) -> String {
        switch entry {
        case .fixed(let key, _, _, _, _):
            return key.replacingOccurrences(of: ".", with: "_")
        case .parameterized(let pattern, _, _, _, _):
            // Strip the `($param)` section entirely; parameter moves to args.
            let stripped = stripPlaceholder(from: pattern)
            return stripped.replacingOccurrences(of: ".", with: "_")
        case .composite(let key, _, _, _, _, _):
            let stripped = key.contains("(") ? stripPlaceholder(from: key) : key
            return stripped.replacingOccurrences(of: ".", with: "_")
        case .action(let key, _, _, _, _):
            return key.replacingOccurrences(of: ".", with: "_")
        }
    }

    private static func toolSpec(for entry: FactEntry) -> ToolSpec {
        let name = toolName(for: entry)
        switch entry {
        case .fixed(_, let description, _, _, _):
            return ToolSpec(name: name, description: description, inputSchema: ToolSpec.InputSchema())
        case .parameterized(let pattern, let example, let description, let availability, _):
            return parameterizedSpec(
                name: name, pattern: pattern, example: example,
                description: description, availability: availability())
        case .composite(let key, let description, _, _, let availability, _):
            return compositeSpec(name: name, key: key, description: description, availability: availability)
        case .action(_, let description, let params, _, _):
            return actionSpec(name: name, description: description, params: params)
        }
    }

    /// Literal composite → no input schema. A parameterised composite uses the
    /// same spec shape as a parameterised atomic, falling back to the
    /// placeholder name for the example since composites don't declare a
    /// `paramExample` like atomics do.
    private static func compositeSpec(
        name: String,
        key: String,
        description: String,
        availability: () -> Availability
    ) -> ToolSpec {
        guard key.contains("(") else {
            return ToolSpec(name: name, description: description, inputSchema: ToolSpec.InputSchema())
        }
        return parameterizedSpec(
            name: name, pattern: key, example: placeholderName(in: key) ?? "value",
            description: description, availability: availability())
    }

    /// Build a multi-property input schema from the action's parameter list.
    /// Every property is `string` type — the model encodes numeric / boolean
    /// values as strings and the resolver coerces. Keeps the parser tiny and
    /// matches what the existing single-string parameterised path does.
    private static func actionSpec(
        name: String,
        description: String,
        params: [ActionParam]
    ) -> ToolSpec {
        var props: [String: ToolSpec.Property] = [:]
        var required: [String] = []
        for p in params {
            props[p.name] = ToolSpec.Property(type: "string", description: p.description)
            if p.required { required.append(p.name) }
        }
        return ToolSpec(
            name: name,
            description: description,
            inputSchema: ToolSpec.InputSchema(
                properties: props,
                required: required.sorted() // deterministic for cache stability
            )
        )
    }

    /// Parse an action's `argsJSON` into a `[String: String]` keyed by the
    /// declared parameter names. Coerces numerics and bools to their
    /// string representation so resolvers can do their own typed parsing
    /// without us guessing types here. Unknown keys are ignored — only
    /// declared parameters survive.
    fileprivate static func parseActionArgs(_ json: String, expecting params: [ActionParam]) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for p in params {
            if let s = obj[p.name] as? String {
                out[p.name] = s
            } else if let n = obj[p.name] as? Int {
                out[p.name] = String(n)
            } else if let d = obj[p.name] as? Double {
                out[p.name] = String(d)
            } else if let b = obj[p.name] as? Bool {
                out[p.name] = b ? "true" : "false"
            }
        }
        return out
    }

    /// Shared spec-builder for both parameterised atomics and
    /// parameterised composites. Emits a single required string parameter
    /// with the availability's validRange inlined into its description.
    private static func parameterizedSpec(
        name: String,
        pattern: String,
        example: String,
        description: String,
        availability: Availability
    ) -> ToolSpec {
        guard let param = placeholderName(in: pattern) else {
            return ToolSpec(name: name, description: description, inputSchema: ToolSpec.InputSchema())
        }
        let prop = ToolSpec.Property(
            type: "string",
            description: paramDescription(example: example, availability: availability)
        )
        return ToolSpec(
            name: name,
            description: description,
            inputSchema: ToolSpec.InputSchema(properties: [param: prop], required: [param])
        )
    }

    /// Inline the availability's validRange into the parameter's
    /// description so the model sees the valid span without having
    /// to try and miss. Month-granularity start only (privacy +
    /// cache-stability) — no rolling end date.
    private static func paramDescription(example: String, availability: Availability) -> String {
        var out = "Example: \(example)"
        guard let range = availability.validRange else { return out }
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy" // e.g. "January 2026"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        out += ". Data available as early as \(formatter.string(from: range.lowerBound)); do not request earlier dates."
        return out
    }

    /// Given "session.by_date($date)" returns "date".
    fileprivate static func placeholderName(in pattern: String) -> String? {
        guard let open = pattern.firstIndex(of: "("),
              let close = pattern.firstIndex(of: ")"),
              open < close
        else { return nil }
        let inner = pattern[pattern.index(after: open) ..< close]
        guard inner.first == "$" else { return nil }
        return String(inner.dropFirst())
    }

    /// Given "session.by_date($date)" returns "session.by_date".
    private static func stripPlaceholder(from pattern: String) -> String {
        guard let open = pattern.firstIndex(of: "("),
              let close = pattern.firstIndex(of: ")"),
              open < close
        else { return pattern }
        return String(pattern[..<open]) + String(pattern[pattern.index(after: close)...])
    }

    /// Extract a single string value from a JSON object like `{"date":"yyyy-mm-dd"}`.
    /// Kept deliberately small — we don't need a general parser; all catalog
    /// params are single-string for now.
    private static func parseSingleStringArg(_ json: String, key: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let s = obj[key] as? String { return s }
        if let n = obj[key] as? Int { return String(n) }
        if let d = obj[key] as? Double { return String(d) }
        return nil
    }
}

#if canImport(CryptoKit)
private func _sha256HexCrypto(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}
#endif

// MARK: - Suspending timeout race

/// Structured replacement for `DispatchSemaphore` bridges that would
/// park the main thread inside fact resolvers (a watchdog-kill
/// signature seen mid-workout in the field).
/// Semantics mirror the `Task.detached { … } + semaphore.wait
/// (timeout:)` pattern EXACTLY, with suspension instead of blocking:
///
///   • `operation` runs in a detached task, off the caller's actor.
///   • First finisher wins: the caller resumes with the operation's
///     value, or with `nil` at the deadline — never traps, never
///     resumes twice (lock-guarded single-shot).
///   • On timeout the operation is NOT cancelled. That is deliberate
///     behaviour preservation, not an oversight: `routes.library
///     .engage` and `location.roads_ahead` document that a timed-out
///     OSM/Overpass fetch keeps running in the background to warm the
///     tile cache for the next call — cancelling the loser would break
///     that contract. The losing deadline task simply finishes its
///     sleep (bounded by `seconds`) and exits.
enum FactResolveTimeout {
    static func withTimeout<T>(
        seconds: Double,
        _ operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        let claimWin = Self.singleShotClaim()
        return await withCheckedContinuation { continuation in
            Task.detached { await resumeWithOperation(operation, claimWin, continuation) }
            Task.detached { await resumeWithTimeout(seconds, claimWin, continuation) }
        }
    }

    private static func resumeWithOperation<T>(
        _ operation: @Sendable () async -> T?,
        _ claimWin: @Sendable () -> Bool,
        _ continuation: CheckedContinuation<T?, Never>
    ) async {
        let value = await operation()
        if claimWin() { continuation.resume(returning: value) }
    }

    private static func resumeWithTimeout(
        _ seconds: Double,
        _ claimWin: @Sendable () -> Bool,
        _ continuation: CheckedContinuation<(some Any)?, Never>
    ) async {
        await sleepQuietly(UInt64(seconds * 1_000_000_000), context: "resumeWithTimeout")
        if claimWin() { continuation.resume(returning: nil) }
    }

    /// Single-shot claim: exactly one of the two racers may resume
    /// the continuation. Returns true only for the first caller.
    private static func singleShotClaim() -> @Sendable () -> Bool {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return {
            resumed.withLock { (done: inout Bool) -> Bool in
                let already = done
                done = true
                return !already
            }
        }
    }
}

// MARK: - Composite result envelope

/// Standard shape for a composite that aggregates multiple children and
/// may have partial failures, so the model parses one consistent
/// envelope across every composite, not N bespoke shapes.
enum CompositeResult {
    /// Build a composite's record keyed by child: `present` lists each
    /// resolved child as `{key, value}` and `missing` lists each absent
    /// one as `{key, reason, detail?}`. When any child is missing the
    /// record also carries `status: "partialData"`, so the model sees both
    /// what resolved and what didn't.
    static func recordFromChildren(
        _ children: [(key: String, value: FactValue)]
    ) -> FactValue {
        var present: [FactValue] = []
        var missing: [FactValue] = []
        for (key, val) in children {
            if case .missing(let reason, let detail) = val {
                missing.append(.record(missingItem(key: key, reason: reason, detail: detail)))
            } else {
                present.append(.record(["key": .string(key), "value": val]))
            }
        }
        var record: [String: FactValue] = ["present": .list(present), "missing": .list(missing)]
        if !missing.isEmpty { record["status"] = .string("partialData") }
        return .record(record)
    }

    /// One entry in the `missing` list: the child key, why it's absent, and
    /// the resolver's detail when it gave one.
    private static func missingItem(
        key: String,
        reason: MissingReason,
        detail: String?
    ) -> [String: FactValue] {
        var item: [String: FactValue] = ["key": .string(key), "reason": .string(reason.rawValue)]
        if let detail { item["detail"] = .string(detail) }
        return item
    }
}
