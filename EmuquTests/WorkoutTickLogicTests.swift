@testable import Emuqu
import XCTest

/// Pure-logic tests for the two decision cores behind the workout
/// tick / finalize paths:
///
///   • `WorkoutRecorder.HRArbitration.decide` — the per-tick HR-source
///     arbitration (wrist fallback) and the strap notice shown to the user,
///     from `arbitrateHRSource` (WorkoutRecorder+Ticker.swift).
///   • `WorkoutRecorder.deviceFetchDecision` — the expected-beats density
///     gate from `mergeWorkoutRRWithDeviceFetch` (WorkoutRecorder.swift).
///
/// No recorder instance, no BLE, no timers, no clocks — inputs in,
/// decision out. The tick never acts on the strap link itself: getting a
/// silent strap back is the link's job (`StrapFeedHealth`), so these
/// decisions only choose what to display and what to tell the user.
@MainActor
final class WorkoutTickLogicTests: XCTestCase {
    private typealias Arbitration = WorkoutRecorder.HRArbitration

    // MARK: - Helpers

    /// Build arbitration inputs with a "healthy strap, idle watch" baseline;
    /// each case overrides only what it exercises. `.infinity` mirrors the
    /// production sentinel for "this channel has never produced an event".
    private func inputs(
        sourceMode: WorkoutRecorder.HRSource = .strap,
        recordingElapsedSeconds: Int = 3600,
        strapSilentFor: TimeInterval = 0,
        watchRoutedSilentFor: TimeInterval = .infinity,
        latestWatchHR: Int? = nil,
        strapFeed: StrapFeedHealth.Status = .live
    ) -> Arbitration.Inputs {
        Arbitration.Inputs(
            sourceMode: sourceMode,
            recordingElapsedSeconds: recordingElapsedSeconds,
            strapSilentFor: strapSilentFor,
            watchRoutedSilentFor: watchRoutedSilentFor,
            latestWatchHR: latestWatchHR,
            strapFeed: strapFeed
        )
    }

    private func noEffects() -> Arbitration.Decision {
        Arbitration.Decision(displayHRUpdate: nil, strapNotice: nil)
    }

    private func displayOnly(_ hr: Int) -> Arbitration.Decision {
        Arbitration.Decision(displayHRUpdate: hr, strapNotice: nil)
    }

    /// Every source the mode relies on is silent: the stale display value is
    /// dropped, with whatever notice applies.
    private func cleared(_ notice: WorkoutStrapNotice? = nil) -> Arbitration.Decision {
        Arbitration.Decision(displayHRUpdate: nil, strapNotice: notice, clearDisplayHR: true)
    }

    // MARK: - Science contract

    func testArbitrationThresholdsMatchAuditedValues() {
        XCTAssertEqual(Arbitration.wristFallbackSilenceSec, 10)
        XCTAssertEqual(Arbitration.strapNoticeGraceSec, 15)
        XCTAssertEqual(Arbitration.wristHRMaxAgeSec, 30)
    }

    // MARK: - HR arbitration (table-driven)

    private struct Case {
        let name: String
        let inputs: Arbitration.Inputs
        let expected: Arbitration.Decision
    }

    func testArbitrationCascadeTable() {
        for c in cascadeCases() {
            XCTAssertEqual(Arbitration.decide(c.inputs), c.expected, c.name)
        }
    }

    private func cascadeCases() -> [Case] {
        strapChannelCases() + sourceModeCases() + noticeCases()
    }

    /// Strap mode with the strap channels in various states of silence.
    private func strapChannelCases() -> [Case] {
        [
            Case(
                name: "strap healthy (2 s silent) — RR-derived display stands, no fallback",
                inputs: inputs(strapSilentFor: 2, latestWatchHR: 140),
                expected: noEffects()
            ),
            Case(
                name: "strap silent exactly 10 s — threshold is strictly greater-than, no fallback yet",
                inputs: inputs(strapSilentFor: 10, watchRoutedSilentFor: 10, latestWatchHR: 140),
                expected: noEffects()
            ),
            Case(
                name: "silent past the threshold, wrist HR available — falls back to Watch wrist HR",
                inputs: inputs(strapSilentFor: 11, watchRoutedSilentFor: 11, latestWatchHR: 142),
                expected: displayOnly(142)
            ),
            Case(
                name: "silent past the threshold, wrist HR unavailable — stale display value dropped",
                inputs: inputs(strapSilentFor: 11, watchRoutedSilentFor: 11, latestWatchHR: nil),
                expected: cleared()
            ),
            Case(
                name: "Polar long-silent but Watch-routed strap fresh — wrist fallback masked OFF (channels are independent)",
                inputs: inputs(strapSilentFor: 600, watchRoutedSilentFor: 3, latestWatchHR: 142, strapFeed: .stalled),
                expected: noEffects()
            )
        ]
    }

    /// The other two source modes: neither shows a strap notice.
    private func sourceModeCases() -> [Case] {
        [
            Case(
                name: "watch mode — wrist HR always wins, even with fresh strap channels",
                inputs: inputs(sourceMode: .watch, strapSilentFor: 0, watchRoutedSilentFor: 0, latestWatchHR: 131),
                expected: displayOnly(131)
            ),
            Case(
                name: "watch mode with everything silent and no strap — no strap notice outside .strap mode",
                inputs: inputs(
                    sourceMode: .watch, strapSilentFor: .infinity, watchRoutedSilentFor: .infinity,
                    latestWatchHR: 131, strapFeed: .waitingForStrap
                ),
                expected: displayOnly(131)
            ),
            Case(
                name: "watch mode, no current wrist reading — display cleared",
                inputs: inputs(sourceMode: .watch, latestWatchHR: nil),
                expected: cleared()
            ),
            Case(
                name: "none mode — no HR at all, regardless of what the Watch reports",
                inputs: inputs(
                    sourceMode: .none, strapSilentFor: .infinity, watchRoutedSilentFor: .infinity,
                    latestWatchHR: 140, strapFeed: .waitingForStrap
                ),
                expected: noEffects()
            )
        ]
    }

    /// What the user is told, and when.
    private func noticeCases() -> [Case] {
        [
            Case(
                name: "no link past the grace — strap not connected (wrist fallback also applies)",
                inputs: inputs(
                    recordingElapsedSeconds: 60, strapSilentFor: .infinity, watchRoutedSilentFor: .infinity,
                    latestWatchHR: 142, strapFeed: .waitingForStrap
                ),
                expected: Arbitration.Decision(displayHRUpdate: 142, strapNotice: .strapNotConnected)
            ),
            Case(
                name: "linked but stalled past the grace — strap silent",
                inputs: inputs(strapSilentFor: 40, watchRoutedSilentFor: .infinity, strapFeed: .stalled),
                expected: cleared(.strapSilent)
            ),
            Case(
                name: "linked and still setting up — no notice; the strap is still enabling its services",
                inputs: inputs(
                    recordingElapsedSeconds: 60, strapSilentFor: .infinity, watchRoutedSilentFor: .infinity,
                    strapFeed: .settingUp
                ),
                expected: cleared()
            ),
            Case(
                name: "1 s into the workout, no beat has ever landed — no notice; the strap has had no chance to speak",
                inputs: inputs(
                    recordingElapsedSeconds: 1, strapSilentFor: .infinity, watchRoutedSilentFor: .infinity,
                    strapFeed: .waitingForStrap
                ),
                expected: cleared()
            ),
            Case(
                name: "elapsed exactly 15 s — the grace is strictly greater-than",
                inputs: inputs(
                    recordingElapsedSeconds: 15, strapSilentFor: .infinity, watchRoutedSilentFor: .infinity,
                    strapFeed: .waitingForStrap
                ),
                expected: cleared()
            ),
            Case(
                name: "elapsed 16 s and no strap link — now it is worth saying",
                inputs: inputs(
                    recordingElapsedSeconds: 16, strapSilentFor: .infinity, watchRoutedSilentFor: .infinity,
                    strapFeed: .waitingForStrap
                ),
                expected: cleared(.strapNotConnected)
            ),
            Case(
                name: "feed status lags a beat that just landed — fresh beats win, no notice",
                inputs: inputs(strapSilentFor: 1, strapFeed: .stalled),
                expected: noEffects()
            ),
            Case(
                name: "Watch-routed strap carrying heart rate — no notice about the phone's link",
                inputs: inputs(strapSilentFor: .infinity, watchRoutedSilentFor: 2, strapFeed: .waitingForStrap),
                expected: noEffects()
            )
        ]
    }

    // MARK: - Infinity safety (FlowRecoveryCrash)

    /// No strap beat ever landed this workout → silence is `.infinity`. The
    /// decision must be computed without converting it to an integer.
    func testInfiniteSilenceIsHandledWithoutTrapping() {
        let decision = Arbitration.decide(inputs(
            strapSilentFor: .infinity,
            watchRoutedSilentFor: .infinity,
            latestWatchHR: nil,
            strapFeed: .waitingForStrap
        ))
        XCTAssertEqual(decision, cleared(.strapNotConnected))
    }

    // MARK: - Lost-walk regression

    /// From a field log: a tick watchdog forced a strap reconnect 1 s into a
    /// walk, tearing down the strap's service setup; the process was gone
    /// before the next heartbeat and the walk was lost. The tick no longer
    /// touches the link at all, and it says nothing for the whole start grace.
    func testNothingIsSaidDuringTheStartGrace() {
        for feed in [StrapFeedHealth.Status.waitingForStrap, .settingUp, .stalled] {
            for elapsed in 0 ... Int(Arbitration.strapNoticeGraceSec) {
                let decision = Arbitration.decide(inputs(
                    recordingElapsedSeconds: elapsed,
                    strapSilentFor: .infinity,
                    watchRoutedSilentFor: .infinity,
                    strapFeed: feed
                ))
                XCTAssertNil(decision.strapNotice, "notice \(elapsed) s into the workout (feed \(feed))")
            }
        }
    }

    // MARK: - Device-fetch density gate: science contract

    func testDeviceFetchConstantsMatchAuditedValues() {
        XCTAssertEqual(WorkoutRecorder.DeviceFetchDecision.skipFetchDensityThreshold, 0.95, accuracy: 0.000001)
        XCTAssertEqual(WorkoutRecorder.DeviceFetchDecision.minPlausibleAvgRRMs, 300)
        XCTAssertEqual(WorkoutRecorder.DeviceFetchDecision.minElapsedSecForDensityCheck, 60)
        XCTAssertEqual(WorkoutRecorder.DeviceFetchDecision.deviceWindowToleranceMs, 60_000)
    }

    // MARK: - Device-fetch density gate: decisions

    func testHighDensitySkipsFetch() {
        // 10-min workout at 60 bpm (avg RR 1000 ms): 600 expected beats,
        // 600 streamed → density 1.0 → skip the slow H10 download.
        let decision = WorkoutRecorder.deviceFetchDecision(
            streamingPointCount: 600, elapsedSec: 600, summedRRMs: 600_000
        )
        guard case let .skipFetch(density, expectedBeats) = decision else {
            return XCTFail("expected .skipFetch, got \(decision)")
        }
        XCTAssertEqual(density, 1.0, accuracy: 1e-9)
        XCTAssertEqual(expectedBeats, 600, accuracy: 1e-9)
    }

    func testDensityExactlyAtThresholdSkips() {
        // 950 beats of avg RR 1000 ms over 1000 s → expected 1000 beats,
        // density exactly 0.95 — the original used >=, so this skips.
        let decision = WorkoutRecorder.deviceFetchDecision(
            streamingPointCount: 950, elapsedSec: 1000, summedRRMs: 950_000
        )
        guard case .skipFetch = decision else {
            return XCTFail("density exactly 0.95 must skip (>= threshold), got \(decision)")
        }
    }

    func testLowDensityFetchesAndReportsDensity() throws {
        // 300 beats of avg RR 1000 ms over 600 s → expected 600 beats,
        // density 0.5 → fetch, and the shell logs the below-threshold value.
        let decision = WorkoutRecorder.deviceFetchDecision(
            streamingPointCount: 300, elapsedSec: 600, summedRRMs: 300_000
        )
        guard case let .fetch(belowThresholdDensity) = decision else {
            return XCTFail("expected .fetch, got \(decision)")
        }
        XCTAssertEqual(try XCTUnwrap(belowThresholdDensity), 0.5, accuracy: 1e-9)
    }

    func testShortElapsedEdgeAlwaysFetchesWithoutDensityLog() {
        // Original gate was `elapsedSec > 60` — exactly 60 s does NOT
        // qualify, and the density log must not fire (nil payload).
        let atBoundary = WorkoutRecorder.deviceFetchDecision(
            streamingPointCount: 60, elapsedSec: 60, summedRRMs: 60_000
        )
        XCTAssertEqual(atBoundary, .fetch(belowThresholdDensity: nil))

        let shortWorkout = WorkoutRecorder.deviceFetchDecision(
            streamingPointCount: 30, elapsedSec: 30, summedRRMs: 30_000
        )
        XCTAssertEqual(shortWorkout, .fetch(belowThresholdDensity: nil))
    }

    func testZeroPointsFetchesWithoutDensityLog() {
        // Empty streaming buffer (original `!streamingPoints.isEmpty`
        // guard): no density math possible — and no division by zero.
        let decision = WorkoutRecorder.deviceFetchDecision(
            streamingPointCount: 0, elapsedSec: 600, summedRRMs: 0
        )
        XCTAssertEqual(decision, .fetch(belowThresholdDensity: nil))
    }

    func testImplausibleAvgRRFetchesWithoutDensityLog() {
        // Mean RR exactly 300 ms (avg HR 200 bpm). Original gate was
        // `avgRR > 300` — strictly greater-than, so 300 falls through to
        // a plain fetch with no density estimate.
        let decision = WorkoutRecorder.deviceFetchDecision(
            streamingPointCount: 100, elapsedSec: 600, summedRRMs: 30_000
        )
        XCTAssertEqual(decision, .fetch(belowThresholdDensity: nil))
    }

    func testAvgRRUsesIntegerDivisionLikeTheOriginal() {
        // Original: `streamingPoints.reduce(0) { $0 + $1.rr_ms } / count`
        // — Int division. 30_099 / 100 = 300 (not 300.99), which must fall
        // on the implausible side of the strictly-greater-than gate.
        let truncatedToGate = WorkoutRecorder.deviceFetchDecision(
            streamingPointCount: 100, elapsedSec: 600, summedRRMs: 30_099
        )
        XCTAssertEqual(truncatedToGate, .fetch(belowThresholdDensity: nil))

        // 30_100 / 100 = 301 > 300 → density math runs (and reports the
        // low density for this sparse 100-beat buffer).
        let justPastGate = WorkoutRecorder.deviceFetchDecision(
            streamingPointCount: 100, elapsedSec: 600, summedRRMs: 30_100
        )
        guard case let .fetch(belowThresholdDensity) = justPastGate else {
            return XCTFail("expected .fetch with density payload, got \(justPastGate)")
        }
        XCTAssertNotNil(belowThresholdDensity)
    }
}

/// Distance moved while a workout is paused stays out of its total.
final class PausedMotionLedgerTests: XCTestCase {
    func testPausedStretchIsLeftOutAfterResume() {
        var ledger = PausedMotionLedger()
        ledger.pause(pedometer: 1_000, footPod: 900)
        ledger.resume(pedometer: 1_400, footPod: 1_300)
        XCTAssertEqual(ledger.pedometerDistance(2_000), 1_600, accuracy: 0.001)
        XCTAssertEqual(ledger.footPodDistance(1_800), 1_400, accuracy: 0.001)
    }

    func testStretchStillPausedAtStopIsLeftOut() {
        var ledger = PausedMotionLedger()
        ledger.pause(pedometer: 1_000, footPod: 0)
        XCTAssertEqual(ledger.pedometerDistance(1_250), 1_000, accuracy: 0.001)
    }

    func testSeveralPausesAddUp() {
        var ledger = PausedMotionLedger()
        ledger.pause(pedometer: 100, footPod: 0)
        ledger.resume(pedometer: 150, footPod: 0)
        ledger.pause(pedometer: 300, footPod: 0)
        ledger.resume(pedometer: 380, footPod: 0)
        XCTAssertEqual(ledger.pedometerDistance(500), 370, accuracy: 0.001)
    }

    func testNoPauseLeavesDistanceAlone() {
        XCTAssertEqual(PausedMotionLedger().pedometerDistance(1_234), 1_234, accuracy: 0.001)
    }
}
