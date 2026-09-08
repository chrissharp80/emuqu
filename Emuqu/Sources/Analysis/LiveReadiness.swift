import Foundation

/// Live readiness — the dashboard hero's "where am I right now" number.
///
/// The morning Recovery Score is frozen at acceptance: it's what the night
/// gave you. Readiness is *that* score, plus everything that has happened
/// since — today's workout, ATL still dissipating, hours spent recovering.
/// A 93 "Excellent" morning still gets pulled down by a hard afternoon run,
/// and a 60 "Fair" morning recovers as a rest day passes.
///
/// A pure helper so the Dashboard v2 hero and the
/// "why readiness is here" detail panel can both call it without re-deriving
/// half-a-dozen interpolations from `@ObservedObject` state.
struct LiveReadiness {
    /// 0-100 — what we render in the hero ring.
    let score: Double
    /// 0-100 — the frozen morning recovery score that fed readiness.
    let morningRecovery: Double
    /// Hours elapsed since the morning session ended. Drives intra-day
    /// fatigue dissipation.
    let hoursSinceMorning: Double
    /// Sum of TRIMP from workouts in the last 72h (after exponential decay
    /// is applied — i.e. what the readiness math actually consumed).
    let acuteFatigueLoad: Double
    /// Today's accumulated TRIMP (raw, undecayed). What the user did today.
    let todayTrimp: Double
    /// ATL/CTL ratio at the moment of compute. Surfaced to the panel as
    /// "load relative to fitness."
    let acuteChronicRatio: Double?
    /// True when `score` was pulled meaningfully below `morningRecovery`
    /// by today's training (≥3 points). Lets the headline say "your
    /// afternoon run pulled this down" instead of repeating the morning copy.
    let pulledDownByTodaysTraining: Bool
    /// True when fatigue dissipation since morning has lifted readiness
    /// above where it started (rest day, ATL bleeding off).
    let liftedByRecovery: Bool
    /// The day's marquee workout — the one worth naming in narrative copy.
    /// Picked as the highest-TRIMP today; nil on rest days. Lets the panel
    /// say "Hard 45-min run pulled this down" instead of leaning on raw
    /// TRIMP numbers per the Joystick playbook's "hide millisecond, show
    /// verdict" rule.
    let todayPrimaryWorkout: WorkoutDescriptor?

    /// Compute live readiness from a morning recovery score and current
    /// training metrics. The recovery score is taken as a primary input
    /// rather than read off the session so callers can pass a pre-acceptance
    /// live calculation (for sessions that haven't frozen their score yet).
    ///
    /// - Parameters:
    ///   - recoveryScore: Morning recovery score on the 0–100 scale.
    ///   - morningSession: Today's overnight session — used for the frozen
    ///     ATL/CTL snapshot and the session end time that anchors
    ///     `hoursSinceMorning`. Nil-tolerant for callers that don't have a
    ///     session at all (degrades to a no-context, anchor-now readout).
    ///   - liveMetrics: Current `TrainingMetricsCache` snapshot. Nil-tolerant
    ///     too — we degrade to "readiness == recoveryScore" when training
    ///     data hasn't synced, so the hero still renders an honest number.
    ///   - now: Injectable clock for deterministic tests.
    static func compute(
        recoveryScore: Double,
        morningSession: HRVSession?,
        liveMetrics: TrainingMetrics?,
        now: Date = Date()
    ) -> LiveReadiness {
        let sessionEnd = morningSession?.endDate ?? morningSession?.startDate ?? now
        let hoursSinceMorning = max(0, now.timeIntervalSince(sessionEnd) / 3_600.0)
        guard let live = liveMetrics else {
            return morningOnly(recoveryScore: recoveryScore, hoursSinceMorning: hoursSinceMorning)
        }
        let interpolated = interpolatedLoad(
            morningSession: morningSession, live: live, hoursSinceMorning: hoursSinceMorning
        )
        // Acute-fatigue decay only fires when there's training today. On rest
        // days the 7-day ATL EWMA already carries yesterday's workout, and the
        // freshness bonus handles the dissipation — adding 24h-decayed acute
        // fatigue on top would double-count yesterday's load.
        let recentLoads = live.todayTrimp > 0 ? recentWorkoutLoads(from: live, now: now) : nil
        return readiness(
            recoveryScore: recoveryScore, hoursSinceMorning: hoursSinceMorning,
            live: live, interpolated: interpolated, recentLoads: recentLoads, now: now
        )
    }

    private static func readiness(
        recoveryScore: Double,
        hoursSinceMorning: Double,
        live: TrainingMetrics,
        interpolated: InterpolatedLoad,
        recentLoads: [RecoveryScoreCalculator.WorkoutLoad]?,
        now: Date
    ) -> LiveReadiness {
        let score = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: recoveryScore, todayTrimp: live.todayTrimp,
            ctl: interpolated.ctl, atl: interpolated.atl,
            morningATL: interpolated.morningATLForReadiness,
            acuteChronicRatio: interpolated.acr, recentWorkoutLoads: recentLoads
        )
        return LiveReadiness(
            score: score,
            morningRecovery: recoveryScore,
            hoursSinceMorning: hoursSinceMorning,
            acuteFatigueLoad: computeRawAcuteFatigue(todayTrimp: live.todayTrimp, recentLoads: recentLoads),
            todayTrimp: live.todayTrimp,
            acuteChronicRatio: interpolated.acr,
            pulledDownByTodaysTraining: recoveryScore - score >= 3,
            liftedByRecovery: score - recoveryScore >= 3,
            todayPrimaryWorkout: WorkoutDescriptor.todayPrimary(
                from: live.todayWorkouts.isEmpty ? live.recentWorkouts : live.todayWorkouts,
                now: now
            )
        )
    }

    /// Without live training metrics we can't compute drift. The morning score
    /// is returned as readiness so the hero still renders something honest — it
    /// just won't move during the day.
    private static func morningOnly(recoveryScore: Double, hoursSinceMorning: Double) -> LiveReadiness {
        LiveReadiness(
            score: recoveryScore,
            morningRecovery: recoveryScore,
            hoursSinceMorning: hoursSinceMorning,
            acuteFatigueLoad: 0,
            todayTrimp: 0,
            acuteChronicRatio: nil,
            pulledDownByTodaysTraining: false,
            liftedByRecovery: false,
            todayPrimaryWorkout: nil
        )
    }

    /// ATL/CTL blended between this morning's frozen snapshot and today's live
    /// values, plus the anchor the freshness bonus is measured from.
    struct InterpolatedLoad {
        let atl: Double
        let ctl: Double
        let acr: Double?
        let morningATLForReadiness: Double
    }

    /// Mirrors RecoveryDashboardView.computeTrainingReadiness (today branch).
    /// ATL/CTL are interpolated between the frozen morning values and the
    /// stepped EWMA values via dayFraction, so readiness matches the accepted
    /// score at acceptance time and gradually relaxes as real hours pass.
    ///
    /// When the morning context is missing
    /// (unusual — the session is processed but its training snapshot didn't
    /// persist) this defaults to 0 rather than today's live value.
    /// Interpolation then ramps ATL from "unknown morning" to today's value
    /// across the day.
    private static func interpolatedLoad(
        morningSession: HRVSession?,
        live: TrainingMetrics,
        hoursSinceMorning: Double
    ) -> InterpolatedLoad {
        let morningContext = morningSession?.trainingSnapshot
            ?? morningSession?.analysisResult?.trainingContext
        let morningATL = morningContext?.atl ?? 0
        let morningCTL = morningContext?.ctl ?? 0
        let dayFraction = min(max(hoursSinceMorning / 24.0, 0), 1.0)
        let effectiveATL = morningATL + (live.atl - morningATL) * dayFraction
        let effectiveCTL = morningCTL + (live.ctl - morningCTL) * dayFraction
        // For stale sessions (>24h since acceptance) the frozen morning ATL is
        // yesterday's snapshot — no longer a meaningful "this morning" anchor
        // for the freshness bonus. Using the interpolated value collapses the
        // bonus to zero rather than rewarding multi-day decay.
        return InterpolatedLoad(
            atl: effectiveATL,
            ctl: effectiveCTL,
            acr: effectiveCTL > 0 ? effectiveATL / effectiveCTL : nil,
            morningATLForReadiness: dayFraction >= 1.0 ? effectiveATL : morningATL
        )
    }

    /// Headline copy for the explain panel. Names the day's main event when
    /// there is one — the workout that pulled readiness down, or the rest
    /// that lifted it. Falls back to the calculator's stock readiness
    /// message when neither story applies.
    var headline: String {
        let drop = Int((morningRecovery - score).rounded())
        let lift = Int((score - morningRecovery).rounded())
        if pulledDownByTodaysTraining {
            if let w = todayPrimaryWorkout {
                return "Your \(w.phrase) pulled readiness down about \(drop) from this morning."
            }
            // No today workout but readiness still dragged — yesterday's
            // training is decaying out via the 24h acute-fatigue term.
            return "Recent training is pulling readiness about \(drop) below this morning."
        }
        if liftedByRecovery {
            return "Fatigue is dissipating through the day — readiness is up about \(lift) from this morning."
        }
        return RecoveryScoreCalculator.readinessMessage(
            for: score / 10,
            acuteChronicRatio: acuteChronicRatio
        )
    }

    /// Optional one-liner for the Today's Loop card under the medallion.
    /// Only returns when there's a story the morning verdict's stock copy
    /// won't tell — so the dashboard can fall back to the canonical verdict
    /// ladder for ordinary days.
    var loopCardText: String? {
        // Name today's marquee workout when one exists; otherwise speak of
        // "recent training" so a yesterday-evening run pulling on this
        // morning's readiness doesn't get mislabeled as "today's main event."
        if pulledDownByTodaysTraining, let w = todayPrimaryWorkout {
            return "Your \(w.phrase) is the day's main event — let it absorb."
        }
        if pulledDownByTodaysTraining {
            return "Recent training is still in your legs — let it absorb."
        }
        if liftedByRecovery {
            return "Body is using the day to recover — readiness is climbing."
        }
        return nil
    }

    // MARK: - Helpers

    /// Build the WorkoutLoad array `RecoveryScoreCalculator.calculateReadiness`
    /// expects. 72h lookback so fatigue decays smoothly across midnight rather
    /// than cliffing when `todayTrimp` resets at the new calendar day.
    static func recentWorkoutLoads(
        from metrics: TrainingMetrics,
        now: Date = Date()
    ) -> [RecoveryScoreCalculator.WorkoutLoad]? {
        let cutoff: TimeInterval = 72 * 3600
        let loads = metrics.recentWorkouts.compactMap { workout -> RecoveryScoreCalculator.WorkoutLoad? in
            let elapsed = now.timeIntervalSince(workout.date)
            guard elapsed >= 0, elapsed <= cutoff else { return nil }
            let trimp = workout.calculateTrimp()
            guard trimp > 0 else { return nil }
            return RecoveryScoreCalculator.WorkoutLoad(
                hoursAgo: elapsed / 3600.0,
                trimp: trimp
            )
        }
        return loads.isEmpty ? nil : loads
    }

    /// Sum of decayed TRIMP from recent workouts — the value the readiness
    /// math actually consumes for "acute fatigue." Surfaced to the panel as
    /// the size of the load still pulling on the user.
    private static func computeRawAcuteFatigue(
        todayTrimp: Double,
        recentLoads: [RecoveryScoreCalculator.WorkoutLoad]?
    ) -> Double {
        guard let loads = recentLoads, !loads.isEmpty else { return todayTrimp }
        let tau = RecoveryScoreConstants.Readiness.acuteFatigueTauHours
        return loads.reduce(0.0) { sum, load in
            sum + load.trimp * exp(-load.hoursAgo / tau)
        }
    }
}

/// Plain-language summary of a single workout — enough for narrative copy
/// without surfacing TRIMP or HR averages directly. The Joystick playbook
/// is consistent: "show the verdict, hide the millisecond." Same rule
/// applies here — name the workout the way a coach would.
struct WorkoutDescriptor: Equatable {
    /// Lowercased everyday word for the activity ("run", "ride", "walk",
    /// "swim", "strength", "yoga", "workout"). Stays singular and unadorned
    /// so it composes into phrases like "hard 45-min run."
    let typeLabel: String
    /// Rounded duration in whole minutes. Workouts under a minute get
    /// floored to 1 — saying "0-min run" reads worse than the rounding lie.
    let durationMinutes: Int
    /// "easy" / "moderate" / "hard" / "very hard" — bucketed off TRIMP, the
    /// integrated load measure. Spoken in the user-facing voice; matches the
    /// panel's signal-stack labels for consistency.
    let intensityWord: String
    /// Underlying TRIMP, kept for any caller that wants to show the raw
    /// number. Panel copy avoids it; the chart story lives elsewhere.
    let trimp: Double

    /// One short phrase ready to drop into a sentence: "hard 45-min run",
    /// "easy 22-min walk", "moderate 60-min ride."
    var phrase: String {
        "\(intensityWord) \(durationMinutes)-min \(typeLabel)"
    }

    /// Maximum plausible duration for a single workout we'd feature in the
    /// daily narrative. HealthKit occasionally surfaces "workouts" of 12+
    /// hours — sleep tracking imported as a workout, an Apple Watch session
    /// that never auto-stopped, an old ride sensor that dumped a stale
    /// session. Saying "your hard 827-min run is the day's main event"
    /// reads as a bug to anyone who sees it. Cap at 6 hours; longer entries
    /// get filtered out of the marquee pool. (They still count toward
    /// TRIMP and ATL — only the narrative slot rejects them.)
    private static let maxNarrativeDurationMinutes: Double = 360

    /// Pick the day's marquee workout to feature in narrative copy. TODAY
    /// only — a yesterday-evening run is still pulling on readiness via the
    /// 24h acute-fatigue decay, but it's not "the day's main event" of
    /// today's day, and naming it as such reads as a bug at 3 AM when the
    /// user knows they haven't done anything yet. The residual-fatigue
    /// signal is conveyed by `loopCardText`'s generic copy instead.
    static func todayPrimary(
        from workouts: [HealthKitManager.WorkoutSummary],
        now: Date = Date()
    ) -> WorkoutDescriptor? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let candidates = workouts.filter {
            $0.durationMinutes > 0
                && $0.durationMinutes <= maxNarrativeDurationMinutes
                && cal.isDate($0.date, inSameDayAs: today)
        }
        guard let pick = candidates.max(by: { $0.calculateTrimp() < $1.calculateTrimp() }) else {
            return nil
        }
        let trimp = pick.calculateTrimp()
        guard trimp > 0 else { return nil }
        return WorkoutDescriptor(
            typeLabel: typeLabel(for: pick.workoutType),
            durationMinutes: max(1, Int(pick.durationMinutes.rounded())),
            intensityWord: intensityWord(for: trimp),
            trimp: trimp
        )
    }

    /// Map the WorkoutSummary's stored type string to a single-word everyday
    /// label. Keeps narrative copy short — "Cycling" reads as a noun, "ride"
    /// composes naturally into "moderate 60-min ride."
    private static func typeLabel(for raw: String) -> String {
        switch raw {
        case "Running": return "run"
        case "Cycling": return "ride"
        case "Swimming": return "swim"
        case "Strength": return "strength session"
        case "HIIT": return "HIIT session"
        case "Yoga": return "yoga session"
        case "Walking": return "walk"
        case "Hiking": return "hike"
        case "Rowing": return "row"
        case "Cross Training": return "cross-training session"
        case "Elliptical": return "elliptical session"
        case "Stairs": return "stair workout"
        default: return "workout"
        }
    }

    /// Bucket TRIMP into the panel's intensity vocabulary. Boundaries match
    /// `ReadinessExplainView.todayTrainingTint` so the colour and the word
    /// always agree.
    private static func intensityWord(for trimp: Double) -> String {
        if trimp < 30 { return "easy" }
        if trimp < 80 { return "moderate" }
        if trimp < 150 { return "hard" }
        return "very hard"
    }
}
