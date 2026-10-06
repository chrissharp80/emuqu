import Foundation

// `BreadcrumbNamespace`: answers "where have I been" from the breadcrumb
// trail and its archive.

// MARK: - breadcrumb.* namespace
//
// Surfaces the Get-Me-Back breadcrumb store to the AI so
// it can answer "where did I park", "how far back is the trailhead",
// "list my recent trails", and so on. Read-only; mutating the store
// (engaging / clearing trails) belongs to the user-facing UI.
//
// Companion to the `directions.routeTo` action with `destination ==
// "origin"` — the AI can chain "where am I → look up the active trail
// origin → route walking from current position back to it." This
// namespace is the lookup half.
struct BreadcrumbNamespace: FactNamespaceResolver {
    let namespace = "breadcrumb"

    private static func tripleFromTrail(
        _ trail: BreadcrumbTrail
    ) -> [String: FactValue] {
        var rec: [String: FactValue] = [
            "started_at": .date(trail.startedAt),
            "fix_count": .integer(trail.fixes.count),
            "walked_meters": .double(trail.walkedTrailLengthMeters())
        ]
        if let label = trail.label {
            rec["label"] = .string(label)
        }
        if let resolved = trail.resolvedOriginLabel {
            rec["resolved_origin_label"] = .string(resolved)
        }
        if let origin = trail.origin {
            rec["origin_lat"] = .double(origin.latitude)
            rec["origin_lon"] = .double(origin.longitude)
            rec["origin_observed_at"] = .date(origin.timestamp)
        }
        if let crow = trail.crowFlyDistanceFromTipToOriginMeters() {
            rec["crow_fly_meters_to_origin"] = .double(crow)
        }
        return rec
    }

    var entries: [FactEntry] {
        [
            breadcrumbActiveEntry,
            breadcrumbRecentEntry,
            breadcrumbCountEntry,
            // What the recurrence classifier has to work with.
            breadcrumbArchiveSummaryEntry,
            // The live recorder's feed: "where am I right now, what's my
            // heading, how steep is this bit", read from the shared recorder.
            breadcrumbCurrentFixEntry,
            breadcrumbRecentTrackEntry,
            breadcrumbDerivedGradePercentEntry
        ]
    }

    private var breadcrumbActiveEntry: FactEntry {
        .fixed(
            key: "breadcrumb.active",
            description: """
            Current active Get-Me-Back trail (if engaged). Returns the origin coordinate, the user-supplied label, when the trail started, the fix count, the total walked-out distance in meters, and the crow-fly distance from the tip \
            back to the origin. Use this when the user asks 'how far back is the trailhead' / 'where did I start' / 'do I have an active trail'. Returns notRecorded when no trail is engaged — tell the user to engage Get Me Back first \
            if they want one.
            """,
            valueType: "Record"
        ) {
            guard let trail = AppDependencies.current.location.breadcrumbStore.load() else {
                return .missing(reason: .notRecorded, detail: "no active Get Me Back trail — engage one from Fitness tab → Get Me Back to drop a pin where you start")
            }
            return .record(Self.tripleFromTrail(trail))
        }
    }

    private var breadcrumbRecentEntry: FactEntry {
        .fixed(
            key: "breadcrumb.recent",
            description: Self.breadcrumbRecentDescription,
            valueType: "List"
        ) {
            let trails = AppDependencies.current.location.breadcrumbStore.loadArchive().prefix(10)
            if trails.isEmpty {
                return .missing(reason: .notRecorded, detail: "no archived trails — every workout with GPS auto-archives a trail; record a walk/run/bike or engage Get Me Back to populate this")
            }
            return .list(trails.map { trail in
                var rec = Self.tripleFromTrail(trail)
                rec["id"] = .string(FactValue.localISO8601(trail.startedAt))
                return .record(rec)
            })
        }
    }

    private static let breadcrumbRecentDescription = """
    Newest archived trails (up to 10). Each entry has the same fields as `breadcrumb.active` plus a synthetic `id` (the started_at ISO string) so the AI can disambiguate. Includes auto-archived workout tracks (labelled 'Run \
    on Apr 29, 2026 at 8:13 AM' etc.) so you can tell the user where any recent workout started (where they parked), even without having explicitly engaged Get Me Back. Directions can only lead back to the ACTIVE trail's start, not to an archived one. Use this for 'where did I park yesterday' / 'list my recent trails' / \
    'show me my hikes'. Empty list when nothing's been recorded.
    """

    private var breadcrumbCountEntry: FactEntry {
        .fixed(
            key: "breadcrumb.count",
            description: "Number of trails currently archived (excluding the active one). Cheap; returns 0 when the archive is empty. Useful as a guard before calling `breadcrumb.recent` so the AI doesn't ask a question it knows has no answer.",
            valueType: "Int"
        ) {
            .integer(AppDependencies.current.location.breadcrumbStore.loadArchive().count)
        }
    }

    // Answers "do you have my historical walks?" concretely: total trails,
    // date range, distinct (start coord, hour band) buckets, and how many
    // buckets hold enough trails for a recurrence match to be possible.
    private var breadcrumbArchiveSummaryEntry: FactEntry {
        .fixed(
            key: "breadcrumb.archive_summary",
            description: Self.breadcrumbArchiveSummaryDescription,
            valueType: "Record"
        ) { self.resolveBreadcrumbArchiveSummary() }
    }

    private func resolveBreadcrumbArchiveSummary() -> FactValue {
        let archive = AppDependencies.current.location.breadcrumbStore.loadArchive()
        guard !archive.isEmpty else {
            return .missing(reason: .notRecorded, detail: "no archived trails — trails are auto-saved at the end of every GPS-bearing workout, plus any Get-Me-Back trails you explicitly save. Record a walk/run/bike to populate.")
        }
        let dates = archive.map(\.startedAt).sorted()
        let bucketCounts = recurrenceBuckets(archive)
        return .record([
            "total_trails": .integer(archive.count),
            "earliest_date": .string(FactValue.localISO8601(dates.first ?? Date())),
            "latest_date": .string(FactValue.localISO8601(dates.last ?? Date())),
            "unique_buckets": .integer(bucketCounts.count),
            "buckets_meeting_recurrence_threshold": .integer(bucketCounts.values.filter { $0 >= 2 }.count),
            "median_trail_duration_seconds": .double(median(trailDurations(archive))),
            "median_trail_path_length_meters": .double(median(archive.map { $0.walkedTrailLengthMeters() }.sorted()))
        ])
    }

    private func trailDurations(_ archive: [BreadcrumbTrail]) -> [Double] {
        archive.compactMap { trail -> TimeInterval? in
            guard let origin = trail.origin, let last = trail.fixes.last else { return nil }
            return last.timestamp.timeIntervalSince(origin.timestamp)
        }.sorted()
    }

    // The classifier's own bucket key (start coordinate + 4-hour band),
    // counting only trails with the 5+ fixes it requires of a candidate.
    private func recurrenceBuckets(_ archive: [BreadcrumbTrail]) -> [String: Int] {
        archive.reduce(into: [:]) { dict, trail in
            guard trail.origin != nil, trail.fixes.count >= 5 else { return }
            dict[RecurrenceClassifier.bucketKey(for: trail), default: 0] += 1
        }
    }

    private func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let m = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[m - 1] + sorted[m]) / 2 : sorted[m]
    }

    private static let breadcrumbArchiveSummaryDescription = """
    Diagnostic snapshot of the breadcrumb archive — what the recurrence classifier sees. Returns: total_trails (count), earliest_date (ISO), latest_date (ISO), unique_buckets (number of distinct start-coord + hour-band combinations \
    across the archive), buckets_meeting_recurrence_threshold (number of buckets with ≥2 trails of 5+ fixes — a new trail from such a bucket can be recognised as 'your usual route', but only if its path also averages within 75 m of at least two of them), median_trail_duration_seconds (median \
    of all archived trail durations), median_trail_path_length_meters. Use to answer 'do you have access to my historical walks' / 'how many walks do you have on record' / 'why doesn't the AI recognise my usual route'. Empty \
    archive returns notRecorded with a note explaining where trails come from.
    """

    private var breadcrumbCurrentFixEntry: FactEntry {
        .fixed(
            key: "breadcrumb.current_fix",
            description: """
            Most recent committed breadcrumb fix from the live recorder. Returns { latitude, longitude, altitude_m?, accuracy_m, course_deg?, speed_ms?, captured_at }. Use to answer 'where am I right now' even outside an active workout \
            — the recorder runs whenever its mode is engaged. Returns notRecorded when no breadcrumb recorder is active OR when no fix has landed yet.
            """,
            valueType: "Record"
        ) { self.resolveBreadcrumbCurrentFix() }
    }

    private func resolveBreadcrumbCurrentFix() -> FactValue {
        let trail = MainActor.assumeIsolated { AppDependencies.current.location.breadcrumbRecorder.activeTrail }
        guard let last = trail?.fixes.last else {
            return .missing(reason: .notRecorded, detail: "no active breadcrumb trail")
        }
        var out: [String: FactValue] = [
            "latitude": .double(last.latitude),
            "longitude": .double(last.longitude),
            "accuracy_m": .double(last.horizontalAccuracyMeters),
            "captured_at": .date(last.timestamp)
        ]
        if let alt = last.altitudeMeters { out["altitude_m"] = .double(alt) }
        if let course = last.courseDegrees { out["course_deg"] = .double(course) }
        if let speed = last.speedMS { out["speed_ms"] = .double(speed) }
        return .record(out)
    }

    private var breadcrumbRecentTrackEntry: FactEntry {
        .fixed(
            key: "breadcrumb.recent_track",
            description: """
            Last up-to-20 committed breadcrumb fixes in chronological order (oldest first). Each entry has the same fields as `breadcrumb.current_fix`. Use to reason about heading changes, grade trajectory, or 'how did I get here' across \
            a recent stretch. Returns notRecorded when no trail is engaged or fewer than 2 fixes exist.
            """,
            valueType: "List"
        ) { self.resolveBreadcrumbRecentTrack() }
    }

    private func resolveBreadcrumbRecentTrack() -> FactValue {
        let trail = MainActor.assumeIsolated { AppDependencies.current.location.breadcrumbRecorder.activeTrail }
        let fixes = (trail?.fixes ?? []).suffix(20)
        guard fixes.count >= 2 else {
            return .missing(reason: .notRecorded, detail: "fewer than 2 breadcrumb fixes — start moving or engage Get Me Back")
        }
        let items: [FactValue] = fixes.map { fix in
            var rec: [String: FactValue] = [
                "latitude": .double(fix.latitude),
                "longitude": .double(fix.longitude),
                "accuracy_m": .double(fix.horizontalAccuracyMeters),
                "captured_at": .date(fix.timestamp)
            ]
            if let alt = fix.altitudeMeters { rec["altitude_m"] = .double(alt) }
            if let course = fix.courseDegrees { rec["course_deg"] = .double(course) }
            if let speed = fix.speedMS { rec["speed_ms"] = .double(speed) }
            return .record(rec)
        }
        return .list(items)
    }

    private var breadcrumbDerivedGradePercentEntry: FactEntry {
        .fixed(
            key: "breadcrumb.derived_grade_percent",
            description: """
            Grade percentage derived from the elevation delta of the most recent ~100 m of breadcrumb fixes. Positive = climbing, negative = descending. Returns notRecorded when no track is active OR the segment doesn't cover enough \
            horizontal distance for a stable estimate (≥ 50 m). Honest about noise: GPS altitude jitter is ±5 m, so very short rises (<2 m) are floored to 0 to avoid 'fake hills.'
            """,
            valueType: "Double"
        ) { self.resolveBreadcrumbDerivedGradePercent() }
    }

    private func resolveBreadcrumbDerivedGradePercent() -> FactValue {
        let trail = MainActor.assumeIsolated { AppDependencies.current.location.breadcrumbRecorder.activeTrail }
        let fixes = trail?.fixes ?? []
        guard fixes.count >= 2 else {
            return .missing(reason: .notRecorded, detail: "need at least 2 fixes for a grade estimate")
        }
        let (acc, startIdx) = gradeSegment(fixes)
        guard acc >= 50 else {
            return .missing(reason: .notYetComputed, detail: "track segment too short for a stable grade")
        }
        guard let endAlt = fixes.last?.altitudeMeters,
              let startAlt = fixes[startIdx].altitudeMeters
        else {
            return .missing(reason: .notRecorded, detail: "altitude missing on one of the endpoints")
        }
        let rise = endAlt - startAlt
        guard abs(rise) >= 2.0 else { return .double(0) }
        return .double((rise / acc) * 100.0)
    }

    private func gradeSegment(_ fixes: [BreadcrumbFix]) -> (Double, Int) {
        var acc: Double = 0
        var startIdx = 0
        for i in (1 ..< fixes.count).reversed() {
            acc += fixes[i].asCLLocation.distance(from: fixes[i - 1].asCLLocation)
            if acc >= 100 { startIdx = i - 1; break }
        }
        return (acc, startIdx)
    }
}
