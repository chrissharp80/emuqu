import Foundation

/// Errors that occur within the HRV analysis pipeline.
/// Used for structured logging and boundary diagnostics — callers see Optional results
/// so the public API is unchanged, but every failure is now categorized and logged.
enum PipelineError: Error, LocalizedError {
    case noRRSeries(sessionId: UUID)
    case timeDomainFailed(sessionId: UUID, windowStart: Int, windowEnd: Int)
    case nonlinearFailed(sessionId: UUID, windowStart: Int, windowEnd: Int)
    case windowSelectionFailed(sessionId: UUID)
    case noRecoveryWindow(sessionId: UUID)
    case insufficientRange(sessionId: UUID, start: Int, end: Int)
    case healthKitFetchFailed(sessionId: UUID, operation: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case let .noRRSeries(id):
            "No RR series for session \(id.uuidString.prefix(8))"
        case let .timeDomainFailed(id, start, end):
            "Time domain analysis failed for session \(id.uuidString.prefix(8)) window [\(start)-\(end)]"
        case let .nonlinearFailed(id, start, end):
            "Nonlinear analysis failed for session \(id.uuidString.prefix(8)) window [\(start)-\(end)]"
        case let .windowSelectionFailed(id):
            "Window selection returned no result for session \(id.uuidString.prefix(8))"
        case let .noRecoveryWindow(id):
            "No recovery window found for session \(id.uuidString.prefix(8))"
        case let .insufficientRange(id, start, end):
            "Invalid window range [\(start)-\(end)] for session \(id.uuidString.prefix(8))"
        case let .healthKitFetchFailed(id, op, _):
            "Apple Health \(op) failed for session \(id.uuidString.prefix(8))"
        }
    }
}

/// `try?` that leaves a trace.
///
/// The refactor spec's rule is "no swallowed errors", and the flat `try?` count
/// was budgeted precisely because it is the one place this codebase routinely
/// broke it. The write/encode/delete subset is the dangerous half: a swallowed
/// read degrades a feature and the user sees it immediately, while a swallowed
/// *write* is silent data loss that surfaces days later as a hole in a 60-day
/// baseline — with nothing in the log to say when it happened.
///
/// This is deliberately **not** a behaviour change. `attempt` returns `nil` on
/// throw exactly as `try?` does, so every call site keeps its existing control
/// flow, its existing `guard … else { return }`, and its existing recovery
/// path. The only difference is that the failure is now recorded. That
/// restraint is the point: converting these sites to propagate errors would be
/// a behaviour change wearing a refactor's clothes, and the spec forbids doing
/// both at once.
///
/// Logs at `.warning` so failures land in the user-facing "Recent Problems"
/// catalog in Settings → Troubleshooting. A write that fails is something the
/// user is entitled to know about, because it is their data that did not land.
///
/// ```swift
/// // before — failure is invisible
/// try? data.write(to: url, options: .atomic)
///
/// // after — identical behaviour, failure is greppable
/// attempt("breadcrumbs.write") { try data.write(to: url, options: .atomic) }
/// ```
///
/// - Parameters:
///   - operation: Stable, greppable identifier for the side effect, in
///     `subsystem.verb` form. Stability matters more than prose — this string
///     is the key you search the log for.
///   - body: The throwing work.
/// - Returns: `body`'s result, or `nil` if it threw.
@inline(__always)
@discardableResult
func attempt<T>(
    _ operation: String,
    file: String = #file,
    line: Int = #line,
    _ body: () throws -> T
) -> T? {
    do {
        return try body()
    } catch {
        debugLog("[\(operation)] failed: \(error.localizedDescription)", level: .warning, file: file, line: line)
        return nil
    }
}

/// Pause without letting a cancellation propagate, and say so in the log.
///
/// The idiom this replaces — `try? await Task.sleep(...)` — has identical
/// behaviour (a `CancellationError` is discarded either way) but leaves no
/// trace. Debugging a "why did that retry loop stop pausing" report from a
/// user log is impossible when the interruption is silent, so the swallow is
/// funnelled through one place that records it.
///
/// `context` is a short phrase naming what the caller was waiting for, e.g.
/// "strap reconnect backoff".
///
/// The entry is attributed to the caller, as `attempt` does. Attributed here,
/// every cancelled debounce in the app was filed under this file's name —
/// `[Errors]` — so an exported log showed routine cancellations as a column of
/// errors from nowhere in particular.
func sleepQuietly(_ nanoseconds: UInt64, context: String, file: String = #file, line: Int = #line) async {
    do {
        try await Task.sleep(nanoseconds: nanoseconds)
    } catch {
        debugLog("[Sleep] interrupted during \(context): \(error)", file: file, line: line)
    }
}
