import SwiftUI

// MARK: - SensorManagementSheet
//
// Opens when the user taps the strap status pill in the Fitness tab's
// pre-flight view. Lets them pair, forget (swipe a paired strap) and
// reconnect the Polar strap (and view foot pod / PM5 status) WITHOUT it
// being a gate to the rest
// of the planning surface. The sensor sheet is a side-panel for
// sensor management, not a step in starting a workout.
//
// Per UX research: leading apps (Strava, Polar Beat, TrainerRoad) all
// surface sensor management as a sheet from a status pill, never as
// a required step in the start flow.
struct SensorManagementSheet: View {
    var polarManager: PolarManager
    let onDismiss: () -> Void

    var body: some View {
        List {
            polarSection
            footPodSection
            pm5Section
        }
        .navigationTitle(String(localized: "Sensors", bundle: LanguageManager.appBundle))
        .accessibilityIdentifier("sensors.root")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done", bundle: LanguageManager.appBundle), action: onDismiss)
            }
        }
    }

    // MARK: - Polar strap

    @ViewBuilder
    private var polarSection: some View {
        Section {
            polarStatusRow
            polarActionButtons
            discoveredDevicesList
            knownDevicesList
        } header: {
            Text(String(localized: "Polar Strap (HRV)", bundle: LanguageManager.appBundle))
        } footer: {
            // Deliberately does NOT name the two straps in one breath as
            // providing "HRV-grade metrics (RMSSD, SDNN, DFA α1)". The H10 derives
            // its intervals from ECG and is validated against one; the Verity Sense
            // derives them optically, and the published validation covers heart
            // RATE rather than beat-to-beat interval accuracy. That gap matters
            // most for DFA α1, which reads the pattern between individual beats.
            Text(String(localized: "Both straps give the beat-to-beat intervals HRV needs; Apple Watch heart rate cannot. The H10 reads them from ECG and is more accurate. The Verity Sense is optical — comfier overnight, noisier between beats, most so in α1.", bundle: LanguageManager.appBundle))
        }
    }

    /// Status row
    private var polarStatusRow: some View {
        HStack {
            Image(systemName: polarIcon)
                .foregroundStyle(polarColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(polarTitle)
                    .font(.body)
                Text(polarSubtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            connectionStateBadge
        }
    }

    /// Action buttons — change with state
    ///
    /// Once a device is in `knownDevices`, showing ONLY a
    /// "Reconnect" button would make the "Pair a strap" path
    /// permanently gone: the user couldn't add a second device —
    /// ever — without nuking the known list. So when there's
    /// a known device, show BOTH "Reconnect" (primary) and
    /// "Pair another" (secondary). Discovery flow is identical
    /// either way; the existing `discoveredDevices` list below
    /// renders new candidates regardless of knownDevices count.
    private var polarActionButtons: some View {
        HStack(spacing: 8) {
            stateDrivenPolarButtons
            Spacer()
        }
    }

    @ViewBuilder
    private var stateDrivenPolarButtons: some View {
        if polarManager.connectionState == .connected {
            disconnectPolarButton
        } else if polarManager.connectionState == .scanning {
            stopScanningPolarButton
        } else if !polarManager.knownDevices.isEmpty {
            reconnectButton2
            pairAnotherButton3
        } else {
            pairStrapButton
        }
    }

    private var disconnectPolarButton: some View {
        Button(role: .destructive) {
            polarManager.disconnect()
        } label: {
            Label(String(localized: "Disconnect", bundle: LanguageManager.appBundle), systemImage: "xmark.circle")
        }
    }

    private var stopScanningPolarButton: some View {
        Button(role: .destructive) {
            polarManager.stopScanning()
        } label: {
            Label(String(localized: "Stop scanning", bundle: LanguageManager.appBundle), systemImage: "stop.circle")
        }
    }

    /// Discovered devices during a scan
    @ViewBuilder
    private var discoveredDevicesList: some View {
        if polarManager.connectionState == .scanning, !polarManager.discoveredDevices.isEmpty {
            ForEach(polarManager.discoveredDevices, id: \.id) { discoveredDeviceButton($0) }
        }
    }

    private func discoveredDeviceButton(_ device: PolarManager.DiscoveredDevice) -> some View {
        Button {
            polarManager.connect(deviceId: device.id)
        } label: {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(AppTheme.terracotta)
                Text(device.name)
                Spacer()
                Text(String(localized: "Tap to pair", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    /// Known devices list
    @ViewBuilder
    private var knownDevicesList: some View {
        if !polarManager.knownDevices.isEmpty {
            ForEach(polarManager.knownDevices, id: \.id) { knownDeviceRow($0) }
        }
    }

    private func knownDeviceRow(_ device: PolarManager.KnownDevice) -> some View {
        HStack {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text(device.name)
            Spacer()
            Text(String(localized: "Paired", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        // Swipe to forget: removes the strap from the paired list.
        .swipeActions {
            Button(role: .destructive) {
                polarManager.removeKnownDevice(id: device.id)
            } label: {
                Label(String(localized: "Forget", bundle: LanguageManager.appBundle), systemImage: "trash")
            }
        }
    }

    private var reconnectButton2: some View {
        Button {
            polarManager.connectToLastDevice()
        } label: {
            Label(String(localized: "Reconnect", bundle: LanguageManager.appBundle), systemImage: "arrow.clockwise")
        }
    }

    private var pairAnotherButton3: some View {
        Button {
            polarManager.startScanning()
        } label: {
            Label(String(localized: "Pair another", bundle: LanguageManager.appBundle), systemImage: "magnifyingglass")
        }
    }

    private var pairStrapButton: some View {
        Button {
            polarManager.startScanning()
        } label: {
            Label(String(localized: "Pair a strap", bundle: LanguageManager.appBundle), systemImage: "magnifyingglass")
        }
        // A UI test asserts this is offered; it must not tap it, since
        // `startScanning()` raises the system Bluetooth prompt.
        .accessibilityIdentifier("sensors.pairStrap")
    }

    // MARK: - Foot pod (Stryd / FTMS)

    @ViewBuilder
    private var footPodSection: some View {
        Section {
            FootPodRow()
        } header: {
            Text(String(localized: "Foot Pod / Bike Trainer", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "Stryd foot pods stream running power. FTMS-spec bike trainers (Wahoo Kickr, Tacx, Saris) stream cycling power. Auto-reconnects at workout start once paired.", bundle: LanguageManager.appBundle))
        }
    }

    // MARK: - Concept2 PM5

    @ViewBuilder
    private var pm5Section: some View {
        Section {
            PM5Row()
        } header: {
            Text(String(localized: "Concept2 PM5", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "PM5 monitor for the Concept2 rower. Streams stroke rate, distance, drag factor, instantaneous power.", bundle: LanguageManager.appBundle))
        }
    }

    // MARK: - Polar visual

    private var polarIcon: String {
        polarManager.connectionState == .connected
            ? "sensor.tag.radiowaves.forward.fill"
            : "sensor.tag.radiowaves.forward"
    }

    private var polarColor: Color {
        switch polarManager.connectionState {
        case .connected: return linkedBadge.color
        case .connecting, .scanning: return .blue
        case .disconnected:
            return polarManager.knownDevices.isEmpty ? .gray : .orange
        }
    }

    private var polarTitle: String {
        polarManager.knownDevices.first?.name ?? String(localized: "Polar Strap", bundle: LanguageManager.appBundle)
    }

    private var polarSubtitle: String {
        switch polarManager.connectionState {
        case .connected: return linkedSubtitle
        case .connecting: return String(localized: "Connecting…", bundle: LanguageManager.appBundle)
        case .scanning: return String(localized: "Scanning for nearby straps…", bundle: LanguageManager.appBundle)
        case .disconnected:
            return polarManager.knownDevices.isEmpty
                ? String(localized: "No strap paired", bundle: LanguageManager.appBundle)
                : String(localized: "Tap Reconnect to bring it back", bundle: LanguageManager.appBundle)
        }
    }

    private var connectionStateBadge: some View {
        Text(badgeText)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(polarColor.opacity(0.18)))
            .foregroundStyle(polarColor)
    }

    private var badgeText: String {
        switch polarManager.connectionState {
        case .connected: return linkedBadge.text
        case .connecting: return String(localized: "Connecting", bundle: LanguageManager.appBundle)
        case .scanning: return String(localized: "Scanning", bundle: LanguageManager.appBundle)
        case .disconnected: return String(localized: "Off", bundle: LanguageManager.appBundle)
        }
    }

    /// A link is not a feed: "streaming RR" only once beats are arriving. The
    /// same rule as the Record tab's badge.
    private var linkedBadge: (color: Color, text: String) {
        ConnectionStatusBadge.content(
            state: .connected, feed: polarManager.feedStatus, heartRate: polarManager.currentHeartRate
        )
    }

    private var linkedSubtitle: String {
        switch polarManager.feedStatus {
        case .live: return String(localized: "Connected — streaming RR", bundle: LanguageManager.appBundle)
        case .stalled: return String(localized: "No heart rate from strap", bundle: LanguageManager.appBundle)
        case .settingUp, .waitingForStrap:
            return String(localized: "Waiting for the strap's first heartbeat...", bundle: LanguageManager.appBundle)
        }
    }
}

// MARK: - Foot pod row (status + reconnect / pair)

private struct FootPodRow: View {
    @Environment(\.dependencies) var dependencies
    private var manager: FootPodManager { dependencies.collection.footPodManager }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRowForFootPod
            HStack(spacing: 8) {
                stateDrivenButtonsForFootPod
                Spacer()
            }
        }
    }

    private var statusRowForFootPod: some View {
        HStack {
            Image(systemName: "shoeprints.fill")
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(manager.lastStatusLine)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            statusBadgeForFootPod
        }
    }

    private var statusBadgeForFootPod: some View {
        Text(badge)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var stateDrivenButtonsForFootPod: some View {
        if manager.connectionState == .connected {
            disconnectButton2
        } else if manager.connectionState == .scanning {
            stopScanningButton2
        } else if !manager.knownDevices.isEmpty {
            theyPairedButton
            pairAnotherButton2
        } else {
            pairButton2
        }
    }

    private var disconnectButton2: some View {
        Button(role: .destructive) {
            manager.disconnect()
        } label: {
            Label(String(localized: "Disconnect", bundle: LanguageManager.appBundle), systemImage: "xmark.circle")
        }
    }

    private var stopScanningButton2: some View {
        Button(role: .destructive) {
            manager.stopScanning()
        } label: {
            Label(String(localized: "Stop scanning", bundle: LanguageManager.appBundle), systemImage: "stop.circle")
        }
    }

    private var theyPairedButton: some View {
        // Same pair-another pattern as the Polar
        // section above. Reconnect + "Pair another" so users
        // aren't permanently locked to the first foot pod
        // they paired.
        Button {
            manager.reconnectLast()
        } label: {
            Label(String(localized: "Reconnect", bundle: LanguageManager.appBundle), systemImage: "arrow.clockwise")
        }
    }

    private var pairAnotherButton2: some View {
        Button {
            manager.startScanning()
        } label: {
            Label(String(localized: "Pair another", bundle: LanguageManager.appBundle), systemImage: "magnifyingglass")
        }
    }

    private var pairButton2: some View {
        Button {
            manager.startScanning()
        } label: {
            Label(String(localized: "Pair", bundle: LanguageManager.appBundle), systemImage: "magnifyingglass")
        }
    }

    private var title: String {
        manager.knownDevices.first?.name ?? String(localized: "Foot Pod / Bike Trainer", bundle: LanguageManager.appBundle)
    }

    private var color: Color {
        switch manager.connectionState {
        case .connected: return .green
        case .connecting, .scanning: return .blue
        case .disconnected:
            return manager.knownDevices.isEmpty ? .gray : .orange
        }
    }

    private var badge: String {
        switch manager.connectionState {
        case .connected: return String(localized: "Connected", bundle: LanguageManager.appBundle)
        case .connecting: return String(localized: "Connecting", bundle: LanguageManager.appBundle)
        case .scanning: return String(localized: "Scanning", bundle: LanguageManager.appBundle)
        case .disconnected: return manager.knownDevices.isEmpty ? String(localized: "Not paired", bundle: LanguageManager.appBundle) : String(localized: "Off", bundle: LanguageManager.appBundle)
        }
    }
}

// MARK: - PM5 row (status + reconnect / pair)

private struct PM5Row: View {
    @Environment(\.dependencies) var dependencies
    private var manager: Concept2Manager { dependencies.collection.concept2Manager }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRowForRower
            HStack(spacing: 8) {
                stateDrivenButtonsForRower
                Spacer()
            }
        }
    }

    private var statusRowForRower: some View {
        HStack {
            Image(systemName: "figure.rower")
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(manager.lastStatusLine)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            statusBadgeForRower
        }
    }

    private var statusBadgeForRower: some View {
        Text(badge)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var stateDrivenButtonsForRower: some View {
        if manager.connectionState == .connected {
            disconnectButton
        } else if manager.connectionState == .scanning {
            stopScanningButton
        } else if !manager.knownDevices.isEmpty {
            reconnectButton
            pairAnotherButton
        } else {
            pairButton
        }
    }

    private var disconnectButton: some View {
        Button(role: .destructive) {
            manager.disconnect()
        } label: {
            Label(String(localized: "Disconnect", bundle: LanguageManager.appBundle), systemImage: "xmark.circle")
        }
    }

    private var stopScanningButton: some View {
        Button(role: .destructive) {
            manager.stopScanning()
        } label: {
            Label(String(localized: "Stop scanning", bundle: LanguageManager.appBundle), systemImage: "stop.circle")
        }
    }

    private var reconnectButton: some View {
        // Same pair-another pattern.
        Button {
            manager.reconnectLast()
        } label: {
            Label(String(localized: "Reconnect", bundle: LanguageManager.appBundle), systemImage: "arrow.clockwise")
        }
    }

    private var pairAnotherButton: some View {
        Button {
            manager.startScanning()
        } label: {
            Label(String(localized: "Pair another", bundle: LanguageManager.appBundle), systemImage: "magnifyingglass")
        }
    }

    private var pairButton: some View {
        Button {
            manager.startScanning()
        } label: {
            Label(String(localized: "Pair", bundle: LanguageManager.appBundle), systemImage: "magnifyingglass")
        }
    }

    private var title: String {
        manager.knownDevices.first?.name ?? String(localized: "Concept2 PM5", bundle: LanguageManager.appBundle)
    }

    private var color: Color {
        switch manager.connectionState {
        case .connected: return .green
        case .connecting, .scanning: return .blue
        case .disconnected:
            return manager.knownDevices.isEmpty ? .gray : .orange
        }
    }

    private var badge: String {
        switch manager.connectionState {
        case .connected: return String(localized: "Connected", bundle: LanguageManager.appBundle)
        case .connecting: return String(localized: "Connecting", bundle: LanguageManager.appBundle)
        case .scanning: return String(localized: "Scanning", bundle: LanguageManager.appBundle)
        case .disconnected: return manager.knownDevices.isEmpty ? String(localized: "Not paired", bundle: LanguageManager.appBundle) : String(localized: "Off", bundle: LanguageManager.appBundle)
        }
    }
}
