import Foundation

/// How much recording the strap has done since it last reported a NEW battery
/// percentage, and whether the displayed percentage is still believable.
///
/// Its own type because `PolarManager` is over the aggregate type-size
/// threshold and this is a self-contained concern: three counters, their
/// per-device persistence, and one rule for reading them. It touches no BLE
/// and makes no async call.
///
/// Holds the manager strongly and is built on demand by it, the shape
/// `check_no_unowned.sh` requires: a value with no stored state of its own
/// cannot outlive what it points at and cannot form a cycle. The counters stay
/// on the manager, which is where they were and where the observable state
/// belongs; only the rules for reading and updating them moved here.
@MainActor
struct StrapBatteryUsageTracker {
    let manager: PolarManager

    //
    // Polar straps push BLE Battery Service notifications only on CHANGE. An
    // H10 sat at "100%" can stay at "100%" for weeks while the cell silently
    // discharges. Wall-clock heuristics ("stale after 6 hours") are useless
    // for a user who exercises with the strap intermittently — and outright
    // wrong for a user who uses the strap with multiple apps so we can't even
    // see most of the load.
    //
    // What we CAN do is count the recording hours we've put on the strap
    // SINCE the last time the device-reported value actually changed. That's
    // a strict lower bound on consumed runtime: if the device said "85%" four
    // weeks ago and we've recorded 47 h since (and the user has done other
    // workouts we don't see), we're a long way past 85% — flag the reading.
    //
    // Persisted per device ID so swapping straps (his + hers, or two H10s)
    // doesn't cross-contaminate the counters.

    // The counters live on the manager. `batteryLastReportedValue` is kept
    // apart from `batteryLevel` so a callback repeating the SAME value (which
    // doesn't reset the counter) is told from one with a NEW value (which
    // does). `batteryLastChangedAt` advances only on a changed value, unlike
    // `lastBatteryUpdateTime`, which every callback moves — Polar sometimes
    // re-emits the same value on connect. `hoursRecordedSinceBatteryChanged`
    // goes back to 0 when a new value arrives.

    private static let usagePrefix = "polar.batteryUsage."

    private static func usageKey(_ component: String, deviceId: String) -> String {
        "\(usagePrefix)\(component).\(deviceId)"
    }

    /// Restore persisted battery-usage state for a freshly-connected device.
    /// Called from the `deviceConnected` observer. Per-device keying lets
    /// users alternate between multiple straps without losing each one's
    /// counter.
    @MainActor
    func loadState(for deviceId: String) {
        let defaults = UserDefaults.standard
        let storedValue = defaults.object(forKey: Self.usageKey("value", deviceId: deviceId)) as? Int
        let storedAt = defaults.object(forKey: Self.usageKey("changedAt", deviceId: deviceId)) as? Date
        let storedHours = defaults.double(forKey: Self.usageKey("hours", deviceId: deviceId))
        manager.batteryLastReportedValue = storedValue
        manager.batteryLastChangedAt = storedAt
        manager.hoursRecordedSinceBatteryChanged = max(0, storedHours)
    }

    private func persist(for deviceId: String) {
        let defaults = UserDefaults.standard
        if let v = manager.batteryLastReportedValue {
            defaults.set(v, forKey: Self.usageKey("value", deviceId: deviceId))
        }
        if let at = manager.batteryLastChangedAt {
            defaults.set(at, forKey: Self.usageKey("changedAt", deviceId: deviceId))
        }
        defaults.set(manager.hoursRecordedSinceBatteryChanged, forKey: Self.usageKey("hours", deviceId: deviceId))
    }

    /// Add recorded time to the running counter. Call from session-end paths
    /// (overnight stop, workout stop, quick reading stop, etc.) with the
    /// number of hours the strap was actively delivering data. Persists
    /// after each call so a crash doesn't lose the count.
    @MainActor
    func recordRecordingHours(_ hours: Double) {
        guard hours > 0, hours < 48 else { return } // sanity bound: > 48h = telemetry bug
        guard let deviceId = manager.connectedDeviceId else { return }
        manager.hoursRecordedSinceBatteryChanged += hours
        persist(for: deviceId)
        recomputeStaleness()
    }

    /// Compare cumulative recording hours against the device's spec runtime
    /// to decide whether the displayed % is plausible. Anything past 70 % of
    /// spec without a fresh device-reported change is flagged.
    @MainActor
    func recomputeStaleness() {
        guard manager.batteryLevel != nil, let deviceType = manager.connectedDeviceType else {
            manager.isBatteryReadingStale = false
            return
        }
        let spec = deviceType.specRecordingHours
        guard spec > 0 else { return }
        // 70 % of spec — gives a comfortable margin while still raising the
        // flag well before the user wakes up to a dead strap.
        manager.isBatteryReadingStale = manager.hoursRecordedSinceBatteryChanged > spec * 0.7
    }

    /// The recording-hours counter resets only when the device reports a
    /// value DIFFERENT from the last one we recorded. Polar emits the
    /// current value on connect even if nothing changed — those callbacks
    /// tell us the link is alive but nothing about discharge progress.
    @MainActor
    func applyLevelUpdate(from identifier: String, batteryLevel: UInt) {
        guard manager.isActiveDeviceInfoSource(identifier) else { return }
        let normalizedLevel = Int(batteryLevel)
        guard (0 ... 100).contains(normalizedLevel) else {
            debugLog("[StrapBattery] Ignoring invalid battery callback \(batteryLevel) for \(identifier)")
            return
        }
        debugLog("[PolarManager] Battery callback: \(normalizedLevel)% for \(identifier)")
        manager.batteryLevel = normalizedLevel
        manager.lastBatteryUpdateTime = Date()
        if manager.batteryLastReportedValue != normalizedLevel {
            manager.batteryLastReportedValue = normalizedLevel
            manager.batteryLastChangedAt = Date()
            manager.hoursRecordedSinceBatteryChanged = 0
        }
        persist(for: identifier)
        recomputeStaleness()
    }
}
