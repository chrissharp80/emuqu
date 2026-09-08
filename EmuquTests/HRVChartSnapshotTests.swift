@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for the three HRV visualisations.
///
/// These are the core science display of the app — the tachogram, the Poincaré
/// plot and the overnight heart-rate chart — and each is ~600 lines that
/// no other test reaches. They take only a session and an analysis
/// result, which is what makes them cheap to pin down.
///
/// Every input is frozen: the RR series is generated from a closed-form
/// function of the beat index, so the same picture is produced on every machine
/// and every day.
@MainActor
final class HRVChartSnapshotTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_622_534_400)
    /// Fixed so nothing derived from the id can vary between runs.
    private static let fixedSessionId =
        UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE") ?? UUID()

    /// A physiologically plausible overnight series: a slow respiratory sway,
    /// a gentle downward HR drift through the night, and two ectopic beats so
    /// the artifact handling has something to draw.
    private func makeSeries(beats: Int = 600) -> RRSeries {
        var t: Int64 = 0
        var points: [RRPoint] = []
        for i in 0 ..< beats {
            let phase = Double(i) / 12.0
            let drift = 60.0 * (Double(i) / Double(beats))
            var rr = 950.0 + drift + 45.0 * sin(phase)
            if i == 200 || i == 401 { rr *= 0.55 }  // ectopic
            let ms = Int(rr.rounded())
            points.append(RRPoint(t_ms: t, rr_ms: ms))
            t += Int64(ms)
        }
        return RRSeries(
            points: points,
            sessionId: Self.fixedSessionId,
            startDate: anchor
        )
    }

    private func makeResult() -> HRVAnalysisResult {
        var result = HRVAnalysisResult(
            windowStart: 100, windowEnd: 400,
            timeDomain: TimeDomainMetrics(
                meanRR: 60_000.0 / 58.0, sdnn: 54.0, rmssd: 45.0, pnn50: 20.0,
                sdsd: 42.75, meanHR: 58.0, sdHR: 3.0, triangularIndex: 12.0
            ),
            frequencyDomain: FrequencyDomainMetrics(
                vlf: 500, lf: 800, hf: 666.67, lfHfRatio: 1.2, totalPower: 2100
            ),
            nonlinear: NonlinearMetrics(
                sd1: 32.0, sd2: 48.0, sd1Sd2Ratio: 0.67,
                sampleEntropy: 1.5, approxEntropy: 1.2,
                dfaAlpha1: 0.95, dfaAlpha2: 0.85, dfaAlpha1R2: 0.95
            ),
            ansMetrics: ANSMetrics(
                stressIndex: 120, pnsIndex: 1.5, snsIndex: -0.5,
                readinessScore: 7.0, respirationRate: 14.0,
                nocturnalHRDip: 12.0, daytimeRestingHR: 65.0, nocturnalMedianHR: 57.0
            ),
            artifactPercentage: 3.0,
            cleanBeatCount: 290,
            // Frozen: `Date()` here would repaint any rendered timestamp daily.
            analysisDate: anchor
        )
        result.isConsolidated = true
        result.isOrganizedRecovery = true
        result.windowHRStability = 0.04
        return result
    }

    private func makeSession() -> HRVSession {
        var session = HRVSession(startDate: anchor, sessionType: .overnight)
        session.endDate = anchor.addingTimeInterval(8 * 3600)
        session.state = .complete
        session.rrSeries = makeSeries()
        session.analysisResult = makeResult()
        return session
    }

    func testTachogramRenders() {
        assertSnapshot(
            of: TachogramView(session: makeSession(), result: makeResult()),
            named: "chart-tachogram"
        )
    }

    func testPoincarePlotRenders() {
        assertSnapshot(
            of: PoincarePlotView(session: makeSession(), result: makeResult()),
            named: "chart-poincare"
        )
    }

    func testHeartRateChartRenders() {
        assertSnapshot(
            of: HeartRateChartView(session: makeSession(), result: makeResult()),
            named: "chart-heart-rate"
        )
    }

    /// The open-source notice screen is a distribution requirement, and its
    /// contents are checked against `Package.resolved` by `check_sbom_drift`.
    /// This pins that it still renders.
    func testAcknowledgementsRenders() {
        assertSnapshot(of: AcknowledgementsView(), named: "screen-acknowledgements")
    }
}
