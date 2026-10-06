@testable import Emuqu
import XCTest

/// The recovery card's message on Flo's context and the PDF, and the live
/// load's monotony, all reach the shared training advice gate.
///
/// Before, the morning card, the PDF breakdown and Flo's "note:" line printed
/// `breakdown.message`, which takes no load, so a 92 under a 1.99 acute:chronic
/// ratio still said "Go hard" there while the steps beneath it said to ease
/// off; and the live load handed the gate no monotony, so a heavy week of
/// identical sessions never held the push on a "right now" surface.
@MainActor
final class TrainingAdviceSurfaceTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        pinEnglishLanguage()
    }

    private let heavy = TrainingContext(
        atl: 79.6, ctl: 40, tsb: -39.6, yesterdayTrimp: 80, vo2Max: nil, daysSinceHardWorkout: 1, recentWorkouts: nil
    )
    private let clear = TrainingContext(
        atl: 40, ctl: 40, tsb: 0, yesterdayTrimp: 40, vo2Max: nil, daysSinceHardWorkout: 4, recentWorkouts: nil
    )

    private func liveLoad(acwr: Double, monotony: Double? = nil, strain: Double? = nil) -> TrainingLoadRegistry.TrainingLoad {
        TrainingLoadRegistry.TrainingLoad(
            atl: acwr * 40, ctl: 40, tsb: 40 - acwr * 40, acwr: acwr, todayTrimp: nil,
            provenance: .live(asOf: Date()), monotony: monotony, strain: strain
        )
    }

    private func strongBreakdown() -> RecoveryScoreCalculator.ScoreBreakdown {
        let factors = ["HRV", "Sleep", "Vitals"].map {
            RecoveryScoreCalculator.ScoreFactor(label: $0, detail: "", score: 92, weight: 1.0 / 3, impact: .positive)
        }
        return RecoveryScoreCalculator.ScoreBreakdown(compositeScore: 92, tier: 3, factors: factors, penalties: [])
    }

    private func night(endingDaysAgo days: Double, frozen: TrainingContext) -> HRVSession {
        let end = Date().addingTimeInterval(-days * 86_400)
        var session = HRVSession(
            id: UUID(), startDate: end.addingTimeInterval(-8 * 3_600), endDate: end,
            state: .complete, sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        session.recoveryScore = 9.2
        session.scoreBreakdown = strongBreakdown()
        session.trainingSnapshot = frozen
        return session
    }

    // MARK: - Flo's score note

    /// Today's note reads the live load: frozen clear, live at ACWR 1.99.
    func testFloTodayNoteReadsTheLiveLoad() throws {
        let today = night(endingDaysAgo: 0, frozen: clear)
        let context = ContextBuilder.build(
            latestSession: today, recentSessions: [today], userSettings: UserSettings(),
            liveLoadSnapshot: liveLoad(acwr: 1.99)
        )
        let note = try XCTUnwrap(context.today?.scoreMessage)
        XCTAssertFalse(note.contains("Go hard"), note)
        XCTAssertTrue(note.contains("an easier session"), note)
    }

    /// A past night's note reads the load frozen with it, not today's.
    func testFloPastNoteReadsItsFrozenLoad() throws {
        let past = night(endingDaysAgo: 3, frozen: heavy)
        let context = ContextBuilder.build(
            latestSession: past, recentSessions: [past], userSettings: UserSettings(),
            liveLoadSnapshot: liveLoad(acwr: 1.0)
        )
        let note = try XCTUnwrap(context.today?.scoreMessage)
        XCTAssertTrue(note.contains("an easier session"), note)
        XCTAssertEqual(context.recent.first?.scoreMessage, note)
    }

    // MARK: - PDF breakdown message

    func testPDFBreakdownMessageReadsTheReportsTrainingLoad() {
        let session = night(endingDaysAgo: 3, frozen: heavy)
        let inputs = PDFReportGenerator.ReportInputs(
            session: session, result: TrainingAdviceSurfaceTests.emptyResult, series: nil, artifactFlags: [],
            hasRawData: false, sleepData: nil, sleepTrend: nil, recentSessions: [], healthKitHR: nil,
            vitals: nil, compositeRecoveryScore: 92, scoreBreakdown: strongBreakdown(), baselineStats: nil,
            trainingContext: heavy, style: .comprehensive, sections: .all
        )
        XCTAssertEqual(PDFReportGenerator().adviceLoadLevel(inputs), .easier)
    }

    private static let emptyResult = HRVAnalysisResult(
        windowStart: 0, windowEnd: 10,
        timeDomain: TimeDomainMetrics(
            meanRR: 1_000, sdnn: 60, rmssd: 50, pnn50: 20, sdsd: 45, meanHR: 58, sdHR: 5, triangularIndex: nil
        ),
        frequencyDomain: nil,
        nonlinear: NonlinearMetrics(
            sd1: 30, sd2: 60, sd1Sd2Ratio: 0.5, sampleEntropy: 1.5,
            approxEntropy: 1.3, dfaAlpha1: 0.9, dfaAlpha2: nil, dfaAlpha1R2: 0.95
        ),
        ansMetrics: nil, artifactPercentage: 2, cleanBeatCount: 500, analysisDate: Date()
    )

    // MARK: - Monotony on the live load

    /// Monotony 2.5 with strain 2,000 is Foster's warning; the live load now
    /// carries it to the gate, which holds the push.
    func testLiveLoadMonotonyHoldsThePush() {
        let monotonous = liveLoad(acwr: 1.0, monotony: 2.5, strain: 2_000)
        XCTAssertEqual(TrainingAdviceGate.level(.init(live: monotonous)), .holdPush)
        XCTAssertEqual(TrainingAdviceGate.level(.init(live: liveLoad(acwr: 1.0))), .clear)
    }
}
