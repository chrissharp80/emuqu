@testable import Emuqu
import XCTest

/// The heart rate a report shows as the night's average, minimum and maximum
/// is the whole recording's, not the analysis window's: the window is a few
/// minutes of the calmest sleep and barely moves from night to night.
final class RecordingHeartRateTests: XCTestCase {
    private func result(windowMeanHR: Double = 64) -> HRVAnalysisResult {
        HRVAnalysisResult(
            windowStart: 0, windowEnd: 10,
            timeDomain: TimeDomainMetrics(
                meanRR: 60_000 / windowMeanHR, sdnn: 60, rmssd: 50, pnn50: 20, sdsd: 45,
                meanHR: windowMeanHR, sdHR: 5, triangularIndex: nil
            ),
            frequencyDomain: nil,
            nonlinear: NonlinearMetrics(
                sd1: 30, sd2: 60, sd1Sd2Ratio: 0.5, sampleEntropy: 1.5,
                approxEntropy: 1.3, dfaAlpha1: 0.9, dfaAlpha2: nil, dfaAlpha1R2: 0.95
            ),
            ansMetrics: nil, artifactPercentage: 2, cleanBeatCount: 500, analysisDate: Date()
        )
    }

    func testTheAverageIsTheWholeRecordingWhenItIsKnown() {
        var night = result(windowMeanHR: 64)
        night.overnightMeanHR = 73
        night.overnightMinHR = 58
        night.overnightMaxHR = 112
        XCTAssertEqual(night.recordingMeanHR, 73)
        XCTAssertEqual(night.recordingMinHR, 58)
        XCTAssertEqual(night.recordingMaxHR, 112)
        XCTAssertEqual(night.timeDomain.meanHR, 64, "the window mean the baseline uses is unchanged")
    }

    func testAnOlderResultFallsBackToTheWindow() {
        let night = result(windowMeanHR: 64)
        XCTAssertEqual(night.recordingMeanHR, 64)
        XCTAssertEqual(night.recordingMinHR, night.timeDomain.minHR)
        XCTAssertEqual(night.recordingMaxHR, night.timeDomain.maxHR)
    }
}
