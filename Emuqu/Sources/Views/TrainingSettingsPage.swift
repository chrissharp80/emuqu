import SwiftUI

// MARK: - Training Settings Page
//
// Controls whether training load feeds into recovery scoring and lets the
// user schedule a break (illness, surgery, vacation) that hides load
// metrics without affecting the underlying calculations.

struct TrainingSettingsPage: View {
    @Environment(SettingsManager.self) var settingsManager
    /// Two-way access to the settings for controls. An `@Environment` value has
    /// no projected `$` binding, so this stands in for `$settingsManager.settings`.
    private var settingsBinding: Binding<UserSettings> {
        Binding(get: { settingsManager.settings }, set: { settingsManager.settings = $0 })
    }
    @Environment(LanguageManager.self) private var languageManager

    var body: some View {
        Form {
            goalSection
            trainingLoadSection
            hideFitnessTabSection
        }
        .zenFormBackground()
        .navigationTitle(String(localized: "Training", bundle: LanguageManager.appBundle))
    }

    /// Build plan §4.6 M3.3 + §D8 — Goal picker. Single training-
    /// config knob.
    private var goalSection: some View {
        Section {
            goalFields
        } header: {
            Text("Goal", bundle: LanguageManager.appBundle)
        } footer: {
            goalFooter
        }
    }

    @ViewBuilder
    private var goalFields: some View {
        Picker(
            String(localized: "Goal", bundle: LanguageManager.appBundle),
            selection: settingsBinding.trainingGoal
        ) {
            ForEach(TrainingGoal.allCases) { goal in
                Text(goal.displayName).tag(goal)
            }
        }
        Text(verbatim: settingsManager.settings.trainingGoal.blurb)
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)
    }

    @ViewBuilder
    private var goalFooter: some View {
        Text("Maintain / Build / Peak. Affects Coach voice and Trajectory ramp-rate language. Does not change the recovery score.", bundle: LanguageManager.appBundle)
    }

    private var trainingLoadSection: some View {
        Section {
            trainingLoadFields
        } header: {
            Text("Training Load", bundle: LanguageManager.appBundle)
        } footer: {
            trainingLoadFooter
        }
    }

    @ViewBuilder
    private var trainingLoadFields: some View {
        Toggle(
            String(localized: "Training Load", bundle: LanguageManager.appBundle),
            isOn: settingsBinding.enableTrainingLoadIntegration
        )
        .accessibilityHint(Text("Include ATL / CTL / TSB in your recovery score.", bundle: LanguageManager.appBundle))

        trainingLoadDetailFields
    }

    @ViewBuilder
    private var trainingLoadDetailFields: some View {
        if settingsManager.settings.enableTrainingLoadIntegration {
            trainingBreakFields
        }
    }

    @ViewBuilder
    private var trainingBreakFields: some View {
        if settingsManager.settings.trainingBreakStartDate != nil {
            onBreakCard
        } else {
            startBreakButton
                .foregroundColor(.orange)
        }
    }

    private var startBreakButton: some View {
        Button {
            settingsManager.settings.trainingBreakStartDate = Date()
            settingsManager.settings.trainingBreakEndDate = Calendar.current.date(byAdding: .day, value: 7, to: Date())
        } label: {
            Label(
                String(localized: "Schedule Training Break", bundle: LanguageManager.appBundle),
                systemImage: "bed.double"
            )
        }
    }

    private var onBreakCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            breakHeaderRow

            breakStartPicker
            breakEndPicker
            breakReasonField
            clearBreakButton
        }
    }

    private var breakHeaderRow: some View {
        HStack {
            Image(systemName: "bed.double.fill")
                .foregroundColor(.orange)
                .accessibilityHidden(true)
            Text(
                settingsManager.settings.isOnTrainingBreak
                    ? String(localized: "On Break", bundle: LanguageManager.appBundle)
                    : String(localized: "Break Scheduled", bundle: LanguageManager.appBundle)
            )
            .foregroundColor(.orange)
            .fontWeight(.medium)
        }
    }

    private var breakStartPicker: some View {
        DatePicker(
            String(localized: "From", bundle: LanguageManager.appBundle),
            selection: Binding(
                get: { settingsManager.settings.trainingBreakStartDate ?? Date() },
                set: { settingsManager.settings.trainingBreakStartDate = $0 }
            ),
            displayedComponents: .date
        )
        .font(.subheadline)
        .accessibilityLabel(Text("Training break start date", bundle: LanguageManager.appBundle))
    }

    private var breakEndPicker: some View {
        DatePicker(
            String(localized: "Until", bundle: LanguageManager.appBundle),
            selection: Binding(
                get: { settingsManager.settings.trainingBreakEndDate ?? (Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()) },
                set: { settingsManager.settings.trainingBreakEndDate = $0 }
            ),
            displayedComponents: .date
        )
        .font(.subheadline)
        .accessibilityLabel(Text("Training break end date", bundle: LanguageManager.appBundle))
    }

    private var breakReasonField: some View {
        TextField(
            String(localized: "Reason (optional)", bundle: LanguageManager.appBundle),
            text: Binding(
                get: { settingsManager.settings.trainingBreakReason ?? "" },
                set: { settingsManager.settings.trainingBreakReason = $0.isEmpty ? nil : $0 }
            )
        )
        .font(.subheadline)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel(Text("Reason for training break", bundle: LanguageManager.appBundle))
    }

    private var clearBreakButton: some View {
        Button(String(localized: "Clear Break", bundle: LanguageManager.appBundle)) {
            settingsManager.settings.trainingBreakStartDate = nil
            settingsManager.settings.trainingBreakEndDate = nil
            settingsManager.settings.trainingBreakReason = nil
        }
        .foregroundColor(.red)
        .font(.subheadline)
    }

    @ViewBuilder
    private var trainingLoadFooter: some View {
        Text("Training breaks hide load metrics during time off (sick, surgery, vacation). Doesn't affect calculations.", bundle: LanguageManager.appBundle)
    }

    /// Hide-Fitness-tab lives here, not in a top-level "Tabs"
    /// section or inside Appearance. It's a
    /// workout-related preference — recovery-only / HRV-only
    /// users who don't record workouts can declutter the tab
    /// bar without hunting through Appearance.
    private var hideFitnessTabSection: some View {
        Section {
            hideFitnessTabFields
        } header: {
            Text("Fitness Tab", bundle: LanguageManager.appBundle)
        } footer: {
            hideFitnessTabFooter
        }
    }

    @ViewBuilder
    private var hideFitnessTabFields: some View {
        Toggle(isOn: settingsBinding.hideFitnessTab) {
            VStack(alignment: .leading, spacing: 2) {
                // Build plan §4.6 M3.3 — Comeback mode lives in the Modes
                // sub-screen, not here, per the spec's "single source of
                // truth for modes" rule (a duplicate here would mirror a
                // setting also defined in ModesSettingsPage and lead to
                // two UIs writing the same `comebackModeStartDate` field).
                Text("Hide Fitness tab", bundle: LanguageManager.appBundle)
                    .font(.body)
                Text(settingsManager.settings.hideFitnessTab
                    ? String(localized: "Workout recording is removed from the tab bar. Settings is promoted in.", bundle: LanguageManager.appBundle)
                    : String(localized: "Hide if you only use Emuqu for HRV / overnight recovery and don't record workouts.", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var hideFitnessTabFooter: some View {
        Text("The AI assistant is told which surfaces are off so it won't recommend features you've removed.", bundle: LanguageManager.appBundle)
    }
}
