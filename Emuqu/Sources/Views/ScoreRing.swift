import SwiftUI

/// The hero element. One ScoreRing component, three sizes
/// (Hero / Card / Inline), reused on Dashboard, Sleep detail, anywhere a
/// 0–100 score appears.
///
/// States:
///   • `default`             — score and verdict shown, ring filled to value
///   • `loading`             — skeleton shimmer, score "—"
///   • `buildingBaseline`    — progress dots (Day X of N), no score number
///   • `noData`              — ghost outline + CTA below
///   • `error(message)`      — ghost outline + error chip below
///
/// Animation behaviours:
///   • Reveal: 600ms easeOutQuart ring fill + last 200ms digit roll
///   • Subtle "breathing": 4-second sine-wave scale (1.0 → 1.005 → 1.0)
///     when score > 67. Disabled on `UIAccessibility.isReduceMotionEnabled`
///   • Day-30+ users get 400ms snappier reveal
///
/// Accessibility: combined element via `.accessibilityElement(children:
/// .combine)`, label "Recovery score 94, Excellent, ring filled 94 percent."
/// Pair colour with `ScoreVerdict.glyphName` glyph + verdict word — never
/// colour alone.
struct ScoreRing: View {
    enum DisplayState {
        case `default`(score: Int, verdict: ScoreVerdict)
        case loading
        case buildingBaseline(day: Int, target: Int)
        case noData
        case error(message: String)
    }

    enum Size {
        case hero    // 210pt — Dashboard
        case card    // 90pt  — Sleep detail / detail headers
        case inline  // 44pt  — list rows / chips

        var diameter: CGFloat {
            switch self {
            case .hero:   210
            case .card:   90
            case .inline: 44
            }
        }

        var lineWidth: CGFloat {
            switch self {
            case .hero:   12
            case .card:   8
            case .inline: 4
            }
        }

        var scoreFontSize: CGFloat {
            switch self {
            case .hero:   84
            case .card:   34
            case .inline: 16
            }
        }

        var verdictFontSize: CGFloat {
            switch self {
            case .hero:   17
            case .card:   13
            case .inline: 0   // hide
            }
        }
    }

    let state: DisplayState
    let size: Size
    var snappy: Bool = false   // true → 400ms reveal (Day-30+ users)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealedFraction: Double = 0
    @State private var displayedScore: Int = 0
    @State private var breathingScale: CGFloat = 1.0

    private var revealDuration: Double { snappy ? 0.4 : 0.6 }

    /// Pure projection of the `state` enum's score (if any).
    /// Used as the value the digit-roll animation tracks. SwiftUI's
    /// `onChange(of:)` needs an `Equatable` Hashable value here, and an
    /// optional `Int` is both.
    private var scoreFromState: Int? {
        if case let .default(score, _) = state { return score }
        return nil
    }

    var body: some View {
        ZStack {
            stateView
        }
        .frame(width: size.diameter, height: size.diameter)
        .scaleEffect(breathingScale)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .onAppear { animateOnAppear() }
        .onChange(of: scoreFromState) { _, newScore in
            animateScoreChange(to: newScore)
        }
    }

    /// Without the `.onChange` above, when the
    /// parent re-renders with a new score, SwiftUI reuses the existing `@State`
    /// storage for `displayedScore`, `.onAppear` does NOT re-fire (the view
    /// didn't reappear), and the centre label keeps showing the OLD number
    /// because `centerLabel` reads `displayedScore` (the @State) not the `score`
    /// param. User-reported symptom: "hero badge doesn't update unless I change
    /// tabs or restart the app" — exactly the @State-pinning signature, and the
    /// reason four upstream fixes (archive signal, reload path,
    /// `vm.reanalyzedSession`, cache refresh) never moved the visible number.
    ///
    /// That `.onChange` runs the digit-roll between the current
    /// `displayedScore` and whatever the new `state` carries. No full reveal
    /// replay (the ring is already shown); only the numeric value animates, so
    /// the user sees a transition from old → new rather than a snap.
    @ViewBuilder
    private var stateView: some View {
        switch state {
        case let .default(score, verdict):
            ringView(value: Double(score) / 100, color: verdict.color)
            centerLabel(score: score, verdict: verdict)
        case .loading:
            loadingRing
        case let .buildingBaseline(day, target):
            buildingBaselineView(day: day, target: target)
        case .noData:
            noDataView
        case let .error(message):
            errorView(message: message)
        }
    }

    @ViewBuilder
    private var loadingRing: some View {
        ringView(value: 0.18, color: AppTheme.textTertiary.opacity(0.4))
            .opacity(0.6)
        Text(verbatim: "—")
            .font(.system(size: size.scoreFontSize, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(AppTheme.textTertiary)
    }

    // MARK: - Pieces

    private func ringView(value: Double, color: Color) -> some View {
        ZStack {
            Circle()
                .stroke(AppTheme.textTertiary.opacity(0.18), lineWidth: size.lineWidth)
            Circle()
                .trim(from: 0, to: value * revealedFraction)
                .stroke(color, style: StrokeStyle(lineWidth: size.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }

    /// The score digits deliberately do **not** use `scaledFont`.
    ///
    /// They are centred inside a ring whose diameter is fixed by `Size`
    /// (210 / 90 / 44 pt) — that geometry is the component's contract, and
    /// every caller lays out around it. At AX5 an 84 pt figure on the
    /// large-title curve would render past the stroke it sits inside, so the
    /// number would grow *out* of its own ring rather than the layout
    /// absorbing it. The verdict word beneath it does scale, which is what
    /// carries the reading for a user at a larger text size.
    private func centerLabel(score: Int, verdict: ScoreVerdict) -> some View {
        VStack(spacing: size == .hero ? 4 : 2) {
            Text(verbatim: "\(displayedScore)")
                .font(.system(size: size.scoreFontSize, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
                .contentTransition(.numericText(value: Double(displayedScore)))
            if size != .inline {
                Text(verbatim: verdict.localizedWord)
                    .scaledFont(size: size.verdictFontSize, weight: .semibold)
                    .foregroundStyle(verdict.textColor)
            }
        }
    }

    private func buildingBaselineView(day: Int, target: Int) -> some View {
        VStack(spacing: 6) {
            baselineDots(day: day, target: target)
            baselineCaption(day: day, target: target)
        }
    }

    /// One dot per collected day, capped at 14 so a long target doesn't
    /// overflow the ring.
    private func baselineDots(day: Int, target: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<min(target, 14), id: \.self) { idx in
                Circle()
                    .fill(idx < day ? AppTheme.wongGood : AppTheme.textTertiary.opacity(0.25))
                    .frame(width: size == .hero ? 8 : 4, height: size == .hero ? 8 : 4)
            }
        }
    }

    @ViewBuilder
    private func baselineCaption(day: Int, target: Int) -> some View {
        if size != .inline {
            Text(String(localized: "Day \(day) of \(target)", bundle: LanguageManager.appBundle))
                .scaledFont(size: size.verdictFontSize, weight: .semibold)
                .foregroundStyle(AppTheme.textSecondary)
            Text(String(localized: "Building your baseline", bundle: LanguageManager.appBundle))
                .scaledFont(size: max(11, size.verdictFontSize - 4))
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private var noDataView: some View {
        VStack(spacing: 4) {
            Image(systemName: "circle.dashed")
                .font(.system(size: size.scoreFontSize * 0.5))
                .foregroundStyle(AppTheme.textTertiary)
            if size != .inline {
                Text(String(localized: "No reading yet", bundle: LanguageManager.appBundle))
                    .scaledFont(size: size.verdictFontSize, weight: .semibold)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: size.scoreFontSize * 0.5))
                .foregroundStyle(AppTheme.wongAttention)
            if size != .inline {
                Text(verbatim: message)
                    .scaledFont(size: size.verdictFontSize - 2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
    }

    // MARK: - Animation

    private func animateOnAppear() {
        guard !reduceMotion else {
            revealedFraction = 1
            if case let .default(score, _) = state { displayedScore = score }
            return
        }
        // easeOutQuart (4th-order polynomial), not
        // SwiftUI's default cubic .easeOut. Custom timing curve below
        // approximates `1 - (1-t)^4`. Using SwiftUI's `Animation.timingCurve`
        // with control points calibrated against the easeOutQuart Bezier
        // approximation (https://easings.net/#easeOutQuart).
        let easeOutQuart = Animation.timingCurve(0.25, 1, 0.5, 1, duration: revealDuration)
        withAnimation(easeOutQuart) {
            revealedFraction = 1
        }
        if case let .default(score, _) = state {
            revealScore(score, curve: easeOutQuart)
        }
    }

    /// Digit roll for the LAST 200 ms of the reveal
    /// (independent of total duration). Snappy mode is 400 ms total → digit
    /// rolls at 200 ms; default is 600 ms → digit rolls at 400 ms. Previous
    /// code used a 66 % delay, which broke the 200 ms window in snappy mode
    /// (a 4 ms roll).
    ///
    /// Subtle breathing starts once the reveal completes — only when score > 67.
    private func revealScore(_ score: Int, curve easeOutQuart: Animation) {
        let digitRollDuration: Double = 0.2
        withAnimation(easeOutQuart.delay(max(0, revealDuration - digitRollDuration))) {
            displayedScore = score
        }
        guard score > 67 else { return }
        withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true).delay(revealDuration)) {
            breathingScale = 1.005
        }
    }

    /// Re-runs the digit-roll animation when the parent
    /// passes a new `state.default(score: …)` while the ScoreRing is
    /// still on screen. This is the in-place mid-session update path
    /// (reanalysis lands a new score, sleep refresh recomputes, manual
    /// window choice applies). The `.onAppear` reveal is intentionally
    /// NOT replayed — the ring is already visible; only the centre
    /// number needs to roll from old to new.
    ///
    /// Also handles transitions OUT of `.default` (e.g., switching to
    /// `.loading` mid-reanalysis) by resetting `displayedScore` so a
    /// later .default doesn't briefly flash the prior session's number.
    /// A transition INTO `.default` replays the full ring reveal only after
    /// the view has left `.default` (which resets the ring). When the view
    /// first appeared in a non-`.default` state (building baseline, loading),
    /// `animateOnAppear` has already revealed the ring, so only the digits roll.
    private func animateScoreChange(to newScore: Int?) {
        guard let newScore else {
            resetForNonDefaultState()
            return
        }
        guard !reduceMotion else {
            displayedScore = newScore
            revealedFraction = 1
            return
        }
        rollScore(to: newScore)
        updateBreathing(for: newScore)
    }

    /// Leaving `.default`: reset the rolled-up number so a later re-entry
    /// doesn't start from a stale value, pull the ring back to "unrevealed" so
    /// the next transition gets its proper reveal animation, and stop breathing.
    private func resetForNonDefaultState() {
        displayedScore = 0
        revealedFraction = 0
        breathingScale = 1.0
    }

    /// If `revealedFraction` is still 0 we're crossing from a non-`.default`
    /// state (loading, buildingBaseline) into `.default` for the first time on
    /// this view instance — replay the full reveal so the ring fills in
    /// properly. Otherwise roll the digits over ~250 ms with no ring
    /// re-reveal: SwiftUI's `.contentTransition(.numericText)` on the Text
    /// handles the per-digit transition; we just animate the underlying value.
    private func rollScore(to newScore: Int) {
        let easeOutQuart = Animation.timingCurve(0.25, 1, 0.5, 1, duration: revealDuration)
        guard revealedFraction < 0.99 else {
            withAnimation(.easeInOut(duration: 0.25)) { displayedScore = newScore }
            return
        }
        withAnimation(easeOutQuart) { revealedFraction = 1 }
        withAnimation(easeOutQuart.delay(max(0, revealDuration - 0.2))) {
            displayedScore = newScore
        }
    }

    /// Breathing toggles with the new score band (>67 only).
    private func updateBreathing(for newScore: Int) {
        if newScore > 67 {
            guard breathingScale == 1.0 else { return }
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                breathingScale = 1.005
            }
        } else if breathingScale != 1.0 {
            withAnimation(.easeInOut(duration: 0.4)) { breathingScale = 1.0 }
        }
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        let bundle = LanguageManager.appBundle
        switch state {
        case let .default(score, verdict):
            return String(localized: "Recovery score \(score), \(verdict.localizedWord), ring filled \(score) percent.", bundle: bundle)
        case .loading:
            return String(localized: "Recovery score loading.", bundle: bundle)
        case let .buildingBaseline(day, target):
            return String(localized: "Building baseline. Day \(day) of \(target).", bundle: bundle)
        case .noData:
            return String(localized: "No reading yet.", bundle: bundle)
        case let .error(message):
            return String(localized: "Error: \(message)", bundle: bundle)
        }
    }
}
