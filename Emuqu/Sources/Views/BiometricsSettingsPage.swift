import HealthKit
import SwiftUI

// MARK: - Biometrics Settings Page
//
// Covers the biometric values the analysis engine depends on: VO2max, body
// weight, max HR, resting HR, and LTHR. Everything here accepts a manual
// override; the `effective*` properties on `UserSettings` fall back to
// age-adjusted / formula-based defaults when a field is left blank.
//
// Each numeric field is bounds-clamped so a typo like "2000 bpm" Max HR
// can't silently poison every downstream zone / TRIMP / HRR calculation.

struct BiometricsSettingsPage: View {
    @Environment(\.dependencies) var dependencies
    @Environment(SettingsManager.self) var settingsManager
    /// Two-way access to the settings for controls. An `@Environment` value has
    /// no projected `$` binding, so this stands in for `$settingsManager.settings`.
    var settingsBinding: Binding<UserSettings> {
        Binding(get: { settingsManager.settings }, set: { settingsManager.settings = $0 })
    }
    @Environment(LanguageManager.self) var languageManager
    @FocusState var isNumericFieldFocused: Bool

    /// "Fill from Apple Health" button state.
    @State var isFillingFromHealthKit = false
    @State var fillFeedback: String?

    var body: some View {
        ZStack {
            keyboardDismissOverlay
            biometricsForm
        }
        .navigationTitle(String(localized: "Biometrics", bundle: LanguageManager.appBundle))
    }

    /// A transparent tap target above the form that dismisses the number pad.
    @ViewBuilder
    private var keyboardDismissOverlay: some View {
        if isNumericFieldFocused {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { isNumericFieldFocused = false }
                .zIndex(1)
        }
    }

    // MARK: - Bounds-clamping helpers
    //
    // TextFields backed by `UserSettings` values still need bounds-checking —
    // a typo like "2000 bpm" Max HR silently poisons every downstream zone /
    // TRIMP / HRR calculation. The clamp ONLY applies to the upper bound on
    // every keystroke, NOT the lower bound. Why: clamping the lower bound
    // mid-typing rewrites the user's input ("1" intended for "180" gets
    // clamped to 80, then "18" stays at 80, then "180" finally lands but the
    // field looks broken in the meantime — user complaint: "the
    // fields aren't taking the right numbers from the keyboard").
    //
    // The lower bound is enforced by `effective*` computed defaults in
    // `UserSettings` — a stored value below the minimum yields the same
    // result downstream as `nil` (the formula default), which is what the
    // user wants if they're partway through typing.
    func clampedIntBinding(
        _ keyPath: WritableKeyPath<UserSettings, Int?>,
        range: ClosedRange<Int>
    ) -> Binding<Int?> {
        Binding(
            get: { settingsManager.settings[keyPath: keyPath] },
            set: { newValue in
                guard let v = newValue else {
                    settingsManager.settings[keyPath: keyPath] = nil
                    return
                }
                // Only clamp the UPPER bound on each keystroke. Lower
                // bound is informational — see comment above.
                settingsManager.settings[keyPath: keyPath] = min(v, range.upperBound)
            }
        )
    }

    func clampedDoubleBinding(
        _ keyPath: WritableKeyPath<UserSettings, Double?>,
        range: ClosedRange<Double>
    ) -> Binding<Double?> {
        Binding(
            get: { settingsManager.settings[keyPath: keyPath] },
            set: { newValue in
                guard let v = newValue else {
                    settingsManager.settings[keyPath: keyPath] = nil
                    return
                }
                settingsManager.settings[keyPath: keyPath] = min(v, range.upperBound)
            }
        )
    }

    /// Pulls body mass, biological sex, and date of birth from Apple
    /// Health and writes them into UserSettings ONLY where the user
    /// hasn't already set an explicit value. Idempotent: rerunning is
    /// safe and won't clobber overrides. Permission-denied reads come
    /// back as nil and don't fail the whole operation — partial fills
    /// are honest about what landed.
    ///
    /// Authorization is request-once-per-app; the existing app-level request
    /// covers these types, so this never re-prompts.
    func fillFromAppleHealth() async {
        isFillingFromHealthKit = true
        defer { isFillingFromHealthKit = false }
        let profile = await dependencies.collection.healthKitManager.fetchBiometricProfile()
        let filled = [
            fillBodyWeight(from: profile),
            fillBiologicalSex(from: profile),
            fillBirthday(from: profile)
        ].compactMap { $0 }
        fillFeedback = filled.isEmpty
            ? String(localized: "Nothing to fill — Apple Health had nothing new.", bundle: LanguageManager.appBundle)
            : String(localized: "Filled: \(filled.joined(separator: ", ")).", bundle: LanguageManager.appBundle)
    }

    /// Only if the user hasn't entered one.
    private func fillBodyWeight(from profile: HealthKitManager.BiometricProfile) -> String? {
        guard let kg = profile.bodyWeightKg, settingsManager.settings.bodyWeightKg == nil else { return nil }
        settingsManager.settings.bodyWeightKg = kg
        let display = UnitsPreferenceStore.current.resolved == .imperial
            ? String(format: "%.0f lb", locale: .current, kg * 2.20462)
            : String(format: "%.0f kg", locale: .current, kg)
        return "weight (\(display))"
    }

    private func fillBiologicalSex(from profile: HealthKitManager.BiometricProfile) -> String? {
        guard settingsManager.settings.biologicalSex == nil, let hkSex = profile.biologicalSex else { return nil }
        switch hkSex {
        case .female:
            settingsManager.settings.biologicalSex = .female
            return "biological sex (female)"
        case .male:
            settingsManager.settings.biologicalSex = .male
            return "biological sex (male)"
        case .other:
            settingsManager.settings.biologicalSex = .other
            return "biological sex (other)"
        case .notSet:
            return nil
        @unknown default:
            return nil
        }
    }

    private func fillBirthday(from profile: HealthKitManager.BiometricProfile) -> String? {
        guard settingsManager.settings.birthday == nil, let dob = profile.dateOfBirth else { return nil }
        settingsManager.settings.birthday = dob
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return "birthday (\(formatter.string(from: dob)))"
    }

    /// Build plan §M3.3 line 1217 — current HR-zone mode. "Manual" when
    /// the user has overridden any of max-HR / resting-HR / LTHR;
    /// otherwise "Auto" derived from age + RHR + observed max.
    var zonesModeLabel: String {
        let hasOverride = settingsManager.settings.maxHR != nil
            || settingsManager.settings.userRestingHR != nil
            || settingsManager.settings.lactateThresholdHR != nil
        return hasOverride ? "Manual" : "Auto"
    }

    var zonesModeFooter: String {
        let max = settingsManager.settings.effectiveMaxHR
        let rhr = settingsManager.settings.effectiveRestingHR
        let lthr = settingsManager.settings.effectiveLTHR
        return "Effective: max \(max) bpm · resting \(rhr) bpm · LTHR \(lthr) bpm"
    }

    /// Body-weight binding that round-trips through pounds when the user's
    /// units preference resolves to imperial, and through kilograms
    /// otherwise. Storage stays kg-canonical so calorie math (which
    /// always uses kg) doesn't have to branch — only the input field
    /// shape varies. Upper-bound clamp is generous (250 kg / 550 lb) so
    /// "still typing" intermediate values don't get clobbered.
    func bodyWeightDisplayBinding(isImperial: Bool) -> Binding<Double?> {
        Binding(
            get: {
                guard let kg = settingsManager.settings.bodyWeightKg else { return nil }
                return isImperial ? kg * 2.20462 : kg
            },
            set: { newValue in
                guard let v = newValue else {
                    settingsManager.settings.bodyWeightKg = nil
                    return
                }
                let kg = isImperial ? v / 2.20462 : v
                // Same upper-bound-only-on-keystroke philosophy as the
                // Int helpers: clamp the upper sanity ceiling so a typo
                // can't poison calorie math, but never the lower bound
                // (which would rewrite the user's input mid-typing).
                settingsManager.settings.bodyWeightKg = min(kg, 250.0)
            }
        )
    }
}
