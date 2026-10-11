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
//     the Watch reconnects it on app launch — only while auto-reconnect
//     is on (legacy mode, where the wrist owns the strap). In
//     display-only mode, the default, the iPhone owns the strap and the
//     saved one is left alone.
//   • Live HR + RR are pushed via WCSession back to iOS as
//     `watchStrapSample` messages so the iPhone-side recorder can
//     fold them in as a fallback when its own BLE path is empty.
//   • Permission state is exposed to the UI via `connectionState` so
//     the user gets a clear "Bluetooth off / not authorised / scanning
//     / connecting / connected" pill instead of a silent failure.
//   • BLE in watchOS background is intentionally left to the system —
//     we don't ask for `bluetooth-central` background mode. Discovery
//     scans run only while the pairing screen is open (it stops them on
//     disappear, and a scan still waiting for the radio is dropped with
//     it) and never in the background (`appDidEnterBackground`).
//     Continuous background BLE on the wrist is a battery
//     sink the user will notice; the live channel runs while the app is
//     foreground or during an active workout (workout-processing
//     background mode).
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

    // MARK: - Private state

    private let log = Logger(subsystem: "com.chrissharp.flowrecovery", category: "WatchStrapConnector")

    /// Not `CBCentralManager!`. A `let` cannot work here
    /// (the manager needs `self` as its delegate, so it can only be built after
    /// `super.init()`), and an implicitly-unwrapped optional is the crash the
    /// SwiftLint rule exists to prevent. `lazy` gives a non-optional property,
    /// and creating the manager is what puts the Bluetooth permission prompt
    /// on screen, so `init` creates it only for a strap already paired; the
    /// pairing screen creates it otherwise.
    private lazy var central = CBCentralManager(delegate: self, queue: nil)
    private var connectedPeripheral: CBPeripheral?

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

    /// The saved strap's identifier, mirrored from `savedPeripheralKey` so a
    /// view reading `hasSavedStrap` re-renders when a strap is saved or
    /// forgotten. Written only through `rememberStrap` and `forgetSavedStrap`.
    @Published private var savedStrapIdentifier: String?

    /// Whether a saved strap may be reconnected automatically (on launch,
    /// when Bluetooth comes up, after a drop). Off while the iPhone owns the
    /// strap (display-only mode, the default until the phone says otherwise),
    /// so a strap paired in legacy mode is not held from the wrist alongside
    /// the phone. Set by `WatchSessionManager` from each mode push.
    private(set) var autoReconnectEnabled = false

    /// Name shown for a sensor that does not advertise one.
    nonisolated static var genericSensorName: String { String(localized: "Heart Rate Sensor") }

    /// True when the user tapped "Pair" but Bluetooth wasn't ready
    /// yet (state still `.unknown`, or the system was still settling
    /// after init). Causes `centralManagerDidUpdateState` to start
    /// scanning automatically once state reaches `.poweredOn`. Without
    /// this, the user's tap dropped on the floor and nothing visible
    /// happened ("couldn't tell refresh did anything").
    private var pendingScanRequest = false

    override private init() {
        super.init()
        savedStrapIdentifier = UserDefaults.standard.string(forKey: savedPeripheralKey)
        // `nil` queue == main. We're @MainActor so the delegate
        // callbacks line up without an extra hop. A paired strap is
        // reconnected as soon as the radio comes up, so its manager starts
        // now; without one, launching the app is no reason to ask for
        // Bluetooth.
        if savedStrapIdentifier != nil {
            _ = central
        }
    }

    // MARK: - Public API

    /// Begin scanning for peripherals advertising the Heart Rate
    /// Service. If a previously-paired peripheral is known and
    /// auto-reconnect is on, we reconnect to that one instead (no scan
    /// needed). With auto-reconnect off (the iPhone owns the strap) the
    /// saved strap is left alone, so opening the screen only to forget it
    /// does not take the strap from the phone.
    /// Clears the list and moves to a visibly active state first, whatever the
    /// radio is doing: a tap that changes nothing on screen reads as a tap that
    /// did not register. If Bluetooth is not ready the scan is deferred and
    /// resumed from `centralManagerDidUpdateState`. A strap already connected
    /// is left as it is, with no scan: the screen shows the live link, and
    /// "Searching…" over a streaming strap would say the opposite.
    func startScanning() {
        discovered = []
        guard central.state == .poweredOn else { return deferScan() }
        pendingScanRequest = false
        let resting = restingState()
        if case .connected = resting {
            connectionState = resting
            return
        }
        if autoReconnectEnabled, let known = savedPeripheral() {
            log.info("[WatchStrap] startScanning: reusing saved peripheral \(known.identifier.uuidString)")
            connect(to: known)
            return
        }
        connectionState = .scanning
        beginDiscovery()
    }

    /// Bluetooth is not ready: show why, and run the scan once it is
    /// (`radioCameUp`).
    private func deferScan() {
        log.info("[WatchStrap] startScanning: BT state=\(self.stateString(self.central.state)) — deferring scan, will retry when poweredOn")
        connectionState = mapBluetoothState(central.state)
        pendingScanRequest = true
    }

    /// The strap this Watch paired with last, if the system still knows it.
    private func savedPeripheral() -> CBPeripheral? {
        guard let savedID = savedStrapIdentifier, let uuid = UUID(uuidString: savedID) else { return nil }
        return central.retrievePeripherals(withIdentifiers: [uuid]).first
    }

    /// What the header says when no scan is running: the live link, a connect
    /// still pending, or idle.
    private func restingState() -> ConnectionState {
        guard let peripheral = connectedPeripheral else { return .idle }
        let name = peripheral.name ?? Self.genericSensorName
        switch peripheral.state {
        case .connected: return .connected(deviceName: name)
        case .connecting: return .connecting(deviceName: name)
        case .disconnected, .disconnecting: return .idle
        @unknown default: return .idle
        }
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

    /// Ends discovery (the pairing screen went away), and drops a scan still
    /// waiting for Bluetooth so none starts later with no screen to stop it.
    /// The header goes back to the link's own state, not to idle over a
    /// connected strap.
    func stopScanning() {
        pendingScanRequest = false
        if central.isScanning { central.stopScan() }
        if case .scanning = connectionState { connectionState = restingState() }
    }

    /// The Watch app left the foreground: no discovery scan runs in the
    /// background, and none waits for the radio. Touches the Bluetooth
    /// manager only when a scan is running, so it never raises the Bluetooth
    /// permission prompt for a user who never opened the pairing screen.
    func appDidEnterBackground() {
        pendingScanRequest = false
        guard case .scanning = connectionState else { return }
        stopScanning()
    }

    /// Connect to a specific peripheral, typically the one the user
    /// picked from the discovered list.
    ///
    /// Already connected to it: the state is restated, not reissued, so the
    /// header does not fall back to "Connecting" while HR streams. A pending
    /// or live link to a different strap is cancelled first, so two straps
    /// never feed beats at once.
    func connect(to peripheral: CBPeripheral) {
        if central.isScanning { central.stopScan() }
        let name = peripheral.name ?? Self.genericSensorName
        if let current = connectedPeripheral, current.identifier == peripheral.identifier,
           current.state == .connected {
            connectionState = .connected(deviceName: name)
            return
        }
        if let other = connectedPeripheral, other.identifier != peripheral.identifier {
            connectedPeripheral = nil
            central.cancelPeripheralConnection(other)
        }
        connectedPeripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting(deviceName: name)
        central.connect(peripheral, options: nil)
    }

    /// True when a strap has been paired and not forgotten, connected or not.
    /// Published through `savedStrapIdentifier`, so the Start screen's pairing
    /// row appears and disappears as a strap is saved or forgotten.
    var hasSavedStrap: Bool {
        savedStrapIdentifier != nil
    }

    private func rememberStrap(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: savedPeripheralKey)
        savedStrapIdentifier = id.uuidString
    }

    private func forgetSavedStrap() {
        UserDefaults.standard.removeObject(forKey: savedPeripheralKey)
        savedStrapIdentifier = nil
    }

    /// Refresh from the pairing screen: always a discovery scan, even with a
    /// saved strap. A pending reconnect to a strap that is lost, dead or
    /// replaced never completes, so it is cancelled (the strap stays saved)
    /// rather than left on "Connecting…" forever.
    func rescan() {
        discovered = []
        guard central.state == .poweredOn else {
            connectionState = mapBluetoothState(central.state)
            pendingScanRequest = true
            return
        }
        pendingScanRequest = false
        if case .connecting = connectionState, let pending = connectedPeripheral {
            connectedPeripheral = nil
            central.cancelPeripheralConnection(pending)
        }
        connectionState = .scanning
        beginDiscovery()
    }

    /// Follows the phone's mode: off in display-only mode drops any wrist
    /// link (the strap stays saved), on reconnects the saved strap.
    func setAutoReconnect(_ enabled: Bool) {
        guard enabled != autoReconnectEnabled else { return }
        autoReconnectEnabled = enabled
        if enabled {
            if hasSavedStrap, central.state == .poweredOn { radioCameUp() }
        } else {
            disconnect()
        }
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
    /// the "Forget Strap" button, which also shows beside a running
    /// discovery scan: that scan carries on (the user is likely looking for
    /// another strap), and the header keeps saying so.
    func disconnectAndForget() {
        forgetSavedStrap()
        if let p = connectedPeripheral {
            central.cancelPeripheralConnection(p)
        }
        connectedPeripheral = nil
        clearLiveReadings()
        if connectionState != .scanning { connectionState = .idle }
    }

    /// The last strap's readings, which must not be shown as a newly
    /// connected strap's.
    private func clearLiveReadings() {
        liveHeartRate = nil
        lastRRMillis = []
        batteryPercent = nil
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
}

// MARK: - CBCentralManagerDelegate

extension WatchStrapConnector: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            // Powered on, the header keeps a live or pending link's state
            // rather than reading idle over it.
            self.connectionState = state == .poweredOn ? self.restingState() : self.mapBluetoothState(state)
            self.log.info("[WatchStrap] central state changed → \(self.stateString(state))")
            guard state == .poweredOn else { return }
            self.radioCameUp()
        }
    }

    /// Bluetooth is available again: reconnect the saved strap (when
    /// auto-reconnect is on), or run a scan the user asked for before the
    /// radio was ready so their tap is not a no-op. Covers a cold launch and
    /// a Control-Centre Bluetooth toggle.
    @MainActor
    private func radioCameUp() {
        if autoReconnectEnabled, let known = savedPeripheral() {
            log.info("[WatchStrap] BT poweredOn — auto-reconnecting to \(known.identifier.uuidString)")
            connect(to: known)
            return
        }
        guard pendingScanRequest else { return }
        log.info("[WatchStrap] BT poweredOn — running deferred scan request")
        startScanning()
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
        let rawName = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? ""
        guard Self.looksLikeHeartRateSensor(advertisementData: advertisementData, name: rawName) else { return }

        let device = DiscoveredDevice(
            id: peripheral.identifier,
            name: rawName.isEmpty ? Self.genericSensorName : rawName,
            rssi: RSSI.intValue
        )
        let named = !rawName.isEmpty
        Task { @MainActor in self.noteDiscovered(device, carriesName: named) }
    }

    /// A peripheral counts as a heart-rate sensor when its advertisement lists
    /// the heart-rate service, or its name is one of the sensors this app
    /// supports. The scan itself stays open, because Polar gear does not always
    /// advertise 180D in the advert packet.
    nonisolated private static func looksLikeHeartRateSensor(
        advertisementData: [String: Any], name: String
    ) -> Bool {
        let advertisedUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        if advertisedUUIDs.contains(heartRateServiceUUID) { return true }
        let lowercased = name.lowercased()
        return ["polar", "h10", "h9", "verity", "oh1", "wahoo", "tickr", "hrm", "heart"]
            .contains { lowercased.contains($0) }
    }

    /// Strongest signal first, so the closest strap tops the picker — the
    /// household case of two H10s nearby and the user wearing one of them.
    ///
    /// A later advert packet without the local name must not overwrite the
    /// "Polar H10 12345678" already shown.
    @MainActor
    private func noteDiscovered(_ device: DiscoveredDevice, carriesName: Bool) {
        if let idx = discovered.firstIndex(where: { $0.id == device.id }) {
            discovered[idx].rssi = device.rssi
            if carriesName, discovered[idx].name == Self.genericSensorName { discovered[idx] = device }
        } else {
            discovered.append(device)
        }
        discovered.sort { $0.rssi > $1.rssi }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        let name = peripheral.name ?? Self.genericSensorName
        Task { @MainActor in self.didConnect(peripheral, id: id, name: name, central: central) }
    }

    /// A connect that completes for a strap no longer wanted (the user picked
    /// another, or forgot it) is dropped rather than adopted.
    @MainActor
    private func didConnect(_ peripheral: CBPeripheral, id: UUID, name: String, central: CBCentralManager) {
        guard connectedPeripheral?.identifier == id else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        log.info("[WatchStrap] connected \(id.uuidString) (\(name))")
        rememberStrap(id)
        connectionState = .connected(deviceName: name)
        // Discover the two services we use. Specifying the array
        // (instead of nil) keeps the discovery payload tiny — the
        // strap exposes a dozen services we don't care about.
        peripheral.discoverServices([Self.heartRateServiceUUID, Self.batteryServiceUUID])
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let detail = error?.localizedDescription
        let id = peripheral.identifier
        Task { @MainActor in
            self.log.warning("[WatchStrap] failed to connect: \(detail ?? "no error")")
            guard self.connectedPeripheral?.identifier == id else { return }
            self.connectedPeripheral = nil
            self.connectionState = .disconnected(reason: detail)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let detail = error?.localizedDescription
        Task { @MainActor in self.handleDisconnect(peripheral, central: central, detail: detail) }
    }

    /// Auto-reconnect after a drop — the strap may have just stepped out of
    /// range briefly, and CoreBluetooth's `connect` waits without a scan. Not
    /// when the user has moved on to a discovery scan (`rescan` cancels the
    /// pending link) or auto-reconnect is off. A strap this connector already
    /// let go of (replaced, forgotten, or cancelled by a rescan) is ignored:
    /// its disconnect says nothing about the current link. The dropped
    /// strap's last readings are cleared, so a reconnect — or another strap —
    /// does not show them as its own.
    @MainActor
    private func handleDisconnect(_ peripheral: CBPeripheral, central: CBCentralManager, detail: String?) {
        log.info("[WatchStrap] disconnected: \(detail ?? "no error")")
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        connectedPeripheral = nil
        clearLiveReadings()
        guard connectionState != .scanning else { return }
        connectionState = .disconnected(reason: detail)
        guard autoReconnectEnabled, hasSavedStrap else { return }
        connectedPeripheral = peripheral
        central.connect(peripheral, options: nil)
        connectionState = .connecting(deviceName: peripheral.name ?? Self.genericSensorName)
    }
}

// MARK: - CBPeripheralDelegate

extension WatchStrapConnector: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        guard error == nil, let hrSvc = services.first(where: { $0.uuid == Self.heartRateServiceUUID }) else {
            let reason = error?.localizedDescription
            Task { @MainActor in self.noHeartRateService(peripheral, reason: reason) }
            return
        }
        peripheral.discoverCharacteristics([Self.heartRateMeasurementUUID], for: hrSvc)
        if let batSvc = services.first(where: { $0.uuid == Self.batteryServiceUUID }) {
            peripheral.discoverCharacteristics([Self.batteryLevelUUID], for: batSvc)
        }
    }

    /// The strap connected but will give no heart rate: service discovery
    /// failed (`reason`), or it has no Heart Rate Service. Left alone it would
    /// show as a connected strap that never streams. The link is dropped and
    /// the header says why; a device with no Heart Rate Service is also
    /// forgotten, so it is not reconnected on the next launch.
    @MainActor
    private func noHeartRateService(_ peripheral: CBPeripheral, reason: String?) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        connectedPeripheral = nil
        central.cancelPeripheralConnection(peripheral)
        if reason == nil, savedStrapIdentifier == peripheral.identifier.uuidString { forgetSavedStrap() }
        connectionState = .disconnected(reason: reason ?? String(localized: "No heart rate from strap"))
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil, let chars = service.characteristics else { return }
        for char in chars { subscribe(peripheral, to: char) }
    }

    /// Heart rate notifies; battery is read once and then notifies.
    nonisolated private func subscribe(_ peripheral: CBPeripheral, to char: CBCharacteristic) {
        switch char.uuid {
        case Self.heartRateMeasurementUUID:
            peripheral.setNotifyValue(true, for: char)
        case Self.batteryLevelUUID:
            peripheral.readValue(for: char)
            peripheral.setNotifyValue(true, for: char)
        default:
            break
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        let id = peripheral.identifier
        if characteristic.uuid == Self.heartRateMeasurementUUID {
            guard let measurement = WatchMessageDecoding.strapMeasurement(data) else { return }
            Task { @MainActor in self.publishBeat(measurement, from: id) }
        } else if characteristic.uuid == Self.batteryLevelUUID {
            guard let byte = data.first else { return }
            Task { @MainActor in self.noteBattery(Int(byte), from: id) }
        }
    }

    /// Only the current strap's battery: a value already queued from a strap
    /// just replaced or forgotten is dropped.
    @MainActor
    private func noteBattery(_ percent: Int, from id: UUID) {
        guard connectedPeripheral?.identifier == id else { return }
        batteryPercent = percent
    }
}

// MARK: - Bridge to WatchSessionManager + iPhone

extension WatchStrapConnector {
    /// Mirror the live HR onto WatchSessionManager so the big-HR display
    /// reflects whichever source is producing the freshest data — the
    /// iPhone-pushed relay, OR our direct strap connection here.
    /// `applyDirectStrapHR` stamps the beat, and the session manager's
    /// `displayedHRSource` prefers it while it is fresh.
    @MainActor
    private func publishToWatchSession(hr: Int, rrMillis _: [Double]) {
        sessionManager?.applyDirectStrapHR(hr)
    }

    func attach(sessionManager: WatchSessionManager) {
        self.sessionManager = sessionManager
    }

    /// One notification from the strap: to this app's UI, to the phone-facing
    /// session mirror (only a real beat), and on to the iPhone. A notification
    /// already queued from a strap just replaced or forgotten is dropped, so it
    /// cannot re-show or forward that strap's beat. A packet with no real beat
    /// (lost contact, rate 0) clears the shown rate rather than leaving the
    /// last one up as live.
    @MainActor
    private func publishBeat(_ measurement: WatchMessageDecoding.StrapMeasurement, from id: UUID) {
        guard connectedPeripheral?.identifier == id else { return }
        liveHeartRate = measurement.heartRate
        lastRRMillis = measurement.rrMillis
        if let hr = measurement.heartRate { publishToWatchSession(hr: hr, rrMillis: measurement.rrMillis) }
        forwardSampleToiPhone(hr: measurement.heartRate, rrMillis: measurement.rrMillis)
    }

    /// Forward the sample to the paired iPhone over WCSession so the
    /// iPhone-side recorder can fold it into a workout when its own
    /// PolarManager isn't holding the strap (e.g. the user paired the
    /// strap to the Watch instead of the phone).
    ///
    /// Live channel only. A beat is worth something only while it is live:
    /// queued with `transferUserInfo` while the phone was out of range, an
    /// hour of beats arrived later looking fresh — a stale heart rate shown
    /// as live, and old intervals mixed into the next workout. A beat the
    /// phone cannot take now is dropped.
    ///
    /// `hr` is left out when the packet carried no real beat; its intervals
    /// still go, as the iPhone's own strap path keeps them. A packet with
    /// neither is not sent.
    @MainActor
    private func forwardSampleToiPhone(hr: Int?, rrMillis: [Double]) {
        guard WCSession.isSupported(), hr != nil || !rrMillis.isEmpty else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }

        var payload: [String: any Sendable] = ["type": "watchStrapSample", "rrMillis": rrMillis, "ts": Date().timeIntervalSince1970]
        if let hr { payload["hr"] = hr }
        // `@Sendable`: WatchConnectivity calls the error handler on its own
        // queue, and a main-actor-isolated closure asserts main at entry.
        session.sendMessage(payload, replyHandler: nil) { @Sendable error in
            Self.logDroppedSample(error)
        }
    }

    /// The live send failed; the beat is dropped (see `forwardSampleToiPhone`).
    nonisolated private static func logDroppedSample(_ error: Error) {
        Logger(subsystem: "com.chrissharp.flowrecovery", category: "WatchStrapConnector")
            .debug("[WatchStrap] live sample send failed, dropped: \(error.localizedDescription)")
    }
}
