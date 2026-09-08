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

    var body: some View {
        if sessionManager.justCompleted {
            NavigationStack {
                CompletionScreen(sessionManager: sessionManager)
            }
        } else {
            TabView(selection: $page) {
                NavigationStack {
                    StartScreen(sessionManager: sessionManager)
                }
                .tag(TabPage.start)

                LiveMetricsScreen(
                    sessionManager: sessionManager,
                    workoutManager: workoutManager
                )
                .tag(TabPage.live)

                PauseStopScreen(sessionManager: sessionManager)
                    .tag(TabPage.pauseStop)
            }
            .tabViewStyle(.verticalPage)
            .onChange(of: sessionManager.isRecording) { _, isRec in
                // When iOS starts a workout (either via the Watch's
                // Start button or from the Fitness tab on the phone),
                // jump to the live page so the user sees their data.
                // When the workout ends (`isRecording` flips false),
                // bounce back to the start screen so the next workout
                // begins from a familiar place. We only auto-jump on
                // transitions, not on every tick — `onChange` already
                // gives us that.
                if isRec, page == .start {
                    page = .live
                } else if !isRec, page == .live || page == .pauseStop {
                    page = .start
                }
            }
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
    SportOption(raw: "bike", label: String(localized: "Bike")),
    SportOption(raw: "indoorRun", label: String(localized: "Treadmill")),
    SportOption(raw: "indoorBike", label: String(localized: "Indoor Bike"))
]

struct ZoneOption: Hashable, Identifiable {
    let value: Int    // 0 = no target
    let label: String
    var id: Int { value }
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
        Text(sessionManager.statusLine)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(3)
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
                value: selectedZone.label.components(separatedBy: " — ").first ?? selectedZone.label
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
    /// only in legacy / opt-in mode, where the user explicitly chose to pair
    /// the strap to the wrist.
    @ViewBuilder
    private var strapPairingRow: some View {
        if !sessionManager.displayOnlyMode {
            NavigationLink { WatchStrapPairingView() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text(directStrapButtonLabel).font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(directStrapButtonTint)
        }
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
        if sessionManager.displayOnlyMode {
            if effectiveStrapConnected {
                let name = sessionManager.phoneStrapDeviceName.map { " (\($0))" } ?? ""
                return String(localized: "Strap connected to iPhone\(name) — tap to start; the iPhone will collect HR and stream stats here.")
            }
            return String(localized: "iPhone has no strap connected — workout will start but HR may rely on Watch wrist sensor.")
        } else {
            return effectiveStrapConnected
                ? String(localized: "Strap paired to Watch — tap to start")
                : String(localized: "No strap paired to Watch — workout will start but HR may rely on the wrist sensor")
        }
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
    /// the buttons above are disabled AND we explain *why* so the user
    /// can do something about it instead of staring at "iPhone not
    /// reachable" and assuming the app is broken.
    @ViewBuilder
    private var reachabilityBanner: some View {
        if sessionManager.isReachable {
            HStack(spacing: 6) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .foregroundStyle(.green)
                Text(String(localized: "iPhone ready"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "iphone.slash")
                        .foregroundStyle(.orange)
                    Text(String(localized: "iPhone not reachable"))
                        .font(.caption.weight(.semibold))
                }
                // Plain-English why. iOS gates `WCSession.sendMessage` —
                // the session must be active on the paired phone. The
                // four real causes the user can fix.
                Text(String(localized: "Wake your iPhone and open Emuqu once. After that the Watch stays connected even if the phone locks or the app backgrounds."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
            .background(Color.orange.opacity(0.15))
            .cornerRadius(6)
        }
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
                HStack {
                    Text(sport.label)
                        .font(.body)
                    Spacer()
                    if sport == selection {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.green)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(String(localized: "Sport"))
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
                HStack {
                    Text(zone.label)
                        .font(.body)
                    Spacer()
                    if zone == selection {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.green)
                    }
                }
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

    var body: some View {
        Group {
            if sessionManager.messagesReceived == 0 {
                connectionStatusView
            } else {
                ZStack(alignment: .top) {
                    metricsGrid
                        .opacity(sessionManager.isPaused ? 0.4 : 1.0)
                    if sessionManager.isPaused {
                        pausedBanner
                    }
                }
            }
        }
        .padding(6)
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
            Text(sessionManager.heartRate.map { "\($0)" } ?? "—")
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
                Text(sessionManager.isReachable ? String(localized: "Waiting for workout") : String(localized: "iPhone not reachable"))
                    .font(.caption.weight(.medium))
            }
            Text(sessionManager.statusLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer(minLength: 0)
            if sessionManager.isReachable {
                Text(String(localized: "Swipe up to start a workout from the Watch."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                Text(String(localized: "Open Emuqu on iPhone to wake the connection."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
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
            HStack(spacing: 6) {
                Image(systemName: sessionManager.isPaused ? "pause.circle.fill" : "play.circle.fill")
                    .foregroundStyle(sessionManager.isPaused ? .yellow : .green)
                Text(sessionManager.isPaused ? (sessionManager.autoPaused ? String(localized: "Auto-paused") : String(localized: "Paused")) : String(localized: "Recording"))
                    .font(.headline)
            }

            if sessionManager.isPaused {
                Button {
                    sessionManager.requestResumeWorkout()
                    WKInterfaceDevice.current().play(.start)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text(String(localized: "Resume"))
                            .font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            } else {
                Button {
                    sessionManager.requestPauseWorkout()
                    WKInterfaceDevice.current().play(.click)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pause.fill")
                        Text(String(localized: "Pause"))
                            .font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
            }

            Divider().padding(.vertical, 2)

            Button(role: .destructive) {
                sessionManager.requestStopWorkout()
                WKInterfaceDevice.current().play(.stop)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                    Text(String(localized: "End"))
                        .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Text(sessionManager.statusLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(6)
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
            Image(systemName: "checkmark.seal.fill")
                .watchScaledFont(size: 36, relativeTo: .title)
                .foregroundStyle(.green)

            Text(String(localized: "Workout saved"))
                .font(.headline)

            Text(String(localized: "Your workout is archived on the iPhone. Tap Save & Done to dismiss the summary on both devices."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

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

            Text(sessionManager.statusLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(8)
    }
}
