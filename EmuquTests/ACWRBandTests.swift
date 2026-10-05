@testable import Emuqu
import XCTest

/// The Training Load screen and the PDF report once described the same
/// acute:chronic ratio with different bands (five on screen, four in the PDF).
/// Both now read `ACWRBand`; these tests pin its edges and that the PDF text
/// carries the same label the screen shows.
@MainActor
final class ACWRBandTests: XCTestCase {
    func testBandEdgesMatchTheTrainingLoadScreen() {
        XCTAssertEqual(ACWRBand(ratio: 0.0), .belowUsual)
        XCTAssertEqual(ACWRBand(ratio: 0.79), .belowUsual)
        XCTAssertEqual(ACWRBand(ratio: 0.8), .maintenance)
        XCTAssertEqual(ACWRBand(ratio: 1.0), .maintenance)
        XCTAssertEqual(ACWRBand(ratio: 1.01), .inRange)
        XCTAssertEqual(ACWRBand(ratio: 1.3), .inRange)
        XCTAssertEqual(ACWRBand(ratio: 1.31), .aboveUsual)
        XCTAssertEqual(ACWRBand(ratio: 1.5), .aboveUsual)
        XCTAssertEqual(ACWRBand(ratio: 1.51), .sharpIncrease)
        XCTAssertEqual(ACWRBand(ratio: 3.0), .sharpIncrease)
    }

    func testThereAreFiveBandsInGaugeOrder() {
        XCTAssertEqual(
            ACWRBand.allCases,
            [.belowUsual, .maintenance, .inRange, .aboveUsual, .sharpIncrease]
        )
    }

    func testEveryBandHasDistinctNonEmptyCopy() {
        let labels = ACWRBand.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, ACWRBand.allCases.count)
        for band in ACWRBand.allCases {
            XCTAssertFalse(band.label.isEmpty)
            XCTAssertFalse(band.detail.isEmpty)
            XCTAssertFalse(band.rangeText.isEmpty)
        }
    }

    func testPDFInterpretationUsesTheScreenBandLabel() {
        let renderer = DeepDiveReportRenderer(
            generator: PDFReportGenerator(settingsProvider: { UserSettings() })
        )
        for ratio in [0.5, 0.9, 1.1, 1.4, 1.8] {
            let band = ACWRBand(ratio: ratio)
            let text = renderer.interpretACWR(ratio)
            XCTAssertTrue(text.contains(band.label), "\(ratio): \(text)")
            XCTAssertTrue(text.contains(band.detail), "\(ratio): \(text)")
        }
    }

    func testPDFNoLongerUsesTheOldFourBandWording() {
        let renderer = DeepDiveReportRenderer(
            generator: PDFReportGenerator(settingsProvider: { UserSettings() })
        )
        // 0.9 was "Within your usual" under the old 0.8–1.3 band.
        XCTAssertFalse(renderer.interpretACWR(0.9).contains("Within your usual"))
        XCTAssertFalse(renderer.interpretACWR(1.8).contains("Sharp recent increase"))
    }
}
