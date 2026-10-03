import Accelerate
import Foundation
import os

// MARK: - Frequency Domain Analysis

//
// This implementation follows standard HRV spectral analysis methodology:
//
// ## Windowing Choice: Hann Window
// - The Hann (Hanning) window is chosen over rectangular/Hamming/Blackman because:
//   1. Good frequency resolution with minimal spectral leakage
//   2. Widely used in HRV research, enabling comparison with published data
//   3. Side lobes -31dB below main lobe (better than rectangular's -13dB)
//   4. Smooth taper to zero at edges reduces edge artifacts in RR data
// - Trade-off: Slight loss of frequency resolution vs rectangular, but the leakage
//   reduction is critical for accurate LF/HF band power estimation
//
// ## Welch's Method
// - Overlapping segments with averaging reduces variance in PSD estimate
// - 50% overlap is standard for Hann window (optimal for minimum variance)
// - Each segment is linearly detrended before windowing, so a segment's own
//   offset and drift do not leak through the window's main lobe into the
//   lowest bins (removing only the whole-window mean leaves both)
// - 256-sample segments at 4Hz = 64 seconds per segment for LF and HF
//   - This provides ~0.016 Hz frequency resolution (sufficient for LF/HF bands)
//   - Short enough to capture multiple segments in a 5-minute window
//   - Long enough for stable spectral estimates
// - VLF comes from its own pass with 1024-sample (256 s) segments: at
//   0.016 Hz the 0.003-0.04 Hz band is only two bins, the first of them next
//   to DC; at 0.0039 Hz it is nine
//
// ## Resampling at 4 Hz
// - RR intervals are non-uniformly sampled (event-based)
// - Cubic spline interpolation to uniform 4 Hz grid enables FFT
// - Cubic spline is the de facto standard (Kubios, pyHRV, BIOPAC) — linear
//   interpolation introduces HF rolloff that inflates LF/HF ratio
//   (Clifford & Tarassenko 2005, IEEE Trans Biomed Eng)
// - 4 Hz is standard in HRV analysis (Nyquist = 2 Hz, well above HF 0.4 Hz)
// - Higher sampling adds no information but increases computation
//
// ## Band Boundaries (per Task Force 1996 guidelines)
// - VLF: 0.003-0.04 Hz (requires 10+ min window for meaningful estimate)
// - LF: 0.04-0.15 Hz (mix of sympathetic/parasympathetic, also baroreceptor)
// - HF: 0.15-0.4 Hz (parasympathetic, respiratory sinus arrhythmia)
//
// References:
// - Task Force of ESC/NASPE (1996). Circulation 93:1043-1065
// - Welch, P.D. (1967). IEEE Trans Audio Electroacoustics AU-15:70-73
// - Welch PSD on 4 Hz cubic-spline-resampled RR (Hann, 50% overlap) —
//   Clifford & Tarassenko, IEEE TBME 2005;52:630-638

/// Frequency domain analysis using Welch's method
enum FrequencyDomainAnalyzer {
    // MARK: - DFT Cache

    /// The setups live inside the lock (`uncheckedState`: `OpaquePointer` is
    /// not `Sendable`), so there is no unguarded global to race on.
    private static let dftSetupCache = OSAllocatedUnfairLock<[Int: OpaquePointer]>(uncheckedState: [:])

    /// Get or create cached DFT setup for given size.
    ///
    /// DFT setups are never evicted while the app is running because:
    /// 1. The returned OpaquePointer may be in use by a concurrent caller —
    ///    destroying it while `vDSP_DFT_ExecuteD` is running causes use-after-free.
    /// 2. The number of distinct FFT sizes is bounded in practice (3–5 powers
    ///    of 2), so unbounded caching uses negligible memory.
    /// 3. `teardownDFTCache()` provides explicit cleanup on memory warning or termination.
    static func getDFTSetup(size: Int) -> OpaquePointer? {
        dftSetupCache.withLockUnchecked { cache in
            if let existing = cache[size] { return existing }
            guard let setup = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(size), .FORWARD) else { return nil }
            cache[size] = setup
            return setup
        }
    }

    /// Memory-warning hook. Intentionally a no-op: a real destroy-all
    /// is a use-after-free if any caller is inside `vDSP_DFT_ExecuteD`
    /// at the moment of the warning — the cache lock serialises the
    /// dictionary mutation, not the in-flight Accelerate call.
    ///
    /// Three FFT call sites use
    /// `getDFTSetup` without bumping a "in-flight" counter, so we
    /// cannot safely destroy setups without ALSO refactoring every
    /// caller to a `withSetup { ... }` wrapper that bumps/unbumps
    /// around the Accelerate call. That refactor is straightforward
    /// but invasive, and the memory cost of NOT destroying is bounded:
    /// 3-5 FFT sizes × a few KB each = ~10 KB total, leaked for the
    /// app's lifetime. Strictly preferable to a real use-after-free
    /// crash under memory pressure (the exact moment when reliable
    /// behaviour matters most).
    ///
    /// If you want to wire up real cleanup later: add an `inflightCount`
    /// protected by the cache lock, wrap getDFTSetup + Execute in a
    /// `withSetup` wrapper that increments/decrements the counter,
    /// and make this function block (NSCondition / continuation) until
    /// the counter reaches 0 before destroying.
    static func teardownDFTCache() {
        // Intentionally no-op. See doc-comment.
    }

    // MARK: - Constants

    /// Resampling frequency in Hz
    private static let resampleFrequency: Double = 4.0

    /// Frequency band boundaries (Hz)
    private static let vlfRange = HRVConstants.FrequencyBands.vlfLow ..< HRVConstants.FrequencyBands.vlfHigh
    private static let lfRange = HRVConstants.FrequencyBands.lfLow ..< HRVConstants.FrequencyBands.lfHigh
    private static let hfRange = HRVConstants.FrequencyBands.hfLow ... HRVConstants.FrequencyBands.hfHigh

    /// Minimum window duration for VLF analysis (minutes)
    private static let vlfMinDuration: Double = HRVConstants.FrequencyBands.minimumVLFWindowMinutes * 2

    // MARK: - Welch Configuration

    /// Default segment length for Welch's method (256 samples = 64 sec at 4 Hz)
    private static let defaultWelchSegmentLength: Int = 256

    /// Segment length for the VLF pass (1024 samples = 256 sec at 4 Hz,
    /// 0.0039 Hz resolution). Only used once the window passes the VLF gate,
    /// which guarantees at least two overlapping segments.
    private static let vlfWelchSegmentLength: Int = 1024

    /// Overlap fraction for Welch's method (50%)
    private static let welchOverlap: Double = 0.5

    // MARK: - Public API

    /// Compute frequency domain metrics for a window of RR intervals
    /// - Parameters:
    ///   - series: The complete RR series
    ///   - flags: Artifact flags for each point
    ///   - windowStart: Start index in series
    ///   - windowEnd: End index in series (exclusive)
    /// - Returns: Frequency domain metrics, or nil if insufficient data
    static func computeFrequencyDomain(
        _ series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int
    ) -> FrequencyDomainMetrics? {
        // Window bounds must be valid against BOTH points and flags (separate
        // parameters). Valid callers always satisfy this; a stale window index
        // applied to a shorter/re-loaded series would otherwise trap on the
        // slice. nil = the existing insufficient-data contract.
        guard windowStart >= 0, windowStart <= windowEnd,
              windowEnd <= series.points.count, windowEnd <= flags.count else { return nil }
        let windowPoints = Array(series.points[windowStart ..< windowEnd])
        let windowFlags = Array(flags[windowStart ..< windowEnd])
        guard windowPoints.count >= 120 else { return nil }
        var t: [Double] = []
        var rr: [Double] = []
        for i in 0 ..< windowPoints.count where !windowFlags[i].isArtifact {
            t.append(windowPoints[i].midpointMs / 1_000.0)
            rr.append(Double(windowPoints[i].rr_ms))
        }
        guard t.count >= 60 else { return nil }
        return computeFromCleanPairs(times: t, rrValues: rr)
    }

    /// Compute frequency domain metrics from pre-cleaned (time, RR) pairs.
    /// Used by HRVSleepStageClassifier for per-window spectral analysis without
    /// requiring a full RRSeries + ArtifactFlags wrapper.
    ///
    /// - Parameters:
    ///   - times: Timestamps in seconds (e.g., cumulative RR midpoints)
    ///   - rrValues: RR intervals in milliseconds, parallel to times
    /// - Returns: Frequency domain metrics, or nil if insufficient data
    static func computeFromCleanPairs(times: [Double], rrValues: [Double]) -> FrequencyDomainMetrics? {
        guard times.count >= 60,
              let tFirst = times.first,
              let tLast = times.last else { return nil }

        let duration = tLast - tFirst
        guard duration > 0 else { return nil }
        let sampleCount = Int(round(duration * resampleFrequency)) + 1
        guard sampleCount >= 64 else { return nil }

        let resampled = cubicSplineResample(
            t: times, values: rrValues, fs: resampleFrequency,
            sampleCount: sampleCount, tStart: tFirst
        )
        return computePSD(signal: resampled, fs: resampleFrequency, usableWindowMin: duration / 60.0)
    }

    /// Compute PSD using Welch's method (overlapping segments)
    /// Per design spec: 50% overlap, Hann window, averaged periodograms
    /// - Parameters:
    ///   - signal: Uniformly sampled signal (mean removed internally)
    ///   - fs: Sampling frequency in Hz
    ///   - segmentLength: FFT segment length (default 256 = 64 sec at 4 Hz)
    ///   - usableWindowMin: Duration in minutes for VLF gating
    /// - Returns: Frequency domain metrics
    static func computePSD(
        signal: [Double],
        fs: Double,
        segmentLength: Int? = nil,
        usableWindowMin: Double? = nil
    ) -> FrequencyDomainMetrics {
        let mean = signal.reduce(0, +) / Double(signal.count)
        let data = signal.map { $0 - mean }
        // Round to a power of 2 for FFT efficiency.
        let segLen = 1 << Int(floor(log2(Double(segmentLength ?? defaultWelchSegmentLength))))
        let stepSize = Int(Double(segLen) * (1.0 - welchOverlap))
        guard data.count >= (segmentLength ?? defaultWelchSegmentLength),
              (data.count - segLen) / stepSize + 1 >= 1,
              let dftSetup = getDFTSetup(size: segLen)
        else {
            return welchFallback(data: data, fs: fs, usableWindowMin: usableWindowMin, segLen: segLen)
        }
        let bands = bandPowers(
            psd: computeWelchPSD(
                data: data, fs: fs, segLen: segLen, stepSize: stepSize,
                numSegments: (data.count - segLen) / stepSize + 1, dftSetup: dftSetup
            ),
            fs: fs, fftN: segLen
        )
        let windowMin = usableWindowMin ?? (Double(data.count) / fs / 60.0)
        return metrics(vlf: windowMin >= vlfMinDuration ? vlfPower(data: data, fs: fs) : nil, lf: bands.lf, hf: bands.hf)
    }

    private static func metrics(vlf: Double?, lf: Double, hf: Double) -> FrequencyDomainMetrics {
        FrequencyDomainMetrics(
            vlf: vlf, lf: lf, hf: hf,
            lfHfRatio: hf > 0 ? lf / hf : nil,
            totalPower: (vlf ?? 0) + lf + hf
        )
    }

    /// VLF band power from the long-segment Welch pass. Nil when the signal is
    /// shorter than one long segment or no DFT setup exists for it — a VLF
    /// figure from 64-s segments is not one this app reports.
    private static func vlfPower(data: [Double], fs: Double) -> Double? {
        let segLen = vlfWelchSegmentLength
        let stepSize = Int(Double(segLen) * (1.0 - welchOverlap))
        guard data.count >= segLen, let dftSetup = getDFTSetup(size: segLen) else { return nil }
        let psd = computeWelchPSD(
            data: data, fs: fs, segLen: segLen, stepSize: stepSize,
            numSegments: (data.count - segLen) / stepSize + 1, dftSetup: dftSetup
        )
        return bandPowers(psd: psd, fs: fs, fftN: segLen).vlf
    }

    /// Too short for Welch, or no DFT setup available: a single-window
    /// periodogram if the signal is long enough, otherwise an empty spectrum.
    private static func welchFallback(
        data: [Double],
        fs: Double,
        usableWindowMin: Double?,
        segLen: Int
    ) -> FrequencyDomainMetrics {
        guard getDFTSetup(size: segLen) != nil || data.count < segLen else {
            return FrequencyDomainMetrics(vlf: nil, lf: 0, hf: 0, lfHfRatio: nil, totalPower: 0)
        }
        return computeSingleWindowPSD(signal: data, fs: fs, usableWindowMin: usableWindowMin)
    }

    // MARK: - PSD Helpers

    /// Run Welch's method: windowed, overlapping DFT segments averaged into a periodogram.
    private static func computeWelchPSD(
        data: [Double], fs: Double, segLen: Int, stepSize: Int,
        numSegments: Int, dftSetup: OpaquePointer
    ) -> [Double] {
        let halfN = segLen / 2
        var window = [Double](repeating: 0, count: segLen)
        vDSP_hann_windowD(&window, vDSP_Length(segLen), Int32(vDSP_HANN_DENORM))
        var windowPower: Double = 0
        vDSP_dotprD(window, 1, window, 1, &windowPower, vDSP_Length(segLen))
        windowPower /= Double(segLen)
        let norm = fs * Double(segLen) * windowPower
        var avgPsd = [Double](repeating: 0, count: halfN + 1)
        for seg in 0 ..< numSegments {
            accumulateSegment(
                linearlyDetrended(Array(data[(seg * stepSize) ..< (seg * stepSize + segLen)])),
                into: &avgPsd, window: window, norm: norm, segLen: segLen, dftSetup: dftSetup
            )
        }
        for k in 0 ... halfN {
            avgPsd[k] /= Double(numSegments)
        }
        return avgPsd
    }

    /// One windowed segment's periodogram, added into the running average.
    /// Bins 1..<halfN are doubled to fold in the negative frequencies; DC and
    /// Nyquist are not.
    private static func accumulateSegment(
        _ segment: [Double],
        into avgPsd: inout [Double],
        window: [Double],
        norm: Double,
        segLen: Int,
        dftSetup: OpaquePointer
    ) {
        let halfN = segLen / 2
        var windowed = [Double](repeating: 0, count: segLen)
        var inputImag = [Double](repeating: 0, count: segLen)
        var outputReal = [Double](repeating: 0, count: segLen)
        var outputImag = [Double](repeating: 0, count: segLen)
        vDSP_vmulD(segment, 1, window, 1, &windowed, 1, vDSP_Length(segLen))
        vDSP_DFT_ExecuteD(dftSetup, &windowed, &inputImag, &outputReal, &outputImag)
        avgPsd[0] += (outputReal[0] * outputReal[0] + outputImag[0] * outputImag[0]) / norm
        for k in 1 ..< halfN {
            avgPsd[k] += (outputReal[k] * outputReal[k] + outputImag[k] * outputImag[k]) * 2.0 / norm
        }
        avgPsd[halfN] += (outputReal[halfN] * outputReal[halfN] + outputImag[halfN] * outputImag[halfN]) / norm
    }

    /// The segment minus its least-squares straight line (Welch with linear
    /// detrending). Without it, the part of a segment's offset and slope that
    /// the whole-window mean removal leaves behind is spread by the Hann main
    /// lobe into bins 1-2 — the VLF band at 64-s segments.
    static func linearlyDetrended(_ segment: [Double]) -> [Double] {
        let n = Double(segment.count)
        guard segment.count > 1 else { return segment.map { _ in 0 } }
        let xMean = (n - 1) / 2
        let yMean = segment.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for (i, y) in segment.enumerated() {
            let dx = Double(i) - xMean
            sxy += dx * (y - yMean)
            sxx += dx * dx
        }
        let slope = sxx > 0 ? sxy / sxx : 0
        return segment.enumerated().map { i, y in y - yMean - slope * (Double(i) - xMean) }
    }

    // MARK: - Cubic Spline Resampling

    /// Resample non-uniformly spaced (t, values) to a uniform grid using natural cubic spline.
    /// Uses the Thomas algorithm (tridiagonal solver) for O(n) spline coefficient computation.
    /// This matches the resampling method used by Kubios, pyHRV, and BIOPAC.
    private static func cubicSplineResample(
        t: [Double], values: [Double], fs: Double, sampleCount: Int, tStart: Double
    ) -> [Double] {
        let n = t.count
        guard n >= 2 else {
            return [Double](repeating: values.first ?? 0, count: sampleCount)
        }
        guard n > 2 else {
            return linearResample(t: t, values: values, fs: fs, sampleCount: sampleCount, tStart: tStart)
        }
        let (h, delta) = intervalsAndSlopes(t: t, values: values)
        let knots = SplineKnots(
            t: t, values: values, h: h, delta: delta,
            m: secondDerivatives(h: h, delta: delta, n: n)
        )
        return evaluateSpline(knots: knots, fs: fs, sampleCount: sampleCount, tStart: tStart)
    }

    /// Two knots is not enough for a spline — straight line between them.
    private static func linearResample(
        t: [Double], values: [Double], fs: Double, sampleCount: Int, tStart: Double
    ) -> [Double] {
        var resampled = [Double](repeating: 0, count: sampleCount)
        for i in 0 ..< sampleCount {
            let targetT = tStart + Double(i) / fs
            let frac = (t[1] - t[0]) > 0 ? (targetT - t[0]) / (t[1] - t[0]) : 0
            resampled[i] = values[0] + frac * (values[1] - values[0])
        }
        return resampled
    }

    /// h[i] = t[i+1] - t[i]; delta[i] = (y[i+1] - y[i]) / h[i].
    private static func intervalsAndSlopes(t: [Double], values: [Double]) -> ([Double], [Double]) {
        let n = t.count
        var h = [Double](repeating: 0, count: n - 1)
        var delta = [Double](repeating: 0, count: n - 1)
        for i in 0 ..< (n - 1) {
            h[i] = t[i + 1] - t[i]
            delta[i] = h[i] > 0 ? (values[i + 1] - values[i]) / h[i] : 0
        }
        return (h, delta)
    }

    /// Natural spline: S''(0) = S''(n-1) = 0, solved with the Thomas algorithm — O(n).
    private static func secondDerivatives(h: [Double], delta: [Double], n: Int) -> [Double] {
        var m = [Double](repeating: 0, count: n)
        var cp = [Double](repeating: 0, count: n - 2) // modified upper diagonal
        var dp = [Double](repeating: 0, count: n - 2) // modified RHS
        let b0 = 2.0 * (h[0] + h[1])
        cp[0] = h[1] / b0
        dp[0] = 6.0 * (delta[1] - delta[0]) / b0
        for i in 1 ..< (n - 2) {
            let b = 2.0 * (h[i] + h[i + 1]) - h[i] * cp[i - 1]
            cp[i] = h[i + 1] / b
            dp[i] = (6.0 * (delta[i + 1] - delta[i]) - h[i] * dp[i - 1]) / b
        }
        m[n - 2] = dp[n - 3]
        for i in stride(from: n - 3, through: 1, by: -1) {
            m[i] = dp[i - 1] - cp[i - 1] * m[i + 1]
        }
        return m // m[0] and m[n-1] stay 0 — the natural boundary conditions
    }

    /// Evaluates a + b*dt + c*dt^2 + d*dt^3 at each uniform grid point.
    private static func evaluateSpline(
        knots: SplineKnots,
        fs: Double, sampleCount: Int, tStart: Double
    ) -> [Double] {
        let (t, values, h) = (knots.t, knots.values, knots.h)
        let n = t.count
        var resampled = [Double](repeating: 0, count: sampleCount)
        var seg = 0
        for i in 0 ..< sampleCount {
            let targetT = tStart + Double(i) / fs
            while seg < n - 2, t[seg + 1] < targetT {
                seg += 1
            }
            let s = max(0, min(n - 2, seg))
            resampled[i] = h[s] > 0
                ? splineValue(at: targetT - t[s], segment: s, knots: knots)
                : values[s]
        }
        return resampled
    }

    private static func splineValue(at dt: Double, segment s: Int, knots: SplineKnots) -> Double {
        let hi = knots.h[s]
        let c = knots.m[s] / 2.0
        let d = (knots.m[s + 1] - knots.m[s]) / (6.0 * hi)
        let b = knots.delta[s] - hi * (2.0 * knots.m[s] + knots.m[s + 1]) / 6.0
        return knots.values[s] + dt * (b + dt * (c + dt * d))
    }

    /// A solved natural cubic spline: the knots plus the per-segment spacing,
    /// slopes and second derivatives it was solved for.
    private struct SplineKnots {
        let t: [Double]
        let values: [Double]
        let h: [Double]
        let delta: [Double]
        let m: [Double]
    }

    // MARK: - Single Window Fallback

    /// Single-window FFT for short signals (fallback when Welch not possible)
    private static func computeSingleWindowPSD(
        signal: [Double],
        fs: Double,
        usableWindowMin: Double?
    ) -> FrequencyDomainMetrics {
        let sampleCount = signal.count
        let fftN = 1 << Int(vDSP_Length(ceil(log2(Double(sampleCount)))))
        guard let psd = singleWindowSpectrum(signal: signal, fs: fs, fftN: fftN) else {
            return FrequencyDomainMetrics(vlf: nil, lf: 0, hf: 0, lfHfRatio: nil, totalPower: 0)
        }
        let bands = bandPowers(psd: psd, fs: fs, fftN: fftN)
        let windowMin = usableWindowMin ?? (Double(sampleCount) / fs / 60.0)
        return FrequencyDomainMetrics(
            vlf: windowMin >= vlfMinDuration ? bands.vlf : nil,
            lf: bands.lf,
            hf: bands.hf,
            lfHfRatio: bands.hf > 0 ? bands.lf / bands.hf : nil,
            totalPower: (windowMin >= vlfMinDuration ? bands.vlf : 0) + bands.lf + bands.hf
        )
    }

    /// Hann-windowed, zero-padded periodogram over one segment. Nil when no
    /// DFT setup could be created for that size.
    ///
    /// The taper spans the samples, not the padded length: a window as long as
    /// the padding gave the signal only its rising half and left the zeros the
    /// rest. The normalisation is the window's energy over those same samples
    /// (`fs · Σw²`), so a sine of amplitude A integrates to A²/2 whatever the
    /// padding.
    private static func singleWindowSpectrum(signal: [Double], fs: Double, fftN: Int) -> [Double]? {
        let count = signal.count
        var window = [Double](repeating: 0, count: count)
        vDSP_hann_windowD(&window, vDSP_Length(count), Int32(vDSP_HANN_DENORM))
        var padded = [Double](repeating: 0, count: fftN)
        vDSP_vmulD(linearlyDetrended(signal), 1, window, 1, &padded, 1, vDSP_Length(count))
        var windowEnergy: Double = 0
        vDSP_dotprD(window, 1, window, 1, &windowEnergy, vDSP_Length(count))
        guard windowEnergy > 0, let dftSetup = getDFTSetup(size: fftN) else { return nil }
        var psd = [Double](repeating: 0, count: fftN / 2 + 1)
        accumulateSegment(
            padded, into: &psd, window: [Double](repeating: 1, count: fftN),
            norm: fs * windowEnergy, segLen: fftN, dftSetup: dftSetup
        )
        return psd
    }

    /// Integrate a one-sided PSD into the VLF, LF and HF bands
    /// (HRVConstants.FrequencyBands: 0.003..<0.04, 0.04..<0.15, 0.15...0.4 Hz).
    private static func bandPowers(
        psd: [Double],
        fs: Double,
        fftN: Int
    ) -> (vlf: Double, lf: Double, hf: Double) {
        let freqRes = fs / Double(fftN)
        var vlf = 0.0, lf = 0.0, hf = 0.0
        for k in 0 ... (fftN / 2) {
            let freq = Double(k) * freqRes
            let power = psd[k] * freqRes
            if vlfRange.contains(freq) {
                vlf += power
            } else if lfRange.contains(freq) {
                lf += power
            } else if hfRange.contains(freq) {
                hf += power
            }
        }
        return (vlf, lf, hf)
    }
}
