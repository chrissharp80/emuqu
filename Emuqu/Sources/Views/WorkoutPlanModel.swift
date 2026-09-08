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
    /// True when `selectedRoute` came from the "Discover" tab so we
    /// know to save it to the user's library on workout start. Routes
    /// the user picked from "My Routes" are already saved.
    var routeNeedsSaveToLibrary: Bool = false
    /// Routes are a
    /// disclosure. Indoor sports never need them; most casual outdoor
    /// users use "just go" (record-as-you-walk + save-as-route at
    /// end) more than pre-pick. Auto-expands when a route is already
    /// selected so the user sees their pick without a tap.
    var routeExpanded: Bool = false

    // MARK: Coaching (collapsible advanced options)
    var coachingExpanded: Bool = false
    var selectedThresholds: [WorkoutThreshold] = []
    var selectedPlan: IntervalPlan?
    var selectedTargetZone: Int?

    // MARK: HR Source
    /// User's explicit pick (if any). When nil, the tab resolves a
    /// sensible default at Start time based on what's connected
    /// (strap if paired+connected, else Watch).
    var explicitHRSource: WorkoutRecorder.HRSource?

    // MARK: Sensor sheet
    /// Drives the strap-pill's tap target. A sheet for managing the
    /// Polar / foot pod / PM5 connections — never a gate, opened on
    /// demand when the user wants to fiddle with sensors.
    var sensorSheetPresented: Bool = false

    // MARK: Start sequence
    /// True from the moment the user taps Start until either the
    /// recorder.phase has flipped to .recording OR the start failed.
    /// Gates the Start button so a second tap during the
    /// connect-and-start sequence can't fire `recorder.start()` twice.
    var startInProgress: Bool = false
    /// Live label shown on the Start button during the start sequence
    /// — "Connecting H10…", "Starting…", etc.
    var startProgressLabel: String = ""

    // MARK: - Resolution helpers

    /// HR source the next Start tap will actually use. Resolves the
    /// explicit pick if set, else falls back to the smart default.
    func resolvedSource(strapConnected: Bool, hasKnownStrap: Bool) -> WorkoutRecorder.HRSource {
        if let explicit = explicitHRSource { return explicit }
        if strapConnected { return .strap }
        if hasKnownStrap { return .strap }  // will trigger reconnect
        return .watch
    }

    /// True iff Start can fire right now (not already starting).
    func canStart(recorderPhase: WorkoutRecorder.Phase?) -> Bool {
        guard !startInProgress else { return false }
        guard let phase = recorderPhase else { return false }
        switch phase {
        case .idle, .finished: return true
        case .failed: return true
        case .recording, .finalizing: return false
        }
    }
}
