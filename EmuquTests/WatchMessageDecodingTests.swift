@testable import Emuqu
import XCTest

/// Covers the phone → Watch message contract.
///
/// The watch target shipped 2,497 lines with no tests at all. Not because its
/// logic was untestable but because the testable part — reading a loosely-typed
/// `[String: Any]` and deciding what state transition it implies — was welded
/// to the part that genuinely is not: `@Published` assignment and
/// `HKWorkoutSession` lifecycle, neither of which runs without a paired Watch.
///
/// `WatchMessageDecoding` is that testable part, extracted, and
/// `WatchSessionManager.apply(_:)` now routes through it — so these tests cover
/// the shipping path rather than a parallel copy of it.
///
/// The rules worth pinning are the ones that produced field bugs:
///   • absent ≠ zero (partial updates are the norm)
///   • `justCompleted` only on a true → false transition
///   • `displayOnlyMode` is sticky across partial messages
///   • `startWorkout` is refused in display-only mode
final class WatchMessageDecodingTests: XCTestCase {

    // MARK: - Decoding

    func testDecodeReadsEveryKnownField() {
        let update = WatchMessageDecoding.decode([
            "heartRate": 142,
            "hrPercentOfMax": 78,
            "peakHR": 171,
            "elapsedSec": 1_845,
            "distanceMeters": 5_012.5,
            "paceDisplay": "5:12 /km",
            "alpha1": 0.72,
            "band": "aerobic",
            "sport": "trail_run",
            "cadenceSpm": 174.0,
            "elevationGainMeters": 231.0,
            "targetZone": 2,
            "units": "metric",
            "displayOnlyMode": true,
            "isPaused": false,
            "autoPaused": false,
            "isRecording": true,
            "voiceChatState": "listening"
        ])

        XCTAssertEqual(update.heartRate, 142)
        XCTAssertEqual(update.hrPercentOfMax, 78)
        XCTAssertEqual(update.peakHR, 171)
        XCTAssertEqual(update.elapsedSeconds, 1_845)
        XCTAssertEqual(update.distanceMeters, 5_012.5)
        XCTAssertEqual(update.paceDisplay, "5:12 /km")
        XCTAssertEqual(update.alpha1, 0.72)
        XCTAssertEqual(update.band, "aerobic")
        XCTAssertEqual(update.cadenceSpm, 174.0)
        XCTAssertEqual(update.elevationGainMeters, 231.0)
        XCTAssertEqual(update.targetZone, 2)
        XCTAssertEqual(update.unitsPreference, "metric")
        XCTAssertEqual(update.displayOnlyMode, true)
        XCTAssertEqual(update.isPaused, false)
        XCTAssertEqual(update.autoPaused, false)
        XCTAssertEqual(update.isRecording, true)
        XCTAssertEqual(update.voiceChatStateLabel, "listening")
    }

    /// An empty message must produce an all-`nil` update, not a zeroed one.
    /// iOS pushes only what changed, so "absent" has to mean "leave it alone" —
    /// a decode that defaulted to `0`/`false` would blank the live metrics on
    /// every partial update.
    func testAbsentFieldsDecodeAsNilNotZero() {
        let update = WatchMessageDecoding.decode([:])

        XCTAssertNil(update.heartRate)
        XCTAssertNil(update.elapsedSeconds)
        XCTAssertNil(update.distanceMeters)
        XCTAssertNil(update.isRecording)
        XCTAssertNil(update.isPaused)
        XCTAssertNil(update.displayOnlyMode)
        XCTAssertEqual(update, WatchMessageDecoding.StateUpdate())
    }

    /// A wrong-typed value is treated as absent rather than coerced. The
    /// payload crosses a process boundary from a separately-versioned iOS
    /// build; a type mismatch means the two sides disagree about the schema,
    /// and guessing there is how a stale field overwrites a good one.
    func testWrongTypedValuesAreTreatedAsAbsent() {
        let update = WatchMessageDecoding.decode([
            "heartRate": "142",          // String where Int expected
            "distanceMeters": 5_012,     // Int where Double expected
            "isRecording": 1,            // Int where Bool expected
            "band": 4                    // Int where String expected
        ])

        XCTAssertNil(update.heartRate)
        XCTAssertNil(update.distanceMeters)
        XCTAssertNil(update.isRecording)
        XCTAssertNil(update.band)
    }

    /// A `liveState` tick is a whole snapshot: iOS leaves out a metric it has
    /// not measured, so the Watch must be able to tell a tick from a partial
    /// update to clear a heart rate that stopped arriving.
    func testOnlyALiveStateTickIsASnapshot() {
        XCTAssertTrue(WatchMessageDecoding.decode(["type": "liveState"]).isLiveSnapshot)
        XCTAssertFalse(WatchMessageDecoding.decode(["type": "strapState"]).isLiveSnapshot)
        XCTAssertFalse(WatchMessageDecoding.decode(["heartRate": 120]).isLiveSnapshot)
    }

    func testSportRawIsCarriedForTheWatchSession() {
        XCTAssertEqual(WatchMessageDecoding.decode(["sport": "treadmill"]).sportRaw, "treadmill")
        XCTAssertNil(WatchMessageDecoding.decode([:]).sportRaw)
    }

    func testSportRawIsHumanised() {
        XCTAssertEqual(WatchMessageDecoding.sportLabel(fromRaw: "trail_run"), "Trail Run")
        XCTAssertEqual(WatchMessageDecoding.sportLabel(fromRaw: "ride"), "Ride")
        XCTAssertEqual(WatchMessageDecoding.sportLabel(fromRaw: "open_water_swim"), "Open Water Swim")
        XCTAssertEqual(WatchMessageDecoding.sportLabel(fromRaw: ""), "")
    }

    func testDecodeSurfacesSportThroughTheHumanisedLabel() {
        let update = WatchMessageDecoding.decode(["sport": "indoor_ride"])
        XCTAssertEqual(update.sportLabel, "Indoor Ride")
    }

    // MARK: - Recording transitions

    func testRecordingTransitionStartsOnFalseToTrue() {
        let update = WatchMessageDecoding.decode(["isRecording": true])
        XCTAssertEqual(
            WatchMessageDecoding.recordingTransition(wasRecording: false, update: update),
            .started
        )
    }

    func testRecordingTransitionStopsOnTrueToFalse() {
        let update = WatchMessageDecoding.decode(["isRecording": false])
        XCTAssertEqual(
            WatchMessageDecoding.recordingTransition(wasRecording: true, update: update),
            .stopped
        )
    }

    /// Repeated pushes of the same state must not restart the workout session.
    /// iOS re-sends `isRecording: true` on every state sync, and a `.started`
    /// on each one would tear down and rebuild `HKWorkoutSession` mid-workout.
    func testRepeatedSameStateIsNotATransition() {
        let stillRecording = WatchMessageDecoding.decode(["isRecording": true])
        XCTAssertEqual(
            WatchMessageDecoding.recordingTransition(wasRecording: true, update: stillRecording),
            .none
        )

        let stillIdle = WatchMessageDecoding.decode(["isRecording": false])
        XCTAssertEqual(
            WatchMessageDecoding.recordingTransition(wasRecording: false, update: stillIdle),
            .none
        )
    }

    func testMessageWithoutRecordingFieldIsNotATransition() {
        let update = WatchMessageDecoding.decode(["heartRate": 130])
        XCTAssertEqual(
            WatchMessageDecoding.recordingTransition(wasRecording: true, update: update),
            .none
        )
    }

    // MARK: - justCompleted banner

    func testJustCompletedSetOnStopTransition() {
        let update = WatchMessageDecoding.decode(["isRecording": false])
        XCTAssertTrue(
            WatchMessageDecoding.justCompleted(current: false, wasRecording: true, update: update)
        )
    }

    /// The regression this rule exists for: a cold Watch launch reports
    /// `isRecording: false` while `wasRecording` is also false, and must NOT
    /// raise a "Save & Done" banner for a workout that never happened.
    func testColdLaunchDoesNotRaiseCompletionBanner() {
        let update = WatchMessageDecoding.decode(["isRecording": false])
        XCTAssertFalse(
            WatchMessageDecoding.justCompleted(current: false, wasRecording: false, update: update)
        )
    }

    func testStartingANewWorkoutClearsALingeringBanner() {
        let update = WatchMessageDecoding.decode(["isRecording": true])
        XCTAssertFalse(
            WatchMessageDecoding.justCompleted(current: true, wasRecording: false, update: update)
        )
    }

    func testBannerSurvivesAMessageThatDoesNotMentionRecording() {
        let update = WatchMessageDecoding.decode(["heartRate": 88])
        XCTAssertTrue(
            WatchMessageDecoding.justCompleted(current: true, wasRecording: false, update: update)
        )
    }

    // MARK: - In-flight request clearing

    func testConfirmedRecordingClearsStartRequest() {
        XCTAssertTrue(WatchMessageDecoding.clearsStartWorkoutRequest(
            update: WatchMessageDecoding.decode(["isRecording": true])
        ))
        XCTAssertFalse(WatchMessageDecoding.clearsStartWorkoutRequest(
            update: WatchMessageDecoding.decode(["isRecording": false])
        ))
        XCTAssertFalse(WatchMessageDecoding.clearsStartWorkoutRequest(
            update: WatchMessageDecoding.decode([:])
        ))
    }

    func testAnyNonIdleVoiceStateClearsVoiceRequest() {
        for state in ["starting", "listening", "thinking", "speaking"] {
            XCTAssertTrue(
                WatchMessageDecoding.clearsVoiceChatRequest(
                    update: WatchMessageDecoding.decode(["voiceChatState": state])
                ),
                "\(state) should clear the in-flight voice request"
            )
        }
        XCTAssertFalse(WatchMessageDecoding.clearsVoiceChatRequest(
            update: WatchMessageDecoding.decode(["voiceChatState": "idle"])
        ))
        XCTAssertFalse(WatchMessageDecoding.clearsVoiceChatRequest(
            update: WatchMessageDecoding.decode([:])
        ))
    }

    // MARK: - Commands

    func testCommandParsing() {
        XCTAssertEqual(WatchMessageDecoding.command(["type": "startWorkout"]), .startWorkout)
        XCTAssertEqual(WatchMessageDecoding.command(["type": "stopWorkout"]), .stopWorkout)
        XCTAssertEqual(WatchMessageDecoding.command(["type": "liveState"]), .liveState)
        XCTAssertEqual(WatchMessageDecoding.command(["type": "voiceChatState"]), .voiceChatState)
        XCTAssertNil(WatchMessageDecoding.command([:]))
        XCTAssertNil(WatchMessageDecoding.command(["heartRate": 100]))
    }

    func testStrapStateCarriesItsPayload() {
        let command = WatchMessageDecoding.command([
            "type": "strapState",
            "strapConnected": true,
            "strapDeviceName": "Polar H10 ABC123"
        ])
        XCTAssertEqual(command, .strapState(connected: true, deviceName: "Polar H10 ABC123"))
    }

    /// A `strapState` with no payload is still a valid command — iOS sends it
    /// to signal "no strap" — so the fields decode to nil rather than the
    /// command being rejected.
    func testStrapStateWithoutPayloadIsStillTheCommand() {
        XCTAssertEqual(
            WatchMessageDecoding.command(["type": "strapState"]),
            .strapState(connected: nil, deviceName: nil)
        )
    }

    /// An unrecognised verb is carried, not dropped, so a schema drift between
    /// a newer iOS build and an older Watch build is diagnosable.
    func testUnknownVerbIsCarried() {
        XCTAssertEqual(
            WatchMessageDecoding.command(["type": "teleport"]),
            .unknown("teleport")
        )
    }

    // MARK: - Display-only mode gating

    /// The rule that stops Apple Health offering to "Record a workout" for a
    /// workout the Watch does not own. iOS gates this too, so reaching here in
    /// display-only mode means a stale build or a downstream bug — and
    /// honouring it is the user-visible failure.
    func testStartWorkoutIsRefusedInDisplayOnlyMode() {
        XCTAssertFalse(
            WatchMessageDecoding.shouldStartWorkout(for: .startWorkout, displayOnlyMode: true)
        )
    }

    func testStartWorkoutIsHonouredInLegacyMode() {
        XCTAssertTrue(
            WatchMessageDecoding.shouldStartWorkout(for: .startWorkout, displayOnlyMode: false)
        )
    }

    func testOnlyStartWorkoutStartsAWorkout() {
        XCTAssertFalse(
            WatchMessageDecoding.shouldStartWorkout(for: .stopWorkout, displayOnlyMode: false)
        )
        XCTAssertFalse(
            WatchMessageDecoding.shouldStartWorkout(
                for: .strapState(connected: true, deviceName: nil), displayOnlyMode: false
            )
        )
        XCTAssertFalse(
            WatchMessageDecoding.shouldStartWorkout(for: .unknown("teleport"), displayOnlyMode: false)
        )
    }

    // MARK: - Sticky display-only mode

    /// `displayOnlyMode` decodes as `nil` when absent, which is what makes the
    /// caller's `if let` leave the previous value in place. If this ever
    /// decoded to `false` instead, every partial update would silently drop the
    /// Watch out of display-only mode and re-enable local workout sessions.
    func testDisplayOnlyModeIsAbsentRatherThanFalseInPartialUpdates() {
        let partial = WatchMessageDecoding.decode(["heartRate": 120, "isRecording": true])
        XCTAssertNil(partial.displayOnlyMode)

        let explicit = WatchMessageDecoding.decode(["displayOnlyMode": false])
        XCTAssertEqual(explicit.displayOnlyMode, false)
    }

    // MARK: - Realistic payload

    /// A representative live-workout push, asserted end to end so a schema
    /// change on the iOS side shows up here rather than as a blank Watch face.
    func testRepresentativeLiveWorkoutPush() {
        let message: [String: Any] = [
            "type": "state",
            "heartRate": 148,
            "hrPercentOfMax": 81,
            "peakHR": 165,
            "elapsedSec": 2_730,
            "distanceMeters": 8_450.0,
            "paceDisplay": "5:23 /km",
            "sport": "trail_run",
            "cadenceSpm": 168.0,
            "elevationGainMeters": 412.0,
            "isRecording": true,
            "isPaused": false,
            "displayOnlyMode": true
        ]

        let update = WatchMessageDecoding.decode(message)

        XCTAssertEqual(update.heartRate, 148)
        XCTAssertEqual(update.sportLabel, "Trail Run")
        XCTAssertEqual(update.displayOnlyMode, true)
        XCTAssertEqual(
            WatchMessageDecoding.recordingTransition(wasRecording: false, update: update),
            .started
        )
        XCTAssertEqual(WatchMessageDecoding.command(message), .unknown("state"))
    }

    // MARK: - Words the Watch writes itself

    // The phone used to send the α1 band, the pace and its refusals already
    // worded in its app language, so a Watch set to another language showed
    // two languages. It now sends codes and numbers and the Watch words them
    // from the shared catalogue; the phone's wording stays in the payload for
    // Watch builds that predate the codes, and is what an unknown code falls
    // back to.

    func testBandCodeIsNamedOnTheWatch() {
        let update = WatchMessageDecoding.decode(["bandCode": "nearAeT", "band": "Schwelle"])
        XCTAssertEqual(update.band, String(localized: "Threshold"))
    }

    func testUnknownBandCodeFallsBackToThePhonesWording() {
        let update = WatchMessageDecoding.decode(["bandCode": "someFutureBand", "band": "Schwelle"])
        XCTAssertEqual(update.band, "Schwelle")
    }

    func testEveryPhoneBandHasAWatchName() {
        let codes: [LiveDFAAnalyzer.Band] = [.unknown, .belowAeT, .nearAeT, .aboveVT2]
        for band in codes {
            XCTAssertNotNil(WatchMessageDecoding.bandLabel(fromCode: band.rawValue), "\(band) has no Watch name")
        }
    }

    func testPaceNumberIsWrittenOnTheWatch() {
        let metric = WatchMessageDecoding.decode(["paceSecPerKm": 312.0, "units": "metric", "paceDisplay": "phone"])
        XCTAssertEqual(metric.paceDisplay, String(localized: "\("5:12") /km"))
        let imperial = WatchMessageDecoding.decode(["paceSecPerKm": 312.0, "units": "imperial"])
        XCTAssertEqual(imperial.paceDisplay, String(localized: "\("8:22") /mi"))
    }

    func testPaceWithoutANumberFallsBackToThePhonesWording() {
        XCTAssertEqual(WatchMessageDecoding.decode(["paceDisplay": "5:12 /km"]).paceDisplay, "5:12 /km")
        XCTAssertNil(WatchMessageDecoding.pace(secPerKm: 0, imperial: false))
    }

    /// The phone's live tick carries the band as a code the Watch knows.
    func testLiveStateBandCodeFollowsAlpha1() {
        XCTAssertEqual(liveState(alpha1: 0.9).bandCode, .belowAeT)
        XCTAssertEqual(liveState(alpha1: 0.6).bandCode, .nearAeT)
        XCTAssertEqual(liveState(alpha1: 0.3).bandCode, .aboveVT2)
        XCTAssertEqual(liveState(alpha1: nil).bandCode, .unknown)
    }

    /// Every refusal the phone can send is one the Watch can word itself.
    @MainActor
    func testEveryPhoneRefusalIsWordedOnTheWatch() throws {
        let refusals: [WatchControlRefusal] = [.phoneNotReady, .unknownMessage, .unknownSport, .needsUnlock]
        for refusal in refusals {
            let reply = WatchConnectivityBridge.refusalReply(refusal, sport: "kayak")
            XCTAssertEqual(reply["ok"] as? Bool, false)
            XCTAssertEqual(reply["error"] as? String, refusal.phoneText(sport: "kayak"))
            let code = try XCTUnwrap(reply["errorCode"] as? String)
            XCTAssertEqual(WatchMessageDecoding.refusalText(code: code, sport: "kayak"), refusal.phoneText(sport: "kayak"))
        }
        XCTAssertNil(WatchMessageDecoding.refusalText(code: "someFutureRefusal", sport: nil))
    }

    /// A Watch Start from a user the phone's paywall stops gets an
    /// explicit prompt, not a bare refusal or a later "didn't acknowledge".
    @MainActor
    func testUnlockRefusalShowsTheUnlockPromptWithoutPrefix() {
        let reply = WatchConnectivityBridge.refusalReply(.needsUnlock, sport: "run")
        let status = WatchMessageDecoding.controlReplyStatus(reply, sport: "run", successStatus: "ok")
        XCTAssertEqual(status, String(localized: "Open Emuqu on your iPhone to start your free trial or unlock."))
    }

    /// The defect this pins: the Watch's Talk button started voice chat on
    /// the phone for a user the paywall stops there, and the reply said it
    /// had started. A refused voice-chat request carries the same unlock
    /// code a refused Watch Start does, and reads as the same prompt.
    @MainActor
    func testARefusedVoiceChatReplyCarriesTheUnlockPrompt() {
        let reply = WatchConnectivityBridge.voiceChatReply(
            refusal: .needsUnlock, hasAcceptedDisclaimer: true, stateLabel: "starting")
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertNil(reply["voiceChatState"])
        XCTAssertNil(reply["needsDisclaimer"])
        XCTAssertEqual(
            WatchMessageDecoding.controlReplyStatus(reply, sport: nil, successStatus: ""),
            String(localized: "Open Emuqu on your iPhone to start your free trial or unlock."))
    }

    /// The unlock comes before the disclaimer: the disclaimer is shown in Flo,
    /// which the paywall covers.
    @MainActor
    func testVoiceChatReplyForTheDisclaimerAndForAnAcceptedRequest() {
        let refusedFirst = WatchConnectivityBridge.voiceChatReply(
            refusal: .needsUnlock, hasAcceptedDisclaimer: false, stateLabel: "off")
        XCTAssertEqual(refusedFirst["errorCode"] as? String, WatchControlRefusal.needsUnlock.rawValue)
        let disclaimer = WatchConnectivityBridge.voiceChatReply(
            refusal: nil, hasAcceptedDisclaimer: false, stateLabel: "off")
        XCTAssertEqual(disclaimer["ok"] as? Bool, false)
        XCTAssertEqual(disclaimer["needsDisclaimer"] as? Bool, true)
        let accepted = WatchConnectivityBridge.voiceChatReply(
            refusal: nil, hasAcceptedDisclaimer: true, stateLabel: "starting")
        XCTAssertEqual(accepted["ok"] as? Bool, true)
        XCTAssertEqual(accepted["voiceChatState"] as? String, "starting")
    }

    /// Other refusals say which device answered; an accepted request shows
    /// the caller's success wording; an unknown code quotes the phone.
    @MainActor
    func testControlReplyStatusForAcceptedAndOtherRefusals() {
        XCTAssertEqual(WatchMessageDecoding.controlReplyStatus(["ok": true], sport: nil, successStatus: "Paused"), "Paused")
        let notReady = WatchConnectivityBridge.refusalReply(.phoneNotReady)
        let notReadyText = String(localized: "Phone not ready")
        XCTAssertEqual(
            WatchMessageDecoding.controlReplyStatus(notReady, sport: nil, successStatus: "ok"),
            String(localized: "iPhone: \(notReadyText)")
        )
        let future: [String: Any] = ["ok": false, "errorCode": "someFutureRefusal", "error": "Strap busy"]
        XCTAssertEqual(
            WatchMessageDecoding.controlReplyStatus(future, sport: nil, successStatus: "ok"),
            String(localized: "iPhone: \("Strap busy")")
        )
    }

    // MARK: - Numbers from another build

    /// The defect this pins: a non-finite cadence passed the Watch's `c >= 1`
    /// check and trapped in `Int(c.rounded())`. Every number from the phone
    /// is range-checked where it is decoded, and a value outside its range is
    /// absent, like a value of the wrong type.
    func testDecodeDropsNonFiniteAndImplausibleNumbers() {
        let update = WatchMessageDecoding.decode([
            "heartRate": 9_000,
            "hrPercentOfMax": -5,
            "peakHR": 400,
            "elapsedSec": -1,
            "distanceMeters": Double.infinity,
            "alpha1": Double.nan,
            "cadenceSpm": Double.infinity,
            "elevationGainMeters": -Double.infinity,
            "targetZone": 9
        ])
        XCTAssertNil(update.heartRate)
        XCTAssertNil(update.hrPercentOfMax)
        XCTAssertNil(update.peakHR)
        XCTAssertNil(update.elapsedSeconds)
        XCTAssertNil(update.distanceMeters)
        XCTAssertNil(update.alpha1)
        XCTAssertNil(update.cadenceSpm)
        XCTAssertNil(update.elevationGainMeters)
        XCTAssertNil(update.targetZone)
    }

    func testDecodeKeepsTheEdgesOfEachRange() {
        let update = WatchMessageDecoding.decode([
            "heartRate": 250, "peakHR": 0, "cadenceSpm": 0.0, "alpha1": 3.0, "targetZone": 5
        ])
        XCTAssertEqual(update.heartRate, 250)
        XCTAssertEqual(update.peakHR, 0)
        XCTAssertEqual(update.cadenceSpm, 0)
        XCTAssertEqual(update.alpha1, 3)
        XCTAssertEqual(update.targetZone, 5)
    }

    /// The phone side of the same boundary: RR intervals and heart rates the
    /// Watch relays are checked before `Int(...)` and before the display.
    func testPhoneDropsNonFiniteAndImplausibleWatchBeats() {
        let beats = WatchPayloadBounds.plausibleRRMillis([812, .nan, .infinity, -.infinity, 1e300, -800, 0, 300, 2_500, 2_499.4])
        XCTAssertEqual(beats, [812, 2_499.4])
        XCTAssertEqual(WatchPayloadBounds.plausibleHeartRate(150), 150)
        XCTAssertNil(WatchPayloadBounds.plausibleHeartRate(0))
        XCTAssertNil(WatchPayloadBounds.plausibleHeartRate(60_000))
        XCTAssertNil(WatchPayloadBounds.plausibleHeartRate(nil))
    }

    // MARK: - Ending the Watch session without the iPhone

    /// The defect this pins (Guideline 2.4.2): with the iPhone app gone, the
    /// Watch's workout session ran until the iPhone app next launched. The
    /// wrist End now ends it at once when the iPhone cannot be reached; with
    /// the iPhone reachable, the iPhone's answer ends it as before.
    func testWristStopEndsTheSessionOnlyWhenTheIPhoneIsUnreachable() {
        XCTAssertTrue(WatchMessageDecoding.endsSessionOnWristStop(phoneReachable: false))
        XCTAssertFalse(WatchMessageDecoding.endsSessionOnWristStop(phoneReachable: true))
    }

    func testPhoneSilenceEndsTheSessionOnlyPastTheLimit() {
        let contact = Date(timeIntervalSince1970: 1_000)
        let limit = WatchMessageDecoding.phoneSilenceLimit
        XCTAssertFalse(WatchMessageDecoding.phoneSilenceExceeded(lastContact: contact, now: contact))
        XCTAssertFalse(WatchMessageDecoding.phoneSilenceExceeded(lastContact: contact, now: contact.addingTimeInterval(limit)))
        XCTAssertTrue(WatchMessageDecoding.phoneSilenceExceeded(lastContact: contact, now: contact.addingTimeInterval(limit + 1)))
        // A recording iPhone sends every second: the limit is many ticks long,
        // and still well short of an hour of a sensor left on.
        XCTAssertGreaterThanOrEqual(limit, 10 * 60)
        XCTAssertLessThanOrEqual(limit, 60 * 60)
    }

    private func liveState(alpha1: Double?) -> WatchConnectivityBridge.LiveState {
        WatchConnectivityBridge.LiveState(
            sport: .run, heartRate: 140, peakHR: 160, userMaxHR: 190,
            totals: WatchConnectivityBridge.LiveTotals(elapsedSec: 60, distanceMeters: 200, elevationGainMeters: 0),
            paceDisplay: nil, alpha1: alpha1, band: "", cadenceSpm: nil, targetZone: nil, unitsPreference: "metric",
            isRecording: true, isPaused: false, autoPaused: false
        )
    }
}
