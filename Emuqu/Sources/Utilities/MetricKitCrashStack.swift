import Foundation

/// Turns a MetricKit `MXCallStackTree` JSON payload into ordered, readable
/// stack frames.
///
/// Kept separate from `SystemDiagnosticsManager` because it is pure — data in,
/// strings out, no MetricKit types — so the shape of a payload can be asserted
/// in tests without a crash, a device, or a 24-hour delivery window. The
/// manager keeps the subscription and the logging; this keeps the parsing.
///
/// The value of these frames: `offsetIntoBinaryTextSegment` is measured from
/// the binary's text segment, so it survives ASLR, and `binaryUUID` names the
/// exact build. Together they symbolicate against an archived dSYM with
/// `atos -o <dSYM> -l 0x100000000 0x1<offset>` — which the raw return
/// addresses from the in-process signal handler cannot do unless the dSYM is
/// for the exact binary the user is running.
enum MetricKitCrashStack {
    /// Flatten the crashing thread's stack, outermost frame first.
    ///
    /// MetricKit nests frames — each carries its callees in `subFrames` —
    /// because several threads' stacks share prefixes. Only the thread marked
    /// `threadAttributed` crashed; when no thread carries the flag (payload
    /// shapes have varied across iOS releases) every thread is flattened
    /// rather than returning nothing, because a long stack is still readable
    /// and an empty one is not.
    static func frames(fromCallStackTree data: Data) -> [String] {
        let parsed = attempt("metrickit.callStackTree.parse") {
            try JSONSerialization.jsonObject(with: data)
        }
        guard let parsed, let root = parsed as? [String: Any] else { return [] }
        return frames(fromCallStackTree: root)
    }

    static func frames(fromCallStackTree root: [String: Any]) -> [String] {
        guard let stacks = root["callStacks"] as? [[String: Any]] else { return [] }
        let attributed = stacks.filter { $0["threadAttributed"] as? Bool == true }
        var out: [String] = []
        for stack in (attributed.isEmpty ? stacks : attributed) {
            for frame in stack["callStackRootFrames"] as? [[String: Any]] ?? [] {
                append(frame, into: &out)
            }
        }
        return out
    }

    /// One frame, rendered as `<binary> +0x<offset> (<uuid>)`.
    ///
    /// A missing field prints `?` rather than dropping the frame: a stack with
    /// a hole in it still shows the calling sequence, and dropping frames
    /// silently renumbers everything below the hole.
    static func describe(_ frame: [String: Any]) -> String {
        let name = frame["binaryName"] as? String ?? "?"
        let uuid = frame["binaryUUID"] as? String ?? "?"
        let offset = frame["offsetIntoBinaryTextSegment"] as? Int
        let offsetText = offset.map { "0x" + String($0, radix: 16) } ?? "?"
        return "\(name) +\(offsetText) (\(uuid))"
    }

    /// Deepest nesting this will follow.
    ///
    /// The tree comes from outside the app, and this walks it by recursing. A
    /// pathological or corrupt payload should cost a truncated stack, not a
    /// stack overflow inside the code whose entire job is explaining crashes.
    /// Real traces are tens of frames deep; this is far past any of them.
    static let maxDepth = 512

    private static func append(_ frame: [String: Any], into out: inout [String], depth: Int = 0) {
        out.append(describe(frame))
        guard depth < maxDepth else { return }
        for sub in frame["subFrames"] as? [[String: Any]] ?? [] {
            append(sub, into: &out, depth: depth + 1)
        }
    }
}
