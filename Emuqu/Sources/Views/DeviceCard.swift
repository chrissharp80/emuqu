import SwiftUI

/// Build plan §3.11 — Polar device status card. Used on Record screen
/// and in Settings → Wearables.
///
/// States mirror the actual BLE lifecycle: connected / connecting /
/// disconnected / low-battery / firmware-update-available.
struct DeviceCard: View {
    let deviceName: String
    let batteryPercent: Int?
    let firmware: String?
    let connectionState: ConnectionState
    let lastSeen: Date?
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?

    enum ConnectionState: Equatable {
        case connected
        case connecting
        case disconnected
        case lowBattery(percent: Int)
        case firmwareUpdateAvailable

        var label: String {
            switch self {
            case .connected: String(localized: "Connected", bundle: LanguageManager.appBundle)
            case .connecting: String(localized: "Connecting…", bundle: LanguageManager.appBundle)
            case .disconnected: String(localized: "Disconnected", bundle: LanguageManager.appBundle)
            case .lowBattery: String(localized: "Low battery", bundle: LanguageManager.appBundle)
            case .firmwareUpdateAvailable: String(localized: "Firmware update", bundle: LanguageManager.appBundle)
            }
        }

        @MainActor var color: Color {
            switch self {
            case .connected: AppTheme.wongOptimal
            case .connecting: AppTheme.wongCaution
            case .disconnected: AppTheme.textTertiary
            case .lowBattery: AppTheme.wongAttention
            case .firmwareUpdateAvailable: AppTheme.wongGood
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            deviceHeaderRow
            deviceActionRow
            lowBatteryNote
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(connectionState.color.opacity(0.2), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(deviceName), \(connectionState.label)\(batteryPercent.map { String(localized: ", \($0) percent battery", bundle: LanguageManager.appBundle) } ?? "")", bundle: LanguageManager.appBundle))
    }

    private var deviceHeaderRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: deviceGlyph)
                .scaledFont(size: 24)
                .foregroundStyle(AppTheme.primary)
                .frame(width: 36)
            deviceTitleBlock
            Spacer()
            actionButton
        }
    }

    private var deviceTitleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: deviceName)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
            connectionStateRow
        }
    }

    private var connectionStateRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connectionState.color)
                .frame(width: 6, height: 6)
            Text(verbatim: connectionState.label)
                .scaledFont(size: 12)
                .foregroundStyle(connectionState.color)
            lastSeenLabel
        }
    }

    @ViewBuilder
    private var lastSeenLabel: some View {
        if let lastSeen {
            Text(verbatim: "·")
                .foregroundStyle(AppTheme.textTertiary)
            Text(verbatim: relativeTimeString(lastSeen))
                .scaledFont(size: 12)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private var deviceActionRow: some View {
        HStack(spacing: 12) {
            batteryPill
            firmwarePill
            Spacer()
        }
    }

    @ViewBuilder
    private var batteryPill: some View {
        if let battery = batteryPercent {
            HStack(spacing: 4) {
                Image(systemName: batteryGlyph(battery))
                    .scaledFont(size: 12)
                    .foregroundStyle(battery <= 20 ? AppTheme.wongAttention : AppTheme.textSecondary)
                Text(verbatim: "\(battery)%")
                    .scaledFont(size: 12, monospacedDigit: true)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var firmwarePill: some View {
        if let firmware {
            Text(verbatim: "FW \(firmware)")
                .scaledFont(size: 11)
                .foregroundStyle(AppTheme.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(AppTheme.sectionTint))
        }
    }

    @ViewBuilder
    private var lowBatteryNote: some View {
        if case let .lowBattery(p) = connectionState {
            Text(String(localized: "Battery at \(p)% — change before your next overnight session.", bundle: LanguageManager.appBundle))
                .scaledFont(size: 12)
                .foregroundStyle(AppTheme.wongAttention)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch connectionState {
        case .disconnected: connectButton
        case .connected, .lowBattery: disconnectButton
        case .connecting: ProgressView().controlSize(.small)
        case .firmwareUpdateAvailable: EmptyView()
        }
    }

    @ViewBuilder
    private var connectButton: some View {
        if let onConnect {
            Button(String(localized: "Connect", bundle: LanguageManager.appBundle), action: onConnect)
                .scaledFont(size: 13, weight: .semibold)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(AppTheme.primary.opacity(0.15)))
                .foregroundStyle(AppTheme.primary)
                .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var disconnectButton: some View {
        if let onDisconnect {
            Button(String(localized: "Disconnect", bundle: LanguageManager.appBundle), action: onDisconnect)
                .scaledFont(size: 13)
                .foregroundStyle(AppTheme.textSecondary)
                .buttonStyle(.plain)
        }
    }

    private var deviceGlyph: String {
        let name = deviceName.lowercased()
        if name.contains("h10") { return "heart.fill" }
        if name.contains("verity") { return "circle.dotted" }
        return "sensor.tag.radiowaves.forward"
    }

    private func batteryGlyph(_ pct: Int) -> String {
        switch pct {
        case 76...: "battery.100"
        case 51...75: "battery.75"
        case 26...50: "battery.50"
        case 6...25: "battery.25"
        default: "battery.0"
        }
    }

    private func relativeTimeString(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
}
