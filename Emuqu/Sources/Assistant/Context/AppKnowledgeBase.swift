import Foundation

// MARK: - App Knowledge Base
//
// Static FAQ / feature reference the AI Assistant can draw on when the user
// asks about the app itself ("how do I delete a workout?", "what's TRIMP?",
// "can it record without my phone?", etc.). Lives in the SYSTEM PROMPT rather
// than the per-request user context — it's stable, doesn't change per user,
// and Anthropic/OpenAI prompt caching means sending it repeatedly is cheap.
//
// Keep it factual, terse, and up to date with reality. Lying here is worse
// than omitting — the AI will confidently state a feature exists and the
// user will try it and find nothing.
//
// Sections are kept short and scannable so the model can pick out the
// relevant bit when answering a specific question rather than regurgitating
// the whole manual.
enum AppKnowledgeBase {
    /// Rendered as a block inside the system prompt. Do not include user
    /// data here — that belongs in AssistantContext.
    ///
    /// Keep "Capabilities the app does NOT have" HONEST and SHORT. The tool
    /// catalog is the source of truth for what the assistant can retrieve —
    /// if a tool exists for it, the app does it, so do not add "No X" lines
    /// that contradict a shipped tool. (Denials removed because they were
    /// false: the app HAS Stryd/foot-pod + FTMS cycling power, custom-interval
    /// structured workouts, and saved-route loading.) These notes lived inside
    /// the string as `//` lines, which went to the model as prompt text.
    static let reference: String = """
    # Emuqu — App Reference

    Emuqu is an iOS app for heart-rate variability (HRV) tracking overnight \
    AND live workout capture (walk / run / bike / hike / row and more). It pairs with Polar H10 / \
    Verity Sense BLE heart-rate straps and uses iPhone GPS + CMPedometer for motion. \
    Apple Watch is used for fallback HR (overnight and during workouts) and sleep-stage data.

    ## Tabs (v2 layout — 5 tabs)
    - **Dashboard** — today's recovery score (0–100 ring), HRV / Sleep / Vitals factor cards, \
      load trajectory, history. Tap any factor to drill into its detail screen.
    - **Record** — start an overnight HRV session with the strap.
    - **Fitness** — start a workout, see live metrics, browse workout history, export, \
      browse trends (weekly load, ramp).
    - **Flo** — this AI chat. Active provider visible in a chip; context chips above the \
      thread show what the AI sees (today's recovery, last workout, mode flags). \
      Per-screen suggested prompts available from the toolbar lightbulb.
    - **More** — profile + avatar, Trends (with the session calendar), Settings (search-enabled), Help, About. Past sessions also open from the Dashboard's Recent strip.

    ## Recovery Score (v3.1.oct2026)
    - **0–100 composite**. Tier verdict: 90+ Excellent · 75–89 Good · 60–74 Fair · 45–59 Pay Attention · 30–44 Low · <30 Very low.
    - **Three factors** (D2 detail screen explains each):
      - **HRV — 60% weight** (the core signal). Strap-derived ln(RMSSD) vs the user's own baseline (up to 60 nights; from the 3rd night, cautious until the 7th).
      - **Sleep — 25% weight** (the lever the user can move tonight). Duration + efficiency + stages.
      - **Vitals — 15% weight** (slow-moving context). Resp rate, wrist temp, resting HR vs baselines.
    - **When the score appears** (one rule, counted in nights in the baseline): nights 1–2 the morning \
      report scores on general HRV thresholds; from the 3rd night the score compares the user with \
      their own baseline; the Dashboard and score detail show the score from the 14th night \
      ("Building your baseline" before that); from the 28th night the pip reads "Full algorithm".
    - **Baseline**: overnight readings only, one per night (the night's wake date), and a night is \
      scored against the nights before it, never against itself or later nights.
    - **SpO₂ penalty**: a flat -10 applied to the composite when overnight SpO₂ drops below 95%. \
      Separate from the 15% Vitals factor.
    - **Sleep HR — strap-derived nocturnal mean.** Score uses the analysis-window mean HR \
      from the strap (matches `BaselineTracker.meanHRBaseline`). NOT Apple's daytime RHR \
      sample. The two differ by ~10–15 bpm; mixing them invalidates deviation reads.

    ## Modes
    - **Comeback mode** (Settings → Modes) — when active, for a 21-day window from \
      the activation date, a Tier 3 (HRV + Sleep + Vitals) score's weights shift to \
      HRV 80% / Sleep 20% / Vitals 0%. Vitals are silenced because illness can leave \
      them noisy for weeks. A Tier 2 score (no vitals) keeps its usual weights, and \
      the SpO₂ penalty still applies in Comeback mode. Coaching \
      should reference the day-in-window when relevant ("you're 5 days into your comeback").
    - **Peaking detection** — UI flag only at this build. The toggle exists in \
      Settings → Modes and the dashboard surfaces a "Peaking" chip when the user has \
      enabled it, but the score calculator does not change behavior based on it. Do \
      not claim it modifies the score.
    - **Intentional Overreach** — UI flag only at this build. Same as Peaking: chip \
      visible on dashboard, but the score calculator does not branch on it. Do not \
      claim it suppresses warnings or shifts weights.

    ## HRV session flow
    1. Record tab → Start recording before bed → strap captures RR intervals all night.
    2. In the morning, accept or reject the session.
    3. Dashboard refreshes with today's recovery score (0–100 hero ring on D1).
    4. HealthKit sleep data is pulled in automatically if enabled (Settings → Sleep).
    5. HealthKit vitals (resp rate / SpO₂ / wrist temp) often arrive minutes-to-hours \
       AFTER acceptance — the score's vitals factor refreshes when those samples land.

    ## Workout flow
    1. Fitness tab → Start Workout → picks up a known Polar strap automatically, else prompts to pair.
    2. Sport picker (walk/run/trail run/hike/bike/indoor bike/treadmill/row/air bike/CrossFit).
    3. Live screen: HR hero + zone color, elapsed, distance, steps, elevation, live map, DFA α1.
    4. Voice chat button opens conversational AI overlay during workout (AirPods recommended).
    5. Background recording continues when the screen locks (location + audio background modes).
    6. RR data + GPS track saved to disk about every minute, and to iCloud every 5 minutes — data survives app kill.
    7. Tap Stop → instant summary with HR/pace/cadence charts, elevation plot, splits, exports.

    ## HR zones
    Zones are percent-of-max-HR. Denominator is the user's MAX HR from settings \
    (falls back to the Tanaka estimate 208 − 0.7 × age, else 180 with no birthday). Session peak is NOT used as denominator.
    - Z1: 50–60% (recovery)
    - Z2: 60–70% (aerobic base)
    - Z3: 70–80% (tempo)
    - Z4: 80–90% (threshold)
    - Z5: 90%+ (max effort)
    Color-only labels — we don't claim "VO₂ Max zone" or "Threshold zone" without a lab test.

    ## Voice coach + AI chat
    - Voice coach fires observational lines only (never commands). Rules gated on \
      real data in WorkoutAIContext — never invents pace, HR, or baselines.
    - Voice chat (Talk button) pipes through the same AssistantViewModel as typed \
      chat — same history, same model. AirPods + screen-off = hands-free on a walk.
    - Watch Talk button sends a WCSession message; audio runs on the phone + AirPods.

    ## Exports
    - **GPX**: lat/lon/alt trackpoints — Strava, Garmin Connect, WorkOutDoors.
    - **CSV**: per-row HR, pace, cadence, METs + optional trackpoint lat/lon/alt. Numbers/Excel.
    - **TCX**: per-point HR + cadence; TrainingPeaks / Final Surge / Garmin Connect.
    Exports are pre-generated on the post-summary screen — tap the share icon, no wait.

    ## Metrics — what they mean
    - **RMSSD**: short-term HRV, vagal tone. Higher = parasympathetic dominance, usually good recovery.
    - **SDNN**: overall HRV variability over the window. Complements RMSSD.
    - **DFA α1**: fractal scaling of RR intervals. ~1.0 = aerobic, <0.75 = threshold-ish, <0.50 = max effort.
    - **LF/HF**: frequency-domain. LF ~ mixed sympathetic/parasympathetic; HF ~ parasympathetic.
    - **TRIMP (Banister)**: training load from time and heart-rate reserve, weighted exponentially, with sex-specific coefficients.
    - **hrTSS**: TrainingPeaks-style Training Stress Score from HR.
    - **Pa:Hr decoupling**: pace-to-HR drift between first/second half of workout. >5% = drift.
    - **Efficiency Factor (EF)**: normalized pace ÷ avg HR. Track over weeks to see fitness change.
    - **HRR @ 1/2 min**: bpm drop in the 60/120 s after stopping. >12 = healthy autonomic reset.
    - **METs**: mechanical energy expenditure in rest-multiples. Estimated from speed+sport band; \
      NOT estimated from HR alone (HR alone overclaims for caffeine / anxiety / digestion).
    - **Nocturnal dip**: % drop from waking HR to sleeping HR. 10–20% is healthy.

    ## Settings worth knowing (consolidated More → Settings, with search)
    - **Max HR**: More → Settings → Biometrics. Drives all zone math + voice coach.
    - **Units**: auto-follows locale; override to metric/imperial in Settings.
    - **Training break**: mark a range (injury, surgery, vacation) to hide load metrics during recovery.
    - **Modes**: Comeback / Peaking / Intentional Overreach toggles + windows.
    - **Sleep integration** / **HRV sleep augmentation**: Apple Health sleep → scoring. On by default.
    - **iCloud sync**: default on. Sessions back up to CloudKit private database.
    - **HealthKit export**: optional — HRV, mean HR, resting HR auto-push to Health after each session.
    - **Notifications**: daily report on/off + delivery time, workout coach and turn alerts.

    ## Step-by-step navigation paths (give these verbatim when the user asks "how do I…")
    Tabs are: Dashboard / Record / Fitness / Flo / More. Settings live under More.

    - **Turn off coach alerts during workouts** (master switch):
      More → Settings → Notifications → toggle off "Coach alerts during workouts".
      OR for a one-session mute: tap the speaker icon on the workout recording screen.
    - **Turn on mile-marker check-ins** (the opt-in periodic split + pace + HR-zone announcements):
      More → Settings → Notifications → "Periodic check-ins" → toggle "Mile-marker notifications" on, then pick the interval.
    - **Pair a new heart-rate strap or foot pod or PM5**:
      Fitness tab → tap the strap status pill on the workout setup screen → the Sensors sheet → tap "Pair a strap" / "Pair another" (when one is already known) — devices appear under it as you scan. If a device is already paired, "Pair another" sits next to "Reconnect".
    - **Send a recovery / daily / workout report by email**:
      Dashboard → tap the paper-plane icon (top right toolbar) → pick "Send recovery report" / "Send daily report" / "Send workout report" — mail composer opens with default training email pre-filled.
    - **Browse old reports**:
      Same paper-plane menu → "Browse all reports" — or More → Settings → Reports → "View all reports".
    - **Set up the Tavily web-search key (1000 free searches / month)**:
      More → Settings → Flo → "Web Search" section → enable the toggle, then tap "Get a free Tavily key" if needed and paste it into the field. Searches are restricted to authority domains (PubMed, manufacturer docs, training science) — supplement-spam sites are excluded.
    - **Switch the speech recognizer to WhisperKit** (open-source, better in noise, ~100 MB on-device model on first use):
      More → Settings → Flo → "Speech recognizer" → pick "WhisperKit (open-source)". Switch takes effect at the next voice session start. Apple is the fallback if WhisperKit fails to load.
    - **Keep clipboard contents from auto-clearing** (default ON since 2026-05-07 — ideas don't get lost when an alert preempts you):
      More → Settings → Flo → "Clipboard" → toggle "Keep copied content until I paste it".
    - **Set the home address for "lead me home" routing**:
      More → Settings → Biometrics → Home Address.
    - **Set default email recipients for reports**:
      More → Settings → Profile → Recovery emails / Training emails (separate sections; the training one is mirrored under More → Settings → Reports → Default recipient).
    - **Disable a specific provider** (kill switch — useful if a key is leaked or a service is acting up):
      More → Settings → Flo → "Provider availability" → toggle off the offending one.
    - **Reset cache / training-load / score telemetry**:
      More → Settings → Troubleshooting → "Reset cache telemetry"; memory and termination history is under Troubleshooting → Archive Diagnostics → "System Diagnostics".
    - **End an active workout**:
      Hold the red "Hold to end workout" bar at the bottom of the recording screen for ~1.2 s. A haptic fires when the hold registers, another when it completes.

    ## Capabilities the app does NOT have (yet)
    - No Apple Watch as the PRIMARY HR source for a workout (a Polar strap is primary; the Watch is a fallback).
    - No multi-sport transitions in a single session (no bike-to-run hand-off).

    ## Scope of this AI chat
    - Live workout context (HR, pace, distance, zone, route topology) while a workout runs — via the workout.live.* tools.
    - The FULL session archive is reachable through the typed tools (sleep/hrv/vitals/recovery/workout/training), not just a fixed recent window — use a tool to fetch history rather than assuming a cutoff.
    - User profile (age, sex, fitness level, max HR, VO₂max if set).
    - Cannot control recording, delete workouts, or change settings on the user's \
      behalf — it can only report + reason + suggest. Actions stay in the user's hands.
    """

    /// Compact version for Apple on-device model (limited context window).
    /// Trimmed down to features + metric definitions without verbose intros.
    static let referenceCompact: String = """
    # Emuqu — quick reference
    Tabs (v2): Dashboard, Record, Fitness, Flo, More (Trends/Settings/Help live here; past sessions open from the Dashboard).
    Recovery Score (v3.1.oct2026): 0–100 composite. HRV 60% · Sleep 25% · Vitals 15%. \
    SpO₂<95% adds a flat -10 penalty. Sleep HR is the strap's nocturnal analysis-window mean, \
    NOT Apple's daytime RHR — never compare them apples-to-apples mixed.
    Modes: Comeback (active = a score with vitals shifts to HRV 80% / Sleep 20% / Vitals 0% for 21 days). \
    Peaking + Intentional Overreach are UI flags only at this build — chips on dashboard, no score effect.
    Sports: walk/run/trailRun/hike/bike/indoorBike/treadmill/row/airBike/crossFit (GPS uses first five; row reads distance, stroke rate and watts from a Concept2 PM5 or FTMS rower; air bike and CrossFit are strap-HR only).
    HR zones = %-of-user-max-HR (Settings → Biometrics → Max HR; default 208 − 0.7 × age).
    Exports: GPX (map), CSV (per-row HR/pace/cadence/METs), TCX (HR+cadence).
    Metrics: RMSSD (HRV vagal), SDNN (overall HRV), DFA α1 (aerobic band), TRIMP/hrTSS (load), \
    Pa:Hr decoupling (drift), EF (efficiency), HRR (recovery), METs (energy proxy — from motion only, not HR).
    Max HR: user-set, else 208 − 0.7 × age (Tanaka), else 180 with no birthday.
    Training break: user-settable range, hides load.
    Stryd / foot-pod power, FTMS cycling power and structured intervals are supported. AI can inform but not change settings.
    For app-feature, metric-explanation, or navigation questions (e.g. "what does DFA mean", \
    "where's the export option", "what's pNN50"), call `app.help.lookup(topic:)` — the full \
    reference lives there. Valid topics: tabs, recovery_score, modes, hrv_session_flow, \
    workout_flow, hr_zones, voice_coach, exports, metrics, settings, navigation, capabilities, scope.
    """

    /// Available topics for `lookup(topic:)`. Stable identifiers that
    /// match the section headers in `reference`. Listed in the tool's
    /// description so the model knows what to ask for.
    static let helpTopics: [String] = [
        "tabs",
        "recovery_score",
        "modes",
        "hrv_session_flow",
        "workout_flow",
        "hr_zones",
        "voice_coach",
        "exports",
        "metrics",
        "settings",
        "navigation",
        "capabilities",
        "scope",
        "all"
    ]

    /// Return one section of the full reference for the given topic.
    /// Topic strings normalize loosely (case-insensitive, dashes / spaces
    /// / underscores all collapse to underscore). Returns the compact
    /// reference for unknown / empty topics so the model never gets
    /// nothing back.
    static func lookup(topic raw: String) -> String {
        let key = raw
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .trimmingCharacters(in: .whitespaces)
        if key == "all" { return reference }
        guard let heading = Self.topicHeadings[key] else { return referenceCompact }
        return extractSection(named: heading) ?? referenceCompact
    }

    /// Topic aliases → the heading each one resolves to in `reference`.
    private static let topicHeadings: [String: String] = [
        "tabs": "Tabs (v2 layout — 5 tabs)",
        "recovery_score": "Recovery Score (v3.1.oct2026)",
        "modes": "Modes",
        "hrv_session_flow": "HRV session flow",
        "session": "HRV session flow",
        "sessions": "HRV session flow",
        "workout_flow": "Workout flow",
        "workout": "Workout flow",
        "workouts": "Workout flow",
        "fitness": "Workout flow",
        "hr_zones": "HR zones",
        "zones": "HR zones",
        "voice_coach": "Voice coach + AI chat",
        "voice": "Voice coach + AI chat",
        "ai_chat": "Voice coach + AI chat",
        "exports": "Exports",
        "export": "Exports",
        "metrics": "Metrics — what they mean",
        "metric": "Metrics — what they mean",
        "settings": "Settings worth knowing",
        "navigation": "Step-by-step navigation paths",
        "navigate": "Step-by-step navigation paths",
        "how_do_i": "Step-by-step navigation paths",
        "capabilities": "Capabilities the app does NOT have",
        "limits": "Capabilities the app does NOT have",
        "scope": "Scope of this AI chat"
    ]

    /// Walk `reference` line by line, returning the block under the
    /// matching `## heading` until the next `##`. Returns nil on no
    /// match so `lookup(topic:)` can fall back cleanly.
    private static func extractSection(named heading: String) -> String? {
        var captured: [String] = []
        var inside = false
        let target = "## " + heading
        for line in reference.components(separatedBy: "\n") {
            guard !(inside && line.hasPrefix("## ")) else { break }
            if line.hasPrefix(target) { inside = true }
            if inside { captured.append(line) }
        }
        guard !captured.isEmpty else { return nil }
        return captured.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
