import SwiftUI

/// Slider card shown when HRV data quality is poor (pre-sleep, insufficient).
/// Lets the user rate their perceived readiness on a 0-10 scale. The value
/// is blended into the HRV factor (30% weight) alongside the baseline fallback.
struct SubjectiveReadinessCard: View {
    @Binding var perceivedReadiness: Double?
    let quality: HRVDataQuality

    @State private var sliderValue: Double = 5.0
    @State private var hasSubmitted: Bool = false

    private var qualityMessage: String {
        switch quality {
        case .preSleep:
            String(localized: "Your strap disconnected before sleep. Rate how you feel so we can estimate your recovery.", bundle: LanguageManager.appBundle)
        case .insufficient:
            String(localized: "Not enough HRV data for a reliable score. Rate how you feel instead.", bundle: LanguageManager.appBundle)
        case .good:
            ""
        }
    }

    private var emoji: String {
        switch Int(sliderValue.rounded()) {
        case 0 ... 1: "\u{1F629}" // weary
        case 2 ... 3: "\u{1F614}" // pensive
        case 4 ... 5: "\u{1F610}" // neutral
        case 6 ... 7: "\u{1F60A}" // smiling
        case 8 ... 9: "\u{1F4AA}" // flexed bicep
        case 10: "\u{1F525}" // fire
        default: "\u{1F610}"
        }
    }

    private var label: String {
        switch Int(sliderValue.rounded()) {
        case 0 ... 1: String(localized: "Terrible", bundle: LanguageManager.appBundle)
        case 2 ... 3: String(localized: "Poor", bundle: LanguageManager.appBundle)
        case 4 ... 5: String(localized: "OK", bundle: LanguageManager.appBundle)
        case 6 ... 7: String(localized: "Good", bundle: LanguageManager.appBundle)
        case 8 ... 9: String(localized: "Great", bundle: LanguageManager.appBundle)
        case 10: String(localized: "Peak", bundle: LanguageManager.appBundle)
        default: String(localized: "OK", bundle: LanguageManager.appBundle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Text(qualityMessage)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            sliderRow

            submitButton
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
        .padding(.horizontal)
        .onAppear { restoreExistingRating() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "hand.raised.fill")
                .foregroundColor(AppTheme.accent)
            Text(String(localized: "How Do You Feel?", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.textPrimary)
        }
    }

    /// VoiceOver reads the slider as the question with the rating and its
    /// word; the emoji and the word beside the slider repeat that, so they
    /// are hidden from it.
    private var sliderRow: some View {
        HStack {
            Text(emoji)
                .font(.title)
                .accessibilityHidden(true)
            Slider(value: $sliderValue, in: 0 ... 10, step: 1)
                .tint(sliderColor)
                .accessibilityLabel(Text(String(localized: "How Do You Feel?", bundle: LanguageManager.appBundle)))
                .accessibilityValue(Text(String(localized: "\(Int(sliderValue.rounded())) of 10, \(label)", bundle: LanguageManager.appBundle)))
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundColor(labelColor)
                .frame(minWidth: 55, alignment: .trailing)
                .fixedSize()
                .accessibilityHidden(true)
        }
    }

    private var submitButton: some View {
        Button {
            submit()
        } label: {
            bodyLabel
        }
    }

    private func submit() {
        let normalized = sliderValue / 10.0
        perceivedReadiness = normalized
        hasSubmitted = true
    }

    private func restoreExistingRating() {
        if let existing = perceivedReadiness {
            sliderValue = existing * 10.0
            hasSubmitted = true
        }
    }

    private var bodyLabel: some View {
        HStack {
            if hasSubmitted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
            Text(hasSubmitted ? String(localized: "Update", bundle: LanguageManager.appBundle) : String(localized: "Apply", bundle: LanguageManager.appBundle))
        }
        .font(.subheadline.weight(.medium))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(AppTheme.accent.opacity(0.15))
        .foregroundColor(AppTheme.accent)
        .cornerRadius(8)
    }

    /// The word's colour: the slider's hue, darkened where needed to read as
    /// text on the card.
    private var labelColor: Color {
        switch Int(sliderValue.rounded()) {
        case 0 ... 2: AppTheme.terracottaText
        case 3 ... 4: AppTheme.wongAttentionText
        case 7 ... 8: AppTheme.sageText
        case 9 ... 10: AppTheme.terracottaText
        default: AppTheme.softGoldText
        }
    }

    private var sliderColor: Color {
        switch Int(sliderValue.rounded()) {
        case 0 ... 2: .red
        case 3 ... 4: .orange
        case 5 ... 6: .yellow
        case 7 ... 8: .green
        case 9 ... 10: AppTheme.accent
        default: .yellow
        }
    }
}
