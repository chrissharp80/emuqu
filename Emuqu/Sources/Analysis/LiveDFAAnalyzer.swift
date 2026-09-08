import Foundation

// MARK: - Live DFA Analyzer
//
// Computes DFA α1 on a rolling 2-minute window of RR intervals during a live
// workout. Designed to be cheap enough to recompute every ~20 seconds on the
// main thread without visibly stutter.
//
// ─────────────────────────────────────────────────────────────────
// SCIENTIFIC BASIS:
//
// DFA α1 (detrended fluctuation analysis, short-term scaling exponent) is
// a non-linear HRV index. Its *interpretation as an aerobic-threshold
// proxy* was established by:
//
//   Rogers B., Berk S., Gronwald T. "An Index of Non-Linear HRV as a
//   Proxy of the Aerobic Threshold Based on Blood Lactate Concentration
//   in Elite Triathletes" (2022, Sports, PMC8875480)
//
//   Gronwald T., Rogers B. "Fractal Correlation Properties of Heart Rate
//   Variability as a Biomarker for Intensity Distribution and Training
//   Prescription in Endurance Exercise" (2021, PMC7845545)
//
// Their incremental-exercise studies showed α1 decreases with intensity
// and crosses ≈0.75 at the aerobic threshold (LT1/VT1). Agreement with
// gas-exchange VT1 in that paper (15 men): HR at HRVT within ~2 bpm on
// average, ICC 0.96, limits of agreement −12 to +8 bpm. Later cohorts are
// weaker — Schaffarczyk 2022 (26 women, cycling) ICC 0.87 for HR;
// Van Hooren 2023 (14 runners) limits ±11 bpm and no agreement once
// fatigued; Sempere-Ruiz 2024 (16 untrained) test–retest ICC 0.52 for HR.
// So: a validated proxy on average, with roughly ±10 bpm individual error.
// (Do not quote Schaffarczyk's VO₂ ICC range as if it were a 2024
// replication for HR; the 2024 paper reports different numbers. That
// phrasing is listed under `_retracted_claims` in the science register,
// and the register gate fails if it appears anywhere.)
//
// The ≈0.50 / anaerobic-threshold (LT2/VT2) pairing must not be stated
// with the same confidence as the 0.75 one.
// The 0.75 aerobic-threshold association is the replicated finding; the
// second-threshold association is weaker and less consistently reproduced,
// and reading a live α1 under 0.45 as "you are above LT2" is firmer than the
// evidence. The band is kept as a coarse INTENSITY display, and its label is
// "Very Hard" rather than a threshold claim.
//
// Measurement adds to that. Against ECG, chest-strap α1 has limits of
// agreement near ±10% at low intensity but roughly +58% / −41% at high
// intensity — precisely where these lower bands sit. Treat the hard end of
// this scale as directional.
//
// Band interpretation (what this analyzer returns):
//   • α1 ≥ 0.85   → belowAeT  ("easy" — clearly below aerobic threshold)
//   • 0.65-0.85   → nearAeT   ("threshold" — at/around LT1)
//   • 0.45-0.65   → nearVT2   ("hard" — well above LT1)
//   • α1 < 0.45   → aboveVT2  ("very hard" — the low end of the scale)
//
// The threshold VALUES above are what the literature calls out; the
// BANDS are our UI bucketing (slightly wider than the cited 0.75/0.50
// inflection points to avoid jitter around zone boundaries). Don't
// confuse "0.85 lower bound for belowAeT" with claiming α1 ≥ 0.85 is a
// paper-reported threshold — it isn't. It's a conservative display
// choice so a noisy α1 hovering at 0.76 doesn't flap between bands.
//
// What α1 is NOT used for in this app:
//   • Secretly rewriting TRIMP / hrTSS. TRIMP uses published Banister
//     formula with the user's configured LTHR — α1 suggests *what LTHR
//     to set*, but does not feed into the calculation. Validated
//     methods in, validated methods out.
// ─────────────────────────────────────────────────────────────────
//
// The UI surfaces the raw α1 plus a coarse band (belowAeT / nearAeT / nearVT2 /
// aboveVT2) so we can say what it means without the user doing the math.
// The post-summary additionally surfaces the HR at which α1 crossed 0.75 as a
// field ESTIMATE of LT1 the user can carry into their LTHR setting.
//
// It is NOT "a validated LT1 estimate". The 0.75 crossing is validated as a
// threshold PROXY under the cited incremental-exercise protocols; a crossing
// observed in an arbitrary field session is not itself a validated
// measurement, and calling it one promotes a protocol-dependent finding into
// a guarantee. The estimate is still worth surfacing — it is just an estimate.
@Observable
@MainActor
final class LiveDFAAnalyzer {
    // MARK: Published live output

    private(set) var currentAlpha1: Double?
    private(set) var currentBand: Band = .unknown
    private(set) var fitQuality: Double?
    /// Why α1 is currently nil (or stale). Cleared to `.ok` once a value has
    /// been produced. Exposed to the live UI and the voice-coach context so the
    /// AI can say "α1 isn't showing because the strap is dropping beats"
    /// instead of pretending the value doesn't exist. When α1 IS valid this
    /// still carries diagnostic info (last recompute time, fit quality, beats
    /// in window) — so "it's working fine" is a visible, provable state too.
    private(set) var status: Status = .warmup(fractionReady: 0)
    /// Rolling-window fill fraction 0..1, so the UI can animate a "X %
    /// ready" readout during the first two minutes. Separate from `status`
    /// so views can bind to it independently.
    private(set) var bufferFillFraction: Double = 0
    /// Most recent recompute timestamp — nil if we've never produced a value.
    /// Used to spot "value is stale because RR has stopped arriving."
    private(set) var lastComputeAt: Date?
    /// Beats currently in the rolling window. Correlates with `bufferFillFraction`
    /// but exposed separately for the diagnostic readout ("217 / 240 needed").
    private(set) var beatsInWindow: Int = 0
    /// Fraction (0..1) of the last fitted window that was artifact-corrected.
    /// Nil until a window has been evaluated. Above
    /// `lowConfidenceCorrectedFraction` the α1 on screen is real but softer
    /// than it looks; above `maxCorrectedFraction` no α1 is published at all.
    private(set) var correctedFraction: Double?

    enum Band: String {
        case unknown
        case belowAeT   // α1 > 0.85
        case nearAeT    // 0.65 ≤ α1 ≤ 0.85
        case nearVT2    // 0.45 ≤ α1 < 0.65
        case aboveVT2   // α1 < 0.45

        var label: String {
            switch self {
            case .unknown: "—"
            case .belowAeT: "Easy"
            case .nearAeT: "Threshold"
            case .nearVT2: "Hard"
            case .aboveVT2: "Very Hard"
            }
        }
    }

    /// Reason α1 is (not) currently valid. Used for UI badges AND the voice
    /// coach context so "α1 missing" never just silently shows nothing.
    enum Status: Equatable {
        /// Still filling the 2-minute rolling window. `fractionReady` is 0..1.
        case warmup(fractionReady: Double)
        /// Producing values within the last `cadenceSec` — everything fine.
        case ok
        /// Had values earlier but the RR stream has stopped arriving.
        /// `secondsSinceLastBeat` shows how long the gap has been.
        case stalled(secondsSinceLastBeat: Double)
        /// The DFA fit failed (e.g., insufficient variance in the beat series).
        /// Typically means very flat HR and noisy RR — rare.
        case fitFailed
        /// Too much of the window had to be artifact-corrected for α1 to mean
        /// anything. `correctedFraction` is 0..1 — see `maxCorrectedFraction`.
        case tooManyArtifacts(correctedFraction: Double)

        var label: String {
            switch self {
            case .warmup(let f): "warming up (\(Int(f * 100)) %)"
            case .ok: "ok"
            case .stalled(let s): "strap silent for \(Int(s)) s"
            case .fitFailed: "fit failed"
            case .tooManyArtifacts(let f): "signal too noisy (\(Int((f * 100).rounded())) % corrected)"
            }
        }
    }

    // MARK: Config

    /// Rolling window size in seconds.
    private let windowSec: TimeInterval
    /// Recompute cadence (seconds between α1 evaluations).
    private let cadenceSec: TimeInterval
    /// Minimum beats required for a valid DFA fit — ~64 beats ≈ 50-60 s at
    /// walking HR. The 2-minute window generally holds 200+ at jogging pace.
    private let minBeatsForFit: Int = 64

    /// Fraction of a window that may be artifact-corrected before α1 is
    /// reported as low-confidence rather than clean.
    ///
    /// Gronwald & Rogers' 2022 update (Front. Physiol. 13:879071) measured the
    /// bias artifact correction itself introduces into α1: minimal below 3 %,
    /// with a negligible shift in the derived HRV threshold even at 6 %. Those
    /// two numbers are the two gates below.
    /// `nonisolated` for the same reason `cleanRRForDFA` is: the offline
    /// re-analyzer applies the identical threshold from a background task, and
    /// a threshold the two paths cannot share is a threshold they will drift on.
    nonisolated static let lowConfidenceCorrectedFraction: Double = 0.03
    /// Fraction above which the window is rejected outright — the number would
    /// be describing the interpolator, not the athlete.
    nonisolated static let maxCorrectedFraction: Double = 0.06

    /// A beat count alone (64 beats) is not enough to fit: it says nothing
    /// about whether the beats SPAN the two-minute window. At HR 160 that
    /// is ~24 s of data, and every comment in this file (and in
    /// `WorkoutAlpha1Reanalyzer`, which runs "the exact same math
    /// offline vs. live") says two minutes. Rogers/Gronwald's protocol uses
    /// fixed 2-minute windows precisely because α1 needs that many points to
    /// be stable; fitting a quarter of one and labelling the result "Hard"
    /// mid-run is the failure mode the beat count alone cannot see.
    ///
    /// Both conditions have to hold: enough beats AND enough elapsed time.
    private var hasEnoughDataForFit: Bool {
        rollingBuffer.count >= minBeatsForFit && bufferSpanSec >= windowSec - Self.windowSpanSlackSec
    }

    /// How far short of `windowSec` a FULL window is allowed to measure.
    ///
    /// The buffer can never span `windowSec` exactly. `trimToWindow` drops
    /// beats strictly older than the cutoff, so the oldest RETAINED beat sits
    /// up to one RR interval after it — a "full" two-minute window at 60 bpm
    /// measures about 119 s. A bare `>= windowSec` test therefore never passes
    /// and α1 warms up forever, which is what this constant exists to prevent.
    ///
    /// The slack is one maximum-length interval: 2000 ms, the same ceiling
    /// `isArtifactBeat` uses for an implausibly slow beat. Anything longer is
    /// not a beat gap, it is missing data, and the beat-count condition is what
    /// catches that.
    private static let windowSpanSlackSec: TimeInterval = 2.0

    /// Elapsed time actually covered by the rolling buffer, in seconds.
    private var bufferSpanSec: TimeInterval {
        guard let first = rollingBuffer.first, let last = rollingBuffer.last else { return 0 }
        return Double(last.t_ms - first.t_ms) / 1_000.0
    }

    // MARK: State

    private var rollingBuffer: [RRPoint] = []
    private var lastComputeDate: Date?
    private var sessionStart: Date?
    /// Wall-clock of the most recent ingested beat. Lets us report
    /// "stalled for N seconds" when the strap stops providing data.
    private var lastBeatAt: Date?

    init(windowSec: TimeInterval = 120, cadenceSec: TimeInterval = 20) {
        self.windowSec = windowSec
        self.cadenceSec = cadenceSec
    }

    // MARK: - Public API

    func reset(sessionStart: Date) {
        rollingBuffer.removeAll()
        lastComputeDate = nil
        lastBeatAt = nil
        currentAlpha1 = nil
        currentBand = .unknown
        fitQuality = nil
        bufferFillFraction = 0
        beatsInWindow = 0
        correctedFraction = nil
        lastComputeAt = nil
        status = .warmup(fractionReady: 0)
        self.sessionStart = sessionStart
    }

    /// Feed newly-arrived RR points into the rolling buffer and trigger a
    /// recompute if enough time has elapsed since the last one.
    func ingest(points: [RRPoint], now: Date = Date()) {
        guard let start = sessionStart else { return }
        rollingBuffer.append(contentsOf: points)
        if !points.isEmpty {
            lastBeatAt = now
        }
        trimToWindow(now: now, sessionStart: start)
        publishFillProgress()

        if let last = lastComputeDate, now.timeIntervalSince(last) < cadenceSec {
            refreshStatus(now: now)
            return
        }
        lastComputeDate = now
        recompute(now: now)
    }

    /// Drop beats that have fallen out of the rolling window.
    private func trimToWindow(now: Date, sessionStart start: Date) {
        let cutoffMs = MillisecondOffset.between(now, and: start, fallback: 0) - Int64(windowSec * 1000)
        guard cutoffMs > 0 else { return }
        rollingBuffer.removeAll { $0.t_ms < cutoffMs }
    }

    /// Publish how full the window is, on whichever of the two requirements is
    /// further from being met.
    ///
    /// That "whichever" is the point. The caption reads "warming up — X % of
    /// 2-min window", so it has to track the BINDING constraint, not the
    /// flattering one. Before the elapsed-time gate existed this hit 100 % as
    /// soon as 64 beats had arrived — sometimes 25 s into a window the same
    /// caption was calling two minutes long.
    private func publishFillProgress() {
        beatsInWindow = rollingBuffer.count
        let byBeats = min(1, Double(rollingBuffer.count) / Double(minBeatsForFit))
        // Divided by the SAME span `hasEnoughDataForFit` requires, so 100 %
        // means ready. Dividing by the nominal `windowSec` instead peaked at
        // 99 % on a window the gate already considered full — the readout and
        // the gate disagreeing about "full" is how a progress bar earns a
        // reputation for lying.
        let byTime = min(1, bufferSpanSec / max(windowSec - Self.windowSpanSlackSec, 1))
        bufferFillFraction = min(byBeats, byTime)
    }

    /// Force a status refresh without ingesting new beats. Called by the tick
    /// loop so "stalled for N seconds" updates even when the strap is silent.
    func tick(now: Date = Date()) {
        refreshStatus(now: now)
    }

    // MARK: - Recompute

    private func recompute(now: Date) {
        guard hasEnoughDataForFit else {
            refreshStatus(now: now)
            return
        }
        let cleaned = Self.cleanRRForDFA(rollingBuffer.map { Double($0.rr_ms) })
        correctedFraction = cleaned.correctedFraction
        guard let result = fitOrExplain(cleaned) else { return }
        currentAlpha1 = result.alpha1
        fitQuality = result.alpha1R2
        currentBand = band(for: result.alpha1)
        lastComputeAt = now
        refreshStatus(now: now)
    }

    /// Fit the cleaned window, or set the status explaining why not.
    ///
    /// Returning nil ALWAYS leaves `status` saying which of the two reasons it
    /// was, because "no α1 this tick" with no explanation is the failure this
    /// analyzer was already burned by once — see `markStalled`.
    private func fitOrExplain(_ cleaned: CleanedSeries) -> DFAAnalyzer.DFAResult? {
        // Too much of the buffer was corrected; α1 here would be describing the
        // interpolator rather than the athlete. Report it so the UI can say
        // "signal too noisy this window" instead of showing a stale number.
        guard cleaned.correctedFraction <= Self.maxCorrectedFraction else {
            logWindow(cleaned: cleaned, result: nil)
            markTooNoisy(correctedFraction: cleaned.correctedFraction)
            return nil
        }
        guard let result = DFAAnalyzer.compute(cleaned.values) else {
            status = .fitFailed
            return nil
        }
        logWindow(cleaned: cleaned, result: result)
        return result
    }

    /// The window was too heavily corrected to publish. Clear the displayed α1
    /// for the same reason `markStalled` does: a number that is no longer being
    /// computed must not stay on screen looking current.
    private func markTooNoisy(correctedFraction: Double) {
        status = .tooManyArtifacts(correctedFraction: correctedFraction)
        currentAlpha1 = nil
        currentBand = .unknown
        fitQuality = nil
    }

    /// Diagnostic log. Users have reported α1 staying above
    /// 1.0 during HR 150–170 efforts. The Kubios-style ±20 % ectopic filter can
    /// over-correct at high intensity (real intensity-driven beat-to-beat shifts
    /// get flagged), smoothing the very variability DFA needs to drop α1 into
    /// the 0.4–0.5 (above-VT2) band. This makes the correction rate visible per
    /// recompute so the hypothesis can be confirmed from a real session's traces.
    ///
    /// The correction count is carried out of the cleaner, NOT inferred as
    /// `raw.count - cleaned.count`: `cleanRRForDFA` interpolates artifacts IN
    /// PLACE — a property `testCleaningPreservesSeriesLength` asserts on
    /// purpose, because dropping beats would shift DFA's box-size accounting —
    /// so that subtraction is identically zero and every trace would read
    /// `rejected=0 (0%)`, whatever the strap was doing.
    private func logWindow(cleaned: CleanedSeries, result: DFAAnalyzer.DFAResult?) {
        guard !cleaned.values.isEmpty else { return }
        let avgRR = cleaned.values.reduce(0, +) / Double(cleaned.values.count)
        let estHR = avgRR > 0 ? Int((60_000.0 / avgRR).rounded()) : 0
        let fit = result.map {
            "α1=\(String(format: "%.2f", $0.alpha1)) R²=\(String(format: "%.2f", $0.alpha1R2))"
        } ?? "α1=rejected"
        let pct = String(format: "%.0f", cleaned.correctedFraction * 100)
        debugLog("[LiveDFA] \(fit) beats=\(cleaned.values.count) corrected=\(cleaned.correctedCount) (\(pct)%) avgHR≈\(estHR)")
    }

    /// Kubios-style artifact correction for live α1 computation.
    ///
    /// Algorithm:
    ///   1. Out-of-range beats (rr < 300 ms = >200 bpm, rr > 2000 ms =
    ///      <30 bpm) are rejected outright — they can't come from a
    ///      healthy heart during exercise.
    ///   2. For each beat, compute the median of the 5 preceding clean
    ///      beats. If `|rr − median| / median > 0.20`, the beat is an
    ///      ectopic / missed / extra beat.
    ///   3. Replace artifact beats by linear interpolation between their
    ///      nearest clean neighbours. Same treatment Kubios uses
    ///      (configurable there as "medium"). Interpolation preserves
    ///      the series length so DFA window semantics don't shift.
    ///
    /// Returns the corrected series AND how much of it was corrected.
    ///
    /// The count has to come back alongside the values: step 3 preserves the
    /// series length by construction, so no caller can recover "how much of
    /// this was invented" by inspecting the result. That is exactly what the
    /// old `[Double]` return signature invited, and what both callers did.
    ///
    /// `nonisolated` because this is a pure value transform with no
    /// instance state — lets the re-analyzer run on a background task.
    nonisolated static func cleanRRForDFA(_ rrs: [Double]) -> CleanedSeries {
        guard rrs.count >= 8 else { return CleanedSeries(values: rrs, correctedCount: 0) }
        let isArtifact = artifactMask(rrs)
        return CleanedSeries(
            values: interpolatingArtifacts(rrs, isArtifact: isArtifact),
            correctedCount: isArtifact.lazy.filter { $0 }.count
        )
    }

    /// An artifact-corrected RR series and the size of the correction.
    ///
    /// Deliberately not just `[Double]`. Correction here is interpolation in
    /// place, so the corrected series is indistinguishable from a clean one of
    /// the same length — the provenance only survives if it is carried.
    struct CleanedSeries: Equatable {
        let values: [Double]
        let correctedCount: Int

        /// 0..1. Zero for an empty series rather than NaN, so threshold
        /// comparisons on it never silently take the wrong branch.
        var correctedFraction: Double {
            values.isEmpty ? 0 : Double(correctedCount) / Double(values.count)
        }
    }

    /// Pass 1: mark artifact indices using a trailing median (a 5-beat window
    /// of recent clean values). Out-of-range beats (>200 bpm / <30 bpm) are
    /// rejected outright — they can't come from a healthy heart during exercise.
    nonisolated private static func artifactMask(_ rrs: [Double]) -> [Bool] {
        var isArtifact = Array(repeating: false, count: rrs.count)
        var recentClean: [Double] = []
        for i in 0 ..< rrs.count {
            isArtifact[i] = isArtifactBeat(rrs[i], recentClean: recentClean)
            guard !isArtifact[i] else { continue }
            recentClean.append(rrs[i])
            if recentClean.count > 5 { recentClean.removeFirst() }
        }
        return isArtifact
    }

    /// Implausible outright, or more than 20% off the running median of the
    /// last few clean beats.
    nonisolated private static func isArtifactBeat(_ rr: Double, recentClean: [Double]) -> Bool {
        let minRR: Double = 300 // >200 bpm — implausible
        let maxRR: Double = 2_000 // <30 bpm — implausible
        let ectopicRatio: Double = 0.20
        if rr < minRR || rr > maxRR { return true }
        guard recentClean.count >= 3 else { return false }
        let sorted = recentClean.sorted()
        let med = sorted[sorted.count / 2]
        return abs(rr - med) / med > ectopicRatio
    }

    /// Pass 2: replace artifact beats with linear interpolation from the
    /// nearest surrounding clean beats, preserving the series length so DFA
    /// window semantics don't shift.
    nonisolated private static func interpolatingArtifacts(_ rrs: [Double], isArtifact: [Bool]) -> [Double] {
        var out = rrs
        for i in 0 ..< rrs.count where isArtifact[i] {
            let leftIdx = stride(from: i - 1, through: 0, by: -1).first { !isArtifact[$0] }
            let rightIdx = ((i + 1) ..< rrs.count).first { !isArtifact[$0] }
            switch (leftIdx, rightIdx) {
            case let (l?, r?):
                out[i] = rrs[l] + (rrs[r] - rrs[l]) * Double(i - l) / Double(r - l)
            case let (l?, nil):
                out[i] = rrs[l]
            case let (nil, r?):
                out[i] = rrs[r]
            default:
                // Entire buffer is artifact — should never happen after the
                // minRR/maxRR gate, but guard for safety.
                break
            }
        }
        return out
    }

    private func refreshStatus(now: Date) {
        // Still warming up the window — on beats, elapsed time, or both.
        if !hasEnoughDataForFit {
            status = .warmup(fractionReady: bufferFillFraction)
            return
        }
        if let lastBeat = lastBeatAt {
            let silentFor = now.timeIntervalSince(lastBeat)
            if silentFor > cadenceSec * 2 {
                markStalled(silentFor: silentFor)
                return
            }
        }
        // `.ok` is conditioned on there BEING a value, so a window rejected for
        // artifact load keeps its `.tooManyArtifacts` caption until the next
        // recompute produces one — the same contract `.fitFailed` has.
        if currentAlpha1 != nil { status = .ok }
    }

    /// The strap has gone silent, so the displayed α1/band/fitQuality are
    /// nulled.
    ///
    /// If `currentAlpha1` retained its last computed value
    /// indefinitely, a strap that died mid-workout would leave a stale α1 number
    /// on screen for the rest of the session ("α1 showing a value
    /// during a strap-less workout when no RR data is available"). Silence beyond
    /// 2× cadence (40 s default) flips the display to "—" until fresh beats
    /// resume; the status stays `.stalled` so the caption explains why.
    private func markStalled(silentFor: TimeInterval) {
        status = .stalled(secondsSinceLastBeat: silentFor)
        guard currentAlpha1 != nil else { return }
        currentAlpha1 = nil
        currentBand = .unknown
        fitQuality = nil
    }

    private func band(for alpha1: Double) -> Band {
        switch alpha1 {
        case 0.85...: .belowAeT
        case 0.65 ..< 0.85: .nearAeT
        case 0.45 ..< 0.65: .nearVT2
        default: .aboveVT2
        }
    }
}
