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
        // Backstop: the band search already limits the peak to 9-30
        // breaths/min, so this only rejects a degenerate spectrum.
        guard breathsPerMin >= 6, breathsPerMin <= 40 else { return nil }
        return breathsPerMin
    }

    /// Mean-centred, Hann-windowed over the samples, then zero-padded to a
    /// power of 2. The window spans the data, not the padded length, so the
    /// real signal tapers to zero at both ends before the padding starts
    /// instead of being cut off abruptly, which would leak power across the
    /// band the peak search reads.
    private static func meanRemovedHannWindow(_ resampled: [Double]) -> [Double] {
        let count = resampled.count
        var mean: Double = 0
        vDSP_meanvD(resampled, 1, &mean, vDSP_Length(count))
        let centered = resampled.map { $0 - mean }

        var window = [Double](repeating: 0, count: count)
        vDSP_hann_windowD(&window, vDSP_Length(count), Int32(vDSP_HANN_DENORM))
        var windowed = [Double](repeating: 0, count: count)
        vDSP_vmulD(centered, 1, window, 1, &windowed, 1, vDSP_Length(count))

        // Zero-pad to power of 2
        let log2n = vDSP_Length(ceil(log2(Double(count))))
        let fftN = 1 << Int(log2n)
        windowed.append(contentsOf: [Double](repeating: 0, count: fftN - count))
        return windowed
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

    /// Peak in the respiratory band (0.15-0.5 Hz = 9-30 breaths/min). Nil
    /// when the band carries no power, or when its largest bin is not a
    /// breathing peak (`isBreathingPeak`).
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
        // A flat band (no power anywhere) has no breathing in it.
        guard peakPower > 0, isBreathingPeak(psd: psd, peakBin: peakBin, band: minBin ... maxBin, freqRes: freqRes) else { return nil }
        return Double(peakBin) * freqRes
    }

    /// Half-width of the peak, and the share of the band's power it must hold.
    static let peakHalfWidthHz = 0.02
    static let peakConcentrationMinimum = 0.4
    /// How tall the band's peak must be against the strongest peak above
    /// 0.04 Hz.
    static let peakHeightMinimum = 0.05

    /// Whether the band's largest bin is breathing rather than noise or
    /// leakage. The largest bin of any spectrum has some power, so it alone
    /// gave a plausible rate for white noise (about 13 breaths/min) and for a
    /// 3 breaths/min modulation (8.9, the band's edge, at a millionth of the
    /// slow peak's power). Breathing concentrates the band's power near one
    /// frequency (at least 40 % within ±0.02 Hz) and is not dwarfed by a
    /// slower rhythm (at least 5 % of the strongest peak above 0.04 Hz). On
    /// synthetic five-minute windows this keeps 95-100 % of breathing,
    /// including a rate wandering ±0.04 Hz with beat noise, and passes 0-3 %
    /// of white or 1/f noise.
    private static func isBreathingPeak(psd: [Double], peakBin: Int, band: ClosedRange<Int>, freqRes: Double) -> Bool {
        let halfWidth = max(1, Int((peakHalfWidthHz / freqRes).rounded()))
        let near = max(band.lowerBound, peakBin - halfWidth) ... min(band.upperBound, peakBin + halfWidth)
        let bandPower = psd[band].reduce(0, +)
        let nearPower = psd[near].reduce(0, +)
        let strongest = psd[min(Int(0.04 / freqRes), band.lowerBound) ... band.upperBound].max() ?? 0
        return nearPower >= peakConcentrationMinimum * bandPower && psd[peakBin] >= peakHeightMinimum * strongest
    }

    // MARK: - Helpers

    /// Linear-interpolation resampling of the RR series to a uniform grid.
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
