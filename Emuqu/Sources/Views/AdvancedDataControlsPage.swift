import SwiftUI

/// Settings → Privacy → Advanced Data Controls.
///
/// Shelter page for destructive operations — the "lock box" that sits
/// between the main Settings list and actions that permanently remove
/// user data. Drilling in is a deliberate two-tap minimum; confirming the
/// action inside requires typing a phrase, not just hitting OK.
///
/// The policy here isn't just paranoia: HRV history is multi-month data
/// that rebuilds slowly, and a one-tap-from-Settings flow with a single
/// `confirmationDialog` button makes it trivially easy to wipe it while
/// looking for something else in Privacy.
struct AdvancedDataControlsPage: View {
    var body: some View {
        List {
            permanentWarningSection
            deleteAllDataSection
        }
        .zenFormBackground()
        .navigationTitle(String(localized: "Advanced Data Controls", bundle: LanguageManager.appBundle))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var permanentWarningSection: some View {
        Section {
            Label {
                Text(String(localized: "Everything in this section is permanent.", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppTheme.alert)
            }
            Text(String(localized: "Actions here can't be undone from inside the app. Read the per-action page before tapping anything.", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        } header: {
            Text(String(localized: "Erase Data", bundle: LanguageManager.appBundle))
        }
    }

    private var deleteAllDataSection: some View {
        Section {
            deleteAllDataFields
        } header: {
            Text(String(localized: "Destructive", bundle: LanguageManager.appBundle))
        } footer: {
            deleteAllDataFooter
        }
    }

    @ViewBuilder
    private var deleteAllDataFields: some View {
        deleteAllDataButton
            // The destructive route is the one that most
            // needs a test that cannot drift. Its row label is title plus
            // subtitle joined, so an English label match never found it and
            // the deletion suite skipped instead of running.
            .accessibilityIdentifier("settings.deleteAllData")
    }

    private var deleteAllDataButton: some View {
        NavigationLink {
            DeleteAllDataPage()
        } label: {
            deleteAllMyDataSection
        }
    }

    private var deleteAllMyDataSection: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Delete All My Data", bundle: LanguageManager.appBundle))
                    .foregroundColor(AppTheme.alert)
                Text(String(localized: "Wipes local sessions, API keys, AI chats, memory facts.", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
        } icon: {
            Image(systemName: "trash")
                .foregroundStyle(AppTheme.alert)
        }
    }

    @ViewBuilder
    private var deleteAllDataFooter: some View {
        Text(String(localized: "The delete action requires you to type a confirmation phrase on the next screen, so a stray tap can't destroy your history.", bundle: LanguageManager.appBundle))
    }
}

#Preview {
    NavigationStack {
        AdvancedDataControlsPage()
    }
}

// MARK: - Performance & Battery

/// Master switches for everything other than the core HRV + Sleep loop.
/// User request from an iPhone-11 owner: cold start was unbearable
/// because every singleton (AI, voice, Watch, BLE, StoreKit) was being
/// initialized synchronously before first frame. These toggles let
/// older-device owners turn off whatever they don't use.
///
/// The toggles are stored in UserSettings (file-backed, App Group
/// container) and ALSO mirrored to UserDefaults on every save so the
/// heavy singletons can peek them at startup before SettingsManager
/// has finished reading its JSON file. See
/// `UserSettings.PerformanceFlagKey` for the mirror keys and
/// `UserSettings.performanceFlag(_:)` for the read helper.
struct PerformanceSettingsPage: View {
    @Environment(\.dependencies) var dependencies
    private var settingsManager: SettingsManager { dependencies.app.settingsManager }
    private var bundle: Bundle { LanguageManager.appBundle }

    var body: some View {
        Form {
            coldStartSection
            screenOnFields
            aiAssistantSection
            watchConnectivityFields
            icloudSyncSection
            restartNoticeSection
        }
        .zenFormBackground()
        .navigationTitle(String(localized: "Performance & Battery", bundle: LanguageManager.appBundle))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var coldStartSection: some View {
        Section {
            Text(String(localized: "Cold-start matters most on older iPhones (iPhone 11 and earlier). Turning OFF the features you don't use skips initializing the relevant subsystems at app launch.", bundle: bundle))
                .font(.footnote)
                .foregroundStyle(AppTheme.textSecondary)
            Text(String(localized: "HRV recording and sleep integration are always on — they're the core of the app and have no startup cost.", bundle: bundle))
                .font(.footnote)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var screenOnFields: some View {
        Section {
            Toggle(isOn: Bindable(settingsManager).settings.keepScreenOnDuringRecording) {
                screenOnToggleLabel
            }
        } header: {
            Text(String(localized: "Battery", bundle: bundle))
        }
    }

    private var screenOnToggleLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "Keep screen on during recording", bundle: bundle))
                .font(.body)
            Text(String(localized: "Default ON. The screen stays awake during overnight HRV recording, workouts, and Polar device downloads. Turn OFF to let iOS Auto-Lock kick in — saves battery on overnight sessions where the phone sits face-down and you're not watching the live HR display.", bundle: bundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var aiAssistantSection: some View {
        Section {
            aiAssistantFields
        } header: {
            Text(String(localized: "AI / Voice", bundle: bundle))
        } footer: {
            aiAssistantFooter
        }
    }

    @ViewBuilder
    private var aiAssistantFields: some View {
        Toggle(isOn: Bindable(settingsManager).settings.enableAIAssistant) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "AI Assistant", bundle: bundle))
                    .font(.body)
                Text(String(localized: "When OFF: the Assistant tab is hidden and the chat / Coach Report subsystems don't initialize. The medical-query guard still loads (tiny, no network).", bundle: bundle))
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        Toggle(isOn: Bindable(settingsManager).settings.enableVoiceMode) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Voice mode", bundle: bundle))
                    .font(.body)
                Text(String(localized: "When OFF: speech recognition + text-to-speech don't initialize at app launch. You can still text-chat with the AI if AI Assistant is on. Saves the AVAudioSession + SFSpeechRecognizer setup cost.", bundle: bundle))
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .disabled(!settingsManager.settings.enableAIAssistant)
    }

    @ViewBuilder
    private var aiAssistantFooter: some View {
        Text(String(localized: "Per-provider kill switches (OpenAI, Anthropic, Gemini, Grok, DeepSeek) live in Settings → AI Assistant.", bundle: bundle))
            .font(.footnote)
    }

    private var watchConnectivityFields: some View {
        Section {
            appleWatchConnectivitySection
        } header: {
            Text(String(localized: "Apple Watch", bundle: bundle))
        }
    }

    private var appleWatchConnectivitySection: some View {
        Toggle(isOn: Bindable(settingsManager).settings.enableWatchConnectivity) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Apple Watch connectivity", bundle: bundle))
                    .font(.body)
                Text(String(localized: "When OFF: WCSession isn't activated at launch. Useful if you don't use the Watch app — even when no Watch is paired, the activation roundtrip costs ~50–200 ms cold start.", bundle: bundle))
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private var icloudSyncSection: some View {
        Section {
            icloudSyncFields
        } header: {
            Text(String(localized: "Cloud + Training surfaces", bundle: bundle))
        }
    }

    @ViewBuilder
    private var icloudSyncFields: some View {
        icloudSyncToggleRow
        Toggle(isOn: Bindable(settingsManager).settings.enableTrainingLoadIntegration) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Training-load integration", bundle: bundle))
                    .font(.body)
                Text(String(localized: "ATL/CTL/TSB cards, Today's Loop verdict, training-readiness card. When OFF: dashboard skips all training surfaces (recovery + HRV-only flow).", bundle: bundle))
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        Toggle(isOn: Bindable(settingsManager).settings.hideFitnessTab) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Hide Fitness tab", bundle: bundle))
                    .font(.body)
                Text(String(localized: "Removes the workout-recording tab. Recovery-only users get a cleaner UI.", bundle: bundle))
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private var icloudSyncToggleRow: some View {
        Toggle(isOn: Bindable(settingsManager).settings.iCloudSyncEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "iCloud sync", bundle: bundle))
                    .font(.body)
                Text(String(localized: "Backs up sessions to your private iCloud container so they survive device changes. When OFF: no CloudKit network traffic, no sync banner, sessions stay device-local.", bundle: bundle))
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private var restartNoticeSection: some View {
        Section {
            Text(String(localized: "Changes take effect on next app launch for the AI / Voice / Apple Watch toggles (those gate singleton init at startup). Other toggles take effect immediately.", bundle: bundle))
                .font(.footnote)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }
}

#Preview {
    NavigationStack {
        PerformanceSettingsPage()
    }
}
