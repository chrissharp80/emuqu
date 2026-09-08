import Foundation

// MARK: - Interval Controller
//
// Runs an `IntervalPlan` alongside a live workout. Driven by per-second ticks
// from `WorkoutRecorder.incrementalBackupTick`. Tracks the current step
// (flattened across repeats), decides when to advance, and emits transitions
// via a callback so the voice coach + UI can announce them ("next: 3 min
// threshold, Zone 4").
//
// Deliberately separate from WorkoutRecorder so the interval logic is easy
// to test in isolation. Owns only the plan + cursor; the recorder is the
// source of truth for elapsed time and HR.

@Observable

@MainActor
final class IntervalController {
    // MARK: - Published state

    /// 0-based index into the FLATTENED step list (plan.steps × repeatCount).
    /// Nil when no plan is active.
    private(set) var currentStepIndex: Int?
    /// Time since the current step began (monotonic increment while the
    /// plan is active; resets on step advance).
    private(set) var stepElapsedSec: Int = 0
    /// True once the last step of the last repeat has finished.
    private(set) var isFinished: Bool = false

    // MARK: - Private

    private var plan: IntervalPlan?
    /// Flattened step list — repeats materialised for easy indexing.
    private var flatSteps: [IntervalStep] = []
    private var stepStartAt: Date?
    /// Transition hook — fired with the NEW step whenever we advance.
    /// Upstream (WorkoutRecorder) wires this to the voice coach so each
    /// transition gets a gentle spoken cue.
    var onStepChange: ((IntervalStep, _ stepOf: Int, _ totalSteps: Int) -> Void)?
    /// Plan-complete hook — called once when the last step finishes.
    var onFinish: (() -> Void)?

    // MARK: - Public

    /// Attach a plan and cue the first step. Idempotent: calling with the
    /// same plan twice just resets the cursor.
    func load(plan: IntervalPlan, startAt: Date = Date()) {
        self.plan = plan
        flatSteps = []
        for _ in 0 ..< max(1, plan.repeatCount) {
            flatSteps.append(contentsOf: plan.steps)
        }
        currentStepIndex = flatSteps.isEmpty ? nil : 0
        stepElapsedSec = 0
        stepStartAt = startAt
        isFinished = false
        if let first = flatSteps.first {
            onStepChange?(first, 1, flatSteps.count)
        }
    }

    /// Clear the plan — call when the workout stops or the user cancels.
    func clear() {
        plan = nil
        flatSteps = []
        currentStepIndex = nil
        stepElapsedSec = 0
        stepStartAt = nil
        isFinished = false
    }

    /// Per-second tick from the recorder. Decides whether to advance the step.
    /// Returns the active step so the recorder can feed it into the voice
    /// coach's context for zone-drift rules.
    @discardableResult
    func tick(totalDistanceMeters: Double = 0) -> IntervalStep? {
        guard !isFinished, let idx = currentStepIndex, idx < flatSteps.count else { return nil }
        let step = flatSteps[idx]
        let now = Date()
        if let startAt = stepStartAt {
            stepElapsedSec = Int(now.timeIntervalSince(startAt))
        }
        if Self.isComplete(step, elapsedSec: stepElapsedSec, totalDistanceMeters: totalDistanceMeters) {
            advance(at: now)
        }
        return currentStep
    }

    /// A step ends on whichever of duration or distance it declares; a step
    /// with neither never self-completes (the user advances it).
    private static func isComplete(_ step: IntervalStep, elapsedSec: Int, totalDistanceMeters: Double) -> Bool {
        if let dur = step.durationSec { return elapsedSec >= dur }
        if let dist = step.distanceMeters { return totalDistanceMeters >= dist }
        return false
    }

    /// User-tapped "skip" — advance immediately.
    func skip() {
        advance(at: Date())
    }

    // MARK: - Derived

    var currentStep: IntervalStep? {
        guard let idx = currentStepIndex, idx < flatSteps.count else { return nil }
        return flatSteps[idx]
    }

    /// 1-based step number for UI display.
    var stepNumber: Int { (currentStepIndex ?? 0) + 1 }
    var totalSteps: Int { flatSteps.count }

    /// Peek at the step that comes after the current one without
    /// advancing. Used by the AI broker to surface "next: 3 min @ Z4"
    /// in the live snapshot. Returns nil on the final step.
    func peekNextStep() -> IntervalStep? {
        guard let idx = currentStepIndex else { return nil }
        let next = idx + 1
        guard next < flatSteps.count else { return nil }
        return flatSteps[next]
    }

    /// Fraction of current step that has elapsed (0...1). For duration-based
    /// steps. Distance-based steps need the recorder's distance too; the
    /// view layer supplies that separately.
    var stepProgress: Double {
        guard let step = currentStep, let dur = step.durationSec, dur > 0 else { return 0 }
        return min(1.0, Double(stepElapsedSec) / Double(dur))
    }

    // MARK: - Private

    private func advance(at date: Date) {
        guard let idx = currentStepIndex else { return }
        let next = idx + 1
        if next >= flatSteps.count {
            isFinished = true
            currentStepIndex = nil
            stepElapsedSec = 0
            stepStartAt = nil
            onFinish?()
            return
        }
        currentStepIndex = next
        stepElapsedSec = 0
        stepStartAt = date
        let step = flatSteps[next]
        onStepChange?(step, next + 1, flatSteps.count)
    }
}
