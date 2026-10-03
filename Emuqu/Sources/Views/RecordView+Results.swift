import SwiftUI

// The morning-results preview and its supporting rows. Members are internal
// rather than `private` because Swift's `private` does not reach across files.

extension RecordView {
    // MARK: - Morning Results Preview

    func morningResultsPreview(session: HRVSession, result: HRVAnalysisResult) -> some View {
        VStack(spacing: 16) {
            MorningPreviewCards.header(session)
            MorningPreviewCards.metrics(result)
            deviceFetchIndicator
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
            saveMorningReading()
            selectedTab = .dashboard
        } label: {
            Text(String(localized: "Continue to Dashboard", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.secondary)
    }

    /// Subtle device fetch indicator, with an escape hatch that accepts the
    /// beats already streamed rather than waiting on the strap.
    @ViewBuilder
    var deviceFetchIndicator: some View {
        if morningCoordination.isDeviceFetchInProgress {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6)
                Text(String(localized: "Syncing strap data\u{2026}", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
                Spacer()
                skipDeviceFetchButton
            }
        }
    }

    var skipDeviceFetchButton: some View {
        Button(action: skipDeviceFetch) {
            Text(String(localized: "Use \(sessionState.collectedPoints.count.formatted()) streamed beats", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.medium))
        }
        .buttonStyle(.bordered)
        .tint(.secondary)
    }

    func skipDeviceFetch() {
        collector.deviceFetchPolicy = .skipByUser
        collector.polarManager.cancelFetch()
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
        Task {
            cachedRecentSessions = await collector.recentSessionsAsync(
                limit: MorningResultsView.recentSessionsContextLimit)
            guard let session = sessionState.currentSession,
                  let result = reanalyzedResult ?? session.analysisResult else { return }
            pendingMorningPresentation = ResultsPresentation(session: session, result: result)
        }
    }

    /// Stores the pre-score feeling as `HRVSession.morningFeeling` (1–5), the
    /// field the Dashboard prompt, the heatmap and the narrative use, unless
    /// one is already set. Only that field is written, so the tag/notes save on
    /// Done can't overwrite it. Soreness and motivation are not read anywhere.
    func applyMorningFeelingAnswers(_ answers: PreScorePromptView.Answers, to session: HRVSession) {
        guard let feeling = answers.feeling, session.morningFeeling == nil else { return }
        let value = Self.feelingValue(feeling)
        let id = session.id
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

    func saveMorningReading() {
        Task {
            if let session = sessionState.currentSession { await persistTagsAndNotes(for: session) }
            do {
                try await collector.acceptSession()
            } catch {
                debugLog("[RecordView] ⚠️ Failed to accept session: \(error)")
            }
            await MainActor.run {
                selectedTags.removeAll()
                sessionNotes = ""
                quickSource = nil
                selectedSessionType = nil
            }
        }
    }

    /// Write the user's tags + notes onto the session.
    ///
    /// The morning tag is auto-added only when the recording ended in the
    /// morning (before 10 AM). If the archive write fails the session isn't
    /// archived yet (e.g. recovered from the device), so we apply the tags
    /// directly to `currentSession` and let `acceptSession()` pick them up.
    func persistTagsAndNotes(for session: HRVSession) async {
        var tagsToSave = selectedTags
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 4, hour < 10 { tagsToSave.insert(ReadingTag.morning) }
        do {
            try collector.archive.updateTags(
                session.id,
                tags: Array(tagsToSave),
                notes: sessionNotes.isEmpty ? nil : sessionNotes
            )
        } catch {
            await MainActor.run { applyTagsInMemory(Array(tagsToSave)) }
        }
    }

    /// Apply tags + notes straight onto `currentSession` when the archive
    /// write couldn't land.
    @MainActor
    func applyTagsInMemory(_ tags: [ReadingTag]) {
        sessionState.currentSession?.tags = tags
        if !sessionNotes.isEmpty { sessionState.currentSession?.notes = sessionNotes }
    }

    func discardMorningReading() {
        rejectSession()
    }
}
