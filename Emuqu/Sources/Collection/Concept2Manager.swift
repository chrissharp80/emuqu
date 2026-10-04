@preconcurrency import CoreBluetooth
import Foundation

// MARK: - Concept2Manager
//
// Reads live data from a Concept2 PM5 erg over BLE. Mirrors FootPodManager's
// shape: scan → connect → subscribe to characteristics → publish state via
// observable properties that the recorder reads each tick.
//
// The PM5 exposes four custom services using the prefix
// `ce06xxxx-43e5-11e4-916c-0800200c9a66`:
//   • Discovery     ce06_0000…  — advertised, used to surface the device
//   • Information   ce06_0010…  — serial / firmware
//   • Control       ce06_0020…  — start/stop/configure (we don't use today)
//   • Rowing        ce06_0030…  — the live data stream
//
// Inside Rowing service we subscribe to:
//   • General Status 0x0031          — distance, drag factor
//   • Additional Status 0x0032       — stroke rate, pace
//   • Additional Stroke Data 0x0036  — stroke power (watts), stroke count
//
// Spec PDF: http://www.concept2.cn/files/pdf/us/monitors/PM5_BluetoothSmartInterfaceDefinition.pdf
// Open-source reference (MIT): https://github.com/BoutFitness/Concept2-SDK
//
// Persisted-known-devices and reconnect logic match FootPodManager so the
// rower auto-pairs on subsequent launches without re-scanning every time.
@Observable
@MainActor
final class Concept2Manager: NSObject, BLEPeripheralConnecting {
    static let shared = Concept2Manager()

    enum ConnectionState: Equatable {
        case disconnected, scanning, connecting, connected
    }

    // MARK: Published state

    private(set) var connectionState: ConnectionState = .disconnected
    /// Distance rowed in this session, meters. Comes from the PM5 odometer
    /// reset at session start.
    private(set) var distanceMeters: Double?
    /// Current 500 m pace from the PM5 (seconds per 500 m). The PM5's native
    /// unit — most rowers think in "split times" not in raw m/s.
    private(set) var paceSecPer500m: Double?
    /// Stroke rate in strokes per minute.
    private(set) var strokeRateSPM: Double?
    /// Drag factor — proxy for fan damper resistance setting (typical 100–135).
    private(set) var dragFactor: Int?
    /// Power of the last stroke in watts, from Additional Stroke Data
    /// (0x0036, see `strokeData(from:)`). Nil between pieces and when the
    /// reading is implausible. Named to match `FootPodManager` for the recorder.
    private(set) var instantaneousPowerWatts: Int?
    /// Calories burned, as reported by the PM5 (uses its own model — we
    /// pass through rather than re-derive).
    ///
    /// NOTE: not yet populated — always nil. Total Calories lives in
    /// Additional Status 2 (0x0033), which this manager does not subscribe
    /// to; 0x0036 carries only a per-stroke calorie RATE (cal/hr), not a
    /// total. Left in place because finalize (WorkoutRecorder+Lifecycle)
    /// reads it; wire up 0x0033 to populate it for real.
    private(set) var caloriesBurned: Int?
    /// Total stroke count this piece, from Additional Stroke Data (0x0036).
    private(set) var strokeCount: Int?

    private(set) var knownDevices: [KnownErg] = []
    private(set) var discoveredDevices: [DiscoveredErg] = []
    private(set) var lastStatusLine: String = String(localized: "Idle", bundle: LanguageManager.appBundle)

    struct KnownErg: Codable, Identifiable, Equatable {
        let id: String
        let name: String
    }

    struct DiscoveredErg: Identifiable, Equatable {
        let id: String
        let name: String
    }

    // MARK: BLE infra

    /// Created on first use rather than declared implicitly-unwrapped.
    ///
    /// It was `CBCentralManager!` only because `self` cannot be passed as the
    /// delegate until after `super.init()`, so the property could not be
    /// initialised inline. `lazy` says exactly that and removes the trap: the
    /// value is never nil at any point a caller can observe, and the compiler
    /// now guarantees it instead of the programmer promising it.
    @ObservationIgnored lazy var central: CBCentralManager = .init(delegate: self, queue: .main)
    @ObservationIgnored private var activePeripheral: CBPeripheral?
    /// Set once connected and cleared by `disconnect()`. A drop while it is
    /// set, during a workout, was not asked for (the sensor slept between
    /// intervals, or blipped out of range), so the connection is asked for
    /// again: CoreBluetooth keeps that request open until the sensor is back.
    /// Before, a drop ended cadence, pace and power for the rest of the
    /// workout.
    @ObservationIgnored private var expectsLink = false
    /// True from a workout's start to its stop. Outside a workout a drop is
    /// left alone, so the app doesn't hold a connection request open for a
    /// sensor nobody is using.
    @ObservationIgnored private var workoutHoldsLink = false
    @ObservationIgnored private var generalDataChar: CBCharacteristic?
    @ObservationIgnored private var additionalDataChar: CBCharacteristic?
    @ObservationIgnored private var strokeDataChar: CBCharacteristic?
    var pendingReconnectId: String?
    @ObservationIgnored private var scanTimeoutTimer: Timer?

    // PM5 UUIDs — full 128-bit form because the prefix is custom (Concept2 OUI).
    nonisolated static let discoveryService = CBUUID(string: "ce060000-43e5-11e4-916c-0800200c9a66")
    nonisolated static let rowingService = CBUUID(string: "ce060030-43e5-11e4-916c-0800200c9a66")
    nonisolated static let generalDataChar_UUID = CBUUID(string: "ce060031-43e5-11e4-916c-0800200c9a66")
    nonisolated static let additionalDataChar_UUID = CBUUID(string: "ce060032-43e5-11e4-916c-0800200c9a66")
    nonisolated static let strokeDataChar_UUID = CBUUID(string: "ce060036-43e5-11e4-916c-0800200c9a66")
    /// The three rowing-data characteristics this manager subscribes to.
    nonisolated static let rowingDataChars = [generalDataChar_UUID, additionalDataChar_UUID, strokeDataChar_UUID]

    private let knownDevicesKey = "fitness.concept2.knownDevices"

    override init() {
        super.init()
        // Touch `central` so the Bluetooth stack comes up at init exactly as it
        // did when this was an explicit assignment — `lazy` alone would defer
        // creation to the first scan and delay the first `poweredOn` callback.
        _ = central
        loadKnownDevices()
    }

    // MARK: Public control

    func startScanning() {
        guard central.state == .poweredOn else {
            lastStatusLine = String(localized: "Waiting for Bluetooth…", bundle: LanguageManager.appBundle)
            return
        }
        discoveredDevices = []
        connectionState = .scanning
        lastStatusLine = String(localized: "Scanning for Concept2 erg…", bundle: LanguageManager.appBundle)
        central.scanForPeripherals(
            withServices: [Self.discoveryService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopScanning() }
        }
    }

    func stopScanning() {
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = nil
        if central.isScanning { central.stopScan() }
        if connectionState == .scanning { connectionState = .disconnected }
    }

    func reconnectLast() {
        guard let last = knownDevices.first else { return }
        connect(deviceId: last.id)
    }

    /// Called at a workout's start and stop. At the stop, a reconnect still
    /// waiting for the sensor is cancelled.
    func holdLinkForWorkout(_ holds: Bool) {
        workoutHoldsLink = holds
        if !holds, expectsLink, connectionState == .connecting { disconnect() }
    }

    func disconnect() {
        expectsLink = false
        if let p = activePeripheral { central.cancelPeripheralConnection(p) }
        cleanupAfterDisconnect()
    }

    func removeKnownDevice(id: String) {
        knownDevices.removeAll { $0.id == id }
        saveKnownDevices()
    }

    // MARK: Internal

    func attach(peripheral: CBPeripheral) {
        activePeripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        let name = peripheral.name ?? String(localized: "Concept2 PM5", bundle: LanguageManager.appBundle)
        lastStatusLine = String(localized: "Connecting to \(name)…", bundle: LanguageManager.appBundle)
        central.connect(peripheral, options: nil)
    }

    private func cleanupAfterDisconnect() {
        activePeripheral = nil
        generalDataChar = nil
        additionalDataChar = nil
        strokeDataChar = nil
        distanceMeters = nil
        paceSecPer500m = nil
        strokeRateSPM = nil
        instantaneousPowerWatts = nil
        dragFactor = nil
        caloriesBurned = nil
        strokeCount = nil
        connectionState = .disconnected
    }

    private func rememberDevice(peripheral: CBPeripheral) {
        let id = peripheral.identifier.uuidString
        let name = peripheral.name ?? String(localized: "Concept2 PM5", bundle: LanguageManager.appBundle)
        var list = knownDevices
        list.removeAll { $0.id == id }
        list.insert(KnownErg(id: id, name: name), at: 0)
        if list.count > 4 { list = Array(list.prefix(4)) }
        knownDevices = list
        saveKnownDevices()
    }

    private func saveKnownDevices() {
        if let data = attempt("concept2.knownDevices.encode", { try JSONEncoder().encode(knownDevices) }) {
            UserDefaults.standard.set(data, forKey: knownDevicesKey)
        }
    }

    private func loadKnownDevices() {
        guard let data = UserDefaults.standard.data(forKey: knownDevicesKey),
              let decoded = try? JSONDecoder().decode([KnownErg].self, from: data)
        else { return }
        knownDevices = decoded
    }
}

// MARK: - CBCentralManagerDelegate

extension Concept2Manager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            if state == .poweredOff { self.dropForPowerOff() }
            guard state == .poweredOn else { return }
            // Cleared before connecting: `connect(deviceId:)` parks the id
            // again when it has to scan for the erg.
            if let pendingId = self.pendingReconnectId {
                self.pendingReconnectId = nil
                self.connect(deviceId: pendingId)
            }
        }
    }

    /// Bluetooth off sends no disconnect for the erg, so the state stayed
    /// `.connected` on a dead link and nothing reconnected it. Mid-workout,
    /// the erg is parked for `.poweredOn` and the piece's distance is kept.
    @MainActor
    private func dropForPowerOff() {
        let distance = distanceMeters
        let parkedId = expectsLink && workoutHoldsLink ? activePeripheral?.identifier.uuidString : nil
        cleanupAfterDisconnect()
        guard let parkedId else { return }
        pendingReconnectId = parkedId
        distanceMeters = distance
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData _: [String: Any],
        rssi _: NSNumber
    ) {
        let id = peripheral.identifier.uuidString
        let name = peripheral.name ?? String(localized: "Concept2 PM5", bundle: LanguageManager.appBundle)
        Task { @MainActor in
            if !self.discoveredDevices.contains(where: { $0.id == id }) {
                self.discoveredDevices.append(DiscoveredErg(id: id, name: name))
            }
            // Auto-connect to the most-recent paired erg, or to the one
            // `connect(deviceId:)` parked while scanning for it.
            if self.pendingReconnectId == id {
                self.pendingReconnectId = nil
                self.stopScanning()
                self.attach(peripheral: peripheral)
            } else if self.knownDevices.first?.id == id, self.connectionState == .scanning {
                self.attach(peripheral: peripheral)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.connectionState = .connected
            self.expectsLink = true
            let name = peripheral.name ?? String(localized: "Concept2 PM5", bundle: LanguageManager.appBundle)
            self.lastStatusLine = String(localized: "Connected to \(name)", bundle: LanguageManager.appBundle)
            peripheral.discoverServices([Self.rowingService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect _: CBPeripheral, error _: Error?) {
        Task { @MainActor in
            self.connectionState = .disconnected
            self.lastStatusLine = String(localized: "Connection failed", bundle: LanguageManager.appBundle)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error _: Error?) {
        Task { @MainActor in
            let distance = self.distanceMeters
            self.cleanupAfterDisconnect()
            guard self.expectsLink, self.workoutHoldsLink else { return }
            // The PM5 keeps counting the piece while the link is down.
            // Clearing it handed live rowing distance to GPS and the
            // pedometer, which read about zero on an erg.
            self.distanceMeters = distance
            self.attach(peripheral: peripheral)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension Concept2Manager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices _: Error?) {
        Task { @MainActor in Self.discoverRowingCharacteristics(on: peripheral) }
    }

    /// Only the rowing service's three data characteristics are requested —
    /// the PM5 advertises several services we never read.
    @MainActor
    private static func discoverRowingCharacteristics(on peripheral: CBPeripheral) {
        for service in peripheral.services ?? [] where service.uuid == rowingService {
            peripheral.discoverCharacteristics(rowingDataChars, for: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error _: Error?
    ) {
        Task { @MainActor in self.bindRowingCharacteristics(service, on: peripheral) }
    }

    /// Subscribe to whichever of the data characteristics this service
    /// carries, and remember the device once at least one is bound.
    @MainActor
    private func bindRowingCharacteristics(_ service: CBService, on peripheral: CBPeripheral) {
        for ch in service.characteristics ?? [] where Self.rowingDataChars.contains(ch.uuid) {
            if ch.uuid == Self.generalDataChar_UUID { generalDataChar = ch }
            if ch.uuid == Self.additionalDataChar_UUID { additionalDataChar = ch }
            if ch.uuid == Self.strokeDataChar_UUID { strokeDataChar = ch }
            peripheral.setNotifyValue(true, for: ch)
        }
        guard generalDataChar != nil || additionalDataChar != nil || strokeDataChar != nil else { return }
        rememberDevice(peripheral: peripheral)
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error _: Error?
    ) {
        guard let data = characteristic.value else { return }
        let uuid = characteristic.uuid
        Task { @MainActor in
            if uuid == Self.generalDataChar_UUID {
                self.parseGeneralData(data: data)
            } else if uuid == Self.additionalDataChar_UUID {
                self.parseAdditionalData(data: data)
            } else if uuid == Self.strokeDataChar_UUID {
                self.applyStrokeData(Self.strokeData(from: data))
            }
        }
    }

    // MARK: Packet decoding
    //
    // PM5 packets are little-endian. Field layouts come from the BLE Smart
    // Comms Interface Definition v1.39 spec — all offsets are zero-based
    // within the characteristic payload.

    /// General Rowing Data (0x0031). 19 bytes.
    /// Layout:
    ///   bytes 0–2  Elapsed Time (u24, units of 0.01 s)
    ///   bytes 3–5  Distance (u24, units of 0.1 m)
    ///   byte  6    Workout Type
    ///   byte  7    Interval Type
    ///   byte  8    Workout State
    ///   byte  9    Rowing State
    ///   byte 10    Stroke State
    ///   bytes 11–13 Total Work Distance (u24, m)
    ///   bytes 14–16 Workout Duration (u24, depends on type)
    ///   byte 17    Workout Duration Type
    ///   byte 18    Drag Factor
    @MainActor
    private func parseGeneralData(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 19 else { return }
        let distRaw = UInt32(bytes[3]) | (UInt32(bytes[4]) << 8) | (UInt32(bytes[5]) << 16)
        distanceMeters = Double(distRaw) * 0.1
        dragFactor = Int(bytes[18])
    }

    /// Additional Status (0x0032). Length varies; we read the first
    /// few well-defined fields used by the live UI:
    ///   bytes 0–2   Elapsed Time (u24, 0.01 s)
    ///   bytes 3–4   Speed (u16, 0.001 m/s)         → derive split pace
    ///   byte  5     Stroke Rate (u8, strokes/min)
    ///   byte  6     Heart Rate (u8) — present only if the PM5 has a paired strap
    ///   bytes 7–8   Current Pace (u16, 0.01 s per 500 m)
    ///   bytes 9–10  Average Pace (u16, 0.01 s per 500 m)
    ///   bytes 11–12 Rest Distance (u16, m)
    ///   bytes 13–15 Rest Time (u24, 0.01 s)
    ///   byte  16    Erg Machine Type
    /// There is no power field here: an earlier reading of bytes 16–17 as
    /// average power only ever ran on packets the PM5 doesn't send (17
    /// bytes), and byte 16 is the machine type. Power comes from 0x0036.
    @MainActor
    private func parseAdditionalData(data: Data) {
        let bytes = [UInt8](data)
        // Need indices 0…8 below (bytes[8] is read for the pace u16). A
        // `>= 8` guard admits an 8-byte packet — "Length varies" per
        // the erg spec — and traps on bytes[8] mid-row.
        guard bytes.count >= 9 else { return }
        let strokeRate = bytes[5]
        strokeRateSPM = strokeRate > 0 ? Double(strokeRate) : nil
        let paceRaw = UInt16(bytes[7]) | (UInt16(bytes[8]) << 8)
        let paceSec = Double(paceRaw) * 0.01
        paceSecPer500m = paceSec > 0 ? paceSec : nil
    }

    /// What one Additional Stroke Data packet says.
    struct StrokeData: Equatable {
        /// Stroke power in watts; nil when zero or implausible.
        let powerWatts: Int?
        let strokeCount: Int
    }

    /// Plausible stroke power on an erg. Zero is sent between strokes and
    /// pieces; above 1 500 W is beyond even an elite sprint stroke and means
    /// a misread packet, so neither may reach power-TSS.
    nonisolated static let plausibleStrokePowerWatts = 1 ... 1_500

    /// Additional Stroke Data (0x0036). 15 bytes, sent once per stroke:
    ///   bytes 0–2   Elapsed Time (u24, 0.01 s)
    ///   bytes 3–4   Stroke Power (u16, watts)
    ///   bytes 5–6   Stroke Calories (u16, cal/hr)
    ///   bytes 7–8   Stroke Count (u16)
    ///   bytes 9–11  Projected Work Time (u24, s)
    ///   bytes 12–14 Projected Work Distance (u24, m)
    /// Layout per the Concept2 PM5 Bluetooth Smart Interface Definition (and
    /// the MIT Concept2-SDK decoder linked above). Not verified against a
    /// live PM5 capture here, so the power is range-guarded rather than
    /// trusted. Nil when the packet is too short to hold the fields read.
    nonisolated static func strokeData(from data: Data) -> StrokeData? {
        let bytes = [UInt8](data)
        guard bytes.count >= 9 else { return nil }
        let power = Int(UInt16(bytes[3]) | (UInt16(bytes[4]) << 8))
        let strokes = Int(UInt16(bytes[7]) | (UInt16(bytes[8]) << 8))
        return StrokeData(
            powerWatts: plausibleStrokePowerWatts.contains(power) ? power : nil,
            strokeCount: strokes
        )
    }

    @MainActor
    private func applyStrokeData(_ stroke: StrokeData?) {
        guard let stroke else { return }
        instantaneousPowerWatts = stroke.powerWatts
        strokeCount = stroke.strokeCount
    }
}
