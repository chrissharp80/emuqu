import Foundation

// A candidate recovery window with its scores, lifted out of `WindowSelector`.
//
// The selector is the only place it is used, but nesting it there made it the
// single largest declaration in a type already flagged for size — ~100
// lines of the scorer describing a value, not behaviour. Nothing about it
// depends on the selector, so it does not need to live inside it.

/// Scored candidate block with HRV metrics
struct ScoredRecoveryBlock {
    let startIndex: Int
    let endIndex: Int
    let startMs: Int64
    let endMs: Int64
    let artifactRate: Double
    let ectopicRate: Double
    let meanHR: Double
    let hrCV: Double
    let rmssd: Double
    let sdnn: Double
    let cleanBeatCount: Int
    /// Relative position of window midpoint within sleep episode (0.0 = start, 1.0 = end)
    let relativePosition: Double
    /// Clean RR intervals for this window (needed for DFA/frequency analysis)
    let cleanRRs: [Double]

    // MARK: - Organization Metrics

    /// DFA α1 for this window (nil if insufficient data)
    let dfaAlpha1: Double?
    /// LF/HF ratio (nil if insufficient data for frequency analysis)
    let lfHfRatio: Double?

    /// Consolidated recovery score: RMSSD weighted by stability
    /// Higher RMSSD is good, but unstable windows are penalized
    /// Formula: rmssd * stabilityFactor, where stabilityFactor decreases with higher CV
    func recoveryScore(stabilityWeight: Double) -> Double {
        // Typical HR CV during stable sleep is 0.02-0.05 (2-5%)
        // CV > 0.10 indicates significant instability
        // stabilityFactor ranges from ~1.0 (very stable) to ~0.5 (unstable)
        let stabilityFactor = 1.0 / (1.0 + stabilityWeight * hrCV)
        // **Artifact penalty.** Among windows
        // that pass the hard cutoff, prefer the cleaner ones. A
        // window with 2% artifacts (factor 0.95) scores ~46% higher than a
        // window with 14% artifacts (factor 0.65) on the same RMSSD — so when
        // the user's whole night has both, the selector picks the
        // clean one. Linear penalty: artifactFactor goes from 1.0
        // (zero artifacts) to ~0.625 (15% artifacts).
        let artifactFactor = max(0.5, 1.0 - artifactRate * 2.5)
        return rmssd * stabilityFactor * artifactFactor
    }

    /// Classify this window as Organized Recovery or High Variability
    /// Organized Recovery: DFA α1 ~0.75-1.0, LF/HF < 1.5, stable HR
    /// High Variability: high RMSSD but disorganized (α1 outside range or unstable)
    /// Check DFA α1 is in OPTIMAL range (0.75-1.0).
    /// Research (PMC4100066) shows healthy NREM α1 values:
    ///   N3 (deep): 0.78 ± 0.21, N2: 0.85 ± 0.16, N1: 0.89 ± 0.23
    /// Range 0.75-1.0 captures core healthy NREM values.
    /// Values > 1.0 = over-correlated, approaching Brownian noise.
    /// Values < 0.75 = less organized, transitional.
    private var alpha1IsOptimal: Bool {
        dfaAlpha1.map { WindowSelector.RecoveryWindow.optimalAlpha1Range.contains($0) } ?? false
    }

    /// LF/HF is parasympathetic-dominant (vacuously true when unavailable).
    private var lfHfIsOrganized: Bool {
        lfHfRatio.map { $0 <= WindowSelector.RecoveryWindow.maxOrganizedLfHf } ?? true
    }

    private var hrIsStable: Bool {
        hrCV < WindowSelector.RecoveryWindow.unstableCVThreshold
    }

    var isOrganizedRecovery: Bool {
        // Must have DFA α1 to classify (need sufficient data). If we can't
        // compute DFA, use HR stability as proxy.
        guard dfaAlpha1 != nil else { return hrIsStable }

        // If LF/HF is missing, require stable HR so "organized" still reflects
        // sustained regulation rather than alpha1-only spikes.
        if lfHfRatio == nil {
            return alpha1IsOptimal && hrIsStable
        }

        // With LF/HF available, keep existing tolerant rule:
        // strong alpha1 plus either favorable LF/HF or stable HR.
        return alpha1IsOptimal && (lfHfIsOrganized || hrIsStable)
    }

    /// Get window classification for reporting
    /// Three-tier classification based on DFA α1:
    /// - Organized Recovery (0.75-1.0): readiness indicator (healthy NREM range)
    /// - Flexible Unconsolidated (0.60-0.75): some capacity, not strong readiness
    /// - High Variability (outside both): neither
    var classification: WindowSelector.RecoveryWindow.WindowClassification {
        if cleanBeatCount < 60 {
            return .insufficient
        }

        guard let alpha1 = dfaAlpha1 else {
            // Without DFA, use HR stability as proxy
            return hrCV < WindowSelector.RecoveryWindow.unstableCVThreshold ? .organizedRecovery : .highVariability
        }

        // Three-tier classification based on α1
        if WindowSelector.RecoveryWindow.optimalAlpha1Range.contains(alpha1) {
            // α1 in 0.75-1.0: organized, adaptive autonomic control (healthy NREM range)
            return .organizedRecovery
        } else if WindowSelector.RecoveryWindow.flexibleAlpha1Range.contains(alpha1) {
            // α1 in 0.60-0.75: approaching uncorrelated — some capacity, less organized
            return .flexibleUnconsolidated
        } else {
            // α1 < 0.60 or > 1.0: high variability (random/Brownian or constrained)
            return .highVariability
        }
    }
}
