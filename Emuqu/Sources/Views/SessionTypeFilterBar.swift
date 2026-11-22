import SwiftUI

/// History's session-type chips: All / Extended / Naps / Quick / Breathe.
/// There is no Workouts chip: workouts live in the Fitness tab. "Extended"
/// is the spec's term for overnight. `selection` is the type History filters
/// to, nil for All; tapping a chip sets it.
struct SessionTypeFilterBar: View {
    @Binding var selection: SessionType?

    var body: some View {
        // A bare HStack forces all 5 chips to share
        // the screen width, so "Extended" wrapped to 3 lines while the
        // shorter labels stayed on one. Horizontal ScrollView lets each
        // chip size to its content (matches History's tag filter bar
        // just below it).
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(String(localized: "All", bundle: LanguageManager.appBundle), icon: "list.bullet", type: nil, color: AppTheme.primary)

                chip(String(localized: "Extended", bundle: LanguageManager.appBundle), icon: SessionType.overnight.icon, type: .overnight, color: AppTheme.primary)

                chip(String(localized: "Naps", bundle: LanguageManager.appBundle), icon: SessionType.nap.icon, type: .nap, color: AppTheme.mist)

                chip(String(localized: "Quick", bundle: LanguageManager.appBundle), icon: SessionType.quick.icon, type: .quick, color: AppTheme.sage)

                chip(String(localized: "Breathe", bundle: LanguageManager.appBundle), icon: SessionType.breathe.icon, type: .breathe, color: AppTheme.sdnnColor)
            }
            .padding(.vertical, 1) // prevents shadow-clipping at chip edges
        }
    }

    /// One chip: selected when `type` is the current selection (nil is All),
    /// and tapping it selects `type`.
    private func chip(_ title: String, icon: String, type: SessionType?, color: Color) -> some View {
        SessionTypeFilterButton(title: title, icon: icon, isSelected: selection == type, color: color) {
            selection = type
        }
    }
}

// MARK: - Session Type Filter Button

private struct SessionTypeFilterButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? color : color.opacity(0.15))
            .foregroundColor(isSelected ? .white : color)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "\(title) filter", bundle: LanguageManager.appBundle))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
