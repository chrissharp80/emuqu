import CoreLocation
import Foundation

// MARK: - Conversational summary
//
// The short coach-voice email body and every sentence that feeds it. Split
// from CoachReportGenerator.swift: extracting functions to satisfy
// the refactor spec's 20-line rule pushes that file past the 1000-line limit,
// so the two halves of the report live where each can be read on its own.
//
// Members are internal rather than private because Swift's `private` does not
// reach across files; same convention as PDFReportGenerator+Sections.swift.

extension CoachReportGenerator {
    /// Short, conversational coach voice — used as the body of the
    /// auto Coach Report email. Pairs with the epic PDF attachment
    /// (WorkoutPDFReport) so the user gets a quick read inline plus
    /// the full clinical breakdown attached.
    ///
    /// Prose explicitly connects cause and effect ("your pace was
    /// slower for the same HR — that's because of…"). No bullet
    /// dump. Sentences reference cross-metrics so the user
    /// understands *why* something matters, not just the number.
    static func renderConversationalSummary(
        session: HRVSession,
        archive: SessionArchive?,
        units: UnitsPreference,
        userMaxHR: Int,
        userRestingHR: Int
    ) -> String {
        let past: [HRVSession] = archive.map { archive in
            archive.entries
                .filter { $0.sessionType == .workout && $0.sessionId != session.id }
                .compactMap { try? archive.retrieveLightweight($0.sessionId) }
        } ?? []
        return renderConversationalSummary(
            session: session,
            pastWorkouts: past,
            units: units,
            userMaxHR: userMaxHR,
            userRestingHR: userRestingHR
        )
    }
    /// Pre-fetched-history entry point. Lets callers (notably the
    /// post-workout email scheduler) walk the archive ONCE on the
    /// MainActor and then run the rendering itself on a detached task,
    /// instead of holding MainActor for the whole render.
    ///
    /// Exists because generating the coach report
    /// froze the AI chat when the renderer iterated the
    /// archive (`@MainActor`) inline, blocking MainActor for seconds
    /// on archives with many sessions. The heavy walk happens
    /// once before detach, and the render is pure-function detached
    /// work.
    /// The report's running order, stated once.
    ///
    /// `nil` means "this section had nothing to say" and drops out. Every entry
    /// is a pure function of the session, so the shape of the email is readable
    /// here without tracing a sequence of `append` calls through 50 lines.
    static func renderConversationalSummary(
        session: HRVSession,
        pastWorkouts: [HRVSession],
        units: UnitsPreference,
        userMaxHR: Int,
        userRestingHR _: Int
    ) -> String {
        guard let meta = session.workoutMetadata else {
            return "Coach Report\n\nNo workout metadata for this session — nothing to report on."
        }
        let paragraphs: [String?] = [
            summaryHeadline(session: session, meta: meta, units: units),
            openingVerdict(session: session, meta: meta, userMaxHR: userMaxHR),
            physiologyParagraph(meta: meta, userMaxHR: userMaxHR),
            historyComparison(session: session, meta: meta, pastWorkouts: pastWorkouts, units: units, userMaxHR: userMaxHR),
            recoveryParagraph(meta: meta),
            tomorrowParagraph(session: session, meta: meta),
            Self.pdfFootnote
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
    /// "# Run — Tuesday 3 June 2026 at 07:14\n\n5.2 km on **River Loop**, 28:40."
    static func summaryHeadline(
        session: HRVSession,
        meta: WorkoutMetadata,
        units: UnitsPreference
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short
        let sport = meta.sport.displayName
        let dist = formatDistance(meta.distanceMeters, units: units)
        let dur = formatDuration(session.duration ?? 0)
        let route: String = {
            guard let name = meta.recognizedRouteName, !name.isEmpty else { return "" }
            return " on **\(name)**"
        }()
        return "# \(sport) — \(dateFormatter.string(from: session.startDate))\n\n\(dist)\(route), \(dur)."
    }
    static func openingVerdict(session _: HRVSession, meta: WorkoutMetadata, userMaxHR: Int) -> String {
        let hrSamples = (meta.samples ?? []).compactMap { $0.heartRate }
        let avgHR = hrSamples.isEmpty ? nil : Double(hrSamples.reduce(0, +)) / Double(hrSamples.count)
        let pct = (avgHR.map { userMaxHR > 0 ? $0 / Double(userMaxHR) : 0 }) ?? 0
        let alphas = (meta.samples ?? []).compactMap { $0.alpha1 }
        let avgAlpha = alphas.isEmpty ? nil : alphas.reduce(0, +) / Double(alphas.count)

        var sentence = "**Verdict:** \(intensityLabel(percentOfMax: pct)) effort"
        if let avg = avgHR, userMaxHR > 0 {
            sentence += " — averaged \(Int(round(avg))) bpm (\(Int(round(pct*100)))% of max)"
        }
        sentence += alpha1Verdict(avgAlpha)
        return sentence
    }
    static func intensityLabel(percentOfMax pct: Double) -> String {
        if pct < 0.65 { return "easy aerobic" }
        if pct < 0.75 { return "moderate endurance" }
        if pct < 0.85 { return "tempo" }
        if pct < 0.92 { return "threshold" }
        return "VO2max-territory"
    }
    static func alpha1Verdict(_ avgAlpha: Double?) -> String {
        guard let a = avgAlpha else { return "." }
        if a >= 0.75 {
            return ". Your DFA α1 sat at \(String(format: "%.2f", locale: .current, a)) — that's textbook below-AT1, the kind of session that builds aerobic base without taxing recovery."
        }
        if a >= 0.50 {
            return ". DFA α1 averaged \(String(format: "%.2f", locale: .current, a)), which puts you between AT1 and AT2 — meaningful tempo work."
        }
        return ". DFA α1 dropped to \(String(format: "%.2f", locale: .current, a)) on average — high-intensity efforts pulled you below AT2, so this counts as a hard day."
    }
    static func physiologyParagraph(meta: WorkoutMetadata, userMaxHR _: Int) -> String? {
        let bits = [
            decouplingSentence(meta: meta),
            heartRateDriftSentence(meta: meta),
            cadenceDriftSentence(meta: meta)
        ].compactMap { $0 }
        guard !bits.isEmpty else { return nil }
        return "**What your body did:** " + bits.joined(separator: " ")
    }
    static func decouplingSentence(meta: WorkoutMetadata) -> String? {
        var bits: [String] = []
        if let dec = meta.decouplingPercent {
            if dec >= 5 {
                bits.append("Aerobic decoupling came in at \(String(format: "%.1f%%", locale: .current, dec)) — your HR drifted up faster than your pace, which is a fueling, heat, or fatigue signal. The body had to recruit more cardiac output to hold the same workload.")
            } else {
                bits.append("Pa:Hr decoupling was \(String(format: "%+.1f%%", locale: .current, dec)) — well coupled, meaning your cardiovascular system held the workload cleanly through the whole session. Aerobic fitness held up.")
            }
        }
        return bits.first
    }
    static func heartRateDriftSentence(meta: WorkoutMetadata) -> String? {
        var bits: [String] = []
        if let samples = meta.samples,
           let drift = WorkoutLiveTrends.hrDriftPercent(samples: samples) {
            if drift > 5 {
                bits.append("HR drifted \(String(format: "%+.1f%%", locale: .current, drift)) from the first quarter to the last — at the same effort, your heart had to work harder near the end. Most likely cause is dehydration or heat; second most likely is glycogen depletion if this was over an hour.")
            } else if drift > 0 {
                bits.append("HR drift was \(String(format: "%+.1f%%", locale: .current, drift)) — within normal range for steady aerobic work.")
            }
        }
        return bits.first
    }
    static func cadenceDriftSentence(meta: WorkoutMetadata) -> String? {
        var bits: [String] = []
        let cads = (meta.samples ?? []).compactMap { $0.cadenceStepsPerMin }.filter { $0 > 0 }
        if !cads.isEmpty,
           let driftCad = WorkoutLiveTrends.cadenceDriftSpm(samples: meta.samples ?? []) {
            let avgCad = cads.reduce(0, +) / Double(cads.count)
            if abs(driftCad) >= 3 {
                let dir = driftCad > 0 ? "rose by" : "dropped by"
                let why = driftCad > 0
                    ? "Cadence climbing as fatigue sets in usually means your stride shortened — common in the back third of long efforts."
                    : "Cadence falling near the end is a fatigue signal — your stride lengthened or you slowed without realising it."
                bits.append("Cadence averaged \(Int(round(avgCad))) spm and \(dir) \(String(format: "%.1f", locale: .current, abs(driftCad))) by the last quarter. \(why)")
            }
        }
        return bits.first
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
        sport: Sport,
        units: UnitsPreference
    ) -> [String] {
        guard let pd = paceDeltaSecPerKm else { return [] }
        guard let hd = hrDelta else { return [paceOnlySentence(pd, sport: sport, units: units)] }
        return combinationSentences(
            paceDelta: pd, hrDelta: hd, todayPaceSecPerKm: todayPaceSecPerKm,
            todayAvgHR: todayAvgHR, sport: sport, units: units
        )
    }

    /// With no HR to cross it against, pace alone is all that can be said.
    private static func paceOnlySentence(_ pd: Double, sport: Sport, units: UnitsPreference) -> String {
        let displayPaceDelta = units == .imperial ? pd * 1.609344 : pd
        let unitLabel = units == .imperial ? "/mi" : "/km"
        return "Pace was \(abs(Int(displayPaceDelta.rounded()))) sec\(unitLabel) \(pd < 0 ? "faster" : "slower") than your typical \(sport.displayName.lowercased())."
    }

    /// The six-way matrix. Each cell means something different, which is the
    /// whole point of the section — neither number says much without the other.
    private static func combinationSentences(
        paceDelta pd: Double,
        hrDelta hd: Double,
        todayPaceSecPerKm: Double?,
        todayAvgHR: Double?,
        sport: Sport,
        units: UnitsPreference
    ) -> [String] {
        var out: [String] = []
        let displayPaceDelta = units == .imperial ? pd * 1.609344 : pd
        let unitLabel = units == .imperial ? "/mi" : "/km"
        let (paceDir, hrDir) = (pd < 0 ? "faster" : "slower", hd < 0 ? "lower" : "higher")
        if abs(pd) < 5 && abs(hd) < 2 {
            out.append("Both your pace (\(units.formatPace(secondsPerMeter: (todayPaceSecPerKm ?? 0)/1_000) ?? "—")) and HR (\(Int(round(todayAvgHR ?? 0))) bpm) were dead on your typical numbers for \(sport.displayName.lowercased()). Boring is good — it means recovery is steady.")
        } else if pd > 5 && hd > 2 {
            out.append("Your pace was \(abs(Int(displayPaceDelta.rounded()))) sec\(unitLabel) \(paceDir) AND your HR was \(Int(abs(hd.rounded()))) bpm \(hrDir) — that combination is a freshness or environmental signal. Either you came in fatigued (TSB negative), it was hotter / more humid than your average session, or you didn't fuel as well. The body had to ask the heart to work harder for less output.")
        } else if pd > 5 && hd < -2 {
            out.append("You were \(abs(Int(displayPaceDelta.rounded()))) sec\(unitLabel) \(paceDir) but your HR was actually \(Int(abs(hd.rounded()))) bpm \(hrDir) — that's a deliberate-easy signal. You held back, the body responded with less cardiac demand. Good sign of autonomic recovery.")
        } else if pd < -5 && hd < -2 {
            out.append("You were \(abs(Int(displayPaceDelta.rounded()))) sec\(unitLabel) \(paceDir) AND your HR was \(Int(abs(hd.rounded()))) bpm \(hrDir) — that's a clean fitness signal. Same effort, more output. This is what training adaptation looks like.")
        } else if pd < -5 && hd > 2 {
            out.append("You went \(abs(Int(displayPaceDelta.rounded()))) sec\(unitLabel) \(paceDir) but it cost you \(Int(abs(hd.rounded()))) bpm \(hrDir) HR — you pushed harder than usual. Acceptable for a key session, less so for what was supposed to be easy.")
        } else if abs(pd) >= 5 {
            out.append("Pace was \(abs(Int(displayPaceDelta.rounded()))) sec\(unitLabel) \(paceDir) than your typical \(sport.displayName.lowercased()). HR was within normal range, so the change is likely intentional pacing rather than a physiology shift.")
        } else if abs(hd) >= 2 {
            out.append("Pace was on baseline but HR was \(Int(abs(hd.rounded()))) bpm \(hrDir) — for the same workload, that suggests \(hd > 0 ? "lingering fatigue, heat, or under-fueling" : "you came in fresher than usual"). Worth correlating with how you felt.")
        }
        return out
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
            return ["First (or near-first) outing on \(routeName) — once you have 3-4 sessions there, route-specific comparisons get reliable."]
        }
        guard let dist = meta.distanceMeters, dist > 100,
              let dur = session.duration, dur > 60,
              let routeAvgPace = averageRoutePace(Array(routePeers))
        else { return [] }
        return [routeLapSentence(
            routeName: routeName,
            delta: dur * 1_000.0 / dist - routeAvgPace,
            units: units
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
    private static func routeLapSentence(routeName: String, delta: Double, units: UnitsPreference) -> String {
        guard abs(delta) >= 5 else {
            return "On \(routeName), you were within seconds of your typical lap — a like-for-like read since the terrain is identical."
        }
        let displayDelta = units == .imperial ? delta * 1.609344 : delta
        let unitLabel = units == .imperial ? "/mi" : "/km"
        return "On \(routeName) specifically, you were \(abs(Int(displayDelta.rounded()))) sec\(unitLabel) \(delta < 0 ? "faster" : "slower") than your typical lap on this exact route — that's a like-for-like comparison since terrain is identical."
    }
    static func comparisonParagraph(
        session: HRVSession,
        meta: WorkoutMetadata,
        pastWorkouts: [HRVSession],
        units: UnitsPreference,
        userMaxHR: Int
    ) -> String? {
        let sportPeers = pastWorkouts.filter { $0.workoutMetadata?.sport == meta.sport }.prefix(30)
        guard sportPeers.count >= 2 else {
            guard let routeName = meta.recognizedRouteName, !routeName.isEmpty else { return nil }
            return "**How it compared:** first time on \(routeName) in your archive, so no route baseline yet. Sport-wide history is also too thin to compare confidently — give it a few more sessions."
        }
        let baselines = WorkoutHistoryBaselines.compute(from: Array(sportPeers), sport: meta.sport, limit: 30)
        guard baselines.sampleCount >= 2 else { return nil }
        let deltas = comparisonDeltas(session: session, meta: meta, baselines: baselines)
        var sentences = paceVsHeartRateSentences(
            paceDeltaSecPerKm: deltas.paceDelta, hrDelta: deltas.hrDelta,
            todayPaceSecPerKm: deltas.todayPace, todayAvgHR: deltas.todayAvgHR,
            sport: meta.sport, units: units
        )
        sentences += routeComparisonSentences(
            session: session, meta: meta, pastWorkouts: pastWorkouts, units: units
        )
        guard !sentences.isEmpty else { return nil }
        return "**How it compared:** " + sentences.joined(separator: " ")
    }

    /// Today's session measured against the sport-wide baseline. Any field can
    /// be nil when the session didn't record enough to compare.
    struct ComparisonDeltas {
        let paceDelta: Double?
        let hrDelta: Double?
        let todayPace: Double?
        let todayAvgHR: Double?
    }

    /// Today's pace and HR against the sport-wide baseline. Any of these can be
    /// nil when the session didn't record enough to compare.
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
        let two = hrr.bestAtTwoMinutes

        let interp = hrrRecoveryClause(oneMinuteDrop: one.drop)

        var sentence = "**Recovery:** Your heart rate dropped \(one.drop) bpm in the first minute after peak (\(one.peakHR) → \(one.hr))"
        if let two {
            sentence += " and \(two.drop) bpm by two minutes"
        }
        sentence += " — \(interp)."
        return sentence
    }

    /// How to read a one-minute heart-rate-recovery drop, as a mid-sentence
    /// clause. `CoachReportGenerator+Sections.hrrInterpretation` renders the
    /// same four bands as a standalone italic bullet; the 25 / 18 / 12 bpm
    /// cutoffs are the conventional clinical/athletic ones and must stay in
    /// step between the two.
    private static func hrrRecoveryClause(oneMinuteDrop drop: Int) -> String {
        switch drop {
        case 25...:
            "excellent autonomic recovery — vagal reactivation is strong, classic well-trained-aerobic profile"
        case 18 ..< 25:
            "solid recovery, in line with a fit aerobic athlete"
        case 12 ..< 18:
            "moderate recovery — there's headroom to improve aerobic conditioning"
        default:
            "limited recovery — fatigue, dehydration, or detraining are the usual culprits when 1-min HRR is under 12 bpm"
        }
    }

    static func tomorrowParagraph(session: HRVSession, meta _: WorkoutMetadata) -> String {
        var bits: [String] = []
        if let ctx = session.trainingSnapshot {
            if let acwr = ctx.acuteChronicRatio { bits.append(loadRangeAdvice(acwr: acwr)) }
            if let tsb = freshnessAdvice(tsb: ctx.tsb) { bits.append(tsb) }
        }
        if let drift = (session.workoutMetadata?.samples).flatMap(WorkoutLiveTrends.hrDriftPercent), drift > 5 {
            bits.append("HR drift was \(String(format: "%.0f%%", locale: .current, drift)) — revisit hydration and carb intake during long efforts; if heat was a factor, shift tomorrow earlier in the day.")
        }
        if bits.isEmpty {
            bits.append("No load-management flags from this session — execute the next session as planned.")
        }
        return "**For tomorrow:** " + bits.joined(separator: " ")
    }
    /// Descriptive load-range copy instead of ACWR-by-name plus
    /// Gabbett "spike-injury zone" framing. The ratio drives the branch;
    /// the user-facing text describes what is observed.
    static func loadRangeAdvice(acwr: Double) -> String {
        if acwr >= 1.5 {
            return "Recent training is well above your usual range. Plan an easy day or full rest tomorrow — heavier-than-usual load this week needs absorption time, regardless of how recovered HRV looks."
        }
        if acwr >= 1.3 {
            return "Recent training is running above your usual range. One more easy day this week before the next quality session."
        }
        if acwr >= 0.8 {
            return "Recent training is within your usual range. Current volume is sustainable; planned hard sessions are safe to execute."
        }
        return "Recent training is below your usual range. Room to add quality this week."
    }
    /// Nil in the neutral band, where TSB says nothing worth a sentence.
    static func freshnessAdvice(tsb: Double) -> String? {
        if tsb < -10 {
            return "TSB is \(String(format: "%+.0f", locale: .current, tsb)) — meaningfully tired. Tomorrow should be aerobic recovery only."
        }
        if tsb > 5 {
            return "TSB is \(String(format: "%+.0f", locale: .current, tsb)) — fresh. Good window for the next quality session."
        }
        return nil
    }
}
