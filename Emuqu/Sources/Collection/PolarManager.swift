import AVFoundation
import CoreBluetooth
import Foundation
import os

#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

// RxSwift is gone as of Polar BLE SDK 8.2.0.
//
// The SDK dropped its RxSwift dependency, and the streaming APIs this app uses
// return `AsyncThrowingStream` directly. No `ObservableType.values` bridge
// (wrapping an Observable subscription in a continuation) is needed: the
// streams are already async sequences, and `for try await` iterates them
// natively.
//
// The upgrade was forced rather than opportunistic. RxSwift 6.5.0, which Polar
// 6.13.0 pinned exactly, ships no privacy manifest, and Apple requires one for
// RxSwift as a listed SDK. No version satisfies both constraints: 7.0/7.1 pin
// RxSwift 6.8.0 (which does have the manifest) but declare `path: "Sources"`
// while their repository keeps `Tests/` inside it, so SPM compiles their test
// files into the library and the package does not build for any consumer.
// 8.x narrowed that path and removed RxSwift altogether.

// MARK: - Device Type Detection

/// Identifies which Polar device is connected to select the correct SDK APIs
enum PolarDeviceType: String, Codable {
    case h10
    case veritySense

    /// Detect device type from the BLE advertised name
    static func from(deviceName: String) -> PolarDeviceType {
        let name = deviceName.lowercased()
        if name.contains("sense") || name.contains("verity") || name.contains("oh1") {
            return .veritySense
        }
        return .h10
    }

    var displayName: String {
        switch self {
        case .h10: "Polar H10"
        case .veritySense: "Polar Verity Sense"
        }
    }

    var icon: String {
        switch self {
        case .h10: "heart.fill"
        case .veritySense: "waveform.path.ecg"
        }
    }

    /// Manufacturer-quoted runtime per battery / charge cycle. Used to judge
    /// when a stale "100%" reading has likely lapped reality. The H10 spec is
    /// ~400 hours of training time on its CR2025 cell (Polar product page).
    /// Verity Sense quotes ~30 hours of streaming on a single charge.
    /// These are upper bounds — temperature, signal margin, and the cell's
    /// shelf life all shorten them. We only use them to flag staleness, not
    /// to render a "battery left" gauge, so being approximate is fine.
    var specRecordingHours: Double {
        switch self {
        case .h10: 400.0
        case .veritySense: 30.0
        }
    }
}

/// Manages Polar device connection and RR/PPI recording
/// Supports Polar H10 (ECG) and Verity Sense (optical PPG)
@Observable
@MainActor
final class PolarManager: NSObject {
    // MARK: - Published State

    var connectionState: ConnectionState = .disconnected
    var recordingState: RecordingState = .idle
    var connectedDeviceId: String?
    var connectedDeviceType: PolarDeviceType?
    /// Device ID of a connection attempt in progress (set during `.connecting`, cleared on connect/cancel).
    var pendingDeviceId: String?
    var discoveredDevices: [DiscoveredDevice] = []
    var knownDevices: [KnownDevice] = []
    var lastError: Error?
    var batteryLevel: Int?
    var isRecordingOnDevice: Bool = false
    var isH10RecordingFeatureReady: Bool = false
    var isHrStreamingReady: Bool = false // True when .feature_hr is ready for streaming
    var isOfflineRecordingReady: Bool = false // True when Verity Sense offline recording is ready
    var isCheckingRecordingStatus: Bool = false // True while checking device status on connect
    var hasPendingExercise: Bool = false

    /// Device-internal recording: start, stop, status, download. Lazy — a
    /// streaming-only user never builds it.
    var recording: StrapRecordingCoordinator {
        StrapRecordingCoordinator(manager: self)
    }

    // Forwarders for the call sites that reach recording through the manager.
    // The behaviour lives one reference away in `StrapRecordingCoordinator`.

    func startRecording() async throws { try await recording.startRecording() }
    func stopAndFetchRecording() async throws -> [RRPoint] { try await recording.stopAndFetchRecording() }
    func stopDeviceRecordingIfNeeded() async { await recording.stopDeviceRecordingIfNeeded() }
    func fetchExerciseDataQuick() async -> [RRPoint]? { await recording.fetchExerciseDataQuick() }
    func checkRecordingStatus(deviceId: String? = nil) async throws -> Bool {
        try await recording.checkRecordingStatus(deviceId: deviceId)
    }
    func checkForStoredExercises(deviceId: String? = nil) async {
        await recording.checkForStoredExercises(deviceId: deviceId)
    }
    func clearAnyExistingExercises() async throws { try await recording.clearAnyExistingExercises() }
    func discardStoredExercises() async throws { try await recording.discardStoredExercises() }
    func discardPendingExercise() { recording.discardPendingExercise() }
    func recoverExerciseData() async throws -> StrapRecordingCoordinator.RecoveredExercise {
        try await recording.recoverExerciseData()
    }
    var hasStoredExercise: Bool = false // True if H10 has stored data that can be recovered
    var storedExerciseDate: Date? // Date of stored exercise on H10 (for archive comparison)
    var firmwareVersion: String? // User-visible revision (prefers DIS software revision, falls back to firmware revision)
    var lastConnectedTime: Date? // When this device was last successfully connected
    var fetchProgress: FetchProgress? // Non-nil during fetch operations

    // Fetch cancellation
    var fetchCancelled = false
    private static let disFirmwareRevisionUUID = CBUUID(string: "2A26")
    private static let disSoftwareRevisionUUID = CBUUID(string: "2A28")
    var hasReceivedSoftwareRevision = false

    /// Accept async device-info callbacks only from the currently connected device.
    /// Internal, not private: `StrapBatteryUsageTracker` asks the same question
    /// before accepting a battery callback, and a second copy of the rule is a
    /// second thing to keep correct.
    func isActiveDeviceInfoSource(_ identifier: String) -> Bool {
        guard let connectedId = connectedDeviceId else { return false }
        return connectedId == identifier
    }

    /// Timestamp of the most recent battery level callback from the device.
    /// Reset on every callback regardless of whether the value actually changed.
    var lastBatteryUpdateTime: Date?

    /// True when the battery reading is judged stale. Computed from
    /// `hoursRecordedSinceBatteryChanged` vs the device's `specRecordingHours`,
    /// not from wall-clock elapsed time — wall-clock punished users who only
    /// connect to record (the strap reads the same %, gets called "stale",
    /// even though the user genuinely hasn't drained it).
    var isBatteryReadingStale: Bool = false

    // MARK: - Battery Usage Tracking
    //
    // The counters, their persistence, and the staleness rule live on
    // `StrapBatteryUsageTracker`. These forwarders keep every existing call
    // site working.

    /// The battery value the device most recently reported, tracked separately
    /// from `batteryLevel` so a callback repeating the SAME value (which Polar
    /// emits on connect) is told apart from one carrying a NEW one.
    /// These three are written by `StrapBatteryUsageTracker` and by nothing
    /// else. They were `private(set)` while the logic lived here; a
    /// `private(set)` setter is private to the DECLARING FILE, so keeping it
    /// would have meant either moving the logic back or adding a setter
    /// forwarder per property. Named as a group here so the ownership is
    /// still legible without the access modifier saying it.
    var batteryLastReportedValue: Int?
    /// When the device last reported a CHANGED value — not merely a callback.
    var batteryLastChangedAt: Date?
    /// Recording hours put on the strap since that change. A strict lower
    /// bound on consumed runtime.
    var hoursRecordedSinceBatteryChanged: Double = 0

    /// Built on demand: a value with no state of its own, so it cannot outlive
    /// the manager or retain it.
    var battery: StrapBatteryUsageTracker { StrapBatteryUsageTracker(manager: self) }

    func loadBatteryUsageStateIfNeeded(for deviceId: String) { battery.loadState(for: deviceId) }
    func recordRecordingHours(_ hours: Double) { battery.recordRecordingHours(hours) }
    func checkBatteryStaleness() { battery.recomputeStaleness() }

    func applyBatteryLevelUpdate(from identifier: String, batteryLevel: UInt) {
        battery.applyLevelUpdate(from: identifier, batteryLevel: batteryLevel)
    }

    /// Polar's own sample apps treat software revision (2A28) as the user-visible
    /// firmware label. Firmware revision (2A26) is kept only as fallback.
    ///
    /// Polar's SDK fires this callback multiple times per
    /// connect (once per BLE characteristic discovered, sometimes
    /// 6–8x). We log only on actual change to avoid duplicates polluting
    /// the debug log. Same applies to the fallback path.
    @MainActor
    func applyFirmwareRevisionUpdate(from identifier: String, uuid: CBUUID, value: String) {
        guard isActiveDeviceInfoSource(identifier) else { return }
        if uuid == Self.disSoftwareRevisionUUID {
            setFirmwareVersion(value, label: "Software revision (displayed as firmware)")
            hasReceivedSoftwareRevision = true
            return
        }
        guard uuid == Self.disFirmwareRevisionUUID, !hasReceivedSoftwareRevision else { return }
        setFirmwareVersion(value, label: "Firmware revision fallback")
    }

    @MainActor
    private func setFirmwareVersion(_ value: String, label: String) {
        let isNew = firmwareVersion != value
        firmwareVersion = value
        if isNew {
            debugLog("[PolarManager] \(label): \(value)")
        }
    }

    @MainActor
    func applyFirmwareRevisionUpdate(from identifier: String, key: String, value: String) {
        let normalizedKey = key.uppercased()
        guard normalizedKey == Self.disFirmwareRevisionUUID.uuidString ||
            normalizedKey == Self.disSoftwareRevisionUUID.uuidString else { return }
        applyFirmwareRevisionUpdate(from: identifier, uuid: CBUUID(string: normalizedKey), value: value)
    }

    /// Called when startRecording() rescues unrecovered data from the device before clearing.
    /// RRCollector hooks this to back up the rescued points via RawRRBackup.
    var onUnrecoveredDataRescued: (([RRPoint]) -> Void)?

    // Streaming mode state
    var isStreaming: Bool = false
    var streamingElapsedSeconds: Int = 0

    /// Streaming data storage — NOT observable to avoid SwiftUI thrashing on every beat.
    /// During overnight sessions the array grows to 20,000+ points; publishing it would
    /// trigger expensive view diffs every heartbeat and cause iOS to kill the app.
    var _streamedRRPoints: [RRPoint] = []

    /// Lightweight published count so the UI can display beat totals without copying the array.
    var streamedRRCount: Int = 0

    /// Last N points for live waveform / stats display (published, cheap to diff).
    var recentRRPoints: [RRPoint] = []
    static let recentRRWindowSize = 60

    /// Maximum streaming buffer size — safety cap to prevent unbounded growth.
    /// 100,000 points ≈ 28 hours at 1 beat/sec, well beyond any realistic session.
    static let maxStreamingBufferSize = 100_000

    /// Throttle UI updates — only push recentRRPoints every N beats to reduce SwiftUI work.
    var lastUIUpdateBeatCount: Int = 0
    static let uiUpdateBeatInterval = 5

    /// Public read-only access to the full streaming buffer (no SwiftUI observation).
    var streamedRRPoints: [RRPoint] {
        _streamedRRPoints
    }

    /// Heartbeat logging (only log if nothing noteworthy happened in 30 min).
    /// A lock-protected box, not a `nonisolated(unsafe) var`: it is accessed
    /// from Polar SDK background callbacks (PolarManager+Streaming), so a
    /// bare `var` races with itself. Semantics: last-write-wins, no
    /// observer count.
    private let _lastSignificantLogTime = OSAllocatedUnfairLock<Date>(initialState: .init())
    nonisolated var lastSignificantLogTime: Date {
        get { _lastSignificantLogTime.withLock { $0 } }
        set { _lastSignificantLogTime.withLock { $0 = newValue } }
    }

    /// Live HR monitoring (active when connected, even if not streaming RR data)
    var currentHeartRate: Int?

    /// Connection health tracking - true when keep-alive pings are failing
    var connectionHealthWarning: Bool = false

    /// Published when reconnect attempts are exhausted and the session cannot be resumed.
    /// Observers (RRCollector) should auto-save the streaming data and alert the user.
    var reconnectExhausted: Bool = false

    // MARK: - Types

    // Stored exercise entry for deferred clearing
    #if canImport(PolarBleSdk)
        var pendingExerciseEntry: PolarExerciseEntry?
    #endif

    typealias DiscoveredDevice = StrapDiscoveredDevice
    typealias KnownDevice = StrapKnownDevice

    enum ConnectionState: Equatable {
        case disconnected
        case scanning
        case connecting
        case connected
    }

    enum RecordingState: Equatable {
        case idle
        case starting
        case recording
        case stopping
        case fetching
    }

    /// Progress tracking for fetch operations
    typealias FetchProgress = StrapFetchProgress

    enum PolarError: Error, LocalizedError {
        case notConnected
        case alreadyRecording
        case notRecording
        case recordingFailed(String)
        case fetchFailed(String)
        case sdkNotAvailable
        case noRecordingFound
        case hasUnrecoveredData // H10 has data that wasn't successfully retrieved

        var errorDescription: String? {
            switch self {
            case .notConnected: "Polar device not connected"
            case .alreadyRecording: "Recording already in progress"
            case .notRecording: "No recording in progress"
            case let .recordingFailed(msg): "Recording failed: \(msg)"
            case let .fetchFailed(msg): "Fetch failed: \(msg)"
            case .sdkNotAvailable: "Polar SDK not available"
            case .noRecordingFound: "No recording found on device"
            case .hasUnrecoveredData: "Your device has unrecovered recording data. Recover it first or explicitly discard it."
            }
        }
    }

    // MARK: - Persisted State
    //
    // Pairings and the last-connected timestamp live in
    // `StrapPairingStore`, which owns their App Group location and the
    // migration from the two older ones. These forwarders keep the call sites.

    /// The most recently connected device ID (first in knownDevices list)
    var lastConnectedDeviceId: String? { knownDevices.first?.id }

    func addKnownDevice(id: String, name: String, deviceType: PolarDeviceType) {
        knownDevices = StrapPairingStore.adding(
            KnownDevice(id: id, name: name, deviceType: deviceType), to: knownDevices
        )
        StrapPairingStore.save(knownDevices)
    }

    func removeKnownDevice(id: String) {
        knownDevices.removeAll { $0.id == id }
        StrapPairingStore.save(knownDevices)
    }

    private func loadKnownDevices() { knownDevices = StrapPairingStore.load() }

    private func loadLastConnectedTime() {
        if let time = StrapPairingStore.loadLastConnectedTime() { lastConnectedTime = time }
    }

    func saveLastConnectedTime() {
        if let time = lastConnectedTime { StrapPairingStore.saveLastConnectedTime(time) }
    }

    // MARK: - Constants

    // MARK: - Private Properties

    #if canImport(PolarBleSdk)
        var api: PolarBleApi?
        /// Sendable handle over `api` for the recording coordinator's helpers.
        var strapAPI: StrapAPI? { api.map { StrapAPI(sdk: $0) } }
        @ObservationIgnored var searchTask: Task<Void, Never>?

        // Rx `Disposable`s became `Task`s with the Polar SDK 8.2.0 upgrade.
        //
        // A `Task` is the right shape for what these always were: a cancellable
        // unit of work owning one stream. `dispose()` becomes `cancel()`, and
        // cancellation now propagates into the `for try await` loop rather than
        // tearing down a subscription from the outside — which is stricter,
        // because the loop body finishes its current iteration instead of being
        // cut mid-write.
        @ObservationIgnored var streamingTask: Task<Void, Never>?
        @ObservationIgnored var streamingTimer: Timer?
        var streamingStartTime: Date?
        var streamingCumulativeMs: Int64 = 0
        @ObservationIgnored var hrMonitorTask: Task<Void, Never>? // For live HR on connect

        // Streaming reconnection state
        var streamingReconnectAttempts: Int = 0
        var isReconnectingStream: Bool = false
        var streamingReconnectCount: Int = 0 // Total successful reconnects

        /// Debounced BLE power-off teardown task. Cancelled
        /// when blePowerOn arrives within the debounce window. See
        /// `blePowerOff` in PolarManager+Observers for the rationale.
        @ObservationIgnored var pendingPowerOffTeardown: Task<Void, Never>?

        // Keep-alive ping failure tracking
        var consecutivePingFailures: Int = 0
        let maxPingFailuresBeforeWarning: Int = 3
    #endif

    // MARK: - Initialization

    private var apiInitialized = false

    /// Dedicated dispatch queue for the Polar BLE SDK.
    ///
    /// **Why not `DispatchQueue.main`:** initialising the SDK with the main
    /// queue means every CoreBluetooth callback,
    /// GATT notify, PS-FTP query, and the SDK's own internal sync waits
    /// (`waitPacketsWritten` has a 90 s timeout) ran on the main thread.
    /// On a cold launch the H10's exercise-listing handshake alone
    /// consumed the main thread for 20–30 s — user-visible as the
    /// workout-start hang, keyboard typing lagging, the recording timer
    /// stuck on `0:01`. The Console showed the smoking-gun warning
    /// "Potential Structural Swift Concurrency Issue: unsafeForcedSync
    /// called from Swift Concurrent context" during this BLE work.
    ///
    /// **Why this is safe:** All five `PolarBleApi*Observer` extensions
    /// (`+Observers.swift`, `+Streaming.swift`) already wrap their
    /// delegate-method bodies in `Task { @MainActor in … }` before
    /// touching any observable property — they were written
    /// defensively for exactly this kind of off-main delivery. The SDK
    /// itself doesn't require main-thread callbacks; the queue is just
    /// where it serializes BLE work.
    ///
    /// Serial queue + `.userInitiated` qos: ordering matters for BLE
    /// state-machine transitions, and the user's workout depends on
    /// timely heart-rate samples.
    private static let sdkQueue: DispatchQueue =
        DispatchQueue(label: "com.emuqu.polarsdk", qos: .userInitiated)

    /// Tokens for the block-based `NotificationCenter` observers registered in
    /// `init`. Stored so `deinit` removes them — block observers are not
    /// auto-removed on dealloc and would otherwise linger for the app's
    /// lifetime (and accumulate across the many managers built in tests).
    @ObservationIgnored private let lifecycleObservers = NotificationTokens()

    override init() {
        super.init()
        loadKnownDevices()
        loadLastConnectedTime()
        // Defer setupPolarApi() — CoreBluetooth init is expensive and not needed
        // until the user actually tries to scan/connect. ensureApiReady() handles it.
        observeSignificantLogs()
        observeAudioRouteChanges()
    }

    /// Listen for significant log events to reset the heartbeat timer.
    private func observeSignificantLogs() {
        lifecycleObservers.add(NotificationCenter.default.addObserver(
            forName: DebugLogger.significantLogPosted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.lastSignificantLogTime = Date()
        })
    }

    /// The route-change diagnostic lives on `StrapAudioRouteWatch`; see there
    /// for why a BLE strap cares about audio routes at all.
    private func observeAudioRouteChanges() {
        StrapAudioRouteWatch.observe(on: self, into: lifecycleObservers)
    }

    deinit { lifecycleObservers.removeAll() }

    /// Lazily initialize the Polar BLE SDK on first use.
    func ensureApiReady() {
        guard !apiInitialized else { return }
        apiInitialized = true
        setupPolarApi()
    }

    /// H10 internal recording requires pairing ONCE, then it remembers.
    /// This enables recording RR to H10 memory — survives disconnect/app backgrounding.
    /// The SDK handle and its observer wiring. Building it lives on
    /// `PolarSDKFactory`; attaching `self` as every observer has to be here,
    /// because `self` is what conforms.
    private func setupPolarApi() {
        #if canImport(PolarBleSdk)
            api = PolarSDKFactory.makeApi(queue: Self.sdkQueue)
            api?.observer = self
            api?.deviceInfoObserver = self
            api?.deviceFeaturesObserver = self
            api?.powerStateObserver = self
            api?.logger = self
            debugLog("[PolarManager] API initialized with H10 + Verity Sense support: \(api != nil)")
        #else
            debugLog("[PolarManager] PolarBleSdk not available")
        #endif
    }

    // MARK: - Helpers

    /// Preserve non-throwing sleep semantics while surfacing interruptions in logs.
    func sleepIgnoringCancellation(_ nanoseconds: UInt64, context: String) async {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            debugLog("[PolarManager] Sleep interrupted during \(context): \(error)")
        }
    }

    #if canImport(PolarBleSdk)
        func convertToRRPoints(_ exercise: PolarExerciseData) -> [RRPoint] {
            debugLog("[PolarManager] Converting exercise data: \(exercise.samples.count) samples")
            return StrapExerciseDecoder.rrPoints(fromIntervalsMs: exercise.samples.map(Int.init))
        }
    #endif
}
