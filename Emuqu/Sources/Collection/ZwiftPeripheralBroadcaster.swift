@preconcurrency import CoreBluetooth
import Foundation

// MARK: - ZwiftPeripheralBroadcaster
//
// Makes the iPhone show up to Zwift (or any BLE-aware indoor-cycling app)
// as a Heart Rate + Cycling Power sensor. Zwift has no API to push data
// IN, so the integration model is reversed: we BROADCAST our merged
// strap-HR + Stryd / FTMS power as standard BLE peripherals, Zwift sees
// us as a sensor and pairs.
//
// Use case: indoor trainer rider whose Stryd is strapped to their shoe and
// whose Polar H10 is on their chest. Both already pair with Emuqu
// for HRV / TRIMP capture. Without this broadcaster they'd have to either
// (a) disconnect from Emuqu while riding so Zwift can pair with
// the strap directly, or (b) use a separate BLE bridge accessory. Now
// Emuqu does the bridging in software — one ride, full HRV
// capture in Emuqu AND live HR + power in Zwift.
//
// Standard BLE profiles used (no proprietary anything):
//   • Heart Rate Service     0x180D, Heart Rate Measurement char 0x2A37
//   • Cycling Power Service  0x1818, Cycling Power Measurement   0x2A63,
//                            Cycling Power Feature              0x2A65,
//                            Sensor Location                    0x2A5D
//
// Spec: bluetooth.com/specifications. Zwift confirms support for any BLE
// HRS / CPS sensor: support.zwift.com/en_us/ant-and-ble-overview-B1S1BVgr
@Observable
@MainActor
final class ZwiftPeripheralBroadcaster: NSObject {
    static let shared = ZwiftPeripheralBroadcaster()

    // MARK: Public state

    // NOTE: `isAdvertising` / `subscriberCount` are read by AI live-state
    // resolution (AppFactResolver+Live) even when the Zwift broadcaster
    // feature is OFF. Their getters MUST NOT touch `peripheralManager`, or
    // they'd force-create the CBPeripheralManager and trigger the iOS
    // bluetooth-peripheral permission prompt on users who never enabled the
    // feature. The manager is created lazily in `startBroadcasting()`.
    private(set) var isAdvertising: Bool = false
    private(set) var subscriberCount: Int = 0
    /// A broadcast was asked for and not stopped. A new peripheral manager
    /// reports `.unknown` until the radio answers, so the request is kept and
    /// carried out when the state turns `.poweredOn`.
    @ObservationIgnored private var wantsBroadcast = false

    // MARK: BLE infra

    // Created lazily on first `startBroadcasting()` — NOT in `init()` — to
    // avoid triggering the BT-peripheral permission prompt when the feature
    // is off (the default). nil until then.
    @ObservationIgnored private var peripheralManager: CBPeripheralManager?
    @ObservationIgnored private var hrMeasurementChar: CBMutableCharacteristic?
    @ObservationIgnored private var cpMeasurementChar: CBMutableCharacteristic?
    @ObservationIgnored private var cpFeatureChar: CBMutableCharacteristic?
    @ObservationIgnored private var sensorLocationChar: CBMutableCharacteristic?
    private var subscribedCentrals: Set<CBCentral> = []

    // MARK: Service / characteristic UUIDs (BLE SIG)

    nonisolated static let heartRateService = CBUUID(string: "180D")
    nonisolated static let heartRateMeasurementChar_UUID = CBUUID(string: "2A37")
    nonisolated static let cyclingPowerService = CBUUID(string: "1818")
    nonisolated static let cyclingPowerMeasurementChar_UUID = CBUUID(string: "2A63")
    nonisolated static let cyclingPowerFeatureChar_UUID = CBUUID(string: "2A65")
    nonisolated static let sensorLocationChar_UUID = CBUUID(string: "2A5D")

    override init() {
        super.init()
        // Intentionally do NOT create the CBPeripheralManager here — see the
        // note on `peripheralManager`. It's created on first broadcast.
    }

    // MARK: Public control

    /// Begin advertising HRS + CPS. Safe to call before BT is powered on —
    /// the request is remembered and `peripheralManagerDidUpdateState`
    /// starts advertising once the radio is ready.
    func startBroadcasting() {
        wantsBroadcast = true
        let manager = existingOrNewPeripheralManager()
        guard manager.state == .poweredOn else {
            debugLog("[Zwift] Waiting for Bluetooth before advertising")
            return
        }
        if isAdvertising { return }
        // A failed advertise leaves its services registered; adding them
        // again would list each one twice.
        manager.removeAllServices()
        configureServices()
        manager.startAdvertising([
            CBAdvertisementDataLocalNameKey: "Emuqu",
            CBAdvertisementDataServiceUUIDsKey: [Self.heartRateService, Self.cyclingPowerService]
        ])
        isAdvertising = true
    }

    /// Lazily create the peripheral manager on first use. This is the only
    /// place that instantiates it, so the BT-peripheral permission prompt only
    /// appears once the user actually starts the Zwift broadcaster.
    private func existingOrNewPeripheralManager() -> CBPeripheralManager {
        if let existing = peripheralManager { return existing }
        let manager = CBPeripheralManager(delegate: self, queue: .main)
        peripheralManager = manager
        return manager
    }

    func stopBroadcasting() {
        wantsBroadcast = false
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        isAdvertising = false
        subscribedCentrals.removeAll()
        subscriberCount = 0
    }

    /// Push the latest heart rate + power values out to any subscribed
    /// centrals (Zwift). Call at workout-recorder tick rate (~1 Hz).
    /// Either argument can be nil — broadcasts whichever profile has data.
    func update(heartRate: Int?, powerWatts: Int?) {
        guard isAdvertising, let peripheralManager else { return }
        if let hr = heartRate, hr > 0, let char = hrMeasurementChar {
            // HR Measurement layout: byte 0 flags, then BPM. Flag bit 0 = 0
            // means BPM is uint8 (range 0-255, perfectly enough for HR).
            let data = Data([0x00, UInt8(min(255, max(0, hr)))])
            peripheralManager.updateValue(data, for: char, onSubscribedCentrals: nil)
        }
        if let watts = powerWatts, watts >= 0, let char = cpMeasurementChar {
            // CPS Measurement layout: bytes 0–1 flags (u16, little-endian),
            // bytes 2–3 instantaneous power (int16, watts). We only set
            // the mandatory power field — no pedal balance, no crank revs,
            // no torque. Zwift only needs the power.
            let clamped = Int16(min(2000, max(0, watts)))
            let raw = UInt16(bitPattern: clamped)
            let data = Data([
                0x00, 0x00,                       // flags = 0 → only mandatory power present
                UInt8(raw & 0xFF), UInt8(raw >> 8)
            ])
            peripheralManager.updateValue(data, for: char, onSubscribedCentrals: nil)
        }
    }

    // MARK: Internal

    private func configureServices() {
        peripheralManager?.add(heartRateService())
        peripheralManager?.add(cyclingPowerService())
    }

    private func heartRateService() -> CBMutableService {
        let hrService = CBMutableService(type: Self.heartRateService, primary: true)
        let hrChar = CBMutableCharacteristic(
            type: Self.heartRateMeasurementChar_UUID,
            properties: [.notify],
            value: nil,
            permissions: []
        )
        hrService.characteristics = [hrChar]
        self.hrMeasurementChar = hrChar
        return hrService
    }

    /// CP Feature is a mandatory READ characteristic (32-bit bitfield). We
    /// declare zero features — meaning we only support instantaneous power, no
    /// pedal balance / accumulated torque / wheel revs / etc.
    ///
    /// Sensor Location is also required by spec. 0x06 = "Hip", reasonable for a
    /// phone in a jersey pocket. Zwift just needs the byte to be present and
    /// valid; the specific location doesn't change behaviour.
    private func cyclingPowerService() -> CBMutableService {
        let cpService = CBMutableService(type: Self.cyclingPowerService, primary: true)
        let cpMeasurement = CBMutableCharacteristic(
            type: Self.cyclingPowerMeasurementChar_UUID, properties: [.notify], value: nil, permissions: []
        )
        let cpFeature = Self.readOnlyCharacteristic(Self.cyclingPowerFeatureChar_UUID, value: Data([0x00, 0x00, 0x00, 0x00]))
        let sensorLocation = Self.readOnlyCharacteristic(Self.sensorLocationChar_UUID, value: Data([0x06]))
        cpService.characteristics = [cpMeasurement, cpFeature, sensorLocation]
        self.cpMeasurementChar = cpMeasurement
        self.cpFeatureChar = cpFeature
        self.sensorLocationChar = sensorLocation
        return cpService
    }

    private static func readOnlyCharacteristic(_ uuid: CBUUID, value: Data) -> CBMutableCharacteristic {
        CBMutableCharacteristic(type: uuid, properties: [.read], value: value, permissions: [.readable])
    }
}

// MARK: - CBPeripheralManagerDelegate

extension ZwiftPeripheralBroadcaster: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let state = peripheral.state
        Task { @MainActor in self.radioStateChanged(state) }
    }

    /// A broadcast asked for before the radio was ready starts now.
    private func radioStateChanged(_ state: CBManagerState) {
        guard state == .poweredOn else {
            isAdvertising = false
            return
        }
        if wantsBroadcast, !isAdvertising { startBroadcasting() }
    }

    nonisolated func peripheralManager(_: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        Task { @MainActor in
            self.subscribedCentrals.insert(central)
            self.subscriberCount = self.subscribedCentrals.count
        }
    }

    nonisolated func peripheralManager(_: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        Task { @MainActor in
            self.subscribedCentrals.remove(central)
            self.subscriberCount = self.subscribedCentrals.count
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_: CBPeripheralManager, error: Error?) {
        Task { @MainActor in
            if let error {
                debugLog("[Zwift] Advertising failed: \(error.localizedDescription)", level: .warning)
                self.isAdvertising = false
            }
        }
    }
}
