import CoreLocation
import Foundation

// MARK: - Conversational summary
//
// The short coach-voice email body and every sentence that feeds it. Every
// sentence is whole and localized: the email is sent as-is in
// the app language, so nothing is spliced from English fragments.
//
// Members are internal rather than private because Swift's `private` does not
// reach across files.

extension CoachReportGenerator {
    /// Short, conversational coach voice — used as the body of the
    /// auto Coach Report email. Pairs with the PDF attachment
    /// (WorkoutPDFReport) so the user gets a quick read inline plus
    /// the full clinical breakdown attached. The caller appends
    /// `pdfFootnote` only when the PDF is actually attached.
    ///
    /// Only the most recent `historyLimit` workouts are decoded: the
    /// comparison reads at most 30 same-sport sessions, so decoding the whole
    /// archive was wasted work.
    static func renderConversationalSummary(
        session: HRVSession,
        archive: SessionArchive?,
        units: UnitsPreference,
        userMaxHR: Int,
        userRestingHR: Int
    ) -> String {
        renderConversationalSummary(
            session: session,
            pastWorkouts: archive.map { recentPastWorkouts(in: $0, excluding: session.id) } ?? [],
            units: units,
            userMaxHR: userMaxHR,
            userRestingHR: userRestingHR
        )
    }

    /// How many past workouts the comparison may decode.
    static let historyLimit = 120

    /// The newest past workouts, newest first, decoded lightweight.
    static func recentPastWorkouts(in archive: SessionArchive, excluding id: UUID) -> [HRVSession] {
        archive.entries
            .filter { $0.sessionType == .workout && $0.sessionId != id }
            .sorted { $0.date > $1.date }
            .prefix(historyLimit)
            .compactMap { archive.retrieveLightweightOrLog($0.sessionId, caller: "CoachReportGenerator") }
    }

    /// Pre-fetched-history entry point. Lets callers (notably the
    /// post-workout email scheduler) walk the archive once on the
    /// MainActor and then run the rendering itself on a detached task,
    /// instead of holding MainActor for the whole render.
    ///
    /// The list below is the report's running order. `nil` means "this
    /// section had nothing to say" and drops out.
    static func renderConversationalSummary(
        session: HRVSession,
        pastWorkouts: [HRVSession],
        units: UnitsPreference,
        userMaxHR: Int,
        userRestingHR _: Int
    ) -> String {
        guard let meta = session.workoutMetadata else {
            return String(localized: "Coach Report", bundle: LanguageManager.appBundle) + "\n\n"
                + String(localized: "No workout data for this session, so there's nothing to report on.", bundle: LanguageManager.appBundle)
        }
        let paragraphs: [String?] = [
            summaryHeadline(session: session, meta: meta, units: units),
            openingVerdict(session: session, meta: meta, userMaxHR: userMaxHR),
            physiologyParagraph(meta: meta, userMaxHR: userMaxHR),
            historyComparison(session: session, meta: meta, pastWorkouts: pastWorkouts, units: units, userMaxHR: userMaxHR),
            recoveryParagraph(meta: meta),
            tomorrowParagraph(session: session, meta: meta)
        ]
        return paragraphs.compactMap { $0 }.joined(separator: "\n\n")
    }

    /// Nil when there is no history to compare against.
    static func historyComparison(
        session: HRVSession,
        meta: WorkoutMetadata,
        pastWorkouts: [HRVSession],
        units: UnitsPreference,
        userMaxHR: Int
    ) -> String? {
        guard !pastWorkouts.isEmpty else { return nil }
        return comparisonParagraph(
            session: session, meta: meta, pastWorkouts: pastWorkouts, units: units, userMaxHR: userMaxHR
        )
    }

    /// "# Run — Tuesday, 3 June 2026 at 07:14\n\n5.20 km on **River Loop**, 28:40."
    static func summaryHeadline(
        session: HRVSession,
        meta: WorkoutMetadata,
        units: UnitsPreference
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = LanguageManager.appLocale
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short
        let dist = formatDistance(meta.distanceMeters, units: units)
        let dur = formatDuration(session.duration ?? 0)
        let line: String = if let name = meta.recognizedRouteName, !name.isEmpty {
            String(localized: "\(dist) on **\(name)**, \(dur).", bundle: LanguageManager.appBundle)
        } else {
            String(localized: "\(dist), \(dur).", bundle: LanguageManager.appBundle)
        }
        return "# \(meta.sport.localizedName) — \(dateFormatter.string(from: session.startDate))\n\n\(line)"
    }

    static func openingVerdict(session _: HRVSession, meta: WorkoutMetadata, userMaxHR: Int) -> String {
        let hrSamples = (meta.samples ?? []).compactMap { $0.heartRate }
        let avgHR = hrSamples.isEmpty ? nil : Double(hrSamples.reduce(0, +)) / Double(hrSamples.count)
        let pct = (avgHR.map { userMaxHR > 0 ? $0 / Double(userMaxHR) : 0 }) ?? 0
        let alphas = (meta.samples ?? []).compactMap { $0.alpha1 }
        let avgAlpha = alphas.isEmpty ? nil : alphas.reduce(0, +) / Double(alphas.count)
        let label = intensityLabel(percentOfMax: pct)
        var sentences = [String(localized: "**Verdict:** \(label).", bundle: LanguageManager.appBundle)]
        if let avg = avgHR, userMaxHR > 0 {
            let bpm = Int(round(avg)), pctOfMax = Int(round(pct * 100))
            sentences.append(String(localized: "You averaged \(bpm) bpm, \(pctOfMax)% of your max.", bundle: LanguageManager.appBundle))
        }
        if let alphaSentence = alpha1Verdict(avgAlpha) { sentences.append(alphaSentence) }
        return sentences.joined(separator: " ")
    }

    static func intensityLabel(percentOfMax pct: Double) -> String {
        if pct < 0.65 { return String(localized: "Easy aerobic effort", bundle: LanguageManager.appBundle) }
        if pct < 0.75 { return String(localized: "Moderate endurance effort", bundle: LanguageManager.appBundle) }
        if pct < 0.85 { return String(localized: "Tempo effort", bundle: LanguageManager.appBundle) }
        if pct < 0.92 { return String(localized: "Threshold effort", bundle: LanguageManager.appBundle) }
        return String(localized: "VO2max-level effort", bundle: LanguageManager.appBundle)
    }

    static func alpha1Verdict(_ avgAlpha: Double?) -> String? {
        guard let a = avgAlpha else { return nil }
        let alpha = decimal(a, digits: 2)
        if a >= 0.75 {
            return String(localized: "Your DFA α1 sat at \(alpha) — that's textbook below-AT1, the kind of session that builds aerobic base without taxing recovery.", bundle: LanguageManager.appBundle)
        }
        if a >= 0.50 {
            return String(localized: "DFA α1 averaged \(alpha), which puts you between AT1 and AT2 — meaningful tempo work.", bundle: LanguageManager.appBundle)
        }
        return String(localized: "DFA α1 averaged \(alpha) — the hard efforts pulled it below 0.50, so this counts as a hard day.", bundle: LanguageManager.appBundle)
    }

    static func physiologyParagraph(meta: WorkoutMetadata, userMaxHR _: Int) -> String? {
        let bits = [
            decouplingSentence(meta: meta),
            heartRateDriftSentence(meta: meta),
            cadenceDriftSentence(meta: meta)
        ].compactMap { $0 }
        guard !bits.isEmpty else { return nil }
        let body = bits.joined(separator: " ")
        return String(localized: "**What your body did:** \(body)", bundle: LanguageManager.appBundle)
    }

    static func decouplingSentence(meta: WorkoutMetadata) -> String? {
        guard let dec = meta.decouplingPercent else { return nil }
        if dec >= 5 {
            let value = percent(dec)
            return String(localized: "Aerobic decoupling came in at \(value) — your HR drifted up faster than your pace, which is a fueling, heat, or fatigue signal. The body had to recruit more cardiac output to hold the same workload.", bundle: LanguageManager.appBundle)
        }
        let value = percent(dec, signed: true)
        return String(localized: "Pa:Hr decoupling was \(value) — well coupled, meaning your cardiovascular system held the workload cleanly through the whole session. Aerobic fitness held up.", bundle: LanguageManager.appBundle)
    }

    static func heartRateDriftSentence(meta: WorkoutMetadata) -> String? {
        guard let samples = meta.samples,
              let drift = WorkoutLiveTrends.hrDriftPercent(samples: samples), drift > 0 else { return nil }
        let value = percent(drift, signed: true)
        if drift > 5 {
            return String(localized: "HR drifted \(value) from the first quarter to the last — at the same effort, your heart had to work harder near the end. Most likely cause is dehydration or heat; second most likely is glycogen depletion if this was over an hour.", bundle: LanguageManager.appBundle)
        }
        return String(localized: "HR drift was \(value) — within normal range for steady aerobic work.", bundle: LanguageManager.appBundle)
    }

    static func cadenceDriftSentence(meta: WorkoutMetadata) -> String? {
        let cads = (meta.samples ?? []).compactMap { $0.cadenceStepsPerMin }.filter { $0 > 0 }
        guard !cads.isEmpty,
              let driftCad = WorkoutLiveTrends.cadenceDriftSpm(samples: meta.samples ?? []),
              abs(driftCad) >= 3 else { return nil }
        let avgCad = Int(round(cads.reduce(0, +) / Double(cads.count)))
        let change = decimal(abs(driftCad), digits: 1)
        if driftCad > 0 {
            return String(localized: "Cadence averaged \(avgCad) spm and rose by \(change) by the last quarter. Cadence climbing as fatigue sets in usually means your stride shortened — common in the back third of long efforts.", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Cadence averaged \(avgCad) spm and dropped by \(change) by the last quarter. Cadence falling near the end is a fatigue signal — your stride lengthened or you slowed without realising it.", bundle: LanguageManager.appBundle)
    }

    /// The cause-and-effect matrix: pace delta crossed with HR delta.
    ///
    /// Six combinations, each meaning something different — slower *and*
    /// higher HR is a freshness or heat signal; faster *and* lower HR is
    /// adaptation. The whole point of the section is that neither number means
    /// much without the other, which is why this reads as one table rather than
    /// two independent checks.
    static func paceVsHeartRateSentences(
        paceDeltaSecPerKm: Double?,
        hrDelta: Double?,
        todayPaceSecPerKm: Double?,
        todayAvgHR: Double?,
        sport _: Sport,
        units: UnitsPreference
    ) -> [String] {
        guard let pd = paceDeltaSecPerKm else { return [] }
        guard let hd = hrDelta else { return [paceOnlySentence(pd, units: units)] }
        let sentence = combinationSentence(
            pace: PaceDelta(secPerKm: pd, units: units), hrDelta: hd,
            todayPaceSecPerKm: todayPaceSecPerKm, todayAvgHR: todayAvgHR, units: units
        )
        return sentence.map { [$0] } ?? []
    }

    /// A pace difference in the user's unit, ready to quote ("12 sec/km").
    struct PaceDelta {
        let secPerKm: Double
        let text: String

        init(secPerKm: Double, units: UnitsPreference) {
            self.secPerKm = secPerKm
            let seconds = abs(Int((units == .imperial ? secPerKm * 1.609344 : secPerKm).rounded()))
            text = units == .imperial
                ? String(localized: "\(seconds) sec/mi", bundle: LanguageManager.appBundle)
                : String(localized: "\(seconds) sec/km", bundle: LanguageManager.appBundle)
        }

        var isFaster: Bool { secPerKm < 0 }
    }

    /// With no HR to cross it against, pace alone is all that can be said.
    private static func paceOnlySentence(_ pd: Double, units: UnitsPreference) -> String {
        let delta = PaceDelta(secPerKm: pd, units: units).text
        return pd < 0
            ? String(localized: "Pace was \(delta) faster than usual for this sport.", bundle: LanguageManager.appBundle)
            : String(localized: "Pace was \(delta) slower than usual for this sport.", bundle: LanguageManager.appBundle)
    }

    /// The six-way matrix. Each cell means something different, which is the
    /// whole point of the section — neither number says much without the other.
    private static func combinationSentence(
        pace: PaceDelta,
        hrDelta hd: Double,
        todayPaceSecPerKm: Double?,
        todayAvgHR: Double?,
        units: UnitsPreference
    ) -> String? {
        let pd = pace.secPerKm
        if abs(pd) < 5, abs(hd) < 2 {
            let paceText = units.formatPace(secondsPerMeter: (todayPaceSecPerKm ?? 0) / 1_000) ?? "—"
            let bpm = Int(round(todayAvgHR ?? 0))
            return String(localized: "Both your pace (\(paceText)) and HR (\(bpm) bpm) were right on your usual numbers for this sport. Boring is good — it means recovery is steady.", bundle: LanguageManager.appBundle)
        }
        if abs(pd) >= 5, abs(hd) >= 2 { return bothChangedSentence(pace: pace, hrDelta: hd) }
        if abs(pd) >= 5 { return paceOnlyChangedSentence(pace: pace) }
        if abs(hd) >= 2 { return heartRateOnlyChangedSentence(hrDelta: hd) }
        return nil
    }

    /// Pace and HR both moved: four cells, one per direction pair.
    private static func bothChangedSentence(pace: PaceDelta, hrDelta hd: Double) -> String {
        let delta = pace.text, bpm = Int(abs(hd.rounded()))
        switch (pace.isFaster, hd > 0) {
        case (false, true):
            return String(localized: "Your pace was \(delta) slower AND your HR was \(bpm) bpm higher — that combination is a freshness or environmental signal. Either you came in fatigued (TSB negative), it was hotter or more humid than your average session, or you didn't fuel as well. The body had to ask the heart to work harder for less output.", bundle: LanguageManager.appBundle)
        case (false, false):
            return String(localized: "You were \(delta) slower but your HR was actually \(bpm) bpm lower — that's a deliberate-easy signal. You held back, and the body responded with less cardiac demand. Good sign of autonomic recovery.", bundle: LanguageManager.appBundle)
        case (true, false):
            return String(localized: "You were \(delta) faster AND your HR was \(bpm) bpm lower — that's a clean fitness signal. Same effort, more output. This is what training adaptation looks like.", bundle: LanguageManager.appBundle)
        case (true, true):
            return String(localized: "You went \(delta) faster but it cost you \(bpm) bpm more HR — you pushed harder than usual. Acceptable for a key session, less so for what was supposed to be easy.", bundle: LanguageManager.appBundle)
        }
    }

    private static func paceOnlyChangedSentence(pace: PaceDelta) -> String {
        let delta = pace.text
        return pace.isFaster
            ? String(localized: "Pace was \(delta) faster than usual for this sport. HR was within normal range, so the change is likely intentional pacing rather than a physiology shift.", bundle: LanguageManager.appBundle)
            : String(localized: "Pace was \(delta) slower than usual for this sport. HR was within normal range, so the change is likely intentional pacing rather than a physiology shift.", bundle: LanguageManager.appBundle)
    }

    private static func heartRateOnlyChangedSentence(hrDelta hd: Double) -> String {
        let bpm = Int(abs(hd.rounded()))
        return hd > 0
            ? String(localized: "Pace was on baseline but HR was \(bpm) bpm higher — for the same workload, that suggests lingering fatigue, heat, or under-fueling. Worth comparing with how you felt.", bundle: LanguageManager.appBundle)
            : String(localized: "Pace was on baseline but HR was \(bpm) bpm lower — for the same workload, that suggests you came in fresher than usual. Worth comparing with how you felt.", bundle: LanguageManager.appBundle)
    }

    /// Like-for-like comparison against previous laps of the same recognised
    /// route, where terrain is identical and the read is therefore cleaner than
    /// the sport-wide baseline above.
    static func routeComparisonSentences(
        session: HRVSession,
        meta: WorkoutMetadata,
        pastWorkouts: [HRVSession],
        units: UnitsPreference
    ) -> [String] {
        guard let routeName = meta.recognizedRouteName, !routeName.isEmpty else { return [] }
        let routePeers = pastWorkouts.filter { $0.workoutMetadata?.recognizedRouteName == routeName }.prefix(20)
        guard routePeers.count >= 2 else {
            return [String(localized: "First (or near-first) outing on \(routeName) — once you have 3-4 sessions there, route-specific comparisons get reliable.", bundle: LanguageManager.appBundle)]
        }
        guard let dist = meta.distanceMeters, dist > 100,
              let dur = session.duration, dur > 60,
              let routeAvgPace = averageRoutePace(Array(routePeers))
        else { return [] }
        return [routeLapSentence(
            routeName: routeName,
            pace: PaceDelta(secPerKm: dur * 1_000.0 / dist - routeAvgPace, units: units)
        )]
    }

    /// Distance-weighted average pace across prior laps of the same route. Nil
    /// when none of them recorded enough distance to be worth comparing.
    private static func averageRoutePace(_ routePeers: [HRVSession]) -> Double? {
        var totalDist: Double = 0
        var totalDur: Double = 0
        for prior in routePeers {
            guard let pd = prior.workoutMetadata?.distanceMeters, pd > 100,
                  let pdur = prior.duration, pdur > 60 else { continue }
            totalDist += pd
            totalDur += pdur
        }
        guard totalDist > 100 else { return nil }
        return totalDur * 1_000.0 / totalDist
    }

    /// Within five seconds of the usual lap reads as "the same", not as a
    /// change worth narrating.
    private static func routeLapSentence(routeName: String, pace: PaceDelta) -> String {
        guard abs(pace.secPerKm) >= 5 else {
            return String(localized: "On \(routeName), you were within seconds of your typical lap — a like-for-like read since the terrain is identical.", bundle: LanguageManager.appBundle)
        }
        let delta = pace.text
        return pace.isFaster
            ? String(localized: "On \(routeName) specifically, you were \(delta) faster than your typical lap on this exact route — that's a like-for-like comparison since terrain is identical.", bundle: LanguageManager.appBundle)
            : String(localized: "On \(routeName) specifically, you were \(delta) slower than your typical lap on this exact route — that's a like-for-like comparison since terrain is identical.", bundle: LanguageManager.appBundle)
    }

    static func comparisonParagraph(
        session: HRVSession,
        meta: WorkoutMetadata,
        pastWorkouts: [HRVSession],
        units: UnitsPreference,
        userMaxHR _: Int
    ) -> String? {
        let sportPeers = pastWorkouts.filter { $0.workoutMetadata?.sport == meta.sport }.prefix(30)
        guard sportPeers.count >= 2 else {
            guard let routeName = meta.recognizedRouteName, !routeName.isEmpty else { return nil }
            return String(localized: "**How it compared:** first time on \(routeName) in your archive, so no route baseline yet. Sport-wide history is also too thin to compare confidently — give it a few more sessions.", bundle: LanguageManager.appBundle)
        }
        let baselines = WorkoutHistoryBaselines.compute(from: Array(sportPeers), sport: meta.sport, limit: 30)
        guard baselines.sampleCount >= 2 else { return nil }
        let deltas = comparisonDeltas(session: session, meta: meta, baselines: baselines)
        let sentences = paceVsHeartRateSentences(
            paceDeltaSecPerKm: deltas.paceDelta, hrDelta: deltas.hrDelta,
            todayPaceSecPerKm: deltas.todayPace, todayAvgHR: deltas.todayAvgHR,
            sport: meta.sport, units: units
        ) + routeComparisonSentences(session: session, meta: meta, pastWorkouts: pastWorkouts, units: units)
        guard !sentences.isEmpty else { return nil }
        let body = sentences.joined(separator: " ")
        return String(localized: "**How it compared:** \(body)", bundle: LanguageManager.appBundle)
    }

    /// Today's session measured against the sport-wide baseline. Any field can
    /// be nil when the session didn't record enough to compare.
    struct ComparisonDeltas {
        let paceDelta: Double?
        let hrDelta: Double?
        let todayPace: Double?
        let todayAvgHR: Double?
    }

    /// Today's pace and HR against the sport-wide baseline.
    private static func comparisonDeltas(
        session: HRVSession,
        meta: WorkoutMetadata,
        baselines: WorkoutHistoryBaselines
    ) -> ComparisonDeltas {
        let hrSamples = (meta.samples ?? []).compactMap { $0.heartRate }
        let todayAvgHR = hrSamples.isEmpty ? nil : Double(hrSamples.reduce(0, +)) / Double(hrSamples.count)
        var todayPace: Double?
        var paceDelta: Double?
        if let p = baselines.avgPaceSecPerKm,
           let dist = meta.distanceMeters, dist > 100,
           let dur = session.duration, dur > 60 {
            todayPace = dur * 1_000.0 / dist
            paceDelta = (todayPace ?? 0) - p
        }
        let hrDelta = (baselines.avgHR).flatMap { base in todayAvgHR.map { $0 - base } }
        return ComparisonDeltas(paceDelta: paceDelta, hrDelta: hrDelta, todayPace: todayPace, todayAvgHR: todayAvgHR)
    }

    static func recoveryParagraph(meta: WorkoutMetadata) -> String? {
        guard let hrr = meta.hrrSamples,
              let one = hrr.bestAtOneMinute
        else { return nil }
        let (drop, peak, after) = (one.drop, one.peakHR, one.hr)
        let measured: String = if let two = hrr.bestAtTwoMinutes {
            String(localized: "**Recovery:** Your heart rate dropped \(drop) bpm in the first minute after peak (\(peak) → \(after)) and \(two.drop) bpm by two minutes.", bundle: LanguageManager.appBundle)
        } else {
            String(localized: "**Recovery:** Your heart rate dropped \(drop) bpm in the first minute after peak (\(peak) → \(after)).", bundle: LanguageManager.appBundle)
        }
        return measured + " " + hrrRecoverySentence(oneMinuteDrop: drop)
    }

    /// How to read a one-minute heart-rate-recovery drop. The 25 / 18 / 12 bpm
    /// cutoffs are the conventional clinical/athletic ones.
    private static func hrrRecoverySentence(oneMinuteDrop drop: Int) -> String {
        switch drop {
        case 25...:
            String(localized: "That's excellent autonomic recovery — vagal reactivation is strong, a classic well-trained aerobic profile.", bundle: LanguageManager.appBundle)
        case 18 ..< 25:
            String(localized: "That's solid recovery, in line with a fit aerobic athlete.", bundle: LanguageManager.appBundle)
        case 12 ..< 18:
            String(localized: "That's moderate recovery — there's headroom to improve aerobic conditioning.", bundle: LanguageManager.appBundle)
        default:
            String(localized: "That's limited recovery — fatigue, dehydration, or detraining are the usual culprits when 1-min HRR is under 12 bpm.", bundle: LanguageManager.appBundle)
        }
    }

    static func tomorrowParagraph(session: HRVSession, meta _: WorkoutMetadata) -> String {
        var bits: [String] = []
        if let ctx = session.trainingSnapshot {
            if let acwr = ctx.acuteChronicRatio { bits.append(loadRangeAdvice(acwr: acwr)) }
            if let tsb = freshnessAdvice(tsb: ctx.tsb) { bits.append(tsb) }
        }
        if let drift = (session.workoutMetadata?.samples).flatMap(WorkoutLiveTrends.hrDriftPercent), drift > 5 {
            let value = percent(drift, digits: 0)
            bits.append(String(localized: "HR drift was \(value) — revisit hydration and carb intake during long efforts; if heat was a factor, shift tomorrow earlier in the day.", bundle: LanguageManager.appBundle))
        }
        if bits.isEmpty {
            bits.append(String(localized: "No load-management flags from this session — execute the next session as planned.", bundle: LanguageManager.appBundle))
        }
        let body = bits.joined(separator: " ")
        return String(localized: "**For tomorrow:** \(body)", bundle: LanguageManager.appBundle)
    }

    /// Descriptive load-range copy instead of ACWR-by-name plus
    /// Gabbett "spike-injury zone" framing. The ratio drives the branch;
    /// the user-facing text describes what is observed.
    static func loadRangeAdvice(acwr: Double) -> String {
        if acwr >= 1.5 {
            return String(localized: "Recent training is well above your usual range. Plan an easy day or full rest tomorrow — heavier-than-usual load this week needs absorption time, regardless of how recovered HRV looks.", bundle: LanguageManager.appBundle)
        }
        if acwr >= 1.3 {
            return String(localized: "Recent training is running above your usual range. One more easy day this week before the next quality session.", bundle: LanguageManager.appBundle)
        }
        if acwr >= 0.8 {
            return String(localized: "Recent training is within your usual range. Current volume is sustainable; planned hard sessions are safe to execute.", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Recent training is below your usual range. Room to add quality this week.", bundle: LanguageManager.appBundle)
    }

    /// Nil in the neutral band, where TSB says nothing worth a sentence.
    static func freshnessAdvice(tsb: Double) -> String? {
        let value = decimal(tsb, digits: 0, signed: true)
        if tsb < -10 {
            return String(localized: "TSB is \(value) — meaningfully tired. Tomorrow should be aerobic recovery only.", bundle: LanguageManager.appBundle)
        }
        if tsb > 5 {
            return String(localized: "TSB is \(value) — fresh. Good window for the next quality session.", bundle: LanguageManager.appBundle)
        }
        return nil
    }

    // MARK: - Number formatting (app locale)

    static func decimal(_ value: Double, digits: Int, signed: Bool = false) -> String {
        value.formatted(
            .number.precision(.fractionLength(digits))
                .sign(strategy: signed ? .always() : .automatic)
                .locale(LanguageManager.appLocale)
        )
    }

    /// `value` is already a percentage (5.2 means 5.2 %).
    static func percent(_ value: Double, digits: Int = 1, signed: Bool = false) -> String {
        (value / 100).formatted(
            .percent.precision(.fractionLength(digits))
                .sign(strategy: signed ? .always() : .automatic)
                .locale(LanguageManager.appLocale)
        )
    }
}
