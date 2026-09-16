import SwiftUI

// Watch target entry point.
@main
struct WatchApp: App {
    // Use the process-wide `shared` singleton so background helpers
    // (e.g. `WatchStrapConnector` pushing direct-BLE HR samples) write
    // into the SAME instance the view tree is observing. Wrapping it
    // in `@StateObject` here gives SwiftUI ownership of the lifetime —
    // it's still the singleton object, just under SwiftUI's reference.
    @StateObject private var sessionManager = WatchSessionManager.shared
    @StateObject private var workoutManager = WatchWorkoutManager()
    /// The direct-BLE strap connector, owned here and handed to the view
    /// tree through the environment. This file is the Watch target's
    /// composition root: the only place a `.shared` instance is read.
    @StateObject private var strapConnector = WatchStrapConnector.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The connector publishes direct-strap heart rate into the session
        // manager; wire that here, before any view exists, so a sample can
        // never arrive with nowhere to go.
        WatchStrapConnector.shared.attach(sessionManager: WatchSessionManager.shared)
    }

    var body: some Scene {
        WindowGroup {
            WatchLiveView(sessionManager: sessionManager, workoutManager: workoutManager)
                .environmentObject(strapConnector)
                .onAppear { wireUp() }
                .onChange(of: scenePhase) { _, phase in followScenePhase(phase) }
        }
    }

    /// Reopening the Watch app mid-workout used to offer a NEW session.
    /// Returning to the foreground re-pulls the current state so the live one
    /// is restored instead.
    private func followScenePhase(_ phase: ScenePhase) {
        guard phase == .active else { return }
        sessionManager.requestCurrentStateFromPhone()
    }

    /// Wires the workout manager late, but deliberately does NOT re-activate
    /// WCSession: it was activated in `WatchSessionManager.init()`, and
    /// activating again opens a window where messages drop — the
    /// delegate-set-after-activate race behind "the first tap did nothing".
    ///
    /// HealthKit authorization is kicked off here so the first iOS-triggered
    /// `startWorkout` does not fail on an auth throw; the system prompt is
    /// gated and appears only the first time a workout needs it.
    ///
    /// The state pull restores a mid-workout session on relaunch, for the case
    /// where WCSession activated before this view appeared.
    private func wireUp() {
        sessionManager.attach(workoutManager: workoutManager)
        Task { await workoutManager.requestAuthorizationIfNeeded() }
        sessionManager.requestCurrentStateFromPhone()
    }
}
