import Foundation

// MARK: - Rule catalogue
//
// The rules themselves.
// One `xRule()` factory per rule, each pairing a `condition` predicate with a
// `message` builder; rules that need per-workout memory own a small state
// class and a `resetWorkoutState` hook the engine calls at workout start.
//
// A condition may track per-reading streak state, keyed on the reading it
// came from (α1 recompute, workout second), so evaluating the same snapshot
// twice gives the same answer. Anything spent by firing (a once-per-workout
// flag, a threshold's own cooldown) is spent in `didFire`, which the engine
// runs only when the rule actually fires.
//
// The four group functions are internal rather than private because
// `defaultRules()` lives in the other file and Swift's `private` is
// file-scoped. Everything below them stays private to this file.

extension WorkoutTriggerEngine {
    // α1 threshold crossings and heart-rate drift/spike.
    static func effortRules() -> [Rule] {
        [
            alpha1BelowAeTRule(),
            alpha1AboveVT2Rule(),
            hrDriftHighRule(),
            hrSpikeNoPaceRule()
        ]
    }

    /// α1 ectopic / artifact gate. A
    /// single misclassified beat or ectopic can tank α1 for one
    /// window without the user actually being in a different
    /// physiological state — α1 is computed from RR-interval
    /// detrended-fluctuation analysis, and one bad beat shows up
    /// as a major fit-quality drop (low R²). The DFA fit's R²
    /// (alpha1FitQuality) signals this directly: a low R² means
    /// the line-fit explained little of the variance, which
    /// happens when ectopic outliers dominate the log-log plot.
    ///
    /// Rule: don't fire α1 coaching alerts when the most recent
    /// fit's R² is below 0.85. The metric is unreliable on that
    /// window; wait for the next clean window.
    private static func alpha1FitOK(_ ctx: WorkoutAIContext) -> Bool {
        guard let r2 = ctx.alpha1FitQuality else { return true }
        return r2 >= 0.85
    }

        // α1 in the aerobic-edge band (0.60 ≤ α1 < 0.75). A level test, not
        // a crossing: it fires again every 20 min (its cooldown) while α1
        // stays in the band.
    private static func alpha1BelowAeTRule() -> Rule {
        Rule(
            // .silent rather than .spoken. Per
            // user spec, alerts during workouts are emergency-
            // shaped only ("you're about to die"). Routine
            // physiology coaching like α1 transitions is only
            // recorded (engine.history, in memory, not shown
            // anywhere yet) or left to the opt-in mile-marker
            // tier, not spoken as an audible interrupt while the user is
            // walking. Same logic applies to all the demotions
            // below; comment is here once for the whole batch.
            id: "alpha1.belowAeT",
            tier: .silent,
            cooldown: 20 * 60,
            condition: alpha1BelowAeTCondition,
            message: alpha1BelowAeTMessage
        )
    }

    private static func alpha1BelowAeTCondition(_ ctx: WorkoutAIContext) -> Bool {
        guard alpha1FitOK(ctx) else { return false }
        guard let alpha = ctx.alpha1 else { return false }
        return alpha < 0.75 && alpha >= 0.60
    }

    private static func alpha1BelowAeTMessage(_ ctx: WorkoutAIContext) -> String {
        let a = String(format: "%.2f", locale: .current, ctx.alpha1 ?? 0.75)
        return String(localized: "Your α1 just hit \(a) — you're at your aerobic edge. Back off to keep it easy, or hold this for tempo, your call.", bundle: LanguageManager.appBundle)
    }

        // α1 below 0.50 (above VT2, intense). It reads no target zone or
        // stated intent, so it fires on any session, hard ones included.
        //
        // Debounced. Debug log
        // hrv_debug_log_1778086619.txt showed α1 going
        // 1.41 → 0.32 → 1.31 in 40 seconds with HR steady at
        // 129 bpm, 0% ectopic rejection, R²=0.93. The 0.32
        // reading was a single-sample numerical artifact, not
        // real intensity — but it fired this trigger and the
        // voice coach interrupted the user mid-walk to warn
        // about anaerobic threshold. False alarm logged in the
        // user's defect list as #14 ("Voice coach flagging HR
        // drift on downhill sections"; same root cause —
        // single-sample dropouts firing alerts).
        //
        // Fix: require 2 consecutive sub-threshold α1
        // recomputes. Recompute cadence is 20 s, so this is
        // effectively a "sustained for ~40 s" gate. Real
        // intensity transitions hold through multiple recomputes;
        // numerical artifacts don't.
    private static func alpha1AboveVT2Rule() -> Rule {
        {
            let state = Alpha1VT2State()
            return Rule(
                id: "alpha1.aboveVT2",
                tier: .silent,
                cooldown: 15 * 60,
                condition: { alpha1AboveVT2Condition($0, state: state) },
                message: { alpha1AboveVT2Message($0, state: state) },
                resetWorkoutState: { alpha1AboveVT2ResetWorkoutState(state: state) }
            )
        }()
    }

    /// Closure-captured per-workout state for `alpha1AboveVT2Rule`.
    private final class Alpha1VT2State {
        var consecutiveBelow: Int = 0
        var lastReading: Alpha1Reading?
    }

    /// One α1 recompute as the context shows it: the value and its fit R².
    /// Two recomputes rarely agree on both, so a repeat of the pair is the
    /// same reading seen on a later tick.
    fileprivate struct Alpha1Reading: Equatable {
        let alpha: Double
        let fitQuality: Double?
    }

    /// A window with no α1, or one the R² gate rejects, breaks the run: the
    /// readings either side of it are not consecutive.
    private static func alpha1AboveVT2Condition(_ ctx: WorkoutAIContext, state: Alpha1VT2State) -> Bool {
        guard alpha1FitOK(ctx), let alpha = ctx.alpha1 else {
            state.consecutiveBelow = 0
            return false
        }
        // Only count NEW readings. Tick fires at
        // 1 Hz but α1 only recomputes every 20 s,
        // so we'd see the same reading many times.
        let reading = Alpha1Reading(alpha: alpha, fitQuality: ctx.alpha1FitQuality)
        if reading != state.lastReading {
            state.lastReading = reading
            state.consecutiveBelow = alpha < 0.50 ? state.consecutiveBelow + 1 : 0
        }
        return state.consecutiveBelow >= 2 && alpha < 0.50
    }

    private static func alpha1AboveVT2Message(_ ctx: WorkoutAIContext, state: Alpha1VT2State) -> String {
        let a = String(format: "%.2f", locale: .current, ctx.alpha1 ?? 0)
        return String(localized: "α1 at \(a) — you're above your anaerobic threshold. If that's on purpose, nice. If not, easing up wouldn't hurt.", bundle: LanguageManager.appBundle)
    }

    private static func alpha1AboveVT2ResetWorkoutState(state: Alpha1VT2State) {
        state.consecutiveBelow = 0
        state.lastReading = nil
    }

        // HR drift >5% in the back half of a long session.
        //
        // Must not read `ctx.hrDriftPercent`, which is
        // a post-finalize field (always nil mid-workout), or this
        // rule never fires. Reads `liveHRDriftPercent`, which
        // `WorkoutLiveTrends` computes per-tick from the rolling
        // sample buffer.
        //
        // Grade-aware suppression. HR rising while on
        // a climb is mechanical, not drift; surfacing "drift" when
        // the user is mid-hill is the kind of false alarm the user
        // explicitly called out (item #12). Skip when the current
        // sustained grade is >+2 % (climb) or <-2 % (descent —
        // HR dropping on a downhill mid-quartile would also distort
        // the comparison, just in the other direction). The workout
        // must also be more than 30 min in, and the HR slope must be
        // known and not falling (see the condition). The user's spec:
        // "only surface when genuinely meaningful."
    private static func hrDriftHighRule() -> Rule {
        Rule(
            id: "hr.driftHigh",
            tier: .silent,
            cooldown: 20 * 60,
            condition: hrDriftHighCondition,
            message: hrDriftHighMessage
        )
    }

    private static func hrDriftHighCondition(_ ctx: WorkoutAIContext) -> Bool {
        guard let drift = ctx.liveHRDriftPercent else { return false }
        guard drift > 5.0, ctx.elapsedSeconds > 30 * 60 else { return false }
        // Fail-closed gates. Suppressing only when grade > 2 %
        // OR slope < 0 were *known* let nil values pass the
        // alert through, which is the user's bug list
        // items #4 (uphill) and #5 (downhill HR falling).
        // Both trigger when grade isn't computed in time.
        // Rule: REQUIRE both signals before firing.
        // The user wants no false alarms, even at the cost
        // of missing some real drift events.
        guard let g = ctx.currentGradePercent else { return false }
        if abs(g) > 2.0 { return false }
        guard let slope = ctx.recentHRSlopeBpm else { return false }
        if slope < 0 { return false }
        return true
    }

    private static func hrDriftHighMessage(_ ctx: WorkoutAIContext) -> String {
        let d = String(format: "%.0f", locale: .current, ctx.liveHRDriftPercent ?? 0)
        // Include current HR + grade
        // so the user has the context, not just the verdict.
        let grade = ctx.currentGradePercent.map { String(format: "%+.1f%%", locale: .current, $0) }
        switch (ctx.heartRate, grade) {
        case let (hr?, g?):
            return String(localized: "HR's at \(hr), grade \(g), drifted \(d)% higher for the same pace — could be fueling, heat, or just a long day. Easing off for a bit is an option.", bundle: LanguageManager.appBundle)
        case let (hr?, nil):
            return String(localized: "HR's at \(hr), drifted \(d)% higher for the same pace — could be fueling, heat, or just a long day. Easing off for a bit is an option.", bundle: LanguageManager.appBundle)
        case let (nil, g?):
            return String(localized: "grade \(g), drifted \(d)% higher for the same pace — could be fueling, heat, or just a long day. Easing off for a bit is an option.", bundle: LanguageManager.appBundle)
        case (nil, nil):
            return String(localized: "drifted \(d)% higher for the same pace — could be fueling, heat, or just a long day. Easing off for a bit is an option.", bundle: LanguageManager.appBundle)
        }
    }

        // HR spike with no pace change.
        //
        // OLD (broken): compared HR to SESSION peak, so it fired at 100 bpm
        // when the session peak was 105 — reading as "effort problem" while
        // the user was standing still. No zone labels exist on a walk
        // that never got above a jog, and cooldown of 5 min meant the
        // spurious alert chained.
        //
        // NEW: only fires when (a) HR is genuinely high against the user's
        // MAX HR (not session peak), AND (b) we have meaningful pace data
        // (GPS-based sport, meaningful recent split). Both gates protect
        // against resting-HR false positives on short walks with no GPS.
        // Single-sample ectopic beats can
        // momentarily push HR above 85% max while pace stays
        // slow. Firing on a single tick would let one
        // misclassified beat trigger an unwelcome
        // alert. Mirror the α1 VT2 rule's pattern: require two
        // CONSECUTIVE samples that meet the criteria before
        // firing. Single-beat artifacts can't pass this gate; a
        // real sustained spike (≥2 s of consistent 85%+ HR with
        // slow pace) will.
    private static func hrSpikeNoPaceRule() -> Rule {
        {
            let state = HRSpikeState()
            return Rule(
                id: "hr.spikeNoPace",
                tier: .haptic,
                cooldown: 10 * 60,
                condition: { hrSpikeNoPaceCondition($0, state: state) },
                message: { hrSpikeNoPaceMessage($0, state: state) },
                resetWorkoutState: { hrSpikeNoPaceResetWorkoutState(state: state) }
            )
        }()
    }

    /// Closure-captured per-workout state for `hrSpikeNoPaceRule`.
    private final class HRSpikeState {
        var consecutiveAbove: Int = 0
        var lastSampleSecond: Int = -1
    }

    /// One sample per workout second: the engine ticks once a second and the
    /// strap delivers HR at about 1 Hz, so a spike held at a steady HR
    /// (165, 165, 165) counts every second, and the same snapshot evaluated
    /// twice counts once. A second that fails any gate breaks the run.
    private static func hrSpikeNoPaceCondition(_ ctx: WorkoutAIContext, state: HRSpikeState) -> Bool {
        if ctx.elapsedSeconds != state.lastSampleSecond {
            state.lastSampleSecond = ctx.elapsedSeconds
            state.consecutiveAbove = hrSpikeSampleQualifies(ctx) ? state.consecutiveAbove + 1 : 0
        }
        return state.consecutiveAbove >= 2
    }

    /// HR above 85 % of max while pace is more than 5 % slower than the last
    /// split, on a GPS sport. Fail-closed grade gate: require a known, flat
    /// grade so an uphill doesn't false-positive.
    private static func hrSpikeSampleQualifies(_ ctx: WorkoutAIContext) -> Bool {
        guard let hr = ctx.heartRate, ctx.userMaxHR > 0, ctx.sport.usesGPS,
              let current = ctx.currentPaceSecPerKm,
              let recent = ctx.recentSplitPaces.first, recent > 0,
              let grade = ctx.currentGradePercent, abs(grade) <= 2.0
        else { return false }
        return Double(hr) / Double(ctx.userMaxHR) > 0.85 && current > recent * 1.05
    }

    private static func hrSpikeNoPaceMessage(_ ctx: WorkoutAIContext, state: HRSpikeState) -> String {
        let grade = ctx.currentGradePercent.map { String(format: "%+.1f%%", locale: .current, $0) }
        switch (ctx.heartRate, grade) {
        case let (hr?, g?):
            return String(localized: "HR's at \(hr), grade \(g) — pace didn't pick up. Stress, heat, or fatigue maybe. Just flagging it.", bundle: LanguageManager.appBundle)
        case let (hr?, nil):
            return String(localized: "HR's at \(hr) — pace didn't pick up. Stress, heat, or fatigue maybe. Just flagging it.", bundle: LanguageManager.appBundle)
        case let (nil, g?):
            return String(localized: "HR's up, grade \(g) — pace didn't pick up. Stress, heat, or fatigue maybe. Just flagging it.", bundle: LanguageManager.appBundle)
        case (nil, nil):
            return String(localized: "HR's up — pace didn't pick up. Stress, heat, or fatigue maybe. Just flagging it.", bundle: LanguageManager.appBundle)
        }
    }

    private static func hrSpikeNoPaceResetWorkoutState(state: HRSpikeState) {
        state.consecutiveAbove = 0
        state.lastSampleSecond = -1
    }

    // Drift out of the target zone, and the route's climbs ahead. One climb
    // rule: `route.climbAhead` covers every `upcomingClimb`, with its length
    // and queue position.
    static func terrainAndZoneRules() -> [Rule] {
        [
            zoneDriftedHighRule(),
            zoneDriftedLowRule(),
            routeClimbAheadRule()
        ]
    }

        // Zone-target drift rules. Only fire when the user has set a
        // target zone on the ready screen. Tier `.silent`: recorded in
        // the engine history only, never spoken. Each tests the current
        // tick's HR against the target band (once the workout is 1 min /
        // 3 min in; there is no drift-duration debounce), with a 2.5 min
        // cooldown so the user isn't nagged every tick of being slightly
        // out of zone.
        //
        // Scientific basis: HR-zone adherence in polarized training
        // (80/20 rule — Seiler, Kiely) requires actually *staying* in
        // the chosen zone for most of the work.
        // Grade-aware suppression on
        // zone-drift-high too. Outdoor activities at >+2% sustained
        // grade legitimately push HR above the target band — that's
        // the climb doing work, not the user violating their plan.
        // Surfacing "you've drifted above Zone N" mid-hill is a
        // false alarm. Suppress when sustained grade > +2%.
    private static func zoneDriftedHighRule() -> Rule {
        Rule(
            id: "zone.drifted.high",
            tier: .silent,
            cooldown: 2 * 60 + 30,
            condition: zoneDriftedHighCondition,
            message: zoneDriftedHighMessage
        )
    }

    private static func zoneDriftedHighCondition(_ ctx: WorkoutAIContext) -> Bool {
        guard let target = ctx.targetZone,
              let hr = ctx.heartRate,
              ctx.userMaxHR > 0
        else { return false }
        let pct = Double(hr) / Double(ctx.userMaxHR)
        // Top of zone `target` on the canonical %HRmax band model
        // the low-drift rule + TRIMP use: zone N = [(N-1)*0.10+0.50,
        // N*0.10+0.50]. Was `+ 0.60`, i.e. the top of zone N+1 — one
        // full zone too high, so high-drift only fired a zone late.
        let upperBound = Double(target) * 0.10 + 0.50  // Z1 top=0.60, Z2=0.70, Z3=0.80...
        guard pct > upperBound + 0.03, ctx.elapsedSeconds > 60 else { return false }
        // Fail-closed grade gate. An if-let here would let
        // the alert through when grade is nil; instead
        // require a known flat grade before flagging zone
        // violation. Hills explain HR rise mechanically.
        guard let g = ctx.currentGradePercent else { return false }
        if g > 2.0 { return false }
        return true
    }

    private static func zoneDriftedHighMessage(_ ctx: WorkoutAIContext) -> String {
        let target = ctx.targetZone ?? 0
        let hr = ctx.heartRate ?? 0
        return String(localized: "HR at \(hr) — you've drifted above Zone \(target). Back off slightly if this is supposed to be Zone \(target), stay on it if you shifted intent, your call.", bundle: LanguageManager.appBundle)
    }

    private static func zoneDriftedLowRule() -> Rule {
        Rule(
            id: "zone.drifted.low",
            tier: .silent,
            cooldown: 2 * 60 + 30,
            condition: { ctx in
                guard let target = ctx.targetZone, target > 1,
                      let hr = ctx.heartRate,
                      ctx.userMaxHR > 0
                else { return false }
                let pct = Double(hr) / Double(ctx.userMaxHR)
                let lowerBound = Double(target - 1) * 0.10 + 0.50  // below the band
                return pct < lowerBound - 0.03 && ctx.elapsedSeconds > 180
            },
            message: { ctx in
                let target = ctx.targetZone ?? 0
                let hr = ctx.heartRate ?? 0
                return String(localized: "HR at \(hr) — easier than Zone \(target). Pick it up if that's still the goal, or settle in if you've shifted to recovery pace.", bundle: LanguageManager.appBundle)
            }
        )
    }

        // Route-aware climb forecast. Fires once when the user gets
        // within ~500 m of a sustained climb the bound route
        // promised — long enough out to ease off the gas, short
        // enough that the cue still feels relevant. Cooldown
        // dwarfs typical climb durations so we don't re-fire DURING
        // the climb. With route topology we now also speak the climb
        // length, gain, and how it fits in the queue ("first of
        // three") so the user has full pre-emptive awareness.
    private static func routeClimbAheadRule() -> Rule {
        Rule(
            id: "route.climbAhead",
            tier: .silent,
            cooldown: 8 * 60,
            condition: routeClimbAheadCondition,
            message: routeClimbAheadMessage
        )
    }

    private static func routeClimbAheadCondition(_ ctx: WorkoutAIContext) -> Bool {
        guard let climb = ctx.upcomingClimb else { return false }
        return climb.distanceMeters > 0 && climb.distanceMeters < 500
    }

    private static func routeClimbAheadMessage(_ ctx: WorkoutAIContext) -> String {
        guard let climb = ctx.upcomingClimb else { return String(localized: "Climb ahead.", bundle: LanguageManager.appBundle) }
        let useImperial = ctx.userUnits.resolved == .imperial
        let distLabel = useImperial
            ? String(localized: "\(Int((climb.distanceMeters * 1.0936).rounded())) yards", bundle: LanguageManager.appBundle)
            : String(localized: "\(Int(climb.distanceMeters.rounded())) meters", bundle: LanguageManager.appBundle)
        let climbCount = ctx.routeTopology.map { $0.climbsAhead.count } ?? 0
        let grade = String(localized: "\(Int(climb.gradePercent.rounded())) percent grade", bundle: LanguageManager.appBundle)
        let lengthLabel = climbLengthLabel(climb.lengthMeters, imperial: useImperial)
        return routeClimbSentence(distance: distLabel, length: lengthLabel, grade: grade, climbCount: climbCount)
    }

    /// One whole sentence per variant (with/without climb length, with/without
    /// queue position) so translators see each cue as a unit.
    private static func routeClimbSentence(distance: String, length: String?, grade: String, climbCount: Int) -> String {
        switch (length, climbCount > 1) {
        case let (length?, true):
            return String(localized: "Climb in \(distance) — \(length) at about \(grade). First of \(climbCount). Save some power.", bundle: LanguageManager.appBundle)
        case let (length?, false):
            return String(localized: "Climb in \(distance) — \(length) at about \(grade). Save some power.", bundle: LanguageManager.appBundle)
        case (nil, true):
            return String(localized: "Climb in \(distance) — about \(grade). First of \(climbCount). Save some power.", bundle: LanguageManager.appBundle)
        case (nil, false):
            return String(localized: "Climb in \(distance) — about \(grade). Save some power.", bundle: LanguageManager.appBundle)
        }
    }

    /// Spoken length of a climb, or nil when the route topology didn't give
    /// one. Short climbs read better in feet/meters than in miles/kilometers.
    private static func climbLengthLabel(_ lengthMeters: Double, imperial: Bool) -> String? {
        guard lengthMeters > 0 else { return nil }
        if imperial {
            let mi = lengthMeters / 1609.344
            let feet = Int((lengthMeters * UnitConstants.feetPerMeter).rounded())
            guard mi >= 0.1 else { return String(localized: "\(feet) feet", bundle: LanguageManager.appBundle) }
            return String(localized: "\(String(format: "%.1f", locale: .current, mi)) miles", bundle: LanguageManager.appBundle)
        }
        let km = lengthMeters / 1000.0
        guard km >= 0.1 else { return String(localized: "\(Int(lengthMeters.rounded())) meters", bundle: LanguageManager.appBundle) }
        return String(localized: "\(String(format: "%.1f", locale: .current, km)) kilometers", bundle: LanguageManager.appBundle)
    }

    // Strap health, user-set thresholds, cadence. Split markers are
    // `WorkoutMileMarkerEngine`'s, not a rule here.
    static func equipmentAndProgressRules() -> [Rule] {
        [
            equipmentStrapDownRule(),
            userThresholdBreachRule(),
            cadenceConsistencyDropRule()
        ]
    }

        // Strap dropped mid-session: connected on one workout second, gone
        // on the next. A workout recorded without a strap never had one to
        // drop, so it never fires.
    private static func equipmentStrapDownRule() -> Rule {
        let state = StrapLinkState()
        return Rule(
            id: "equipment.strapDown",
            tier: .haptic,
            urgency: .urgent,
            cooldown: 60,
            condition: { strapDroppedCondition($0, state: state) },
            message: { _ in
                String(localized: "Strap just went quiet — switching to your Watch's heart rate.", bundle: LanguageManager.appBundle)
            },
            resetWorkoutState: { state.reset() }
        )
    }

    /// The strap link on the last two distinct workout seconds, so the same
    /// snapshot evaluated twice gives the same answer.
    private final class StrapLinkState {
        var observedSecond = -1
        var previous = false
        var current = false

        func reset() {
            observedSecond = -1
            previous = false
            current = false
        }
    }

    private static func strapDroppedCondition(_ ctx: WorkoutAIContext, state: StrapLinkState) -> Bool {
        if ctx.elapsedSeconds != state.observedSecond {
            state.observedSecond = ctx.elapsedSeconds
            state.previous = state.current
            state.current = ctx.strapConnected
        }
        return state.previous && !state.current
    }

        // User-declared threshold breaches. ONE rule covers all
        // user thresholds — it walks the active list and fires for any
        // threshold whose breach duration has crossed its debounce.
        // This is the ambient-coach surface: user pre-sets "don't
        // exceed 135 for 30s", goes quiet with their audiobook, and
        // only hears the coach when the line is crossed long enough
        // to matter.
        //
        // The rule's tier is `.spoken` (not aiSpoken) — the cue is
        // user-supplied or templated, no LLM round-trip needed, so it
        // can fire instantly the moment the breach matures. Each
        // threshold's own `cooldownSec` gates repeats of THAT threshold
        // (tracked per threshold in `ThresholdCooldownState`, on the
        // workout clock); the engine's 30 s rule cooldown is only a floor
        // between any two threshold cues. The threshold's cooldown starts
        // when its cue fires, which the engine lets happen only when it can
        // be heard, so a muted coach doesn't spend it.
    private static func userThresholdBreachRule() -> Rule {
        let state = ThresholdCooldownState()
        return Rule(
            id: "user.threshold.breach",
            tier: .spoken,
            urgency: .urgent,
            cooldown: 30,
            condition: { ctx in !dueThresholds(ctx, state: state).isEmpty },
            message: { ctx in userThresholdBreachMessage(ctx, state: state) },
            didFire: { ctx in startThresholdCooldown(ctx, state: state) },
            resetWorkoutState: { state.lastSpokenAt.removeAll() }
        )
    }

    /// Workout second at which each threshold's cue was last spoken.
    private final class ThresholdCooldownState {
        var lastSpokenAt: [UUID: Int] = [:]
    }

    /// Thresholds breached past their debounce whose own cooldown has run
    /// out, longest-breached first.
    private static func dueThresholds(_ ctx: WorkoutAIContext, state: ThresholdCooldownState) -> [WorkoutThreshold] {
        ctx.activeThresholds
            .filter { threshold in
                let breachSec = ctx.thresholdBreachSec[threshold.id] ?? 0
                guard breachSec > 0, breachSec >= threshold.debounceSec else { return false }
                guard let last = state.lastSpokenAt[threshold.id] else { return true }
                return ctx.elapsedSeconds - last >= threshold.cooldownSec
            }
            .sorted { (ctx.thresholdBreachSec[$0.id] ?? 0) > (ctx.thresholdBreachSec[$1.id] ?? 0) }
    }

    /// Picks the due threshold with the longest sustained breach — that's
    /// the most-needed cue right now if several are firing simultaneously.
    private static func userThresholdBreachMessage(_ ctx: WorkoutAIContext, state: ThresholdCooldownState) -> String {
        guard let threshold = dueThresholds(ctx, state: state).first else {
            return String(localized: "Threshold breached.", bundle: LanguageManager.appBundle)
        }
        if let userCue = threshold.userCue, !userCue.isEmpty { return userCue }
        return threshold.defaultCue(currentValue: observedValue(of: threshold, in: ctx))
    }

    /// Starts the cooldown of the threshold `userThresholdBreachMessage`
    /// picked: the same `dueThresholds` lookup, before anything changed it.
    private static func startThresholdCooldown(_ ctx: WorkoutAIContext, state: ThresholdCooldownState) {
        guard let threshold = dueThresholds(ctx, state: state).first else { return }
        state.lastSpokenAt[threshold.id] = ctx.elapsedSeconds
    }

    /// The live reading for whichever metric this threshold watches, falling
    /// back to the threshold's own value when the metric isn't being sampled.
    private static func observedValue(of threshold: WorkoutThreshold, in ctx: WorkoutAIContext) -> Double {
        switch threshold.metric {
        case .heartRateBPM: return Double(ctx.heartRate ?? 0)
        case .powerWatts: return Double(ctx.powerWatts ?? 0)
        case .paceSecPerKm: return ctx.currentPaceSecPerKm ?? 0
        case .alpha1: return ctx.alpha1 ?? 0
        case .cadenceSPM: return Double(ctx.cadenceStepsPerMin ?? 0)
        default: return threshold.value
        }
    }

        // Cadence consistency drop. Fires when the
        // cadence has dropped >5 spm sustained vs the first quarter.
        // Tier .haptic: meant as a wrist tap, so cadence breakdown — a
        // fatigue signal worth flagging — doesn't interrupt the user's
        // audiobook. No Watch handler exists yet, so it is recorded only.
    private static func cadenceConsistencyDropRule() -> Rule {
        Rule(
            id: "cadence.consistencyDrop",
            tier: .haptic,
            cooldown: 8 * 60,
            condition: { ctx in
                guard let drift = ctx.cadenceDriftSpm else { return false }
                return drift < -5.0 && ctx.elapsedSeconds > 15 * 60
            },
            message: { ctx in
                let d = String(format: "%.0f", locale: .current, abs(ctx.cadenceDriftSpm ?? 0))
                return String(localized: "Cadence is down about \(d) steps per minute from where you started — stride's getting heavy. Maybe shorten and quicken if that's bothering you.", bundle: LanguageManager.appBundle)
            }
        )
    }

    // Rules that frame the session as a whole: decoupling, the opening
    // readiness note, race-pace detection, periodic check-ins, training load.
    // `settings` is the engine's settings provider (the periodic check-in
    // reads its toggle and cadence through it).
    static func sessionNarrativeRules(settings: @escaping @MainActor () -> UserSettings) -> [Rule] {
        [
            aerobicDecouplingMaterialRule(),
            readinessOpeningRecommendationRule(),
            racePaceModeDetectedRule(),
            coachPeriodicUpdateRule(settings: settings),
            trainingRecentLoadAboveUsualRangeRule()
        ]
    }

        // Aerobic decoupling alert. Fires when Pa:Hr
        // efficiency has dropped >5 % in the second half — the
        // generally-cited threshold for "your aerobic system is
        // showing strain." Tier .silent: the message is written as a
        // prompt for a model to frame, but no code sends it to one; it is
        // recorded in the engine history only.
        //
        // Grade-aware suppression. Pa:Hr efficiency
        // legitimately drops on sustained climbs (more HR per unit
        // of forward speed because you're paying the climb tax);
        // that's expected geography, not aerobic strain. Skip when
        // the current sustained grade is >+2 % so a hilly back-half
        // doesn't generate a false "you're decoupling" alert
        // (item #4 / #12).
    private static func aerobicDecouplingMaterialRule() -> Rule {
        Rule(
            id: "aerobic.decouplingMaterial",
            tier: .silent,
            cooldown: 15 * 60,
            condition: { ctx in
                guard let dec = ctx.aerobicDecouplingPercent else { return false }
                guard dec > 5.0, ctx.elapsedSeconds > 25 * 60 else { return false }
                if let g = ctx.currentGradePercent, g > 2.0 { return false }
                return true
            },
            message: { ctx in
                let d = String(format: "%.0f", locale: .current, ctx.aerobicDecouplingPercent ?? 0)
                return "Aerobic decoupling has hit \(d) percent. Speak ONE short " +
                    "sentence acknowledging the drift, naming what it usually means " +
                    "(fueling / heat / fatigue), and offering an optional pace easeoff. " +
                    "Don't overstate — this is a signal, not an alarm."
            }
        )
    }

        // Readiness-based push/back-off recommendation.
        // Fires ONCE early in a workout (~3 min in, after the first
        // sustained ramp) when today's readiness context is loaded.
        // Frames whether today's a push day or back-off day based on
        // recovery score + TSB + projected days-until-fresh.
        // Closure-captured fired flag; resets per workout via the
        // engine's resetWorkoutState pass.
    private static func readinessOpeningRecommendationRule() -> Rule {
        {
            let state = ReadinessOpeningState()
            return Rule(
                id: "readiness.openingRecommendation",
                tier: .silent,
                cooldown: 0, // gated via state, fires once per workout
                condition: { readinessOpeningRecommendationCondition($0, state: state) },
                message: { _ in
                    "You're a few minutes in. Speak ONE short sentence framing " +
                    "today as a PUSH day or a BACK-OFF day based on todayRecoveryScore, " +
                    "todayTSB, and projectedDaysUntilFresh in the context. Cite ONE " +
                    "concrete number. End with an optional pacing suggestion. " +
                    "If readiness is genuinely middling (no clear signal), say so " +
                    "rather than picking a side."
                },
                didFire: { _ in state.fired = true },
                resetWorkoutState: { state.fired = false }
            )
        }()
    }

    /// Closure-captured per-workout state for `readinessOpeningRecommendationRule`.
    private final class ReadinessOpeningState {
        var fired: Bool = false
    }

    private static func readinessOpeningRecommendationCondition(_ ctx: WorkoutAIContext, state: ReadinessOpeningState) -> Bool {
        guard !state.fired else { return false }
        guard ctx.elapsedSeconds >= 180, ctx.elapsedSeconds < 600 else { return false }
        // Need at least one readiness datapoint to make
        // the call worth speaking. Without inputs, stay
        // silent rather than bluffing.
        return ctx.todayRecoveryScore != nil
            || ctx.todayTSB != nil
            || ctx.projectedDaysUntilFresh != nil
    }

        // Race-pace mode auto-trigger. Fires once per
        // workout when the user has held a pace within ±3 % of
        // their predicted 5K pace for 2+ minutes sustained AND
        // the workout is at least 5 min in. The AI prompt frames
        // it as "you're holding 5K pace — want me to call your
        // splits?" so the user can confirm intent.
        //
        // Closure-captured state tracks (a) sustained-at-pace
        // seconds and (b) whether we've already fired this
        // workout. Reset via the engine's `resetWorkoutState`
        // hook so a new workout starts cleanly.
    private static func racePaceModeDetectedRule() -> Rule {
        {
            let state = RacePaceState()
            return Rule(
                id: "race.paceMode.detected",
                tier: .silent,
                cooldown: 0, // gating via state.fired
                condition: { racePaceModeDetectedCondition($0, state: state) },
                message: { _ in
                    "The user has been holding their predicted 5K race pace for the " +
                    "last two minutes. Speak ONE short sentence acknowledging that " +
                    "they're on race pace, citing the predictedRaceTime5KSec from " +
                    "the context (in the user's units), and offering to call out " +
                    "splits + projected finish at each kilometer. End with an " +
                    "optional check — if they meant to be at easy pace, this is a " +
                    "warning, not a celebration."
                },
                didFire: { _ in state.fired = true },
                resetWorkoutState: { racePaceModeDetectedResetWorkoutState(state: state) }
            )
        }()
    }

    /// Closure-captured per-workout state for `racePaceModeDetectedRule`.
    private final class RacePaceState {
        var sustainedSec: Int = 0
        var fired: Bool = false
        var lastElapsedSec: Int?
    }

    /// Longest gap between two ticks credited as time at race pace. The
    /// engine ticks once a second; a longer gap (the app suspended) is not
    /// time the user was seen holding the pace.
    private static let racePaceMaxCreditSec = 5

    /// Reset the sustained counter whenever we're not in the candidate band,
    /// so the rule requires CONTIGUOUS time at race pace, not cumulative.
    /// Time is the workout clock (`elapsedSeconds`), so a pause adds nothing
    /// and the same snapshot evaluated twice adds nothing.
    private static func racePaceModeDetectedCondition(_ ctx: WorkoutAIContext, state: RacePaceState) -> Bool {
        guard !state.fired,
              ctx.elapsedSeconds >= 300, // ≥ 5 min in
              let currentPace = ctx.currentPaceSecPerKm,
              currentPace > 0,
              let raceSec = ctx.predictedRaceTime5KSec, raceSec > 0
        else { return restartRacePaceWindow(state, at: ctx.elapsedSeconds) }
        let racePace = raceSec / 5.0
        guard abs(currentPace - racePace) / racePace <= 0.03 else { return restartRacePaceWindow(state, at: ctx.elapsedSeconds) }
        if let last = state.lastElapsedSec {
            state.sustainedSec += min(max(0, ctx.elapsedSeconds - last), racePaceMaxCreditSec)
        }
        state.lastElapsedSec = ctx.elapsedSeconds
        return state.sustainedSec >= 120 // 2 min sustained
    }

    /// Clear the sustained-seconds window and report "not firing".
    private static func restartRacePaceWindow(_ state: RacePaceState, at elapsedSec: Int) -> Bool {
        state.sustainedSec = 0
        state.lastElapsedSec = elapsedSec
        return false
    }

    private static func racePaceModeDetectedResetWorkoutState(state: RacePaceState) {
        state.sustainedSec = 0
        state.fired = false
        state.lastElapsedSec = nil
    }

        // Periodic coach check-in. Fires every
        // `periodicCoachCadenceSec` seconds (default 300 = 5 min) only
        // when (a) `enablePeriodicCoachUpdates` is on AND (b) at least
        // one live trend metric is present. Tier .silent: recorded in
        // the engine history only, never spoken. Closure-state tracks
        // the workout second it last fired; resets per workout via the
        // engine's resetWorkoutState hook. Settings come through the
        // engine's provider rather than the app-wide settings.
    private static func coachPeriodicUpdateRule(settings: @escaping @MainActor () -> UserSettings) -> Rule {
        let state = CoachUpdateState()
        return Rule(
            id: "coach.periodicUpdate",
            tier: .silent,
            cooldown: 0, // gated via state + cadence setting
            condition: { coachPeriodicUpdateCondition($0, state: state, settings: settings()) },
            message: coachPeriodicUpdateMessage,
            didFire: { ctx in state.lastFiredElapsedSec = ctx.elapsedSeconds },
            resetWorkoutState: { state.lastFiredElapsedSec = nil }
        )
    }

    /// Closure-captured per-workout state for `coachPeriodicUpdateRule`.
    private final class CoachUpdateState {
        var lastFiredElapsedSec: Int?
    }

    /// Reads the settings fresh each tick — the user can toggle them
    /// mid-workout.
    ///
    /// Never fires inside the first cadence window: let the workout actually
    /// start and gather some data first.
    private static func coachPeriodicUpdateCondition(_ ctx: WorkoutAIContext, state: CoachUpdateState, settings: UserSettings) -> Bool {
        guard settings.enablePeriodicCoachUpdates else { return false }
        let cadence = max(60, settings.periodicCoachCadenceSec) // floor 1 min
        guard ctx.elapsedSeconds >= cadence else { return false }
        if let last = state.lastFiredElapsedSec, ctx.elapsedSeconds - last < cadence {
            return false
        }
        return hasLiveSignal(ctx)
    }

    /// At least one MEANINGFUL live trend metric. A cross-workout baseline
    /// alone is not one. If there's nothing to say right now, the periodic
    /// coach update stays silent instead of filling air.
    private static func hasLiveSignal(_ ctx: WorkoutAIContext) -> Bool {
        ctx.liveHRDriftPercent != nil
            || ctx.aerobicDecouplingPercent != nil
            || ctx.reverseSplitDeltaSecPerKm != nil
            || ctx.cadenceDriftSpm != nil
    }

    private static func coachPeriodicUpdateMessage(_ ctx: WorkoutAIContext) -> String {
        let elapsedMin = ctx.elapsedSeconds / 60
        return "You're \(elapsedMin) minutes into the workout. Speak ONE short sentence about the single most coaching-relevant signal right now: liveHRDriftPercent, aerobicDecouplingPercent, reverseSplitDeltaSecPerKm, cadenceDriftSpm, or pace vs historicalSportAvg. Cite the actual number and what it means for the user — DO NOT list multiple. If NO metric stands out (everything is in normal range), STAY SILENT: output nothing at all. NEVER speak generic encouragement (\"nice work\", \"keep it up\", \"go for it\", \"great run\") or filler just to fill space — a specific observation or nothing."
    }

        // ACWR approaching/above the 1.5 "danger
        // zone" threshold (Gabbett et al.). Fires once per workout
        // when training load context is loaded and ACWR ≥ 1.4.
        // Tier .silent: recorded in the engine history only, never
        // spoken.
        //
        // Closure-state caches the live ACWR proxy. Reset via the
        // engine's resetWorkoutState hook from round 11 so a new
        // workout starts clean.
    private static func trainingRecentLoadAboveUsualRangeRule() -> Rule {
        {
            let state = RecentLoadState()
            return Rule(
                // Neutral descriptor rather than "acwrApproachingDangerZone";
                // the trigger fires on ATL/CTL math but the AI's prompt does
                // not instruct it to surface the raw ACWR number to the user.
                id: "training.recentLoadAboveUsualRange",
                tier: .silent,
                cooldown: 0,
                condition: { trainingRecentLoadAboveUsualRangeCondition($0, state: state) },
                message: trainingRecentLoadAboveUsualRangeMessage,
                didFire: { _ in state.fired = true },
                resetWorkoutState: { state.fired = false }
            )
        }()
    }

    /// Closure-captured per-workout state for `trainingRecentLoadAboveUsualRangeRule`.
    private final class RecentLoadState {
        var fired: Bool = false
    }

    private static func trainingRecentLoadAboveUsualRangeCondition(_ ctx: WorkoutAIContext, state: RecentLoadState) -> Bool {
        guard !state.fired else { return false }
        guard let atl = ctx.todayATL, let ctl = ctx.todayCTL, ctl > 0 else { return false }
        return atl / ctl >= 1.4
    }

    private static func trainingRecentLoadAboveUsualRangeMessage(_ ctx: WorkoutAIContext) -> String {
        let atl = ctx.todayATL ?? 0
        let ctl = ctx.todayCTL ?? 1
        let acwr = atl / ctl
        let descriptor = acwr >= 1.5 ? "noticeably above the user's usual range" : "above the user's usual range"
        return "Training-load context: recent training is \(descriptor) compared to the user's longer-term fitness base. Speak ONE short, conversational sentence acknowledging the heavier-than-usual recent load and offering an optional 'consider an easy day tomorrow.' Do NOT name a specific ACWR number to the user — the ratio is sports-science jargon, not user-friendly. If todayRecoveryScore is high (≥75), soften the message — the user's autonomic state says they're recovering well even though recent load is elevated."
    }
}
