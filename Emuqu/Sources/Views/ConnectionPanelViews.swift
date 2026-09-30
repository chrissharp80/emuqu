import CoreBluetooth
import SwiftUI

// MARK: - Connection Panel (isolated PolarManager observation)

/// The outer panel routes to a state-specific sub-view (disconnected /
/// scanning / connecting / connected). `polarManager` MUST be @ObservedObject
/// here — without it, `polarManager.connectionState` change does not re-run
/// the body, so the switch sticks on the last branch it rendered. That's the
/// "Disconnect button still shows after disconnect" bug and the "device info
/// doesn't appear until I tap something" bug — both surface from the same
/// missed observation.
struct ConnectionPanel: View {
    var polarManager: PolarManager
    /// Plain reference, not @ObservedObject. RRCollector publishes nothing; observing it
    /// is dead weight. Used here only as a method/dependency carrier.
    let collector: RRCollector
    let selectedSessionType: SessionType?

    var body: some View {
        VStack(spacing: 16) {
            // Header + status badge react through collector's throttled proxy
            ConnectionPanelHeader(polarManager: polarManager)

            // Route to state-specific sub-view; each observes PolarManager in isolation
            connectingSection
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Device connection", bundle: LanguageManager.appBundle))
    }

    @ViewBuilder
    private var connectingSection: some View {
        switch polarManager.connectionState {
        case .disconnected:
            ConnectionPanelDisconnected(polarManager: polarManager, selectedSessionType: selectedSessionType)
        case .scanning:
            ConnectionPanelScanning(polarManager: polarManager)
        case .connecting:
            connectingPanel
        case .connected:
            ConnectionPanelConnected(polarManager: polarManager)
        }
    }

    private var connectingPanel: some View {
        VStack(spacing: 10) {
            HStack {
                ProgressView().scaleEffect(0.8)
                Text(String(localized: "Connecting...", bundle: LanguageManager.appBundle)).font(.subheadline)
            }
            cancelConnectionButton
        }
    }

    private var cancelConnectionButton: some View {
        Button {
            polarManager.cancelConnection()
        } label: {
            Text(String(localized: "Cancel", bundle: LanguageManager.appBundle))
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(String(localized: "Cancel connection", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Stop trying to connect to the Polar device", bundle: LanguageManager.appBundle))
    }
}

// MARK: - Connection Panel Sub-Views (isolated PolarManager observation)

/// Header row: device name + connection status badge. Observes PolarManager
/// so the badge updates promptly on state changes.
private struct ConnectionPanelHeader: View {
    var polarManager: PolarManager

    var body: some View {
        HStack {
            Text(polarManager.connectedDeviceType?.displayName ?? "Polar Device")
                .font(.headline)
            Spacer()
            connectionStatusBadge
        }
    }

    private var connectionStatusBadge: some View {
        let (color, text) = ConnectionStatusBadge.content(
            state: polarManager.connectionState,
            feed: polarManager.feedStatus,
            heartRate: polarManager.currentHeartRate
        )
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(text).font(.caption).foregroundColor(AppTheme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(.systemBackground))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection status: \(text)")
    }
}

/// What the connection badge says.
///
/// A link is not a working strap: green means beats are arriving, and shows
/// the latest one. A link with no beat yet reads "Setting up", and one whose
/// beats have stopped says so, so the two are never mistaken for each other
/// or for a working strap.
enum ConnectionStatusBadge {
    static func content(
        state: PolarManager.ConnectionState, feed: StrapFeedHealth.Status, heartRate: Int?
    ) -> (color: Color, text: String) {
        switch state {
        case .disconnected: return (.gray, String(localized: "Disconnected", bundle: LanguageManager.appBundle))
        case .scanning: return (.yellow, String(localized: "Scanning", bundle: LanguageManager.appBundle))
        case .connecting: return (.orange, String(localized: "Connecting", bundle: LanguageManager.appBundle))
        case .connected: return linked(feed: feed, heartRate: heartRate)
        }
    }

    private static func linked(feed: StrapFeedHealth.Status, heartRate: Int?) -> (color: Color, text: String) {
        switch feed {
        case .live:
            guard let heartRate else { return (.green, String(localized: "Connected", bundle: LanguageManager.appBundle)) }
            return (.green, String(localized: "\(heartRate) bpm", bundle: LanguageManager.appBundle))
        case .stalled:
            return (.orange, String(localized: "No heart rate from strap", bundle: LanguageManager.appBundle))
        case .settingUp, .waitingForStrap:
            return (.orange, String(localized: "Setting up", bundle: LanguageManager.appBundle))
        }
    }
}

/// Disconnected state: known device list + scan button.
private struct ConnectionPanelDisconnected: View {
    var polarManager: PolarManager
    let selectedSessionType: SessionType?

    private var filteredKnownDevices: [PolarManager.KnownDevice] {
        let devices = polarManager.knownDevices
        guard let sessionType = selectedSessionType else { return devices }
        switch sessionType {
        case .overnight, .nap, .workout:
            // Workouts prefer H10 (authoritative RR during exercise) just like
            // overnight/nap sessions.
            return devices.sorted { d1, _ in d1.deviceType == .h10 }
        case .quick, .breathe:
            return devices
        }
    }

    // When the user denied Bluetooth at the system prompt,
    // tapping "Scan" would spin forever with no explanation (App Store
    // 5.1.1 denied-permission dead-end). Surface a Settings deep-link
    // instead. `CBCentralManager.authorization` is a static read (no
    // manager instance needed); re-evaluated on `.onAppear` so returning
    // from Settings refreshes it.
    @State private var btAuthorization = CBCentralManager.authorization

    private var bluetoothAccessDenied: Bool {
        btAuthorization == .denied || btAuthorization == .restricted
    }

    var body: some View {
        VStack(spacing: 12) {
            knownDeviceList
        }
        .onAppear { btAuthorization = CBCentralManager.authorization }
    }

    @ViewBuilder
    private var knownDeviceList: some View {
        if bluetoothAccessDenied {
            bluetoothDeniedBanner
        } else {
            deviceDiscoveryList
        }
    }

    @ViewBuilder
    private var deviceDiscoveryList: some View {
        ForEach(filteredKnownDevices) { device in
            KnownDeviceRow(
                device: device,
                onConnect: { polarManager.connect(deviceId: device.id) },
                onRemove: { polarManager.removeKnownDevice(id: device.id) }
            )
        }
        scanButton
        Text(String(localized: "Put on your Polar device and ensure good sensor contact", bundle: LanguageManager.appBundle))
            .font(.caption).foregroundColor(AppTheme.textSecondary).multilineTextAlignment(.center)
    }

    private var scanButton: some View {
        Button {
            polarManager.startScanning()
        } label: {
            Label(String(localized: "Scan for Devices", bundle: LanguageManager.appBundle), systemImage: "antenna.radiowaves.left.and.right")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(String(localized: "Scan for Devices", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Search for nearby Polar heart rate sensors", bundle: LanguageManager.appBundle))
    }

    private var bluetoothDeniedBanner: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundColor(.orange)
                .accessibilityHidden(true)
            Text(String(localized: "Bluetooth access is off", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
            Text(String(localized: "Emuqu needs Bluetooth to connect to your Polar heart rate sensor. Turn it on for Emuqu in Settings.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
            openSettingsButton
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var openSettingsButton: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            Label(String(localized: "Open Settings", bundle: LanguageManager.appBundle), systemImage: "gear")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}

/// Scanning state: discovered device list + stop button.
private struct ConnectionPanelScanning: View {
    var polarManager: PolarManager

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                ProgressView().scaleEffect(0.8)
                Text(String(localized: "Scanning for Polar devices...", bundle: LanguageManager.appBundle)).font(.subheadline)
            }
            discoveredDeviceList
            Button {
                polarManager.stopScanning()
            } label: {
                Text(String(localized: "Stop Scanning", bundle: LanguageManager.appBundle))
            }
            .buttonStyle(.bordered)
        }
    }

    /// Until a strap answers, say what it takes for one to, as onboarding does.
    @ViewBuilder
    private var discoveredDeviceList: some View {
        if polarManager.discoveredDevices.isEmpty {
            Text(String(localized: "Make sure your sensor is nearby and turned on.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
                .multilineTextAlignment(.center)
        } else {
            discoveredDeviceRows
        }
    }

    private var discoveredDeviceRows: some View {
        VStack(spacing: 8) {
            ForEach(polarManager.discoveredDevices) { device in
                discoveredDeviceRow(device)
            }
        }
    }

    private func discoveredDeviceRow(_ device: PolarManager.DiscoveredDevice) -> some View {
        Button {
            polarManager.connect(deviceId: device.id)
        } label: {
            discoveredDeviceLabel(device)
        }
        .buttonStyle(.plain)
    }

    private func discoveredDeviceLabel(_ device: PolarManager.DiscoveredDevice) -> some View {
        HStack {
            Image(systemName: "heart.fill").foregroundColor(.red)
            Text(device.name)
            Spacer()
            Text("\(device.rssi) dBm").font(.caption).foregroundColor(AppTheme.textSecondary)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(8)
    }
}

/// Connected state: device info + disconnect button.
///
/// PolarManager is observed directly so battery / firmware / hasStoredExercise
/// updates that arrive AFTER initial connect (BLE characteristic notifications
/// land asynchronously) trigger a re-render. Without @ObservedObject the panel
/// renders once with everything nil, then sits stale until the user taps
/// somewhere else and forces SwiftUI to re-evaluate — which the user has been
/// reporting as "the detail screen doesn't come up until I do something".
///
/// No live HR display in this panel: it appears inconsistently (only when a
/// prior session leaves the HR stream active) and the user finds it
/// distracting. HR is visible during active recording in the dedicated
/// streaming/overnight status views.
private struct ConnectionPanelConnected: View {
    var polarManager: PolarManager

    var body: some View {
        VStack(spacing: 12) {
            recordingSection

            DeviceInfoPanelObserving(polarManager: polarManager)

            disconnectSection
        }
    }

    private var recordingSection: some View {
        HStack {
            Text(polarManager.connectedDeviceId ?? "Unknown")
                .font(.subheadline).fontWeight(.medium)
            Spacer()
            recordingOnDeviceBadge
        }
    }

    @ViewBuilder
    private var recordingOnDeviceBadge: some View {
        if polarManager.isRecordingOnDevice {
            HStack(spacing: 4) {
                Circle().fill(.red).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(String(localized: "Recording", bundle: LanguageManager.appBundle)).font(.caption).foregroundColor(.red)
            }
            .accessibilityLabel("Recording in progress")
        }
    }

    private var disconnectSection: some View {
        Button {
            polarManager.disconnect()
            onDisconnect?()
        } label: {
            Text(String(localized: "Disconnect", bundle: LanguageManager.appBundle))
        }
        .buttonStyle(.bordered)
        .disabled(polarManager.recordingState != .idle)
    }

    /// Called after user-initiated disconnect so parent can reset source selection
    var onDisconnect: (() -> Void)?
}

// MARK: - Known Device Row

private struct KnownDeviceRow: View {
    let device: PolarManager.KnownDevice
    let onConnect: () -> Void
    let onRemove: () -> Void

    @State private var offset: CGFloat = 0
    @State private var revealed = false

    private let deleteWidth: CGFloat = 70

    var body: some View {
        ZStack(alignment: .trailing) {
            deleteBackdrop
            deviceRow
        }
        .clipped()
        .contextMenu { removeDeviceButton }
    }

    /// Sits behind the row and is revealed by the left swipe.
    private var deleteBackdrop: some View {
        // Delete button (sits behind the row)
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                onRemove()
            }
        } label: {
            Image(systemName: "trash.fill")
                .font(.body)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel(String(localized: "Remove Device", bundle: LanguageManager.appBundle))
        .frame(width: deleteWidth)
        .background(Color.red)
        .cornerRadius(10)
    }

    private var deviceRow: some View {
        // Main row content
        HStack(spacing: 12) {
            Image(systemName: device.deviceType.icon)
                .font(.title3)
                .foregroundColor(AppTheme.primary)
                .frame(width: 28)
                .accessibilityHidden(true)
            deviceRowText
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppTheme.sectionTint)
        .cornerRadius(10)
        .offset(x: offset)
        .onTapGesture { handleTap() }
        .gesture(swipeToDelete)
    }

    private var deviceRowText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(device.name)
                .font(.subheadline.weight(.medium))
            Text(device.id)
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private func handleTap() {
        if revealed {
            withAnimation(.easeOut(duration: 0.2)) {
                offset = 0
                revealed = false
            }
        } else {
            onConnect()
        }
    }

    private var swipeToDelete: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in dragChanged(value.translation.width) }
            .onEnded { value in dragEnded(value.translation.width) }
    }

    private func dragChanged(_ translation: CGFloat) {
        if revealed {
            // Already open — allow dragging back closed or further
            let newOffset = -deleteWidth + translation
            offset = min(0, max(-deleteWidth, newOffset))
        } else {
            // Only allow left swipe
            if translation < 0 {
                offset = max(-deleteWidth, translation)
            }
        }
    }

    private func dragEnded(_ translation: CGFloat) {
        withAnimation(.easeOut(duration: 0.2)) {
            if revealed {
                settleFromOpen(translation)
            } else {
                settleFromClosed()
            }
        }
    }

    /// Swiped back to the right by more than 30 pt: close. Anything less snaps
    /// back open.
    private func settleFromOpen(_ translation: CGFloat) {
        if translation > 30 {
            offset = 0
            revealed = false
        } else {
            offset = -deleteWidth
        }
    }

    /// Opening: snap open once past halfway, otherwise fall closed again.
    private func settleFromClosed() {
        // If swiped back right, close
        // Opening: snap open if past halfway
        if offset < -deleteWidth / 2 {
            offset = -deleteWidth
            revealed = true
        } else {
            offset = 0
        }
    }

    private var removeDeviceButton: some View {
        Button(role: .destructive) {
            onRemove()
        } label: {
            Label(String(localized: "Remove Device", bundle: LanguageManager.appBundle), systemImage: "trash")
        }
    }
}
