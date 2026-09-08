import SwiftUI

// The filter card — activity, radius, length, ascent, difficulty — split out
// of `DiscoverTrailsView.swift` to keep that type's body under the
// 500-line limit. The members stay private to
// the type via this extension.

extension DiscoverTrailsView {
    var filtersCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            activityPicker
            searchRadiusFilter
            lengthRangeFilter
            elevationGainFilter
            difficultyFilter
        }
        .padding(14)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
    /// Elevation gain range. Applied to BOTH tabs.
    /// Saved-routes filter is exact (we computed ascent at save
    /// time). Discover-tab filter is best-effort: the Overpass
    /// response doesn't carry elevation natively, so we filter
    /// the post-fetch list by length only and surface a footer
    /// note that ascent filtering for discovered trails kicks
    /// in once the user picks one (we do a TopoElevationService
    /// lookup on bind).
    var elevationGainFilter: some View {
        elevationGainStack
    }
    var elevationGainStack: some View {
        VStack(alignment: .leading, spacing: 4) {
            filterHeader(String(localized: "Ascent", bundle: LanguageManager.appBundle), value: ascentRangeLabel)
            HStack(spacing: 8) {
                Slider(value: $minAscentMeters, in: 0 ... 1_500, step: 50)
                    .tint(AppTheme.terracotta)
            }
            HStack(spacing: 8) {
                Slider(value: $maxAscentMeters, in: 100 ... 2_000, step: 50)
                    .tint(AppTheme.terracotta)
            }
            ascentFilterCaveat
        }
    }
    func filterHeader(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textPrimary)
        }
    }
    @ViewBuilder
    var ascentFilterCaveat: some View {
        if tab == .findNew {
            Text(String(localized: "Note: ascent filter applies to saved routes only — OSM doesn't include elevation per-trail. Discover-tab results filter by length above.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    /// Difficulty filter (discover only — saved routes don't carry
    /// a formal difficulty rating; their ascent + length are the
    /// proxy). Two-bucket inclusive selector.
    @ViewBuilder
    var difficultyFilter: some View {
        if tab == .findNew {
            difficultyStack
        }
    }
    var difficultyStack: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Difficulty", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)
            difficultyChips
            Text(String(localized: "Unrated trails (no sac_scale / mtb:scale tag) are included regardless of these filters — most OSM ways don't carry a difficulty rating.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    var activitySegments: some View {
        Picker(String(localized: "Activity", bundle: LanguageManager.appBundle), selection: $filters.activity) {
            ForEach(TrailDiscoveryService.Activity.allCases) { a in
                Text(a.displayName).tag(a)
            }
        }
        .pickerStyle(.segmented)
    }
    var difficultyChips: some View {
        HStack(spacing: 6) {
            ForEach([TrailDiscoveryService.Difficulty.easy,
                     .moderate, .hard, .expert], id: \.self) { difficultyChip($0) }
        }
    }
    /// Activity picker
    var activityPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Activity", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)
            activitySegments
        }
    }
    /// Search radius — discover-only (saved routes are already
    /// local). Hidden in the saved tab to keep the filter card
    /// focused on what actually filters the visible list.
    @ViewBuilder
    var searchRadiusFilter: some View {
        if tab == .findNew {
            searchRadiusStack
        }
    }
    var searchRadiusStack: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(localized: "Within", bundle: LanguageManager.appBundle))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Text(unitsAreImperial
                    ? String(format: "%.0f mi", locale: .current, radiusKm * 0.6214)
                    : String(format: "%.0f km", locale: .current, radiusKm))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            Slider(value: $radiusKm, in: 2 ... 50, step: 1)
                .tint(AppTheme.terracotta)
        }
    }
    /// Length range — applies to both tabs. Stepper-driven for
    /// precision (slider was finicky for users wanting "8 to 12 km").
    var lengthRangeFilter: some View {
        lengthRangeStack
    }
    var lengthRangeStack: some View {
        VStack(alignment: .leading, spacing: 4) {
            filterHeader(String(localized: "Length", bundle: LanguageManager.appBundle), value: lengthRangeLabel)
            lengthSteppers
        }
    }
    /// Show the length in the user's units. The stored value stays
    /// in km (the search filter is metric); only the displayed number/label
    /// converts. `%@` keeps the placeholder localizable.
    var lengthSteppers: some View {
        HStack(spacing: 8) {
            Stepper(value: $minLengthKm, in: 0 ... 100, step: 1) {
                Text(String(localized: "Min: \(stepperLengthLabel(minLengthKm))", bundle: LanguageManager.appBundle))
                    .font(.caption2)
            }
            Stepper(value: $maxLengthKm, in: 1 ... 100, step: 1) {
                Text(String(localized: "Max: \(stepperLengthLabel(maxLengthKm))", bundle: LanguageManager.appBundle))
                    .font(.caption2)
            }
        }
    }
    @ViewBuilder
    func difficultyChip(_ d: TrailDiscoveryService.Difficulty) -> some View {
        Button {
            cycleDifficulty(d)
        } label: {
            difficultyChipLabel(d)
        }
        .buttonStyle(.plain)
    }
    func difficultyChipLabel(_ d: TrailDiscoveryService.Difficulty) -> some View {
        let isInRange = (filters.minDifficulty.map { $0 <= d } ?? true)
            && (filters.maxDifficulty.map { d <= $0 } ?? true)
        let active = isInRange && filters.minDifficulty != nil
        let color = Self.difficultyColor(d)
        return Text(d.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(active ? color.opacity(0.25) : AppTheme.background.opacity(0.5))
            .foregroundStyle(active ? color : AppTheme.textSecondary)
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(active ? color.opacity(0.6) : .clear, lineWidth: 1)
            )
    }
}
