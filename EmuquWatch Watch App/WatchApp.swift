import SwiftUI
import WatchKit

// Watch target entry point.
@main
struct WatchApp: App {
    // Both objects come from the Watch target's composition root,
    // `WatchDependencies`. Background helpers (`WatchStrapConnector` pushing
    // direct-BLE HR samples) write into the SAME session manager the view
    // tree observes; `@StateObject` gives SwiftUI ownership of the lifetime
    // of that one object.
    @StateObject private var sessionManager = WatchDependencies.current.sessionManager
    /// Owns the workout manager (see `WatchAppDelegate`).
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    /// The direct-BLE strap connector, handed to the view tree through the
    /// environment.
    @StateObject private var strapConnector = WatchDependencies.current.strapConnector
    @Environment(\.scenePhase) private var scenePhase

    private var workoutManager: WatchWorkoutManager { appDelegate.workoutManager }

    init() {
        // The connector publishes direct-strap heart rate into the session
        // manager; wire that here, before any view exists, so a sample can
        // never arrive with nowhere to go.
        let dependencies = WatchDependencies.current
        dependencies.strapConnector.attach(sessionManager: dependencies.sessionManager)
    }

    var body: some Scene {
        WindowGroup {
            WatchLiveView(sessionManager: sessionManager, workoutManager: workoutManager)
                .environmentObject(strapConnector)
                .onAppear { wireUp() }
                .onChange(of: scenePhase) { _, phase in followScenePhase(phase) }
                // The wrist reconnects a saved strap only when the iPhone does
                // not own it (legacy mode).
                .onChange(of: sessionManager.displayOnlyMode, initial: true) { _, displayOnly in
                    strapConnector.setAutoReconnect(!displayOnly)
                }
        }
    }

    /// Returning to the foreground re-pulls the current state so reopening the
    /// Watch app mid-workout restores the live session rather than offering a
    /// new one (a pull already in flight from launch answers it).
    /// Going to the background ends any strap discovery scan: continuous
    /// background BLE on the wrist is a battery sink.
    private func followScenePhase(_ phase: ScenePhase) {
        if phase == .background { strapConnector.appDidEnterBackground() }
        guard phase == .active else { return }
        sessionManager.requestCurrentStateFromPhone()
    }

    /// Wires the workout manager late, but deliberately does NOT re-activate
    /// WCSession: it was activated in `WatchSessionManager.init()`, and
    /// activating again opens a window where messages drop — the
    /// delegate-set-after-activate race behind "the first tap did nothing".
    ///
    /// HealthKit authorization is asked for here, on the first launch, because
    /// a workout the iPhone starts arrives while the Watch app may not be on
    /// screen to show the prompt, and a workout session cannot begin without
    /// it. The Watch app exists to run those workouts.
    ///
    /// The state pull restores a mid-workout session on relaunch, for the case
    /// where WCSession activated before this view appeared.
    ///
    /// The workout manager follows the iPhone's messages so it can end its
    /// session when the iPhone app goes silent mid-workout.
    private func wireUp() {
        sessionManager.attach(workoutManager: workoutManager)
        workoutManager.followPhoneMessages(of: sessionManager)
        Task { await workoutManager.requestAuthorizationIfNeeded() }
        sessionManager.requestCurrentStateFromPhone()
    }
}

/// The app delegate, for the one thing only a delegate is told: watchOS
/// relaunched the app to hand back a workout session that was running when
/// the app was ended (a crash, memory pressure).
///
/// It owns the workout manager rather than `WatchApp` because that relaunch
/// can happen in the background, before any view exists, and the recovered
/// session has to reach the same manager the views and the session manager
/// use afterwards.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    let workoutManager = WatchWorkoutManager()

    func handleActiveWorkoutRecovery() {
        workoutManager.recoverActiveSession()
    }
}
