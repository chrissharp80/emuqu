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
}
