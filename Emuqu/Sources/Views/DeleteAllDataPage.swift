import SwiftUI

/// Settings → Privacy → Advanced Data Controls → "Delete All My Data".
///
/// Single user-discoverable action that fans out to every store the app
/// writes to. Required for GDPR Art. 17 / CCPA right-to-delete posture.
///
/// Deletes locally AND remotely (App Store): the purge
/// awaits `CloudKitSyncManager.deleteAllRemoteData()`, which removes the
/// app's CloudKit zones from the user's private iCloud database. If that
/// fails (offline, signed out of iCloud), the local wipe still proceeds
/// and the Result section tells the user to run the purge again with
/// connectivity. See `DataPurgeService` for the full fan-out.
///
/// Safety posture: the action is gated behind a type-to-confirm phrase
/// (the user must type `DELETE MY DATA`) followed by a final native
/// confirmation dialog. Two steps, both explicit, so nobody wipes a
/// year of HRV history by tapping once in the wrong place. The phrase
/// is intentionally not localised — the magic string should be the
/// same in every language so screenshots / support can reference one
/// canonical invocation.
struct DeleteAllDataPage: View {
    @Environment(RRCollector.self) var collector
    @Environment(SettingsManager.self) var settingsManager

    /// The verbatim phrase the user has to type. English + uppercase by
    /// design — any single-keystroke typo prevents the wipe.
    private static let confirmPhrase = "DELETE MY DATA"

    @State private var typedConfirmation: String = ""
    @State private var showingConfirmation = false
    @State private var report: DataPurgeService.Report?
    @State private var isPurging = false

    private var phraseMatches: Bool {
        typedConfirmation.trimmingCharacters(in: .whitespacesAndNewlines) == Self.confirmPhrase
    }

    @ViewBuilder
    private var confirmationActions: some View {
        Button(String(localized: "Delete All My Data", bundle: LanguageManager.appBundle), role: .destructive) { performPurge() }
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
    }

    var body: some View {
        sections
            .zenFormBackground()
            .navigationTitle(String(localized: "Delete All My Data", bundle: LanguageManager.appBundle))
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                String(localized: "Delete everything?", bundle: LanguageManager.appBundle),
                isPresented: $showingConfirmation,
                titleVisibility: .visible
            ) {
                confirmationActions
            } message: {
                Text(String(localized: "Last chance — this cannot be undone. The app will need to be restarted afterward.", bundle: LanguageManager.appBundle))
            }
    }

    private var sections: some View {
        List {
            warningSection
            whatGetsRemovedSection
            whatStaysSection
            confirmFieldSection
            deleteButtonSection
            purgingProgressSection
            resultSection
        }
    }

    private var warningSection: some View {
        Section {
            Text(String(localized: "This permanently removes everything Emuqu has stored on this device and in your iCloud.", bundle: LanguageManager.appBundle))
                .font(.subheadline)
        }
    }

    private var whatGetsRemovedSection: some View {
        Section(String(localized: "What gets removed", bundle: LanguageManager.appBundle)) {
            bullet(String(localized: "All recorded HRV sessions and their analysis results", bundle: LanguageManager.appBundle))
            bullet(String(localized: "iCloud copies of your data — synced sessions, in-progress recording backups, and the settings backup are deleted from your private iCloud database (requires an internet connection)", bundle: LanguageManager.appBundle))
            bullet(String(localized: "Raw RR backup files (the safety-net copies in the app's container)", bundle: LanguageManager.appBundle))
            bullet(String(localized: "Local iCloud sync state (uploaded-set, change tokens, pending queue)", bundle: LanguageManager.appBundle))
            bullet(String(localized: "All AI provider API keys stored in the iOS Keychain", bundle: LanguageManager.appBundle))
            bullet(String(localized: "AI conversation history", bundle: LanguageManager.appBundle))
            bullet(String(localized: "AI memory facts (\u{201C}Remember this\u{201D} entries)", bundle: LanguageManager.appBundle))
            bullet(String(localized: "Disclaimer-acceptance flag (you'll be re-prompted next launch)", bundle: LanguageManager.appBundle))
            bullet(String(localized: "Your settings and profile, which go back to their defaults", bundle: LanguageManager.appBundle))
        }
    }

    private var whatStaysSection: some View {
        Section {
            bullet(String(localized: "Health-app sleep / HRV samples that this app wrote to Apple Health — remove them in the Health app under Sources \u{2192} Emuqu.", bundle: LanguageManager.appBundle))
        } header: {
            Text(String(localized: "What is NOT removed automatically", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "If the iCloud deletion fails (no network, or not signed into iCloud), your local data is still removed — run Delete All My Data again once you're back online to clear the iCloud copies.", bundle: LanguageManager.appBundle))
        }
    }

    private var confirmFieldSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Type **\(Self.confirmPhrase)** below to unlock the delete button.", bundle: LanguageManager.appBundle))
                    .font(.subheadline)
                TextField(Self.confirmPhrase, text: $typedConfirmation)
                    // Stable handles on both halves of
                    // the destructive gate, so a test can assert the button
                    // stays disabled until the phrase matches without ever
                    // being at risk of tapping the wrong element.
                    .accessibilityIdentifier("deleteAllData.confirmField")
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .disabled(isPurging)
            }
        } header: {
            Text(String(localized: "Confirm intent", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "We ask for the phrase verbatim so a stray tap can't start a wipe. The button below stays disabled until it matches.", bundle: LanguageManager.appBundle))
        }
    }

    private var deleteButtonSection: some View {
        Section {
            Button(role: .destructive) {
                showingConfirmation = true
            } label: {
                deleteSectionLabel
            }
            .disabled(isPurging || !phraseMatches)
            .accessibilityIdentifier("deleteAllData.confirmButton")
        }
    }

    private var deleteSectionLabel: some View {
        HStack {
            Spacer()
            Text(String(localized: "Delete All My Data", bundle: LanguageManager.appBundle))
                .font(.body.weight(.semibold))
            Spacer()
        }
    }

    @ViewBuilder
    private var purgingProgressSection: some View {
        if isPurging {
            Section {
                purgingRow
            }
        }
    }

    private var purgingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(String(localized: "Deleting\u{2026} this includes removing your data from iCloud and can take a few seconds.", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let report {
            Section(String(localized: "Result", bundle: LanguageManager.appBundle)) {
                Text(report.summary)
                    .font(.caption.monospaced())
                    .foregroundColor(report.errors.isEmpty ? AppTheme.textSecondary : AppTheme.alert)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(String(localized: "\u{2022}", bundle: LanguageManager.appBundle))
            Text(text)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private func performPurge() {
        isPurging = true
        // Async: the purge now awaits the remote CloudKit zone deletion
        // (serialized behind any in-flight sync) before the local wipe.
        Task {
            let result = await DataPurgeService.purgeAllUserData(
                archive: collector.archive,
                rawBackup: collector.rawBackup,
                cloudSync: collector.cloudSyncManager,
                settingsManager: settingsManager
            )
            report = result
            isPurging = false
        }
    }
}

#Preview {
    NavigationStack {
        DeleteAllDataPage()
            .environment(AppDependencies.current.app.settingsManager)
            .environment(RRCollector())
    }
}
