import SwiftUI

// The Fitness tab's trailing toolbar menu: GPX download, plus the two ways a
// workout gets INTO the app without having been recorded by it.
//
// Its own file because these are one coherent surface — everything about
// moving workout data across the app's boundary, in one place.

extension FitnessTabView {
    // `fitnessDataMenu` and `healthImportSheet` are internal because the tab's
    // toolbar and modifier chain reach them from the other file. Everything
    // else here is private: it is reached only from inside this extension.
    var fitnessDataMenu: some View {
        Menu { fitnessDataMenuItems } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel(String(localized: "More options", bundle: LanguageManager.appBundle))
            .accessibilityIdentifier("fitness.dataMenu")
    }

    @ViewBuilder
    private var fitnessDataMenuItems: some View {
        healthImportMenuButton
        gpxImportMenuButton
        Divider()
        gpxDownloadMenuButton
    }

    private var healthImportMenuButton: some View {
        Button { showHealthImport = true } label: { healthImportMenuLabel }
    }

    private var healthImportMenuLabel: some View {
        Label(
            String(localized: "Import from Apple Health", bundle: LanguageManager.appBundle),
            systemImage: "heart.text.square"
        )
    }

    /// Until now nothing set `showImporter`: the file importer and its result
    /// handler both existed and were unreachable, which is a feature the code
    /// claims to have and does not.
    private var gpxImportMenuButton: some View {
        Button { showImporter = true } label: { gpxImportMenuLabel }
    }

    private var gpxImportMenuLabel: some View {
        Label(
            String(localized: "Import GPX file", bundle: LanguageManager.appBundle),
            systemImage: "square.and.arrow.down"
        )
    }

    private var gpxDownloadMenuButton: some View {
        Button { Task { await exportLatestGPX() } } label: { gpxDownloadMenuLabel }
    }

    private var gpxDownloadMenuLabel: some View {
        Label(
            String(localized: "Download GPX", bundle: LanguageManager.appBundle),
            systemImage: "square.and.arrow.up"
        )
    }

    var healthImportSheet: some View {
        NavigationStack {
            HealthWorkoutImportSheet(
                importer: healthImporter,
                archive: collector.archive,
                onImported: {
                    collector.notifyArchiveChanged()
                    reloadInterruptedRecordings()
                }
            )
        }
    }

    private var healthImporter: HealthWorkoutImporter {
        HealthWorkoutImporter(manager: dependencies.collection.healthKitManager)
    }

    // MARK: - Interrupted recordings

    /// The card that tells the user a recording died before it captured
    /// anything, and that the hour can still be rebuilt.
    ///
    /// Only the most recent one is shown. A user who has lost two recordings
    /// wants the walk from this morning back, not a list; the sheet behind the
    /// card lists them all.
    @ViewBuilder
    var interruptedRecordingCard: some View {
        if let stub = interruptedRecordings.first {
            InterruptedRecordingCard(stub: stub) { showHealthImport = true }
        }
    }

    /// Reads the archive for recordings that captured nothing.
    ///
    /// Cheap despite the per-session file read: `interruptedSessions` only
    /// opens a session file for a workout entry the INDEX already says ran for
    /// under a minute, and there are approximately none of those in a normal
    /// archive. Called on tab load and after an import so a rebuilt walk clears
    /// its own card.
    func reloadInterruptedRecordings() {
        interruptedRecordings = healthImporter.interruptedSessions(archive: collector.archive)
    }
}
