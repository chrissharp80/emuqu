import Foundation

// MARK: - Interval Plan
//
// A structured workout plan — a sequence of timed steps. Common patterns:
//   • 5× (3 min Z4, 2 min Z2)            → classic 5/3/2 threshold set
//   • 10 min warm-up Z2                  → pre-interval prep
//   • 4× (30s hard, 30s easy) × 2 blocks → 4×30/30 double
//
// The plan is a flat list of steps with an optional group-repeat structure.
// We intentionally keep this simple — one-dimensional repeats ("do this list
// N times") rather than nested tree-style structure. Scientific-training
// literature (Seiler's 80/20, Lucia polarized) covers 99% of real sessions
// with this shape.
//
// The `WorkoutRecorder` ticks through the plan's steps during the workout;
// the voice coach announces transitions via TTS. Stats per step are
// captured at finalize (avg HR, distance, pace) so the post-summary can
// show a per-interval breakdown next to the regular splits.

struct IntervalStep: Codable, Equatable, Identifiable {
    /// The step's index in the plan, so it is stable within one plan
    /// instance.
    var id: Int { index }
    let index: Int

    /// How long this step runs. Set exactly one of `durationSec` or
    /// `distanceMeters`; nothing enforces it, and a step with neither runs
    /// open-ended.
    let durationSec: Int?
    let distanceMeters: Double?

    /// What the user is aiming for during this step. Surfaced to the user
    /// ("Zone 3 tempo") and to the voice coach.
    enum Target: Codable, Equatable {
        case zone(Int)               // HR zone 1–5
        case hrRange(lo: Int, hi: Int) // explicit bpm range
        case paceSecPerKm(Int)       // exact pace target
        case effort(EffortCue)       // RPE-style cue ("easy", "hard")

        enum EffortCue: String, Codable { case recovery, easy, moderate, hard, allOut }
    }

    let target: Target
    /// Short label ("warm up", "interval", "cool down"). Stored in English;
    /// `displayLabel` is the on-screen and spoken form.
    let label: String
    /// Whether this step is a "work" step (counts in the training-stress
    /// tally) vs. "recovery" (does not, for session-level TRIMP weighting).
    /// Set explicitly by whoever builds the step; there is no default.
    let isWork: Bool

    /// `label` in the app's language when it is one of the preset labels;
    /// a label the user wrote is shown as written.
    var displayLabel: String {
        let b = LanguageManager.appBundle
        return switch label {
        case "warm up": String(localized: "warm up", bundle: b)
        case "aerobic base": String(localized: "aerobic base", bundle: b)
        case "cool down": String(localized: "cool down", bundle: b)
        case "interval": String(localized: "interval", bundle: b)
        case "recovery": String(localized: "recovery", bundle: b)
        case "easy": String(localized: "easy", bundle: b)
        case "hard": String(localized: "hard", bundle: b)
        case "rest": String(localized: "rest", bundle: b)
        default: label
        }
    }

    /// Human-readable "what is this step" string for AI consumption.
    /// Combines label + duration/distance + target into one phrase the
    /// assistant can read back verbatim. Examples:
    ///   "warm up — 5 min @ Zone 2"
    ///   "interval 3 of 5 — 800 m @ Zone 4"
    ///   "all out — 30 s @ hard effort"
    /// Used by `WorkoutRecorder.liveIntervalProgressSnapshot` and the
    /// `workout.live.interval.*` AI facts.
    var intervalAILabel: String {
        ([label] + amountPart + [targetPart]).joined(separator: " — ")
    }

    /// Duration if the interval is timed, else distance; empty when neither is
    /// set (an open-ended interval).
    private var amountPart: [String] {
        if let dur = durationSec {
            let mins = dur / 60
            let secs = dur % 60
            if mins > 0, secs == 0 { return ["\(mins) min"] }
            return mins > 0 ? ["\(mins) min \(secs) s"] : ["\(secs) s"]
        }
        guard let dist = distanceMeters else { return [] }
        return dist >= 1_000 ? [String(format: "%.1f km", dist / 1_000)] : ["\(Int(dist)) m"]
    }

    private var targetPart: String {
        switch target {
        case .zone(let z): "@ Zone \(z)"
        case .hrRange(let lo, let hi): "@ \(lo)–\(hi) bpm"
        case .paceSecPerKm(let p): String(format: "@ %d:%02d/km", p / 60, p % 60)
        case .effort(let e): "@ \(e.rawValue) effort"
        }
    }
}

struct IntervalPlan: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let steps: [IntervalStep]
    /// If set, the whole plan loops this many times. The voice coach
    /// announces "set 2 of 3" / etc.
    let repeatCount: Int

    var totalSteps: Int { steps.count * max(1, repeatCount) }

    /// `name` in the app's language for the presets; a user plan's name as
    /// written.
    var displayName: String {
        let b = LanguageManager.appBundle
        return switch name {
        case "Easy base (30 min Z2)": String(localized: "Easy base (30 min Z2)", bundle: b)
        case "5×3' tempo @ Z4": String(localized: "5×3' tempo @ Z4", bundle: b)
        case "4×30/30 VO₂ (2 sets)": String(localized: "4×30/30 VO₂ (2 sets)", bundle: b)
        default: name
        }
    }

    var estimatedDurationSec: Int {
        let perSet = steps.compactMap { $0.durationSec }.reduce(0, +)
        return perSet * max(1, repeatCount)
    }

    // MARK: - Presets

    /// Curated list of training plans the user can pick from without having
    /// to hand-author one. Drawn from standard running coach literature
    /// (Daniels, Seiler, Magness). Each preset's zones are keyed to the
    /// user's max HR via the normal HRZone math — the plan carries zone
    /// numbers, not bpm values, so it adapts to each user.
    /// Preset ids are fixed literals so a plan keeps its identity across
    /// launches and devices. `UUID(uuidString:)` is failable for a malformed
    /// string; trapping with the offending literal named beats a bare `!`,
    /// which would only report a `nil` unwrap.
    private static func presetID(_ raw: String) -> UUID {
        guard let id = UUID(uuidString: raw) else {
            preconditionFailure("IntervalPlan preset has a malformed UUID literal: \(raw)")
        }
        return id
    }

    static let presets: [IntervalPlan] = [
        IntervalPlan(
            id: Self.presetID("11111111-1111-1111-1111-111111111111"),
            name: "Easy base (30 min Z2)",
            steps: [
                IntervalStep(index: 0, durationSec: 5 * 60, distanceMeters: nil,
                             target: .zone(2), label: "warm up", isWork: false),
                IntervalStep(index: 1, durationSec: 20 * 60, distanceMeters: nil,
                             target: .zone(2), label: "aerobic base", isWork: true),
                IntervalStep(index: 2, durationSec: 5 * 60, distanceMeters: nil,
                             target: .zone(1), label: "cool down", isWork: false)
            ],
            repeatCount: 1
        ),
        IntervalPlan(
            id: Self.presetID("22222222-2222-2222-2222-222222222222"),
            name: "5×3' tempo @ Z4",
            steps: [
                IntervalStep(index: 0, durationSec: 10 * 60, distanceMeters: nil,
                             target: .zone(2), label: "warm up", isWork: false),
                IntervalStep(index: 1, durationSec: 3 * 60, distanceMeters: nil,
                             target: .zone(4), label: "interval", isWork: true),
                IntervalStep(index: 2, durationSec: 2 * 60, distanceMeters: nil,
                             target: .zone(2), label: "recovery", isWork: false),
                IntervalStep(index: 3, durationSec: 3 * 60, distanceMeters: nil,
                             target: .zone(4), label: "interval", isWork: true),
                IntervalStep(index: 4, durationSec: 2 * 60, distanceMeters: nil,
                             target: .zone(2), label: "recovery", isWork: false),
                IntervalStep(index: 5, durationSec: 3 * 60, distanceMeters: nil,
                             target: .zone(4), label: "interval", isWork: true),
                IntervalStep(index: 6, durationSec: 2 * 60, distanceMeters: nil,
                             target: .zone(2), label: "recovery", isWork: false),
                IntervalStep(index: 7, durationSec: 3 * 60, distanceMeters: nil,
                             target: .zone(4), label: "interval", isWork: true),
                IntervalStep(index: 8, durationSec: 2 * 60, distanceMeters: nil,
                             target: .zone(2), label: "recovery", isWork: false),
                IntervalStep(index: 9, durationSec: 3 * 60, distanceMeters: nil,
                             target: .zone(4), label: "interval", isWork: true),
                IntervalStep(index: 10, durationSec: 5 * 60, distanceMeters: nil,
                             target: .zone(2), label: "cool down", isWork: false)
            ],
            repeatCount: 1
        ),
        IntervalPlan(
            id: Self.presetID("33333333-3333-3333-3333-333333333333"),
            name: "4×30/30 VO₂ (2 sets)",
            steps: [
                IntervalStep(index: 0, durationSec: 10 * 60, distanceMeters: nil,
                             target: .zone(2), label: "warm up", isWork: false),
                IntervalStep(index: 1, durationSec: 30, distanceMeters: nil,
                             target: .zone(5), label: "hard", isWork: true),
                IntervalStep(index: 2, durationSec: 30, distanceMeters: nil,
                             target: .zone(2), label: "easy", isWork: false),
                IntervalStep(index: 3, durationSec: 30, distanceMeters: nil,
                             target: .zone(5), label: "hard", isWork: true),
                IntervalStep(index: 4, durationSec: 30, distanceMeters: nil,
                             target: .zone(2), label: "easy", isWork: false),
                IntervalStep(index: 5, durationSec: 30, distanceMeters: nil,
                             target: .zone(5), label: "hard", isWork: true),
                IntervalStep(index: 6, durationSec: 30, distanceMeters: nil,
                             target: .zone(2), label: "easy", isWork: false),
                IntervalStep(index: 7, durationSec: 30, distanceMeters: nil,
                             target: .zone(5), label: "hard", isWork: true),
                IntervalStep(index: 8, durationSec: 3 * 60, distanceMeters: nil,
                             target: .zone(1), label: "rest", isWork: false)
            ],
            repeatCount: 2
        )
    ]
}
