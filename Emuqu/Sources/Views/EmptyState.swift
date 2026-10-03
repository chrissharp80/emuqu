import SwiftUI

/// Shell for every empty/no-data screen. Centred line
/// illustration hint, headline, body, primary CTA, optional secondary CTA.
/// canonical empty / error state copy library.
/// Verbatim strings the spec requires every view to use when it has
/// nothing to show. Centralised so a copy update lands in one place
/// and propagates everywhere. Computed, not stored, so the copy follows an
/// in-app language switch.
@MainActor
enum EmptyStateLibrary {
    static var noDevicePaired: EmptyState {
        EmptyState(
            glyph: "sensor.tag.radiowaves.forward",
            headline: String(localized: "Pair a strap to start", bundle: LanguageManager.appBundle),
            message: String(localized: "Emuqu needs an HRV-grade heart rate sensor — Polar H10 or Verity Sense.", bundle: LanguageManager.appBundle),
            primaryLabel: String(localized: "Pair a device", bundle: LanguageManager.appBundle)
        )
    }
    static var noSessionsYet: EmptyState {
        EmptyState(
            glyph: "list.bullet.rectangle",
            headline: String(localized: "No readings yet", bundle: LanguageManager.appBundle),
            message: String(localized: "Take your first reading in Record.", bundle: LanguageManager.appBundle),
            primaryLabel: String(localized: "Take a reading", bundle: LanguageManager.appBundle)
        )
    }
    static func searchNoResults(query: String) -> EmptyState {
        EmptyState(
            glyph: "magnifyingglass",
            headline: String(localized: "No readings match \"\(query)\"", bundle: LanguageManager.appBundle),
            message: String(localized: "Try a different keyword or remove filters.", bundle: LanguageManager.appBundle),
            secondaryLabel: String(localized: "Clear search", bundle: LanguageManager.appBundle)
        )
    }
    static func buildingBaseline(day: Int) -> EmptyState {
        EmptyState(
            glyph: "circle.dotted",
            headline: String(localized: "Building your baseline", bundle: LanguageManager.appBundle),
            message: String(localized: "Trends need 7+ days of data. You're on day \(day). Keep recording!", bundle: LanguageManager.appBundle)
        )
    }
    static var coachOffline: EmptyState {
        EmptyState(
            glyph: "wifi.slash",
            headline: String(localized: "Coach offline.", bundle: LanguageManager.appBundle),
            message: String(localized: "Your data is saved. Coach will analyze when you reconnect.", bundle: LanguageManager.appBundle)
        )
    }
    static var apiKeyInvalid: EmptyState {
        EmptyState(
            glyph: "key.slash",
            headline: String(localized: "API key invalid", bundle: LanguageManager.appBundle),
            message: String(localized: "Update your provider key in Settings → Flo.", bundle: LanguageManager.appBundle)
        )
    }
    static var appleHealthDenied: EmptyState {
        EmptyState(
            glyph: "heart.slash",
            headline: String(localized: "Apple Health permissions needed", bundle: LanguageManager.appBundle),
            message: String(localized: "Emuqu can't read your sleep or workout data without these permissions. Open iOS Settings → Privacy & Security → Health → Emuqu and turn them on.", bundle: LanguageManager.appBundle),
            primaryLabel: String(localized: "Open iOS Settings", bundle: LanguageManager.appBundle)
        )
    }
    static func batteryTooLow(percent: Int) -> EmptyState {
        EmptyState(
            glyph: "battery.0",
            headline: String(localized: "Strap battery too low for overnight", bundle: LanguageManager.appBundle),
            message: String(localized: "Polar H10 needs at least 30% battery for a full overnight recording. Yours is at \(percent)%.", bundle: LanguageManager.appBundle)
        )
    }
    static var readingTooShort: EmptyState {
        EmptyState(
            glyph: "clock.badge.exclamationmark",
            headline: String(localized: "Reading was incomplete", bundle: LanguageManager.appBundle),
            message: String(localized: "Analysis based on partial data — try again for the full picture.", bundle: LanguageManager.appBundle),
            secondaryLabel: String(localized: "Try again", bundle: LanguageManager.appBundle)
        )
    }
    static func highArtifactRate(percent: Double) -> EmptyState {
        EmptyState(
            glyph: "waveform.badge.exclamationmark",
            headline: String(localized: "Signal quality was low", bundle: LanguageManager.appBundle),
            message: String(format: NSLocalizedString("%.1f%% artifacts. Consider re-reading.", bundle: LanguageManager.appBundle, comment: ""), percent)
        )
    }
}

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
