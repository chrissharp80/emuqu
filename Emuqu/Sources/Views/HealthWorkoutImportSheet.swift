import HealthKit
import SwiftUI

/// Lists the workouts Apple Health has and Emuqu does not, and rebuilds the
/// ones the user picks.
///
/// This is the user-facing half of `HealthWorkoutImporter`, and it exists for
/// two people: the one whose recording died mid-workout and wants the hour
/// back, and the one who records in Strava or the Workout app and would
/// otherwise be told their training history is empty.
///
/// The footer states the limit plainly rather than letting the user discover it
/// in a summary screen: an imported workout has heart rate, distance, route and
/// elevation, and it cannot have HRV, because Apple Health stores averaged
/// heart rate rather than beat-to-beat intervals.
struct HealthWorkoutImportSheet: View {
    let importer: HealthWorkoutImporter
    let archive: SessionArchive
    let onImported: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [HealthWorkoutImporter.Candidate]?
    /// Recordings that died before capturing anything. Listed first: this is
    /// the one the user came here angry about.
    @State private var interrupted: [HealthWorkoutImporter.InterruptedSession] = []
    /// Rows already actioned, and the row currently working.
    ///
    /// Deliberately keyed by ROW id, not by workout id: a row is either an
    /// HKWorkout (keyed by its HealthKit uuid) or an interrupted recording
    /// (keyed by its archive session id). Those are two different id spaces
    /// and the view has no business conflating them into one meaning — what it
    /// tracks here is which rows are done and which one is spinning.
    @State private var completedRows: Set<UUID> = []
    @State private var busyRow: UUID?
    @State private var failureMessage: String?

    var body: some View {
        withFailureAlert(listBody)
    }

    private var listBody: some View {
        List { content }
            .navigationTitle(String(localized: "Import from Apple Health", bundle: LanguageManager.appBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { doneToolbarItem }
            .task { await load() }
    }

    private var doneToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) { dismiss() }
        }
    }

    @ViewBuilder
    private var content: some View {
        interruptedSection
        RebuildFromHealthSection(onRebuild: startManualRebuild, isBusy: busyRow == Self.manualRebuildRow)
        candidateRows
        limitsFooter
    }

    /// A fixed id for the manual-rebuild row's busy state. It is not a session
    /// and not an HKWorkout, so it has no id of its own to key on.
    private static let manualRebuildRow = UUID()

    private func startManualRebuild(at start: Date, sport: Sport) {
        Task { await manualRebuild(at: start, sport: sport) }
    }

    private func manualRebuild(at start: Date, sport: Sport) async {
        busyRow = Self.manualRebuildRow
        defer { busyRow = nil }
        switch await importer.rebuild(startingAt: start, sport: sport) {
        case let .success(session):
            store(session, markingDone: Self.manualRebuildRow)
        case let .failure(reason):
            failureMessage = Self.message(for: reason)
        }
    }

    // MARK: - Interrupted recordings

    @ViewBuilder
    private var interruptedSection: some View {
        if !interrupted.isEmpty { Section { interruptedRows } header: { interruptedHeader } }
    }

    private var interruptedHeader: some View {
        Text(String(localized: "Interrupted recordings", bundle: LanguageManager.appBundle))
    }

    private var interruptedRows: some View {
        ForEach(interrupted) { stub in
            HStack {
                interruptedLabel(stub)
                Spacer()
                interruptedAction(stub)
            }
        }
    }

    private func interruptedLabel(_ stub: HealthWorkoutImporter.InterruptedSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(stub.sport.localizedName, systemImage: stub.sport.icon)
            Text(Self.dateText(stub.startDate))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func interruptedAction(_ stub: HealthWorkoutImporter.InterruptedSession) -> some View {
        if completedRows.contains(stub.id) {
            importedBadge
        } else if busyRow == stub.id {
            ProgressView()
        } else {
            rebuildButton(stub)
        }
    }

    private func rebuildButton(_ stub: HealthWorkoutImporter.InterruptedSession) -> some View {
        Button(String(localized: "Rebuild", bundle: LanguageManager.appBundle)) { startRebuild(stub) }
            .buttonStyle(.bordered)
            .disabled(busyRow != nil)
    }

    // MARK: - Rows

    @ViewBuilder
    private var candidateRows: some View {
        if let candidates { resultSection(candidates) } else { loadingRow }
    }

    @ViewBuilder
    private func resultSection(_ found: [HealthWorkoutImporter.Candidate]) -> some View {
        if found.isEmpty { emptyRows } else { Section { ForEach(found, content: row) } }
    }

    private var loadingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(String(localized: "Checking Apple Health…", bundle: LanguageManager.appBundle))
                .foregroundStyle(.secondary)
        }
    }

    private var emptyRows: some View {
        Section {
            Text(String(localized: "Nothing to import", bundle: LanguageManager.appBundle))
                .font(.headline)
            emptyExplanation
        }
    }

    private var emptyExplanation: some View {
        Text(String(
            localized: "Every workout Apple Health has from the last 30 days is already in Emuqu.",
            bundle: LanguageManager.appBundle
        ))
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    /// States the limit here rather than letting the user discover it in a
    /// summary screen with an empty HRV panel.
    private var limitsFooter: some View {
        Section { limitsText }
    }

    // Deliberately one literal on one line: the catalogue extractor does not
    // pick up a multi-line `"""` literal, so a wrapped version of this sentence
    // would ship untranslated in all sixteen locales while every gate still
    // reported clean.
    private var limitsText: some View {
        Text(String(localized: "Heart rate, distance, route and elevation come across. HRV and DFA α1 don't — Apple Health stores averaged heart rate, not the beat-to-beat intervals those need.", bundle: LanguageManager.appBundle))
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func row(_ candidate: HealthWorkoutImporter.Candidate) -> some View {
        HStack {
            rowLabel(candidate)
            Spacer()
            action(for: candidate)
        }
    }

    private func rowLabel(_ candidate: HealthWorkoutImporter.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(candidate.sport.localizedName, systemImage: candidate.sport.icon)
            Text(subtitle(for: candidate)).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func action(for candidate: HealthWorkoutImporter.Candidate) -> some View {
        if completedRows.contains(candidate.id) {
            importedBadge
        } else if busyRow == candidate.id {
            ProgressView()
        } else {
            importButton(candidate)
        }
    }

    private var importedBadge: some View {
        Label(
            String(localized: "Imported", bundle: LanguageManager.appBundle),
            systemImage: "checkmark.circle.fill"
        )
        .labelStyle(.iconOnly)
        .foregroundStyle(.green)
    }

    private func importButton(_ candidate: HealthWorkoutImporter.Candidate) -> some View {
        Button(String(localized: "Import", bundle: LanguageManager.appBundle)) { startImport(candidate) }
            .buttonStyle(.bordered)
            .disabled(busyRow != nil)
    }

    // MARK: - Failure alert

    private func withFailureAlert(_ view: some View) -> some View {
        view.alert(
            String(localized: "Import", bundle: LanguageManager.appBundle),
            isPresented: failurePresented,
            actions: { failureDismissButton },
            message: { failureText }
        )
    }

    private var failurePresented: Binding<Bool> {
        Binding(get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } })
    }

    private var failureDismissButton: some View {
        Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) { failureMessage = nil }
    }

    @ViewBuilder
    private var failureText: some View {
        if let failureMessage { Text(failureMessage) }
    }

    // MARK: - Formatting

    /// Date · duration · distance · which app wrote it. The source name is the
    /// part that tells a Strava user this is their run and not a stray sample.
    private func subtitle(for candidate: HealthWorkoutImporter.Candidate) -> String {
        var parts = [Self.dateText(candidate.startDate)]
        parts.append(LocalizedDuration.hoursMinutes(minutes: Int(candidate.duration / 60)))
        if let meters = candidate.distanceMeters {
            parts.append(UnitsPreferenceStore.current.formatDistance(meters: meters))
        }
        if !candidate.sourceName.isEmpty { parts.append(candidate.sourceName) }
        return parts.joined(separator: " · ")
    }

    /// Date and time in the app language, not the phone's.
    private static func dateText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(LanguageManager.appLocale))
    }

    // MARK: - Actions

    private func load() async {
        guard candidates == nil else { return }
        interrupted = importer.interruptedSessions(archive: archive)
        candidates = await importer.candidates(archive: archive)
    }

    private func startRebuild(_ stub: HealthWorkoutImporter.InterruptedSession) {
        Task { await rebuild(stub) }
    }

    private func rebuild(_ stub: HealthWorkoutImporter.InterruptedSession) async {
        busyRow = stub.id
        defer { busyRow = nil }
        switch await importer.rebuild(stub) {
        case let .success(session):
            store(session, markingDone: stub.id)
        case let .failure(reason):
            failureMessage = Self.message(for: reason)
        }
    }

    /// The two failures read differently on purpose. Steps that show no
    /// activity are the end of the road. No steps at all is either a time
    /// Health recorded nothing or a Steps permission that is off, and an app
    /// cannot tell which (HealthKit does not reveal read permission), so the
    /// message states the fact and names the setting to check.
    private static func message(for reason: HealthWorkoutImporter.RebuildFailure) -> String {
        switch reason {
        case .noActivityAfterStart:
            String(
                localized: "Apple Health has no activity recorded after that recording started, so there is nothing to rebuild it from.",
                bundle: LanguageManager.appBundle
            )
        case .noSamplesAtAll:
            String(
                localized: "Apple Health has no step data for that time, so there is nothing to rebuild it from. If you had your iPhone or Apple Watch with you then, check that Steps is on in Settings → Privacy & Security → Health → Emuqu, and try again.",
                bundle: LanguageManager.appBundle
            )
        }
    }

    private func startImport(_ candidate: HealthWorkoutImporter.Candidate) {
        Task { await importWorkout(candidate) }
    }

    private func importWorkout(_ candidate: HealthWorkoutImporter.Candidate) async {
        busyRow = candidate.id
        defer { busyRow = nil }
        guard let session = await importer.session(for: candidate) else {
            failureMessage = String(
                localized: "That workout is no longer in Apple Health.",
                bundle: LanguageManager.appBundle
            )
            return
        }
        store(session, markingDone: candidate.id)
    }

    /// A rebuild reuses the interrupted stub's id, which iCloud already holds,
    /// so the write asks for a re-upload; the archive only sends one when the
    /// id was already archived, and a new import syncs as usual.
    private func store(_ session: HRVSession, markingDone id: UUID) {
        do {
            _ = try archive.archive(session, skipSameNightMerge: false, requestingReupload: true)
            completedRows.insert(id)
            onImported()
        } catch {
            failureMessage = error.localizedDescription
        }
    }
}
