import Foundation

// The questions people ask out loud mid-workout, answered from the live
// snapshot without a model: how am I doing, this spot against past passes,
// should I ease off, is it the climb, what's ahead, where am I, my heart
// rate. Apple's on-device model cannot fit Flo's instructions, the tools and
// a tool's answer in its window, so these failed there; answered here they
// work on every model and with none, in well under a second.
//
// Served only while a workout is live (`MatchContext.liveWorkout`), and
// tried before the recovery patterns, so a mid-workout "how am I doing?"
// means the workout, not this morning's recovery score. As with the rest of
// `DeterministicIntent`, a handler that lacks a number returns nil and the
// question goes to the model.
extension DeterministicIntent {
    static let livePatterns: [Pattern] = [
        Pattern(id: "live_spot_compare", triggers: [
            #"^(?!.*\b(?:turn|(?:go|keep|bear|take\s+a)\s+(?:left|right)|directions?|way\s+(?:home|back)|get\s+(?:back|home))\b)"#
                + #"(?=.*\b(?:here|this\s+(?:spot|hill|climb|stretch|section|place|point|corner|street|road|part)|same\s+(?:spot|place|hill|climb|stretch|part))\b)"#
                + #"(?=.*\b(?:compar\w*|vs|versus|than|before|last\s+time|usual|previous)\b)"#,
            #"^\s*am\s+i\s+(?:faster|slower)(?:\s+than\s+(?:last\s+time|before|usual))?\s*$"#
        ], handler: liveSpotCompare),
        Pattern(id: "live_ease_off", triggers: [
            #"^\s*(?:should|do|can)\s+i\s+(?:ease|back)\s+off"# + liveTail,
            #"^\s*should\s+i\s+(?:slow\s+down|push(?:\s+(?:on|harder))?|go\s+harder|pick\s+it\s+up|speed\s+up)"# + liveTail,
            #"^\s*am\s+i\s+(?:going|pushing|working)\s+too\s+hard"# + liveTail
        ], handler: liveEaseOff),
        Pattern(id: "live_climb_or_me", triggers: [
            #"\bis\s+(?:it|that)\s+(?:just\s+)?the\s+(?:hill|climb|grade|incline)\b"#,
            #"\bam\s+i\s+(?:really\s+|actually\s+)?(?:slower|slowing(?:\s+down)?)\b"#,
            #"\bwhy\s+am\s+i\s+(?:so\s+)?slow\b"#
        ], handler: liveClimbOrMe),
        Pattern(id: "live_whats_ahead", triggers: [
            #"^\s*(?:what(?:['’]?s|\s+is)|anything)\s+(?:ahead|coming(?:\s+up)?|up\s+ahead)(?:\s+(?:of\s+(?:me|us)|on\s+(?:this|the)\s+(?:route|run|ride|course|trail)))?"# + liveTail,
            #"^\s*(?:any|is\s+there\s+a|are\s+there\s+any)\s+(?:more\s+)?(?:hills?|climbs?)(?:\s+(?:ahead|left|coming(?:\s+up)?|up\s+ahead|on\s+(?:this|the)\s+(?:route|run|ride|course|trail)))?"# + liveTail
        ], handler: liveWhatsAhead),
        Pattern(id: "live_where_am_i", triggers: [
            #"^\s*where\s+(?:am\s+i|are\s+we)(?:\s+(?:now|right\s+now|at))?\s*$"#
        ], handler: liveWhereAmI),
        Pattern(id: "live_heart_rate", triggers: [
            #"^\s*(?:what(?:['’]?s|\s+is)\s+)?my\s+(?:heart\s*rate|hr|pulse)(?:\s+(?:now|right\s+now))?\s*$"#,
            #"^\s*heart\s*rate\s*$"#
        ], handler: liveHeartRate),
        Pattern(id: "live_summary", triggers: [
            #"^\s*how\s+(?:am|are)\s+(?:i|we)\s+doing(?:\s+(?:so\s+far|now))?\s*$"#,
            #"^\s*how(?:['’]?s|\s+is)\s+(?:it|this|my\s+(?:run|walk|ride|workout))\s+going\s*$"#
        ], handler: liveSummary)
    ]

    /// What may end a whole-utterance live question: "now", "here", "a bit"
    /// and the like. A longer question ("my knee hurts, should I push
    /// through it", "what's coming up in my plan this week") carries more
    /// than the live snapshot answers, so it goes to the model.
    static let liveTail = #"(?:\s+(?:now|here|right\s+now|a\s+bit|a\s+little|yet))?\s*$"#

    /// Units and formatting the live answers share.
    private static var units: UnitsPreference { UnitsPreferenceStore.current }

    static func paceText(_ secondsPerKm: Double?) -> String? {
        secondsPerKm.flatMap { units.formatPace(secondsPerMeter: $0 / 1000) }
    }

    // MARK: How am I doing / heart rate / where am I

    static func liveSummary(_ utterance: String, _ ctx: MatchContext) -> String? {
        guard let live = ctx.liveWorkout, let hr = live.heartRate, let pace = paceText(live.currentPaceSecPerKm),
              live.distanceMeters > 50 else { return nil }
        let (minutes, distance) = (live.elapsedSeconds / 60, units.formatDistance(meters: live.distanceMeters))
        return String(localized: "\(minutes) minutes in: \(distance) at \(pace), heart rate \(hr).", bundle: LanguageManager.appBundle)
    }

    static func liveHeartRate(_ utterance: String, _ ctx: MatchContext) -> String? {
        guard let live = ctx.liveWorkout, let hr = live.heartRate, live.userMaxHR > 0 else { return nil }
        let percent = Int((Double(hr) / Double(live.userMaxHR) * 100).rounded())
        return String(localized: "\(hr) beats per minute, \(percent) percent of your max.", bundle: LanguageManager.appBundle)
    }

    static func liveWhereAmI(_ utterance: String, _ ctx: MatchContext) -> String? {
        guard let live = ctx.liveWorkout, let road = live.currentRoadName, !road.isEmpty else { return nil }
        let place = live.currentLocality ?? live.currentAdministrativeArea ?? ""
        let bundle = LanguageManager.appBundle
        if let cross = live.currentNearestCrossStreet, !cross.isEmpty, cross != road {
            return place.isEmpty
                ? String(localized: "On \(road) near \(cross).", bundle: bundle)
                : String(localized: "On \(road) near \(cross), \(place).", bundle: bundle)
        }
        return place.isEmpty ? String(localized: "On \(road).", bundle: bundle) : String(localized: "On \(road), \(place).", bundle: bundle)
    }

    // MARK: Is it the climb

    static func liveClimbOrMe(_ utterance: String, _ ctx: MatchContext) -> String? {
        guard let live = ctx.liveWorkout, let pace = paceText(live.currentPaceSecPerKm) else { return nil }
        let bundle = LanguageManager.appBundle
        if let grade = live.currentGradePercent, grade >= 2, let flat = paceText(live.gradeAdjustedPaceSecPerKm) {
            let percent = Int(grade.rounded())
            return String(localized: "It's the climb. \(pace) on a \(percent) percent grade is \(flat) on flat ground.", bundle: bundle)
        }
        guard let grade = live.currentGradePercent, abs(grade) < 2, let split = paceText(live.recentSplitPaces.last) else { return nil }
        return String(localized: "It isn't the hill, it's close to flat here. You're at \(pace); your last split was \(split).", bundle: bundle)
    }
}

// MARK: - This spot before

extension DeterministicIntent {
    /// A pace this close to the usual one (as a share of it) is "about the
    /// same"; so is a heart rate this many beats from it.
    static let samePaceShare = 0.02
    static let sameHeartRateBeats = 2

    static func liveSpotCompare(_ utterance: String, _ ctx: MatchContext) -> String? {
        guard let live = ctx.liveWorkout, let visits = live.visitsHere, let hr = live.heartRate,
              let paceNow = live.currentPaceSecPerKm, let pace = paceText(paceNow) else { return nil }
        let bundle = LanguageManager.appBundle
        let now = String(localized: "Here you're at \(pace) and \(hr) beats per minute.", bundle: bundle)
        guard let before = spotBefore(visits),
              let usualPace = visits.count > 1 ? visits.medianPaceSecPerKm : visits.latestPaceSecPerKm,
              let usualHR = visits.count > 1 ? visits.medianHeartRate : visits.latestHeartRate else { return nil }
        return [now, before, paceVerdict(now: paceNow, usual: usualPace), heartRateVerdict(now: hr, usual: usualHR)].joined(separator: " ")
    }

    private static func spotBefore(_ visits: PlaceHistory.Visits) -> String? {
        let bundle = LanguageManager.appBundle
        if visits.count > 1, let pace = paceText(visits.medianPaceSecPerKm), let hr = visits.medianHeartRate {
            return String(localized: "Over your last \(visits.count) passes here you averaged \(pace) at \(hr).", bundle: bundle)
        }
        guard let pace = paceText(visits.latestPaceSecPerKm), let hr = visits.latestHeartRate else { return nil }
        let date = visits.latestDate.formatted(Date.FormatStyle(locale: LanguageManager.appLocale).month(.abbreviated).day())
        return String(localized: "Last time here, \(date), you were at \(pace) and \(hr).", bundle: bundle)
    }

    /// Pace in seconds per km: lower is faster.
    static func paceVerdict(now: Double, usual: Double) -> String {
        let bundle = LanguageManager.appBundle
        guard abs(now - usual) > usual * samePaceShare else { return String(localized: "About your usual pace.", bundle: bundle) }
        let delta = paceDeltaText(abs(now - usual))
        return now < usual
            ? String(localized: "That's \(delta) faster than usual.", bundle: bundle)
            : String(localized: "That's \(delta) slower than usual.", bundle: bundle)
    }

    static func paceDeltaText(_ secondsPerKm: Double) -> String {
        let bundle = LanguageManager.appBundle
        guard units.resolved == .imperial else {
            return String(localized: "\(Int(secondsPerKm.rounded())) seconds per kilometer", bundle: bundle)
        }
        let perMile = Int((secondsPerKm * UnitConstants.metersPerMile / 1000).rounded())
        return String(localized: "\(perMile) seconds per mile", bundle: bundle)
    }

    static func heartRateVerdict(now: Int, usual: Int) -> String {
        let bundle = LanguageManager.appBundle
        let delta = now - usual
        guard abs(delta) > sameHeartRateBeats else { return String(localized: "Heart rate about the same.", bundle: bundle) }
        return delta < 0
            ? String(localized: "Heart rate \(-delta) beats lower.", bundle: bundle)
            : String(localized: "Heart rate \(delta) beats higher.", bundle: bundle)
    }
}

// MARK: - Should I ease off / what's ahead

extension DeterministicIntent {
    static func liveLimit(_ live: AssistantContext.LiveWorkoutSnapshot) -> ClimbHeartRateForecast.Limit? {
        ClimbHeartRateForecast.limit(
            ceilings: live.activeThresholds.compactMap(ClimbHeartRateForecast.Ceiling.init), maxHR: live.userMaxHR,
            thresholdHeartRate: live.thresholdHeartRate, thresholdIsUserSet: live.thresholdHeartRateIsUserSet ?? false
        )
    }

    static func liveEaseOff(_ utterance: String, _ ctx: MatchContext) -> String? {
        guard let live = ctx.liveWorkout, let hr = live.heartRate, let limit = liveLimit(live) else { return nil }
        let imperial = units.resolved == .imperial
        if hr >= limit.bpm { return overLimit(hr: hr, limit: limit) }
        if let forecast = ClimbHeartRateForecast.forecast(climb: live.historyClimbAhead, heartRate: hr, limit: limit) {
            return ClimbHeartRateForecast.warning(forecast, imperial: imperial)
        }
        return underLimit(hr: hr, limit: limit)
    }

    private static func overLimit(hr: Int, limit: ClimbHeartRateForecast.Limit) -> String {
        let (bpm, bundle) = (limit.bpm, LanguageManager.appBundle)
        switch limit.source {
        case .userLimit: return String(localized: "Yes, ease off. Your heart rate is \(hr), over your \(bpm) limit.", bundle: bundle)
        case .threshold: return String(localized: "Yes, ease off. Your heart rate is \(hr), over your threshold of \(bpm).", bundle: bundle)
        case .estimatedThreshold: return String(localized: "Yes, ease off. Your heart rate is \(hr), over your estimated threshold of \(bpm).", bundle: bundle)
        }
    }

    private static func underLimit(hr: Int, limit: ClimbHeartRateForecast.Limit) -> String {
        let (bpm, margin, bundle) = (limit.bpm, limit.bpm - hr, LanguageManager.appBundle)
        switch limit.source {
        case .userLimit: return String(localized: "You're fine. Heart rate \(hr), \(margin) under your \(bpm) limit.", bundle: bundle)
        case .threshold: return String(localized: "You're fine. Heart rate \(hr), \(margin) under your threshold of \(bpm).", bundle: bundle)
        case .estimatedThreshold: return String(localized: "You're fine. Heart rate \(hr), \(margin) under your estimated threshold of \(bpm).", bundle: bundle)
        }
    }

    /// The next climb: the bound route's first, else the one past workouts
    /// agree on; with what it did to the heart rate before, when known.
    static func liveWhatsAhead(_ utterance: String, _ ctx: MatchContext) -> String? {
        guard let live = ctx.liveWorkout else { return nil }
        let bundle = LanguageManager.appBundle
        var history = live.historyClimbAhead
        let next: (distance: Double, length: Double, grade: Double)?
        if let climb = live.routeTopology?.climbsAhead.first {
            next = (climb.distanceToStartMeters, climb.lengthMeters, climb.gradePercent)
            // The past rise belongs to the route's climb only if it is the same one.
            if let past = history, abs(past.distanceMeters - climb.distanceToStartMeters) > PlaceHistory.climbAgreementMeters { history = nil }
        } else {
            next = history.map { ($0.distanceMeters, $0.lengthMeters, $0.gradePercent) }
        }
        guard let next, next.length > 0 else { return nil }
        let (distance, length) = (units.formatDistance(meters: next.distance), units.formatDistance(meters: next.length))
        let ahead = String(localized: "Next climb in \(distance): \(length) at about \(Int(next.grade.rounded())) percent.", bundle: bundle)
        guard let rise = history?.heartRateRise, rise >= ClimbHeartRateForecast.minimumRise else { return ahead }
        return ahead + " " + String(localized: "It has taken your heart rate up \(rise) beats before.", bundle: bundle)
    }
}
