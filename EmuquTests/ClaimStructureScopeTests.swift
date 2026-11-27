@testable import Emuqu
import XCTest

/// A claim's referent is set by the structure around it, not only by its
/// sentence: the heading or bold label over it, the lead-in its list or table
/// hangs from, the item it is nested under, its table column's header and row
/// label, and the line before when a sentence wraps. A number under a past
/// night's heading is that night's, and rewriting it to today's value writes a
/// false history and tells the model it fabricated a true one.
@MainActor
final class ClaimStructureScopeTests: XCTestCase {
    private let score10 = 9.1

    override func setUp() async throws {
        try await super.setUp()
        MetricsVerifier.clearCorrections()
    }

    override func tearDown() async throws {
        MetricsVerifier.clearCorrections()
        try await super.tearDown()
    }

    /// Each shape of markdown that places a recovery score on another night.
    private let pastNightRecoveryRows = [
        "## Night before (Nov 25)\n- Recovery score: 55",
        "Night before (Nov 25)\n- Recovery score: 55",
        "### Nov 25\n\nYour recovery score is 55.",
        "**Nov 25**\n- Recovery score: 55",
        "**Nov 25**\nRecovery score: 55",
        "**Nov 25:** Recovery score 55",
        "Last week:\n1. Recovery 55\n2. Recovery 61",
        "- Tuesday\n  - Recovery 55",
        "| Metric | Yesterday |\n|---|---|\n| Recovery | 55 |",
        "| Night | Score |\n|---|---|\n| Nov 25 | Recovery 55 |",
        "Two nights ago your\nrecovery is 55.",
        "## Today\nRecovery is 91.\n## Nov 25\n- Recovery 55"
    ]

    func testAPastNightsScoreUnderItsHeadingIsLeftAlone() {
        for text in pastNightRecoveryRows {
            XCTAssertTrue(
                MetricsVerifier.recoveryScoreClaims(in: text, score10: score10).isEmpty,
                "Rewrote another night's score: \(text.debugDescription)"
            )
        }
    }

    /// The same shapes placing the score on today are still checked, so the
    /// structure narrows nothing it should not.
    private let todayRecoveryRows = [
        "## Today\n- Recovery score: 55",
        "**This morning**\n- Recovery score: 55",
        "- **Recovery score:** 55",
        "| Metric | Today |\n|---|---|\n| Recovery | 55 |",
        "## Nov 25\n- Recovery 61\n\n## Today\n- Recovery 55",
        "Your recovery\nscore is 55."
    ]

    func testTodaysScoreInTheSameShapesIsStillChecked() {
        for text in todayRecoveryRows {
            let found = MetricsVerifier.recoveryScoreClaims(in: text, score10: score10)
            XCTAssertEqual(found.map(\.actual), ["91"], "Missed today's score: \(text.debugDescription)")
            XCTAssertEqual(found.first.map { String(text[$0.range]) }, "55", "Wrong span in \(text.debugDescription)")
        }
    }

    /// "85/100" is the form the prompt's own live state uses. The slash names
    /// the scale; it is not the other end of a range.
    func testAScoreWithItsScaleIsChecked() {
        let rows: [(String, String?)] = [
            ("Recovery 85/100.", "91"),
            ("Your recovery score is 55 / 100.", "91"),
            ("Recovery 8/100.", "91"),
            ("Recovery 5/10.", "9.1"),
            ("Recovery 5 out of 10.", "9.1"),
            ("Recovery 91/100.", nil),
            ("Recovery 9/10.", nil),
            ("Recovery 60-70 is fine.", nil)
        ]
        for (text, actual) in rows {
            XCTAssertEqual(MetricsVerifier.recoveryScoreClaims(in: text, score10: score10).first?.actual, actual, text)
        }
    }

    func testTrainingLoadUnderAPastHeadingIsLeftAlone() {
        let past = ["## Last week\n- TSB: -5", "Before your race:\n- TSB -5", "| Metric | Monday |\n|---|---|\n| TSB | -5 |"]
        for text in past {
            XCTAssertTrue(MetricsVerifier.trainingLoadClaims(in: text, tsb: -20, atl: 40, ctl: 42, acwr: nil).isEmpty, text)
        }
        let today = ["## Today\n- **TSB:** -5", "| Load | Now |\n|---|---|\n| TSB | -5 |"]
        for text in today {
            XCTAssertEqual(MetricsVerifier.trainingLoadClaims(in: text, tsb: -20, atl: 40, ctl: 42, acwr: nil).map(\.metric), ["TSB"], text)
        }
    }

    func testSleepUnderAnotherNightsHeadingIsLeftAlone() {
        let other = ["## Sleep on Nov 25\n- You slept 5 hours and 10 minutes", "**Tuesday**\n- Sleep: 5h 10m"]
        for text in other {
            XCTAssertTrue(MetricsVerifier.sleepDiscrepancies(in: text, nightMinutes: 415, efficiency: 95).isEmpty, text)
        }
        let lastNight = "## Last night\n- You slept 5 hours and 10 minutes"
        XCTAssertEqual(MetricsVerifier.sleepDiscrepancies(in: lastNight, nightMinutes: 415, efficiency: 95).first?.actual, "6 hours and 55 minutes")
        let efficiency = "## Sleep\n- Efficiency: 80%"
        XCTAssertEqual(MetricsVerifier.sleepDiscrepancies(in: efficiency, nightMinutes: 415, efficiency: 95).first?.actual, "95%")
    }

    func testAnotherReadingsRMSSDUnderItsHeadingIsLeftAlone() {
        XCTAssertTrue(MetricsVerifier.rmssdClaims(in: "## Your nap\n- RMSSD 31 ms", rmssd: 48).isEmpty)
        XCTAssertEqual(MetricsVerifier.rmssdClaims(in: "## Overnight\n- RMSSD 31 ms", rmssd: 48).first?.actual, "48 ms")
    }

    // MARK: - A heading in an earlier piece of a streamed reply

    private func live(heartRate: Int) -> AssistantContext.LiveWorkoutSnapshot {
        AssistantContext.LiveWorkoutSnapshot(
            sport: "Run", snapshotAt: Date(), sessionStartAt: Date().addingTimeInterval(-840), elapsedSeconds: 840, heartRate: heartRate, peakHR: heartRate, userMaxHR: 188,
            beatCount: 2_200, distanceMeters: 2_500, stepCount: 2_350, cadenceStepsPerMin: 168, elevationGainMeters: 18,
            alpha1: nil, alpha1Band: "Unknown", alpha1Status: "warmup", alpha1FitQualityR2: nil, strapConnected: true, strapSilentSec: nil,
            gpsFixCount: 84, gpsAccuracyMeters: 5, currentPaceSecPerKm: 330, currentSpeedMS: 2.9, powerWatts: nil, currentMETs: nil,
            recentSplitPaces: [328, 331], currentLatitude: nil, currentLongitude: nil, currentAltitudeMeters: nil,
            currentHeadingDegrees: nil, currentHeadingCardinal: nil, currentGradePercent: nil, unitsPreference: "metric", targetZone: nil
        )
    }

    private func state(heartRate: Int) -> MetricsVerifier.AppState {
        var state = ChatServices(.current).verifiedAppState
        state.liveWorkout = live(heartRate: heartRate)
        return state
    }

    /// The heading arrives in one piece and the bullet in the next; the
    /// bullet is read under the heading.
    func testAHeadingInAnEarlierPieceSetsTheReferent() {
        let past = MetricsVerifier.verifyReply("- Your HR is 150 bpm.\n", after: "## Yesterday's run\n", against: state(heartRate: 162))
        XCTAssertNil(past.correctedText)
        XCTAssertTrue(past.discrepancies.isEmpty)
        let now = MetricsVerifier.verifyReply("- Your HR is 150 bpm.\n", after: "## Your run\n", against: state(heartRate: 162))
        XCTAssertEqual(now.correctedText, "- Your HR is 162 bpm.\n")
    }

    /// Only the new piece is checked and returned: a claim already shown is
    /// not checked again or returned with it.
    func testOnlyTheNewPieceIsCheckedAndReturned() {
        let result = MetricsVerifier.verifyReply(" Hold it there for 10 minutes.", after: "Your HR is 150 bpm.", against: state(heartRate: 162))
        XCTAssertNil(result.correctedText)
        XCTAssertTrue(result.discrepancies.isEmpty)
    }

    func testTheStreamBufferReadsTheReplyAlreadyShown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClaimScope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AssistantViewModel(
            services: ChatServices(.current),
            store: ConversationStore(fileURL: directory.appendingPathComponent("chat.json")),
            factsStore: UserFactsStore(fileURL: directory.appendingPathComponent("facts.json"))
        )
        let turn = ChatTurn(role: .assistant, text: "")
        model.turns.append(turn)
        let snapshot = state(heartRate: 162)
        let buffer = StreamTextBuffer(owner: model, turnID: turn.id) { snapshot }
        for delta in ["Yesterday's run:\n", "- Your HR is 150 bpm.\n", "- Your HR is 150 bpm."] {
            try await Task.sleep(for: .milliseconds(40))
            buffer.append(chunk: delta, thisRoundIsEmpty: true)
        }
        buffer.flush(force: true, thisRoundIsEmpty: true)
        buffer.commitCorrections()
        XCTAssertEqual(model.turns.first { $0.id == turn.id }?.text, "Yesterday's run:\n- Your HR is 150 bpm.\n- Your HR is 150 bpm.")
        XCTAssertNil(MetricsVerifier.consumePendingCorrectionsBlock(), "A true past value was reported as a fabrication")
    }

    func testTheSpokenReplyStartsAfreshOnReset() {
        let chunker = SpokenTextChunker()
        chunker.verifiedReply = "Yesterday's run\n"
        chunker.reset()
        XCTAssertEqual(chunker.verifiedReply, "")
    }

    // MARK: - Line kinds

    func testEachLineIsReadAsItsKind() {
        let rows: [(String, MetricsVerifier.ScopeLineKind)] = [
            ("", .blank), ("## Nov 25", .heading), ("**Nov 25**", .label), ("__Nov 25__:", .label),
            ("On Nov 25:", .leadIn), ("- Recovery 55", .listItem), ("12) Recovery 55", .listItem), ("• Recovery 55", .listItem),
            ("| a | b |", .tableRow), ("|---|:--:|", .tableRule), ("**Recovery:** 55", .text), ("Recovery 55.", .text)
        ]
        for (line, kind) in rows {
            XCTAssertEqual(MetricsVerifier.lineKind(line), kind, line)
        }
    }
}
