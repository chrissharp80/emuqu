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
                "by_ordinal": .init("session.by_ordinal", "n", hint: " (integer)")
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
                "trend": .init("recovery.trend", "period")
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
            parameterized: [
                "by_date": .init("hrv.by_date", "date"),
                "recent": .init("hrv.recent", "period")
            ],
            args: args
        )
    }

    func resolveSleep(args: [String: String]) async -> FactValue {
        let which = args["which"] ?? "latest"
        switch which {
        case "latest":
            return await registry.resolveAsync("sleep.latest")
        case "by_date":
            guard let date = args["date"] else {
                return .missing(reason: .invalidParameter, detail: "which='by_date' requires 'date'")
            }
            return await registry.resolveAsync("sleep.by_date(\(date))")
        case "recent":
            guard let period = args["period"] else {
                return .missing(reason: .invalidParameter, detail: "which='recent' requires 'period'")
            }
            return await registry.resolveAsync("sleep.recent(\(period))")
        default:
            return .missing(reason: .invalidParameter, detail: "unknown which='\(which)' for get_sleep")
        }
    }

    /// `which` → fact-key suffix, for every `get_workout` variant whose whole
    /// implementation is "resolve this dated fact".
    ///
    /// These twelve are a table rather than one `case` each inside `resolveWorkout`
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
        "timeline": "timeline.by_date"
    ]

    func resolveWorkout(args: [String: String]) async -> FactValue {
        guard let which = args["which"] else {
            return .missing(reason: .invalidParameter, detail: "get_workout requires 'which'")
        }

        let key: String?
        if which == "by_ordinal" {
            guard let n = args["n"] else {
                return .missing(reason: .invalidParameter, detail: "which='by_ordinal' requires 'n'")
            }
            key = "workout.by_ordinal(\(n))"
        } else if let suffix = Self.datedWorkoutKeySuffixes[which] {
            key = args["date"].map { "workout.\(suffix)(\($0))" }
        } else {
            return .missing(reason: .invalidParameter, detail: "unknown which='\(which)' for get_workout")
        }

        guard let resolvedKey = key else {
            return .missing(reason: .invalidParameter, detail: "which='\(which)' requires 'date' (YYYY-MM-DD)")
        }
        return await registry.resolveAsync(resolvedKey)
    }

    func resolveListWorkouts(args: [String: String]) async -> FactValue {
        guard let period = args["period"] else {
            return .missing(reason: .invalidParameter, detail: "list_workouts requires 'period'")
        }
        let which = args["which"] ?? "list"
        switch which {
        case "list":
            return await registry.resolveAsync("workout.list(\(period))")
        case "count":
            return await registry.resolveAsync("workout.count(\(period))")
        case "recent":
            return await registry.resolveAsync("workout.recent(\(period))")
        default:
            return .missing(reason: .invalidParameter, detail: "unknown which='\(which)' for list_workouts")
        }
    }

    func resolveWalks(args: [String: String]) async -> FactValue {
        guard let which = args["which"], let period = args["period"] else {
            return .missing(reason: .invalidParameter, detail: "get_walks requires 'which' and 'period'")
        }
        switch which {
        case "count": return await registry.resolveAsync("walks.count(\(period))")
        case "list": return await registry.resolveAsync("walks.list(\(period))")
        case "total_distance_m": return await registry.resolveAsync("walks.total_distance_m(\(period))")
        case "total_trimp": return await registry.resolveAsync("walks.total_trimp(\(period))")
        case "hardest": return await registry.resolveAsync("walks.hardest(\(period))")
        default:
            return .missing(reason: .invalidParameter, detail: "unknown which='\(which)' for get_walks")
        }
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
        let profileResult = await registry.resolveAsync("user.profile.\(field)")
        if !profileResult.isMissingUnknownKey { return profileResult }
        return await registry.resolveAsync("user.settings.\(field)")
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
        ],
        "subscription": [
            ("is_in_trial", "app.subscription.is_in_trial"),
            ("trial_days_remaining", "app.subscription.trial_days_remaining"),
            ("trial_started_at", "app.subscription.trial_started_at")
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
        "pace_zones": "training.pace_zones"
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
        "sport_baseline": .init("training.sport_baseline", "sport")
    ]

    func resolveScoreMeta(args: [String: String]) async -> FactValue {
        guard let field = args["field"] else {
            return .missing(reason: .invalidParameter, detail: "get_score_meta requires 'field'")
        }
        switch field {
        case "algorithm_version": return await registry.resolveAsync("score.algorithm.version")
        case "history_recomputed": return await registry.resolveAsync("score.history.recomputed_under_v2")
        default:
            return .missing(reason: .invalidParameter, detail: "unknown field='\(field)' for get_score_meta")
        }
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
        switch field {
        case "count": return await registry.resolveAsync("routes.library.count")
        case "list": return await registry.resolveAsync("routes.library.list")
        default:
            return .missing(reason: .invalidParameter, detail: "unknown field='\(field)' for get_routes (use action tools to mutate)")
        }
    }

    func resolveTags(args: [String: String]) async -> FactValue {
        guard let which = args["which"] else {
            return .missing(reason: .invalidParameter, detail: "get_tags requires 'which'")
        }
        switch which {
        case "correlation":
            guard let tag = args["tag"] else { return .missing(reason: .invalidParameter, detail: "which='correlation' requires 'tag'") }
            return await registry.resolveAsync("tags.correlation(\(tag))")
        case "count":
            guard let tag = args["tag"] else { return .missing(reason: .invalidParameter, detail: "which='count' requires 'tag'") }
            return await registry.resolveAsync("tags.count(\(tag))")
        case "list_active":
            guard let date = args["date"] else { return .missing(reason: .invalidParameter, detail: "which='list_active' requires 'date'") }
            return await registry.resolveAsync("tags.list_active(\(date))")
        case "recent_tagged":
            guard let tag = args["tag"] else { return .missing(reason: .invalidParameter, detail: "which='recent_tagged' requires 'tag'") }
            return await registry.resolveAsync("tags.recent_tagged(\(tag))")
        default:
            return .missing(reason: .invalidParameter, detail: "unknown which='\(which)' for get_tags")
        }
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
        switch field {
        case "memory_list": return await registry.resolveAsync("assistant.memory.list")
        case "memory_count": return await registry.resolveAsync("assistant.memory.count")
        case "memory_auto_extract_enabled": return await registry.resolveAsync("assistant.memory.auto_extract_enabled")
        case "contacts_list": return await registry.resolveAsync("assistant.contacts.list")
        default:
            return .missing(reason: .invalidParameter, detail: "unknown field='\(field)' for get_assistant_state")
        }
    }

    // MARK: - Helpers

    /// Parse a JSON args object into `[String: String]` — same coercion
    /// rules as the registry's action-arg parser (numbers/bools coerced
    /// to their string representation; missing keys absent).
    func parseArgs(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in obj {
            if let s = value as? String { out[key] = s } else if let n = value as? Int { out[key] = String(n) } else if let d = value as? Double { out[key] = String(d) } else if let b = value as? Bool { out[key] = b ? "true" : "false" }
        }
        return out
    }

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

// MARK: - FactValue convenience

private extension FactValue {
    /// True when this value is `.missing(reason: .notRecorded, detail
    /// containing 'no such key')` — i.e. the key didn't exist in the
    /// catalog. `resolveUser` uses this to decide whether to fall back
    /// to the settings namespace when the user passed a bare field name.
    var isMissingUnknownKey: Bool {
        if case .missing(let reason, let detail) = self,
           reason == .notRecorded,
           let detail, detail.hasPrefix("no such key") {
            return true
        }
        return false
    }
}
