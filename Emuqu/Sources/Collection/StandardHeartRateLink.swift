@preconcurrency import CoreBluetooth
import Foundation

/// Live heart rate straight from the strap's standard Heart Rate Service.
///
/// ## Why the app reads this itself
///
/// The Polar SDK delivers heart rate only after it has set the whole strap up:
/// every service discovered in one step, every characteristic, every readable
/// value read, notifications enabled one at a time. On a link the app built
/// that took seconds; on a link the phone already had open when the app
/// connected, the discovery step alone took 16–23 s in field logs and the
/// first beat arrived 25–70 s in. Heart rate needs none of that — one service,
/// one characteristic, one subscription — and it is what every heart-rate app
/// reads, which is why they show a beat as soon as they open.
///
/// So live beats come from here, asking iOS for the Heart Rate Service alone,
/// and the SDK keeps doing everything that is Polar-specific — the H10's own
/// recording, the Verity's PPI stream, file transfer — in the background.
/// Nothing waits on it for a beat.
///
/// ## The connection
///
/// The SDK builds the link; this attaches to the same strap by its
/// CoreBluetooth identifier, which the SDK reports with its connection, through
/// a `CBCentralManager` of its own. iOS keeps one physical link per strap and
/// shares it between the two. The connection made here is held for as long as
/// the SDK's link lasts: a subscription that ends and re-opens only turns
/// notifications off and on. `releaseAll()` lets go when the SDK's link ends —
/// a drop, the user's disconnect, a reset — so this never keeps the strap
/// connected after the app meant it to go.
///
/// A disconnect callback counts only while the strap is actually disconnected.
/// The one that answers `releaseAll()` can arrive after a new subscription has
/// already started reconnecting; by then the strap is connecting again, and
/// that callback is about the connection that was let go.
///
/// ## Threading
///
/// The central runs on the main queue, so every delegate callback arrives on
/// the main thread in the order iOS delivered it; `MainActor.assumeIsolated`
/// states that rather than hopping through a `Task`, which would not preserve
/// the order of the beats.
@MainActor
final class StandardHeartRateLink: NSObject {
    enum LinkError: Error, Equatable {
        /// The SDK has not reported which peripheral the strap is, or iOS does
        /// not know it.
        case strapNotConnected
        /// Bluetooth is off or the app is not allowed to use it.
        case bluetoothUnavailable
        /// The strap does not publish the Heart Rate Service.
        case serviceNotFound
        /// The link dropped while subscribed.
        case disconnected
    }

    static let heartRateService = CBUUID(string: "180D")
    static let heartRateMeasurement = CBUUID(string: "2A37")

    /// Created on the first subscription, not at launch: the app does not stand
    /// up a Bluetooth central before the user connects a strap.
    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    /// The strap this central is connected (or connecting) to.
    private var held: CBPeripheral?
    /// Its Heart Rate Measurement characteristic, once discovered.
    private var measurement: CBCharacteristic?
    private var active: Subscription?

    private struct Subscription {
        let id: UUID
        let peripheralId: UUID
        let continuation: AsyncThrowingStream<[StrapHRSample], Error>.Continuation
        let startedAt: Date
        var delivered = false
        var reportedValueError = false
    }

    /// Heart-rate samples from the strap whose CoreBluetooth identifier is
    /// `peripheralId`, until the stream is cancelled or the link drops. One
    /// subscription at a time: a new one ends the previous, as the feed opens
    /// exactly one per link.
    func samples(peripheralId: UUID?) -> AsyncThrowingStream<[StrapHRSample], Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [StrapHRSample].self)
        guard let peripheralId else {
            continuation.finish(throwing: LinkError.strapNotConnected)
            return stream
        }
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.end(id) }
        }
        if let previous = active { finish(previous, throwing: nil) }
        active = Subscription(id: id, peripheralId: peripheralId, continuation: continuation, startedAt: Date())
        attach()
        return stream
    }

    /// Lets go of the strap: ends the subscription and cancels this central's
    /// connection. Called whenever the SDK's link ends.
    func releaseAll() {
        if let active { finish(active, throwing: nil) }
        guard let peripheral = held else { return }
        held = nil
        measurement = nil
        guard central.state == .poweredOn, peripheral.state != .disconnected else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    /// Brings the active subscription as far as it can go now; each callback
    /// that moves the connection on calls back in.
    private func attach() {
        guard let subscription = active else { return }
        switch central.state {
        case .poweredOn: break
        case .unknown, .resetting: return
        default:
            finish(subscription, throwing: LinkError.bluetoothUnavailable)
            return
        }
        if let peripheral = held, peripheral.identifier == subscription.peripheralId {
            if peripheral.state == .connected { subscribe(on: peripheral) }
            return
        }
        connect(to: subscription)
    }

    private func connect(to subscription: Subscription) {
        releaseHeldPeripheral()
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [subscription.peripheralId]).first else {
            finish(subscription, throwing: LinkError.strapNotConnected)
            return
        }
        peripheral.delegate = self
        held = peripheral
        central.connect(peripheral)
    }

    /// A subscription for a different strap than the one held.
    private func releaseHeldPeripheral() {
        guard let peripheral = held else { return }
        held = nil
        measurement = nil
        if peripheral.state != .disconnected { central.cancelPeripheralConnection(peripheral) }
    }

    private func subscribe(on peripheral: CBPeripheral) {
        guard let measurement else {
            peripheral.discoverServices([Self.heartRateService])
            return
        }
        peripheral.setNotifyValue(true, for: measurement)
    }

    private func end(_ id: UUID) {
        guard let subscription = active, subscription.id == id else { return }
        active = nil
        stopNotifying()
    }

    private func finish(_ subscription: Subscription, throwing error: Error?) {
        if active?.id == subscription.id {
            active = nil
            stopNotifying()
        }
        subscription.continuation.finish(throwing: error)
    }

    /// Ends the notifications, not the connection: the next subscription on
    /// this link turns them back on.
    private func stopNotifying() {
        guard let peripheral = held, peripheral.state == .connected, let measurement else { return }
        peripheral.setNotifyValue(false, for: measurement)
    }

    private func isHeld(_ peripheral: CBPeripheral) -> Bool {
        held?.identifier == peripheral.identifier
    }

    fileprivate func powerChanged() {
        if central.state != .poweredOn {
            held = nil
            measurement = nil
        }
        attach()
    }

    fileprivate func connected(_ peripheral: CBPeripheral) {
        guard isHeld(peripheral), active != nil else { return }
        subscribe(on: peripheral)
    }

    fileprivate func lost(_ peripheral: CBPeripheral, error: Error?) {
        guard isHeld(peripheral), peripheral.state == .disconnected else { return }
        held = nil
        measurement = nil
        if let active { finish(active, throwing: error ?? LinkError.disconnected) }
    }

    fileprivate func discoveredServices(on peripheral: CBPeripheral, error: Error?) {
        guard isHeld(peripheral), let subscription = active else { return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.heartRateService }) else {
            finish(subscription, throwing: error ?? LinkError.serviceNotFound)
            return
        }
        peripheral.discoverCharacteristics([Self.heartRateMeasurement], for: service)
    }

    fileprivate func discoveredCharacteristics(of service: CBService, on peripheral: CBPeripheral, error: Error?) {
        guard isHeld(peripheral), let subscription = active else { return }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.heartRateMeasurement }) else {
            finish(subscription, throwing: error ?? LinkError.serviceNotFound)
            return
        }
        measurement = characteristic
        peripheral.setNotifyValue(true, for: characteristic)
    }

    /// Turning notifications on is the step the strap can refuse; a refusal
    /// ends the subscription so the feed tries again rather than waiting on
    /// beats that will not come.
    fileprivate func notificationStateChanged(on peripheral: CBPeripheral, error: Error?) {
        guard let error, isHeld(peripheral), let subscription = active else { return }
        finish(subscription, throwing: error)
    }

    fileprivate func received(_ data: Data, from peripheral: CBPeripheral) {
        guard isHeld(peripheral), var subscription = active, let sample = HeartRateMeasurement.parse(data) else { return }
        if !subscription.delivered {
            subscription.delivered = true
            active = subscription
            let seconds = Date().timeIntervalSince(subscription.startedAt)
            debugLog("[PolarManager] Heart Rate Service delivering — first sample \(String(format: "%.1f", seconds)) s after subscribing")
        }
        subscription.continuation.yield([sample])
    }

    /// Logged once per subscription: a strap that keeps failing reads would
    /// otherwise write a line every beat.
    fileprivate func receiveFailed(from peripheral: CBPeripheral, error: Error) {
        guard isHeld(peripheral), var subscription = active, !subscription.reportedValueError else { return }
        subscription.reportedValueError = true
        active = subscription
        debugLog("[PolarManager] Heart Rate Service read failed: \(error.localizedDescription)")
    }
}

extension StandardHeartRateLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { powerChanged() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { connected(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { lost(peripheral, error: error) }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        MainActor.assumeIsolated { lost(peripheral, error: error) }
    }
}

extension StandardHeartRateLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { discoveredServices(on: peripheral, error: error) }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        MainActor.assumeIsolated { discoveredCharacteristics(of: service, on: peripheral, error: error) }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        MainActor.assumeIsolated { notificationStateChanged(on: peripheral, error: error) }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        let data = characteristic.value
        MainActor.assumeIsolated {
            guard characteristic.uuid == Self.heartRateMeasurement else { return }
            if let error {
                receiveFailed(from: peripheral, error: error)
            } else if let data {
                received(data, from: peripheral)
            }
        }
    }
}
