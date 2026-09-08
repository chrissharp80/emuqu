@testable import Emuqu
import XCTest

/// Tests for the analysis-window selection method.
///
/// This enum decides which slice of a night a
/// recovery score is computed from, and it is persisted in every archived
/// session — so a changed raw value silently re-labels historical readings.
final class WindowSelectionMethodTests: XCTestCase {
    // MARK: - Persistence

    func testRawValuesAreStable() {
        // These strings are written into archived sessions. Changing one
        // re-labels every historical reading that used it, so they are pinned
        // here rather than left to a rename to quietly break.
        XCTAssertEqual(WindowSelectionMethod.consolidatedRecovery.rawValue, "consolidatedRecovery")
        XCTAssertEqual(WindowSelectionMethod.peakRMSSD.rawValue, "peakRMSSD")
        XCTAssertEqual(WindowSelectionMethod.peakSDNN.rawValue, "peakSDNN")
        XCTAssertEqual(WindowSelectionMethod.peakTotalPower.rawValue, "peakTotalPower")
        XCTAssertEqual(WindowSelectionMethod.custom.rawValue, "custom")
    }

    func testEveryCaseRoundTripsThroughItsRawValue() {
        for method in WindowSelectionMethod.allCases {
            XCTAssertEqual(WindowSelectionMethod(rawValue: method.rawValue), method)
        }
    }

    func testDecodingAnUnknownMethodFails() {
        // Better to reject an unknown method than to silently fall back to a
        // different window and present the resulting score as the same thing.
        XCTAssertNil(WindowSelectionMethod(rawValue: "peakSomethingElse"))
    }

    // MARK: - The automatic set

    func testCustomIsNotAnAutomaticMethod() {
        // `custom` means the user dragged the window themselves. Including it
        // in the automatic set would let the app pick a window it cannot
        // actually compute without user input.
        XCTAssertFalse(
            WindowSelectionMethod.automaticMethods.contains(.custom),
            "custom requires user input and cannot be selected automatically"
        )
    }

    func testAutomaticMethodsAreEveryCaseExceptCustom() {
        let expected = WindowSelectionMethod.allCases.filter { $0 != .custom }
        XCTAssertEqual(Set(WindowSelectionMethod.automaticMethods), Set(expected))
    }

    func testDefaultMethodIsAutomatic() {
        // The factory default must be something the app can compute unaided.
        XCTAssertTrue(
            WindowSelectionMethod.automaticMethods.contains(.defaultMethod),
            "the default must be selectable without user input"
        )
    }

    func testDefaultIsConsolidatedRecovery() {
        XCTAssertEqual(WindowSelectionMethod.defaultMethod, .consolidatedRecovery)
    }

    // MARK: - Presentation

    func testEveryCaseHasNonEmptyLabels() {
        // A missing localisation renders as a blank row in the window picker,
        // leaving the user unable to tell the options apart.
        for method in WindowSelectionMethod.allCases {
            XCTAssertFalse(method.displayName.isEmpty, "\(method.rawValue) has no display name")
            XCTAssertFalse(method.shortName.isEmpty, "\(method.rawValue) has no short name")
            XCTAssertFalse(method.tooltip.isEmpty, "\(method.rawValue) has no tooltip")
            XCTAssertFalse(method.icon.isEmpty, "\(method.rawValue) has no icon")
        }
    }

    func testDisplayNamesAreDistinct() {
        let names = WindowSelectionMethod.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "two methods share a display name")
    }

    func testShortNamesAreDistinct() {
        let names = WindowSelectionMethod.allCases.map(\.shortName)
        XCTAssertEqual(Set(names).count, names.count, "two methods share a short name")
    }
}
