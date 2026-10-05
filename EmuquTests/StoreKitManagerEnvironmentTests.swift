@testable import Emuqu
import StoreKit
import XCTest

/// What a verified `AppTransaction` environment does to the
/// developer-install route.
final class StoreKitManagerEnvironmentTests: XCTestCase {
    /// The defect this pins: a sandbox install, which is what App Review
    /// runs, was anchored as a beta tester and never met the paywall. Sandbox
    /// now changes nothing, so a reviewer meets the customer's paywall and
    /// unlocks only through the sandbox trial or purchase.
    func testSandboxGrantsNothing() {
        XCTAssertNil(StoreKitManager.verifiedXcodeInstall(for: .sandbox))
    }

    func testXcodeIsADeveloperInstall() {
        XCTAssertEqual(StoreKitManager.verifiedXcodeInstall(for: .xcode), true)
    }

    func testProductionClearsTheDeveloperInstallRecord() {
        XCTAssertEqual(StoreKitManager.verifiedXcodeInstall(for: .production), false)
    }
}
