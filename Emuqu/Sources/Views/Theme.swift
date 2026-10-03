import SwiftUI

/// App theme — high-contrast, health-app palette optimized for readability.
/// Blue primary (trust/calm), green accents (recovery/growth), clean dark backgrounds.
enum AppTheme {
    // MARK: - Core Palette (color-theme aware)

    /// The active color theme (read from user settings)
    @MainActor static var currentColorTheme: ColorTheme {
        AppDependencies.current.app.settingsManager.settings.colorTheme
    }

    /// Primary accent — adapts to color theme and appearance
    @MainActor static var primary: Color {
        let isDark = currentTheme == .dark
        switch currentColorTheme {
        case .blue: return isDark ? Color(red: 0.38, green: 0.60, blue: 1.00) : Color(red: 0.23, green: 0.51, blue: 0.96)
        case .teal: return isDark ? Color(red: 0.28, green: 0.76, blue: 0.73) : Color(red: 0.10, green: 0.59, blue: 0.56)
        case .indigo: return isDark ? Color(red: 0.52, green: 0.50, blue: 0.98) : Color(red: 0.35, green: 0.34, blue: 0.84)
        case .purple: return isDark ? Color(red: 0.72, green: 0.48, blue: 0.96) : Color(red: 0.58, green: 0.30, blue: 0.82)
        case .rose: return isDark ? Color(red: 0.94, green: 0.45, blue: 0.62) : Color(red: 0.82, green: 0.28, blue: 0.48)
        case .orange: return isDark ? Color(red: 0.96, green: 0.58, blue: 0.28) : Color(red: 0.82, green: 0.44, blue: 0.10)
        }
    }

    /// Primary accent for **filled surfaces carrying white text**.
    ///
    /// `primary` is tuned to read as an accent *against* the background — as a
    /// tint on labels, icons, and strokes. White text sitting *on* it is a
    /// different contrast problem, and `primary` fails it in every colour
    /// theme: white on the blue theme is 3.69:1 in light appearance and 2.80:1
    /// in dark, against the 4.5:1 WCAG 2.2 AA floor for body-sized text.
    /// `AccessibilityAuditUITests` flagged the assistant disclaimer's primary
    /// button on exactly this.
    ///
    /// Each value is the corresponding `primary` darkened along its own hue
    /// until white clears 4.6:1, so the colour theme the user picked still
    /// reads as the colour theme they picked — the button is a deeper version
    /// of their accent, not a different one. Measured (white-on-fill):
    ///
    /// | theme  | light | dark |
    /// |--------|-------|------|
    /// | blue   | 4.63  | 4.68 |
    /// | teal   | 4.71  | 4.67 |
    /// | indigo | 5.59  | 4.61 |
    /// | purple | 4.98  | 4.61 |
    /// | rose   | 4.66  | 4.63 |
    /// | orange | 4.62  | 4.64 |
    ///
    /// Use this **only** where white (or another near-white) label sits on the
    /// fill. For tinted text, strokes, and glyphs on the page background, keep
    /// using `primary` — it is the accent the design is built around.
    @MainActor static var primaryFilled: Color {
        let isDark = currentTheme == .dark
        switch currentColorTheme {
        case .blue: return isDark ? Color(red: 0.29, green: 0.45, blue: 0.75) : Color(red: 0.20, green: 0.45, blue: 0.84)
        case .teal: return isDark ? Color(red: 0.18, green: 0.50, blue: 0.48) : Color(red: 0.09, green: 0.51, blue: 0.48)
        case .indigo: return isDark ? Color(red: 0.43, green: 0.41, blue: 0.80) : Color(red: 0.35, green: 0.34, blue: 0.84)
        case .purple: return isDark ? Color(red: 0.56, green: 0.37, blue: 0.75) : Color(red: 0.58, green: 0.30, blue: 0.82)
        case .rose: return isDark ? Color(red: 0.70, green: 0.34, blue: 0.46) : Color(red: 0.78, green: 0.27, blue: 0.46)
        case .orange: return isDark ? Color(red: 0.65, green: 0.39, blue: 0.19) : Color(red: 0.70, green: 0.37, blue: 0.09)
        }
    }

    /// Deep primary for depth
    @MainActor static var primaryDark: Color {
        let isDark = currentTheme == .dark
        switch currentColorTheme {
        case .blue: return isDark ? Color(red: 0.28, green: 0.48, blue: 0.90) : Color(red: 0.12, green: 0.35, blue: 0.78)
        case .teal: return isDark ? Color(red: 0.18, green: 0.60, blue: 0.57) : Color(red: 0.05, green: 0.43, blue: 0.40)
        case .indigo: return isDark ? Color(red: 0.38, green: 0.36, blue: 0.85) : Color(red: 0.22, green: 0.21, blue: 0.68)
        case .purple: return isDark ? Color(red: 0.56, green: 0.34, blue: 0.82) : Color(red: 0.42, green: 0.18, blue: 0.66)
        case .rose: return isDark ? Color(red: 0.80, green: 0.32, blue: 0.50) : Color(red: 0.66, green: 0.16, blue: 0.34)
        case .orange: return isDark ? Color(red: 0.82, green: 0.44, blue: 0.18) : Color(red: 0.66, green: 0.30, blue: 0.04)
        }
    }

    /// Light primary — soft accent
    @MainActor static var primaryLight: Color {
        let isDark = currentTheme == .dark
        switch currentColorTheme {
        case .blue: return isDark ? Color(red: 0.56, green: 0.73, blue: 1.00) : Color(red: 0.44, green: 0.64, blue: 0.98)
        case .teal: return isDark ? Color(red: 0.48, green: 0.85, blue: 0.83) : Color(red: 0.32, green: 0.74, blue: 0.72)
        case .indigo: return isDark ? Color(red: 0.65, green: 0.64, blue: 1.00) : Color(red: 0.52, green: 0.51, blue: 0.92)
        case .purple: return isDark ? Color(red: 0.82, green: 0.64, blue: 1.00) : Color(red: 0.72, green: 0.50, blue: 0.90)
        case .rose: return isDark ? Color(red: 1.00, green: 0.64, blue: 0.76) : Color(red: 0.92, green: 0.50, blue: 0.64)
        case .orange: return isDark ? Color(red: 1.00, green: 0.72, blue: 0.48) : Color(red: 0.92, green: 0.60, blue: 0.32)
        }
    }

    // MARK: - Wong 2011 Deuteranopia-Safe Status Palette
    //
    // status colours always pair with a glyph and a
    // text label. Never colour alone. The palette below is from Wong (2011)
    // Nature Methods — the canonical reference for plot colours legible
    // to deuteranopic viewers (~6% of men). These are the LOCKED status
    // colours for the recovery-score ladder, vitals chip, and trajectory
    // verdicts.
    //
    // Mapping:
    //   wongOptimal   #009E73 — Optimal (75–100 score) — teal-green
    //   wongGood      #0072B2 — Good (60–74 score)     — desaturated blue
    //   wongCaution   #E69F00 — Caution / Pay attention (45–59) — amber-orange
    //   wongAttention #D55E00 — Pay attention / Low (1–44) — orange-red
    //
    // The user's `colorTheme` picker still alters non-status accents
    // (primary / sage / etc.), but these four constants do NOT shift —
    // they are calibrated for accessibility and consistency, not aesthetic.

    /// Wong 2011 — Optimal recovery (teal-green). Used for ScoreVerdict.excellent
    /// and ScoreVerdict.good, vitals "Normal," and trajectory descriptors that
    /// are positive/healthy.
    static let wongOptimal = Color(red: 0.0, green: 0.62, blue: 0.45) // #009E73

    /// Wong 2011 — Good (desaturated blue). Used for ScoreVerdict.fair and
    /// neutral / informational moments where green would read as celebratory.
    static let wongGood = Color(red: 0.0, green: 0.45, blue: 0.70) // #0072B2

    /// Wong 2011 — Caution (amber-orange). Used for ScoreVerdict.payAttention,
    /// vitals "Watch," and ramp-band "Rapid increase" framing. Pair with a
    /// triangle / circle glyph; never colour alone.
    static let wongCaution = Color(red: 0.90, green: 0.62, blue: 0.0) // #E69F00

    /// Wong 2011 — Pay attention (orange-red). Reserved for ScoreVerdict.low,
    /// ScoreVerdict.veryLow, vitals "Elevated." Always pairs with a glyph.
    /// This is the strongest tier on the ladder — there is intentionally no
    /// pure red on the consumer surface ("pure red is
    /// reserved for genuine medical alerts (<1% of UI surface)").
    static let wongAttention = Color(red: 0.84, green: 0.37, blue: 0.0) // #D55E00

    // MARK: - Status colours as text

    // The status colours are tuned for rings, glyphs and fills. As text on the
    // light theme's white cards they fail WCAG contrast — the verdict word in
    // wongCaution read at 2.3:1, a "Good" HRV label in softGold at 1.6:1 —
    // so words take these: the same hues darkened to at least 4.5:1 on the
    // light theme, and the base colour (lightened where it fell short) on dim
    // and dark.

    @MainActor static var wongOptimalText: Color {
        currentTheme == .light ? Color(red: 0.0, green: 0.496, blue: 0.36) : wongOptimal
    }

    @MainActor static var wongGoodText: Color {
        currentTheme == .light ? wongGood : Color(red: 0.19, green: 0.554, blue: 0.757)
    }

    @MainActor static var wongCautionText: Color {
        currentTheme == .light ? Color(red: 0.576, green: 0.397, blue: 0.0) : wongCaution
    }

    @MainActor static var wongAttentionText: Color {
        currentTheme == .light ? Color(red: 0.714, green: 0.314, blue: 0.0) : Color(red: 0.846, green: 0.395, blue: 0.04)
    }

    @MainActor static var sageText: Color {
        currentTheme == .light ? Color(red: 0.126, green: 0.491, blue: 0.302) : sage
    }

    @MainActor static var softGoldText: Color {
        currentTheme == .light ? Color(red: 0.539, green: 0.418, blue: 0.121) : softGold
    }

    @MainActor static var terracottaText: Color {
        currentTheme == .light ? Color(red: 0.733, green: 0.281, blue: 0.265) : terracotta
    }

    @MainActor static var dustyRoseText: Color {
        currentTheme == .light ? Color(red: 0.513, green: 0.363, blue: 0.711) : dustyRose
    }

    // MARK: - Accent Colors (vivid, high-contrast)

    /// Emerald green — recovery, vitality, growth
    @MainActor static let sage = Color(red: 0.20, green: 0.78, blue: 0.48) // #34C77A

    /// Warm coral — attention, heart rate, urgency.
    /// Used by the dashboard hero, score breakdown card, and similar
    /// non-fitness surfaces. Fitness views use `fitnessAccent` instead
    /// so the user's color-theme picker actually affects them.
    @MainActor static let terracotta = Color(red: 0.94, green: 0.36, blue: 0.34) // #F05C57

    /// Accent for the Fitness tab and post-workout summary: always `primary`,
    /// which tracks the user's selected `colorTheme`, so changing the theme
    /// repaints workout-related surfaces (active-sport fill, Start button,
    /// route polyline, hero-card icon).
    @MainActor static var fitnessAccent: Color { primary }

    /// Soft violet — gentle warmth, secondary data
    static let dustyRose = Color(red: 0.65, green: 0.46, blue: 0.90) // #A675E5

    /// Warm sand/cream — subtle highlights
    static let sand = Color(red: 0.94, green: 0.91, blue: 0.85) // #F0E8D9

    /// Bright amber — warning, moderate readiness
    @MainActor static let softGold = Color(red: 0.98, green: 0.76, blue: 0.22) // #FAC238

    /// Cyan — fresh accent, cool data
    static let mist = Color(red: 0.30, green: 0.78, blue: 0.90) // #4DC7E5

    // MARK: - Secondary (Legacy compatibility)

    static let secondary = dustyRose
    static let secondaryLight = Color(red: 0.78, green: 0.65, blue: 0.95) // #C7A6F2
    static let secondaryDark = Color(red: 0.50, green: 0.34, blue: 0.72) // #7F57B8
    @MainActor static let accent = terracotta

    // MARK: - Semantic Colors

    /// Success — vivid green
    @MainActor static let success = sage

    /// Warning — darker amber. `softGold` at #FAC238 only hits ~1.6:1 on
    /// white (WCAG AA fail for normal text). This variant at #8A5A00 hits
    /// ~4.9:1 on white / ~5.5:1 on Dim / ~7.5:1 on Dark so it reads as
    /// caution text without visual noise. Use `softGold` for fills / rings
    /// / glyphs where contrast is carried by the surrounding chrome, and
    /// use `warning` when the color is the primary carrier of meaning on
    /// a text element.
    static let warning = Color(red: 0.54, green: 0.35, blue: 0.00) // #8A5A00

    /// Alert — clear red
    static let alert = Color(red: 0.92, green: 0.30, blue: 0.28) // #EB4D47

    // MARK: - Current Theme

    /// The active appearance theme (read from user settings)
    @MainActor static var currentTheme: AppearanceTheme {
        AppDependencies.current.app.settingsManager.settings.appearanceTheme
    }

    // MARK: - Backgrounds (theme-aware)

    /// Main background — adapts to user theme
    @MainActor static var background: Color {
        switch currentTheme {
        case .light: Color(red: 0.96, green: 0.96, blue: 0.97) // #F5F5F7
        case .dim: Color(red: 0.16, green: 0.16, blue: 0.19) // #292930
        case .dark: Color(red: 0.07, green: 0.07, blue: 0.08) // #111114
        }
    }

    /// Card background — adapts to user theme
    @MainActor static var cardBackground: Color {
        switch currentTheme {
        case .light: Color.white
        case .dim: Color(red: 0.20, green: 0.20, blue: 0.24) // #33333D
        case .dark: Color(red: 0.11, green: 0.11, blue: 0.13) // #1C1C22
        }
    }

    /// Elevated card — adapts to user theme
    @MainActor static var cardElevated: Color {
        switch currentTheme {
        case .light: Color.white
        case .dim: Color(red: 0.24, green: 0.24, blue: 0.28) // #3D3D47
        case .dark: Color(red: 0.15, green: 0.15, blue: 0.17) // #26262B
        }
    }

    /// Subtle tint for sections
    @MainActor static var sectionTint: Color {
        switch currentTheme {
        case .light: Color(red: 0.93, green: 0.93, blue: 0.95) // #EDEDED
        case .dim: Color(red: 0.18, green: 0.18, blue: 0.21) // #2E2E36
        case .dark: Color(red: 0.09, green: 0.09, blue: 0.11) // #17171B
        }
    }

    // MARK: - Text Colors (theme-aware)

    /// Primary text — adapts to background
    @MainActor static var textPrimary: Color {
        switch currentTheme {
        case .light: Color(red: 0.10, green: 0.10, blue: 0.13) // #1A1A21
        case .dim: Color(red: 0.92, green: 0.92, blue: 0.94) // #EAEAF0
        case .dark: Color(red: 0.94, green: 0.94, blue: 0.96) // #F0F0F5
        }
    }

    /// Secondary text — adapts to background
    @MainActor static var textSecondary: Color {
        switch currentTheme {
        case .light: Color(red: 0.36, green: 0.36, blue: 0.42) // #5C5C6B
        case .dim: Color(red: 0.66, green: 0.66, blue: 0.72) // #A8A8B8
        case .dark: Color(red: 0.62, green: 0.62, blue: 0.70) // #9E9EB3
        }
    }

    /// Tertiary text — adapts to background.
    ///
    /// Contrast-corrected. The previous values (#80808F / #808094 / #707085)
    /// failed WCAG 2.2 AA in **all three** themes on **all three** surfaces —
    /// between 2.78:1 and 3.89:1 against a 4.5:1 requirement — which
    /// `AccessibilityAuditUITests` surfaced as the single largest source of
    /// contrast failures across every tab. These clear 4.5:1 on the worst case
    /// (elevated card) and go up from there:
    ///
    /// | theme | page bg | card | elevated |
    /// |-------|---------|------|----------|
    /// | light | 4.60    | 5.01 | 5.01     |
    /// | dim   | 6.20    | 5.36 | 4.60     |
    /// | dark  | 5.81    | 5.22 | 4.64     |
    ///
    /// Hue and the slight blue-violet cast are unchanged — only lightness
    /// moved, so the visual character of the palette is preserved. Tertiary is
    /// still clearly recessive against `textSecondary`.
    @MainActor static var textTertiary: Color {
        switch currentTheme {
        case .light: Color(red: 0.43, green: 0.43, blue: 0.49) // #6E6E7D
        case .dim: Color(red: 0.66, green: 0.66, blue: 0.75) // #A8A8BE
        case .dark: Color(red: 0.55, green: 0.55, blue: 0.64) // #8D8DA3
        }
    }

    // MARK: - Gradients

    /// Primary gradient
    @MainActor static var primaryGradient: LinearGradient {
        LinearGradient(
            colors: [primaryLight, primary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Hero card gradient — bold depth
    @MainActor static var heroGradient: LinearGradient {
        LinearGradient(
            colors: [primary.opacity(0.85), primaryDark.opacity(0.95)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Metric Colors (Harmonious)

    /// RMSSD — primary blue
    @MainActor static var rmssdColor: Color {
        primary
    }

    /// SDNN — violet (brightened on dark backgrounds)
    @MainActor static var sdnnColor: Color {
        switch currentTheme {
        case .light, .dim: Color(red: 0.55, green: 0.38, blue: 0.82) // #8C61D1
        case .dark: Color(red: 0.68, green: 0.54, blue: 0.94) // #AD8AF0
        }
    }

    /// Heart rate — coral red
    @MainActor static let heartRateColor = terracotta

    /// HF power — emerald green
    @MainActor static let hfColor = sage

    /// LF power — light blue
    @MainActor static var lfColor: Color {
        primaryLight
    }

    /// VLF power — neutral gray
    static let vlfColor = Color(red: 0.55, green: 0.55, blue: 0.62) // #8C8C9E

    // MARK: - Readiness Colors

    /// Readiness color aligned with `RecoveryScoreCalculator.readinessLabel` tiers:
    /// ≥ 7.0 "Ready", ≥ 4.5 "Moderate", ≥ 2.0 "Fatigued", < 2.0 "Rest"
    @MainActor static func readinessColor(_ score: Double) -> Color {
        if score >= 7.0 { return sage }
        if score >= 4.5 { return softGold }
        if score >= 2.0 { return terracotta }
        return dustyRose
    }

    /// Recovery score color — delegates to the canonical `ScoreVerdict`
    /// ladder (90/75/60/45/30) and its Wong palette.
    /// An independent ladder or palette here makes the morning sheet's
    /// score ring disagree with the dashboard hero for the SAME number
    /// (e.g. 78 gold here, "Good" green on the dashboard). One ladder, one
    /// palette.
    static func recoveryColor(_ score: Double) -> Color {
        ScoreVerdict(score: score).color
    }

    // MARK: - HRV Helpers

    /// HRV label from absolute RMSSD value.
    /// When a non-nil, positive `baseline` is supplied the assessment is
    /// baseline-relative (percent-change thresholds); otherwise absolute thresholds are used.
    static func hrvLabel(_ hrv: Double, baseline: Double? = nil) -> String {
        if let baseline, baseline > 0 {
            // The tiers "What This Means" rates the same night by.
            let b = LanguageManager.appBundle
            return switch AnalysisSummaryGenerator.personalCategory(ratio: hrv / baseline) {
            case .excellent: String(localized: "Excellent", bundle: b)
            case .good: String(localized: "Good", bundle: b)
            case .fair: String(localized: "Fair", bundle: b)
            case .reduced: String(localized: "Reduced", bundle: b)
            case .low: String(localized: "Low", bundle: b)
            }
        }
        if hrv >= 60 { return String(localized: "Excellent", bundle: LanguageManager.appBundle) }
        if hrv >= 45 { return String(localized: "Good", bundle: LanguageManager.appBundle) }
        if hrv >= 30 { return String(localized: "Fair", bundle: LanguageManager.appBundle) }
        return String(localized: "Low", bundle: LanguageManager.appBundle)
    }

    /// HRV color from absolute RMSSD value (with optional baseline-relative mode).
    @MainActor static func hrvColor(_ hrv: Double, baseline: Double? = nil) -> Color {
        if let baseline, baseline > 0 {
            // The `hrvLabel` tiers in the absolute palette below: Good must
            // not share Excellent's colour, or the two read the same.
            return switch AnalysisSummaryGenerator.personalCategory(ratio: hrv / baseline) {
            case .excellent: sage
            case .good: softGold
            case .fair: terracotta
            case .reduced, .low: dustyRose
            }
        }
        if hrv >= 60 { return sage }
        if hrv >= 45 { return softGold }
        if hrv >= 30 { return terracotta }
        return dustyRose
    }

    /// `hrvColor` for words: the same tiers, in the readable text shades.
    @MainActor static func hrvTextColor(_ hrv: Double, baseline: Double? = nil) -> Color {
        switch hrvColor(hrv, baseline: baseline) {
        case sage: sageText
        case softGold: softGoldText
        case terracotta: terracottaText
        default: dustyRoseText
        }
    }

    // MARK: - Data Source Helpers

    /// SF Symbol name for the given data-source key.
    static func dataSourceIcon(_ source: String) -> String {
        switch source {
        case "composite": "arrow.triangle.merge"
        case "internal": "internaldrive.fill"
        case "streaming": "antenna.radiowaves.left.and.right"
        default: "questionmark.circle"
        }
    }

    /// Color for the given data-source key.
    @MainActor static func dataSourceColor(_ source: String) -> Color {
        switch source {
        case "composite": softGold
        case "internal": sage
        case "streaming": primary
        default: textSecondary
        }
    }

    /// Human-readable label for the given data-source key.
    static func dataSourceLabel(_ source: String) -> String {
        switch source {
        case "composite": String(localized: "Streamed + Strap", bundle: LanguageManager.appBundle)
        case "internal": String(localized: "Strap", bundle: LanguageManager.appBundle)
        case "streaming": String(localized: "Streamed", bundle: LanguageManager.appBundle)
        default: source.capitalized
        }
    }

    // MARK: - LF/HF Ratio Helpers

    /// Which band dominates, stated plainly. The app does not read LF/HF as a
    /// stress or recovery measure (see the Metric Guide), so the label names
    /// the band rather than a nervous-system state.
    static func balanceInterpretation(_ ratio: Double?) -> String {
        guard let r = ratio else { return "—" }
        if r < 0.5 { return String(localized: "HF-dominant", bundle: LanguageManager.appBundle) }
        if r < 2.0 { return String(localized: "Mixed", bundle: LanguageManager.appBundle) }
        return String(localized: "LF-dominant", bundle: LanguageManager.appBundle)
    }

    /// One neutral colour for every ratio: no band is good or bad.
    @MainActor static func balanceColor(_ ratio: Double?) -> Color {
        ratio == nil ? textTertiary : textPrimary
    }

    // MARK: - Time Formatting

    /// Format an integer number of minutes as "Xh Ym" or "Ym".
    static func formatMinutes(_ minutes: Int) -> String {
        LocalizedDuration.hoursMinutes(minutes: minutes)
    }

    // MARK: - Chart Colors (Cohesive palette)

    @MainActor static var poincarePointColor: Color {
        primary.opacity(0.5)
    }

    @MainActor static var poincareEllipseColor: Color {
        primary.opacity(0.12)
    }

    @MainActor static var poincareEllipseStroke: Color {
        primary.opacity(0.4)
    }

    @MainActor static var tachogramLine: Color {
        primary
    }

    @MainActor static var tachogramFill: Color {
        primary.opacity(0.15)
    }

    // MARK: - Tag Colors (Soft, distinguishable)

    @MainActor static func tagColor(for name: String) -> Color {
        switch name.lowercased() {
        case "morning": softGold
        case "post-exercise", "exercise": terracotta
        case "recovery": sage
        case "evening": dustyRose
        case "night", "sleep", "pre-sleep": primaryDark
        case "stressed": alert
        case "relaxed": mist
        default: primaryLight
        }
    }

    // MARK: - Layout Constants

    static let cornerRadius: CGFloat = 16
    static let smallCornerRadius: CGFloat = 10
    static let padding: CGFloat = 16
    static let smallPadding: CGFloat = 10

    /// Subtle shadow — adapts to theme
    @MainActor static var cardShadow: Color {
        switch currentTheme {
        case .light: Color.black.opacity(0.06)
        case .dim: Color.black.opacity(0.20)
        case .dark: Color.black.opacity(0.30)
        }
    }

    @MainActor static let cardShadowRadius: CGFloat = 12
}

// MARK: - View Extensions

extension View {
    /// Apply zen card styling
    @MainActor func zenCard() -> some View {
        padding(AppTheme.padding)
            .background(AppTheme.cardBackground)
            .cornerRadius(AppTheme.cornerRadius)
            .shadow(color: AppTheme.cardShadow, radius: AppTheme.cardShadowRadius, x: 0, y: 2)
    }

    /// Apply elevated card styling
    @MainActor func elevatedCard() -> some View {
        padding(AppTheme.padding)
            .background(AppTheme.cardElevated)
            .cornerRadius(AppTheme.cornerRadius)
            .shadow(color: AppTheme.cardShadow, radius: AppTheme.cardShadowRadius + 4, x: 0, y: 4)
    }

    /// Hero card with gradient
    @MainActor func heroCard() -> some View {
        padding(AppTheme.padding)
            .background(AppTheme.heroGradient)
            .cornerRadius(AppTheme.cornerRadius)
            .shadow(color: AppTheme.primary.opacity(0.15), radius: 12, x: 0, y: 4)
    }

    /// Gradient foreground style
    @MainActor func gradientForeground() -> some View {
        foregroundStyle(AppTheme.primaryGradient)
    }

    /// Zen background for screens
    @MainActor func zenBackground() -> some View {
        background(AppTheme.background.ignoresSafeArea())
    }

    /// Zen background for List/Form screens (hides default grouped background)
    @MainActor func zenFormBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(AppTheme.background.ignoresSafeArea())
    }

    /// Soft section header style
    @MainActor func sectionHeader() -> some View {
        font(.subheadline.weight(.semibold))
            .foregroundColor(AppTheme.textSecondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }
}

// MARK: - Button Styles

/// The disabled state is drawn, not ignored. Without it a disabled button
/// looks exactly like a working one, and the only feedback for a tap is
/// nothing happening — which reads as a broken app, and was reported as one.
struct ZenButtonStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var isEnabled

    @MainActor func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius)
                    .fill(isEnabled ? color : AppTheme.textTertiary.opacity(0.35))
                    .shadow(color: isEnabled ? color.opacity(0.3) : .clear, radius: 8, x: 0, y: 4)
            )
            .opacity(isEnabled ? 1 : 0.7)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct ZenSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    @MainActor func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundColor(isEnabled ? AppTheme.primary : AppTheme.textTertiary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius)
                    .stroke(AppTheme.primary.opacity(isEnabled ? 0.3 : 0.15), lineWidth: 1.5)
                    .background(AppTheme.cardBackground.cornerRadius(AppTheme.smallCornerRadius))
            )
            .opacity(isEnabled ? 1 : 0.7)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ZenButtonStyle {
    @MainActor static func zen(_ color: Color? = nil) -> ZenButtonStyle {
        let color = color ?? AppTheme.primary
        return ZenButtonStyle(color: color)
    }
}

extension ButtonStyle where Self == ZenSecondaryButtonStyle {
    static var zenSecondary: ZenSecondaryButtonStyle {
        ZenSecondaryButtonStyle()
    }
}

// Note: Color hex extension is in HRVSession.swift
