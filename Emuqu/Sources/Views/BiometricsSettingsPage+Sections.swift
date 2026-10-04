import SwiftUI

// MARK: - Biometrics form sections
//
// Nine `Section` blocks, each its own property named for the MARK
// comment that labels it, with each section's fields, input row and
// footer separate so nothing here runs past twenty lines — rather than one
// 350-line `body` nested six deep.
//
// They live in this file because the split pushed the struct itself past
// SwiftLint's 500-line `type_body_length` — the same reason
// `RecordView+Sections.swift` exists. Every member is a computed property on
// `BiometricsSettingsPage` itself, so the form and its focus state are exactly
// what they were inline.

extension BiometricsSettingsPage {
    // MARK: - Form
    //
    // Each section is its own property, named for the MARK
    // comment that labels it. Computed properties on the same struct,
    // so the form and its focus state behave as if inline.

    var biometricsForm: some View {
        Form {
            appleHealthFillSection
            vo2maxSection
            bodyWeightSection
            homeAddressSection
            hrZonesModeSection
            maxHRSection
            restingHRSection
            lthrSection
            functionalThresholdPowerSection
        }
        .scrollDismissesKeyboard(.immediately)
        .zenFormBackground()
        .toolbar { dismissKeyboardToolbar }
    }

    var dismissKeyboardToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) {
                isNumericFieldFocused = false
            }
        }
    }

    /// Fill from Apple Health
    /// Pulls body weight, biological sex, and birthday from
    /// Apple Health when available, ONLY into fields that
    /// haven't been set manually. Doesn't overwrite anything
    /// the user has already entered. Reads are permission-
    /// scoped — denied reads silently return nil and the
    /// remaining fields still fill.
    var appleHealthFillSection: some View {
        Section {
            fillFromAppleHealthButton
            fillFeedbackText
        } footer: {
            Text("Pulls body weight, biological sex, and birthday from Apple Health. Only fills fields you haven't set manually — your overrides are never overwritten.", bundle: LanguageManager.appBundle)
        }
    }

    var fillFromAppleHealthButton: some View {
        Button {
            Task { await fillFromAppleHealth() }
        } label: {
            fillFromAppleHealthLabel
        }
        .disabled(isFillingFromHealthKit)
    }

    @ViewBuilder
    var fillFeedbackText: some View {
        if let feedback = fillFeedback {
            Text(feedback)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    var fillFromAppleHealthLabel: some View {
        HStack {
            if isFillingFromHealthKit {
                ProgressView().padding(.trailing, 4)
            } else {
                Image(systemName: "heart.text.square.fill")
                    .foregroundStyle(.pink)
            }
            Text("Fill from Apple Health", bundle: LanguageManager.appBundle)
                .fontWeight(.medium)
            Spacer()
        }
    }

    /// VO2max
    var vo2maxSection: some View {
        Section {
            vo2maxFields
        } header: {
            Text("Cardio Fitness", bundle: LanguageManager.appBundle)
        } footer: {
            vo2maxFooter
        }
    }

    @ViewBuilder
    var vo2maxFields: some View {
        Toggle(
            String(localized: "Apple Health VO2max", bundle: LanguageManager.appBundle),
            isOn: settingsBinding.useHealthKitVO2Max
        )
        .accessibilityHint(Text("Use Apple Health's estimated VO2max when no override is set.", bundle: LanguageManager.appBundle))

        vo2maxOverrideRow

        if settingsManager.settings.vo2MaxOverride != nil {
            Button(String(localized: "Clear Override", bundle: LanguageManager.appBundle)) {
                settingsManager.settings.vo2MaxOverride = nil
            }
            .foregroundColor(.red)
        }
    }

    var vo2maxOverrideRow: some View {
        HStack {
            Text("VO2max Override", bundle: LanguageManager.appBundle)
            Spacer()
            TextField(
                "",
                value: clampedDoubleBinding(\.vo2MaxOverride, range: Self.vo2MaxRange),
                format: .number
            )
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .frame(width: 60)
            .focused($isNumericFieldFocused)
            .accessibilityLabel(Text("VO2 max override", bundle: LanguageManager.appBundle))
            .accessibilityHint(Text("Millilitres per kilogram per minute, between 10 and 100", bundle: LanguageManager.appBundle))
            Text(String(localized: "ml/kg/min", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    var vo2maxFooter: some View {
        Text("VO2max personalizes your age-adjusted HRV ranges. Override if you have a lab-tested value.", bundle: LanguageManager.appBundle)
    }

    /// Body weight — calorie estimation
    /// Storage is always kg (formula uses kg and switching units
    /// shouldn't migrate stored values), but the input field
    /// displays + accepts lb when the user's units preference
    /// resolves to imperial. `bodyWeightDisplayBinding` does
    /// the conversion both ways so the user sees their familiar
    /// unit and the database stays kg-canonical.
    var bodyWeightSection: some View {
        Section {
            bodyWeightFields
        } header: {
            Text("Body Weight", bundle: LanguageManager.appBundle)
        } footer: {
            bodyWeightFooter
        }
    }

    @ViewBuilder
    var bodyWeightFields: some View {
        bodyWeightRow

        if settingsManager.settings.bodyWeightKg != nil {
            Button(String(localized: "Clear", bundle: LanguageManager.appBundle)) {
                settingsManager.settings.bodyWeightKg = nil
            }
            .foregroundColor(.red)
        }
    }

    /// Storage is always kg; the field displays and accepts lb when the units
    /// preference resolves to imperial. `bodyWeightDisplayBinding` converts both
    /// ways so the user sees a familiar unit and the database stays kg-canonical.
    var bodyWeightRow: some View {
        let isImperial = UnitsPreferenceStore.current.resolved == .imperial
        return HStack {
            Text("Body Weight", bundle: LanguageManager.appBundle)
            Spacer()
            TextField(
                isImperial
                    ? "\(Int((settingsManager.settings.effectiveBodyWeightKg * 2.20462).rounded()))"
                    : "\(Int(settingsManager.settings.effectiveBodyWeightKg))",
                value: bodyWeightDisplayBinding(isImperial: isImperial),
                format: .number
            )
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .frame(width: 70)
            .focused($isNumericFieldFocused)
            .accessibilityLabel(Text(isImperial ? "Body weight in pounds" : "Body weight in kilograms", bundle: LanguageManager.appBundle))
            Text(isImperial ? "lb" : "kg", bundle: LanguageManager.appBundle)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    var bodyWeightFooter: some View {
        let kg = settingsManager.settings.effectiveBodyWeightKg
        let lb = kg * 2.20462
        let source = settingsManager.settings.bodyWeightKg != nil
            ? String(localized: "your value", bundle: LanguageManager.appBundle)
            : String(localized: "75 kg default", bundle: LanguageManager.appBundle)
        Text("Used for calorie estimation via the Compendium of Physical Activities formula (METs × 3.5 × kg × min / 200). Current: \(Int(kg)) kg / \(Int(lb.rounded())) lb (\(source)).", bundle: LanguageManager.appBundle)
    }

    /// Home address — used by AI's "lead me home" routing
    /// Free-text address. Apple's CLGeocoder
    /// accepts loose phrasings ("123 Main St Springfield",
    /// "the house at the end of Pine Lane"). Stored only on
    /// device + iCloud sync (same as every other UserSettings
    /// field). Empty string == unset; the AI tool returns
    /// notRecorded with a hint until the user fills this in.
    var homeAddressSection: some View {
        Section {
            homeAddressFields
        } header: {
            Text("Home Address", bundle: LanguageManager.appBundle)
        } footer: {
            homeAddressFooter
        }
    }

    @ViewBuilder
    var homeAddressFields: some View {
        TextField(
            String(localized: "e.g. 123 Main St, Springfield IL", bundle: LanguageManager.appBundle),
            text: Binding(
                get: { settingsManager.settings.homeAddress ?? "" },
                set: { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    settingsManager.settings.homeAddress = trimmed.isEmpty ? nil : newValue
                }
            )
        )
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled()
        .accessibilityLabel(Text("Home address", bundle: LanguageManager.appBundle))

        if settingsManager.settings.homeAddress != nil {
            Button(String(localized: "Clear", bundle: LanguageManager.appBundle)) {
                settingsManager.settings.homeAddress = nil
            }
            .foregroundColor(.red)
        }
    }

    @ViewBuilder
    var homeAddressFooter: some View {
        Text("Used when you ask the AI to 'lead me home' or 'route me back home'. Stored only on this device (and your iCloud, if sync is on). Apple's geocoder is forgiving — full street address, neighborhood + city, or even a landmark name will all work.", bundle: LanguageManager.appBundle)
    }

    /// HR Zones mode (Auto / Manual):
    /// Auto: max HR from age (Tanaka), resting HR from the recordings'
    /// baseline. Manual: any of the values below overridden by hand.
    var hrZonesModeSection: some View {
        Section {
            HStack {
                Text(String(localized: "Mode", bundle: LanguageManager.appBundle))
                Spacer()
                Text(verbatim: zonesModeLabel)
                    .foregroundStyle(AppTheme.textSecondary)
                    .font(.subheadline)
            }
            Text(verbatim: zonesModeFooter)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        } header: {
            Text("HR Zones", bundle: LanguageManager.appBundle)
        } footer: {
            Text("Auto: max HR from your age, resting HR from your recordings. Manual: edit any value below — the override sticks until you clear it.", bundle: LanguageManager.appBundle)
        }
    }

    /// Max HR — workout zones + voice coach
    var maxHRSection: some View {
        Section {
            maxHRFields
        } header: {
            Text("Workout HR Zones", bundle: LanguageManager.appBundle)
        } footer: {
            maxHRFooter
        }
    }

    @ViewBuilder
    var maxHRFields: some View {
        maxHRRow

        if settingsManager.settings.maxHR != nil {
            Button(String(localized: "Use Age-Based Default", bundle: LanguageManager.appBundle)) {
                settingsManager.settings.maxHR = nil
            }
            .foregroundColor(.red)
        }
    }

    var maxHRRow: some View {
        HStack {
            // MARK: Max HR — workout zones + voice coach
            Text("Max Heart Rate", bundle: LanguageManager.appBundle)
            Spacer()
            TextField(
                "\(settingsManager.settings.effectiveMaxHR)",
                value: clampedIntBinding(\.maxHR, range: Self.maxHRRange),
                format: .number
            )
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .frame(width: 60)
            .focused($isNumericFieldFocused)
            .accessibilityLabel(Text("Maximum heart rate", bundle: LanguageManager.appBundle))
            .accessibilityHint(Text("Beats per minute, between 80 and 230", bundle: LanguageManager.appBundle))
            Text(String(localized: "bpm", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    var maxHRFooter: some View {
        let eff = settingsManager.settings.effectiveMaxHR
        let src: String = {
            if settingsManager.settings.maxHR != nil {
                return String(localized: "your override", bundle: LanguageManager.appBundle)
            }
            if settingsManager.settings.birthday != nil {
                return String(localized: "208 − 0.7 × age", bundle: LanguageManager.appBundle)
            }
            return String(localized: "default (no age set)", bundle: LanguageManager.appBundle)
        }()
        Text("Used for workout zones and the voice coach. Current effective max: \(eff) bpm (\(src)). Set your actual max if you know it — otherwise 208 − 0.7 × age is a rough estimate.", bundle: LanguageManager.appBundle)
    }

    /// Resting HR — Karvonen / HRR denominator
    var restingHRSection: some View {
        Section {
            restingHRFields
        } header: {
            Text("Resting Heart Rate", bundle: LanguageManager.appBundle)
        } footer: {
            restingHRFooter
        }
    }

    @ViewBuilder
    var restingHRFields: some View {
        restingHRRow

        if settingsManager.settings.userRestingHR != nil {
            Button(String(localized: "Use Auto-Tracked Baseline", bundle: LanguageManager.appBundle)) {
                settingsManager.settings.userRestingHR = nil
            }
            .foregroundColor(.red)
        }
    }

    var restingHRRow: some View {
        HStack {
            Text("Resting Heart Rate", bundle: LanguageManager.appBundle)
            Spacer()
            TextField(
                // MARK: Resting HR — Karvonen / HRR denominator
                "\(settingsManager.settings.effectiveRestingHR)",
                value: clampedIntBinding(\.userRestingHR, range: Self.restingHRRange),
                format: .number
            )
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .frame(width: 60)
            .focused($isNumericFieldFocused)
            .accessibilityLabel(Text("Resting heart rate", bundle: LanguageManager.appBundle))
            .accessibilityHint(Text("Beats per minute, between 30 and 110", bundle: LanguageManager.appBundle))
            Text(String(localized: "bpm", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    var restingHRFooter: some View {
        let eff = settingsManager.settings.effectiveRestingHR
        let src: String = {
            if settingsManager.settings.userRestingHR != nil {
                return String(localized: "your override", bundle: LanguageManager.appBundle)
            }
            if settingsManager.settings.baselineHR != nil {
                return String(localized: "HRV-derived baseline", bundle: LanguageManager.appBundle)
            }
            return String(localized: "60 bpm default", bundle: LanguageManager.appBundle)
        }()
        Text("Feeds TRIMP and heart-rate-reserve load math. Workout zones are a share of max HR and don't use it. Current effective resting: \(eff) bpm (\(src)). A lab or watch nightly-low value is typically more accurate than the HRV-derived baseline.", bundle: LanguageManager.appBundle)
    }

    /// LTHR — Banister TRIMP + hrTSS anchor
    var lthrSection: some View {
        Section {
            lthrFields
        } header: {
            Text("Lactate Threshold HR", bundle: LanguageManager.appBundle)
        } footer: {
            lthrFooter
        }
    }

    @ViewBuilder
    var lthrFields: some View {
        lthrRow

        if settingsManager.settings.lactateThresholdHR != nil {
            Button(String(localized: "Use 0.88 × Max Default", bundle: LanguageManager.appBundle)) {
                settingsManager.settings.lactateThresholdHR = nil
            }
            .foregroundColor(.red)
        }
    }

    var lthrRow: some View {
        HStack {
            Text("Lactate Threshold HR", bundle: LanguageManager.appBundle)
            Spacer()
            TextField(
                // MARK: LTHR — Banister TRIMP + hrTSS anchor
                "\(settingsManager.settings.effectiveLTHR)",
                value: clampedIntBinding(\.lactateThresholdHR, range: Self.lthrRange),
                format: .number
            )
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .frame(width: 60)
            .focused($isNumericFieldFocused)
            .accessibilityLabel(Text("Lactate threshold heart rate", bundle: LanguageManager.appBundle))
            .accessibilityHint(Text("Beats per minute, between 80 and 220", bundle: LanguageManager.appBundle))
            Text(String(localized: "bpm", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    var lthrFooter: some View {
        let eff = settingsManager.settings.effectiveLTHR
        let src: String = settingsManager.settings.lactateThresholdHR != nil
            ? String(localized: "your override", bundle: LanguageManager.appBundle)
            : String(localized: "0.88 × max HR", bundle: LanguageManager.appBundle)
        Text("Normalizes Banister TRIMP and hrTSS. Current effective LTHR: \(eff) bpm (\(src)). Friel test: 30-min solo time trial; mean HR over the final 20 min = LTHR. The Fitness tab also surfaces an α1-derived AeT after aerobic workouts as a rough field proxy.", bundle: LanguageManager.appBundle)
    }

    var functionalThresholdPowerSection: some View {
        Section {
            functionalThresholdPowerFields
        } header: {
            Text(String(localized: "Functional Threshold Power", bundle: LanguageManager.appBundle))
        } footer: {
            functionalThresholdPowerFooter
        }
    }

    @ViewBuilder
    var functionalThresholdPowerFields: some View {
        functionalThresholdPowerRow
        HStack {
            Text("Cycling FTP", bundle: LanguageManager.appBundle)
            Spacer()
            TextField(
                "—",
                value: clampedIntBinding(\.cyclingFTPWatts, range: Self.ftpRange),
                format: .number
            )
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .frame(width: 60)
            .focused($isNumericFieldFocused)
            .accessibilityLabel(Text("Cycling FTP in watts", bundle: LanguageManager.appBundle))
            Text(String(localized: "W", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    var functionalThresholdPowerRow: some View {
        HStack {
            Text("Running FTP", bundle: LanguageManager.appBundle)
            Spacer()
            TextField(
                "—",
                value: clampedIntBinding(\.runningFTPWatts, range: Self.ftpRange),
                format: .number
            )
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .frame(width: 60)
            .focused($isNumericFieldFocused)
            .accessibilityLabel(Text("Running FTP in watts", bundle: LanguageManager.appBundle))
            Text(String(localized: "W", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    var functionalThresholdPowerFooter: some View {
        Text(String(localized: "Anchors power-TSS, intensity factor, and power zones for sessions where a power meter is connected (Stryd for run, CPS/FTMS for bike). Field test: 20-min all-out time trial → take 95 % of average power. Running FTP is typically 5–15 % higher than cycling FTP for the same person, so set them separately. When unset, normalized power is still recorded; only the FTP-anchored derivations stay blank.", bundle: LanguageManager.appBundle))
    }
}
