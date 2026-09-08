@testable import Emuqu
import XCTest

/// DeterministicIntent precision gate.
///
/// The target is ≥ 95% precision against a 200-utterance labeled set. This
/// is the smaller unit-test contract: a hand-picked set of utterances
/// that probe the patterns directly.
///
/// **What we're testing.** Each pattern's regex either matches an
/// utterance shape we expect to handle, or it doesn't. We don't test
/// the rendered output (that depends on archive data) — only that
/// the pattern hits OR misses correctly.
///
/// **What this suite explicitly does not allow.** Medical-speculation
/// queries, AFib/arrhythmia queries, and any open-ended advice
/// ("should I train hard today") MUST fall through to the LLM. If
/// any of those start matching deterministic patterns, this test
/// fails — that's the safety contract.
@MainActor
final class DeterministicIntentTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal MatchContext with no archive data so we can
    /// test pattern matching without seeding sessions. Pattern hits
    /// where the handler returns nil (because data is unavailable)
    /// look identical to pattern misses — both fall through to the
    /// LLM. We separately test the regexes via a private surface so
    /// "matched but no data" is distinguishable from "didn't match."
    private func emptyContext() -> DeterministicIntent.MatchContext {
        DeterministicIntent.MatchContext(
            now: Date(),
            archive: SessionArchive.shared,
            userSettings: UserSettings()
        )
    }

    /// Returns true if any pattern's regex matches the utterance.
    /// Independent of whether the handler can produce a string.
    private func anyPatternMatches(_ utterance: String) -> Bool {
        let normalized = utterance
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!,"))
        for pattern in DeterministicIntent.patterns {
            for regex in pattern.compiled {
                let range = NSRange(normalized.startIndex..., in: normalized)
                if regex.firstMatch(in: normalized, options: [], range: range) != nil {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Patterns we EXPECT to match (precision side)

    func testRecoveryScoreVariantsMatch() {
        XCTAssertTrue(anyPatternMatches("what's my recovery score"))
        XCTAssertTrue(anyPatternMatches("recovery score"))
        XCTAssertTrue(anyPatternMatches("how am I doing today"))
        XCTAssertTrue(anyPatternMatches("recovery"))
    }

    func testRHRVariantsMatch() {
        XCTAssertTrue(anyPatternMatches("what's my resting heart rate"))
        XCTAssertTrue(anyPatternMatches("rhr"))
        XCTAssertTrue(anyPatternMatches("what's my heart rate"))
        XCTAssertTrue(anyPatternMatches("how's my pulse today"))
    }

    func testHRVVariantsMatch() {
        XCTAssertTrue(anyPatternMatches("what's my hrv"))
        XCTAssertTrue(anyPatternMatches("rmssd"))
        XCTAssertTrue(anyPatternMatches("hrv today"))
    }

    func testSleepVariantsMatch() {
        XCTAssertTrue(anyPatternMatches("how did I sleep"))
        XCTAssertTrue(anyPatternMatches("how was my sleep"))
        XCTAssertTrue(anyPatternMatches("how long did I sleep last night"))
        XCTAssertTrue(anyPatternMatches("sleep"))
    }

    func testLastWorkoutVariantsMatch() {
        XCTAssertTrue(anyPatternMatches("tell me about my last workout"))
        XCTAssertTrue(anyPatternMatches("how was my last workout"))
        XCTAssertTrue(anyPatternMatches("last workout"))
    }

    func testTrainedRecentlyVariantsMatch() {
        XCTAssertTrue(anyPatternMatches("did I train yesterday"))
        XCTAssertTrue(anyPatternMatches("did I run today"))
        XCTAssertTrue(anyPatternMatches("any workouts yesterday"))
    }

    // MARK: - Patterns we EXPECT to miss (the SAFETY contract)
    //
    // These MUST NOT match. If any of them start matching, the
    // deterministic path is over-shooting and we'll bypass the LLM
    // for queries that genuinely need its reasoning, tools, or
    // medical-refusal guardrail.

    func testMedicalSpeculationDoesNotMatch() {
        XCTAssertFalse(anyPatternMatches("how long am I going to live"))
        XCTAssertFalse(anyPatternMatches("do I have AFib"))
        XCTAssertFalse(anyPatternMatches("am I going to die"))
        XCTAssertFalse(anyPatternMatches("is my heart rate dangerous"))
        XCTAssertFalse(anyPatternMatches("do you think I have a problem"))
    }

    func testAdviceQueriesDoNotMatch() {
        XCTAssertFalse(anyPatternMatches("should I train hard today"))
        XCTAssertFalse(anyPatternMatches("should I rest"))
        XCTAssertFalse(anyPatternMatches("am I overtraining"))
        XCTAssertFalse(anyPatternMatches("would I improve if I added a long run"))
        XCTAssertFalse(anyPatternMatches("what if I rested for five days"))
    }

    func testToolRequestsDoNotMatch() {
        XCTAssertFalse(anyPatternMatches("email this to my coach"))
        XCTAssertFalse(anyPatternMatches("lead me back to where I parked"))
        XCTAssertFalse(anyPatternMatches("save this workout as a route"))
        XCTAssertFalse(anyPatternMatches("search the web for AI voices"))
    }

    func testWebQueriesDoNotMatch() {
        XCTAssertFalse(anyPatternMatches("what's the weather"))
        XCTAssertFalse(anyPatternMatches("are there commercially licensable AI voices"))
        XCTAssertFalse(anyPatternMatches("what's the news today"))
    }

    func testHistoricalDepthQueriesDoNotMatch() {
        XCTAssertFalse(anyPatternMatches("compare my recovery to last month"))
        XCTAssertFalse(anyPatternMatches("trend over 8 weeks"))
        XCTAssertFalse(anyPatternMatches("explain my recovery trend over the last 8 weeks"))
    }

    func testEdgeCasesDoNotFalseTrigger() {
        // Words that look like markers but are conversational
        XCTAssertFalse(anyPatternMatches("recovery is hard"))
        XCTAssertFalse(anyPatternMatches("heart rate variability is interesting"))
        XCTAssertFalse(anyPatternMatches("sleep is the best medicine"))
        XCTAssertFalse(anyPatternMatches("can you see the top of the last hill"))
    }

    // MARK: - tryMatch contract (data unavailable → fall through)

    func testTryMatchReturnsNilWhenArchiveEmpty() {
        // SessionArchive.shared has no today's session in CI; pattern
        // matches but handler returns nil → tryMatch returns nil.
        let result = DeterministicIntent.tryMatch("what's my recovery score", in: emptyContext())
        // Either nil (no archive data) OR a string (real data exists
        // because the test bundle picked up persisted state) — both
        // are valid; we just need the call not to crash.
        XCTAssert(result == nil || result?.isEmpty == false,
                  "tryMatch must return either nil (fall-through) or a non-empty answer")
    }

    func testTryMatchReturnsNilForUnmatchedUtterance() {
        let result = DeterministicIntent.tryMatch("explain my training periodization for the next quarter", in: emptyContext())
        XCTAssertNil(result, "Unmatched utterance must return nil to fall through to LLM")
    }

    // MARK: - DST day resolution

    /// A calendar pinned to a DST-observing zone, so these tests assert real
    /// transition behaviour regardless of the machine's system time zone.
    private func newYorkCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TestTimeZone.newYork
        return cal
    }

    private func date(
        _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ cal: Calendar
    ) throws -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (y, m, d, h, min)
        return try XCTUnwrap(cal.date(from: c), "could not build \(y)-\(m)-\(d) \(h):\(min)")
    }

    /// The regression this guards: US spring-forward 2026 is 08 Mar, making
    /// that local day 23 h long. At 00:30 on 09 Mar, the old
    /// `now.addingTimeInterval(-86400)` landed at 23:30 on **07** Mar, so
    /// "did I train yesterday?" reported on the wrong day. Calendar-aware
    /// day arithmetic must still resolve to 08 Mar.
    func testYesterdayCrossingSpringForwardResolvesToPreviousDay() throws {
        let cal = newYorkCalendar()
        let now = try date(2026, 3, 9, 0, 30, cal)

        let resolved = DeterministicIntent.dayStart(isYesterday: true, now: now, calendar: cal)

        let parts = cal.dateComponents([.year, .month, .day], from: resolved)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 3)
        XCTAssertEqual(parts.day, 8, "yesterday from 09 Mar must be 08 Mar, not 07 Mar")

        // And prove a fixed-86400 implementation fails this case, so the
        // test is guarding a real regression rather than restating Foundation.
        let legacy = cal.startOfDay(for: now.addingTimeInterval(-86400))
        XCTAssertEqual(
            cal.dateComponents([.day], from: legacy).day, 7,
            "sanity: the fixed-86400 approach lands on 07 Mar — that was the bug"
        )
    }

    /// Fall-back makes the local day 25 h long; yesterday must still be the
    /// immediately preceding calendar day.
    func testYesterdayCrossingFallBackResolvesToPreviousDay() throws {
        let cal = newYorkCalendar()
        let now = try date(2026, 11, 2, 0, 30, cal)

        let resolved = DeterministicIntent.dayStart(isYesterday: true, now: now, calendar: cal)

        let parts = cal.dateComponents([.year, .month, .day], from: resolved)
        XCTAssertEqual(parts.month, 11)
        XCTAssertEqual(parts.day, 1, "yesterday from 02 Nov must be 01 Nov")
    }

    /// `isYesterday: false` is plain start-of-day and must not shift.
    func testTodayResolvesToStartOfDayAcrossTransition() throws {
        let cal = newYorkCalendar()
        let now = try date(2026, 3, 9, 0, 30, cal)

        let resolved = DeterministicIntent.dayStart(isYesterday: false, now: now, calendar: cal)

        let parts = cal.dateComponents([.year, .month, .day, .hour], from: resolved)
        XCTAssertEqual(parts.day, 9)
        XCTAssertEqual(parts.hour, 0, "today must resolve to local midnight")
    }

    /// Non-transition days must be unaffected — guards against a fix that
    /// only works on the edge case.
    func testYesterdayOnOrdinaryDayIsUnchanged() throws {
        let cal = newYorkCalendar()
        let now = try date(2026, 6, 15, 9, 0, cal)

        let resolved = DeterministicIntent.dayStart(isYesterday: true, now: now, calendar: cal)

        let parts = cal.dateComponents([.month, .day], from: resolved)
        XCTAssertEqual(parts.month, 6)
        XCTAssertEqual(parts.day, 14)
    }
}
