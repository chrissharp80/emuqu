import CoreLocation
@testable import Emuqu
import os
import XCTest

/// Tests for `WorkoutAnalyzer`'s pure computation surface and for
/// `WorkoutThreshold`'s parser / evaluator.
///
/// Between them they own
/// the training-load numbers the whole app reasons about — TRIMP feeds ATL/CTL,
/// which feeds TSB and ACWR, which feeds the readiness verdict and the coach's
/// "should I train today" answer. An error here propagates into every downstream
/// surface silently, because the output is a plausible-looking number rather
/// than a crash.
///
/// The TRIMP assertions pin the published Banister formulation
/// (Morton, Fitz-Clarke & Banister, *J Appl Physiol* 1990) including the
/// sex-specific coefficients, because a regression there would be invisible.
final class WorkoutAnalyzerMathTests: XCTestCase {
    /// Capture-and-restore; `NSTimeZone.default` is
    /// process-global. See `ArchivePolicyTests`.
    private static let savedDefaultTimeZone = OSAllocatedUnfairLock<TimeZone?>(initialState: nil)

    override class func setUp() {
        super.setUp()
        savedDefaultTimeZone.withLock { $0 = NSTimeZone.default }
        NSTimeZone.default = TestTimeZone.utc
    }

    override class func tearDown() {
        if let saved = savedDefaultTimeZone.withLock({ $0 }) { NSTimeZone.default = saved }
        savedDefaultTimeZone.withLock { $0 = nil }
        super.tearDown()
    }

    // MARK: - Distance and elevation

    func testDistanceOfDegenerateTrackIsZero() {
        XCTAssertEqual(WorkoutAnalyzer.computeDistance(track: []), 0)
        XCTAssertEqual(WorkoutAnalyzer.computeDistance(track: [fix(lat: 39.78, lon: -89.65)]), 0,
                       "a single fix has no segment to measure")
    }

    /// One degree of latitude is ~111.19 km. A 0.01° step should be ~1,111 m.
    func testDistanceAccumulatesAcrossSegments() {
        let track = [
            fix(lat: 39.7800, lon: -89.65),
            fix(lat: 39.7900, lon: -89.65),
            fix(lat: 39.8000, lon: -89.65)
        ]
        let d = WorkoutAnalyzer.computeDistance(track: track)
        XCTAssertEqual(d, 2223, accuracy: 40, "two 0.01° latitude steps ≈ 2,223 m")
    }

    /// Gain counts only the up-moves.
    func testElevationGainCountsOnlyUpMoves() {
        let alts: [Double] = [100, 120, 110, 150, 130]
        let track = alts.enumerated().map { i, a in
            fix(lat: 39.78 + Double(i) * 0.001, lon: -89.65, alt: a)
        }
        // ups: +20, +40 = 60.
        XCTAssertEqual(WorkoutAnalyzer.computeElevationGain(track: track), 60, accuracy: 0.001)
    }

    func testElevationOfFlatTrackIsZero() {
        let track = (0 ..< 5).map { i in fix(lat: 39.78 + Double(i) * 0.001, lon: -89.65, alt: 200) }
        XCTAssertEqual(WorkoutAnalyzer.computeElevationGain(track: track), 0)
    }

    func testElevationOfDegenerateTrackIsZero() {
        XCTAssertEqual(WorkoutAnalyzer.computeElevationGain(track: []), 0)
        XCTAssertEqual(WorkoutAnalyzer.computeElevationGain(track: [fix(lat: 1, lon: 1, alt: 50)]), 0)
    }

    // MARK: - TRIMP

    /// Below the 30-beat floor there is not enough signal to publish a number,
    /// and publishing a small one would understate load rather than omit it.
    func testTrimpRequiresMinimumBeatCount() {
        XCTAssertNil(WorkoutAnalyzer.computeTRIMP(rrPoints: beats(count: 29, rrMs: 500)))
        XCTAssertNotNil(WorkoutAnalyzer.computeTRIMP(rrPoints: beats(count: 30, rrMs: 500)))
    }

    /// With both anchors present the Banister path is taken and produces a
    /// positive, finite load.
    func testTrimpWithBothAnchorsIsPositiveAndFinite() throws {
        let trimp = try XCTUnwrap(
            WorkoutAnalyzer.computeTRIMP(rrPoints: beats(count: 600, rrMs: 500), userMaxHR: 190, userRestingHR: 50)
        )
        XCTAssertGreaterThan(trimp, 0)
        XCTAssertTrue(trimp.isFinite)
    }

    /// Harder work over the same beat count must score higher. 400 ms RR = 150
    /// bpm; 800 ms RR = 75 bpm.
    func testTrimpRisesWithIntensity() throws {
        let easy = try XCTUnwrap(
            WorkoutAnalyzer.computeTRIMP(rrPoints: beats(count: 600, rrMs: 800), userMaxHR: 190, userRestingHR: 50)
        )
        let hard = try XCTUnwrap(
            WorkoutAnalyzer.computeTRIMP(rrPoints: beats(count: 600, rrMs: 400), userMaxHR: 190, userRestingHR: 50)
        )
        XCTAssertGreaterThan(hard, easy, "150 bpm must score more load than 75 bpm")
    }

    /// Longer duration at the same intensity must score higher — TRIMP is an
    /// integral, not an average.
    func testTrimpRisesWithDuration() throws {
        let short = try XCTUnwrap(
            WorkoutAnalyzer.computeTRIMP(rrPoints: beats(count: 300, rrMs: 500), userMaxHR: 190, userRestingHR: 50)
        )
        let long = try XCTUnwrap(
            WorkoutAnalyzer.computeTRIMP(rrPoints: beats(count: 1200, rrMs: 500), userMaxHR: 190, userRestingHR: 50)
        )
        XCTAssertGreaterThan(long, short)
        XCTAssertEqual(long / short, 4.0, accuracy: 0.05, "4× the beats at one intensity is 4× the load")
    }

    /// The published Banister integral for one hour at a given HRR fraction.
    /// Male: A = 0.64, b = 1.92. 60 min at HRR 0.5 →
    /// 60 × 0.5 × 0.64 × e^(1.92 × 0.5) = 50.1.
    func testBanisterMaleCoefficientsMatchPublishedFormula() {
        let hrs = Array(repeating: (120.0, 1.0), count: 3600) // HR 120, 1s each
        // HRR = (120 − 50) / (190 − 50) = 0.5
        let trimp = WorkoutAnalyzer.banisterTRIMP(hrs: hrs, maxHR: 190, restHR: 50, sex: .male)
        let expected = 60.0 * 0.5 * 0.64 * exp(1.92 * 0.5)
        XCTAssertEqual(trimp, expected, accuracy: 0.01, "male coefficients A=0.64 b=1.92")
    }

    /// Female: A = 0.86, b = 1.67. Same HRR and duration.
    func testBanisterFemaleCoefficientsMatchPublishedFormula() {
        let hrs = Array(repeating: (120.0, 1.0), count: 3600)
        let trimp = WorkoutAnalyzer.banisterTRIMP(hrs: hrs, maxHR: 190, restHR: 50, sex: .female)
        let expected = 60.0 * 0.5 * 0.86 * exp(1.67 * 0.5)
        XCTAssertEqual(trimp, expected, accuracy: 0.01, "female coefficients A=0.86 b=1.67")
    }

    /// The exponential weighting means the sexes diverge, and they must not be
    /// silently interchangeable.
    func testBanisterSexCoefficientsDiffer() {
        let hrs = Array(repeating: (160.0, 1.0), count: 1800)
        let male = WorkoutAnalyzer.banisterTRIMP(hrs: hrs, maxHR: 190, restHR: 50, sex: .male)
        let female = WorkoutAnalyzer.banisterTRIMP(hrs: hrs, maxHR: 190, restHR: 50, sex: .female)
        XCTAssertNotEqual(male, female, accuracy: 0.0001)
    }

    /// Zero-length RR entries must not produce infinities.
    func testTrimpIgnoresZeroLengthBeats() {
        let mixed = (0 ..< 200).map { i -> RRPoint in
            let rrMs: Int = i.isMultiple(of: 2) ? 500 : 0
            return RRPoint(t_ms: Int64(i * 500), rr_ms: rrMs)
        }
        let trimp = WorkoutAnalyzer.computeTRIMP(rrPoints: mixed, userMaxHR: 190, userRestingHR: 50)
        if let trimp {
            XCTAssertTrue(trimp.isFinite, "a zero RR must be skipped, not divided by")
            XCTAssertGreaterThanOrEqual(trimp, 0)
        }
    }

    /// hrTSS requires HRmax and HRrest — without a heart-rate reserve there is
    /// nothing to anchor against, so it publishes nothing.
    func testHrTSSRequiresHRMaxAndHRRest() {
        let rr = beats(count: 600, rrMs: 500)
        XCTAssertNil(WorkoutAnalyzer.computeHrTSS(rrPoints: rr, userMaxHR: nil, userRestingHR: 50, userLTHR: 165))
        XCTAssertNil(WorkoutAnalyzer.computeHrTSS(rrPoints: rr, userMaxHR: 190, userRestingHR: nil, userLTHR: 165))
        XCTAssertNotNil(WorkoutAnalyzer.computeHrTSS(rrPoints: rr, userMaxHR: 190, userRestingHR: 50, userLTHR: 165))
    }

    /// LTHR, by contrast, is OPTIONAL — it falls back to 0.88 × HRmax, the
    /// standard population approximation.
    ///
    /// Pinned because the source comment claimed the opposite ("if
    /// any is missing, skip hrTSS"). The comment was stale; the fallback had
    /// always been there. Whichever way this behaviour is later decided, the
    /// test now makes the choice explicit instead of leaving code and comment
    /// disagreeing.
    func testHrTSSFallsBackToEightyEightPercentOfMaxWhenLTHRAbsent() throws {
        let rr = beats(count: 600, rrMs: 500)
        let withoutLTHR = try XCTUnwrap(
            WorkoutAnalyzer.computeHrTSS(rrPoints: rr, userMaxHR: 190, userRestingHR: 50, userLTHR: nil)
        )
        let withEquivalentLTHR = try XCTUnwrap(
            WorkoutAnalyzer.computeHrTSS(rrPoints: rr, userMaxHR: 190, userRestingHR: 50, userLTHR: Int(190.0 * 0.88))
        )
        XCTAssertEqual(
            withoutLTHR, withEquivalentLTHR, accuracy: 0.5,
            "a missing LTHR must behave as 0.88 × HRmax"
        )
    }

    /// A higher LTHR means a harder reference hour, so the same session scores
    /// a lower hrTSS against it.
    func testHrTSSFallsAsLTHRRises() throws {
        let rr = beats(count: 600, rrMs: 500)
        let lowLT = try XCTUnwrap(
            WorkoutAnalyzer.computeHrTSS(rrPoints: rr, userMaxHR: 190, userRestingHR: 50, userLTHR: 150)
        )
        let highLT = try XCTUnwrap(
            WorkoutAnalyzer.computeHrTSS(rrPoints: rr, userMaxHR: 190, userRestingHR: 50, userLTHR: 175)
        )
        XCTAssertLessThan(highLT, lowLT, "a harder reference hour must lower the same session's hrTSS")
    }

    // MARK: - WorkoutThreshold: evaluate

    func testGreaterThanFiresOnlyAboveValue() {
        let t = WorkoutThreshold(metric: .heartRateBPM, condition: .greaterThan, value: 160)
        XCTAssertEqual(evaluateHR(t, 170), true)
        XCTAssertEqual(evaluateHR(t, 150), false)
    }

    func testLessThanFiresOnlyBelowValue() {
        let t = WorkoutThreshold(metric: .heartRateBPM, condition: .lessThan, value: 120)
        XCTAssertEqual(evaluateHR(t, 110), true)
        XCTAssertEqual(evaluateHR(t, 130), false)
    }

    /// A missing observation is `nil` — "unknown", distinct from "not breached".
    /// Conflating them would make the coach cue on absent data.
    func testMissingObservationIsUnknownNotFalse() {
        let t = WorkoutThreshold(metric: .powerWatts, condition: .greaterThan, value: 250)
        let result = t.evaluate(
            hrBPM: 150, hrZone: nil, powerWatts: nil, ftpWatts: nil,
            paceSecPerKm: nil, alpha1: nil, cadenceSPM: nil
        )
        XCTAssertNil(result, "absent power must be unknown, not a non-breach")
    }

    /// α1 thresholds read the other way round — falling α1 means going anaerobic.
    func testAlpha1LessThanThreshold() {
        let t = WorkoutThreshold(metric: .alpha1, condition: .lessThan, value: 0.75)
        let breached = t.evaluate(
            hrBPM: nil, hrZone: nil, powerWatts: nil, ftpWatts: nil,
            paceSecPerKm: nil, alpha1: 0.60, cadenceSPM: nil
        )
        XCTAssertEqual(breached, true)
    }

    func testDistanceAndElapsedThresholdsEvaluate() {
        let dist = WorkoutThreshold(metric: .distanceMeters, condition: .greaterThan, value: 5000)
        XCTAssertEqual(
            dist.evaluate(hrBPM: nil, hrZone: nil, powerWatts: nil, ftpWatts: nil,
                          paceSecPerKm: nil, alpha1: nil, cadenceSPM: nil, distanceMeters: 6000),
            true
        )
        let elapsed = WorkoutThreshold(metric: .elapsedSec, condition: .greaterThan, value: 3600)
        XCTAssertEqual(
            elapsed.evaluate(hrBPM: nil, hrZone: nil, powerWatts: nil, ftpWatts: nil,
                             paceSecPerKm: nil, alpha1: nil, cadenceSPM: nil, elapsedSec: 1800),
            false
        )
    }

    // MARK: - WorkoutThreshold: init clamping

    /// Debounce cannot go negative and cooldown has a 10 s floor — otherwise a
    /// malformed threshold could make the coach talk continuously.
    func testInitClampsDebounceAndCooldown() {
        let t = WorkoutThreshold(
            metric: .heartRateBPM, condition: .greaterThan, value: 160,
            debounceSec: -5, cooldownSec: 1
        )
        XCTAssertEqual(t.debounceSec, 0, "negative debounce clamps to 0")
        XCTAssertEqual(t.cooldownSec, 10, "cooldown floors at 10s so cues can't spam")
    }

    // MARK: - WorkoutThreshold: plain-text parser

    func testParsesElapsedTimePhrases() throws {
        for (text, seconds) in [("30 minutes", 1800.0), ("1 hour", 3600.0), ("1.5 hr", 5400.0), ("90 secs", 90.0)] {
            let t = try XCTUnwrap(WorkoutThreshold.parsePlainText(text), "failed to parse '\(text)'")
            XCTAssertEqual(t.metric, .elapsedSec, "'\(text)' should be an elapsed-time threshold")
            XCTAssertEqual(t.value, seconds, accuracy: 0.01, "'\(text)' should be \(seconds)s")
        }
    }

    func testParsesDistancePhrases() throws {
        let miles = try XCTUnwrap(WorkoutThreshold.parsePlainText("5 miles"))
        XCTAssertEqual(miles.metric, .distanceMeters)
        XCTAssertEqual(miles.value, 5 * 1609.344, accuracy: 0.01)

        let km = try XCTUnwrap(WorkoutThreshold.parsePlainText("10 km"))
        XCTAssertEqual(km.metric, .distanceMeters)
        XCTAssertEqual(km.value, 10_000, accuracy: 0.01)
    }

    /// One-shot thresholds (a distance or time marker) get a huge cooldown so
    /// they announce once and stay quiet.
    func testMarkerThresholdsAreOneShot() throws {
        let t = try XCTUnwrap(WorkoutThreshold.parsePlainText("5 miles"))
        XCTAssertEqual(t.debounceSec, 0, "a distance marker should fire immediately, not debounce")
        XCTAssertGreaterThan(t.cooldownSec, 100_000, "markers are one-shot")
    }

    /// The original phrasing is preserved as the spoken cue.
    func testParserPreservesOriginalTextAsCue() throws {
        let t = try XCTUnwrap(WorkoutThreshold.parsePlainText("30 minutes"))
        XCTAssertEqual(t.userCue, "30 minutes")
    }

    func testParserRejectsEmptyAndUnparseableInput() {
        XCTAssertNil(WorkoutThreshold.parsePlainText(""))
        XCTAssertNil(WorkoutThreshold.parsePlainText("   "))
        XCTAssertNil(WorkoutThreshold.parsePlainText("something with no measurable quantity"))
    }

    /// The natural-language escape hatch keeps the free text and does not
    /// pretend to be a numeric threshold.
    func testNaturalLanguageFactoryKeepsText() {
        let t = WorkoutThreshold.naturalLanguage(text: "tell me when I'm halfway through")
        XCTAssertEqual(t.metric, .naturalLanguage)
        XCTAssertEqual(t.naturalLanguageText, "tell me when I'm halfway through")
        XCTAssertEqual(t.userCue, "tell me when I'm halfway through", "cue defaults to the text")
    }

    /// Every metric must round-trip through Codable — thresholds are persisted
    /// with the session and a lost case would silently drop a user's alert.
    func testEveryMetricRoundTripsThroughCodable() throws {
        for metric in WorkoutThreshold.Metric.allCases {
            let original = WorkoutThreshold(metric: metric, condition: .greaterThan, value: 42)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(WorkoutThreshold.self, from: data)
            XCTAssertEqual(decoded.metric, metric, "\(metric.rawValue) failed to round-trip")
            XCTAssertEqual(decoded.value, 42)
            XCTAssertEqual(decoded, original)
        }
    }

    // MARK: - Fixtures

    private func fix(lat: Double, lon: Double, alt: Double = 0) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: alt, horizontalAccuracy: 5, verticalAccuracy: 5,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func beats(count: Int, rrMs: Int) -> [RRPoint] {
        var t: Int64 = 0
        return (0 ..< count).map { _ in
            let p = RRPoint(t_ms: t, rr_ms: rrMs)
            t += Int64(rrMs)
            return p
        }
    }

    private func evaluateHR(_ t: WorkoutThreshold, _ hr: Int) -> Bool? {
        t.evaluate(
            hrBPM: hr, hrZone: nil, powerWatts: nil, ftpWatts: nil,
            paceSecPerKm: nil, alpha1: nil, cadenceSPM: nil
        )
    }
}
