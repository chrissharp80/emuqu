import SwiftUI

/// Build plan §4.1 O5 — Quick profile.
/// Three fields, all optional: Birthday / Biological sex / Body weight.
/// "Three things and we're done." — fitness level + VO2max removed; both
/// are derivable later from observed sessions and HealthKit if present.
struct OnboardingProfilePage: View {
    @Environment(SettingsManager.self) var settingsManager
    @FocusState private var isWeightFocused: Bool
    let advance: () -> Void

    var body: some View {
        ScrollView {
            stack
                .padding(.horizontal)
        }
        .safeAreaInset(edge: .bottom) { pinnedNavigationButtons }
        .scrollDismissesKeyboard(.interactively)
        .toolbar { keyboardDoneButton }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 20)

            profileHeaderCard

            birthdayCard

            biologicalSexCard

            bodyWeightCard
        }
        .padding(.bottom, 16)
    }

    /// Pinned above the page indicator. Scrolled with the content, Skip and
    /// Next fell off the bottom of a small screen once the birthday wheel took
    /// its space, and a tap where they used to be pages backwards instead.
    private var pinnedNavigationButtons: some View {
        VStack(spacing: 6) {
            incompleteProfileHint
            profileNavigationButtons
        }
        .padding(.horizontal)
        .padding(.bottom, 52)
        .background(AppTheme.background)
    }

    /// Next is disabled until the two fields it needs are filled. Saying so
    /// beats a greyed button the user has to guess about.
    @ViewBuilder
    private var incompleteProfileHint: some View {
        if !isProfileComplete {
            Text(String(localized: "Set your birthday and biological sex to continue, or tap Skip.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Header
    private var profileHeaderCard: some View {
        profilePageHeader
        .frame(maxWidth: .infinity)
    }

    /// Birthday
    private var birthdayCard: some View {
        birthdayField
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }

    /// Biological Sex
    private var biologicalSexCard: some View {
        biologicalSexField
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }

    /// Body weight (replaces VO2max + Fitness Level per build plan §4.1 O5).
    private var bodyWeightCard: some View {
        bodyWeightField
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }

    private var profilePageHeader: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.system(.largeTitle))
                .fontWeight(.bold)
                .minimumScaleFactor(0.5)
                .foregroundStyle(AppTheme.sage)
                .accessibilityHidden(true)

            Text(String(localized: "Quick profile", bundle: LanguageManager.appBundle))
                .font(.title2.bold())
                .foregroundColor(AppTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Text(String(localized: "Three things and we're done.", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    /// Wheel, not the compact calendar. The compact style opens on this month
    /// and pages back one month at a time; a tester born in 1964 had to tap
    /// through more than seven hundred months to reach it.
    private var birthdayField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Birthday", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textPrimary)
            birthdayWheel
            Text(String(localized: "HRV ranges adjust by age.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    private var birthdayWheel: some View {
        DatePicker(
            "Birthday",
            selection: birthdayBinding,
            in: ...Date(),
            displayedComponents: .date
        )
        .datePickerStyle(.wheel)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .accessibilityLabel(String(localized: "Birthday", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Used to calculate age-adjusted HRV baselines", bundle: LanguageManager.appBundle))
    }

    private var biologicalSexField: some View {
        VStack(alignment: .leading, spacing: 6) {
            biologicalSexPicker
            Text(String(localized: "Affects max-HR estimate.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    private var bodyWeightField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(localized: "Body weight", bundle: LanguageManager.appBundle))
                Spacer()
                TextField("Optional", value: weightBinding, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .focused($isWeightFocused)
                    .accessibilityLabel(String(localized: "Body weight", bundle: LanguageManager.appBundle))
                    .accessibilityHint(String(localized: "Used to estimate calories burned during workouts", bundle: LanguageManager.appBundle))
                Text(verbatim: weightUnitLabel)
                    .foregroundColor(AppTheme.textTertiary)
                    .font(.caption)
            }
            Text(String(localized: "Used for calorie estimation in workouts.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    /// BP §O5 line 485 — "all three required to continue."
    /// Next is disabled until birthday + biological sex +
    /// body weight all have non-default values. Skip remains
    /// available for users who genuinely want to bypass —
    /// the spec calls onboarding "skippable" overall (line
    /// 217 of the doc) but the per-page Next must validate.
    private var profileNavigationButtons: some View {
        HStack {
            Button(String(localized: "Skip", bundle: LanguageManager.appBundle)) { advance() }
                .buttonStyle(.zenSecondary)
                .accessibilityLabel(String(localized: "Skip", bundle: LanguageManager.appBundle))
                .accessibilityHint(String(localized: "Skip profile setup and continue to the next step", bundle: LanguageManager.appBundle))
                .accessibilityIdentifier("onboarding.skip")
            Spacer()
            Button(String(localized: "Next", bundle: LanguageManager.appBundle)) { advance() }
                .buttonStyle(.zen(AppTheme.sage))
                .disabled(!isProfileComplete)
                .accessibilityLabel(String(localized: "Next", bundle: LanguageManager.appBundle))
                .accessibilityIdentifier("onboarding.advance")
                .accessibilityHint(String(localized: "Save profile and continue to the next step", bundle: LanguageManager.appBundle))
        }
    }

    /// A menu picker drops its own label, so the row names itself the way
    /// the body-weight row does; the card read "Not Set" with nothing to say
    /// what was not set.
    private var biologicalSexPicker: some View {
        HStack {
            Text(String(localized: "Biological Sex", bundle: LanguageManager.appBundle))
            Spacer()
            Picker(String(localized: "Biological Sex", bundle: LanguageManager.appBundle), selection: biologicalSexBinding) {
                biologicalSexOptions
            }
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var biologicalSexOptions: some View {
        Text(String(localized: "Not Set", bundle: LanguageManager.appBundle)).tag(UserSettings.BiologicalSex?.none)
        ForEach(UserSettings.BiologicalSex.allCases) { sex in
            Text(sex.displayName).tag(Optional(sex))
        }
    }

    // MARK: - Bindings

    private var birthdayBinding: Binding<Date> {
        Binding(
            get: { settingsManager.settings.birthday ?? (Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()) },
            set: { settingsManager.settings.birthday = $0 }
        )
    }

    private var biologicalSexBinding: Binding<UserSettings.BiologicalSex?> {
        Binding(
            get: { settingsManager.settings.biologicalSex },
            set: { settingsManager.settings.biologicalSex = $0 }
        )
    }

    /// Stored kg. Onboarding always asks in kg; the dedicated Settings
    /// → Biometrics page later lets the user switch to lb if preferred.
    private var weightBinding: Binding<Double?> {
        Binding(
            get: { settingsManager.settings.bodyWeightKg },
            set: { settingsManager.settings.bodyWeightKg = $0 }
        )
    }

    private var weightUnitLabel: String { "kg" }

    /// BP §O5 line 485 — three required fields. Birthday must not be
    /// nil (the default value substituted in `birthdayBinding` is "30
    /// years ago" which is fine even when nil; we treat nil as
    /// not-yet-set). Sex must be selected (non-nil). Weight must be
    /// non-nil and > 0.
    private var isProfileComplete: Bool {
        let s = settingsManager.settings
        guard s.birthday != nil else { return false }
        guard s.biologicalSex != nil else { return false }
        guard let kg = s.bodyWeightKg, kg > 0 else { return false }
        return true
    }

    @ToolbarContentBuilder
    private var keyboardDoneButton: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) { isWeightFocused = false }
        }
    }
}

#Preview {
    OnboardingProfilePage(advance: {})
        .environment(AppDependencies.current.app.settingsManager)
}
