@testable import Emuqu
import XCTest

/// Tests for the HR-source downgrade cascade run at workout start.
final class WorkoutHRSourceResolverTests: XCTestCase {
    private typealias Source = WorkoutRecorder.HRSource
    private typealias Resolution = WorkoutHRSourceResolver.Resolution

    private func resolve(
        _ requested: Source = .strap,
        recording: Bool = false,
        connected: Bool = true,
        known: Bool = true,
        watch: Bool = true
    ) -> Resolution {
        WorkoutHRSourceResolver.resolve(
            requested: requested,
            strapIsRecordingOnDevice: recording,
            strapIsConnected: connected,
            hasKnownDevices: known,
            isWatchPaired: watch
        )
    }

    // MARK: - Sources that never consult the strap

    /// A watch or sourceless user must not be blocked on hardware they did not
    /// ask for — not even when a strap is sitting there mid-recording.
    func testNonStrapSourcesPassThroughUntouched() {
        XCTAssertEqual(resolve(.watch), .use(.watch))
        XCTAssertEqual(resolve(.none), .use(.none))
        XCTAssertEqual(resolve(.watch, recording: true, connected: false, known: false, watch: false), .use(.watch))
        XCTAssertEqual(resolve(.none, recording: true, connected: false, known: false, watch: false), .use(.none))
    }

    // MARK: - Never preempt an overnight recording

    /// The most expensive failure in the app. The H10 keeps one exercise file;
    /// starting a workout over a running overnight recording loses the night.
    func testAStrapMidRecordingRefusesTheWorkout() {
        XCTAssertEqual(resolve(recording: true), .strapBusy)
    }

    /// Busy is busy whether or not the link happens to be up right now — the
    /// strap keeps recording through a dropout, and reconnecting to start a
    /// workout over it would still destroy the file.
    func testABusyStrapRefusesEvenWhenDisconnected() {
        XCTAssertEqual(resolve(recording: true, connected: false), .strapBusy)
        XCTAssertEqual(resolve(recording: true, connected: false, known: false, watch: false), .strapBusy)
    }

    /// The busy check outranks every downgrade. If it did not, a disconnected
    /// busy strap would fall through to `.watch` and the workout would start —
    /// over the top of the night.
    func testBusyOutranksEveryDowngrade() {
        for connected in [true, false] {
            for known in [true, false] {
                for watch in [true, false] {
                    XCTAssertEqual(
                        resolve(recording: true, connected: connected, known: known, watch: watch),
                        .strapBusy,
                        "connected=\(connected) known=\(known) watch=\(watch) must still refuse"
                    )
                }
            }
        }
    }

    // MARK: - The happy path

    func testAConnectedFreeStrapIsUsed() {
        XCTAssertEqual(resolve(), .use(.strap))
    }

    /// Connected wins outright — no reconnect, no downgrade, whatever else is
    /// available.
    func testAConnectedStrapIgnoresTheFallbacks() {
        XCTAssertEqual(resolve(connected: true, known: false, watch: false), .use(.strap))
    }

    // MARK: - The downgrade cascade

    /// The reported confusion: the ready screen said "connected", the strap
    /// dropped in the gap before Start. Reconnect and proceed rather than
    /// failing the start.
    func testAKnownButDisconnectedStrapReconnectsRatherThanFailing() {
        XCTAssertEqual(resolve(connected: false, known: true), .reconnectThenUseStrap)
    }

    /// Reconnect is preferred over the watch — a strap that has been paired is
    /// far more likely to come back than not, and it is the only source that
    /// yields HRV-grade data.
    func testReconnectIsPreferredOverTheWatch() {
        XCTAssertEqual(resolve(connected: false, known: true, watch: true), .reconnectThenUseStrap)
    }

    /// Never paired, but there is a watch: take the wrist HR rather than
    /// recording nothing.
    func testWithNoStrapEverPairedTheWatchStandsIn() {
        XCTAssertEqual(resolve(connected: false, known: false, watch: true), .use(.watch))
    }

    /// Nothing at all: record the workout with no HR rather than refusing the
    /// start. The post-summary tells the user what was missing.
    func testWithNothingAvailableTheWorkoutStillStartsWithNoSource() {
        XCTAssertEqual(resolve(connected: false, known: false, watch: false), .use(.none))
    }

    // MARK: - Provenance

    /// Provenance must reflect the POST-downgrade source, or the analyzer
    /// expects HRV-grade fields that were never captured.
    func testProvenanceFollowsTheResolvedSourceNotTheRequestedOne() {
        XCTAssertEqual(WorkoutHRSourceResolver.provenanceSource(for: .use(.none)), Source.none)
        XCTAssertEqual(WorkoutHRSourceResolver.provenanceSource(for: .use(.watch)), .watch)
        XCTAssertEqual(WorkoutHRSourceResolver.provenanceSource(for: .use(.strap)), .strap)
    }

    /// A reconnect still records strap provenance — that is what it will be
    /// once the link lands.
    func testAReconnectRecordsStrapProvenance() {
        XCTAssertEqual(WorkoutHRSourceResolver.provenanceSource(for: .reconnectThenUseStrap), .strap)
    }

    /// A refused start has no provenance because there is no workout.
    func testARefusedStartHasNoProvenance() {
        XCTAssertNil(WorkoutHRSourceResolver.provenanceSource(for: .strapBusy))
    }

    // MARK: - Whole-space properties

    /// Across every combination, a strap request either refuses or yields a
    /// usable source — it can never fall off the end undecided.
    func testEveryStrapRequestResolvesToSomething() {
        for recording in [true, false] {
            for connected in [true, false] {
                for known in [true, false] {
                    for watch in [true, false] {
                        let outcome = resolve(recording: recording, connected: connected, known: known, watch: watch)
                        if recording {
                            XCTAssertEqual(outcome, .strapBusy)
                        } else {
                            XCTAssertNotEqual(outcome, .strapBusy)
                            XCTAssertNotNil(WorkoutHRSourceResolver.provenanceSource(for: outcome))
                        }
                    }
                }
            }
        }
    }

    /// `.strap` is only ever the answer when a strap is actually reachable —
    /// connected now, or known and being reconnected. Claiming strap provenance
    /// otherwise records HRV-grade expectations against data that will not exist.
    func testStrapProvenanceRequiresAReachableStrap() {
        for connected in [true, false] {
            for known in [true, false] {
                for watch in [true, false] {
                    let outcome = resolve(connected: connected, known: known, watch: watch)
                    if WorkoutHRSourceResolver.provenanceSource(for: outcome) == .strap {
                        XCTAssertTrue(connected || known,
                                      "claimed strap with connected=\(connected) known=\(known)")
                    }
                }
            }
        }
    }
}
