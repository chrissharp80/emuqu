import CoreLocation
import Foundation

// MARK: - Clinical report sections
//
// The long-form Markdown report: one function per section, in document order.
// Split from CoachReportGenerator.swift — see the note in
// CoachReportGenerator+Conversational.swift.

extension CoachReportGenerator {
    static func headerSection(
        session: HRVSession,
        meta: WorkoutMetadata,
        units: UnitsPreference
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short
        let date = dateFormatter.string(from: session.startDate)
        let sport = meta.sport.displayName
        let dist = formatDistance(meta.distanceMeters, units: units)
        let dur = formatDuration(session.duration ?? 0)
        var lines: [String] = [
            "# Coach Report — \(sport)",
            "",
            "**\(date)** · \(dist) · \(dur)"
        ]
        if let route = meta.recognizedRouteName, !route.isEmpty {
            lines.append("Route: **\(route)**")
        }
        return lines.joined(separator: "\n")
    }
    /// Average and peak HR, or an honest note when the strap was silent.
    static func heartRateLines(hrSamples: [Int], userMaxHR: Int) -> [String] {
        guard !hrSamples.isEmpty else { return ["- HR: not captured for this session."] }
        let avg = Double(hrSamples.reduce(0, +)) / Double(hrSamples.count)
        let peak = hrSamples.max() ?? Int(avg)
        let pctOfMax = userMaxHR > 0 ? Int(round(avg / Double(userMaxHR) * 100)) : 0
        return [
            "- Average HR: **\(Int(round(avg))) bpm** (~\(pctOfMax) % of max)",
            "- Peak HR: **\(peak) bpm**"
        ]
    }
    /// Time in zone by percent of max HR, emitted only when there is HR and a max.
    static func zoneLines(
        meta: WorkoutMetadata,
        hrSamples: [Int],
        userMaxHR: Int
    ) -> [String] {
        guard !hrSamples.isEmpty, userMaxHR > 0 else { return [] }
        let breakdown = WorkoutZoneBreakdown.compute(
            samples: meta.samples ?? [],
            userMaxHR: userMaxHR
        )
        guard breakdown.totalSec > 0 else { return [] }
        var lines = ["- Time in zone (% of max HR):"] + zoneBreakdownLines(breakdown)
        if let dom = breakdown.dominantZone {
            lines.append("- Dominant zone: **Z\(dom)**")
        }
        return lines
    }
    static func zoneBreakdownLines(_ breakdown: WorkoutZoneBreakdown) -> [String] {
        let total = Double(breakdown.totalSec)
        let zones = [
            ("Z1", breakdown.z1Sec), ("Z2", breakdown.z2Sec), ("Z3", breakdown.z3Sec),
            ("Z4", breakdown.z4Sec), ("Z5", breakdown.z5Sec)
        ]
        return zones.map { label, seconds in
            "  - \(label) \(formatTime(seconds)) (\(Int(round(Double(seconds) / total * 100)))%)"
        }
    }
    /// Training load, most-accurate source first.
    ///
    /// Leading with the best available number keeps the AI coach's
    /// reasoning anchored on powerTSS when power was recorded, rather than on
    /// HR-only TRIMP. `preferredLoad` arrives pre-resolved: an in-function
    /// `MainActor.assumeIsolated` traps when the renderer
    /// runs from a detached task, so the caller captures it first.
    static func loadLines(
        meta: WorkoutMetadata,
        preferredLoad: PreferredLoadSnapshot?
    ) -> [String] {
        var lines: [String] = []
        if let load = preferredLoad {
            lines.append("- Load: **\(Int(round(load.value)))** · \(loadSourceLabel(load.source))")
        }
        // Both TRIMP and hrTSS stay visible below the primary line so
        // power-equipped athletes can still see how the HR side reads.
        if let trimp = meta.luciaTRIMP, preferredLoad?.source != .banister {
            lines.append("  - Lucia TRIMP: \(Int(round(trimp))) (HR-based)")
        }
        if let hrTSS = meta.hrTSS, preferredLoad?.source != .hr {
            lines.append("  - hrTSS: \(Int(round(hrTSS)))")
        }
        if let intensity = meta.intensityFactor {
            lines.append("- Intensity Factor: \(String(format: "%.2f", locale: .current, intensity))")
        }
        return lines
    }
    static func loadSourceLabel(_ source: WorkoutMetadata.TrainingLoadSource) -> String {
        switch source {
        case .power: "powerTSS (Coggan)"
        case .hr: "hrTSS"
        case .mets: "METs (pace + grade)"
        case .banister: "Lucia TRIMP (Banister)"
        case .routeHistory: "Route-history estimate"
        }
    }
    /// One plain-language sentence for what that effort actually felt like.
    static func effortInterpretation(hrSamples: [Int], userMaxHR: Int) -> String? {
        guard !hrSamples.isEmpty, userMaxHR > 0 else { return nil }
        let avg = Double(hrSamples.reduce(0, +)) / Double(hrSamples.count)
        let pct = avg / Double(userMaxHR)
        if pct < 0.65 { return "_Easy effort — recovery / aerobic base territory._" }
        if pct < 0.75 { return "_Moderate effort — endurance build, sustainable for hours._" }
        if pct < 0.85 { return "_Tempo effort — at or near your aerobic threshold._" }
        if pct < 0.92 { return "_Hard — at or above lactate threshold; sustainable for ~30–60 min if fit._" }
        return "_Very hard — VO2max territory; not sustainable beyond ~10 min._"
    }
    static func effortSection(
        session: HRVSession,
        meta: WorkoutMetadata,
        userMaxHR: Int,
        preferredLoad: PreferredLoadSnapshot? = nil
    ) -> String {
        let hrSamples = (meta.samples ?? []).compactMap { $0.heartRate }
        var lines = ["## Effort"]
        lines += heartRateLines(hrSamples: hrSamples, userMaxHR: userMaxHR)
        lines += zoneLines(
            meta: meta,
            hrSamples: hrSamples,
            userMaxHR: userMaxHR
        )
        lines += loadLines(meta: meta, preferredLoad: preferredLoad)
        if let interpretation = effortInterpretation(hrSamples: hrSamples, userMaxHR: userMaxHR) {
            lines.append(interpretation)
        }
        return lines.joined(separator: "\n")
    }
    static func paceCadenceSection(
        meta: WorkoutMetadata,
        units: UnitsPreference
    ) -> String {
        var lines = ["## Pace & Cadence"]
        lines += averagePaceLines(meta: meta, units: units)
        lines += splitLines(meta: meta, units: units)
        // Reverse split + cadence drift from samples
        if let samples = meta.samples, !samples.isEmpty {
            lines += paceTrendLines(samples: samples, units: units)
            lines += cadenceLines(samples: samples)
        }
        return lines.joined(separator: "\n")
    }

    private static func averagePaceLines(meta: WorkoutMetadata, units: UnitsPreference) -> [String] {
        guard let dist = meta.distanceMeters, dist > 0,
              let samples = meta.samples,
              let lastT = samples.last?.offsetSec, lastT > 0
        else { return [] }
        let avgPaceSecPerKm = Double(lastT) / (dist / 1_000.0)
        let formatted = units.formatPace(secondsPerMeter: avgPaceSecPerKm / 1_000) ?? "—"
        return ["- Average pace: **\(formatted)**"]
    }

    private static func splitLines(meta: WorkoutMetadata, units: UnitsPreference) -> [String] {
        guard let splits = meta.splits, !splits.isEmpty else { return [] }
        var lines = ["- Splits:"]
        for split in splits.prefix(20) {
            let label = "\(split.index)"
            let pace = split.averagePaceSecPerKm.map { units.formatPace(secondsPerMeter: $0 / 1_000) ?? "—" } ?? "—"
            let hr = split.averageHR.map { " · HR \(Int(round($0)))" } ?? ""
            let elev = split.elevationGainMeters.map { " · +\(formatElevation($0, units: units))" } ?? ""
            lines.append("  - Split \(label): \(pace)\(hr)\(elev)")
        }
        return lines
    }

    private static func paceTrendLines(samples: [WorkoutSample], units: UnitsPreference) -> [String] {
        var lines: [String] = []
        if let rsd = WorkoutLiveTrends.reverseSplitDeltaSecPerKm(samples: samples) {
            let dir = rsd < 0 ? "faster" : "slower"
            let (delta, unit) = units == .imperial ? (rsd * 1.609344, "sec/mi") : (rsd, "sec/km")
            lines.append(String(format: "- Reverse split delta: **%+.0f %@** (second half %@ than first)", locale: .current, delta, unit, dir))
        }
        if let gradeAdj = WorkoutLiveTrends.recentSplitGradeAdjustedPaces(samples: samples) as [Double]?, !gradeAdj.isEmpty {
            let label = gradeAdj.prefix(3).map { p in
                units.formatPace(secondsPerMeter: p / 1_000) ?? "—"
            }.joined(separator: ", ")
            lines.append("- Last splits, grade-adjusted (Strava-style): \(label)")
        }
        return lines
    }

    private static func cadenceLines(samples: [WorkoutSample]) -> [String] {
        var lines: [String] = []
        if let cad = samples.compactMap({ $0.cadenceStepsPerMin }).filter({ $0 > 0 }) as [Double]?,
           !cad.isEmpty {
            let avgCad = cad.reduce(0, +) / Double(cad.count)
            lines.append("- Average cadence: **\(Int(round(avgCad))) spm**")
        }
        if let drift = WorkoutLiveTrends.cadenceDriftSpm(samples: samples) {
            let dir = drift < 0 ? "down" : "up"
            lines.append(String(format: "- Cadence drift: **%+.1f spm** (last quarter %@ vs first quarter)", locale: .current, drift, dir))
        }
        return lines
    }
    static func aerobicPhysiologySection(meta: WorkoutMetadata) -> String {
        var lines = ["## Aerobic Physiology"]
        lines += alpha1Lines(meta: meta)
        if let dec = meta.decouplingPercent {
            let dir = dec >= 5 ? " — meaningful drift (fueling, heat, or fatigue)" : " — well coupled, fitness held"
            lines.append(String(format: "- Aerobic decoupling Pa:Hr: **%+.1f %%**\(dir)", locale: .current, dec))
        }
        if let samples = meta.samples,
           let drift = WorkoutLiveTrends.hrDriftPercent(samples: samples) {
            let plain = drift > 5 ? " — fatigue / heat / dehydration signal" : " — within normal range"
            lines.append(String(format: "- HR drift (last quartile vs first): **%+.1f %%**\(plain)", locale: .current, drift))
        }
        if let ef = meta.efficiencyFactor {
            lines.append(String(format: "- Efficiency Factor (NP / avg HR): %.3f", locale: .current, ef))
        }
        return lines.joined(separator: "\n")
    }
    static func alpha1Lines(meta: WorkoutMetadata) -> [String] {
        let alphas = (meta.samples ?? []).compactMap { $0.alpha1 }
        guard !alphas.isEmpty else {
            return ["- α1: not captured (no RR series for this session)."]
        }
        let avg = alphas.reduce(0, +) / Double(alphas.count)
        return [
            String(format: "- DFA α1: avg **%.2f** (range %.2f–%.2f)", locale: .current, avg, alphas.min() ?? 0, alphas.max() ?? 0),
            alpha1Interpretation(average: avg)
        ]
    }
    static func alpha1Interpretation(average avg: Double) -> String {
        if avg >= 0.75 { return "_Predominantly below aerobic threshold — easy/aerobic territory the whole way._" }
        if avg >= 0.50 { return "_Between AT1 and AT2 — tempo / threshold band._" }
        return "_Below AT2 — high-intensity efforts pulled the average down._"
    }
    static func hrrSection(meta: WorkoutMetadata) -> String {
        var lines = ["## Heart Rate Recovery"]
        guard let hrr = meta.hrrSamples, !hrr.isEmpty else {
            lines.append("- HRR window did not capture samples (strap disconnected or window expired before peak HR was recorded).")
            return lines.joined(separator: "\n")
        }
        if let one = hrr.bestAtOneMinute {
            lines.append("- 1-minute HRR: **−\(one.drop) bpm** (peak \(one.peakHR) → \(one.hr))")
        }
        if let two = hrr.bestAtTwoMinutes {
            lines.append("- 2-minute HRR: **−\(two.drop) bpm** (peak \(two.peakHR) → \(two.hr))")
        }
        if let one = hrr.bestAtOneMinute {
            lines.append(hrrInterpretation(oneMinuteDrop: one.drop))
        }
        return lines.joined(separator: "\n")
    }
    /// Vagal-reactivation bands for 1-minute HRR.
    static func hrrInterpretation(oneMinuteDrop drop: Int) -> String {
        if drop >= 25 { return "_Excellent autonomic recovery — vagal reactivation is strong._" }
        if drop >= 18 { return "_Good recovery — typical of a fit aerobic athlete._" }
        if drop >= 12 { return "_Moderate recovery — room to improve aerobic conditioning._" }
        return "_Limited recovery — fatigue, dehydration, or detraining are candidates._"
    }
    static func elevationSection(meta: WorkoutMetadata, units: UnitsPreference) -> String {
        var lines = ["## Elevation"]
        if let gain = meta.elevationGainMeters, gain > 0 {
            lines.append("- Total gain: **\(formatElevation(gain, units: units))**")
        }
        if let loss = meta.elevationLossMeters, loss > 0 {
            lines.append("- Total loss: **\(formatElevation(loss, units: units))**")
        }
        if (meta.elevationGainMeters ?? 0) == 0, (meta.elevationLossMeters ?? 0) == 0 {
            lines.append("- No barometric or GPS-altitude data captured (indoor session or GPS denied).")
        }
        return lines.joined(separator: "\n")
    }
    static func powerSection(meta: WorkoutMetadata) -> String {
        var lines = ["## Power (foot pod)"]
        if let avg = meta.averagePowerWatts { lines.append("- Average: **\(Int(round(avg))) W**") }
        if let np = meta.normalizedPowerWatts { lines.append("- Normalized Power: **\(Int(round(np))) W**") }
        if let pk = meta.peakPowerWatts { lines.append("- Peak: \(pk) W") }
        if let intensity = meta.intensityFactor { lines.append("- Intensity Factor (NP/FTP): \(String(format: "%.2f", locale: .current, intensity))") }
        if let vi = meta.variabilityIndex { lines.append("- Variability Index (NP/avg): \(String(format: "%.2f", locale: .current, vi))") }
        if let pTSS = meta.powerTSS { lines.append("- powerTSS: **\(Int(round(pTSS)))**") }
        return lines.joined(separator: "\n")
    }
    static func comparisonsSection(
        session: HRVSession,
        meta: WorkoutMetadata,
        pastWorkouts: [HRVSession],
        units: UnitsPreference
    ) -> String {
        var lines = ["## How This Compares"]
        lines += sportWideComparison(session: session, meta: meta, pastWorkouts: pastWorkouts, units: units)
        lines += routeComparison(session: session, meta: meta, pastWorkouts: pastWorkouts, units: units)
        if lines.count == 1 {
            lines.append("- Not enough comparable history yet to draw confident comparisons.")
        }
        return lines.joined(separator: "\n")
    }
    /// "today X vs Y — N sec/km faster than <comparand>".
    ///
    /// Both comparison blocks built this from scratch. The arithmetic was
    /// identical; the wording was not, in two places — the reference is
    /// "typical" for the sport and "route avg" for the route, and the trailing
    /// comparand is "usual" for the sport and "your typical <route name>" for
    /// the route. Both are parameters here so the shared version cannot quietly
    /// normalise one into the other.
    static func paceComparisonLine(
        todayPace: Double,
        referencePace: Double,
        referenceLabel: String,
        comparand: String,
        units: UnitsPreference
    ) -> String {
        let delta = todayPace - referencePace
        let displayDelta = units == .imperial ? delta * 1.609344 : delta
        let unitLabel = units == .imperial ? "/mi" : "/km"
        let dir = delta < 0 ? "faster" : "slower"
        let todayLabel = units.formatPace(secondsPerMeter: todayPace / 1_000) ?? "—"
        let baseLabel = units.formatPace(secondsPerMeter: referencePace / 1_000) ?? "—"
        return "- Pace: today \(todayLabel) vs \(referenceLabel) \(baseLabel) — "
            + "\(abs(Int(displayDelta.rounded()))) sec\(unitLabel) \(dir) than \(comparand)"
    }
    /// Seconds per km for a workout, or nil when the distance or duration is too
    /// small for the ratio to mean anything.
    static func paceSecPerKm(distanceMeters: Double?, duration: TimeInterval?) -> Double? {
        guard let distanceMeters, distanceMeters > 100, let duration, duration > 60 else { return nil }
        return duration * 1_000.0 / distanceMeters
    }
    static func sportWideComparison(
        session: HRVSession,
        meta: WorkoutMetadata,
        pastWorkouts: [HRVSession],
        units: UnitsPreference
    ) -> [String] {
        let sportPeers = pastWorkouts.filter { $0.workoutMetadata?.sport == meta.sport }.prefix(30)
        guard !sportPeers.isEmpty else { return [] }
        let baselines = WorkoutHistoryBaselines.compute(from: Array(sportPeers), sport: meta.sport, limit: 30)
        guard baselines.sampleCount >= 2 else { return [] }

        var lines = ["**Sport-wide (last \(baselines.sampleCount) \(meta.sport.displayName.lowercased()) sessions):**"]
        if let line = sportPaceLine(session: session, meta: meta, baseline: baselines.avgPaceSecPerKm, units: units) {
            lines.append(line)
        }
        if let line = sportHeartRateLine(meta: meta, baselineHR: baselines.avgHR) {
            lines.append(line)
        }
        return lines
    }
    static func sportPaceLine(
        session: HRVSession,
        meta: WorkoutMetadata,
        baseline: Double?,
        units: UnitsPreference
    ) -> String? {
        guard let baseline,
              let todayPace = paceSecPerKm(distanceMeters: meta.distanceMeters, duration: session.duration)
        else { return nil }
        return paceComparisonLine(
            todayPace: todayPace, referencePace: baseline,
            referenceLabel: "typical", comparand: "usual", units: units
        )
    }
    static func sportHeartRateLine(meta: WorkoutMetadata, baselineHR: Double?) -> String? {
        guard let baselineHR else { return nil }
        let hrSamples = (meta.samples ?? []).compactMap { $0.heartRate }
        guard !hrSamples.isEmpty else { return nil }
        let todayHR = Double(hrSamples.reduce(0, +)) / Double(hrSamples.count)
        let delta = todayHR - baselineHR
        let dir = delta < 0 ? "lower" : "higher"
        return String(
            format: "- Avg HR: today %d bpm vs typical %d bpm — %@%d bpm %@ than usual",
            Int(round(todayHR)), Int(round(baselineHR)),
            delta < 0 ? "" : "+", abs(Int(delta.rounded())), dir
        )
    }
    static func routeComparison(
        session: HRVSession,
        meta: WorkoutMetadata,
        pastWorkouts: [HRVSession],
        units: UnitsPreference
    ) -> [String] {
        guard let routeName = meta.recognizedRouteName, !routeName.isEmpty else { return [] }
        let routePeers = pastWorkouts.filter { $0.workoutMetadata?.recognizedRouteName == routeName }.prefix(20)
        guard !routePeers.isEmpty else {
            return ["**On this route (\(routeName)):** first session — no prior data to compare."]
        }

        var lines = ["**On this route (\(routeName), last \(routePeers.count) sessions):**"]
        guard let routeAvgPace = routeAveragePace(routePeers),
              let todayPace = paceSecPerKm(distanceMeters: meta.distanceMeters, duration: session.duration)
        else { return lines }
        lines.append(paceComparisonLine(
            todayPace: todayPace, referencePace: routeAvgPace,
            referenceLabel: "route avg", comparand: "your typical \(routeName)", units: units
        ))
        return lines
    }
    /// Distance-weighted average pace across prior runs of the same route.
    static func routeAveragePace(_ routePeers: ArraySlice<HRVSession>) -> Double? {
        var totalDistance: Double = 0
        var totalDuration: Double = 0
        for prior in routePeers {
            guard let distance = prior.workoutMetadata?.distanceMeters, distance > 100,
                  let duration = prior.duration, duration > 60 else { continue }
            totalDistance += distance
            totalDuration += duration
        }
        guard totalDistance > 100 else { return nil }
        return totalDuration * 1_000.0 / totalDistance
    }
    static func trainingLoadSection(session: HRVSession) -> String {
        var lines = ["## Training Load Context"]
        guard let ctx = session.trainingSnapshot else {
            lines.append("- Training-load snapshot not available for this session.")
            return lines.joined(separator: "\n")
        }
        lines.append(String(format: "- ATL (fatigue, 7-day EWMA): **%.1f**", locale: .current, ctx.atl))
        lines.append(String(format: "- CTL (fitness, 42-day EWMA): **%.1f**", locale: .current, ctx.ctl))
        lines.append(String(format: "- TSB (form / freshness, CTL−ATL): **%+.1f**", locale: .current, ctx.tsb))
        if let acwr = ctx.acuteChronicRatio {
            lines.append(String(format: "- ACWR (acute / chronic ratio): **%.2f**\(acwrZoneSuffix(acwr))", locale: .current, acwr))
        }
        if let days = TrainingLoadProjection.daysUntilFresh(currentATL: ctx.atl, currentCTL: ctx.ctl) {
            lines.append("- Days at zero load until TSB ≥ 0: **\(days)**")
        }
        return lines.joined(separator: "\n")
    }
    /// This is the DATA section of the coach report — athletes
    /// and coaches reading the PDF expect the raw ratio, so the number stays
    /// visible here. The dashboard is where the descriptive translation lives.
    static func acwrZoneSuffix(_ acwr: Double) -> String {
        if acwr >= 1.5 { return " — sharp recent increase vs your usual range" }
        if acwr >= 1.3 { return " — above your usual range" }
        if acwr >= 0.8 { return " — within your usual range" }
        return " — below your usual range (taper, rest week, or natural variation)"
    }
    static func recommendationsSection(session: HRVSession, meta _: WorkoutMetadata) -> String {
        var lines = ["## Recommendations", recoveryRecommendation(session: session)]
        if let ctx = session.trainingSnapshot, let acwr = ctx.acuteChronicRatio {
            lines.append(loadRecommendation(acwr: acwr))
        }
        if let drift = (session.workoutMetadata?.samples).flatMap(WorkoutLiveTrends.hrDriftPercent), drift > 5 {
            lines.append("- **Fueling / heat:** HR drift was \(String(format: "%.0f%%", locale: .current, drift)). Consider revisiting hydration / carbs during long efforts; if heat was a factor, plan tomorrow earlier in the day.")
        }
        return lines.joined(separator: "\n")
    }
    static func recoveryRecommendation(session: HRVSession) -> String {
        let recoveryHrs = session.trainingSnapshot.flatMap {
            RecoveryTimeEstimate.hoursFromTrainingLoad(atl: $0.atl, ctl: $0.ctl)
        }
        guard session.trainingSnapshot != nil else {
            return "- **Recovery:** no training-load snapshot for this session, so no recovery-time estimate."
        }
        guard let hrs = recoveryHrs else {
            return "- **Recovery:** TSB is non-negative — body is fresh. Tomorrow can be a quality session."
        }
        return "- **Recovery:** ~\(Int(round(hrs))) hours until TSB returns to zero. Skip hard sessions until then."
    }
    /// Descriptive copy, no risk-prediction.
    static func loadRecommendation(acwr: Double) -> String {
        if acwr >= 1.5 {
            return "- **Load:** Recent training is well above your usual range. Plan an easy day or full rest tomorrow — the heavier-than-usual load needs absorption time, regardless of how recovered HRV looks."
        }
        if acwr >= 1.3 {
            return "- **Load:** Recent training is running above your usual range. One more easy day this week before the next quality session."
        }
        if acwr >= 0.8 {
            return "- **Load:** Recent training is within your usual range. Continue current volume, planned hard sessions are safe."
        }
        return "- **Load:** Recent training is below your usual range. Room to add quality this week."
    }
    static func footer() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        return """
        ---
        *Generated by Emuqu on \(dateFormatter.string(from: Date())). Numbers come from the recorded session; comparisons are computed from your recent history. Recommendations are heuristic — always trust how your body actually feels in the morning.*
        """
    }
}
