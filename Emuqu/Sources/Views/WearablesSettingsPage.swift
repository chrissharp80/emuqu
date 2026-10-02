import SwiftUI

// MARK: - Wearables & Apple Health Settings Page
//
// Covers BLE foot-pod pairing, Apple Health export toggles, and the
// one-and-done cleanup for historical sleep samples the app wrote before
// we stopped doing that.

struct WearablesSettingsPage: View {
    @Environment(\.dependencies) var dependencies
    /// Materials go opaque when the user asks for reduced transparency —
    /// iOS does not substitute for you. See `AdaptiveMaterial`.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @Environment(SettingsManager.self) var settingsManager
    /// Two-way access to the settings for controls. An `@Environment` value has
    /// no projected `$` binding, so this stands in for `$settingsManager.settings`.
    private var settingsBinding: Binding<UserSettings> {
        Binding(get: { settingsManager.settings }, set: { settingsManager.settings = $0 })
    }
    @Environment(RRCollector.self) var collector
    @Environment(LanguageManager.self) private var languageManager

    private var footPod: FootPodManager { dependencies.collection.footPodManager }
    @State private var isCleaningSleepWrites = false
    @State private var showingSleepCleanupConfirm = false
    @State private var showingSleepCleanupResult = false
    @State private var sleepCleanupMessage = ""

    /// HealthKit re-auth flow. HKHealthStore deliberately
    /// hides denial state, so once a user denies permissions there's no
    /// in-app signal we can use to detect it. `requestAuthorization` is
    /// idempotent — calling it again will either prompt for any types
    /// the user hasn't seen yet, or no-op silently.
    @State private var isReprompting = false
    @State private var showingHKHelpSheet = false

    /// First-enable-of-broadcast in-app explainer.
    /// The OS Bluetooth purpose string covers all BLE roles in one shot,
    /// but the act of switching from "your sensors connect to your phone"
    /// to "your phone broadcasts your HR + power outbound to other apps"
    /// deserves a dedicated explainer the user must read once per device.
    /// Stored in UserDefaults so it persists across launches but isn't
    /// synced to iCloud — re-enabling on a different device re-shows it.
    @State private var showingBroadcastExplainer = false
    @AppStorage("settings.broadcaster.acknowledged") private var broadcastAcknowledged: Bool = false

    var body: some View {
        withCleanupResult(withCleanupDialogs(wearablesForm))
    }

    private var wearablesForm: some View {
        Form {
            footPodSection
            healthKitPermissionsSection
            broadcasterSection
            appleHealthExportSection
            sleepCleanupSection
        }
        .zenFormBackground()
    }

    private func withCleanupDialogs(_ content: some View) -> some View {
        content
            .confirmationDialog(
                Text("Delete Emuqu sleep samples from Apple Health?", bundle: LanguageManager.appBundle),
                isPresented: $showingSleepCleanupConfirm,
                titleVisibility: .visible
            ) {
                sleepCleanupActions
            } message: {
                Text("This removes only sleep samples written by Emuqu. Watch and third-party sleep data are untouched. Cannot be undone.", bundle: LanguageManager.appBundle)
            }
    }

    private func withCleanupResult(_ content: some View) -> some View {
        content
            .alert(
                Text("Sleep Cleanup", bundle: LanguageManager.appBundle),
                isPresented: $showingSleepCleanupResult
            ) {
                sleepCleanupResultActions
            } message: {
                Text(sleepCleanupMessage)
            }
            .sheet(isPresented: $showingHKHelpSheet) {
                healthKitHelpSheet
            }
            .sheet(isPresented: $showingBroadcastExplainer) { broadcasterDisclosure }
            .navigationTitle(String(localized: "Wearables", bundle: LanguageManager.appBundle))
    }

    private var sleepCleanupResultActions: some View {
        Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) {}
    }

    @ViewBuilder
    private var sleepCleanupActions: some View {
        Button(String(localized: "Delete", bundle: LanguageManager.appBundle), role: .destructive) { runSleepCleanup() }
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
    }

    private var broadcasterDisclosure: some View {
        BroadcasterDisclosureSheet(
            onAccept: {
                broadcastAcknowledged = true
                settingsManager.settings.enableZwiftBroadcast = true
                showingBroadcastExplainer = false
            },
            onDecline: {
                settingsManager.settings.enableZwiftBroadcast = false
                showingBroadcastExplainer = false
            }
        )
    }

    private var appleHealthExportSection: some View {
        Section {
            Toggle(
                String(localized: "Export to Apple Health", bundle: LanguageManager.appBundle),
                isOn: settingsBinding.enableHealthKitExport
            )
            .accessibilityHint(Text("Write HRV and heart-rate results back to the Health app.", bundle: LanguageManager.appBundle))

            healthKitExportToggles
        } header: {
            Text("Apple Health Export", bundle: LanguageManager.appBundle)
        } footer: {
            Text("HRV and heart rate are written automatically after each recording. Sleep is only written when Apple Health had no sleep for the night but the strap detected it from your heart rate — the \u{201C}forgot your Watch\u{201D} case. Watch-recorded sleep is never overwritten.", bundle: LanguageManager.appBundle)
        }
    }

    @ViewBuilder
    private var healthKitExportToggles: some View {
        if settingsManager.settings.enableHealthKitExport {
            Toggle(
                String(localized: "HRV (SDNN)", bundle: LanguageManager.appBundle),
                isOn: settingsBinding.exportSDNN
            )
            Toggle(
                String(localized: "Mean Heart Rate", bundle: LanguageManager.appBundle),
                isOn: settingsBinding.exportHeartRate
            )
            Toggle(
                String(localized: "Resting Heart Rate", bundle: LanguageManager.appBundle),
                isOn: settingsBinding.exportRestingHeartRate
            )
            Toggle(
                String(localized: "Sleep (fill-in only)", bundle: LanguageManager.appBundle),
                isOn: settingsBinding.exportSleepData
            )
            .accessibilityHint(Text("Writes detected sleep to Health only when Health has none for that night.", bundle: LanguageManager.appBundle))
        }
    }

    /// Removes the sleep samples the app wrote to Apple Health. A
    /// user-requested escape hatch, not automatic.
    private var sleepCleanupSection: some View {
        Section {
            deleteSleepWritesButton
        } footer: {
            Text("Removes every sleep sample this app has written to Apple Health. Watch and other sources are untouched.", bundle: LanguageManager.appBundle)
        }
    }

    private var deleteSleepWritesButton: some View {
        Button(role: .destructive) {
            showingSleepCleanupConfirm = true
        } label: {
            deleteSleepWritesLabel
        }
        .disabled(isCleaningSleepWrites)
        .accessibilityLabel(Text("Delete Emuqu sleep samples from Apple Health", bundle: LanguageManager.appBundle))
    }

    private var deleteSleepWritesLabel: some View {
        HStack {
            if isCleaningSleepWrites {
                ProgressView().scaleEffect(0.8)
                Text("Cleaning up…", bundle: LanguageManager.appBundle)
            } else {
                Image(systemName: "trash")
                    .accessibilityHidden(true)
                Text("Delete Emuqu sleep from Apple Health", bundle: LanguageManager.appBundle)
            }
        }
    }

    @ViewBuilder
    private var healthKitHelpSheet: some View {
        NavigationStack {
            healthKitHelpBody
                .navigationTitle(String(localized: "Apple Health Permissions", bundle: LanguageManager.appBundle))
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) { healthKitHelpActions }
        }
    }

    private var healthKitHelpBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(localized: "If you previously denied Apple Health access, iOS won't show the system prompt again. The only way to re-enable specific categories is in the iOS Settings app, not here.", bundle: LanguageManager.appBundle))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text(String(localized: "Step-by-step", bundle: LanguageManager.appBundle))
                    .font(.subheadline.bold())

                healthKitHelpSteps

                Text(String(localized: "Why we can't deep-link there", bundle: LanguageManager.appBundle))
                    .font(.subheadline.bold())

                Text(String(localized: "Apple deliberately doesn't expose a URL scheme that opens the per-app Health permissions page. The button below opens Emuqu's own iOS Settings page; from there, navigate to Privacy & Security → Health → Emuqu.", bundle: LanguageManager.appBundle))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
    }

    private var healthKitHelpSteps: some View {
        bulletList([
            "Open the iOS Settings app (the gear icon on your Home Screen).",
            "Tap Privacy & Security.",
            "Tap Health.",
            "Tap Emuqu.",
            "Toggle on every category you want the app to read or write — at minimum, Sleep, Heart Rate, and Heart Rate Variability.",
            "Come back to Emuqu and pull-to-refresh the dashboard."
        ])
    }

    private var healthKitHelpActions: some View {
        VStack(spacing: 10) {
            openSettingsButton
            Button {
                showingHKHelpSheet = false
            } label: {
                Text(String(localized: "Close", bundle: LanguageManager.appBundle))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .background(AdaptiveMaterial.ultraThin(reduceTransparency))
    }

    private var openSettingsButton: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            showingHKHelpSheet = false
        } label: {
            Text(String(localized: "Open iOS Settings", bundle: LanguageManager.appBundle))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    @ViewBuilder
    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { bulletRow($0) }
        }
    }

    private func bulletRow(_ item: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(String(localized: "•", bundle: LanguageManager.appBundle)).foregroundStyle(AppTheme.textSecondary)
            Text(item)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    // Re-prompt + help path. HKHealthStore's
    // privacy posture (no denial signal) means the only recovery path
    // is the user re-running the auth flow + going into iOS Settings →
    // Privacy & Security → Health → Emuqu to flip individual
    // toggles.
    @ViewBuilder
    private var healthKitPermissionsSection: some View {
        Section {
            repromptHealthKitButton

            Button {
                showingHKHelpSheet = true
            } label: {
                Label(String(localized: "Help: Apple Health permissions", bundle: LanguageManager.appBundle), systemImage: "questionmark.circle")
            }
        } header: {
            Text("Apple Health Access", bundle: LanguageManager.appBundle)
        } footer: {
            Text("If Emuqu isn't reading your sleep, HRV, or workouts, your Apple Health permissions may be off. Tap the re-request button to bring up the system prompt again, or open the help guide for the manual steps.", bundle: LanguageManager.appBundle)
        }
    }

    private var repromptHealthKitButton: some View {
        Button { repromptHealthKit() } label: {
            repromptHealthKitLabel
        }
        .disabled(isReprompting)
    }

    private var repromptHealthKitLabel: some View {
        HStack {
            Label(String(localized: "Re-request Apple Health permissions", bundle: LanguageManager.appBundle), systemImage: "heart.text.square")
            if isReprompting {
                Spacer()
                ProgressView().scaleEffect(0.8)
            }
        }
    }

    private func repromptHealthKit() {
        isReprompting = true
        Task {
            do {
                try await collector.healthKit.requestAuthorization()
            } catch {
                debugLog("[Wearables] re-prompt HK auth failed: \(error)", level: .warning)
            }
            await MainActor.run { isReprompting = false }
        }
    }

    // covers Polar + Stryd + Concept2 + broadcaster in one disclosure, but
    // the in-app toggle that flips Emuqu from BLE *consumer* to BLE
    // *peripheral* gets its own gate the first time it's enabled. Users
    // need to know their HR + power are leaving the device outbound to
    // other apps on their network (Zwift, TrainerRoad, Rouvy).
    @ViewBuilder
    private var broadcasterSection: some View {
        Section {
            broadcastToggle
        } header: {
            Text("Broadcast as BLE sensor", bundle: LanguageManager.appBundle)
        } footer: {
            Text("Off by default. When on, your live heart rate and cycling power are advertised over Bluetooth so Zwift, TrainerRoad, Rouvy, and similar apps can subscribe to them. Only active during a workout.", bundle: LanguageManager.appBundle)
        }
    }

    private var broadcastToggle: some View {
        Toggle(
            String(localized: "Broadcast HR + Power to indoor-trainer apps", bundle: LanguageManager.appBundle),
            isOn: Binding(
                get: { settingsManager.settings.enableZwiftBroadcast },
                set: { newValue in
                    if newValue && !broadcastAcknowledged {
                        // Defer the actual flip until the user accepts.
                        showingBroadcastExplainer = true
                    } else {
                        settingsManager.settings.enableZwiftBroadcast = newValue
                    }
                }
            )
        )
        .accessibilityHint(Text("When enabled, your iPhone advertises as a Heart Rate and Cycling Power BLE peripheral so apps like Zwift can pair to it.", bundle: LanguageManager.appBundle))
    }

    // MARK: - Foot pod section
    //
    // Pairs with generic BLE running foot pods — Stryd, Polar Stride Sensor,
    // Milestone, Garmin HRM-Pro+. Provides direct speed + cadence (bypasses
    // GPS jitter) and, for Stryd-class devices, running power. During a
    // workout the recorder takes foot-pod readings in preference to GPS +
    // pedometer when available.
    @ViewBuilder
    private var footPodSection: some View {
        Section {
            footPodStatusRow
            knownFootPods
            footPodConnectionControls
            discoveredFootPods
        } header: {
            Text("Foot Pod / Running Power", bundle: LanguageManager.appBundle)
        } footer: {
            Text("Pairs with Stryd, Polar Stride Sensor, Milestone, Garmin HRM-Pro+, and any BLE running pod. Connect the pod (take it out of storage mode — most need a gentle tap) then tap Scan. During a workout, the foot pod overrides GPS for speed/cadence and provides power when supported (Stryd).", bundle: LanguageManager.appBundle)
        }
    }

    private var footPodStatusRow: some View {
        HStack {
            Image(systemName: footPod.connectionState == .connected
                ? "figure.run.circle.fill"
                : "figure.run.circle")
                .foregroundStyle(footPod.connectionState == .connected ? Color.green : AppTheme.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(footPodStatusTitle)
                    .font(.subheadline.weight(.medium))
                Text(footPod.lastStatusLine)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)

    }

    private var knownFootPods: some View {
        ForEach(footPod.knownDevices) { dev in
            knownFootPodRow(dev)
        }
    }

    private func knownFootPodRow(_ dev: FootPodManager.KnownFootPod) -> some View {
        Button {
            footPod.connect(deviceId: dev.id)
        } label: {
            knownFootPodLabel(dev)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                footPod.removeKnownDevice(id: dev.id)
            } label: {
                Label(
                    String(localized: "Forget", bundle: LanguageManager.appBundle),
                    systemImage: "trash"
                )
            }
        }
    }

    private func knownFootPodLabel(_ dev: FootPodManager.KnownFootPod) -> some View {
        HStack {
            footPodCapabilities(dev)
            Spacer()
            Text("Reconnect", bundle: LanguageManager.appBundle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.primary)
        }
    }

    private func footPodCapabilities(_ dev: FootPodManager.KnownFootPod) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(dev.name)
                .foregroundStyle(AppTheme.textPrimary)
            if dev.supportsPower {
                Text("Speed, cadence, power", bundle: LanguageManager.appBundle)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
            } else {
                Text("Speed, cadence", bundle: LanguageManager.appBundle)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var footPodConnectionControls: some View {
        switch footPod.connectionState {
        case .scanning: stopScanningButton
        case .connected: disconnectFootPodButton
        default: scanForFootPodsButton
        }
    }

    private var stopScanningButton: some View {
        Button { footPod.stopScanning() } label: {
            HStack {
                ProgressView().scaleEffect(0.7)
                Text("Scanning…", bundle: LanguageManager.appBundle)
                Spacer()
                Text("Stop", bundle: LanguageManager.appBundle).font(.caption)
            }
        }
    }

    private var disconnectFootPodButton: some View {
        Button(role: .destructive) { footPod.disconnect() } label: {
            Text("Disconnect", bundle: LanguageManager.appBundle)
        }
    }

    private var scanForFootPodsButton: some View {
        Button { footPod.startScanning() } label: {
            Label(
                String(localized: "Scan for foot pod", bundle: LanguageManager.appBundle),
                systemImage: "antenna.radiowaves.left.and.right"
            )
        }
    }

    @ViewBuilder
    private var discoveredFootPods: some View {
        if !footPod.discoveredDevices.isEmpty, footPod.connectionState == .scanning {
            ForEach(footPod.discoveredDevices) { dev in
                discoveredFootPodRow(dev)
            }
        }
    }

    private func discoveredFootPodRow(_ dev: FootPodManager.DiscoveredFootPod) -> some View {
        Button {
            footPod.connect(deviceId: dev.id)
        } label: {
            discoveredFootPodLabel(dev)
        }
    }

    private func discoveredFootPodLabel(_ dev: FootPodManager.DiscoveredFootPod) -> some View {
        HStack {
            Text(dev.name).foregroundStyle(AppTheme.textPrimary)
            Spacer()
            if dev.supportsPower {
                Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                    .font(.caption)
                    .accessibilityHidden(true)
            }
            Text("\(dev.rssi) dBm", bundle: LanguageManager.appBundle)
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private var footPodStatusTitle: String {
        switch footPod.connectionState {
        case .disconnected:
            return String(localized: "No foot pod connected", bundle: LanguageManager.appBundle)
        case .scanning:
            return String(localized: "Looking for foot pods…", bundle: LanguageManager.appBundle)
        case .connecting:
            return String(localized: "Connecting…", bundle: LanguageManager.appBundle)
        case .connected:
            var parts: [String] = [String(localized: "Connected", bundle: LanguageManager.appBundle)]
            if let s = footPod.instantaneousSpeedMS {
                parts.append(String(format: "%.2f m/s", locale: .current, s))
            }
            if let w = footPod.instantaneousPowerWatts {
                parts.append("\(w) W")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// Wipes every sleep sample this app has written to Apple Health. The app
    /// does not write sleep any more, so this is a one-and-done
    /// cleanup — after it runs, there's nothing new to remove on a repeat.
    private func runSleepCleanup() {
        guard !isCleaningSleepWrites else { return }
        isCleaningSleepWrites = true
        Task {
            let message = await Self.sleepCleanupMessage(healthKit: collector.healthKit)
            await MainActor.run { finishSleepCleanup(message) }
        }
    }

    private static func sleepCleanupMessage(healthKit: HealthKitManager) async -> String {
        do {
            let count = try await healthKit.deleteAllAppWrittenSleepSamples()
            return count == 0
                ? String(localized: "No Emuqu sleep samples found in Apple Health. Nothing to clean up.", bundle: LanguageManager.appBundle)
                : String(localized: "Removed \(count) sleep samples written by Emuqu.", bundle: LanguageManager.appBundle)
        } catch {
            return String(localized: "Cleanup failed: \(error.localizedDescription)", bundle: LanguageManager.appBundle)
        }
    }

    @MainActor
    private func finishSleepCleanup(_ message: String) {
        isCleaningSleepWrites = false
        sleepCleanupMessage = message
        showingSleepCleanupResult = true
    }
}
