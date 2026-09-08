// `@preconcurrency`: CMPedometerData predates Sendable.
@preconcurrency import CoreMotion
import Foundation

// MARK: - Pedometer History Importer
//
// Reads the iPhone's onboard motion-coprocessor step history (up to ~7 days)
// and surfaces it as a list of passive-activity summaries. Useful when the
// user first installs the app and wants credit for the walking they've
// already been doing, and as a gentle "walking activity" sidebar in the
// Fitness tab even when they weren't explicitly recording a workout.
//
// Not an HKWorkout — these aren't recorded workouts. They're passive step
// summaries bucketed by day. They appear in Fitness history as separate
// entries marked "passive" so they don't get confused with explicit
// strap-recorded sessions.
//
// CMPedometer data is on-device; no network, no HealthKit required.
enum PedometerHistoryImporter {
    struct DailySteps: Identifiable, Equatable, Sendable {
        let date: Date
        let stepCount: Int
        let distanceMeters: Double
        let floorsAscended: Int
        let floorsDescended: Int

        var id: Date { date }
    }

    /// Reads up to `days` worth of daily step summaries (max 7 — iOS only
    /// stores ~7 days of motion history on-device). Returns most-recent first.
    ///
    /// Each day is queried separately: `CMPedometer.queryPedometerData`
    /// aggregates across the whole range, so per-day totals require iteration.
    static func importRecent(days: Int = 7) async -> [DailySteps] {
        guard CMPedometer.isStepCountingAvailable() else { return [] }
        let pedometer = CMPedometer()
        let calendar = Calendar.current
        let now = Date()
        var out: [DailySteps] = []
        for offset in 0 ..< min(days, 7) {
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) else { continue }
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
            // Don't query into the future.
            if let steps = await queryPedometerData(pedometer: pedometer, from: dayStart, to: min(dayEnd, now)) {
                out.append(steps)
            }
        }
        return out
    }

    private static func reduced(_ data: CMPedometerData?, dayStart: Date) -> DailySteps? {
        data.map { dailySteps($0, dayStart: dayStart) }
    }

    private static func dailySteps(_ data: CMPedometerData, dayStart: Date) -> DailySteps {
        DailySteps(
            date: dayStart,
            stepCount: data.numberOfSteps.intValue,
            distanceMeters: data.distance?.doubleValue ?? 0,
            floorsAscended: data.floorsAscended?.intValue ?? 0,
            floorsDescended: data.floorsDescended?.intValue ?? 0
        )
    }

    /// Resumes with the already-reduced `DailySteps` because `CMPedometerData`
    /// is not `Sendable` and must not cross out of the pedometer's callback.
    ///
    /// `@Sendable` on the handler states the isolation rather than inheriting
    /// it. This enum is nonisolated today, so the closure is nonisolated either
    /// way — but if it ever gains `@MainActor`, an inherited-isolation handler
    /// would assert the main queue on CoreMotion's own worker thread, and
    /// libdispatch answers a failed queue assertion with `__builtin_trap()`.
    /// That is not hypothetical: it is what `WorkoutPedometer` did, and it cost
    /// a user a whole recorded walk.
    private static func queryPedometerData(pedometer: CMPedometer, from: Date, to: Date) async -> DailySteps? {
        await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: from, to: to) { @Sendable data, _ in
                continuation.resume(returning: Self.reduced(data, dayStart: from))
            }
        }
    }
}
