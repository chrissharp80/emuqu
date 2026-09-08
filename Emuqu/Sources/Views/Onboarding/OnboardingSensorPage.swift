import SwiftUI

/// Onboarding screen 2: Scan and pair a Polar sensor
struct OnboardingSensorPage: View {
    @Environment(RRCollector.self) var collector
    let advance: () -> Void

    private var polar: PolarManager {
        collector.polarManager
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Spacer(minLength: 20)
                sensorPageHeader
                stateDrivenContent
                Spacer(minLength: 24)
                appleHealthPrimer
                Spacer(minLength: 16)
                navigationButtons
            }
            .padding(.horizontal)
        }
        .onDisappear { stopScanningOnLeave() }
    }

    private var sensorPageHeader: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(.largeTitle))
                .fontWeight(.bold)
                .minimumScaleFactor(0.5)
                .foregroundStyle(AppTheme.mist)
                .accessibilityHidden(true)

            Text(String(localized: "Connect Your Sensor", bundle: LanguageManager.appBundle))
                .font(.title2.bold())
                .foregroundColor(AppTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Text(String(localized: "Pair a Polar H10 or Verity Sense. You can always do this later from the Record tab.", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var stateDrivenContent: some View {
        switch polar.connectionState {
        case .disconnected: disconnectedContent
        case .scanning: scanningContent
        case .connecting: connectingContent
        case .connected: connectedContent
        }
    }

    private var disconnectedContent: some View {
        VStack(spacing: 16) {
            knownDevicesList
            pairPolarH10Button
            pairPolarVeritySenseButton
            illDoThisLaterButton
        }
    }

    @ViewBuilder
    private var knownDevicesList: some View {
        if !polar.knownDevices.isEmpty {
            knownDevicesStack
        }
    }

    private var knownDevicesStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Known Devices", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.textSecondary)
            ForEach(polar.knownDevices) { device in
                knownDeviceButton(device)
            }
        }
    }

    private func knownDeviceButton(_ device: PolarManager.KnownDevice) -> some View {
        Button {
            polar.connect(deviceId: device.id)
        } label: {
            knownDeviceLabel(device)
        }
    }

    private func knownDeviceLabel(_ device: PolarManager.KnownDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.deviceType == .h10 ? "heart.fill" : "waveform.path")
                .foregroundColor(AppTheme.sage)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(AppTheme.textPrimary)
                Text(device.id)
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }
            Spacer()
            Text(String(localized: "Connect", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.medium))
                .foregroundColor(AppTheme.sage)
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.smallCornerRadius)
    }

    /// BP §O3 line 471 — explicit per-device buttons matching
    /// user-recognized brand names. Both kick off the same
    /// discovery scan; the discovered list filters down to
    /// whichever device the user actually owns. The label
    /// makes the intent obvious instead of forcing the user
    /// to know "we're looking for any nearby Polar."
    private var pairPolarH10Button: some View {
        Button {
            polar.startScanning()
        } label: {
            Label(String(localized: "Pair Polar H10", bundle: LanguageManager.appBundle), systemImage: "heart.fill")
                .frame(maxWidth: .infinity)
                .frame(height: 60) // 60pt for the joystick test
        }
        .buttonStyle(.zen(AppTheme.primary))
        .accessibilityHint(String(localized: "Search for a Polar H10 chest strap", bundle: LanguageManager.appBundle))
    }

    private var scanningContent: some View {
        VStack(spacing: 16) {
            scanningIndicator
            discoveredDevicesList
            stopScanningButton
        }
    }

    private var scanningIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(String(localized: "Scanning for Polar devices...", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var discoveredDevicesList: some View {
        if polar.discoveredDevices.isEmpty {
            Text(String(localized: "Make sure your sensor is nearby and turned on.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
                .multilineTextAlignment(.center)
        } else {
            ForEach(polar.discoveredDevices) { device in
                discoveredDeviceButton(device)
            }
        }
    }

    private func discoveredDeviceButton(_ device: PolarManager.DiscoveredDevice) -> some View {
        Button {
            polar.connect(deviceId: device.id)
        } label: {
            discoveredDeviceLabel(device)
        }
    }

    private var connectingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(String(localized: "Connecting...", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var connectedContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(.largeTitle))
                .minimumScaleFactor(0.5)
                .foregroundStyle(AppTheme.sage)
                .accessibilityHidden(true)
            connectedDeviceLabel
            Text(String(localized: "Your sensor is ready to use.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private var connectedDeviceLabel: some View {
        if let deviceId = polar.connectedDeviceId {
            Text("Connected to \(deviceId)")
                .font(.subheadline.weight(.medium))
                .foregroundColor(AppTheme.textPrimary)
        }
    }

    /// Priming text for the HealthKit
    /// auth prompt that fires when the user taps Next / Skip.
    /// Without this, the system prompt arrives unannounced and
    /// users deny in confusion (which then triggers the silent
    /// lockout the banner exists to recover from).
    private var appleHealthPrimer: some View {
        VStack(alignment: .leading, spacing: 8) {
            appleHealthPrimerHeading
            Text(String(localized: "iOS will ask permission to read your sleep, heart rate, and HRV data. Emuqu uses these to compute your recovery score. You can change any of these later in Settings → Privacy → Health.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.smallCornerRadius)
    }

    private var appleHealthPrimerHeading: some View {
        HStack(spacing: 8) {
            Image(systemName: "heart.text.square")
                .foregroundColor(AppTheme.sage)
                .accessibilityHidden(true)
            Text(String(localized: "Next: Apple Health", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.textPrimary)
        }
    }

    private var navigationButtons: some View {
        HStack {
            skipButton
            Spacer()
            nextButton
        }
        .padding(.bottom, 48)
    }

    private var skipButton: some View {
        Button(String(localized: "Skip", bundle: LanguageManager.appBundle)) { advance() }
            .buttonStyle(.zenSecondary)
            .accessibilityLabel(String(localized: "Skip", bundle: LanguageManager.appBundle))
            .accessibilityHint(String(localized: "Skip sensor pairing and continue", bundle: LanguageManager.appBundle))
            .accessibilityIdentifier("onboarding.skip")
    }

    private var nextButton: some View {
        Button(String(localized: "Next", bundle: LanguageManager.appBundle)) { advance() }
            .buttonStyle(.zen(AppTheme.sage))
            .accessibilityLabel(String(localized: "Next", bundle: LanguageManager.appBundle))
            .accessibilityHint(String(localized: "Continue to the next step", bundle: LanguageManager.appBundle))
            .accessibilityIdentifier("onboarding.advance")
    }

    private func stopScanningOnLeave() {
        if polar.connectionState == .scanning {
            polar.stopScanning()
        }
    }

    // MARK: - Disconnected

    private var pairPolarVeritySenseButton: some View {
        Button {
            polar.startScanning()
        } label: {
            Label(String(localized: "Pair Polar Verity Sense", bundle: LanguageManager.appBundle), systemImage: "waveform.path")
                .frame(maxWidth: .infinity)
                .frame(height: 60)
        }
        .buttonStyle(.zen(AppTheme.mist))
        .accessibilityHint(String(localized: "Search for a Polar Verity Sense armband", bundle: LanguageManager.appBundle))
    }

    private var illDoThisLaterButton: some View {
        // BP §O3 line 471 — "I'll do this later" tertiary link.
        // Distinct from the Skip button at the bottom (which still
        // skips the page entirely). This lets the user advance
        // without searching but stay on the page while they think
        // about it. Visually less prominent.
        Button {
            advance()
        } label: {
            Text(String(localized: "I'll do this later", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityHint(String(localized: "Skip pairing for now; you can do this later from Record.", bundle: LanguageManager.appBundle))
        .accessibilityIdentifier("onboarding.skip")
    }

    // MARK: - Scanning

    private var stopScanningButton: some View {
        Button(String(localized: "Stop Scanning", bundle: LanguageManager.appBundle)) {
            polar.stopScanning()
        }
        .buttonStyle(.zenSecondary)
    }

    private func discoveredDeviceLabel(_ device: PolarManager.DiscoveredDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.deviceType == .h10 ? "heart.fill" : "waveform.path")
                .foregroundColor(AppTheme.sage)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(AppTheme.textPrimary)
                Text("\(device.rssi) dBm")
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }
            Spacer()
            Text(String(localized: "Pair", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.medium))
                .foregroundColor(AppTheme.sage)
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.smallCornerRadius)
    }

    // MARK: - Connecting

    // MARK: - Connected
}

#Preview {
    OnboardingSensorPage(advance: {})
        .environment(RRCollector())
}
