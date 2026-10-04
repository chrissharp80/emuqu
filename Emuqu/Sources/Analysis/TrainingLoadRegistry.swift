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
/// 1. **One accessor per intent.** A surface that shows "right now"
///    reads `live()`; a one-shot capture (a report) reads
///    `liveRefreshed()`, which refreshes first. Which underlying store
///    to consult lives here, not at the call site. Per-session frozen
///    values are read from the session's own `trainingSnapshot`, and
///    past days from `TrainingMetricsCache.sampleOn(date:)`.
///
/// 2. **Provenance attached to every value.** `TrainingLoad` carries
///    a `Provenance` tag identifying its source and the `asOf:` date
///    the number was captured. The AI facts bake the "as of HH:MM"
///    into the value (see the table); no screen or report draws
///    `TrainingLoad.disclosure` itself.
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
/// | AI `training.load.by_date(yyyy-mm-dd)`| historical day          | `TrainingMetricsCache.sampleOn(date:)`  | day stamp baked in |
/// | Workout post-summary card            | live now                | `live()`                                | none |
/// | Recovery Score Detail                | frozen morning          | the session's `trainingSnapshot`        | none |
/// | Holistic Daily Report (Flo report)   | captured at render      | `liveRefreshed()`                       | none drawn |
/// | PDF Reports (overnight, workout)     | captured at render      | `liveRefreshed()`                       | none drawn |
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
/// accepted, its `trainingSnapshot` is permanent, so surfaces that read
/// it are stable across views.
@MainActor
enum TrainingLoadRegistry {
    /// A training-load reading with its source identified. Every reader
    /// gets the full tuple, provenance included.
    struct TrainingLoad {
        let atl: Double
        let ctl: Double
        let tsb: Double
        let acwr: Double?
        /// TRIMP applied to today's load. Nil when nothing was recorded
        /// today.
        let todayTrimp: Double?
        let provenance: Provenance

        /// Display string for the as-of timestamp, in the app locale:
        /// a time today, weekday + time within a week, else date + time.
        var asOfDisplay: String {
            let formatter = DateFormatter()
            formatter.locale = LanguageManager.appLocale
            let cal = Calendar.current
            let asOf = provenance.asOf
            if cal.isDateInToday(asOf) {
                formatter.timeStyle = .short
            } else if let daysAgo = cal.dateComponents([.day], from: asOf, to: Date()).day, daysAgo < 7 {
                formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
            } else {
                formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
            }
            return formatter.string(from: asOf)
        }

        /// One-line disclosure for human display. Caller decides
        /// prominence (banner in a report, footnote in a tooltip).
        var disclosure: String {
            let time = asOfDisplay
            return String(localized: "Live · updated \(time)", bundle: LanguageManager.appBundle)
        }
    }

    /// Identifies where a `TrainingLoad` value came from and when.
    enum Provenance {
        /// In-memory cache; reflects every archive write since the
        /// cache last refreshed. `asOf` is the cache's last-refresh
        /// timestamp. Use for any "right now" surface.
        case live(asOf: Date)

        var asOf: Date {
            switch self {
            case .live(let asOf): asOf
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
}
