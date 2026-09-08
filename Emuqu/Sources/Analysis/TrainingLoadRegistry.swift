import Foundation

/// Canonical source-of-truth map for training-load values (ATL / CTL /
/// TSB / ACWR / today's TRIMP) across the entire app.
///
/// # The problem this exists to solve
///
/// The same physical concept ("user's current CTL") was readable from
/// four distinct places in the codebase:
///
/// 1. `TrainingMetricsCache.current` — set by
///    `HealthKitManager.calculateTrainingMetrics(...)`; live in-memory.
/// 2. `TrainingMetricsCache.dailySeries[today]` — Banister EWMA replay
///    over a 400-day window; same data via a different code path.
/// 3. `HRVSession.trainingSnapshot` — `TrainingContext` frozen at
///    session acceptance with `forMorningReading: true`. Does NOT
///    include today's TRIMP. Persisted on the session file forever.
/// 4. `HRVSession.analysisResult.trainingContext` — also frozen at
///    session acceptance via the same path.
///
/// Different surfaces read different sources without coordination:
/// Dashboard pulled live, AI pulled live, **PDF and Holistic Daily
/// Report pulled frozen morning snapshots**, AI's
/// `workout.live.today_readiness` mixed live and frozen fields.
///
/// User-visible symptom (from a user report):
///   * Dashboard:        CTL 36.4 / ATL 61.2 / TSB −24.8  (live, post-walk)
///   * Holistic Report:  CTL 30   / ATL 61   / TSB −30    (frozen at 03:34 AM, pre-walk)
///   * AI live answer:   often stale by up to the cache-TTL window
///
/// The user reasonably calls all three "wrong" because there's no
/// disclosure of which era each value comes from.
///
/// # What this registry does
///
/// Three guarantees:
///
/// 1. **One accessor per intent.** Every surface picks the semantic
///    it promises the user (`.live` "this is right now",
///    `.frozenForSession` "this is what was true when this session
///    was accepted", `.dailySeries(date:)` "this is what was true on
///    a specific past date") and reads through the corresponding
///    static method on `TrainingLoadRegistry`. The implementation
///    of which underlying store to consult lives here, not at the
///    call site.
///
/// 2. **Provenance attached to every value.** `TrainingLoad` carries
///    a `Provenance` tag identifying its source and the `asOf:` date
///    the number was captured. Callers can render an "as of HH:MM"
///    disclosure so a user looking at a snapshot understands what
///    era they're viewing.
///
/// 3. **Documented surface→source map.** The table below is the
///    contract. Adding a new surface that displays training load is
///    a code review checklist item: pick a row, route through the
///    registry, render with disclosure where appropriate.
///
/// # Surface → source map (canonical)
///
/// | Surface                              | Intent                  | Accessor                                | Disclosure |
/// |--------------------------------------|-------------------------|-----------------------------------------|------------|
/// | Dashboard Load card                  | live now                | `live()`                                | none (live by definition) |
/// | Dashboard Load chip + verdict        | live now                | `live()`                                | none |
/// | Load & Trajectory page numbers       | live now                | `live()`                                | none |
/// | AI `training.load.ctl/atl/tsb/acwr`  | live now                | `live()`                                | "as of HH:MM" baked into the value |
/// | AI `dashboardLoadSnapshot` block     | live now                | `live()`                                | "as of HH:MM" inline in the block |
/// | AI `workout.live.today_readiness`    | live ATL/CTL/TSB +      | `live()`                                | (recovery_score + training_readiness fields are frozen by separate contract) |
/// |                                      | frozen morning readiness|                                         |            |
/// | AI `training.load.by_date(yyyy-mm-dd)`| historical day          | `forDate(_:)`                           | day stamp baked in |
/// | Workout post-summary card            | live now                | `live()`                                | none |
/// | Recovery Score Detail                | frozen morning          | `frozenForSession(_:)`                  | "captured HH:MM" prominent |
/// | Holistic Daily Report (Flo report)   | frozen at report time   | `frozenForSession(_:)`                  | "Numbers as of HH:MM" prominent in PDF |
/// | PDF Reports (overnight, workout)     | frozen at report time   | `frozenForSession(_:)`                  | "Numbers as of HH:MM" prominent in PDF |
///
/// # Invalidation contract
///
/// `TrainingMetricsCache` invalidates on every
/// `.flowRecoveryArchiveChanged` notification. So
/// the next `live()` read after a workout / session-write triggers a
/// real HealthKit refresh + EWMA replay. The fast-exit gate in
/// `refresh()` still protects the AI send path from per-turn HK
/// fetches when nothing has changed since the last refresh.
///
/// Frozen values are immutable by definition — once a session is
/// accepted, its `trainingSnapshot` is permanent. Reports that read
/// frozen values are stable across views; only the disclosure changes
/// (the as-of timestamp tells the user what era they're looking at).
@MainActor
enum TrainingLoadRegistry {
    /// A training-load reading with its source identified. Every reader
    /// gets the full tuple so they can render the disclosure if their
    /// surface needs it (reports yes, dashboards no).
    struct TrainingLoad {
        let atl: Double
        let ctl: Double
        let tsb: Double
        let acwr: Double?
        /// TRIMP applied to today's load. Nil for frozen snapshots (the
        /// frozen capture is pre-today by definition; see
        /// `forMorningReading: true` path).
        let todayTrimp: Double?
        let provenance: Provenance

        /// Display string for the as-of timestamp. Use in reports and
        /// any surface where the user needs to know what era the
        /// numbers come from. Format: "9:42 AM" / "Aug 14, 9:42 AM" /
        /// "Mar 3, 2025".
        var asOfDisplay: String {
            let formatter = DateFormatter()
            formatter.timeZone = .current
            let cal = Calendar.current
            let asOf = provenance.asOf
            if cal.isDateInToday(asOf) {
                formatter.dateStyle = .none
                formatter.timeStyle = .short
            } else if let daysAgo = cal.dateComponents([.day], from: asOf, to: Date()).day, daysAgo < 7 {
                formatter.dateFormat = "EEE h:mm a"
            } else {
                formatter.dateFormat = "MMM d, h:mm a"
            }
            return formatter.string(from: asOf)
        }

        /// One-line disclosure for human display. Caller decides
        /// prominence (banner in a report, footnote in a tooltip).
        var disclosure: String {
            switch provenance {
            case .live:
                return "Live · updated \(asOfDisplay)"
            case .frozenAtSessionAcceptance:
                return "Captured \(asOfDisplay) · pre-workout snapshot"
            case .historicalDailySeries(let day):
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM d, yyyy"
                return "As of \(formatter.string(from: day))"
            }
        }
    }

    /// Identifies where a `TrainingLoad` value came from and when.
    enum Provenance {
        /// In-memory cache; reflects every archive write since the
        /// cache last refreshed. `asOf` is the cache's last-refresh
        /// timestamp. Use for any "right now" surface.
        case live(asOf: Date)

        /// Frozen at session acceptance via
        /// `calculateTrainingMetrics(forMorningReading: true)`. The
        /// session's `startDate` is the as-of moment. Excludes today's
        /// TRIMP. Use for reports and per-session detail views that
        /// promise "this is what your numbers were on this morning."
        case frozenAtSessionAcceptance(sessionId: UUID, asOf: Date)

        /// A specific day's value from the cached daily series.
        case historicalDailySeries(date: Date)

        var asOf: Date {
            switch self {
            case .live(let asOf): return asOf
            case .frozenAtSessionAcceptance(_, let asOf): return asOf
            case .historicalDailySeries(let day): return day
            }
        }
    }

    // MARK: - Accessors

    /// **Live current value.** Use for dashboards, the AI's live-state
    /// block, the AI's `training.load.*` resolvers, and the live load
    /// chip. Returns nil only when the cache is genuinely cold (first
    /// launch before any refresh has completed).
    ///
    /// **Source priority matters.** Preferring
    /// `cache.sampleOn(today)` (daily-series EWMA) with a fall back to
    /// `cache.snapshot()` (cache.current) causes the AI to
    /// quote different numbers than the Dashboard.
    ///
    /// Root cause: `TrainingMetricsCache.refresh()` publishes
    /// `cache.current` immediately after the 120-day dashboard
    /// calculation finishes, then kicks the 400-day Banister daily-
    /// series replay as a detached task (see TrainingMetricsCache.swift
    /// :184). Until the detached task finishes, `sampleOn(today)`
    /// returns the OLD value while `cache.current` is fresh. The
    /// Dashboard observes `cache.current` directly, so it
    /// reflects the fresh value while the registry returns the stale
    /// daily-series value — same physical concept, different numbers
    /// in the same minute.
    ///
    /// Order: `cache.snapshot()` (== `cache.current`) FIRST —
    /// guarantees the registry returns exactly what the Dashboard
    /// shows. Fall back to `sampleOn(today)` only when `current` is
    /// missing entirely (truly cold cache).
    static func live() -> TrainingLoad? {
        let cache = AppDependencies.current.analysis.trainingMetricsCache
        if let metrics = cache.snapshot() {
            return TrainingLoad(
                atl: metrics.atl,
                ctl: metrics.ctl,
                tsb: metrics.tsb,
                acwr: metrics.acuteChronicRatio,
                todayTrimp: metrics.todayTrimp > 0 ? metrics.todayTrimp : nil,
                provenance: .live(asOf: cache.lastUpdated ?? Date())
            )
        }
        return dailySeriesFallback(cache: cache)
    }

    /// Today's daily-series bucket, for the cold-cache window where
    /// `dailySeries[today]` is populated before `cache.current` is set.
    private static func dailySeriesFallback(cache: TrainingMetricsCache) -> TrainingLoad? {
        let today = Calendar.current.startOfDay(for: Date())
        if let day = cache.sampleOn(date: today)
            ?? cache.samplesSince(today.addingTimeInterval(-7 * 86_400)).first {
            let acwr = day.ctl > 0 ? day.atl / day.ctl : nil
            return TrainingLoad(
                atl: day.atl,
                ctl: day.ctl,
                tsb: day.tsb,
                acwr: acwr,
                todayTrimp: day.date == today ? day.trimp : nil,
                provenance: .live(asOf: cache.lastUpdated ?? Date())
            )
        }
        return nil
    }

    /// Like `live()` but first awaits a cache refresh, so the value
    /// reflects every archive write since the last refresh.
    ///
    /// **Report generators must use this, not `live()`.** Reports
    /// capture the value once and never re-read it. `live()` reads the
    /// non-blocking `cache.snapshot()`, which returns the *previous*
    /// `current` whenever the cache was invalidated but not yet
    /// recomputed — and `invalidate()` (fired on every archive write,
    /// e.g. a workout save) clears freshness without touching `current`.
    /// So a report rendered in the window between a workout save and the
    /// background refresh landing would freeze the pre-workout TSB/ACWR.
    /// The dashboard self-heals because it observes `cache.current`
    /// and re-renders when the async refresh publishes; a one-shot report
    /// capture does not. `refresh()` fast-exits when the cache is already
    /// fresh, so this is cheap on the warm (no-workout-since) path.
    static func liveRefreshed() async -> TrainingLoad? {
        await AppDependencies.current.analysis.trainingMetricsCache.refresh()
        return live()
    }

    /// **Frozen morning snapshot for a specific session.** Use for
    /// reports, Recovery Score Detail, and any surface that says "what
    /// your training load was when this session was accepted."
    ///
    /// Returns nil when the session was recorded before training-load
    /// integration was enabled (no `trainingSnapshot` on the session).
    static func frozenForSession(_ session: HRVSession) -> TrainingLoad? {
        if let snap = session.trainingSnapshot {
            return frozenLoad(
                atl: snap.atl, ctl: snap.ctl, tsb: snap.tsb,
                acwr: snap.acuteChronicRatio, session: session
            )
        }
        // Fall back to `analysisResult.trainingContext` for
        // sessions where the snapshot landed there instead. Both stores are
        // populated by the same code path at acceptance; older sessions
        // sometimes have only one.
        guard let ctx = session.analysisResult?.trainingContext else { return nil }
        return frozenLoad(
            atl: ctx.atl, ctl: ctx.ctl, tsb: ctx.tsb,
            acwr: ctx.acuteChronicRatio, session: session
        )
    }

    private static func frozenLoad(
        atl: Double,
        ctl: Double,
        tsb: Double,
        acwr: Double?,
        session: HRVSession
    ) -> TrainingLoad {
        TrainingLoad(
            atl: atl,
            ctl: ctl,
            tsb: tsb,
            acwr: acwr,
            todayTrimp: nil,
            provenance: .frozenAtSessionAcceptance(
                sessionId: session.id,
                asOf: session.startDate
            )
        )
    }

    /// **Historical lookup for a specific date.** Use for AI tools that
    /// answer "what was my CTL on March 15." Returns nil when the date
    /// is outside the cached daily-series window.
    static func forDate(_ date: Date) -> TrainingLoad? {
        let day = Calendar.current.startOfDay(for: date)
        guard let sample = AppDependencies.current.analysis.trainingMetricsCache.sampleOn(date: day) else {
            return nil
        }
        let acwr = sample.ctl > 0 ? sample.atl / sample.ctl : nil
        return TrainingLoad(
            atl: sample.atl,
            ctl: sample.ctl,
            tsb: sample.tsb,
            acwr: acwr,
            todayTrimp: sample.trimp,
            provenance: .historicalDailySeries(date: day)
        )
    }
}
