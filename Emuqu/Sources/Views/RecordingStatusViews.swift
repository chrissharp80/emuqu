import SwiftUI

/// Isolated device info panel that observes PolarManager for battery/firmware updates.
/// Battery level arrives asynchronously after connection — without observation the
/// initial render shows no battery. This view re-evaluates when PolarManager publishes
/// changes.
struct DeviceInfoPanelObserving: View {
    var polarManager: PolarManager

    var body: some View {
        DeviceInfoPanelView(
            deviceType: polarManager.connectedDeviceType,
            batteryLevel: polarManager.batteryLevel,
            batteryLastChangedAt: polarManager.batteryLastChangedAt,
            hoursRecordedSinceChange: polarManager.hoursRecordedSinceBatteryChanged,
            specRecordingHours: polarManager.connectedDeviceType?.specRecordingHours,
            isBatteryReadingStale: polarManager.isBatteryReadingStale,
            firmwareVersion: polarManager.firmwareVersion,
            hasStoredExercise: polarManager.hasStoredExercise,
            storedExerciseDate: polarManager.storedExerciseDate,
            lastConnectedTime: polarManager.lastConnectedTime
        )
    }
}

// MARK: - Overnight Streaming Status (isolated from RecordView body evaluation)

/// Extracted so the per-second elapsed time and per-beat heartbeat count updates
/// only re-evaluate THIS view, not the parent overnightRecordingSection body.
struct OvernightStreamingStatus: View {
    enum StrapBackup {
        case notRequested
        case starting
        case recording
    }

    var streamingLifecycle: StreamingLifecycle
    var polarManager: PolarManager
    var strapBackup: StrapBackup = .notRequested

    var body: some View {
        VStack(spacing: 8) {
            recordingSection
            liveStatsOrWaiting
            strapBackupLine
            Text(String(localized: "Keep the app open - silent audio keeps it running in background.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.sage)
                .multilineTextAlignment(.center)
            Text(String(localized: "Tap 'Get Reading' when you're ready to analyze.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(AppTheme.sectionTint)
        .cornerRadius(AppTheme.smallCornerRadius)
    }

    private var totalBeats: Int {
        streamingLifecycle.pausedBeatCount + polarManager.streamedRRCount
    }

    /// The Verity Sense streams in batches, so it can sit at zero beats for the
    /// first 15–30 s. Say so rather than showing a live card full of zeroes.
    @ViewBuilder
    private var liveStatsOrWaiting: some View {
        if totalBeats == 0 {
            waitingForFirstBeat
        } else {
            liveStatsRow
        }
    }

    @ViewBuilder
    private var strapBackupLine: some View {
        switch strapBackup {
        case .notRequested:
            EmptyView()
        case .starting:
            Label(String(localized: "Strap backup: starting...", bundle: LanguageManager.appBundle), systemImage: "internaldrive")
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        case .recording:
            Label(String(localized: "Strap backup: recording", bundle: LanguageManager.appBundle), systemImage: "internaldrive.fill")
                .font(.caption)
                .foregroundColor(AppTheme.sage)
        }
    }

    /// Same height as the stats row, so the card does not jump when the
    /// first beat arrives.
    @ViewBuilder
    private var waitingForFirstBeat: some View {
        let isVeritySense = polarManager.connectedDeviceType == .veritySense
        HStack(spacing: 8) {
            ProgressView()
                .tint(AppTheme.sage)
            Text(isVeritySense
                ? String(localized: "Waiting for Verity Sense data...", bundle: LanguageManager.appBundle)
                : String(localized: "Waiting for the strap's first heartbeat...", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        }
        .padding(.vertical, 8)
        Text(isVeritySense
            ? String(localized: "The Verity Sense sends data in batches. The first reading usually arrives within 15-30 seconds.", bundle: LanguageManager.appBundle)
            : String(localized: "The strap starts sending beats a few seconds after it connects.", bundle: LanguageManager.appBundle))
            .font(.caption)
            .foregroundColor(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
    }

    private var liveStatsRow: some View {
        HStack(spacing: 20) {
            statColumn(value: formattedElapsed,
                       label: String(localized: "Elapsed", bundle: LanguageManager.appBundle),
                       color: AppTheme.primary)
            statColumn(value: "\(totalBeats)",
                       label: String(localized: "Heartbeats", bundle: LanguageManager.appBundle),
                       color: AppTheme.sage)
            bpmColumn
        }
        .padding(.vertical, 8)
    }

    /// Always render the BPM column — placeholder until the first HR sample
    /// lands — so the card keeps a fixed size from the first frame. Otherwise the
    /// column pops in ~1–2 s after start and the whole card reflows/grows just as
    /// the pre-start content (connection panel, capture picker) collapses away,
    /// which reads as the screen "folding in then flashing open".
    private var bpmColumn: some View {
        statColumn(
            value: polarManager.currentHeartRate.map { String(localized: "\($0)", bundle: LanguageManager.appBundle) } ?? "—",
            label: String(localized: "BPM", bundle: LanguageManager.appBundle),
            color: AppTheme.accent
        )
    }

    private func statColumn(value: String, label: String, color: Color) -> some View {
        VStack {
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundColor(color)
            Text(label)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private var recordingSection: some View {
        HStack {
            Image(systemName: "moon.zzz.fill")
                .foregroundColor(AppTheme.primary)
            Text(String(localized: "Recording...", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textPrimary)
        }
    }

    private var formattedElapsed: String {
        let seconds = streamingLifecycle.streamingElapsedSeconds
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
}

// MARK: - Device Recording Status (crash recovery / internal recording)

/// Shows recording-in-progress status when the device has an active offline recording.
/// After a crash, the persisted start time lets us show how long the recording has been running.
/// Extracted as a separate View so the per-minute timer only re-evaluates THIS view.
struct DeviceRecordingStatus: View {
    var deviceStatus: DeviceStatus
    let persistedStartTime: Date?

    @State private var elapsedSeconds: Int = 0
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            recordingOnDeviceSection

            deviceRecordingGuidance
        }
        .padding()
        .background(AppTheme.sectionTint)
        .cornerRadius(AppTheme.smallCornerRadius)
        .onAppear { updateElapsed() }
        .onReceive(timer) { _ in updateElapsed() }
    }

    @ViewBuilder
    private var deviceRecordingGuidance: some View {
        if persistedStartTime != nil {
            crashRecoveryGuidance
        } else {
            freshStartGuidance
        }
    }

    /// Crash recovery: show elapsed time from the persisted start.
    @ViewBuilder
    private var crashRecoveryGuidance: some View {
        elapsedReadout

        Text(String(localized: "Tap 'Wake Up - Get Results' to retrieve your data.", bundle: LanguageManager.appBundle))
            .font(.caption)
            .foregroundColor(AppTheme.sage)
            .multilineTextAlignment(.center)
    }

    /// Fresh start: the device is recording, and the user can go to sleep.
    @ViewBuilder
    private var freshStartGuidance: some View {
        Text(String(localized: "Go to sleep. \(deviceStatus.connectedDeviceType?.displayName ?? String(localized: "Device", bundle: LanguageManager.appBundle)) stores data internally — you can close the app.", bundle: LanguageManager.appBundle))
            .font(.caption)
            .foregroundColor(AppTheme.sage)
            .multilineTextAlignment(.center)

        Text(String(localized: "Open the app to retrieve your reading.", bundle: LanguageManager.appBundle))
            .font(.caption)
            .foregroundColor(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
    }

    private var recordingOnDeviceSection: some View {
        HStack {
            Image(systemName: "moon.zzz.fill")
                .foregroundColor(AppTheme.primary)
            Text(String(localized: "Recording on device...", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textPrimary)
        }
    }

    private var elapsedReadout: some View {
        HStack(spacing: 20) {
            VStack {
                Text(formattedElapsed)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundColor(AppTheme.primary)
                Text(String(localized: "Elapsed", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
        .padding(.vertical, 8)
    }

    private func updateElapsed() {
        guard let start = persistedStartTime else { return }
        elapsedSeconds = max(0, Int(Date().timeIntervalSince(start)))
    }

    private var formattedElapsed: String {
        let hours = elapsedSeconds / 3600
        let minutes = (elapsedSeconds % 3600) / 60
        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        } else {
            return String(format: "%d min", minutes)
        }
    }
}

// MARK: - Device Info Panel

/// Collapsible device info panel showing battery, firmware, memory status, and connection time
struct DeviceInfoPanelView: View {
    let deviceType: PolarDeviceType?
    let batteryLevel: Int?
    /// Wall-clock time at which the device last reported a CHANGED battery
    /// value. Different from "we received any callback" — Polar re-emits the
    /// current value on connect even when nothing changed, which doesn't tell
    /// us anything about discharge progress.
    var batteryLastChangedAt: Date?
    /// Cumulative recording hours the app has put on the strap since the
    /// device last reported a new battery value. A LOWER bound on real
    /// runtime consumed (the user may use the strap with other apps too).
    var hoursRecordedSinceChange: Double = 0
    /// Manufacturer-quoted runtime per battery / charge cycle. Used to scale
    /// the "X hours used" line into "approximately Y% of strap capacity".
    /// nil means unknown device.
    var specRecordingHours: Double?
    /// Set when `hoursRecordedSinceChange` exceeds 70 % of `specRecordingHours`
    /// — the displayed % is almost certainly stale. Computed by PolarManager
    /// rather than here so the warning fires even outside this panel.
    var isBatteryReadingStale: Bool = false
    let firmwareVersion: String?
    let hasStoredExercise: Bool
    let storedExerciseDate: Date?
    let lastConnectedTime: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            infoRow(
                label: String(localized: "Device", bundle: LanguageManager.appBundle),
                value: deviceType?.displayName ?? String(localized: "Unknown", bundle: LanguageManager.appBundle),
                icon: deviceType?.icon ?? "heart.fill"
            )

            batteryRows
            estimatedBatteryLifeRow
            firmwareRow

            // Internal Memory Status (H10 exercise / Verity Sense offline recording)
            memorySessionStoredSection

            connectedSection
        }
        .padding(12)
        .background(AppTheme.sectionTint)
        .cornerRadius(AppTheme.smallCornerRadius)
    }

    @ViewBuilder
    private var batteryRows: some View {
        if let battery = batteryLevel {
            batteryInfoRow(level: battery)
            batteryProvenanceRow
        }
    }

    /// Verity Sense: estimated battery life remaining (~30 hr from full).
    @ViewBuilder
    private var estimatedBatteryLifeRow: some View {
        if deviceType == .veritySense, let battery = batteryLevel {
            infoRow(
                label: String(localized: "Est. Battery Life", bundle: LanguageManager.appBundle),
                value: String(format: String(localized: "~%.0f hours", bundle: LanguageManager.appBundle),
                              30.0 * Double(battery) / 100.0),
                icon: "clock"
            )
        }
    }

    @ViewBuilder
    private var firmwareRow: some View {
        if let firmware = firmwareVersion {
            infoRow(label: String(localized: "Firmware", bundle: LanguageManager.appBundle), value: firmware, icon: "cpu")
        }
    }

    @ViewBuilder
    private var batteryProvenanceRow: some View {
        if hoursRecordedSinceChange > 0 || batteryLastChangedAt != nil {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isBatteryReadingStale ? "exclamationmark.triangle.fill" : "clock")
                    .foregroundColor(isBatteryReadingStale ? AppTheme.warning : AppTheme.textTertiary)
                    .frame(width: 20)
                batteryProvenanceText
                Spacer(minLength: 0)
            }
            .padding(.leading, 28)
        }
    }

    private var batteryProvenanceText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recordedSinceUpdateSummary)
                .font(.caption2)
                .foregroundColor(isBatteryReadingStale ? AppTheme.warning : AppTheme.textSecondary)
            lastReportedChangeLabel
            staleBatteryAdvice
        }
    }

    /// How much recording the strap has done since it last reported a battery
    /// change, expressed against the strap's spec capacity when we know it.
    private var recordedSinceUpdateSummary: String {
        if hoursRecordedSinceChange < 0.1 {
            return String(localized: "Reading is fresh", bundle: LanguageManager.appBundle)
        }
        let h = hoursRecordedSinceChange
        let hoursStr = h < 1 ? String(format: "%.0f min", locale: .current, h * 60) : String(format: "%.1f h", locale: .current, h)
        guard let spec = specRecordingHours, spec > 0 else {
            return String(localized: "\(hoursStr) recorded since update", bundle: LanguageManager.appBundle)
        }
        let pct = Int((hoursRecordedSinceChange / spec) * 100)
        return String(localized: "\(hoursStr) recorded since update (~\(pct)% of strap capacity)", bundle: LanguageManager.appBundle)
    }

    @ViewBuilder
    private var lastReportedChangeLabel: some View {
        if let changed = batteryLastChangedAt {
            Text("Strap last reported a change \(changed, style: .relative) ago", bundle: LanguageManager.appBundle)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    @ViewBuilder
    private var staleBatteryAdvice: some View {
        if isBatteryReadingStale {
            Text(String(localized: "Polar straps only push battery on change. Replace the cell soon.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.warning)
        }
    }

    @ViewBuilder
    private var memorySessionStoredSection: some View {
        if deviceType == .h10 || deviceType == .veritySense {
            if hasStoredExercise {
                storedSessionRow
            } else {
                infoRow(
                    label: String(localized: "Memory", bundle: LanguageManager.appBundle),
                    value: String(localized: "Empty (ready)", bundle: LanguageManager.appBundle),
                    icon: "internaldrive",
                    valueColor: AppTheme.sage
                )
            }
        }
    }

    private var storedSessionRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive.fill")
                .foregroundColor(.orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Memory: Session Stored", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.orange)
                storedSessionDateLabel
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var storedSessionDateLabel: some View {
        if let date = storedExerciseDate {
            Text(date, style: .relative)
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var connectedSection: some View {
        if let lastTime = lastConnectedTime {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(AppTheme.textTertiary)
                    .frame(width: 20)
                Text(String(localized: "Connected", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
                Spacer()
                Text(lastTime, style: .relative)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(AppTheme.textPrimary)
                    + Text(String(localized: " ago", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
    }

    @MainActor private func infoRow(
        label: String,
        value: String,
        icon: String,
        valueColor: Color? = nil
    ) -> some View {
        let valueColor = valueColor ?? AppTheme.textPrimary
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(AppTheme.textTertiary)
                .frame(width: 20)
            Text(label)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(valueColor)
        }
    }

    private func batteryInfoRow(level: Int) -> some View {
        let clampedLevel = min(100, max(0, level))
        let batteryFill = Double(clampedLevel) / 100.0

        return HStack(spacing: 8) {
            Image(systemName: "battery.100percent", variableValue: batteryFill)
                .foregroundColor(AppTheme.textTertiary)
                .frame(width: 20)
            Text(String(localized: "Battery", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
            Spacer()
            Text("\(clampedLevel)%")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(batteryColor(clampedLevel))
        }
    }

    private func batteryColor(_ level: Int) -> Color {
        if level < 10 { return AppTheme.alert }
        if level < 20 { return AppTheme.warning }
        return AppTheme.sage
    }

    /// Provenance line under the battery row: how many recording hours we've
    /// put on the strap since the device last reported a NEW battery value,
    /// optionally as a fraction of the manufacturer-quoted runtime.
    ///
    /// Why this exists: Polar's BLE Battery Service only pushes notifications
    /// when the value actually changes. The Polar SDK exposes only a cached
    /// "last observed" getter — there is no way to force a fresh BLE READ.
    /// So a Polar H10 that genuinely sat at 100 % for two weeks looks
    /// identical to one whose owner is about to wake up to a dead strap. The
    /// only signal we can compute is "we've recorded N hours since the
    /// strap last said its number changed". We compare that to the strap's
    /// spec runtime (~400 h H10, ~30 h Verity) to flag a stale reading
    /// before it bites.
}
