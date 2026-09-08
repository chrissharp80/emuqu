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
//      prevent repeat chatter. Tiers decide whether the output interrupts
//      audibly (spoken), sends a light wrist pulse (haptic), or is merely
//      logged to the post-session timeline (silent).
//
// The engine is a pure evaluator — it takes a context and returns any events
// that fire. The coach (WorkoutVoiceCoach) handles TTS/haptic dispatch.
@MainActor
final class WorkoutTriggerEngine {
    // MARK: Tier

    enum Tier: String {
        case silent    // logged only
        case haptic    // wrist pulse + logged
        case spoken    // audible + logged (message spoken verbatim)
        case aiSpoken  // message is a PROMPT — AI generates the line to speak
    }

    // MARK: Urgency
    //
    // Bug list item #8: "only genuine emergency-level
    // thresholds should interrupt" an active AI voice conversation.
    // `routine` triggers (drift, zone drift, climb-ahead) get DROPPED
    // when the AI is mid-conversation; `urgent` triggers (strap
    // dropped, user-declared threshold breach, intervals) still
    // preempt because the user explicitly opted into them.
    enum Urgency {
        case routine   // background coaching — suppress when AI is talking
        case urgent    // user-declared threshold / intervals / strap drop / SOS
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
        /// Optional per-workout state reset hook. Called
        /// from `WorkoutTriggerEngine.reset()` (which the recorder
        /// fires at workout start). Rules that hold closure-captured
        /// state across ticks (e.g. the mile-marker rule's
        /// `lastSplitFiredAt`) implement this to clean up between
        /// workouts. Default no-op for stateless rules.
        let resetWorkoutState: () -> Void

        init(
            id: String,
            tier: Tier,
            urgency: Urgency = .routine,
            cooldown: TimeInterval,
            condition: @escaping (WorkoutAIContext) -> Bool,
            message: @escaping (WorkoutAIContext) -> String,
            resetWorkoutState: @escaping () -> Void = {}
        ) {
            self.id = id
            self.tier = tier
            self.urgency = urgency
            self.cooldown = cooldown
            self.condition = condition
            self.message = message
            self.resetWorkoutState = resetWorkoutState
        }
    }

    // MARK: State

    private var lastFired: [String: Date] = [:]
    private(set) var history: [Event] = []
    private(set) var rules: [Rule]

    init(rules: [Rule]? = nil) {
        self.rules = rules ?? WorkoutTriggerEngine.defaultRules()
    }

    // MARK: Evaluate

    /// Evaluate all rules against the context, returning any events that
    /// should fire (respecting per-rule cooldowns).
    func evaluate(context: WorkoutAIContext, now: Date = Date()) -> [Event] {
        var fired: [Event] = []
        for rule in rules {
            if let last = lastFired[rule.id], now.timeIntervalSince(last) < rule.cooldown { continue }
            guard rule.condition(context) else { continue }
            let event = Event(ruleID: rule.id, tier: rule.tier, urgency: rule.urgency, message: rule.message(context), firedAt: now)
            fired.append(event)
            record(event)
            lastFired[rule.id] = now
        }
        return fired
    }

    /// Append to history, capped at the last 200 events. An ultramarathon can
    /// accumulate thousands of evaluations; the array was only cleared at
    /// workout end, so a 12-hour overnight session held the entire log
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
        // per-workout state. The mile-marker rule and any future
        // stateful rules implement `resetWorkoutState` to reset
        // closure-captured counters; stateless rules use the
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
    // Split into groups rather than one function. A declarative rule table
    // is data, not branching logic, and scattering one catalogue across several
    // functions could make the trigger set harder to read — but that argument
    // holds for the *rows* and not for the *table*: 17 rules in one linear
    // block is a catalogue nobody can navigate, and needs a SwiftLint
    // suppression for both body length and cyclomatic complexity.
    //
    // The rows are untouched and their ORDER is byte-identical, which matters:
    // `evaluate` walks `rules` in order and appends every rule that fires, so
    // the order of the returned array is the order events reach the coach.
    // Grouping is by what a reader would look for, not by an invented taxonomy.
    //
    // The catalogue cannot move to a resource file: every rule carries
    // `condition` and `message` closures, and those do not serialise.
    static func defaultRules() -> [Rule] {
        effortRules() + terrainAndZoneRules() + equipmentAndProgressRules() + sessionNarrativeRules()
    }
}
