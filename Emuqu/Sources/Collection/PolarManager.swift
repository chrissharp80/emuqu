import AVFoundation
import CoreBluetooth
import Foundation
import os

#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

// The Polar BLE SDK (8.x) has no RxSwift dependency: the streaming APIs this
// app uses return `AsyncThrowingStream` directly, so `for try await` iterates
// them natively with no Observable bridge.
//
// Polar 8.x is the minimum: 6.13.0 pins RxSwift 6.5.0, which ships no privacy
// manifest (Apple requires one for RxSwift as a listed SDK), and 7.0/7.1 pin
// RxSwift 6.8.0 but declare `path: "Sources"` while their repository keeps
// `Tests/` inside it, so SPM compiles their test files into the library and
// the package does not build for any consumer.

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
///
/// The strap's parts each hold only what they use. The state they share lives
/// in small observed objects owned here — `linkState`, `pairings`,
/// `deviceRecording`, `stream`, `battery`, the discovery results. Everything
/// outside the views takes the parts it uses; the properties below read those
/// parts for the views, and `lastError` also clears from them.
@Observable
@MainActor
final class PolarManager: NSObject {
    // MARK: - Parts

    /// The link: which strap, its readiness, its feed and readings.
    @ObservationIgnored let linkState: StrapLinkState
    /// State the link coordinator keeps between SDK events. Not observed.
    @ObservationIgnored let linkRuntime: StrapLinkRuntime
    /// The SDK's observer callbacks send into this from its own queue.
    @ObservationIgnored nonisolated let linkRuntimePump: StrapEventPump
    /// The SDK handle, created on first use.
    @ObservationIgnored let radio: StrapRadioSource
    @ObservationIgnored let pairings: StrapPairings
    @ObservationIgnored let discoveryResults: StrapDiscoveryState
    /// What the strap's own memory is doing, and transfers off it.
    @ObservationIgnored let deviceRecording: StrapRecordingState
    /// A streaming session's buffer.
    @ObservationIgnored let stream: StrapStreamSession
    /// The strap's battery-usage counters and staleness rule.
    @ObservationIgnored let battery: StrapBatteryUsageTracker

    /// Waiting on the link, and the few things other parts do to it.
    var link: StrapLinkControl { StrapLinkControl(state: linkState, runtime: linkRuntime, radio: radio) }

    /// What each SDK event does, the heart-rate feed, and feed health.
    /// Built on first use; held for the manager's life.
    @ObservationIgnored private(set) lazy var linkEvents = StrapLinkCoordinator(
        link: link, stream: stream, battery: battery, pairings: pairings, recording: recording
    )

    /// Device-internal recording: start, stop, status, download.
    var recording: StrapRecordingCoordinator {
        StrapRecordingCoordinator(link: link, device: deviceRecording, discovery: discovery)
    }

    // MARK: - State the views read

    var connectionState: ConnectionState { linkState.connectionState }
    var connectedDeviceId: String? { linkState.connectedDeviceId }
    var connectedDeviceType: PolarDeviceType? { linkState.connectedDeviceType }
    /// Device ID of a connection attempt in progress (set during `.connecting`, cleared on connect/cancel).
    var pendingDeviceId: String? { linkState.pendingDeviceId }
    var lastError: Error? {
        get { linkState.lastError }
        set { linkState.lastError = newValue }
    }
    var batteryLevel: Int? { linkState.batteryLevel }
    /// See `StrapLinkState.isBatteryReadingStale`.
    var isBatteryReadingStale: Bool { linkState.isBatteryReadingStale }
    var firmwareVersion: String? { linkState.firmwareVersion }
    /// The strap's own heart-rate reading, live whenever a strap is linked.
    var currentHeartRate: Int? { linkState.currentHeartRate }

    /// Whether heart rate is actually arriving, as opposed to merely connected.
    var feedStatus: StrapFeedHealth.Status { linkState.feedStatus }

    /// True while the strap is linked but has stopped delivering heart rate.
    var connectionHealthWarning: Bool { feedStatus == .stalled }

    var discoveredDevices: [DiscoveredDevice] { discoveryResults.discoveredDevices }
    var knownDevices: [KnownDevice] { pairings.knownDevices }
    /// When this device was last successfully connected.
    var lastConnectedTime: Date? { pairings.lastConnectedTime }

    var recordingState: RecordingState { deviceRecording.recordingState }
    var isRecordingOnDevice: Bool { deviceRecording.isRecordingOnDevice }
    /// True if H10 has stored data that can be recovered.
    var hasStoredExercise: Bool { deviceRecording.hasStoredExercise }
    /// Date of stored exercise on H10 (for archive comparison).
    var storedExerciseDate: Date? { deviceRecording.storedExerciseDate }

    var isStreaming: Bool { stream.isStreaming }
    /// Lightweight published count so the UI can display beat totals without copying the array.
    var streamedRRCount: Int { stream.streamedRRCount }
    /// Last N points for live waveform / stats display.
    var recentRRPoints: [RRPoint] { stream.recentRRPoints }

    // MARK: - Types

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
        /// Carries a message already worded for the user.
        case recordingFailed(String)
        /// Carries an internal detail for logs; users see a plain sentence.
        case fetchFailed(String)
        case sdkNotAvailable
        case noRecordingFound
        /// The strap holds recordings, but none started since the session
        /// began: an earlier session's file, which is never filed as this one.
        case noRecordingSinceSessionStart
        /// The phone and the strap no longer share a usable pairing. Only the
        /// user can repair it, so nothing retries.
        case pairingLost
        /// The strap never became ready for the operation before its deadline.
        /// The payload names the feature for logs; users see a plain sentence.
        case featureNotReady(String)
        /// The strap refused to record to its own memory because its battery
        /// is too low (Polar PFTP `BATTERY_TOO_LOW`), at the level it last
        /// reported.
        case strapBatteryTooLow(percent: Int?)
        /// The strap holds a recording that could not be downloaded, and
        /// starting a new one would delete it.
        case strapHoldsUndownloadedRecording

        var errorDescription: String? {
            switch self {
            case .pairingLost: String(localized: "The strap's Bluetooth pairing was lost. In iOS Settings → Bluetooth, forget the Polar strap, then connect it again from Emuqu.", bundle: LanguageManager.appBundle)
            case .featureNotReady: String(localized: "The strap didn't finish setting up. Keep it on and close to the phone, then try again.", bundle: LanguageManager.appBundle)
            case .notConnected: String(localized: "Polar device not connected", bundle: LanguageManager.appBundle)
            case .alreadyRecording: String(localized: "Recording already in progress", bundle: LanguageManager.appBundle)
            case let .recordingFailed(msg): String(localized: "Recording failed: \(msg)", bundle: LanguageManager.appBundle)
            case .fetchFailed: String(localized: "Couldn't download the recording from the strap. Keep it close to the phone, then try again.", bundle: LanguageManager.appBundle)
            case .sdkNotAvailable: String(localized: "Polar SDK not available", bundle: LanguageManager.appBundle)
            case .noRecordingFound: String(localized: "No recording found on device", bundle: LanguageManager.appBundle)
            case .noRecordingSinceSessionStart: String(localized: "No recording found on the strap for this session.", bundle: LanguageManager.appBundle)
            case let .strapBatteryTooLow(percent): Self.batteryTooLowDescription(percent: percent)
            case .strapHoldsUndownloadedRecording: String(localized: "The strap holds a recording that hasn't been downloaded, so its own recording wasn't started (that would delete it). Recover it from the Record screen; tonight records from the live stream.", bundle: LanguageManager.appBundle)
            }
        }

        private static func batteryTooLowDescription(percent: Int?) -> String {
            guard let percent else {
                return String(localized: "Your strap's battery is too low to record to its own memory. Tonight records from the live stream only. Replace the strap's battery (CR2025).", bundle: LanguageManager.appBundle)
            }
            return String(localized: "Your strap's battery is too low (\(percent)%) to record to its own memory. Tonight records from the live stream only. Replace the strap's battery (CR2025).", bundle: LanguageManager.appBundle)
        }
    }

    // MARK: - Initialization

    private var apiInitialized = false

    /// Dedicated dispatch queue for the Polar BLE SDK.
    ///
    /// **Why not `DispatchQueue.main`:** initialising the SDK with the main
    /// queue would put every CoreBluetooth callback, GATT notify, PS-FTP
    /// query, and the SDK's own internal sync waits (`waitPacketsWritten` has
    /// a 90 s timeout) on the main thread. On a cold launch the H10's
    /// exercise-listing handshake alone can hold the main thread for 20–30 s
    /// — a workout-start hang, lagging keyboard, the recording timer stuck on
    /// `0:01` — and the BLE work trips the "Potential Structural Swift
    /// Concurrency Issue: unsafeForcedSync called from Swift Concurrent
    /// context" warning.
    ///
    /// **Why this is safe:** the `PolarBleApi*Observer` conformances in
    /// `+Observers.swift` touch no state. Each forwards its callback into
    /// `StrapEventPump`, which delivers them to the main actor in the order the
    /// SDK raised them. The SDK itself doesn't require main-thread callbacks;
    /// the queue is just where it serializes BLE work.
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
        let linkState = StrapLinkState()
        let linkRuntime = StrapLinkRuntime()
        let radio = StrapRadioSource()
        let pairings = StrapPairings()
        self.linkState = linkState
        self.linkRuntime = linkRuntime
        linkRuntimePump = linkRuntime.pump
        self.radio = radio
        self.pairings = pairings
        discoveryResults = StrapDiscoveryState()
        deviceRecording = StrapRecordingState()
        stream = StrapStreamSession(
            link: StrapLinkControl(state: linkState, runtime: linkRuntime, radio: radio), pairings: pairings
        )
        battery = StrapBatteryUsageTracker(link: linkState, pairings: pairings)
        super.init()
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
        ) { [weak stream] _ in
            stream?.lastSignificantLogTime = Date()
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

    /// The SDK handle and its observer wiring. Building it lives on
    /// `PolarSDKFactory`; attaching `self` as every observer has to be here,
    /// because `self` is what conforms.
    private func setupPolarApi() {
        #if canImport(PolarBleSdk)
            linkEvents.startEventDelivery()
            radio.api = PolarSDKFactory.makeApi(queue: Self.sdkQueue)
            radio.api?.observer = self
            radio.api?.deviceInfoObserver = self
            radio.api?.deviceFeaturesObserver = self
            radio.api?.powerStateObserver = self
            radio.api?.logger = self
            debugLog("[PolarManager] API initialized with H10 + Verity Sense support: \(radio.api != nil)")
        #else
            debugLog("[PolarManager] PolarBleSdk not available")
        #endif
    }
}
