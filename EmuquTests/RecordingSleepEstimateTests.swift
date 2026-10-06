@testable import Emuqu
import XCTest

/// A night with no Apple Health sleep: the Overnight PDF and the Overnight
/// screen read one recording-length estimate, and neither invents deep sleep.
@MainActor
final class RecordingSleepEstimateTests: XCTestCase {
    private func renderer() -> OvernightReportRenderer {
        OvernightReportRenderer(generator: PDFReportGenerator(settingsProvider: { UserSettings() }))
    }

    func testFullNightEstimateIsNinetyPercentOfTheRecording() {
        let estimate = RecordingSleepEstimate(recordingMinutes: 480)
        XCTAssertEqual(estimate.asleepMinutes, 432)
        XCTAssertEqual(estimate.efficiencyPercent, 90, accuracy: 0.001)
    }

    func testShortRecordingEstimateIsEightyFivePercent() {
        XCTAssertEqual(RecordingSleepEstimate(recordingMinutes: 150).asleepMinutes, 127)
    }

    func testEmptyRecordingEstimatesNothing() {
        let estimate = RecordingSleepEstimate(recordingMinutes: 0)
        XCTAssertEqual(estimate.asleepMinutes, 0)
        XCTAssertEqual(estimate.efficiencyPercent, 0)
    }

    /// The PDF printed "Est. Deep 1h 26m" (20 % of 432 min) for an 8 h night
    /// with no Apple Health sleep, while the screen showed no deep card.
    func testPDFWithoutAppleHealthSleepPrintsNoDeepSleep() {
        for minutes in [480, 150] {
            let stats = renderer().computeOvernightSleepStats(sleepData: nil, durationMinutes: minutes)
            XCTAssertNil(stats.deepSleepMinutes, "\(minutes) min")
            XCTAssertEqual(stats.deepFormatted, reportMissingValue)
            XCTAssertEqual(stats.sleepMinutes, RecordingSleepEstimate(recordingMinutes: minutes).asleepMinutes)
        }
    }

    /// `SleepData.empty` is what the PDF gets when Apple Health has nothing.
    func testPDFWithEmptyAppleHealthSleepUsesTheSharedEstimate() {
        let stats = renderer().computeOvernightSleepStats(sleepData: .empty, durationMinutes: 480)
        XCTAssertEqual(stats.sleepMinutes, 432)
        XCTAssertNil(stats.deepSleepMinutes)
    }

    func testPDFKeepsMeasuredDeepSleep() {
        let sleep = PDFReportGenerator.SleepData(
            totalSleepMinutes: 420, inBedMinutes: 460, deepSleepMinutes: 75,
            remSleepMinutes: 90, awakeMinutes: 20, sleepEfficiency: 91
        )
        let stats = renderer().computeOvernightSleepStats(sleepData: sleep, durationMinutes: 480)
        XCTAssertEqual(stats.sleepMinutes, 420)
        XCTAssertEqual(stats.deepSleepMinutes, 75)
    }

    func testPDFLeavesUnmeasuredDeepSleepNil() {
        let sleep = PDFReportGenerator.SleepData(
            totalSleepMinutes: 420, inBedMinutes: 460, deepSleepMinutes: nil,
            remSleepMinutes: nil, awakeMinutes: 20, sleepEfficiency: nil
        )
        let stats = renderer().computeOvernightSleepStats(sleepData: sleep, durationMinutes: 480)
        XCTAssertNil(stats.deepSleepMinutes)
        XCTAssertEqual(stats.deepFormatted, reportMissingValue)
    }
}
