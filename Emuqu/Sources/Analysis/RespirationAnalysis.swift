import Accelerate
import Foundation

/// ECG-Derived Respiration Rate Analysis
/// Estimates breathing rate from RR interval modulation
enum RespirationAnalyzer {
    // MARK: - Respiration Rate from RR

    /// Estimate respiration rate from RR interval series
    /// Uses the HF peak in PSD as respiratory frequency
    ///
    /// - Parameters:
    ///   - rr: RR intervals in ms
    ///   - fs: Resampling frequency (default 4 Hz)
    /// - Returns: Respiration rate in breaths/min, or nil if cannot determine
    static func estimateRespirationRate(_ rr: [Double], fs: Double = 4.0) -> Double? {
        guard rr.count >= 60 else { return nil }
        let resampled = resampleRR(rr, fs: fs)
        guard resampled.count >= 32 else { return nil }
        let windowed = meanRemovedHannWindow(resampled)
        guard let psd = powerSpectrum(windowed) else { return nil }
        guard let peakFreq = respiratoryPeakFrequency(psd: psd, fs: fs, fftN: windowed.count) else { return nil }
        let breathsPerMin = peakFreq * 60.0
        // Sanity check (normal range 8-30 breaths/min).
        guard breathsPerMin >= 6, breathsPerMin <= 40 else { return nil }
        return breathsPerMin
    }

    /// Mean-centred, zero-padded to a power of 2, then Hann-windowed.
    private static func meanRemovedHannWindow(_ resampled: [Double]) -> [Double] {
        var mean: Double = 0
        vDSP_meanvD(resampled, 1, &mean, vDSP_Length(resampled.count))
        var centered = resampled.map { $0 - mean }

        // Zero-pad to power of 2
        let log2n = vDSP_Length(ceil(log2(Double(centered.count))))
        let fftN = 1 << Int(log2n)
        centered.append(contentsOf: [Double](repeating: 0, count: fftN - centered.count))

        // Apply Hann window
        var window = [Double](repeating: 0, count: fftN)
        vDSP_hann_windowD(&window, vDSP_Length(fftN), Int32(vDSP_HANN_DENORM))
        vDSP_vmulD(centered, 1, window, 1, &centered, 1, vDSP_Length(fftN))
        return centered
    }

    /// Single-sided power spectrum. Nil when no DFT setup could be created.
    ///
    /// Reuses the cached setup from FrequencyDomainAnalyzer to avoid repeated
    /// twiddle-factor computation (O(n log n) per creation).
    private static func powerSpectrum(_ centered: [Double]) -> [Double]? {
        var centered = centered
        let fftN = centered.count
        guard let dftSetup = FrequencyDomainAnalyzer.getDFTSetup(size: fftN) else { return nil }
        var inputImag = [Double](repeating: 0, count: fftN)
        var outputReal = [Double](repeating: 0, count: fftN)
        var outputImag = [Double](repeating: 0, count: fftN)
        vDSP_DFT_ExecuteD(dftSetup, &centered, &inputImag, &outputReal, &outputImag)
        let halfN = fftN / 2
        var psd = [Double](repeating: 0, count: halfN + 1)
        for k in 0 ... halfN {
            psd[k] = outputReal[k] * outputReal[k] + outputImag[k] * outputImag[k]
        }
        return psd
    }

    /// Peak in the respiratory band (0.15-0.4 Hz = 9-24 breaths/min).
    private static func respiratoryPeakFrequency(psd: [Double], fs: Double, fftN: Int) -> Double? {
        let halfN = fftN / 2
        let freqRes = fs / Double(fftN)
        let minBin = Int(0.15 / freqRes)
        let maxBin = min(Int(0.5 / freqRes), halfN)

        guard maxBin > minBin else { return nil }

        var peakBin = minBin
        var peakPower = psd[minBin]

        for k in minBin ... maxBin where psd[k] > peakPower {
            peakPower = psd[k]
            peakBin = k
        }
        return Double(peakBin) * freqRes
    }

    // MARK: - Helpers

    /// Simple cubic spline resampling to uniform grid
    private static func resampleRR(_ rr: [Double], fs: Double) -> [Double] {
        guard rr.count >= 4 else { return rr }
        let t = cumulativeTimeAxis(rr)
        guard let tFirst = t.first, let tLast = t.last else { return rr }
        let sampleCount = Int((tLast - tFirst) * fs) + 1
        guard sampleCount >= 4 else { return rr }
        var resampled = [Double](repeating: 0, count: sampleCount)
        var tIdx = 0
        for i in 0 ..< sampleCount {
            let targetT = tFirst + Double(i) / fs
            // Advance to the last beat at or before the target time.
            while tIdx < t.count - 1, t[tIdx + 1] < targetT {
                tIdx += 1
            }
            resampled[i] = interpolated(rr, t: t, at: targetT, index: tIdx)
        }
        return resampled
    }

    /// Beat times in seconds, from cumulative RR.
    private static func cumulativeTimeAxis(_ rr: [Double]) -> [Double] {
        var t = [Double](repeating: 0, count: rr.count)
        var cumTime: Double = 0
        for i in 0 ..< rr.count {
            t[i] = cumTime / 1_000.0
            cumTime += rr[i]
        }
        return t
    }

    /// Linear interpolation between the bracketing beats, or the beat itself at
    /// the end of the series / on a zero-width interval.
    private static func interpolated(_ rr: [Double], t: [Double], at targetT: Double, index tIdx: Int) -> Double {
        guard tIdx < t.count - 1, t[tIdx + 1] > t[tIdx] else { return rr[tIdx] }
        let frac = (targetT - t[tIdx]) / (t[tIdx + 1] - t[tIdx])
        return rr[tIdx] + frac * (rr[tIdx + 1] - rr[tIdx])
    }

}
