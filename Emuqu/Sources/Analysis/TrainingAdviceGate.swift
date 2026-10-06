import Foundation

/// The one decision on how hard today's training advice may go. Every advice
/// surface asks it before it words a recommendation: the morning steps, the
/// recovery card message, the score detail's "What to do today", the workout
/// report's prescription tier, the Training Readiness card and Flo's context.
///
/// Recovery says whether the body is ready; the training load says whether it
/// is still absorbing recent work. A strong morning never cancels a load
/// reason, because HRV describes today and the load describes the past weeks.
///
/// Load rules, from the app's cited sources and Help:
/// - Acute:chronic ratio above 1.5 is a sharp increase over the usual range,
///   where "an easier session helps your body absorb the work" (Help, ACWR
///   Training Zones). 1.3–1.5 is above the usual range: normal training, but
///   no "go hard". The ratio counts only once the chronic load reaches the
///   level at which the readiness model trusts it (`ctlThreshold`); below
///   that one walk swings it.
/// - Training-load balance (CTL − ATL) at −15 or lower is heavy accumulated
///   fatigue, an easier session whatever the ratio.
/// - The Foster (1998) monotony warning (`FosterMonotonyWarning`, the rule
///   Load & Trajectory and the Training Load screen use) holds the push: a
///   heavy week of very same-y training is the accumulated-fatigue pattern.
enum TrainingAdviceGate {
    /// The training-load inputs the gate reads. A missing value never blocks,
    /// except that a missing chronic load leaves the ratio unqualified.
    struct Load: Sendable, Equatable {
        var acwr: Double?
        var ctl: Double?
        var tsb: Double?
        /// Foster monotony and strain of the last seven days.
        var monotony: Double?
        var strain: Double?
    }

    /// How far the load lets today's advice go, mildest first.
    enum LoadLevel: Int, Comparable, Sendable {
        /// Nothing in the load argues against a hard day.
        case clear
        /// Normal training is fine; no "go hard".
        case holdPush
        /// An easier session helps the body absorb the work.
        case easier

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Why the load holds the advice back, for the surfaces that explain it.
    enum Reason: Sendable, Equatable {
        case sharpIncrease
        case heavyFatigue
        case aboveUsual
        case monotonous
    }

    struct Assessment: Sendable, Equatable {
        let level: LoadLevel
        let reasons: [Reason]

        static let clear = Assessment(level: .clear, reasons: [])
    }

    /// TSB at or below this is heavy accumulated fatigue.
    static let heavyFatigueTSB = -15.0

    // MARK: - Decision

    static func assess(_ load: Load?) -> Assessment {
        guard let load else { return .clear }
        let reasons = ratioReasons(load) + fatigueReasons(load) + monotonyReasons(load)
        let level: LoadLevel = reasons.contains { $0 == .sharpIncrease || $0 == .heavyFatigue }
            ? .easier
            : (reasons.isEmpty ? .clear : .holdPush)
        return Assessment(level: level, reasons: reasons)
    }

    static func level(_ load: Load?) -> LoadLevel {
        assess(load).level
    }

    /// The highest advice the morning allows: a hard day needs a well-recovered
    /// score (`scoreWellRecovered`) and a clear load.
    static func allowsPush(recoveryScore: Double, load: Load?) -> Bool {
        recoveryScore >= HRVThresholds.scoreWellRecovered && level(load) == .clear
    }

    /// A chronic load under `ctlThreshold` makes the ratio noise; a caller
    /// that has the ratio but not the chronic load gets the ratio read as is.
    private static func ratioReasons(_ load: Load) -> [Reason] {
        guard let acwr = load.acwr, acwr.isFinite,
              (load.ctl ?? .infinity) >= RecoveryScoreConstants.Readiness.ctlThreshold
        else { return [] }
        switch ACWRBand(ratio: acwr) {
        case .sharpIncrease: return [.sharpIncrease]
        case .aboveUsual: return [.aboveUsual]
        case .belowUsual, .maintenance, .inRange: return []
        }
    }

    private static func fatigueReasons(_ load: Load) -> [Reason] {
        guard let tsb = load.tsb, tsb.isFinite, tsb <= heavyFatigueTSB else { return [] }
        return [.heavyFatigue]
    }

    private static func monotonyReasons(_ load: Load) -> [Reason] {
        guard let monotony = load.monotony, let strain = load.strain,
              FosterMonotonyWarning.isRaised((monotony: monotony, strain: strain))
        else { return [] }
        return [.monotonous]
    }
}

// MARK: - Building the load from each source

extension TrainingAdviceGate.Load {
    /// The live load every "right now" surface reads.
    init(live: TrainingLoadRegistry.TrainingLoad) {
        self.init(acwr: live.acwr, ctl: live.ctl, tsb: live.tsb, monotony: live.monotony, strain: live.strain)
    }

    /// A session's frozen training context, for advice about that morning.
    init(context: TrainingContext) {
        self.init(acwr: context.acuteChronicRatio, ctl: context.ctl, tsb: context.tsb, monotony: nil, strain: nil)
    }

    /// The full metrics, which carry the daily TRIMP Foster monotony needs.
    init(metrics: TrainingMetrics, referenceDate: Date = Date()) {
        let foster = RecoveryScoreCalculator.fosterMonotonyStrain(dailyTrimp: metrics.dailyTrimp, referenceDate: referenceDate)
        self.init(
            acwr: metrics.acuteChronicRatio, ctl: metrics.ctl, tsb: metrics.tsb,
            monotony: foster?.monotony, strain: foster?.strain
        )
    }

    /// Live first, the frozen context when the live cache is cold.
    static func preferring(live: TrainingLoadRegistry.TrainingLoad?, frozen: TrainingContext?) -> Self? {
        if let live { return Self(live: live) }
        return frozen.map { Self(context: $0) }
    }
}

// MARK: - Copy

extension TrainingAdviceGate.Assessment {
    /// One sentence naming the load reason that matters most, in `bundle`'s
    /// language. Nil when the load is clear.
    func reasonLine(bundle: Bundle) -> String? {
        if level == .easier {
            return String(localized: "Recent load is above your usual range — a lighter session helps you absorb the work.", bundle: bundle)
        }
        if reasons.contains(.aboveUsual) {
            return String(localized: "Recent load is above average — listen to your body.", bundle: bundle)
        }
        if reasons.contains(.monotonous) {
            return String(localized: "Your training has been unusually similar day-to-day this week", bundle: bundle)
        }
        return nil
    }
}
