import Foundation

/// Compact, polymorphic tool schema for the AI Coach.
///
/// **Why.** The Fact Catalog has 200+ entries (one per
/// metric). Emitting one tool per entry blows up the LLM's tool list,
/// degrades reasoning, kills cache-hit rate, and trips per-provider
/// caps. The
/// catalog itself is correctly granular for code that needs typed
/// resolvers — but the model only
/// needs to know "ask for a session by date" or "list workouts last
/// week," not 30 distinct tool names for the variations.
///
/// **What this is.** A schema-side translator: ~20 well-described
/// polymorphic tools that map (tool_name, args) → underlying fact-key
/// strings, then forward to `FactResolverRegistry.resolveAsync(_:)`
/// (the suspending twin of `resolve(_:)` — see FactCatalog.swift). The
/// model sees a tighter, easier-to-reason-about surface over the same
/// catalog and resolvers.
///
/// **Tool budget.**
///   • 24 read tools (cover all `.fixed` + `.parameterized` + `.composite`;
///     `find_data` searches the whole catalog for what the typed tools
///     don't name, `lookup_fact` reads what it finds,
///     `get_stored_record` returns any session as the app saved it, and
///     `analyze_data` computes averages, extremes, trends and comparisons
///     in the app instead of in the model's text)
///   • up to 20 action tools (`allowedActionNames`, preserved verbatim —
///     write operations stay visible because their identity matters:
///     `assistant_email_compose` vs `assistant_contacts_add` are
///     different audit-trail events).
///
/// Total: 44 at most, well inside every provider's tool cap.
@MainActor
struct CompactToolRouter {
    let registry: FactResolverRegistry

    // MARK: - Schema

    /// The compact tool list returned to providers in place of
    /// `FactResolverRegistry.toolSchema()`, sorted by name so the schema
    /// bytes stay the same from send to send (cloud prompt caches key on
    /// them). The order says nothing about relevance: Apple Intelligence,
    /// which can hold only a few tools, re-ranks it per question
    /// (`ToolRetriever.ranked(for:tools:)`).
    static func schema(registry: FactResolverRegistry) -> [ToolSpec] {
        let specs = readTools() + actionTools(registry: registry)
        return deduped(specs).sorted { $0.name < $1.name }
    }

    /// Defensive dedupe. Anthropic returns
    /// HTTP 400 ("tools: Tool names must be unique") if any
    /// two ToolSpecs share a name, and the turn then falls back
    /// to another provider, so the user appears stuck on the
    /// fallback even with Grok / Anthropic selected.
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

    // MARK: - Dispatch

    /// Resolve a compact tool call. For action tools we forward to the
    /// underlying registry verbatim (they keep their original names for
    /// audit-trail clarity). For read tools we translate args → fact-key.
    /// `async`: the registry's tool path suspends on the
    /// handful of `.awaitable` resolvers (network / HealthKit / geo)
    /// instead of parking the main thread behind semaphores. Both
    /// production callers (AssistantViewModel's tool loop and
    /// AppleToolDispatcher) are async.
    ///
    /// Read-tool results pass through the registry's rate limiter and 80 KB
    /// size cap and are logged when slow (`gatedReadResult`), the same gates
    /// the registry applies to its own tool path; neither path discards a
    /// slow result.
    ///
    /// Only the tools this router advertises run: an action outside
    /// `allowedActionNames`, or a per-entry tool name, is refused even if a
    /// provider emits it, so the schema's allow-list is also the dispatch
    /// allow-list.
    func resolveTool(name: String, argsJSON rawArgs: String) async -> FactValue {
        let argsJSON = Self.normalizedArgs(rawArgs, tool: name)
        // 1. Try the read-tool router first.
        let startedAt = Date()
        if let raw = await resolveReadTool(name: name, argsJSON: argsJSON) {
            let elapsed = Date().timeIntervalSince(startedAt)
            let args = FactResolverRegistry.stringArgs(fromJSON: argsJSON)
            let projected = Self.projectedTools.contains(name) ? FactProjection.keep(fields: FactProjection.fieldNames(from: args["fields"]), in: raw) : raw
            let value = PaceDisplay.annotate(projected, field: args["field"])
            return registry.gatedReadResult(toolName: name, argsJSON: argsJSON, value: value, elapsed: elapsed)
        }
        // 2. Allowed action tools flow through the registry.
        guard Self.allowedActionNames.contains(name) else {
            return .missing(reason: .invalidParameter, detail: "unknown tool '\(name)'")
        }
        return await registry.resolveTool(name: name, argsJSON: argsJSON)
    }

    /// Arguments as a JSON object. Apple's on-device model sometimes sends a
    /// read tool's main value bare (`segment_lookback_at_current_position`
    /// instead of `{"field":"segment_lookback_at_current_position"}`); read
    /// as nothing, the tool would answer its default instead of the question.
    /// A bare value becomes the tool's main option; anything else passes
    /// through unchanged.
    static func normalizedArgs(_ raw: String, tool: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("{"), let key = bareValueOption[tool] else { return raw }
        let value = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        do {
            let data = try JSONSerialization.data(withJSONObject: [key: value])
            return String(data: data, encoding: .utf8) ?? raw
        } catch {
            // A one-string object always encodes; if it ever doesn't, the
            // model's text goes through as it came.
            return raw
        }
    }

    /// The read tools that take `fields`: their records are cut to those
    /// fields before the size cap is checked, so a long period fits.
    static let projectedTools: Set<String> = ["get_hrv", "get_sleep", "get_vitals", "get_recovery", "list_workouts", "get_session", "get_stored_record"]

    /// The `fields` option's description, the same on every tool that takes it.
    private static let fieldsOption = (
        "fields",
        "Optional comma-separated field names to return per item (e.g. 'date,rmssd_ms'), keeps long periods small; date, session_type and id always stay"
    )

    /// The option a bare value fills, per read tool.
    static let bareValueOption: [String: String] = [
        "get_session": "which", "get_recovery": "which", "get_hrv": "which", "get_sleep": "which",
        "get_vitals": "date", "get_workout": "which", "list_workouts": "which", "get_walks": "which",
        "get_baseline": "metric", "get_user": "field", "get_app_state": "aspect", "get_training_load": "which",
        "get_score_meta": "field", "get_breadcrumbs": "field", "get_routes": "field", "get_tags": "which",
        "get_workout_live": "field", "get_assistant_state": "field", "get_healthkit": "field",
        "lookup_fact": "key", "find_data": "query", "get_stored_record": "date", "analyze_data": "metric"
    ]

    // MARK: - Capability index (progressive-disclosure "menu")

    /// A generated, always-current index of the DATA the assistant can
    /// retrieve — one line per typed read tool, name + its one-sentence
    /// purpose. Injected into the (cached) system prompt so the model is TOLD
    /// what's reachable instead of guessing or denying it. Generated from
    /// `readTools()`, so it can NEVER drift from the real schema the way the
    /// hand-written capability docs do. This is the progressive-disclosure
    /// index layer (Anthropic "effective context engineering"): a small,
    /// always-present table of contents up front; the tools themselves are the
    /// just-in-time fetch. Byte-stable across sends → safe in the cached prefix.
    static func capabilityIndex() -> String {
        let lines = readTools().map { spec -> String in
            let purpose = spec.description.range(of: ". ").map { String(spec.description[..<$0.lowerBound]) } ?? spec.description
            let capped = purpose.count > 170 ? String(purpose.prefix(170)) + "…" : purpose
            return "- \(spec.name): \(capped)"
        }
        return capabilityIndexHeader + "\n\n" + lines.joined(separator: "\n")
    }

    /// The instructions above the tool list in `capabilityIndex()`.
    private static let capabilityIndexHeader = """
        # What you can retrieve (data tools)
        These tools fetch the user's OWN data from the app. For ANY question about \
        the user's recovery, HRV, sleep, vitals, training load, trajectory, workouts, \
        routes, tags, or trends, CALL the matching tool BEFORE answering. Never claim \
        you don't have the data without calling the tool first — the app has it, and \
        today's headline figures are already in the live-state block below. The app \
        holds far more than these tools name (heat acclimation, heart-rate recovery \
        trends, streaks, live coaching metrics, navigation steps and more): when no \
        tool below obviously fits, call find_data with a few words before you say \
        the app can't do something. Every pace comes with a `…pace_display` field \
        already in the user's units ("9:07 /mi"): say that one, never convert \
        `…pace_sec_per_km` yourself.
        """

    // MARK: - Read tool catalog

    // Tool-schema catalogue — one `spec(...)` row per tool.
    // Same shape as `WorkoutTriggerEngine.defaultRules`: data, not control flow.
    //
    // Sliced into `readTools1…N` purely for length. The catalogue is one flat
    // list to the model and the numbering runs 1–24 straight through the
    // slices, so a row keeps its number wherever the slice boundary lands.
    static func readTools() -> [ToolSpec] {
        readTools1() + readTools1b() + readTools2() + readTools2b() + readTools3() + readTools3a() + readTools3b() + readTools4() + readTools4b()
            + readTools5() + readTools5b() + readTools6() + readTools6b() + readTools7() + readTools8() + readTools9() + readTools10() + readTools11()
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
            spec("get_session", getSessionDescription, [
                ("which", "'latest', 'by_date', 'by_id', 'by_ordinal', or 'recent'"),
                ("date", "YYYY-MM-DD, the day the overnight's midpoint falls in (required when which='by_date')"),
                ("id", "Overnight session UUID (required when which='by_id')"),
                ("n", "Ordinal index, 0 = the newest overnight (required when which='by_ordinal')"),
                ("period", "For which='recent': 30d / last_month / all_time / 2026 (a year) / 2026-02 (a month) / 2026-02-20 (a day) / 2026-02-01..2026-02-28 / since_2026-02-01"),
                fieldsOption
            ])
        ]
    }

    private static let getSessionDescription = """
        Look up one recorded overnight session as a single record: identity and timing, plus that session's HRV analysis, recovery score, sleep and vitals records. Overnight sessions only — workouts are get_workout; naps and quick \
        readings come through get_hrv. `which`: 'latest' (default; the newest reliable overnight), 'by_date', 'by_id', 'by_ordinal', or 'recent'. For 'by_date' pass `date` as YYYY-MM-DD, the local day the overnight's midpoint \
        falls in (the same day get_hrv and get_sleep file it under); for 'by_id' pass `id` (an overnight session's UUID); for 'by_ordinal' pass `n` as integer where 0 = the newest overnight. \
        Any date back to the first recording works; to compare two nights ('tonight vs February 20'), call 'by_date' once per date. 'recent' with `period` lists every overnight in the period, partial nights included.
        """

    private static func readTools1b() -> [ToolSpec] {
        [
            // 3. get_recovery
            spec("get_recovery", """
                Recovery score lookup. `which`: 'latest' (default), 'by_date', 'recent', 'week_summary', 'trend', 'breakdown'. Use 'trend' for 'am I improving over time?' — it returns the improving/stable/declining verdict + HRV & resting-HR slopes \
                from the archive (no strap/reading needed). 'breakdown' (with `date`) is what made up that day's score: 'why was my score low on Feb 20'. \
                For 'by_date' pass `date` as YYYY-MM-DD; for 'recent' and 'trend' pass `period` (7d / 14d / 30d / 60d / 90d / 180d / 365d / today / yesterday / last_week / this_week / last_month / last_quarter / last_year / \
                all_time).
                """, [
                ("which", "'latest', 'by_date', 'recent', 'week_summary', 'trend', or 'breakdown'"),
                ("date", "YYYY-MM-DD"),
                ("period", "7d / 14d / 30d / 60d / 90d / 180d / 365d / today / yesterday / last_week / this_week / last_month / last_quarter / last_year / all_time / 2026 (a year) / 2026-02 (a month) / 2026-02-20 (a day) / 2026-02-01..2026-02-28 (a range) / since_2026-02-01"),
                fieldsOption
            ])
        ]
    }

    private static func readTools2() -> [ToolSpec] {
        [
            // 4. get_hrv
            spec("get_hrv", """
                HRV and overnight heart rate (RMSSD, nadir, lowest, mean and max heart rate per night) lookup. `which`: 'latest' (default), 'by_date', 'recent', 'live_snapshot', 'window'. For 'by_date' pass `date`; \
                for 'recent' pass `period`: it returns one record per night, so 'my lowest heart rate this week' or 'my nadir every night' is one call. \
                'live_snapshot' returns the live recording state: phase, whether beats are still arriving, beat count, elapsed time and the last error ('is it still recording', 'did the strap drop'). 'window' \
                returns the analysis-window classification (organized recovery, consolidated, etc.). 'timeline' (with `date`) is that night's heart rate and HRV through the night: 'my heart rate at 3am', \
                'how did my heart rate go through the night'. 'readings' (with `date`) is every reading of that day, overnight, naps and quick readings: 'every reading that day'.
                """, [
                ("which", "'latest', 'by_date', 'recent', 'live_snapshot', 'window', 'timeline', or 'readings'"),
                ("date", "YYYY-MM-DD"),
                ("period", "7d / 14d / 30d / 90d / 180d / 365d / last_week / last_month / last_year / all_time / 2026 (a year) / 2026-02 (a month) / 2026-02-20 (a day) / 2026-02-01..2026-02-28 (a range) / since_2026-02-01"),
                fieldsOption
            ])
        ]
    }

    private static func readTools2b() -> [ToolSpec] {
        [
            // 5. get_sleep
            spec("get_sleep", "Sleep lookup (total, deep, REM, awake, efficiency, cycles). `which`: 'latest' (default), 'by_date', 'recent'. For 'by_date' pass `date`; for 'recent' pass `period` for one record per night.", [
                ("which", "'latest', 'by_date', or 'recent'"),
                ("date", "YYYY-MM-DD"),
                ("period", "7d / 14d / 30d / 90d / 180d / 365d / last_week / last_month / last_year / all_time / 2026 (a year) / 2026-02 (a month) / 2026-02-20 (a day) / 2026-02-01..2026-02-28 (a range) / since_2026-02-01"),
                fieldsOption
            ]),
            // 6. get_vitals
            spec("get_vitals", """
                Overnight vitals (resting HR, respiratory rate, wrist temperature, SpO2). Pass `date` as YYYY-MM-DD for one night, or `period` for one record per night (resting heart rate this week); \
                neither gives the latest night.
                """, [
                ("date", "YYYY-MM-DD"),
                ("period", "7d / 14d / 30d / 90d / 180d / 365d / last_week / last_month / last_year / all_time / 2026 (a year) / 2026-02 (a month) / 2026-02-20 (a day) / 2026-02-01..2026-02-28 (a range) / since_2026-02-01"),
                fieldsOption
            ])
        ]
    }

    private static func readTools3() -> [ToolSpec] {
        [
            // 7. get_workout
            spec("get_workout", getWorkoutDescription, [
                ("which", "Variant — see description for full list"),
                ("date", "YYYY-MM-DD: the day of the workout, or for 'segment_compare' the one day to search"),
                ("sport", "Optional sport of the workout that day: run, trail_run, walk, hike, bike, indoor_bike, treadmill, row, air_bike, crossfit"),
                ("position", "Optional which workout that day in start order, 1 = the first (with `date`)"),
                ("id", "Workout UUID (for which='by_id', or in place of `date` on any single-workout variant)"),
                ("n", "Ordinal, 0 = most recent (for which='by_ordinal')"),
                ("point", "'lat,lon' or 'lat,lon,radius_m' (for which='segment_compare')"),
                ("period", "For 'segment_compare': how far back to search: last_year / 2026 (a year) / 2026-02 (a month) / 2026-02-20 (a day) / 2026-02-01..2026-02-28 (a range) / since_2026-02-01 / all_time")
            ], required: ["which"])
        ]
    }

    private static let getWorkoutDescription = """
        One recorded workout. `which` selects what to return. Records: 'by_date', 'by_id', 'by_ordinal', 'deep_dive' (every analysis figure in one record). Single values: 'feeling', 'feeling_note', 'hrr_1min', 'hrr_2min', \
        'power_avg', 'power_peak', 'power_normalized', 'power_tss', 'power_intensity', 'power_variability'. Every variant except 'by_ordinal' and 'segment_compare' picks its workout the same way: `date` (YYYY-MM-DD, any day back to \
        the first recording) reads the latest workout started that day; add `sport` for 'my run on March 3' when the day also had a walk, and `position` for 'the second workout that day' (1 = the first started). Or pass `id`, a \
        workout UUID, for one exact workout. Each record says workouts_that_day, position_that_day and other_workout_ids_that_day, so when a day had several you can read the others by id. 'by_ordinal' takes `n` (0 = the newest). \
        **Per-second analysis primitive: 'timeline'** returns a downsampled (~200 buckets) time-series of HR, pace, cadence, altitude, grade, α1, power per bucket. Use 'timeline' for ANY question that needs the time-series shape: 'did my HR \
        spike when I was flat / going downhill', 'where did pace drop on the climb', 'was α1 still healthy late in the workout', 'where did cadence collapse', 'did power drop while HR held'. \
        **'segment_compare'** takes `point`: each GPS workout that passed a place, with the user's pace, HR, power, cadence and altitude at that exact spot ('how did I do on that hill compared to before', 'compare this run with \
        the one on February 20'). Without a bound it reads the 30 most recent GPS workouts; pass `date` for one day's workouts or `period` to search further back. `point` is 'lat,lon' or 'lat,lon,radius_m' (default 50 m); \
        take it from a location tool, or for a hill on a past workout from that workout's 'timeline' (each bucket carries `lat`/`lon`: pick the climb by grade_pct). During a workout, get_workout_live field='segment_lookback_at_current_position' \
        does this for where the user is now. To compare two workouts, call once per workout.
        """

    private static func readTools3a() -> [ToolSpec] {
        [
            // 8. list_workouts
            spec("list_workouts", """
                PRIMARY tool for ANY workout history question — runs, walks, hikes, bikes, rows, all sports. Use this whenever the user asks 'what workouts did I do', 'show me this week's training', 'how many runs', 'what's my recent activity'. `which`: \
                'list' (default — full workout records, each with its id and workouts_that_day), 'count', 'recent' (period summary). Pass `period` like '7d', '30d', 'this_week', 'last_week', '2026-02'; add `sport` to keep one sport \
                ('how many runs last month', 'my rides this year'). A day with several workouts lists each one; read any of them later with get_workout id. **Do NOT use get_walks for general workout questions** — that tool is walk-only and will \
                return empty if the user did runs/rides/hikes.
                """, [
                ("which", "'list', 'count', or 'recent'"),
                ("sport", "Optional: keep only this sport (run, trail_run, walk, hike, bike, indoor_bike, treadmill, row, air_bike, crossfit)"),
                ("period", "7d / 14d / 30d / 60d / 90d / 180d / 365d / today / yesterday / last_week / this_week / last_month / last_quarter / last_year / all_time / 2026 (a year) / 2026-02 (a month) / 2026-02-20 (a day) / 2026-02-01..2026-02-28 (a range) / since_2026-02-01"),
                fieldsOption
            ], required: ["period"])
        ]
    }

    private static func readTools3b() -> [ToolSpec] {
        [
            // 9. get_walks
            spec("get_walks", "Walk-only aggregates (separate from runs/rides). `which`: 'summary' (count, distance, load and the hardest walk in one record), 'count', 'list', 'total_distance_m', 'total_trimp', 'hardest'. Pass `period` like '7d', '30d'.", [
                ("which", "'summary', 'count', 'list', 'total_distance_m', 'total_trimp', or 'hardest'"),
                ("period", "7d / 14d / 30d / 90d / 180d / 365d / last_week / last_month / last_year / all_time / 2026 (a year) / 2026-02 (a month) / 2026-02-20 (a day) / 2026-02-01..2026-02-28 (a range) / since_2026-02-01")
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
                'weight_kg', 'biological_sex', 'age', 'cycling_ftp', 'running_ftp', 'vo2_max'.
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
                'healthkit' (availability), 'capabilities' (barometer presence), 'version' (schema versions).
                """, [
                ("aspect", "'now', 'devices', 'settings', 'healthkit', 'capabilities', or 'version'")
            ], required: ["aspect"])
        ]
    }

    private static func readTools5() -> [ToolSpec] {
        [
            // 13. get_training_load
            spec("get_training_load", """
                Training load + trajectory (ATL/CTL/TSB/TRIMP/ACWR). `which`: 'snapshot' (current values), 'trajectory' (the Load & Trajectory verdict: building/detraining/high-strain, ramp band + rate, form descriptor, monotony/strain), 'by_date', \
                'recent', 'this_week', 'last_4_weeks', 'by_sport', 'recovery_hours_needed', 'days_until_fresh', 'days_until_atl_converges', 'projected_tsb', 'race_predictions', 'sport_baseline', 'pace_zones'. Pass `date`, `period`, `sport`, `daily_trimp`, \
                or `params` as needed. Coaching history: 'heat_acclimation' (how adapted the user is to training in heat, and what to do about it), 'workout_streak' (consecutive days with a workout), \
                'workouts_this_week', 'hrr_trend_1min' / 'hrr_trend_2min' (average heart-rate recovery after workouts over `period`; rising = fitter).
                """, [
                ("which", "Variant — see description"),
                ("date", "YYYY-MM-DD"),
                ("period", "7d / 14d / 30d / 90d / 180d / 365d / last_week / last_month / last_year / all_time / 2026 (a year) / 2026-02 (a month) / 2026-02-20 (a day) / 2026-02-01..2026-02-28 (a range) / since_2026-02-01"),
                ("sport", "Sport identifier (run, bike, walk, etc.)"),
                ("daily_trimp", "Daily training load on the TSS scale ATL/CTL use (number as string)"),
                ("params", "Comma-separated parameter blob for advanced queries")
            ], required: ["which"])
        ]
    }

    private static func readTools5b() -> [ToolSpec] {
        [
            // 14. get_score_meta
            spec("get_score_meta", "Recovery-score algorithm metadata. `field`: 'algorithm_version' (current scoring version, e.g. '\(ScoringVersion.current)') or 'history_recomputed' (whether the user has run the v1→v2 history recompute).", [
                ("field", "'algorithm_version' or 'history_recomputed'")
            ], required: ["field"]),
            // 15. get_breadcrumbs
            spec("get_breadcrumbs", "GPS breadcrumb trail state. `field`: 'active', 'count', 'current_fix', 'derived_grade_percent', 'recent', 'recent_track', 'list(<period>)' (the trails in a period), 'by_date(<yyyy-MM-dd>)' (one day's trail).", [
                ("field", "Specific field — see description")
            ], required: ["field"])
        ]
    }

    private static func readTools6() -> [ToolSpec] {
        [
            // 16. get_routes
            spec("get_routes", """
                Saved routes and the route being followed now (read-only). `field`: 'count', 'list', or 'next_step' (the next turn of the engaged route and how far away it is: \
                'what's next', 'how far now', 'am I there yet'). To rename, save or follow a route, use the dedicated action tools.
                """, [
                ("field", "'count', 'list', or 'next_step'")
            ], required: ["field"]),
            // 17. get_tags
            spec("get_tags", """
                Tag-correlation lookups. `which`: 'correlation' (correlation between a tag and recovery score), 'count' (sessions with this tag in `period`, or across the whole archive when no period is given), 'list_active' (tags on a specific \
                date), 'recent_tagged' (recent sessions matching a tag), 'list' (every tag used in `period`), 'tagged_in_period' (the sessions with `tag` in `period`). Pass \
                `tag` and/or `date`/`period` as needed.
                """, [
                ("which", "'correlation', 'count', 'list_active', 'recent_tagged', 'list', or 'tagged_in_period'"),
                ("tag", "Tag name"),
                ("date", "YYYY-MM-DD"),
                ("period", "7d / 14d / 30d / 90d / 180d / 365d / last_week / last_month / last_year / all_time / 2026 (a year) / 2026-02 (a month) / 2026-02-20 (a day) / 2026-02-01..2026-02-28 (a range) / since_2026-02-01")
            ], required: ["which"])
        ]
    }

    private static func readTools6b() -> [ToolSpec] {
        [
            // 18. get_workout_live
            spec("get_workout_live", """
                Live workout state, and how the user did at this exact spot in past workouts (only meaningful while a workout is recording). \
                `field`: 'snapshot' (default — full bundle), or specific fields like 'hr', 'pace_sec_per_km', 'speed_m_per_s', 'power_watts', 'sport', 'location', 'weather', 'today_readiness', \
                'thresholds.active', 'thresholds.any_breaching', 'thresholds.breach_state', 'interval.active', 'interval.current_step', 'interval.next_step', 'route_topology', 'recognized_route', 'hr_drift_percent', \
                'reverse_split_delta_sec_per_km', 'hrr_capture_status', 'units_preference', 'training_pace_zones', 'route_history_baseline', 'segment_lookback_at_current_position', \
                'alpha1', 'alpha1_band', 'alpha1_status', 'elapsed_sec', 'distance_meters', 'cadence_spm', 'elevation_gain_meters', 'historical_baseline' (the user's usual pace and HR for this sport), \
                'location.locality', 'location.compact_address'. **Coaching metrics:** 'grade_adjusted_pace_sec_per_km' (pace corrected for the hill, for 'am I really slower or is it the climb'), \
                'aerobic_decoupling_percent' (heart rate rising at the same pace: past ~5% the aerobic engine is tiring), 'cadence_drift_spm' (stride shortening with fatigue). \
                **Same spot, earlier workouts: 'segment_lookback_at_current_position'** — the user's pace, HR, power, cadence and altitude at the exact spot they are on now, \
                from each of their recent GPS workouts that passed within 50 m. Use it for 'how am I doing on this hill vs last time', 'was I faster here before', \
                'what was my heart rate at this corner last week'. Answer with the numbers; never say you can't compare a spot.
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
            ], required: ["field"])
        ]
    }

    private static func readTools8() -> [ToolSpec] {
        [
            // 20. get_healthkit
            spec("get_healthkit", """
                Apple Health reads that work outside a workout. `field`: 'heart_rate_latest' (most recent heart-rate sample in the last 24 hours, any source) or \
                'today_activity' (today's steps, walking/running distance and flights climbed so far).
                """, [
                ("field", "'heart_rate_latest' or 'today_activity'")
            ], required: ["field"]),
            // 21. lookup_fact (universal fallback)
            spec("lookup_fact", """
                Long-tail fact lookup by raw fact-catalog key. Use this only when no other tool fits — most needs are covered by the typed tools above. find_data finds the key for anything else. Example keys: 'recovery.today.full', \
                'session.latest.id', 'training.load.acwr'. Pass `key` as the dotted path. Parameterised keys take their parameter inline like 'session.by_date(2026-04-21)'. The app manual is here too: \
                'app.help.lookup(<topic>)' returns one section (topics are listed in the app reference).
                """, [
                ("key", "Dotted fact-catalog key")
            ], required: ["key"])
        ]
    }

    private static func readTools9() -> [ToolSpec] {
        [
            // 22. find_data (catalog search)
            spec("find_data", """
                Search everything the app can tell you or do, by plain words. Use it whenever no other tool obviously fits, before you ever say the app can't answer or can't do something: 'heat acclimation', \
                'heart rate recovery trend', 'workout streak', 'next turn', 'roads ahead', 'grade adjusted pace', 'is it still recording'. Returns up to 8 matches, each with what it is and how to get it: a `lookup_fact` key \
                (replace the example argument with the one you need) or the name of the tool to call.
                """, [
                ("query", "A few words for what you're looking for")
            ], required: ["query"])
        ]
    }

    private static func readTools10() -> [ToolSpec] {
        [
            // 23. get_stored_record (every stored field)
            spec("get_stored_record", getStoredRecordDescription, [
                ("kind", "Optional: overnight, nap, quick, breathe or workout (with `date` or `period`)"),
                ("date", "YYYY-MM-DD: every session filed under that day"),
                ("id", "A session UUID from any other tool: that one session"),
                ("period", "7d / 30d / last_month / all_time / 2026 (a year) / 2026-02 (a month) / 2026-02-01..2026-02-28 / since_2026-02-01: every session in it, newest first"),
                ("fields", "Optional comma-separated stored keys to keep per session (e.g. 'startDate,deviceProvenance'); date, session_type and id always stay")
            ])
        ]
    }

    private static let getStoredRecordDescription = """
        The full stored record of any session, exactly as the app saved it: every field, under its stored key, for overnights, naps, quick readings and workouts. Use it when no other tool has the field you need, \
        or to check a value another tool gave. Pass `id` for one session, `date` for every session that day, or `period` for every session in it; `kind` keeps one kind. Scales are as stored: recoveryScore is 0-10 \
        (the app shows it as 0-100), morningFeeling and workoutFeeling 1-5, fields ending in Ms are milliseconds from startDate, dates are in the user's time zone. Raw beats, per-second samples and the GPS track \
        are left out (get_hrv and get_workout 'timeline' have them).
        """

    private static func readTools11() -> [ToolSpec] {
        [
            // 24. analyze_data (arithmetic the app computes)
            spec("analyze_data", analyzeDataDescription, [
                ("metric", "A numeric field name from the records, e.g. rmssd_ms, overnight_nadir_hr_bpm, overnight_min_hr_bpm, total_sleep_minutes, deep_minutes, resting_heart_rate_bpm, score, distance_m, avg_pace_sec_per_km, load"),
                ("op", "'summary' (default), 'trend', 'compare_dates' or 'compare_periods'"),
                ("period", "For summary and trend (default last_30d): 7d / 30d / 90d / this_week / last_month / all_time / 2026 (a year) / 2026-02 (a month) / 2026-02-01..2026-02-28 / since_2026-02-01"),
                ("date_a", "For compare_dates: YYYY-MM-DD, or today / yesterday"),
                ("date_b", "For compare_dates: YYYY-MM-DD, or today / yesterday"),
                ("period_a", "For compare_periods: the first period, same forms as period"),
                ("period_b", "For compare_periods: the second period, same forms as period"),
                ("sport", "Optional, workout metrics only: run, trail_run, walk, hike, bike, indoor_bike, treadmill, row, air_bike, crossfit")
            ], required: ["metric"])
        ]
    }

    private static let analyzeDataDescription = """
        Averages, lowest/highest with dates, trends, compare two days or two periods, computed by the app: use this instead of computing yourself from listed records. `metric` is a field name from the \
        get_hrv, get_sleep, get_vitals, get_recovery or list_workouts records (overnight metrics give one value per day, the reading the by-date lookups pick; workout metrics one value per workout, `sport` keeps one sport). \
        `op`: 'summary' over `period` returns n, mean, median, min, min_date, max, max_date, sum, stdev, first_date, last_date; 'trend' over `period` returns n, mean, slope_per_day, slope_per_week \
        (least squares), first_date, first_value, last_date, last_value, change; 'compare_dates' with `date_a` and `date_b` ('tonight vs February 20') returns date_a, value_a, date_b, value_b, session_type_a / \
        session_type_b (only for a nap or quick reading), source_lookup_a, source_lookup_b, difference (b minus a), percent_change; 'compare_periods' with `period_a` and `period_b` ('this month vs last February') \
        returns period_a and period_b (each: period, n, mean, min, min_date, max, max_date, first_date, last_date, source_lookup) plus difference (mean b minus mean a) and percent_change. Every answer also has \
        metric, op, unit, sport, period and source_lookup (the lookup the values came from), values (date and value pairs, with session_type for a nap or quick reading, up to 31), dates_without_value (days \
        with a recording but no value) and dates_without_recording (days of a short period with no overnight). A pace metric adds a *_pace_display beside each pace figure in the user's units: say that one. \
        Quote these numbers as given; a missing figure says why.
        """

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
    /// `assistant_artifacts_*` is the long-term bug / feature / decision
    /// list the conversation summary tells the model to track items in.
    static let allowedActionNames: Set<String> = [
        "assistant_artifacts_add",
        "assistant_artifacts_update_status",
        "routes_library_rename",
        "routes_library_save_workout",
        "routes_library_engage",
        "assistant_contacts_add",
        "assistant_contacts_remove",
        "assistant_email_compose",
        "assistant_memory_add",
        "assistant_memory_remove",
        "assistant_memory_clear",
        "assistant_memory_restore",
        "web_search",
        "location_current",
        "location_current_detailed",
        "location_situation",
        "location_roads_ahead",
        "location_set_address",
        "directions_routeTo",
        "directions_clear"
    ]

    // MARK: - Read-tool dispatch

    /// Tool name → resolver, for every read tool whose whole implementation
    /// is "hand the parsed args to a resolver of the same shape".
    ///
    /// These nineteen share one
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
            "get_assistant_state": resolveAssistantState(args:),
            "get_stored_record": resolveStoredRecord(args:), "analyze_data": resolveAnalyzeData(args:)
        ]
    }

    /// Returns nil if the tool isn't a compact read tool. Returns a
    /// FactValue otherwise (which may itself be `.missing` for bad args).
    private func resolveReadTool(name: String, argsJSON: String) async -> FactValue? {
        let args = FactResolverRegistry.stringArgs(fromJSON: argsJSON)
        if let resolver = uniformReadResolvers[name] {
            return await resolver(args)
        }
        switch name {
        case "get_today":
            return await registry.resolveAsync("recovery.today.full")
        case "get_vitals":
            return await resolveVitals(args: args)
        case "get_healthkit":
            return await resolveHealthKitTool(field: args["field"] ?? "")
        case "lookup_fact":
            guard let key = args["key"] else { return .missing(reason: .invalidParameter, detail: "lookup_fact requires 'key'") }
            return await registry.resolveAsync(key)
        case "find_data":
            return resolveFindData(query: args["query"] ?? "")
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
