import Foundation

/// The one way a fact resolver turns a model-supplied argument into a number.
///
/// Tool arguments are written by a language model, so any text can arrive.
/// `Double(String)` accepts "inf", "nan" and "1e20", and `Int(Double)` traps on
/// every one of them, as does a day count, loop bound or array index built
/// from them. Each numeric parameter therefore declares its range here, and
/// `value(_:)` accepts only a finite number inside it (a whole number where the
/// parameter is a count). Anything else throws a `FactArgumentError` whose
/// `factValue` is the `.invalidParameter` reply naming the parameter and the
/// accepted range, so the model can correct the call.
struct FactNumericArgument: Sendable {
    let name: String
    let range: ClosedRange<Double>
    /// True when the lower bound itself is not accepted (`gap_trimp > 0`).
    let excludesLowerBound: Bool
    /// True for counts, days and indices: only whole numbers are accepted.
    let integral: Bool

    init(_ name: String, _ range: ClosedRange<Double>, excludesLowerBound: Bool = false, integral: Bool = false) {
        self.name = name
        self.range = range
        self.excludesLowerBound = excludesLowerBound
        self.integral = integral
    }

    /// The parsed value, or a throw when the text is not a finite number
    /// inside this parameter's range.
    func value(_ raw: some StringProtocol) throws(FactArgumentError) -> Double {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(text), parsed.isFinite, accepts(parsed) else {
            throw FactArgumentError(detail: "\(name) must be \(requirement), got '\(text.prefix(40))'")
        }
        return parsed
    }

    /// The parsed whole number. `Int(exactly:)` cannot trap, and the range
    /// check in `value(_:)` has already bounded the result.
    func integer(_ raw: some StringProtocol) throws(FactArgumentError) -> Int {
        let parsed = try value(raw)
        guard let whole = Int(exactly: parsed) else {
            throw FactArgumentError(detail: "\(name) must be \(requirement)")
        }
        return whole
    }

    private func accepts(_ value: Double) -> Bool {
        guard range.contains(value), !(excludesLowerBound && value == range.lowerBound) else { return false }
        return !integral || value.rounded(.towardZero) == value
    }

    /// "a whole number from 1 to 365", "a number above 0 and at most 10000".
    var requirement: String {
        let kind = integral ? "a whole number" : "a finite number"
        let low = Self.format(range.lowerBound)
        let high = Self.format(range.upperBound)
        return excludesLowerBound ? "\(kind) above \(low) and at most \(high)" : "\(kind) from \(low) to \(high)"
    }

    private static func format(_ bound: Double) -> String {
        bound.rounded(.towardZero) == bound ? String(format: "%.0f", bound) : String(bound)
    }
}

/// A rejected tool argument. `factValue` is the reply the model receives.
struct FactArgumentError: Error, Equatable {
    let detail: String

    var factValue: FactValue {
        .missing(reason: .invalidParameter, detail: detail)
    }
}

extension FactNumericArgument {
    /// Splits a comma-separated parameter list into trimmed fields. Throws
    /// with `format` (the expected shape, e.g. "'daily_trimp,gap_trimp'")
    /// unless the field count is one of `counts`. Empty fields count, so
    /// "60,,5" is three fields and is rejected rather than silently read as two.
    static func fields(
        _ raw: String,
        counts: Set<Int>,
        format: String
    ) throws(FactArgumentError) -> [String] {
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard counts.contains(parts.count), !parts.contains(where: \.isEmpty) else {
            throw FactArgumentError(detail: "expected \(format), got '\(raw.prefix(80))'")
        }
        return parts
    }
}

// MARK: - Declared parameters

/// Bounds for every numeric parameter the fact catalog accepts. A new
/// numeric parameter gets its declaration here, never an inline `Double(…)`.
extension FactNumericArgument {
    /// ATL and CTL are exponentially weighted averages of daily TRIMP, so
    /// neither can exceed the largest daily load. A long, hard day is a few
    /// hundred TRIMP; 10,000 is far above anything a person can record and
    /// low enough that projections stay finite.
    static let startingATL = FactNumericArgument("starting_atl", 0 ... 10_000)
    static let startingCTL = FactNumericArgument("starting_ctl", 0 ... 10_000)
    static let dailyTrimp = FactNumericArgument("daily_trimp", 0 ... 10_000)
    static let gapTrimp = FactNumericArgument("gap_trimp", 0 ... 10_000, excludesLowerBound: true)
    /// Up to one year ahead.
    static let horizonDays = FactNumericArgument("horizon_days", 1 ... 365, integral: true)

    static let latitude = FactNumericArgument("lat", -90 ... 90)
    static let longitude = FactNumericArgument("lon", -180 ... 180)
    /// Below 5 m GPS noise alone decides the match; above 5 km the match is
    /// no longer "this point" on a route.
    static let segmentRadiusMeters = FactNumericArgument("radius_m", 5 ... 5_000)

    /// Recency index into the workout list (0 = most recent).
    static let ordinal = FactNumericArgument("ordinal", 0 ... 100_000, integral: true)
    /// Live-timeline lookback in seconds; up to one day is accepted and the
    /// resolver clamps it to the window it keeps.
    static let lookbackSeconds = FactNumericArgument("seconds", 1 ... 86_400, integral: true)
    /// The search tool returns 1–10 results.
    static let maxResults = FactNumericArgument("max_results", 1 ... 10, integral: true)
}
