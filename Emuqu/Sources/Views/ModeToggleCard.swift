import SwiftUI

/// Build plan §3.13 — used on Trajectory screen for Comeback, Peaking,
/// Intentional overreach. Card with icon, mode name, status (Off / On /
/// Auto-detected), tap-to-explain disclosure, optional end-date picker
/// for overreach.
///
/// Behavior: tap to toggle. Confirmation sheet on enable for Comeback
/// (because it changes scoring). No confirmation for Peaking-auto.
/// Confirmation for Intentional overreach because it suppresses warning
/// copy.
struct ModeToggleCard: View {
    enum ModeStatus {
        case off
        case on(detail: String?)
        case autoDetected
    }

    let icon: String
    let title: String
    let status: ModeStatus
    let footerCopy: String
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) { content }
            .buttonStyle(.plain)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            Text(verbatim: footerCopy)
                .scaledFont(size: 13)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(cardBackground)
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .scaledFont(size: 18, weight: .semibold)
                .foregroundStyle(statusColor)
                .frame(width: 28, height: 28)
            Text(verbatim: title)
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            statusBadge
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(AppTheme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(statusColor.opacity(0.2), lineWidth: 1)
            )
    }

    private var statusBadgeStyle: (label: String, color: Color) {
        switch status {
        case .off: ("Off", AppTheme.textTertiary)
        case let .on(detail):
            detail.map { ("On · \($0)", AppTheme.wongOptimal) } ?? ("On", AppTheme.wongOptimal)
        case .autoDetected: ("Auto", AppTheme.wongGood)
        }
    }

    private var statusBadge: some View {
        let (label, color) = statusBadgeStyle
        return Text(verbatim: label)
            .scaledFont(size: 12, weight: .semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
    }

    private var statusColor: Color {
        switch status {
        case .off: AppTheme.textTertiary
        case .on: AppTheme.wongOptimal
        case .autoDetected: AppTheme.wongGood
        }
    }
}
