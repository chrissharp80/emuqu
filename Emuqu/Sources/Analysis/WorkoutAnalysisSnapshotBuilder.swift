import Foundation

// MARK: - WorkoutAnalysisSnapshotBuilder
//
// Pure-function pipeline that turns the session's raw sample stream +
// metadata context into a persistable `WorkoutAnalysisSnapshot`. One
// pass over `samples[]` computes every derivation the UI and the PDF
// surface, so neither SwiftUI re-renders nor the PDF generator ever
// need to iterate the raw array again.
//
// Single responsibility: take observed values in, produce analytic
// derivatives out. No I/O, no side effects, safe to call from any
// thread.
enum WorkoutAnalysisSnapshotBuilder {
    /// Inputs bundle — makes the signature readable without a
    /// proliferation of positional args.
    struct Inputs {
        let sport: Sport
        let durationSec: TimeInterval
        let distanceMeters: Double?
        let elevationGainMeters: Double?
        let elevationLossMeters: Double?
        let meanHR: Double?
        let userMaxHR: Int
        let bodyWeightKg: Double
        let samples: [WorkoutSample]
        let splits: [Split]
        let trimp: Double?
        let decouplingPercent: Double?
    }

    /// Everything the single pass over `samples` accumulates. Bundled so the
    /// pass can be lifted out of `build` without turning into a fifteen-value
    /// tuple return.
    private struct SamplePass {
        var secondsBelowAT1 = 0
        var secondsBetweenThresholds = 0
        var secondsAboveAT2 = 0
        var alphaSum = 0.0
        var alphaCount = 0
        var alphaMin = Double.infinity
        var alphaMax = -Double.infinity
        var firstCrossOffset: Int?
        var firstCrossHR: Int?
        var zoneSecs = [0, 0, 0, 0, 0]
        var metsSum = 0.0
        var metsCount = 0
        var cadenceSum = 0.0
        var cadenceCount = 0
        var movingSec = 0

        /// α1 band split at the two aerobic thresholds: at or above 0.75 is
        /// below AT1, 0.50–0.75 sits between the thresholds, under 0.50 is
        /// above AT2.
        mutating func addAlphaBandTime(_ dt: Int, forAlpha1 a: Double) {
            if a >= 0.75 {
                secondsBelowAT1 += dt
            } else if a >= 0.50 {
                secondsBetweenThresholds += dt
            } else {
                secondsAboveAT2 += dt
            }
        }

        /// Five HR zones by percentage of max: 50-60 / 60-70 / 70-80 /
        /// 80-90 / 90+. Anything under 50 % is not counted as zone time.
        mutating func addZoneTime(_ dt: Int, heartRate hr: Int, maxHR: Int) {
            switch Double(hr) / Double(maxHR) {
            case ..<0.50: break
            case 0.50 ..< 0.60: zoneSecs[0] += dt
            case 0.60 ..< 0.70: zoneSecs[1] += dt
            case 0.70 ..< 0.80: zoneSecs[2] += dt
            case 0.80 ..< 0.90: zoneSecs[3] += dt
            default: zoneSecs[4] += dt
            }
        }
    }

    /// One pass over the sample stream, accumulating every per-sample
    /// derivation the snapshot needs. Extracted from `build` verbatim — the
    /// arithmetic and the ordering are unchanged; only the accumulators moved
    /// from local `var`s into `SamplePass` so `build` reads as the four steps
    /// it always was: scan, summarise, narrate, assemble.
    private static func scan(samples: [WorkoutSample], userMaxHR: Int) -> SamplePass {
        var pass = SamplePass()
        var cross = AT1CrossDetector()
        var lastOffset = 0
        let maxHR = max(userMaxHR, 1)
        for s in samples {
            let dt = max(1, s.offsetSec - lastOffset)
            lastOffset = s.offsetSec
            accumulate(s, dt: dt, maxHR: maxHR, into: &pass, cross: &cross)
        }
        return pass
    }

    private static func accumulate(
        _ s: WorkoutSample,
        dt: Int,
        maxHR: Int,
        into pass: inout SamplePass,
        cross: inout AT1CrossDetector
    ) {
        accumulateAlpha1(s, dt: dt, into: &pass, cross: &cross)
        // HR zone buckets (50-60 / 60-70 / 70-80 / 80-90 / 90+)
        if let hr = s.heartRate {
            pass.addZoneTime(dt, heartRate: hr, maxHR: maxHR)
        }
        if let m = s.mets {
            pass.metsSum += m
            pass.metsCount += 1
        }
        if let c = s.cadenceStepsPerMin, c > 0 {
            pass.cadenceSum += c
            pass.cadenceCount += 1
        }
        if isMoving(s) { pass.movingSec += dt }
    }

    private static func accumulateAlpha1(
        _ s: WorkoutSample,
        dt: Int,
        into pass: inout SamplePass,
        cross: inout AT1CrossDetector
    ) {
        guard let a = s.alpha1 else { return }
        pass.alphaSum += a
        pass.alphaCount += 1
        if a < pass.alphaMin { pass.alphaMin = a }
        if a > pass.alphaMax { pass.alphaMax = a }
        pass.addAlphaBandTime(dt, forAlpha1: a)
        cross.consume(alpha1: a, sample: s, dt: dt, into: &pass)
    }

    /// "Moving" is the OR of three independent signals. `paceSecPerKm` alone
    /// is not enough: it is gated on a 2.5-m-per-1-s GPS distance delta
    /// upstream. A casual 3-mph walk covers ~1.3 m/s, so most pace samples
    /// come back nil and the moving-time percentage reads absurdly low ("32 %"
    /// for a 100 %-active walk). Counting cadence above a floor, and any HR
    /// reading, catches active-but-slow movement GPS alone can't resolve. 50 spm
    /// is the floor below which the user really was stationary (a shuffle).
    private static func isMoving(_ s: WorkoutSample) -> Bool {
        (s.paceSecPerKm ?? 0) > 0
            || (s.cadenceStepsPerMin ?? 0) >= 50
            || ((s.heartRate ?? 0) > 0 && (s.alpha1 != nil || s.mets != nil))
    }

    /// Sustained-cross detection for the α1 = 0.75 aerobic threshold.
    ///
    /// The rolling α1 buffer is still filling during the first ~2 minutes of a
    /// workout and frequently dips below 0.75 transiently before stabilising,
    /// so a crossing only counts after the warmup window AND after the sub-0.75
    /// state has persisted for `sustainSec`.
    ///
    /// The sustain length is deliberately longer than the α1 rolling window
    /// (120 s). A single ectopic beat contaminates the window for exactly the
    /// window's length — so a sustained sub-0.75 lasting longer than 120 s
    /// cannot be an ectopic shadow, it has to be a real effort. 180 s also
    /// matches the >= 3-min phase length Rogers & Gronwald's original
    /// ramp-protocol validation uses. A shorter sustain (30 s was tried first)
    /// leaked ectopic-shadow crossings through on clean Zone-1 walks — the
    /// 2026-04 user report "my α1 LT1 says 121 bpm on a 120 bpm walk because of
    /// one ectopic beat."
    private struct AT1CrossDetector {
        private let warmupSec = 120
        private let sustainSec = 180
        private var sustainedBelowSec = 0
        private var pendingOffset: Int?
        private var pendingHR: Int?

        mutating func consume(alpha1 a: Double, sample s: WorkoutSample, dt: Int, into pass: inout SamplePass) {
            guard pass.firstCrossOffset == nil, s.offsetSec >= warmupSec else { return }
            guard a < 0.75 else {
                sustainedBelowSec = 0
                pendingOffset = nil
                pendingHR = nil
                return
            }
            if pendingOffset == nil {
                pendingOffset = s.offsetSec
                pendingHR = s.heartRate
            }
            sustainedBelowSec += dt
            guard sustainedBelowSec >= sustainSec else { return }
            pass.firstCrossOffset = pendingOffset
            pass.firstCrossHR = pendingHR
        }
    }

    static func build(_ inputs: Inputs) -> WorkoutAnalysisSnapshot {
        snapshot(inputs, derived: derive(inputs))
    }

    /// Everything one pass over the samples produces, before it is shaped into
    /// the snapshot the UI reads.
    ///
    /// A parameter object for `snapshot` rather than eleven arguments under a
    /// `function_parameter_count` waiver. `snapshot` is `private
    /// static` with one caller, so this is not a public-signature change — and
    /// every one of these fields is already a local in `build`, computed
    /// together and used together.
    private struct Derived {
        let pass: SamplePass
        let below: Int
        let btwn: Int
        let above: Int
        let zoneSecs: [Int]
        let zoneTotal: Int
        let dominantZone: (Int?, Int?)
        let splits: ((Split, Double)?, (Split, Double)?)
        let energy: EnergyEconomy
        let narratives: (hero: String, howYouDid: String)
    }

    private static func derive(_ inputs: Inputs) -> Derived {
        let pass = scan(samples: inputs.samples, userMaxHR: inputs.userMaxHR)
        let below = pass.secondsBelowAT1
        let btwn = pass.secondsBetweenThresholds
        let above = pass.secondsAboveAT2
        let zoneSecs = pass.zoneSecs
        let zoneTotal = zoneSecs.reduce(0, +)
        return Derived(
            pass: pass, below: below, btwn: btwn, above: above,
            zoneSecs: zoneSecs, zoneTotal: zoneTotal,
            dominantZone: dominantZone(zoneSecs: zoneSecs, zoneTotal: zoneTotal),
            splits: fastestAndSlowestSplits(inputs.splits),
            energy: energyAndEconomy(inputs, pass: pass),
            narratives: buildNarratives(
                inputs, below: below, btwn: btwn, above: above,
                alphaTotal: below + btwn + above, pass: pass
            )
        )
    }

    private static func snapshot(_: Inputs, derived: Derived) -> WorkoutAnalysisSnapshot {
        let (pass, energy, narratives) = (derived.pass, derived.energy, derived.narratives)
        let (below, btwn, above) = (derived.below, derived.btwn, derived.above)
        let (fastest, slowest) = derived.splits
        let alphaTotal = below + btwn + above
        return WorkoutAnalysisSnapshot(
            alpha1Mean: pass.alphaCount > 0 ? pass.alphaSum / Double(pass.alphaCount) : nil,
            alpha1Max: pass.alphaCount > 0 ? pass.alphaMax : nil, alpha1Min: pass.alphaCount > 0 ? pass.alphaMin : nil,
            secondsBelowAT1: alphaSeconds(below, total: alphaTotal), secondsBetweenAT1AT2: alphaSeconds(btwn, total: alphaTotal),
            secondsAboveAT2: alphaSeconds(above, total: alphaTotal),
            firstAT1CrossingOffsetSec: pass.firstCrossOffset, firstAT1CrossingHR: pass.firstCrossHR,
            dominantAlpha1BandRaw: dominantAlpha1Band(below: below, btwn: btwn, above: above), hrZoneSeconds: derived.zoneTotal > 0 ? derived.zoneSecs : nil,
            dominantHRZone: derived.dominantZone.0, dominantHRZonePercent: derived.dominantZone.1,
            fastestSplitIndex: fastest?.0.index, fastestSplitPaceSecPerKm: fastest?.1, slowestSplitIndex: slowest?.0.index, slowestSplitPaceSecPerKm: slowest?.1,
            movingTimeSec: pass.movingSec, movingTimePercent: energy.movingPercent, vamMetersPerHour: energy.vam,
            calorieRatePerHour: energy.caloriePerHour, estimatedTotalCalories: energy.totalCalories, strideLengthMeters: energy.strideLen,
            powerHRRatio: nil, // wired at caller when avgPower is available
            gradeAdjustedPaceSecPerKm: energy.gapSecPerKm, relativeEffortLabel: nil,
            howYouDidNarrative: narratives.howYouDid, heroNarrative: narratives.hero
        )
    }

    /// Alpha-1 seconds are reported only when the workout produced any — a
    /// workout with no α1 stream must read "not measured", never "0 s below".
    private static func alphaSeconds(_ value: Int, total: Int) -> Int? {
        total > 0 ? value : nil
    }

    /// The two plain-English readouts the summary card and the hero line show.
    private static func buildNarratives(
        _ inputs: Inputs,
        below: Int, btwn: Int, above: Int,
        alphaTotal: Int,
        pass: SamplePass
    ) -> (hero: String, howYouDid: String) {
        let heroNarrative = buildHeroNarrative(
            durationMin: Int(inputs.durationSec / 60),
            below: below, btwn: btwn, above: above,
            firstCrossOffset: pass.firstCrossOffset, firstCrossHR: pass.firstCrossHR
        )
        let howYouDid = buildHowYouDidNarrative(
            bands: Alpha1BandMinutes(
                total: Int(inputs.durationSec / 60),
                below: below, between: btwn, above: above, alphaTotal: alphaTotal
            ),
            decouplingPercent: inputs.decouplingPercent,
            durationSec: inputs.durationSec,
            trimp: inputs.trimp,
            elevationGain: inputs.elevationGainMeters
        )
        return (heroNarrative, howYouDid)
    }

    /// The zone that took the most time, and its share, as (1-based index, %).
    private static func dominantZone(zoneSecs: [Int], zoneTotal: Int) -> (Int?, Int?) {
        guard zoneTotal > 0,
              let (maxIdx, _) = zoneSecs.enumerated().max(by: { $0.element < $1.element })
        else { return (nil, nil) }
        return (maxIdx + 1, Int(Double(zoneSecs[maxIdx]) / Double(zoneTotal) * 100))
    }

    /// Splits that recorded a pace, ranked. Splits without one can't be
    /// compared and are excluded rather than treated as infinitely slow.
    private static func fastestAndSlowestSplits(_ splits: [Split]) -> ((Split, Double)?, (Split, Double)?) {
        let paced = splits.compactMap { s -> (Split, Double)? in
            guard let p = s.averagePaceSecPerKm, p > 0 else { return nil }
            return (s, p)
        }
        return (paced.min(by: { $0.1 < $1.1 }), paced.max(by: { $0.1 < $1.1 }))
    }

    // MARK: - Private helpers

    /// Calorie, movement, climb-rate and economy derivations. Split out of
    /// `build` unchanged — these six all read from the same duration and the
    /// same pass totals, so they belong together and nothing else needs them.
    private struct EnergyEconomy {
        let caloriePerHour: Double?
        let totalCalories: Double?
        let movingPercent: Int?
        let vam: Double?
        let strideLen: Double?
        let gapSecPerKm: Double?
    }

    private static func energyAndEconomy(_ inputs: Inputs, pass: SamplePass) -> EnergyEconomy {
        let avgMETs: Double? = pass.metsCount > 0 ? pass.metsSum / Double(pass.metsCount) : nil
        let durationHours = inputs.durationSec / 3_600.0
        let caloriePerHour: Double? = avgMETs.map { $0 * inputs.bodyWeightKg }
        return EnergyEconomy(
            caloriePerHour: caloriePerHour,
            totalCalories: caloriePerHour.map { $0 * durationHours },
            movingPercent: movingPercent(inputs, pass: pass),
            vam: vam(inputs, durationHours: durationHours),
            strideLen: strideLength(
                distanceMeters: inputs.distanceMeters, durationSec: inputs.durationSec,
                cadenceSum: pass.cadenceSum, cadenceCount: pass.cadenceCount
            ),
            gapSecPerKm: gradeAdjustedPace(
                durationSec: inputs.durationSec, distanceMeters: inputs.distanceMeters,
                elevGain: inputs.elevationGainMeters, elevLoss: inputs.elevationLossMeters
            )
        )
    }

    /// `movingSec` accumulates seconds (via `dt`), not sample count, so it is
    /// normalized against duration. Clamped to 100 % so a noisy sample-gap
    /// doesn't produce more.
    private static func movingPercent(_ inputs: Inputs, pass: SamplePass) -> Int? {
        guard inputs.durationSec > 10 else { return nil }
        let pct = Double(pass.movingSec) / inputs.durationSec * 100.0
        return Int(min(100, max(0, pct)))
    }

    /// Vertical ascent metres per hour. Needs a real climb over a real
    /// duration, otherwise the rate is meaningless.
    private static func vam(_ inputs: Inputs, durationHours: Double) -> Double? {
        guard let gain = inputs.elevationGainMeters, gain > 10, inputs.durationSec > 60 else { return nil }
        return gain / max(0.001, durationHours)
    }

    private static func dominantAlpha1Band(below: Int, btwn: Int, above: Int) -> String? {
        let m = max(below, max(btwn, above))
        guard m > 0 else { return nil }
        if below == m { return "belowAeT" }
        if btwn == m { return "nearAeT" }
        return "aboveVT2"  // collapsing hard-ish bands together for the pill colour
    }

    private static func strideLength(
        distanceMeters: Double?,
        durationSec: TimeInterval,
        cadenceSum: Double,
        cadenceCount: Int
    ) -> Double? {
        guard let dist = distanceMeters, dist > 100,
              durationSec > 60, cadenceCount > 0 else { return nil }
        let avgCad = cadenceSum / Double(cadenceCount)
        let totalSteps = avgCad * (durationSec / 60.0)
        guard totalSteps > 0 else { return nil }
        return dist / (totalSteps / 2.0)
    }

    private static func gradeAdjustedPace(
        durationSec: TimeInterval,
        distanceMeters: Double?,
        elevGain: Double?,
        elevLoss: Double?
    ) -> Double? {
        guard durationSec > 300, let dist = distanceMeters, dist > 500 else { return nil }
        let avgPace = durationSec / (dist / 1_000)
        let netGainRatio = ((elevGain ?? 0) - (elevLoss ?? 0)) / dist
        let avgGrade = netGainRatio * 100.0
        return avgPace - 2.0 * avgGrade
    }

    private static func buildHeroNarrative(
        durationMin: Int,
        below: Int, btwn: Int, above: Int,
        firstCrossOffset: Int?, firstCrossHR: Int?
    ) -> String {
        guard durationMin > 0 else { return "" }
        let alphaTotal = below + btwn + above
        guard alphaTotal > 0 else {
            return "\(durationMin) minutes of movement. α1 not captured — strap data unavailable."
        }
        if btwn == 0, above == 0 {
            return "\(durationMin) min aerobic-base work — α1 stayed above threshold the whole time. Ideal Zone-2 session."
        }
        if below == 0, btwn == 0 {
            return "\(durationMin) min above anaerobic threshold. Very high cost — short, intense effort profile."
        }
        if let c = firstCrossOffset {
            let mm = c / 60, ss = c % 60
            let hrPart = firstCrossHR.map { " at \($0) bpm" } ?? ""
            if above > 0 {
                return "Crossed aerobic threshold at \(mm):\(String(format: "%02d", ss))\(hrPart). \(above / 60) min above LT2. Mixed-intensity session."
            }
            return "Crossed aerobic threshold at \(mm):\(String(format: "%02d", ss))\(hrPart). \(btwn / 60) min at threshold, \(below / 60) min easy."
        }
        return "\(durationMin) min · Easy \(below / 60)m · Threshold \(btwn / 60)m · Hard \(above / 60)m."
    }

    /// Minutes spent in each α1 band. `total` is the whole session; `alphaTotal`
    /// is how much of it produced an α1 reading at all.
    struct Alpha1BandMinutes {
        let total: Int
        let below: Int
        let between: Int
        let above: Int
        let alphaTotal: Int
    }

    private static func buildHowYouDidNarrative(
        bands: Alpha1BandMinutes,
        decouplingPercent: Double?,
        durationSec: TimeInterval,
        trimp: Double?,
        elevationGain: Double?
    ) -> String {
        var parts: [String] = []
        if bands.alphaTotal > 0 {
            parts.append(intensitySentence(
                totalMin: bands.total, below: bands.below, btwn: bands.between, above: bands.above
            ))
        }
        if let decoupling = decouplingPercent, durationSec >= 600 {
            parts.append(decouplingSentence(decoupling))
        }
        if let trimp { parts.append(trimpSentence(trimp)) }
        if let gain = elevationGain, gain >= 30 {
            parts.append("Climbed \(Int(gain * UnitConstants.feetPerMeter)) ft.")
        }
        return parts.joined(separator: " ")
    }

    private static func trimpSentence(_ trimp: Double) -> String {
        if trimp >= 150 { return "TRIMP \(Int(trimp)) — heavy session." }
        if trimp >= 80 { return "TRIMP \(Int(trimp)) — moderate load." }
        return "TRIMP \(Int(trimp)) — light load."
    }

    /// How the session's time split across the two thresholds.
    private static func intensitySentence(totalMin: Int, below: Int, btwn: Int, above: Int) -> String {
        if btwn == 0, above == 0 {
            return "Solid aerobic-base effort — α1 stayed above threshold for the full \(totalMin) min."
        } else if below == 0, btwn == 0 {
            return "Hard session — you were above anaerobic threshold the whole time (\(above / 60) min at α1 < 0.50)."
        } else if above > 0 {
            return "Mixed-intensity: \(below / 60) min easy, \(btwn / 60) min threshold, \(above / 60) min above anaerobic threshold."
        } else {
            return "Threshold workout — you pushed into the LT1-LT2 band for \(btwn / 60) min, easy the remaining \(below / 60) min."
        }
    }

    private static func decouplingSentence(_ decoupling: Double) -> String {
        if decoupling < 5 {
            return "Pa:Hr decoupling stayed at \(String(format: "%+.1f %%", decoupling)) — strong aerobic efficiency."
        } else if decoupling < 8 {
            return "Pa:Hr decoupling \(String(format: "%+.1f %%", decoupling)) — mild drift; worth watching for hydration / fuel."
        } else {
            return "Pa:Hr decoupling \(String(format: "%+.1f %%", decoupling)) — notable efficiency loss."
        }
    }
}
