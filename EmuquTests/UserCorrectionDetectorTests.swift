@testable import Emuqu
import XCTest

/// Tests for `UserCorrectionDetector` — the "trust the user, not the cache"
/// detector that decides whether the assistant's injected context blocks get
/// suppressed on the next turn.
///
/// The failure this guards against is specific and was observed in a real
/// transcript: the user says "TSB is -8.8", the cached block still says
/// "TSB +2.1", and the model keeps quoting the cache back at them. Every
/// assertion below is about *observation* — the detector reports what the
/// user said and never decides policy, so the tests check exactly that
/// boundary too.
final class UserCorrectionDetectorTests: XCTestCase {
    // MARK: - Nothing to detect

    func testNoMessagesProducesNoSignals() {
        let signals = UserCorrectionDetector.detect(userMessages: [])
        XCTAssertTrue(signals.assertedValues.isEmpty)
        XCTAssertFalse(signals.dashboardContradicted)
        XCTAssertFalse(signals.explicitOverrideRequested)
        XCTAssertFalse(signals.hasAnyCorrection)
    }

    func testOrdinaryConversationIsNotACorrection() {
        let signals = UserCorrectionDetector.detect(userMessages: [
            "how did I sleep last night?",
            "what should I do for training today?"
        ])
        XCTAssertFalse(signals.hasAnyCorrection)
    }

    func testAskingAboutAMetricIsNotAssertingOne() {
        // A number has to be adjacent to the metric. "what is my ctl?" is a
        // question, not a correction, and must not poison the context.
        let signals = UserCorrectionDetector.detect(userMessages: ["what is my ctl?"])
        XCTAssertTrue(signals.assertedValues.isEmpty)
    }

    // MARK: - Value extraction

    func testExtractsASimpleAssertion() {
        let signals = UserCorrectionDetector.detect(userMessages: ["my ctl is 62"])
        XCTAssertEqual(signals.assertedValues["ctl"], 62)
        XCTAssertTrue(signals.hasAnyCorrection)
    }

    func testAcceptsEveryConnectorForm() {
        let cases: [(String, String, Double)] = [
            ("tsb = -13.7", "tsb", -13.7),
            ("atl: 88", "atl", 88),
            ("rmssd was 42", "rmssd", 42),
            ("acwr of 1.35", "acwr", 1.35),
            ("hr is 145", "hr", 145),
            ("ctl being 60", "ctl", 60),
            ("sdnn 55", "sdnn", 55)
        ]
        for (text, key, expected) in cases {
            let signals = UserCorrectionDetector.detect(userMessages: [text])
            XCTAssertEqual(signals.assertedValues[key], expected, "failed on \"\(text)\"")
        }
    }

    func testExtractionIsCaseInsensitive() {
        let signals = UserCorrectionDetector.detect(userMessages: ["MY CTL IS 62 AND TSB IS -4.5"])
        XCTAssertEqual(signals.assertedValues["ctl"], 62)
        XCTAssertEqual(signals.assertedValues["tsb"], -4.5)
    }

    func testExtractsMultipleMetricsFromOneMessage() {
        let signals = UserCorrectionDetector.detect(
            userMessages: ["dashboard says ctl 62, atl 71, tsb -9.4, acwr 1.15"]
        )
        XCTAssertEqual(signals.assertedValues["ctl"], 62)
        XCTAssertEqual(signals.assertedValues["atl"], 71)
        XCTAssertEqual(signals.assertedValues["tsb"], -9.4)
        XCTAssertEqual(signals.assertedValues["acwr"], 1.15)
    }

    func testAccumulatesMetricsAcrossSeparateMessages() {
        let signals = UserCorrectionDetector.detect(userMessages: [
            "my atl is 71",
            "and my ctl is 62"
        ])
        XCTAssertEqual(signals.assertedValues["atl"], 71)
        XCTAssertEqual(signals.assertedValues["ctl"], 62)
    }

    func testNewestMessageWinsWhenTheUserRestatesAMetric() {
        let signals = UserCorrectionDetector.detect(userMessages: [
            "my ctl is 50",
            "sorry, my ctl is 62"
        ])
        XCTAssertEqual(signals.assertedValues["ctl"], 62)
    }

    func testLastAssertionWinsWithinASingleMessage() {
        let signals = UserCorrectionDetector.detect(
            userMessages: ["ctl is 50 — no wait, ctl is 62"]
        )
        XCTAssertEqual(signals.assertedValues["ctl"], 62)
    }

    func testRequiresAWholeWordMetricName() {
        // "hrtss" must not be read as an assertion about "hr".
        let signals = UserCorrectionDetector.detect(userMessages: ["hrtss is 120"])
        XCTAssertEqual(signals.assertedValues["hrtss"], 120)
        XCTAssertNil(signals.assertedValues["hr"])
    }

    func testMultiWordMetricBeatsItsBareSuffix() {
        // "recovery score is 78" — the bare "recovery" token has no adjacent
        // number (the word "score" is in the way), so only the long form
        // registers. Worth pinning: the composer keys off exact metric names.
        let signals = UserCorrectionDetector.detect(userMessages: ["my recovery score is 78"])
        XCTAssertEqual(signals.assertedValues["recovery score"], 78)
        XCTAssertNil(signals.assertedValues["recovery"])
    }

    func testLongerHeartRateNameClaimsItsMatch() {
        // "resting hr" is matched first and blanked, so the bare "hr" does
        // not also report the resting value as a plain heart rate.
        let signals = UserCorrectionDetector.detect(userMessages: ["my resting hr is 48"])
        XCTAssertEqual(signals.assertedValues["resting hr"], 48)
        XCTAssertNil(signals.assertedValues["hr"])
    }

    func testMaxHeartRateIsNotReadAsHeartRate() {
        let signals = UserCorrectionDetector.detect(userMessages: ["my max hr 190"])
        XCTAssertEqual(signals.assertedValues["max hr"], 190)
        XCTAssertNil(signals.assertedValues["hr"])
    }

    func testClockTimesAreNotValues() {
        for text in ["my hr at 5 am was high", "sleep at 11", "hr 5:30 this morning", "hr 6 pm"] {
            let signals = UserCorrectionDetector.detect(userMessages: [text])
            XCTAssertTrue(signals.assertedValues.isEmpty, "failed on \"\(text)\"")
        }
    }

    func testQuestionsAssertNothing() {
        let signals = UserCorrectionDetector.detect(userMessages: ["Why is my rmssd 42 today?"])
        XCTAssertTrue(signals.assertedValues.isEmpty)
    }

    // MARK: - Spelled-out numbers (voice mode)

    func testNormalisesSpelledNegativeDecimal() {
        // The exact voice-mode phrasing that must not slip past the detector.
        let signals = UserCorrectionDetector.detect(
            userMessages: ["my tsb is negative thirteen point seven"]
        )
        XCTAssertEqual(signals.assertedValues["tsb"] ?? .nan, -13.7, accuracy: 0.001)
    }

    func testNormalisesSpelledCompoundTens() {
        let signals = UserCorrectionDetector.detect(userMessages: ["ctl is sixty two"])
        XCTAssertEqual(signals.assertedValues["ctl"], 62)
    }

    func testDigitFormIsUnaffectedByNormalisation() {
        let signals = UserCorrectionDetector.detect(userMessages: ["ctl is 62"])
        XCTAssertEqual(signals.assertedValues["ctl"], 62)
    }

    // MARK: - Transcription aliases

    func testFoldsTranscriptionTyposIntoTheCanonicalMetric() {
        for typo in ["bsb", "tsp", "tbs"] {
            let signals = UserCorrectionDetector.detect(userMessages: ["\(typo) is -8.8"])
            XCTAssertEqual(signals.assertedValues["tsb"], -8.8, "failed on \"\(typo)\"")
        }
        XCTAssertEqual(
            UserCorrectionDetector.detect(userMessages: ["atrl is 71"]).assertedValues["atl"],
            71
        )
        XCTAssertEqual(
            UserCorrectionDetector.detect(userMessages: ["clt is 62"]).assertedValues["ctl"],
            62
        )
        XCTAssertEqual(
            UserCorrectionDetector.detect(userMessages: ["acrw is 1.2"]).assertedValues["acwr"],
            1.2
        )
    }

    func testCorrectSpellingOutranksATypoInTheSameMessage() {
        let signals = UserCorrectionDetector.detect(userMessages: ["tsb is -5 and bsb is -8.8"])
        XCTAssertEqual(signals.assertedValues["tsb"], -5)
    }

    func testAliasDoesNotCreateItsOwnKey() {
        let signals = UserCorrectionDetector.detect(userMessages: ["bsb is -8.8"])
        XCTAssertNil(signals.assertedValues["bsb"])
    }

    // MARK: - Dashboard contradiction

    func testDetectsDashboardContradictionPhrases() {
        let phrases = [
            "the dashboard actually says 62",
            "the dashboard says something else",
            "no it's not that",
            "actually it's different",
            "you're wrong",
            "that's incorrect",
            "those are wrong",
            "wrong value"
        ]
        for phrase in phrases {
            XCTAssertTrue(
                UserCorrectionDetector.detect(userMessages: [phrase]).dashboardContradicted,
                "missed contradiction in \"\(phrase)\""
            )
        }
    }

    func testConversationalOpenersAreNotContradictions() {
        let phrases = [
            "Actually it's been a rough week — how's my load?",
            "No it's fine, just tell me my HRV"
        ]
        for phrase in phrases {
            XCTAssertFalse(
                UserCorrectionDetector.detect(userMessages: [phrase]).dashboardContradicted,
                "\"\(phrase)\" is not a correction"
            )
        }
        XCTAssertTrue(UserCorrectionDetector.detect(userMessages: ["Actually, it's 62."]).dashboardContradicted)
    }

    func testSleepAndRecoveryNeedAConnector() {
        let quoted = UserCorrectionDetector.detect(userMessages: ["recovery 45 seems low", "sleep 8 hours was fine"])
        XCTAssertNil(quoted.assertedValues["recovery"])
        XCTAssertNil(quoted.assertedValues["sleep"])
        let stated = UserCorrectionDetector.detect(userMessages: ["my recovery is 45"])
        XCTAssertEqual(stated.assertedValues["recovery"], 45)
    }

    func testBareContradictionCountsEvenWithoutAFreshValue() {
        // Real transcript: "no. you are wrong". No number given, but the
        // cache block still has to come out of the context or the model
        // just re-quotes it.
        let signals = UserCorrectionDetector.detect(userMessages: ["no. you are wrong"])
        XCTAssertTrue(signals.dashboardContradicted)
        XCTAssertTrue(signals.assertedValues.isEmpty)
        XCTAssertTrue(signals.hasAnyCorrection)
    }

    func testContradictionDetectionIsCaseInsensitive() {
        XCTAssertTrue(
            UserCorrectionDetector.detect(userMessages: ["YOU ARE WRONG"]).dashboardContradicted
        )
    }

    // MARK: - Explicit override

    func testDetectsExplicitOverridePhrases() {
        let phrases = [
            "stop calling tools",
            "do not fetch anything",
            "don't call the tool again",
            "just use these numbers",
            "use the data i gave you",
            "i don't care what the dashboard says",
            "stop using the live data",
            "stop saying that",
            "knock it off",
            "stop repeating yourself"
        ]
        for phrase in phrases {
            XCTAssertTrue(
                UserCorrectionDetector.detect(userMessages: [phrase]).explicitOverrideRequested,
                "missed override in \"\(phrase)\""
            )
        }
    }

    func testRealNumbersPhraseTripsBothSignals() {
        // "the real numbers are …" is deliberately in both phrase lists: it
        // contradicts the cache *and* instructs the assistant to stop using it.
        let signals = UserCorrectionDetector.detect(userMessages: ["the real numbers are 62 and 71"])
        XCTAssertTrue(signals.dashboardContradicted)
        XCTAssertTrue(signals.explicitOverrideRequested)
    }

    func testSignalsFromDifferentMessagesCombine() {
        let signals = UserCorrectionDetector.detect(userMessages: [
            "you're wrong",
            "stop calling tools",
            "my ctl is 62"
        ])
        XCTAssertTrue(signals.dashboardContradicted)
        XCTAssertTrue(signals.explicitOverrideRequested)
        XCTAssertEqual(signals.assertedValues["ctl"], 62)
    }

    // MARK: - Rendering

    func testRenderReturnsNilWithoutAnyCorrection() {
        XCTAssertNil(UserCorrectionDetector.renderAssertedBlock(UserCorrectionDetector.Signals()))
    }

    func testRenderLeadsWithTheAuthoritativeHeader() {
        let signals = UserCorrectionDetector.detect(userMessages: ["ctl is 62"])
        let block = UserCorrectionDetector.renderAssertedBlock(signals)
        XCTAssertEqual(
            block?.split(separator: "\n").first.map(String.init),
            "# User-stated values (authoritative — fresher than any cache)"
        )
    }

    func testRenderIncludesTheStalenessNoticeOnlyWhenAFlagIsSet() {
        var withFlag = UserCorrectionDetector.Signals()
        withFlag.dashboardContradicted = true
        let flagged = UserCorrectionDetector.renderAssertedBlock(withFlag)
        XCTAssertTrue(flagged?.contains("stale or wrong") ?? false)

        var valuesOnly = UserCorrectionDetector.Signals()
        valuesOnly.assertedValues = ["ctl": 62]
        let plain = UserCorrectionDetector.renderAssertedBlock(valuesOnly)
        XCTAssertFalse(plain?.contains("stale or wrong") ?? true)
    }

    func testRenderOmitsTheValueListWhenOnlyAFlagIsSet() {
        var signals = UserCorrectionDetector.Signals()
        signals.explicitOverrideRequested = true
        let block = UserCorrectionDetector.renderAssertedBlock(signals) ?? ""
        XCTAssertFalse(block.contains("\n- "), block)
    }

    func testRenderOrdersPrioritisedMetricsFirstThenAlphabetically() {
        var signals = UserCorrectionDetector.Signals()
        signals.assertedValues = [
            "watts": 240,
            "ctl": 62,
            "atl": 71,
            "cadence": 172,
            "tsb": -9
        ]
        let keys = (UserCorrectionDetector.renderAssertedBlock(signals) ?? "")
            .split(separator: "\n")
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2).prefix(while: { $0 != ":" })) }
        XCTAssertEqual(keys, ["atl", "ctl", "tsb", "cadence", "watts"])
    }

    func testRenderFormatsEachMetricInItsConventionalPrecision() {
        var signals = UserCorrectionDetector.Signals()
        signals.assertedValues = [
            "tsb": -9.42,
            "acwr": 1.3,
            "ctl": 62,
            "rmssd": 41.62,
            "cadence": 172
        ]
        let block = UserCorrectionDetector.renderAssertedBlock(signals) ?? ""
        // TSB is signed — "+2.1" vs "-9.4" is the whole point of the metric.
        XCTAssertTrue(block.contains("- tsb: -9.4"), block)
        XCTAssertTrue(block.contains("- acwr: 1.30"), block)
        XCTAssertTrue(block.contains("- ctl: 62.0"), block)
        XCTAssertTrue(block.contains("- rmssd: 41.6"), block)
        // Anything unlisted falls through to %g — no trailing ".0" noise.
        XCTAssertTrue(block.contains("- cadence: 172"), block)
        XCTAssertFalse(block.contains("- cadence: 172.0"), block)
    }

    func testRenderMarksAPositiveTsbWithItsSign() {
        var signals = UserCorrectionDetector.Signals()
        signals.assertedValues = ["tsb": 2.1]
        XCTAssertTrue(
            (UserCorrectionDetector.renderAssertedBlock(signals) ?? "").contains("- tsb: +2.1")
        )
    }

    // MARK: - Other times, plans and units

    /// A past reading, a goal or a workout prescription is not today's value,
    /// so it must not be rendered as an authoritative correction; a plain
    /// statement about now still is.
    func testOnlyTodaysValuesAreAsserted() {
        let rows: [(text: String, key: String, value: Double?)] = [
            ("Last month my rhr was 48. Why is it higher now?", "rhr", nil),
            ("I'm aiming for a ctl of 80 before the marathon.", "ctl", nil),
            ("Tomorrow do 5x1km at hr 170.", "hr", nil),
            ("my max hr was 195 back in 2019", "max hr", nil),
            ("my target tsb is -10 for race day", "tsb", nil),
            ("my rhr is 52 this morning", "rhr", 52),
            ("last night my rmssd was 38", "rmssd", 38),
            ("My HRV is 38 this morning, not 55.", "rmssd", 38),
            ("my ctl is 62", "ctl", 62)
        ]
        for row in rows {
            XCTAssertEqual(UserCorrectionDetector.detect(userMessages: [row.text]).assertedValues[row.key], row.value, row.text)
        }
    }

    /// A value placed at another time by the lines around it, not its own
    /// sentence, is not today's either: a heading or lead-in over a list, or
    /// a sentence wrapped onto the next line.
    func testValuesUnderAnotherTimesHeadingAreNotAsserted() {
        let rows: [(text: String, key: String, value: Double?)] = [
            ("Yesterday:\n- rhr is 52", "rhr", nil),
            ("Last week\n- ctl is 62", "ctl", nil),
            ("Two days ago my\nrhr was 52", "rhr", nil),
            ("Today:\n- rhr is 52", "rhr", 52)
        ]
        for row in rows {
            XCTAssertEqual(UserCorrectionDetector.detect(userMessages: [row.text]).assertedValues[row.key], row.value, row.text.debugDescription)
        }
    }

    /// A pace or distance keeps the unit it was given in: 8:30 per mile is
    /// not 8:30 per kilometer.
    func testPaceAndDistanceKeepTheirUnit() {
        let rows: [(text: String, line: String)] = [
            ("My pace was 8:30 per mile.", "- pace: 8:30 min/mi"),
            ("my pace is 5:15/km", "- pace: 5:15 min/km"),
            ("distance was 10 miles", "- distance: 10 mi"),
            ("my pace is 5:15", "- pace: 5:15")
        ]
        for row in rows {
            let block = UserCorrectionDetector.renderAssertedBlock(UserCorrectionDetector.detect(userMessages: [row.text])) ?? ""
            XCTAssertTrue(block.split(separator: "\n").contains { $0 == row.line }, "\(row.text): \(block)")
        }
    }

    /// "Stop telling me" is a data override only with data after it, or as
    /// the whole reply.
    func testStopSayingIsAnOverrideOnlyAboutTheNumbers() {
        let rows: [(text: String, override: Bool)] = [
            ("stop telling me to slow down every kilometer", false),
            ("stop saying great job after every split", false),
            ("stop saying my tsb is -20", true),
            ("stop telling me it's 45", true),
            ("quit repeating those numbers", true),
            ("no!!! stop saying that", true)
        ]
        for row in rows {
            XCTAssertEqual(UserCorrectionDetector.detect(userMessages: [row.text]).explicitOverrideRequested, row.override, row.text)
        }
    }

    /// A statement before the question in the same sentence is still stated;
    /// the question itself is not.
    func testAStatementBeforeAQuestionIsKept() {
        XCTAssertEqual(UserCorrectionDetector.detect(userMessages: ["my hrv is 38, why does the app say 45?"]).assertedValues["rmssd"], 38)
        for question in ["what was my hr at 5 am?", "is my hrv 38?", "why is my tsb -8, and is that bad?"] {
            XCTAssertTrue(UserCorrectionDetector.detect(userMessages: [question]).assertedValues.isEmpty, question)
        }
    }

    /// A number with a time unit after it is a duration, not the value.
    func testADurationIsNotAValue() {
        XCTAssertNil(UserCorrectionDetector.detect(userMessages: ["my recovery was 3 days"]).assertedValues["recovery"])
        XCTAssertNil(UserCorrectionDetector.detect(userMessages: ["my rmssd was 40 minutes after waking"]).assertedValues["rmssd"])
        XCTAssertEqual(UserCorrectionDetector.detect(userMessages: ["my hr is 150 for 20 minutes now"]).assertedValues["hr"], 150)
        XCTAssertEqual(UserCorrectionDetector.detect(userMessages: ["my sleep was 7.5 hours"]).assertedValues["sleep"], 7.5)
    }
}

/// A slash pair with no year is linked as a date only where it reads as one.
final class CitationFractionTests: XCTestCase {
    private func isFraction(_ text: String, _ match: String) throws -> Bool {
        let range = try XCTUnwrap(text.range(of: match))
        return AssistantCitationResolver.isBareFraction(text, range: range)
    }

    func testAFractionOrScoreIsNotADate() throws {
        XCTAssertTrue(try isFraction("You hit your sleep goal 4/5 nights.", "4/5"))
        XCTAssertTrue(try isFraction("I'd rate that session 4/5.", "4/5"))
    }

    func testADateIsStillADate() throws {
        XCTAssertFalse(try isFraction("On 11/24 your recovery was 55.", "11/24"))
        XCTAssertFalse(try isFraction("11/24: recovery 55", "11/24"))
        XCTAssertFalse(try isFraction("Since 4/5 your HRV has risen.", "4/5"))
        XCTAssertFalse(try isFraction("On 11/24/2026 you slept well.", "11/24/2026"))
    }
}
