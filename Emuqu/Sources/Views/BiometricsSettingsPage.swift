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
        .onChange(of: isNumericFieldFocused) { _, focused in
            if !focused { dropValuesBelowMinimum() }
        }
        .onDisappear { dropValuesBelowMinimum() }
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
    // The lower bound is applied once editing ends (`dropValuesBelowMinimum`,
    // when focus leaves the number fields or the page closes): a value below
    // its minimum is cleared, so the formula default applies, which is what
    // the user wants if they stopped partway through typing.

    static let vo2MaxRange = 10.0 ... 100.0
    static let maxHRRange = 80 ... 230
    static let restingHRRange = 30 ... 110
    static let lthrRange = 80 ... 220
    static let ftpRange = 50 ... 600
    /// Body weight in kg. The field's own ceiling is in `bodyWeightDisplayBinding`.
    static let minimumBodyWeightKg = 30.0

    /// Clear every value below its field's minimum — a typo such as "4.5" for
    /// a VO2max of 45, or "5" W of FTP — instead of feeding it to the stress
    /// baseline, zones and calorie maths.
    func dropValuesBelowMinimum() {
        var s = settingsManager.settings
        s.vo2MaxOverride = s.vo2MaxOverride.flatMap { $0 >= Self.vo2MaxRange.lowerBound ? $0 : nil }
        s.maxHR = Self.atLeast(Self.maxHRRange.lowerBound, s.maxHR)
        s.userRestingHR = Self.atLeast(Self.restingHRRange.lowerBound, s.userRestingHR)
        s.lactateThresholdHR = Self.atLeast(Self.lthrRange.lowerBound, s.lactateThresholdHR)
        s.cyclingFTPWatts = Self.atLeast(Self.ftpRange.lowerBound, s.cyclingFTPWatts)
        s.runningFTPWatts = Self.atLeast(Self.ftpRange.lowerBound, s.runningFTPWatts)
        s.bodyWeightKg = s.bodyWeightKg.flatMap { $0 >= Self.minimumBodyWeightKg ? $0 : nil }
        guard s != settingsManager.settings else { return }
        settingsManager.settings = s
    }

    private static func atLeast(_ minimum: Int, _ value: Int?) -> Int? {
        value.flatMap { $0 >= minimum ? $0 : nil }
    }
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
            ? String(localized: "\(Int((kg * 2.20462).rounded())) lb", bundle: LanguageManager.appBundle)
            : String(localized: "\(Int(kg.rounded())) kg", bundle: LanguageManager.appBundle)
        return String(localized: "weight (\(display))", bundle: LanguageManager.appBundle)
    }

    private func fillBiologicalSex(from profile: HealthKitManager.BiometricProfile) -> String? {
        guard settingsManager.settings.biologicalSex == nil, let hkSex = profile.biologicalSex else { return nil }
        switch hkSex {
        case .female:
            settingsManager.settings.biologicalSex = .female
            return String(localized: "biological sex (female)", bundle: LanguageManager.appBundle)
        case .male:
            settingsManager.settings.biologicalSex = .male
            return String(localized: "biological sex (male)", bundle: LanguageManager.appBundle)
        case .other:
            settingsManager.settings.biologicalSex = .other
            return String(localized: "biological sex (other)", bundle: LanguageManager.appBundle)
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
        formatter.locale = LanguageManager.appLocale
        formatter.dateStyle = .medium
        return String(localized: "birthday (\(formatter.string(from: dob)))", bundle: LanguageManager.appBundle)
    }

    /// Current HR-zone mode. "Manual" when
    /// the user has overridden any of max-HR / resting-HR / LTHR;
    /// otherwise "Auto": max HR from age (Tanaka), resting HR from the
    /// measured baseline.
    var zonesModeLabel: String {
        let hasOverride = settingsManager.settings.maxHR != nil
            || settingsManager.settings.userRestingHR != nil
            || settingsManager.settings.lactateThresholdHR != nil
        return hasOverride
            ? String(localized: "Manual", bundle: LanguageManager.appBundle)
            : String(localized: "Auto", bundle: LanguageManager.appBundle)
    }

    var zonesModeFooter: String {
        let max = settingsManager.settings.effectiveMaxHR
        let rhr = settingsManager.settings.effectiveRestingHR
        let lthr = settingsManager.settings.effectiveLTHR
        return String(localized: "Effective: max \(max) bpm · resting \(rhr) bpm · LTHR \(lthr) bpm", bundle: LanguageManager.appBundle)
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
