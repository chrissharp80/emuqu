import CoreLocation
import MapKit
import SwiftUI
import UIKit

// MARK: - Fitness Recording View
//
// Single-screen live workout surface. Everything visible in one scroll —
// HR hero, metric tiles, physiology, and the live map. No TabView, no
// swipefest. Mirrors the layout production apps converged on because
// users mid-workout shouldn't have to think about page navigation.
struct FitnessRecordingView: View {
    @Environment(\.dependencies) var dependencies
    var recorder: WorkoutRecorder
    let onStop: () -> Void

    private var coach: WorkoutVoiceCoach
    var conversation: VoiceConversationController
    private var intervals: IntervalController
    // Explicit sub-object observation. The recorder itself
    // has ZERO observable properties (all live state lives on
    // lifecycle / workoutHR / motion / dfa). Without observing them
    // here, the view reads
    // `recorder.elapsedSeconds`, `recorder.distanceMeters`,
    // `recorder.workoutHR.currentHR` etc. via computed forwarders, but
    // SwiftUI doesn't know to re-render when those observable values
    // change — so the metrics show as zeros until the user navigates
    // away and back (which destroys + recreates the view, body
    // re-evaluates with the latest values). User report:
    // "Workout metrics do not display until the user navigates to a
    // different screen (or AI chat) and then comes back."
    private var lifecycle: WorkoutLifecycle
    private var workoutHR: WorkoutHR
    private var motion: WorkoutMotion
    private var dfa: LiveDFAAnalyzer
    @Environment(SettingsManager.self) private var settingsManager

    // Hold-to-end gesture state. `holdProgress` fills the button from 0 → 1
    // over `holdDurationSec`. Release before 1 = cancel. Reaching 1 fires
    // `onStop()`. No system popup — the confirmation IS the hold, right at
    // the thumb, which is what we need in bright sunlight.
    @State var holdProgress: Double = 0
    @State var holdTimer: Timer?
    @State var isHolding = false
    let holdDurationSec: Double = 1.2
    /// Two-phase body render. The first body() call paints
    /// ONLY the cheap header + heart-rate hero + control bar — that's
    /// what the user needs to see immediately ("the workout started").
    /// Heavy sub-cards (metric tile grid with TimelineView, physiology
    /// card with GeometryReader, map card) wait for `.task` to flip
    /// this to true after one runloop tick (~50ms). The runloop ticks
    /// fire any deferred `Task { @MainActor }` work in between — which
    /// is where GPS / pedometer / foot-pod / watch-bridge setup all
    /// live. A beta tester log showed 12 s of
    /// dead-silence main thread between phase=.recording and those
    /// deferred Tasks firing; lazy-rendering the heavy cards collapses
    /// the body's first-mount cost so the runloop has cycles to spare.
    @State private var heavySubcardsReady = false

    init(recorder: WorkoutRecorder, onStop: @escaping () -> Void) {
        self.recorder = recorder
        self.onStop = onStop
        coach = recorder.voiceCoach
        conversation = recorder.conversation
        intervals = recorder.intervalController
        lifecycle = recorder.lifecycle
        workoutHR = recorder.workoutHR
        motion = recorder.motion
        dfa = recorder.dfa
    }

    private var sport: Sport? { recorder.currentSession?.sport }
    var usesGPS: Bool { sport?.usesGPS == true }
    var units: UnitsPreference { UnitsPreferenceStore.current }
    /// User's max HR (from Settings → Fitness → Max HR, else 220-age, else 180).
    /// Used as the denominator for zone classification — never the session peak.
    private var userMaxHR: Int { settingsManager.settings.effectiveMaxHR }

    // MARK: - Cached localized labels
    //
    // This screen re-evaluates `body` on EVERY 1 Hz tick (HR,
    // timer, DFA, motion all publish ~1 Hz). Running the static
    // `String(localized:bundle:)` labels on every tick — against the large
    // localized string table — is the start/scroll latency the user
    // reported. These labels only change
    // on a language switch, so compute them ONCE per `LanguageManager.revision`
    // and read the cached struct in `body` instead of re-localizing per tick.
    struct Labels {
        let rec, saving, heartRate, bpm, dfaAlpha1: String
        let elapsed, distance, pace, avgHR, steps, elevation: String
        let power, footPod, est, hrDrift, fatiguing, stable, decoupling, decoupled, coupled: String
        init(_ b: Bundle) {
            rec = String(localized: "REC", bundle: b)
            saving = String(localized: "SAVING", bundle: b)
            heartRate = String(localized: "Heart Rate", bundle: b)
            bpm = String(localized: "bpm", bundle: b)
            dfaAlpha1 = String(localized: "DFA α1", bundle: b)
            elapsed = String(localized: "Elapsed", bundle: b)
            distance = String(localized: "Distance", bundle: b)
            pace = String(localized: "Pace", bundle: b)
            avgHR = String(localized: "Avg HR", bundle: b)
            steps = String(localized: "Steps", bundle: b)
            elevation = String(localized: "Elevation", bundle: b)
            power = String(localized: "Power", bundle: b)
            footPod = String(localized: "foot pod", bundle: b)
            est = String(localized: "est", bundle: b)
            hrDrift = String(localized: "HR Drift", bundle: b)
            fatiguing = String(localized: "fatiguing", bundle: b)
            stable = String(localized: "stable", bundle: b)
            decoupling = String(localized: "Decoupling", bundle: b)
            decoupled = String(localized: "decoupled", bundle: b)
            coupled = String(localized: "coupled", bundle: b)
        }
    }
    private static var _labelsCache: (rev: Int, labels: Labels)?
    /// The localized labels for this view, cached per language revision.
    var labels: Labels {
        let rev = AppDependencies.current.services.languageManager.revision
        if let c = Self._labelsCache, c.rev == rev { return c.labels }
        let l = Labels(LanguageManager.appBundle)
        Self._labelsCache = (rev, l)
        return l
    }

    var body: some View {
        recordingBackground
        // A bottom-aligned overlay, not `.safeAreaInset(edge: .bottom)`.
        // With iOS 26's floating-pill TabView,
        // `safeAreaInset` no longer anchors content right above the tab
        // bar — it renders Talk + Hold buttons hundreds of points
        // higher, sitting on top of the Steps/Elevation row in the
        // scroll. Overlay alignment is deterministic regardless of the
        // TabView style.
        .overlay(alignment: .bottom) { bottomControls }
        // Stamp when SwiftUI actually mounts this view so we
        // can compare against phase=.recording in WorkoutRecorder. If the
        // user perceives a ~1 s gap from tap to "started" and the log
        // shows `phase.recording → recordingView.onAppear` taking most of
        // it, that's hard proof that SwiftUI's body build / first layout
        // of this 1000-LOC view is the bottleneck, not Polar.
        .onAppear {
            debugLog("[StartLatency] FitnessRecordingView onAppear")
        }
        .task { await mountHeavySubcards() }
    }

    /// Yield ONE runloop tick before mounting the heavy sub-cards.
    /// The `.task` modifier fires after the first `body()` returns; the brief
    /// sleep gives the main runloop an opportunity to drain any deferred
    /// `Task { @MainActor }` work the `recorder.start()` path scheduled (GPS,
    /// pedometer, watch bridge). With those firing FIRST, the metric tiles + map
    /// have real data to render the moment they appear — and the user perceives
    /// the workout going fully live in under a second instead of in 12 s.
    private func mountHeavySubcards() async {
        await sleepQuietly(50_000_000, context: "body")
        heavySubcardsReady = true
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            voiceBar
            stopButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.6), .black.opacity(0.9)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private var recordingBackground: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.cardBackground.opacity(0.9), .black],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            recordingScroll
        }
    }

    private var recordingScroll: some View {
        ScrollView {
            recordingCards
        }
    }

    private var recordingCards: some View {
        VStack(spacing: 14) {
            headerBar
            if recorder.intervalController.currentStep != nil {
                intervalBanner
            }
            if let route = recorder.plannedRoute {
                recognizedRouteBanner(route: route)
            }
            if let notice = lifecycle.strapNotice {
                strapNoticeBanner(notice)
            }
            hrHeroCard
            heavySubcards
            Spacer(minLength: 10)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 180) // room for the bottom controls
    }

    /// Heavy sub-cards gated on
    /// `heavySubcardsReady`. Flipped to true ~50 ms
    /// after onAppear via `.task`. First body() returns
    /// in milliseconds; deferred `Task { @MainActor }`
    /// work (GPS startTracking, pedometer.start, etc.)
    /// fires in the gap. See the field doc-comment.
    @ViewBuilder
    private var heavySubcards: some View {
        if heavySubcardsReady {
            metricTileGrid
            physiologyCard
            if usesGPS {
                mapCard
            }
        } else {
            // Match the natural height the full content will
            // occupy, so the layout doesn't visibly jump when
            // the cards swap in. ~340 pt covers grid + phys
            // + map placeholder.
            Color.clear.frame(height: 340)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        headerBarContent
    }

    private var headerBarContent: some View {
        HStack(spacing: 12) {
            sportTitle
            Spacer()
            beatCountPill
            muteButton
            recordingPill
        }
    }

    @ViewBuilder
    private var sportTitle: some View {
        if let sport {
            Image(systemName: sport.icon)
                .font(.title3)
                .foregroundStyle(AppTheme.fitnessAccent)
            Text(sport.displayName)
                .font(.headline)
        }
    }

    @ViewBuilder
    private var beatCountPill: some View {
        if recorder.beatCount > 0 {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.fitnessAccent)
                Text("\(recorder.beatCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private var muteButton: some View {
        Button {
            coach.isMuted.toggle()
        } label: {
            Image(systemName: coach.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.subheadline)
                .foregroundStyle(coach.isMuted ? AppTheme.textTertiary : AppTheme.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(AppTheme.cardBackground.opacity(0.6)))
                // The circle stays 30 pt; the tap target is the 44 pt minimum,
                // which matters mid-workout with a sweaty finger.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(coach.isMuted
            ? String(localized: "Unmute coach", bundle: LanguageManager.appBundle)
            : String(localized: "Mute coach", bundle: LanguageManager.appBundle))
    }

    private var recordingPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.white)
                .frame(width: 6, height: 6)
                .opacity(recorder.phase == .finalizing ? 0.5 : 1)
            Text(recorder.phase == .finalizing ? labels.saving : labels.rec)
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(AppTheme.fitnessAccent))
    }

    // MARK: - HR Hero

    private var hrHeroCard: some View {
        let zone = HRZone.classify(hr: recorder.currentHR ?? 0, userMaxHR: userMaxHR)
        let zoneColor = zone?.color ?? AppTheme.fitnessAccent
        let hrText = recorder.currentHR.map(String.init) ?? "—"
        return VStack(spacing: 4) {
            hrHeroHeader(zone: zone, zoneColor: zoneColor)
            hrHeroReadout(hrText: hrText, zoneColor: zoneColor)
            peakHRLabel
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(hrHeroBackground(zoneColor))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(heartRateAccessibilityLabel(hrText: hrText, zone: zone, peakHR: recorder.peakHR))
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Full HR + zone + peak as a single VoiceOver utterance so the color
    /// of the zone pill isn't the only signal. VoiceOver users got "140"
    /// and nothing about Zone 3 of 5.
    private func heartRateAccessibilityLabel(hrText: String, zone: HRZone?, peakHR: Int) -> String {
        var parts: [String] = []
        if hrText == "—" {
            parts.append(String(localized: "Heart rate not available", bundle: LanguageManager.appBundle))
        } else {
            parts.append(String(localized: "Heart rate \(hrText) beats per minute", bundle: LanguageManager.appBundle))
        }
        if let zone {
            parts.append("\(zone.label)")
        }
        if peakHR > 0 {
            parts.append(String(localized: "peak \(peakHR)", bundle: LanguageManager.appBundle))
        }
        return parts.joined(separator: ", ")
    }

    /// Live interval banner. Shows the step number, label, target, and a
    /// progress bar for time-based steps. Tap the ⏭ button to skip ahead.
    private func hrHeroBackground(_ zoneColor: Color) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(AppTheme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(zoneColor.opacity(0.3), lineWidth: 1)
            )
    }

    private func hrHeroHeader(zone: HRZone?, zoneColor: Color) -> some View {
        HStack {
            Text(labels.heartRate)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            hrZonePill(zone: zone, zoneColor: zoneColor)
        }
    }

    @ViewBuilder
    private func hrZonePill(zone: HRZone?, zoneColor: Color) -> some View {
        if let zone {
            Text(zone.label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(zoneColor.opacity(0.2)))
                .foregroundStyle(zoneColor)
        }
    }

    private func hrHeroReadout(hrText: String, zoneColor: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(hrText)
                .scaledFont(size: 68, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(zoneColor)
                .contentTransition(.numericText())
            Text(labels.bpm)
                .font(.title3.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var peakHRLabel: some View {
        if recorder.peakHR > 0 {
            Text(String(localized: "peak \(recorder.peakHR)", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private var intervalBanner: some View {
        HStack(alignment: .center, spacing: 10) {
            intervalStepLabel
            Spacer()
            skipIntervalButton
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.cardBackground))
    }

    private var intervalStepLabel: some View {
        let step = intervals.currentStep
        return VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "Step \(intervals.stepNumber) of \(intervals.totalSteps)", bundle: LanguageManager.appBundle))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.textTertiary)
            Text(step.map { "\($0.label) · \(intervalTargetLabel($0.target))" } ?? "—")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            intervalStepProgress(step)
        }
    }

    /// Only timed steps get a progress bar — a distance or HR target has no
    /// meaningful fraction to show.
    @ViewBuilder
    private func intervalStepProgress(_ step: IntervalStep?) -> some View {
        if let step, step.durationSec != nil {
            ProgressView(value: intervals.stepProgress)
                .tint(AppTheme.primary)
                .frame(height: 4)
        }
    }

    private var skipIntervalButton: some View {
        Button {
            intervals.skip()
        } label: {
            Image(systemName: "forward.end.fill")
                .foregroundStyle(AppTheme.primary)
                .padding(8)
                .background(Circle().fill(AppTheme.primary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Skip interval step", bundle: LanguageManager.appBundle))
    }

    /// Banner shown when the recorder has bound a route — either because
    /// the user picked one from a GPX or because the auto-recogniser
    /// matched today's track to a familiar loop. Slightly different copy
    /// for the two cases so the user knows we noticed without nagging.
    private func recognizedRouteBanner(route: Route) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "map.fill")
                .foregroundStyle(AppTheme.fitnessAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(routeBannerLead(route: route))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(routeBannerDetail(route: route))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.cardBackground))
    }

    /// The route's `name` carries the user's chosen library name when the
    /// recogniser bound it from SavedRouteStore; for hand-loaded GPX routes it
    /// carries the file name. Only an auto-detected route calls out the
    /// direction — the user who picked it already knows which way round it is.
    private func routeBannerLead(route: Route) -> String {
        let isReverse = recorder.plannedRouteDirection == .reverse
        guard recorder.plannedRouteWasAutoDetected, isReverse else {
            return String(localized: "Following \(route.name)", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Following \(route.name) (in reverse)", bundle: LanguageManager.appBundle)
    }

    /// Route through the canonical units formatter rather than an inline
    /// imperial/metric branch.
    private func routeBannerDetail(route: Route) -> String {
        let dist = units.formatDistance(meters: route.totalDistanceMeters)
        let climbs = route.climbs.count
        guard climbs > 0 else { return dist }
        return "\(dist) · " + String(localized: "\(climbs) climbs ahead", bundle: LanguageManager.appBundle)
    }

    /// Shown when a strap workout has no strap heart rate. The workout keeps
    /// running; this explains why HR is missing rather than leaving the user
    /// wondering. Non-blocking and non-dismissable — it clears the moment the
    /// strap delivers again. The advice differs because the remedies do: a
    /// strap that is out of reach needs to be closer, one that is linked but
    /// silent usually needs skin contact.
    private func strapNoticeBanner(_ notice: WorkoutStrapNotice) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.strapNoticeTitle(notice))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(Self.strapNoticeDetail(notice))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.4), lineWidth: 1))
    }

    private static func strapNoticeTitle(_ notice: WorkoutStrapNotice) -> String {
        switch notice {
        case .strapNotConnected: String(localized: "Strap not connected", bundle: LanguageManager.appBundle)
        case .strapSilent: String(localized: "No heart rate from strap", bundle: LanguageManager.appBundle)
        }
    }

    private static func strapNoticeDetail(_ notice: WorkoutStrapNotice) -> String {
        switch notice {
        case .strapNotConnected:
            String(localized: "Recording continues without heart rate. Move the strap closer to the phone or replace the battery.", bundle: LanguageManager.appBundle)
        case .strapSilent:
            String(localized: "Moisten the strap's electrodes and make sure it sits snugly against your skin.", bundle: LanguageManager.appBundle)
        }
    }

    private func intervalTargetLabel(_ target: IntervalStep.Target) -> String {
        switch target {
        case .zone(let z): return String(localized: "Zone \(z)", bundle: LanguageManager.appBundle)
        case .hrRange(let lo, let hi): return "\(lo)–\(hi) bpm"
        case .paceSecPerKm(let p): return paceTargetLabel(secPerKm: p)
        case .effort(let cue): return Self.effortLabel(cue)
        }
    }

    /// Respect the user's units (not a hardcoded /km). `p` is
    /// seconds per km; `formatPace` takes seconds per meter and renders /mi or
    /// /km per preference.
    private func paceTargetLabel(secPerKm p: Int) -> String {
        if let formatted = units.formatPace(secondsPerMeter: Double(p) / 1000.0) {
            return formatted
        }
        return String(format: "%d:%02d/km", p / 60, p % 60)
    }

    private static func effortLabel(_ cue: IntervalStep.Target.EffortCue) -> String {
        switch cue {
        case .recovery: return String(localized: "recovery", bundle: LanguageManager.appBundle)
        case .easy: return String(localized: "easy", bundle: LanguageManager.appBundle)
        case .moderate: return String(localized: "moderate", bundle: LanguageManager.appBundle)
        case .hard: return String(localized: "hard", bundle: LanguageManager.appBundle)
        case .allOut: return String(localized: "all-out", bundle: LanguageManager.appBundle)
        }
    }
}
