import Foundation

// The per-tool resolvers and their helpers — the half that actually answers.
// The schema, dispatch table and capability index live in
// `CompactToolRouter.swift`.

extension CompactToolRouter {
    // MARK: - Per-tool resolvers

    /// One row of a `which`-style dispatch table: the fact key, the single
    /// argument that fills its placeholder, and an optional format hint for
    /// the error message when that argument is missing.
    struct ParameterizedRow {
        let key: String
        let arg: String
        var hint: String = ""

        init(_ key: String, _ arg: String, hint: String = "") {
            self.key = key
            self.arg = arg
            self.hint = hint
        }
    }

    /// Shared `which`-style dispatch. Each supported value either names a
    /// no-argument fact key or a key template plus the one argument that fills
    /// it — a table, not control flow, so the branch count belongs to the tool
    /// schema rather than to this function.
    func dispatch(
        _ which: String,
        tool: String,
        selector: String = "which",
        plain: [String: String],
        parameterized: [String: ParameterizedRow] = [:],
        args: [String: String]
    ) async -> FactValue {
        if let key = plain[which] { return await registry.resolveAsync(key) }
        guard let row = parameterized[which] else {
            return .missing(reason: .invalidParameter, detail: "unknown \(selector)='\(which)' for \(tool)")
        }
        guard let value = args[row.arg] else {
            return .missing(
                reason: .invalidParameter,
                detail: "\(selector)='\(which)' requires '\(row.arg)'\(row.hint)"
            )
        }
        return await registry.resolveAsync("\(row.key)(\(value))")
    }

    func resolveSession(args: [String: String]) async -> FactValue {
        await dispatch(
            args["which"] ?? "latest",
            tool: "get_session",
            plain: ["latest": "session.latest"],
            parameterized: [
                "by_date": .init("session.by_date", "date", hint: " (YYYY-MM-DD)"),
                "by_id": .init("session.by_id", "id", hint: " (UUID)"),
                "by_ordinal": .init("session.by_ordinal", "n", hint: " (integer)"),
                "recent": .init("session.recent", "period")
            ],
            args: args
        )
    }

    func resolveRecovery(args: [String: String]) async -> FactValue {
        await dispatch(
            args["which"] ?? "latest",
            tool: "get_recovery",
            plain: [
                "latest": "recovery.score.latest",
                "today_full": "recovery.today.full",
                "week_summary": "recovery.week.summary"
            ],
            parameterized: [
                "by_date": .init("recovery.score.by_date", "date"),
                "recent": .init("recovery.score.recent", "period"),
                "trend": .init("recovery.trend", "period"),
                "breakdown": .init("recovery.breakdown.by_date", "date", hint: " (YYYY-MM-DD)")
            ],
            args: args
        )
    }

    func resolveHRV(args: [String: String]) async -> FactValue {
        let which = args["which"] ?? "latest"
        // The window classification is a bundle of three fields rather than a
        // single key, so it can't ride the shared table.
        if which == "window" {
            return await resolveBundle([
                ("classification", "hrv.window.classification"),
                ("is_consolidated", "hrv.window.is_consolidated"),
                ("is_organized_recovery", "hrv.window.is_organized_recovery")
            ])
        }
        return await dispatch(
            which,
            tool: "get_hrv",
            plain: ["latest": "hrv.latest", "live_snapshot": "hrv.live.snapshot"],
            parameterized: Self.hrvRows,
            args: args
        )
    }

    /// get_hrv's dated and period variants.
    private static let hrvRows: [String: ParameterizedRow] = [
        "by_date": .init("hrv.by_date", "date"),
        "recent": .init("hrv.recent", "period"),
        "timeline": .init("hrv.timeline.by_date", "date", hint: " (YYYY-MM-DD)"),
        "readings": .init("hrv.readings.by_date", "date", hint: " (YYYY-MM-DD)")
    ]

    /// A period lists the nights, a date reads one, and neither reads the latest.
    func resolveVitals(args: [String: String]) async -> FactValue {
        if let period = args["period"] { return await registry.resolveAsync("vitals.recent(\(period))") }
        if let date = args["date"] { return await registry.resolveAsync("vitals.by_date(\(date))") }
        return await registry.resolveAsync("vitals.latest")
    }

    func resolveSleep(args: [String: String]) async -> FactValue {
        await dispatch(
            args["which"] ?? "latest",
            tool: "get_sleep",
            plain: ["latest": "sleep.latest"],
            parameterized: [
                "by_date": .init("sleep.by_date", "date"),
                "recent": .init("sleep.recent", "period")
            ],
            args: args
        )
    }

    /// `which` → fact-key suffix, for every `get_workout` variant whose whole
    /// implementation is "resolve this dated fact".
    ///
    /// These are a table rather than one `case` each inside `resolveWorkout`
    /// (which would dominate its cyclomatic complexity). They differ only by the
    /// suffix, so the mapping is data. `by_ordinal` stays a branch because it
    /// reads a different argument and builds a different key shape.
    private static let datedWorkoutKeySuffixes: [String: String] = [
        "by_date": "by_date",
        "feeling": "feeling.by_date",
        "feeling_note": "feeling_note.by_date",
        "hrr_1min": "hrr_1min_drop.by_date",
        "hrr_2min": "hrr_2min_drop.by_date",
        "power_avg": "power.avg.by_date",
        "power_peak": "power.peak.by_date",
        "power_normalized": "power.normalized.by_date",
        "power_tss": "power.tss.by_date",
        "power_intensity": "power.intensity_factor.by_date",
        "power_variability": "power.variability.by_date",
        "timeline": "timeline.by_date",
        "deep_dive": "deep_dive.by_date"
    ]

    func resolveWorkout(args: [String: String]) async -> FactValue {
        guard let which = args["which"] else {
            return .missing(reason: .invalidParameter, detail: "get_workout requires 'which'")
        }
        if which == "segment_compare" { return await resolveSegmentCompare(args: args) }
        if which == "by_ordinal" { return await resolveWorkoutByOrdinal(args: args) }
        if which == "by_id" { return await resolveWorkoutByID(args: args) }
        guard let suffix = Self.datedWorkoutKeySuffixes[which] else {
            return .missing(reason: .invalidParameter, detail: "unknown which='\(which)' for get_workout")
        }
        guard let selector = Self.workoutSelector(args) else {
            return .missing(reason: .invalidParameter, detail: "which='\(which)' requires 'date' (YYYY-MM-DD) or 'id' (a workout UUID)")
        }
        return await registry.resolveAsync("workout.\(suffix)(\(selector))")
    }

    /// The argument every single-workout variant takes (`WorkoutSelector`):
    /// the workout's id when given, else the date with the sport and the
    /// position that day when given.
    static func workoutSelector(_ args: [String: String]) -> String? {
        if let id = nonEmpty(args["id"]) { return id }
        guard let date = nonEmpty(args["date"]) else { return nil }
        return ([date] + [args["sport"], args["position"]].compactMap(nonEmpty)).joined(separator: ",")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// `get_workout` which='by_id': one workout by its UUID.
    private func resolveWorkoutByID(args: [String: String]) async -> FactValue {
        guard let id = Self.nonEmpty(args["id"]) else {
            return .missing(reason: .invalidParameter, detail: "which='by_id' requires 'id' (a workout UUID)")
        }
        return await registry.resolveAsync("workout.by_id(\(id))")
    }

    /// `get_workout` which='by_ordinal': the `n`th most recent workout.
    private func resolveWorkoutByOrdinal(args: [String: String]) async -> FactValue {
        guard let n = args["n"] else {
            return .missing(reason: .invalidParameter, detail: "which='by_ordinal' requires 'n'")
        }
        return await registry.resolveAsync("workout.by_ordinal(\(n))")
    }

    /// `get_workout` which='segment_compare': every recent GPS workout that
    /// passed `point`, with what the user's body was doing at that spot.
    private func resolveSegmentCompare(args: [String: String]) async -> FactValue {
        guard let point = args["point"] else {
            return .missing(reason: .invalidParameter, detail: "which='segment_compare' requires 'point' ('lat,lon' or 'lat,lon,radius_m')")
        }
        let bound = Self.nonEmpty(args["date"]) ?? Self.nonEmpty(args["period"])
        return await registry.resolveAsync("workout.segment_compare(\([point, bound].compactMap { $0 }.joined(separator: ",")))")
    }

    /// A named `sport` rides on the period ('last_30d,run'), which the
    /// workout period lookups read as a sport filter.
    func resolveListWorkouts(args: [String: String]) async -> FactValue {
        var filtered = args
        if let period = args["period"], let sport = Self.nonEmpty(args["sport"]) { filtered["period"] = "\(period),\(sport)" }
        return await dispatch(
            args["which"] ?? "list",
            tool: "list_workouts",
            plain: [:],
            parameterized: Self.periodRows(prefix: "workout", ["list", "count", "recent"]),
            args: filtered
        )
    }

    func resolveWalks(args: [String: String]) async -> FactValue {
        guard let which = args["which"] else {
            return .missing(reason: .invalidParameter, detail: "get_walks requires 'which' and 'period'")
        }
        return await dispatch(
            which,
            tool: "get_walks",
            plain: [:],
            parameterized: Self.periodRows(prefix: "walks", ["count", "list", "total_distance_m", "total_trimp", "hardest", "summary"]),
            args: args
        )
    }

    /// Rows where each `which` value is the fact name `<prefix>.<which>`
    /// filled with the `period` argument.
    private static func periodRows(prefix: String, _ names: [String]) -> [String: ParameterizedRow] {
        Dictionary(uniqueKeysWithValues: names.map { ($0, ParameterizedRow("\(prefix).\($0)", "period")) })
    }

    /// `rmssd` and `hr` are window-selected; everything else is a flat key.
    func resolveBaseline(args: [String: String]) async -> FactValue {
        guard let metric = args["metric"] else {
            return .missing(reason: .invalidParameter, detail: "get_baseline requires 'metric'")
        }
        if let windows = Self.baselineWindows[metric] {
            return await windowedBaseline(metric: metric, windows: windows, args: args)
        }
        return await dispatch(
            metric,
            tool: "get_baseline",
            selector: "metric",
            plain: [
                "days_of_history": "baseline.days_of_history",
                "is_established": "baseline.is_established"
            ],
            args: args
        )
    }

    /// Resolve a windowed baseline, defaulting to the 30-day window.
    private func windowedBaseline(
        metric: String,
        windows: [String: String],
        args: [String: String]
    ) async -> FactValue {
        let window = args["window"] ?? "30d"
        guard let key = windows[window] else {
            return .missing(reason: .invalidParameter, detail: "unknown window='\(window)' for \(metric) baseline")
        }
        return await registry.resolveAsync(key)
    }

    /// Which windows each windowed baseline metric supports.
    private static let baselineWindows: [String: [String: String]] = [
        "rmssd": [
            "7d": "baseline.rmssd.mean_7d",
            "30d": "baseline.rmssd.mean_30d",
            "deviation_today": "baseline.rmssd.deviation_pct_today",
            "deviation_today_vs_30d": "baseline.rmssd.deviation_pct_today_vs_30d"
        ],
        "hr": [
            "7d": "baseline.hr.mean_7d",
            "30d": "baseline.hr.mean_30d",
            "deviation_today_vs_30d": "baseline.hr.deviation_pct_today_vs_30d"
        ]
    ]

    func resolveUser(args: [String: String]) async -> FactValue {
        let field = args["field"] ?? "profile"
        if let bundle = Self.userBundles[field] { return await resolveBundle(bundle) }
        // Anything else is an explicit field name — try profile, then settings.
        let profileKey = "user.profile.\(field)"
        if catalogDeclares(profileKey) { return await registry.resolveAsync(profileKey) }
        return await registry.resolveAsync("user.settings.\(field)")
    }

    /// Whether some namespace declares `key` as a fixed or composite fact —
    /// asked of the catalog itself rather than read from a missing value's
    /// message text.
    private func catalogDeclares(_ key: String) -> Bool {
        registry.namespaces.contains { $0.entries.contains { Self.entry($0, hasKey: key) } }
    }

    private static func entry(_ entry: FactEntry, hasKey key: String) -> Bool {
        switch entry {
        case .fixed(let k, _, _, _, _), .composite(let k, _, _, _, _, _): k == key
        case .parameterized, .action: false
        }
    }

    /// The two `field` values that answer with a record of several facts.
    private static let userBundles: [String: [(String, String)]] = [
        "profile": [
            ("age", "user.profile.age"),
            ("biological_sex", "user.profile.biological_sex"),
            ("max_hr", "user.profile.max_hr"),
            ("resting_hr", "user.profile.resting_hr"),
            ("lthr", "user.profile.lthr"),
            ("max_hr_is_user_set", "user.profile.max_hr_is_user_set"),
            ("lthr_is_user_set", "user.profile.lthr_is_user_set"),
            ("weight_kg", "user.profile.weight_kg"),
            ("cycling_ftp", "user.profile.cycling_ftp"),
            ("vo2_max", "user.profile.vo2_max"),
            ("vo2_max_is_override", "user.profile.vo2_max_is_override"),
            ("uses_healthkit_vo2max", "user.profile.uses_healthkit_vo2max"),
            ("vo2_max_trend", "user.profile.vo2_max_trend")
        ],
        "settings": [
            ("units", "user.settings.units"),
            ("typical_sleep_hours", "user.settings.typical_sleep_hours"),
            ("on_training_break", "user.settings.on_training_break"),
            ("comeback_mode_active", "user.settings.comeback_mode_active"),
            ("comeback_mode_day_in_window", "user.settings.comeback_mode_day_in_window")
        ]
    ]

    func resolveAppState(args: [String: String]) async -> FactValue {
        guard let aspect = args["aspect"] else {
            return .missing(reason: .invalidParameter, detail: "get_app_state requires 'aspect'")
        }
        if let bundle = Self.appStateBundles[aspect] {
            return await resolveBundle(bundle)
        }
        guard let key = Self.appStateSingletons[aspect] else {
            return .missing(reason: .invalidParameter, detail: "unknown aspect='\(aspect)' for get_app_state")
        }
        return await registry.resolveAsync(key)
    }

    /// Aspects that answer with a record of several facts at once.
    private static let appStateBundles: [String: [(String, String)]] = [
        "now": [
            ("iso", "app.now.iso"),
            ("local_date", "app.now.local_date"),
            ("day_of_week", "app.now.day_of_week"),
            ("timezone", "app.now.timezone")
        ],
        "devices": [
            ("polar_connected", "app.devices.polar.connected"),
            ("polar_battery_percent", "app.devices.polar.battery_percent"),
            ("polar_device_type", "app.devices.polar.device_type"),
            ("polar_firmware", "app.devices.polar.firmware"),
            ("polar_known_count", "app.devices.polar.known_count"),
            ("polar_recording_hours_since_charge", "app.devices.polar.recording_hours_since_charge"),
            ("polar_spec_capacity_hours", "app.devices.polar.spec_capacity_hours"),
            ("foot_pod_connected", "app.devices.foot_pod.connected"),
            ("foot_pod_known_count", "app.devices.foot_pod.known_count"),
            ("foot_pod_snapshot", "app.devices.foot_pod.snapshot"),
            ("pm5_connected", "app.devices.pm5.connected"),
            ("pm5_known_count", "app.devices.pm5.known_count"),
            ("zwift_advertising", "app.devices.zwift_broadcast.advertising"),
            ("zwift_subscribers", "app.devices.zwift_broadcast.subscriber_count")
        ],
        "settings": [
            ("healthkit_export_on", "app.settings.healthkit_export_on"),
            ("penalize_missing_sleep_on", "app.settings.penalize_missing_sleep_on"),
            ("sleep_hrv_augmentation_on", "app.settings.sleep_hrv_augmentation_on"),
            ("sleep_integration_on", "app.settings.sleep_integration_on"),
            ("training_load_integration_on", "app.settings.training_load_integration_on"),
            ("zwift_broadcast_on", "app.settings.zwift_broadcast_on")
        ]
    ]

    /// Aspects that answer with a single fact.
    private static let appStateSingletons: [String: String] = [
        "healthkit": "app.healthkit.available",
        "capabilities": "app.capabilities.has_barometer",
        "version": "app.version.schema.workout_metadata"
    ]

    /// Argument dispatch: one row per supported `which`
    /// value from the tool schema. The row count is fixed by the schema.
    func resolveTrainingLoad(args: [String: String]) async -> FactValue {
        guard let which = args["which"] else {
            return .missing(reason: .invalidParameter, detail: "get_training_load requires 'which'")
        }
        return await dispatch(
            which,
            tool: "get_training_load",
            plain: Self.trainingLoadKeys,
            parameterized: Self.trainingLoadParameterized,
            args: args
        )
    }

    /// `which` values that resolve to a fact key with no arguments.
    private static let trainingLoadKeys: [String: String] = [
        "snapshot": "training.load.snapshot",
        "atl": "training.load.atl",
        "ctl": "training.load.ctl",
        "tsb": "training.load.tsb",
        "acwr": "training.load.acwr",
        "this_week": "training.load.weekly.current",
        "last_4_weeks": "training.load.weekly.last_4_weeks",
        "trajectory": "training.trajectory",
        "recovery_hours_needed": "training.recovery_hours_needed",
        "days_until_fresh": "training.days_until_fresh",
        "pace_zones": "training.pace_zones",
        "heat_acclimation": "heat.acclimation.summary",
        "workout_streak": "workout.streak.consecutive_days",
        "workouts_this_week": "workout.streak.this_week_count"
    ]

    /// `which` values that take exactly one argument, and which one.
    private static let trainingLoadParameterized: [String: ParameterizedRow] = [
        "by_date": .init("training.load.by_date", "date"),
        "atl_by_date": .init("training.load.atl.by_date", "date"),
        "ctl_by_date": .init("training.load.ctl.by_date", "date"),
        "tsb_by_date": .init("training.load.tsb.by_date", "date"),
        "trimp_by_date": .init("training.load.trimp.by_date", "date"),
        "recent": .init("training.load.recent", "period"),
        "by_sport": .init("training.load.by_sport", "period"),
        "days_until_atl_converges": .init("training.days_until_atl_converges", "params"),
        "projected_tsb": .init("training.projected_tsb", "daily_trimp"),
        "race_predictions": .init("training.race_predictions", "sport"),
        "sport_baseline": .init("training.sport_baseline", "sport"),
        "hrr_trend_1min": .init("hrr.recent_avg_1min", "period"),
        "hrr_trend_2min": .init("hrr.recent_avg_2min", "period")
    ]

    func resolveScoreMeta(args: [String: String]) async -> FactValue {
        guard let field = args["field"] else {
            return .missing(reason: .invalidParameter, detail: "get_score_meta requires 'field'")
        }
        return await dispatch(
            field, tool: "get_score_meta", selector: "field",
            plain: ["algorithm_version": "score.algorithm.version", "history_recomputed": "score.history.recomputed_under_v2"],
            args: args
        )
    }

    func resolveBreadcrumbs(args: [String: String]) async -> FactValue {
        guard let field = args["field"] else {
            return .missing(reason: .invalidParameter, detail: "get_breadcrumbs requires 'field'")
        }
        let key = "breadcrumb.\(field)"
        return await registry.resolveAsync(key)
    }

    func resolveRoutes(args: [String: String]) async -> FactValue {
        guard let field = args["field"] else {
            return .missing(reason: .invalidParameter, detail: "get_routes requires 'field'")
        }
        return await dispatch(
            field, tool: "get_routes (use action tools to mutate)", selector: "field",
            plain: ["count": "routes.library.count", "list": "routes.library.list", "next_step": "directions.next_step"],
            args: args
        )
    }

    func resolveTags(args: [String: String]) async -> FactValue {
        guard let which = args["which"] else {
            return .missing(reason: .invalidParameter, detail: "get_tags requires 'which'")
        }
        if which == "count" { return await resolveTagCount(args: args) }
        if which == "tagged_in_period" { return await resolveTaggedInPeriod(args: args) }
        return await dispatch(
            which,
            tool: "get_tags",
            plain: [:],
            parameterized: [
                "correlation": .init("tags.correlation", "tag"),
                "list_active": .init("tags.list_active", "date"),
                "recent_tagged": .init("tags.recent_tagged", "tag"),
                "list": .init("tags.list", "period")
            ],
            args: args
        )
    }

    /// The sessions carrying `tag` in `period`.
    private func resolveTaggedInPeriod(args: [String: String]) async -> FactValue {
        guard let tag = args["tag"], let period = args["period"] else {
            return .missing(reason: .invalidParameter, detail: "which='tagged_in_period' requires 'tag' and 'period'")
        }
        return await registry.resolveAsync("tags.tagged_in_period(\(tag),\(period))")
    }

    /// Within `period` when one is passed, else across the whole archive.
    private func resolveTagCount(args: [String: String]) async -> FactValue {
        guard let tag = args["tag"] else { return .missing(reason: .invalidParameter, detail: "which='count' requires 'tag'") }
        if let period = args["period"], !period.isEmpty {
            return await registry.resolveAsync("tags.count_in_period(\(tag),\(period))")
        }
        return await registry.resolveAsync("tags.count(\(tag))")
    }

    func resolveWorkoutLive(args: [String: String]) async -> FactValue {
        let field = args["field"] ?? "snapshot"
        // Most fields share the simple `workout.live.<field>` shape.
        return await registry.resolveAsync("workout.live.\(field)")
    }

    func resolveAssistantState(args: [String: String]) async -> FactValue {
        guard let field = args["field"] else {
            return .missing(reason: .invalidParameter, detail: "get_assistant_state requires 'field'")
        }
        return await dispatch(
            field, tool: "get_assistant_state", selector: "field",
            plain: [
                "memory_list": "assistant.memory.list",
                "memory_count": "assistant.memory.count",
                "memory_auto_extract_enabled": "assistant.memory.auto_extract_enabled",
                "contacts_list": "assistant.contacts.list"
            ],
            args: args
        )
    }

    /// `get_stored_record`: one session by `id`, else every session on
    /// `date` or in `period`, with `kind` keeping one session type.
    func resolveStoredRecord(args: [String: String]) async -> FactValue {
        if let id = Self.nonEmpty(args["id"]) { return await registry.resolveAsync("stored.by_id(\(id))") }
        let kind = Self.nonEmpty(args["kind"]).map { ",\($0)" } ?? ""
        if let date = Self.nonEmpty(args["date"]) { return await registry.resolveAsync("stored.by_date(\(date)\(kind))") }
        if let period = Self.nonEmpty(args["period"]) { return await registry.resolveAsync("stored.in_period(\(period)\(kind))") }
        return .missing(reason: .invalidParameter, detail: "get_stored_record requires 'id', 'date' (YYYY-MM-DD) or 'period'")
    }

    /// `find_data`: the catalog entries that match `query`, each with what
    /// it is and how to get it. An action the router doesn't advertise is
    /// left out, since naming a tool the model can't call would only send
    /// it to a refusal.
    func resolveFindData(query: String) -> FactValue {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .missing(reason: .invalidParameter, detail: "find_data requires 'query'")
        }
        let rows = registry.entries(matching: query, limit: Self.findDataLimit + 4).compactMap(Self.findDataRow(for:))
        guard !rows.isEmpty else {
            return .missing(reason: .notRecorded, detail: "nothing in the app matches '\(query)'; try other words")
        }
        return .list(Array(rows.prefix(Self.findDataLimit)))
    }

    static let findDataLimit = 8

    /// One match: the action to call, or the key `lookup_fact` reads, and
    /// what it is. Nil for an action the router doesn't advertise.
    private static func findDataRow(for entry: FactEntry) -> FactValue? {
        guard entry.isAction else {
            return .record(["lookup_fact_key": .string(entry.display), "about": .string(summary(of: entry))])
        }
        let tool = FactResolverRegistry.toolName(for: entry)
        guard allowedActionNames.contains(tool) else { return nil }
        return .record(["call_tool": .string(tool), "about": .string(summary(of: entry))])
    }

    /// The first two sentences of an entry's description, without its
    /// `[ACTION]`-style tag, capped so eight matches stay small.
    private static func summary(of entry: FactEntry) -> String {
        let text = entry.entryDescription.replacingOccurrences(of: #"^\[[A-Z-]+\]\s*"#, with: "", options: .regularExpression)
        let sentences = text.components(separatedBy: ". ").prefix(2).joined(separator: ". ")
        return sentences.count > 280 ? String(sentences.prefix(280)) + "…" : sentences
    }

    // MARK: - Helpers

    /// Resolve N keys and bundle into one `.record` FactValue keyed by
    /// display label. Used by tools that return a bag of related fields
    /// in one call (get_user profile, get_app_state devices, get_hrv
    /// window). Missing children are kept in the record so the model
    /// can see which sub-fields had no data.
    func resolveBundle(_ pairs: [(label: String, key: String)]) async -> FactValue {
        var children: [String: FactValue] = [:]
        for (label, key) in pairs {
            children[label] = await registry.resolveAsync(key)
        }
        return .record(children)
    }
}
