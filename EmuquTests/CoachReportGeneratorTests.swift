@testable import Emuqu
import os
import XCTest

/// Tests for `CoachReportGenerator` — the conversational summary that becomes
/// the body of the auto Coach Report email.
///
/// The entry point is a nonisolated function from `(HRVSession,
/// [HRVSession], UnitsPreference, Int, Int)` to `String`, so it is tested
/// directly. It is user-facing prose about health: a unit conversion that
/// reports kilometres as miles is wrong advice rather than a cosmetic defect.
///
/// The assertions target structure, not exact wording, so the copy can be
/// edited (including by `Tools/copy_linter`) without the suite turning red for
/// a non-defect.
final class CoachReportGeneratorTests: XCTestCase {
    /// Capture-and-restore; `NSTimeZone.default` is
    /// process-global, so a suite that sets it leaves it on UTC for whoever
    /// runs next. The report formats dates, so it is sensitive to this.
    private static let savedDefaultTimeZone = OSAllocatedUnfairLock<TimeZone?>(initialState: nil)

    override class func setUp() {
        super.setUp()
        savedDefaultTimeZone.withLock { $0 = NSTimeZone.default }
        NSTimeZone.default = TestTimeZone.utc
    }

    override class func tearDown() {
        if let saved = savedDefaultTimeZone.withLock({ $0 }) { NSTimeZone.default = saved }
        savedDefaultTimeZone.withLock { $0 = nil }
        super.tearDown()
    }

    // MARK: - Units

    func testUnitsPreferenceSwitchesTheDistanceUnit() {
        let metric = summary(makeSession(), units: .metric)
        let imperial = summary(makeSession(), units: .imperial)

        XCTAssertTrue(metric.contains("km"), "metric summary should quote kilometres")
        XCTAssertFalse(metric.contains(" mi,"), "metric summary must not quote miles")
        XCTAssertTrue(imperial.contains("mi"), "imperial summary should quote miles")
        XCTAssertNotEqual(metric, imperial, "the unit preference must actually change the output")
    }

    // MARK: - Conversational summary

    func testConversationalSummaryIsProseNotMarkdownHeadings() {
        let summary = CoachReportGenerator.renderConversationalSummary(
            session: makeSession(),
            pastWorkouts: [],
            units: .metric,
            userMaxHR: 185,
            userRestingHR: 48
        )

        XCTAssertFalse(summary.isEmpty)
        XCTAssertFalse(summary.contains("## "), "the email body is prose — no section headings")
        XCTAssertFalse(summary.contains("# Coach Report"), "the Markdown title belongs to the PDF report only")
    }

    func testConversationalSummaryWithoutMetadataStillReturnsSomething() {
        var session = HRVSession(startDate: Self.start, sessionType: .overnight)
        session.workoutMetadata = nil

        let summary = CoachReportGenerator.renderConversationalSummary(
            session: session,
            pastWorkouts: [],
            units: .metric,
            userMaxHR: 185,
            userRestingHR: 48
        )

        XCTAssertTrue(summary.contains("nothing to report on"))
    }

    // MARK: - Determinism

    func testSummaryIsDeterministicForTheSameInput() {
        // If this ever fails, something is reading ambient state (a live
        // archive, a singleton, a random tiebreak) that a report generator
        // has no business reading.
        let a = summary(makeSession(), past: [makeSession(offsetDays: -3)])
        let b = summary(makeSession(), past: [makeSession(offsetDays: -3)])
        XCTAssertEqual(a, b)
    }

    // MARK: - Fixtures

    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func summary(
        _ session: HRVSession,
        past: [HRVSession] = [],
        units: UnitsPreference = .metric
    ) -> String {
        CoachReportGenerator.renderConversationalSummary(
            session: session,
            pastWorkouts: past,
            units: units,
            userMaxHR: 185,
            userRestingHR: 48
        )
    }

    private func makeSession(offsetDays: Int = 0) -> HRVSession {
        let start = Self.start.addingTimeInterval(Double(offsetDays) * 86_400)
        var session = HRVSession(startDate: start, sessionType: .workout)
        session.endDate = start.addingTimeInterval(3600)

        let timeDomain = TimeDomainMetrics(
            meanRR: 1000, sdnn: 55, rmssd: 42.5, pnn50: 20,
            sdsd: 38, meanHR: 142, sdHR: 5, triangularIndex: nil
        )
        let nonlinear = NonlinearMetrics(
            sd1: 30, sd2: 60, sd1Sd2Ratio: 0.5, sampleEntropy: 1.5,
            approxEntropy: 1.3, dfaAlpha1: 0.9, dfaAlpha2: nil, dfaAlpha1R2: 0.95
        )
        session.analysisResult = HRVAnalysisResult(
            windowStart: 0, windowEnd: 500, timeDomain: timeDomain,
            frequencyDomain: nil, nonlinear: nonlinear, ansMetrics: nil,
            artifactPercentage: 2.0, cleanBeatCount: 500, analysisDate: start
        )

        var metadata = WorkoutMetadata(sport: .run)
        metadata.distanceMeters = 10_000
        metadata.elevationGainMeters = 180
        metadata.luciaTRIMP = 137.5
        metadata.samples = (0 ..< 12).map(Self.sample(at:))
        session.workoutMetadata = metadata
        return session
    }

    /// One synthetic tick.
    ///
    /// Every value is bound to an explicitly-typed `let` rather than written
    /// inline. As inline literal arithmetic (`140 + i`,
    /// `250 + Double(i) * 4`) inside a `map` whose return type also had to be
    /// inferred, this hits "the compiler is unable to type-check this expression
    /// in reasonable time" on the CI runner while still compiling locally. The
    /// annotations leave the solver nothing to search.
    private static func sample(at i: Int) -> WorkoutSample {
        let offsetSec: Int = i * 300
        let heartRate: Int = 140 + i
        let distance: Double = Double(i) * 850
        let pace: Double = 300 + Double(i)
        let altitude: Double = 250 + Double(i) * 4
        return WorkoutSample(
            offsetSec: offsetSec,
            heartRate: heartRate,
            distanceMeters: distance,
            paceSecPerKm: pace,
            cadenceStepsPerMin: 172,
            altitudeMeters: altitude,
            alpha1: 0.75,
            mets: 9.5
        )
    }
}
