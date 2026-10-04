import Foundation

/// Pure session-selection policy for the v2 dashboard.
///
/// Extracted from `DashboardV2View`'s private computed properties so the
/// quality-aware selection rules — and the regression history embedded in
/// their comments — live in clock-free, testable functions instead of view
/// internals.
///
/// Inputs:
///   - `sessions` is the newest-first array MainTabView passes the dashboard
///     (the N-most-recent archive slice). Every `first { … }` rule below
///     depends on that ordering.
///   - `Calendar` and "now" are injected by the caller; nothing in this enum
///     reads `Date()`, `Calendar.current`, or any global state.
///
/// Regression coverage lives in `DashboardSessionPolicyTests`.
enum DashboardSessionPolicy {
    /// View-agnostic cell for the Recent strip. `DashboardV2View` maps this
    /// 1:1 onto `RecentStrip.Day` (a view-layer type this model file must
    /// not depend on).
    struct RecentDay: Equatable, Sendable {
        let date: Date
        let score: Int?
        let verdict: ScoreVerdict?
    }

    /// Cold-start SEED for the dashboard hero score, derived from the
    /// synchronously-loaded lightweight index (`SessionArchiveEntry`) so the
    /// ring isn't blank on first paint while the full sessions decrypt.
    ///
    /// Mirrors `latestOvernightComplete`'s quality gates on the entry's
    /// index-side mirrored fields — overnight, HRV-reliable (excludes
    /// `.insufficient`/`.preSleep`), and carries a frozen `recoveryScore` —
    /// with the same most-recent-night-then-longest-duration selection (the
    /// duration proxy is `endDate − date`, since the index has no cleanBeat /
    /// analysisResult). Returns the 0–100 display score (non-finite-safe), or
    /// nil when there's no scorable overnight yet.
    ///
    /// This is intentionally a sibling of `latestOvernightComplete` (distinct
    /// input type, transient use) rather than a shared generic — the two never
    /// need to change together beyond the gate list mirrored above.
    static func latestOvernightScore(inEntries entries: [SessionArchiveEntry], calendar: Calendar) -> Int? {
        let candidates = entries.filter {
            $0.sessionType == .overnight && $0.isReliableForHRVAggregates && $0.recoveryScore != nil
        }
        guard !candidates.isEmpty else { return nil }
        let byNight = Dictionary(grouping: candidates) { calendar.startOfDay(for: entryDay(of: $0)) }
        guard let latestNight = byNight.keys.max() else { return nil }
        let entryDuration: (SessionArchiveEntry) -> TimeInterval = { ($0.endDate ?? $0.date).timeIntervalSince($0.date) }
        guard let winner = byNight[latestNight]?.max(by: { entryDuration($0) < entryDuration($1) }),
              let score = winner.recoveryScore else { return nil }
        return ScoreVerdict.safeDisplayScore(score * 10)
    }

    /// Cold-start SEED for the dashboard's non-hero summary (HRV chip, Sleep
    /// chip, Recent strip), from the synchronously-loaded index — the same idea
    /// as `latestOvernightScore` for the hero, so the whole summary paints on
    /// the first frame instead of only the ring. Every value is an exact index
    /// mirror; `sleepMinutes` is nil when the latest overnight carries no stage
    /// breakdown, so the chip shows "—" rather than a wrong duration.
    struct DashboardSeed: Equatable, Sendable {
        let hrvRmssdMs: Int?
        let sleepMinutes: Int?
        let recentDays: [RecentDay]
    }

    static func dashboardSummarySeed(inEntries entries: [SessionArchiveEntry], today: Date, calendar: Calendar) -> DashboardSeed {
        let latest = latestScoredOvernightEntry(in: entries, calendar: calendar)
        return DashboardSeed(
            hrvRmssdMs: latest?.meanRMSSD.map { Int($0.rounded()) },
            sleepMinutes: latest.flatMap { totalSleepMinutes(in: $0) },
            recentDays: recentDays(fromEntries: entries, today: today, calendar: calendar)
        )
    }

    /// Same gate + selection as `latestOvernightScore`: the latest night's
    /// longest-duration reliable overnight that carries a frozen score.
    private static func latestScoredOvernightEntry(
        in entries: [SessionArchiveEntry], calendar: Calendar
    ) -> SessionArchiveEntry? {
        let overnight = entries.filter {
            $0.sessionType == .overnight && $0.isReliableForHRVAggregates && $0.recoveryScore != nil
        }
        let byNight = Dictionary(grouping: overnight) { calendar.startOfDay(for: entryDay(of: $0)) }
        return byNight.keys.max().flatMap { night in
            byNight[night]?.max(by: { entryDuration($0) < entryDuration($1) })
        }
    }

    private static func entryDuration(_ entry: SessionArchiveEntry) -> TimeInterval {
        (entry.endDate ?? entry.date).timeIntervalSince(entry.date)
    }

    /// Deep + REM + core. Nil when the index carries no stage breakdown, so the
    /// chip shows "—" rather than a wrong duration.
    private static func totalSleepMinutes(in entry: SessionArchiveEntry) -> Int? {
        let total = (entry.deepSleepMinutes ?? 0) + (entry.remSleepMinutes ?? 0) + (entry.coreSleepMinutes ?? 0)
        return total > 0 ? total : nil
    }

    /// Index-mirror of `recentDays(from:today:calendar:)` for the cold-start
    /// seed, with the same day rules as `sessionForDay` (no workouts, no
    /// unreliable HRV, an overnight on its wake day, overnight preferred, then
    /// the longest) so the strip does not move when the full sessions load.
    /// Uses the per-day `recoveryScore` the index carries; a day whose only
    /// reading predates score-persistence shows "—" until the full sessions
    /// load (the `readinessScore` fallback needs the full session).
    static func recentDays(fromEntries entries: [SessionArchiveEntry], today: Date, calendar: Calendar) -> [RecentDay] {
        let todayStart = calendar.startOfDay(for: today)
        var days: [RecentDay] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            let entry = entryForDay(date, in: entries, calendar: calendar)
            let scoreInt = entry?.recoveryScore.map { ScoreVerdict.safeDisplayScore($0 * 10) }
            let verdict = scoreInt.map { ScoreVerdict(score: Double($0)) }
            days.append(RecentDay(date: date, score: scoreInt, verdict: verdict))
        }
        return days
    }

    /// `sessionForDay` on the index: overnight first, then the longest.
    private static func entryForDay(_ date: Date, in entries: [SessionArchiveEntry], calendar: Calendar) -> SessionArchiveEntry? {
        let candidates = entries.filter {
            $0.sessionType != .workout && $0.recoveryScore != nil && $0.isReliableForHRVAggregates
                && calendar.isDate(entryDay(of: $0), inSameDayAs: date)
        }
        let overnights = candidates.filter { $0.sessionType == .overnight }
        if let best = overnights.max(by: { entryDuration($0) < entryDuration($1) }) { return best }
        return candidates.max(by: { entryDuration($0) < entryDuration($1) })
    }

    /// `dayOf` on the index: an overnight belongs to the day it ended sleep.
    private static func entryDay(of entry: SessionArchiveEntry) -> Date {
        if entry.sessionType == .overnight, let sleepEnd = entry.sleepEnd { return sleepEnd }
        return entry.endDate ?? entry.date
    }

    /// Most recent **overnight** session with an analysis result. The
    /// HRV chip uses this so a quick mid-day exercise capture (a 2-5
    /// min session with very different physiology — depressed RMSSD
    /// because the user is mid-effort) doesn't dominate the dashboard
    /// for the rest of the day. A user reported
    /// a 3 ms HRV chip showing through the afternoon after they took
    /// a quick reading mid-workout. The morning overnight value is
    /// the canonical "today's recovery HRV"; everything else is noise
    /// at this surface.
    ///
    /// Quality-aware selection. A naive `.first { … }`
    /// returns whichever overnight session happened to land first
    /// in the sorted array. Beta tester report: "only that dashboard
    /// card is fucked. the underlying history seems fine if i go
    /// into the view all and history tab." Root cause: a 22-minute
    /// partial-backup recovery had the same `sessionType == .overnight
    /// && analysisResult != nil` shape as her real 8-hour Monday
    /// session. Both passed the filter; the recovered partial won
    /// the tie because it had been re-archived more recently. The
    /// history view groups by date and surfaces the longer one,
    /// which is why she only saw the corruption on the dashboard.
    ///
    /// New rule: among overnight sessions that share a recovery
    /// night (keyed on the wake day, as the Recent strip's `dayOf` does —
    /// keying on the start day put a night that began after midnight in the
    /// same group as the following night), pick
    /// the longest-duration one. Across DIFFERENT nights, keep the
    /// most-recent-night-wins ordering the dashboard already
    /// depended on. Duration — not `cleanBeatCount`, which is the
    /// analysis window size (~400 beats whether the session is
    /// 22 min or 8 hours) — is the actual "is this a real
    /// overnight" signal.
    ///
    /// Never surface an untrustworthy-HRV reading as the
    /// canonical "today's recovery HRV". `.insufficient` (awake/too-short
    /// partial) and `.preSleep` (recording ended before sleep) both carry a
    /// non-representative RMSSD that must not headline the dashboard.
    static func latestOvernightComplete(in sessions: [HRVSession], calendar: Calendar) -> HRVSession? {
        let candidates = sessions.filter {
            $0.sessionType == .overnight && $0.analysisResult != nil && $0.isReliableForHRVAggregates
        }
        guard !candidates.isEmpty else { return nil }
        let byNight: [Date: [HRVSession]] = Dictionary(grouping: candidates) {
            calendar.startOfDay(for: dayOf($0))
        }
        guard let mostRecentNight = byNight.keys.max() else { return nil }
        let nightSessions = byNight[mostRecentNight] ?? []
        return nightSessions.max(by: { duration(of: $0) < duration(of: $1) })
    }

    /// Most recent session with a sleep snapshot attached.
    ///
    /// Deliberately NOT gated on `isReliableForHRVAggregates`: sleep minutes are
    /// an independent HealthKit stream, valid even when the HRV *window* was too
    /// short to trust (`.insufficient`) or pre-sleep. A truly bogus sleep
    /// snapshot can no longer attach at all — `fetchSleepData`'s plausibility
    /// choke point blocks a foreign-night block from a short clip — so this
    /// fallback surfaces real sleep rather than hiding it. (The HRV chip's
    /// primary source, `latestOvernightComplete`, IS gated.)
    static func latestWithSleep(in sessions: [HRVSession]) -> HRVSession? {
        sessions.first { $0.sleepSnapshot != nil }
    }

    /// Most recent session with a vitals snapshot attached. Like `latestWithSleep`,
    /// NOT gated on HRV reliability — resting HR / SpO₂ / temperature are
    /// independent of whether the HRV window was trustworthy.
    static func latestWithVitals(in sessions: [HRVSession]) -> HRVSession? {
        sessions.first { $0.vitalsSnapshot != nil && !($0.vitalsSnapshot?.isEmpty ?? true) }
    }

    /// Pick the day's representative reading. The strip is "did you take a
    /// reading on this day?" — so any session with a recovery score counts
    /// EXCEPT `.workout` (exercise-time captures, which can produce noisy
    /// 3 ms RMSSD readings mid-effort). When a day has both an overnight
    /// and a quick spot-check, prefer overnight as the canonical morning
    /// reading.
    ///
    /// An "overnight-only" rule
    /// is over-broad: it catches `.quick` (the Altini-style 5-minute morning
    /// spot check, which is the sanctioned alternative to
    /// overnight) as collateral damage, leaving days with a legitimate
    /// morning reading rendered as empty cells. The narrower exclude-
    /// `.workout` rule preserves the original intent (no exercise noise on
    /// the streak) without dropping legitimate spot-checks.
    static func sessionForDay(_ date: Date, in sessions: [HRVSession], calendar: Calendar) -> HRVSession? {
        let candidates = sessions.filter { isDayCandidate($0, on: date, calendar: calendar) }
        let overnights = candidates.filter { $0.sessionType == .overnight }
        if let bestOvernight = overnights.max(by: { duration(of: $0) < duration(of: $1) }) {
            return bestOvernight
        }
        return candidates
            .filter { $0.sessionType != .overnight }
            .max(by: { duration(of: $0) < duration(of: $1) })
    }

    /// Light the dot for any real reading — one that has a live
    /// `analysisResult` OR a stored `recoveryScore`. Requiring
    /// `analysisResult` alone breaks restored devices: after an
    /// iCloud restore the index score comes back (History renders it — that's
    /// why History was full) but the full session can rehydrate WITHOUT its
    /// analysisResult attached, so the strip's dots stayed blank while History
    /// showed the same readings. The device that recorded the sessions
    /// natively kept its analysisResult, so its strip was fine — same iCloud
    /// data, two devices, only the restored one blank. `recentDays` reads
    /// `recoveryScore ?? readinessScore`, and `recoveryScore` survives the
    /// restore, so admitting it here makes the strip agree with History.
    ///
    /// An untrustworthy-HRV reading must not fill a day cell. On
    /// a day with no real reading (e.g. the strap battery died), a paused
    /// pre-sleep partial would otherwise be the sole candidate and paint the
    /// slot with a bogus low score — and land on the WRONG day when its
    /// fabricated sleepEnd resolves to an adjacent night. Leave the cell empty.
    private static func isDayCandidate(_ session: HRVSession, on date: Date, calendar: Calendar) -> Bool {
        session.sessionType != .workout
            && (session.analysisResult != nil || session.recoveryScore != nil)
            && session.isReliableForHRVAggregates
            && calendar.isDate(dayOf(session), inSameDayAs: date)
    }

    /// Match History's `displayDate` rule for overnights: prefer the
    /// actual sleep-end (wake time) over endDate, because the recording
    /// may have run hours past wake when the user forgot to stop the
    /// strap. Without this, an overnight whose recording ran long lands
    /// on the wrong calendar day in the strip — visible to the user as
    /// a missing dot on the day they swear they had a reading.
    private static func dayOf(_ session: HRVSession) -> Date {
        if session.sessionType == .overnight {
            if let snapshot = session.sleepSnapshot, let sleepEnd = snapshot.sleepEnd {
                return sleepEnd
            }
            if let endMs = session.sleepEndMs {
                return session.startDate.addingTimeInterval(TimeInterval(endMs) / 1000.0)
            }
        }
        return session.endDate ?? session.startDate
    }

    /// Quality-aware pick when multiple sessions land on
    /// the same day. Beta tester: a 22-minute partial-backup recovery
    /// shared a Monday with the real overnight. `.first(where:)`
    /// returns whichever happened to be sorted first — usually the
    /// re-archived-more-recently partial. Dashboard tile, weekly
    /// strip cell, and the day-detail view (`onViewReport`) all
    /// route through THIS function, so all three surfaces showed
    /// the wrong session. The history list grouped per-date and
    /// surfaced both, which is why only "the card" looked wrong.
    ///
    /// Rule: among overnight candidates, prefer the one with the
    /// longest recording duration. `cleanBeatCount` looked like a
    /// good signal at first but it's the ANALYSIS WINDOW size
    /// (~400 beats for any session that finds a usable window) —
    /// not the session total. Duration distinguishes a 22-min
    /// recovery from a 7-hour overnight unambiguously.
    private static func duration(of session: HRVSession) -> TimeInterval {
        let end = session.endDate ?? session.startDate
        return end.timeIntervalSince(session.startDate)
    }

    /// Last 7 readings. (7, not 30, honors the design
    /// contract — if 7 turns out to be too few in
    /// practice, the change is a one-line bump.)
    static func recentDays(from sessions: [HRVSession], today: Date, calendar: Calendar) -> [RecentDay] {
        let todayStart = calendar.startOfDay(for: today)
        var days: [RecentDay] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            let session = sessionForDay(date, in: sessions, calendar: calendar)
            // Prefer the composite recovery score; fall back to the
            // HRV-only readiness score so legacy sessions (where
            // recoveryScore wasn't populated even though the reading was
            // accepted) still surface a value rather than "—".
            let score10: Double? = session?.recoveryScore ?? session?.readinessScore
            let scoreInt = score10.map { ScoreVerdict.safeDisplayScore($0 * 10) }
            let verdict = scoreInt.map { ScoreVerdict(score: Double($0)) }
            days.append(RecentDay(date: date, score: scoreInt, verdict: verdict))
        }
        return days
    }
}

// MARK: - When the score appears

/// The one rule for when the recovery score appears, counted in nights in the
/// personal baseline (`BaselineTracker.daysCollected`, at most one a night).
/// Help, Flo's knowledge base, onboarding and the dashboard all state it:
///
/// - Nights 1-2: the morning report scores the night on general HRV
///   thresholds; there is no personal baseline yet.
/// - From night 3: the score compares the night with the user's own baseline
///   (`RecoveryBaselineStats.minimumDays`), cautiously until night 7.
/// - From night 14: the Dashboard and the score detail show the score and
///   its verdict; before that they show "Building your baseline".
/// - From night 28: the baseline counts as mature ("Full algorithm").
enum ScoreAppearancePolicy {
    /// Night the score first compares the user with their own baseline.
    static let personalBaselineNights = BaselineTracker.RecoveryBaselineStats.minimumDays
    /// Night the Dashboard and score detail first show the score.
    static let scoreShownNights = 14
    /// Night the baseline counts as mature.
    static let fullBaselineNights = 28

    enum Stage: Equatable {
        case building, provisional, full
    }

    /// Whether the headline score and verdict are shown.
    static func showsScore(baselineNights: Int) -> Bool {
        baselineNights >= scoreShownNights
    }

    static func stage(baselineNights: Int) -> Stage {
        if baselineNights < scoreShownNights { return .building }
        if baselineNights < fullBaselineNights { return .provisional }
        return .full
    }
}
