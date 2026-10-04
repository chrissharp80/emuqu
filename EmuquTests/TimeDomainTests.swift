@testable import Emuqu
import XCTest

/// Time domain HRV analysis tests
final class TimeDomainTests: XCTestCase {
    // MARK: - RMSSD Tests

    /// RMSSD equals the hand-computed value for a known pattern
    func testRMSSDAccuracy() throws {
        // Create known RR intervals with calculable RMSSD
        // Need at least 10 points for TimeDomain analysis
        // Using pattern: 800, 820, 790, 830, 780, repeated twice
        // Successive diffs: 20, -30, 40, -50, 20, 20, -30, 40, -50
        // (the fifth is the 780 → 800 wraparound)
        // Squares: 400, 900, 1600, 2500, 400, 400, 900, 1600, 2500 = 11200
        // RMSSD = sqrt(11200 / 9) ≈ 35.28

        let basePattern = [800, 820, 790, 830, 780]
        var points: [RRPoint] = []
        var t_ms: Int64 = 0

        for _ in 0 ..< 2 {
            for rr in basePattern {
                points.append(RRPoint(t_ms: t_ms, rr_ms: rr))
                t_ms += Int64(rr)
            }
        }
        // Total: 10 points

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        let m = try XCTUnwrap(metrics)

        let expectedRMSSD = (11_200.0 / 9.0).squareRoot()
        XCTAssertEqual(
            m.rmssd,
            expectedRMSSD,
            accuracy: 0.01,
            "RMSSD must equal the hand-computed reference. Expected \(expectedRMSSD), got \(m.rmssd)"
        )
    }

    /// Test pNN50 calculation
    func testPNN50() throws {
        // Create intervals where some diffs > 50ms
        // Need at least 10 points for TimeDomain analysis
        // Pattern: 800, 860(+60), 840(-20), 895(+55), 865(-30), 935(+70), 900(-35), 820(-80), 880(+60), 830(-50), 890(+60)
        // Diffs > 50: +60, +55, +70, -80, +60, +60 = 6 out of 10 = 60%
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 860), // +60
            RRPoint(t_ms: 1660, rr_ms: 840), // -20
            RRPoint(t_ms: 2500, rr_ms: 895), // +55
            RRPoint(t_ms: 3395, rr_ms: 865), // -30
            RRPoint(t_ms: 4260, rr_ms: 935), // +70
            RRPoint(t_ms: 5195, rr_ms: 900), // -35
            RRPoint(t_ms: 6095, rr_ms: 820), // -80
            RRPoint(t_ms: 6915, rr_ms: 880), // +60
            RRPoint(t_ms: 7795, rr_ms: 830), // -50
            RRPoint(t_ms: 8625, rr_ms: 890) // +60
        ]

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        let m = try XCTUnwrap(metrics)
        XCTAssertEqual(
            m.pnn50,
            60.0,
            accuracy: 0.1,
            "pNN50 should be 60%. Got \(m.pnn50)"
        )
    }

    /// Test SDNN calculation
    func testSDNN() throws {
        // Need at least 10 points for TimeDomain analysis
        // RR intervals: 800, 900, 700, 850, 750, 800, 900, 700, 850, 750
        // Mean: 800
        // Variance and SD should be consistent with pattern

        let pattern = [800, 900, 700, 850, 750]
        var points: [RRPoint] = []
        var t_ms: Int64 = 0

        for _ in 0 ..< 2 {
            for rr in pattern {
                points.append(RRPoint(t_ms: t_ms, rr_ms: rr))
                t_ms += Int64(rr)
            }
        }
        // Total: 10 points

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        XCTAssertNotNil(metrics)

        // With repeated pattern [800, 900, 700, 850, 750], mean is 800
        // SDNN should still be around 79 since pattern repeats
        // Just verify it's in a reasonable range
        XCTAssertGreaterThan(try XCTUnwrap(metrics?.sdnn), 70, "SDNN should be > 70 for this pattern")
        XCTAssertLessThan(try XCTUnwrap(metrics?.sdnn), 90, "SDNN should be < 90 for this pattern")
    }

    /// Test mean RR and HR
    func testMeanRRAndHR() throws {
        // RR intervals averaging 750ms = 80 bpm
        // Need at least 10 points for TimeDomain analysis
        let points = [
            RRPoint(t_ms: 0, rr_ms: 700),
            RRPoint(t_ms: 700, rr_ms: 750),
            RRPoint(t_ms: 1450, rr_ms: 800),
            RRPoint(t_ms: 2250, rr_ms: 750),
            RRPoint(t_ms: 3000, rr_ms: 750),
            RRPoint(t_ms: 3750, rr_ms: 740),
            RRPoint(t_ms: 4490, rr_ms: 760),
            RRPoint(t_ms: 5250, rr_ms: 750),
            RRPoint(t_ms: 6000, rr_ms: 750),
            RRPoint(t_ms: 6750, rr_ms: 750)
        ]

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        let m = try XCTUnwrap(metrics)
        XCTAssertEqual(
            m.meanRR,
            750,
            accuracy: 1,
            "Mean RR should be 750ms. Got \(m.meanRR)"
        )
        XCTAssertEqual(
            m.meanHR,
            80,
            accuracy: 1,
            "Mean HR should be 80 bpm. Got \(m.meanHR)"
        )
    }

    // MARK: - Artifact Exclusion

    /// Artifacts should be excluded from calculations
    func testArtifactExclusion() throws {
        // Need at least 10 clean points after excluding artifacts
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 810),
            RRPoint(t_ms: 1610, rr_ms: 400), // Artifact - should be excluded
            RRPoint(t_ms: 2010, rr_ms: 790),
            RRPoint(t_ms: 2800, rr_ms: 800),
            RRPoint(t_ms: 3600, rr_ms: 805),
            RRPoint(t_ms: 4405, rr_ms: 795),
            RRPoint(t_ms: 5200, rr_ms: 800),
            RRPoint(t_ms: 6000, rr_ms: 810),
            RRPoint(t_ms: 6810, rr_ms: 790),
            RRPoint(t_ms: 7600, rr_ms: 800)
        ]

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        flags[2] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)
        // 11 points total, 10 clean after excluding artifact

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())

        let metrics = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        let m = try XCTUnwrap(metrics)

        // Mean should be based on clean beats only: (800 + 810 + 790 + 800) / 4 = 800
        XCTAssertEqual(
            m.meanRR,
            800,
            accuracy: 1,
            "Mean RR should exclude artifacts. Got \(m.meanRR)"
        )
    }

    /// A flagged beat is skipped, not bridged: the beats either side of it
    /// were never neighbours, so their difference is not part of RMSSD.
    func testRMSSDDoesNotBridgeARemovedBeat() throws {
        // Every true successive difference is ±10 ms; the level steps from
        // ~800 to ~900 at beat 7. Beat 6 is flagged, and bridging beat 5
        // (810) to beat 7 (910) would add a 100 ms difference.
        let rrs = (0 ..< 14).map { ($0 < 7 ? 800 : 900) + ($0.isMultiple(of: 2) ? 0 : 10) }
        var t: Int64 = 0
        let points = rrs.map { rr -> RRPoint in
            defer { t += Int64(rr) }
            return RRPoint(t_ms: t, rr_ms: rr)
        }
        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        flags[6] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let metrics = try XCTUnwrap(TimeDomainAnalyzer.computeTimeDomain(
            series, flags: flags, windowStart: 0, windowEnd: points.count
        ))
        XCTAssertEqual(metrics.rmssd, 10, accuracy: 1e-9, "A difference across the removed beat must not count")
    }

    // MARK: - Edge Cases

    /// Insufficient data should return nil
    func testInsufficientData() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 810)
        ]

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        XCTAssertNil(metrics, "Should return nil for insufficient data")
    }

    /// Window bounds should be respected
    func testWindowBounds() {
        let points = (0 ..< 20).map { i -> RRPoint in
            let offsetMs = Int64(i * 800)
            let alternation: Int = i.isMultiple(of: 2) ? 20 : -20
            return RRPoint(t_ms: offsetMs, rr_ms: 800 + alternation)
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        // Analyze only middle 10 beats
        let metrics = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 5,
            windowEnd: 15
        )

        XCTAssertNotNil(metrics)
        // Should analyze exactly 10 beats
    }

    // MARK: - Statistics Parity (routed through Utilities/Statistics)

    /// SDNN parity: exact sample standard deviation (N-1 denominator) of the RR
    /// intervals, since the SD helper now delegates to Statistics.sampleStandardDeviation.
    func testSDNNParityExact() throws {
        // Pattern [800, 900, 700, 850, 750] x2 → mean 800, sumSqDev 50000,
        // sample variance 50000/9 = 5555.5556, sample SD = sqrt(5555.5556) ≈ 74.5356
        let pattern = [800, 900, 700, 850, 750]
        var points: [RRPoint] = []
        var t_ms: Int64 = 0
        for _ in 0 ..< 2 {
            for rr in pattern {
                points.append(RRPoint(t_ms: t_ms, rr_ms: rr))
                t_ms += Int64(rr)
            }
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = TimeDomainAnalyzer.computeTimeDomain(
            series, flags: flags, windowStart: 0, windowEnd: points.count
        )

        XCTAssertEqual(try XCTUnwrap(metrics?.sdnn), 74.53559924999298, accuracy: 1e-6)
    }

    /// RMSSD parity: exact root mean square of successive differences, since the
    /// RMS helper now delegates to Statistics.rootMeanSquare.
    func testRMSSDParityExact() throws {
        // Pattern [800, 820, 790, 830, 780] x2 → successive diffs
        // [20, -30, 40, -50, 20, 20, -30, 40, -50] (9 diffs, including the
        // 780→800 wraparound), RMSSD = sqrt(8400/9) ≈ 35.27668.
        let pattern = [800, 820, 790, 830, 780]
        var points: [RRPoint] = []
        var t_ms: Int64 = 0
        for _ in 0 ..< 2 {
            for rr in pattern {
                points.append(RRPoint(t_ms: t_ms, rr_ms: rr))
                t_ms += Int64(rr)
            }
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = TimeDomainAnalyzer.computeTimeDomain(
            series, flags: flags, windowStart: 0, windowEnd: points.count
        )

        XCTAssertEqual(try XCTUnwrap(metrics?.rmssd), 35.276684147527874, accuracy: 1e-6)
    }
    // MARK: - Stored sensor HR vs the RR-derived fallback
    //
    // When the Polar sensor reported HR alongside the beats, that reading is
    // preferred. When every stored-HR point in the window was artifact-rejected
    // the answer must be "no stored HR", so the caller derives a real figure
    // from the window's clean beats instead. Fabricating a sentinel biases the
    // RHR z-score the recovery score is built on — and nothing asserted it
    // until a mutation planting a 60 bpm sentinel survived this suite.

    /// 800 ms beats are 75 bpm. With every stored-HR point flagged as an
    /// artifact, the window still has to report ~75 from the beats — not the
    /// 60 bpm a sentinel would supply.
    func testAllStoredHRArtifactsFallsBackToTheBeatsNotASentinel() throws {
        var points: [RRPoint] = []
        var t: Int64 = 0
        // Ten clean beats with no stored HR at all, then two artifact beats
        // that DO carry a stored HR — so the stored path is entered and then
        // finds nothing usable.
        for _ in 0 ..< 10 {
            points.append(RRPoint(t_ms: t, rr_ms: 800))
            t += 800
        }
        for _ in 0 ..< 2 {
            points.append(RRPoint(t_ms: t, rr_ms: 800, wallClockMs: nil, hr: 200))
            t += 800
        }
        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        flags[10] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)
        flags[11] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let metrics = try XCTUnwrap(TimeDomainAnalyzer.computeTimeDomain(
            series, flags: flags, windowStart: 0, windowEnd: points.count
        ))
        XCTAssertEqual(metrics.meanHR, 75, accuracy: 2,
                       "800 ms beats are 75 bpm; a fabricated sentinel would read ~60")
        XCTAssertNotEqual(metrics.meanHR, 60, accuracy: 1)
    }

    /// The other side of the same rule: when stored HR IS usable it is used,
    /// rather than being recomputed from the intervals.
    func testUsableStoredHRIsPreferredOverTheRRDerivedFigure() throws {
        var points: [RRPoint] = []
        var t: Int64 = 0
        // 800 ms beats would give 75 bpm, but the sensor says 88.
        for _ in 0 ..< 12 {
            points.append(RRPoint(t_ms: t, rr_ms: 800, wallClockMs: nil, hr: 88))
            t += 800
        }
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let metrics = try XCTUnwrap(TimeDomainAnalyzer.computeTimeDomain(
            series, flags: flags, windowStart: 0, windowEnd: points.count
        ))
        XCTAssertEqual(metrics.meanHR, 88, accuracy: 0.5,
                       "the sensor's own reading is preferred when it survives artifact rejection")
    }

    /// Task Force RMSSD differences ADJACENT beats. Beats either side of a
    /// recording break (here a 10 s pause on the session timeline) are
    /// neighbours in the array but not in the heart, so the jump across the
    /// break is left out: every remaining difference is 20 ms.
    func testNoSuccessiveDifferenceAcrossARecordingBreak() throws {
        var points: [RRPoint] = []
        var t: Int64 = 0
        for i in 0 ..< 16 {
            let rr = i.isMultiple(of: 2) ? 800 : 820
            points.append(RRPoint(t_ms: t, rr_ms: rr))
            t += Int64(rr)
        }
        t += 10_000
        for i in 0 ..< 16 {
            let rr = i.isMultiple(of: 2) ? 900 : 920
            points.append(RRPoint(t_ms: t, rr_ms: rr))
            t += Int64(rr)
        }
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let metrics = try XCTUnwrap(TimeDomainAnalyzer.computeTimeDomain(
            series, flags: flags, windowStart: 0, windowEnd: points.count
        ))
        XCTAssertEqual(metrics.rmssd, 20, accuracy: 1e-9)
        XCTAssertEqual(TimeDomainAnalyzer.beatsAfterRecordingBreak(in: points, range: points.indices), [16])
    }

    /// A streamed beat whose arrival clock jumped past a Bluetooth dropout is a
    /// break even though the beat timeline (cumulative RR) shows none.
    func testArrivalClockDropoutIsARecordingBreak() {
        let before = RRPoint(t_ms: 0, rr_ms: 800, wallClockMs: 1_000, hr: nil)
        let sameBatch = RRPoint(t_ms: 800, rr_ms: 800, wallClockMs: 1_000, hr: nil)
        let afterDropout = RRPoint(t_ms: 800, rr_ms: 800, wallClockMs: 9_000, hr: nil)
        XCTAssertFalse(TimeDomainAnalyzer.isRecordingBreak(between: before, and: sameBatch))
        XCTAssertTrue(TimeDomainAnalyzer.isRecordingBreak(between: before, and: afterDropout))
    }
}
