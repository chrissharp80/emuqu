import Combine
@preconcurrency import CoreBluetooth
import Foundation

// MARK: - FootPodManager
//
// Generic Bluetooth LE foot-pod / power-meter controller. Unlike the Polar
// strap (which speaks through `PolarBleSdk`'s wrapper), foot pods from Stryd,
// Polar Stride Sensor, Milestone, Garmin HRM-Pro+, etc. all publish through
// standard BLE SIG services. We talk to them directly via CoreBluetooth —
// no proprietary SDK, no vendor lock-in.
//
// Services consumed:
//   • Running Speed and Cadence Service (0x1814)
//       — RSC Measurement characteristic (0x2A53) — instantaneous speed
//         (m/s × 256), cadence (spm), optional stride length, optional
//         total distance.
//   • Cycling Power Service (0x1818)
//       — Cycling Power Measurement characteristic (0x2A63) — instantaneous
//         power (int16 watts). Stryd publishes running power through this
//         standard service despite its name — no proprietary protocol needed
//         for basic watt readings.
//
// What this manager DOES:
//   - Scan for peripherals advertising RSC or Cycling Power.
//   - Remember the last-connected device (UserDefaults, like PolarManager).
//   - Auto-reconnect on next workout.
//   - Publish speed / cadence / distance / power as observable for the
//     WorkoutRecorder to consume.
//   - Persist a short log line per reconnect so debugging is possible.
//
// What this manager does NOT do (left for future passes):
//   - Stryd's proprietary LSS / Leg Spring Stiffness / Wind Detection protocol.
//   - Calibration offsets (treadmill distance correction).
//   - Simultaneous multi-device (one foot pod at a time is the norm).
//   - Background-mode reconnect (CoreBluetooth state-restoration). The
//     `bluetooth-central` UIBackgroundMode is already declared in Info.plist
//     so iOS keeps the central alive during a workout that started in the
//     foreground. State-restoration would need a full UUID-preservation
//     path we haven't yet needed.
/// The connect-by-identifier step the BLE sensor managers share
/// (`FootPodManager`, `Concept2Manager`). Each keeps its own central,
/// characteristics, and parsing; only this handshake is common.
///
/// Building a `CBCentralManager` is what shows the iOS Bluetooth prompt, so
/// each manager builds its central on first use by `central`, from a scan or
/// connect the user asked for (or a reconnect to a sensor they paired).
/// Creating the manager object itself never builds one; `centralIfCreated`
/// is how teardown paths reach the central without building it.
@MainActor
protocol BLEPeripheralConnecting: AnyObject {
    /// The central, built on first access.
    var central: CBCentralManager { get }
    /// The central if something has already built it; nil before that.
    var centralIfCreated: CBCentralManager? { get }
    /// Pending reconnect: Bluetooth was not powered on yet, or the peripheral
    /// was not retrievable by id and must be picked up from a scan's results.
    var pendingReconnectId: String? { get set }
    func attach(peripheral: CBPeripheral)
    func startScanning()
    func stopScanning()
}

extension BLEPeripheralConnecting {
    /// Connect to a specific peripheral. Pass a discovered or known device id.
    func connect(deviceId: String) {
        stopScanning()
        // A central built moments ago is not powered on yet, and CoreBluetooth
        // refuses lookups until it is; `.poweredOn` connects the parked id.
        guard central.state == .poweredOn else {
            pendingReconnectId = deviceId
            return
        }
        // Ask CoreBluetooth to retrieve by identifier (works for
        // previously-paired peripherals the system still knows about).
        if let uuid = UUID(uuidString: deviceId),
           let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            attach(peripheral: peripheral)
            return
        }
        // Fallback: peripheral must be in this scan's results; defer connect.
        pendingReconnectId = deviceId
        startScanning()
    }
}

@Observable
@MainActor
final class FootPodManager: NSObject, BLEPeripheralConnecting {
    /// Process-wide shared instance. CoreBluetooth's CBCentralManager keeps
    /// BLE state across view lifecycles, so constructing one per sheet would
    /// lose pairing and trigger re-scans constantly. Singleton match the
    /// pattern used by PolarManager + WatchConnectivityBridge.
    static let shared = FootPodManager()

    // MARK: - Public published state

    enum ConnectionState: Equatable {
        case disconnected
        case scanning
        case connecting
        case connected
    }

    private(set) var connectionState: ConnectionState = .disconnected
    /// Most-recent speed in m/s. Nil when the pod is silent.
    private(set) var instantaneousSpeedMS: Double?
    /// Running cadence in steps per minute from the pod.
    private(set) var cadenceStepsPerMin: Double?
    /// Stride length (m) when the pod reports it.
    private(set) var strideLengthMeters: Double?
    /// Pod-reported cumulative distance (m). The pod zeroes this at its own
    /// discretion (typically power-on), so treat as monotonic within a session
    /// after the first reading. Cleared on a disconnect outside a workout.
    private(set) var podReportedDistanceMeters: Double?
    /// Instantaneous power in watts (from Cycling Power Service — Stryd uses
    /// this for running power too). Nil if the pod doesn't publish power.
    private(set) var instantaneousPowerWatts: Int?
    /// Known / remembered devices — shown as "Reconnect to X" in UI.
    private(set) var knownDevices: [KnownFootPod] = []
    /// Devices seen during the current scan window.
    private(set) var discoveredDevices: [DiscoveredFootPod] = []
    /// Latest human-readable status for UI diagnostics.
    private(set) var lastStatusLine: String = String(localized: "Idle", bundle: LanguageManager.appBundle)

    // MARK: - Types

    struct KnownFootPod: Codable, Identifiable, Equatable {
        let id: String // CBPeripheral.identifier.uuidString
        let name: String
        /// True if this peripheral advertised Cycling Power — so Stryd-class
        /// devices show "power + pace" instead of "pace only".
        let supportsPower: Bool
    }

    struct DiscoveredFootPod: Identifiable, Equatable {
        let id: String
        let name: String
        let rssi: Int
        let supportsPower: Bool
    }

    // MARK: - Private

    /// Nil until the user scans for, or connects to, a foot pod or trainer.
    /// Building the central shows the Bluetooth prompt, and this manager is
    /// created at launch (the workout recorder holds it), so `init` must not
    /// build one.
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
    @ObservationIgnored private var rscMeasurementChar: CBCharacteristic?
    @ObservationIgnored private var powerMeasurementChar: CBCharacteristic?
    /// FTMS Indoor Bike Data characteristic — present on smart trainers /
    /// indoor bikes that broadcast power via FTMS instead of (or in
    /// addition to) the CPS path.
    @ObservationIgnored private var indoorBikeDataChar: CBCharacteristic?
    /// Pending reconnect when central starts in `.poweredOff` then powers on.
    var pendingReconnectId: String?
    /// Suppress scan during connect so we don't thrash the central.
    @ObservationIgnored private var scanTimeoutTimer: Timer?

    /// BLE SIG service UUIDs — short form is fine; CoreBluetooth expands.
    /// `nonisolated static let` so `nonisolated` CoreBluetooth delegate
    /// methods can read these without crossing actor isolation. Without
    /// the explicit `nonisolated`, Swift 6 inherits the enclosing class's
    /// `@MainActor` isolation onto static constants too. Compile-time
    /// constants don't need isolation.
    nonisolated static let runningSpeedCadenceService = CBUUID(string: "1814")
    nonisolated static let rscMeasurementChar_UUID = CBUUID(string: "2A53")
    nonisolated static let cyclingPowerService = CBUUID(string: "1818")
    nonisolated static let cyclingPowerMeasurementChar_UUID = CBUUID(string: "2A63")
    /// Fitness Machine Service — used by smart trainers, indoor bikes,
    /// treadmills, ergometers. Power-broadcasting bike trainers (Wahoo
    /// KICKR, Tacx Neo, Saris H3, Zwift Hub) advertise FTMS in addition
    /// to or instead of the standard CPS. Reading the Indoor Bike Data
    /// characteristic gives us instantaneous power + cadence + speed in
    /// one shot. Spec: BLE FTMS 1.0, characteristic Indoor Bike Data 0x2AD2.
    nonisolated static let fitnessMachineService = CBUUID(string: "1826")
    nonisolated static let indoorBikeDataChar_UUID = CBUUID(string: "2AD2")

    private let knownDevicesKey = "fitness.footpod.knownDevices"

    // MARK: - Init

    /// Reads the remembered devices only; the central is built on first use.
    override init() {
        super.init()
        loadKnownDevices()
    }

    // MARK: - Public control

    /// Kick off a fresh scan. Before Bluetooth is powered on the scan waits,
    /// and `.poweredOn` starts it.
    func startScanning() {
        guard central.state == .poweredOn else {
            scanWaitingForBluetooth = true
            lastStatusLine = String(localized: "Waiting for Bluetooth…", bundle: LanguageManager.appBundle)
            return
        }
        scanWaitingForBluetooth = false
        discoveredDevices = []
        connectionState = .scanning
        lastStatusLine = String(localized: "Scanning for foot pods…", bundle: LanguageManager.appBundle)
        // Advertising on any of the three services is enough to surface.
        central.scanForPeripherals(
            withServices: [
                Self.runningSpeedCadenceService,
                Self.cyclingPowerService,
                Self.fitnessMachineService
            ],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        armScanTimeout()
    }

    /// Safety: auto-stop the scan after 20 s so we don't drain battery if the
    /// user walks away from the settings sheet without tapping Stop.
    private func armScanTimeout() {
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopScanning() }
        }
    }

    func stopScanning() {
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = nil
        scanWaitingForBluetooth = false
        if let centralIfCreated, centralIfCreated.isScanning { centralIfCreated.stopScan() }
        if connectionState == .scanning { connectionState = .disconnected }
    }

    /// Try to reconnect to the most-recently paired device (if any).
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
        if let p = activePeripheral {
            centralIfCreated?.cancelPeripheralConnection(p)
        }
        // Teardown state here too in case the cancellation callback is slow.
        cleanupAfterDisconnect()
    }

    func removeKnownDevice(id: String) {
        knownDevices.removeAll { $0.id == id }
        saveKnownDevices()
    }

    // MARK: - Internal

    func attach(peripheral: CBPeripheral) {
        activePeripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        let name = peripheral.name ?? String(localized: "foot pod", bundle: LanguageManager.appBundle)
        lastStatusLine = String(localized: "Connecting to \(name)…", bundle: LanguageManager.appBundle)
        central.connect(peripheral, options: nil)
    }

    /// The odometer reading survives a link loss mid-workout (the pod keeps
    /// counting and the workout's baseline still applies when it comes back);
    /// otherwise it is cleared, so the next workout can't take a previous
    /// session's reading as its starting point.
    private func cleanupAfterDisconnect() {
        activePeripheral = nil
        rscMeasurementChar = nil
        powerMeasurementChar = nil
        indoorBikeDataChar = nil
        instantaneousSpeedMS = nil
        cadenceStepsPerMin = nil
        strideLengthMeters = nil
        instantaneousPowerWatts = nil
        if !workoutHoldsLink { podReportedDistanceMeters = nil }
        connectionState = .disconnected
    }

    private func rememberDevice(peripheral: CBPeripheral, supportsPower: Bool) {
        let id = peripheral.identifier.uuidString
        let name = peripheral.name ?? String(localized: "Foot pod", bundle: LanguageManager.appBundle)
        let entry = KnownFootPod(id: id, name: name, supportsPower: supportsPower)
        var list = knownDevices
        list.removeAll { $0.id == id }
        list.insert(entry, at: 0)
        if list.count > 4 { list = Array(list.prefix(4)) }  // keep list short
        knownDevices = list
        saveKnownDevices()
    }

    private func saveKnownDevices() {
        guard let data = attempt("footPod.knownDevices.encode", { try JSONEncoder().encode(knownDevices) }) else { return }
        UserDefaults.standard.set(data, forKey: knownDevicesKey)
    }

    private func loadKnownDevices() {
        guard let data = UserDefaults.standard.data(forKey: knownDevicesKey),
              let list = try? JSONDecoder().decode([KnownFootPod].self, from: data)
        else { return }
        knownDevices = list
    }
}

// MARK: - CBCentralManagerDelegate

extension FootPodManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in self.applyBluetoothState(state) }
    }

    /// `.poweredOn` also drains any reconnect the caller parked while the radio
    /// was unavailable, and starts a scan that was waiting for it.
    @MainActor
    private func applyBluetoothState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            lastStatusLine = String(localized: "Bluetooth ready", bundle: LanguageManager.appBundle)
            drainPendingReconnect()
            if scanWaitingForBluetooth { startScanning() }
        case .poweredOff:
            lastStatusLine = String(localized: "Bluetooth is off", bundle: LanguageManager.appBundle)
            parkReconnectIfMidWorkout()
            cleanupAfterDisconnect()
        case .unauthorized:
            lastStatusLine = String(localized: "Bluetooth permission denied", bundle: LanguageManager.appBundle)
        case .resetting, .unknown, .unsupported:
            lastStatusLine = String(localized: "Bluetooth unavailable", bundle: LanguageManager.appBundle)
        @unknown default:
            break
        }
    }

    @MainActor
    /// Bluetooth off mid-workout drops the pod without a disconnect callback.
    /// Its id is parked so `.poweredOn` connects it again.
    private func parkReconnectIfMidWorkout() {
        guard expectsLink, workoutHoldsLink, let id = activePeripheral?.identifier.uuidString else { return }
        pendingReconnectId = id
    }

    private func drainPendingReconnect() {
        guard let pending = pendingReconnectId else { return }
        pendingReconnectId = nil
        connect(deviceId: pending)
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier.uuidString
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? String(localized: "Foot pod", bundle: LanguageManager.appBundle)
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let supportsPower = services.contains(Self.cyclingPowerService)
        let rssi = RSSI.intValue
        Task { @MainActor in
            let entry = DiscoveredFootPod(id: id, name: name, rssi: rssi, supportsPower: supportsPower)
            if let existing = self.discoveredDevices.firstIndex(where: { $0.id == id }) {
                self.discoveredDevices[existing] = entry
            } else {
                self.discoveredDevices.append(entry)
            }
            self.attachIfPendingReconnect(peripheral)
        }
    }

    /// `connect(deviceId:)` parks a device CoreBluetooth couldn't retrieve and
    /// scans for it; this is where the scan picks it up.
    @MainActor
    private func attachIfPendingReconnect(_ peripheral: CBPeripheral) {
        guard pendingReconnectId == peripheral.identifier.uuidString else { return }
        pendingReconnectId = nil
        stopScanning()
        attach(peripheral: peripheral)
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.connectionState = .connected
            self.expectsLink = true
            let name = peripheral.name ?? String(localized: "foot pod", bundle: LanguageManager.appBundle)
            self.lastStatusLine = String(localized: "Connected to \(name)", bundle: LanguageManager.appBundle)
            peripheral.delegate = self
            peripheral.discoverServices([Self.runningSpeedCadenceService, Self.cyclingPowerService, Self.fitnessMachineService])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let err = error?.localizedDescription ?? String(localized: "unknown error", bundle: LanguageManager.appBundle)
        Task { @MainActor in
            self.lastStatusLine = String(localized: "Connect failed: \(err)", bundle: LanguageManager.appBundle)
            self.cleanupAfterDisconnect()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.lastStatusLine = String(localized: "Disconnected", bundle: LanguageManager.appBundle)
            self.cleanupAfterDisconnect()
            if self.expectsLink, self.workoutHoldsLink { self.attach(peripheral: peripheral) }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension FootPodManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            Self.discoverMeasurementCharacteristics(on: peripheral)
        }
    }

    /// Only the measurement characteristic of each recognised service is
    /// requested — discovering everything wakes characteristics we never read.
    @MainActor
    private static func discoverMeasurementCharacteristics(on peripheral: CBPeripheral) {
        for service in peripheral.services ?? [] {
            guard let characteristic = measurementCharacteristic(for: service.uuid) else { continue }
            peripheral.discoverCharacteristics([characteristic], for: service)
        }
    }

    /// The one measurement characteristic we care about on each supported
    /// service; nil for any other service the peripheral happens to advertise.
    private static func measurementCharacteristic(for serviceUUID: CBUUID) -> CBUUID? {
        switch serviceUUID {
        case runningSpeedCadenceService: return rscMeasurementChar_UUID
        case cyclingPowerService: return cyclingPowerMeasurementChar_UUID
        case fitnessMachineService: return indoorBikeDataChar_UUID
        default: return nil
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            guard let characteristics = service.characteristics else { return }
            let supportsPower = self.bindMeasurementCharacteristics(characteristics, on: peripheral)
            // Remember the device once we've seen its characteristics so the
            // supportsPower flag is accurate.
            let hasAny = self.rscMeasurementChar != nil || self.powerMeasurementChar != nil || self.indoorBikeDataChar != nil
            guard hasAny else { return }
            let hasPower = self.powerMeasurementChar != nil || self.indoorBikeDataChar != nil
            self.rememberDevice(peripheral: peripheral, supportsPower: supportsPower || hasPower)
        }
    }

    /// Subscribe to whichever measurement characteristics this service exposes,
    /// returning whether any of them carries power.
    @MainActor
    private func bindMeasurementCharacteristics(_ characteristics: [CBCharacteristic], on peripheral: CBPeripheral) -> Bool {
        var supportsPower = false
        for ch in characteristics {
            switch ch.uuid {
            case Self.rscMeasurementChar_UUID:
                rscMeasurementChar = ch
            case Self.cyclingPowerMeasurementChar_UUID:
                powerMeasurementChar = ch
                supportsPower = true
            case Self.indoorBikeDataChar_UUID:
                indoorBikeDataChar = ch
                supportsPower = true
            default:
                continue
            }
            peripheral.setNotifyValue(true, for: ch)
        }
        return supportsPower
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value else { return }
        let uuid = characteristic.uuid
        Task { @MainActor in
            if uuid == Self.rscMeasurementChar_UUID {
                self.parseRSC(data: data)
            } else if uuid == Self.cyclingPowerMeasurementChar_UUID {
                self.parsePower(data: data)
            } else if uuid == Self.indoorBikeDataChar_UUID {
                self.parseIndoorBikeData(data: data)
            }
        }
    }

    // MARK: - Packet decoding

    /// Running Speed & Cadence measurement characteristic (0x2A53).
    ///
    /// Layout (little-endian):
    ///   byte 0         flags:
    ///                    bit 0 — stride length present
    ///                    bit 1 — total distance present
    ///                    bit 2 — running (1) vs walking (0)
    ///   bytes 1–2      instantaneous speed (u16) in units of 1/256 m/s
    ///   byte 3         instantaneous cadence (u8) in steps per minute
    ///   bytes 4–5      stride length (u16) in 1/100 m (if flag set)
    ///   bytes 6–9      total distance (u32) in 1/10 m (if flag set)
    @MainActor
    private func parseRSC(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, let speedRaw = Self.u16(bytes, at: 1) else { return }
        let flags = bytes[0]
        let speedMS = Double(speedRaw) / 256.0
        let cadence = Double(bytes[3])
        instantaneousSpeedMS = speedMS > 0 ? speedMS : nil
        cadenceStepsPerMin = cadence > 0 ? cadence : nil
        var offset = 4
        if flags & 0x01 != 0 {
            if let strideRaw = Self.u16(bytes, at: offset) { strideLengthMeters = Double(strideRaw) / 100.0 }
            offset += 2
        }
        if flags & 0x02 != 0, let distRaw = Self.u32(bytes, at: offset) {
            podReportedDistanceMeters = Double(distRaw) / 10.0
        }
    }

    /// Little-endian u32 at `offset`, or nil when the packet is too short.
    private static func u32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard bytes.count >= offset + 4 else { return nil }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    /// Cycling Power Measurement characteristic (0x2A63).
    /// Layout (little-endian):
    ///   bytes 0–1  flags (u16)      — we only read the mandatory fields
    ///   bytes 2–3  instantaneous power (int16, watts, signed)
    ///   (remaining optional fields — pedal power balance, crank revs, etc.
    ///    — ignored for running-power use)
    @MainActor
    private func parsePower(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return }
        let lo = UInt16(bytes[2])
        let hi = UInt16(bytes[3])
        let raw = lo | (hi << 8)
        let signed = Int16(bitPattern: raw)
        // Negative power from a foot pod is a measurement artifact (e.g.
        // standing still on a treadmill). Clamp to 0 for display.
        let watts = max(0, Int(signed))
        instantaneousPowerWatts = watts > 0 ? watts : nil
    }

    /// FTMS Indoor Bike Data characteristic (0x2AD2). Used by smart trainers
    /// (Wahoo KICKR, Tacx Neo, Saris H3, Zwift Hub) and indoor bikes that
    /// don't broadcast plain CPS. Spec: BLE FTMS 1.0 §4.9.
    ///
    /// Layout (little-endian):
    ///   bytes 0–1  flags (u16)
    ///                bit 0 = More Data (continuation packet — skip)
    ///                bit 1 = Average Speed Present
    ///                bit 2 = Instantaneous Cadence Present
    ///                bit 3 = Average Cadence Present
    ///                bit 4 = Total Distance Present (u24)
    ///                bit 5 = Resistance Level Present (i16)
    ///                bit 6 = Instantaneous Power Present (i16)
    ///                ...
    ///   bytes 2–3  Instantaneous Speed (u16, units of 0.01 km/h) — present
    ///              UNLESS bit 0 says continuation
    ///   then optional fields in order, each gated by the matching bit.
    ///
    /// We read inst speed (always-present absent the continuation bit), then
    /// inst cadence and inst power if their flag bits are set. Optional
    /// fields between are skipped over by their fixed widths.
    @MainActor
    private func parseIndoorBikeData(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return }
        let flags = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        var offset = 2
        if flags & 0x0001 == 0 {
            guard applyInstantaneousSpeed(bytes, at: offset) else { return }
            offset += 2
        }
        offset += (flags & 0x0002 != 0 ? 2 : 0) // Average Speed (skip)
        if flags & 0x0004 != 0 {                // Instantaneous Cadence (0.5/min units)
            if let cadRaw = Self.u16(bytes, at: offset) { cadenceStepsPerMin = Double(cadRaw) / 2.0 }
            offset += 2
        }
        // Average Cadence (2), Total Distance u24 (3), Resistance Level (2).
        offset += (flags & 0x0008 != 0 ? 2 : 0) + (flags & 0x0010 != 0 ? 3 : 0) + (flags & 0x0020 != 0 ? 2 : 0)
        applyInstantaneousPower(bytes, at: offset, flags: flags)
    }

    /// Instantaneous speed is the only "default" field — present unless bit 0
    /// (More Data) is set, in which case THIS packet is just a continuation of
    /// the previous and the speed slot is skipped too. Returns false when the
    /// packet is truncated, which means the rest of it can't be trusted either.
    @MainActor
    private func applyInstantaneousSpeed(_ bytes: [UInt8], at offset: Int) -> Bool {
        guard let speedRaw = Self.u16(bytes, at: offset) else { return false }
        let kmh = Double(speedRaw) / 100.0
        instantaneousSpeedMS = kmh > 0 ? kmh / 3.6 : nil
        return true
    }

    @MainActor
    private func applyInstantaneousPower(_ bytes: [UInt8], at offset: Int, flags: UInt16) {
        guard flags & 0x0040 != 0, let raw = Self.u16(bytes, at: offset) else { return }
        let watts = max(0, Int(Int16(bitPattern: raw)))
        instantaneousPowerWatts = watts > 0 ? watts : nil
    }

    /// Little-endian u16 at `offset`, or nil when the packet is too short.
    private static func u16(_ bytes: [UInt8], at offset: Int) -> UInt16? {
        guard bytes.count >= offset + 2 else { return nil }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
}
