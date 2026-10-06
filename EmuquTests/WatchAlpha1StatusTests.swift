@testable import Emuqu
import XCTest

/// The phone tells the Watch whether its α1 is current, and the Watch shows a
/// value only when it is. The live payload used to carry `alpha1` with no
/// status, so the Watch had no way to tell a frozen value from a live one.
final class WatchAlpha1StatusTests: XCTestCase {
    @MainActor
    func testTheLivePayloadCarriesTheAlpha1Status() {
        let warming = WatchConnectivityBridge.liveStatePayload(liveState(alpha1: nil, status: .warmup(fractionReady: 0.4)))
        XCTAssertEqual(warming["alpha1Status"] as? String, "warmup")
        XCTAssertNil(warming["alpha1"])
        let live = WatchConnectivityBridge.liveStatePayload(liveState(alpha1: 0.8, status: .ok))
        XCTAssertEqual(live["alpha1Status"] as? String, "ok")
        XCTAssertEqual(live["alpha1"] as? Double, 0.8)
    }

    func testStatusCodesAreStable() {
        XCTAssertEqual(LiveDFAAnalyzer.Status.ok.code, "ok")
        XCTAssertEqual(LiveDFAAnalyzer.Status.warmup(fractionReady: 0.5).code, "warmup")
        XCTAssertEqual(LiveDFAAnalyzer.Status.stalled(secondsSinceLastBeat: 50).code, "stalled")
        XCTAssertEqual(LiveDFAAnalyzer.Status.fitFailed.code, "fitFailed")
        XCTAssertEqual(LiveDFAAnalyzer.Status.tooManyArtifacts(correctedFraction: 0.1).code, "tooManyArtifacts")
    }

    func testTheWatchShowsAlpha1OnlyWhenThePhoneSaysItIsCurrent() {
        let current = WatchMessageDecoding.decode([
            "type": "liveState", "alpha1": 0.8, "bandCode": "belowAeT", "alpha1Status": "ok"
        ])
        XCTAssertEqual(current.alpha1, 0.8)
        XCTAssertEqual(current.band, WatchMessageDecoding.bandLabel(fromCode: "belowAeT"))
        let stalled = WatchMessageDecoding.decode([
            "type": "liveState", "alpha1": 0.8, "bandCode": "belowAeT", "alpha1Status": "stalled"
        ])
        XCTAssertNil(stalled.alpha1, "a value the phone has stopped computing is not shown as live")
        XCTAssertEqual(stalled.band, "—")
    }

    /// A phone build from before the status sends none; its α1 is shown as sent.
    func testAPhoneWithoutTheStatusIsTakenAsSent() {
        let update = WatchMessageDecoding.decode(["type": "liveState", "alpha1": 0.6, "bandCode": "nearAeT"])
        XCTAssertEqual(update.alpha1, 0.6)
        XCTAssertEqual(update.band, WatchMessageDecoding.bandLabel(fromCode: "nearAeT"))
    }

    private func liveState(alpha1: Double?, status: LiveDFAAnalyzer.Status) -> WatchConnectivityBridge.LiveState {
        WatchConnectivityBridge.LiveState(
            sport: .run, heartRate: 140, peakHR: 160, userMaxHR: 190,
            totals: WatchConnectivityBridge.LiveTotals(elapsedSec: 60, distanceMeters: 200, elevationGainMeters: 0),
            paceDisplay: nil, alpha1: alpha1, band: "", cadenceSpm: nil, targetZone: nil, unitsPreference: "metric",
            isRecording: true, isPaused: false, autoPaused: false, alpha1Status: status
        )
    }
}
