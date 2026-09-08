import Foundation
import os

/// Ties every log line emitted during one flow back to that flow.
///
/// A single overnight recording touches the BLE stack, HealthKit, the analysis
/// pipeline, the archive, CloudKit sync, and sometimes the assistant. Without
/// it all of that lands in one flat stream with nothing joining it, so
/// reconstructing "what happened to *this* session" means reading by
/// timestamp and guessing — and guessing badly whenever two flows overlap,
/// which is the normal case (a sync running while a workout records).
///
/// The refactor spec asks for exactly this: *"Logs must carry correlation
/// (request/job/session IDs) so a single flow can be traced end-to-end."*
///
/// ## Why an ambient value rather than a parameter
///
/// The alternative is threading an ID through every signature between the flow
/// entry point and the log call. That is ~1,400 call sites and a wide public-API
/// change, which the refactor spec forbids in a cleanup ("Do not rename exported
/// symbols, change signatures… as part of cleanup"). An ambient value costs one
/// `begin`/`end` pair per flow and changes no signature at all.
///
/// ## Why not `@TaskLocal`
///
/// `@TaskLocal` is the idiomatic answer and it does not work here. The values
/// this needs to reach are logged from `CBCentralManagerDelegate` and
/// `CBPeripheralDelegate` callbacks, HealthKit observer-query handlers, and
/// `DispatchQueue` blocks — none of which inherit a task-local, because none of
/// them are child tasks of the code that started the flow. A task-local would
/// tag the neat half of a recording and silently drop the half that actually
/// needs tracing.
///
/// So the value is process-wide and lock-protected. `OSAllocatedUnfairLock` is
/// `Sendable` over a `Sendable` state, so this stays a legal global under strict
/// concurrency without an `@unchecked Sendable` or `nonisolated(unsafe)` escape.
///
/// ## Cost
///
/// One uncontended `os_unfair_lock` acquire per log line. That is tens of
/// nanoseconds against a call that already builds a `String`, formats a `Date`,
/// and dispatches twice — it does not register.
enum LogCorrelation {
    /// The active flow's identifier, or `nil` outside any flow.
    ///
    /// `private` because callers should go through ``scope(_:_:)`` or the
    /// ``begin(_:)``/``end(_:)`` pair rather than assigning; a stack is easier
    /// to reason about than a setter when flows nest.
    private static let storage = OSAllocatedUnfairLock<[Entry]>(initialState: [])

    private struct Entry {
        let token: Token
        let label: String
    }

    /// Opaque handle returned by ``begin(_:)`` and required by ``end(_:)``.
    ///
    /// Typed rather than a bare `String` so that ending the wrong scope is a
    /// compile-time-shaped mistake instead of a silently mismatched string, and
    /// so a caller cannot end a scope it did not open.
    struct Token: Equatable, Sendable {
        fileprivate let id: UUID
    }

    /// A short, human-scannable tag for the innermost active flow, or `nil`.
    ///
    /// Format is `<label>-<4 hex>` — long enough to be unique within a log file
    /// and short enough not to dominate the line. `nil` when no flow is active,
    /// which is the common case for app-lifecycle and UI logging and is why the
    /// prefix is omitted entirely rather than printed as `[cid:none]`.
    static var current: String? {
        storage.withLock { $0.last?.label }
    }

    /// Opens a correlation scope. Every subsequent `debugLog` on any thread is
    /// tagged with `name` until the matching ``end(_:)``.
    ///
    /// Scopes nest: the innermost open scope wins, and closing it restores the
    /// one beneath. That matters because a recording can legitimately start a
    /// sync, and the sync's lines should read as the sync's.
    ///
    /// - Parameter name: Flow kind, e.g. `"record"`, `"sync"`, `"analysis"`.
    ///   Kept short; it is a prefix on every line the flow emits.
    /// - Returns: The token that ``end(_:)`` requires.
    @discardableResult
    static func begin(_ name: String) -> Token {
        let token = Token(id: UUID())
        // Four hex digits from the UUID: 65,536 values, which is far more than
        // the number of flows that can overlap in one log file, and short
        // enough to keep the prefix unobtrusive.
        let suffix = String(token.id.uuidString.prefix(4)).lowercased()
        let label = "\(name)-\(suffix)"
        storage.withLock { $0.append(Entry(token: token, label: label)) }
        return token
    }

    /// Closes the scope opened by `token`.
    ///
    /// Removes that specific entry rather than popping the top, so an
    /// unbalanced or out-of-order close — a flow that fails partway and unwinds
    /// through a different path than it entered — cannot strand every scope
    /// above it. Ending an already-ended token is a no-op, which makes this
    /// safe to call from both a success path and a `defer`.
    static func end(_ token: Token) {
        storage.withLock { entries in
            entries.removeAll { $0.token == token }
        }
    }

    /// Runs `body` inside a correlation scope, closing it however `body` exits.
    ///
    /// Prefer this to the `begin`/`end` pair wherever the flow is
    /// scope-shaped — it cannot leak a scope.
    static func scope<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let token = begin(name)
        defer { end(token) }
        return try body()
    }

    /// `async` counterpart to ``scope(_:_:)``.
    static func scope<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        let token = begin(name)
        defer { end(token) }
        return try await body()
    }

    /// Drops every open scope.
    ///
    /// Only for test teardown — a test that opens a scope and fails an
    /// assertion before closing it would otherwise tag every later test's
    /// output with a dead flow.
    static func resetForTesting() {
        storage.withLock { $0.removeAll() }
    }
}
