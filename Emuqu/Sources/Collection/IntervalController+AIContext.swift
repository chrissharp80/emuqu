import Foundation

extension IntervalController {
    /// Snapshot the IntervalController's current state for the AI broker
    /// each tick. Returns nil when no plan is bound or the plan has
    /// finished (so the AI doesn't see a stale step from a prior plan).
    /// `nextStepLabel` peeks one ahead so the assistant can answer "what's
    /// after this?" without needing the whole plan.
    func liveProgressSnapshot() -> AssistantContext.LiveWorkoutSnapshot.IntervalProgressSnapshot? {
        guard let step = currentStep, !isFinished else { return nil }
        let stepLabel = step.intervalAILabel
        // The next step's label, or nil after the last step.
        let nextLabel: String? = peekNextStep()?.intervalAILabel
        let remaining: Int? = step.durationSec.map { max(0, $0 - stepElapsedSec) }
        return AssistantContext.LiveWorkoutSnapshot.IntervalProgressSnapshot(
            currentStepNumber: stepNumber,
            totalSteps: totalSteps,
            currentStepLabel: stepLabel,
            stepElapsedSec: stepElapsedSec,
            stepRemainingSec: remaining,
            nextStepLabel: nextLabel,
            isFinished: isFinished
        )
    }
}
