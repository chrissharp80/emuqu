import SwiftUI

/// The single narrative on Dashboard. "Today's Loop"
/// card. Reused as AI Coach card in Workout summary.
///
/// Visual: quote-style card with left vertical accent bar in the score
/// colour, 16pt corner radius, body at 17pt SF Pro Display Semibold,
/// optional thumbs-up / thumbs-down feedback chips at bottom.
///
/// One sentence per idea. Two if absolutely
/// needed. Never three.
struct NarrativeCard: View {
    let text: String
    var accent: Color = AppTheme.wongOptimal
    var feedbackChipsEnabled: Bool = false
    var onThumbsUp: () -> Void = {}
    var onThumbsDown: () -> Void = {}
    var state: DisplayState = .default

    enum DisplayState {
        case `default`
        case loading
        case error(String)
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            if feedbackChipsEnabled, case .default = state {
                feedbackRow
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(accent)
                .frame(width: 4)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            stack
                .padding(.leading, 14)
                .padding(.trailing, 16)
                .padding(.vertical, 16)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppTheme.cardBackground)
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .default:
            Text(verbatim: text)
                .scaledFont(size: 17, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case .loading:
            skeleton
        case let .error(message):
            offlineCopy(message)
        }
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 4)
                .fill(AppTheme.textTertiary.opacity(0.18))
                .frame(height: 14)
            RoundedRectangle(cornerRadius: 4)
                .fill(AppTheme.textTertiary.opacity(0.18))
                .frame(height: 14)
                .padding(.trailing, 60)
        }
    }

    private func offlineCopy(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Coach offline.", bundle: LanguageManager.appBundle))
                .scaledFont(size: 17, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: message)
                .scaledFont(size: 14)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var feedbackRow: some View {
        HStack(spacing: 10) {
            Text(String(localized: "Does this feel right?", bundle: LanguageManager.appBundle))
                .scaledFont(size: 13)
                .foregroundStyle(AppTheme.textTertiary)
            Spacer()
            yesThisFeelsRightButton
            noThisFeelsOffButton
        }
    }

    private var yesThisFeelsRightButton: some View {
        Button(action: onThumbsUp) {
            Image(systemName: "hand.thumbsup")
                .scaledFont(size: 14, weight: .medium)
                .padding(8)
                .background(Circle().fill(AppTheme.sectionTint))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Yes, this feels right", bundle: LanguageManager.appBundle))
    }

    private var noThisFeelsOffButton: some View {
        Button(action: onThumbsDown) {
            Image(systemName: "hand.thumbsdown")
                .scaledFont(size: 14, weight: .medium)
                .padding(8)
                .background(Circle().fill(AppTheme.sectionTint))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "No, this feels off", bundle: LanguageManager.appBundle))
    }
}
