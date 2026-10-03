import Foundation

// The shared system prompt: about 1,240 lines of prose sent verbatim to every
// provider, covering the medical boundary, the tone rules and the tool-use
// contract. It has its own file so a prompt change is reviewable on its own;
// the exact bytes are the contract with the model.

// MARK: - Shared system prompt

enum AssistantSystemPrompt {
    /// Composed pair of stable + variable prompt sections. Anthropic's
    /// prompt cache only matches byte-for-byte prefixes, so anything
    /// per-send (clock snapshot, today's data) MUST live in the variable
    /// half — otherwise every send is a cache miss. See `composeSplit`.
    struct Composed {
        /// Stable across many turns (persona, app reference, units,
        /// user facts). Sent first, marked with cache_control=ephemeral.
        let stable: String
        /// Per-send (current time, prior-conversation summary, rendered
        /// data context). Sent after `stable`, no cache control.
        let variable: String

        /// Single-string fallback for providers (Apple, OpenAI) whose
        /// SDKs don't expose multi-block system prompts.
        var combined: String {
            variable.isEmpty ? stable : "\(stable)\n\n\(variable)"
        }

        /// Combined string with a marker between the cached and
        /// uncached halves. Anthropic provider splits on this marker
        /// to build two cache-aware system blocks; other providers
        /// strip it and send the whole thing as one prompt.
        var combinedWithMarker: String {
            variable.isEmpty ? stable : "\(stable)\(Self.cacheSplitMarker)\(variable)"
        }

        /// Sentinel that delimits the stable / variable halves inside
        /// the combined system prompt. Chosen to be visually obvious
        /// in any leaked prompt + unlikely to collide with real text.
        static let cacheSplitMarker = "\n\n<<<__FLOW_CACHE_SPLIT__>>>\n\n"
    }

    /// Stored asserted values used by `composeSplit` to inject the
    /// override block. Set by the caller (AssistantViewModel) just
    /// before compose; cleared after. Static because compose is a
    /// static func and can't accept a new parameter without a
    /// cascading API change across every call site.
    @MainActor
    static var pendingUserAssertedValues: UserAssertedValuesParser.AssertedValues = [:]

    /// Recent user messages (last ~6 from the conversation) used by
    /// `UserCorrectionDetector` to identify correction signals
    /// — value assertions, dashboard-contradiction phrases,
    /// explicit override requests. The composer reads this to decide
    /// whether to suppress the dashboard cache block this turn. Set
    /// by the dispatch caller; cleared after each compose.
    @MainActor
    static var pendingRecentUserMessages: [String] = []

    /// Backwards-compatible single-string composer. Returns the
    /// combined string with the cache-split marker baked in — the
    /// marker is invisible to providers that don't recognise it
    /// (they strip it before sending). Anthropic splits on it to
    /// build cache-aware system blocks.
    ///
    /// Marked `@MainActor`. Reads MainActor-isolated
    /// state (AppDependencies.current.app.settingsManager, dashboard snapshot, active
    /// workout marker) via direct sync access. Guarding those reads
    /// with `MainActor.assumeIsolated` instead would trap the process
    /// if any caller invoked compose from a detached / background
    /// task. All current callers are
    /// @MainActor; this annotation makes the assumption a compiler-
    /// enforced contract so a future off-main caller fails to build
    /// rather than crashing in production.
    @MainActor
    static func compose(
        userFacts: String,
        priorSummary: String?,
        contextRendered: String,
        includeAppReference: Bool = true,
        compactAppReference: Bool = false,
        voiceMode: Bool = false,
        toolMode: Bool = false
    ) -> String {
        composeSplit(
            userFacts: userFacts,
            priorSummary: priorSummary,
            contextRendered: contextRendered,
            includeAppReference: includeAppReference,
            compactAppReference: compactAppReference,
            voiceMode: voiceMode,
            toolMode: toolMode
        ).combinedWithMarker
    }

    /// Two-section composer. Stable prefix is large + identical across
    /// turns within a 5-minute window so Anthropic's prompt cache hits
    /// it on every send (was 0% before this split — the per-second
    /// `nowSnapshot` immediately after `base` blew the cache prefix
    /// even though nothing else had changed).
    @MainActor
    static func composeSplit(
        userFacts: String,
        priorSummary: String?,
        contextRendered: String,
        includeAppReference: Bool = true,
        compactAppReference: Bool = false,
        voiceMode: Bool = false,
        toolMode: Bool = false
    ) -> Composed {
        let stable = stableSections(
            userFacts: userFacts,
            includeAppReference: includeAppReference,
            compactAppReference: compactAppReference,
            voiceMode: voiceMode,
            toolMode: toolMode
        )
        let variable = variableSections(priorSummary: priorSummary, contextRendered: contextRendered)
        return Composed(
            stable: stable.joined(separator: "\n\n"),
            variable: variable.joined(separator: "\n\n")
        )
    }

    /// Everything that is byte-stable across turns, in prompt order.
    @MainActor
    private static func stableSections(
        userFacts: String,
        includeAppReference: Bool,
        compactAppReference: Bool,
        voiceMode: Bool,
        toolMode: Bool
    ) -> [String] {
        var sections: [String] = [base]
        sections += localeAndFeatureSections(settings: AppDependencies.current.app.settingsManager.settings)
        sections += toolModeSections(toolMode: toolMode)
        // Voice overlay goes AFTER base so its "1–3 sentences, no headers,
        // no lists" rules override the persona's implicit leaning toward
        // thorough written answers. Only included on voice turns — typed
        // chat still gets full, structured responses.
        if voiceMode { sections.append(voiceOverlay) }
        // App-level reference (features, metrics, capabilities). Static across
        // users and sessions — goes EARLY so prompt caching can hit it on
        // every send without counting as per-request variable content. Compact
        // variant is offered for small-context providers (Apple on-device).
        if includeAppReference {
            sections.append(compactAppReference ? AppKnowledgeBase.referenceCompact : AppKnowledgeBase.reference)
        }
        if !userFacts.isEmpty {
            sections.append("# About this user (cross-session memory)\n" + userFacts)
        }
        return sections
    }

    /// **Language override** — when the user explicitly opted into
    /// English-only AI responses (Settings → AI), inject an
    /// unambiguous instruction. Without this the model mirrors the
    /// device locale (Locale.current) which means a Japanese-locale
    /// phone gets Japanese responses even from a bilingual user
    /// who'd prefer English. Static string so prompt caching is
    /// unaffected.
    ///
    /// **Locale + units directive** — make the user's unit system AND
    /// their location/locale unmissable. Without this the model
    /// defaults to its training-data prior (mostly metric, mostly
    /// global English) regardless of what the user has set. A US
    /// user with imperial units explicitly chosen was getting "your
    /// pace was 5:30 per kilometer" which is wrong on both counts.
    /// Static per device so prompt cache stays warm; only changes
    /// when the user toggles units or moves country (rare).
    ///
    /// **Disabled-feature surface** — tells the model which tabs /
    /// integrations the user has switched off, so it doesn't waste
    /// turns trying to fetch from areas the user has disabled or
    /// recommend features they've removed.
    @MainActor
    private static func localeAndFeatureSections(settings: UserSettings) -> [String] {
        var sections: [String] = []
        if settings.forceAIEnglish {
            sections.append("# Language\nRespond in English regardless of the language the user wrote in or the device locale. The user has explicitly opted into English-only AI responses.")
        }
        sections.append(localeAndUnitsDirective(settings: settings))
        let disabled = disabledFeaturesSummary(settings: settings)
        if !disabled.isEmpty { sections.append(disabled) }
        return sections
    }

    /// Tool-use overlay first — it redefines where data comes from (tools,
    /// not a text dump) which overrides the base's "use only numbers
    /// that appear in the structured data below" assumption. The generated
    /// capability index that follows is the always-present "menu" of what
    /// the model can retrieve, so it never guesses or denies data the app
    /// has. Byte-stable (generated from the static read-tool catalog) → stays
    /// in the cached prefix. See `CompactToolRouter.capabilityIndex()`.
    ///
    /// Non-tool-mode capability awareness. When Coach is running
    /// on Apple Intelligence (or any provider that doesn't accept tools
    /// today), the toolOverlay is omitted and the model has no idea email /
    /// contacts / directions / web search even exist. Combined with the base
    /// rule "If the app doesn't have a capability, say so ONCE", Apple Coach
    /// denies things the app actually does ("I don't have email"). User
    /// report: "It has limited awareness." The fallback block tells the
    /// model the app CAPABILITIES exist but THIS provider doesn't carry them,
    /// and how the user can flip the switch.
    @MainActor
    private static func toolModeSections(toolMode: Bool) -> [String] {
        toolMode ? [toolOverlay, CompactToolRouter.capabilityIndex()] : [nonToolModeOverlay]
    }

    /// Anything that changes turn-to-turn. Lives outside the cache prefix so
    /// the cache survives across calls even when these sections move.
    ///
    /// **Current time** was moved out of the stable prefix (it sat immediately
    /// after `base`) because it changes every second and was invalidating
    /// Anthropic's prompt cache on every send.
    ///
    /// When a workout is active, mark
    /// it explicitly. Without this, the first turn after the user
    /// opens the Coach mid-workout has no signal that a session is in
    /// flight: tool-mode strips `contextRendered`, so the model relies on
    /// tool calls to discover live state, but there's no system-prompt cue
    /// telling it a workout exists. Result: Coach answers "What's my heart
    /// rate?" with "I don't have that information" because nothing prompted
    /// it to call `get_workout_live`. The marker is intentionally minimal —
    /// just enough to make the workout's existence and the relevant tool
    /// name unmissable. HR / pace / GPS are NOT inlined (they change per
    /// second; inlining would blow the cache).
    ///
    /// Surface any unconsumed hallucination corrections
    /// from the previous turn. The voice-side guard records these
    /// when it catches a fabricated number; we inject ONE reminder
    /// into the next turn's variable (per-send) section, then the
    /// buffer clears. Without this, the model fabricates the same
    /// number on every subsequent turn because it never sees that
    /// it got it wrong (the user heard the corrected number, the
    /// model thinks its claim was accepted).
    @MainActor
    private static func variableSections(priorSummary: String?, contextRendered: String) -> [String] {
        var sections: [String] = [nowSnapshot()]
        sections += trainingLoadSections()
        if let liveMarker = activeWorkoutMarker() { sections.append(liveMarker) }
        if let corrections = MetricsVerifier.consumePendingCorrectionsBlock() {
            sections.append(corrections)
        }
        if let summary = priorSummary, !summary.isEmpty {
            sections.append("# Earlier in this conversation\n" + summary)
        }
        if !contextRendered.isEmpty {
            sections.append("# Current data\n" + contextRendered)
        }
        return sections
    }

    /// Inline the dashboard's current training-load
    /// numbers so the AI never has to call a tool to know the
    /// headline TSB / ATL / CTL / recovery score, and can never
    /// contradict the dashboard. Background:
    ///
    /// User asked "what's my current TSB" on Grok. Dashboard
    /// showed TSB −15.5 / ATL 44.2 / CTL 28.7. Grok answered
    /// "TSB negative twenty-nine, ATL 58, CTL 29, ACWR 2.0" —
    /// either because it called `workout.live.today_readiness`
    /// (frozen at workout-start, would be wrong direction) or
    /// because the live snapshot the resolver read was stale,
    /// or because the model misread one of the four tools that
    /// can return ATL/CTL/TSB and disagree.
    ///
    /// Putting the real values in the variable section means
    /// every send carries them in the `<live_state>` block (or
    /// for Apple, the compactRender) and the model reads them
    /// directly. No tool round trip, no source-of-truth ambiguity,
    /// no drift from the dashboard.
    ///
    /// Structural fix per STALE-benchmark research
    /// and Home Assistant precedent. The model can't reliably
    /// resolve "snapshot says X, user says Y" via prose meta-rules
    /// (55 % accuracy per STALE), so we resolve it structurally
    /// BEFORE the prompt reaches the model:
    ///   1. If the user has stated values OR explicitly contradicted
    ///      the cache OR asked us to stop using it — inject a
    ///      user-stated block ABOVE the dashboard cache.
    ///   2. If they contradicted the cache OR asked to override —
    ///      OMIT the dashboard cache entirely. No conflict for the
    ///      model to resolve.
    ///   3. Source attribution is a HARD RULE elsewhere in the
    ///      prompt: every number gets a "per the cache" / "you
    ///      told me" / "from <tool>" tag, so the user has a
    ///      handle to see where any disagreement is coming from.
    @MainActor
    private static func trainingLoadSections() -> [String] {
        let signals = UserCorrectionDetector.detect(userMessages: Self.pendingRecentUserMessages)
        var sections: [String] = []
        if let userBlock = UserCorrectionDetector.renderAssertedBlock(signals) {
            sections.append(userBlock)
        }
        let suppressCache = signals.dashboardContradicted || signals.explicitOverrideRequested
        if !suppressCache, let snap = dashboardLoadSnapshot() { sections.append(snap) }
        return sections
    }

    /// Build the locale + units directive. Always injected — the
    /// difference between a user with imperial units who's getting
    /// "5:30/km" and the same user getting "8:51/mile" is whether the
    /// model SAW this directive. Don't rely on the AI calling the
    /// `user.settings.units` fact — bake the directive in.
    ///
    /// Composed of:
    /// - Units (imperial vs metric) — drives distance / pace / elevation
    /// - Temperature unit (F vs C) — drives weather + thermal coaching
    /// - Country / region from `Locale.current` — drives turn directions
    ///   ("right" / "left"), road conventions ("4-lane highway"), and
    ///   altitude phrasing (feet for US/UK pilots, meters for
    ///   metric-trained athletes)
    @MainActor
    private static func localeAndUnitsDirective(settings: UserSettings) -> String {
        [
            unitsAndLocaleBlock(settings: settings),
            routeLoadingGuidance,
            locationToolGuidance,
            locationPhrasingGuidance
        ].joined(separator: "\n\n")
    }

    /// The units + region header itself. Interpolated per device.
    @MainActor
    private static func unitsAndLocaleBlock(settings: UserSettings) -> String {
        let imperial = UnitsPreferenceStore.current.resolved == .imperial
        let temperatureUnit = settings.temperatureUnit == .fahrenheit
            ? "Fahrenheit (°F, NOT Celsius)"
            : "Celsius (°C)"
        let region = Locale.current.region?.identifier ?? "unknown"
        let regionName = Locale.current.localizedString(forRegionCode: region) ?? region
        return """
        # Units & locale (ALWAYS use these — never default to metric/Celsius)
        - units_system: **\(imperial ? "imperial" : "metric")**
        - distance: speak in **\(imperial ? "miles (NOT kilometers)" : "kilometers")**
        - pace: speak in **\(imperial ? "minutes per mile (NOT per km)" : "minutes per kilometer")**
        - elevation: speak in **\(imperial ? "feet (NOT meters)" : "meters")**
        - temperature: speak in **\(temperatureUnit)**
        - user_region: \(regionName) (\(region))

        Convert any internal metric values (the data context uses meters / km / Celsius for storage consistency) to the user's units before reading them aloud or writing them. NEVER read raw metric numbers to a user whose units_system is "imperial". \
        Example: if the data shows distance_meters: 8047, you say "5.0 miles" — not "8 kilometers" or "8047 meters".
        """
    }

    /// How to load a route into `ActiveRouteSession`, and who narrates the turns.
    private static let routeLoadingGuidance = """
        # Loading a route + proactive turn alerts
        Two ways to engage a route into ActiveRouteSession:

        **A. NEW DESTINATION via `directions_routeTo`** — when the user says "take me home" / "navigate to <X>" / "lead me to the car" / "back to where I started" / "route me to the park" / any "get me to <somewhere>" phrasing. Apple's MapKit computes \
        a fresh walking route. Accepts an `origin` keyword (breadcrumb origin — typically "where I started this walk" or "my car"), a `poi` query ("parking lot", "hospital", "Trader Joe's"), or a free-text `address`.

        **B. SAVED ROUTE via `routes_library_engage`** — when the user names a route they've previously saved ("load my Saturday loop", "engage Daily 1", "follow my morning hill route"). Follows the user's EXACT recorded polyline, with turn detection \
        via bearing-change and road names from OSM. Returns a `direction` field (forward / reverse — auto-inferred from which end of the polyline the user is closer to) AND a `has_unnamed_turns` flag (true when some turns lack road names — common on \
        footpaths or in regions like Japan where most residential streets are unnamed; tell the user "a few turns don't have road names but I'll still call them out"). If the user names a route you don't recognise, call `get_routes` (field='list') first to \
        see what's available.

        After loading EITHER way, BRIEFLY confirm ("OK, loaded your Saturday loop — 3.2 mi, 8 turns, going forward. I'll let you know each one.") and then SHUT UP. The user will hear proactive turn alerts at ~500 ft / ~200 ft / AT each turn IF AND ONLY \
        IF they have `enableTurnByTurnAlerts` on (Settings → Notifications → Navigation). When they have `enableTurnMarkerUpdates` on, they'll also hear a per-leg recap (HR + pace + time) AFTER each completed turn.

        Do NOT manually narrate every turn yourself if the user has the toggles on — the engine fires the alerts automatically and the user has chosen the cadence. Your role is the conversational layer ("you'll be home in about 12 min, your HR is in \
        Z2") not the per-turn announcer. If the user has the toggles OFF and asks "what's my next turn?", call `lookup_fact` with key 'directions.next_step' and answer that one turn — don't proactively follow up unless they ask again.

        When the user says "never mind" / "cancel that" / "I'm not going there" / "forget the route", call `directions_clear`.
        """

    /// Which tool answers a situational question — reach for these instead of bare-denying.
    private static let locationToolGuidance = """
        # Location + journey awareness — REACH FOR THESE TOOLS, don't bare-deny
        When the user asks "where am I", "what street am I on", "which way am I going", "where can I run", "where am I heading", "how long until I'm back", "is this my usual route", "what's around me", "what's coming up", "am I about to hit X street", \
        or ANY situational / route-aware question, CALL one of these tools instead of saying you don't know:
        - `location_situation` — **PREFERRED, ONE CALL ANSWERS EVERYTHING**. Bundles current address, heading, speed, nearby POIs (water / restroom / food / parking / medical), the active route's next-turn (when one is engaged), AND the journey block: \
        shape (out-and-back outbound vs returning, loop, point-to-point), direction, projected_remaining_seconds, plus a `recurrence` sub-record when the trail matches a historical pattern ("morning route near Cedar Ln, you've done this 6 times, median \
        47 min"). Use this for anything situational; the others are slices.
        - Roads ahead without an engaged route ("what road am I about to hit") — answer from `location_situation`'s road and cross-street fields. **Do NOT invent a road name** that no tool returned; if none is there, say "I don't have road data for this \
        stretch" instead.
        - `location_current` — slim address-only lookup (street/city) when you only need that.
        - `location_current_detailed` — current + heading, speed, altitude, accuracy.
        - `get_workout_live` (field='location' / 'location_bundle' / 'route_topology') — workout-bound location data.
        - `breadcrumb.archive_summary` (via lookup_fact) — when the user asks "do you have my historical walks" / "how many walks do you have on record" / "why don't you recognise my usual route", call this to get a concrete count instead of guessing.
        Do NOT say "I don't know your location" / "I don't have a recognized route" / "I don't have breadcrumbs" without first attempting `location_situation`. That tool answers all of those at once. If `recurrence` is absent in the response, the user's \
        archive doesn't have ≥2 prior trails in this hour-band yet — say "I don't see this as a recurring route in your history yet" instead of "I don't have that capability."
        """

    /// How to phrase a location reply: most-specific level present, and never drop a field the user wants.
    private static let locationPhrasingGuidance = """
        # How to PHRASE a location reply (use the most-specific level present, don't drop fields the user wants)
        When you read back a location, lead with the most-specific identifier that's populated in the response, in this order of preference:
        1. **`area_of_interest`** when present — named landmarks ("Cedar Falls", "Lakeside Park", "Centennial Park"). Strong signal of "where am I, in human terms."
        2. **`sub_locality`** when present — Apple's neighborhood field, the answer to "what neighborhood am I in?"; often nil in suburban-residential areas.
        3. **`road`** + **`locality`** when neither of the above is present.
        4. Always include the **`postal_code`** when asked for a precise address; otherwise omit unless useful.
        5. Mention **`nearest_cross_street`** or **`nearest_intersection`** when they're populated. When NULL/empty, say "I don't have a cross street for this fix" rather than just leaving it out — silence reads as the AI not trying.

        When BOTH `sub_locality` and `road` are populated, combine them: "you're in Lakeside Hills on Elm Parkway." Saying just the road silently drops the neighborhood.

        Likewise for `journey`: when `recurrence` is present, LEAD with it ("looks like your usual morning route — you've done this 6 times, typically about 47 min"). When `shape` is `out_and_back_returning` and `projected_remaining_seconds` is set, \
        surface the projection ("about 14 min from getting back to Cedar Ln"). When `shape` is `out_and_back_outbound`, hedge ("you've gone 1.8 km out, ~14 min back if you turn around now").
        """

    /// Compact section listing the major user toggles that are OFF, so
    /// the AI doesn't waste turns trying to query / recommend disabled
    /// surfaces. Returns "" when everything is on (no need to inject
    /// the section). Exists so an HRV-only user (Fitness +
    /// training-load disabled) doesn't get coaching pushes about
    /// workouts the app won't even show them.
    @MainActor
    private static func disabledFeaturesSummary(settings: UserSettings) -> String {
        let disabled = disabledFeatureLines(settings)
        guard !disabled.isEmpty else { return "" }
        return """
        # Disabled features (don't pursue these)
        The user has explicitly turned these off in Settings. Do NOT push them, query them, or recommend re-enabling unless the user asks:
        \(disabled.joined(separator: "\n"))
        """
    }

    /// One bullet per feature the user has switched off, in the order the
    /// prompt lists them.
    @MainActor
    private static func disabledFeatureLines(_ s: UserSettings) -> [String] {
        var disabled: [String] = []
        if s.hideFitnessTab {
            disabled.append("""
                - **fitness_tab_hidden** — the user has hidden the Fitness tab. Don't suggest workouts, training plans, or features that live there. Don't try to fetch live workout data (`get_workout_live` will be empty/missing). Workout history \
                (`list_workouts`) still works for past sessions but the user isn't actively recording new ones.
                """)
        }
        if !s.enableTrainingLoadIntegration {
            disabled.append("- **training_load_disabled** — the user has turned off training-load tracking. ATL/CTL/TSB/TRIMP/ACR are not being computed for this user. Don't reference them in coaching. Skip the `training.*` namespace.")
        }
        if !s.enableSleepIntegration {
            disabled.append("- **sleep_integration_disabled** — HealthKit sleep data is NOT folded into recovery scoring. The recovery score is HRV-only. Don't reference sleep metrics in your reasoning about today's score.")
        }
        if s.isOnTrainingBreak {
            disabled.append("- **on_training_break** — the user is on a recovery / off-season break (date range: \(s.trainingBreakStartDate?.formatted(date: .abbreviated, time: .omitted) ?? "open")\(s.trainingBreakEndDate.map { " → \($0.formatted(date: .abbreviated, time: .omitted))" } ?? " (ongoing)")\(s.trainingBreakReason.map { ", reason: \($0)" } ?? "")). Don't push training intensity recommendations.")
        }
        return disabled
    }

    /// Per-send marker indicating a workout is currently in progress.
    /// Returns nil when no active session — caller skips the section
    /// entirely. Static fields only (sport, started-at, elapsed
    /// rounded to the minute) so the same marker holds across many
    /// rapid sends without forcing prompt-cache invalidation; the
    /// volatile metrics (HR, pace, GPS) live behind the
    /// `get_workout_live` tool that the marker explicitly names. The
    /// exact second is a tool call away if the model needs it.
    ///
    /// The block carries explicit provenance per HARD
    /// RULE #1 (source attribution). The model can tag values
    /// read from here as "from the live workout snapshot
    /// (started HH:MM)", matching the same tagging shape the
    /// dashboard cache block uses. If the user contradicts
    /// anything in this block, the attribution makes it obvious
    /// which source they're correcting.
    @MainActor
    private static func activeWorkoutMarker() -> String? {
        guard let live = AppDependencies.current.assistant.liveWorkoutBroker.currentSnapshot() else { return nil }
        let elapsedMinutes = max(1, live.elapsedSeconds / 60)
        let startedAt = formatted(live.sessionStartAt, "h:mm a")
        return """
        # Live workout snapshot (started \(startedAt), ~\(elapsedMinutes) min ago)
        - sport: \(live.sport)
        - strap_connected: \(live.strapConnected)

        Live HR / pace / location / power / cadence / GPS change every second and are NOT inlined — call `get_workout_live` for those, then state the numbers plainly to the user (e.g. "Your HR is 150"). Do NOT name the tool or say "from get_workout_live" \
        in your answer — that's internal plumbing. If the user states a different value than the tool returns, the user's value is fresher — acknowledge briefly ("Got it — using <user value>") and use it.
        """
    }

    /// Per-send "right now" snapshot — current ISO timestamp, local
    /// date, timezone, day-of-week. Rounded to the minute so the prompt
    /// cache hits for ~60s of sends rather than missing every second;
    /// that's a tolerable cache cost versus the alternative (the model
    /// can't tell when "now" is). Without this the model anchors to its
    /// training-cutoff date and gets every relative-time question wrong.
    private static func nowSnapshot() -> String {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .timeZone], from: now)
        let rounded = cal.date(from: comps) ?? now
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        return """
        # Current time (always anchor here, never your training cutoff)
        - now_iso: \(isoFormatter.string(from: rounded))
        - local_date: \(formatted(rounded, "yyyy-MM-dd"))
        - timezone: \(TimeZone.current.identifier)
        - day_of_week: \(formatted(rounded, "EEEE"))

        Use these values when the user asks "what time is it" / "what day is it" / \
        "yesterday" / "an hour ago" / "today" — never your model's training cutoff.
        """
    }

    /// A date in the device's current time zone under a fixed pattern.
    private static func formatted(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale.current
        return formatter.string(from: date)
    }

    /// Snapshot of the dashboard's current training-load
    /// numbers. Lives in the variable section (carried in the
    /// `<live_state>` block for cloud providers, in compactRender for
    /// Apple) so the model reads the authoritative values directly.
    /// This is the AI's single source of truth for ATL / CTL / TSB /
    /// recovery — no tool call needed, no risk of picking a frozen /
    /// stale variant of the same numbers.
    ///
    /// Returns nil when the cache is cold (first launch, no workouts
    /// yet). The block is then omitted entirely so we don't ship
    /// misleading zeroes; the model falls back to tools, which will
    /// surface the empty state honestly.
    ///
    /// Routes through `TrainingLoadRegistry.live()`.
    /// See TrainingLoadRegistry.swift's header for the
    /// canonical surface→source map. The registry exists because
    /// four readers (dashboard / AI / report / recovery detail)
    /// reading three different stores drift; the user
    /// observed dashboard=36.4 CTL, report=30 CTL, AI=29 CTL all in
    /// the same minute. The registry guarantees every "live" reader
    /// sees the same number, attaches provenance + as-of timestamp,
    /// and gates on the same cache-invalidation contract (archive
    /// notifications, in TrainingMetricsCache.init).
    @MainActor
    private static func dashboardLoadSnapshot() -> String? {
        guard let load = TrainingLoadRegistry.live() else { return nil }
        logDashboardSnapshot(load)
        let acwr = load.acwr.map { String(format: "%.2f", $0) } ?? "n/a (ctl=0)"
        var lines: [String] = [
            "# Dashboard cache (as of \(load.asOfDisplay))",
            "",
            """
                These numbers are the most-recent metrics computation; the user's screen may be a refresh ahead. State them plainly (e.g. \"TSB is -8.8\") — do NOT say \"dashboard cache\" or recite this timestamp to the user; that's internal. If the \
                user gives a different value, theirs is fresher: use it and don't re-quote these.
                """,
            "",
            "- atl: \(String(format: "%.1f", load.atl))  (acute load, 7-day EWMA — fatigue proxy)",
            "- ctl: \(String(format: "%.1f", load.ctl))  (chronic load, 42-day EWMA — fitness proxy)",
            "- tsb: \(String(format: "%.1f", load.tsb))  (form: ctl − atl; negative = fatigued, positive = fresh)",
            "- acwr: \(acwr)  (atl ÷ ctl)"
        ]
        if let recovery = todayRecoveryLine() { lines.append(recovery) }
        lines.append("")
        lines.append(dashboardCacheFooter)
        return lines.joined(separator: "\n")
    }

    /// Diagnostic so we can prove whether the cache
    /// the AI reads matches the cache the Dashboard renders. Real
    /// user transcript: AI quoted "ATL 64.7 / CTL 33.6 / TSB -31.1
    /// as of 6:42 PM cache" while the dashboard at the same minute
    /// showed ATL 51.2 / CTL 34.9 / TSB -16.2. They should be the
    /// same source. If the next log shows the emitted values
    /// still differ from what the user reports seeing on the
    /// dashboard at the same time, either (a) the dashboard reads
    /// a different source than `TrainingMetricsCache.snapshot()`
    /// (= source-of-truth bug, fixable), or (b) the cache hasn't
    /// refreshed since the dashboard rendered (= refresh-timing
    /// bug, also fixable). Either way the log identifies which.
    private static func logDashboardSnapshot(_ load: TrainingLoadRegistry.TrainingLoad) {
        debugLog(
            "[dashboardLoadSnapshot] emitting atl=\(String(format: "%.1f", load.atl)) ctl=\(String(format: "%.1f", load.ctl)) tsb=\(String(format: "%+.1f", load.tsb)) as_of=\(load.asOfDisplay)"
        )
    }

    /// Today's frozen recovery score from the most recent overnight session.
    /// Nil when there isn't one (new install, or no recording today yet).
    ///
    /// The night is the one whose midpoint falls today, as the voice answer
    /// picks it. Matching the start date found nothing on a normal morning
    /// (a night is dated the evening it began) and could pick an unreliable
    /// partial. On the dashboard's 0-100 scale.
    @MainActor
    private static func todayRecoveryLine() -> String? {
        let archive = AppDependencies.current.storage.sessionArchive
        guard let score = DeterministicIntent.todaysOvernightEntry(now: Date(), archive: archive)?.recoveryScore else { return nil }
        return "- recovery_score_today: \(RecoveryScoreCalculator.displayScore(score * 10)) / 100"
    }

    /// Framed as "cache as of HH:MM, may be stale", not as
    /// "canonical / do NOT call a tool". Research findings
    /// that drive this:
    ///   - OpenAI instruction-hierarchy paper (arxiv 2404.13208):
    ///     user corrections that match system intent are ALIGNED
    ///     and should win. Calling the cache "canonical" framed
    ///     legitimate corrections as misaligned.
    ///   - Bleakley + arxiv 2305.17311 + 2601.21433: negated
    ///     instructions ("do NOT call a tool") are followed LESS
    ///     reliably than positive directives by every frontier
    ///     model. Stacking "do NOT" prohibitions in the prompt
    ///     weakens each one.
    ///   - STALE benchmark (Marie 2026): frontier LLMs reject
    ///     stale premises only 55.2 % of the time; the only
    ///     reliable fix is to REMOVE the stale fact from
    ///     context, not to tell the model "trust the user."
    ///   - Home Assistant community precedent: when device-state
    ///     cache and user statement disagree, the user wins.
    ///
    /// `variableSections` suppresses the whole block when
    /// `UserCorrectionDetector` reports a dashboard-contradiction or
    /// explicit-override signal — the structural fix the STALE paper
    /// recommends.
    private static let dashboardCacheFooter = """
    If the user states different numbers than these, the user's numbers are newer than \
    this block — use the user's numbers and acknowledge the cache is behind. For \
    historical or trend questions, call `training.load.by_date(…)` or \
    `training.load.recent(…)`.
    """

    /// Base persona used across all providers. The full system prompt is
    /// composed via `compose(...)` per request.
}
