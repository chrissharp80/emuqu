import SwiftUI
import WatchKit

// Wrist-side pairing flow for `WatchStrapConnector`. Three phases:
//
//   1. Already connected — show device name, battery, live HR if it
//      has streamed at least one sample, plus a Forget button.
//   2. Connecting / scanning — progress with the discovered list. Tap
//      a row to commit.
//   3. Idle (BT off / not allowed / waiting) — explain why we can't
//      scan and what the user can do about it.
//
// The view stays in scrolling-list shape so it works even on a 41 mm
// face. No fancy graphics — every row is a tap target sized for a
// fingertip.
struct WatchStrapPairingView: View {
    @EnvironmentObject private var connector: WatchStrapConnector

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                stateHeader
                Divider()
                content
            }
            .padding(.horizontal, 6)
        }
        .navigationTitle(String(localized: "Strap"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Fire-and-forget scan trigger; the connector itself
            // dedups against an existing connection / saved peripheral
            // and skips the scan if a reconnect is sufficient.
            connector.startScanning()
        }
        .onDisappear {
            // Stop scanning when the user backs out so the BT radio
            // isn't kept hot. An active connection persists; only
            // active discovery stops.
            connector.stopScanning()
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var stateHeader: some View {
        switch connector.connectionState {
        case .connected(let name): connectedHeader(name: name)
        case .connecting(let name): connectingHeader(name: name)
        case .scanning: statusRow("antenna.radiowaves.left.and.right", .blue,
                                  String(localized: "Searching…"),
                                  String(localized: "Wear your strap so it advertises"))
        case .poweredOff: statusRow("bolt.slash.fill", .orange,
                                    String(localized: "Bluetooth is off"),
                                    String(localized: "Turn it on in Watch Settings → Bluetooth"))
        case .unauthorized: statusRow("lock.fill", .orange,
                                      String(localized: "Bluetooth not allowed"),
                                      String(localized: "Allow Emuqu to use Bluetooth in Watch Settings → Privacy"))
        case .waitingForBluetooth: statusRow("ellipsis", .gray,
                                             String(localized: "Bluetooth warming up"), "")
        case .disconnected(let reason): disconnectedHeader(reason: reason)
        case .idle: statusRow("antenna.radiowaves.left.and.right", .gray,
                              String(localized: "Ready to scan"), "")
        }
    }

    private func connectingHeader(name: String) -> some View {
        statusRow("arrow.triangle.2.circlepath", .blue,
                  String(localized: "Connecting \(name)…"),
                  String(localized: "Hold the strap close to your wrist"))
    }

    /// The disconnect reason when the radio gave one, and the recovery
    /// instruction when it did not.
    private func disconnectedHeader(reason: String?) -> some View {
        statusRow("wifi.exclamationmark", .orange,
                  String(localized: "Disconnected"),
                  reason ?? String(localized: "Tap a strap below to reconnect."))
    }

    private func statusRow(_ icon: String, _ tint: Color, _ title: String, _ subtitle: String) -> some View {
        simpleStatusRow(icon: icon, tint: tint, title: title, subtitle: subtitle)
    }

    @ViewBuilder
    private var content: some View {
        if case .connected = connector.connectionState {
            connectedActions
        } else {
            discoveredList
        }
    }

    // MARK: Connected

    @ViewBuilder
    private func connectedHeader(name: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text(name)
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            HStack(spacing: 12) {
                if let bpm = connector.liveHeartRate {
                    Label(String(localized: "\(bpm) bpm"), systemImage: "waveform.path.ecg")
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
                if let battery = connector.batteryPercent {
                    Label("\(battery)%", systemImage: "battery.50")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !connector.lastRRMillis.isEmpty {
                Text("RR: \(connector.lastRRMillis.map { String(format: "%.0f", $0) }.joined(separator: ", ")) ms")
                    .watchScaledFont(size: 10, design: .monospaced, relativeTo: .caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var connectedActions: some View {
        VStack(spacing: 6) {
            Button(role: .destructive) {
                connector.disconnectAndForget()
            } label: {
                Label(String(localized: "Forget Strap"), systemImage: "minus.circle")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: Discovery

    @ViewBuilder
    private var discoveredList: some View {
        if connector.discovered.isEmpty {
            emptyDiscoveryState
            // Shown even on first appear, so the user can poke the BLE stack
            // if it did not auto-start.
            rescanButton
        } else {
            ForEach(connector.discovered) { device in deviceRow(device) }
            rescanButton
        }
    }

    /// The spinner is the point: an empty list with no visual cue is
    /// indistinguishable from a Refresh that did nothing.
    private var emptyDiscoveryState: some View {
        HStack(spacing: 8) {
            if case .scanning = connector.connectionState {
                ProgressView().progressViewStyle(.circular).scaleEffect(0.7)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(connector.connectionState == .scanning
                    ? String(localized: "Searching…")
                    : String(localized: "No straps yet"))
                    .font(.caption)
                Text(String(localized: "Wear the strap (sensor pad must be wet) and stay within 2 m of your wrist."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func deviceRow(_ device: WatchStrapConnector.DiscoveredDevice) -> some View {
        Button { select(device) } label: { deviceRowLabel(device) }
            .buttonStyle(.bordered)
    }

    private func select(_ device: WatchStrapConnector.DiscoveredDevice) {
        WKInterfaceDevice.current().play(.click)
        connector.connect(to: device)
    }

    private func deviceRowLabel(_ device: WatchStrapConnector.DiscoveredDevice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.caption2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.caption.weight(.semibold)).lineLimit(1)
                Text("\(device.rssi) dBm")
                    .watchScaledFont(size: 10, relativeTo: .caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var rescanButton: some View {
        // Re-extracted so the empty-state and populated-state arms
        // share the same button. Haptic on tap, ProgressView while
        // scanning is in flight — gives the user something to look at
        // so they don't keep mashing the tap.
        Button {
            WKInterfaceDevice.current().play(.click)
            connector.startScanning()
        } label: {
            HStack(spacing: 6) {
                if case .scanning = connector.connectionState {
                    ProgressView().progressViewStyle(.circular).scaleEffect(0.6)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(connector.connectionState == .scanning ? String(localized: "Searching…") : String(localized: "Refresh"))
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(connector.connectionState == .scanning)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func simpleStatusRow(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.caption)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .watchScaledFont(size: 11, relativeTo: .caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
