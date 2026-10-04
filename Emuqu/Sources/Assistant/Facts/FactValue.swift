import Foundation

// MARK: - MissingReason

/// Structured reason for a missing/unresolvable fact. Replaces the earlier
/// freeform `reason: String?` — the model's prompt can now teach absence
/// semantics by example via the schema itself ("if `missingReason` is
/// present, the value is absent; here's what each reason means") instead
/// of a soft prompt rule that leaks under pressure.
///
/// Every resolver that cannot return a real value MUST pick one of these.
/// No exceptions. If you need a new category, add a case here rather than
/// stuffing justification into the `detail` field.
///
/// See docs/VOICE_AND_TOOL_USE.md §Layer-2 for the design rationale.
enum MissingReason: String, Codable, Sendable {
    /// User has no data for this query. Most common — the archive just
    /// doesn't contain what's being asked for.
    case notRecorded

    /// Data exists but the derived metric (trend, baseline, aggregate)
    /// hasn't finished computing yet. Retryable later.
    case notYetComputed

    /// Parameter outside the fact's valid range (see Availability). The
    /// model should not have asked — belt-and-braces vs schema.
    case outOfRange

    /// Sensor signal was too noisy / had too much dropout to trust.
    case sensorDropout

    /// Tool call had malformed arguments (wrong type, unparseable date,
    /// missing required field). Caller error.
    case invalidParameter

    /// Programmer / unexpected condition. Bug. Model should report that
    /// the fact is unavailable and stop, not retry.
    case internalError

    /// Composite response would exceed the provider's tool-output size
    /// cap. Model should narrow the query.
    case tooMuchData

    /// Same `(key, params)` has been asked repeatedly this turn with
    /// missing results. Third call short-circuits to prevent loops.
    case rateLimited

    /// Composite-only: some children resolved, others did not. The
    /// `value` contains a structured `{present: [...], missing: [...]}`
    /// envelope per the composite-partial-results convention.
    case partialData
}

// MARK: - Availability

/// Per-entry availability, evaluated at schema-build time. Drives two
/// things:
///   1. The schema-builder drops entries where `hasData == false` — the
///      model literally never sees a tool for a fact the user has no
///      data for. That closes the "ask, miss, pivot" round-trip loop.
///   2. `validRange` is inlined into the parameterized entry's `doc` so
///      the model knows what dates are in range without having to try
///      and miss.
///
/// The closure MUST be synchronous and metadata-only — no HealthKit
/// queries, no file I/O, no network. It's called during schema build,
/// which happens once per registry construction (per send today;
/// per-launch + on-data-change in a future iteration).
struct Availability: Sendable {
    let hasData: Bool
    /// Inclusive range for date-parameterized facts. Nil for literal
    /// facts or when the fact doesn't constrain dates.
    let validRange: ClosedRange<Date>?
    /// When the underlying data last changed (for freshness signalling).
    /// Nil if unknown.
    let lastUpdated: Date?

    static let alwaysAvailable = Availability(hasData: true, validRange: nil, lastUpdated: nil)
    static let unavailable = Availability(hasData: false, validRange: nil, lastUpdated: nil)

    /// Availability of every workout-backed namespace: unavailable until the
    /// archive holds a single workout, otherwise valid across the span of
    /// archived workout dates. Shared by the `walks.*` and `hrr.*` namespaces.
    static func workouts(in archive: SessionArchive) -> Availability {
        let hasAny = archive.entries.contains { $0.sessionType == .workout }
        guard hasAny else { return .unavailable }
        let dates = archive.entries.filter { $0.sessionType == .workout }.map(\.date)
        guard let earliest = dates.min(), let latest = dates.max() else {
            return .alwaysAvailable
        }
        return Availability(hasData: true, validRange: earliest ... latest, lastUpdated: latest)
    }
}

// MARK: - FactValue

/// Typed union for every value that can come back from the fact
/// registry. Designed to be BOTH human-readable when rendered (so a
/// user debugging the AI's context dump can see exactly what's there)
/// AND machine-friendly (so the LLM parses it reliably).
///
/// Rendering rules:
///   • .integer / .double → compact numeric with up to 2 decimals
///   • .string → quoted, truncated for display if very long
///   • .date → ISO 8601 with the local UTC offset (unambiguous, machine-parseable)
///   • .duration → "63m 07s" (human) + seconds in a record when precise
///   • .boolean → yes / no
///   • .missing → structured `{missingReason, detail?}` in the wire format
///   • .list → bracketed, comma-separated
///   • .record → nested key: value lines (pretty) or flat JSON (compact)
enum FactValue: Sendable {
    case integer(Int)
    case double(Double)
    case string(String)
    case date(Date)
    case durationSec(Int)
    case boolean(Bool)
    /// Structured absence. `reason` is enum-typed so the model can reason
    /// on it in code; `detail` is an optional human-readable hint for
    /// debugging (e.g., "invalid ordinal '-1'"). The detail never
    /// replaces the reason — clients should gate logic on reason only.
    case missing(reason: MissingReason, detail: String? = nil)
    case list([FactValue])
    case record([String: FactValue])

    /// Human-readable single-line representation. Short enough to sit in
    /// a value column in the rendered context; use `.prettyMultiline()`
    /// for nested records.
    /// Drop trailing zeros for cleanliness, cap at 2 decimals.
    ///
    /// The strip pattern must not be `#".?0+$"#`. That `.` is an
    /// unescaped regex wildcard, so on "5.20" the leftmost match starts
    /// at the `2`, eats "20", and returns "5." — the value gone, the
    /// decimal point left behind. It hit every double whose two-decimal
    /// form ends in exactly one zero (x.10 … x.90), which is a large
    /// share of the metrics the assistant quotes back to the user.
    /// Escaped, the pattern means
    /// optional decimal point, then trailing zeros.
    ///
    /// An `if` expression rather than a ternary: `void_function_in_ternary`
    /// is a false positive here, but the `if`
    /// says the same thing in a shape the rule reads correctly.
    private static func trimmed(_ d: Double) -> String {
        if d.truncatingRemainder(dividingBy: 1) == 0 {
            String(format: "%.0f", d)
        } else {
            String(format: "%.2f", d).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        }
    }

    var humanReadable: String {
        switch self {
        case .integer(let n): "\(n)"
        case .double(let d):
            Self.trimmed(d)
        case .string(let s): s
        case .date(let d):
            Self.localISO8601(d)
        case .durationSec(let sec):
            Self.formatDuration(sec)
        case .boolean(let b): b ? "yes" : "no"
        case .missing(let reason, let detail):
            detail.map { "unknown (\(reason.rawValue): \($0))" } ?? "unknown (\(reason.rawValue))"
        case .list(let items):
            "[" + items.map(\.humanReadable).joined(separator: ", ") + "]"
        case .record(let r):
            "{" + r.sorted(by: { $0.key < $1.key })
                .map { "\($0.key): \($0.value.humanReadable)" }
                .joined(separator: ", ") + "}"
        }
    }

    /// Multi-line indented rendering for `.record` values in the
    /// catalog dump. Clearer to read when nested.
    func prettyMultiline(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch self {
        case .record(let r):
            // Only the trailing newline goes: trimming the front too would
            // strip the first line's indent inside a nested block.
            var text = r.sorted(by: { $0.key < $1.key })
                .map { pad + $0.key + ": " + nestedRendering(of: $0.value, indent: indent) }
                .joined()
            while text.last?.isWhitespace == true { text.removeLast() }
            return text
        case .list(let items):
            guard !items.isEmpty else { return pad + "(empty)" }
            return items.map { v in
                "\(pad)- " + (v.isScalar ? v.humanReadable : "\n" + v.prettyMultiline(indent: indent + 1))
            }.joined(separator: "\n")
        default:
            return pad + humanReadable
        }
    }

    /// One record field's value: scalars stay inline, nested records and lists
    /// drop to their own indented block.
    private func nestedRendering(of value: FactValue, indent: Int) -> String {
        switch value {
        case .record, .list:
            return "\n" + value.prettyMultiline(indent: indent + 1) + "\n"
        default:
            return value.humanReadable + "\n"
        }
    }

    /// True when the value is a single scalar (no nested record / list).
    var isScalar: Bool {
        switch self {
        case .record, .list: false
        default: true
        }
    }

    /// True when this FactValue represents absence. Registries and
    /// composites switch on this to decide follow-up behavior.
    var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }

    /// Convenience builder — turns an optional scalar into a
    /// `.missing(reason:)` when nil, so resolvers can write
    /// `return .from(optionalValue)` instead of branching.
    ///
    /// Default reason is `.notRecorded` because that's the most common
    /// case (the user just doesn't have this data point). Callers that
    /// mean something more specific (e.g., "birthday not set" is
    /// structurally unrecorded, but callable-parameter error is
    /// `.invalidParameter`) pass the right reason explicitly.
    static func from(_ value: Int?, reason: MissingReason = .notRecorded, detail: String? = nil) -> FactValue {
        value.map { .integer($0) } ?? .missing(reason: reason, detail: detail)
    }

    static func from(_ value: Double?, reason: MissingReason = .notRecorded, detail: String? = nil) -> FactValue {
        value.map { .double($0) } ?? .missing(reason: reason, detail: detail)
    }

    static func from(_ value: String?, reason: MissingReason = .notRecorded, detail: String? = nil) -> FactValue {
        value.map { .string($0) } ?? .missing(reason: reason, detail: detail)
    }

    static func from(_ value: Date?, reason: MissingReason = .notRecorded, detail: String? = nil) -> FactValue {
        value.map { .date($0) } ?? .missing(reason: reason, detail: detail)
    }

    static func from(_ value: Bool?, reason: MissingReason = .notRecorded, detail: String? = nil) -> FactValue {
        value.map { .boolean($0) } ?? .missing(reason: reason, detail: detail)
    }

    // MARK: JSON serialization (tool_result payload)

    /// Serialise to a JSON string suitable for embedding as the `content`
    /// of an Anthropic `tool_result` (or equivalent on other providers).
    ///
    /// Wire shape is a consistent envelope:
    ///
    ///   {
    ///     "value": <typed scalar/list/record, or null when missing>,
    ///     "missingReason": "notRecorded" | "outOfRange" | ... | null,
    ///     "detail": "free-text hint, optional",
    ///     "asOf": "<ISO8601>",
    ///     "confidence": "high"
    ///   }
    ///
    /// Every response — success or missing — has the same shape. That's
    /// how the model learns absence semantics structurally: any time
    /// `missingReason` is non-null, the value is absent and here's why.
    /// No prompt rule required.
    ///
    /// `asOf` is the resolve time and `confidence` is always "high".
    /// Keys are sorted so the same value always encodes in the same key
    /// order; `asOf` still changes per call, so payloads are not
    /// byte-identical across calls. Dates are ISO 8601 with the device's
    /// local UTC offset, so the calendar day matches the local
    /// `yyyy-MM-dd` dates the tools take as parameters.
    var toolResultJSON: String {
        let raw: [String: Any] = envelope()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = attempt("factValue.encode", { try encoder.encode(AnyFactJSON(raw)) }),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{\"missingReason\":\"internalError\",\"detail\":\"encoding failed\"}"
    }

    /// Public-surface JSON serialization for cross-provider tool-result
    /// envelopes. Renders this `FactValue` to the same schema cloud
    /// providers see when they get a tool result back (`{"value": …,
    /// "missingReason": …}`). Exposed so the
    /// `AppleToolDispatcher` can hand the same JSON payload to
    /// Apple's `Tool.call` return value.
    func toToolResultJSON() -> String {
        let env = envelope()
        guard JSONSerialization.isValidJSONObject(env),
              let data = try? JSONSerialization.data(withJSONObject: env, options: [.sortedKeys])
        else {
            return #"{"value":null,"missingReason":"internalError","detail":"FactValue not JSON-serialisable"}"#
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Build the dictionary that `toolResultJSON` and
    /// `toToolResultJSON()` encode.
    private func envelope() -> [String: Any] {
        var env: [String: Any] = [
            "asOf": Self.localISO8601(Date()),
            "confidence": "high"
        ]
        switch self {
        case .missing(let reason, let detail):
            env["value"] = NSNull()
            env["missingReason"] = reason.rawValue
            if let detail { env["detail"] = detail }
        default:
            env["value"] = toAnyJSON()
            // missingReason deliberately omitted on success — its presence
            // is THE signal to the model that a value is absent.
        }
        return env
    }

    /// Walk the FactValue tree into Foundation-native types
    /// (String/Int/Double/Bool/[Any]/[String:Any]/NSNull) so an encodable
    /// wrapper can emit them as JSON.
    private func toAnyJSON() -> Any {
        switch self {
        case .integer(let n): return n
        case .double(let d):
            // NaN / infinity are not valid JSON; emit null for that one
            // field instead of failing the whole payload.
            return d.isFinite ? d : NSNull()
        case .string(let s): return s
        case .date(let d): return Self.localISO8601(d)
        case .durationSec(let sec): return sec
        case .boolean(let b): return b
        case .missing:
            // Nested missing inside a list/record. Emit the envelope
            // inline so the model can read field-level absence.
            return envelope()
        case .list(let items):
            return items.map { $0.toAnyJSON() }
        case .record(let r):
            return r.mapValues { $0.toAnyJSON() }
        }
    }

    // MARK: Formatting helpers

    /// ISO 8601 with the device's current UTC offset (e.g.
    /// `2026-04-21T19:30:00-07:00`). Built per call from a `Sendable`
    /// format style so a time-zone change while the app runs is picked
    /// up and the resolvers can format from any isolation domain.
    static func localISO8601(_ date: Date) -> String {
        Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: .current).format(date)
    }

    private static func formatDuration(_ sec: Int) -> String {
        let h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60
        if h > 0 { return String(format: "%dh %dm %ds", h, m, s) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }
}

/// Foundation-type → JSON wrapper for `FactValue.toolResultJSON`. Accepts
/// whatever `FactValue` encodes (scalars, arrays, dicts) and emits them
/// via `Encodable` so JSONEncoder's `.sortedKeys` handles key ordering
/// uniformly across nested records.
private struct AnyFactJSON: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let s as String: try c.encode(s)
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let arr as [Any]: try c.encode(arr.map(AnyFactJSON.init))
        case let dict as [String: Any]:
            try c.encode(dict.mapValues(AnyFactJSON.init))
        case is NSNull: try c.encodeNil()
        default: try c.encodeNil()
        }
    }
}
