import Combine
@preconcurrency import CoreBluetooth
import Foundation
import os
import WatchConnectivity

// Direct Bluetooth Heart Rate Service connection from the Apple Watch.
//
// Architecture so far put iOS in charge of the Polar strap (PolarBleSdk
// only ships for iOS / macOS), and the Watch only mirrored iOS's
// connection state via WCSession. That breaks the moment the iPhone is
// out of range, in another room, or its app got terminated — the
// Watch's "strap" pill went stale and live HR vanished.
//
// `WatchStrapConnector` gives the Watch its own first-class BLE central
// using CoreBluetooth + the standard Bluetooth Heart Rate Service
// (UUID 180D, characteristic 2A37). Polar H10, Polar Verity Sense, and
// virtually every other chest strap or arm band on the market broadcast
// this profile, including RR-Interval values when the user's hardware
// supports them — so we can drive HRV-grade metrics on the wrist
// without depending on the Polar SDK.
//
// Design notes
// ------------
//   • Single CBCentralManager per process (`shared`). watchOS allows
//     multiple but you'd just be paying double the radio cost.
//   • Last-paired peripheral identifier persists in UserDefaults so
//     the Watch reconnects automatically on app launch — the user
//     pairs once, then it just works.
//   • Live HR + RR are pushed via WCSession back to iOS as
//     `watchStrapSample` messages so the iPhone-side recorder can
//     fold them in as a fallback when its own BLE path is empty.
//   • Permission state is exposed to the UI via `connectionState` so
//     the user gets a clear "Bluetooth off / not authorised / scanning
//     / connecting / connected" pill instead of a silent failure.
//   • BLE in watchOS background is intentionally left to the system —
//     we don't ask for `bluetooth-central` background mode, and we
//     stop scanning aggressively when the app backgrounds. Continuous
//     background BLE on the wrist is a battery sink the user will
//     notice; the live channel runs while the app is foreground or
//     during an active workout (workout-processing background mode).
@MainActor
final class WatchStrapConnector: NSObject, ObservableObject {
    static let shared = WatchStrapConnector()

    /// The session manager that receives direct-strap heart rate. Set once
    /// by `WatchApp.init()`, the Watch target's composition root, before any
    /// view exists; the connector does not reach for a singleton itself.
    private weak var sessionManager: WatchSessionManager?

    // MARK: - Published UI state

    enum ConnectionState: Equatable {
        case idle
        /// Waiting for `centralManager.state` to settle before any
        /// scan / connect attempts can run.
        case waitingForBluetooth
        case unauthorized
        case poweredOff
        case scanning
        case connecting(deviceName: String)
        case connected(deviceName: String)
        case disconnected(reason: String?)
    }

    @Published private(set) var connectionState: ConnectionState = .waitingForBluetooth

    /// Devices seen during the current scan, keyed by peripheral
    /// identifier so duplicate `didDiscover` callbacks (which fire
    /// repeatedly per advertisement) don't add multiple rows.
    @Published private(set) var discovered: [DiscoveredDevice] = []

    struct DiscoveredDevice: Identifiable, Equatable {
        let id: UUID            // peripheral.identifier
        let name: String
        var rssi: Int
    }

    /// Most recent HR sample from the connected peripheral.
    @Published private(set) var liveHeartRate: Int?
    /// Most recent RR-interval batch from a HR Measurement notification,
    /// in milliseconds. The H10 typically emits 1–2 RR per notification
    /// (each notification represents one measurement window).
    @Published private(set) var lastRRMillis: [Double] = []
    /// Battery level from the standard Battery Service (180F / 2A19),
    /// percent 0–100. nil until we've successfully read it once.
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var lastError: String?

    // MARK: - Private state

    private let log = Logger(subsystem: "com.chrissharp.flowrecovery", category: "WatchStrapConnector")

    /// Not `CBCentralManager!`. A `let` cannot work here
    /// (the manager needs `self` as its delegate, so it can only be built after
    /// `super.init()`), and an implicitly-unwrapped optional is the crash the
    /// SwiftLint rule exists to prevent. `lazy` gives a non-optional property;
    /// `init` touches it immediately so the manager is still created eagerly
    /// and the Bluetooth power-state callback arrives at exactly the same
    /// moment it did before.
    private lazy var central = CBCentralManager(delegate: self, queue: nil)
    private var connectedPeripheral: CBPeripheral?
    private var hrCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?

    // Standard Bluetooth GATT UUIDs.
    // https://www.bluetooth.com/specifications/assigned-numbers/
    //
    // Kept as nonisolated static String constants
    // (CBUUID is non-Sendable and the whole class is @MainActor, which
    // collided with the CoreBluetooth delegate callbacks reading these
    // from a nonisolated context — Swift 6 strict-concurrency error).
    // Strings are Sendable; CBUUID is reconstructed at point of use, which
    // is essentially free.
    nonisolated static let heartRateServiceUUIDString = "180D"
    nonisolated static let heartRateMeasurementUUIDString = "2A37"
    nonisolated static let batteryServiceUUIDString = "180F"
    nonisolated static let batteryLevelUUIDString = "2A19"

    nonisolated private static var heartRateServiceUUID: CBUUID { CBUUID(string: heartRateServiceUUIDString) }
    nonisolated private static var heartRateMeasurementUUID: CBUUID { CBUUID(string: heartRateMeasurementUUIDString) }
    nonisolated private static var batteryServiceUUID: CBUUID { CBUUID(string: batteryServiceUUIDString) }
    nonisolated private static var batteryLevelUUID: CBUUID { CBUUID(string: batteryLevelUUIDString) }

    /// UserDefaults key for the last-paired peripheral identifier.
    /// Persisted as a String (UUID's UUIDString form). On launch we ask
    /// CoreBluetooth for that peripheral via
    /// `retrievePeripherals(withIdentifiers:)` and reconnect without a
    /// scan.
    private let savedPeripheralKey = "WatchStrapConnector.savedPeripheralIdentifier"

    /// Optional rolling-RR buffer maintained by the WCSession bridge
    /// for the rare moment the iPhone's PolarManager hands its strap
    /// over to the Watch. Each entry is one RR in ms.
    private var samplesPendingForwarding: [(date: Date, rr: Double)] = []
    private let maxBufferedSamples = 2_000
    private var lastForwardAt: Date?

    /// True when the user tapped "Pair" but Bluetooth wasn't ready
    /// yet (state still `.unknown`, or the system was still settling
    /// after init). Causes `centralManagerDidUpdateState` to start
    /// scanning automatically once state reaches `.poweredOn`. Without
    /// this, the user's tap dropped on the floor and nothing visible
    /// happened ("couldn't tell refresh did anything").
    private var pendingScanRequest = false

    override private init() {
        super.init()
        // `nil` queue == main. We're @MainActor so the delegate
        // callbacks line up without an extra hop. Touching `central` here
        // keeps creation eager — see the property.
        _ = central
    }

    // MARK: - Public API

    /// Begin scanning for peripherals advertising the Heart Rate
    /// Service. If a previously-paired peripheral is known, we attempt
    /// to reconnect to that one first (no scan needed); only if that
    /// fails do we fall through to discovery.
    /// Clears the list and moves to a visibly active state first, whatever the
    /// radio is doing: a tap that changes nothing on screen reads as a tap that
    /// did not register. If Bluetooth is not ready the scan is deferred and
    /// resumed from `centralManagerDidUpdateState`.
    func startScanning() {
        discovered = []
        guard central.state == .poweredOn else {
            log.info("[WatchStrap] startScanning: BT state=\(self.stateString(self.central.state)) — deferring scan, will retry when poweredOn")
            connectionState = mapBluetoothState(central.state)
            pendingScanRequest = true
            return
        }
        pendingScanRequest = false
        if let known = savedPeripheral() {
            log.info("[WatchStrap] startScanning: reusing saved peripheral \(known.identifier.uuidString)")
            connect(to: known)
            return
        }
        connectionState = .scanning
        beginDiscovery()
    }

    /// The strap this Watch paired with last, if the system still knows it.
    private func savedPeripheral() -> CBPeripheral? {
        guard let savedID = UserDefaults.standard.string(forKey: savedPeripheralKey),
              let uuid = UUID(uuidString: savedID)
        else { return nil }
        return central.retrievePeripherals(withIdentifiers: [uuid]).first
    }

    /// Scans with NO service filter, deliberately.
    ///
    /// Filtering on `heartRateServiceUUID` (180D) silently excludes peripherals
    /// that do not advertise the service in their advertisement packet — the
    /// Polar H10 in particular often advertises only its name and manufacturer
    /// data and does not expose 180D until after connection, so the picker
    /// stayed empty with the strap on the wrist. The filtering happens in
    /// `didDiscover` instead, against both the advertised services AND the
    /// device name, which catches the straps that expose 180D as well as the
    /// name-stamped Polar gear that does not.
    ///
    /// `allowDuplicates` lets RSSI update as the strap moves closer, so the
    /// list can be sorted by signal and the user can tell which "Polar H10" in
    /// a busy household is theirs.
    private func beginDiscovery() {
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func stopScanning() {
        if central.isScanning { central.stopScan() }
        if case .scanning = connectionState { connectionState = .idle }
    }

    /// Connect to a specific peripheral, typically the one the user
    /// picked from the discovered list.
    func connect(to peripheral: CBPeripheral) {
        if central.isScanning { central.stopScan() }
        connectedPeripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting(deviceName: peripheral.name ?? "Heart Rate Sensor")
        central.connect(peripheral, options: nil)
    }

    /// Convenience wrapper used by the watch-side picker UI.
    func connect(to device: DiscoveredDevice) {
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [device.id]).first else {
            log.warning("[WatchStrap] connect(to: device) — peripheral disappeared from BT cache")
            return
        }
        connect(to: peripheral)
    }

    /// Drop the current connection AND clear the saved-peripheral
    /// preference so we don't auto-reconnect on next launch. Used by
    /// the "Forget Strap" button.
    func disconnectAndForget() {
        UserDefaults.standard.removeObject(forKey: savedPeripheralKey)
        if let p = connectedPeripheral {
            central.cancelPeripheralConnection(p)
        }
        connectedPeripheral = nil
        hrCharacteristic = nil
        batteryCharacteristic = nil
        liveHeartRate = nil
        lastRRMillis = []
        batteryPercent = nil
        connectionState = .idle
    }

    /// Disconnect but preserve the saved-peripheral preference so the
    /// app reconnects on next launch.
    func disconnect() {
        if let p = connectedPeripheral {
            central.cancelPeripheralConnection(p)
        }
    }

    // MARK: - Helpers

    private func mapBluetoothState(_ state: CBManagerState) -> ConnectionState {
        switch state {
        case .poweredOn: return .idle
        case .poweredOff: return .poweredOff
        case .unauthorized: return .unauthorized
        case .resetting, .unknown: return .waitingForBluetooth
        case .unsupported: return .unauthorized
        @unknown default: return .waitingForBluetooth
        }
    }

    private func stateString(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .unauthorized: return "unauthorized"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unknown: return "unknown"
        @unknown default: return "default"
        }
    }

    /// Parse a Heart Rate Measurement (characteristic 2A37) packet per
    /// the Bluetooth GATT spec. Returns the HR plus any RR intervals
    /// present in the same notification (in milliseconds).
    ///
    /// Layout
    ///   • byte 0  : flags
    ///       bit 0 : HR value format       (0 = uint8, 1 = uint16)
    ///       bit 4 : RR-Interval Bit       (0 = no RR, 1 = RR follows)
    ///   • bytes 1–N: HR value             (1 or 2 bytes per flag bit 0)
    ///   • optional: Energy Expended       (2 bytes if flag bit 3 set)
    ///   • optional: RR-Intervals          (2 bytes each, little-endian,
    ///                                     1/1024 second units)
    /// Pure parser — no actor isolation so the nonisolated
    /// CBPeripheralDelegate callback can call it without hopping.
    nonisolated static /// Bluetooth Heart Rate Measurement (0x2A37), per the SIG spec: a flags
    /// byte, then an 8- or 16-bit rate, then optional energy and RR fields.
    func parseHeartRateMeasurement(_ data: Data) -> (hr: Int, rrMillis: [Double])? {
        guard let flags = data.first else { return nil }
        var cursor = 1
        guard let hrValue = Self.readHeartRate(data, cursor: &cursor, wide: flags & 0b0000_0001 != 0) else {
            return nil
        }
        if flags & 0b0000_1000 != 0 {
            cursor += 2 // energy expended, unused
            guard data.count >= cursor else { return (hrValue, []) }
        }
        guard flags & 0b0001_0000 != 0 else { return (hrValue, []) }
        return (hrValue, Self.readRRIntervals(data, from: cursor))
    }

    nonisolated private static func readHeartRate(_ data: Data, cursor: inout Int, wide: Bool) -> Int? {
        let width = wide ? 2 : 1
        guard data.count >= cursor + width else { return nil }
        let value = wide
            ? Int(data[cursor]) | (Int(data[cursor + 1]) << 8)
            : Int(data[cursor])
        cursor += width
        return value
    }

    /// 16-bit little-endian, in units of 1/1024 s — hence the 1000/1024
    /// conversion to milliseconds.
    nonisolated private static func readRRIntervals(_ data: Data, from start: Int) -> [Double] {
        var cursor = start
        var rrMillis: [Double] = []
        while cursor + 1 < data.count {
            let raw = Int(data[cursor]) | (Int(data[cursor + 1]) << 8)
            rrMillis.append(Double(raw) * 1000.0 / 1024.0)
            cursor += 2
        }
        return rrMillis
    }
}

// MARK: - CBCentralManagerDelegate

extension WatchStrapConnector: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            let mapped = self.mapBluetoothState(state)
            self.connectionState = mapped
            self.log.info("[WatchStrap] central state changed → \(self.stateString(state))")
            if state == .poweredOn {
                // Highest priority: if a saved peripheral exists,
                // auto-reconnect (no scan needed). Covers app cold
                // launch + Control-Centre BT toggle.
                if let saved = UserDefaults.standard.string(forKey: self.savedPeripheralKey),
                   let uuid = UUID(uuidString: saved),
                   let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
                    self.log.info("[WatchStrap] BT poweredOn — auto-reconnecting to \(known.identifier.uuidString)")
                    self.connect(to: known)
                    return
                }
                // No saved peripheral, but the user already requested
                // a scan (e.g. tapped Pair before BT was ready) —
                // fire it now so their tap doesn't end up a no-op.
                if self.pendingScanRequest {
                    self.log.info("[WatchStrap] BT poweredOn — running deferred scan request")
                    self.startScanning()
                }
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Post-filter discovered peripherals so we keep
        // the open scan (necessary for Polar gear that doesn't
        // advertise 180D in the advert packet) but still hide random
        // BLE noise. A peripheral counts as a heart-rate sensor if
        // EITHER:
        //   • Its advertisement-data service-UUID list contains 180D, OR
        //   • Its name suggests an HR sensor the SDK supports.
        let advertisedUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let advertisesHeartRate = advertisedUUIDs.contains(Self.heartRateServiceUUID)

        let rawName = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? ""
        let lowercasedName = rawName.lowercased()
        let nameLooksLikeHR = lowercasedName.contains("polar")
            || lowercasedName.contains("h10")
            || lowercasedName.contains("h9")
            || lowercasedName.contains("verity")
            || lowercasedName.contains("oh1")
            || lowercasedName.contains("wahoo")
            || lowercasedName.contains("tickr")
            || lowercasedName.contains("hrm")
            || lowercasedName.contains("heart")

        guard advertisesHeartRate || nameLooksLikeHR else { return }

        let id = peripheral.identifier
        let name = rawName.isEmpty ? "Heart Rate Sensor" : rawName
        let rssi = RSSI.intValue
        Task { @MainActor in
            if let idx = self.discovered.firstIndex(where: { $0.id == id }) {
                self.discovered[idx].rssi = rssi
                // Keep the strongest-signal name we've seen so a
                // later advert packet that lacks the local name can't
                // overwrite the "Polar H10 12345678" we already had.
                if !rawName.isEmpty, self.discovered[idx].name == "Heart Rate Sensor" {
                    self.discovered[idx] = DiscoveredDevice(id: id, name: name, rssi: rssi)
                }
            } else {
                self.discovered.append(DiscoveredDevice(id: id, name: name, rssi: rssi))
            }
            // Sort by RSSI descending so the closest strap appears
            // at the top of the picker — the household-gear case
            // where two H10s are nearby and the user wants the one
            // they're wearing.
            self.discovered.sort { $0.rssi > $1.rssi }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        let name = peripheral.name ?? "Heart Rate Sensor"
        Task { @MainActor in
            self.log.info("[WatchStrap] connected \(id.uuidString) (\(name))")
            UserDefaults.standard.set(id.uuidString, forKey: self.savedPeripheralKey)
            self.connectionState = .connected(deviceName: name)
            // Discover the two services we use. Specifying the array
            // (instead of nil) keeps the discovery payload tiny — the
            // strap exposes a dozen services we don't care about.
            peripheral.discoverServices([Self.heartRateServiceUUID, Self.batteryServiceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let detail = error?.localizedDescription ?? "unknown"
        Task { @MainActor in
            self.log.warning("[WatchStrap] failed to connect: \(detail)")
            self.connectionState = .disconnected(reason: detail)
            self.lastError = detail
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let detail = error?.localizedDescription
        Task { @MainActor in
            self.log.info("[WatchStrap] disconnected: \(detail ?? "no error")")
            self.connectionState = .disconnected(reason: detail)
            self.connectedPeripheral = nil
            self.hrCharacteristic = nil
            self.batteryCharacteristic = nil
            // Auto-reconnect attempt — the strap may have just stepped
            // out of range briefly. CoreBluetooth's `connect` waits
            // forever (no scan needed) so this is safe.
            if UserDefaults.standard.string(forKey: self.savedPeripheralKey) != nil {
                central.connect(peripheral, options: nil)
                self.connectionState = .connecting(deviceName: peripheral.name ?? "Heart Rate Sensor")
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension WatchStrapConnector: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        let hrSvc = services.first { $0.uuid == Self.heartRateServiceUUID }
        let batSvc = services.first { $0.uuid == Self.batteryServiceUUID }
        if let hrSvc {
            peripheral.discoverCharacteristics([Self.heartRateMeasurementUUID], for: hrSvc)
        }
        if let batSvc {
            peripheral.discoverCharacteristics([Self.batteryLevelUUID], for: batSvc)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil, let chars = service.characteristics else { return }
        for char in chars {
            if char.uuid == Self.heartRateMeasurementUUID {
                Task { @MainActor in self.hrCharacteristic = char }
                peripheral.setNotifyValue(true, for: char)
            } else if char.uuid == Self.batteryLevelUUID {
                Task { @MainActor in self.batteryCharacteristic = char }
                peripheral.readValue(for: char)
                peripheral.setNotifyValue(true, for: char)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        if characteristic.uuid == Self.heartRateMeasurementUUID {
            guard let parsed = WatchStrapConnector.parseHeartRateMeasurement(data) else { return }
            Task { @MainActor in
                self.liveHeartRate = parsed.hr
                self.lastRRMillis = parsed.rrMillis
                self.publishToWatchSession(hr: parsed.hr, rrMillis: parsed.rrMillis)
                self.forwardSampleToiPhone(hr: parsed.hr, rrMillis: parsed.rrMillis)
            }
        } else if characteristic.uuid == Self.batteryLevelUUID {
            guard let byte = data.first else { return }
            Task { @MainActor in
                self.batteryPercent = Int(byte)
            }
        }
    }
}

// MARK: - Bridge to WatchSessionManager + iPhone

extension WatchStrapConnector {
    /// Mirror the live HR + RR onto WatchSessionManager so the existing
    /// Watch UI (status pill, big-HR display) reflects whichever source
    /// is producing the freshest data — the iPhone-pushed mirror, OR
    /// our direct strap connection here. We update the same
    /// @Published properties WatchSessionManager already exposes; the
    /// "watch-direct strap connected" flag below tells the UI which
    /// took priority.
    @MainActor
    private func publishToWatchSession(hr: Int, rrMillis _: [Double]) {
        sessionManager?.applyDirectStrapHR(hr)
    }

    func attach(sessionManager: WatchSessionManager) {
        self.sessionManager = sessionManager
    }

    /// Forward the sample to the paired iPhone over WCSession so the
    /// iPhone-side recorder can fold it into a workout when its own
    /// PolarManager isn't holding the strap (e.g. the user paired the
    /// strap to the Watch instead of the phone, or they're out for a
    /// walk with the phone left at home).
    ///
    /// Not unconditionally firing BOTH `sendMessage` and
    /// `transferUserInfo` on every beat: iPhone-side handlers would overwrite
    /// the same field twice and we'd pay for double WCSession traffic
    /// (60+ msgs per minute per channel). Instead: prefer `sendMessage`
    /// when reachable, fall back to `transferUserInfo` only when the
    /// live channel is unavailable or the send errors out. Halves
    /// WCSession load without losing samples.
    @MainActor
    private func forwardSampleToiPhone(hr: Int, rrMillis: [Double]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        let payload: [String: Any] = [
            "type": "watchStrapSample",
            "hr": hr,
            "rrMillis": rrMillis,
            "ts": Date().timeIntervalSince1970
        ]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in
                // Live channel failed — queue via transferUserInfo so
                // the sample isn't lost. Captured weakly because the
                // connector may have torn down by the time the error
                // callback fires.
                Task { @MainActor in
                    guard WCSession.isSupported() else { return }
                    let s = WCSession.default
                    guard s.activationState == .activated else { return }
                    s.transferUserInfo(payload)
                }
            }
        } else {
            session.transferUserInfo(payload)
        }
    }
}
