@testable import Emuqu
import XCTest

/// Extended artifact detection and correction tests
final class ArtifactCorrectionTests: XCTestCase {
    let detector = ArtifactDetector()

    // MARK: - Correction Method Tests

    /// Test deletion correction
    func testDeletionCorrection() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 810),
            RRPoint(t_ms: 1610, rr_ms: 300), // Artifact
            RRPoint(t_ms: 1910, rr_ms: 820),
            RRPoint(t_ms: 2730, rr_ms: 800)
        ]

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        flags[2] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)

        let rrValues = points.map(\.rr_ms)

        let (corrected, newFlags) = ArtifactCorrector.correct(
            rrValues: rrValues,
            flags: flags,
            method: .deletion
        )

        // Should have one fewer value
        XCTAssertEqual(corrected.count, points.count - 1)

        // Artifact should be gone
        XCTAssertFalse(newFlags.contains { $0.isArtifact })
    }

    /// Test linear interpolation correction
    func testLinearInterpolation() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 810),
            RRPoint(t_ms: 1610, rr_ms: 300), // Artifact - should interpolate to ~820
            RRPoint(t_ms: 1910, rr_ms: 830),
            RRPoint(t_ms: 2740, rr_ms: 840)
        ]

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        flags[2] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)

        let rrValues = points.map(\.rr_ms)

        let (corrected, newFlags) = ArtifactCorrector.correct(
            rrValues: rrValues,
            flags: flags,
            method: .linearInterpolation
        )

        // Should maintain same length
        XCTAssertEqual(corrected.count, points.count)

        // Corrected value should be reasonable (between 810 and 830)
        XCTAssertGreaterThan(corrected[2], 800)
        XCTAssertLessThan(corrected[2], 850)

        // Flag should show correction
        XCTAssertTrue(newFlags[2].corrected)
        XCTAssertFalse(newFlags[2].isArtifact)
    }

    /// Test cubic interpolation
    func testCubicInterpolation() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 820),
            RRPoint(t_ms: 1620, rr_ms: 850),
            RRPoint(t_ms: 2470, rr_ms: 200), // Artifact
            RRPoint(t_ms: 2670, rr_ms: 900),
            RRPoint(t_ms: 3570, rr_ms: 920),
            RRPoint(t_ms: 4490, rr_ms: 930)
        ]

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        flags[3] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)

        let rrValues = points.map(\.rr_ms)

        let (corrected, newFlags) = ArtifactCorrector.correct(
            rrValues: rrValues,
            flags: flags,
            method: .cubicSpline
        )

        // Should maintain length
        XCTAssertEqual(corrected.count, points.count)

        // Cubic should provide smooth interpolation
        XCTAssertGreaterThan(corrected[3], 850)
        XCTAssertLessThan(corrected[3], 920)

        XCTAssertTrue(newFlags[3].corrected)
    }

    /// Test median replacement
    func testMedianReplacement() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 795),
            RRPoint(t_ms: 795, rr_ms: 800),
            RRPoint(t_ms: 1595, rr_ms: 805),
            RRPoint(t_ms: 2400, rr_ms: 200), // Artifact
            RRPoint(t_ms: 2600, rr_ms: 810),
            RRPoint(t_ms: 3410, rr_ms: 815),
            RRPoint(t_ms: 4225, rr_ms: 820)
        ]

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        flags[3] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)

        let rrValues = points.map(\.rr_ms)

        let (corrected, newFlags) = ArtifactCorrector.correct(
            rrValues: rrValues,
            flags: flags,
            method: .median
        )

        // Median of surrounding clean values should be ~808
        XCTAssertGreaterThan(corrected[3], 795)
        XCTAssertLessThan(corrected[3], 820)

        XCTAssertTrue(newFlags[3].corrected)
    }

    // MARK: - Multiple Consecutive Artifacts

    /// Test handling consecutive artifacts
    func testConsecutiveArtifacts() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 810),
            RRPoint(t_ms: 1610, rr_ms: 200), // Artifact 1
            RRPoint(t_ms: 1810, rr_ms: 250), // Artifact 2
            RRPoint(t_ms: 2060, rr_ms: 220), // Artifact 3
            RRPoint(t_ms: 2280, rr_ms: 830),
            RRPoint(t_ms: 3110, rr_ms: 840)
        ]

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        flags[2] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)
        flags[3] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)
        flags[4] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)

        let rrValues = points.map(\.rr_ms)

        let (corrected, newFlags) = ArtifactCorrector.correct(
            rrValues: rrValues,
            flags: flags,
            method: .linearInterpolation
        )

        // All three should be corrected
        for i in 2 ... 4 {
            XCTAssertTrue(
                newFlags[i].corrected,
                "Artifact at index \(i) should be corrected"
            )
            XCTAssertGreaterThan(
                corrected[i],
                700,
                "Corrected value should be reasonable"
            )
            XCTAssertLessThan(
                corrected[i],
                900,
                "Corrected value should be reasonable"
            )
        }
    }

    /// Test very long artifact sequence
    func testLongArtifactSequence() {
        var points = [RRPoint]()
        points.append(RRPoint(t_ms: 0, rr_ms: 800))
        points.append(RRPoint(t_ms: 800, rr_ms: 810))

        // Add 20 consecutive artifacts
        for i in 0 ..< 20 {
            points.append(RRPoint(t_ms: Int64(1600 + i * 300), rr_ms: 200))
        }

        points.append(RRPoint(t_ms: 7600, rr_ms: 820))
        points.append(RRPoint(t_ms: 8420, rr_ms: 830))

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        for i in 2 ..< 22 {
            flags[i] = ArtifactFlags(isArtifact: true, type: .technical, confidence: 1.0)
        }

        let rrValues = points.map(\.rr_ms)

        let (corrected, _) = ArtifactCorrector.correct(
            rrValues: rrValues,
            flags: flags,
            method: .linearInterpolation
        )

        // Should interpolate smoothly across long gap
        for i in 2 ..< 22 {
            XCTAssertGreaterThan(corrected[i], 700)
            XCTAssertLessThan(corrected[i], 900)
        }
    }

    // MARK: - Edge Case Correction

    /// Test artifact at beginning
    func testArtifactAtBeginning() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 200), // Artifact at start
            RRPoint(t_ms: 200, rr_ms: 800),
            RRPoint(t_ms: 1000, rr_ms: 810),
            RRPoint(t_ms: 1810, rr_ms: 820)
        ]

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        flags[0] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)

        let rrValues = points.map(\.rr_ms)

        let (corrected, newFlags) = ArtifactCorrector.correct(
            rrValues: rrValues,
            flags: flags,
            method: .linearInterpolation
        )

        // Should handle gracefully
        XCTAssertEqual(corrected.count, points.count)
        XCTAssertTrue(newFlags[0].corrected || newFlags[0].isArtifact)
    }

    /// Test artifact at end
    func testArtifactAtEnd() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 810),
            RRPoint(t_ms: 1610, rr_ms: 820),
            RRPoint(t_ms: 2430, rr_ms: 200) // Artifact at end
        ]

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        flags[3] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)

        let rrValues = points.map(\.rr_ms)

        let (corrected, newFlags) = ArtifactCorrector.correct(
            rrValues: rrValues,
            flags: flags,
            method: .linearInterpolation
        )

        // Should handle gracefully
        XCTAssertEqual(corrected.count, points.count)
        XCTAssertTrue(newFlags[3].corrected || newFlags[3].isArtifact)
    }

    // MARK: - Correction Quality

    /// Test that correction preserves HRV metrics reasonably
    func testCorrectionPreservesMetrics() throws {
        // Create clean data
        var points = (0 ..< 200).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800 + Int.random(in: -30 ... 30))
        }

        _ = points.map(\.rr_ms)
        let originalFlags = [ArtifactFlags](repeating: .clean, count: points.count)

        // Calculate original RMSSD
        let originalMetrics = TimeDomainAnalyzer.computeTimeDomain(
            RRSeries(points: points, sessionId: UUID(), startDate: Date()),
            flags: originalFlags,
            windowStart: 0,
            windowEnd: points.count
        )

        // Add some artifacts
        var artifactFlags = originalFlags
        for i in [20, 50, 80, 120, 150] {
            points[i] = RRPoint(t_ms: points[i].t_ms, rr_ms: 200)
            artifactFlags[i] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)
        }

        // Correct artifacts
        let artifactRR = points.map(\.rr_ms)
        let (corrected, correctedFlags) = ArtifactCorrector.correct(
            rrValues: artifactRR,
            flags: artifactFlags,
            method: .cubicSpline
        )

        // Calculate corrected RMSSD
        let correctedPoints = corrected.enumerated().map { i, rr in
            RRPoint(t_ms: Int64(i * 800), rr_ms: rr)
        }

        let correctedMetrics = TimeDomainAnalyzer.computeTimeDomain(
            RRSeries(points: correctedPoints, sessionId: UUID(), startDate: Date()),
            flags: correctedFlags,
            windowStart: 0,
            windowEnd: correctedPoints.count
        )

        let originalTimeDomain = try XCTUnwrap(originalMetrics)
        let correctedTimeDomain = try XCTUnwrap(correctedMetrics)

        // Corrected metrics should be reasonably close to original
        let rmssdDifference = abs(correctedTimeDomain.rmssd - originalTimeDomain.rmssd)
        let rmssdPercentDiff = (rmssdDifference / originalTimeDomain.rmssd) * 100

        XCTAssertLessThan(
            rmssdPercentDiff,
            20.0,
            "Corrected RMSSD should be within 20% of original clean data"
        )
    }

    // MARK: - Performance Tests

    /// Test correction performance on large dataset
    func testCorrectionPerformance() {
        let points = (0 ..< 10000).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800 + Int.random(in: -50 ... 50))
        }

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)

        // Add 5% artifacts randomly
        for _ in 0 ..< 500 {
            let idx = Int.random(in: 0 ..< points.count)
            flags[idx] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)
        }

        let rrValues = points.map(\.rr_ms)

        measure {
            _ = ArtifactCorrector.correct(
                rrValues: rrValues,
                flags: flags,
                method: .cubicSpline
            )
        }
    }
}

// MARK: - Reference correction methods
//
// No app code path applies these corrections, so they live with the tests
// that exercise them rather than in the app target.

/// Artifact correction methods
enum ArtifactCorrectionMethod: String, CaseIterable, Identifiable {
    case none = "None"
    case deletion = "Deletion"
    case linearInterpolation = "Linear Interpolation"
    case cubicSpline = "Cubic Spline"
    case median = "Median Replacement"

    var id: String {
        rawValue
    }

    var description: String {
        switch self {
        case .none:
            "Keep artifacts in data (excluded from analysis)"
        case .deletion:
            "Remove artifact intervals entirely"
        case .linearInterpolation:
            "Replace with linearly interpolated values"
        case .cubicSpline:
            "Replace with cubic spline interpolated values"
        case .median:
            "Replace with local median value"
        }
    }
}

/// Artifact correction algorithms
enum ArtifactCorrector {
    /// Apply artifact correction to RR intervals
    /// - Parameters:
    ///   - rrValues: Original RR intervals in ms
    ///   - flags: Artifact flags for each interval
    ///   - method: Correction method to apply
    /// - Returns: Corrected RR intervals and updated flags
    static func correct(
        rrValues: [Int],
        flags: [ArtifactFlags],
        method: ArtifactCorrectionMethod
    ) -> (corrected: [Int], flags: [ArtifactFlags]) {
        guard rrValues.count == flags.count else {
            return (rrValues, flags)
        }

        switch method {
        case .none:
            return (rrValues, flags)

        case .deletion:
            return deletionCorrection(rrValues: rrValues, flags: flags)

        case .linearInterpolation:
            return linearInterpolationCorrection(rrValues: rrValues, flags: flags)

        case .cubicSpline:
            return cubicSplineCorrection(rrValues: rrValues, flags: flags)

        case .median:
            return medianCorrection(rrValues: rrValues, flags: flags)
        }
    }

    // MARK: - Deletion Method

    /// Remove artifacts entirely from the series
    private static func deletionCorrection(
        rrValues: [Int],
        flags: [ArtifactFlags]
    ) -> (corrected: [Int], flags: [ArtifactFlags]) {
        var corrected = [Int]()
        var newFlags = [ArtifactFlags]()

        for i in 0 ..< rrValues.count where !flags[i].isArtifact {
            corrected.append(rrValues[i])
            newFlags.append(.clean)
        }

        return (corrected, newFlags)
    }

    // MARK: - Linear Interpolation

    /// Replace artifacts with linearly interpolated values
    private static func linearInterpolationCorrection(
        rrValues: [Int],
        flags: [ArtifactFlags]
    ) -> (corrected: [Int], flags: [ArtifactFlags]) {
        var corrected = rrValues
        var newFlags = flags
        var i = 0
        while i < corrected.count {
            guard flags[i].isArtifact else {
                i += 1
                continue
            }
            var endIdx = i
            while endIdx < corrected.count, flags[endIdx].isArtifact {
                endIdx += 1
            }
            fillArtifactRun(
                i ..< endIdx, corrected: &corrected, newFlags: &newFlags, flags: flags
            )
            i = endIdx
        }
        return (corrected, newFlags)
    }

    /// Bridges one run of artifacts between the clean beats either side of it.
    /// A run at the very start or end of the recording has only one anchor, so
    /// it is held flat at that value rather than extrapolated.
    private static func fillArtifactRun(
        _ run: Range<Int>,
        corrected: inout [Int],
        newFlags: inout [ArtifactFlags],
        flags: [ArtifactFlags]
    ) {
        let beforeIdx = (0 ..< run.lowerBound).reversed().first { !flags[$0].isArtifact }
        let afterIdx = (run.upperBound ..< corrected.count).first { !flags[$0].isArtifact }
        for j in run {
            guard let value = bridgedValue(
                at: j, before: beforeIdx, after: afterIdx, corrected: corrected
            ) else { continue }
            corrected[j] = value
            newFlags[j] = ArtifactFlags(
                isArtifact: false,
                type: flags[j].type,
                confidence: flags[j].confidence,
                corrected: true
            )
        }
    }

    /// The interpolated (or held) value for one artifact beat. Nil when the run
    /// has no clean beat on either side, in which case it stays flagged.
    private static func bridgedValue(
        at j: Int,
        before beforeIdx: Int?,
        after afterIdx: Int?,
        corrected: [Int]
    ) -> Int? {
        switch (beforeIdx, afterIdx) {
        case let (before?, after?):
            let startVal = Double(corrected[before])
            let endVal = Double(corrected[after])
            let frac = Double(j - before) / Double(after - before)
            return Int(round(startVal + frac * (endVal - startVal)))
        case let (before?, nil): return corrected[before]
        case let (nil, after?): return corrected[after]
        case (nil, nil): return nil
        }
    }

    // MARK: - Cubic Spline Interpolation

    /// Replace artifacts with cubic spline interpolated values
    /// Provides smoother correction than linear interpolation
    private static func cubicSplineCorrection(
        rrValues: [Int],
        flags: [ArtifactFlags]
    ) -> (corrected: [Int], flags: [ArtifactFlags]) {
        var cleanIndices = [Int]()
        var cleanValues = [Double]()
        for i in 0 ..< rrValues.count where !flags[i].isArtifact {
            cleanIndices.append(i)
            cleanValues.append(Double(rrValues[i]))
        }
        // A natural cubic spline needs four knots; below that, fall back.
        guard cleanIndices.count >= 4 else {
            return linearInterpolationCorrection(rrValues: rrValues, flags: flags)
        }
        let spline = NaturalCubicSpline(x: cleanIndices.map { Double($0) }, y: cleanValues)
        return splineCorrected(rrValues: rrValues, flags: flags, spline: spline)
    }

    /// A natural cubic spline through the clean beats, solved once and then
    /// evaluated at each artifact position.
    private struct NaturalCubicSpline {
        let x: [Double]
        let y: [Double]
        private let b: [Double]
        private let c: [Double]
        private let d: [Double]

        init(x: [Double], y: [Double]) {
            self.x = x
            self.y = y
            let h = Self.spacing(x)
            let c = Self.secondDerivatives(x: x, y: y, h: h)
            self.c = c
            (self.b, self.d) = Self.firstAndThirdDerivatives(y: y, h: h, c: c)
        }

        /// Knot spacing.
        private static func spacing(_ x: [Double]) -> [Double] {
            // `count: -1` traps before the loop ever runs. The one caller
            // guards on four knots, but the guard belongs next to the code
            // that depends on it.
            guard x.count >= 2 else { return [] }
            var h = [Double](repeating: 0, count: x.count - 1)
            for i in 0 ..< x.count - 1 {
                h[i] = x[i + 1] - x[i]
            }
            return h
        }

        /// Solves the tridiagonal system for the second derivatives (Thomas
        /// algorithm). Natural end conditions leave c[0] and c[n-1] at zero.
        private static func secondDerivatives(x: [Double], y: [Double], h: [Double]) -> [Double] {
            let n = x.count
            // A natural spline needs interior knots to solve for; with fewer
            // than three the system is empty and `1 ..< n - 1` is invalid.
            guard n >= 3 else { return [Double](repeating: 0, count: n) }
            var alpha = [Double](repeating: 0, count: n)
            for i in 1 ..< n - 1 where h[i - 1] > 0 && h[i] > 0 {
                alpha[i] = 3.0 / h[i] * (y[i + 1] - y[i]) - 3.0 / h[i - 1] * (y[i] - y[i - 1])
            }
            let (mu, z) = thomasForwardSweep(x: x, h: h, alpha: alpha)
            var c = [Double](repeating: 0, count: n)
            for j in stride(from: n - 2, through: 0, by: -1) {
                c[j] = z[j] - mu[j] * c[j + 1]
            }
            return c
        }

        /// Thomas forward elimination. A zero pivot means two knots coincide;
        /// that row is skipped, leaving its `mu`/`z` at the natural-end zeros
        /// so the back substitution treats it as a straight segment.
        private static func thomasForwardSweep(
            x: [Double],
            h: [Double],
            alpha: [Double]
        ) -> (mu: [Double], z: [Double]) {
            let n = x.count
            var l = [Double](repeating: 1, count: n)
            var mu = [Double](repeating: 0, count: n)
            var z = [Double](repeating: 0, count: n)
            for i in 1 ..< max(1, n - 1) {
                l[i] = 2.0 * (x[i + 1] - x[i - 1]) - h[i - 1] * mu[i - 1]
                guard l[i] != 0 else { continue }
                mu[i] = h[i] / l[i]
                z[i] = (alpha[i] - h[i - 1] * z[i - 1]) / l[i]
            }
            return (mu, z)
        }

        private static func firstAndThirdDerivatives(
            y: [Double],
            h: [Double],
            c: [Double]
        ) -> ([Double], [Double]) {
            let n = y.count
            // As in `spacing`: `count: -1` traps before the loop.
            guard n >= 2 else { return ([], []) }
            var b = [Double](repeating: 0, count: n - 1)
            var d = [Double](repeating: 0, count: n - 1)
            for i in 0 ..< n - 1 where h[i] > 0 {
                b[i] = (y[i + 1] - y[i]) / h[i] - h[i] * (c[i + 1] + 2.0 * c[i]) / 3.0
                d[i] = (c[i + 1] - c[i]) / (3.0 * h[i])
            }
            return (b, d)
        }

        /// The segment containing `xi`, clamped to the spline's own range.
        private func segmentIndex(for xi: Double) -> Int {
            // The `max(0, x.count - 2)` fallback below already anticipates a
            // short knot list; the loop bound has to as well.
            for j in 0 ..< max(0, x.count - 1) {
                if x[j] <= xi, xi <= x[j + 1] { return j }
                if x[j] > xi { return max(0, j - 1) }
            }
            return max(0, x.count - 2)
        }

        func value(at xi: Double) -> Double {
            let segIdx = segmentIndex(for: xi)
            let dt = xi - x[segIdx]
            return y[segIdx] + b[segIdx] * dt + c[segIdx] * dt * dt + d[segIdx] * dt * dt * dt
        }
    }

    /// Evaluates the spline at each artifact index, clamped to a physiological
    /// RR range so an overshooting segment can't invent an impossible beat.
    private static func splineCorrected(
        rrValues: [Int],
        flags: [ArtifactFlags],
        spline: NaturalCubicSpline
    ) -> (corrected: [Int], flags: [ArtifactFlags]) {
        var corrected = rrValues
        var newFlags = flags
        for i in 0 ..< rrValues.count where flags[i].isArtifact {
            corrected[i] = Int(round(max(300, min(2_000, spline.value(at: Double(i))))))
            newFlags[i] = ArtifactFlags(
                isArtifact: false,
                type: flags[i].type,
                confidence: flags[i].confidence,
                corrected: true
            )
        }
        return (corrected, newFlags)
    }

    // MARK: - Median Replacement

    /// Replace artifacts with local median value
    /// Simple and robust method, good for isolated artifacts
    private static func medianCorrection(
        rrValues: [Int],
        flags: [ArtifactFlags],
        windowSize: Int = 11
    ) -> (corrected: [Int], flags: [ArtifactFlags]) {
        var corrected = rrValues
        var newFlags = flags
        for i in 0 ..< rrValues.count where flags[i].isArtifact {
            // A window with no clean beat at all leaves the artifact flagged.
            guard let median = localCleanMedian(
                at: i, rrValues: rrValues, flags: flags, halfWindow: windowSize / 2
            ) else { continue }
            corrected[i] = median
            newFlags[i] = ArtifactFlags(
                isArtifact: false,
                type: flags[i].type,
                confidence: flags[i].confidence,
                corrected: true
            )
        }
        return (corrected, newFlags)
    }

    /// Median of the clean beats within `halfWindow` either side of `i`.
    private static func localCleanMedian(
        at i: Int,
        rrValues: [Int],
        flags: [ArtifactFlags],
        halfWindow: Int
    ) -> Int? {
        let start = max(0, i - halfWindow)
        let end = min(rrValues.count, i + halfWindow + 1)
        var windowClean = [Int]()
        for j in start ..< end where !flags[j].isArtifact {
            windowClean.append(rrValues[j])
        }
        guard !windowClean.isEmpty else { return nil }
        windowClean.sort()
        let mid = windowClean.count / 2
        return windowClean.count.isMultiple(of: 2)
            ? (windowClean[mid - 1] + windowClean[mid]) / 2
            : windowClean[mid]
    }
}
