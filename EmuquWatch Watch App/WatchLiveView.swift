import SwiftUI
import WatchKit

// Top-level Watch UI. Vertical-paged TabView:
//
//   1. StartScreen — before/between workouts. Pick sport + target zone
//      via full-screen navigation pickers (tap row → list), not the
//      tiny inline wheels that were unreadable on a 41 mm face. Start,
//      or open the voice chat on the iPhone.
//   2. LiveMetricsScreen — dense glanceable HR/pace/distance/α1 grid.
//      Shows a prominent PAUSED banner when the session is paused.
//   3. PauseStopScreen — Pause ↔ Resume toggle + End. Dedicated so the
//      buttons can't be fat-fingered from the metrics screen.
//
// When the workout just finished, the whole tree is replaced by
// CompletionScreen — big Save & Done to dismiss the post-workout sheet
// on the phone and reset the Watch back to the Start page.
struct WatchLiveView: View {
    @ObservedObject var sessionManager: WatchSessionManager
    @ObservedObject var workoutManager: WatchWorkoutManager

    /// TabView selection — bound to the page tags below so we can auto-
    /// jump to the LiveMetrics page when `isRecording` flips true (the
    /// user starts a workout from the iPhone, OR taps Start on the
    /// Watch and iOS sends back the next live snapshot). Without this,
    /// the user would manually have to swipe to see the data they just
    /// asked for.
    @State private var page: TabPage = .start

    /// Stable, never-conditional page identities. Conditional inclusion
    /// of `PauseStopScreen` (the previous shape, gated on `isRecording`)
    /// caused the watchOS `AttributeGraph cycle detected` warnings —
    /// the TabView was rebuilding its child set inside the same update
    /// pass that flipped `isRecording`. Keeping all three pages always
    /// present and gating the *content* internally is the standard
    /// SwiftUI fix.
    private enum TabPage: Hashable { case start, live, pauseStop }

    /// The `onChange` sits outside the branch: a workout ending swaps the
    /// pages for `CompletionScreen` in the same update, and a modifier on the
    /// removed pages would never see the change, leaving `page` on Live.
    var body: some View {
        Group {
            if sessionManager.justCompleted {
                completion
            } else {
                pages.tabViewStyle(.verticalPage)
            }
        }
        .onChange(of: sessionManager.isRecording) { _, isRec in followRecording(isRec) }
    }

    private var completion: some View {
        NavigationStack {
            CompletionScreen(sessionManager: sessionManager)
        }
    }

    private var pages: some View {
        TabView(selection: $page) {
            NavigationStack {
                StartScreen(sessionManager: sessionManager)
            }
            .tag(TabPage.start)

            LiveMetricsScreen(sessionManager: sessionManager, workoutManager: workoutManager)
                .tag(TabPage.live)

            PauseStopScreen(sessionManager: sessionManager)
                .tag(TabPage.pauseStop)
        }
    }

    /// A workout starting on either device jumps to the live page so the user
    /// sees their data; one ending returns to the start screen so the next
    /// begins somewhere familiar. Only on transitions — `onChange` gives that.
    private func followRecording(_ isRecording: Bool) {
        if isRecording, page == .start {
            page = .live
        } else if !isRecording, page == .live || page == .pauseStop {
            page = .start
        }
    }
}

// MARK: - Sport + Zone options (shared)

struct SportOption: Hashable, Identifiable {
    let raw: String
    let label: String
    var id: String { raw }
}

let sportOptions: [SportOption] = [
    SportOption(raw: "run", label: String(localized: "Run")),
    SportOption(raw: "walk", label: String(localized: "Walk")),
    SportOption(raw: "bike", label: String(localized: "Ride")),
    SportOption(raw: "treadmill", label: String(localized: "Treadmill")),
    SportOption(raw: "indoor_bike", label: String(localized: "Indoor Ride"))
]

struct ZoneOption: Hashable, Identifiable {
    let value: Int    // 0 = no target
    let label: String
    var id: Int { value }

    /// The row value on the start screen: "Zone 3", or "No target". Built
    /// from `value`, not cut out of the translated `label`, whose separator
    /// differs by language (Spanish uses a colon).
    var shortLabel: String {
        value == 0 ? label : String(localized: "Zone \(value)")
    }
}

let zoneOptions: [ZoneOption] = [
    ZoneOption(value: 0, label: String(localized: "No target")),
    ZoneOption(value: 1, label: String(localized: "Zone 1 — Recovery")),
    ZoneOption(value: 2, label: String(localized: "Zone 2 — Aerobic")),
    ZoneOption(value: 3, label: String(localized: "Zone 3 — Tempo")),
    ZoneOption(value: 4, label: String(localized: "Zone 4 — Threshold")),
    ZoneOption(value: 5, label: String(localized: "Zone 5 — VO₂ max"))
]

// MARK: - Start screen

private struct StartScreen: View {
    @ObservedObject var sessionManager: WatchSessionManager
    /// Observe the direct-strap connector so the "Pair Strap to Watch"
    /// row updates its label/tint live as BLE state moves through
    /// scanning → connecting → connected.
    @EnvironmentObject private var strap: WatchStrapConnector
    @State private var selectedSport: SportOption = sportOptions[0]
    /// 0 = no target.
    @State private var selectedZone: ZoneOption = zoneOptions[0]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(.horizontal, 6)
        }
    }

    /// The rows, in order. Split from `body` so each one is readable on its
    /// own — the combined version ran to 150 lines, well past the spec limit,
    /// and the comments explaining WHY each row behaves as it does were what
    /// made it unreadable rather than the SwiftUI.
    @ViewBuilder
    private var content: some View {
        reachabilityBanner
        // No iOS-mirrored strap state here. The Polar SDK's
        // `deviceDisconnected` callback can lag 30–60 s after a chest strap
        // leaves the body, so a mirrored pill with no staleness eviction shows
        // "Connected" after the strap is off. The pairing entry below uses
        // CoreBluetooth directly on the Watch, which sees disconnects
        // immediately. Single source of truth.
        Text(String(localized: "Start from Watch"))
            .font(.headline)
        sportRow
        targetRow
        startButton
        Divider().padding(.vertical, 4)
        strapPairingRow
        voiceChatButton
        statusText
    }

    /// No line limit: this screen scrolls, and a refusal such as the unlock
    /// prompt must read in full at every text size.
    private var statusText: some View {
        Text(sessionManager.statusLine)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }

    /// Full-row navigation selectors rather than an inline wheel picker: each
    /// option becomes a row tall enough to hit with a fingertip. The wheel was
    /// unreadable on a watch face.
    private var sportRow: some View {
        NavigationLink { SportPickerView(selection: $selectedSport) } label: {
            pickerRowLabel(
                title: String(localized: "Sport"), icon: "figure.run", value: selectedSport.label
            )
        }
        .buttonStyle(.bordered)
    }

    private var targetRow: some View {
        NavigationLink { ZonePickerView(selection: $selectedZone) } label: {
            pickerRowLabel(
                title: String(localized: "Target"), icon: "target",
                value: selectedZone.shortLabel
            )
        }
        .buttonStyle(.bordered)
    }

    private func pickerRowLabel(title: String, icon: String, value: String) -> some View {
        HStack {
            Label(title, systemImage: icon).labelStyle(.titleAndIcon).font(.caption)
            Spacer()
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    /// Tint and hint reflect the SOURCE of truth for the active strap, which
    /// depends on mode: in display-only mode (the default) the iPhone owns the
    /// strap and the tint follows `phoneStrapConnected`; in legacy mode the
    /// Watch pairs directly and it follows `strapIsConnected`.
    private var startButton: some View {
        Button(action: startWorkout) { startButtonLabel }
            .buttonStyle(.borderedProminent)
            .tint(effectiveStrapConnected ? .green : .orange)
            .disabled(!sessionManager.isReachable || sessionManager.startWorkoutRequestInFlight)
            .accessibilityHint(Text(effectiveStrapHint))
    }

    private func startWorkout() {
        sessionManager.requestStartWorkout(
            sportRaw: selectedSport.raw,
            targetZone: selectedZone.value == 0 ? nil : selectedZone.value
        )
        WKInterfaceDevice.current().play(.start)
    }

    /// The spinner replaces the icon while the request is in flight, so the tap
    /// has an unmistakable acknowledgement. Without it users tapped Start three
    /// times because nothing appeared to happen.
    private var startButtonLabel: some View {
        HStack(spacing: 6) {
            if sessionManager.startWorkoutRequestInFlight {
                ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(0.7)
            } else {
                Image(systemName: "play.fill")
            }
            Text(sessionManager.startWorkoutRequestInFlight
                ? String(localized: "Starting…")
                : String(localized: "Start"))
                .font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
    }

    /// Hidden when the iPhone owns the strap, which is the default. Visible
    /// in legacy / opt-in mode, where the user explicitly chose to pair the
    /// strap to the wrist — and whenever a strap is still saved on the Watch,
    /// so it can always be forgotten.
    @ViewBuilder
    private var strapPairingRow: some View {
        if !sessionManager.displayOnlyMode || strap.hasSavedStrap {
            NavigationLink { WatchStrapPairingView() } label: { strapPairingLabel }
                .buttonStyle(.bordered)
                .tint(directStrapButtonTint)
        }
    }

    private var strapPairingLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "antenna.radiowaves.left.and.right")
            Text(directStrapButtonLabel).font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
    }

    private var voiceChatButton: some View {
        Button(action: toggleVoiceChat) { voiceChatButtonLabel }
            .buttonStyle(.bordered)
            .tint(voiceChatTint)
            .disabled(!sessionManager.isReachable || sessionManager.voiceChatRequestInFlight)
    }

    private func toggleVoiceChat() {
        sessionManager.requestVoiceChatToggle()
        WKInterfaceDevice.current().play(.click)
    }

    private var voiceChatButtonLabel: some View {
        HStack(spacing: 4) {
            if sessionManager.voiceChatRequestInFlight {
                ProgressView().progressViewStyle(.circular).tint(.blue).scaleEffect(0.7)
            } else {
                Image(systemName: voiceChatIcon)
            }
            Text(voiceChatLabel).font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
    }

    /// Voice-chat button label/icon/tint reflect the iPhone's
    /// `VoiceConversationController.state` once it's pushed back via
    /// WCSession. Before the first push (state stays at "idle") the
    /// button looks the same as before.
    private var voiceChatLabel: String {
        if sessionManager.voiceChatRequestInFlight { return String(localized: "Starting…") }
        switch sessionManager.voiceChatStateLabel {
        case "starting": return String(localized: "Connecting…")
        case "listening": return String(localized: "Listening")
        case "thinking": return String(localized: "Thinking…")
        case "speaking": return String(localized: "Speaking")
        case "alert": return String(localized: "Alert")
        default: return String(localized: "Talk to AI")
        }
    }

    private var voiceChatIcon: String {
        switch sessionManager.voiceChatStateLabel {
        case "listening": return "waveform.circle.fill"
        case "speaking": return "speaker.wave.3.fill"
        case "thinking": return "ellipsis.circle.fill"
        case "alert": return "exclamationmark.circle.fill"
        default: return "waveform.and.mic"
        }
    }

    private var voiceChatTint: Color {
        switch sessionManager.voiceChatStateLabel {
        case "listening": return .green
        case "speaking": return .pink
        case "alert": return .orange
        default: return .blue
        }
    }

    /// Label + tint for the "Pair Strap to Watch" entry on the Start
    /// screen. Mirrors `WatchStrapConnector.connectionState` so the
    /// user has a glanceable state pill: "Connected", "Searching…",
    /// "Bluetooth off", or the default "Pair Strap" call to action.
    private var directStrapButtonLabel: String {
        switch strap.connectionState {
        case .connected(let name): return String(localized: "Strap: \(name)")
        case .connecting(let name): return String(localized: "Connecting \(name)…")
        case .scanning: return String(localized: "Searching…")
        case .poweredOff: return String(localized: "BT off")
        case .unauthorized: return String(localized: "BT not allowed")
        case .waitingForBluetooth: return String(localized: "BT warming up")
        case .disconnected, .idle: return String(localized: "Pair Strap to Watch")
        }
    }

    /// True iff the Watch has a Bluetooth heart-rate sensor connected
    /// via `WatchStrapConnector`. Used to drive the Start button's
    /// advisory tint without forcing every call site to `switch` on
    /// the full enum (which carries associated values so `==` won't
    /// compile).
    private var strapIsConnected: Bool {
        if case .connected = strap.connectionState { return true }
        return false
    }

    /// What the user actually cares about when they tap
    /// Start: "is there a strap that will be feeding HR data into this
    /// workout?" The answer depends on mode:
    ///   • Display-only (default): iPhone owns the strap. Read iPhone
    ///     state from `sessionManager.phoneStrapConnected`.
    ///   • Legacy: Watch BLE-pairs directly. Read `strap.connectionState`.
    private var effectiveStrapConnected: Bool {
        sessionManager.displayOnlyMode
            ? sessionManager.phoneStrapConnected
            : strapIsConnected
    }

    private var effectiveStrapHint: String {
        guard sessionManager.displayOnlyMode else {
            return effectiveStrapConnected
                ? String(localized: "Strap paired to Watch — tap to start")
                : String(localized: "No strap paired to Watch — workout will start but HR may rely on the wrist sensor")
        }
        guard effectiveStrapConnected else {
            return String(localized: "iPhone has no strap connected — workout will start but HR may rely on Watch wrist sensor.")
        }
        let name = sessionManager.phoneStrapDeviceName.map { " (\($0))" } ?? ""
        return String(localized: "Strap connected to iPhone\(name) — tap to start; the iPhone will collect HR and stream stats here.")
    }

    private var directStrapButtonTint: Color {
        switch strap.connectionState {
        case .connected: return .green
        case .connecting, .scanning: return .blue
        case .poweredOff, .unauthorized: return .orange
        default: return .gray
        }
    }

    /// Actionable reachability banner. If the iPhone can't be reached
    /// Start and Talk are disabled (each means "now", so neither is queued)
    /// AND we explain *why* so the user
    /// can do something about it instead of staring at "iPhone not
    /// reachable" and assuming the app is broken.
    @ViewBuilder
    private var reachabilityBanner: some View {
        if sessionManager.isReachable { phoneReadyRow } else { phoneUnreachableBanner }
    }

    private var phoneReadyRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .foregroundStyle(.green)
            Text(String(localized: "iPhone ready"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Says what to do about it: iOS gates `WCSession.sendMessage` on the
    /// session being active on the paired phone, and waking the phone once is
    /// the fix the user can actually apply.
    private var phoneUnreachableBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "iphone.slash")
                    .foregroundStyle(.orange)
                Text(String(localized: "iPhone not reachable"))
                    .font(.caption.weight(.semibold))
            }
            Text(String(localized: "Wake your iPhone and open Emuqu once. After that the Watch stays connected even if the phone locks or the app backgrounds."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(Color.orange.opacity(0.15))
        .cornerRadius(6)
    }
}

// MARK: - Sport picker

private struct SportPickerView: View {
    @Binding var selection: SportOption
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(sportOptions) { sport in
            Button {
                selection = sport
                dismiss()
            } label: {
                PickerRow(label: sport.label, isSelected: sport == selection)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(String(localized: "Sport"))
    }
}

/// One row of a picker: its label, with a tick when it is the chosen one.
private struct PickerRow: View {
    let label: String
    let isSelected: Bool

    var body: some View {
        HStack {
            Text(label)
                .font(.body)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.green)
            }
        }
    }
}

// MARK: - Zone picker

private struct ZonePickerView: View {
    @Binding var selection: ZoneOption
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(zoneOptions) { zone in
            Button {
                selection = zone
                dismiss()
            } label: {
                PickerRow(label: zone.label, isSelected: zone == selection)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(String(localized: "Target Zone"))
    }
}

// MARK: - Live metrics screen

/// Dense glanceable layout. Users shouldn't need the AI to say "HR 152,
/// 78% of max, pace 5:12" when they can look at the wrist and see it.
/// Order is deliberate: HR + zone on top, then pace + elapsed, then
/// α1 / band / distance / elevation. Paused state dims + overlays a
/// banner so the user knows the clock is stopped.
private struct LiveMetricsScreen: View {
    @ObservedObject var sessionManager: WatchSessionManager
    @ObservedObject var workoutManager: WatchWorkoutManager

    /// The grid only while a workout records: before the first one, and after
    /// one ends, it would show nothing live or the finished workout's numbers.
    var body: some View {
        Group {
            if sessionManager.isRecording { metrics } else { connectionStatusView }
        }
        .padding(6)
    }

    /// Paused dims the grid and overlays a banner, so the user can see at a
    /// glance that the clock is stopped.
    private var metrics: some View {
        ZStack(alignment: .top) {
            metricsGrid
                .opacity(sessionManager.isPaused ? 0.4 : 1.0)
            if sessionManager.isPaused { pausedBanner }
        }
        .overlay(alignment: .bottom) { startErrorNote }
    }

    /// Why wrist-HR fallback is not running, when the Watch's workout
    /// session failed to start.
    @ViewBuilder
    private var startErrorNote: some View {
        if let error = workoutManager.lastStartError {
            Text(error)
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(3)
                .padding(4)
                .background(Color.black.opacity(0.7))
                .cornerRadius(6)
        }
    }

    private var pausedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.yellow)
            Text(sessionManager.autoPaused ? String(localized: "Auto-paused") : String(localized: "Paused"))
                .font(.caption.weight(.bold))
                .foregroundStyle(.yellow)
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.black.opacity(0.7))
        .cornerRadius(6)
    }

    private var metricsGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            topBar
            heartRateRow
            Divider()
            paceAndTimeRow
            alphaAndDistanceRow
            elevationRow
        }
    }

    private var heartRateRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(sessionManager.displayedHeartRate.map { "\($0)" } ?? "—")
                .watchScaledFont(size: 44, weight: .bold, design: .rounded,
                                 monospacedDigit: true, relativeTo: .title)
                .foregroundStyle(hrColor)
            VStack(alignment: .leading, spacing: 0) {
                Text("bpm").font(.caption2).foregroundStyle(.secondary)
                heartRateSubLabel
            }
            Spacer()
        }
    }

    /// Percent-of-max when the phone has sent a max HR, otherwise the session
    /// peak — and nothing at all until one of the two exists.
    @ViewBuilder
    private var heartRateSubLabel: some View {
        if let pct = sessionManager.hrPercentOfMax {
            Text(String(localized: "\(pct)% max"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(hrColor)
        } else if sessionManager.peakHR > 0 {
            Text(String(localized: "peak \(sessionManager.peakHR)"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var paceAndTimeRow: some View {
        HStack {
            metricCell(label: String(localized: "Pace"), value: sessionManager.paceDisplay ?? "—")
            Spacer(minLength: 8)
            metricCell(label: String(localized: "Time"), value: sessionManager.formattedElapsed, alignment: .trailing)
        }
    }

    private var alphaAndDistanceRow: some View {
        HStack {
            metricCell(label: sessionManager.band, value: "α1 \(sessionManager.alpha1Label)")
            Spacer(minLength: 8)
            metricCell(label: String(localized: "Dist"), value: sessionManager.distanceDisplay, alignment: .trailing)
        }
    }

    /// The right-hand cell is cadence when a foot pod is reporting, and the
    /// target zone otherwise — the two are never both useful at this size.
    private var elevationRow: some View {
        HStack {
            metricCell(label: String(localized: "Elev"), value: sessionManager.elevationDisplay)
            Spacer(minLength: 8)
            if let cadence = sessionManager.cadenceDisplay {
                metricCell(label: String(localized: "Cad"), value: cadence, alignment: .trailing)
            } else if let zone = sessionManager.targetZone {
                metricCell(label: String(localized: "Target"), value: "Z\(zone)", alignment: .trailing)
            }
        }
    }

    private var topBar: some View {
        HStack {
            Text(sessionManager.sportLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Circle()
                .fill(sessionManager.isReachable ? .green : .orange)
                .frame(width: 6, height: 6)
                .accessibilityLabel(Text(sessionManager.isReachable
                    ? String(localized: "iPhone ready")
                    : String(localized: "iPhone not reachable")))
        }
    }

    private var hrColor: Color {
        guard let pct = sessionManager.hrPercentOfMax else { return .primary }
        switch pct {
        case ..<60: return .blue
        case 60 ..< 70: return .green
        case 70 ..< 80: return .yellow
        case 80 ..< 90: return .orange
        default: return .red
        }
    }

    @ViewBuilder
    private func metricCell(
        label: String,
        value: String,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
        }
    }

    private var connectionStatusView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: sessionManager.isReachable ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                    .foregroundStyle(sessionManager.isReachable ? .green : .orange)
                Text(connectionTitle)
                    .font(.caption.weight(.medium))
            }
            Text(sessionManager.statusLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Text(connectionHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private var connectionTitle: String {
        sessionManager.isReachable
            ? String(localized: "Waiting for workout")
            : String(localized: "iPhone not reachable")
    }

    private var connectionHint: String {
        sessionManager.isReachable
            ? String(localized: "Swipe down to start a workout from the Watch.")
            : String(localized: "Open Emuqu on iPhone to wake the connection.")
    }
}

// MARK: - Pause / Stop screen

/// Dedicated page so End can't be fat-fingered from the metrics screen,
/// and so Pause/Resume sits right next to it rather than competing with
/// a dense numerical grid.
private struct PauseStopScreen: View {
    @ObservedObject var sessionManager: WatchSessionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if sessionManager.isPaused { resumeButton } else { pauseButton }
            Divider().padding(.vertical, 2)
            endButton
            Text(sessionManager.statusLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(6)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: sessionManager.isPaused ? "pause.circle.fill" : "play.circle.fill")
                .foregroundStyle(sessionManager.isPaused ? .yellow : .green)
            Text(headerTitle)
                .font(.headline)
        }
    }

    private var headerTitle: String {
        guard sessionManager.isPaused else { return String(localized: "Recording") }
        return sessionManager.autoPaused ? String(localized: "Auto-paused") : String(localized: "Paused")
    }

    private var resumeButton: some View {
        Button {
            sessionManager.requestResumeWorkout()
            WKInterfaceDevice.current().play(.start)
        } label: {
            Self.buttonLabel(icon: "play.fill", title: String(localized: "Resume"))
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
    }

    private var pauseButton: some View {
        Button {
            sessionManager.requestPauseWorkout()
            WKInterfaceDevice.current().play(.click)
        } label: {
            Self.buttonLabel(icon: "pause.fill", title: String(localized: "Pause"))
        }
        .buttonStyle(.borderedProminent)
        .tint(.yellow)
    }

    private var endButton: some View {
        Button(role: .destructive) {
            sessionManager.requestStopWorkout()
            WKInterfaceDevice.current().play(.stop)
        } label: {
            Self.buttonLabel(icon: "stop.fill", title: String(localized: "End"))
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }

    private static func buttonLabel(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Completion screen

/// Shown after the iPhone flips isRecording true → false. Full-bleed
/// "Save & Done" so the user can close the loop without reaching for
/// the phone — confirms dismissal of the iPhone's post-workout sheet
/// too, so returning to the phone doesn't land on a lingering summary.
private struct CompletionScreen: View {
    @ObservedObject var sessionManager: WatchSessionManager

    var body: some View {
        VStack(spacing: 10) {
            savedHeader
            saveAndDoneButton

            Text(sessionManager.statusLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(8)
    }

    private var savedHeader: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .watchScaledFont(size: 36, relativeTo: .title)
                .foregroundStyle(.green)

            Text(String(localized: "Workout saved"))
                .font(.headline)

            Text(String(localized: "Your workout is archived on the iPhone. Tap Save & Done to dismiss the summary on both devices."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var saveAndDoneButton: some View {
        Button {
            sessionManager.requestAcknowledgeFinished()
            WKInterfaceDevice.current().play(.success)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                Text(String(localized: "Save & Done"))
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
    }
}
