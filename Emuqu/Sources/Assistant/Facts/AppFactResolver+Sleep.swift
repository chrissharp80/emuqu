import CoreLocation
import CoreMotion
import Foundation
import os

// The CMAltimeter availability helper, the local-day date format, the
// overnight archive lookups, and the sleep / hrv / vitals / recovery
// namespaces that read them.

// MARK: - CMAltimeter availability check
//
// Stand-alone helper so the app.* namespace can answer without
// importing CoreMotion into this file's import set.
func CMAltimeterIsAvailable() -> Bool {
    #if canImport(CoreMotion)
        return CMAltimeter.isRelativeAltitudeAvailable()
    #else
        return false
    #endif
}

// MARK: - Local-day parameter format

/// The `yyyy-MM-dd` format every `by_date` fact parameter and
/// `app.now.local_date` use. Pinned to en_US_POSIX and the Gregorian
/// calendar so a user on the Japanese or Buddhist calendar, or with
/// Arabic-Indic digits, still produces and parses a Gregorian date in
/// ASCII digits; the time zone is the device's, so the string names the
/// user's local day.
enum FactLocalDay {
    static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

// MARK: - Overnight archive helpers (shared by sleep/hrv/vitals/recovery)

/// Overnight sessions are the app's primary HRV + sleep + vitals surface.
/// Four namespaces below (sleep, hrv, vitals, recovery) all read from them,
/// so their availability / lookup helpers live here to avoid duplication.
enum OvernightArchive {
    /// Session types that carry an HRV analysis the assistant can reason
    /// about. Naps and quick spot-checks run the same analysis pipeline, so
    /// they count toward availability: a user whose only reading is a quick
    /// one still gets the `hrv.*` tools. The single-reading lookups below
    /// prefer the overnight, the way the dashboard does, and every record
    /// carries `session_type` so the model can tell a nap or quick reading
    /// from a night.
    private static let hrvBearingTypes: Set<SessionType> = [.overnight, .nap, .quick]

    /// Earliest + latest HRV-bearing-session date, or nil when none exist.
    /// Availability closures read this to gate the schema — no sessions of
    /// any HRV-bearing type means all four `hrv.*` / `sleep.*` / `vitals.*` /
    /// `recovery.*` namespaces vanish from the tool catalog.
    static func availability(_ archive: SessionArchive) -> Availability {
        let dates = archive.entries
            .filter { hrvBearingTypes.contains($0.sessionType) }
            .map(\.date)
        guard let earliest = dates.min(), let latest = dates.max() else {
            return .unavailable
        }
        return Availability(hasData: true, validRange: earliest ... latest, lastUpdated: latest)
    }

    /// The reading the dashboard would headline: on the most recent local
    /// day (midpoint rule) with a reliable reading, the longest overnight,
    /// else the longest nap or quick reading. `.insufficient` / `.preSleep`
    /// partials never qualify. `scoredOnly` keeps only readings with a
    /// recovery score, which quick readings never get, so the recovery facts
    /// agree with the ring.
    static func latest(_ archive: SessionArchive, scoredOnly: Bool = false) -> HRVSession? {
        let candidates = reliableEntries(archive, scoredOnly: scoredOnly)
        let cal = Calendar.current
        guard let latestDay = candidates.map({ cal.startOfDay(for: midpoint(of: $0)) }).max() else { return nil }
        let sameDay = candidates.filter { cal.isDate(midpoint(of: $0), inSameDayAs: latestDay) }
        return representative(of: sameDay).flatMap { archive.retrieveLightweightOrLog($0.sessionId) }
    }

    /// Look up an HRV-bearing session by local calendar date using the
    /// midpoint-in-day rule: a session is assigned to the
    /// local day its midpoint falls in. This matches how users refer to
    /// "Tuesday's sleep" — it started Monday night but covers Tuesday.
    /// Same selection as `latest` within that day.
    static func byDate(_ iso: String, archive: SessionArchive, scoredOnly: Bool = false) -> HRVSession? {
        guard let target = FactLocalDay.formatter().date(from: iso) else { return nil }
        let cal = Calendar.current
        let sameDay = reliableEntries(archive, scoredOnly: scoredOnly)
            .filter { cal.isDate(midpoint(of: $0), inSameDayAs: target) }
        return representative(of: sameDay).flatMap { archive.retrieveLightweightOrLog($0.sessionId) }
    }

    /// Every reliable reading in the period, newest first. Lists keep naps
    /// and quick readings; each record's `session_type` labels them. Same
    /// midpoint rule as `byDate`: on the start date, last night began
    /// yesterday and "today" came back empty beside this morning's score.
    static func inPeriod(_ period: String, archive: SessionArchive, types: Set<SessionType>? = nil) -> [HRVSession] {
        guard let interval = PeriodParser.interval(for: period) else { return [] }
        let allowed = types ?? hrvBearingTypes
        return reliableEntries(archive, scoredOnly: false)
            .filter { allowed.contains($0.sessionType) && interval.containsBeforeEnd(midpoint(of: $0)) }
            .sorted { $0.date > $1.date }
            .compactMap { archive.retrieveLightweightOrLog($0.sessionId) }
    }

    /// Adds `session_type` to a record so a nap or quick reading is never
    /// mistaken for a night. Non-record values pass through unchanged.
    static func labeled(_ value: FactValue, _ session: HRVSession) -> FactValue {
        guard case .record(var fields) = value else { return value }
        fields["session_type"] = .string(session.sessionType.rawValue)
        return .record(fields)
    }

    private static func reliableEntries(_ archive: SessionArchive, scoredOnly: Bool) -> [SessionArchiveEntry] {
        archive.entries.filter {
            hrvBearingTypes.contains($0.sessionType) && $0.isReliableForHRVAggregates
                && (!scoredOnly || $0.recoveryScore != nil)
        }
    }

    /// The longest overnight, else the longest other reading. Longest, not
    /// newest: a 22-minute partial must not beat the real night.
    private static func representative(of entries: [SessionArchiveEntry]) -> SessionArchiveEntry? {
        let overnights = entries.filter { $0.sessionType == .overnight }
        let pool = overnights.isEmpty ? entries : overnights
        return pool.max { duration(of: $0) < duration(of: $1) }
    }

    private static func duration(of entry: SessionArchiveEntry) -> TimeInterval {
        max(0, (entry.endDate ?? entry.date).timeIntervalSince(entry.date))
    }

    private static func midpoint(of entry: SessionArchiveEntry) -> Date {
        entry.date.addingTimeInterval(duration(of: entry) / 2)
    }
}

// MARK: - sleep.* namespace
//
// Sleep data lives on `HRVSession.sleepSnapshot` for overnight sessions.
// Exposes last-night convenience, historic by-date lookup, and recent-N
// listing so the AI can answer both "how did I sleep?" and "how did I
// sleep last Tuesday compared to the week before?" without guesswork.

struct SleepNamespace: FactNamespaceResolver {
    let namespace = "sleep"
    let archive: SessionArchive
    let settings: @Sendable () -> UserSettings

    /// Build a sleep record for one session. Keys map 1:1 to fields on
    /// `SleepData` and are snake-cased for JSON consumption.
    ///
    /// efficiency_percent is already on 0–100 scale (matches the source
    /// `SleepData.sleepEfficiency`); the AssistantContext seam divides by
    /// 100 for Apple's compact render, but for tool results the model is
    /// easier to read when percent means percent. It is left out for a night
    /// whose wake was not measured (`SleepData.measuredSleepEfficiency`).
    ///
    /// The source is the frozen `sleepSnapshot` OR a live HealthKit read
    /// (see `sleepRecordAsync`). Same shape either way — `data_source` tells
    /// the model when the numbers came from a LIVE read because the night
    /// hadn't been accepted (or synced late), so it can say "based on your
    /// synced sleep, not yet locked into today's score."
    private static func sleepRecordFromData(_ sleep: SleepData, date: Date, userAge: Int?, typicalSleepHours: Double, live: Bool) -> FactValue {
        var record: [String: FactValue] = [
            "date": .date(date),
            "total_sleep_minutes": .integer(sleep.nightSleepMinutes),
            "in_bed_minutes": .integer(sleep.inBedMinutes),
            "awake_minutes": .integer(sleep.awakeMinutes)
        ]
        if let efficiency = sleep.measuredSleepEfficiency { record["efficiency_percent"] = .double(efficiency) }
        if let deep = sleep.deepSleepMinutes { record["deep_minutes"] = .integer(deep) }
        if let rem = sleep.remSleepMinutes { record["rem_minutes"] = .integer(rem) }
        if let latency = sleep.sleepLatencyMinutes { record["latency_minutes"] = .integer(latency) }
        record.merge(
            sleepScienceFields(sleep, userAge: userAge, typicalSleepHours: typicalSleepHours)
        ) { current, _ in current }
        if live { record["data_source"] = .string("live_healthkit_pending_acceptance") }
        return .record(record)
    }

    /// Sleep-science layer (SleepScienceAnalyzer) — the fragmentation,
    /// cycles, architecture, and enhanced 0–100 quality score the app's
    /// Sleep detail screen shows. Pure computation over the stored stages,
    /// so it's free to include on every sleep read. `age_norms` fields appear
    /// only when the user set a birthday.
    private static func sleepScienceFields(
        _ sleep: SleepData,
        userAge: Int?,
        typicalSleepHours: Double
    ) -> [String: FactValue] {
        guard let sci = SleepScienceAnalyzer.analyze(
            sleepData: sleep, userAge: userAge, typicalSleepHours: typicalSleepHours
        ) else { return [:] }
        var out: [String: FactValue] = [
            "fragmentation_index": .double(sci.fragmentationIndex),
            "awakening_count": .integer(sci.awakeningCount),
            "sleep_cycles": .integer(sci.cycleCount),
            "architecture_score": .double(sci.architecture.architectureScore),
            "deep_front_loaded": .boolean(sci.architecture.deepFrontLoaded),
            "rem_back_loaded": .boolean(sci.architecture.remBackLoaded),
            "enhanced_sleep_score": .double(sci.enhancedScore)
        ]
        if let norms = sci.ageNorms {
            out["deep_in_expected_range"] = .boolean(norms.isDeepInRange)
            out["rem_in_expected_range"] = .boolean(norms.isREMInRange)
        }
        return out
    }

    /// Snapshot path (sync) — used by by_date / recent.
    private static func sleepRecord(for session: HRVSession?, userAge: Int?, typicalSleepHours: Double) -> FactValue {
        guard let session else { return .missing(reason: .notRecorded, detail: "no overnight session matched") }
        guard let sleep = session.sleepSnapshot else { return .missing(reason: .notRecorded, detail: "session has no sleep snapshot") }
        let record = sleepRecordFromData(sleep, date: session.startDate, userAge: userAge, typicalSleepHours: typicalSleepHours, live: false)
        return OvernightArchive.labeled(record, session)
    }

    /// Snapshot-first, else a LIVE HealthKit read. The frozen `sleepSnapshot`
    /// is written at morning acceptance; before that (un-accepted night) or
    /// when the Watch synced sleep AFTER acceptance, the snapshot is nil and
    /// the app's own HealthKit data still has the night. Rather than answer
    /// "no sleep", fetch it live (cache-warm by morning via the sleep observer)
    /// so the assistant reflects the app's truth.
    private func sleepRecordAsync(for session: HRVSession?, userAge: Int?, typicalSleepHours: Double) async -> FactValue {
        guard let session else { return .missing(reason: .notRecorded, detail: "no overnight session matched") }
        if session.sleepSnapshot != nil {
            return Self.sleepRecord(for: session, userAge: userAge, typicalSleepHours: typicalSleepHours)
        }
        let live: FactValue? = await FactResolveTimeout.withTimeout(seconds: 5) {
            await Self.liveSleepRecord(for: session, userAge: userAge, typicalSleepHours: typicalSleepHours)
        }
        return live.map { OvernightArchive.labeled($0, session) }
            ?? .missing(reason: .notRecorded, detail: "no sleep snapshot and HealthKit returned no sleep for that window")
    }

    /// Nil on a query failure or a night HealthKit has no sleep for.
    private static func liveSleepRecord(for session: HRVSession, userAge: Int?, typicalSleepHours: Double) async -> FactValue? {
        do {
            let data = try await AppDependencies.current.collection.healthKitManager.fetchSleepData(
                for: session.startDate, recordingEnd: session.endDate ?? Date()
            )
            guard data.nightSleepMinutes > 0 else { return nil }
            return sleepRecordFromData(data, date: session.startDate, userAge: userAge, typicalSleepHours: typicalSleepHours, live: true)
        } catch {
            return nil
        }
    }

    var entries: [FactEntry] {
        return [
            sleepLatestEntry,
            sleepByDateDateEntry,
            sleepRecentPeriodEntry
        ]
    }

    private var sleepByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "sleep.by_date($date)",
            paramExample: "2026-04-21",
            description: "Sleep record for a specific local date (yyyy-MM-dd). Uses the midpoint-in-day rule — a session spanning midnight is assigned to the local day its midpoint falls in, so 'Tuesday's sleep' is the night that ends Tuesday morning, not the one that started Tuesday.",
            availability: { OvernightArchive.availability(self.archive) },
            resolve: { param, _ in
                let cfg = self.settings()
                return Self.sleepRecord(for: OvernightArchive.byDate(param, archive: self.archive), userAge: cfg.age, typicalSleepHours: cfg.typicalSleepHours)
            }
        )
    }

    private var sleepRecentPeriodEntry: FactEntry {
        .parameterized(
            pattern: "sleep.recent($period)",
            paramExample: "last_7d",
            description: "List of sleep records over a recent period (last_7d / last_14d / last_30d / last_90d / all_time), overnights and naps. Each item is the same record shape as sleep.latest; session_type says which. Most recent first.",
            availability: { OvernightArchive.availability(self.archive) },
            resolve: { param, _ in
                let sessions = OvernightArchive.inPeriod(param, archive: self.archive, types: [.overnight, .nap])
                guard !sessions.isEmpty else {
                    return .missing(reason: .notRecorded, detail: "no overnight sessions in period")
                }
                let cfg = self.settings()
                return .list(sessions.map { Self.sleepRecord(for: $0, userAge: cfg.age, typicalSleepHours: cfg.typicalSleepHours) })
            }
        )
    }

    private var sleepLatestEntry: FactEntry {
        .fixed(
            key: "sleep.latest",
            description: """
            Last overnight sleep as a record: total_sleep_minutes, in_bed_minutes, efficiency_percent (0–100; absent when the night's wake was not measured), \
            awake_minutes, deep_minutes, rem_minutes, latency_minutes, PLUS the sleep-science layer the app's Sleep detail screen shows \
            — fragmentation_index, awakening_count, sleep_cycles, architecture_score, deep_front_loaded, rem_back_loaded, enhanced_sleep_score (0–100), and deep/rem_in_expected_range (age-adjusted). If last night hasn't been accepted \
            yet (or HealthKit synced sleep after acceptance), this falls back to a LIVE HealthKit read and marks data_source=live_healthkit_pending_acceptance — so 'how did I sleep last night?' answers even before the morning results \
            are opened. Use for 'how did I sleep?', 'was my sleep fragmented?', 'how many cycles?', 'was my sleep architecture healthy?'.
            """,
            valueType: "Record",
            availability: { OvernightArchive.availability(self.archive) },
            body: .awaitable {
                let cfg = self.settings()
                return await self.sleepRecordAsync(for: OvernightArchive.latest(self.archive), userAge: cfg.age, typicalSleepHours: cfg.typicalSleepHours)
            }
        )
    }
}

// MARK: - hrv.* namespace
//
// Time + frequency domain HRV metrics from overnight sessions'
// analysisResult. Exposes the canonical metrics (RMSSD, SDNN, meanHR,
// LF/HF) plus the full record for deep inspection.

struct HRVNamespace: FactNamespaceResolver {
    let namespace = "hrv"
    let archive: SessionArchive

    private static func hrvRecord(for session: HRVSession?) -> FactValue {
        guard let session else {
            return .missing(reason: .notRecorded, detail: "no overnight session matched")
        }
        guard let analysis = session.analysisResult else {
            return .missing(reason: .notYetComputed, detail: "session has no analysis result yet")
        }
        var record = timeDomainFields(session: session, analysis: analysis)
        record.merge(nonlinearFields(analysis)) { current, _ in current }
        record.merge(frequencyFields(analysis)) { current, _ in current }
        record.merge(ansFields(analysis)) { current, _ in current }
        if let nadirAt = nadirWallClock(session: session, analysis: analysis) {
            record["overnight_nadir_at_iso"] = .date(nadirAt)
        }
        return OvernightArchive.labeled(.record(record), session)
    }

    /// The optional metrics in the field tables below are a field table, not
    /// control flow: every entry says "include this key when the value
    /// exists". Assigning `nil` to a dictionary subscript removes the key,
    /// which is exactly what an `if let` per field would do — `record`
    /// is a dictionary, so insertion order does not matter either.
    private static func optionalDoubles(_ pairs: [(String, Double?)]) -> [String: FactValue] {
        var out: [String: FactValue] = [:]
        for (key, value) in pairs {
            out[key] = value.map { FactValue.double($0) }
        }
        return out
    }

    /// Time-domain metrics plus the window-scoped HR summary.
    ///
    /// Window-scoped HR (5-min recovery slice): the AI should treat these as
    /// the recovery-window snapshot, not the whole-night numbers — the latter
    /// come from the `overnight_*` keys in `nonlinearFields`.
    ///
    /// `artifact_percent` is exposed so the AI
    /// can caveat answers when the artifact rate is high.
    private static func timeDomainFields(
        session: HRVSession,
        analysis: HRVAnalysisResult
    ) -> [String: FactValue] {
        let td = analysis.timeDomain
        return [
            "date": .date(session.startDate),
            "rmssd_ms": .double(td.rmssd),
            "sdnn_ms": .double(td.sdnn),
            "pnn50_percent": .double(td.pnn50),
            "sdsd_ms": .double(td.sdsd),
            "sd_hr_bpm": .double(td.sdHR),
            "window_mean_hr_bpm": .double(td.meanHR),
            "window_min_hr_bpm": .double(td.minHR),
            "window_max_hr_bpm": .double(td.maxHR),
            "artifact_percent": .double(analysis.artifactPercentage)
        ]
    }

    /// Nonlinear metrics — DFA α1 is the gold-standard nonlinear
    /// marker; SD1/SD2 visualize the same parasympathetic signal as
    /// RMSSD on the Poincaré plot. User explicitly asked for
    /// Triangular Index above + "search for others" → these were added.
    ///
    /// The whole-night HR summary rides along here: it's what the user
    /// actually means when they ask "what was my nadir last night?".
    /// Computed across the FULL series at analysis time and persisted on the
    /// result so we don't have to ship the RR series in every prompt.
    private static func nonlinearFields(_ analysis: HRVAnalysisResult) -> [String: FactValue] {
        let nl = analysis.nonlinear
        var out: [String: FactValue] = [
            "sd1_ms": .double(nl.sd1),
            "sd2_ms": .double(nl.sd2),
            "sd1_sd2_ratio": .double(nl.sd1Sd2Ratio)
        ]
        out.merge(optionalDoubles([
            ("triangular_index", analysis.timeDomain.triangularIndex),
            ("dfa_alpha1", nl.dfaAlpha1),
            ("dfa_alpha2", nl.dfaAlpha2),
            ("dfa_alpha1_r2", nl.dfaAlpha1R2),
            ("sample_entropy", nl.sampleEntropy),
            ("approximate_entropy", nl.approxEntropy),
            ("overnight_nadir_hr_bpm", analysis.overnightNadirHR),
            ("overnight_min_hr_bpm", analysis.overnightMinHR),
            ("overnight_max_hr_bpm", analysis.overnightMaxHR),
            ("overnight_mean_hr_bpm", analysis.overnightMeanHR)
        ])) { current, _ in current }
        return out
    }

    /// The wall-clock time of the overnight nadir, when we can derive it from
    /// the series timeline. Falls back to session start + offset.
    private static func nadirWallClock(session: HRVSession, analysis: HRVAnalysisResult) -> Date? {
        guard let offsetMs = analysis.overnightNadirTimeMs else { return nil }
        guard let series = session.rrSeries else {
            return session.startDate.addingTimeInterval(TimeInterval(offsetMs) / 1000.0)
        }
        return series.wallClockTime(forTMs: offsetMs)
    }

    private static func frequencyFields(_ analysis: HRVAnalysisResult) -> [String: FactValue] {
        guard let fd = analysis.frequencyDomain else { return [:] }
        var out: [String: FactValue] = [
            "lf_power_ms2": .double(fd.lf),
            "hf_power_ms2": .double(fd.hf),
            "total_power_ms2": .double(fd.totalPower)
        ]
        out.merge(optionalDoubles([
            ("lf_hf_ratio", fd.lfHfRatio),
            ("vlf_power_ms2", fd.vlf)
        ])) { current, _ in current }
        return out
    }

    /// PNS/SNS Index + respiration
    /// rate + nocturnal HR dip are all useful coaching signals
    /// the AI can cite. Daytime resting HR + nocturnal
    /// median HR provide the dip's denominator/numerator so the
    /// AI can explain WHY the dip is what it is.
    private static func ansFields(_ analysis: HRVAnalysisResult) -> [String: FactValue] {
        guard let ans = analysis.ansMetrics else { return [:] }
        return optionalDoubles([
            ("stress_index", ans.stressIndex),
            ("readiness_score", ans.readinessScore),
            ("pns_index", ans.pnsIndex),
            ("sns_index", ans.snsIndex),
            ("respiration_rate_per_min", ans.respirationRate),
            ("nocturnal_hr_dip_percent", ans.nocturnalHRDip),
            ("daytime_resting_hr_bpm", ans.daytimeRestingHR),
            ("nocturnal_median_hr_bpm", ans.nocturnalMedianHR)
        ])
    }

    var entries: [FactEntry] {
        return [
            hrvLatestEntry,
            hrvByDateDateEntry,
            hrvRecentPeriodEntry
        ]
    }

    private var hrvByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "hrv.by_date($date)",
            paramExample: "2026-04-21",
            description: "HRV analysis for a specific local date (yyyy-MM-dd). Midpoint-in-day session matching.",
            availability: { OvernightArchive.availability(self.archive) },
            resolve: { param, _ in
                Self.hrvRecord(for: OvernightArchive.byDate(param, archive: self.archive))
            }
        )
    }

    private var hrvRecentPeriodEntry: FactEntry {
        .parameterized(
            pattern: "hrv.recent($period)",
            paramExample: "last_7d",
            description: "List of HRV analyses over a recent period. Each item is the same record shape as hrv.latest. Most recent first.",
            availability: { OvernightArchive.availability(self.archive) },
            resolve: { param, _ in
                let sessions = OvernightArchive.inPeriod(param, archive: self.archive)
                guard !sessions.isEmpty else {
                    return .missing(reason: .notRecorded, detail: "no overnight sessions in period")
                }
                return .list(sessions.map { Self.hrvRecord(for: $0) })
            }
        )
    }

    private var hrvLatestEntry: FactEntry {
        .fixed(
            key: "hrv.latest",
            description: """
            Latest HRV analysis as a record: the dashboard's reading (the night's overnight; a nap or quick reading only on a day with no reliable overnight — session_type says which). Window-scoped fields (window_mean_hr_bpm, window_min_hr_bpm, window_max_hr_bpm) \
            come from the 5-min recovery analysis window. Whole-night fields (overnight_nadir_hr_bpm, overnight_nadir_at_iso, \
            overnight_min_hr_bpm, overnight_max_hr_bpm, overnight_mean_hr_bpm) span the entire recording — use these when the user asks about 'nadir' / 'lowest HR last night' / 'when did my HR bottom out'. Also: rmssd_ms, sdnn_ms, pnn50_percent, \
            lf/hf power, lf_hf_ratio, stress_index, readiness_score.
            """,
            valueType: "Record",
            availability: { OvernightArchive.availability(self.archive) },
            resolve: { Self.hrvRecord(for: OvernightArchive.latest(self.archive)) }
        )
    }
}

// MARK: - vitals.* namespace
//
// Respiratory rate, SpO2, wrist temperature, resting HR — from the
// RecoveryVitals snapshot on overnight sessions.

struct VitalsNamespace: FactNamespaceResolver {
    let namespace = "vitals"
    let archive: SessionArchive

    private static func vitalsRecordFromData(_ v: RecoveryVitals, date: Date, live: Bool) -> FactValue {
        var record: [String: FactValue] = ["date": .date(date)]
        if let rr = v.respiratoryRate { record["respiratory_rate_bpm"] = .double(rr) }
        if let rrb = v.respiratoryRateBaseline { record["respiratory_rate_baseline_bpm"] = .double(rrb) }
        if let dev = v.respiratoryDeviation { record["respiratory_deviation_bpm"] = .double(dev) }
        if let spo2 = v.oxygenSaturation { record["oxygen_saturation_percent"] = .double(spo2) }
        if let spo2min = v.oxygenSaturationMin { record["oxygen_saturation_min_percent"] = .double(spo2min) }
        // Tonight minus the personal baseline. The raw reading and baseline
        // are offsets from a population 36.5 °C, so neither is passed on.
        if let temp = v.wristTemperatureDeviation { record["wrist_temperature_deviation_c"] = .double(temp) }
        if let rhr = v.restingHeartRate { record["resting_heart_rate_bpm"] = .double(rhr) }
        record["status"] = .string({
            switch v.status {
            case .normal: "normal"
            case .elevated: "elevated"
            case .warning: "warning"
            }
        }())
        if live { record["data_source"] = .string("live_healthkit_pending_acceptance") }
        return .record(record)
    }

    /// Snapshot path (sync) — used by by_date.
    private static func vitalsRecord(for session: HRVSession?) -> FactValue {
        guard let session else { return .missing(reason: .notRecorded, detail: "no overnight session matched") }
        guard let v = session.vitalsSnapshot, !v.isEmpty else {
            return .missing(reason: .notRecorded, detail: "session has no vitals recorded")
        }
        return OvernightArchive.labeled(vitalsRecordFromData(v, date: session.startDate, live: false), session)
    }

    /// Snapshot-first, else a LIVE HealthKit read. Vitals (SpO2 / respiration /
    /// wrist temp) frequently sync minutes-to-hours AFTER acceptance, so the
    /// frozen snapshot can be empty even when HealthKit already has them.
    private func vitalsRecordAsync(for session: HRVSession?) async -> FactValue {
        guard let session else { return .missing(reason: .notRecorded, detail: "no overnight session matched") }
        if let v = session.vitalsSnapshot, !v.isEmpty {
            return Self.vitalsRecord(for: session)
        }
        let ref = session.endDate ?? session.startDate
        let live: FactValue? = await FactResolveTimeout.withTimeout(seconds: 5) {
            let v = await AppDependencies.current.collection.healthKitManager.fetchRecoveryVitals(relativeTo: ref)
            return v.isEmpty ? nil : Self.vitalsRecordFromData(v, date: session.startDate, live: true)
        }
        return live.map { OvernightArchive.labeled($0, session) }
            ?? .missing(reason: .notRecorded, detail: "no vitals snapshot and HealthKit returned no vitals for that window")
    }

    var entries: [FactEntry] {
        return [
            vitalsLatestEntry,
            vitalsByDateDateEntry,
            // "What's my heart rate right now" outside a workout: the newest
            // HealthKit HR sample from the last 10 minutes.
            vitalsHrNowEntry
        ]
    }

    private var vitalsByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "vitals.by_date($date)",
            paramExample: "2026-04-21",
            description: "Vitals record for a specific local date (yyyy-MM-dd).",
            availability: { OvernightArchive.availability(self.archive) },
            resolve: { param, _ in
                Self.vitalsRecord(for: OvernightArchive.byDate(param, archive: self.archive))
            }
        )
    }

    private var vitalsLatestEntry: FactEntry {
        .fixed(
            key: "vitals.latest",
            description: """
            Latest overnight vitals: respiratory rate, SpO2, wrist temperature (deviation from baseline), resting HR. Includes baselines and a status flag (normal/elevated/warning) \
            for readings above the personal baseline. The flag is not evidence of illness; the usual causes are training, alcohol, heat and stress. Falls back \
            to a LIVE HealthKit read (data_source=live_healthkit_pending_acceptance) when the night isn't accepted yet or vitals synced late.
            """,
            valueType: "Record",
            availability: { OvernightArchive.availability(self.archive) },
            body: .awaitable { await self.vitalsRecordAsync(for: OvernightArchive.latest(self.archive)) }
        )
    }

    private var vitalsHrNowEntry: FactEntry {
        .fixedAsync(
            key: "vitals.hr_now",
            description: """
            Most recent heart-rate reading from any source (Apple Watch, chest strap, or the live workout pipeline), via HealthKit. Use this when the user asks 'what's my HR right now' or 'how high is my heart rate' OUTSIDE an active \
            workout — once a workout ends and the strap disconnects, `workout.live.hr` returns notRecorded; this tool fills the gap. Returns the bpm value plus the timestamp of the sample so the AI can say 'your HR was 68 bpm 30 seconds \
            ago'. Samples older than 10 min count as notRecorded, because an old reading is not 'right now'; for the last known reading of any age within 24 hours use `app.healthkit.heart_rate_latest`.
            """,
            valueType: "Record"
        ) {
            let result = await Self.latestHeartRateSample()
            guard let result else {
                return .missing(reason: .notRecorded, detail: "no HR sample in the last 10 minutes — wear your Apple Watch or start a workout to get a live reading")
            }
            return .record([
                "bpm": .double(result.bpm),
                "observed_at": .date(result.at),
                "age_seconds": .double(Date().timeIntervalSince(result.at)),
                "source": .string(result.source)
            ])
        }
    }

    /// A suspending fetch, not a Task.detached + semaphore
    /// bridge (which would park the calling thread for up to 5 s). 5 s ceiling;
    /// thrown HealthKit errors are swallowed, because absence
    /// is what `notRecorded` means to the caller.
    private static func latestHeartRateSample() async -> (bpm: Double, at: Date, source: String)? {
        await FactResolveTimeout.withTimeout(seconds: 5) { await newestHeartRateInLastTenMinutes() }
    }

    /// nil on any failure. A thrown HealthKit error is swallowed on purpose:
    /// absence is exactly what `notRecorded` means to the caller.
    private static func newestHeartRateInLastTenMinutes() async -> (bpm: Double, at: Date, source: String)? {
        let now = Date()
        do {
            let samples = try await AppDependencies.current.collection.healthKitManager
                .fetchHeartRateSamplesDetailed(from: now.addingTimeInterval(-600), to: now)
            guard let latest = samples.max(by: { $0.date < $1.date }) else { return nil }
            return (bpm: latest.hr, at: latest.date, source: latest.source)
        } catch {
            // Swallow — the caller treats absence as notRecorded.
            return nil
        }
    }
}

// MARK: - recovery.* namespace
//
// Recovery score — the 0-100 composite of HRV, sleep, vitals (v3.1.oct2026; training load lives on the parallel Load & Trajectory surface).
// The score is the user-facing summary; this namespace exposes it + its
// day-over-day history so the AI can explain trend questions.

struct RecoveryNamespace: FactNamespaceResolver {
    let namespace = "recovery"
    let archive: SessionArchive

    /// The recovery score plus the parallel signals the AI needs to caveat it.
    ///
    /// `training_readiness` is frozen (0–10) and a separate number from the
    /// recovery score — it lets the AI answer "how ready am I to train?"
    /// distinctly.
    ///
    /// `data_quality` is the flag that lets the AI CAVEAT a poor reading
    /// instead of presenting a baseline-fallback number as if it were a clean
    /// overnight: good = normal scoring path · preSleep = strap ended before
    /// sleep · insufficient = too short / awake partial.
    private static func scoreRecord(for session: HRVSession?) -> FactValue {
        guard let session else {
            return .missing(reason: .notRecorded, detail: "no overnight session matched")
        }
        guard let score = session.recoveryScore else {
            return .missing(reason: .notYetComputed, detail: "session has no recovery score yet")
        }
        var record: [String: FactValue] = [
            "date": .date(session.startDate),
            // On the dashboard's 0-100 scale. Stored as 0-10, it reached the
            // model as 7.2 while the ring showed 72.
            "score": .integer(RecoveryScoreCalculator.displayScore(score * 10)),
            "scale": .string("0-100 (higher = more recovered)")
        ]
        if let readiness = session.frozenReadiness { record["training_readiness"] = .double(readiness) }
        if let q = session.hrvDataQuality { record["data_quality"] = .string(q.rawValue) }
        record.merge(subjectiveMorningFields(session)) { current, _ in current }
        return OvernightArchive.labeled(.record(record), session)
    }

    /// Subjective morning signals — captured BEFORE the score is revealed and
    /// stored as a PARALLEL signal (never blended into the score). Answers
    /// "did I say I felt bad this morning?" and routes divergence advice.
    ///
    /// `perceived_readiness` (0–1) is offered when HRV quality is poor and is
    /// then blended into the HRV factor at 30% alongside the baseline fallback.
    private static func subjectiveMorningFields(_ session: HRVSession) -> [String: FactValue] {
        var out: [String: FactValue] = [:]
        if let feeling = session.morningFeeling { out["morning_feeling"] = .integer(feeling) }
        if let tags = session.morningFeelingTags, !tags.isEmpty {
            out["morning_feeling_tags"] = .list(tags.map { .string($0.rawValue) })
        }
        if let perceived = session.perceivedReadiness { out["perceived_readiness"] = .double(perceived) }
        if let notes = session.notes, !notes.isEmpty { out["notes"] = .string(notes) }
        return out
    }

    var entries: [FactEntry] {
        return [
            recoveryScoreLatestEntry,
            recoveryScoreByDateDateEntry,
            recoveryScoreRecentPeriodEntry,
            recoveryTrendPeriodEntry
        ]
    }

    private var recoveryScoreByDateDateEntry: FactEntry {
        .parameterized(
            pattern: "recovery.score.by_date($date)",
            paramExample: "2026-04-21",
            description: "Recovery score for a specific local date (yyyy-MM-dd).",
            availability: { OvernightArchive.availability(self.archive) },
            resolve: { param, _ in
                Self.scoreRecord(for: OvernightArchive.byDate(param, archive: self.archive, scoredOnly: true))
            }
        )
    }

    private var recoveryScoreRecentPeriodEntry: FactEntry {
        .parameterized(
            pattern: "recovery.score.recent($period)",
            paramExample: "last_7d",
            description: "List of recovery scores over a recent period. Each item is a record with date + score. Most recent first. Use for 'have I been recovering?' / 'am I trending up?'.",
            availability: { OvernightArchive.availability(self.archive) },
            resolve: { param, _ in
                let sessions = OvernightArchive.inPeriod(param, archive: self.archive).filter { $0.recoveryScore != nil }
                guard !sessions.isEmpty else {
                    return .missing(reason: .notRecorded, detail: "no scored overnight sessions in period")
                }
                return .list(sessions.map { Self.scoreRecord(for: $0) })
            }
        )
    }

    private var recoveryTrendPeriodEntry: FactEntry {
        .parameterized(
            pattern: "recovery.trend($period)",
            paramExample: "last_30d",
            description: """
            Whether recovery is IMPROVING, STABLE, or DECLINING over a period — the same trend TrendView shows. Returns the overall direction plus per-metric direction and slope-per-day for HRV (RMSSD) and resting HR, readiness direction, \
            sample size, and plain-language insights. Reads the archive, so it works with NO strap on and no reading today. This is the tool for 'am I improving over time?' / 'is my recovery trending up?' / 'am I getting fitter?' — \
            use it instead of the latest/today facts, which need a fresh reading.
            """,
            availability: { OvernightArchive.availability(self.archive) },
            resolve: { param, _ in Self.resolveRecoveryTrend(param, archive: self.archive) }
        )
    }

    private static func resolveRecoveryTrend(_ param: String, archive: SessionArchive) -> FactValue {
        // Archive-backed, NOT strap-gated: window the overnight
        // sessions by the requested period, then let the analyzer
        // (period .all — inPeriod already did the windowing) compute
        // the same improving/stable/declining verdict + slopes that
        // TrendView renders. Needs ≥2 readings to have a slope.
        let sessions = OvernightArchive.inPeriod(param, archive: archive)
        guard let summary = TrendAnalyzer.analyze(sessions: sessions, period: .all) else {
            return .missing(
                reason: .notYetComputed,
                detail: "need at least 2 overnight readings in this period to compute a trend"
            )
        }
        let record = Self.trendRecord(from: summary)
        return .record(record)
    }

    private static func trendRecord(from summary: TrendAnalyzer.TrendSummary) -> [String: FactValue] {
        var record: [String: FactValue] = [
            "overall": .string(summary.overallTrend.rawValue),
            "data_points": .integer(summary.dataPoints.count),
            "hrv_rmssd_trend": .string(summary.rmssdStats.trend.rawValue),
            "hrv_rmssd_slope_per_day": .double(summary.rmssdStats.trendSlope),
            "hrv_rmssd_mean": .double(summary.rmssdStats.mean),
            "resting_hr_trend": .string(summary.hrStats.trend.rawValue),
            "resting_hr_slope_per_day": .double(summary.hrStats.trendSlope)
        ]
        if let readiness = summary.readinessStats {
            record["readiness_trend"] = .string(readiness.trend.rawValue)
            record["readiness_slope_per_day"] = .double(readiness.trendSlope)
        }
        if !summary.insights.isEmpty {
            record["insights"] = .list(summary.insights.map { .string($0) })
        }
        return record
    }

    private var recoveryScoreLatestEntry: FactEntry {
        .fixed(
            key: "recovery.score.latest",
            description: """
            Today's recovery score (0–100) plus its context: training_readiness (0–10, separate from the score), data_quality (good / preSleep / insufficient — cite this to caveat a poor reading), morning_feeling (1–5, what the user \
            SAID before seeing the score), morning_feeling_tags (e.g. infection/hangover/sore), perceived_readiness (0–1), and notes. Composite of HRV 60% / Sleep 25% / Vitals 15% (v3.1.oct2026); comeback mode shifts a Tier 3 score to 80/20/0. Training \
            load lives on the Load & Trajectory page, not in the score. Source of truth for 'how recovered am I?', 'am I ready to train?', and 'did I say I felt bad this morning?'.
            """,
            valueType: "Record",
            availability: { OvernightArchive.availability(self.archive) },
            resolve: { Self.scoreRecord(for: OvernightArchive.latest(self.archive, scoredOnly: true)) }
        )
    }
}
