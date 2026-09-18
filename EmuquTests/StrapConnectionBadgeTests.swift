@testable import Emuqu
import SwiftUI
import XCTest

/// What the app tells the user about the strap while it connects.
///
/// ## Why this exists
///
/// A field log showed a connect that took fifty seconds to deliver its first
/// beat, and for the whole of it the badge said "Connected". A link is not a
/// working strap: the badge says the strap is setting up until a beat arrives,
/// shows the rate once beats are flowing, and says so when they stop.
@MainActor
final class StrapConnectionBadgeTests: XCTestCase {
    private let deviceId = "H10-BADGE"

    private func connectedManager() -> PolarManager {
        let manager = PolarManager()
        manager.radioForTesting = FakeStrapRadio()
        manager.link.apply(.connected(deviceId: deviceId, name: "Polar H10 BADGE"))
        return manager
    }

    // MARK: - Feed status

    func testTheFirstBeatTurnsTheFeedLive() {
        let manager = connectedManager()
        XCTAssertEqual(manager.feedStatus, .settingUp)

        manager.ingestHeartRate([StrapHRSample(hr: 58, rrsMs: [1_034], rrAvailable: true)])

        XCTAssertEqual(manager.feedStatus, .live)
        XCTAssertEqual(manager.currentHeartRate, 58)
    }

    // MARK: - What the badge says

    /// A link without a beat is not "Connected".
    func testALinkStillSettingUpIsNotShownAsConnected() {
        let badge = ConnectionStatusBadge.content(state: .connected, feed: .settingUp, heartRate: nil)

        XCTAssertEqual(badge.text, String(localized: "Setting up", bundle: LanguageManager.appBundle))
        XCTAssertEqual(badge.color, .orange)
    }

    /// Beats arriving: green, with the latest reading.
    func testALiveFeedShowsTheHeartRate() {
        let badge = ConnectionStatusBadge.content(state: .connected, feed: .live, heartRate: 62)

        XCTAssertEqual(badge.text, String(localized: "\(62) bpm", bundle: LanguageManager.appBundle))
        XCTAssertEqual(badge.color, .green)
    }

    /// A strap that stopped sending says so rather than staying green.
    func testAStalledFeedIsNotShownAsConnected() {
        let badge = ConnectionStatusBadge.content(state: .connected, feed: .stalled, heartRate: 62)

        XCTAssertEqual(badge.text, String(localized: "No heart rate from strap", bundle: LanguageManager.appBundle))
        XCTAssertEqual(badge.color, .orange)
    }

    func testNoLinkIsShownAsDisconnectedWhateverTheFeedLastSaid() {
        let badge = ConnectionStatusBadge.content(state: .disconnected, feed: .live, heartRate: 62)

        XCTAssertEqual(badge.text, String(localized: "Disconnected", bundle: LanguageManager.appBundle))
        XCTAssertEqual(badge.color, .gray)
    }
}
