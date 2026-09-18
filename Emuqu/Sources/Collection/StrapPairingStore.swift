import Foundation

/// Where Polar pairings and the last-connected timestamp live, and how they got
/// there.
///
/// Its own type because `PolarManager` is over the aggregate type-size
/// threshold and none of this needs the manager: it is a `UserDefaults`
/// location, a codable list, and two forward migrations.
///
/// The location matters. Pairings sit in the App Group suite so a reinstall
/// does not force the user to re-pair; reads fall back to the legacy
/// `.standard` store and migrate across, and below that to the oldest
/// single-device-id format, so an install from any era upgrades in place
/// rather than losing its strap.
enum StrapPairingStore {
    private static let knownDevicesKey = UserDefaultsKeys.knownDevices
    private static let lastConnectedTimeKey = UserDefaultsKeys.lastConnectedTime
    private static var defaults: UserDefaults { SharedUserDefaults.appGroup }

    /// Most recent first, and never listed twice.
    static func adding(_ device: PolarManager.KnownDevice, to devices: [PolarManager.KnownDevice]) -> [PolarManager.KnownDevice] {
        var devices = devices
        devices.removeAll { $0.id == device.id }
        devices.insert(device, at: 0)
        return devices
    }

    /// App Group first, then the legacy `.standard` store (migrated forward),
    /// then the oldest single-device-id format.
    static func load() -> [PolarManager.KnownDevice] {
        if let devices = decode(defaults.data(forKey: knownDevicesKey), source: "suite") {
            return devices
        }
        if let data = UserDefaults.standard.data(forKey: knownDevicesKey),
           let devices = decode(data, source: "legacy") {
            defaults.set(data, forKey: knownDevicesKey)
            debugLog("[StrapPairing] Migrated knownDevices from .standard → App Group")
            return devices
        }
        guard let oldId = UserDefaults.standard.string(forKey: UserDefaultsKeys.legacyLastDeviceId) else {
            return []
        }
        let migrated = [PolarManager.KnownDevice(id: oldId, name: "Polar \(oldId)", deviceType: .h10)]
        save(migrated)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.legacyLastDeviceId)
        return migrated
    }

    static func save(_ devices: [PolarManager.KnownDevice]) {
        do {
            defaults.set(try JSONEncoder().encode(devices), forKey: knownDevicesKey)
        } catch {
            debugLog("[StrapPairing] Failed to encode known devices: \(error)")
        }
    }

    static func loadLastConnectedTime() -> Date? {
        var interval = defaults.double(forKey: lastConnectedTimeKey)
        if interval == 0 {
            interval = UserDefaults.standard.double(forKey: lastConnectedTimeKey)
            if interval > 0 { defaults.set(interval, forKey: lastConnectedTimeKey) }
        }
        return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
    }

    static func saveLastConnectedTime(_ time: Date) {
        defaults.set(time.timeIntervalSince1970, forKey: lastConnectedTimeKey)
    }

    /// Every pairing, in every place one has been kept — for the UI tests'
    /// fresh-install reset, which must start with no strap paired.
    static func removeAll() {
        for store in [defaults, UserDefaults.standard] {
            store.removeObject(forKey: knownDevicesKey)
            store.removeObject(forKey: lastConnectedTimeKey)
        }
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.legacyLastDeviceId)
    }

    private static func decode(_ data: Data?, source: String) -> [PolarManager.KnownDevice]? {
        guard let data else { return nil }
        do {
            return try JSONDecoder().decode([PolarManager.KnownDevice].self, from: data)
        } catch {
            debugLog("[StrapPairing] Failed to decode known devices (\(source)): \(error)")
            return nil
        }
    }
}
