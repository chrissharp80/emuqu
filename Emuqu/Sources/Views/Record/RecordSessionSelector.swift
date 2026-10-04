import SwiftUI

// MARK: - Session Type Picker Section

/// The session type picker card shown before a recording session begins.
/// Lets the user choose between Extended (overnight) and Quick reading.
struct RecordSessionSelector: View {
    @Environment(\.dependencies) var dependencies
    @Binding var selectedSessionType: SessionType?
    private var settingsManager: SettingsManager { dependencies.app.settingsManager }
    var body: some View {
        v2Body
    }

    /// Vertical stack of large mode buttons.
    /// Same underlying SessionType bindings.
    @ViewBuilder
    private var v2Body: some View {
        VStack(spacing: 14) {
            chooseSessionHeader
            dailyModeButton
            extendedModeButton
            napModeButton
        }
    }

    private var chooseSessionHeader: some View {
        HStack {
            Text(String(localized: "Choose session", bundle: LanguageManager.appBundle))
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(AppTheme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
        }
    }

    private var dailyModeButton: some View {
        v2ModeButton(
            type: .quick,
            label: String(localized: "Daily", bundle: LanguageManager.appBundle),
            glyph: "waveform.circle",
            subheading: String(localized: "5-min spot check — Polar strap", bundle: LanguageManager.appBundle),
            detail: String(localized: "Sit quietly, breathe normally. Single readiness score.", bundle: LanguageManager.appBundle)
        )
    }

    private var extendedModeButton: some View {
        v2ModeButton(
            type: .overnight,
            label: String(localized: "Extended", bundle: LanguageManager.appBundle),
            glyph: "moon.stars",
            subheading: String(localized: "Overnight or multi-hour", bundle: LanguageManager.appBundle),
            detail: String(localized: "Start before bed. Full night of HRV + sleep.", bundle: LanguageManager.appBundle)
        )
    }

    private var napModeButton: some View {
        v2ModeButton(
            type: .nap,
            label: String(localized: "Nap", bundle: LanguageManager.appBundle),
            glyph: "bed.double",
            subheading: String(localized: "Short rest, full analysis", bundle: LanguageManager.appBundle),
            detail: String(localized: "Analyzed in full, like an overnight.", bundle: LanguageManager.appBundle)
        )
    }

    private func v2ModeButton(type: SessionType, label: String, glyph: String, subheading: String, detail: String) -> some View {
        let isSelected = selectedSessionType == type
        return Button { selectMode(type) } label: {
            modeButtonLabel(glyph: glyph, label: label, subheading: subheading, detail: detail, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(label) session — \(subheading)", bundle: LanguageManager.appBundle))
        .accessibilityHint(detail)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func selectMode(_ type: SessionType) {
        withAnimation { selectedSessionType = type }
    }

    private func modeButtonLabel(glyph: String, label: String, subheading: String, detail: String, isSelected: Bool) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: glyph)
                .scaledFont(size: 26, weight: .medium)
                .foregroundStyle(isSelected ? .white : AppTheme.primary)
                .frame(width: 36)
            modeButtonCaption(label: label, subheading: subheading, detail: detail, isSelected: isSelected)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ModeButtonChrome(isSelected: isSelected))
    }

    private struct ModeButtonChrome: ViewModifier {
        let isSelected: Bool

        func body(content: Content) -> some View {
            content
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isSelected ? AppTheme.primaryFilled : AppTheme.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(isSelected ? AppTheme.primaryFilled : AppTheme.textTertiary.opacity(0.2), lineWidth: 1)
                )
        }
    }

    private func modeButtonCaption(label: String, subheading: String, detail: String, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: label)
                .scaledFont(size: 17, weight: .semibold)
                .foregroundStyle(isSelected ? .white : AppTheme.textPrimary)
            Text(verbatim: subheading)
                .scaledFont(size: 13)
                .foregroundStyle(isSelected ? .white : AppTheme.textSecondary)
            Text(verbatim: detail)
                .scaledFont(size: 11)
                .foregroundStyle(isSelected ? .white : AppTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Selected Session Header

/// Shows the currently selected session type with a "Change" button.
struct RecordSelectedSessionHeader: View {
    let selectedSessionType: SessionType?
    let onChange: () -> Void

    var body: some View {
        HStack {
            selectedLabel
            Spacer()
            changeButton
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var selectedLabel: some View {
        if let sessionType = selectedSessionType {
            Image(systemName: sessionType.icon)
                .foregroundStyle(AppTheme.primaryGradient)
            Text(sessionType == .overnight ? String(localized: "Extended", bundle: LanguageManager.appBundle) : sessionType.displayName)
                .font(.subheadline.weight(.medium))
        }
    }

    /// A caption-sized text button measures ~44 × 14 pt, well under the
    /// 44 × 44 HIG minimum. `contentShape` extends the tappable region without
    /// changing the visual layout — padding here would push the row apart.
    private var changeButton: some View {
        Button(String(localized: "Change", bundle: LanguageManager.appBundle), action: onChange)
            .font(.caption)
            .foregroundColor(AppTheme.primary)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(String(localized: "Change session type", bundle: LanguageManager.appBundle))
            .accessibilityHint(String(localized: "Pick a different recording session type", bundle: LanguageManager.appBundle))
    }
}
