import SwiftUI

/// Build plan §3.12 — standard nav bar pattern. Most v2 screens just use
/// SwiftUI's stock `.navigationTitle` + `.toolbar`, but a few surfaces
/// want a heavier custom header (with score colour, share button, and a
/// subtle subtitle). This component standardises that.
///
/// **Bug to avoid (per the plan):** never render the parent's nav bar
/// inside the child. If you use NavigationHeader on a screen that's
/// pushed inside a NavigationStack, hide the system nav bar with
/// `.toolbar(.hidden, for: .navigationBar)`.
struct NavigationHeader: View {
    let title: String
    var subtitle: String?
    var leadingGlyph: String?
    /// VoiceOver label for the icon-only leading button.
    /// Without it the button reads as just its SF Symbol name.
    var leadingLabel: String?
    var leadingAction: (() -> Void)?
    var trailingGlyph: String?
    /// VoiceOver label for the icon-only trailing button.
    var trailingLabel: String?
    var trailingAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            glyphButton(leadingGlyph, action: leadingAction, label: leadingLabel)
            titleStack
            Spacer()
            glyphButton(trailingGlyph, action: trailingAction, label: trailingLabel)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// 44pt min tap target, contentShape so the whole
    /// frame is tappable.
    @ViewBuilder
    private func glyphButton(_ glyph: String?, action: (() -> Void)?, label: String?) -> some View {
        if let glyph, let action {
            Button(action: action) {
                Image(systemName: glyph)
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(AppTheme.primary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(OptionalA11yLabel(label: label))
        }
    }

    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .scaledFont(size: 28, weight: .bold)
                .foregroundStyle(AppTheme.textPrimary)
            if let subtitle {
                Text(verbatim: subtitle)
                    .scaledFont(size: 13)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }
}

/// Applies an `.accessibilityLabel` only when a non-nil
/// label is supplied, so an absent label leaves the element's default
/// VoiceOver behaviour untouched rather than blanking it.
private struct OptionalA11yLabel: ViewModifier {
    let label: String?
    func body(content: Content) -> some View {
        if let label {
            content.accessibilityLabel(Text(label))
        } else {
            content
        }
    }
}

// MARK: - Localized duration

/// Locale-aware "1h 23m" / "45 min" formatting for the
/// view layer. The shared `DurationFormatter` in Utilities hardcodes
/// English "h"/"m"/"min"; that file is owned elsewhere, so the View
/// surfaces route through `DateComponentsFormatter`, which renders the
/// unit abbreviations in the user's language automatically.
enum LocalizedDuration {
    /// "1h 23m" (or "23m"), rounded to whole minutes. Falls back to the
    /// non-localized form only if the formatter returns nil.
    static func hoursMinutes(minutes: Int) -> String {
        let secs = TimeInterval(max(0, minutes) * 60)
        let f = hoursMinutesFormatter
        return f.string(from: secs) ?? DurationFormatter.hoursMinutes(minutes: minutes)
    }

    /// "45 min" — minutes only, spelled with a localized abbreviation.
    static func minutes(_ minutes: Int) -> String {
        let secs = TimeInterval(max(0, minutes) * 60)
        let f = minutesOnlyFormatter
        return f.string(from: secs) ?? "\(max(0, minutes)) min"
    }

    private static let hoursMinutesFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .abbreviated // "1h 23m" — units localized by the OS
        f.zeroFormattingBehavior = .dropLeading
        return f
    }()

    private static let minutesOnlyFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.minute]
        f.unitsStyle = .abbreviated // "45 min"
        return f
    }()
}
