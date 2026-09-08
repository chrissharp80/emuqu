import CoreLocation
import CoreMotion
import Foundation
import os

// Split out from AppFactResolver.swift to keep the
// primary file under budget. Holds hrv.live, tags, hrr, composites,
// routes.library, app.now, app.devices, assistant.memory namespaces.

// MARK: - hrv.live.* namespace
//
// Live HRV-recording facts sourced from `LiveHRVBroker`. Mirrors the
// `workout.live.*` pattern but for the RR/HRV side — quick streaming,
// overnight recordings, paused, analyzing. Hosted providers (Claude,
// GPT, Gemini, Grok, DeepSeek) query facts via tool calls and don't
// see the on-device `compactRender()` output, so without this the AI
// would say "I don't have access to live data" mid-overnight recording
// even though the screen shows a real beat count.
//
// `.alwaysAvailable` so the model can ask "is a recording active?" at
// any time; when no snapshot exists every atomic field returns
// `.missing(.notRecorded)` with a human-readable "no HRV recording
// active" detail.
struct HRVLiveNamespace: FactNamespaceResolver {
    let namespace = "hrv.live"

    private var snapshot: AssistantContext.LiveHRVSnapshot? {
        AppDependencies.current.assistant.liveHRVBroker.currentSnapshot()
    }

    private func missing(_ detail: String = "no HRV recording active") -> FactValue {
        .missing(reason: .notRecorded, detail: detail)
    }

    /// Full snapshot record — one tool call returns everything the AI
    /// needs about the current recording. Atomic keys below exist for
    /// models that prefer narrower reads.
    private func snapshotRecord() -> FactValue {
        guard let s = snapshot else { return missing() }
        var rec: [String: FactValue] = [
            "phase": .string(s.phase),
            "phase_description": .string(s.phaseDescription),
            "is_collecting": .boolean(s.isCollecting),
            "beat_count": .integer(s.beatCount),
            "snapshot_at": .date(s.snapshotAt)
        ]
        if let elapsed = s.elapsedSeconds { rec["elapsed_sec"] = .integer(elapsed) }
        if let start = s.sessionStartAt { rec["session_started_at"] = .date(start) }
        if let err = s.lastErrorDescription, !err.isEmpty {
            rec["last_error"] = .string(err)
        }
        return .record(rec)
    }

    var entries: [FactEntry] {
        [
            hrvLiveActiveEntry,
            hrvLiveSnapshotEntry,
            hrvLivePhaseEntry,
            hrvLivePhaseDescriptionEntry,
            hrvLiveIsCollectingEntry,
            hrvLiveBeatCountEntry,
            hrvLiveElapsedSecEntry,
            hrvLiveSessionStartedAtEntry,
            hrvLiveLastErrorEntry
        ]
    }

    private var hrvLiveActiveEntry: FactEntry {
        .fixed(
            key: "hrv.live.active",
            description: """
            Whether an HRV recording is currently in progress (quick streaming, overnight, paused, or analyzing). Check this first before calling other hrv.live.* facts. Independent of workout.live.active — a user can have HRV running \
            without a workout (overnight) or a workout without HRV.
            """,
            valueType: "Bool"
        ) {
            .boolean(self.snapshot != nil)
        }
    }

    private var hrvLiveSnapshotEntry: FactEntry {
        .fixed(
            key: "hrv.live.snapshot",
            description: "Full live-recording state in one record: phase, phase_description, is_collecting, beat_count, elapsed_sec, session_started_at, last_error. Use this when answering any 'what's happening with my recording right now' question.",
            valueType: "Record"
        ) {
            self.snapshotRecord()
        }
    }

    private var hrvLivePhaseEntry: FactEntry {
        .fixed(
            key: "hrv.live.phase",
            description: "Machine-readable phase label: 'streaming', 'overnight', 'deviceRecording', 'paused', 'analyzing', 'awaitingAcceptance'. For human-readable phrasing use hrv.live.phase_description.",
            valueType: "String"
        ) {
            self.snapshot.map { .string($0.phase) } ?? self.missing()
        }
    }

    private var hrvLivePhaseDescriptionEntry: FactEntry {
        .fixed(
            key: "hrv.live.phase_description",
            description: "Human-readable phase string — use this verbatim when explaining state to the user. Examples: 'Overnight recording', 'Quick streaming (target 3m)', 'Paused', 'Analyzing'. Prefer this over `phase`.",
            valueType: "String"
        ) {
            self.snapshot.map { .string($0.phaseDescription) } ?? self.missing()
        }
    }

    private var hrvLiveIsCollectingEntry: FactEntry {
        .fixed(
            key: "hrv.live.is_collecting",
            description: "True only while beats are actively landing. A paused or analyzing session returns false even though a snapshot exists — useful to distinguish 'still recording' from 'recorded, now processing'.",
            valueType: "Bool"
        ) {
            self.snapshot.map { .boolean($0.isCollecting) } ?? self.missing()
        }
    }

    private var hrvLiveBeatCountEntry: FactEntry {
        .fixed(
            key: "hrv.live.beat_count",
            description: "Total RR beats captured in the active session so far. Zero is legitimate (session just started, no beats yet) — distinguish from 'missing' which means no session is active.",
            valueType: "Int"
        ) {
            self.snapshot.map { .integer($0.beatCount) } ?? self.missing()
        }
    }

    private var hrvLiveElapsedSecEntry: FactEntry {
        .fixed(
            key: "hrv.live.elapsed_sec",
            description: "Seconds since the active recording began. Nil when a session hasn't started yet (pre-warm / permission check).",
            valueType: "Int"
        ) {
            guard let s = self.snapshot else { return self.missing() }
            return s.elapsedSeconds.map { .integer($0) } ?? self.missing("session not started yet")
        }
    }

    private var hrvLiveSessionStartedAtEntry: FactEntry {
        .fixed(
            key: "hrv.live.session_started_at",
            description: "Wall-clock timestamp of when the active session began. Nil if pre-start.",
            valueType: "Date"
        ) {
            guard let s = self.snapshot else { return self.missing() }
            return s.sessionStartAt.map { .date($0) } ?? self.missing("session not started yet")
        }
    }

    private var hrvLiveLastErrorEntry: FactEntry {
        .fixed(
            key: "hrv.live.last_error",
            description: "Last-error string from the recording path, if one exists. Populated when a session stumbled (e.g. strap disconnect, audio-session interruption). Explain this to the user verbatim when they ask why a recording paused — do not paraphrase.",
            valueType: "String"
        ) {
            guard let s = self.snapshot else { return self.missing() }
            return (s.lastErrorDescription.flatMap { $0.isEmpty ? nil : .string($0) })
                ?? self.missing("no error on the recording path")
        }
    }
}

// MARK: - tags.* namespace
//
// Tag-based queries over all archived sessions. The archive stores every
// session's `[ReadingTag]` so counting / filtering is a synchronous scan
// — the tags array is part of the lightweight SessionArchiveEntry index,
// no full-session deserialise needed for the common case.

struct TagsNamespace: FactNamespaceResolver {
    let namespace = "tags"
    let archive: SessionArchive

    /// Match a tag parameter against a ReadingTag (case-insensitive name
    /// match). Accepts either the system-tag accessor (e.g. "caffeine")
    /// or the display name ("Caffeine", "Post-Exercise").
    private static func nameMatches(_ param: String, tag: ReadingTag) -> Bool {
        tag.name.caseInsensitiveCompare(param) == .orderedSame
            || tag.name.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
            .caseInsensitiveCompare(param.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")) == .orderedSame
    }

    /// All sessions whose tag list contains the named tag. Reads through
    /// archive.retrieve — tags live inside HRVSession, not the lightweight
    /// index — but this is bounded to the total archive size and cached
    /// per-id inside the archive.
    private func sessionsWithTag(_ tagName: String) -> [HRVSession] {
        let all = archive.entries.sorted { $0.date > $1.date }
        var out: [HRVSession] = []
        for entry in all {
            guard let session = archive.retrieveLightweightOrLog(entry.sessionId) else { continue }
            if session.tags.contains(where: { Self.nameMatches(tagName, tag: $0) }) {
                out.append(session)
            }
        }
        return out
    }

    private func tagsAvailability() -> Availability {
        let hasAny = !archive.entries.isEmpty
        guard hasAny else { return .unavailable }
        let dates = archive.entries.map(\.date)
        guard let earliest = dates.min(), let latest = dates.max() else {
            return .alwaysAvailable
        }
        return Availability(hasData: true, validRange: earliest ... latest, lastUpdated: latest)
    }

    private func sessionsOn(_ iso: String) -> [HRVSession] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        guard let target = formatter.date(from: iso) else { return [] }
        let cal = Calendar.current
        let day = cal.startOfDay(for: target)
        guard let next = cal.date(byAdding: .day, value: 1, to: day) else { return [] }
        return archive.entries
            .filter { $0.date >= day && $0.date < next }
            .compactMap { archive.retrieveLightweightOrLog($0.sessionId) }
    }

    var entries: [FactEntry] {
        return [
            tagsCountTagEntry,
            tagsRecentTaggedTagEntry,
            tagsListActiveDateEntry,
            tagsCorrelationTagEntry
        ]
    }

    private var tagsCountTagEntry: FactEntry {
        .parameterized(
            pattern: "tags.count($tag)",
            paramExample: "Caffeine",
            description: "Total number of sessions tagged with the named system or custom tag across the entire archive. Accepts the display name (e.g. 'Caffeine', 'Post-Exercise', 'Alcohol').",
            availability: { self.tagsAvailability() },
            resolve: { param, _ in
                .integer(self.sessionsWithTag(param).count)
            }
        )
    }

    private var tagsRecentTaggedTagEntry: FactEntry {
        .parameterized(
            pattern: "tags.recent_tagged($tag)",
            paramExample: "Caffeine",
            description: "Up to the last 10 sessions carrying the named tag, each with date and recovery score if available. Most recent first.",
            availability: { self.tagsAvailability() },
            resolve: { param, _ in self.resolveTagsRecentTaggedTag(param) }
        )
    }

    private func resolveTagsRecentTaggedTag(_ param: String) -> FactValue {
        let sessions = self.sessionsWithTag(param).prefix(10)
        guard !sessions.isEmpty else {
            return .missing(reason: .notRecorded, detail: "no sessions have the '\(param)' tag")
        }
        return .list(sessions.map { session in
            var record: [String: FactValue] = [
                "date": .date(session.startDate),
                "session_id": .string(session.id.uuidString),
                "session_type": .string(session.sessionType.rawValue)
            ]
            if let score = session.recoveryScore { record["recovery_score"] = .double(score) }
            return .record(record)
        })
    }

    private var tagsListActiveDateEntry: FactEntry {
        .parameterized(
            pattern: "tags.list_active($date)",
            paramExample: "2026-04-21",
            description: "List of tags attached to sessions on a specific local date (yyyy-MM-dd). Returns names of every tag present across all sessions that day.",
            availability: { self.tagsAvailability() },
            resolve: { param, _ in self.resolveTagsListActive(param) }
        )
    }

    private func resolveTagsListActive(_ param: String) -> FactValue {
        let sessions = self.sessionsOn(param)
        guard !sessions.isEmpty else {
            return .missing(reason: .notRecorded, detail: "no sessions on \(param)")
        }
        var names: Set<String> = []
        for s in sessions {
            for t in s.tags { names.insert(t.name) }
        }
        guard !names.isEmpty else {
            return .missing(reason: .notRecorded, detail: "no tags on any session that day")
        }
        return .list(names.sorted().map { .string($0) })
    }

    private var tagsCorrelationTagEntry: FactEntry {
        .composite(
            key: "tags.correlation($tag)",
            description: "Average recovery score on sessions tagged with the named tag vs sessions without it. Returns a record with tagged_avg, untagged_avg, sample_size (tagged), and total_sessions. Use to detect tag-value correlations (e.g. 'do alcohol days reduce recovery?').",
            valueType: "Record",
            dependencies: [],
            availability: { self.tagsAvailability() },
            resolve: { param, _ in self.resolveTagsCorrelationTag(param) }
        )
    }

    private func resolveTagsCorrelationTag(_ param: String?) -> FactValue {
        guard let param else {
            return .missing(reason: .invalidParameter, detail: "missing tag arg")
        }
        let (tagged, untagged) = taggedScores(matching: param)
        guard !tagged.isEmpty else {
            return .missing(reason: .notRecorded, detail: "no scored sessions with the '\(param)' tag")
        }
        return .record([
            "tagged_avg": .double(tagged.reduce(0, +) / Double(tagged.count)),
            "untagged_avg": untagged.isEmpty ? .missing(reason: .notRecorded, detail: "no untagged scored sessions") : .double(untagged.reduce(0, +) / Double(untagged.count)),
            "sample_size": .integer(tagged.count),
            "total_sessions": .integer(tagged.count + untagged.count)
        ])
    }

    private func taggedScores(matching param: String) -> ([Double], [Double]) {
        let all = self.archive.entries
            .compactMap { self.archive.retrieveLightweightOrLog($0.sessionId) }
        var tagged: [Double] = []
        var untagged: [Double] = []
        for s in all {
            guard let score = s.recoveryScore else { continue }
            let has = s.tags.contains { Self.nameMatches(param, tag: $0) }
            if has { tagged.append(score) } else { untagged.append(score) }
        }
        return (tagged, untagged)
    }
}

// MARK: - hrr.* namespace
//
// HRR-aggregate queries over recent workouts. Reads archive-side
// workouts (which snapshot their HealthKit-derived HRR samples at
// acceptance time) so this is synchronous — no live HealthKit calls.

struct HRRNamespace: FactNamespaceResolver {
    let namespace = "hrr"
    let archive: SessionArchive

    private func cutoff(for period: String) -> Date? {
        PeriodParser.cutoff(for: period)
    }

    /// Sessions in period that carry HRR samples. Sorted newest first.
    private func sessionsWithHRR(_ period: String) -> [HRVSession] {
        guard let cutoff = cutoff(for: period) else { return [] }
        return archive.entries
            .filter { $0.sessionType == .workout && $0.date >= cutoff }
            .sorted { $0.date > $1.date }
            .compactMap { archive.retrieveLightweightOrLog($0.sessionId) }
            .filter { ($0.workoutMetadata?.hrrSamples ?? []).isEmpty == false }
    }

    private func hrrAvailability() -> Availability {
        .workouts(in: archive)
    }

    var entries: [FactEntry] {
        return [
            hrrRecentAvg1minPeriodEntry,
            hrrRecentAvg2minPeriodEntry,
            hrrTrendPeriodEntry
        ]
    }

    private var hrrRecentAvg1minPeriodEntry: FactEntry {
        .parameterized(
            pattern: "hrr.recent_avg_1min($period)",
            paramExample: "last_30d",
            description: "Average 1-minute HRR drop (bpm) across workouts with valid HRR captured in the period. Periods: last_7d / last_14d / last_30d / last_90d / all_time.",
            availability: { self.hrrAvailability() },
            resolve: { param, _ in
                let sessions = self.sessionsWithHRR(param)
                let drops = sessions.compactMap { $0.workoutMetadata?.hrrSamples?.bestAtOneMinute?.drop }
                guard !drops.isEmpty else {
                    return .missing(reason: .notRecorded, detail: "no 1-min HRR samples in period")
                }
                let avg = Double(drops.reduce(0, +)) / Double(drops.count)
                return .double(avg)
            }
        )
    }

    private var hrrRecentAvg2minPeriodEntry: FactEntry {
        .parameterized(
            pattern: "hrr.recent_avg_2min($period)",
            paramExample: "last_30d",
            description: "Average 2-minute HRR drop (bpm) across workouts with valid HRR captured in the period.",
            availability: { self.hrrAvailability() },
            resolve: { param, _ in
                let sessions = self.sessionsWithHRR(param)
                let drops = sessions.compactMap { $0.workoutMetadata?.hrrSamples?.bestAtTwoMinutes?.drop }
                guard !drops.isEmpty else {
                    return .missing(reason: .notRecorded, detail: "no 2-min HRR samples in period")
                }
                let avg = Double(drops.reduce(0, +)) / Double(drops.count)
                return .double(avg)
            }
        )
    }

    private var hrrTrendPeriodEntry: FactEntry {
        .parameterized(
            pattern: "hrr.trend($period)",
            paramExample: "last_30d",
            description: "HRR trend over the period — splits the window in half and returns {first_half_avg, second_half_avg, change_bpm} for the 1-minute drop. Positive change_bpm = improving recovery.",
            availability: { self.hrrAvailability() },
            resolve: { param, _ in self.resolveHrrTrendPeriod(param) }
        )
    }

    private func resolveHrrTrendPeriod(_ param: String) -> FactValue {
        let sessions = self.sessionsWithHRR(param)
            .compactMap { s -> (date: Date, drop: Int)? in
                guard let d = s.workoutMetadata?.hrrSamples?.bestAtOneMinute?.drop else { return nil }
                return (s.startDate, d)
            }
            .sorted { $0.date < $1.date }
        guard sessions.count >= 2 else {
            return .missing(reason: .notYetComputed, detail: "fewer than 2 HRR-bearing workouts in period")
        }
        let midpoint = sessions.count / 2
        let firstHalf = sessions.prefix(midpoint)
        let secondHalf = sessions.suffix(sessions.count - midpoint)
        let firstAvg = Double(firstHalf.map(\.drop).reduce(0, +)) / Double(firstHalf.count)
        let secondAvg = Double(secondHalf.map(\.drop).reduce(0, +)) / Double(secondHalf.count)
        return .record([
            "first_half_avg": .double(firstAvg),
            "second_half_avg": .double(secondAvg),
            "change_bpm": .double(secondAvg - firstAvg),
            "sample_size": .integer(sessions.count)
        ])
    }
}

// MARK: - Composites namespace
//
// Composites aggregate multiple atomic facts into a single tool call, so
// the common questions don't fan out into 5–10 round-trips. Each composite
// calls atomics ONLY (never other composites — the flat-leaf invariant,
// docs/FLO_ARCHITECTURE.md §6) and reports partial failures via the standard
// CompositeResult envelope + `missingReason: .partialData`.
//
// The five shipped here are the top-5 "read everything about this one
// thing" questions for this app. Review real user prompts before adding
// more, so the catalog grows to match actual usage, not speculation.

struct CompositesNamespace: FactNamespaceResolver {
    let namespace = "composites"

    var entries: [FactEntry] {
        return [
            // 1. user.profile.snapshot → every user.profile.* in one call.
            //    Replaces 7–8 individual fact calls when the model needs
            //    to reason about physiology (max_hr + lthr + resting_hr +
            userProfileSnapshotEntry,
            // 2. training.snapshot → CTL/ATL/TSB/ACWR in one call.
            //    The four training-load atomics map to four separate tool
            trainingLoadSnapshotEntry,
            // 3. walks.summary($period) → count + distance + trimp + hardest
            walksSummaryPeriodEntry,
            // 4. recovery.today.full → score + latest sleep + latest hrv +
            //    latest vitals, so the model can answer "how am I today?"
            recoveryTodayFullEntry,
            // 5. recovery.week.summary → recovery scores + sleep + hrv for
            //    the last 7 days. Answers "how's my week been?" in one
            //    call rather than the model having to chain 21+ atomic
            recoveryWeekSummaryEntry
        ]
    }

    //    weight + age + sex + units).
    private var userProfileSnapshotEntry: FactEntry {
        .composite(
            key: "user.profile.snapshot",
            description: """
            User's complete profile as a single record: max_hr, resting_hr, lthr, weight_kg, biological_sex, age, units, typical_sleep_hours. Use this at the start of any question that needs physiology (\"is X high for me?\", \"what's \
            my zone 2?\", \"how much sleep do I need?\") rather than calling the individual user.profile.* atomics.
            """,
            valueType: "Record",
            dependencies: [
                "user.profile.max_hr",
                "user.profile.resting_hr",
                "user.profile.lthr",
                "user.profile.weight_kg",
                "user.profile.biological_sex",
                "user.profile.age",
                "user.settings.units",
                "user.settings.typical_sleep_hours"
            ],
            resolve: { _, registry in self.resolveUserProfileSnapshot(registry) }
        )
    }

    private func resolveUserProfileSnapshot(_ registry: FactResolverRegistry) -> FactValue {
        let keys = [
            "user.profile.max_hr",
            "user.profile.resting_hr",
            "user.profile.lthr",
            "user.profile.weight_kg",
            "user.profile.biological_sex",
            "user.profile.age",
            "user.settings.units",
            "user.settings.typical_sleep_hours"
        ]
        let children = keys.map { ($0, registry.resolve($0)) }
        return CompositeResult.recordFromChildren(children)
    }

    //    calls today; this packs them into one.
    private var trainingLoadSnapshotEntry: FactEntry {
        .composite(
            key: "training.load.snapshot",
            description: "Complete training-load snapshot: ctl (chronic load, fitness proxy), atl (acute load, fatigue proxy), tsb (stress balance, freshness), acwr (acute:chronic ratio). Use for 'am I ready to train?' / 'am I carrying too much accumulated load?'.",
            valueType: "Record",
            dependencies: [
                "training.load.ctl",
                "training.load.atl",
                "training.load.tsb",
                "training.load.acwr"
            ],
            resolve: { _, registry in self.resolveTrainingLoadSnapshot(registry) }
        )
    }

    private func resolveTrainingLoadSnapshot(_ registry: FactResolverRegistry) -> FactValue {
        let keys = [
            "training.load.ctl",
            "training.load.atl",
            "training.load.tsb",
            "training.load.acwr"
        ]
        let children = keys.map { ($0, registry.resolve($0)) }
        return CompositeResult.recordFromChildren(children)
    }

    //    in one call. Common "how was my week of walking?" question.
    private var walksSummaryPeriodEntry: FactEntry {
        .composite(
            key: "walks.summary($period)",
            description: "Complete walks summary for a period: count, total_distance_m, total_trimp, hardest workout record. Period: last_7d / last_14d / last_30d / last_90d / all_time. Use for 'how much did I walk this week?' / 'how's my training been?'.",
            valueType: "Record",
            dependencies: [
                "walks.count($period)",
                "walks.total_distance_m($period)",
                "walks.total_trimp($period)",
                "walks.hardest($period)"
            ],
            resolve: { param, registry in self.resolveWalksSummaryPeriod(param, registry) }
        )
    }

    private func resolveWalksSummaryPeriod(_ param: String?, _ registry: FactResolverRegistry) -> FactValue {
        guard let period = param else {
            return .missing(reason: .invalidParameter, detail: "missing period arg")
        }
        let specs: [(String, String)] = [
            ("count", "walks.count(\(period))"),
            ("total_distance_m", "walks.total_distance_m(\(period))"),
            ("total_trimp", "walks.total_trimp(\(period))"),
            ("hardest", "walks.hardest(\(period))")
        ]
        let children = specs.map { ($0.1, registry.resolve($0.1)) }
        return CompositeResult.recordFromChildren(children)
    }

    //    in one tool call with the full picture.
    private var recoveryTodayFullEntry: FactEntry {
        .composite(
            key: "recovery.today.full",
            description: "Everything about today's recovery in one call: recovery score, last night's sleep record, last night's HRV record, last night's vitals. Use this at the start of any 'how am I today?' / 'should I train hard?' / 'what's my recovery?' conversation.",
            valueType: "Record",
            dependencies: [
                "recovery.score.latest",
                "sleep.latest",
                "hrv.latest",
                "vitals.latest"
            ],
            resolve: { _, registry in self.resolveRecoveryTodayFull(registry) }
        )
    }

    private func resolveRecoveryTodayFull(_ registry: FactResolverRegistry) -> FactValue {
        let keys = [
            "recovery.score.latest",
            "sleep.latest",
            "hrv.latest",
            "vitals.latest"
        ]
        let children = keys.map { ($0, registry.resolve($0)) }
        return CompositeResult.recordFromChildren(children)
    }

    //    calls (7 dates × 3 dimensions).
    private var recoveryWeekSummaryEntry: FactEntry {
        .composite(
            key: "recovery.week.summary",
            description: "Last 7 days of recovery: daily recovery scores + sleep records + HRV records. Use for 'how's my week been?' / 'have I been recovering?' / 'is there a trend?'.",
            valueType: "Record",
            dependencies: [
                "recovery.score.recent(last_7d)",
                "sleep.recent(last_7d)",
                "hrv.recent(last_7d)"
            ],
            resolve: { _, registry in
                let keys = [
                    "recovery.score.recent(last_7d)",
                    "sleep.recent(last_7d)",
                    "hrv.recent(last_7d)"
                ]
                let children = keys.map { ($0, registry.resolve($0)) }
                return CompositeResult.recordFromChildren(children)
            }
        )
    }
}
