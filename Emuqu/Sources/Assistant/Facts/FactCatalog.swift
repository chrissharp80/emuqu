import Foundation
import os
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Self-registering catalog primitives
//
// Every fact available to the AI is described by a single declarative
// entry. Adding a new fact means adding ONE line — an entry with its
// key, description, and closure — and the catalog, the resolver, AND
// the prompt-exposed list all update together. You cannot have a
// resolver without also publishing it to the catalog, which is the
// invariant the user asked for: "when new facts are created, they get
// added to this."
//
// ─────────────────────────────────────────────────────────────────
// SCALING MODEL (why an in-memory catalog is the right primitive here,
// and how it migrates to a DB when it outgrows memory):
//
// The CATALOG is a schema-level structure: a list of every key
// pattern the app understands, with descriptions and types. It grows
// ONLY as the app grows — each new metric we add surfaces one entry.
// Expected mature size: 100-300 entries. Fits in memory easily,
// serialises to ~10 KB of text for the system prompt.
//
// The DATA that keys resolve to is NOT in the catalog. It lives in
// the existing archive (sessions on disk) and model objects (settings,
// trends). A key like `session.by_id($id).alpha1.mean` triggers a disk
// read of that one session via `archive.retrieve(id)` — scales fine
// because we never load everything at once.
//
// If the app one day needs to query hundreds of sessions at once
// (e.g. "what was my average α1 across every walk in 2025?"), the
// resolver contract lets us plug a SQLite-backed fact store behind
// `FactNamespaceResolver` without touching the catalog side: one
// namespace switches its `resolve` closure to hit the DB, the rest
// keep reading live models. Migration path is incremental, not a
// ground-up rebuild.
// ─────────────────────────────────────────────────────────────────
//
// Two entry shapes:
//   • .fixed — key is a single string, takes no parameters.
//               e.g. "user.profile.max_hr"
//   • .parameterized — key template with `$param` placeholder, resolver
//               receives the concrete parameter string.
//               e.g. pattern="session.by_date($date)", the resolver
//               gets "YYYY-MM-DD".

/// Per-parameter declaration for `.action(...)` entries. Actions take
/// multiple named arguments (unlike read-only `.parameterized(...)` which
/// is single-string-only), so we declare them explicitly here.
struct ActionParam: Sendable {
    let name: String
    let description: String
    let required: Bool

    init(_ name: String, _ description: String, required: Bool = true) {
        self.name = name
        self.description = description
        self.required = required
    }
}

/// Resolution body for a `.fixed` entry. A sync-only catalog forces
/// the nine network/HealthKit/geo resolvers to bridge
/// async work through `DispatchSemaphore` waits that park the main
/// thread (the iOS App Watchdog kill signature).
/// Entries therefore declare which world they live in:
///   • `.sync` — the ~226 in-memory / archive / settings reads. Their
///     closures are untouched and still run inline on the main actor.
///   • `.awaitable` — the handful that genuinely wait on the outside
///     world (Tavily, HealthKit, Overpass/OSM, CLGeocoder, cold GPS).
///     `@MainActor` so they keep the exact isolation the sync contract
///     documented; their awaits SUSPEND the main actor instead of
///     blocking it.
enum FactResolveBody: Sendable {
    case sync(@Sendable () -> FactValue)
    case awaitable(@MainActor @Sendable () async -> FactValue)
}

/// Execution body for an `.action` entry. Same split + same isolation
/// rationale as `FactResolveBody` — see its doc comment.
enum FactExecuteBody: Sendable {
    case sync(@Sendable (_ args: [String: String]) -> FactValue)
    case awaitable(@MainActor @Sendable (_ args: [String: String]) async -> FactValue)
}

enum FactEntry: Sendable {
    /// Fixed, non-parameterized fact. One key, one value.
    ///
    /// `availability` is a synchronous, metadata-only closure the
    /// schema-builder invokes once per build to decide whether this
    /// entry should be emitted to the model at all. MUST NOT perform
    /// I/O — reads UserDefaults flags, in-memory archive counts, etc.
    /// only. See `Availability` in FactValue.swift and the design doc
    /// (Layer 1 §2.2).
    ///
    /// Construct via the `.fixed(...)` / `.fixedAsync(...)` static
    /// factories below — they wrap the closure into the right
    /// `FactResolveBody` so declaration sites stay plain closures.
    case fixed(
        key: String,
        description: String,
        valueType: String,  // "Int", "Double", "Duration", "Date", etc.
        availability: @Sendable () -> Availability,
        body: FactResolveBody
    )
    /// Parameterized fact. The pattern string contains `$param`; when
    /// an incoming key matches the pattern, the concrete parameter
    /// string is passed to `resolve`.
    /// The pattern matches on the LEADING tokens: a key like
    /// "session.by_date(YYYY-MM-DD).alpha1.mean" with pattern
    /// "session.by_date($date)" matches on the "session.by_date(X)"
    /// prefix, and the resolver receives ("YYYY-MM-DD", tail=".alpha1.mean").
    case parameterized(
        pattern: String,      // e.g. "session.by_date($date)"
        paramExample: String, // a sample argument, e.g. a calendar day as YYYY-MM-DD
        description: String,
        availability: @Sendable () -> Availability,
        resolve: @Sendable (_ param: String, _ tail: FactKey?) -> FactValue
    )
    /// Composite fact that aggregates multiple atomic facts. Its resolver
    /// receives a reference to the `FactResolverRegistry` so it can call
    /// children (other atomic facts); partial failures are reported via
    /// the standard `CompositeResult` envelope + `missingReason:.partialData`.
    ///
    /// `key` can be literal (`training.load.snapshot`) or parameterised
    /// (`sleep.week_summary($period)`). `dependencies` lists child keys for
    /// CI validation / documentation — it is NOT consulted at runtime; the
    /// resolver picks its own children.
    ///
    /// Composites call atomics ONLY. A composite that calls another
    /// composite would defeat the flat-leaf invariant `sourceFacts`
    /// depends on and would make dependency validation non-terminating.
    case composite(
        key: String,
        description: String,
        valueType: String,     // usually "Record" or "List"
        dependencies: [String],
        availability: @Sendable () -> Availability,
        resolve: @Sendable (_ param: String?, _ registry: FactResolverRegistry) -> FactValue
    )

    /// **Mutation tool.** Differs from the three read variants above in
    /// that the closure performs a side effect on app state (rename a
    /// saved route, save a workout to the route library, etc.) instead
    /// of resolving a value.
    ///
    /// `key` is dotted just like fact keys (e.g. `routes.library.rename`)
    /// so the namespace organisation stays consistent; the tool name the
    /// model sees is `key.replacingOccurrences(of: ".", with: "_")` per
    /// the existing convention.
    ///
    /// **Safety contract** (enforced via the system-prompt tool-use
    /// overlay, NOT by the registry — registries can't read intent):
    ///   • Description MUST start with the literal token `[ACTION]` so the
    ///     model can recognise mutation tools without parsing semantics.
    ///   • Description MUST state the precondition that the user
    ///     explicitly asked for this mutation in the current turn. The
    ///     prompt overlay reinforces "do not call action tools based on
    ///     inference, only on explicit user instruction with the new
    ///     value."
    ///   • Result `FactValue` should be a confirmation record the model
    ///     can read back to the user ("renamed 'Daily 1' → 'Morning Loop'")
    ///     so the user has a verbal receipt the change committed.
    ///
    /// Construct via the `.action(...)` / `.actionAsync(...)` static
    /// factories below — they wrap the closure into the right
    /// `FactExecuteBody`.
    case action(
        key: String,
        description: String,
        parameters: [ActionParam],
        availability: @Sendable () -> Availability,
        body: FactExecuteBody
    )

    /// Key or pattern string for display in the catalog dump.
    var display: String {
        switch self {
        case .fixed(let key, _, _, _, _): key
        case .parameterized(let pattern, let example, _, _, _):
            pattern.replacingOccurrences(of: "$date", with: example)
                .replacingOccurrences(of: "$ordinal", with: example)
                .replacingOccurrences(of: "$id", with: example)
                .replacingOccurrences(of: "$period", with: example)
                .replacingOccurrences(of: "$namespace", with: example)
        case .composite(let key, _, _, _, _, _): key
        case .action(let key, _, _, _, _): key
        }
    }

    var description: String {
        switch self {
        case .fixed(_, let d, _, _, _), .parameterized(_, _, let d, _, _): d
        case .composite(_, let d, _, _, _, _): d
        case .action(_, let d, _, _, _): d
        }
    }

    var valueType: String {
        switch self {
        case .fixed(_, _, let t, _, _): t
        case .parameterized: "Record"
        case .composite(_, _, let t, _, _, _): t
        case .action: "Record"  // confirmation envelope
        }
    }

    /// Evaluate availability. The schema builder uses this to decide
    /// whether to emit a tool for this entry.
    var currentAvailability: Availability {
        switch self {
        case .fixed(_, _, _, let a, _): a()
        case .parameterized(_, _, _, let a, _): a()
        case .composite(_, _, _, _, let a, _): a()
        case .action(_, _, _, let a, _): a()
        }
    }

    /// Declared dependencies for composites. Empty for atomics and actions.
    /// Used by the CI validation suite to enforce "every dependency
    /// references a real catalog entry" at build time.
    var dependencies: [String] {
        switch self {
        case .fixed, .parameterized, .action: []
        case .composite(_, _, _, let deps, _, _): deps
        }
    }

    /// True for `.action(...)` entries; false for read-only entries.
    /// Used by the schema builder to tag mutations + by the prompt
    /// overlay to enumerate them so the model knows which tools require
    /// explicit user instruction.
    var isAction: Bool {
        if case .action = self { return true }
        return false
    }

    /// Envelope returned when a SYNCHRONOUS resolve walk lands on an
    /// `.awaitable` entry. Never blocks, never traps — production
    /// callers of the sync walks (composite children) only reference
    /// sync entries, so this is a guard rail, not a route.
    static func syncPathUnavailable(key: String) -> FactValue {
        .missing(
            reason: .internalError,
            detail: "fact '\(key)' resolves asynchronously — route it through the async tool path (resolveTool)"
        )
    }
}

// MARK: - Back-compat factories
//
// Most entries don't need to override availability — they're always
// reachable as long as the resolver can compute something (even if
// that something is `.missing(.notRecorded)`). Providing argument-
// trimmed static factories means existing declarations keep working
// without everyone having to pass `availability: { .alwaysAvailable }`
// explicitly. Entries that CAN meaningfully be gated (date-
// parameterized ones that need a validRange) pass a real closure.
extension FactEntry {
    static func fixed(
        key: String,
        description: String,
        valueType: String,
        resolve: @escaping @Sendable () -> FactValue
    ) -> FactEntry {
        .fixed(
            key: key,
            description: description,
            valueType: valueType,
            availability: { .alwaysAvailable },
            body: .sync(resolve)
        )
    }

    /// Availability-carrying sync factory. Declaration sites that used
    /// to call the enum case directly (passing a plain closure for
    /// `resolve:`) bind here unchanged now that the case stores a
    /// `FactResolveBody`.
    static func fixed(
        key: String,
        description: String,
        valueType: String,
        availability: @escaping @Sendable () -> Availability,
        resolve: @escaping @Sendable () -> FactValue
    ) -> FactEntry {
        .fixed(
            key: key,
            description: description,
            valueType: valueType,
            availability: availability,
            body: .sync(resolve)
        )
    }

    /// Async fixed fact, for the handful of resolvers that
    /// await the outside world (HealthKit, network, geocoding). The
    /// closure is `@MainActor` and SUSPENDS instead of blocking; pair
    /// every external wait inside it with
    /// `FactResolveTimeout.withTimeout(seconds:)` using the same budget
    /// (and the same timeout fallback value) the retired semaphore
    /// bridge used.
    static func fixedAsync(
        key: String,
        description: String,
        valueType: String,
        resolve: @escaping @MainActor @Sendable () async -> FactValue
    ) -> FactEntry {
        .fixed(
            key: key,
            description: description,
            valueType: valueType,
            availability: { .alwaysAvailable },
            body: .awaitable(resolve)
        )
    }

    static func parameterized(
        pattern: String,
        paramExample: String,
        description: String,
        resolve: @escaping @Sendable (_ param: String, _ tail: FactKey?) -> FactValue
    ) -> FactEntry {
        .parameterized(
            pattern: pattern,
            paramExample: paramExample,
            description: description,
            availability: { .alwaysAvailable },
            resolve: resolve
        )
    }

    /// Composite fact factory. Arity-distinct from the enum case (no
    /// `availability:` parameter) so it defaults to `.alwaysAvailable` — a
    /// composite usually inherits presence from its children, so the
    /// default is correct. Composites that need an explicit availability
    /// use the enum case form directly: `.composite(key:..., availability:..., ...)`.
    static func composite(
        key: String,
        description: String,
        valueType: String = "Record",
        dependencies: [String],
        resolve: @escaping @Sendable (_ param: String?, _ registry: FactResolverRegistry) -> FactValue
    ) -> FactEntry {
        .composite(
            key: key,
            description: description,
            valueType: valueType,
            dependencies: dependencies,
            availability: { .alwaysAvailable },
            resolve: resolve
        )
    }

    /// Action factory. Defaults availability to `.alwaysAvailable` since
    /// most mutations are valid whenever the underlying surface exists
    /// (e.g. you can always rename a saved route as long as you have
    /// any). Mutations that need an explicit availability gate use the
    /// enum case form directly.
    static func action(
        key: String,
        description: String,
        parameters: [ActionParam],
        execute: @escaping @Sendable (_ args: [String: String]) -> FactValue
    ) -> FactEntry {
        .action(
            key: key,
            description: description,
            parameters: parameters,
            availability: { .alwaysAvailable },
            body: .sync(execute)
        )
    }

    /// Async action. Same contract as `fixedAsync`: the
    /// `@MainActor` closure suspends on its external waits (wrapped in
    /// `FactResolveTimeout.withTimeout(seconds:)` with the budget the
    /// retired semaphore bridge used) instead of parking the main
    /// thread behind a `DispatchSemaphore`.
    static func actionAsync(
        key: String,
        description: String,
        parameters: [ActionParam],
        execute: @escaping @MainActor @Sendable (_ args: [String: String]) async -> FactValue
    ) -> FactEntry {
        .action(
            key: key,
            description: description,
            parameters: parameters,
            availability: { .alwaysAvailable },
            body: .awaitable(execute)
        )
    }
}

// MARK: - Namespace resolver

/// Every fact-providing module conforms. Adding a new fact family
/// (e.g. interval workouts, nutrition) means implementing one of
/// these, registering it on `AppFactResolver`, and you're done — both
/// catalog and lookup are wired automatically.
protocol FactNamespaceResolver: Sendable {
    /// Leading namespace token, e.g. "session" or "user".
    var namespace: String { get }
    /// Declarative catalog. This IS the list the AI sees AND the list
    /// the resolver walks — single source of truth, enforced by the
    /// fact that the resolver is a closure attached to the entry.
    var entries: [FactEntry] { get }
}

extension FactNamespaceResolver {
    /// Default resolve walks `entries` once and returns the first
    /// matching closure's result. O(n) per lookup — fine at typical
    /// namespace sizes (<100 entries). If a namespace grows past ~500
    /// entries, override with a dict lookup.
    ///
    /// Composite entries are NOT resolved here — they need the registry
    /// reference, which the namespace doesn't have. See
    /// `FactResolverRegistry.resolve(_:)` for the composite-aware path.
    func resolve(_ key: FactKey) -> FactValue? {
        let rendered = key.rendered
        for entry in entries {
            if let value = resolveEntry(entry, key: key, rendered: rendered, registry: nil) {
                return value
            }
        }
        return nil
    }

    /// A fixed entry's value on a synchronous path. An `.awaitable` body can't
    /// run here, so it reports itself as unavailable rather than blocking.
    private func syncValue(of body: FactResolveBody, key: String) -> FactValue? {
        switch body {
        case .sync(let r): return r()
        case .awaitable: return FactEntry.syncPathUnavailable(key: key)
        }
    }

    /// Composite-aware resolve used by the registry. Same pattern-matching
    /// as the atomic path, but composite cases call the closure with the
    /// registry reference so the resolver can fan out to children.
    func resolve(_ key: FactKey, registry: FactResolverRegistry) -> FactValue? {
        let rendered = key.rendered
        for entry in entries {
            if let value = resolveEntry(entry, key: key, rendered: rendered, registry: registry) {
                return value
            }
        }
        return nil
    }

    /// One entry's contribution on a synchronous walk.
    ///
    /// Composites resolve only when a `registry` is supplied — they need it as
    /// their dependency-resolution surface. Actions are skipped at this layer
    /// entirely: they're dispatched only through the explicit tool-call path
    /// (`resolveTool`), never via free-form key resolution — they're verbs with
    /// side effects, not nouns.
    private func resolveEntry(
        _ entry: FactEntry,
        key: FactKey,
        rendered: String,
        registry: FactResolverRegistry?
    ) -> FactValue? {
        switch entry {
        case .fixed(let k, _, _, _, let body):
            guard k == rendered else { return nil }
            return syncValue(of: body, key: k)
        case .parameterized(let pattern, _, _, _, let r):
            guard let (param, tail) = matchPattern(pattern, against: key) else { return nil }
            return r(param, tail)
        case .composite(let k, _, _, _, _, let r):
            guard let registry else { return nil }
            return compositeValue(k, rendered: rendered, key: key, registry: registry, body: r)
        case .action:
            return nil
        }
    }

    /// A composite entry's value. A literal key (no `$param`) exact-matches; a
    /// parameterised one pattern-matches and passes the captured param string.
    private func compositeValue(
        _ k: String,
        rendered: String,
        key: FactKey,
        registry: FactResolverRegistry,
        body: (String?, FactResolverRegistry) -> FactValue?
    ) -> FactValue? {
        guard k.contains("(") else { return k == rendered ? body(nil, registry) : nil }
        guard let (param, _) = matchPattern(k, against: key) else { return nil }
        return body(param, registry)
    }

    /// Async twin of `resolve(_:registry:)`. Identical walk order,
    /// identical matching, identical composite handling — the ONLY
    /// difference is that `.awaitable` bodies are awaited (suspending
    /// the main actor) instead of refused. This is the
    /// path the tool-dispatch loop takes; the sync walks above remain
    /// for synchronous callers (composite children, all of which are
    /// sync entries).
    @MainActor
    func resolveAsync(_ key: FactKey, registry: FactResolverRegistry) async -> FactValue? {
        let rendered = key.rendered
        for entry in entries {
            if let value = await resolveEntryAsync(entry, key: key, rendered: rendered, registry: registry) {
                return value
            }
        }
        return nil
    }

    @MainActor
    private func resolveEntryAsync(
        _ entry: FactEntry,
        key: FactKey,
        rendered: String,
        registry: FactResolverRegistry
    ) async -> FactValue? {
        switch entry {
        case .fixed(let k, _, _, _, let body):
            guard k == rendered else { return nil }
            return await Self.awaitedValue(of: body)
        case .parameterized(let pattern, _, _, _, let r):
            guard let (param, tail) = matchPattern(pattern, against: key) else { return nil }
            return r(param, tail)
        case .composite(let k, _, _, _, _, let r):
            return compositeValue(k, rendered: rendered, key: key, registry: registry, body: r)
        case .action:
            return nil
        }
    }

    @MainActor
    private static func awaitedValue(of body: FactResolveBody) async -> FactValue? {
        switch body {
        case .sync(let r): return r()
        case .awaitable(let r): return await r()
        }
    }

    /// Try to match a parameterized pattern like "session.by_date($date)"
    /// against a full key. Returns the parameter value + any remaining
    /// tail tokens (for nested access after the parameter).
    private func matchPattern(_ pattern: String, against key: FactKey) -> (param: String, tail: FactKey?)? {
        guard let patternKey = FactKey.parse(pattern),
              patternKey.tokens.count <= key.tokens.count
        else { return nil }
        var param: String?
        for i in 0 ..< patternKey.tokens.count {
            guard let captured = Self.matchToken(patternKey.tokens[i], key.tokens[i]) else { return nil }
            if let captured { param = captured }
        }
        guard let param else { return nil }
        let tailTokens = Array(key.tokens.dropFirst(patternKey.tokens.count))
        return (param, tailTokens.isEmpty ? nil : FactKey(tokens: tailTokens))
    }

    /// Outer nil = no match. Inner nil = matched with nothing captured; an
    /// inner value is the argument a `$`-placeholder captured.
    ///
    /// The token name must match exactly. A `$`-placeholder argument captures
    /// whatever the key supplied; otherwise both arguments must be equal (or
    /// both absent).
    private static func matchToken(_ pTok: FactKey.Token, _ kTok: FactKey.Token) -> String?? {
        guard pTok.name == kTok.name else { return nil }
        guard let arg = pTok.argument, arg.hasPrefix("$") else {
            return pTok.argument == kTok.argument ? .some(nil) : nil
        }
        guard let kArg = kTok.argument else { return nil }
        return .some(kArg)
    }
}
