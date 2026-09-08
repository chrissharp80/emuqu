@testable import Emuqu
import XCTest

/// Pure-logic tests for the two decision cores behind the workout
/// tick / finalize paths:
///
///   • `WorkoutRecorder.HRArbitration.decide` — the per-tick HR-source
///     arbitration cascade + strap-watchdog trigger from
///     `incrementalBackupTick` (WorkoutRecorder+Ticker.swift).
///   • `WorkoutRecorder.deviceFetchDecision` — the expected-beats density
///     gate from `mergeWorkoutRRWithDeviceFetch` (WorkoutRecorder.swift).
///
/// No recorder instance, no BLE, no timers, no clocks — inputs in,
/// decision out. The table cases pin every branch of the original inline
/// cascade, including the `Int(.infinity)` SIGTRAP regression.
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
        watchdogCooldownFor: TimeInterval = .infinity,
        latestWatchHR: Int? = nil,
        isPolarStreaming: Bool = true
    ) -> Arbitration.Inputs {
        Arbitration.Inputs(
            sourceMode: sourceMode,
            recordingElapsedSeconds: recordingElapsedSeconds,
            strapSilentFor: strapSilentFor,
            watchRoutedSilentFor: watchRoutedSilentFor,
            watchdogCooldownFor: watchdogCooldownFor,
            latestWatchHR: latestWatchHR,
            isPolarStreaming: isPolarStreaming
        )
    }

    private func noEffects() -> Arbitration.Decision {
        Arbitration.Decision(displayHRUpdate: nil, shouldForceReconnect: false, strapSilentLabel: nil)
    }

    private func displayOnly(_ hr: Int) -> Arbitration.Decision {
        Arbitration.Decision(displayHRUpdate: hr, shouldForceReconnect: false, strapSilentLabel: nil)
    }

    // MARK: - Science contract (thresholds match the audited inline values)

    func testArbitrationThresholdsMatchAuditedValues() {
        XCTAssertEqual(Arbitration.wristFallbackSilenceSec, 10)
        XCTAssertEqual(Arbitration.watchdogSilenceSec, 25)
        XCTAssertEqual(Arbitration.watchdogCooldownSec, 60)
    }

    // MARK: - HR arbitration + watchdog cascade (table-driven)

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
        strapChannelCases() + sourceModeCases() + startWindowCases()
    }

    /// Strap mode with the strap channels in various states of silence.
    private func strapChannelCases() -> [Case] {
        [
            Case(
                name: "strap healthy (2 s silent) — RR-derived display stands, no fallback, no watchdog",
                inputs: inputs(strapSilentFor: 2, latestWatchHR: 140),
                expected: noEffects()
            ),
            Case(
                name: "strap silent exactly 10 s — tier-1 threshold is strictly greater-than, no fallback yet",
                inputs: inputs(strapSilentFor: 10, watchRoutedSilentFor: 10, latestWatchHR: 140),
                expected: noEffects()
            ),
            Case(
                name: "silent past tier-1, wrist HR available — falls back to Watch wrist HR",
                inputs: inputs(strapSilentFor: 11, watchRoutedSilentFor: 11, latestWatchHR: 142),
                expected: displayOnly(142)
            ),
            Case(
                name: "silent past tier-1, wrist HR unavailable — display left exactly as-is",
                inputs: inputs(strapSilentFor: 11, watchRoutedSilentFor: 11, latestWatchHR: nil),
                expected: noEffects()
            ),
            Case(
                name: "Polar long-silent but Watch-routed strap fresh — wrist fallback masked OFF (2026-04-30 masking fix: channels are independent)",
                inputs: inputs(strapSilentFor: 600, watchRoutedSilentFor: 3, latestWatchHR: 142),
                expected: noEffects()
            ),
            Case(
                name: "silent past tier-2, cooldown never started — watchdog fires (wrist fallback also applies)",
                inputs: inputs(strapSilentFor: 30, watchRoutedSilentFor: 30, watchdogCooldownFor: .infinity, latestWatchHR: 142),
                expected: Arbitration.Decision(displayHRUpdate: 142, shouldForceReconnect: true, strapSilentLabel: "30 s")
            ),
            Case(
                name: "silent past tier-2 but cooldown NOT elapsed (45 s < 60 s) — no re-trigger",
                inputs: inputs(strapSilentFor: 30, watchRoutedSilentFor: 30, watchdogCooldownFor: 45, latestWatchHR: 142),
                expected: displayOnly(142)
            ),
            Case(
                name: "cooldown exactly 60 s — strictly greater-than, still no re-trigger",
                inputs: inputs(strapSilentFor: 90, watchRoutedSilentFor: 90, watchdogCooldownFor: 60, latestWatchHR: 142),
                expected: displayOnly(142)
            ),
            Case(
                name: "silence exactly 25 s — tier-2 threshold is strictly greater-than, watchdog holds (fallback active)",
                inputs: inputs(strapSilentFor: 25, watchRoutedSilentFor: 25, latestWatchHR: 142),
                expected: displayOnly(142)
            ),
            Case(
                name: "tier-2 silence but manager no longer streaming — no point reconnecting a stopped stream",
                inputs: inputs(strapSilentFor: 30, watchRoutedSilentFor: 30, latestWatchHR: 142, isPolarStreaming: false),
                expected: displayOnly(142)
            ),
            Case(
                name: "tier-2 Polar silence but Watch-routed strap carrying it — watchdog AND wrist fallback both stay quiet",
                inputs: inputs(strapSilentFor: 300, watchRoutedSilentFor: 5, latestWatchHR: 142),
                expected: noEffects()
            )
        ]
    }

    /// The other two source modes: neither may ever fire the strap watchdog.
    private func sourceModeCases() -> [Case] {
        [
            Case(
                name: "watch mode — wrist HR always wins, even with fresh strap channels",
                inputs: inputs(sourceMode: .watch, strapSilentFor: 0, watchRoutedSilentFor: 0, latestWatchHR: 131),
                expected: displayOnly(131)
            ),
            Case(
                name: "watch mode with everything silent — watchdog never fires outside .strap mode",
                inputs: inputs(sourceMode: .watch, strapSilentFor: .infinity, watchRoutedSilentFor: .infinity, latestWatchHR: 131),
                expected: displayOnly(131)
            ),
            Case(
                name: "watch mode, no wrist reading yet — nothing to apply",
                inputs: inputs(sourceMode: .watch, latestWatchHR: nil),
                expected: noEffects()
            ),
            Case(
                name: "none mode — no HR at all, regardless of what the Watch reports",
                inputs: inputs(sourceMode: .none, strapSilentFor: .infinity, watchRoutedSilentFor: .infinity, latestWatchHR: 140),
                expected: noEffects()
            )
        ]
    }

    /// The workout-start window: `.infinity` here means "has not started",
    /// not "died". See `testLostWalkRegression…` below.
    private func startWindowCases() -> [Case] {
        [
            Case(
                name: "1 s into the workout, no beat has EVER landed — watchdog must hold; the strap has had no chance to speak",
                inputs: inputs(
                    recordingElapsedSeconds: 1,
                    strapSilentFor: .infinity, watchRoutedSilentFor: .infinity, latestWatchHR: nil
                ),
                expected: noEffects()
            ),
            Case(
                name: "1 s in, no beat ever, wrist HR available — display may fall back, but the watchdog still holds",
                inputs: inputs(
                    recordingElapsedSeconds: 1,
                    strapSilentFor: .infinity, watchRoutedSilentFor: .infinity, latestWatchHR: 142
                ),
                expected: displayOnly(142)
            ),
            Case(
                name: "elapsed exactly 25 s — the start window is strictly greater-than, same as the silence tiers",
                inputs: inputs(
                    recordingElapsedSeconds: 25,
                    strapSilentFor: .infinity, watchRoutedSilentFor: .infinity, latestWatchHR: nil
                ),
                expected: noEffects()
            ),
            Case(
                name: "elapsed 26 s and the strap never spoke — now it IS a dead channel, watchdog fires",
                inputs: inputs(
                    recordingElapsedSeconds: 26,
                    strapSilentFor: .infinity, watchRoutedSilentFor: .infinity, latestWatchHR: nil
                ),
                expected: Arbitration.Decision(
                    displayHRUpdate: nil, shouldForceReconnect: true, strapSilentLabel: "never"
                )
            )
        ]
    }

    // MARK: - SIGTRAP regression (FlowRecoveryCrash)

    /// The crash shape: `lastStrapHRAt` nil (no strap beat EVER landed this
    /// workout) → silence is `.infinity` → the pre-fix code computed
    /// `Int(strapSilent)` for the log label and trapped. The decision must
    /// fire the watchdog for this shape AND produce the infinity-safe
    /// "never" label without trapping.
    func testSIGTRAPRegressionInfiniteSilenceFiresWatchdogWithNeverLabel() {
        let decision = Arbitration.decide(inputs(
            strapSilentFor: .infinity,
            watchRoutedSilentFor: .infinity,
            watchdogCooldownFor: .infinity,
            latestWatchHR: nil
        ))
        XCTAssertTrue(decision.shouldForceReconnect)
        XCTAssertEqual(decision.strapSilentLabel, "never")
        XCTAssertNil(decision.displayHRUpdate)
    }

    // MARK: - Lost-walk regression

    /// From a field log. A walk starts; `PolarManager` logs "HR feature not
    /// ready at stream start — deferring subscription until ready" 4 ms later:
    /// the H10 subscription is deliberately held back until `feature_hr`
    /// fires, to avoid a `notificationNotEnabled` reconnect storm. 1.05 s in,
    /// before the strap could have sent anything, the tick watchdog logged
    /// "strap silent never — forcing reconnect" and kicked attempt 1/60,
    /// tearing down the very wait that prevents the storm. The process was
    /// gone before the next 5 s diagnostics heartbeat; recovery archived a
    /// 1-second session and the walk was lost.
    ///
    /// Every non-elapsed clause was legitimately true on that first tick, so
    /// no threshold change fixes it: `.infinity` at t≈0 means the channel has
    /// not started, not that it died.
    func testLostWalkRegressionWatchdogDoesNotFireOneSecondIntoTheWorkout() {
        let firstTick = inputs(
            recordingElapsedSeconds: 1,
            strapSilentFor: .infinity,
            watchRoutedSilentFor: .infinity,
            watchdogCooldownFor: .infinity,
            latestWatchHR: nil,
            isPolarStreaming: true
        )
        XCTAssertFalse(Arbitration.decide(firstTick).shouldForceReconnect)
        XCTAssertNil(Arbitration.decide(firstTick).strapSilentLabel)

        // The whole deferral window PolarManager is allowed (10 s) stays quiet.
        for elapsed in 0 ... Int(Arbitration.watchdogSilenceSec) {
            var tick = firstTick
            tick.recordingElapsedSeconds = elapsed
            XCTAssertFalse(
                Arbitration.decide(tick).shouldForceReconnect,
                "watchdog fired \(elapsed) s into the workout"
            )
        }
    }

    func testStrapSilentLabelIsInfinitySafe() {
        XCTAssertEqual(Arbitration.strapSilentLabel(forSilence: .infinity), "never")
    }

    func testStrapSilentLabelTruncatesFiniteSecondsLikeTheOriginal() {
        // Original inline code was `"\(Int(strapSilent)) s"` — truncation,
        // not rounding.
        XCTAssertEqual(Arbitration.strapSilentLabel(forSilence: 30.0), "30 s")
        XCTAssertEqual(Arbitration.strapSilentLabel(forSilence: 30.9), "30 s")
    }

    func testWatchdogLabelPresentExactlyWhenReconnectFires() {
        // Non-firing decisions must not carry a label (the shell logs only
        // on fire); firing decisions must always carry one.
        let quiet = Arbitration.decide(inputs(strapSilentFor: 2))
        XCTAssertFalse(quiet.shouldForceReconnect)
        XCTAssertNil(quiet.strapSilentLabel)

        let fired = Arbitration.decide(inputs(
            strapSilentFor: 26, watchRoutedSilentFor: 26, watchdogCooldownFor: .infinity
        ))
        XCTAssertTrue(fired.shouldForceReconnect)
        XCTAssertEqual(fired.strapSilentLabel, "26 s")
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
