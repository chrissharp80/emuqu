import SwiftUI

// MARK: - Metric Explanation Popover

struct MetricExplanationPopover: View {
    let metric: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(metricInfo.description)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)

            Divider()

            interpretationCallout
        }
        .padding()
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
    }

    private var header: some View {
        HStack {
            Text(metricInfo.fullName)
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)
            Spacer()
            closeButton
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(AppTheme.textTertiary)
        }
        .accessibilityLabel(String(localized: "Close", bundle: LanguageManager.appBundle))
    }

    private var interpretationCallout: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .foregroundColor(.yellow)
                .font(.caption)
            Text(metricInfo.interpretation)
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
        .padding(8)
        .background(Color.yellow.opacity(0.1))
        .cornerRadius(8)
    }

    typealias Info = (fullName: String, description: String, interpretation: String)

    /// Looked up by the English metric key. Callers that pass a translated
    /// display label are matched back to the key it translates. The tables
    /// hold factories so the copy resolves in the current app language.
    private var metricInfo: Info {
        let factory = Self.factory(for: metric) ?? Self.englishKey(forLabel: metric).flatMap(Self.factory)
        return factory?() ?? fallbackInfo
    }

    private static var allTables: [[String: @MainActor () -> Info]] {
        [timeDomainInfo, frequencyDomainInfo, nonlinearInfo, ansInfo, dataQualityInfo]
    }

    /// Card and Engine Room labels that name the same metric as a table key.
    private static let aliases = [
        "Window Beats": "Clean Beats", "Window beats": "Clean Beats", "Window HR": "HR Range",
        "HR range": "HR Range", "Resp rate": "Resp Rate", "PNS": "PNS Index", "SNS": "SNS Index",
        "Stress": "Stress Index", "Total power": "Total Power"
    ]

    /// The copy for an English metric key or Engine Room label, or nil when
    /// this glossary has none. `MetricInfoSheet` falls back to it.
    @MainActor
    static func info(forKey key: String) -> Info? {
        factory(for: key)?()
    }

    private static func factory(for key: String) -> (@MainActor () -> Info)? {
        let key = aliases[key] ?? key
        return allTables.lazy.compactMap { $0[key] }.first
    }

    private static func englishKey(forLabel label: String) -> String? {
        (allTables.flatMap(\.keys) + aliases.keys).first {
            String(localized: String.LocalizationValue($0), bundle: LanguageManager.appBundle) == label
        }
    }

    /// Time Domain
    private static let timeDomainInfo: [String: @MainActor () -> Info] = [
        "Mean RR": { (
            String(localized: "Mean RR Interval", bundle: LanguageManager.appBundle),
            String(localized: "The average time between successive heartbeats in milliseconds. Inversely related to heart rate.", bundle: LanguageManager.appBundle),
            String(localized: "Awake at rest: about 750–1,000 ms (60–80 bpm). Asleep: about 900–1,300 ms (45–65 bpm).", bundle: LanguageManager.appBundle)
        ) },
        "SDNN": { (
            String(localized: "Standard Deviation of NN Intervals", bundle: LanguageManager.appBundle),
            String(localized: "Measures overall heart rate variability. Reflects both sympathetic and parasympathetic activity over the measurement period.", bundle: LanguageManager.appBundle),
            String(localized: "Varies widely between people and with age (roughly 50–100 ms in many adults). Increases with fitness. Your own trend is the useful comparison.", bundle: LanguageManager.appBundle)
        ) },
        "RMSSD": { (
            String(localized: "Root Mean Square of Successive Differences", bundle: LanguageManager.appBundle),
            String(localized: "The primary HRV metric. Measures beat-to-beat variation and strongly reflects parasympathetic (rest-and-digest) nervous system activity.", bundle: LanguageManager.appBundle),
            String(localized: "Higher is generally better. Age-dependent ranges: 20s-30s: 40-80ms, 40s-50s: 25-50ms, 60+: 15-35ms. Athletes often higher.", bundle: LanguageManager.appBundle)
        ) },
        "pNN50": { (
            String(localized: "Percentage of NN50", bundle: LanguageManager.appBundle),
            String(localized: "The percentage of successive RR intervals that differ by more than 50ms. Like RMSSD, it reflects parasympathetic (vagal) activity.", bundle: LanguageManager.appBundle),
            String(localized: "Higher values (5-25%) indicate greater parasympathetic activity and recovery. Very low values (<2%) suggest autonomic suppression.", bundle: LanguageManager.appBundle)
        ) },
        "SDSD": { (
            String(localized: "Standard Deviation of Successive Differences", bundle: LanguageManager.appBundle),
            String(localized: "Measures the variability of successive RR interval differences. Closely related to RMSSD and reflects short-term HRV.", bundle: LanguageManager.appBundle),
            String(localized: "Higher values indicate greater beat-to-beat variability. Similar interpretation to RMSSD.", bundle: LanguageManager.appBundle)
        ) },
        "HR Range": { (
            String(localized: "Heart Rate Range", bundle: LanguageManager.appBundle),
            String(localized: "The difference between minimum and maximum heart rate during the recording. Indicates the span of HR variation.", bundle: LanguageManager.appBundle),
            String(localized: "Wider range during rest may indicate arousals or movement. Narrow range suggests stable, restful state.", bundle: LanguageManager.appBundle)
        ) },
        "Mean HR": { (
            String(localized: "Mean Heart Rate", bundle: LanguageManager.appBundle),
            String(localized: "Your average heart rate across the entire measurement period in beats per minute.", bundle: LanguageManager.appBundle),
            String(localized: "Awake at rest: about 60–80 bpm for adults. Asleep: about 45–65 bpm. Lower in endurance athletes.", bundle: LanguageManager.appBundle)
        ) },
        "SD HR": { (
            String(localized: "Heart Rate Standard Deviation", bundle: LanguageManager.appBundle),
            String(localized: "The standard deviation of heart rate values. Measures how much your heart rate fluctuated during the recording.", bundle: LanguageManager.appBundle),
            String(localized: "Higher values indicate more HR variation. At rest, 5-15 bpm is typical.", bundle: LanguageManager.appBundle)
        ) },
        "HRV TI": { (
            String(localized: "HRV Triangular Index", bundle: LanguageManager.appBundle),
            String(localized: "Derived from the histogram of RR intervals (total beats / peak bin). A geometric measure of overall HRV that's robust to artifacts.", bundle: LanguageManager.appBundle),
            String(localized: "Typical range: 15-40. Higher values indicate greater variability. Less sensitive to individual artifacts than time-domain metrics.", bundle: LanguageManager.appBundle)
        ) }
    ]

    /// Frequency Domain
    private static let frequencyDomainInfo: [String: @MainActor () -> Info] = [
        "VLF": { (
            String(localized: "Very Low Frequency Power (≤0.04 Hz)", bundle: LanguageManager.appBundle),
            String(localized: "Power in the very low frequency band. Associated with thermoregulation, hormonal fluctuations, and long-term regulatory mechanisms.", bundle: LanguageManager.appBundle),
            String(localized: "Requires longer recordings (>5 min) to be meaningful. Read it against your own recent nights rather than a population norm.", bundle: LanguageManager.appBundle)
        ) },
        "LF": { (
            String(localized: "Low Frequency Power (0.04-0.15 Hz)", bundle: LanguageManager.appBundle),
            String(localized: "Power in the low frequency band. Reflects a mix of sympathetic and parasympathetic activity, including baroreceptor activity.", bundle: LanguageManager.appBundle),
            String(localized: "Mostly reflects baroreflex activity, with both sympathetic and parasympathetic input. It is not a sympathetic index on its own, and neither is LF/HF (Billman 2013). Read it alongside HF and against your own baseline.", bundle: LanguageManager.appBundle)
        ) },
        "HF": { (
            String(localized: "High Frequency Power (0.15-0.4 Hz)", bundle: LanguageManager.appBundle),
            String(localized: "Power in the high frequency band, strongly associated with parasympathetic (vagal) activity and respiratory sinus arrhythmia.", bundle: LanguageManager.appBundle),
            String(localized: "Higher is generally better at rest. Typical range: 200-3000 ms². Decreases with stress, exercise, and sympathetic activation.", bundle: LanguageManager.appBundle)
        ) },
        "Total Power": { (
            String(localized: "Total Spectral Power", bundle: LanguageManager.appBundle),
            String(localized: "The sum of all frequency band powers (VLF + LF + HF). Represents overall autonomic activity.", bundle: LanguageManager.appBundle),
            String(localized: "Higher values indicate greater overall HRV. Typical range: 1000-8000 ms². Decreases with age and stress.", bundle: LanguageManager.appBundle)
        ) },
        "LF n.u.": { (
            String(localized: "Low Frequency (Normalized Units)", bundle: LanguageManager.appBundle),
            String(localized: "LF power as a percentage of total LF+HF power. Removes the influence of VLF and normalizes for comparison.", bundle: LanguageManager.appBundle),
            String(localized: "Typical range: 30-70%. Higher values suggest relative sympathetic predominance.", bundle: LanguageManager.appBundle)
        ) },
        "HF n.u.": { (
            String(localized: "High Frequency (Normalized Units)", bundle: LanguageManager.appBundle),
            String(localized: "HF power as a percentage of total LF+HF power. Removes VLF influence and normalizes for comparison.", bundle: LanguageManager.appBundle),
            String(localized: "Typical range: 30-70%. Higher values suggest relative parasympathetic predominance and better recovery.", bundle: LanguageManager.appBundle)
        ) },
        "LF/HF": { (
            String(localized: "LF/HF Ratio", bundle: LanguageManager.appBundle),
            String(localized: "The ratio of low-frequency to high-frequency power. Long used as a sympathovagal balance index, an interpretation the evidence does not support (Billman 2013) — LF is not a sympathetic signal.", bundle: LanguageManager.appBundle),
            String(localized: "Usual resting range 0.5-2.0. Read it as a position in that range, not as autonomic balance. Breathing rate moves it as much as anything else — slow paced breathing pushes it up sharply.", bundle: LanguageManager.appBundle)
        ) }
    ]

    /// Nonlinear
    private static let nonlinearInfo: [String: @MainActor () -> Info] = [
        "SD1": { (
            String(localized: "Poincaré SD1 (Short-term)", bundle: LanguageManager.appBundle),
            String(localized: "Standard deviation perpendicular to the line of identity in the Poincaré plot. Measures short-term, beat-to-beat variability.", bundle: LanguageManager.appBundle),
            String(localized: "Strongly correlated with RMSSD and parasympathetic activity. Typical range: 20-70ms. Higher indicates better vagal tone.", bundle: LanguageManager.appBundle)
        ) },
        "SD2": { (
            String(localized: "Poincaré SD2 (Long-term)", bundle: LanguageManager.appBundle),
            String(localized: "Standard deviation along the line of identity in the Poincaré plot. Measures longer-term variability patterns.", bundle: LanguageManager.appBundle),
            String(localized: "Reflects overall HRV including sympathetic influences. Typical range: 50-150ms.", bundle: LanguageManager.appBundle)
        ) },
        "SD1/SD2": { (
            String(localized: "Poincaré SD1/SD2 Ratio", bundle: LanguageManager.appBundle),
            String(localized: "The ratio of short-term to long-term variability. Indicates the balance between rapid parasympathetic and slower autonomic influences.", bundle: LanguageManager.appBundle),
            String(localized: "Typical range: 0.2-0.5. Low ratios suggest reduced parasympathetic modulation.", bundle: LanguageManager.appBundle)
        ) },
        "DFA α1": { (
            String(localized: "DFA Alpha-1 (Short-term Scaling)", bundle: LanguageManager.appBundle),
            String(localized: "Detrended Fluctuation Analysis over 4-16 beats. Measures fractal correlation properties and heart rhythm complexity.", bundle: LanguageManager.appBundle),
            String(localized: "Resting reference range: 0.75–1.0. During exercise it falls as intensity rises: about 0.75 marks the aerobic threshold (VT1) and about 0.5 the second threshold (VT2).", bundle: LanguageManager.appBundle)
        ) },
        "DFA α2": { (
            String(localized: "DFA Alpha-2 (Long-term Scaling)", bundle: LanguageManager.appBundle),
            String(localized: "Detrended Fluctuation Analysis over 16-64 beats. Measures longer-range fractal correlations in heart rhythm.", bundle: LanguageManager.appBundle),
            String(localized: "Less studied than α1. Values around 1.0 are typical at rest.", bundle: LanguageManager.appBundle)
        ) },
        "α1 R²": { (
            String(localized: "DFA Alpha-1 R-squared", bundle: LanguageManager.appBundle),
            String(localized: "The coefficient of determination for the DFA α1 calculation. Indicates how well the fractal model fits your data.", bundle: LanguageManager.appBundle),
            String(localized: "Higher is better. R² > 0.95 indicates reliable α1 measurement. Lower values suggest noisy data or artifacts.", bundle: LanguageManager.appBundle)
        ) },
        "SampEn": { (
            String(localized: "Sample Entropy", bundle: LanguageManager.appBundle),
            String(localized: "Measures the complexity and regularity of the heart rhythm. Lower values indicate more predictable, regular patterns.", bundle: LanguageManager.appBundle),
            String(localized: "Typical range: 1.0–2.0. Higher values reflect more complex heart-rate dynamics. Values below 0.5 are unusual in resting recordings — most often a sensor-quality artifact.", bundle: LanguageManager.appBundle)
        ) },
        "ApEn": { (
            String(localized: "Approximate Entropy", bundle: LanguageManager.appBundle),
            String(localized: "Similar to Sample Entropy but includes self-matches. Measures the predictability of the heart rhythm time series.", bundle: LanguageManager.appBundle),
            String(localized: "Typical range: 0.8-1.5. Higher indicates more complexity. Lower values suggest more regular, predictable rhythm.", bundle: LanguageManager.appBundle)
        ) }
    ]

    /// ANS Indexes
    private static let ansInfo: [String: @MainActor () -> Info] = [
        "Stress Index": { (
            String(localized: "Baevsky's Stress Index", bundle: LanguageManager.appBundle),
            String(localized: "Derived from the geometric properties of RR interval distribution. Reflects sympathetic nervous system load.", bundle: LanguageManager.appBundle),
            String(localized: "Low (<100): Relaxed. Moderate (100-200): Normal. Elevated (200-300): Stressed. High (>300): Significant strain.", bundle: LanguageManager.appBundle)
        ) },
        // The detail line says whose index this is.
        // Emuqu's PNS/SNS share Kubios' published inputs and Nunan 2010 norms,
        // but Kubios' combining weights are proprietary and unpublished, so
        // ours is an equal-thirds mean standing in for a formula we cannot
        // see. The values do not match Kubios' and never did. A user
        // cross-checking against Kubios deserves to know that before they
        // conclude one of the two is broken. See `StressAnalyzer`.
        "PNS Index": { (
            String(localized: "Parasympathetic Nervous System Index", bundle: LanguageManager.appBundle),
            String(localized: "Emuqu's own composite of parasympathetic (rest-and-digest) activity, averaging three HRV metrics against published population norms. It won't match the same-named index in other apps, which use their own weightings.", bundle: LanguageManager.appBundle),
            String(localized: "Range typically -3 to +3. Higher values accompany the resting pattern associated with recovery; lower values the opposite. Read your own trend rather than a single value.", bundle: LanguageManager.appBundle)
        ) },
        "SNS Index": { (
            String(localized: "Sympathetic Nervous System Index", bundle: LanguageManager.appBundle),
            String(localized: "Emuqu's own composite of sympathetic (fight-or-flight) activity, averaging three HRV and stress metrics against published population norms. It won't match the same-named index in other apps, which use their own weightings.", bundle: LanguageManager.appBundle),
            String(localized: "Range typically -3 to +3. Higher values accompany the pattern associated with arousal or stress; lower values the opposite. Read your own trend rather than a single value.", bundle: LanguageManager.appBundle)
        ) },
        "Resp Rate": { (
            String(localized: "Respiratory Rate", bundle: LanguageManager.appBundle),
            String(localized: "Breathing rate estimated from the high-frequency oscillations in heart rate (respiratory sinus arrhythmia).", bundle: LanguageManager.appBundle),
            String(localized: "Normal rest: 12-20 breaths/min. Slower breathing promotes HRV. Very slow (<6) or fast (>20) may affect HRV accuracy.", bundle: LanguageManager.appBundle)
        ) },
        "Readiness": { (
            String(localized: "Recovery Readiness Score", bundle: LanguageManager.appBundle),
            String(localized: "A composite score (1-10) estimating your body's readiness for physical and mental demands.", bundle: LanguageManager.appBundle),
            String(localized: "7–10: Ready. 4.5–7: Moderate. 2–4.5: Fatigued. Below 2: Rest.", bundle: LanguageManager.appBundle)
        ) }
    ]

    /// Data Quality
    private static let dataQualityInfo: [String: @MainActor () -> Info] = [
        "Clean Beats": { (
            String(localized: "Clean Beat Count", bundle: LanguageManager.appBundle),
            String(localized: "The number of normal (non-artifact) heartbeats used in the analysis after artifact removal.", bundle: LanguageManager.appBundle),
            String(localized: "More beats = more reliable analysis. Minimum ~120 for basic metrics, 300+ ideal for frequency analysis.", bundle: LanguageManager.appBundle)
        ) },
        "Artifacts": { (
            String(localized: "Artifact Percentage", bundle: LanguageManager.appBundle),
            String(localized: "The percentage of detected ectopic beats, missed beats, and noise removed from analysis.", bundle: LanguageManager.appBundle),
            String(localized: "<5%: Excellent quality. 5-10%: Good. 10-20%: Acceptable. >20%: Results may be unreliable.", bundle: LanguageManager.appBundle)
        ) }
    ]

    private var fallbackInfo: Info {
        (
            metric,
            String(localized: "This metric helps assess your heart rate variability and autonomic nervous system balance.", bundle: LanguageManager.appBundle),
            String(localized: "Tap for more details about this metric in Settings → Metric Guide.", bundle: LanguageManager.appBundle)
        )
    }
}
