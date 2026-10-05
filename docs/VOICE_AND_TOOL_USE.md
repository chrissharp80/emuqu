# Voice Conversation & Tool Use

> **For the assistant ("Flo") architecture — provider matrix, fact catalog and routing layer — see [`FLO_ARCHITECTURE.md`](FLO_ARCHITECTURE.md).** This document is a complementary view focused on voice + tool-use behavior with field-test notes on what's known to misbehave.

This document covers how the AI assistant fetches your data, how voice
interrupts work, and — equally important — what's fragile, what's stubbed
out, and what's known to misbehave. It is deliberately not a sales sheet.

If you're reading this to decide whether voice mode is reliable: it is not
yet. The pieces are wired up and the architecture is sound, but expect
rough edges, especially around environmental noise, hallucinations, and
providers that haven't been field-tested for tool use.

The chat tab is named **Flo**. The audible mid-workout trigger voice is
called **Coach** (different `AssistantSubsystem`; you'll hear "Coach
here." as its first utterance instead of "Flo here."). The auto-generated
email goes out as a **Flo Report**. All three share the same model picker
and conversation history; what differs is the rendering channel and the
chat-bubble badge.

---

## Adaptive routing (Quick / Auto / Deep / Manual)

Per-turn provider selection is governed by a `RoutingMode` set in
**Settings → Flo → Routing**. The router lives at
[`SmartProviderRouter.swift`](../Emuqu/Sources/Assistant/Facts/SmartProviderRouter.swift);
the **capability classifier** at
[`CapabilityClassifier.swift`](../Emuqu/Sources/Assistant/Facts/CapabilityClassifier.swift);
the abstract-tier → concrete-(provider, model) mapping at
[`TierProviderMapper.swift`](../Emuqu/Sources/Assistant/Facts/TierProviderMapper.swift).

Routing acts only while **Apple Intelligence is the selected model**.
With any other model selected, every turn goes to that model and the
routing picker is disabled (`TurnRouter.preTierDecision`).

| Mode | What it does (Apple selected) |
| --- | --- |
| **Quick** | Every typed turn stays on Apple Intelligence (on-device, free, fastest). Apple's safety filter may still refuse some health-adjacent prompts. |
| **Auto** | Session-sticky **capability classifier**. Apple when zero capability flags fire; otherwise the mid-tier cloud: xAI Grok, then DeepSeek, whichever the user has added a key for and accepted the consent sheet of. Apple when neither is consented. |
| **Deep** | Every typed turn takes the same consented mid-tier cloud as Auto; Apple only when none is consented. |
| **Manual** | Every turn → whatever you picked in the model picker (escape hatch). No routing logic runs. |

In Quick, Auto and Deep, voice turns and action requests Apple can't
serve (email, directions, web search…) go to the first cloud provider
in registry order whose consent sheet the user accepted, if any;
otherwise they stay on Apple.

### Capability-axis classifier

The router used to ask *"how complex does this question look?"* That
collapsed when a simple-looking question turned out to need a tool
the cheap model didn't have ("can you see the top of the last hill?"
is eight words but requires per-tick GPS + altitude). The replacement
asks *"what does this question NEED?"* across four orthogonal binary
axes, each gated by both a keyword marker AND embedding cosine
similarity ≥ 0.55 to a per-axis prototype centroid:

1. **`needsTools`** — explicit action verbs (email, directions, save
   route, list contacts) OR data lookups beyond the static context
   block (per-workout deep-dives, full archive history, route library
   mutations).
2. **`needsWeb`** — facts outside the user's own data (weather, news,
   product recommendations, "is X commercially licensable?").
3. **`needsHistoricalDepth`** — comparisons against history older than
   the static 14-workout context block ("trend over 8 weeks",
   "month-over-month", "since I started").
4. **`needsSpeculation`** — speculative reasoning that on-device
   Apple's safety guardrail typically refuses but `MedicalQueryGuard`
   permits ("best guess on…", "predict next week", "what if I rest").

Truth table → tier:

| Flags set | Tier | Provider (Apple selected) |
| --- | --- | --- |
| 0 | `.quick` | Apple (on-device) |
| 1 | `.auto` | Consented Grok, then DeepSeek; else Apple |
| ≥ 2 | `.deep` | Same as `.auto` (never a weaker model than a one-flag question) |

The keyword gate is critical. Embedding-only over-triggered on plain
lookups ("what's my recovery score" embeds close to history-depth
prototypes — the word "recovery" is shared vocabulary), so an axis
fires only when **both** signals agree. Tests in
[`CapabilityClassifierTests`](../EmuquTests/CapabilityClassifierTests.swift)
enforce the contract (19 cases including the "recovery score" false
positive).

### Voice-mode bypass

Voice does **not** route through `SmartProviderRouter`. The 22-turn
diagnostic session that prompted this rewrite showed every voice turn
landing on Apple even though Anthropic was configured: voice
utterances are reliably ≤ 12 words (Stanford 2024 multi-turn study),
the classifier votes Quick, session stickiness locks it.

Voice only reroutes while Apple is the selected model; any other pick
answers voice turns itself. With Apple selected (and any mode but
Manual), `TurnRouter.appleVoiceBypass` sends the voice turn to the
first available cloud provider, in registry order, whose consent sheet
the user accepted, on that provider's default model. Entering a key is
not consent. With no consented cloud, voice stays on Apple.
This mirrors ChatGPT Advanced Voice, Gemini Live,
Pi.ai, and Granola — production voice AIs all session-stick to a
single model for the duration of a voice session.

### Stickiness rules (typed turns, Auto mode)

1. **Upgrades always allowed.** Proposed tier > current → adopt
   immediately.
2. **Within settling window** (turns 1–3) → take the proposal as-is.
3. **Capability-clear escape.** Post-settle, if the classifier
   returns `Requirement.none` (zero flags) AND the proposal is
   `.quick`, downgrade is allowed. Without this, a single Tier-3
   question early in the conversation locks every subsequent simple
   lookup to the Deep tier.
4. **Otherwise sticky-up** — keep the higher tier.

### Action-intent override

Apple Intelligence gets the tools that fit its budget through
`LanguageModelSession(tools:)`, but for routing `providerSupportsTools`
is false for Apple, so when `messageRequiresTools(text)` detects an
explicit action verb and the turn resolved to Apple, it goes to the
first consented cloud provider in registry order instead. No consented
cloud → it stays on Apple.

### Embedding fallback chain

`NLContextualEmbedding(language: .english)` when assets are loaded →
`NLEmbedding.wordEmbedding(for: .english)` → keyword-only path. Asset
download (~50 MB) runs once on first launch via
`Task.detached { try? await e.requestAssets() }`; until the model is
resident the keyword path classifies adequately (false-negative bias —
prefers Quick over Deep when uncertain).

### Adversarial-spend cap

A daily Tier-3 ceiling of 50 turns (`dailyTier3Cap`) prevents runaway
spend. `recordTier3UsageAndCheck()` counts hits per local-date key in
memory; once exceeded, the view-model downgrades further Deep
proposals to Auto for the rest of the day.

### Deterministic intent shortcut

Before any LLM call, the dispatch path checks
[`DeterministicIntent.tryMatch`](../Emuqu/Sources/Assistant/Facts/DeterministicIntent.swift).
~30–50% of voice turns are repeats of a small set of factual lookups
("what's my recovery", "how did I sleep last night", "what's my RHR")
that don't need an LLM at all. The 14-pattern catalog maps each
trigger regex to a fact-catalog read + template render path that
costs zero tokens, runs in <50 ms, and stays on-device.

Patterns covered: `recovery_score_today`, `resting_hr_today`,
`hrv_rmssd_today`, `sleep_duration_last_night`, `last_workout_summary`,
`trained_recently`, `score_breakdown_today`, `sleep_stages_last_night`,
`body_weight`, `max_hr`, `lthr`, `sleep_latency`, `sleep_efficiency`,
`total_session_count`. Anything ambiguous, parameterised mid-sentence,
needing a tool call, or in the speculation/medical/web band falls
through to the LLM. Precision comes from keeping the patterns narrow
(first match wins; no confidence gate).
[`DeterministicIntentTests`](../EmuquTests/DeterministicIntentTests.swift)
checks it with example-based assertions, not a labeled-precision gate.

### Tier indicator on chat bubbles

Each assistant turn carries `routedTierRaw: Int?`; `ChatBubble`
renders a 6-pt dot below the model badge: green = Quick, blue = Auto,
purple = Deep. Manual-mode and voice-bypass turns leave the field nil
and render no dot.

### AFM prewarm

`AppleFoundationProvider.prewarm()` (idempotent, detached, `.utility`
priority) runs on the first send, not in `AssistantViewModel.init`, when
routing might land on Apple — Quick / Auto, OR Manual with the Apple
provider selected. The model starts loading while the fact registry
and system prompt are built; first-answer latency drops from ~1.5 s to ~300 ms
on A17 / M-series.

### Voice preamble names the model

The earcon at voice-session start now names the model handling the
turn: *"Flo here. Sonnet."* / *"Flo here. Apple."* /
*"Flo here. Haiku."* (the chat-tab voice conversation is the
`.voiceConversation` subsystem, whose `voiceAnnouncement` is "Flo
here."; only the mid-workout `.workoutVoiceCoach` subsystem says
"Coach here."). `VoiceConversationController.currentModelDisplayName()`
maps the active provider and
`AssistantViewModel.activeModelDisplayName` to a single-token label. Users were getting no
signal about whether Apple or Anthropic was talking back; the earcon
makes it audible.

### Cache health telemetry

`LLMCacheTelemetry.shared` records every provider's prompt-cache
hit/miss on the `.usage` stream event (Anthropic
`cache_read_input_tokens` / `cache_creation_input_tokens`, OpenAI
`prompt_tokens_details.cached_tokens`, DeepSeek
`prompt_cache_hit_tokens`, Gemini `cachedContentTokenCount`). A
**Settings → Troubleshooting → AI cache health** card surfaces
cumulative + last-10-turn hit ratios per provider, with a reset
button. Stays on-device.

---

## How the assistant fetches data

Every connected provider — including Apple — now uses tool use. Apple
gets a compacted instruction prefix on top of the tool catalog
because of its tight 4K context window; the cloud providers send the
full instructions and lean on prompt caching.

### Tool-use path (all providers)

1. System prompt ships with the Fact Catalog exposed as a **tool schema**.
   Two layers (Anthropic's "progressive disclosure" / just-in-time pattern):
   the full catalog is over 200 `FactEntry` keys, but the
   model is handed a **compact meta-schema** (`CompactToolRouter` —
   `get_sleep`, `get_hrv`, `get_training_load`, … + `lookup_fact` for the
   long tail), NOT every key. The typed meta-tools cover the common asks; any
   remaining key is reachable by string via `lookup_fact`. The prompt itself
   is small (~3 KB) and byte-identical every turn, so each provider's prompt
   cache hits on turn 2+.
2. When you ask a question, the model replies with one or more
   `tool_use` blocks. We resolve each locally by calling
   [`CompactToolRouter.resolveTool`](../Emuqu/Sources/Assistant/Facts/CompactToolRouter.swift),
   which maps the compact tool onto
   [`FactResolverRegistry`](../Emuqu/Sources/Assistant/Facts/FactResolverRegistry.swift),
   reads from `SessionArchive` + `SettingsManager` and returns a
   structured `FactValue`.
3. The result goes back in a continuation message. The model either asks
   for another tool (chained lookup) or composes a text answer.
4. Hard cap: **8 tool calls per turn** (`AssistantViewModel+Tools.maxToolCallsPerTurn`).
   On the 9th the resolver returns a synthetic
   `{"status":"missing","reason":"tool budget exceeded"}`, and we give the
   model one more pass to compose a closing sentence before force-exiting
   the loop. (Earlier drafts of this doc said 4 and 16 in different places;
   the code is the source of truth — it is 8.)

The old "dump the whole archive into the system prompt every turn" path
is deleted. That's the change that makes DeepSeek stop slowing down
after five turns and that lets Apple answer per-workout history
queries within the 4K window.

### Apple Intelligence — tool wiring + verbatim compaction

Apple's tool-use lives behind a thin adapter:

- **[`AppleToolCatalog.wrap(_:handler:)`](../Emuqu/Sources/Assistant/Providers/AppleFoundationToolAdapter.swift)** —
  wraps each `ToolSpec` in a `Tool<Arguments, Output>` where
  `Arguments = AppleToolArgs(@Guide argumentsJSON: String)` and
  `Output = String`. One adapter shape for the whole catalog (21 read tools plus up to 16 action tools);
  the adapter forwards `argumentsJSON` to the dispatcher.
- **[`AppleToolDispatcher.shared`](../Emuqu/Sources/Assistant/Providers/AppleToolDispatcher.swift)** —
  `@MainActor` singleton. Before each Apple-routed send,
  `AssistantViewModel.dispatch()` calls
  `AppleToolDispatcher.shared.setRegistry(factRegistry)` so the
  adapter handler can find the active `FactResolverRegistry`. The
  handler builds a `CompactToolRouter`, calls `resolveTool`, and
  returns `FactValue.toToolResultJSON()` — the same envelope cloud
  providers see (`{"value": …, "missingReason": …, "asOf": …,
  "confidence": …}`). Wire-shape parity across providers means the
  schema teaches absence semantics structurally instead of via a
  prompt rule.
- **[`AppleContextCompactor`](../Emuqu/Sources/Assistant/Facts/AppleContextCompactor.swift)** —
  Apple's `LanguageModelSession` enforces a 4,096-token combined
  ceiling (system + transcript + tools + response). Without
  compaction, a 20-turn voice conversation hits
  `.exceededContextWindowSize` around turn 12-15. The compactor
  drops oldest user/assistant pairs verbatim once the transcript
  reaches 70% of the budget, keeping the most recent user turn and
  walking newest→oldest. Verbatim deletion (per CogCanvas
  arxiv 2601.00821) preserves quoted preferences ("call me Sam", "I
  run 50 km/week") that LLM-summarisation would blur, and avoids
  recursively calling Apple to compress its own context.
- **Session cache** — `AppleFoundationProvider.SessionCache` reuses
  one `LanguageModelSession` across multiple sends as long as the
  instructions and tool-catalog hash haven't changed. Sessions
  rotate after 20 turns to bound KV-cache drift. On a cache hit the
  provider sends only the latest user turn (the session remembers
  prior turns); on miss it sends the compacted transcript.

### What's in the catalog

Namespaces: `user`, `app`, `session`, `sleep`, `hrv`, `vitals`,
`recovery`, `walks`, `training`, `workout` (live + per-session +
power-derived), `routes_library`, `tags`, `hrr`, `assistant`, `web`,
`location`, `directions`, `breadcrumb`, plus `composites` for
aggregated multi-call queries. Each entry is declared as a `FactEntry`
in
[`AppFactResolver.swift`](../Emuqu/Sources/Assistant/Facts/AppFactResolver.swift).
Adding a new fact is one line in one file — the tool schema regenerates
deterministically at request time and the model discovers it next turn.

**Location namespace** (`location.*`) — works whether or not a workout
is active. Cache fast-path: when a workout is recording OR the app is
foregrounded, the resolved address is kept fresh in
`RoadGeocodingService.shared.current` (workout pipeline + ambient
location service both feed it). Tools return cached values instantly
when < 5 minutes old; on miss they fall back to a 5-second cold fetch:
- `location.current` — resolved street + locality + state + country +
  nearest cross street + intersection. Use for "where am I" / "what
  street am I on".
- `location.current_detailed` — adds heading (degrees + compass
  cardinal), speed (m/s + mph + km/h), altitude (m + ft), GPS
  horizontal accuracy.
- `location.set_address` — forward-geocodes a free-text address the
  user told you and overrides the ambient context with it. For when
  GPS is failing and the user provides a verbal location.

**Directions namespace** (`directions.*`) — turn-by-turn powered by
MapKit. Engages an `ActiveRouteSession` after the first calculate;
subsequent step queries are <10 ms with no network:
- `directions.routeTo` — engages a walking (or driving) route.
  Destinations: `origin` (breadcrumb origin), `home` (saved Settings
  address), `parking` / `park` / `help` (hospital) / `police` /
  `fire` (`MKLocalSearch` nearest), or typed `address`.
- `directions.next_step` — live next-turn against the user's cached
  position. Returns upcoming instruction, distance to it, total
  remaining, an `arrived` flag (true within 25 m of destination).
- `directions.clear` — drops the active session. Use when the user
  says "never mind" or has acknowledged arrival.

**Breadcrumb namespace** (`breadcrumb.*`) — Get Me Back trail
introspection. Read-only; mutating the store belongs to the
GetMeBackView UI:
- `breadcrumb.active` — currently-engaged trail (origin coord, label,
  fix count, walked-out distance, crow-fly distance back to origin).
- `breadcrumb.recent` — newest 10 archived trails (includes auto-
  archived workout tracks, labelled "Run on Apr 29, 8:13 AM" etc.).
- `breadcrumb.count` — number of trails in the archive.

**Score-architecture facts** — let the AI answer
questions about the v3.oct2026 score change without inferring from
indirect signals. Live-evaluated, no caching:
- `score.algorithm.version` — `"v3.1.oct2026"`. Carries the description
  of what changed and the citation behind it (Impellizzeri 2020/2021)
  so the AI has full context when the user asks.
- `score.history.recomputed_under_v2` — Bool. False when an upgrading
  user chose "Maybe later" on the disclosure modal; the AI should warn
  that older session scores in the context may still be under v1.
- `user.settings.comeback_mode_active` — Bool. When true, the recovery
  score is using HRV 80% / Sleep 20% / Vitals 0% instead of the standard
  60/25/15 for 21 days.
- `user.settings.comeback_mode_day_in_window` — Int (0–20) or missing.
  Lets the AI phrase "you're 5 days into a 21-day comeback window"
  instead of just "comeback mode is on".

**Vitals fallback** — in addition to the overnight `vitals.latest`
record:
- `vitals.hr_now` — most recent HR sample from any source via
  HealthKit (Watch / strap / etc.), with a 10-minute staleness gate.
  Used when there's no live workout and the user asks "what's my HR
  right now". Returns notRecorded for samples older than 10 min so
  stale readings don't lie.

**Live workout namespace** (`workout.live.*`) — populated only while a
workout is recording, otherwise returns `.missing(.notRecorded)` with
detail "no workout active":

- `workout.live.active` — cheap boolean, model calls this first
- `workout.live.snapshot` — full per-tick LiveWorkoutSnapshot
- Per-metric atomic keys:
  `workout.live.{sport, elapsed_sec, hr, pace_sec_per_km, speed_m_per_s,
  distance_meters, alpha1, alpha1_band, alpha1_status, cadence_spm,
  elevation_gain_meters, power_watts, location, units_preference}`
- `workout.live.recognized_route` — name + direction (forward / reverse)
  when a saved route was matched mid-workout
- `workout.live.route_topology` — climbs queue (capped at 5, each with
  distance ahead + length + grade + gain), total ascent remaining,
  peak altitude, altitude above route minimum, steepest grade ahead,
  meters to peak. Drives the AI's "what's coming up?" answers.
- `workout.live.weather` — temperature, wind speed + direction,
  humidity, conditions string (MET Norway). 30-min
  cache TTL.

**Power-derived workout facts** (`workout.power.*.by_date($date)`) —
computed at session finalize when both a power source (Stryd / FTMS /
PM5 / CPS) and the matching FTP (`runningFTPWatts` / `cyclingFTPWatts`)
are present:

- `workout.power.avg.by_date($date)` — average power for the date
- `workout.power.normalized.by_date($date)` — Coggan NP
- `workout.power.peak.by_date($date)` — peak watts
- `workout.power.tss.by_date($date)` — Power-TSS, `(NP/FTP)² × hours × 100`
- `workout.power.intensity_factor.by_date($date)` — NP / FTP
- `workout.power.variability.by_date($date)` — NP / avg power

When the workout had no power source or FTP isn't set, the IF / TSS /
variability facts return `.missing(.notRecorded)` with a detail
string ("FTP not set for this workout's sport" / "no power data
captured").

**User profile additions**:

- `user.profile.running_ftp` / `user.profile.cycling_ftp` — the
  FTP anchors for power-TSS

**HRV window classification** (`hrv.window.*`):

- `hrv.window.classification` (organized recovery / fragmented / etc.)
- `hrv.window.is_organized_recovery`, `hrv.window.is_consolidated`

**App utilities** (`app.*`) — TZ-aware time, sensor state,
settings:

- `app.now.{iso, local_date, timezone, day_of_week}` — call before any
  relative-date math so TZ doesn't bite you
- `app.devices.polar.{connected, battery_percent,
  recording_hours_since_charge, spec_capacity_hours, device_type,
  firmware, known_count}` — Polar strap / Verity. The hours-since-charge
  + spec-capacity pair is the honest battery-time-left answer
- `app.devices.{foot_pod, pm5}.{connected, known_count}` — Stryd /
  FTMS bike trainer / Concept2 PM5
- `app.devices.zwift_broadcast.{advertising, subscriber_count}` — BLE
  peripheral state
- `app.settings.{sleep_integration_on, sleep_hrv_augmentation_on,
  penalize_missing_sleep_on, training_load_integration_on,
  zwift_broadcast_on, healthkit_export_on}` — toggle states
- `app.healthkit.available`

**Assistant memory** (`assistant.memory.*`) — the cross-session
"remember this" store, exposed back to the AI:

- `assistant.memory.count`
- `assistant.memory.list` — every saved fact with id + text +
  created_at, newest first
- `assistant.memory.auto_extract_enabled`

**Live workout — road context** (`workout.live.location.*`):

- `workout.live.location.road` — current street name from
  reverse-geocoded GPS ("Elm Street", "US-441")
- `workout.live.location.locality` — city / town
- `workout.live.location.administrative_area` — state / province
- `workout.live.location.country_code` — ISO ("US", "GB")
- `workout.live.location.compact_address` — one-line ready to read
  back to the user

Refreshed every ~15 m of movement OR every ~60 s via Apple's
CLGeocoder (free, on-device where possible). Returns missing for
indoor workouts, before first GPS lock, or when the geocoder doesn't
recognise the coordinate (water, wilderness).

**Per-climb road names**: `workout.live.route_topology` returns each
climb with a `road_name` field when the route was saved through the
SavedRouteStore enrichment pass. Lets the AI say "the climb on Hill
Rd in 0.4 miles" instead of "a climb at distance 412 m."

**Live workout — coaching state** (`workout.live.thresholds.*`,
`workout.live.interval.*`):

- `workout.live.thresholds.active` — what physiological constraints the
  user pre-declared for this workout
- `workout.live.thresholds.any_breaching` — cheap bool guard
- `workout.live.thresholds.breach_state` — per-threshold breach seconds
  vs debounce
- `workout.live.interval.active` — bool
- `workout.live.interval.current_step` — label + step number + elapsed
  + remaining
- `workout.live.interval.next_step` — label of the step after
- `workout.live.hrr_capture_status` — coarse state of the post-Stop HRR
  capture window

**Web search** (`web.*`) — opt-in window onto the open web via Tavily:

- `web.available` — bool; true iff the user enabled web search in
  Settings AND a Tavily key is set. AI calls this first to avoid wasted
  action calls.
- `web.search(query, intent?, max_results?)` `[ACTION]` — runs a Tavily
  search constrained to a curated authority-domain whitelist:
  - `intent: "research"` (default) — PubMed, scholar.google,
    frontiersin, intervals.icu, fellrnr, joefrielsblog, alancouzens,
    Stephen Seiler, Marco Altini, Kubios, EliteHRV, HRV4Training, Oura,
    ACSM, UpToDate, Mayo, Cleveland Clinic
  - `intent: "manufacturer"` — Polar, Garmin, Stryd, Concept2, Wahoo,
    Tacx, Saris, Apple, Zwift official docs
  - `intent: "general"` — open web (only when neither fits)
  - All searches additionally exclude pinterest.com, quora.com,
    answers.yahoo.com, wikihow.com, ehow.com.

The system-prompt overlay enforces five hard rules for web search:
prefer user's own data, results are reference material (never medical
advice), always cite source URLs in Markdown, pick the right intent,
one search per turn unless the user explicitly asked for a survey.

**Routes library** (`routes.library.*`) — both read and **mutation**:

Reads:
- `routes.library.count` — scalar count of saved routes
- `routes.library.list` — every saved route with id / name / sport /
  created_at / distance / ascent / descent / climb_count

Mutations (the catalog's first action tools — see "Mutation tools" §
below):
- `routes.library.rename(current_name, new_name)` `[ACTION]` — rename a
  saved route in place. Case-insensitive name match; returns an
  `invalidParameter` error when multiple routes share the name (forces
  the model to ask the user to disambiguate).
- `routes.library.save_workout(name, date?)` `[ACTION]` — save a
  finished workout to the library under the given name. Without
  `date`, defaults to the most-recent finished workout; with `date`
  (yyyy-MM-dd), targets a specific past one. Errors when the workout
  has no GPS polyline (indoor / no-fix sessions).

### Mutation tools (`[ACTION]`)

A small subset of catalog entries change app state instead of returning
data. They are dispatched through the same tool-use pipeline as reads,
but the contract is stricter:

1. **Description starts with the literal `[ACTION]` token.** This is how
   the prompt overlay enumerates them and how the model recognises a
   mutation tool without parsing semantics.
2. **Explicit-instruction-only.** The system prompt's tool-use overlay
   includes a hard rule: the model may only call a mutation tool when
   the user explicitly asks for the change in the current turn AND
   supplies the new value. Inference is forbidden.
3. **Confirmation read-back.** On success the action returns a record
   with the old + new values; the model must read this back to the user
   in plain language ("Renamed Daily 1 to Morning Loop") so there's a
   verbal receipt the change committed.
4. **Disambiguation surfaces verbatim.** When an action returns
   `invalidParameter` with a disambiguation hint, the model passes it
   to the user and asks — never guesses.
5. **No self-initiated undo.** Mutations stay committed until the user
   asks for the reverse.

The action entries the model can call are listed in
`CompactToolRouter.allowedActionNames`: route library rename /
save_workout / engage, contacts add / remove, email compose, memory
add / remove / clear, web search, current location (plain, detailed,
situation), set address, and directions route-to / clear. Not all of
them change app state (the location and web-search entries read), but
all go through the same action path and contract.

**Known gap:** the catalog covers workouts (live + per-session + power),
training load, sleep / HRV / vitals / recovery snapshots per session or
per day, and the user profile. It does NOT yet expose monthly or
year-over-year aggregations.
Questions like "how is my sleep compared to six months ago?" will often
produce an "I don't have that" response or, worse, a confident-sounding
fabrication from the model. When you catch one, tell the assistant and
it should correct itself (the prompt has a hard rule against denying
what you reported hearing). Aggregations are on the list to add.

---

## Voice conversation flow

The mic button at the top-left of the chat tab toggles a continuous
voice conversation. This is not "press to dictate a message" — that's
the separate mic icon next to the text field. Voice conversation keeps
the mic hot the entire time so you can interrupt the AI mid-sentence.

### Audio session

On voice start, the `AVAudioSession` is configured as `.playAndRecord`
with mode `.measurement` (no input signal processing — Apple's
recommendation for speech recognition). The category claim goes
through `AudioSessionCoordinator` (2026-04-29) — single owner of
`setCategory` calls. Voice and `BackgroundAudioManager` (which claims
`.workoutCue` only while a spoken workout cue plays) both declare
INTENT through it; the coordinator picks the strict-superset category
(voice's `.playAndRecord` wins when both are claimed), so a cue spoken
mid-chat never changes the category under the mic.

History note worth preserving: an earlier revision switched to mode
`.voiceChat` (for hardware AEC) while another audio component called
`setCategory(.playback, ...)` directly, which clobbered the voice
recording config and produced `kAFAssistantErrorDomain:1110 No speech
detected` until full app restart. The coordinator is the proper fix;
the original revert to `.measurement` was a workaround. Software echo rejection
(the gate-4 Jaccard overlap below) covers what AEC would have done
on AirPods.

If the recogniser errors with `1110` or `kLSRErrorDomain:301` mid-
session we auto-restart the recognition task (once per 1.5 s cooldown
to avoid tight loops). Empirically this covers the "audio route
changed mid-session" failure mode without the user having to toggle
voice off and on.

When a system interruption fires (phone call, Siri, timer alarm), the
voice session tears down entirely and does NOT auto-resume. You have
to tap the mic button again to start a new session. This is
deliberate — the user's context shifts during an interruption, so
silently resuming is worse than making you choose.

### Barge-in (interrupting the AI)

Four gates, **all required**, fire an interrupt while the AI is
speaking:

1. **Grace period**: 600 ms after TTS starts, to stop the AI's own
   first syllables from tripping barge-in via echo.
2. **Sustained RMS**: input level above threshold for 300 ms of
   continuous voice. Rules out single pops, footsteps, car horns.
3. **≥ 2 recognized words** in your locale since TTS started. This is
   the critical gate. Wind and passing traffic produce sustained
   loud RMS but decode to zero words; "hey stop" decodes to two.
   If you want to interrupt, say at least two words.
4. **Echo rejection**: if the "new words" Jaccard-overlap with what
   the AI just said (above a length-sensitive threshold), we treat
   them as mic leakage and ignore.

Push-to-talk fallback: there's a **Send now** button in the voice
status pill (visible whenever the controller is listening). Tap it
to commit whatever transcript has been captured, bypassing the
VAD/silence logic. Use it if the recognizer stalls in wind or noise.

### Stop-button behavior

Both the chat **Stop** button and the voice **mic toggle** (when the
AI is speaking) fully tear down the response: they cancel the LLM
stream, stop the AVSpeechSynthesizer immediately, drop any pending
TTS buffer, and block late-arriving tool-use chunks from firing
resolvers after the fact.

This required explicit `Task.checkCancellation()` between every
streaming event and every tool round — Apple's `for try await` loops
do **not** throw `CancellationError` on `Task.cancel()` by default.

### Turn timeouts

- **30 s max turn**: `SFSpeechRecognizer` can silently stall in
  sustained noise. At 30 s we force-finalize whatever transcript
  exists.
- **3 s no-partial activity**: if the recognizer has gone 3 s without
  new partials but we have ≥ 4 characters captured, commit. Catches
  the case where ambient noise keeps VAD alive but actual speech
  stopped.
- **1.2 s end-of-turn silence** (primary): VAD-triggered after
  confirmed voice.

---

## What the assistant will not do

### Data honesty

The system prompt has hard rules forbidding fabrication:

- "Use ONLY numbers from tool results or the data context. If a value
  isn't present, say so — never invent a plausible-sounding number."
- "When a tool returns `status: missing`, respond with a brief
  acknowledgment and stop. Do not speculate, do not pivot to a
  related metric, do not volunteer a protocol."
- "Never deny a claim the user makes about something you said. If
  the user says 'you told me X', ask what they saw — don't flat-deny."
- "If the app doesn't have a capability (analyzing a map, reading a
  photo), say so ONCE and stop. Do not promise future updates will
  help."

### Sports-science framing rules

Three additional system-prompt rules govern how the AI talks about
training-load metrics:

- **Translate jargon, don't recite it.** ACWR, TRIMP, TSB, CTL, ATL,
  SDNN, RMSSD, DFA α1, monotony, strain — these abbreviations belong in
  the AI's reasoning, not in its answer to the user. Say "your recent
  training is above your usual range" instead of "ACWR is 1.42." Direct
  user requests for an abbreviation by name ("what's my ACWR?") are
  still honoured — that's an explicit ask.
- **Recovery-score architecture (v3.oct2026).** The score is HRV (60%) +
  Sleep (25%) + Vitals (15%). Training load is NOT in it — never tell
  the user the score "penalised them for high training load." Heavy
  training shows up via its downstream effect on HRV, not as a separate
  term. When the user asks "why didn't training move my score?", explain
  that the architecture intentionally trusts HRV to tell us whether the
  body absorbed the work, rather than counting the workout twice.
- **No risk-prediction framings.** Never tell the user a number "predicts
  injury," sits in an "advisory zone," or indicates "danger." Those
  framings are retired. Describe what's observed (above
  usual range, below usual range, sharp recent increase) and let the
  user decide what to do.

These are prompt rules, not hard code gates. The model will still
occasionally hallucinate or pivot. When it does, calling it out
("that's not what I asked" / "where did you get that number?") is
the right move; the prompt tells it to acknowledge rather than deny.

### Voice-mode brevity

When the send comes from voice, an extra overlay gets appended:
"1–3 sentences, no markdown, no headers, no numbered lists. Plain
spoken prose only." The model still occasionally produces a
numbered list; it's still tuning.

### Always-on brevity (2026-04-29)

The base persona has a stricter `BREVITY` block that applies to ALL
sends (typed and voice):

- Lead with the answer. The first sentence MUST contain the
  headline number. "RMSSD 48 ms today vs 41 ms yesterday — up 17 %."
- 1–3 sentences for "how am I doing" / "vs yesterday" / "what's my X"
  questions.
- NEVER emit `<data>...</data>` blocks, "let me check", "looking at
  your data", "first I'll fetch", or any other reasoning preamble.

The toolOverlay's "Extract before you answer" rule used to literally
say "Quote the raw values back to yourself in `<data>...</data>`
tags" — which the model interpreted as permission to emit those tags
into the visible reply, producing the verbose preamble users
complained about. Replaced with "Extract silently, then answer. The
first sentence of your visible reply IS the answer."

---

## Known failure modes

### Barge-in misses

- Speech below about −35 dBFS (`bargeInRMSThreshold`) won't trigger gate 2 even with
  recognized words. Bump your speaking volume or tap **Send now**.
- A single emphatic word ("stop!") won't interrupt because gate 3
  requires two. This is a conscious trade — single-word gates were
  constantly false-triggering on coughs.

### Barge-in false positives

- On phone speaker (no AirPods) the TTS leakage is louder; gate 4
  Jaccard echo detection helps but occasionally lets the AI's own
  words register as "new speech." Result: the AI cuts itself off
  mid-sentence. If this happens often, use AirPods.

### Tool-use accuracy

- Anthropic and OpenAI models tend to call tools correctly. DeepSeek
  and Gemini are less field-tested for our catalog. If one of them
  starts inventing values, switch to Claude Haiku for the same
  question and compare.
- Parameterized tools (e.g., `session_by_date`) require the model to
  pass a properly-formatted arg. If the model sends `{"date":"yesterday"}`
  the resolver returns missing — the model should retry with the ISO
  form. Most do; some need a nudge ("try again with yyyy-mm-dd").

### Provider pinning

- The Anthropic Haiku 4.5 model is pinned to a dated version
  (`claude-haiku-4-5-20251001`). Sonnet 4.6 and Opus 4.7 are still
  floating aliases, which means Anthropic can silently repoint them
  and invalidate prompt caches. Dated IDs will replace them once
  confirmed.
- OpenAI / Gemini / DeepSeek / Grok model IDs are not pinned yet.
  Same risk — they could be repointed at any time.

### Apple on-device limitations

- Apple's safety filter occasionally refuses health-adjacent questions.
  That's Apple's call, not ours. Switch to Claude or ChatGPT for
  those.
- Apple now gets tool use, so it can answer
  per-workout, per-date, route, and breadcrumb queries on-device.
  The 4K context ceiling still bites: very long conversations get
  oldest turns dropped verbatim by `AppleContextCompactor` once the
  transcript hits 70% of the budget. If a long historical analysis
  needs the full transcript, switch to a cloud model.
- Apple's reasoning depth is below cloud frontier models. Multi-week
  trend reasoning ("compare this month to last month") is one of the
  capability axes that drives the classifier toward `.auto` or
  `.deep` exactly so questions like that don't land on Apple.

### Hallucinations we've actually observed

- Sleep efficiency rendered as "9592 %" was a unit-scaling bug in the
  data path, not a model failure — fixed in this release. But it's a
  good reminder that data-layer bugs look like AI bugs when they
  surface through the AI.
- Score values flipping between turns without acknowledgment — the
  turn-to-turn consistency rule in the prompt is supposed to catch
  this but models still slip.
- "Analyzing the map" — the model knows it can't, but sometimes still
  offers to "look at it after your next lap." The prompt tells it not
  to; compliance is ~90 %.

When you catch one, tell the assistant directly. The prompt's rules
are designed to respect user-reported observations.

---

## Files that matter

| What | Where |
| --- | --- |
| Fact catalog tools + resolver | [`Emuqu/Sources/Assistant/Facts/FactCatalog.swift`](../Emuqu/Sources/Assistant/Facts/FactCatalog.swift), [`Emuqu/Sources/Assistant/Facts/AppFactResolver.swift`](../Emuqu/Sources/Assistant/Facts/AppFactResolver.swift) |
| Tool schema → provider body | [`Emuqu/Sources/Assistant/Providers/AnthropicProvider.swift`](../Emuqu/Sources/Assistant/Providers/AnthropicProvider.swift), [`Emuqu/Sources/Assistant/Providers/OpenAICompatibleStreamer.swift`](../Emuqu/Sources/Assistant/Providers/OpenAICompatibleStreamer.swift), [`Emuqu/Sources/Assistant/Providers/GeminiProvider.swift`](../Emuqu/Sources/Assistant/Providers/GeminiProvider.swift) |
| Apple Tool adapter + dispatcher | [`Emuqu/Sources/Assistant/Providers/AppleFoundationToolAdapter.swift`](../Emuqu/Sources/Assistant/Providers/AppleFoundationToolAdapter.swift), [`Emuqu/Sources/Assistant/Providers/AppleToolDispatcher.swift`](../Emuqu/Sources/Assistant/Providers/AppleToolDispatcher.swift) |
| Apple session cache + tool wiring | [`Emuqu/Sources/Assistant/Providers/AppleFoundationProvider.swift`](../Emuqu/Sources/Assistant/Providers/AppleFoundationProvider.swift) |
| Apple 4K context compaction | [`Emuqu/Sources/Assistant/Facts/AppleContextCompactor.swift`](../Emuqu/Sources/Assistant/Facts/AppleContextCompactor.swift) |
| Capability-axis classifier | [`Emuqu/Sources/Assistant/Facts/CapabilityClassifier.swift`](../Emuqu/Sources/Assistant/Facts/CapabilityClassifier.swift) |
| Deterministic intent shortcut | [`Emuqu/Sources/Assistant/Facts/DeterministicIntent.swift`](../Emuqu/Sources/Assistant/Facts/DeterministicIntent.swift) |
| Tier router + session stickiness | [`Emuqu/Sources/Assistant/Facts/SmartProviderRouter.swift`](../Emuqu/Sources/Assistant/Facts/SmartProviderRouter.swift) |
| Tier → (provider, model) mapping | [`Emuqu/Sources/Assistant/Facts/TierProviderMapper.swift`](../Emuqu/Sources/Assistant/Facts/TierProviderMapper.swift) |
| Cache-hit telemetry surface | [`Emuqu/Sources/Assistant/Facts/LLMCacheTelemetry.swift`](../Emuqu/Sources/Assistant/Facts/LLMCacheTelemetry.swift) |
| Dispatch loop + voice bypass + budget + cancel | [`Emuqu/Sources/Assistant/ViewModel/AssistantViewModel.swift`](../Emuqu/Sources/Assistant/ViewModel/AssistantViewModel.swift) |
| Audio session + gates + PTT + earcon | [`VoiceConversationController.swift`](../Emuqu/Sources/Assistant/VoiceConversationController.swift) |
| System-prompt overlays | [`Emuqu/Sources/Assistant/Providers/AIProvider.swift`](../Emuqu/Sources/Assistant/Providers/AIProvider.swift) |
| Coding standard the code follows | [`REFACTOR_SPEC.md`](REFACTOR_SPEC.md) |

---

## Status

**Routing & cache strategy items live:**

- Capability-axis classifier replaces length/complexity prototypes
  (4 axes × keyword-gated embedding ≥ 0.55 threshold per axis)
- Routing (Quick / Auto / Deep) acts only while Apple is the selected
  model; any other pick answers every turn
- Voice-mode bypass — with Apple selected, voice → first consented
  cloud provider, no per-turn re-routing; stays on Apple when none is
  consented
- Apple Intelligence wired to `LanguageModelSession(tools:)` via
  `AppleFoundationToolAdapter` + `AppleToolDispatcher.shared` —
  same `FactValue.toToolResultJSON()` envelope cloud providers see
- Verbatim 70%-of-4K context compaction
  (`AppleContextCompactor`) on Apple Foundation session input
- Deterministic intent shortcut for 14 common voice patterns
  ($0 cost, <50 ms, on-device)
- "Flo here. Sonnet." earcon naming the active model
- LLM cache-hit telemetry across the cloud providers (Apple is
  on-device and has no prompt cache; Grok reports none), surfaced in
  Settings → Troubleshooting → AI cache health
- `<live_state>` block moved from system role to last-user-tail to
  protect cached prefix from invalidation (ProjectDiscovery
  7%→74% hit-rate pattern)
- Anthropic prompt-cache breakpoints on last tool definition (1h
  TTL) + system prompt + conversation history
- Sorted-keys JSON across every provider serialiser to keep the
  cached prefix byte-identical across sends

**Voice MVP items live:**

- Four-gate barge-in (grace, RMS, words, echo)
- Tool use with deterministic schema serialization
- Interrupt cancellation including late-chunk drops
- Streaming glitch prevention (pre-tool-use text rewind)
- 8-call tool budget per turn (`maxToolCallsPerTurn`)
- 30 s max-turn and 3 s no-activity safety timeouts
- Push-to-talk fallback
- Recogniser auto-restart on 1110 / 301 with cooldown
- **First-partial 5 s watchdog** — recogniser restart if no partial
  arrives despite detected voice.
- **45 s long-idle restart** — pre-empt SFSpeechRecognizer's silent
  self-termination.
- **Full audio-engine restart per turn** — stops-resets-restarts the
  engine on every `beginUserTurn()` so iOS's post-TTS mic feedback-
  protection mute can't persist across turns.
- **Per-error diagnostic enrichment** — `buffers`, `peakRMS`,
  `engine`, `route`, `state` attached to every recogniser warning in
  the error catalog for field diagnosis.

**AI-exposure MVP items live:**

- `MissingReason` enum + structured tool-result envelope
  (`value`, `missingReason`, `detail`, `asOf`, `confidence`)
- `Availability` closure gates entries from the schema when the user
  has no data; `validRange` start inlined into parameter descriptions
  at month granularity
- `.composite` FactEntry case with partial-data envelope
  (`{present, missing}`) + 5 initial composites
  (user.profile.snapshot, training.load.snapshot, walks.summary,
  recovery.today.full, recovery.week.summary)
- Rate limiter: 3rd consecutive missing (key, args) returns
  `.rateLimited` to break retry loops
- Output-size cap: 80 KB per-response, returns `.tooMuchData` on
  overshoot
- Resolver timeouts: wall-clock 2 s budget, `.internalError` on
  overshoot, warning log on >0.5 s
- Catalog version hash (SHA-256 of sorted-keys serialised schema)
- Cache-hit telemetry across all cache-capable cloud providers (Anthropic
  cache_read/creation, OpenAI prompt_tokens_details.cached_tokens,
  DeepSeek prompt_cache_hit_tokens, Gemini cachedContentTokenCount; Apple
  on-device and Grok report no cache)
- Byte-identity check: per-send schema hash logged; warning on drift
- CI catalog-validation suite: 8 tests (no duplicate tool names,
  parameterised entries have valid placeholders, composite deps
  resolve to real atomics, composites never depend on composites,
  availability closures run <50 ms, deterministic schema serialisation,
  tool names match provider name constraints, all tools have
  descriptions)

**Catalog coverage (the "AI aware of everything" ask):**

The catalog now covers every user-visible data surface:

- `user.*` — profile (max HR, resting HR, LTHR, weight, sex, age,
  units, typical sleep), app capabilities
- `session.*` — workouts (latest, by date, by ordinal, by id with
  full record)
- `sleep.*` — sleep sessions (latest, by date, recent N)
- `hrv.*` — HRV analyses (latest, by date, recent N — RMSSD, SDNN,
  pNN50, mean/min/max HR, LF/HF power, stress, readiness)
- `vitals.*` — respiratory rate, SpO2, wrist temperature, resting
  HR (latest + by date, with status classification)
- `recovery.*` — recovery score (latest, by date, recent N)
- `walks.*` — workout aggregates (count, distance, TRIMP, hardest,
  list per period)
- `training.*` — CTL, ATL, TSB, ACWR, composite snapshot
- `composites` — aggregated multi-call queries

**2026-08 — closed four "computed but never exposed" gaps** (facts that
the app showed on its own screens but had no catalog key for, so the model
could only guess or deny):

- **Load & Trajectory** — `training.trajectory` (via `get_training_load`
  `which:'trajectory'`): the trajectory verdict (building / detraining /
  high-strain / …), ramp band + rate, form descriptor (Fresh/Held/Working/
  Tired), and Foster monotony/strain. Assembled from the SAME inputs as the
  dashboard chip so the AI and UI can't disagree.
- **Sleep science** — `sleep.latest` / `by_date` / `recent` now include
  `fragmentation_index`, `awakening_count`, `sleep_cycles`,
  `architecture_score`, `deep_front_loaded`, `rem_back_loaded`,
  `enhanced_sleep_score`, and age-adjusted range flags (SleepScienceAnalyzer).
- **Morning subjective + score internals** — `recovery.score.*` now include
  `morning_feeling` (1–5) + `morning_feeling_tags`, `notes`,
  `training_readiness`, `data_quality` (good/preSleep/insufficient — so the
  AI can caveat a poor reading), and `perceived_readiness`.
- **Live HealthKit fallback for sleep + overnight vitals** — `sleep.latest`
  and `vitals.latest` are now async: when the frozen `sleepSnapshot` /
  `vitalsSnapshot` is nil (the night hasn't been accepted, or the Watch synced
  sleep/vitals AFTER acceptance), the resolver reads the value LIVE from
  HealthKit (5 s timeout, cache-warm by morning via the sleep observer) and
  tags it `data_source=live_healthkit_pending_acceptance`. This closes the
  "the AI doesn't know anything about my sleep last night" gap — the app's own
  HealthKit truth answers even before the morning results are opened, instead
  of returning `.missing`.

Three areas that look missing from a grep of top-level keys are **already**
covered as record *fields* in the serialized record: nonlinear/ANS
HRV (`dfa_alpha1`, `sd1/sd2`, entropy, `pns/sns_index`, nocturnal dip, nadir)
in `get_hrv`; advanced per-session workout metrics (`vam_m_per_hr`,
`grade_adjusted_pace_sec_per_km`, `efficiency_factor`, `decoupling_percent`,
`dominant_hr_zone`) in `get_workout`; and per-metric trends with slopes in
`recovery.trend`. The stale "Capabilities the app does NOT have" list in
`AppKnowledgeBase` was also trimmed — it had been telling the model the app
can't do Stryd/foot-pod power, cycling power, custom intervals, or route
loading, all of which ship (and have tools), which made the AI deny real
features. The tool catalog is the source of truth for that list now.

Date-parameterised lookups use the midpoint-in-day rule so "Tuesday's
sleep" matches the session whose midpoint falls in that local day
(covers overnight sessions that cross midnight).

**Deferred (post-MVP):**

- Adaptive silence thresholds + whisper half-weight sampling
- Filler-timing state machine for chained tool calls
- Parallel-tool-call benchmark + client-side batching fallback
- Deferred namespaces / native `tool_search`
- `CatalogMetadataCache` actor + `MetadataCoordinator` invalidation
  pipeline (metadata sources don't emit the events this would react
  to yet; SchemaBuilder runs inline per send today)
- `PromptEnvelopeAdapter` protocol refactor (current per-provider
  code already enforces sorted-keys serialisation and the prefix
  shape; adapter abstraction is documentation not capability)

When a deferred item causes real trouble in use, reopen the spec and
promote it.
