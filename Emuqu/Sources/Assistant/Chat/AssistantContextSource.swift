import Foundation

/// Builds an `AssistantContext` from the live app state on every request.
///
/// **No caching.** Prior iterations kept a 5-minute cache and — even at 60 s —
/// users would change something (max HR, finish a workout, delete a session)
/// and then have to wait or resend for the AI to notice. "Always fresh" is
/// the contract now: whatever's on disk + in memory the moment the user
/// presses Send is what the AI sees.
///
/// Build is still run on a dedicated background queue so it never blocks the
/// caller's thread. Sub-component caches still exist where they're a real
/// win — `AnalysisSummaryCache` memoises the expensive per-session summary
/// generation so the top-level rebuild isn't pulling that work each time.
///
/// Reads sessions from `SessionArchive`, settings from `SettingsManager`,
/// runs `TrendAnalyzer`. Pulls per-session sleep/training/vitals from the
/// session's frozen snapshots — never re-queries HealthKit, so it's fast
/// and won't trigger permission prompts.
final class AssistantContextSource: Sendable {
    static let shared = AssistantContextSource()

    private let queue = DispatchQueue(label: "com.chrissharp.flowrecovery.assistant.contextsource", qos: .userInitiated)

    private init() {}

    // MARK: - Public

    /// Returns a freshly built context. Always runs the build on a
    /// background queue — never blocks the caller's thread. Safe to call
    /// from `@MainActor` without freezing the UI.
    ///
    /// The canonical live training-load snapshot resolves on
    /// MainActor BEFORE `build()` goes to a background queue. Calling
    /// `MainActor.assumeIsolated { TrainingLoadRegistry.live() }` inside the
    /// downstream AnalysisSummaryGenerator's cumulative-load gate instead
    /// traps when invoked off-main (the queue.async closure
    /// runs on a serial bg queue). Capturing here and threading through is the
    /// structural equivalent of `HolisticDailyReport.liveLoadSnapshot`.
    ///
    /// The live-workout / live-HRV overlay after the build is belt-and-braces:
    /// `build()` populates both via ContextBuilder, but doing it again here
    /// makes the snapshot reflect the state at the exact moment we return
    /// rather than the instant the build started. (The workout broker returns
    /// nil once its snapshot is more than 12 s old, and both brokers return
    /// nil when nothing is recording.)
    func currentContext() async -> AssistantContext {
        let liveLoadSnapshot = await MainActor.run { TrainingLoadRegistry.live() }
        return await withCheckedContinuation { continuation in
            queue.async {
                var context = self.build(liveLoadSnapshot: liveLoadSnapshot)
                context.liveWorkout = AppDependencies.current.assistant.liveWorkoutBroker.currentSnapshot()
                context.liveHRVSession = AppDependencies.current.assistant.liveHRVBroker.currentSnapshot()
                continuation.resume(returning: context)
            }
        }
    }

    // MARK: - Build

    /// Sleep + training read straight from the session's frozen snapshots, and
    /// TrendAnalyzer ignores non-overnight sessions internally.
    private func build(liveLoadSnapshot: TrainingLoadRegistry.TrainingLoad? = nil) -> AssistantContext {
        let settings = AppDependencies.current.app.settingsManager.settingsSnapshot
        let recentSessions = recentLightweightSessions()
        // Latest overnight session is the "today" anchor — fall back to most
        // recent of any type.
        let overnightSessions = recentSessions.filter { $0.sessionType == .overnight }
        let latestSession = overnightSessions.first ?? recentSessions.first
        return ContextBuilder.build(
            latestSession: latestSession,
            yesterdaySession: previousOvernight(after: latestSession, in: overnightSessions),
            recentSessions: recentSessions,
            sleepInput: AnalysisSleepInput(from: latestSession?.sleepSnapshot),
            sleepTrend: nil,
            trainingContext: latestSession?.trainingSnapshot,
            userSettings: settings,
            customTagNames: settings.customTags.map(\.name),
            trends7Day: TrendAnalyzer.analyze(sessions: recentSessions, period: .week),
            trends30Day: TrendAnalyzer.analyze(sessions: recentSessions, period: .month),
            liveLoadSnapshot: liveLoadSnapshot
        )
    }

    /// Lightweight sessions (no rrSeries blob) for the last ~30 days,
    /// newest first.
    private func recentLightweightSessions() -> [HRVSession] {
        let archive = AppDependencies.current.storage.sessionArchive
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date.distantPast
        return archive.entries
            .filter { $0.date >= cutoff }
            .sorted { $0.date > $1.date }
            .compactMap { archive.retrieveLightweightOrLog($0.sessionId, caller: "AssistantContextSource.build") }
    }

    /// Yesterday = the next overnight session before today's anchor. Skipping
    /// the latest and taking the next means day-over-day questions get a real
    /// comparison rather than the model inventing values.
    private func previousOvernight(after latest: HRVSession?, in overnight: [HRVSession]) -> HRVSession? {
        guard let latest else { return nil }
        return overnight.first { $0.id != latest.id && $0.startDate < latest.startDate }
    }
}

// MARK: - Archive change notification

extension Notification.Name {
    /// Posted by `RRCollector.notifyArchiveChanged()` whenever the session
    /// archive mutates. Consumed by the dashboard and trends listeners;
    /// AssistantContextSource does not rely on it.
    static let flowRecoveryArchiveChanged = Notification.Name("FlowRecoveryArchiveChanged")
    /// Posted when a session's underlying data (sleep,
    /// training context) changes meaningfully after the session was
    /// already scored. Listener in RRCollector picks it up and
    /// triggers a reanalyze so the frozen score doesn't stay stuck at
    /// a crash-truncated value. The notification's `object` is the
    /// session UUID; userInfo contains `"reason"` ("sleep" or
    /// "training") and `"detail"` for the log.
    static let flowRecoveryRescoreNeeded = Notification.Name("FlowRecoveryRescoreNeeded")
}
