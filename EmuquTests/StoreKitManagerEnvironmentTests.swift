@testable import Emuqu
import StoreKit
import XCTest

/// What a verified `AppTransaction` environment does to the
/// developer-install and beta-tester routes.
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

    /// The defect this pins: an Apple ID that earlier sandbox builds anchored
    /// as a beta tester, App Review's included, skipped the paywall. Only a
    /// production install records what lets a beta anchor in; sandbox, which
    /// App Review and TestFlight share, clears it.
    func testOnlyProductionLetsABetaAnchorIn() {
        XCTAssertEqual(StoreKitManager.verifiedProductionInstall(for: .production), true)
        XCTAssertEqual(StoreKitManager.verifiedProductionInstall(for: .sandbox), false)
        XCTAssertEqual(StoreKitManager.verifiedProductionInstall(for: .xcode), false)
    }
}
