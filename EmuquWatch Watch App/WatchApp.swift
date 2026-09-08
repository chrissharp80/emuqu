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
            WatchLiveView(
                sessionManager: sessionManager,
                workoutManager: workoutManager
            )
            .environmentObject(strapConnector)
            .onAppear {
                // Wire the workout manager late, but DON'T (re)activate
                // WCSession here. The session was already activated in
                // WatchSessionManager.init() — re-activating creates a
                // window where messages drop. The bug user complaints
                // mapping to "first tap on the watch did nothing" came
                // from delegate-set-after-activate races at .onAppear.
                sessionManager.attach(workoutManager: workoutManager)
                // Kick off HK authorization so the first iOS-triggered
                // startWorkout doesn't fail with an auth throw. The
                // system prompt is gated and only appears the first
                // time the user starts a workout that needs it.
                Task { await workoutManager.requestAuthorizationIfNeeded() }
                // If the WCSession activated before this view
                // appeared, the activation-time state pull already ran; if
                // not, ask now. Restores a mid-workout session on relaunch.
                sessionManager.requestCurrentStateFromPhone()
            }
            .onChange(of: scenePhase) { _, phase in
                // The user's core complaint was reopening the
                // Watch app mid-workout and being offered a NEW session.
                // Every time we return to the foreground, re-pull the current
                // state so the live session is restored instead.
                if phase == .active {
                    sessionManager.requestCurrentStateFromPhone()
                }
            }
        }
    }
}
