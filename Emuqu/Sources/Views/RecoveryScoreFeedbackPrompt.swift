import SwiftUI

/// Daily one-tap feedback on the recovery score.
///
/// Tiny chip that lives below the recovery-score card asking whether the
/// number matched how the user actually felt today. One tap per day max;
/// once tapped, the chip flips to a brief "thanks — logged" state and
/// hides on the next dashboard load until a new day starts.
///
/// **Hidden when:**
/// - The user has already given feedback today (don't pester).
/// - Cold-start: tier 1 with no real baseline yet (asking "did 72 match
///   how you felt?" before there's a score worth rating is noise).
/// - Recovery score is 0 (computation error / no data).
struct RecoveryScoreFeedbackPrompt: View {
    @Environment(\.dependencies) var dependencies
    let recoveryScore: Double
    let tier: Int
    let comebackModeActive: Bool

    private var store: RecoveryScoreFeedbackStore { dependencies.services.recoveryScoreFeedbackStore }
    @State private var hasJustSubmitted = false

    var body: some View {
        if shouldShow {
            feedbackRow
        }
    }

    private var feedbackRow: some View {
        HStack(spacing: 10) {
            Text(String(localized: "Did this match how you felt today?", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer(minLength: 8)
            feedbackControls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .animation(.easeInOut(duration: 0.2), value: hasJustSubmitted)
    }

    @ViewBuilder
    private var feedbackControls: some View {
        if hasJustSubmitted {
            Text(String(localized: "Thanks — logged", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.sage)
                .transition(.opacity)
        } else {
            thumbButton(
                glyph: "hand.thumbsup",
                tint: AppTheme.sage,
                label: String(localized: "Score matched how I felt", bundle: LanguageManager.appBundle),
                outcome: .matched
            )
            thumbButton(
                glyph: "hand.thumbsdown",
                tint: AppTheme.terracotta,
                label: String(localized: "Score didn't match how I felt", bundle: LanguageManager.appBundle),
                outcome: .mismatched
            )
        }
    }

    /// 44×44 with a rectangular content shape: the glyph is small, the target
    /// is not.
    private func thumbButton(
        glyph: String,
        tint: Color,
        label: String,
        outcome: RecoveryScoreFeedbackStore.Sentiment
    ) -> some View {
        Button {
            submit(outcome)
        } label: {
            Image(systemName: glyph)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var shouldShow: Bool {
        if store.hasFeedbackForToday() { return false }
        if recoveryScore <= 0 { return false }
        // Tier 1 can be a thin score (HRV-only, no baseline) and asking
        // about it adds noise. Allow the prompt only when sleep AND/OR
        // vitals contributed.
        if tier < 2 { return false }
        return true
    }

    private func submit(_ sentiment: RecoveryScoreFeedbackStore.Sentiment) {
        store.recordFeedback(
            sentiment: sentiment,
            recoveryScore: recoveryScore,
            tier: tier,
            comebackModeActive: comebackModeActive
        )
        withAnimation { hasJustSubmitted = true }
    }
}
