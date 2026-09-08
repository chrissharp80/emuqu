import Combine
import Foundation
import UIKit

/// Single source of truth for power-state-aware behaviour decisions.
///
/// **The problem this fixes:** The user's wife had Low
/// Power Mode enabled on her iPhone 11 and reported that Emuqu
/// was draining her battery + slowing the device anytime the app was
/// foreground — not just during sessions. Other apps weren't doing
/// this. The launch path runs ~5 background tasks (archive
/// migrations, session-data repairs, training-metrics cache refresh,
/// CloudKit sync) every cold launch regardless of device state, and
/// CloudKit retries push live-backup uploads every minute when the
/// zone doesn't exist (her exact situation: 20 pending sessions
/// stuck in retry).
///
/// **What this provides:** a process-wide observer of
/// `ProcessInfo.processInfo.isLowPowerModeEnabled` that:
///   - Updates reactively via the system notification
///   - Exposes observable state for SwiftUI
///   - Gives callers a single `.shouldDeferBackgroundWork` boolean to
///     gate optional / non-session work behind
///
/// Callers (`EmuquApp.loadDataAndContinue`, `CloudKitSync*`,
/// `TrainingMetricsCache`, etc.) should check this BEFORE firing
/// non-essential work. Recording sessions (HRV, workouts) ignore this
/// — once the user explicitly starts a recording, we run it through to
/// completion.
@Observable
@MainActor
final class PowerStatePolicy {
    static let shared = PowerStatePolicy()

    /// True when iOS Low Power Mode is currently enabled. Mirrors
    /// `ProcessInfo.processInfo.isLowPowerModeEnabled`. Updated
    /// reactively via the system notification.
    private(set) var isLowPowerMode: Bool

    @ObservationIgnored private let observers = NotificationTokens()

    private init() {
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        observers.add(NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncLowPowerMode() }
        })
    }

    private func syncLowPowerMode() {
        let newValue = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard isLowPowerMode != newValue else { return }
        isLowPowerMode = newValue
    }

    deinit { observers.removeAll() }

    // MARK: - Decisions

    /// True when callers should skip / defer non-essential background
    /// work (CloudKit sync, training-metrics refresh, archive
    /// migrations, etc.). Active recording sessions ignore this.
    var shouldDeferBackgroundWork: Bool {
        isLowPowerMode
    }

    /// Multiplier to apply to launch-time task delays. Returns 1.0 in
    /// normal mode, 4.0 in Low Power Mode — pushing 4s tasks to 16s
    /// and 8s tasks to 32s. Lets the device finish whatever the user
    /// actually opened the app to do (read a number, tap something)
    /// before we hit the disk for housekeeping.
    var launchDelayMultiplier: Double {
        isLowPowerMode ? 4.0 : 1.0
    }

    /// True when periodic auto-refresh (training-metrics cache,
    /// CloudKit pull) should be skipped entirely. In Low Power Mode
    /// we only refresh on user-initiated actions (pull-to-refresh,
    /// tab switch, session end).
    var shouldSkipPeriodicRefresh: Bool {
        isLowPowerMode
    }
}
