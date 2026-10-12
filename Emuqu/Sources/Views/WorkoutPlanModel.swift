import Foundation
import Observation

// MARK: - WorkoutPlanModel
//
// State container for the Fitness tab's pre-flight ("Plan your
// workout") surface. **Owned by the Fitness tab root via `@State`** so
// the picker state survives every parent re-render — heroCard reload,
// archive change, sensor publish, you name it.
//
// **Why @Observable, not ObservableObject.** Apple's Observation
// framework (iOS 17+) gives per-property dependency tracking. A view
// that reads only `selectedSport` won't re-render when `selectedRoute`
// changes. With ObservableObject the whole subtree invalidates on every
// change. The research-recommended pattern is: one model per
// independently-evolving concern, observed at the field level.
//
// **Critical bug this design prevents.** The previous inline-Plan
// implementation kept its picker state as `@State` on the planning
// View struct. SwiftUI re-instantiates that struct any time the parent
// re-renders (which happens every time the hero card refreshes via
// `.task(id:)`), wiping picker state mid-flow. With state hoisted to
// an `@Observable` model owned by the tab root, the model survives
// every child re-instantiation. Sport pick + route bind + threshold
// list all stay put while the user is configuring.
//
// Injected into child views via `.environment(_:)` so they read with
// `@Environment(WorkoutPlanModel.self)`. No `@ObservedObject` chains.
@Observable
@MainActor
final class WorkoutPlanModel {
    // MARK: Sport
    var selectedSport: Sport = .walk

    // MARK: Route
    var selectedRoute: Route?
    /// Routes are a
    /// disclosure. Indoor sports never need them; most casual outdoor
    /// users use "just go" (record-as-you-walk + save-as-route at
    /// end) more than pre-pick. The preflight sets it when a route is
    /// picked, so the user sees their pick without a tap and can still
    /// collapse it.
    var routeExpanded: Bool = false

    // MARK: Coaching (collapsible advanced options)
    var coachingExpanded: Bool = false
    var selectedThresholds: [WorkoutThreshold] = []
    var selectedPlan: IntervalPlan?
    var selectedTargetZone: Int?

    // MARK: Sensor sheet
    /// Drives the strap-pill's tap target. A sheet for managing the
    /// Polar / foot pod / PM5 connections — never a gate, opened on
    /// demand when the user wants to fiddle with sensors.
    var sensorSheetPresented: Bool = false

    // MARK: - Resolution helpers

    /// HR source the next Start tap will use. There is no HR-source control:
    /// the strap when one is connected or paired (a paired one is
    /// reconnected in the background), else the Watch.
    func resolvedSource(strapConnected: Bool, hasKnownStrap: Bool) -> WorkoutRecorder.HRSource {
        strapConnected || hasKnownStrap ? .strap : .watch
    }

    /// True iff Start can fire right now: the recorder exists and is not
    /// recording or finalizing. The start runs synchronously and flips the
    /// phase to `.recording` before a second tap is handled, so the phase is
    /// the double-tap gate.
    func canStart(recorderPhase: WorkoutRecorder.Phase?) -> Bool {
        guard let phase = recorderPhase else { return false }
        switch phase {
        case .idle, .finished: return true
        case .failed: return true
        case .recording, .finalizing: return false
        }
    }

    /// Clears the picks that belong to one workout (route, interval plan,
    /// target zone, cues) once it has started, so the next workout from the
    /// tab starts from a clean plan. The sport stays.
    func clearPerWorkoutPicks() {
        selectedRoute = nil
        routeExpanded = false
        selectedPlan = nil
        selectedTargetZone = nil
        selectedThresholds = []
    }
}
