import CoreLocation
import SwiftUI

// None of the views in this file is placed on a screen in the current app;
// they are kept, with snapshot tests, for the recovery surfaces described
// below.

// MARK: - ArchiveStatusLine

//
// Compact "✓ Saved · ☁ iCloud" line for the recovery card. Shows where the
// current session lives — local archive, iCloud, both, or still saving —
// so users stop wondering whether their data is safe. Tappable for details.
//
// Observes `collector.archiveVersion` (bumps on every archive write) and
// `syncManager.pullVersion` + `syncManager.syncState` so the line updates
// live when state changes.

struct ArchiveStatusLine: View {
    let session: HRVSession
    let collector: RRCollector
    var archiveSignal: ArchiveSignal
    var syncManager: CloudKitSyncManager

    @State private var showingDetails = false

    private var isArchived: Bool {
        collector.archive.exists(session.id)
    }

    private var isUploaded: Bool {
        syncManager.isUploaded(session.id)
    }

    private var isPendingRetry: Bool {
        syncManager.isPendingRetry(session.id)
    }

    private var isSyncing: Bool {
        syncManager.syncState == .syncing
    }

    @ViewBuilder
    var body: some View {
        Button {
            showingDetails = true
        } label: {
            savedStatusRow
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingDetails) {
            ArchiveStatusDetailSheet(
                session: session,
                collector: collector,
                archiveSignal: archiveSignal,
                syncManager: syncManager
            )
            .presentationDetents([.medium])
        }
    }

    private var savedStatusRow: some View {
        HStack(spacing: 6) {
            // Archive status
            archiveStatusSection

            Text(String(localized: "·", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textTertiary)

            // iCloud status
            icloudStatusSection

            Spacer(minLength: 0)

            Image(systemName: "info.circle")
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var archiveStatusSection: some View {
        if isArchived {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(AppTheme.sage)
            Text(String(localized: "Saved", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textSecondary)
        } else {
            ProgressView().scaleEffect(0.6)
            Text(String(localized: "Saving…", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var icloudStatusSection: some View {
        if isUploaded {
            Image(systemName: "icloud.fill")
                .foregroundColor(AppTheme.primary)
            Text(String(localized: "iCloud", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textSecondary)
        } else if isPendingRetry {
            Image(systemName: "icloud.and.arrow.up")
                .foregroundColor(AppTheme.softGold)
            Text(String(localized: "Retrying…", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textSecondary)
        } else if isSyncing {
            ProgressView().scaleEffect(0.6)
            Text(String(localized: "Syncing…", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textSecondary)
        } else {
            Image(systemName: "icloud.slash")
                .foregroundColor(AppTheme.textTertiary)
            Text(String(localized: "Local only", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textTertiary)
        }
    }
}

// MARK: - Details sheet

/// Tapping the status line opens this — shows archive path, hash, upload time,
/// and why the state is what it is. Removes all mystery about where data lives.
struct ArchiveStatusDetailSheet: View {
    let session: HRVSession
    let collector: RRCollector
    var archiveSignal: ArchiveSignal
    var syncManager: CloudKitSyncManager

    @Environment(\.dismiss) private var dismiss

    private var archiveEntry: SessionArchiveEntry? {
        collector.archive.entries.first { $0.sessionId == session.id }
    }

    var body: some View {
        NavigationStack {
            storageForm
                .navigationTitle(String(localized: "Session Storage", bundle: LanguageManager.appBundle))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { doneToolbar }
        }
    }

    private var storageForm: some View {
        Form {
            localArchiveSection

            icloudSection

            forceIcloudSyncSection
        }
    }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) { dismiss() }
        }
    }

    private var forceIcloudSyncSection: some View {
        Section {
            forceIcloudSyncButton
                .disabled(syncManager.syncState == .syncing || !syncManager.isCloudKitAvailable)
        }
    }

    private var forceIcloudSyncButton: some View {
        Button {
            Task { await syncManager.performFullSync() }
        } label: {
            Label(String(localized: "Force iCloud Sync", bundle: LanguageManager.appBundle), systemImage: "arrow.triangle.2.circlepath.icloud")
        }
    }

    private var localArchiveSection: some View {
        Section(String(localized: "Local Archive", bundle: LanguageManager.appBundle)) {
            if let entry = archiveEntry {
                LabeledRow("Status", value: String(localized: "✓ Archived", bundle: LanguageManager.appBundle))
                LabeledRow("Archived at", value: formatDate(entry.date))
                LabeledRow("File hash", value: String(entry.fileHash.prefix(12)) + "…")
                LabeledRow("File path", value: entry.filePath)
            } else {
                LabeledRow("Status", value: String(localized: "Not archived yet", bundle: LanguageManager.appBundle))
            }
        }
    }

    private var icloudSection: some View {
        Section(String(localized: "iCloud", bundle: LanguageManager.appBundle)) {
            icloudStatusRows
            LabeledRow("Pending queue", value: String(localized: "\(syncManager.pendingUploadCount) sessions", bundle: LanguageManager.appBundle))
        }
    }

    @ViewBuilder
    private var icloudStatusRows: some View {
        if !syncManager.isCloudKitAvailable {
            LabeledRow("Status", value: String(localized: "iCloud unavailable", bundle: LanguageManager.appBundle))
        } else if syncManager.isUploaded(session.id) {
            LabeledRow("Status", value: String(localized: "✓ Uploaded", bundle: LanguageManager.appBundle))
            if let last = syncManager.lastSyncDate {
                LabeledRow("Last sync", value: formatDate(last))
            }
        } else if syncManager.isPendingRetry(session.id) {
            LabeledRow("Status", value: String(localized: "Upload failed — queued for retry", bundle: LanguageManager.appBundle))
        } else {
            LabeledRow("Status", value: String(localized: "Not uploaded", bundle: LanguageManager.appBundle))
        }
    }

}

/// `label` is a catalog key, shown in the app's language.
private struct LabeledRow: View {
    let label: LocalizedStringKey
    let value: String
    init(_ label: LocalizedStringKey, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label, bundle: LanguageManager.appBundle)
                .foregroundColor(AppTheme.textSecondary)
            Spacer()
            Text(value)
                .foregroundColor(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
    }
}

// MARK: - LostBackupsBanner

//
// Surfaces the "9 unarchived backups" state to the user. When the user has
// raw RR recordings that never became sessions
// (mid-recording crash, strap download that failed to archive, etc.),
// we tell them and give a one-tap path to Lost Sessions.

struct LostBackupsBanner: View {
    let collector: RRCollector
    var archiveSignal: ArchiveSignal
    /// The count the user dismissed the banner at. It stays hidden while the
    /// count is unchanged; any other count, higher or lower, shows it again
    /// (a "higher only" rule hid a new lost recording after a recovery had
    /// brought the count down).
    @AppStorage("lostBackupsBannerDismissedCount") private var lastDismissedCount: Int = 0
    @State private var showingLostSessions = false

    private var unarchivedCount: Int {
        collector.rawBackup.unarchivedBackupCount
    }

    private var shouldShow: Bool {
        unarchivedCount > 0 && unarchivedCount != lastDismissedCount
    }

    @ViewBuilder
    var body: some View {
        if shouldShow {
            recoverBanner
                .buttonStyle(.plain)
                .sheet(isPresented: $showingLostSessions) { lostSessionsSheet }
        }
    }

    private var recoverBanner: some View {
        Button {
            showingLostSessions = true
        } label: {
            bannerLabel
        }
    }

    private var bannerLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.title3)
                .foregroundColor(AppTheme.softGold)
            bannerCopy
            Spacer(minLength: 0)
            dismissButton
        }
        .padding(12)
        .background(AppTheme.softGold.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(AppTheme.softGold.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(12)
    }

    private var bannerCopy: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(unarchivedCount) recordings to recover", bundle: LanguageManager.appBundle)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.textPrimary)
            Text(String(localized: "Raw data from sessions that never archived. Tap to review.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
                .lineLimit(2)
        }
    }

    private var lostSessionsSheet: some View {
        NavigationStack {
            LostSessionsView()
                .environment(collector)
                .environment(collector.archiveSignal)
        }
    }

    private var dismissButton: some View {
        Button {
            lastDismissedCount = unarchivedCount
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(AppTheme.textTertiary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Dismiss", bundle: LanguageManager.appBundle))
    }
}

// MARK: - InterruptedSessionBanner

//
// A persistent banner meant to back the fire-once launch alert: if the user
// dismisses the alert (tap outside, hit Cancel, etc.), the information would
// stay available here until they act on it.

struct InterruptedSessionBanner: View {
    @Environment(\.dependencies) var dependencies
    let collector: RRCollector
    var archiveSignal: ArchiveSignal
    let onResume: () -> Void
    let onSaveAsComplete: () -> Void
    /// Discard the interrupted-session prompt and the
    /// backed-up beats with it. Destructive (the unsaved data is gone
    /// once cleared), so the caller should confirm with the user
    /// before invoking. The "x" close button on the banner triggers
    /// the confirmation alert that ultimately calls this.
    let onDismiss: () -> Void

    /// Cached read of the on-disk WorkoutTrackBackup. Hydrated in `.task` so
    /// the body doesn't hit the filesystem on every redraw. nil means
    /// either the session isn't a workout or the backup is missing — fall
    /// back to the bare-bones "interrupted recording" copy.
    @State private var workoutContext: WorkoutTrackBackup.Recovered?
    @State private var showDismissConfirm = false

    private var persistedState: (sessionId: UUID, startTime: Date, sessionType: SessionType)? {
        // Only show if the archive DOESN'T already have the session — if it
        // does, the recording was successfully finalized, and we'd be
        // showing a stale banner.
        guard let state = collector.getPersistedRecordingState() else { return nil }
        if collector.archive.exists(state.sessionId) { return nil }
        return state
    }

    private var isResumable: Bool {
        guard let state = persistedState else { return false }
        return Date().timeIntervalSince(state.startTime) < SessionConstants.maxResumableSessionAge
    }

    private typealias PersistedRecording = (sessionId: UUID, startTime: Date, sessionType: SessionType)

    @ViewBuilder
    var body: some View {
        if let state = persistedState {
            withAlerts(withBackdrop(bannerCard(state)), state: state)
        }
    }

    private func bannerCard(_ state: PersistedRecording) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            headline(state)
            detail(state)
            actionButtons
            recoveryTip
        }
    }

    private func headline(_ state: PersistedRecording) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(AppTheme.terracotta)
            Text(headlineText(for: state))
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.textPrimary)
            Spacer()
            dismissButton
        }
    }

    /// Explicit dismiss. Hits a confirmation alert because
    /// clearing the persisted state DOES discard the backed-up beats; without
    /// the warning it'd be too easy to lose data after walking away from the
    /// phone for two hours.
    private var dismissButton: some View {
        Button {
            showDismissConfirm = true
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(AppTheme.textTertiary)
                .imageScale(.medium)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Dismiss", bundle: LanguageManager.appBundle))
    }

    private func detail(_ state: PersistedRecording) -> some View {
        Text(detailText(for: state))
            .font(.caption2)
            .foregroundColor(AppTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if isResumable {
                resumeButton
            }
            saveAsCompleteButton
        }
    }

    private var resumeButton: some View {
        Button {
            onResume()
        } label: {
            Text(resumeButtonLabel)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(AppTheme.primary)
                .foregroundColor(.white)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private var saveAsCompleteButton: some View {
        Button {
            onSaveAsComplete()
        } label: {
            Text(isResumable ? "Save as is" : "Recover data", bundle: LanguageManager.appBundle)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(AppTheme.sectionTint)
                .foregroundColor(AppTheme.textPrimary)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    /// Proactive guidance. After "Save as is" the dashboard can
    /// still show a truncated sleep number (1.4 h instead of the real 5h 53m)
    /// because the session's endDate equals the crash time. Tell the user to
    /// pull-to-refresh to widen the HealthKit query and re-pull training load.
    /// Pull-to-refresh bypasses the frozen snapshot.
    private var recoveryTip: some View {
        Text(String(localized: "Tip: after recovery, pull this dashboard down to refresh sleep + training load. The crash truncated the recording at the moment it died, so the first display may be partial until that pull-to-refresh runs.", bundle: LanguageManager.appBundle))
            .font(.caption2)
            .foregroundColor(AppTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }

    private func withAlerts(_ content: some View, state: PersistedRecording) -> some View {
        content
            .task(id: state.sessionId) {
                loadWorkoutContext(state)
            }
            .alert(String(localized: "Dismiss this prompt?", bundle: LanguageManager.appBundle), isPresented: $showDismissConfirm) {
                Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
                Button(String(localized: "Discard", bundle: LanguageManager.appBundle), role: .destructive) { onDismiss() }
            } message: {
                Text(String(localized: "This clears the interrupted-recording prompt AND discards the backed-up beats from that session. You won't be able to recover them. Tap 'Save as is' instead if you want to keep what was captured.", bundle: LanguageManager.appBundle))
            }
    }

    /// Workout sessions back their context up to disk via WorkoutTrackBackup;
    /// non-workout sessions (overnight, nap, breathe, quick) have no separate
    /// workout artefacts and fall through to the generic copy below.
    private func loadWorkoutContext(_ state: PersistedRecording) {
        guard state.sessionType == .workout else {
            workoutContext = nil
            return
        }
        workoutContext = dependencies.storage.workoutTrackBackup.retrieve(state.sessionId)
    }

    /// Workout-context-aware title. When we have a backed-up workout we
    /// name the sport ("Resume your walk?"); otherwise the generic copy
    /// stays.
    private func headlineText(for state: (sessionId: UUID, startTime: Date, sessionType: SessionType)) -> String {
        if state.sessionType == .workout, let ctx = workoutContext {
            return String(localized: "Resume this \(ctx.header.sport.localizedName) workout?", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Interrupted recording detected", bundle: LanguageManager.appBundle)
    }

    /// Detail line. When we have rich context, surface where the user
    /// left off — sport, elapsed time, distance covered. Falls back to
    /// the original generic line otherwise.
    private func detailText(for state: (sessionId: UUID, startTime: Date, sessionType: SessionType)) -> String {
        if state.sessionType == .workout, let ctx = workoutContext {
            return workoutDetailLine(state: state, context: ctx)
        }
        // No rich workout backup (or non-workout session) — show only
        // what we know: type + relative start time.
        return String(localized: "\(state.sessionType.displayName) recording from \(relativeTime(state.startTime)) was interrupted. Your beats are backed up.", bundle: LanguageManager.appBundle)
    }

    private var resumeButtonLabel: String {
        // Same affordance regardless of whether we have rich context;
        // changing the label would just be visual noise.
        String(localized: "Resume", bundle: LanguageManager.appBundle)
    }

}

// MARK: - File-scope helpers
//
// Kept out of SessionArchive. Each names no member of the
// type and calls nothing inside it, so none needs to be a member.
// `private` at file scope is fileprivate, so every call site in this
// file resolves the same way.

private func formatDate(_ date: Date) -> String {
    date.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(LanguageManager.appLocale))
}

@MainActor
private func withBackdrop(_ content: some View) -> some View {
    content
        .padding(12)
        .background(AppTheme.terracotta.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(AppTheme.terracotta.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(12)
}

private func workoutDetailLine(
    state: (sessionId: UUID, startTime: Date, sessionType: SessionType),
    context: WorkoutTrackBackup.Recovered
) -> String {
    var bits = [elapsedBit(state: state, context: context)].compactMap { $0 }
    // Distance from track segments, rendered in the user's units.
    let distanceMeters = WorkoutGeometry.trackLengthMeters(context.track)
    if distanceMeters >= 50 {
        bits.append(UnitsPreferenceStore.current.formatDistance(meters: distanceMeters))
    }
    // "Started 8 min ago" so the user knows freshness even if the
    // workout details are sparse (e.g. indoor cycle, no GPS).
    bits.append(String(localized: "started \(relativeTime(state.startTime))", bundle: LanguageManager.appBundle))
    let sport = context.header.sport.localizedName
    let bundle = LanguageManager.appBundle
    let lead = String(localized: "\(sport) workout — \(bits.joined(separator: ", ")).", bundle: bundle)
    return lead + " " + String(localized: "Tap Resume to pick up from there, or Save as is to keep what you've got.", bundle: bundle)
}

/// Elapsed time — the last track timestamp anchors it; falls back to the
/// last sample, then to the persisted-state start.
private func elapsedBit(
    state: (sessionId: UUID, startTime: Date, sessionType: SessionType),
    context: WorkoutTrackBackup.Recovered
) -> String? {
    let lastEvent: Date? = context.track.last?.timestamp
        ?? context.samples.last.map { state.startTime.addingTimeInterval(TimeInterval($0.offsetSec)) }
    guard let last = lastEvent else { return nil }
    let elapsed = Int(last.timeIntervalSince(context.header.startDate))
    if elapsed >= 60 { return String(localized: "\(elapsed / 60) min in", bundle: LanguageManager.appBundle) }
    if elapsed >= 1 { return String(localized: "\(elapsed) sec in", bundle: LanguageManager.appBundle) }
    return nil
}

private func relativeTime(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = LanguageManager.appLocale
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}
