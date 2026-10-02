import Foundation

/// Compact, polymorphic tool schema for the AI Coach.
///
/// **Why this exists.** The Fact Catalog has 200+ entries (one per
/// metric). Emitting one tool per entry blows up the LLM's tool list,
/// degrades reasoning, kills cache-hit rate, and trips per-provider
/// caps (xAI Grok 4.1 Fast = 200 max). The catalog itself is correctly
/// granular for code that needs typed resolvers — but the model only
/// needs to know "ask for a session by date" or "list workouts last
/// week," not 30 distinct tool names for the variations.
///
/// **What this is.** A schema-side translator: ~20 well-described
/// polymorphic tools that map (tool_name, args) → underlying fact-key
/// strings, then forward to `FactResolverRegistry.resolveAsync(_:)`
/// (the suspending twin of `resolve(_:)` — see FactCatalog.swift). The
/// existing fact catalog and resolvers are unchanged. The model sees
/// a tighter, easier-to-reason-about surface; the user gets identical
/// answers.
///
/// **Tool budget.**
///   • 19 read tools (cover all `.fixed` + `.parameterized` + `.composite`)
///   • 11 action tools (preserved verbatim — write operations stay
///     visible because their identity matters: `assistant_email_compose`
///     vs `assistant_contacts_add` are different audit-trail events).
///
/// Total: ~30, leaving room for new actions without re-tripping caps.
@MainActor
struct CompactToolRouter {
    let registry: FactResolverRegistry

    // MARK: - Schema

    /// The compact tool list returned to providers in place of
    /// `FactResolverRegistry.toolSchema()`.
    static func schema(registry: FactResolverRegistry) -> [ToolSpec] {
        let specs = readTools() + actionTools(registry: registry)
        return deduped(specs).sorted { $0.name < $1.name }
    }

    /// Defensive dedupe. Anthropic returns
    /// HTTP 400 ("tools: Tool names must be unique") if any
    /// two ToolSpecs share a name. Confirmed in production via
    /// the [Assistant] primary-failure log: every voice turn
    /// was 400-ing on this exact validator and falling back to
    /// OpenAI, which made the user think they were stuck on
    /// OpenAI even when they'd selected Grok / Anthropic.
    ///
    /// Read tools are hard-coded; action tools come from the
    /// registry's `toolSchema()` filtered by an allow-list. A
    /// collision can happen if (a) the registry emits two
    /// entries that translate to the same snake_case tool
    /// name after dot→underscore mapping, or (b) a future
    /// read tool is added with a name that happens to also be
    /// in the action allow-list. Dedupe here keeps both
    /// future failure modes invisible to the model. First
    /// occurrence wins (read tools are appended first; they
    /// shadow any action with the same name). A debug log
    /// surfaces collisions so the underlying duplication can
    /// be cleaned up later — this is a guard, not the cure.
    private static func deduped(_ specs: [ToolSpec]) -> [ToolSpec] {
        var seen: Set<String> = []
        var out: [ToolSpec] = []
        out.reserveCapacity(specs.count)
        for spec in specs {
            guard seen.insert(spec.name).inserted else {
                debugLog("[CompactToolRouter] dropping duplicate tool spec '\(spec.name)' — first occurrence wins. Investigate fact-catalog registration.", level: .warning)
                continue
            }
            out.append(spec)
        }
        return out
    }

    /// Stable hash of the schema for cache-stability diagnostics.
    static func schemaHash(registry: FactResolverRegistry) -> String {
        let specs = schema(registry: registry)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = attempt("compactToolRouter.specs.encode", { try encoder.encode(specs) }) else { return "unknown" }
        return FactResolverRegistry.sha256Hex(data)
    }

    // MARK: - Dispatch

    /// Resolve a compact tool call. For action tools we forward to the
    /// underlying registry verbatim (they keep their original names for
    /// audit-trail clarity). For read tools we translate args → fact-key.
    /// `async`: the registry's tool path suspends on the
    /// handful of `.awaitable` resolvers (network / HealthKit / geo)
    /// instead of parking the main thread behind semaphores. Both
    /// production callers (AssistantViewModel's tool loop and
    /// AppleToolDispatcher) are async.
    func resolveTool(name: String, argsJSON: String) async -> FactValue {
        // 1. Try the read-tool router first.
        if let value = await resolveReadTool(name: name, argsJSON: argsJSON) {
            return value
        }
        // 2. Action tools (and any underlying-key tools that legacy
        //    callers still rely on) flow through the registry.
        return await registry.resolveTool(name: name, argsJSON: argsJSON)
    }

    // MARK: - Capability index (progressive-disclosure "menu")

    /// A generated, always-current index of the DATA the assistant can
    /// retrieve — one line per typed read tool, name + its one-sentence
    /// purpose. Injected into the (cached) system prompt so the model is TOLD
    /// what's reachable instead of guessing or denying it. Generated from
    /// `readTools()`, so it can NEVER drift from the real schema the way the
    /// hand-written capability docs did. This is the progressive-disclosure
    /// index layer (Anthropic "effective context engineering"): a small,
    /// always-present table of contents up front; the tools themselves are the
    /// just-in-time fetch. Byte-stable across sends → safe in the cached prefix.
    static func capabilityIndex() -> String {
        let lines = readTools().map { spec -> String in
            let purpose = spec.description.components(separatedBy: ". ").first ?? spec.description
            let capped = purpose.count > 170 ? String(purpose.prefix(170)) + "…" : purpose
            return "- \(spec.name): \(capped)"
        }
        return """
        # What you can retrieve (data tools)
        These tools fetch the user's OWN data from the app. For ANY question about \
        the user's recovery, HRV, sleep, vitals, training load, trajectory, workouts, \
        routes, tags, or trends, CALL the matching tool BEFORE answering. Never claim \
        you don't have the data without calling the tool first — the app has it, and \
        today's headline figures are already in the live-state block below.

        \(lines.joined(separator: "\n"))
        """
    }

    // MARK: - Read tool catalog

    // Tool-schema catalogue — one `spec(...)` row per tool.
    // Same shape as `WorkoutTriggerEngine.defaultRules`: data, not control flow.
    //
    // Sliced into `readTools1…N` purely for length. The catalogue is one flat
    // list to the model and the numbering runs 1–20 straight through the
    // slices, so a row keeps its number wherever the slice boundary lands.
    private static func readTools() -> [ToolSpec] {
        readTools1() + readTools1b() + readTools2() + readTools2b() + readTools3() + readTools3a() + readTools3b() + readTools4() + readTools4b()
            + readTools5() + readTools5b() + readTools6() + readTools6b() + readTools7()
    }

    /// One `ToolSpec` from a compact row: name, description, and the string
    /// properties it accepts. Every property in this catalogue is a string, so
    /// the type is implied here rather than repeated at forty call sites.
    private static func spec(
        _ name: String,
        _ description: String,
        _ properties: [(String, String)] = [],
        required: [String] = []
    ) -> ToolSpec {
        ToolSpec(
            name: name,
            description: description,
            inputSchema: ToolSpec.InputSchema(
                properties: Dictionary(uniqueKeysWithValues: properties.map {
                    ($0.0, ToolSpec.Property(type: "string", description: $0.1))
                }),
                required: required
            )
        )
    }

    private static func readTools1() -> [ToolSpec] {
        [
            // 1. get_today
            spec("get_today", "Today's full recovery snapshot — score, HRV (RMSSD), sleep summary, vitals, training context. Call this first when the user asks 'how am I doing today' or wants a quick status."),
            // 2. get_session
            spec("get_session", "Look up an overnight HRV session. `which`: 'latest' (default), 'by_date', 'by_id', or 'by_ordinal'. For 'by_date' pass `date` as YYYY-MM-DD; for 'by_id' pass `id` (UUID); for 'by_ordinal' pass `n` as integer where 0 = most recent.", [
                ("which", "'latest', 'by_date', 'by_id', or 'by_ordinal'"),
                ("date", "YYYY-MM-DD (required when which='by_date')"),
                ("id", "Session UUID (required when which='by_id')"),
                ("n", "Ordinal index, 0 = most recent (required when which='by_ordinal')")
            ])
        ]
    }

    private static func readTools1b() -> [ToolSpec] {
        [
            // 3. get_recovery
            spec("get_recovery", """
                Recovery score lookup. `which`: 'latest' (default), 'by_date', 'recent', 'week_summary', 'trend'. Use 'trend' for 'am I improving over time?' — it returns the improving/stable/declining verdict + HRV & resting-HR slopes from the archive \
                (no strap/reading needed). For 'by_date' pass `date` as YYYY-MM-DD; for 'recent' and 'trend' pass `period` (7d / 14d / 30d / 60d / 90d / 180d / 365d / today / yesterday / last_week / this_week / last_month / last_quarter / last_year / \
                all_time).
                """, [
                ("which", "'latest', 'by_date', 'recent', 'week_summary', or 'trend'"),
                ("date", "YYYY-MM-DD"),
                ("period", "7d / 14d / 30d / 60d / 90d / 180d / 365d / today / yesterday / last_week / this_week / last_month / last_quarter / last_year / all_time")
            ])
        ]
    }

    private static func readTools2() -> [ToolSpec] {
        [
            // 4. get_hrv
            spec("get_hrv", """
                HRV (RMSSD + window classification) lookup. `which`: 'latest' (default), 'by_date', 'recent', 'live_snapshot', 'window'. For 'by_date' pass `date`; for 'recent' pass `period`. 'live_snapshot' returns current live recording state. 'window' \
                returns the analysis-window classification (organized recovery, consolidated, etc.).
                """, [
                ("which", "'latest', 'by_date', 'recent', 'live_snapshot', or 'window'"),
                ("date", "YYYY-MM-DD"),
                ("period", "7d / 14d / 30d / 90d / 180d / 365d / last_week / last_month / last_year / all_time")
            ]),
            // 5. get_sleep
            spec("get_sleep", "Sleep data lookup. `which`: 'latest' (default), 'by_date', 'recent'. For 'by_date' pass `date`; for 'recent' pass `period`.", [
                ("which", "'latest', 'by_date', or 'recent'"),
                ("date", "YYYY-MM-DD"),
                ("period", "7d / 14d / 30d / 90d / 180d / 365d / last_week / last_month / last_year / all_time")
            ])
        ]
    }

    private static func readTools2b() -> [ToolSpec] {
        [
            // 6. get_vitals
            spec("get_vitals", "Overnight vitals (resting HR, respiratory rate, temperature, SpO2) for a specific date. Pass `date` as YYYY-MM-DD.", [
                ("date", "YYYY-MM-DD")
            ], required: ["date"])
        ]
    }

    private static func readTools3() -> [ToolSpec] {
        [
            // 7. get_workout
            spec("get_workout", """
                Workout lookup. `which` selects what shape of data to return. Aggregates: 'by_date', 'by_ordinal', 'feeling', 'feeling_note', 'hrr_1min', 'hrr_2min', 'power_avg', 'power_peak', 'power_normalized', 'power_tss', 'power_intensity', 'power_variability'. \
                **Per-second analysis primitive: 'timeline'** — returns a downsampled (~200 buckets) time-series of HR, pace, cadence, altitude, grade, α1, power per bucket. Use 'timeline' for ANY question that needs the time-series shape: 'did my HR \
                spike when I was flat / going downhill', 'where did pace drop on the climb', 'was α1 still healthy late in the workout', 'where did cadence collapse', 'did power drop while HR held'. The timeline gives you the resolution to find spikes, \
                correlations, and segments without needing pre-computed special cases. All variants take `date` (YYYY-MM-DD) except 'by_ordinal' which takes `n`.
                """, [
                ("which", "Variant — see description for full list"),
                ("date", "YYYY-MM-DD"),
                ("n", "Ordinal, 0 = most recent (for which='by_ordinal')")
            ], required: ["which"])
        ]
    }

    private static func readTools3a() -> [ToolSpec] {
        [
            // 8. list_workouts
            spec("list_workouts", """
                PRIMARY tool for ANY workout history question — runs, walks, hikes, bikes, rows, all sports. Use this whenever the user asks 'what workouts did I do', 'show me this week's training', 'how many runs', 'what's my recent activity'. `which`: \
                'list' (default — full session records), 'count', 'recent' (period summary). Pass `period` like '7d', '30d', 'this_week', 'last_week'. **Do NOT use get_walks for general workout questions** — that tool is walk-only and will return empty \
                if the user did runs/rides/hikes.
                """, [
                ("which", "'list', 'count', or 'recent'"),
                ("period", "7d / 14d / 30d / 60d / 90d / 180d / 365d / today / yesterday / last_week / this_week / last_month / last_quarter / last_year / all_time")
            ], required: ["period"])
        ]
    }

    private static func readTools3b() -> [ToolSpec] {
        [
            // 9. get_walks
            spec("get_walks", "Walk-only aggregates (separate from runs/rides). `which`: 'count', 'list', 'total_distance_m', 'total_trimp', 'hardest'. Pass `period` like '7d', '30d'.", [
                ("which", "'count', 'list', 'total_distance_m', 'total_trimp', or 'hardest'"),
                ("period", "7d / 14d / 30d / 90d / 180d / 365d / last_week / last_month / last_year / all_time")
            ], required: ["which", "period"])
        ]
    }

    private static func readTools4() -> [ToolSpec] {
        [
            // 10. get_baseline
            spec("get_baseline", "Baseline stats (rolling means + deviations). `metric`: 'rmssd', 'hr', 'days_of_history', 'is_established'. For 'rmssd' and 'hr' pass `window` ('7d', '30d', 'deviation_today_vs_30d', 'deviation_today').", [
                ("metric", "'rmssd', 'hr', 'days_of_history', or 'is_established'"),
                ("window", "'7d', '30d', 'deviation_today_vs_30d', or 'deviation_today'")
            ], required: ["metric"]),
            // 11. get_user
            spec("get_user", """
                User profile + settings. `field`: 'profile' (returns age, sex, max HR, RHR, LTHR, weight, FTP, VO2 max, etc.) or 'settings' (units, typical sleep, training break, comeback mode, etc.) or one specific key like 'max_hr', 'resting_hr', 'lthr', \
                'weight_kg', 'biological_sex', 'age', 'cycling_ftp', 'vo2_max'.
                """, [
                ("field", "'profile', 'settings', or a specific field name")
            ])
        ]
    }

    private static func readTools4b() -> [ToolSpec] {
        [
            // 12. get_app_state
            spec("get_app_state", """
                Current app/device state. `aspect`: 'now' (date/time/timezone), 'devices' (Polar, foot pod, PM5, Zwift broadcast), 'settings' (toggles), \
                'subscription' (one-time purchase and trial state), 'healthkit' (availability), 'capabilities' (barometer presence), 'version' (schema versions).
                """, [
                ("aspect", "'now', 'devices', 'settings', 'subscription', 'healthkit', 'capabilities', or 'version'")
            ], required: ["aspect"])
        ]
    }

    private static func readTools5() -> [ToolSpec] {
        [
            // 13. get_training_load
            spec("get_training_load", """
                Training load + trajectory (ATL/CTL/TSB/TRIMP/ACWR). `which`: 'snapshot' (default — current values), 'trajectory' (the Load & Trajectory verdict: building/detraining/high-strain, ramp band + rate, form descriptor, monotony/strain), 'by_date', \
                'recent', 'this_week', 'last_4_weeks', 'by_sport', 'recovery_hours_needed', 'days_until_fresh', 'days_until_atl_converges', 'projected_tsb', 'race_predictions', 'sport_baseline', 'pace_zones'. Pass `date`, `period`, `sport`, `daily_trimp`, \
                or `params` as needed.
                """, [
                ("which", "Variant — see description"),
                ("date", "YYYY-MM-DD"),
                ("period", "7d / 14d / 30d / 90d / 180d / 365d / last_week / last_month / last_year / all_time"),
                ("sport", "Sport identifier (run, bike, walk, etc.)"),
                ("daily_trimp", "Daily TRIMP value (number as string)"),
                ("params", "Comma-separated parameter blob for advanced queries")
            ], required: ["which"])
        ]
    }

    private static func readTools5b() -> [ToolSpec] {
        [
            // 14. get_score_meta
            spec("get_score_meta", "Recovery-score algorithm metadata. `field`: 'algorithm_version' (current scoring version, e.g. 'v2.may2026') or 'history_recomputed' (whether the user has run the v1→v2 history recompute).", [
                ("field", "'algorithm_version' or 'history_recomputed'")
            ], required: ["field"]),
            // 15. get_breadcrumbs
            spec("get_breadcrumbs", "GPS breadcrumb trail state. `field`: 'active', 'count', 'current_fix', 'derived_grade_percent', 'recent', 'recent_track'.", [
                ("field", "Specific field — see description")
            ], required: ["field"])
        ]
    }

    private static func readTools6() -> [ToolSpec] {
        [
            // 16. get_routes
            spec("get_routes", "Saved-route library (read-only). `field`: 'count' or 'list'. To rename or save a route, use the dedicated action tools.", [
                ("field", "'count' or 'list'")
            ], required: ["field"]),
            // 17. get_tags
            spec("get_tags", """
                Tag-correlation lookups. `which`: 'correlation' (correlation between a tag and recovery score), 'count' (sessions with this tag in a period), 'list_active' (tags on a specific date), 'recent_tagged' (recent sessions matching a tag). Pass \
                `tag` and/or `date`/`period` as needed.
                """, [
                ("which", "'correlation', 'count', 'list_active', or 'recent_tagged'"),
                ("tag", "Tag name"),
                ("date", "YYYY-MM-DD"),
                ("period", "7d / 14d / 30d / 90d / 180d / 365d / last_week / last_month / last_year / all_time")
            ], required: ["which"])
        ]
    }

    private static func readTools6b() -> [ToolSpec] {
        [
            // 18. get_workout_live
            spec("get_workout_live", """
                Live workout state (only meaningful while a workout is recording). `field`: 'snapshot' (default — full bundle), or specific fields like 'hr', 'pace_sec_per_km', 'speed_m_per_s', 'power_watts', 'sport', 'location', 'weather', 'today_readiness', \
                'thresholds', 'interval', 'route_topology', 'recognized_route', 'hr_drift_percent', 'reverse_split_delta_sec_per_km', 'hrr_capture_status', 'units_preference', 'training_pace_zones', 'route_history_baseline'.
                """, [
                ("field", "Field name (default 'snapshot')")
            ])
        ]
    }

    private static func readTools7() -> [ToolSpec] {
        [
            // 19. get_assistant_state
            spec("get_assistant_state", """
                Assistant memory/contacts state (read-only). `field`: 'memory_list' (all stored memory facts), 'memory_count', 'memory_auto_extract_enabled' (whether auto-memory is on), 'contacts_list' (saved contacts). To add/remove contacts or memories, \
                use dedicated action tools.
                """, [
                ("field", "'memory_list', 'memory_count', 'memory_auto_extract_enabled', or 'contacts_list'")
            ], required: ["field"]),
            // 20. lookup_fact (universal fallback)
            spec("lookup_fact", """
                Long-tail fact lookup by raw fact-catalog key. Use this only when no other tool fits — most needs are covered by the typed tools above. Example keys: 'recovery.today.full', 'session.latest.id', 'training.load.acwr'. Pass `key` as the \
                dotted path. Parameterised keys take their parameter inline like 'session.by_date(2026-04-21)'.
                """, [
                ("key", "Dotted fact-catalog key")
            ], required: ["key"])
        ]
    }

    // MARK: - Action tools (preserved, registry-resolved)

    /// Action entries keep their original tool names so the audit
    /// trail and downstream side effects (email send, contact write,
    /// location share, route rename) remain identifiable. We pull
    /// their specs from the underlying registry's full schema and
    /// filter by name prefix.
    private static func actionTools(registry: FactResolverRegistry) -> [ToolSpec] {
        registry.toolSchema().filter { allowedActionNames.contains($0.name) }
    }

    /// `assistant_memory_*` is bidirectional memory:
    /// the AI can write to UserFactsStore, not just read it.
    private static let allowedActionNames: Set<String> = [
        "routes_library_rename",
        "routes_library_save_workout",
        "routes_library_engage",
        "assistant_contacts_add",
        "assistant_contacts_remove",
        "assistant_email_compose",
        "assistant_memory_add",
        "assistant_memory_remove",
        "assistant_memory_clear",
        "web_search",
        "location_current",
        "location_current_detailed",
        "location_situation",
        "location_set_address",
        "directions_routeTo",
        "directions_clear"
    ]

    // MARK: - Read-tool dispatch

    /// Returns nil if the tool isn't a compact read tool. Returns a
    /// FactValue otherwise (which may itself be `.missing` for bad args).
    /// Tool name → resolver, for every read tool whose whole implementation
    /// is "hand the parsed args to a resolver of the same shape".
    ///
    /// As `case "get_x": return await
    /// resolveX(args: args)` rows inside `resolveReadTool`, these seventeen
    /// were most of that function's cyclomatic complexity. They share one
    /// signature exactly, so the mapping is data, not control flow: a table
    /// makes adding a tool a one-line edit and makes the genuinely
    /// *different* tools below (which parse their own arguments or fan out to
    /// the registry directly) visible instead of buried in a wall of
    /// identical cases.
    private var uniformReadResolvers: [String: ([String: String]) async -> FactValue] {
        [
            "get_session": resolveSession(args:),
            "get_recovery": resolveRecovery(args:),
            "get_hrv": resolveHRV(args:),
            "get_sleep": resolveSleep(args:),
            "get_workout": resolveWorkout(args:),
            "list_workouts": resolveListWorkouts(args:),
            "get_walks": resolveWalks(args:),
            "get_baseline": resolveBaseline(args:),
            "get_user": resolveUser(args:),
            "get_app_state": resolveAppState(args:),
            "get_training_load": resolveTrainingLoad(args:),
            "get_score_meta": resolveScoreMeta(args:),
            "get_breadcrumbs": resolveBreadcrumbs(args:),
            "get_routes": resolveRoutes(args:),
            "get_tags": resolveTags(args:),
            "get_workout_live": resolveWorkoutLive(args:),
            "get_assistant_state": resolveAssistantState(args:)
        ]
    }

    private func resolveReadTool(name: String, argsJSON: String) async -> FactValue? {
        let args = parseArgs(argsJSON)
        if let resolver = uniformReadResolvers[name] {
            return await resolver(args)
        }
        switch name {
        case "get_today":
            return await registry.resolveAsync("recovery.today.full")
        case "get_vitals":
            guard let date = args["date"] else { return .missing(reason: .invalidParameter, detail: "get_vitals requires 'date' (YYYY-MM-DD)") }
            return await registry.resolveAsync("vitals.by_date(\(date))")
        case "get_healthkit":
            return await resolveHealthKitTool(field: args["field"] ?? "")
        case "lookup_fact":
            guard let key = args["key"] else { return .missing(reason: .invalidParameter, detail: "lookup_fact requires 'key'") }
            return await registry.resolveAsync(key)
        default:
            return nil // not a compact read tool
        }
    }

    /// Idle HealthKit reads (works outside an active workout).
    /// Two fields exposed; both backed by facts in `AppHealthKitNamespace`.
    private func resolveHealthKitTool(field: String) async -> FactValue {
        switch field {
        case "heart_rate_latest":
            return await registry.resolveAsync("app.healthkit.heart_rate_latest")
        case "today_activity":
            return await registry.resolveAsync("app.healthkit.today_activity")
        default:
            return .missing(reason: .invalidParameter, detail: "get_healthkit field must be 'heart_rate_latest' or 'today_activity'")
        }
    }
}
