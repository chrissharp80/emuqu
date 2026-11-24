import Foundation

// MARK: - Workout Trigger Engine
//
// Rule-based engine that watches live workout state and emits coaching
// observations. Designed around three hard contracts from the design brief:
//
//   1. REAL DATA ONLY — a trigger only fires when its condition is met by
//      observed fields in WorkoutAIContext. Rules never invent baselines,
//      terrain, or history.
//   2. ALWAYS OPTIONAL — the phrasing offered by every rule ends in an opt
//      clause ("if you feel like it", "up to you", "no pressure"). The AI
//      suggests; the athlete decides. No imperatives.
//   3. SILENCE IS A FEATURE — each trigger has a cooldown and a tier. Cooldowns
//      prevent repeat chatter. `.spoken` rules are heard, `.haptic` rules are
//      felt (a phone and a Watch haptic), and `.silent` ones are recorded in
//      the engine's in-memory event history only.
//
// The engine is a pure evaluator — it takes a context and returns any events
// that fire. The coach (WorkoutVoiceCoach) delivers them.
@MainActor
final class WorkoutTriggerEngine {
    // MARK: Tier

    enum Tier: String {
        case silent    // recorded in history only
        case haptic    // a phone and a Watch haptic + recorded (spoken too when urgent)
        case spoken    // audible + recorded (message spoken verbatim)
    }

    // MARK: Urgency
    //
    // Only genuine emergency-level thresholds interrupt an active AI
    // voice conversation.
    // A `routine` event that reaches the coach while the AI is
    // mid-conversation is DROPPED; an `urgent` one still preempts because
    // the user explicitly opted into it. An urgent event is also felt as a
    // haptic, and an urgent `.haptic` one is spoken as well. In the default
    // catalogue the urgent rules are the user-declared threshold breach
    // (`.spoken`) and the strap drop (`.haptic`); every other rule is
    // routine and `.silent` or `.haptic`.
    enum Urgency {
        case routine   // background coaching — suppress when AI is talking
        case urgent    // user-declared threshold / strap drop
    }

    // MARK: Event

    struct Event {
        let ruleID: String
        let tier: Tier
        let urgency: Urgency
        let message: String
        let firedAt: Date
    }

    // MARK: Rule

    struct Rule {
        let id: String
        let tier: Tier
        let urgency: Urgency
        let cooldown: TimeInterval
        /// Returns true when the rule's condition is satisfied for `ctx`.
        let condition: (WorkoutAIContext) -> Bool
        /// Returns the phrase to emit. Must only reference fields actually
        /// present in ctx; must end with an optional-phrasing tail.
        let message: (WorkoutAIContext) -> String
        /// Runs once each time the rule fires, after `message`. A rule's
        /// once-per-workout flag or own cooldown is spent here, never in
        /// `condition` or `message`, so evaluating a rule doesn't consume it.
        /// Default no-op.
        let didFire: (WorkoutAIContext) -> Void
        /// Optional per-workout state reset hook. Called
        /// from `WorkoutTriggerEngine.reset()` (which the recorder
        /// fires at workout start). Rules that hold closure-captured
        /// state across ticks (e.g. the readiness rule's `fired` flag)
        /// implement this to clean up between workouts. Default no-op
        /// for stateless rules.
        let resetWorkoutState: () -> Void

        init(
            id: String,
            tier: Tier,
            urgency: Urgency = .routine,
            cooldown: TimeInterval,
            condition: @escaping (WorkoutAIContext) -> Bool,
            message: @escaping (WorkoutAIContext) -> String,
            didFire: @escaping (WorkoutAIContext) -> Void = { _ in },
            resetWorkoutState: @escaping () -> Void = {}
        ) {
            self.id = id
            self.tier = tier
            self.urgency = urgency
            self.cooldown = cooldown
            self.condition = condition
            self.message = message
            self.didFire = didFire
            self.resetWorkoutState = resetWorkoutState
        }
    }

    // MARK: State

    private var lastFired: [String: Date] = [:]
    private(set) var history: [Event] = []
    private(set) var rules: [Rule]

    /// `settingsProvider` is what the default rules read their settings
    /// through (the periodic check-in's toggle and cadence), so the engine
    /// can be evaluated with injected settings.
    init(
        rules: [Rule]? = nil,
        settingsProvider: @escaping @MainActor () -> UserSettings = { AppDependencies.current.app.settingsManager.settings }
    ) {
        self.rules = rules ?? WorkoutTriggerEngine.defaultRules(settings: settingsProvider)
    }

    // MARK: Evaluate

    /// Evaluate all rules against the context, returning any events that
    /// should fire (respecting per-rule cooldowns).
    ///
    /// Every rule's condition runs on every call, cooling down or not, so a
    /// rule's streak state (the α1 and HR-spike runs, the strap link, time at
    /// race pace) follows each reading instead of freezing through the
    /// cooldown. Conditions and messages spend nothing: a rule's one-shot or
    /// cooldown state is spent in its `didFire`, so a snapshot evaluated
    /// twice fires at most once.
    ///
    /// `canAlert` is false while the coach is muted or its alerts are off.
    /// A `.spoken` or `.haptic` rule then doesn't fire, keeping its cooldown
    /// and per-rule state for when its alert can be heard or felt.
    func evaluate(context: WorkoutAIContext, now: Date = Date(), canAlert: Bool = true) -> [Event] {
        var fired: [Event] = []
        for rule in rules where shouldFire(rule, context: context, now: now, canAlert: canAlert) {
            let event = Event(ruleID: rule.id, tier: rule.tier, urgency: rule.urgency, message: rule.message(context), firedAt: now)
            rule.didFire(context)
            fired.append(event)
            record(event)
            lastFired[rule.id] = now
        }
        return fired
    }

    /// The condition first, unconditionally (see `evaluate`), then the
    /// cooldown and whether an alert could be delivered.
    private func shouldFire(_ rule: Rule, context: WorkoutAIContext, now: Date, canAlert: Bool) -> Bool {
        let conditionHolds = rule.condition(context)
        if let last = lastFired[rule.id], now.timeIntervalSince(last) < rule.cooldown { return false }
        return conditionHolds && (canAlert || rule.tier == .silent)
    }

    /// Append to history, capped at the last 200 events. An ultramarathon can
    /// accumulate thousands of evaluations and the array is otherwise cleared
    /// only at workout end, so a 12-hour session would hold the entire log
    /// resident in memory.
    private func record(_ event: Event) {
        history.append(event)
        if history.count > 200 {
            history.removeFirst(history.count - 200)
        }
    }

    func reset() {
        lastFired.removeAll()
        history.removeAll()
        // Give every rule a chance to clean up its own
        // per-workout state. Stateful rules (streaks, once-per-workout
        // flags, per-threshold cooldowns) implement `resetWorkoutState`
        // to reset closure-captured counters; stateless rules use the
        // default no-op.
        for rule in rules {
            rule.resetWorkoutState()
        }
    }

    // MARK: - Default rule library
    //
    // Each default rule obeys the three contracts. Messages read like a
    // knowledgeable friend running alongside, not a fitness watch chirping
    // alerts. Cooldowns keep the coach quiet.
    // Split into groups rather than one function: 15 rules in one linear
    // block is a catalogue nobody can navigate.
    //
    // The rule ORDER matters:
    // `evaluate` walks `rules` in order and appends every rule that fires, so
    // the order of the returned array is the order events reach the coach.
    // Grouping is by what a reader would look for, not by an invented taxonomy.
    //
    // The catalogue cannot move to a resource file: every rule carries
    // `condition` and `message` closures, and those do not serialise.
    static func defaultRules(settings: @escaping @MainActor () -> UserSettings) -> [Rule] {
        effortRules() + terrainAndZoneRules() + equipmentAndProgressRules() + sessionNarrativeRules(settings: settings)
    }
}
