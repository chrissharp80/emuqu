import SwiftUI

/// Settings sub-screen for the three training modes:
///   • Comeback mode (21 days; the recovery score weights HRV more heavily)
///   • Peaking detection (auto-detect taper, suppress detraining copy)
///   • Intentional overreach (user-toggled until its end date, suppresses
///     rapid-increase copy; the score is unchanged)
struct ModesSettingsPage: View {
    @Environment(\.dependencies) var dependencies
    @Bindable var settingsManager: SettingsManager = AppDependencies.current.app.settingsManager

    var body: some View {
        Form {
            comebackModeSection
            autoDetectPeakingSection
            intentionalOverreachSection
        }
        .navigationTitle(Text(String(localized: "Modes", bundle: LanguageManager.appBundle)))
        .scrollContentBackground(.hidden)
        .background(AppTheme.background.ignoresSafeArea())
    }

    private var comebackModeSection: some View {
        Section {
            comebackToggle
        } header: {
            Text(String(localized: "Comeback mode", bundle: LanguageManager.appBundle))
        } footer: {
            comebackModeFooter
        }
    }

    @ViewBuilder
    private var comebackModeFooter: some View {
        // Localizable prose, not Text(verbatim:).
        Text(String(
            localized: "Use this when returning from illness, injury, or a long break. For 21 days, your recovery score weights HRV more heavily and ignores noisy vitals so a slow autonomic comeback isn't double-penalised.",
            bundle: LanguageManager.appBundle
        ))
    }

    private var autoDetectPeakingSection: some View {
        Section {
            autoDetectPeakingFields
        } header: {
            Text(String(localized: "Peaking detection", bundle: LanguageManager.appBundle))
        } footer: {
            autoDetectPeakingFooter
        }
    }

    @ViewBuilder
    private var autoDetectPeakingFields: some View {
        Toggle(isOn: $settingsManager.settings.peakingDetectionEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Auto-detect peaking", bundle: LanguageManager.appBundle))
                Text(settingsManager.settings.peakingDetectionEnabled
                    ? String(localized: "On (auto)", bundle: LanguageManager.appBundle)
                    : String(localized: "Off", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var autoDetectPeakingFooter: some View {
        // Localizable prose, not Text(verbatim:).
        Text(String(localized: "When ATL drops below CTL by 10% for 4+ days, Emuqu recognises you're tapering and labels it 'Peaking' on the Trajectory screen. This suppresses 'detraining' messaging. Turn off if you'd rather always see the raw curves.", bundle: LanguageManager.appBundle))
    }

    private var intentionalOverreachSection: some View {
        Section {
            intentionalOverreachFields
        } header: {
            Text(String(localized: "Intentional overreach", bundle: LanguageManager.appBundle))
        } footer: {
            intentionalOverreachFooter
        }
    }

    @ViewBuilder
    private var intentionalOverreachFields: some View {
        overreachToggle
        if overreachInEffect {
            overreachEndDateRow
        }
    }

    @ViewBuilder
    private var intentionalOverreachFooter: some View {
        // Localizable prose, not Text(verbatim:).
        Text(String(
            localized: "Use this when you're deliberately doing a hard training block (camp, race build, peak overload week). Suppresses 'rapid increase' and 'high load' messaging. Metrics still display. Recovery Score is unchanged — only the surrounding copy.",
            bundle: LanguageManager.appBundle
        ))
    }

    // MARK: - Comeback

    private var comebackToggle: some View {
        let active = settingsManager.settings.isComebackModeActive
        let bind = Binding<Bool>(
            get: { active },
            set: { TrainingModeSwitches.setComeback($0, settings: settingsManager, telemetry: dependencies.services.validationTelemetry) }
        )
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: bind) {
                comebackToggleLabel
            }
        }
    }

    private var comebackToggleLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "Comeback mode", bundle: LanguageManager.appBundle))
            Text(comebackStatusText)
                .font(.caption)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private var comebackStatusText: String {
        guard let start = settingsManager.settings.comebackModeStartDate,
              settingsManager.settings.isComebackModeActive else {
            return String(localized: "Off", bundle: LanguageManager.appBundle)
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startDay = calendar.startOfDay(for: start)
        let daysSince = calendar.dateComponents([.day], from: startDay, to: today).day ?? 0
        let remaining = max(0, 21 - daysSince)
        return String(localized: "Active. \(remaining) days remaining.", bundle: LanguageManager.appBundle)
    }

    // MARK: - Overreach

    private var overreachToggle: some View {
        Toggle(isOn: Binding(
            get: { overreachInEffect },
            set: { setOverreach($0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Intentional overreach", bundle: LanguageManager.appBundle))
                Text(overreachStatusText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    /// The mode counts as on only until the start of its end date.
    private var overreachInEffect: Bool {
        settingsManager.settings.isIntentionalOverreachInEffect
    }

    private func setOverreach(_ on: Bool) {
        TrainingModeSwitches.setOverreach(on, settings: settingsManager, telemetry: dependencies.services.validationTelemetry)
    }

    /// Tomorrow: an end date of today would switch the mode off at once.
    private static var earliestOverreachEnd: Date {
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
    }

    private var overreachStatusText: String {
        guard overreachInEffect else { return String(localized: "Off", bundle: LanguageManager.appBundle) }
        if let end = settingsManager.settings.intentionalOverreachEndDate {
            let date = end.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(LanguageManager.appLocale))
            return String(localized: "Active until \(date).", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Active. Tap below to set an end date.", bundle: LanguageManager.appBundle)
    }

    /// With no end date saved (a block switched on open-ended before both
    /// switches shared `TrainingModeSwitches`), the row is a button that
    /// saves the default end date, not a picker showing a date that is not
    /// saved; the caption above asks for exactly that tap.
    @ViewBuilder
    private var overreachEndDateRow: some View {
        if let end = settingsManager.settings.intentionalOverreachEndDate {
            overreachEndDatePicker(end)
        } else {
            Button(String(localized: "Auto-deactivate on", bundle: LanguageManager.appBundle)) {
                settingsManager.settings.intentionalOverreachEndDate = TrainingModeSwitches.defaultOverreachEnd
            }
        }
    }

    private func overreachEndDatePicker(_ end: Date) -> some View {
        let bind = Binding<Date>(
            get: { end },
            set: { settingsManager.settings.intentionalOverreachEndDate = Calendar.current.startOfDay(for: $0) }
        )
        return DatePicker(
            String(localized: "Auto-deactivate on", bundle: LanguageManager.appBundle),
            selection: bind,
            in: Self.earliestOverreachEnd...,
            displayedComponents: .date
        )
    }
}

/// The Comeback and Intentional overreach switches, one implementation for
/// Settings → Modes and the Load & Trajectory screen, so a mode behaves the
/// same whichever screen turned it on: overreach always gets an end date a
/// week out (it never stays on open-ended), and every switch-on is counted
/// in the mode-activation telemetry.
@MainActor
enum TrainingModeSwitches {
    static func setComeback(_ on: Bool, settings: SettingsManager, telemetry: ValidationTelemetry) {
        settings.settings.comebackModeStartDate = on ? Date() : nil
        if on { telemetry.recordModeActivation(.comeback) }
    }

    /// On saves the default end date (a week from today); off clears it.
    static func setOverreach(_ on: Bool, settings: SettingsManager, telemetry: ValidationTelemetry) {
        settings.settings.intentionalOverreachActive = on
        guard on else {
            settings.settings.intentionalOverreachEndDate = nil
            return
        }
        settings.settings.intentionalOverreachEndDate = defaultOverreachEnd
        telemetry.recordModeActivation(.intentionalOverreach)
    }

    static var defaultOverreachEnd: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: 7, to: today) ?? today.addingTimeInterval(7 * 24 * 3600)
    }
}
