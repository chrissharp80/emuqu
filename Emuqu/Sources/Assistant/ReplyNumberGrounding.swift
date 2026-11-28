import Foundation

/// Every number a reply states about the user's data must come from the data
/// the model was given this turn: the live-state block, the conversation, and
/// each tool result. A number is grounded when it matches one of those values
/// at the precision the reply shows, converted only into the unit written
/// after it ("3.96 mi" may be metres in miles, "60 ms" is only milliseconds),
/// or when it is the difference or percent change of two numbers the same
/// reply grounded. Averages, totals and trends are not recomputed here: the
/// app computes them (`analyze_data`), so they arrive as tool values. Each
/// loosening widens what a coincidental match lets through, so the rules stay
/// this narrow (Proof-Carrying Numbers, arXiv 2509.06902, Lemma 5.4).
///
/// Dates, clock times, years and small counts are not checked: they are not
/// the measurements a wrong answer invents.
enum ReplyNumberGrounding {
    /// One number the reply states, as written and as a value.
    struct StatedNumber: Equatable {
        let text: String
        let value: Double
        /// Half a unit in the last place the reply shows: 0.5 for "58", 0.05 for "32.0".
        let halfStep: Double
        /// Other readings of the same span: "4h12m" is also 252 minutes.
        let alternates: [Double]
        /// The unit word written after the number, lowercased; empty when none.
        var unit: String = ""
    }

    /// The stated numbers no source accounts for.
    static func ungrounded(in reply: String, sources: [String]) -> [StatedNumber] {
        let values = groundingSourceValues(sources)
        let aboutTheUser = replySentences(reply).filter { !statesAGeneralNorm($0) }
        let stated = aboutTheUser.flatMap(statedNumbers(in:))
        let grounded = stated.filter { isGrounded($0, by: values) }
        return stated.filter { number in
            !grounded.contains(number) && !isDerived(number, from: grounded)
        }
    }

    /// Phrases of a sentence about people in general, not the user's data:
    /// "adults typically need 7 to 9 hours", "studies put RMSSD at 20 to 70 ms".
    private static let generalNormMarkers = [
        "adults", "most people", "typically", "on average people", "research", "studies", "study", "guideline", "recommended",
        "recommend", "aim for", "normal range", "for most", "in general", "population", "people your age", "healthy range"
    ]

    static func statesAGeneralNorm(_ sentence: String) -> Bool {
        let lowered = sentence.lowercased()
        return generalNormMarkers.contains { lowered.contains($0) }
    }

    // MARK: - Sources

    /// Every number in the sources, plus each JSON list field's sum and mean.
    static func groundingSourceValues(_ sources: [String]) -> [Double] {
        var values: [Double] = []
        for source in sources {
            values += numbersInText(source)
        }
        return values
    }

    /// A value in a source, not a piece of a clock time or a date: "12:44"
    /// and an ISO date give no numbers, `"rmssd_ms":32.04` gives 32.04.
    private static let plainNumber = #"(?<![\d.])(?<!\d:)(?<!\d-)-?\d+(?:\.\d+)?(?![\d]|\.\d|:\d|-\d)"#

    static func numbersInText(_ text: String) -> [Double] {
        guard let regex = DebugLogger.compiledPattern(plainNumber) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).flatMap { Double(text[$0]) }
        }
    }

    // MARK: - Matching

    /// Factors from a stored value into the unit the reply wrote: miles from
    /// metres or kilometres, kilometres from metres, feet from metres, hours
    /// from minutes or seconds, minutes from seconds or hours, a percent from
    /// a ratio. Any other unit, or none, takes the value as stored.
    static func storedValueFactors(forUnit unit: String) -> [Double] {
        switch unit {
        case "mi", "mile", "miles": [1, 1 / 1609.344, 1 / 1.609344]
        case "km", "kilometer", "kilometers", "kilometre", "kilometres": [1, 1 / 1000]
        case "ft", "feet", "foot": [1, 1 / 0.3048]
        case "h", "hr", "hrs", "hour", "hours": [1, 1 / 60, 1 / 3600]
        case "min", "mins", "minute", "minutes": [1, 1 / 60, 60]
        case "%", "percent": [1, 100]
        default: [1]
        }
    }

    static func isGrounded(_ number: StatedNumber, by values: [Double]) -> Bool {
        let candidates = [number.value] + number.alternates
        return values.contains { source in candidates.contains { convertsTo($0, from: source, unit: number.unit, within: number.halfStep) } }
    }

    /// Whether `source`, converted into `unit`, rounds to `stated`. A
    /// Fahrenheit temperature may come from Celsius.
    private static func convertsTo(_ stated: Double, from source: Double, unit: String, within halfStep: Double) -> Bool {
        let fahrenheit = unit.hasPrefix("°f") || unit == "°" || unit.hasPrefix("degree") || unit == "f"
        let conversions = storedValueFactors(forUnit: unit).map { source * $0 } + (fahrenheit ? [source * 9 / 5 + 32] : [])
        return conversions.contains { abs($0 - stated) <= halfStep + 1e-9 }
    }

    /// The difference or percent change of two grounded numbers.
    static func isDerived(_ number: StatedNumber, from grounded: [StatedNumber]) -> Bool {
        let values = grounded.map(\.value)
        let pairs = values.flatMap { a in values.filter { $0 != a }.map { (a, $0) } }
        let derived = pairs.flatMap { a, b in [abs(a - b), b == 0 ? Double.nan : abs(a - b) / abs(b) * 100] }
        return derived.contains { abs($0 - number.value) <= number.halfStep + 1e-9 }
    }

    /// Sentences with their trailing punctuation and space, so joining them
    /// rebuilds the text. A decimal point is not a sentence end.
    static func replySentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var previous: Character = " "
        for character in text {
            let ends = (previous == "." || previous == "!" || previous == "?" || previous == "\n") && (character == " " || character == "\n")
            if ends, !current.isEmpty {
                sentences.append(current)
                current = ""
            }
            current.append(character)
            previous = character
        }
        if !current.isEmpty { sentences.append(current) }
        return sentences
    }
}
