@testable import Emuqu
import XCTest

/// Pins that every regex the log redactor uses actually compiles, and that
/// redaction still removes what it claims to.
///
/// A `guard let regex = try? NSRegularExpression(...) else { return text }`
/// in `DebugLogger.replacing` returns the line **unmodified** on a malformed
/// pattern, which means redaction fails OPEN: raw HRV, heart rate and GPS
/// coordinates flow into `debug_log.txt`, which is user-exportable and
/// routinely attached to support mail. Nothing anywhere would say so.
///
/// That is the same failure shape this repository keeps finding — a control
/// that is present, believed active, and silently doing nothing. The pattern
/// strings are compile-time constants, so "does it compile" is a question a
/// test can answer once and for all.
final class RedactionPatternTests: XCTestCase {
    /// The literal patterns `DebugLogger` composes its redaction chain from. Kept
    /// verbatim rather than reached through the private API, so that editing a
    /// pattern in `DebugLogger` without editing it here shows up as a failure of
    /// `testEveryLivePatternIsCoveredHere` below rather than a silent gap.
    private static let patterns: [String] = [
        #"(?i)(\b(?:lat|lon|latitude|longitude|coord(?:inate)?)\s*[:=]?\s*)[-+]?\d+\.\d+"#,
        #"(?:\s*(?:ms|bpm|BPM|%|°[CF]|min|h|points?))?"#,
        #"\s*(?:[:=]|->|→|<|>)?\s*"#,
        #"(?<![\w.])([A-Za-z_][A-Za-z0-9_]*)\s*[:=]\s*(?:Optional\()?\[?([-+]?\d+(?:\.\d+)?[A-Za-z%°]*)(?![\w]|\.\d|-[0-9A-Fa-f]{4}-)"#,
        #"(?<![\w.])[-+]?\d+(?:\.\d+)?(?:\s*[-–]\s*\d+(?:\.\d+)?)?(\s*(?:bpm|BPM))\b"#
    ] + metricNames + ["(?:" + metricNames.joined(separator: "|") + ")"]

    /// The metric names `DebugLogger.metricNames` joins into its metric
    /// alternation, verbatim and in order.
    private static let metricNames: [String] = [
        #"RMSSD"#, #"SDNN"#, #"pNN50"#, #"HRV"#, #"RHR"#, #"resting\s*HR"#, #"heart\s*rate"#, #"HR"#,
        #"alpha1"#, #"DFA"#, #"SpO2"#, #"respiratory\s*rate"#, #"respiration"#, #"temperature"#,
        #"wrist\s*temp"#, #"breath"#, #"composite"#, #"recovery\s*score"#, #"readiness"#, #"sleep\s*score"#,
        #"\w*score"#, #"baseline"#, #"TSB"#, #"ATL"#, #"CTL"#, #"hrTSS"#, #"TRIMP"#, #"RR"#, #"nadir"#,
        #"sleep"#, #"deep"#, #"REM"#, #"weight"#, #"VO2\s*max"#, #"FTP"#, #"LTHR"#, #"calories"#
    ]

    /// The names are joined into one pattern at runtime; pin the order too,
    /// since an earlier alternative wins at the same position.
    func testMetricNamesMatchTheLiveListInOrder() {
        XCTAssertEqual(DebugLogger.metricNames, Self.metricNames)
    }

    // MARK: - Compilation

    func testEveryRedactionPatternCompiles() {
        for pattern in Self.patterns {
            XCTAssertNoThrow(
                try NSRegularExpression(pattern: pattern, options: []),
                "Malformed redaction pattern — redaction fails OPEN, it does not fail loudly: \(pattern)"
            )
        }
    }

    /// The chain pattern is built at runtime by string interpolation, which is
    /// exactly where a malformed result is easiest to introduce and hardest to
    /// see. Compile the composed constant `redactValueChains` uses.
    func testComposedValueChainPatternCompiles() {
        XCTAssertNoThrow(try NSRegularExpression(pattern: DebugLogger.valueChainPattern, options: []))
    }

    /// The main `scrubPHI` pattern is also composed at runtime, from the
    /// metric, separator and unit patterns above. Compile the composed constant.
    func testComposedMetricPatternCompiles() {
        XCTAssertNoThrow(try NSRegularExpression(pattern: DebugLogger.metricValuePattern, options: []))
    }

    // MARK: - Redaction output

    /// Compiling is not redacting: these pin what `scrubPHI` actually leaves
    /// in `debug_log.txt` — metric names and units stay, the values go, and a
    /// line with no health value passes through untouched.
    func testScrubPHIRedactsHealthValues() {
        XCTAssertEqual(DebugLogger.scrubPHI("RMSSD: 42.5 ms"), "RMSSD: <redacted>")
        XCTAssertEqual(DebugLogger.scrubPHI("RMSSD 42.0→51.3"), "RMSSD <redacted>→<redacted>")
        XCTAssertEqual(DebugLogger.scrubPHI("(start=x, score=72.00) into"), "(start=x, score=<redacted>) into")
        XCTAssertEqual(DebugLogger.scrubPHI("frozenScore=55.20"), "frozenScore=<redacted>")
        XCTAssertEqual(DebugLogger.scrubPHI("lat=37.1234 lon=-122.4567"), "lat=<redacted> lon=<redacted>")
        XCTAssertEqual(DebugLogger.scrubPHI("session 3 started"), "session 3 started")
    }

    /// Named values are redacted unless the key is on the allow-list: no one
    /// has to add `nadir`, `perceivedReadiness` or `total` (sleep minutes)
    /// for them to be covered. These lines all passed through unchanged
    /// before the allow-list.
    func testScrubPHIRedactsUnlistedNamedValues() {
        XCTAssertEqual(
            DebugLogger.scrubPHI("[PDF] Using HealthKit HR: nadir=48.0, max=61.0"),
            "[PDF] Using HealthKit HR: nadir=<redacted>, max=<redacted>"
        )
        XCTAssertEqual(DebugLogger.scrubPHI("Persisted perceivedReadiness=0.70"), "Persisted perceivedReadiness=<redacted>")
        XCTAssertEqual(DebugLogger.scrubPHI("night total=412min"), "night total=<redacted>")
        XCTAssertEqual(
            DebugLogger.scrubPHI("recoveryScore=7.1 frozenReadiness=6.2"),
            "recoveryScore=<redacted> frozenReadiness=<redacted>"
        )
        XCTAssertEqual(
            DebugLogger.scrubPHI("restingHR=54 maxHR=180 bodyWeightKg=72.5"),
            "restingHR=<redacted> maxHR=<redacted> bodyWeightKg=<redacted>"
        )
        XCTAssertEqual(DebugLogger.scrubPHI("values=[42, 51, 60]"), "values=[<redacted>, <redacted>, <redacted>]")
        XCTAssertEqual(DebugLogger.scrubPHI("x: Optional(42.0)"), "x: Optional(<redacted>)")
    }

    /// Counts and identifiers stay, so the log still triages: a key whose
    /// last word is allow-listed, a UUID and a timestamp prefix.
    func testScrubPHIKeepsCountsAndIdentifiers() {
        let line = "[2026-11-21 06:30:00.123] [Cat] [123] beatCount=40000 attempt=2 schemaVersion=3 code=-1009"
        XCTAssertEqual(DebugLogger.scrubPHI(line), line)
        let ids = "session=12345678-ABCD-1234-ABCD-1234567890AB id=3F2A"
        XCTAssertEqual(DebugLogger.scrubPHI(ids), ids)
    }

    /// Prose values: a number in beats per minute whatever names it, and the
    /// metric names added for prose.
    func testScrubPHIRedactsProseHeartRateAndSleep() {
        XCTAssertEqual(DebugLogger.scrubPHI("HR dropped to 52 bpm"), "HR dropped to <redacted> bpm")
        XCTAssertEqual(DebugLogger.scrubPHI("zone 60-70 bpm"), "zone <redacted> bpm")
        XCTAssertEqual(DebugLogger.scrubPHI("RR 850ms"), "RR <redacted>")
        XCTAssertEqual(DebugLogger.scrubPHI("weight 72 kg"), "weight <redacted> kg")
    }

    /// Timing, microphone level and text lengths stay readable for triage;
    /// health values with a similar shape still go.
    func testScrubPHIKeepsDiagnosticNumbers() {
        let rows: [(line: String, scrubbed: String)] = [
            ("finalizing turn, transcript=42 chars", "finalizing turn, transcript=42 chars"),
            ("buffer received (rms=0.0123)", "buffer received (rms=0.0123)"),
            ("finalizeSession done (elapsed=1.42s)", "finalizeSession done (elapsed=1.42s)"),
            ("totalElapsed=2.1s inputTokens=1234", "totalElapsed=2.1s inputTokens=1234"),
            ("heartRate=72", "heartRate=<redacted>"),
            ("total=412min", "total=<redacted>"),
            ("duration=3600s", "duration=<redacted>")
        ]
        for row in rows {
            XCTAssertEqual(DebugLogger.scrubPHI(row.line), row.scrubbed, row.line)
        }
    }

    func testLastKeyWordSplitsCamelAndSnakeCase() {
        XCTAssertEqual(DebugLogger.lastKeyWord("beatCount"), "count")
        XCTAssertEqual(DebugLogger.lastKeyWord("rr_points"), "points")
        XCTAssertEqual(DebugLogger.lastKeyWord("maxHR"), "hr")
        XCTAssertEqual(DebugLogger.lastKeyWord("count"), "count")
    }

    /// The key/value and unit patterns are composed into the scrub at
    /// runtime; compile them as the scrub does.
    func testKeyValueAndUnitPatternsCompile() {
        XCTAssertNoThrow(try NSRegularExpression(pattern: DebugLogger.keyValuePattern, options: []))
        XCTAssertNoThrow(try NSRegularExpression(pattern: DebugLogger.heartRateUnitPattern, options: []))
    }

    /// `DebugLogger.compiledPattern` returns nil rather than trapping on a bad
    /// pattern — the app must not crash mid-recording over a logging concern.
    /// This pins that contract in both directions.
    func testCompiledPatternReturnsNilOnMalformedInput() {
        XCTAssertNil(DebugLogger.compiledPattern("([unterminated"))
        XCTAssertNotNil(DebugLogger.compiledPattern(#"\d+"#))
    }

    /// Caching must not change the result — a second call has to behave like
    /// the first, or redaction becomes order-dependent.
    func testCompiledPatternIsStableAcrossCalls() throws {
        let first = try XCTUnwrap(DebugLogger.compiledPattern(#"[A-Z]\d{2}"#))
        let second = try XCTUnwrap(DebugLogger.compiledPattern(#"[A-Z]\d{2}"#))
        XCTAssertEqual(first.pattern, second.pattern)
    }

    // MARK: - Coverage of the live source

    /// Fails if `DebugLog.swift` grows a raw-string pattern this file does not
    /// know about. Without it, the compile test above would keep passing while
    /// covering less and less — the drift that lets a control go quietly inert.
    func testEveryLivePatternIsCoveredHere() throws {
        let source = try sourceOfDebugLog()
        let live = matches(of: ##"#"((?:[^"\n]|"(?!#))*)"#"##, in: source)
        XCTAssertFalse(live.isEmpty, "Found no patterns in DebugLog.swift — the scraper broke, not the source")
        for pattern in live {
            XCTAssertTrue(
                Self.patterns.contains(pattern),
                "DebugLog.swift uses a redaction pattern this test does not cover. Add it to `patterns`: \(pattern)"
            )
        }
    }

    // MARK: - Every literal regex in the fail-open call sites

    /// Files whose regexes fail OPEN — a compile failure disables the control
    /// silently rather than crashing or erroring. Every raw-string pattern in
    /// them must compile, and this test is the thing that says so.
    ///
    /// `MetricsVerifier` is here for the same reason as `DebugLog`: its regex
    /// failure path returns `[]`, which means "no discrepancies found", so a
    /// malformed pattern silently PASSES every numeric claim the assistant
    /// makes about that metric instead of checking it.
    private static let failOpenSources = [
        "Emuqu/Sources/Utilities/DebugLog.swift",
        "Emuqu/Sources/Assistant/MetricsVerifier.swift"
    ]

    /// `MedicalTermLexicon` fails open the same way — both guards reach its
    /// patterns through `compactMap`, so a concept that will not compile is
    /// silently removed from the medical perimeter. Its own coverage lives in
    /// `CoachVoiceGuardTests.testEveryConceptCompiles`, which walks
    /// `MedicalTermLexicon.all` and is the right place for it: the patterns
    /// there are built from alternation arrays, not raw-string literals, so a
    /// source scrape would not see them. Named here so the next reader looking
    /// for "where are the fail-open regexes checked" finds all three.
    private static let failOpenCoveredElsewhere = [
        "Emuqu/Sources/Assistant/MedicalTermLexicon.swift": "CoachVoiceGuardTests.testEveryConceptCompiles"
    ]

    func testMedicalLexiconCoverageStillExists() {
        XCTAssertFalse(MedicalTermLexicon.all.isEmpty)
        for concept in MedicalTermLexicon.all {
            XCTAssertNotNil(
                MedicalTermLexicon.regex(for: concept),
                "Concept \(concept.id) will not compile — it is silently absent from both medical guards"
            )
        }
        XCTAssertEqual(Self.failOpenCoveredElsewhere.count, 1)
    }

    func testEveryLiteralPatternInFailOpenSourcesCompiles() throws {
        var checked = 0
        for relativePath in Self.failOpenSources {
            let source = try sourceOf(relativePath)
            let patterns = matches(of: ##"#"((?:[^"\n]|"(?!#))*)"#"##, in: source)
            XCTAssertFalse(patterns.isEmpty, "No patterns found in \(relativePath) — the scraper broke, not the source")
            for pattern in patterns {
                XCTAssertNoThrow(
                    try NSRegularExpression(pattern: pattern, options: []),
                    "\(relativePath) carries a malformed regex. It fails OPEN — the control silently stops working: \(pattern)"
                )
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 10, "Scraped implausibly few patterns; the scan regex probably stopped matching")
    }

    private func sourceOfDebugLog() throws -> String {
        try sourceOf("Emuqu/Sources/Utilities/DebugLog.swift")
    }

    private func sourceOf(_ relativePath: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
    }

    private func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
