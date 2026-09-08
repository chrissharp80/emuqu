import SwiftUI

// The custom-tags and iCloud/data settings pages, split out of
// `SettingsPages+Diagnostics.swift`. Troubleshooting stays behind;
// these two are about what the app stores, not how it reports faults.

// MARK: - Custom Tags Page

struct CustomTagsPage: View {
    @Environment(SettingsManager.self) var settingsManager
    @Environment(LanguageManager.self) private var languageManager
    @State private var showingAddTag = false
    @State private var newTagName = ""
    @State private var newTagColor = Color.blue

    var body: some View {
        Form {
            tagsSection
        }
        .zenFormBackground()
        .navigationTitle(String(localized: "Custom Tags", bundle: LanguageManager.appBundle))
        .sheet(isPresented: $showingAddTag) { addTagSheet }
    }

    private var tagsSection: some View {
        Section {
            ForEach(settingsManager.settings.customTags) { tag in
                tagRow(tag)
            }
            .onDelete { offsets in
                deleteTags(at: offsets)
            }

            addCustomTagButton
        } footer: {
            Text("Tag your readings to track patterns (alcohol, travel, illness, etc.). Swipe to delete.", bundle: LanguageManager.appBundle)
        }
    }

    private func tagRow(_ tag: ReadingTag) -> some View {
        HStack {
            Circle()
                .fill(tag.color)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(tag.name)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Tag: \(tag.name)", bundle: LanguageManager.appBundle))
    }

    private func deleteTags(at offsets: IndexSet) {
        for index in offsets {
            settingsManager.removeCustomTag(settingsManager.settings.customTags[index])
        }
    }

    private var addTagSheet: some View {
        AddTagSheet(
            tagName: $newTagName,
            tagColor: $newTagColor,
            onSave: { saveNewTag() }
        )
    }

    private func saveNewTag() {
        let tag = ReadingTag(name: newTagName, colorHex: newTagColor.hexString)
        settingsManager.addCustomTag(tag)
        newTagName = ""
        newTagColor = .blue
    }

    private var addCustomTagButton: some View {
        Button {
            showingAddTag = true
        } label: {
            Label(
                String(localized: "Add Custom Tag", bundle: LanguageManager.appBundle),
                systemImage: "plus"
            )
        }
    }
}

// MARK: - iCloud & Data Page

struct DataSettingsPage: View {
    @Environment(\.dependencies) var dependencies
    @Environment(SettingsManager.self) var settingsManager
    /// Two-way access to the settings for controls. An `@Environment` value has
    /// no projected `$` binding, so this stands in for `$settingsManager.settings`.
    private var settingsBinding: Binding<UserSettings> {
        Binding(get: { settingsManager.settings }, set: { settingsManager.settings = $0 })
    }
    @Environment(RRCollector.self) var collector
    @Environment(ArchiveSignal.self) var archiveSignal
    @Environment(CloudKitSyncManager.self) var syncManager
    @Environment(LanguageManager.self) private var languageManager
    @State private var showingRecoveryAlert = false
    @State private var recoveryMessage = ""
    @State private var isRecovering = false
    @State private var deletedSessionCount: Int = -1
    @State private var isForceSyncing = false
    @State private var showingForceSyncAlert = false
    @State private var forceSyncMessage = ""
    // Settings backup + restore via CloudKit. Surfaces here
    // so a user whose local settings file got wiped (the "fucked up my
    // settings again" data-loss bug) can pull the cloud copy back in
    // one tap without re-entering everything.
    @State private var isBackingUpSettings = false
    @State private var isRestoringSettings = false
    @State private var showingSettingsRestoreConfirm = false
    @State private var showingSettingsBackupAlert = false
    @State private var settingsBackupMessage = ""

    /// User-initiated "Force iCloud Sync" — triggers a full push + pull
    /// and reports success/error. Different from the automatic sync that
    /// runs on launch: this one gives explicit feedback so users stop
    /// wondering whether the last sync actually went through.
    private func forceCloudKitSync() {
        guard !isForceSyncing else { return }
        isForceSyncing = true
        let before = syncManager.uploadedCount
        Task {
            await syncManager.performFullSync()
            await MainActor.run {
                isForceSyncing = false
                forceSyncMessage = forceSyncSummary(newlyUploaded: syncManager.uploadedCount - before)
                showingForceSyncAlert = true
            }
        }
    }

    @MainActor
    private func forceSyncSummary(newlyUploaded delta: Int) -> String {
        if case let .error(msg) = syncManager.syncState {
            return "Sync failed: \(msg). Try again in a moment."
        }
        if delta > 0 {
            return String(localized: "Synced \(delta) sessions to iCloud. \(syncManager.uploadedCount) total uploaded.", bundle: LanguageManager.appBundle)
        }
        if syncManager.pendingUploadCount > 0 {
            return String(localized: "\(syncManager.pendingUploadCount) sessions still pending retry. iCloud may be unreachable.", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Up to date. \(syncManager.uploadedCount) sessions in iCloud.", bundle: LanguageManager.appBundle)
    }

    var body: some View {
        Form {
            statusSection
            importSection
            sessionStorageSection
            icloudSyncSection
            settingsBackupSection
        }
        .zenFormBackground()
        .navigationTitle(String(localized: "iCloud & Data", bundle: LanguageManager.appBundle))
        .onAppear { refreshDeletedCount() }
        .onChange(of: archiveSignal.version) { _, _ in refreshDeletedCount() }
        .alert(Text("RR Data Recovery", bundle: LanguageManager.appBundle), isPresented: $showingRecoveryAlert) {
            Button(String(localized: "OK", bundle: LanguageManager.appBundle)) {}
        } message: {
            Text(recoveryMessage)
        }
    }

    private var statusSection: some View {
        Section {
            Toggle(String(localized: "iCloud Sync", bundle: LanguageManager.appBundle),
                   isOn: settingsBinding.iCloudSyncEnabled)
                .accessibilityHint(Text("Back up and sync recordings across your devices via iCloud.", bundle: LanguageManager.appBundle))

            iCloudSyncDetail
        } footer: {
            Text("Syncs sessions to iCloud using your Apple ID. No account needed.", bundle: LanguageManager.appBundle)
        }
    }

    @ViewBuilder
    private var iCloudSyncDetail: some View {
        if settingsManager.settings.iCloudSyncEnabled {
            syncStatusRow
            syncLastSyncRow
        }
    }

    private var syncStatusRow: some View {
        HStack {
            Text("Status", bundle: LanguageManager.appBundle)
            Spacer()
            syncStateLabel
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var syncStateLabel: some View {
        switch syncManager.syncState {
        case .idle:
            Text("Up to date", bundle: LanguageManager.appBundle).foregroundColor(AppTheme.textSecondary)
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.8)
                Text("Syncing…", bundle: LanguageManager.appBundle).foregroundColor(AppTheme.textSecondary)
            }
        case let .error(message):
            Text(message).foregroundColor(AppTheme.alert).font(.caption)
        }
    }

    @ViewBuilder
    private var syncLastSyncRow: some View {
        if let lastSync = syncManager.lastSyncDate {
            HStack {
                Text("Last Sync", bundle: LanguageManager.appBundle)
                Spacer()
                Text(lastSync, style: .relative).foregroundColor(AppTheme.textSecondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var importSection: some View {
        Section {
            importDataLink
            exportDataLink
            recoverRRDataButton
        } header: {
            Text("Import & Export", bundle: LanguageManager.appBundle)
        }
    }

    private var importDataLink: some View {
        NavigationLink {
            ImportDataView()
        } label: {
            importDataLabel
        }
    }

    private var importDataLabel: some View {
        Label(String(localized: "Import RR Data", bundle: LanguageManager.appBundle),
              systemImage: "square.and.arrow.down")
    }

    private var exportDataLink: some View {
        NavigationLink {
            ExportDataView()
        } label: {
            exportDataLabel
        }
    }

    private var exportDataLabel: some View {
        Label(String(localized: "Export Data", bundle: LanguageManager.appBundle),
              systemImage: "square.and.arrow.up")
    }

    private var recoverRRDataButton: some View {
        Button {
            recoverRRData()
        } label: {
            recoverRRDataLabel
        }
        .disabled(isRecovering || collector.polarManager.connectionState != .connected)
        .accessibilityHint(Text("Re-download the most recent recording from the connected Polar strap.", bundle: LanguageManager.appBundle))
    }

    private var recoverRRDataLabel: some View {
        HStack {
            Label(String(localized: "Recover RR from Strap", bundle: LanguageManager.appBundle),
                  systemImage: "arrow.clockwise.heart")
            Spacer()
            if isRecovering {
                ProgressView().scaleEffect(0.8)
            } else if collector.polarManager.connectionState != .connected {
                Text("Connect strap first", bundle: LanguageManager.appBundle)
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
    }

    // MARK: - Session Storage & Recovery
    //
    // One glance answers "where is my data?" — archive count,
    // iCloud sync state, unarchived raw backups, and all recovery
    // actions in one place.
    private var sessionStorageSection: some View {
        Section {
            archiveCountRow
            uploadedCountRow
            pendingUploadRow
            unarchivedBackupRow
            syncLastSyncRow
        } header: {
            Text("Storage Summary", bundle: LanguageManager.appBundle)
        } footer: {
            Text("Archive is your on-device session store. iCloud sync is automatic but best-effort — use Force Sync below if something looks stuck.", bundle: LanguageManager.appBundle)
                .font(.caption2)
        }
    }

    private var archiveCountRow: some View {
        HStack {
            Label(String(localized: "Archived sessions", bundle: LanguageManager.appBundle),
                  systemImage: "externaldrive.fill")
            Spacer()
            Text("\(collector.archive.entries.count)")
                .foregroundColor(AppTheme.textSecondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text("\(collector.archive.entries.count) sessions", bundle: LanguageManager.appBundle))
    }

    private var uploadedCountRow: some View {
        HStack {
            Label(String(localized: "iCloud uploaded", bundle: LanguageManager.appBundle),
                  systemImage: "icloud.fill")
            Spacer()
            Text("\(syncManager.uploadedCount)")
                .foregroundColor(AppTheme.textSecondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text("\(syncManager.uploadedCount) sessions uploaded", bundle: LanguageManager.appBundle))
    }

    @ViewBuilder
    private var pendingUploadRow: some View {
        if syncManager.pendingUploadCount > 0 {
            HStack {
                Label(String(localized: "Pending iCloud retry", bundle: LanguageManager.appBundle),
                      systemImage: "icloud.and.arrow.up")
                    .foregroundColor(AppTheme.softGold)
                Spacer()
                Text("\(syncManager.pendingUploadCount)")
                    .foregroundColor(AppTheme.softGold)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var unarchivedBackupRow: some View {
        let unarchivedCount = collector.rawBackup.unarchivedBackupCount
        if unarchivedCount > 0 {
            HStack {
                Label(String(localized: "Unarchived recordings", bundle: LanguageManager.appBundle),
                      systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundColor(AppTheme.terracotta)
                Spacer()
                Text("\(unarchivedCount)")
                    .foregroundColor(AppTheme.terracotta)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var lastSyncRow: some View {
        if let last = syncManager.lastSyncDate {
            HStack {
                Label(String(localized: "Last iCloud sync", bundle: LanguageManager.appBundle),
                      systemImage: "clock")
                Spacer()
                Text(last, style: .relative)
                    .foregroundColor(AppTheme.textSecondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var icloudSyncSection: some View {
        Section {
            forceSyncButton
            sessionRecoveryLink
            trashLink
        } header: {
            Text("Recovery Actions", bundle: LanguageManager.appBundle)
        }
        .alert(Text("iCloud Sync", bundle: LanguageManager.appBundle), isPresented: $showingForceSyncAlert) {
            Button(String(localized: "OK", bundle: LanguageManager.appBundle)) {}
        } message: {
            Text(forceSyncMessage)
        }
    }

    private var forceSyncButton: some View {
        Button { forceCloudKitSync() } label: {
            forceSyncLabel
        }
        .disabled(isForceSyncing || !syncManager.isCloudKitAvailable)
    }

    private var forceSyncLabel: some View {
        HStack {
            Label(String(localized: "Force iCloud Sync", bundle: LanguageManager.appBundle),
                  systemImage: "arrow.triangle.2.circlepath.icloud")
            Spacer()
            if isForceSyncing {
                ProgressView().scaleEffect(0.8)
            }
        }
    }

    private var sessionRecoveryLink: some View {
        NavigationLink {
            LostSessionsView()
        } label: {
            sessionRecoveryLabel
        }
    }

    private var sessionRecoveryLabel: some View {
        HStack {
            Label(String(localized: "Recover Lost Sessions", bundle: LanguageManager.appBundle),
                  systemImage: "arrow.counterclockwise.circle")
            Spacer()
            if collector.rawBackup.unarchivedBackupCount > 0 {
                Text("\(collector.rawBackup.unarchivedBackupCount)")
                    .foregroundColor(AppTheme.terracotta)
                    .font(.caption.weight(.semibold))
                    .accessibilityLabel(Text("\(collector.rawBackup.unarchivedBackupCount) lost sessions available", bundle: LanguageManager.appBundle))
            }
        }
    }

    private var trashLink: some View {
        NavigationLink {
            TrashView()
        } label: {
            trashLabel
        }
    }

    private var trashLabel: some View {
        HStack {
            Label(String(localized: "Trash", bundle: LanguageManager.appBundle),
                  systemImage: "trash")
            Spacer()
            if deletedSessionCount > 0 {
                Text("\(deletedSessionCount)")
                    .foregroundColor(AppTheme.textSecondary)
                    .accessibilityLabel(Text("\(deletedSessionCount) deleted sessions", bundle: LanguageManager.appBundle))
            }
        }
    }

    // Settings backup — separate from the session-archive sync
    // above. Exists because a crash on a Watch-triggered
    // background launch can wipe the user's local settings file
    // (max HR, weight, FTP, biometrics, sleep schedule, email
    // contacts, AI provider — every preference), leaving them to
    // re-input everything. The local-side guard
    // (`SettingsManager.LoadOutcome` guard + relaxed file
    // protection) prevents the loss; this backup is the second
    // leg so even if a future bug slips through, recovery is
    // one tap.
    private var settingsBackupSection: some View {
        Section {
            backUpSettingsButton
            restoreSettingsButton
        } header: {
            Text("Settings Backup", bundle: LanguageManager.appBundle)
        } footer: {
            Text("Your settings (Max HR, biometrics, AI provider, units, sleep schedule, etc.) push to your private iCloud automatically on every change. Use these buttons if you need to force a backup or recover after a wipe.", bundle: LanguageManager.appBundle)
                .font(.caption2)
        }
        .confirmationDialog(
            Text("Restore from iCloud?", bundle: LanguageManager.appBundle),
            isPresented: $showingSettingsRestoreConfirm,
            titleVisibility: .visible
        ) { restoreDialogActions } message: { restoreDialogMessage }
        .alert(
            Text("Settings Backup", bundle: LanguageManager.appBundle),
            isPresented: $showingSettingsBackupAlert
        ) { okButton } message: { Text(settingsBackupMessage) }
    }

    private var okButton: some View {
        Button(String(localized: "OK", bundle: LanguageManager.appBundle)) {}
    }

    private var backUpSettingsButton: some View {
        Button { backupSettingsNow() } label: {
            backUpSettingsLabel
        }
        .disabled(isBackingUpSettings || !settingsManager.settings.iCloudSyncEnabled)
    }

    private var backUpSettingsLabel: some View {
        HStack {
            Label(String(localized: "Back Up Settings to iCloud", bundle: LanguageManager.appBundle),
                  systemImage: "icloud.and.arrow.up")
            Spacer()
            if isBackingUpSettings {
                ProgressView().scaleEffect(0.8)
            }
        }
    }

    private var restoreSettingsButton: some View {
        Button {
            showingSettingsRestoreConfirm = true
        } label: {
            restoreSettingsLabel
        }
        .disabled(isRestoringSettings || !settingsManager.settings.iCloudSyncEnabled)
    }

    private var restoreSettingsLabel: some View {
        HStack {
            Label(String(localized: "Restore Settings from iCloud", bundle: LanguageManager.appBundle),
                  systemImage: "icloud.and.arrow.down")
            Spacer()
            if isRestoringSettings {
                ProgressView().scaleEffect(0.8)
            }
        }
    }

    @ViewBuilder
    private var restoreDialogActions: some View {
        Button(String(localized: "Restore", bundle: LanguageManager.appBundle), role: .destructive) {
            restoreSettingsFromCloud()
        }
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
    }

    private var restoreDialogMessage: some View {
        Text("This replaces your current settings with the iCloud backup. Your session archive is unchanged.", bundle: LanguageManager.appBundle)
    }

    /// Manual "Back Up Settings to iCloud" action. The automatic
    /// debounced push runs after every settings change; this is the
    /// belt-and-braces button for users who want explicit confirmation.
    func backupSettingsNow() {
        guard !isBackingUpSettings else { return }
        isBackingUpSettings = true
        Task {
            await dependencies.storage.cloudKitSettingsSync.pushImmediately()
            await MainActor.run { finishSettingsBackup() }
        }
    }

    @MainActor
    private func finishSettingsBackup() {
        isBackingUpSettings = false
        settingsBackupMessage = Self.settingsBackupMessage(for: dependencies.storage.cloudKitSettingsSync.status)
        showingSettingsBackupAlert = true
    }

    private static func settingsBackupMessage(for status: CloudKitSettingsSync.Status) -> String {
        switch status {
        case .lastPushed(let date):
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return String(localized: "Settings backed up to iCloud (\(formatter.string(from: date))).", bundle: LanguageManager.appBundle)
        case .error(let msg):
            return String(localized: "Backup failed: \(msg). Check your iCloud connection and try again.", bundle: LanguageManager.appBundle)
        default:
            return String(localized: "Settings backed up to iCloud.", bundle: LanguageManager.appBundle)
        }
    }

    /// Manual "Restore Settings from iCloud" action. Swaps the local
    /// settings out for whatever's in the cloud. The cloud is the
    /// last-writer-wins store — if multiple devices have edited
    /// settings recently, this restores from the most recent push.
    func restoreSettingsFromCloud() {
        guard !isRestoringSettings else { return }
        isRestoringSettings = true
        Task {
            let message = await Self.restoreSettingsMessage()
            await MainActor.run { finishSettingsRestore(message) }
        }
    }

    private static func restoreSettingsMessage() async -> String {
        do {
            let cloudDate = try await AppDependencies.current.storage.cloudKitSettingsSync.restoreFromCloud()
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let stamp = formatter.string(from: cloudDate)
            return String(localized: "Settings restored from iCloud (last pushed \(stamp)).", bundle: LanguageManager.appBundle)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return String(localized: "Restore failed: \(detail)", bundle: LanguageManager.appBundle)
        }
    }

    @MainActor
    private func finishSettingsRestore(_ message: String) {
        isRestoringSettings = false
        settingsBackupMessage = message
        showingSettingsBackupAlert = true
    }

    func refreshDeletedCount() {
        let collectorRef = collector
        Task {
            let count = await Task.detached {
                await collectorRef.checkForDeletedSessions().count
            }.value
            await MainActor.run { deletedSessionCount = count }
        }
    }

    func recoverRRData() {
        isRecovering = true
        Task {
            let message: String
            do {
                let session = try await collector.recoverFromDevice()
                message = "Successfully recovered \(session?.rrSeries?.points.count ?? 0) RR points."
            } catch {
                message = "Recovery failed: \(error.localizedDescription)"
            }
            await MainActor.run { finishDeviceRecovery(message) }
        }
    }

    @MainActor
    private func finishDeviceRecovery(_ message: String) {
        recoveryMessage = message
        showingRecoveryAlert = true
        isRecovering = false
    }
}

// MARK: - Exportable URL Wrapper

/// Identifiable wrapper for URL to use with .sheet(item:)
struct ExportableURL: Identifiable {
    let id = UUID()
    let url: URL
}
