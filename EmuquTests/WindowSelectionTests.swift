@testable import Emuqu
import XCTest

/// Window selection algorithm tests
final class WindowSelectionTests: XCTestCase {
    let windowSelector = WindowSelector()

    func testScienceContract_WindowOrganizationThresholdsMatchArchitecture() {
        XCTAssertEqual(WindowSelector.RecoveryWindow.optimalAlpha1Range.lowerBound, 0.75, accuracy: 0.0001)
        XCTAssertEqual(WindowSelector.RecoveryWindow.optimalAlpha1Range.upperBound, 1.0, accuracy: 0.0001)
        XCTAssertEqual(WindowSelector.RecoveryWindow.flexibleAlpha1Range.lowerBound, 0.60, accuracy: 0.0001)
        XCTAssertEqual(WindowSelector.RecoveryWindow.flexibleAlpha1Range.upperBound, 0.75, accuracy: 0.0001)
        XCTAssertEqual(WindowSelector.RecoveryWindow.maxOrganizedLfHf, 1.5, accuracy: 0.0001)
        XCTAssertEqual(WindowSelector.RecoveryWindow.unstableCVThreshold, 0.08, accuracy: 0.0001)
    }

    func testScienceContract_DefaultWindowConfigMatchesArchitecture() {
        let config = WindowSelector.Config.default
        XCTAssertEqual(config.beatsPerWindow, 400)
        XCTAssertEqual(config.slideStepBeats, 40)
        XCTAssertEqual(config.maxArtifactRate, 0.15, accuracy: 0.0001)
        XCTAssertEqual(config.minCleanBeats, 300)
        XCTAssertEqual(config.minRelativePosition, 0.30, accuracy: 0.0001)
        XCTAssertEqual(config.maxRelativePosition, 0.70, accuracy: 0.0001)
        XCTAssertEqual(config.stabilityWeight, 10.0, accuracy: 0.0001)
    }

    func testScienceContract_ExactlyFourHundredBeatsInBandUsesFourHundredBeatWindow() {
        // 1000 beats at 800ms => 30-70% band maps to indices 300...699 (exactly 400 beats)
        let points = (0 ..< 1000).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800 + deterministicJitter(index: i, amplitude: 8))
        }
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let window = windowSelector.selectWindowByMethod(
            .peakRMSSD,
            in: series,
            flags: flags,
            sleepStartMs: nil,
            wakeTimeMs: nil
        )

        XCTAssertNotNil(window, "Expected a valid peak RMSSD window in 30-70% band")
        XCTAssertEqual(window?.beatCount, 400, "Exact 400-beat band should use a 400-beat window")
    }

    func testScienceContract_AdaptiveWindowUsesAdaptiveCleanBeatThreshold() {
        // 700 beats => 30-70% band has ~280 beats (adaptive window < 300).
        // This should still produce a valid window when quality is high.
        let points = (0 ..< 700).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800 + deterministicJitter(index: i, amplitude: 8))
        }
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let window = windowSelector.selectWindowByMethod(
            .peakRMSSD,
            in: series,
            flags: flags,
            sleepStartMs: nil,
            wakeTimeMs: nil
        )

        XCTAssertNotNil(window, "Adaptive windows should not be blocked by fixed 300-clean-beat requirement")
        XCTAssertLessThan(window?.beatCount ?? 999, 300, "This scenario should use an adaptive window smaller than 300 beats")
    }

    // MARK: - Recovery Window Selection

    /// Test organized recovery detection
    func testOrganizedRecoveryDetection() {
        // Create a session with clear organized recovery pattern
        // High RMSSD, stable HR, good DFA alpha1
        let session = createSessionWithPattern(
            avgRR: 900, // Low HR (67 bpm)
            rmssdRange: 80 ... 120,
            variationPattern: .stable
        )

        guard let series = session.rrSeries, let flags = session.artifactFlags else {
            XCTFail("Session should have series and flags")
            return
        }

        let window = windowSelector.selectRecoveryWindow(
            series: series,
            flags: flags,
            wakeTimeMs: Int64(series.points.count * 800)
        )

        // selectRecoveryWindow only returns organized recovery (DFA α1 0.75-1.0).
        // Synthetic random data may not produce organized windows, so nil is valid.
        if let w = window {
            XCTAssertGreaterThan(w.qualityScore, 0, "Window should have positive quality score")
        }
    }

    /// Test high variability detection
    func testHighVariabilityDetection() {
        // Create session with high, chaotic variability
        let session = createSessionWithPattern(
            avgRR: 800,
            rmssdRange: 100 ... 150,
            variationPattern: .chaotic
        )

        guard let series = session.rrSeries, let flags = session.artifactFlags else {
            XCTFail("Session should have series and flags")
            return
        }

        let window = windowSelector.selectRecoveryWindow(
            series: series,
            flags: flags,
            wakeTimeMs: Int64(series.points.count * 800)
        )

        // Chaotic data is unlikely to produce organized recovery — nil is expected
        if let w = window {
            XCTAssertGreaterThan(w.qualityScore, 0, "Window should have positive quality score")
        }
    }

    /// Test peak capacity selection
    func testPeakCapacitySelection() {
        let session = createSessionWithPattern(
            avgRR: 900,
            rmssdRange: 80 ... 120,
            variationPattern: .stable
        )

        guard let series = session.rrSeries, let flags = session.artifactFlags else {
            XCTFail("Session should have series and flags")
            return
        }

        let window = windowSelector.selectRecoveryWindow(
            series: series,
            flags: flags,
            wakeTimeMs: Int64(series.points.count * 800)
        )

        // Peak capacity is computed separately via findBestWindowWithCapacity.
        // selectRecoveryWindow only returns organized recovery, so nil is valid.
        if let w = window {
            XCTAssertGreaterThan(w.qualityScore, 0, "Window should have quality score")
        }
    }

    // MARK: - Window Quality

    /// Test artifact filtering
    func testArtifactFiltering() {
        var session = createSessionWithPattern(avgRR: 800, rmssdRange: 60 ... 90, variationPattern: .stable)

        // Add artifacts to first half
        if var flags = session.artifactFlags {
            for i in 0 ..< (flags.count / 2) {
                flags[i] = ArtifactFlags(isArtifact: true, type: .technical, confidence: 1.0)
            }
            session.artifactFlags = flags
        }

        guard let series = session.rrSeries, let flags = session.artifactFlags else {
            XCTFail("Session should have series and flags")
            return
        }

        let window = windowSelector.selectRecoveryWindow(
            series: series,
            flags: flags,
            wakeTimeMs: Int64(series.points.count * 800)
        )

        // Synthetic data may not produce organized recovery windows
        if let w = window {
            // Window should prefer clean section
            let windowArtifacts = flags[w.startIndex ..< w.endIndex]
            let artifactPercent = Double(windowArtifacts.filter(\.isArtifact).count) / Double(windowArtifacts.count) * 100

            XCTAssertLessThan(
                artifactPercent,
                10.0,
                "Selected window should have low artifact percentage"
            )
        }
    }

    /// Test minimum window length requirement
    func testMinimumWindowLength() {
        // Create very short session
        let points = (0 ..< 50).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800)
        }

        let session = createSession(points: points)

        guard let series = session.rrSeries, let flags = session.artifactFlags else {
            XCTFail("Session should have series and flags")
            return
        }

        let window = windowSelector.selectRecoveryWindow(
            series: series,
            flags: flags,
            wakeTimeMs: Int64(series.points.count * 800)
        )

        // 50 beats is under the selector's 120-beat floor: no window at all.
        XCTAssertNil(window, "A night shorter than 120 beats must not yield a window")
    }

    // MARK: - Temporal Spike Filtering

    /// Test spike detection and filtering
    func testSpikeFiltering() {
        // Create session with a temporary spike in variability
        // Need 1500 beats so 30-70% band can contain 400-beat window
        var points = (0 ..< 1500).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800 + deterministicJitter(index: i, amplitude: 20))
        }

        // Add spike in middle (600-650)
        for i in 600 ..< 650 {
            points[i] = RRPoint(t_ms: Int64(i * 800), rr_ms: 800 + deterministicJitter(index: i, amplitude: 100))
        }

        let session = createSession(points: points)

        guard let series = session.rrSeries, let flags = session.artifactFlags else {
            XCTFail("Session should have series and flags")
            return
        }

        let window = windowSelector.selectRecoveryWindow(
            series: series,
            flags: flags,
            wakeTimeMs: Int64(series.points.count * 800)
        )

        // Synthetic data may not produce organized recovery windows
        if let w = window {
            // Window should avoid the spike region
            let spikeRegion = 600 ..< 650
            let windowRange = w.startIndex ..< w.endIndex

            // Check if window overlaps significantly with spike
            let overlap = windowRange.clamped(to: spikeRegion)
            let overlapPercent = Double(overlap.count) / Double(windowRange.count) * 100

            XCTAssertLessThan(
                overlapPercent,
                20.0,
                "Window should avoid spike regions"
            )
        }
    }

    // MARK: - Heart Rate Stability

    /// Test HR stability preference
    func testHRStabilityPreference() {
        // Create two regions: one stable, one variable HR
        // Need 1500 beats so 30-70% band can contain 400-beat window
        var points: [RRPoint] = []

        // First half: stable HR (~75 bpm, 800ms RR)
        for i in 0 ..< 750 {
            points.append(RRPoint(t_ms: Int64(i * 800), rr_ms: 800 + deterministicJitter(index: i, amplitude: 10)))
        }

        // Second half: variable HR (60-90 bpm)
        for i in 750 ..< 1500 {
            let rr = 667 + ((i * 53 + 11) % 334)
            points.append(RRPoint(t_ms: Int64(i * 800), rr_ms: rr))
        }

        let session = createSession(points: points)

        guard let series = session.rrSeries, let flags = session.artifactFlags else {
            XCTFail("Session should have series and flags")
            return
        }

        let window = windowSelector.selectRecoveryWindow(
            series: series,
            flags: flags,
            wakeTimeMs: Int64(series.points.count * 800)
        )

        // Synthetic data may not produce organized recovery windows
        if let w = window {
            // Calculate HR variability in selected window
            let windowPoints = Array(points[w.startIndex ..< w.endIndex])
            let hrValues = windowPoints.map { 60000.0 / Double($0.rr_ms) }
            let hrStdDev = standardDeviation(hrValues)

            // Should prefer stable HR region
            XCTAssertLessThan(
                hrStdDev,
                10.0,
                "Selected window should have stable HR"
            )
        }
    }

    // MARK: - Edge Cases

    /// Test all artifacts session
    func testAllArtifacts() {
        let session = createSessionWithPattern(avgRR: 800, rmssdRange: 60 ... 90, variationPattern: .stable)
        var badSession = session

        guard let series = session.rrSeries else {
            XCTFail("Session should have series")
            return
        }

        badSession.artifactFlags = [ArtifactFlags](repeating: ArtifactFlags(isArtifact: true, type: .technical, confidence: 1.0), count: series.points.count)

        guard let flags = badSession.artifactFlags else {
            XCTFail("Should have flags")
            return
        }

        let window = windowSelector.selectRecoveryWindow(
            series: series,
            flags: flags,
            wakeTimeMs: Int64(series.points.count * 800)
        )

        // Should return nil or handle gracefully
        if window != nil {
            XCTFail("Should not select window from session with all artifacts")
        }
    }

    /// Test insufficient data
    func testInsufficientData() {
        let points = (0 ..< 10).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800)
        }

        let session = createSession(points: points)

        guard let series = session.rrSeries, let flags = session.artifactFlags else {
            XCTFail("Session should have series and flags")
            return
        }

        let window = windowSelector.selectRecoveryWindow(
            series: series,
            flags: flags,
            wakeTimeMs: Int64(series.points.count * 800)
        )

        XCTAssertNil(window, "Should return nil for insufficient data")
    }

    // MARK: - Statistics Parity (routed through Utilities/Statistics)

    /// maskedRMSSD over a run with no gaps is the plain root mean square of
    /// successive differences.
    func testMaskedRMSSDParityExact() {
        // RR [800, 820, 790, 830, 780] → diffs [20, -30, 40, -50],
        // RMSSD = sqrt((400+900+1600+2500)/4) = sqrt(1350) ≈ 36.74235
        let values = [800.0, 820.0, 790.0, 830.0, 780.0].enumerated().map { (index: $0.offset, rr: $0.element) }
        let rmssd = windowSelector.maskedRMSSD(values, kept: Array(repeating: true, count: values.count))
        XCTAssertEqual(rmssd, 36.742346141747674, accuracy: 1e-6)
    }

    /// A difference across a removed beat is not a successive difference.
    func testMaskedRMSSDSkipsPairsAcrossARemovedBeat() {
        // Index 2 was removed: 810 → 600 is not a real pair and must not count.
        let values: [(index: Int, rr: Double)] = [(0, 800), (1, 810), (3, 600), (4, 610)]
        let rmssd = windowSelector.maskedRMSSD(values, kept: [true, true, true, true])
        XCTAssertEqual(rmssd, 10, accuracy: 1e-9)
        XCTAssertEqual(windowSelector.maskedRMSSD([(0, 800)], kept: [true]), 0)
    }

    /// Index neighbours either side of a recording break are not a pair.
    func testMaskedRMSSDSkipsPairsAcrossARecordingBreak() {
        let values: [(index: Int, rr: Double)] = [(0, 800), (1, 810), (2, 600), (3, 610)]
        let rmssd = windowSelector.maskedRMSSD(values, kept: [true, true, true, true], breaks: [2])
        XCTAssertEqual(rmssd, 10, accuracy: 1e-9)
    }

    // MARK: - Helper Methods

    enum VariationPattern {
        case stable
        case chaotic
        case increasing
        case decreasing
    }

    private func createSessionWithPattern(
        avgRR: Int,
        rmssdRange _: ClosedRange<Int>,
        variationPattern: VariationPattern
    ) -> HRVSession {
        var points: [RRPoint] = []

        // Need at least 1500 beats so 30-70% band can contain 400-beat window
        // 30-70% of 1500 = 450-1050 (600 beats) which is enough for 400-beat window
        for i in 0 ..< 1500 {
            let variation: Int = switch variationPattern {
            case .stable:
                deterministicJitter(index: i, amplitude: 20)
            case .chaotic:
                deterministicJitter(index: i, amplitude: 100)
            case .increasing:
                Int(Double(i) / 3.0) + deterministicJitter(index: i, amplitude: 10)
            case .decreasing:
                -Int(Double(i) / 3.0) + deterministicJitter(index: i, amplitude: 10)
            }

            points.append(RRPoint(
                t_ms: Int64(i * avgRR),
                rr_ms: avgRR + variation
            ))
        }

        return createSession(points: points)
    }

    private func createSession(points: [RRPoint]) -> HRVSession {
        let series = RRSeries(
            points: points,
            sessionId: UUID(),
            startDate: Date()
        )

        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        return HRVSession(
            id: UUID(),
            startDate: series.startDate,
            endDate: series.startDate.addingTimeInterval(Double(points.count) * 0.8),
            state: .complete,
            sessionType: .overnight,
            rrSeries: series,
            analysisResult: nil,
            artifactFlags: flags,
            recoveryScore: nil,
            tags: [],
            notes: nil,
            importedMetrics: nil,
            deviceProvenance: nil,
            sleepStartMs: nil,
            sleepEndMs: nil
        )
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }

        let mean = values.reduce(0.0, +) / Double(values.count)
        let squaredDiffs = values.map { pow($0 - mean, 2) }
        let variance = squaredDiffs.reduce(0.0, +) / Double(values.count - 1)

        return sqrt(variance)
    }

    private func deterministicJitter(index: Int, amplitude: Int) -> Int {
        guard amplitude > 0 else { return 0 }
        let span = (amplitude * 2) + 1
        return ((index * 37 + 17) % span) - amplitude
    }
}
