import SwiftUI

// The morning-results preview and its supporting rows. Members are internal
// rather than `private` because Swift's `private` does not reach across files.

extension RecordView {
    // MARK: - Morning Results Preview

    func morningResultsPreview(session: HRVSession, result: HRVAnalysisResult) -> some View {
        VStack(spacing: 16) {
            MorningPreviewCards.header(session)
            MorningPreviewCards.metrics(result)
            viewFullReportButton
            continueToDashboardButton
        }
        .padding()
        .background(MorningPreviewCards.background)
    }

    /// Always offer a way out of the preview, so a hung device fetch can't
    /// strand the user here. This preview shows only for non-overnight
    /// readings awaiting acceptance, so the way out is the full accept path
    /// (baseline, backup archive flag, sync), then the Dashboard.
    private var continueToDashboardButton: some View {
        Button {
            acceptSession()
            selectedTab = .dashboard
        } label: {
            Text(String(localized: "Continue to Dashboard", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.secondary)
    }

    var viewFullReportButton: some View {
        Button(action: presentFullReport) {
            HStack {
                Text(String(localized: "View Full Report", bundle: LanguageManager.appBundle))
                Image(systemName: "chart.xyaxis.line")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppTheme.primary)
    }

    /// The score reveal is gated behind the pre-score
    /// subjective prompt. This sets the pending presentation; the prompt's
    /// onComplete handler hands off to `morningPresentation` when finished.
    func presentFullReport() {
        guard let session = sessionState.currentSession,
              let result = session.analysisResult else { return }
        Task {
            cachedRecentSessions = await collector.recentSessionsAsync(
                limit: MorningResultsView.recentSessionsContextLimit, before: session.startDate)
            pendingMorningPresentation = ResultsPresentation(session: session, result: result)
        }
    }

    /// Stores the pre-score feeling as `HRVSession.morningFeeling` (1–5), the
    /// field the Dashboard prompt, the heatmap and the narrative use, unless
    /// one is already set. Soreness and motivation are not read anywhere.
    ///
    /// Written to the in-memory session as well as the archive: a reading
    /// still waiting for acceptance may not be archived yet, and acceptance
    /// archives the in-memory copy over any stored one.
    func applyMorningFeelingAnswers(_ answers: PreScorePromptView.Answers, to session: HRVSession) {
        guard let feeling = answers.feeling, session.morningFeeling == nil else { return }
        let value = Self.feelingValue(feeling)
        let id = session.id
        if sessionState.currentSession?.id == id, sessionState.currentSession?.morningFeeling == nil {
            sessionState.currentSession?.morningFeeling = value
        }
        let archive = collector.archive
        Task.detached { Self.storePreScoreFeeling(value, id: id, archive: archive) }
    }

    private static func feelingValue(_ feeling: PreScorePromptView.Feeling) -> Int {
        switch feeling {
        case .terrible: 1
        case .hard: 2
        case .ok: 3
        case .good: 4
        case .great: 5
        }
    }

    nonisolated private static func storePreScoreFeeling(_ value: Int, id: UUID, archive: SessionArchive) {
        do {
            try archive.update(id) { stored in
                stored.morningFeeling = stored.morningFeeling ?? value
            }
        } catch {
            debugLog("[RecordView] Pre-score feeling not persisted for \(id.uuidString.prefix(8)): \(error)")
        }
    }

    /// Write the user's tags + notes onto the session: Save, Continue and
    /// Done on a reading awaiting acceptance (`acceptSession`), and a quick
    /// reading as it stops (`stopStreaming`), so a reading gets the same tags
    /// whichever button is pressed. An overnight or nap takes its tags at
    /// auto-accept through `preSessionTagged` instead.
    ///
    /// The morning tag is added when the recording ended between 4 and 10 AM.
    /// The tags go onto `currentSession` as well as the archive: a reading not
    /// archived yet has no file to update, and acceptance archives the
    /// in-memory copy over any stored one.
    func persistTagsAndNotes(for session: HRVSession) async {
        let tags = Array(Self.tagsToSave(selectedTags, endedAt: session.endDate ?? Date()))
        let notes = sessionNotes.isEmpty ? nil : sessionNotes
        applyTagsInMemory(tags, notes: notes, sessionId: session.id)
        await writeTagsToArchive(session.id, tags: tags, notes: notes)
    }

    /// Overnight/nap auto-accept: the session with the tags picked before the
    /// night, plus the morning tag when it ended between 4 and 10 AM (as
    /// every save adds it), added to the tags it already holds (a same-night
    /// merge carries an earlier segment's). Notes left empty keep the
    /// session's own. Pure: the auto-accept re-score archives the session it
    /// returns, so the tags reach the archive with the score.
    func preSessionTagged(_ session: HRVSession) -> HRVSession {
        let picked = Self.tagsToSave(selectedTags, endedAt: session.endDate ?? Date())
        let added = picked.filter { !session.tags.contains($0) }
        var tagged = session
        tagged.tags = session.tags + added.sorted { $0.name < $1.name }
        if !sessionNotes.isEmpty { tagged.notes = sessionNotes }
        return tagged
    }

    /// The archive rewrite (decrypt, encode, write) runs off the main actor.
    /// A failure is logged: for a reading not archived yet it is expected,
    /// and acceptance saves the in-memory copy.
    func writeTagsToArchive(_ id: UUID, tags: [ReadingTag], notes: String?) async {
        let archive = collector.archive
        do {
            try await Task.detached { try archive.updateTags(id, tags: tags, notes: notes) }.value
        } catch {
            debugLog("[RecordView] Tags not written to the archive for \(id.uuidString.prefix(8)): \(error)")
        }
    }

    private static func tagsToSave(_ selected: Set<ReadingTag>, endedAt: Date) -> Set<ReadingTag> {
        let hour = Calendar.current.component(.hour, from: endedAt)
        guard hour >= 4, hour < 10 else { return selected }
        return selected.union([ReadingTag.morning])
    }

    /// Tags & Notes edited in a reading's report (morning or quick), handed
    /// over by the report on its Done or as it closes: onto the in-memory
    /// reading while it is still the current one (acceptance archives that
    /// copy), and into the archived copy. The report hands them over after
    /// the toolbar Done has started acceptance, so these writes land after
    /// `persistTagsAndNotes`'s and the report's edits are what is kept.
    func saveReportTags(_ tags: [ReadingTag], notes: String?, sessionId: UUID) {
        applyTagsInMemory(tags, notes: notes, sessionId: sessionId)
        Task { await writeTagsToArchive(sessionId, tags: tags, notes: notes) }
    }

    /// Apply tags + notes onto `currentSession` when it is the session being
    /// saved.
    func applyTagsInMemory(_ tags: [ReadingTag], notes: String?, sessionId: UUID) {
        guard sessionState.currentSession?.id == sessionId else { return }
        sessionState.currentSession?.tags = tags
        sessionState.currentSession?.notes = notes
    }

    func discardMorningReading() {
        rejectSession()
    }
}
