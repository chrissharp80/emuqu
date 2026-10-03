import SwiftUI

/// Subjective feedback chip.
///
/// Small inline pill that surfaces the user's morning feeling rating on the
/// Dashboard:
///   - When `session.morningFeeling` is set: "😊 Felt good · Edit"
///   - When it's nil (skipped or pre-score prompt didn't fire): "Tap how
///     you feel"
///
/// Tap presents `MorningFeelingPrompt` so the user can set or change the
/// feeling without going back through the full pre-score flow. `onSelect`
/// hands the answer to the caller, which writes it to the archived session.
struct DashboardMorningFeelingChip: View {
    let session: HRVSession
    let onSelect: (Int, [MorningFeelingTag]) -> Void

    @State private var isShowingPrompt = false

    /// Computed, not stored, so the labels follow an in-app language switch.
    private static var labels: [Int: (emoji: String, label: String)] {
        [
            1: ("\u{1F629}", String(localized: "Terrible", bundle: LanguageManager.appBundle)),
            2: ("\u{1F615}", String(localized: "Poor", bundle: LanguageManager.appBundle)),
            3: ("\u{1F610}", String(localized: "OK", bundle: LanguageManager.appBundle)),
            4: ("\u{1F60A}", String(localized: "Felt good", bundle: LanguageManager.appBundle)),
            5: ("\u{1F525}", String(localized: "Great", bundle: LanguageManager.appBundle))
        ]
    }

    var body: some View {
        Button {
            isShowingPrompt = true
        } label: {
            bodyLabel
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isShowingPrompt) { prompt }
    }

    private var prompt: some View {
        MorningFeelingPrompt(
            onSelect: { value, tags in
                onSelect(value, tags)
                isShowingPrompt = false
            },
            onSkip: { isShowingPrompt = false },
            existing: session.morningFeeling,
            existingTags: session.morningFeelingTags ?? []
        )
        .padding(20)
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private var labelContent: some View {
        if let value = session.morningFeeling, let entry = Self.labels[value] {
            Text(verbatim: entry.emoji).scaledFont(size: 14)
            Text(verbatim: entry.label)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: "·")
                .scaledFont(size: 12)
                .foregroundStyle(AppTheme.textTertiary)
            Text(String(localized: "Edit", bundle: LanguageManager.appBundle))
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(AppTheme.primary)
        } else {
            Text(verbatim: "\u{1F60A}").scaledFont(size: 14)
            Text(String(localized: "Tap how you feel", bundle: LanguageManager.appBundle))
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var bodyLabel: some View {
        HStack(spacing: 6) {
            labelContent
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(AppTheme.cardBackground)
        )
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
