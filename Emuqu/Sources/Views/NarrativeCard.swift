import SwiftUI

/// The single narrative on Dashboard: the "Today's Loop" card. Also used
/// for the score explanation on the recovery detail screen.
///
/// Visual: quote-style card with left vertical accent bar in the score
/// colour, 16pt corner radius, body at 17pt SF Pro Display Semibold.
///
/// One sentence per idea. Two if absolutely
/// needed. Never three.
struct NarrativeCard: View {
    let text: String
    var accent: Color = AppTheme.wongOptimal

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(accent)
                .frame(width: 4)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            content
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

    private var content: some View {
        Text(verbatim: text)
            .scaledFont(size: 17, weight: .semibold)
            .foregroundStyle(AppTheme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
