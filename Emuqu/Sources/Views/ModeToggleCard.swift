import SwiftUI

/// Used on the Trajectory screen for Comeback, Peaking and Intentional
/// overreach: icon, mode name, status badge (Off / On / Auto) and an
/// explanation.
///
/// Tapping runs `onTap`. The caller decides whether a tap toggles at once or
/// asks for confirmation first.
struct ModeToggleCard: View {
    enum ModeStatus {
        case off
        case on
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
        case .off: (String(localized: "Off", bundle: LanguageManager.appBundle), AppTheme.textTertiary)
        case .on: (String(localized: "On", bundle: LanguageManager.appBundle), AppTheme.wongOptimal)
        case .autoDetected: (String(localized: "Auto", bundle: LanguageManager.appBundle), AppTheme.wongGood)
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
