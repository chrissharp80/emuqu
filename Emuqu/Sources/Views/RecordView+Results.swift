import SwiftUI

// The morning-results preview and its supporting rows. Members are internal
// rather than `private` because Swift's `private` does not reach across files.

extension RecordView {
    // MARK: - Morning Results Preview

    func morningResultsPreview(session: HRVSession, result: HRVAnalysisResult) -> some View {
        VStack(spacing: 16) {
            MorningPreviewCards.header(session)
            MorningPreviewCards.metrics(result)
            deviceRefinementNotice
            deviceFetchIndicator
            viewFullReportButton
            // Always offer a way out of the morning preview, so a hung device
            // fetch or a missed auto-accept can't strand the user here.
            Button(action: autoAcceptOvernight) {
                Text(String(localized: "Continue to Dashboard", bundle: LanguageManager.appBundle))
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
        }
        .padding()
        .background(MorningPreviewCards.background)
    }

    /// Device refinement notification — auto-applied, informational only, and
    /// self-dismissing after five seconds.
    @ViewBuilder
    var deviceRefinementNotice: some View {
        if morningCoordination.deviceRefinement != nil {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(AppTheme.sage)
                Text(String(localized: "Score updated with strap data", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AppTheme.sage.opacity(0.08))
            .cornerRadius(8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.3), value: morningCoordination.deviceRefinement != nil)
            .onAppear(perform: scheduleRefinementDismiss)
        }
    }

    func scheduleRefinementDismiss() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            withAnimation(.easeOut(duration: 0.3)) { collector.dismissDeviceRefinement() }
        }
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

    /// Build plan §3.10 — the score reveal is gated behind the pre-score
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

    /// Build plan §3.10 — react to the pre-score prompt's answers. The
    /// `How You Felt` heatmap on Trends reads `HRVSession.morningFeeling`
    /// from the archive (set on the Dashboard), so we do NOT persist the
    /// raw answers here — `preScorePrompt.<id>.*` UserDefaults
    /// writes would be read by nothing and would survive "Delete All My Data".
    /// What matters is the tag side-effect.
    ///
    /// If the user said feeling was Terrible / Hard, surface it as a
    /// ReadingTag.morning + a body cluster MorningFeelingTag so the existing
    /// low-feeling narrative pipeline (TagBasedCauseDetector) picks it up.
    /// terrible→tired (catch-all), hard→tired, others → no tag. We
    /// deliberately don't auto-tag "infection" without explicit user input;
    /// misclassifying a tired day as illness is worse than missing one.
    func applyMorningFeelingAnswers(_ answers: PreScorePromptView.Answers, to session: HRVSession) {
        guard let f = answers.feeling, f == .terrible || f == .hard else { return }
        Task { tagLowFeelingMorning(session) }
    }

    func tagLowFeelingMorning(_ session: HRVSession) {
        do {
            var newTags = Set(session.tags)
            newTags.insert(.morning)
            try collector.archive.updateTags(session.id, tags: Array(newTags), notes: session.notes)
        } catch {
            debugLog("applyMorningFeelingAnswers tag update failed: \(error)")
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
