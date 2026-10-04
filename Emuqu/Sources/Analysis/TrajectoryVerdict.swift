import Foundation

/// Surface 2 (Load & Trajectory) verdict + descriptor
/// data model. Calm planner voice, never red, never risk-prediction
/// language.
///
/// Three independent dimensions:
///   • `TrajectoryVerdict` — the nine-state verdict for the chip + header
///   • `FormDescriptor` — TSB descriptor (Fresh / Held / Working / Tired / Very tired)
///   • `RampBand` — ramp-rate band (Conservative / Standard / Rapid increase)
///
/// All three are observational. None use red. None use "danger." None use
/// "advisory." None feed the Recovery Score.
public enum TrajectoryVerdict: String, CaseIterable, Sendable {
    case building          // ↗ Building          — CTL rising at standard pace
    case rapidIncrease     // ↑ Rapid increase    — Ramp >8 TSS/d/wk
    case maintaining       // → Maintaining       — CTL flat
    case detraining        // ↘ Detraining        — CTL falling, no Comeback or Peaking mode
    case highStrain        // ↯ High strain       — TSB deeply negative (unintentional deep fatigue), whichever way CTL is moving; distinct from the intentional `.overreach` mode
    case peaking           // ▶ Peaking           — Taper detected (ATL < CTL by >10%, sustained 4+ days)
    case comeback          // 🌿 Comeback          — Comeback mode active
    case overreach         // 🎯 Overreach         — Intentional Overreach toggled on
    case buildingBaseline  // 📊 Building baseline — First 28 days, insufficient CTL

    /// Glyph + word, English, for the assistant's trajectory fact. Views show
    /// `localizedChipLabel`, and VoiceOver should read
    /// `localizedAccessibilityLabel`, which has no glyph.
    public var chipLabel: String {
        switch self {
        case .building:         "↗ Building"
        case .rapidIncrease:    "↑ Rapid increase"
        case .maintaining:      "→ Maintaining"
        case .detraining:       "↘ Detraining"
        case .highStrain:       "↯ High strain"
        case .peaking:          "▶ Peaking"
        case .comeback:         "🌿 Comeback"
        case .overreach:        "🎯 Overreach (intentional)"
        case .buildingBaseline: "📊 Building baseline"
        }
    }

    // The views' versions, in the app's language.

    public var localizedChipLabel: String {
        let b = LanguageManager.appBundle
        return switch self {
        case .building:         String(localized: "↗ Building", bundle: b)
        case .rapidIncrease:    String(localized: "↑ Rapid increase", bundle: b)
        case .maintaining:      String(localized: "→ Maintaining", bundle: b)
        case .detraining:       String(localized: "↘ Detraining", bundle: b)
        case .highStrain:       String(localized: "↯ High strain", bundle: b)
        case .peaking:          String(localized: "▶ Peaking", bundle: b)
        case .comeback:         String(localized: "🌿 Comeback", bundle: b)
        case .overreach:        String(localized: "🎯 Overreach (intentional)", bundle: b)
        case .buildingBaseline: String(localized: "📊 Building baseline", bundle: b)
        }
    }

    /// Single-sentence narrative for the Trajectory header. Observational,
    /// calm planner voice, ≤ one sentence.
    public var localizedNarrative: String {
        let b = LanguageManager.appBundle
        return switch self {
        case .building:         String(localized: "Your fitness is rising sustainably.", bundle: b)
        case .rapidIncrease:    String(localized: "Load is jumping fast — easy days help you absorb it.", bundle: b)
        case .maintaining:      String(localized: "You're holding fitness.", bundle: b)
        case .detraining:       String(localized: "Fitness is drifting down. Time to rebuild?", bundle: b)
        case .highStrain:       String(localized: "You're carrying heavy fatigue — that's high strain, not a plateau. Plan proper recovery.", bundle: b)
        case .peaking:          String(localized: "You're peaking. Form is good, fitness is held.", bundle: b)
        case .comeback:         String(localized: "You're rebuilding after a break — ease the load back in gradually.", bundle: b)
        case .overreach:        String(localized: "You're pushing on purpose — extra fatigue is expected.", bundle: b)
        case .buildingBaseline: String(localized: "We need a few more weeks of data to draw a full trajectory.", bundle: b)
        }
    }

    /// The verdict without its glyph, for VoiceOver.
    public var localizedAccessibilityLabel: String {
        let b = LanguageManager.appBundle
        return switch self {
        case .building:         String(localized: "Building. Your fitness is rising sustainably.", bundle: b)
        case .rapidIncrease:    String(localized: "Rapid increase. Load is jumping fast.", bundle: b)
        case .maintaining:      String(localized: "Maintaining. You're holding fitness.", bundle: b)
        case .detraining:       String(localized: "Detraining. Fitness is drifting down.", bundle: b)
        case .highStrain:       String(localized: "High strain. Carrying heavy fatigue. Plan recovery.", bundle: b)
        case .peaking:          String(localized: "Peaking. Form is good, fitness is held.", bundle: b)
        case .comeback:         String(localized: "Comeback mode. Rebuilding after a break.", bundle: b)
        case .overreach:        String(localized: "Intentional overreach. Pushing on purpose.", bundle: b)
        case .buildingBaseline: String(localized: "Building baseline. Trajectory not yet drawn.", bundle: b)
        }
    }

    /// Inputs needed by the canonical verdict computation. Keeps the
    /// surface area small so callers can pass a cache series directly.
    public struct Inputs {
        public let currentCTL: Double
        public let ctlOneWeekAgo: Double?  // nil when < 8 days of data
        public let sampleCount: Int
        public let comebackActive: Bool
        public let overreachActive: Bool
        public let peakingDetected: Bool
        public let rampRate: Double  // CTL points per week, from `ctlSlopePerWeek`
        /// Current TSB so the "Detraining" label can be
        /// suppressed when the user is clearly carrying fatigue.
        /// A user at TSB −25 isn't detraining — they're grinding.
        /// CTL noise that drags the slope slightly negative isn't
        /// "fitness drifting down" when ATL says they're hammered.
        /// Optional so existing callers still compile; nil means
        /// "don't gate on fatigue."
        public let currentTSB: Double?

        public init(
            currentCTL: Double,
            ctlOneWeekAgo: Double?,
            sampleCount: Int,
            comebackActive: Bool,
            overreachActive: Bool,
            peakingDetected: Bool,
            rampRate: Double,
            currentTSB: Double? = nil
        ) {
            self.currentCTL = currentCTL
            self.ctlOneWeekAgo = ctlOneWeekAgo
            self.sampleCount = sampleCount
            self.comebackActive = comebackActive
            self.overreachActive = overreachActive
            self.peakingDetected = peakingDetected
            self.rampRate = rampRate
            self.currentTSB = currentTSB
        }
    }

    /// TSB below which the trajectory reads `.highStrain` instead of
    /// "Maintaining", regardless of CTL direction. Set to −15 = the
    /// FormDescriptor "Working → Tired" boundary: at TSB < −15 the athlete is
    /// in "Tired"/"Very tired" form, a real hole that "Maintaining" hides.
    /// Tunable: lower toward −20/−25 to only flag a deeper hole.
    static let deepFatigueOverreachTSB: Double = -15

    /// TrainingPeaks-standard trailing window for the CTL trend. TP offers
    /// 7/28/90-day ramp views; the 7-day is the noisy one, so the trend is
    /// regressed over ~2 weeks — long enough that a negative slope means a
    /// *sustained* decline (Friel's definition of losing fitness), short
    /// enough to stay responsive.
    static let rampTrendWindowDays = 14

    /// CTL trend in CTL points per week: an ordinary-least-squares slope of
    /// the daily CTL values (oldest first) over the trailing
    /// `rampTrendWindowDays`, ×7. 0 below 8 days. Every surface that feeds
    /// `Inputs.rampRate` must use this: a 2-point `CTL_yesterday −
    /// CTL_8-days-ago` delta oscillates day to day for intermittent training
    /// (the lone anchor lands on a workout or a rest day) and flips the
    /// verdict, so the chip, the assistant and the Trajectory screen would
    /// disagree.
    public static func ctlSlopePerWeek(_ dailyCTL: [Double]) -> Double {
        guard dailyCTL.count >= 8 else { return 0 }
        let window = Array(dailyCTL.suffix(rampTrendWindowDays))
        let n = Double(window.count)
        let xMean = (n - 1) / 2
        let yMean = window.reduce(0, +) / n
        var num = 0.0
        var den = 0.0
        for (i, ctl) in window.enumerated() {
            let dx = Double(i) - xMean
            num += dx * (ctl - yMean)
            den += dx * dx
        }
        return den > 0 ? (num / den) * 7.0 : 0
    }

    /// Single source of truth for the trajectory verdict, used by
    /// `LoadTrajectoryView`, the Dashboard's Load chip and the assistant's
    /// trajectory fact. They agree when they pass the same `rampRate`
    /// (`ctlSlopePerWeek`) and series.
    ///
    /// - Mode toggles (comeback / overreach / peaking) win over
    ///   automatic interpretation.
    /// - Need ≥ 8 days of data to call any direction; under that we
    ///   say "buildingBaseline" rather than guess.
    /// - Direction is computed from the **CTL slope**, NOT a snapshot
    ///   threshold. A user with low CTL who is pushing daily reads as
    ///   "building," not "detraining" — detraining only fires when CTL is
    ///   actually FALLING.
    ///
    /// Direction is driven off `rampRate` (the same CTL trend the ramp-rate
    /// card displays) so the verdict and the ramp can never disagree on
    /// screen. A separately computed `currentCTL − ctlOneWeekAgo` delta has
    /// endpoints that don't match the ramp's, so a clearly-rising CTL (ramp
    /// +2.7) can read as "Maintaining". The delta survives only as a fallback
    /// for a caller passing rampRate == 0 with a real CTL change.
    ///
    /// DEEP acute fatigue overrides fitness-DIRECTION entirely, including a
    /// rising CTL: below the Tired/Working boundary the athlete is loading
    /// faster than they absorb, so both "Building" and "Maintaining" mislead.
    /// That check MUST precede the building gate; placed after it,
    /// a rising CTL at TSB −15.2 reads "Building" on the detail view while
    /// the dashboard chip reads "High strain".
    public static func compute(_ inputs: Inputs) -> TrajectoryVerdict {
        if inputs.comebackActive { return .comeback }
        if inputs.overreachActive { return .overreach }
        if inputs.peakingDetected { return .peaking }
        guard inputs.sampleCount > 7, let weekAgoCTL = inputs.ctlOneWeekAgo else {
            return .buildingBaseline
        }
        let delta = inputs.rampRate != 0 ? inputs.rampRate : (inputs.currentCTL - weekAgoCTL)
        if let tsb = inputs.currentTSB, tsb < deepFatigueOverreachTSB { return .highStrain }
        if delta > 1.5 { return inputs.rampRate > 8 ? .rapidIncrease : .building }
        return decliningVerdict(delta: delta, currentTSB: inputs.currentTSB)
    }

    /// Deadband for "Detraining". A marginally
    /// negative weekly ramp is "holding", not losing fitness: TrainingPeaks
    /// treats ~flat CTL as maintaining and Friel defines detraining as a
    /// sustained decline (a run of low/zero days). With the ramp a
    /// 14-day regression (`ctlSlopePerWeek`), −1.5/wk
    /// is a clear, sustained drop; −1 on a noisy 2-point delta flips the
    /// verdict day-to-day. Kept in lockstep with RampBand.
    private static func decliningVerdict(delta: Double, currentTSB: Double?) -> TrajectoryVerdict {
        let detrainingThreshold = -1.5
        guard delta < detrainingThreshold else { return .maintaining }
        // Moderate fatigue (deep-threshold … −5) with a
        // dipping CTL is grinding through real training, not detraining
        // (FormDescriptor "Working"). Keep "Maintaining" so a recovery-day
        // CTL dip doesn't cry "Detraining". Only a genuinely fresh athlete
        // (TSB ≥ −5) whose CTL is falling is actually detraining.
        if let tsb = currentTSB, tsb < -5 { return .maintaining }
        return .detraining
    }
}

/// TSB → form-descriptor mapping, replaces ACWR threshold language.
public enum FormDescriptor: String, CaseIterable, Sendable {
    case fresh       // > +10
    case held        // -5 to +10
    case working     // -15 to -5
    case tired       // -25 to -15
    case veryTired   // < -25

    public init(tsb: Double) {
        switch tsb {
        case let v where v > 10:   self = .fresh
        case let v where v >= -5:  self = .held
        case let v where v >= -15: self = .working
        case let v where v >= -25: self = .tired
        default:                   self = .veryTired
        }
    }

    /// Single-word descriptor, English, for the assistant facts.
    public var word: String {
        switch self {
        case .fresh:     "Fresh"
        case .held:      "Held"
        case .working:   "Working"
        case .tired:     "Tired"
        case .veryTired: "Very tired"
        }
    }

    /// `word` in the app language, for the stat card.
    public var localizedWord: String {
        let b = LanguageManager.appBundle
        return switch self {
        case .fresh:     String(localized: "Fresh", bundle: b)
        case .held:      String(localized: "Held", bundle: b)
        case .working:   String(localized: "Working", bundle: b)
        case .tired:     String(localized: "Tired", bundle: b)
        case .veryTired: String(localized: "Very tired", bundle: b)
        }
    }
}

/// Ramp-rate band — describes weekly CTL slope. No "danger" framing.
public enum RampBand: String, CaseIterable, Sendable {
    case detraining    // < -1.5 TSS/d/wk — load declining
    case holdingSteady // -1.5 … 1.5 TSS/d/wk — flat
    case conservative  // 1.5–3 TSS/d/wk
    case standard      // 3–8 TSS/d/wk
    case rapidIncrease // >8 TSS/d/wk

    // Bands branch on SIGN, not magnitude. A negative ramp
    // is detraining/decline, never "building gradually". Boundaries are
    // aligned with TrajectoryVerdict.compute (delta < -1.5 → detraining,
    // delta > 1.5 → building) so the ramp card can't contradict the header.
    public init(tssPerDayPerWeek: Double) {
        // "Easing down" boundary kept in lockstep with
        // TrajectoryVerdict's detraining deadband so the ramp card word and the
        // verdict chip can never contradict each other on screen.
        let easingThreshold = -1.5
        if tssPerDayPerWeek < easingThreshold { self = .detraining } else if tssPerDayPerWeek < 1.5 { self = .holdingSteady } else if tssPerDayPerWeek < 3 { self = .conservative } else if tssPerDayPerWeek < 8 { self = .standard } else { self = .rapidIncrease }
    }

    /// English, for the assistant facts; views use `localizedWord`.
    public var word: String {
        switch self {
        case .detraining:    "Easing down"
        case .holdingSteady: "Holding steady"
        case .conservative:  "Conservative"
        case .standard:      "Standard"
        case .rapidIncrease: "Rapid increase"
        }
    }

    public var localizedWord: String {
        let b = LanguageManager.appBundle
        return switch self {
        case .detraining:    String(localized: "Easing down", bundle: b)
        case .holdingSteady: String(localized: "Holding steady", bundle: b)
        case .conservative:  String(localized: "Conservative", bundle: b)
        case .standard:      String(localized: "Standard", bundle: b)
        case .rapidIncrease: String(localized: "Rapid increase", bundle: b)
        }
    }

    public var localizedSentence: String {
        let b = LanguageManager.appBundle
        return switch self {
        case .detraining:    String(localized: "Load is easing down — fitness will drift lower if this holds.", bundle: b)
        case .holdingSteady: String(localized: "You're holding load steady.", bundle: b)
        case .conservative:  String(localized: "You're building gradually.", bundle: b)
        case .standard:      String(localized: "You're building at standard pace.", bundle: b)
        case .rapidIncrease: String(localized: "Load is jumping fast — easy days help you absorb it.", bundle: b)
        }
    }
}
