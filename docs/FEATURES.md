# Emuqu — feature reference

The complete feature list, kept out of the README so the README can say what the
project is in one screen. For how each feature is built, start with [`MAINTAINERS.md`](MAINTAINERS.md).

## Key Features

### Recovery Dashboard
- **Research-Informed Recovery Score** (calibrated, not outcome-validated — see the methodology page) — Composite 0-100 score from **HRV (60%) + Sleep (25%) + Vitals (15%)** with ln(RMSSD) z-score normalization against your personal 60-day baseline (SWC band model). Training load is shown on the parallel Load & Trajectory page but does not feed the recovery score (Impellizzeri 2020/2021, Doherty/Altini 2025; see Settings → About → "How Emuqu scores recovery")
- **Three-Tier Scoring** — Automatically uses the best available data: HRV-only (Tier 1, cold start), HRV + Sleep (Tier 2, no overnight vitals data), or HRV + Sleep + Vitals (Tier 3, full-signal day)
- **Vitals factor** — Overnight heart rate, respiratory rate, and wrist temperature each contribute to the 15% Vitals sub-score. They can shift on nights when HRV does not. Missing inputs are dropped — the average is over what's available, not penalised for what isn't
- **Comeback mode** — 21-day toggle for returning from illness or injury. A score that includes vitals shifts to HRV 80% / Sleep 20% / Vitals 0% so noisy post-illness vitals don't drag your number down while HRV recovers
- **Cold-start confidence pips** — ●○○ → ●●○ → ●●● next to the score so you know whether you're on a partial baseline (nights 0–13, before the Dashboard shows the score), provisional baseline (14–27), or the full algorithm (28+)
- **Feeling chip** — Below the score, how you said you felt this morning ("Tap how you feel" if you skipped it). Tap to change it. Saved on that night's session, synced with it, and readable by Flo
- **Score-Based Window Ranking** — Among organized-recovery windows, the chosen window is the one with the best Tier-1 score, not just the highest raw RMSSD
- **Frozen Historical Scores** — Once scored, a session's score doesn't drift as baselines shift later
- **Training Readiness** — Embedded gauge bar (Rest / Fatigued / Moderate / Ready) showing your readiness to train, derived from a training-load base and modulated by your recovery score; copy describes recent load in plain "above your usual range" terms rather than reciting ACWR by name
- **Drill-In Detail Views** — Tap any chip (HRV, Sleep, Vitals, Load) for deep-dive analysis with Kubios-style metrics grids
- **Smart Recommendations** — Coaching-style, factor-aware guidance based on your current state
- **Trend Indicators** — Visual comparison to your personal baselines
- **Pre-Score Morning Feeling** — 1–5 self-rating asked before the score is revealed (so the answer isn't anchored to the number); editable from the dashboard afterward
- **Body & Mind Feeling Tags** — On low-feeling mornings, optional tags (illness, stress, hangover, allergies, etc.) route the morning narrative to specific advice
- **Divergence Detection** — When subjective feeling disagrees with HRV by more than one category, the morning narrative flags it
- **Methodology page** — Settings → About → "How Emuqu scores recovery" — plain-English explanation of what's measured, what isn't, and the literature behind each weight
- **✨ Ask Flo Menu** — Top-right toolbar shortcut to common AI questions (auto-sends and switches to the Flo tab)

### Advanced HRV Analysis
- **Time Domain Metrics** — RMSSD, SDNN, pNN50, Mean RR
- **Frequency Domain** — LF and HF power and their ratio, reported as measurements rather than read as "autonomic balance"
- **Nonlinear Analysis** — DFA α1 (log-spaced box sizes per Peng et al. 1995), Poincaré SD1/SD2
- **Artifact Detection** — Automatic identification and handling of ectopic beats
- **Manual Window Selection** — Tap anywhere on the HRV chart to analyze a custom window and compare it side-by-side with the algorithm's pick

### Training Load (Load & Trajectory page — does NOT feed the recovery score)
- **Acute/Chronic Workload** — ATL, CTL, and TSB calculations shown as Strava-style fitness/fatigue/form curves
- **Acute:Chronic Ratio** — Gauge labelled descriptively (Below your usual / Maintenance / In range / Above your usual / Sharp increase) with graded modifiers rather than hard cutoffs. Per Impellizzeri 2020/2021 the ratio's signal value for predicting injury is weaker than the original Gabbett framing claimed, so Emuqu shows it as descriptive load-range context — never as an injury predictor
- **Foster's Monotony & Strain** — Surfaces a banner when monotony >2.0 and weekly load is meaningfully heavy ("Your training has been unusually similar day-to-day this week"). Observational only; not a score component
- **Banister TRIMP** — Continuous, sex-dependent exponential integration on heart-rate reserve (Banister 1991). Male users get `0.64 × e^(1.92·HRR)`, female users get `0.86 × e^(1.67·HRR)` per the canonical literature. Anchored to your configured max HR, resting HR, and LTHR rather than session peak — so the same walk scores consistently across sessions regardless of conditions
- **HRSS-style hrTSS** — session TRIMP ÷ 1-hour-at-LTHR TRIMP × 100, the definitionally correct formulation ("1 hour at threshold = 100 points")
- **Frozen Training Context** — Training metrics captured at session time for historical accuracy

### Fitness Tab (Workouts)
- **Live Workout Recording** — Run, Trail Run, Walk, Hike, Ride, Indoor Ride, Treadmill, Row, Air Bike, CrossFit. Strap / Apple Watch / none HR sources. GPS + pedometer + foot-pod / power-meter integration.
- **Auto-pairing on workout start** — Tap Start and the app reconnects whatever you've previously paired: Polar strap (H10 / Verity Sense) and Stryd footpod fire `connectToLastDevice` / `reconnectLast` in parallel so you don't have to dig through Settings every session. Strap auto-disconnects after the post-workout HRR window completes (saves H10 battery); footpod disconnects the moment the workout ends. Indoor / no-strap workouts proceed without HR rather than blocking the start.
- **Get Me Back mode** — Offline breadcrumb-and-arrow trail recovery. Tap "Get Me Back" on the Fitness tab to drop a pin where you start; the app captures fixes every 30 s OR 25 m of movement (lower-power than the workout recorder, ~30% less radio time on a 6-hour hike). Tap "Open" later to see a compass arrow physically pointing back to the origin — magnetic compass driven, holds the phone-flat / rotate-body navigation pattern. Honest accuracy display: arrow visually fuzzes when GPS is poor, disappears entirely above 100 m with "Wait for a better fix" — never projects false confidence. Survives crash, kill, day rollover (atomic JSON write on every fix). Brightness slider, "Talk to AI" button (the AI sees `breadcrumb.active` so it can reason about the trail), Emergency SOS deep-link.
- **Multi-trail breadcrumb history** — Active trail + an archive of up to 50 completed trails. **Every GPS-bearing workout auto-archives its track as a breadcrumb trail** ("Run on Apr 29, 8:13 AM") so the AI's `directions.routeTo origin` can lead you back to the parking lot of your morning run even if you never explicitly engaged Get Me Back.
- **Stryd Power (run) + FTMS Bike Power + Concept2 PM5 Rower** — Stryd foot pods stream running power over BLE RSC; FTMS-spec bike trainers (Wahoo Kickr, Tacx, Saris) stream cycling power over `0x1826`; the Concept2 PM5 streams stroke rate, distance, drag factor, and per-stroke power over the PM5 Rowing service. All three feed the same recording pipeline.
- **Power-TSS / NP / IF / Variability** — Set running and cycling FTP separately in Settings → Biometrics. The post-summary hero card surfaces Coggan-style Normalised Power, Intensity Factor, Power-TSS (`(NP/FTP)² × hours × 100`), and Variability Index alongside HR-based hrTSS so power-meter users see their real session load.
- **Threshold-triggered ambient AI coach** — Pre-declare physiological constraints before starting ("HR > 135 for 30s", "stay above zone 2 power", "pace below 9:00/mi"). The coach stays silent — your audiobook keeps playing — and only ducks in when a threshold breaches past its debounce. Each threshold carries its own debounce + cooldown so it never nags. HR / HR-zone / power / power-%FTP / pace / DFA α1 / cadence are all supported.
- **Route library + route-aware coaching** — After any GPS workout, "Add to my route library" lets you name it ("Daily 1", "Long loop"). Next time the app sees you running it — in either direction — the AI coach recognises it by name and gets full topography: the next 5 climbs ahead with length + grade + gain (each tagged with the **reverse-geocoded street name** so the coach says "the climb on Hill Rd in 0.4 miles" instead of "a climb ahead"), total ascent remaining, peak altitude, steepest grade still to come. Routes match direction-agnostically so the same physical loop run east-then-west on a single workout still maps to one saved entry. Settings → My Routes lists / renames / deletes.
- **Discover trails near you** — Fitness tab → Start Workout → "Discover trails near me" searches OpenStreetMap (free, no key, global) for hiking / mountain biking / road cycling trails in a configurable radius. Filter by length and difficulty (Easy / Moderate / Hard / Expert, collapsed from OSM's `sac_scale` and `mtb:scale` tags). Each result has a map preview + difficulty badge + distance from you. Picking one binds it as today's route AND saves it to your library so the road-name enrichment fires before you start.
- **Live road context for the AI** — Reverse geocoding via Apple's `CLGeocoder` populates the AI with current street name, locality, state, country after ~15 m of movement or 60 s, whichever comes first (free, Apple's geocoding service, rate-limit-aware; backs off after 8 failures in a row). A second-stage `MKLocalSearch` resolves the **nearest cross street** so the AI can say "you're on Main St near 1st Ave" — real intersections, not coordinates. Heading (cardinal + degrees) and speed are surfaced too. An always-on `AmbientLocationService` keeps the cache fresh in the foreground when no workout is active; during a backgrounded workout the workout recorder feeds the same cache. The coach answers "where am I" instantly — no more 30-second cold-fetch timeouts.
- **Live weather context** — Current temperature, wind speed + direction, humidity, and conditions (Clear / Overcast / Light rain / etc.) are pulled from MET Norway's forecast API (no API key, global, CC BY 4.0) and refreshed every 30 minutes during the workout, then handed to the AI coach so it can make weather-aware suggestions ("you're already 80 % VO2max in 92 °F heat, ease back").
- **Zwift / TrainerRoad / Rouvy broadcaster** — Optional Settings toggle turns Emuqu into a standard BLE peripheral advertising Heart Rate Service (`0x180D`) and Cycling Power Service (`0x1818`). Lets a user who's already paired their strap + Stryd / bike trainer to Emuqu share that data with their indoor-trainer game without re-pairing each device. Off by default.
- **Dashboard hero card** — Tap-anywhere tile for the latest workout. Big distance, duration + pace, mini GPS polyline trace, scrollable badge row (peak HR / elevation / α1 / TRIMP / hrTSS). Refreshes when the archive changes.
- **Pro-grade barometric elevation** — New recordings capture every `CMAltimeter` sample into a buffer at native 1 Hz, then run a symmetric 15-sample moving-average smoother at session finalize and count a climb or descent once a same-direction run on the smoothed signal reaches 2 m (sports-biomechanics sensor-fusion best practice per Barczyk & Nemra 2014, PMC4179067). Produces numbers consistent with iSmoothRun / Apple Fitness / FITIV — all reading the same barometer, now correctly signal-processed.
- **Topographic elevation lookup for pre-fix sessions** — A "Look up real elevation" action queries OpenTopoData USGS NED 10 m (US; SRTM 30 m international) with a 15 m sustained-climb threshold calibrated against barometric ground truth. Always an approximation vs the live barometer.
- **DFA α1 artifact filter** — Live α1 computation runs each window through a Kubios-style ectopic-beat filter with linear interpolation. Without it, raw RR artifacts inflated α1 toward Brownian (1.5-2.0) during exercise, masking real threshold crossings.
- **Re-analyze α1 for old sessions** — One-tap action regenerates α1 from the stored RR data using the current filter, so historical workouts get clean physiology numbers without re-recording.
- **Sport-aware cadence filter** — Walks cap at 125 spm, runs at 220, bikes at 140 RPM. Foot-pod spike artifacts beyond the sport's physiological ceiling are dropped.
- **Epic Correlated Post-Report** — α1 as the hero section (plain-English story, avg/max/min stats, timeline with AT1/AT2 reference lines), route map coloured by α1 band, threshold-crossings list, HR zone distribution with user-max-HR-anchored bands, derived metrics (moving time, VAM, grade-adjusted pace, calorie rate, stride length, power:HR ratio), decoupling, efficiency factor, splits (unit-aware, retroactively re-bucketed on preference mismatch).
- **α1-derived aerobic-threshold estimate** — the HR at which α1 crossed 0.75, which lab comparisons place within about ±10 bpm of the gas-exchange aerobic threshold (Rogers & Gronwald 2021 and later cohorts), surfaced as an aerobic-threshold reference. It is not your LTHR (LT1 sits well below it), so the app does not suggest replacing one with the other.
- **PDF Workout Report** — On-demand 5–6 page clinical report: Executive Summary → Autonomic / HRV (α1 timeline with AT1/AT2 reference lines) → Cardiopulmonary → Effort & Terrain with MKMapSnapshotter α1-band-coloured route (when GPS present) → Splits + HRR + Derived Metrics → Methodology & Citations. All charts downsampled to ≤ 400 points for fast rendering.
- **Voice Coach** — Rule-engine observations (α1 below AeT / above VT2, HR drift, zone-target drift, climb-ahead with grade + length + queue position, user-threshold breach, strap dropped) spoken over AirPods with long cooldowns. Silence is a feature. AI receives full live context each tick — wall-clock time, GPS position + heading, grade, α1 status, units preference, route topology when bound, current weather — so answers to "what's my pace?" / "where am I?" / "what's coming up?" / "is it raining?" use real numbers.
- **Heart Rate Recovery** — 1-min and 2-min HR drops captured in a 120 s post-stop window. Three-tier fallback (strap / Watch HR samples / HealthKit-computed). `stopStreaming()` is deferred until after the capture window so strap Tier-1 sampling actually runs. Strap auto-disconnects after the HRR window completes (regardless of voice-chat state — chat continues without live HR). Summary sheet refreshes when the detached task writes samples back.
- **Live α1 diagnostics** — if α1 isn't updating, the tile explicitly says why (warming up X%, strap silent Ns, fit failed).
- **Structured Interval Plans** — Pick a plan before starting; the coach announces each step as you hit it.
- **Unit-aware exports** — CSV, PDF fully imperial for imperial users (mi / ft / min-per-mi column headers). GPX / TCX stay spec-compliant metric in the payload (required by Strava / Garmin schemas) with human-readable imperial summaries in `<desc>` / `<Notes>`.

### Sleep Integration
- **Sleep Score** — Weighted quality assessment (0-100) from duration, efficiency, deep sleep, and REM, enhanced with sleep science analysis (fragmentation, cycles, architecture, age-adjusted norms) when stage data is available
- **Stage Analysis** — Deep, REM, core, and awake time breakdown
- **HRV Sleep Stage Classifier** — Full sleep stage classification from chest strap RR data when no Apple Watch is available. With a Watch, optional HRV-enhanced refinement catches stages the Watch misclassifies
- **Sleep Export to Apple Health** — On nights Apple Health has no sleep, write the sleep detected from heart rate as asleep and awake samples. Stages are estimates, so they are not written as deep, REM or core
- **Sleep Adjustment Timeline** — Tap "Adjust Sleep" to fine-tune session boundaries on a draggable timeline (replaces the older slider-based editor). Multi-segment nights show all segments with gap indicators; exclude any segment from totals
- **Sleep Refresh Bounded to Session Start** — Refreshing sleep no longer pulls in pre-recording data; stale baselines are penalized
- **Watch False-Positive Rejection** — Apple Watch sleep samples near recording start are rejected when HR data contradicts
- **Historical Session Protection** — Opening the app no longer rewrites historical sessions' sleep data
- **Recovery Vitals** — Respiratory rate, SpO2, wrist temperature (with baseline deviation), and resting HR integrated alongside sleep data
- **Custom Bedtime** — Set your schedule for accurate overnight windows and morning detection
- **Estimated Sleep When Apple Health Has None** — On a night Apple Health returns no sleep, the app estimates it from the overnight heart-rate drop: first in the strap's RR data, then in the Apple Watch's background heart rate. It is an on-device heuristic (adaptive HR threshold with smoothing and artifact guards), not a clinically validated staging model. Sleep after the strap comes off is not added to a night that already has sleep.
- **Rescore on Manual Sleep Refresh** — adjusting boundaries triggers an automatic recovery score recompute
- **Recovery Correlation** — How sleep impacts your HRV trends

### Data Recording
- **Session-First Flow** — Choose Extended or Quick Reading before connecting to a device
- **Extended Recording** — Continuous RR capture during sleep with live heartbeat counter and hybrid recording (H10 internal memory + BLE streaming for maximum reliability)
- **Pause & Resume** — Pause overnight recording mid-night and resume later as linked segments with combined analysis across the full night
- **Split Sleep Settings** — Configurable merge gap (Off / Default 4.5h / Custom 1-12h) for multi-segment nights
- **Quick Readings** — 2, 3, or 5 minute spot-check measurements with live HRV preview
- **Breathing Voice Guide** — Spoken breathing cues synced to the mandala during quick readings (5.5 breaths/min coherence pattern)
- **Background Collection** — Silent audio playback keeps the app alive overnight; incremental RR backup every 5 minutes
- **Battery Warnings** — Low battery advisories and critical battery lockout before recording
- **Device Info Panel** — Battery level, estimated life, firmware version, memory status
- **Multi-Device Management** — Maintain a list of known Polar devices, switch between H10 and Verity Sense
- **Data Recovery** — Recover stranded data from H10 internal memory after app crashes or disconnections. Dashboard banner offers Resume / Save as is / **Dismiss** (the Dismiss path requires explicit confirmation because it discards the backed-up beats — Save as is keeps them).

### History & Trends
- **Session Archive** — Complete history with search, filtering, and score breakdowns, paginated for fast loading (10 sessions at a time)
- **Long-Press → Ask Flo About This Session** — Surface a session-specific question to Flo with one tap
- **Tag System** — 14 built-in system tags plus custom user-created tags for session categorization and pattern analysis
- **Trends** — 7 / 14 / 30 / 90-day or all-time view of overnight readings: a metric chart (Recovery, RMSSD, SDNN, Mean HR, Balance, HF Power, Stress), a stats grid against your baseline, insights, and a single-tag filter
- **Calendar** — Month grid shaded by daily training load, with a dot for each morning's self-rated feeling; tap a day to open its sessions
- **Organized-Recovery Window Overlay** — Green-shaded zone on overnight charts marks the window the algorithm pulled metrics from (visible on both fresh and pre-existing sessions)
- **PDF Reports** — Professional 3-page overnight-session reports (metrics summary, HRV charts — Poincaré/PSD/tachogram, full narrative analysis). Workouts generate a separate 5–6 page clinical report — see the Fitness Tab section above.
- **Data Import** — Import RR data from CSV, JSON, TXT, Kubios, and EliteHRV formats
- **Export Options** — Share individual sessions or bulk export

### Flo — the AI Assistant
The chat tab is named **Flo** (not "AI Assistant" or "Coach"; the audible mid-workout trigger voice is what we now call **Coach**, and the auto-generated email goes out as a **Flo Report** — three subsystems, one model picker, distinct chat-bubble badges).

- **Six AI Providers** — Apple Intelligence (free, on-device, iOS 26+); bring-your-own-key for Claude, ChatGPT, Gemini, Grok, and DeepSeek
- **Adaptive Routing (Quick / Auto / Deep / Manual)** — only while Apple Intelligence is the selected model; with any other model selected, every turn goes to it and the picker in **Settings → Flo → AI routing** is disabled:
  - **Quick** — typed questions answered on-device by Apple Intelligence. May refuse complex multi-week analyses.
  - **Auto** — session-sticky. An on-device **capability-axis classifier** asks four binary questions of every message — does it need a tool, the web, historical depth, or speculation? — each gated by both a keyword marker AND embedding cosine ≥ 0.55. Zero flags → Apple. Any flag → consented xAI Grok, then DeepSeek; Apple if neither. Tier persists after 3 settling turns, with a **capability-clear escape**: clean lookups can drop back to Apple. Falls back to keyword markers on older OS. A daily cap of 50 top-tier turns guards against runaway spend.
  - **Deep** — every turn to the same consented Grok or DeepSeek model Auto uses; Apple when there is none.
  - **Manual** — every turn goes to whatever you picked in the model picker.

  In Quick, Auto and Deep, voice turns and requests Apple can't carry out (email, contacts, directions, saving or renaming a route, web search) go to the first cloud provider whose data-sharing notice you accepted; with none, they stay on Apple. When no cloud model is set up, every mode answers on Apple — the Settings page says so. Each assistant chat bubble carries a small **tier-indicator dot** below the model badge (sage = Apple/Quick, blue = Auto, purple = Deep) so you can see which tier handled which turn.
- **Voice keeps one model** — a continuous voice conversation stays on one model for the whole session so it doesn't drift between models mid-sentence. The earcon names the active model out loud: *"Flo here. Sonnet."* / *"Flo here. Apple."* / *"Flo here. Haiku."*
- **Deterministic intent shortcut** — ~30–50% of voice queries are routine factual lookups ("what's my recovery score?", "how did I sleep last night?", "what's my RHR?"). These short-circuit through a hand-curated 14-pattern catalog **without** an LLM call — zero tokens, ~50 ms, on-device. Anything ambiguous, parameterised, or in the speculation/medical/web band falls through to the LLM.
- **AFM prewarm** — when routing might land on Apple, the chat view-model fires `LanguageModelSession.prewarm()` on init at `.utility` priority so the KV-cache is resident before your first message. First-answer latency drops from ~1.5 s to ~300 ms on A17/M-series.
- **Cache-health card** — Settings → Troubleshooting → AI cache health surfaces cumulative + last-10-turn prompt-cache hit ratios per provider. All on-device — never sent off device.
- **Context-Aware Chat** — Every message gets your live recovery data, today's analysis, yesterday's session, baselines, 7-day and 30-day trends, training load, and the last 14 days as context (each workout listed with sport / duration / distance / pace / avg+max HR / TRIMP / hrTSS / decoupling / METs / kcal / elevation, plus 7-day and 30-day rollups). The fact catalog (~200 entries across 19 namespaces; see `docs/VOICE_AND_TOOL_USE.md`) covers HRV / sleep / vitals / training / workouts / live workout state (incl. road context, **nearest cross street + intersection**, **heading + cardinal + speed**, weather, route topology, threshold breach state, interval progress), Polar device + battery + recording-hours, paired sensors (Stryd / FTMS / PM5 / Zwift broadcast), saved-route library (read **and** rename / save mutations), **breadcrumb trails** (active + archived), **continuous turn-by-turn navigation**, **point-in-time HR fallback** (HealthKit's most recent sample when there's no live workout), assistant memory, and TZ-aware date facts.
- **AI Mutation Tools** — A small set of `[ACTION]` tools let you ask the AI to act on your data, not just read it: rename a saved route ("rename Daily 1 to Morning Loop"), save a recent workout to your library by name, follow a saved route, route to a destination, clear an active route, take a place you tell it as your location, stage an email draft, add or remove an email contact, add / remove / clear memory facts, and (when enabled) search the web. Strict prompt-overlay guardrails: explicit instruction only, no inference, mandatory verbal confirmation read-back.
- **Continuous turn-by-turn** — Ask the AI "lead me back to where I parked" / "navigate home" / "nearest hospital" and `directions.routeTo` builds an `MKDirections` walking route from your current position. Destinations: `origin` (breadcrumb origin), `home` (your saved Settings address), `parking` / `park` / `help` / `police` / `fire` (nearest via `MKLocalSearch`), or a typed address. Once engaged, `directions.next_step` answers "what's next" / "how far now" / "am I there yet" against your live position — sticky step index so GPS jitter can't bounce you backwards. `arrived` flag flips at 25 m from destination. `directions.clear` ends the session. Fully cached after the initial calculate() — subsequent step queries are <10 ms with no network round-trip.
- **Brevity rules** — System-prompt overlay forbids the model from emitting "let me check…", "looking at your data…", `<data>` extraction blocks, or any other reasoning preamble. First sentence of a reply IS the answer. 1–3 sentences for "how am I doing" / "vs yesterday" questions. Cut the spin, give the number.
- **Apple Intelligence speed-up** — `LanguageModelSession` is cached across messages keyed by instructions + tool-catalog hash (volatile timestamp lines stripped before hashing). Repeat questions in the same conversation reuse the warm session — no per-message warmup tax, no full transcript re-render. Rotates after 20 turns to bound KV-cache drift, on a fresh conversation start, or on a tool-list change. The transcript itself is **verbatim-compacted** at 70% of Apple's 4K window — oldest turn-pairs drop without summarisation so quoted preferences ("call me Sam", "I run 50 km/week") survive.
- **Optional Web Search (Tavily, or Anthropic on Claude)** — Off by default. When enabled in Settings → Flo, on Claude Anthropic runs the search and skips the excluded sites; with a free Tavily key set, the AI can search a curated whitelist of authority sources (PubMed, scholar.google, intervals.icu, fellrnr, Polar/Garmin/Stryd/Apple official docs, ACSM, Mayo, Cleveland Clinic) for questions on-device data can't answer. Hard prompt rules: never synthesise medical-protocol recommendations from search content, always cite source URLs in Markdown.
- **10 Pre-fab Questions** — Suggestion chips above the input ("How am I doing today?", "Why is my score what it is?", "Should I train hard today?", etc.)
- **Voice Input** — Speech is recognised on the iPhone where the language supports it, otherwise by Apple's speech recognition service
- **Cross-Session Memory** — Long-press → "Remember this" stores facts (e.g., "I'm prepping for a marathon") that inject into every future conversation across all providers. Optional auto-extraction toggle
- **Tappable Date Citations** — When the AI mentions a date that matches a session, tap to open a quick-view sheet
- **Markdown Rendering** — Bold, italic, lists, code, links all render properly
- **Streaming with Typing Indicator** — Tokens appear as they arrive; per-provider avatar shows during the wait
- **Token-Aware Truncation + Auto-Summarization** — Long conversations stay responsive; older turns get summarized into a context preamble rather than dropped
- **Anthropic Prompt Caching** — Repeat sends in a chat run at ~10% of the first-send cost
- **Dashboard ✨ Quick Actions** — One-tap shortcuts to common questions ("Why is my score this?", "Should I train today?", "What changed from yesterday?", plus an Open-Flo entry that just navigates without sending)
- **Regenerate, Copy, Remember this** — Long-press any chat bubble
- **Subsystem badges on chat bubbles** — Each assistant turn shows which subsystem produced it: **Flo** (sparkles, primary tint) for the chat tab, **Coach** (running figure, fitness accent) for mid-workout voice triggers, **Flo** (waveform) for hands-free voice conversation, **Flo Report** (envelope, secondary tint) for auto-generated daily emails. Voice subsystems also self-announce on their first utterance ("Flo here." / "Coach here.") so AirPods users can tell who's speaking.
- **Keychain Key Storage** — API keys live in iOS Keychain, encrypted, never synced to iCloud, scoped to this app
- **Privacy-First Disclaimer** — One-time disclosure spelling out which provider receives what data

### Localization
- **17 Languages** — English, Danish, German, Spanish, Finnish, French, Icelandic, Italian, Japanese, Korean, Norwegian Bokmål, Dutch, Portuguese (Brazil), Russian, Swedish, Simplified Chinese, and Arabic
- **Live Language Switching** — Change language instantly from Settings → Language without restarting
- **On-Device Narrative Translation** — Dynamically generated text (analysis summaries, coaching messages) translated in real time using Apple's Translation framework (iOS 18.0+)

### Customization
- **Color Themes** — Six accent color themes (Blue, Teal, Indigo, Purple, Rose, Orange) with light and dark mode variants
- **Appearance Modes** — Light, Dim, and Dark background themes
- **VoiceOver Accessibility** — Comprehensive screen reader support across all views with descriptive labels for charts, gauges, and interactive elements

### In-App Help
- **Searchable Help Center** — 12 categories of articles covering getting started, recording, scoring, sleep, training, vitals, HRV science, the AI Assistant, Get Me Back, your data, personalization, and app navigation
- **Age-Personalized Content** — Metric explanations adapt to your age with specific ranges, context, and actionable guidance
- **Complete Metrics Reference** — Every HRV metric explained with interpretation ranges and what-to-do advice

### Onboarding
- **Health Disclaimer first** — the full disclaimer, with the age confirmation, is agreed to before the wizard starts.
- **7-Page Wizard** — Welcome → Value Prop (3-card carousel) → Profile (birthday, biological sex, body weight; all optional) → Sensor (pair your Polar strap, "I'll do this later" skip) → **Apple Health** (dedicated permission-priming page; system sheet fires inline on the page's Connect button, so the auth prompt doesn't race the splash transition) → Backup (iCloud sync) → "You're In" (14-day calibration note + "Take a reading" / "Skip — show me around", fully localized).
- Every wizard page before "You're In" is skippable; core biometrics (max HR, resting HR, LTHR, body weight, **home address**) can be set or revised any time in Settings → Biometrics, and units in Settings → Profile → Units. The home address is optional — only used by Flo's "lead me home" routing — stored device-local + iCloud (same surface as the rest of your Settings).
- Health Disclaimer acceptance is device-local (not iCloud-synced) — restoring onto a new phone re-prompts.

### Apple Watch app
- **Phone-mirror + wrist controls** — The Watch companion (`EmuquWatch Watch App`) mirrors the live workout the iPhone is recording (HR, pace, elapsed, stats) and offers start / stop / pause controls on the wrist. The iPhone owns the Polar strap and the canonical workout record; the Watch relays over `WatchConnectivity`. An opt-in path lets the Watch connect directly to a standard HR-profile strap via CoreBluetooth (`WatchStrapConnector`).
- **Build status** — Embedded in the iOS build, so installing the app installs the Watch app on a paired watch. See `docs/ARCHITECTURE.md` → "Apple Watch app".

> **No home-screen widget / Live Activity.**

## App Navigation

Emuqu uses a 5-tab layout. **Trends**, **Settings**, **Help & Learn** and **About Emuqu** live one level deep under **More**; **History** opens from **View all** on the Dashboard's Recent strip:

| Tab | Description |
|-----|-------------|
| **Dashboard** | Recovery score (HRV/Sleep/Vitals 60/25/15 with cold-start pips), Today's Loop narrative, feeling chip, HRV/Sleep/Vitals/Load chips, the Recent strip (into History), and the ✨ Ask Flo menu |
| **Record** | Session type selection, device connection, recording controls, and data recovery |
| **Fitness** | Live workout recording (run / ride / walk / hike / row), GPS + barometric elevation, live DFA α1, post-workout summary with PDF report |
| **Flo ✨** | In-app chat with the assistant — Apple Intelligence by default, BYOK for Claude / ChatGPT / Gemini / Grok / DeepSeek, with Quick / Auto / Deep / Manual adaptive routing |
| **More** | Trends (charts, stats grid, calendar), Settings, Help & Learn, About Emuqu, and the purchase screen until you've bought the app |

Two of the five tabs hide on demand:

- **Hide Fitness tab** (Settings → Training, or Settings → Performance & Battery) — recovery-only / HRV-only users get a cleaner 4-tab bar with no workout surfaces.
- **Turn off Flo** (Settings → Performance & Battery → AI Assistant, applied on next launch) — the chat tab disappears entirely; the chat ViewModel, provider registry, and Flo inbox skip work when the tab isn't accessible.

When both are hidden, the tab bar collapses to **Dashboard / Record / More** (3 tabs).
