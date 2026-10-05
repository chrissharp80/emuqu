import Foundation

/// Single source of truth for everything the AI Assistant knows about the user.
///
/// Built fresh per request by `ContextBuilder` from the live app state
/// (Archive, BaselineTracker, TrendAnalyzer, AnalysisSummaryGenerator).
/// Apple's on-device FoundationModels provider consumes this via
/// `compactRender()` — its tool-use API is different from the hosted
/// providers, and its 4K context window favours a curated dump over the
/// tool-catalog approach. Hosted providers (Anthropic, OpenAI, DeepSeek,
/// Gemini, Grok) get the history through Fact Catalog tool calls, plus the
/// small always-relevant slice of this type that `renderLiveStateForCloud()`
/// puts in their `<live_state>` block; `compactRender()` also reaches them
/// on the no-tools fallback paths.
///
/// Pure data — no analysis logic lives here. If a number isn't already
/// computed somewhere in the app, it doesn't belong in the context.
struct AssistantContext: Codable {
    // MARK: - Top-level fields

    let generatedAt: Date
    let userProfile: UserProfileSnapshot
    let today: SessionSnapshot?
    /// Yesterday's overnight session in full detail (for day-over-day comparisons).
    let yesterday: SessionSnapshot?
    /// Yesterday's pre-computed analysis summary (cached from MorningResults if available).
    let yesterdayDiagnostic: AnalysisSummarySnapshot?
    let recent: [SessionSnapshotLite] // Most recent first, last 14 days (includes today + yesterday)
    let baselines: BaselineSnapshot?
    let trends7Day: TrendSnapshot?
    let trends30Day: TrendSnapshot?
    let analysisSummary: AnalysisSummarySnapshot?
    /// Compact workout history — last ~30 days of completed workout sessions.
    /// Complements `recent` (which is HRV-oriented) with sport-specific fields
    /// (distance, pace, TRIMP, METs). So "how many runs this week?" and "how
    /// did my last bike ride go?" have answers without the AI having to load
    /// each full session.
    let recentWorkouts: [WorkoutHistoryEntry]
    /// Set ONLY during a live workout. Gives the AI real-time HR / pace /
    /// distance / DFA α1 so "what's my HR right now?" has a real answer.
    /// Made `var` (not `let`) so `AssistantContextSource` can overlay the
    /// freshest `LiveWorkoutBroker` snapshot after the build, so the block
    /// reflects the moment the context is returned rather than the moment
    /// the build started.
    var liveWorkout: LiveWorkoutSnapshot?
    /// Set whenever RRCollector is actively collecting or analyzing a
    /// recording. Same `var` reasoning as `liveWorkout` — overlaid from
    /// LiveHRVBroker on every request so the snapshot is always fresh.
    var liveHRVSession: LiveHRVSnapshot?

    /// Always-on resolved location, populated by
    /// `ContextBuilder` from `RoadGeocodingService.current` plus the
    /// raw `CLLocation` in `AmbientLocationService`. Independent of
    /// `liveWorkout` — the AI sees the user's road / cross-street /
    /// heading / speed whether a workout is recording or not. If location
    /// only reached the prompt inside the `if let live
    /// = liveWorkout` block, non-workout queries ("suggest a route",
    /// "what's around me") would have no location context and the model had
    /// to call the `location.current` tool — which itself depended on
    /// a cache the user might not have warmed yet.
    struct AmbientLocationSnapshot: Codable {
        let road: String?
        let nearestCrossStreet: String?
        let locality: String?
        let subdivision: String?
        let administrativeArea: String?
        let country: String?
        let headingCardinal: String?
        let headingDegrees: Double?
        let speedMS: Double?
        let altitudeMeters: Double?
        let accuracyMeters: Double?
        /// Seconds since the fix was observed. Lets the AI decide if it's
        /// fresh enough for the question being asked (e.g. "what street
        /// am I on" tolerates 60 s; "how fast am I going" doesn't).
        let ageSeconds: Int?
    }

    /// Always-on resolved-address snapshot. `var` so the cache-overlay
    /// path in `AssistantContextSource` can refresh just this field
    /// without rebuilding the whole tree.
    var ambientLocation: AmbientLocationSnapshot?
}

// MARK: - Rendering

extension AssistantContext {
    /// Minimal live-state block for cloud (tool-using)
    /// providers. The system prompt explicitly tells the model to look
    /// for the "📍 LOCATION:" line in static context (see the LOCATION rule in
    /// `AIProvider+SystemPromptText`)
    /// — but cloud providers' `contextRendered` is set to `""` to
    /// keep the Anthropic / Gemini prompt-prefix cache stable. Without this
    /// block the model could never see the location, so "the AI has no
    /// awareness of my location" was unavoidable on cloud
    /// providers regardless of how good the geocoder was.
    ///
    /// This renderer emits ONLY the always-on volatile fields the system
    /// prompt references (location, in the future possibly weather and
    /// "now" snapshot if needed). Heavy session / trend blocks stay in
    /// `compactRender()` for Apple only, where the smaller context
    /// window benefits from the dump. The output ships in the providers'
    /// `<live_state>` user-message-tail block, not the system prefix —
    /// so cache hit-rate on the stable prefix is preserved.
    ///
    /// Privacy: the location line is gated on
    /// an ACTIVE workout. ProviderConsentSheet discloses GPS / street-
    /// name sharing "during a workout" only, so this block must not
    /// attach road / cross-street / heading / speed to every cloud
    /// turn regardless. Gate on `liveWorkout` — the same
    /// LiveWorkoutBroker-sourced snapshot that drives the rest of the
    /// live-workout context (populated by ContextBuilder and overlaid
    /// fresh per request in AssistantContextSource.currentContext();
    /// non-nil only while WorkoutRecorder is publishing ticks, 12 s
    /// staleness gate, cleared at stop). Outside a workout the entries
    /// are OMITTED entirely (not blanked) — matches the disclosure and
    /// saves tokens. User-initiated location facts (`location.*`,
    /// `directions.*` tools) are unaffected: the user explicitly asked.
    /// TODAY's high-value facts (recovery, HRV, overnight HR,
    /// sleep) go up front so cloud models answer "how am I / why did my HRV
    /// drop last night" WITHOUT depending on a tool call. With an EMPTY data
    /// block (everything tool-only), a model that doesn't reliably call tools
    /// (e.g. Grok) answers "I don't have that" even though the app clearly
    /// has the reading. This is the hybrid
    /// context pattern — small always-relevant state in the prompt, tools
    /// for the long tail (history/aggregations). Only TODAY + YESTERDAY go
    /// here; the archive stays behind tools. It lives in the uncached
    /// `<live_state>` tail, so the cached prefix is unaffected.
    /// Each line is labelled by the session's real wake day relative to
    /// `now` (see `liveStateDayLabel`), so a reading from days ago is never
    /// presented as this morning's.
    func renderLiveStateForCloud(now: Date? = nil) -> String {
        let now = now ?? generatedAt
        var out: [String] = []
        if let line = todayLiveStateLine(now: now) { out.append(line) }
        if let y = yesterday, let td = y.timeDomain {
            let rec = y.recoveryScore.map { "\(RecoveryScoreCalculator.displayScore($0 * 10))/100" } ?? "—"
            let label = Self.liveStateDayLabel(y, now: now)
            out.append("\(label) recovery \(rec), HRV RMSSD \(formatNum(td.rmssd, 1))ms, mean HR \(formatNum(td.meanHR, 0))bpm.")
        }
        if liveWorkout != nil, let loc = ambientLocation {
            let locBits = Self.ambientLocationBits(loc)
            if !locBits.isEmpty { out.append("📍 LOCATION: " + locBits.joined(separator: ", ")) }
        }
        return out.joined(separator: "\n")
    }

    /// "TODAY:" / "YESTERDAY:" only when the session woke today / yesterday;
    /// otherwise its date and age. A non-overnight session (the fallback
    /// anchor when no night was recorded) also names its type.
    static func liveStateDayLabel(_ session: SessionSnapshot, now: Date) -> String {
        let wake = session.endDate ?? session.startDate
        let calendar = Calendar.current
        let kind = session.sessionType == SessionType.overnight.rawValue ? "" : " (\(session.sessionType))"
        if calendar.isDate(wake, inSameDayAs: now) { return "TODAY\(kind):" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(wake, inSameDayAs: yesterday) {
            return "YESTERDAY\(kind):"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: wake), to: calendar.startOfDay(for: now)).day ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return "MOST RECENT\(kind), recorded \(formatter.string(from: wake)) (\(days) days ago, NOT today):"
    }

    /// The latest session's one-liner, or nil when nothing has been recorded yet.
    private func todayLiveStateLine(now: Date) -> String? {
        guard let today else { return nil }
        var bits: [String] = [Self.liveStateDayLabel(today, now: now)]
        if let score = today.recoveryScore {
            let tier = today.scoreTier.map { " (tier \($0))" } ?? ""
            bits.append("recovery \(RecoveryScoreCalculator.displayScore(score * 10))/100" + tier + ";")
        }
        if let td = today.timeDomain {
            bits.append("HRV RMSSD \(formatNum(td.rmssd, 1))ms, SDNN \(formatNum(td.sdnn, 1))ms, mean HR \(formatNum(td.meanHR, 0))bpm;")
        }
        if let oh = today.overnightHR {
            bits.append("overnight HR nadir \(formatNum(oh.nadirBPM, 0))bpm, mean \(formatNum(oh.meanBPM, 0))bpm;")
        }
        if let sleep = today.sleep {
            bits.append("sleep \(sleep.totalSleepMinutes / 60)h\(sleep.totalSleepMinutes % 60)m, \(sleepEfficiencyClause(sleep));")
        }
        if let msg = today.scoreMessage, !msg.isEmpty { bits.append("note: \(msg)") }
        guard bits.count > 1 else { return nil }
        return bits.joined(separator: " ")
    }

    private static func ambientLocationBits(_ loc: AmbientLocationSnapshot) -> [String] {
        placeBits(loc) + motionBits(loc)
    }

    /// Where the user is, from the most specific name outward.
    private static func placeBits(_ loc: AmbientLocationSnapshot) -> [String] {
        var bits: [String] = []
        if let road = loc.road { bits.append("on \(road)") }
        if let cross = loc.nearestCrossStreet, cross != loc.road { bits.append("near \(cross)") }
        if let locality = loc.locality { bits.append("in \(locality)") }
        if let sub = loc.subdivision, sub != loc.locality { bits.append("(\(sub))") }
        if let admin = loc.administrativeArea { bits.append(admin) }
        if let country = loc.country { bits.append(country) }
        return bits
    }

    /// Heading, speed, altitude, fix quality, and how stale the fix is.
    private static func motionBits(_ loc: AmbientLocationSnapshot) -> [String] {
        var bits: [String] = []
        if let cardinal = loc.headingCardinal {
            let degrees = loc.headingDegrees.map { " (\(Int($0))°)" } ?? ""
            bits.append("heading \(cardinal)\(degrees)")
        }
        if let speed = loc.speedMS, speed >= 0 {
            bits.append(String(format: "speed %.1f m/s (%.1f km/h)", speed, speed * 3.6))
        }
        if let alt = loc.altitudeMeters { bits.append("alt \(Int(alt))m") }
        if let acc = loc.accuracyMeters, acc > 0 { bits.append("GPS ±\(Int(acc))m") }
        if let age = loc.ageSeconds { bits.append("(\(age)s old)") }
        return bits
    }

    /// The resolved-location line for an active workout.
    ///
    /// Road, locality, heading, speed and accuracy are
    /// populated by `RoadGeocodingService` and `CLLocation`; unless they reach
    /// the compact prompt the AI cannot answer "what street am I on",
    /// "which way am I going", or "how accurate is my fix right now". The model
    /// uses these strings VERBATIM — see the LOCATION RESOLUTION rule in
    /// `toolOverlay`. No more "based on coordinate 39.78, -89.65".
    ///
    /// Speed ships as m/s AND km/h, which saves the model some arithmetic:
    /// m/s is the canonical scientific unit; pace is what runners think in.
    private func liveWorkoutLocationLines(_ live: LiveWorkoutSnapshot) -> [String] {
        var locBits: [String] = []
        if let road = live.currentRoadName { locBits.append("on \(road)") }
        if let cross = live.currentNearestCrossStreet, cross != live.currentRoadName {
            locBits.append("near \(cross)")
        }
        if let locality = live.currentLocality { locBits.append("in \(locality)") }
        if let cardinal = live.currentHeadingCardinal {
            let degrees = live.currentHeadingDegrees.map { " (\(Int($0))°)" } ?? ""
            locBits.append("heading \(cardinal)\(degrees)")
        }
        if let speed = live.currentSpeedMS {
            locBits.append("speed \(formatNum(speed, 1)) m/s (\(formatNum(speed * 3.6, 1)) km/h)")
        }
        if let acc = live.gpsAccuracyMeters { locBits.append("GPS ±\(Int(acc))m") }
        guard !locBits.isEmpty else { return [] }
        return ["📍 LIVE LOCATION: " + locBits.joined(separator: ", ")]
    }

    /// The HR-history line for an active workout.
    ///
    /// Without this the HR time-series trace is not visible to the typed
    /// coach, which can't identify in-workout moments like peak HR at top of
    /// climb. The voice coach has live access via the recorder snapshot
    /// provider; the typed Coach otherwise has only current HR + peak HR.
    /// Tool-capable providers can call `workout.live.timeline` for full detail,
    /// but tool-less providers (Apple Intelligence) couldn't see history at all.
    /// So a compact last-10-min summary ships directly in the system prompt so
    /// every provider has it, bounded at 6 buckets to keep the line short —
    /// full per-second data is still available via the timeline tool for
    /// Anthropic / OpenAI / etc. when they want detail.
    private func liveWorkoutHRHistoryLines(_ live: LiveWorkoutSnapshot) -> [String] {
        let recent = AppDependencies.current.assistant.liveWorkoutBroker.currentSamples()
        guard recent.count >= 6 else { return [] }
        let summaries = hrBucketSummaries(Array(recent.suffix(min(recent.count, 600))))
        guard !summaries.isEmpty else { return [] }
        return ["📈 LIVE HR HISTORY (min/avg/max bpm per window): " + summaries.joined(separator: " | ")]
    }

    /// Bucket the window (last ~10 min at 1 Hz) into ≤6 spans of roughly equal
    /// length, summarising HR per span as `lo–hi m min/avg/max`.
    private func hrBucketSummaries(_ windowSamples: [WorkoutSample]) -> [String] {
        let bucketCount = min(6, max(2, windowSamples.count / 60))
        let perBucket = windowSamples.count / bucketCount
        var out: [String] = []
        for b in 0 ..< bucketCount {
            let lo = b * perBucket
            let hi = (b == bucketCount - 1) ? windowSamples.count : (b + 1) * perBucket
            let slice = windowSamples[lo ..< hi]
            let hrs = slice.compactMap(\.heartRate)
            guard !hrs.isEmpty else { continue }
            let lowMin = slice.first?.offsetSec ?? 0
            let highMin = slice.last?.offsetSec ?? lowMin
            let avg = Int(Double(hrs.reduce(0, +)) / Double(hrs.count))
            out.append("\(lowMin / 60)–\(highMin / 60)m \(hrs.min() ?? avg)/\(avg)/\(hrs.max() ?? avg)")
        }
        return out
    }

    /// The live-workout block — the most important context when one is active,
    /// which is why it sits at the top of the prompt.
    ///
    /// Extracted from `compactRender` verbatim. `CompactRenderParityTests` is
    /// what makes that claim checkable: the rendered prompt is the contract with
    /// five LLM providers, so this move has to be byte-inert.
    private func liveWorkoutLines(formatter: ISO8601DateFormatter) -> [String] {
        guard let live = liveWorkout else { return [] }
        var out = ["🟢 LIVE WORKOUT: " + liveWorkoutBits(live).joined(separator: ", ")]
        out += liveWorkoutLocationLines(live)
        out += liveWorkoutHRHistoryLines(live)
        return out
    }

    /// Snapshot-age stamp. Apple's
    /// SessionCache reuses the system prompt across turns; if the
    /// signature happens to match (e.g., HR identical to the prior
    /// tick), the AI can answer "what's my HR" with a value sampled
    /// many minutes ago. Stamping `snapshot_age_sec` gives the AI an
    /// honest signal AND the prompt tells it explicitly to
    /// refuse-to-claim-current when the snapshot is older than 15s.
    ///
    /// Peak HR is included so the AI can answer "what was my peak HR at
    /// the top of the climb?" without calling a tool; with only current HR
    /// the typed Coach had to hedge ("I don't know your peak").
    ///
    /// The α1 status line when α1 is nil. Left silent, the AI
    /// made up explanations like "warming up" when really the strap had been
    /// silent for 5 minutes; the diagnostic ships so the AI relays the
    /// real reason. Pairs with LiveDFAAnalyzer nulling α1 on
    /// stalled.
    private func liveWorkoutBits(_ live: LiveWorkoutSnapshot) -> [String] {
        var bits = [
            "Sport: \(live.sport)",
            "\(live.elapsedSeconds / 60)m elapsed",
            "snapshot_age_sec=\(max(0, Int(Date().timeIntervalSince(live.snapshotAt))))"
        ]
        if let hr = live.heartRate {
            let pct = live.userMaxHR > 0 ? Int((Double(hr) / Double(live.userMaxHR)) * 100) : nil
            bits.append(pct.map { "HR \(hr) (\($0)% of max \(live.userMaxHR))" } ?? "HR \(hr)")
        }
        if live.peakHR > 0 { bits.append("peak HR \(live.peakHR)") }
        if live.distanceMeters > 0 { bits.append("dist \(formatNum(live.distanceMeters, 0))m") }
        if live.stepCount > 0 { bits.append("\(live.stepCount) steps") }
        if let alpha = live.alpha1 {
            bits.append("α1 \(formatNum(alpha, 2)) (\(live.alpha1Band))")
        } else {
            bits.append("α1 unavailable: \(live.alpha1Status)")
        }
        return bits
    }

    /// The live-HRV block — independent of any workout.
    ///
    /// A user might be recording HRV overnight with no workout, or quick-
    /// streaming before a run that has not started. Either way the AI needs to
    /// see it, so it can answer "how long has it been recording?" instead of
    /// "I don't have access to a live session."
    private func liveHRVLines() -> [String] {
        var out: [String] = []
        // LIVE HRV recording — independent of workout. A user might be
        // recording HRV overnight (no workout), or quick-streaming before
        // a run (workout hasn't started yet). Either way, this makes sure
        // the AI sees it and can answer "how long has it been recording?"
        // instead of "I don't have access to a live session."
        if let hrv = liveHRVSession {
            var bits: [String] = [hrv.phaseDescription]
            if let elapsed = hrv.elapsedSeconds {
                let mins = elapsed / 60
                bits.append("\(mins)m elapsed")
            }
            if hrv.beatCount > 0 { bits.append("\(hrv.beatCount) beats") }
            bits.append(hrv.isCollecting ? "collecting" : "not collecting")
            if let err = hrv.lastErrorDescription, !err.isEmpty {
                bits.append("last error: \(err)")
            }
            out.append("🟢 LIVE RECORDING: " + bits.joined(separator: ", "))
        }
        return out
    }

    /// The always-on location line.
    ///
    /// Renders whenever the ambient-location cache has data,
    /// workout or not. It is the AI's universal location source; the workout
    /// block still contributes route-topology / climb / weather, but the
    /// basic "where am I" does not depend on a recording being active.
    ///
    /// `includeAmbientLocation` is a privacy gate, not a formatting option: an
    /// on-device render always keeps this line because nothing leaves the phone,
    /// while a cloud-bound render must pass the disclosure-matched check, since
    /// ProviderConsentSheet names ambient location as reaching a cloud provider
    /// during an active workout, not at any time. "Always-on" therefore means
    /// always on DEVICE (see the doc comment on `compactRender`).
    private func ambientLocationLines(includeAmbientLocation: Bool) -> [String] {
        guard includeAmbientLocation, let loc = ambientLocation else { return [] }
        let locBits = Self.ambientLocationBits(loc)
        guard !locBits.isEmpty else { return [] }
        return ["📍 LOCATION: " + locBits.joined(separator: ", ")]
    }

    private func profileLines() -> [String] {
        var out: [String] = []
        var profileBits: [String] = []
        if let age = userProfile.age { profileBits.append("\(age)y") }
        if let sex = userProfile.biologicalSex { profileBits.append(sex) }
        if let fl = userProfile.fitnessLevel { profileBits.append(fl) }
        if let vo2 = userProfile.vo2Max { profileBits.append("VO2max \(formatNum(vo2, 1))") }
        if let maxHR = userProfile.maxHR { profileBits.append("maxHR \(maxHR)") }
        if let units = userProfile.unitsPreference { profileBits.append(units) }
        if userProfile.onTrainingBreak { profileBits.append("on-break") }
        if let goal = userProfile.trainingGoal { profileBits.append("training goal: \(goal)") }
        if !profileBits.isEmpty { out.append("Profile: " + profileBits.joined(separator: ", ")) }
        out.append(algorithmLine())
        return out
    }

    /// Surface algorithm + Comeback state so the AI
    /// can answer questions like "why did my score look different
    /// last week?" or "why is my Vitals factor at 0%?". Compact
    /// single-line description; the AI reads structured data, this
    /// is the rendered version that lives in the prompt itself.
    private func algorithmLine() -> String {
        let version = userProfile.scoreAlgorithmVersion
        var bits = ["Algorithm: \(version) (Tier 3: HRV 60% / Sleep 25% / Vitals 15%; Tier 2: HRV 70% / Sleep 30%; Tier 1: HRV only)"]
        if userProfile.comebackModeActive {
            // Stored 0-based; the user counts the first day as day 1.
            let day = userProfile.comebackModeDayInWindow.map { " — day \($0 + 1) of 21" } ?? ""
            bits.append("Comeback mode active\(day) — on a Tier 3 day weights shift to HRV 80% / Sleep 20% / Vitals 0%; Tier 2 (no vitals) keeps its usual weights; the SpO₂ penalty still applies")
        }
        if !userProfile.scoreHistoryRecomputed {
            bits.append("Score history NOT yet recomputed under \(version) — older session scores in this context may still be under an earlier algorithm")
        }
        return bits.joined(separator: ". ")
    }

    /// Today's session — the headline numbers the model reaches for first.
    private func todayLines(formatter: ISO8601DateFormatter) -> [String] {
        guard let today else { return [] }
        return ["", "--- Today's session ---", "Date: \(formatter.string(from: today.startDate))"]
            + todayScoreLines(today)
            + todayPhysiologyLines(today)
            + todayLoadAndFeelingLines(today)
    }

    /// Recovery score and the coach note that goes with it.
    private func todayScoreLines(_ today: SessionSnapshot) -> [String] {
        var out: [String] = []
        if let score = today.recoveryScore {
            out.append(
                "Recovery score: \(RecoveryScoreCalculator.displayScore(score * 10))/100" +
                    (today.scoreTier.map { " (Tier \($0))" } ?? "")
            )
        }
        if let msg = today.scoreMessage, !msg.isEmpty {
            out.append("Coach note: \(msg)")
        }
        return out
    }

    /// HRV, overnight heart rate, sleep.
    private func todayPhysiologyLines(_ today: SessionSnapshot) -> [String] {
        todayHRVLines(today) + todayOvernightHRLines(today) + todaySleepLines(today)
    }

    private func todayHRVLines(_ today: SessionSnapshot) -> [String] {
        var out: [String] = []
        if let td = today.timeDomain {
            out.append("HRV: RMSSD \(formatNum(td.rmssd, 1))ms, SDNN \(formatNum(td.sdnn, 1))ms, mean HR \(formatNum(td.meanHR, 0))bpm")
        }
        return out
    }

    private func todayOvernightHRLines(_ today: SessionSnapshot) -> [String] {
        var out: [String] = []
        if let oh = today.overnightHR {
            var bits = "Overnight HR: nadir \(formatNum(oh.nadirBPM, 0))bpm"
            if let at = oh.nadirAt {
                let df = DateFormatter()
                df.dateFormat = "h:mm a"
                bits += " at \(df.string(from: at))"
            }
            bits += ", range \(formatNum(oh.minBPM, 0))–\(formatNum(oh.maxBPM, 0)), mean \(formatNum(oh.meanBPM, 0))"
            out.append(bits)
        }
        return out
    }

    private func todaySleepLines(_ today: SessionSnapshot) -> [String] {
        var out: [String] = []
        if let sleep = today.sleep {
            let hours = sleep.totalSleepMinutes / 60
            let mins = sleep.totalSleepMinutes % 60
            out.append(
                "Sleep: \(hours)h \(mins)m, \(sleepEfficiencyClause(sleep))" +
                    (sleep.isShortSleep ? " (short)" : "") +
                    (sleep.isFragmented ? " (fragmented)" : "")
            )
        }
        return out
    }

    /// Training load and the user's own rating of how they feel.
    private func todayLoadAndFeelingLines(_ today: SessionSnapshot) -> [String] {
        var out: [String] = []
        if let training = today.training {
            var line = "Training: ATL \(formatNum(training.atl, 0)), CTL \(formatNum(training.ctl, 0)), TSB \(formatNum(training.tsb, 1))"
            if let acwr = training.acwr { line += ", ACWR \(formatNum(acwr, 2))" }
            out.append(line)
        }
        if let feeling = today.morningFeeling {
            let label = ["Terrible", "Poor", "OK", "Good", "Great"][max(0, min(4, feeling - 1))]
            out.append("Self-rated feeling: \(feeling)/5 (\(label))")
        }
        return out
    }

    /// Yesterday's session — a rich snapshot so day-over-day comparisons have
    /// real values on both sides rather than one side and a memory.
    private func yesterdayLines(formatter: ISO8601DateFormatter) -> [String] {
        var out: [String] = []
        if let y = yesterday {
            out.append("")
            out.append("--- Yesterday's session ---")
            out.append("Date: \(formatter.string(from: y.startDate))")
            out += yesterdayMetricLines(y)
        }
        if let yd = yesterdayDiagnostic {
            out.append("Yesterday's summary: \(yd.analysisTitle) — \(yd.analysisExplanation)")
        }
        return out
    }

    /// Score, HRV, overnight HR, sleep, training load, and the self-rating —
    /// each line present only when that half of the night was captured.
    private func yesterdayMetricLines(_ y: SessionSnapshot) -> [String] {
        var out: [String] = []
        if let score = y.recoveryScore {
            let tier = y.scoreTier.map { " (Tier \($0))" } ?? ""
            out.append("Recovery score: \(RecoveryScoreCalculator.displayScore(score * 10))/100" + tier)
        }
        if let td = y.timeDomain {
            out.append("HRV: RMSSD \(formatNum(td.rmssd, 1))ms, SDNN \(formatNum(td.sdnn, 1))ms, mean HR \(formatNum(td.meanHR, 0))bpm")
        }
        if let oh = y.overnightHR { out.append(overnightHRLine(oh)) }
        if let sleep = y.sleep {
            let (h, m) = (sleep.totalSleepMinutes / 60, sleep.totalSleepMinutes % 60)
            out.append("Sleep: \(h)h \(m)m, \(sleepEfficiencyClause(sleep))")
        }
        if let training = y.training { out.append(trainingLoadLine(training)) }
        if let feeling = y.morningFeeling { out.append("Self-rated feeling: \(feeling)/5") }
        return out
    }

    /// "Overnight HR: nadir 48bpm at 3:14 AM, range 46–71".
    private func overnightHRLine(_ oh: OvernightHRSnapshot) -> String {
        var line = "Overnight HR: nadir \(formatNum(oh.nadirBPM, 0))bpm"
        if let at = oh.nadirAt {
            let df = DateFormatter()
            df.dateFormat = "h:mm a"
            line += " at \(df.string(from: at))"
        }
        return line + ", range \(formatNum(oh.minBPM, 0))–\(formatNum(oh.maxBPM, 0))"
    }

    /// "Training: ATL 44, CTL 29, TSB -15.5, ACWR 1.54, prior-day TRIMP 88".
    private func trainingLoadLine(_ training: TrainingSnapshot) -> String {
        var line = "Training: ATL \(formatNum(training.atl, 0)), CTL \(formatNum(training.ctl, 0)), TSB \(formatNum(training.tsb, 1))"
        if let acwr = training.acwr { line += ", ACWR \(formatNum(acwr, 2))" }
        return line + ", prior-day TRIMP \(formatNum(training.yesterdayTrimp, 0))"
    }

    /// Earlier overnight sessions (before the ones shown as today and
    /// yesterday), one line each with training too. `recent` also holds
    /// workouts, so it is filtered to nights rather than assuming its first
    /// two entries are today and yesterday.
    private func earlierSessionLines() -> [String] {
        let cutoff = (yesterday ?? today)?.startDate ?? .distantFuture
        let earlier = Array(recent.filter {
            $0.sessionType == SessionType.overnight.rawValue && $0.date < cutoff
        }.prefix(5))
        guard !earlier.isEmpty else { return [] }
        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.calendar = Calendar(identifier: .gregorian)
        dateOnly.dateFormat = "yyyy-MM-dd"
        return ["", "--- Earlier sessions (most recent first) ---"]
            + earlier.map { earlierSessionLine($0, dateFormatter: dateOnly) }
    }

    /// One earlier session as a single line. Each field appears only when that
    /// night captured it, so a strap-only night still renders cleanly.
    private func earlierSessionLine(_ s: SessionSnapshotLite, dateFormatter: DateFormatter) -> String {
        var line = dateFormatter.string(from: s.date)
        if let r = s.recoveryScore { line += " score \(RecoveryScoreCalculator.displayScore(r * 10))/100" }
        if let r = s.rmssd { line += " RMSSD \(formatNum(r, 1))ms" }
        if let h = s.meanHR { line += " HR \(formatNum(h, 0))bpm" }
        if let sl = s.sleepMinutes { line += " sleep \(sl / 60)h\(sl % 60)m" }
        if let deep = s.deepSleepMinutes { line += " deep \(deep)m" }
        if let rem = s.remSleepMinutes { line += " REM \(rem)m" }
        if let dip = s.nocturnalDipPercent { line += " dip \(formatNum(dip, 1))%" }
        if let tsb = s.tsb { line += " TSB \(formatNum(tsb, 1))" }
        if let acwr = s.acwr { line += " ACWR \(formatNum(acwr, 2))" }
        if let yt = s.yesterdayTrimp, yt > 0 { line += " trimp \(formatNum(yt, 0))" }
        if let f = s.morningFeeling { line += " feel \(f)/5" }
        return line
    }

    /// Baselines, so "how do I compare to my baseline?" has real numbers behind
    /// it instead of an invitation to guess.
    private func baselineLines() -> [String] {
        var out: [String] = []
        // Baselines so "how do I compare to my baseline?" has real numbers.
        if let b = baselines {
            out.append("")
            out.append("--- Personal baseline (\(b.daysInWindow)-day rolling) ---")
            if let r = b.rmssdBaseline { out.append("RMSSD baseline: \(formatNum(r, 1))ms") }
            if let s = b.sdnnBaseline { out.append("SDNN baseline: \(formatNum(s, 1))ms") }
            if let h = b.meanHRBaseline { out.append("Mean HR baseline: \(formatNum(h, 1))bpm") }
            if let s = b.stressIndexBaseline { out.append("Stress index baseline: \(formatNum(s, 1))") }
        }
        return out
    }

    /// The compressed 7-day summary.
    private func weeklySummaryLines() -> [String] {
        guard let trends = trends7Day else { return [] }
        var out = [
            "",
            "--- 7-day trend (\(trends.dataPointCount) sessions) ---",
            "Overall: \(trends.overallTrend)"
        ]
        out.append(contentsOf: trends.metrics.prefix(4).map(metricTrendLine))
        return out
    }

    private func metricTrendLine(_ metric: TrendSnapshot.MetricTrend) -> String {
        var line = "\(metric.metric): mean \(formatNum(metric.mean, 1)), \(metric.trend.lowercased())"
        if let dev = metric.deviationFromBaseline {
            line += ", \(formatNum(dev, 0))% vs baseline"
        }
        return line
    }

    /// The pre-computed narrative — the heaviest hitter in the dump.
    private func narrativeLines() -> [String] {
        guard let summary = analysisSummary else { return [] }
        var out = ["", "--- Summary ---", "\(summary.analysisTitle) — \(summary.analysisExplanation)"]
        if !summary.probableCauses.isEmpty {
            out.append("Probable causes:")
            out += summary.probableCauses.prefix(3).map {
                "  • [\($0.confidence)] \($0.cause): \($0.explanation)"
            }
        }
        if !summary.keyFindings.isEmpty {
            out.append("Key findings:")
            out += summary.keyFindings.prefix(3).map { "  • \($0)" }
        }
        if !summary.actionableSteps.isEmpty {
            out.append("Suggested actions:")
            out += summary.actionableSteps.prefix(3).map { "  • \($0)" }
        }
        return out
    }

    /// One line per recent workout, plus an indented note line when the user
    /// left one — a long comment can't then swallow the metrics line.
    private func recentWorkoutDetailLines(_ recentWindow: ArraySlice<WorkoutHistoryEntry>) -> [String] {
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        var out: [String] = []
        for w in recentWindow {
            out.append(workoutBits(w, dateFormatter: dateOnly).joined(separator: " · "))
            if let note = w.workoutFeelingNote, !note.isEmpty {
                out.append("    note: \(note)")
            }
        }
        return out
    }

    /// Serializer: one optional-unwrap per workout field. The field count IS
    /// the branch count, so the tables below are data rather than control flow
    /// — the same reasoning already recorded on `WorkoutAIContext.asFactSheet`
    /// and `AppFactResolver+WorkoutLive`.
    private func workoutBits(_ w: WorkoutHistoryEntry, dateFormatter: DateFormatter) -> [String] {
        var bits = [dateFormatter.string(from: w.date), w.sport]
        if let dur = w.durationSec {
            let (m, s) = (dur / 60, dur % 60)
            bits.append(s == 0 ? "\(m)min" : "\(m)m\(s)s")
        }
        if let dist = w.distanceMeters, dist >= 100 { bits.append("\(formatNum(dist / 1000.0, 2))km") }
        if let pace = w.averagePaceSecPerKm {
            bits.append(String(format: "%d:%02d/km", Int(pace) / 60, Int(pace) % 60))
        }
        if let avg = w.averageHR { bits.append("avgHR \(formatNum(avg, 0))") }
        if let mx = w.maxHRInSession { bits.append("maxHR \(mx)") }
        if let trimp = w.trimp { bits.append("TRIMP \(formatNum(trimp, 0))") }
        if let tss = w.hrTSS { bits.append("HRSS \(formatNum(tss, 0))") }
        if let dec = w.decouplingPercent { bits.append("decoupl \(formatNum(dec, 1))%") }
        if let mets = w.avgMETs { bits.append("METs \(formatNum(mets, 1))") }
        if let kcal = w.estimatedCalories { bits.append("\(formatNum(kcal, 0))kcal") }
        if let elev = w.elevationGainMeters, elev > 5 { bits.append("elev \(formatNum(elev, 0))m") }
        return bits + sensorBits(w)
    }

    /// Power, cadence, α1, HRR and the self-rated feeling. Each
    /// is here because the AI was asked about it and had to say it could not
    /// see it, and each is gated on its own nil-check so a
    /// walk-with-no-power-meter still renders cleanly; only sessions that
    /// captured these get them spoken aloud in the AI's context dump.
    private func sensorBits(_ w: WorkoutHistoryEntry) -> [String] {
        var bits: [String] = []
        if let np = w.normalizedPowerWatts { bits.append("NP \(formatNum(np, 0))W") }
        if let avgW = w.avgPowerWatts { bits.append("avgP \(formatNum(avgW, 0))W") }
        if let peakW = w.peakPowerWatts { bits.append("peakP \(peakW)W") }
        if let ptss = w.powerTSS { bits.append("powerLoad \(formatNum(ptss, 0))") }
        if let ifVal = w.intensityFactor { bits.append("IF \(formatNum(ifVal, 2))") }
        if let cad = w.avgCadenceSpm { bits.append("cad \(cad)spm") }
        if let a1 = w.alpha1Mean { bits.append("α1 \(formatNum(a1, 2))") }
        if let h1 = w.hrr1MinDrop { bits.append("HRR-1m -\(h1)bpm") }
        if let h2 = w.hrr2MinDrop { bits.append("HRR-2m -\(h2)bpm") }
        if let feel = w.workoutFeeling { bits.append("felt \(feel)/5") }
        return bits
    }

    /// Recent workouts in full per-session detail, so the AI can answer about a
    /// specific session rather than only about aggregates.
    ///
    /// A one-liner sport histogram ("2 run, 1
    /// bike") is useless for any real question — users complain
    /// the AI has no awareness of workouts at all. So we emit one line per
    /// session for the last 14 (≈2 weeks), each with date, sport, duration,
    /// distance, pace, avg/max HR, TRIMP, hrTSS, METs, estimated kcal — every
    /// metric we have. Adds ~14 lines to the prompt at ~80 chars each (~1100
    /// chars), well within budget even for the on-device Apple Foundation
    /// provider.
    private func recentWorkoutLines() -> [String] {
        guard !recentWorkouts.isEmpty else { return [] }
        let recentWindow = recentWorkouts.prefix(14)
        var out = [""] + weeklyRollupLines()
        out += recentWorkoutDetailLines(recentWindow)
        if recentWorkouts.count > recentWindow.count {
            out.append("(+ \(recentWorkouts.count - recentWindow.count) older — call workout.list to see them)")
        }
        return out
    }

    /// Quick rollup so the model has aggregate weekly numbers without doing
    /// arithmetic in its head.
    private func weeklyRollupLines() -> [String] {
        let shown = min(recentWorkouts.count, 14)
        let last7Days = recentWorkouts.filter { Date().timeIntervalSince($0.date) / 86400 <= 7 }
        let totalKm7 = last7Days.compactMap { $0.distanceMeters }.reduce(0, +) / 1000.0
        let totalTrimp7 = last7Days.compactMap { $0.trimp }.reduce(0, +)
        let totalDur7Min = last7Days.compactMap { $0.durationSec }.reduce(0, +) / 60
        var out = [
            "--- Recent workouts (last \(shown) shown; " +
                "7-day totals: \(last7Days.count) sessions, \(formatNum(totalKm7, 1))km, " +
                "\(totalDur7Min)min, TRIMP \(formatNum(totalTrimp7, 0))) ---"
        ]
        let sportCounts7 = Dictionary(grouping: last7Days, by: { $0.sport })
            .mapValues(\.count)
            .map { "\($0.value) \($0.key)" }
            .sorted()
            .joined(separator: ", ")
        if !sportCounts7.isEmpty { out.append("Sport mix (7d): \(sportCounts7)") }
        if let monthLine = thirtyDayTotalLine(sevenDayCount: last7Days.count) { out.append(monthLine) }
        return out
    }

    /// The 30-day total, but only when it covers more than the 7-day window
    /// already reported.
    private func thirtyDayTotalLine(sevenDayCount: Int) -> String? {
        let last30Days = recentWorkouts.filter { Date().timeIntervalSince($0.date) / 86400 <= 30 }
        guard last30Days.count > sevenDayCount else { return nil }
        let totalKm30 = last30Days.compactMap { $0.distanceMeters }.reduce(0, +) / 1000.0
        return "30-day total: \(last30Days.count) sessions, \(formatNum(totalKm30, 1))km"
    }

    /// Compact render targeted at Apple's on-device model (~1.5K tokens).
    /// Today's headline numbers + brief 7-day trend + key findings.
    /// Drops per-metric breakdowns and historical session list.
    ///
    /// `includeAmbientLocation`: the 📍 LOCATION line carries
    /// street-level position. On-device (Apple) renders keep it always —
    /// nothing leaves the phone. When this render is bound for a CLOUD
    /// provider (no-tools fallback, Apple-guardrail escalation), callers
    /// must pass the same disclosure-matched gate `renderLiveStateForCloud`
    /// uses: ambient location goes to the cloud only during an active
    /// workout (ProviderConsentSheet promises exactly that).
    /// Each prompt section has its own builder below; `CompactRenderParityTests`
    /// pins the output, since every byte of it is the contract with the
    /// providers.
    /// Deliberately no per-render `Generated:` ISO timestamp:
    /// rebuilt from `Date()` every send, it made every
    /// provider's prompt-cache fingerprint change minute-by-minute
    /// even when nothing else had moved. `nowSnapshot()` in the
    /// variable system block already gives the model the current time,
    /// so the line would be redundant AND the single biggest cache-buster
    /// in `compactRender`, since the dump goes to every provider, not
    /// just Apple.
    func compactRender(includeAmbientLocation: Bool = true) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var out = ["=== Emuqu — User Context (compact) ==="]
        out += liveWorkoutLines(formatter: formatter)
        out += liveHRVLines()
        out += ambientLocationLines(includeAmbientLocation: includeAmbientLocation)
        out += profileLines()
        out += todayLines(formatter: formatter)
        out += yesterdayLines(formatter: formatter)
        out += earlierSessionLines()
        out += baselineLines()
        out += weeklySummaryLines()
        out += narrativeLines()
        out += recentWorkoutLines()
        return out.joined(separator: "\n")
    }
}

// MARK: - Local helpers

func formatNum(_ value: Double, _ digits: Int) -> String {
    String(format: "%.\(digits)f", value)
}

/// "efficiency 92%", or "efficiency not measured" for a night whose wake was
/// not measured (a passive Apple Watch heart-rate estimate).
func sleepEfficiencyClause(_ sleep: AssistantContext.SleepSnapshot) -> String {
    guard let efficiency = sleep.sleepEfficiency else { return "efficiency not measured" }
    return "efficiency \(formatNum(efficiency * 100, 0))%"
}
