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
    /// Distance rowed in this workout, meters: the PM5's piece distance less
    /// what it showed when the workout began, plus anything rowed before a
    /// piece reset on the PM5 mid-workout (`ErgPieceCounter`). Before any
    /// workout, the PM5's own piece distance.
    private(set) var distanceMeters: Double?
    /// Stroke rate in strokes per minute.
    private(set) var strokeRateSPM: Double?
    /// Drag factor — proxy for fan damper resistance setting (typical 100–135).
    private(set) var dragFactor: Int?
    /// Power of the last stroke in watts, from Additional Stroke Data
    /// (0x0036, see `strokeData(from:)`). Nil between pieces and when the
    /// reading is implausible. Named to match `FootPodManager` for the recorder.
    private(set) var instantaneousPowerWatts: Int?
    /// Strokes taken in this workout, from Additional Stroke Data (0x0036),
    /// counted the same way as `distanceMeters`.
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

    /// Nil until the user scans for, or connects to, an erg. Building the
    /// central shows the Bluetooth prompt, and this manager is created at the
    /// first workout of any sport, so `init` must not build one.
    @ObservationIgnored private(set) var centralIfCreated: CBCentralManager?
    /// The central, built on first access with this manager as its delegate.
    var central: CBCentralManager {
        if let centralIfCreated { return centralIfCreated }
        let made = CBCentralManager(delegate: self, queue: .main)
        centralIfCreated = made
        return made
    }
    /// A scan asked for before Bluetooth reached `.poweredOn` (a freshly
    /// built central starts in `.unknown`); `.poweredOn` starts it.
    @ObservationIgnored private var scanWaitingForBluetooth = false
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
    /// The PM5's piece counters turned into this workout's totals.
    @ObservationIgnored private var pieceDistance = ErgPieceCounter<Double>()
    @ObservationIgnored private var pieceStrokes = ErgPieceCounter<Int>()
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

    /// Reads the remembered ergs only; the central is built on first use.
    override init() {
        super.init()
        loadKnownDevices()
    }

    // MARK: Public control

    /// Before Bluetooth is powered on the scan waits, and `.poweredOn` starts it.
    func startScanning() {
        guard central.state == .poweredOn else {
            scanWaitingForBluetooth = true
            lastStatusLine = String(localized: "Waiting for Bluetooth…", bundle: LanguageManager.appBundle)
            return
        }
        scanWaitingForBluetooth = false
        discoveredDevices = []
        connectionState = .scanning
        lastStatusLine = String(localized: "Scanning for Concept2 erg…", bundle: LanguageManager.appBundle)
        central.scanForPeripherals(
            withServices: [Self.discoveryService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.endTimedOutScan() }
        }
    }

    /// The erg a parked reconnect was scanning for did not appear, so the
    /// reconnect ends with the scan; left parked, a later unrelated scan or
    /// Bluetooth power-on attached it outside any workout.
    private func endTimedOutScan() {
        pendingReconnectId = nil
        stopScanning()
    }

    func stopScanning() {
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = nil
        scanWaitingForBluetooth = false
        if let centralIfCreated, centralIfCreated.isScanning { centralIfCreated.stopScan() }
        if connectionState == .scanning { connectionState = .disconnected }
    }

    func reconnectLast() {
        guard let last = knownDevices.first else { return }
        connect(deviceId: last.id)
    }

    /// Called at a workout's start and stop. At the start, the PM5's piece
    /// counters are zeroed for the workout (what the PM5 shows now, or its
    /// first reading when the erg is not connected yet). At the stop, a
    /// reconnect still waiting for the sensor — a connect in flight or an id
    /// parked while Bluetooth was off — is cancelled.
    func holdLinkForWorkout(_ holds: Bool) {
        workoutHoldsLink = holds
        if holds {
            beginPieceCounting()
            return
        }
        guard expectsLink else { return }
        pendingReconnectId = nil
        if connectionState == .connecting { disconnect() }
    }

    /// Zeroes the piece counters for a workout starting now. A connected erg
    /// that has reported reads 0 from here; otherwise nothing is shown until
    /// it reports, so a previous workout's totals (kept through a drop) never
    /// open this one.
    private func beginPieceCounting() {
        let linkIsUp = connectionState == .connected
        pieceDistance.beginWorkout(linkIsUp: linkIsUp)
        pieceStrokes.beginWorkout(linkIsUp: linkIsUp)
        distanceMeters = linkIsUp ? distanceMeters.map { _ in 0 } : nil
        strokeCount = linkIsUp ? strokeCount.map { _ in 0 } : nil
    }

    func disconnect() {
        expectsLink = false
        if let p = activePeripheral { centralIfCreated?.cancelPeripheralConnection(p) }
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

    /// `keepingPiece` is a drop mid-workout: the PM5 keeps counting the piece
    /// while the link is down, so the workout's distance, stroke count and
    /// drag factor stand until it is back. Cleared, they handed live rowing
    /// distance to GPS and the pedometer (which read about zero on an erg),
    /// and a workout stopped during the drop saved no strokes or drag factor.
    private func cleanupAfterDisconnect(keepingPiece: Bool = false) {
        activePeripheral = nil
        generalDataChar = nil
        additionalDataChar = nil
        strokeDataChar = nil
        strokeRateSPM = nil
        instantaneousPowerWatts = nil
        connectionState = .disconnected
        guard !keepingPiece else { return }
        distanceMeters = nil
        dragFactor = nil
        strokeCount = nil
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
            if self.scanWaitingForBluetooth { self.startScanning() }
        }
    }

    /// Bluetooth off sends no disconnect for the erg, so the state stayed
    /// `.connected` on a dead link and nothing reconnected it. Mid-workout,
    /// the erg is parked for `.poweredOn` and the piece's distance is kept.
    @MainActor
    private func dropForPowerOff() {
        let parkedId = expectsLink && workoutHoldsLink ? activePeripheral?.identifier.uuidString : nil
        cleanupAfterDisconnect(keepingPiece: parkedId != nil)
        guard let parkedId else { return }
        pendingReconnectId = parkedId
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

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error _: Error?) {
        Task { @MainActor in
            let midWorkout = self.expectsLink && self.workoutHoldsLink
            self.cleanupAfterDisconnect(keepingPiece: midWorkout)
            self.lastStatusLine = String(localized: "Connection failed", bundle: LanguageManager.appBundle)
            if midWorkout { self.retryConnect(peripheral) }
        }
    }

    /// A reconnect that failed mid-workout is asked for again after a short
    /// pause (a failure can come back at once, so not in a tight loop);
    /// before, the first failure ended erg data for the rest of the workout.
    @MainActor
    private func retryConnect(_ peripheral: CBPeripheral) {
        Task { @MainActor [weak self] in
            await sleepQuietly(2_000_000_000, context: "Concept2 reconnect after a failed connect")
            guard let self, self.expectsLink, self.workoutHoldsLink, self.connectionState == .disconnected else { return }
            self.attach(peripheral: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error _: Error?) {
        Task { @MainActor in
            let midWorkout = self.expectsLink && self.workoutHoldsLink
            self.cleanupAfterDisconnect(keepingPiece: midWorkout)
            guard midWorkout else { return }
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
        distanceMeters = pieceDistance.total(forRaw: Double(distRaw) * 0.1)
        dragFactor = Int(bytes[18])
    }

    /// Additional Status (0x0032). Length varies; only the stroke rate is
    /// read (the recorder derives split pace from moving time and distance).
    /// Layout:
    ///   bytes 0–2   Elapsed Time (u24, 0.01 s)
    ///   bytes 3–4   Speed (u16, 0.001 m/s)
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
        // Index 5 is the last one read; "Length varies" per the erg spec.
        guard bytes.count >= 6 else { return }
        let strokeRate = bytes[5]
        strokeRateSPM = strokeRate > 0 ? Double(strokeRate) : nil
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
        strokeCount = pieceStrokes.total(forRaw: stroke.strokeCount)
    }
}

/// One PM5 piece counter (distance, stroke count) as this workout's total.
///
/// The PM5 counts from its own piece start, not the app's workout: metres
/// rowed before the workout began are in its first reading, and resetting the
/// piece on the PM5 mid-workout sends it back to zero. This subtracts what the
/// PM5 showed when the workout began and carries what was rowed before a
/// reset. Before any workout it passes the PM5's value through.
struct ErgPieceCounter<Value: AdditiveArithmetic & Comparable> {
    /// The raw value this stretch of the workout counts from; nil before any
    /// workout.
    private var segmentStart: Value?
    /// What earlier stretches (before a PM5 reset) added up to.
    private var carried: Value = .zero
    private var lastRaw: Value?
    private var awaitingBaseline = false

    /// The workout starts now. With the erg connected, its last reading is
    /// zero; otherwise its first reading once it connects is.
    mutating func beginWorkout(linkIsUp: Bool) {
        carried = .zero
        awaitingBaseline = !linkIsUp || lastRaw == nil
        segmentStart = awaitingBaseline ? nil : lastRaw
    }

    /// This workout's total for a raw PM5 reading.
    mutating func total(forRaw raw: Value) -> Value {
        if awaitingBaseline {
            segmentStart = raw
            lastRaw = raw
            awaitingBaseline = false
        }
        if let last = lastRaw, let start = segmentStart, raw < last {
            carried += last - start
            segmentStart = .zero
        }
        lastRaw = raw
        guard let start = segmentStart else { return raw }
        return carried + (raw - start)
    }
}
