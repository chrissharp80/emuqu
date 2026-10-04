import SwiftUI

/// Shell for every empty/no-data screen. Centred line
/// illustration hint, headline, body, primary CTA, optional secondary CTA.
struct EmptyState: View {
    let glyph: String  // SF Symbol
    let headline: String
    let message: String
    var primaryLabel: String?
    var primaryAction: () -> Void = {}
    var secondaryLabel: String?
    var secondaryAction: () -> Void = {}

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: glyph)
                .scaledFont(size: 56, weight: .light)
                .foregroundStyle(AppTheme.textTertiary)
                .padding(.bottom, 8)
            Text(verbatim: headline)
                .scaledFont(size: 22, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text(verbatim: message)
                .scaledFont(size: 15)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
            primaryActionButton
            secondaryActionButton
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if let primaryLabel {
            Button(action: primaryAction) {
                Text(verbatim: primaryLabel)
                    .scaledFont(size: 16, weight: .semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(AppTheme.primary)
                    )
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private var secondaryActionButton: some View {
        if let secondaryLabel {
            Button(action: secondaryAction) {
                Text(verbatim: secondaryLabel)
                    .scaledFont(size: 14)
                    .foregroundStyle(AppTheme.primary)
                    .underline()
            }
            .buttonStyle(.plain)
        }
    }
}
