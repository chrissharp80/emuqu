import CoreLocation
import MapKit
import SwiftUI

// The metric tiles and inline physiology block, split out of
// `FitnessRecordingView.swift`. The header and HR hero — the parts
// the user watches — stay behind.

extension FitnessRecordingView {
    // MARK: - Metric tiles (2×2)

    var metricTileGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            elapsedTile
            coreMetricTiles
            bodyMetricTiles
            conditionalMetricTiles
            liveTrendTiles
        }
    }

    /// Bug #13: "Elapsed time not live — snapshot-based, not
    /// tight enough." The recorder publishes `elapsedSeconds` (Int) once per
    /// tick (1 Hz), and on a busy main thread the tick can slip — display
    /// freezes for 2-3s and the user feels lag. TimelineView pulls its OWN
    /// clock at 0.5s cadence and we compute elapsed from
    /// `currentSession.startDate` when recording. Falls back to the published
    /// Int when paused / idle / finalizing (those phases need pause-aware
    /// elapsed time which the lifecycle is the source of truth for).
    private var elapsedTile: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = elapsedInterval(at: context.date)
            metricTile(icon: "timer", label: labels.elapsed, value: formatDuration(elapsed))
        }
    }

    private func elapsedInterval(at now: Date) -> TimeInterval {
        if case .recording = recorder.phase,
           let start = recorder.currentSession?.startDate {
            return max(0, now.timeIntervalSince(start))
        }
        return TimeInterval(recorder.elapsedSeconds)
    }

    @ViewBuilder
    private var coreMetricTiles: some View {
        metricTile(
            icon: usesGPS ? "location.fill" : "figure.walk",
            label: labels.distance,
            value: distanceLabel,
            caption: paceCaption
        )
        metricTile(
            icon: "speedometer",
            label: labels.pace,
            value: currentPaceLabel,
            caption: avgPaceCaption
        )
    }

    @ViewBuilder
    private var bodyMetricTiles: some View {
        metricTile(
            icon: "heart.fill",
            label: labels.avgHR,
            value: avgHRLabel,
            caption: peakHRCaption
        )
        metricTile(
            icon: "shoe.2",
            label: labels.steps,
            value: recorder.stepCount > 0 ? "\(recorder.stepCount)" : "—",
            caption: cadenceCaption
        )
        metricTile(icon: "mountain.2", label: labels.elevation, value: elevationLabel)
    }

    /// Only rendered when their source has data, so the grid does not plaster
    /// "—" everywhere on a short indoor walk.
    @ViewBuilder
    private var conditionalMetricTiles: some View {
        // Conditional tiles — only render when their source has data, so
        if recorder.footPodActive, let w = recorder.powerWatts {
            metricTile(
                icon: "bolt.fill",
                label: labels.power,
                value: "\(w) W",
                caption: labels.footPod
            )
        }
        if let mets = currentMETs {
            metricTile(
                icon: "flame.fill",
                label: "METs",
                value: String(format: "%.1f", locale: .current, mets),
                caption: labels.est
            )
        }
    }

    /// Live trend tiles (round-2/4 metrics visible on the
    /// recording screen too, not just to the AI). HR drift = how much HR has
    /// crept up vs the first quartile; decoupling = first-half vs second-half
    /// pace/HR efficiency. Both stay hidden until enough samples accumulate so
    /// they do not show "—" all session.
    @ViewBuilder
    private var liveTrendTiles: some View {
        // Live trend tiles (round-2/4 metrics visible on the
        // recording screen too, not just to the
        // AI). HR drift = how much HR has crept up vs the first
        // quartile; decoupling = first-half vs second-half
        // pace/HR efficiency. Both stay hidden until enough
        // samples accumulate so they don't show "—" all session.
        if let drift = WorkoutLiveTrends.hrDriftPercent(samples: recorder.samplesView) {
            metricTile(
                icon: "waveform.path.ecg",
                label: labels.hrDrift,
                value: String(format: "%+.1f%%", locale: .current, drift),
                caption: drift > 5 ? labels.fatiguing : labels.stable
            )
        }
        decouplingTile
    }

    @ViewBuilder
    private var decouplingTile: some View {
        if let dec = WorkoutLiveTrends.aerobicDecouplingPercent(samples: recorder.samplesView) {
            metricTile(
                icon: "arrow.down.right.circle",
                label: labels.decoupling,
                value: String(format: "%+.1f%%", locale: .current, dec),
                caption: dec > 5 ? labels.decoupled : labels.coupled
            )
        }
    }

    func metricTile(icon: String, label: String, value: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            metricTileHeader(icon: icon, label: label)
            metricTileValue(value)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.cardBackground))
    }

    /// BP §F4 line 920 — 48pt SF Pro Rounded Bold monospaced.
    /// minimumScaleFactor 0.5 lets the value shrink to ~24pt when the tile
    /// narrows on smaller phones / accessibility text scaling, so a 4-digit
    /// pace ("9:42") never truncates.
    private func metricTileValue(_ value: String) -> some View {
        Text(value)
            .scaledFont(size: 48, weight: .bold, design: .rounded)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .contentTransition(.numericText())
    }

    private func metricTileHeader(icon: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(AppTheme.primary)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    // MARK: - Physiology (inline)

    var physiologyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            alpha1Readout
            alpha1IndicatorBar
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.cardBackground))
    }

    private var alpha1Readout: some View {
        HStack(alignment: .top, spacing: 14) {
            alpha1Value
            Spacer()
            alpha1BandBadge
        }
    }

    private var alpha1BandBadge: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(recorder.dfa.currentBand.label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(AppTheme.dustyRose.opacity(0.2)))
                .foregroundStyle(AppTheme.dustyRose)
        }
    }

    private var alpha1Value: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(labels.dfaAlpha1)
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)
            Text(alpha1Label)
                .scaledFont(size: 30, weight: .bold)
                .monospacedDigit()
            if let caption = alpha1Caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
                    .lineLimit(2)
            }
        }
    }

    /// BP §F4 line 921 — live α1 indicator: horizontal bar with a moving dot
    /// showing the current zone (Easy → Threshold → Hard). Educational
    /// element. Domain: 0.0 (anaerobic) → 1.5 (parasympathetic recovery).
    /// Three coloured bands with the dot riding to the user's current value.
    /// Bar domain: 0.0 → 1.5. Three bands per Rogers/Gronwald 2021:
    ///   Hard (0.0–0.5)         — anaerobic / Z4-Z5
    ///   Threshold (0.5–0.75)   — LT2 → LT1 transition
    ///   Aerobic (0.75–1.0)     — Z2-Z3
    ///   Easy (1.0–1.5)         — recovery / Z1
    /// Colour runs caution → optimal as the value climbs into easy.
    @ViewBuilder
    var alpha1IndicatorBar: some View {
        GeometryReader { geo in
            alpha1BarLayers(width: geo.size.width)
        }
        .frame(height: 14)
        // Zone labels under the bar (BP §F4 line 921 "Easy → Threshold → Hard")
        .overlay(alignment: .bottom) {
            HStack {
                Text(String(localized: "Hard", bundle: LanguageManager.appBundle))
                Spacer()
                Text(String(localized: "Threshold", bundle: LanguageManager.appBundle))
                Spacer()
                Text(String(localized: "Easy", bundle: LanguageManager.appBundle))
            }
            .scaledFont(size: 9)
            .foregroundStyle(AppTheme.textTertiary)
            .offset(y: 14)
            .padding(.horizontal, 2)
        }
        .padding(.bottom, 14) // make room for the labels
    }

    private func alpha1BarLayers(width total: CGFloat) -> some View {
        let value = recorder.dfa.currentAlpha1.map { min(1.5, max(0, $0)) }
        let dotX: CGFloat? = value.map { CGFloat($0 / 1.5) * total }
        return ZStack(alignment: .leading) {
            alpha1BandGradient
            alpha1Dot(dotX: dotX, total: total)
        }
        .frame(maxWidth: .infinity)
    }

    private var alpha1BandGradient: some View {
        LinearGradient(
            colors: [
                AppTheme.wongAttention.opacity(0.7), // Hard
                AppTheme.wongCaution.opacity(0.7),   // Threshold
                AppTheme.wongGood.opacity(0.7),      // Aerobic
                AppTheme.wongOptimal.opacity(0.7)   // Easy
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 8)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func alpha1Dot(dotX: CGFloat?, total: CGFloat) -> some View {
        if let dotX {
            Circle()
                .fill(.white)
                .overlay(Circle().stroke(AppTheme.textPrimary.opacity(0.4), lineWidth: 1))
                .frame(width: 14, height: 14)
                .shadow(radius: 1, y: 1)
                .offset(x: max(0, min(total - 14, dotX - 7)), y: 0)
                .animation(.easeOut(duration: 0.5), value: dotX)
                .accessibilityLabel(Text(String(localized: "Current α1 \(alpha1Label)", bundle: LanguageManager.appBundle)))
        }
    }

    // MARK: - Map (inline, smaller)
    //
    // Single persistent Map instance. The previous implementation branched
    // between three layouts (no coords / 1 coord / many coords) and each
    // branch instantiated a new Map — every GPS-fix-count transition tore
    // one down and created another, which SwiftUI's Map renders as a full
    // flash + recenter. That's the 2026-04 user report: "the screen was
    // shifting the whole time between having a map and showing something
    // else" + elevated battery drain. One Map, three *overlay* states,
    // stable camera position — no recreate, no recenter.
    var mapCard: some View {
        StableMapCard(
            coordinates: recorder.liveTrack.map(\.coordinate),
            accuracy: recorder.locationManager.lastHorizontalAccuracy
        )
    }

    @ViewBuilder
    var accuracyBadge: some View {
        if let acc = recorder.locationManager.lastHorizontalAccuracy, acc > 20 {
            Text(String(localized: "GPS ±\(Int(acc))m", bundle: LanguageManager.appBundle))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(.black.opacity(0.55)))
                .foregroundStyle(.white)
        }
    }

    func regionForTrack(_ coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        MapBoundsHelper.region(for: coordinates)
    }

    // MARK: - Derived labels

    var distanceLabel: String {
        units.formatDistance(meters: recorder.distanceMeters)
    }

    var elevationLabel: String {
        units.formatElevation(meters: recorder.elevationGainMeters)
    }

    var paceCaption: String? {
        units.formatPace(elapsedSec: recorder.elapsedSeconds, distanceMeters: recorder.distanceMeters)
    }

    var cadenceCaption: String? {
        guard let c = recorder.cadenceStepsPerMin, c > 0 else { return nil }
        return "\(Int(c.rounded())) spm"
    }

    // Live-view metric helpers (added alongside the tile expansion so the
    // grid has something real to render even on short walks). Each returns
    // a formatted String (or nil to hide the caption); never a forced "—"
    // when the underlying data is genuinely absent.

    /// Instantaneous pace from the most recent captured WorkoutSample, if
    /// it has a `paceSecPerKm`. Falls back to "—" instead of a stale number.
    var currentPaceLabel: String {
        let latest = latestSampleWithPace
        guard let pace = latest?.paceSecPerKm else { return "—" }
        return units.formatPace(secondsPerMeter: pace / 1000) ?? "—"
    }

    /// Overall avg pace = duration ÷ distance. Shown as the tile caption so
    /// the "Pace" tile tells you both "right now" (big) and "for the whole
    /// workout so far" (small).
    var avgPaceCaption: String? {
        guard recorder.distanceMeters > 50, recorder.elapsedSeconds > 10 else { return nil }
        return units.formatPace(
            elapsedSec: recorder.elapsedSeconds,
            distanceMeters: recorder.distanceMeters
        ).map { "avg \($0)" }
    }

    /// Average HR over the captured samples. Live-computed so it reflects
    /// "the workout so far" not the current-beat number on the hero card.
    var avgHRLabel: String {
        let hrValues = recorder.samplesView.compactMap(\.heartRate)
        guard !hrValues.isEmpty else { return "—" }
        let mean = Double(hrValues.reduce(0, +)) / Double(hrValues.count)
        return "\(Int(mean.rounded()))"
    }

    var peakHRCaption: String? {
        guard recorder.peakHR > 0 else { return nil }
        return "peak \(recorder.peakHR)"
    }

    var currentMETs: Double? {
        recorder.samplesView.last?.mets
    }

    var latestSampleWithPace: WorkoutSample? {
        recorder.samplesView.last(where: { $0.paceSecPerKm != nil })
    }

    var alpha1Label: String {
        guard let alpha1 = recorder.dfa.currentAlpha1 else { return "—" }
        return String(format: "%.2f", locale: .current, alpha1)
    }

    /// Strap-less workouts have no RR feed, so DFA stays at
    /// warmup-0% forever and the caption would read "warming up — 0 % of
    /// 2-min window" indefinitely, misleading users into thinking they just
    /// had to wait. Short-circuit when there is no strap source and explain the
    /// requirement directly. Pairs with the LiveDFAAnalyzer fix that nulls α1
    /// when the strap goes silent.
    ///
    /// Everything else routes by the analyzer's own status, so the caption can
    /// never silently say "warming up" after 10 min of a silent strap — the
    /// user (and the AI coach) can see WHY the number is not there.
    var alpha1Caption: String? {
        if recorder.activeHRSource != .strap {
            return String(localized: "Connect a chest strap to enable α1", bundle: LanguageManager.appBundle)
        }
        // Route by the analyzer's own status so the caption never silently
        // says "warming up" after 10 min of a silent strap — the user (and
        // the AI coach) can see WHY the number isn't there.
        switch recorder.dfa.status {
        case .warmup(let fraction):
            let pct = Int(fraction * 100)
            return String(localized: "warming up — \(pct) % of 2-min window", bundle: LanguageManager.appBundle)
        case .stalled(let silent):
            return String(localized: "strap silent for \(Int(silent)) s", bundle: LanguageManager.appBundle)
        case .fitFailed:
            return String(localized: "fit failed — HR too flat for this window", bundle: LanguageManager.appBundle)
        case .tooManyArtifacts(let fraction):
            let pct = Int((fraction * 100).rounded())
            return String(localized: "signal too noisy — \(pct) % of beats corrected", bundle: LanguageManager.appBundle)
        case .ok:
            return alpha1BandCaption
        }
    }

    private var alpha1BandCaption: String? {
        switch recorder.dfa.currentBand {
        case .belowAeT: return String(localized: "below aerobic threshold", bundle: LanguageManager.appBundle)
        case .nearAeT: return String(localized: "near aerobic threshold", bundle: LanguageManager.appBundle)
        case .nearVT2: return String(localized: "approaching anaerobic threshold", bundle: LanguageManager.appBundle)
        case .aboveVT2: return String(localized: "above anaerobic threshold", bundle: LanguageManager.appBundle)
        case .unknown: return nil
        }
    }

    func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Bottom controls

    /// Are we mid-finalize? Drives the button's "Saving…" state so a
    /// user who already pressed Hold To End doesn't think nothing
    /// happened. The recorder transitions phase → .finalizing the
    /// moment stop() is called; the button no-ops further holds
    /// while in this state.
    var isFinalizing: Bool {
        switch recorder.phase {
        case .recording, .idle, .failed: return false
        case .finalizing, .finished: return true
        }
    }

    /// Hold-to-end: the progress bar IS the confirmation. Fills over 1.2 s of
    /// continuous press; release early cancels. No system dialog to scan for on
    /// a sun-washed screen.
    ///
    /// When phase is .finalizing the gesture no-ops (the
    /// recorder's `case .recording = phase else { return }` guard eats the
    /// second tap silently, which made users think the button was broken and
    /// force-quit). The button morphs to a "Saving…" affordance so the held
    /// tap is visibly acknowledged and held gestures are ignored.
    var stopButton: some View {
        withHoldGesture(stopButtonSurface)
    }

    private var stopButtonSurface: some View {
        GeometryReader { geo in
            stopButtonLayers(width: geo.size.width)
        }
        .frame(height: 52)
        .contentShape(Rectangle())
    }

    private func withHoldGesture(_ content: some View) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isFinalizing else { return }
                        startHolding()
                    }
                    .onEnded { _ in cancelHolding() }
            )
            .accessibilityLabel(isFinalizing
                ? String(localized: "Saving workout", bundle: LanguageManager.appBundle)
                : String(localized: "End workout", bundle: LanguageManager.appBundle))
            .accessibilityHint(isFinalizing
                ? String(localized: "Saving in progress, please wait", bundle: LanguageManager.appBundle)
                : String(localized: "Press and hold for \(Int(holdDurationSec)) seconds to end the session", bundle: LanguageManager.appBundle))
            .accessibilityAction(named: String(localized: "End workout now", bundle: LanguageManager.appBundle)) {
                guard !isFinalizing else { return }
                onStop()
            }
    }

    private func stopButtonLayers(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            stopButtonTrack
            stopButtonFill(width: width)
            stopButtonLabel
        }
        .frame(height: 52)
        .shadow(color: AppTheme.fitnessAccent.opacity(0.3), radius: 8, y: 3)
    }

    private var stopButtonTrack: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isFinalizing
                ? AppTheme.fitnessAccent.opacity(0.45)
                : AppTheme.fitnessAccent.opacity(0.85))
    }

    /// The fill layer grows to the right under the user's finger.
    @ViewBuilder
    private func stopButtonFill(width: CGFloat) -> some View {
        // Fill layer grows to the right under the user's finger.
        if !isFinalizing {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.red, Color.red.opacity(0.85)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(width: max(0, width * holdProgress))
        }
    }
    @ViewBuilder
    private var stopButtonLabel: some View {
        HStack(spacing: 8) {
            if isFinalizing {
                savingLabel
            } else {
                holdToEndLabel
            }
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var savingLabel: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .tint(.white)
            .scaleEffect(0.8)
        Text(String(localized: "Saving workout…", bundle: LanguageManager.appBundle))
            .fontWeight(.semibold)
    }

    /// A bare "Hold to End Workout" gives no hint at the
    /// duration the user has to wait for. Shows the cap explicitly
    /// ("Hold 1.2s to end") so the mechanic and timing are obvious before the
    /// first press; switches to a visible countdown once the press starts.
    @ViewBuilder
    private var holdToEndLabel: some View {
        // Each value is bound before use. As one expression — a ternary
        // between two `String(localized:)` calls, one of them interpolating
        // literal arithmetic — this getter cost 171 ms to type-check. The
        // literals are untouched, so the catalogue keys are unchanged.
        let remaining: Double = (1 - holdProgress) * holdDurationSec * 10
        let secondsLeft: Int = Int(remaining) / 10 + 1
        let counting = String(localized: "Hold to end… \(secondsLeft)", bundle: LanguageManager.appBundle)
        let idle = String(localized: "Hold \(formatHoldDuration(holdDurationSec)) to end workout", bundle: LanguageManager.appBundle)
        Image(systemName: "stop.fill")
        Text(isHolding ? counting : idle)
            .fontWeight(.semibold)
            .contentTransition(.numericText())
    }

    /// When the user begins the hold, immediately give
    /// them a tactile cue ("yes, you're holding"). A gesture that stays
    /// silent until the progress bar visibly fills is a slow signal on a
    /// sun-washed outdoor screen. The light impact here is the same
    /// one Apple uses for slider thumbs / drag starts. If the recorder is
    /// ALREADY finalizing (a second hold attempt while the save is in flight),
    /// give a warning haptic instead so the user knows the tap was registered
    /// but the action is gated.
    func startHolding() {
        guard !isHolding else { return }
        if isFinalizing {
            let warning = UINotificationFeedbackGenerator()
            warning.prepare()
            warning.notificationOccurred(.warning)
            return
        }
        isHolding = true
        holdProgress = 0
        let startGen = UIImpactFeedbackGenerator(style: .light)
        startGen.prepare()
        startGen.impactOccurred()
        holdTimer?.invalidate()
        holdTimer = makeHoldTimer()
    }

    /// Run loop `.common` mode so the hold timer fires WHILE the
    /// user is actively touching the button (which puts the run loop in
    /// `.eventTracking`). With `Timer.scheduledTimer`'s default-mode
    /// behavior the hold progress could stall mid-press, ironically right
    /// when the user is most actively holding.
    private func makeHoldTimer() -> Timer {
        let stepSec = 0.05
        let increment = stepSec / holdDurationSec
        let t = Timer(timeInterval: stepSec, repeats: true) { _ in
            // Timers fire on the run loop they were added to — the main one here.
            MainActor.assumeIsolated { advanceHold(by: increment) }
        }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private func advanceHold(by increment: Double) {
        holdProgress = min(1.0, holdProgress + increment)
        guard holdProgress >= 1.0 else { return }
        holdTimer?.invalidate()
        holdTimer = nil
        isHolding = false
        completeHold()
    }

    /// Success cue at the moment the workout actually ends — the same haptic
    /// the OS uses for "task completed", so muscle memory carries the semantic.
    /// Fires `onStop` once, then resets so a re-show doesn't start pre-filled.
    private func completeHold() {
        let successGen = UINotificationFeedbackGenerator()
        successGen.prepare()
        successGen.notificationOccurred(.success)
        onStop()
        holdProgress = 0
    }

    /// Pretty-format the hold duration for the resting button label.
    /// Whole seconds drop the decimal ("1s"); fractional values keep
    /// one decimal place ("1.2s").
    func formatHoldDuration(_ sec: Double) -> String {
        if sec.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(sec))s"
        }
        return String(format: "%.1fs", locale: .current, sec)
    }

    func cancelHolding() {
        // If the user was mid-hold and lifted
        // off before the bar filled, give a gentle "nope" cue so
        // they know the hold was abandoned (vs a phantom finger
        // movement actually registering).
        if isHolding, holdProgress > 0.05, holdProgress < 1.0 {
            let cancelGen = UIImpactFeedbackGenerator(style: .soft)
            cancelGen.prepare()
            cancelGen.impactOccurred()
        }
        holdTimer?.invalidate()
        holdTimer = nil
        isHolding = false
        withAnimation(.easeOut(duration: 0.15)) {
            holdProgress = 0
        }
    }

    var voiceBar: some View {
        HStack(spacing: 10) {
            voiceToggleButton

            voiceStopButton
        }
    }

    @ViewBuilder
    private var voiceStopButton: some View {
        if conversation.state != .idle {
            Button {
                conversation.stop()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.textSecondary)
            }
                
            .accessibilityLabel(String(localized: "Close", bundle: LanguageManager.appBundle)).buttonStyle(.plain)
        }
    }

    private var voiceToggleButton: some View {
        Button {
            conversation.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: voiceButtonIcon)
                Text(voiceButtonLabel)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(voiceButtonColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    var voiceButtonIcon: String {
        switch conversation.state {
        case .idle: "mic.circle.fill"
        case .starting: "ellipsis.circle.fill"
        case .listening: "waveform.circle.fill"
        case .thinking: "ellipsis.circle.fill"
        case .speaking: "speaker.wave.3.fill"
        case .triggerSpeaking: "exclamationmark.circle.fill"
        }
    }

    var voiceButtonLabel: String {
        switch conversation.state {
        case .idle: String(localized: "Talk", bundle: LanguageManager.appBundle)
        case .starting: String(localized: "Connecting…", bundle: LanguageManager.appBundle)
        case .listening: String(localized: "Listening…", bundle: LanguageManager.appBundle)
        case .thinking: String(localized: "Thinking…", bundle: LanguageManager.appBundle)
        case .speaking: String(localized: "Tap to interrupt", bundle: LanguageManager.appBundle)
        case .triggerSpeaking: String(localized: "Alert", bundle: LanguageManager.appBundle)
        }
    }

    @MainActor var voiceButtonColor: Color {
        switch conversation.state {
        case .idle: AppTheme.primary
        case .starting: AppTheme.mist
        case .listening: AppTheme.sage
        case .thinking: AppTheme.mist
        case .speaking: AppTheme.dustyRose
        case .triggerSpeaking: AppTheme.fitnessAccent
        }
    }
}

// MARK: - Stable Map Card
//
// Single Map instance whose camera is owned by @State. Updates are applied
// as *camera moves* on the same Map rather than as new Map construction,
// which fixes both the visible flicker ("screen shifting between map and
// something else") and the battery drain (MKMapView teardown is not cheap).
//
// Placeholder and polyline live as overlays on the same frame so the card's
// footprint never changes size — users mid-workout shouldn't see layout
// jumps.
private struct StableMapCard: View {
    let coordinates: [CLLocationCoordinate2D]
    let accuracy: CLLocationAccuracy?

    @State private var position: MapCameraPosition = .automatic
    /// Tracks how many coordinates we've seen so we only update the camera
    /// when the track grows meaningfully, not every tick. Keeps the map
    /// from panning with every GPS sample.
    @State private var lastFramedCount: Int = 0

    var body: some View {
        ZStack {
            mapBackdrop
            if coordinates.isEmpty {
                waitingForFixPlaceholder
            } else {
                liveRouteMap
            }
        }
        .frame(height: 180)
        .overlay(alignment: .topTrailing) { gpsAccuracyBadge }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: coordinates.count) { _, newCount in reframe(to: newCount) }
    }

    /// Always present so the card height never shifts while GPS is still
    /// looking for a fix.
    private var mapBackdrop: some View {
        // Background frame is always present so height never shifts.
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(AppTheme.cardBackground)
            .frame(height: 180)
    }

    private var waitingForFixPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "location.magnifyingglass")
                .font(.title2)
                .foregroundStyle(AppTheme.textTertiary)
                .accessibilityHidden(true)
            Text(String(localized: "Waiting for GPS fix…", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            Text(String(localized: "Outdoor sky view improves accuracy", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String(localized: "Waiting for GPS fix", bundle: LanguageManager.appBundle)))
    }

    private var liveRouteMap: some View {
        Map(position: $position) {
            if coordinates.count >= 2 {
                MapPolyline(coordinates: coordinates)
                    .stroke(AppTheme.fitnessAccent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            if let last = coordinates.last {
                Marker("", coordinate: last)
                    .tint(coordinates.count >= 2 ? AppTheme.primary : AppTheme.sage)
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .frame(height: 180)
        .accessibilityLabel(Text(String(localized: "Live workout route map", bundle: LanguageManager.appBundle)))
    }

    @ViewBuilder
    private var gpsAccuracyBadge: some View {
        if let acc = accuracy, acc > 20 {
            Text(String(localized: "GPS ±\(Int(acc))m", bundle: LanguageManager.appBundle))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(.black.opacity(0.55)))
                .foregroundStyle(.white)
                .padding(6)
                .accessibilityLabel(Text(String(localized: "GPS accuracy plus or minus \(Int(acc)) metres", bundle: LanguageManager.appBundle)))
        }
    }

    /// Reframe only when the track has grown meaningfully (first fix, then
    /// every +10 points) so the camera does not jitter with every 1-Hz GPS
    /// sample. The user can still pan manually — position is only reset on
    /// these bulk updates.
    private func reframe(to newCount: Int) {
        guard newCount > 0 else { return }
        let shouldFrame = lastFramedCount == 0
            || (newCount - lastFramedCount) >= 10
            || newCount == 1
        guard shouldFrame else { return }
        lastFramedCount = newCount
        if newCount >= 2 {
            position = .region(Self.regionForTrack(coordinates))
        } else if let last = coordinates.last {
            position = .region(MKCoordinateRegion(
                center: last,
                latitudinalMeters: 200,
                longitudinalMeters: 200
            ))
        }
    }

    private static func regionForTrack(_ coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        MapBoundsHelper.region(for: coordinates)
    }
}
