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
//   - Log a line (debug log) per mid-workout reconnect so debugging is possible.
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

/// The measurement subscriptions a BLE sensor link is waiting on, from
/// service discovery to the notification-state answer for each
/// characteristic. A link counts as connected only once a subscription is
/// confirmed; when every awaited step has failed and none is confirmed, the
/// link can deliver nothing and is ended rather than left looking connected.
struct BLESubscriptionTally {
    /// Characteristics whose notifications the sensor confirmed.
    private(set) var confirmed: Set<CBUUID> = []
    private var awaited = 0

    /// A fresh link: nothing confirmed, nothing awaited.
    mutating func reset() {
        confirmed = []
        awaited = 0
    }

    /// Discovery found `steps` services, each now looked into.
    mutating func expect(_ steps: Int) {
        awaited = steps
    }

    /// One awaited step finished and opened `next` further ones (a service's
    /// characteristics found, each now subscribing; zero when it failed).
    /// True when nothing is awaited and nothing is confirmed.
    mutating func settle(opening next: Int = 0) -> Bool {
        awaited = max(0, awaited - 1) + next
        return awaited == 0 && confirmed.isEmpty
    }

    /// The sensor confirmed notifications on `characteristic`.
    mutating func confirm(_ characteristic: CBUUID) {
        confirmed.insert(characteristic)
        awaited = max(0, awaited - 1)
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
    /// Most-recent speed in m/s, as last reported (nil when it reported 0).
    /// Read it through `currentSpeedMS(now:)`, which drops a stale one.
    private(set) var instantaneousSpeedMS: Double?
    /// Running cadence in steps per minute from the pod. An FTMS indoor bike
    /// reports crank revolutions per minute here instead (`parseIndoorBikeData`).
    /// Read it through `currentCadenceStepsPerMin(now:)`.
    private(set) var cadenceStepsPerMin: Double?
    /// Stride length (m) when the pod reports it. Read it through
    /// `currentStrideLengthMeters(now:)`.
    private(set) var strideLengthMeters: Double?
    /// When each of the readings above last arrived.
    @ObservationIgnored private(set) var speedMeasuredAt: Date?
    @ObservationIgnored private(set) var cadenceMeasuredAt: Date?
    @ObservationIgnored private(set) var strideMeasuredAt: Date?
    /// Pod-reported cumulative distance (m). The pod zeroes this at its own
    /// discretion (typically power-on), so treat as monotonic within a session
    /// after the first reading. Cleared on a disconnect outside a workout.
    private(set) var podReportedDistanceMeters: Double?
    /// Instantaneous power in watts (from Cycling Power Service — Stryd uses
    /// this for running power too). Nil if the pod doesn't publish power.
    /// Zero is a measurement (coasting, standing on a stopped belt), not a
    /// missing reading, and is kept as zero.
    private(set) var instantaneousPowerWatts: Int?
    /// When `instantaneousPowerWatts` last arrived.
    @ObservationIgnored private(set) var powerMeasuredAt: Date?

    /// A reading (power, speed, cadence, stride) older than this is not
    /// current: a sensor that stops notifying (the runner stopped and the
    /// pod slept, or it went out of range) without dropping the link leaves
    /// its last values behind. Power meters, RSC pods and FTMS trainers
    /// notify about once a second.
    nonisolated static let readingStaleAfter: TimeInterval = 5

    /// The power reading if it arrived within `readingStaleAfter` of `now`.
    func currentPowerWatts(now: Date = Date()) -> Int? {
        Self.fresh(instantaneousPowerWatts, measuredAt: powerMeasuredAt, now: now)
    }

    /// The speed if it arrived within `readingStaleAfter` of `now`.
    func currentSpeedMS(now: Date = Date()) -> Double? {
        Self.fresh(instantaneousSpeedMS, measuredAt: speedMeasuredAt, now: now)
    }

    /// The cadence if it arrived within `readingStaleAfter` of `now`.
    func currentCadenceStepsPerMin(now: Date = Date()) -> Double? {
        Self.fresh(cadenceStepsPerMin, measuredAt: cadenceMeasuredAt, now: now)
    }

    /// The stride length if it arrived within `readingStaleAfter` of `now`.
    func currentStrideLengthMeters(now: Date = Date()) -> Double? {
        Self.fresh(strideLengthMeters, measuredAt: strideMeasuredAt, now: now)
    }

    /// `value` while it is no older than `readingStaleAfter`, else nil.
    nonisolated static func fresh<Value>(_ value: Value?, measuredAt: Date?, now: Date) -> Value? {
        guard let value, let measuredAt, now.timeIntervalSince(measuredAt) <= readingStaleAfter else { return nil }
        return value
    }

    /// Store a power reading, negative values (a measurement artifact, e.g.
    /// standing still on a treadmill) clamped to zero.
    @MainActor
    private func recordPower(_ raw: Int16, at now: Date) {
        instantaneousPowerWatts = max(0, Int(raw))
        powerMeasuredAt = now
    }

    /// Store a speed reading; 0 m/s is kept as no speed.
    @MainActor
    private func recordSpeed(_ metersPerSecond: Double, at now: Date) {
        instantaneousSpeedMS = metersPerSecond > 0 ? metersPerSecond : nil
        speedMeasuredAt = now
    }

    /// Store a cadence reading; 0 is kept as no cadence.
    @MainActor
    private func recordCadence(_ perMinute: Double, at now: Date) {
        cadenceStepsPerMin = perMinute > 0 ? perMinute : nil
        cadenceMeasuredAt = now
    }
    /// Known / remembered devices — shown as "Reconnect to X" in UI.
    private(set) var knownDevices: [KnownFootPod] = []
    /// The peripheral id of the sensor connected or being connected now; nil
    /// while none is. The sensor sheet titles the row with it, so the row
    /// names the linked sensor rather than the first one paired.
    private(set) var linkedDeviceId: String?
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
    /// Without it, a drop ends cadence, pace and power for the rest of the
    /// workout.
    @ObservationIgnored private var expectsLink = false
    /// True from a workout's start to its stop. Outside a workout a drop is
    /// left alone, so the app doesn't hold a connection request open for a
    /// sensor nobody is using.
    @ObservationIgnored private var workoutHoldsLink = false
    /// The linked sensor's advertised name, for status lines and the
    /// remembered-device list.
    @ObservationIgnored private var linkedName: String?
    /// The measurement subscriptions the linked sensor is setting up.
    @ObservationIgnored private var subscriptions = BLESubscriptionTally()
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
    private let defaults: UserDefaults

    // MARK: - Init

    /// Reads the remembered devices only; the central is built on first use.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
            Task { @MainActor in self?.endTimedOutScan() }
        }
    }

    /// The sensor a parked reconnect was scanning for did not appear, so the
    /// reconnect ends with the scan; left parked, a later unrelated scan or
    /// Bluetooth power-on would attach it outside any workout.
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

    /// Try to reconnect to the most-recently paired device (if any).
    func reconnectLast() {
        guard let last = knownDevices.first else { return }
        connect(deviceId: last.id)
    }

    /// Called at a workout's start and stop. At the stop, a reconnect still
    /// waiting for the sensor — a connect in flight or an id parked while
    /// Bluetooth was off — is cancelled.
    func holdLinkForWorkout(_ holds: Bool) {
        workoutHoldsLink = holds
        guard !holds, expectsLink else { return }
        pendingReconnectId = nil
        if connectionState == .connecting { disconnect() }
    }

    func disconnect() {
        expectsLink = false
        if let p = activePeripheral {
            centralIfCreated?.cancelPeripheralConnection(p)
        }
        // Teardown state here too: the cancellation's own callback is for a
        // device no longer linked, so it changes nothing.
        lastStatusLine = String(localized: "Disconnected", bundle: LanguageManager.appBundle)
        cleanupAfterDisconnect()
    }

    func removeKnownDevice(id: String) {
        knownDevices.removeAll { $0.id == id }
        saveKnownDevices()
    }

    // MARK: - Internal

    /// Links `peripheral`, cancelling the connection to any other sensor
    /// first: one foot pod at a time, and a link left open to the previous
    /// one would keep its callbacks coming.
    func attach(peripheral: CBPeripheral) {
        if let previous = activePeripheral, previous.identifier != peripheral.identifier {
            centralIfCreated?.cancelPeripheralConnection(previous)
        }
        claimLink(peripheral.identifier, name: peripheral.name)
        activePeripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    /// Makes `id` the sensor this manager answers to. Every connection,
    /// discovery and measurement callback checks the device it is about
    /// against this, so a late callback from a sensor switched away from
    /// cannot change the linked one's state. Switching drops the previous
    /// sensor's readings.
    func claimLink(_ id: UUID, name: String?) {
        if let linkedDeviceId, linkedDeviceId != id.uuidString { cleanupAfterDisconnect() }
        linkedDeviceId = id.uuidString
        linkedName = name
        connectionState = .connecting
        let shown = name ?? String(localized: "foot pod", bundle: LanguageManager.appBundle)
        lastStatusLine = String(localized: "Connecting to \(shown)…", bundle: LanguageManager.appBundle)
    }

    /// Whether `id` is the sensor connected or being connected now.
    func isLinked(_ id: UUID) -> Bool {
        linkedDeviceId == id.uuidString
    }

    /// The odometer reading survives a link loss mid-workout (the pod keeps
    /// counting and the workout's baseline still applies when it comes back);
    /// otherwise it is cleared, so the next workout can't take a previous
    /// session's reading as its starting point.
    private func cleanupAfterDisconnect() {
        activePeripheral = nil
        linkedDeviceId = nil
        linkedName = nil
        subscriptions.reset()
        instantaneousSpeedMS = nil
        cadenceStepsPerMin = nil
        strideLengthMeters = nil
        speedMeasuredAt = nil
        cadenceMeasuredAt = nil
        strideMeasuredAt = nil
        instantaneousPowerWatts = nil
        powerMeasuredAt = nil
        if !workoutHoldsLink { podReportedDistanceMeters = nil }
        connectionState = .disconnected
    }

    private func rememberLinkedDevice() {
        guard let id = linkedDeviceId else { return }
        let name = linkedName ?? String(localized: "Foot pod", bundle: LanguageManager.appBundle)
        let supportsPower = !subscriptions.confirmed.isDisjoint(with: [Self.cyclingPowerMeasurementChar_UUID, Self.indoorBikeDataChar_UUID])
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
        defaults.set(data, forKey: knownDevicesKey)
    }

    private func loadKnownDevices() {
        guard let data = defaults.data(forKey: knownDevicesKey),
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
            guard self.linkConnected(peripheral.identifier) else { return }
            peripheral.delegate = self
            peripheral.discoverServices([Self.runningSpeedCadenceService, Self.cyclingPowerService, Self.fitnessMachineService])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            guard self.linkFailedToConnect(peripheral.identifier, error: error) else { return }
            self.retryConnect(peripheral)
        }
    }

    /// A reconnect that failed mid-workout is asked for again after a short
    /// pause (a failure can come back at once, so not in a tight loop), so
    /// one failure does not end pace, cadence and power for the rest of the
    /// workout.
    @MainActor
    private func retryConnect(_ peripheral: CBPeripheral) {
        debugLog("[FootPod] Reconnect failed mid-workout — asking again")
        Task { @MainActor [weak self] in
            await sleepQuietly(2_000_000_000, context: "foot pod reconnect after a failed connect")
            guard let self, self.expectsLink, self.workoutHoldsLink, self.connectionState == .disconnected else { return }
            self.attach(peripheral: peripheral)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            guard self.linkDropped(peripheral.identifier) else { return }
            self.attach(peripheral: peripheral)
        }
    }
}

// MARK: - Link lifecycle

/// What each delegate callback does to this manager's state, keyed by the
/// device it is about. The delegate methods hand CoreBluetooth the follow-up
/// (discover, subscribe, reconnect) when these say to; tests drive these
/// directly with made-up device ids.
extension FootPodManager {
    /// The link to `id` is up; measurements are set up next. The state stays
    /// `.connecting` until a subscription is confirmed. False when `id` is not
    /// the linked sensor.
    func linkConnected(_ id: UUID) -> Bool {
        guard isLinked(id) else { return false }
        expectsLink = true
        subscriptions.reset()
        return true
    }

    /// The connection to `id` failed. True when it should be asked for again
    /// (mid-workout).
    func linkFailedToConnect(_ id: UUID, error: Error?) -> Bool {
        guard isLinked(id) else { return false }
        lastStatusLine = Self.connectFailedLine(error)
        cleanupAfterDisconnect()
        return expectsLink && workoutHoldsLink
    }

    /// The link to `id` dropped. True when it should be asked for again
    /// (a drop mid-workout that nobody asked for).
    func linkDropped(_ id: UUID) -> Bool {
        guard isLinked(id) else { return false }
        lastStatusLine = String(localized: "Disconnected", bundle: LanguageManager.appBundle)
        cleanupAfterDisconnect()
        guard expectsLink, workoutHoldsLink else { return false }
        debugLog("[FootPod] Link dropped mid-workout: reconnecting")
        return true
    }

    /// Service discovery on `id` finished with `recognised` measurement
    /// services. True when their characteristics should be looked up; with
    /// none, or on an error, the link ends.
    func linkFoundServices(_ id: UUID, recognised: Int, error: Error?) -> Bool {
        guard isLinked(id) else { return false }
        guard error == nil, recognised > 0 else {
            endFailedLink(error)
            return false
        }
        subscriptions.expect(recognised)
        return true
    }

    /// One service's lookup on `id` found `measurements`. True when they
    /// should be subscribed to; when the lookup failed and nothing else is
    /// pending or confirmed, the link ends.
    func linkFoundCharacteristics(_ id: UUID, measurements: [CBUUID], error: Error?) -> Bool {
        guard isLinked(id) else { return false }
        let found = error == nil ? measurements.count : 0
        if subscriptions.settle(opening: found) { endFailedLink(error) }
        return found > 0
    }

    /// The sensor answered a subscription request. A confirmed one makes the
    /// link connected and remembers the device; when every request failed,
    /// the link ends, since recording would receive nothing.
    func linkNotificationChanged(_ id: UUID, characteristic: CBUUID, isNotifying: Bool, error: Error?) {
        guard isLinked(id) else { return }
        guard error == nil, isNotifying else {
            if subscriptions.settle() { endFailedLink(error) }
            return
        }
        subscriptions.confirm(characteristic)
        connectionState = .connected
        let name = linkedName ?? String(localized: "foot pod", bundle: LanguageManager.appBundle)
        lastStatusLine = String(localized: "Connected to \(name)", bundle: LanguageManager.appBundle)
        rememberLinkedDevice()
    }

    /// A measurement notification from `id`, stamped `now`; one from any
    /// other device is dropped, so a sensor switched away from cannot fill in
    /// this one's readings.
    func receivedMeasurement(_ data: Data, characteristic: CBUUID, from id: UUID, now: Date = Date()) {
        guard isLinked(id) else { return }
        switch characteristic {
        case Self.rscMeasurementChar_UUID: parseRSC(data: data, now: now)
        case Self.cyclingPowerMeasurementChar_UUID: parsePower(data: data, now: now)
        case Self.indoorBikeDataChar_UUID: parseIndoorBikeData(data: data, now: now)
        default: break
        }
    }

    /// A link that cannot deliver measurements is ended rather than left
    /// showing connected; mid-workout it is asked for again, as after a
    /// failed connect.
    private func endFailedLink(_ error: Error?) {
        let peripheral = activePeripheral
        if let peripheral { centralIfCreated?.cancelPeripheralConnection(peripheral) }
        lastStatusLine = Self.connectFailedLine(error)
        cleanupAfterDisconnect()
        guard expectsLink, workoutHoldsLink, let peripheral else { return }
        retryConnect(peripheral)
    }

    private static func connectFailedLine(_ error: Error?) -> String {
        let err = error?.localizedDescription ?? String(localized: "unknown error", bundle: LanguageManager.appBundle)
        return String(localized: "Connect failed: \(err)", bundle: LanguageManager.appBundle)
    }
}

// MARK: - CBPeripheralDelegate

extension FootPodManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            let services = (peripheral.services ?? []).filter { Self.measurementCharacteristic(for: $0.uuid) != nil }
            guard self.linkFoundServices(peripheral.identifier, recognised: services.count, error: error) else { return }
            Self.discoverMeasurementCharacteristics(on: peripheral, in: services)
        }
    }

    /// Only the measurement characteristic of each recognised service is
    /// requested: discovering everything wakes characteristics we never read.
    @MainActor
    private static func discoverMeasurementCharacteristics(on peripheral: CBPeripheral, in services: [CBService]) {
        for service in services {
            guard let characteristic = measurementCharacteristic(for: service.uuid) else { continue }
            peripheral.discoverCharacteristics([characteristic], for: service)
        }
    }

    /// The one measurement characteristic we care about on each supported
    /// service; nil for any other service the peripheral happens to advertise.
    nonisolated private static func measurementCharacteristic(for serviceUUID: CBUUID) -> CBUUID? {
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
            let wanted = Self.measurementCharacteristic(for: service.uuid)
            let found = (service.characteristics ?? []).filter { $0.uuid == wanted }
            let id = peripheral.identifier
            guard self.linkFoundCharacteristics(id, measurements: found.map(\.uuid), error: error) else { return }
            for characteristic in found { peripheral.setNotifyValue(true, for: characteristic) }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = characteristic.uuid
        let isNotifying = characteristic.isNotifying
        Task { @MainActor in
            self.linkNotificationChanged(peripheral.identifier, characteristic: uuid, isNotifying: isNotifying, error: error)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value else { return }
        let uuid = characteristic.uuid
        Task { @MainActor in
            self.receivedMeasurement(data, characteristic: uuid, from: peripheral.identifier)
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
    private func parseRSC(data: Data, now: Date) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, let speedRaw = Self.u16(bytes, at: 1) else { return }
        let flags = bytes[0]
        recordSpeed(Double(speedRaw) / 256.0, at: now)
        recordCadence(Double(bytes[3]), at: now)
        var offset = 4
        if flags & 0x01 != 0 {
            if let strideRaw = Self.u16(bytes, at: offset) {
                strideLengthMeters = Double(strideRaw) / 100.0
                strideMeasuredAt = now
            }
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
    private func parsePower(data: Data, now: Date) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return }
        let lo = UInt16(bytes[2])
        let hi = UInt16(bytes[3])
        let raw = lo | (hi << 8)
        recordPower(Int16(bitPattern: raw), at: now)
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
    private func parseIndoorBikeData(data: Data, now: Date) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return }
        let flags = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        var offset = 2
        if flags & 0x0001 == 0 {
            guard applyInstantaneousSpeed(bytes, at: offset, now: now) else { return }
            offset += 2
        }
        offset += (flags & 0x0002 != 0 ? 2 : 0) // Average Speed (skip)
        if flags & 0x0004 != 0 {                // Instantaneous Cadence (0.5/min units)
            if let cadRaw = Self.u16(bytes, at: offset) { recordCadence(Double(cadRaw) / 2.0, at: now) }
            offset += 2
        }
        // Average Cadence (2), Total Distance u24 (3), Resistance Level (2).
        offset += (flags & 0x0008 != 0 ? 2 : 0) + (flags & 0x0010 != 0 ? 3 : 0) + (flags & 0x0020 != 0 ? 2 : 0)
        applyInstantaneousPower(bytes, at: offset, flags: flags, now: now)
    }

    /// Instantaneous speed is the only "default" field — present unless bit 0
    /// (More Data) is set, in which case THIS packet is just a continuation of
    /// the previous and the speed slot is skipped too. Returns false when the
    /// packet is truncated, which means the rest of it can't be trusted either.
    @MainActor
    private func applyInstantaneousSpeed(_ bytes: [UInt8], at offset: Int, now: Date) -> Bool {
        guard let speedRaw = Self.u16(bytes, at: offset) else { return false }
        recordSpeed(Double(speedRaw) / 100.0 / 3.6, at: now)
        return true
    }

    @MainActor
    private func applyInstantaneousPower(_ bytes: [UInt8], at offset: Int, flags: UInt16, now: Date) {
        guard flags & 0x0040 != 0, let raw = Self.u16(bytes, at: offset) else { return }
        recordPower(Int16(bitPattern: raw), at: now)
    }

    /// Little-endian u16 at `offset`, or nil when the packet is too short.
    private static func u16(_ bytes: [UInt8], at offset: Int) -> UInt16? {
        guard bytes.count >= offset + 2 else { return nil }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
}
