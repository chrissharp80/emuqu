import Foundation

/// Pure heat-acclimatization model.
///
/// # What this computes
///
/// A 0–100 "% heat-acclimatized" state estimating how adapted the user is
/// to exercising in the heat, plus how much more heat exposure they need
/// to reach a target. This is the Garmin "Heat Acclimation" capability,
/// rebuilt from the physiology literature rather than reverse-engineered.
///
/// # The physiology (citations)
///
/// Repeated exercise in the heat drives adaptations — plasma-volume
/// expansion (~10–12%), lowered exercising heart rate, lowered core/skin
/// temperature, and increased sweat rate — that make a given effort in the
/// heat feel easier and protect performance.
///   • Onset: heart-rate adaptation is essentially complete by ~7 days,
///     sweat-rate adaptation by 10–14 days; "full" acclimatization is
///     reached in ~10–14 days of repeated exposure.
///     Ref: Périard JD et al. 2015 Scand J Med Sci Sports 25(S1):20-38;
///          Tyler CJ et al. 2016 Sports Med 46(11):1699-1724;
///          time-course: Waldron M et al. 2024 Temperature 11(3):223-241.
///   • Decay: in the absence of heat exposure, adaptations fade at roughly
///     2.5% per day — ~30% of the heart-rate adaptation is lost after two
///     weeks, and acclimatization is mostly gone within a month. The
///     fastest-acquired adaptations (plasma volume, exercising HR) decay
///     first.
///     Ref: Daanen HAM, Racinais S, Périard JD. 2018 Sports Med
///          48(2):409-430 (decay meta-analysis); Garrett AT et al. 2009.
///   • Stimulus threshold: a meaningful heat stimulus requires training in
///     the heat; Garmin begins tracking heat acclimation above ~22 °C air
///     temperature. Humidity matters independently because it impairs
///     evaporative (sweat) cooling, so we score heat stress with a
///     humidity-aware index (WBGT), not air temperature alone.
///     Ref: Garmin "Heat & Altitude Acclimation" (running science);
///          Racinais S et al. 2015 Br J Sports Med 49(18):1164 (consensus).
///
/// # The model
///
/// An asymmetric first-order (Banister-EWMA) system — the same family the
/// app already uses for CTL/ATL training load — because heat adaptation is
/// a classic exposure-driven gain with exponential decay. Each day:
///   • exposure days move the state toward a dose-scaled ceiling at the
///     induction rate (τ ≈ 5 days);
///   • non-exposure days decay the state toward zero at ~2.5%/day.
/// Induction is faster than decay, matching the literature (gain in 1–2
/// weeks, loss over 3–4 weeks).
///
/// Every constant lives in `HeatConstants` (Constants.swift) with its
/// citation. This type holds no state and performs no I/O — it is a pure
/// transform over value inputs, fully unit-tested.
enum HeatAcclimation {
    // MARK: - Heat stress (humidity-aware)

    /// Saturation water-vapour pressure (hPa) at air temperature `tempC`,
    /// via the Magnus-Tetens approximation. Used to fold relative humidity
    /// into a real heat-stress measure.
    /// Ref: Alduchov OA, Eskridge RE. 1996 J Appl Meteorol 35(4):601-609.
    static func saturationVaporPressure(tempC: Double) -> Double {
        6.105 * Foundation.exp(17.27 * tempC / (237.7 + tempC))
    }

    /// Estimated shade Wet Bulb Globe Temperature (°C) from air temperature
    /// and relative humidity. The Australian Bureau of Meteorology simplified
    /// approximation: `WBGT ≈ 0.567·Tₐ + 0.393·e + 3.94`, where `e` is the
    /// water-vapour pressure (hPa). This is the standard shade-WBGT proxy
    /// when globe (solar) and wind terms aren't measured; it is humidity-
    /// aware, which air temperature and most "feels-like" running indices
    /// are not.
    /// Ref: Australian Bureau of Meteorology, "Thermal Comfort: WBGT";
    ///      ACSM 2007 position stand (Armstrong LE et al.).
    /// - Parameters:
    ///   - tempC: air temperature in °C.
    ///   - relativeHumidity: 0–100 (%).
    static func wbgtEstimate(tempC: Double, relativeHumidity: Double) -> Double {
        let rh = min(max(relativeHumidity, 0), 100)
        let e = (rh / 100.0) * saturationVaporPressure(tempC: tempC)
        return 0.567 * tempC + 0.393 * e + 3.94
    }

    // MARK: - Per-session heat dose

    /// One heat-exposure session: how hot it was and how long.
    struct Exposure: Equatable {
        /// Air temperature (°C) at the session.
        let tempC: Double
        /// Relative humidity (0–100 %).
        let relativeHumidity: Double
        /// Active duration in minutes.
        let durationMinutes: Double
    }

    /// The 0–1 "stimulus quality" of a single session — how strongly it
    /// would drive heat adaptation if repeated. Combines heat severity
    /// (WBGT above the stimulus threshold, saturating) with a duration
    /// factor (a real heat stimulus needs sustained exposure; a 10-minute
    /// stroll in the heat barely counts, an hour is a full stimulus).
    /// Returns 0 for sub-threshold (cool) sessions.
    static func sessionStimulus(_ exposure: Exposure) -> Double {
        let wbgt = wbgtEstimate(tempC: exposure.tempC, relativeHumidity: exposure.relativeHumidity)
        let over = wbgt - HeatConstants.stimulusWBGTThreshold
        guard over > 0 else { return 0 }

        // Severity saturates: once WBGT is `severitySpanC` above threshold,
        // the session is maximally hot for adaptation purposes — hotter
        // than that is dangerous, not more adaptive.
        let severity = min(over / HeatConstants.severitySpanC, 1.0)

        // Duration factor saturates at `fullStimulusMinutes`. Below
        // `minStimulusMinutes` the exposure is too brief to count.
        guard exposure.durationMinutes >= HeatConstants.minStimulusMinutes else { return 0 }
        let durationFactor = min(exposure.durationMinutes / HeatConstants.fullStimulusMinutes, 1.0)

        return severity * durationFactor
    }

    /// Combine a day's sessions into a single 0–1 daily stimulus. Multiple
    /// hot sessions in a day add up but saturate at 1 (one good hot hour is
    /// already a full daily stimulus; a second doesn't double the adaptive
    /// signal).
    static func dailyStimulus(_ exposures: [Exposure]) -> Double {
        let total = exposures.reduce(0.0) { $0 + sessionStimulus($1) }
        return min(total, 1.0)
    }

    // MARK: - Daily replay (the acclimation state)

    /// One day of the model's input: the date and that day's combined
    /// heat stimulus (0–1, from `dailyStimulus`).
    struct DayInput: Equatable {
        let date: Date
        let stimulus: Double
    }

    /// One day of the model's output.
    struct DaySample: Equatable {
        let date: Date
        /// Acclimatization state, 0–100 (%).
        let level: Double
        /// That day's combined heat stimulus, 0–1.
        let stimulus: Double
    }

    /// Replay daily stimulus forward into the acclimatization state, exactly
    /// mirroring the app's CTL/ATL EWMA replay (zero seed, forward iteration
    /// over sorted, gap-filled days). `days` must already be gap-filled —
    /// every calendar day in the window present, sub-threshold/rest days
    /// carrying `stimulus == 0` so they decay correctly. A missing day would
    /// hold the level artificially high (the same trap documented for the
    /// training-load series).
    ///
    /// Update rule per day:
    ///   • stimulus > 0:  level ← ceiling·k_ind + level·(1 − k_ind)
    ///                    where ceiling = 100·stimulus (a marginal hot day
    ///                    tops out partially; a strong one drives toward 100)
    ///   • stimulus == 0: level ← level·(1 − k_decay)
    static func replay(_ days: [DayInput]) -> [DaySample] {
        let kInduction = HeatConstants.inductionRatePerDay
        let kDecay = HeatConstants.decayRatePerDay
        let sorted = days.sorted { $0.date < $1.date }
        var level = 0.0
        var out: [DaySample] = []
        out.reserveCapacity(sorted.count)
        for day in sorted {
            if day.stimulus > 0 {
                let ceiling = 100.0 * day.stimulus
                level = ceiling * kInduction + level * (1 - kInduction)
            } else {
                level *= (1 - kDecay)
            }
            out.append(DaySample(date: day.date, level: level, stimulus: day.stimulus))
        }
        return out
    }

    // MARK: - Readout

    /// Plain-language acclimatization bands.
    enum Band: String, Codable, Equatable {
        case notAcclimated
        case partial
        case wellAcclimated
        case fullyAcclimated

        var label: String {
            switch self {
            case .notAcclimated: "Not heat-acclimated"
            case .partial: "Partially acclimated"
            case .wellAcclimated: "Well acclimated"
            case .fullyAcclimated: "Fully acclimated"
            }
        }
    }

    static func band(for level: Double) -> Band {
        switch level {
        case ..<HeatConstants.partialBandFloor: .notAcclimated
        case ..<HeatConstants.wellBandFloor: .partial
        case ..<HeatConstants.fullBandFloor: .wellAcclimated
        default: .fullyAcclimated
        }
    }

    /// How many more consecutive hot-exposure days are needed to reach
    /// `target` from `current`, assuming a sustained strong stimulus
    /// (`assumedDailyStimulus`, default a full daily dose). Returns 0 if
    /// already at/above target, or nil if the target is unreachable at the
    /// assumed stimulus (its ceiling sits below the target).
    ///
    /// Inverts the induction EWMA: with ceiling C and rate k, after n days
    /// level Lₙ = C − (C − L₀)(1 − k)ⁿ, so
    ///   n = ln((C − target)/(C − current)) / ln(1 − k), rounded up.
    static func daysToTarget(
        current: Double,
        target: Double = HeatConstants.defaultTargetLevel,
        assumedDailyStimulus: Double = 1.0
    ) -> Int? {
        guard current < target else { return 0 }
        let ceiling = 100.0 * min(max(assumedDailyStimulus, 0), 1)
        guard ceiling > target else { return nil } // can't get there at this dose
        let k = HeatConstants.inductionRatePerDay
        let ratio = (ceiling - target) / (ceiling - current)
        let n = Foundation.log(ratio) / Foundation.log(1 - k)
        return max(1, Int(n.rounded(.up)))
    }

    /// The heat level (as a shade-WBGT in °C, and the air temperature it
    /// roughly corresponds to at moderate humidity) that the current state
    /// represents comfortable adaptation to. A fully-acclimated athlete is
    /// adapted to the upper end of the training range; a partially-adapted
    /// one to a milder level. This maps the abstract 0–100 onto something
    /// the user can feel ("you're acclimated to about 28 °C / 82 °F").
    /// - Returns: estimated WBGT °C the user is comfortably adapted to, or
    ///   nil below the not-acclimated floor.
    static func adaptedWBGT(for level: Double) -> Double? {
        guard level >= HeatConstants.partialBandFloor else { return nil }
        let frac = min(max(level, 0), 100) / 100.0
        return HeatConstants.stimulusWBGTThreshold
            + frac * HeatConstants.adaptedWBGTSpanC
    }

    /// Approximate the air temperature (°C, at ~50% RH) corresponding to a
    /// shade-WBGT, purely for human-friendly phrasing ("adapted to ≈ 28 °C").
    /// Inverts the BoM WBGT relation at fixed RH by fixed-point iteration.
    static func approxAirTempC(fromWBGT wbgt: Double) -> Double {
        var t = wbgt // seed
        for _ in 0..<12 {
            let e = 0.5 * saturationVaporPressure(tempC: t)
            // WBGT = 0.567·T + 0.393·e + 3.94  ⇒  T = (WBGT − 0.393·e − 3.94)/0.567
            t = (wbgt - 0.393 * e - 3.94) / 0.567
        }
        return t
    }
}
