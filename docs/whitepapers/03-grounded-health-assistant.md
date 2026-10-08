# EMUQU — A Measurement-Grounded Assistant with a Multilingual Regulated-Claim Perimeter

**Typed fact catalogue, runtime number verification, and one 17-language vocabulary enforced at input, output and build time**

Technical White Paper • v1.1

v1.1 (2026-10-08): adds prior-art comparison, independent validation, and full provenance.

October 2026

Chris Sharp

Describes Emuqu at source revision e028039 (2026-10-07); scoring version v3.1.oct2026.

---

## Executive Summary

Emuqu is an iOS heart-rate-variability and training app with a conversational coach ("Flo") that can run on six language-model providers: five hosted (Anthropic, OpenAI, Google Gemini, xAI Grok, DeepSeek) and one on-device (Apple Intelligence). Two problems dominate an assistant of this kind. First, it must quote the user's own measurements correctly. A model that says "your TSB is −29" while the dashboard shows −15.5 is wrong in a way the user can check. Second, it must stay inside a wellness perimeter in every language the app ships. That means no naming of a condition for the user, no rhythm assessment, no treatment or dosing, and no categorical certainty about physiological state. The user must also not be left without help when they report an emergency, an injury or thoughts of self-harm.

This paper describes the methods Emuqu uses for both problems, in enough detail to reimplement them:

1. **A typed fact catalogue.** Every fact the model can read is one declarative entry. The entry binds a key grammar, a description, a value type, an availability check and the resolver closure, so a resolver cannot exist unless it is also published. Results come back in a single JSON envelope with a closed, nine-value absence taxonomy. The same envelope is used for all six providers.
2. **A compact tool layer.** 21 polymorphic read tools and 18 allow-listed action tools are drawn from the catalogue. They are sorted and de-duplicated so the bytes stay stable, and a capability index is generated from the same specification list.
3. **Runtime number verification.** Numeric claims about the value *now* are checked against app state with per-metric tolerances. Spelled-out numbers are normalised first. Only the claimed span is corrected, and the correction is fed into the next turn's prompt.
4. **Structural conflict resolution.** When the user contradicts cached numbers or states their own, the stale dashboard block is removed from the prompt rather than argued with.
5. **One multilingual regulated-claim lexicon.** The lexicon has 29 concepts in 17 languages. It drives three enforcement points: a pre-send input guard that answers locally with fixed, localized replies and never sends the turn to any provider; a sentence-level, negation-neutral output guard applied before text is displayed or spoken; and a build-time linter over Swift source and every locale of the string catalogues. A CI gate proves, using a witness string per pattern, that the runtime lexicon covers the build-time list.

What is new is the specific set of rules listed in Section 4, each stated with its closest public prior art and its earliest dated form. Function calling, retrieval, prompt caching, BM25 and regex filtering are prior art and are not claimed. So are three ideas that a prior-art search found already public: deriving a tool's schema, dispatch and enablement from one declaration (OpenAI Agents SDK [17]), verifying a model's numbers against structured values with a tolerance (Proof-Carrying Numbers [18]; US Patent 12,670,149 [19]), and screening a message for crisis language before any model sees it (for example Myra's published protocol [24]). The perimeter is lexical rather than semantic, and Section 5 lists its known gaps.

---

## 1. The Problem

### 1.1 Wrong numbers that look right

Large language models produce fluent text that can contradict their inputs. This is the failure the hallucination literature calls intrinsic or input-conflicting hallucination [1]. In a health-data assistant it shows up as concrete, checkable errors. In logs this app recorded, a model quoted training stress balance (TSB) values from −9 to −29 across turns while the dashboard showed one stable value. In voice mode, a model stated a heart rate of 72 bpm while the live value was 91. These errors come from several sources:

- **The model guesses instead of retrieving.** It answers from priors, or from a value in an earlier turn.
- **Several sources disagree.** Different tools return values computed at different times, for example a readiness snapshot frozen at workout start versus the current load. The model picks the wrong one.
- **Stale context.** A cached block in the prompt contradicts what the user has just said. Benchmarks of stale-premise rejection suggest prose instructions ("trust the user") are not reliable. This is why the method in 3.6 removes the stale block instead of instructing the model.
- **Spoken numbers.** In voice mode the model writes "negative thirty-one point seven", which no digit-matching check sees.

Retrieval-augmented generation [2] and tool use [3][4] reduce guessing, but they do not check what the model finally says. Post-hoc verification methods such as RARR [5] and FActScore [6] check claims against evidence using further model calls. That adds latency and cost and is not deterministic. Deterministic numeric checks are also published. Proof-Carrying Numbers binds each displayed number to a structured claim and verifies it against an authoritative source under a tolerance policy, failing closed; it relies on the model emitting claim-bound tokens [18]. US Patent 12,670,149 describes detecting and correcting inaccurate numeric comparisons in LLM responses [19]. Neither, as publicly described, parses free conversational text or spelled-out spoken numbers. For a streaming voice coach, a check has to run in milliseconds on each sentence of free text before it is spoken.

### 1.2 A regulated perimeter in seventeen languages

The app is a general-wellness product and not a medical device. US FDA general-wellness guidance [7] and App Store Review Guideline 1.4.1 [8] both turn on what the product claims. A model that tells a user "you may have atrial fibrillation" makes a claim the app cannot support. A model that tells a user in crisis to "see a doctor" without giving a crisis line fails them.

Known approaches have gaps for this case:

- **System-prompt rules** are ignored or truncated by some models, and can be overridden by injection [9].
- **Classifier guardrails** such as Llama Guard [10] or programmable rail frameworks such as NeMo Guardrails [11] need a model call or a server-side runtime. Llama Guard 3 covers eight languages, and its categories include Specialized Advice and Self-Harm [22]. That is a general safety taxonomy, not a regulated-claim vocabulary. NeMo Guardrails can run output rails on streamed chunks before they reach the client [23], but on a server, not on the iPhone between token arrival and speech.
- **English-only keyword lists** fail silently. The app ships 16 non-English localizations, and the assistant answers in the user's language. Before the shared lexicon existed, the input guard knew 2 patterns, the output guard 12 and the build-time list 21, all in English, with nothing reconciling them.
- **Negation handling** (NegEx [12] and successors) is designed for clinical notes in one language. It is not robust to sentence-final negation in Japanese and Korean or to split negation in French. A missed negation lets a claim through.
- **Static copy and model output are governed separately.** A term forbidden in static copy can still be said by the model, and the reverse.

---

## 2. Architecture Overview

Table 1 shows one user turn on the text path. The voice path is the same up to the provider call. After that, each speakable chunk goes through steps 10 and 11 before speech.

**Table 1. Turn pipeline**

| Phase | Operation | Purpose |
|---|---|---|
| 1 | Trim input; reject empty | — |
| 2 | **Input guard**: classify the current message against the lexicon's refuse groups in safety order | Answer emergencies, injuries, self-harm and rhythm questions locally; nothing is sent |
| 3 | Consent check for the active hosted provider | No health data goes to a provider the user has not consented to |
| 4 | History assembly: drop `localOnly` turns, truncate to the provider budget, summarise dropped turns | Guarded turns never leave the device on a later send |
| 5 | Build or reuse the fact registry; reset per-turn rate-limit counters | One address space for all facts |
| 6 | Compose tool list: 21 read tools + allow-listed actions, de-duplicated and sorted | Byte-stable schema |
| 7 | Compose system prompt: stable prefix (rules, tool overlay, capability index) + variable sections (time, user-asserted values, dashboard cache unless suppressed, live-workout marker, pending corrections, summary) | Grounding, conflict resolution, correction loop |
| 8 | Stream the provider round; tool calls go to the router → registry → envelope, at most 8 per turn | Retrieval with uniform absence semantics |
| 9 | **Output guard, streaming**: publish only complete sentences, each scrubbed | Prohibited sentences are never displayed |
| 10 | **Number verification** at each round end (chat) / per spoken chunk (voice) | Replace contradicted claimed spans; record corrections |
| 11 | **Output guard, speech**: scrub each utterance before TTS | Nothing prohibited is spoken |
| 12 | **Output guard, final pass** on the whole message | Covers text assembled outside the stream |
| — | **Build time**: copy linter over Swift and string catalogues; lexicon coverage gate | Static copy follows the same vocabulary |

Figure 1 shows the shared-vocabulary structure.

```
                    MedicalTermLexicon (29 concepts x 17 languages)
                    |                    |                       |
      refuseBeforeSending (12)   scrubFromOutput (21)    neverInStaticCopy (12)
                    |                    |                       |
            Input guard           Output guard            Copy linter (all locales)
        (local reply, no send)  (sentence deflection)    + English build-time list
                                                                 |
                                       coverage gate: every build-time regex's
                                       witness string is matched by the lexicon
```

---

## 3. Methods in Detail

### 3.1 The typed fact catalogue

**Entry kinds.** A fact is a value of a four-case sum type `FactEntry`:

| Kind | Key | Resolver signature | Notes |
|---|---|---|---|
| `fixed` | literal dotted key, e.g. `user.profile.max_hr` | `() -> FactValue`, body is `.sync` or `.awaitable` | Carries `valueType` ("Int", "Double", "Duration", "Bool", "Record"…) |
| `parameterized` | pattern with one `$param`, e.g. `session.by_date($date)` plus an example argument | `(param, tail) -> FactValue` | Matches on leading tokens; trailing tokens pass as `tail` |
| `composite` | literal or parameterised | `(param?, registry) -> FactValue` | Declares `dependencies` (atomic keys only) |
| `action` | dotted verb key, e.g. `routes.library.rename` | `([String:String]) -> FactValue`, `.sync` or `.awaitable` | Declares named `ActionParam`s with a required flag; description starts with `[ACTION]` by convention |

Each entry also carries an `availability` closure (3.1.4). Factory functions default availability to "always available" so a declaration is one expression.

**One line, one fact.** A namespace resolver exposes only `namespace: String` and `entries: [FactEntry]`. The same `entries` array serves two purposes: the registry derives the model-facing tool schema from it, and the default resolve walks it to dispatch a key. The resolver closure is a field of the entry, so there is no second table that could drift from the first. A fact that can be resolved is a fact that is published, and the reverse.

**Registry contents at e028039.** 26 namespace resolvers are registered: 16 for the user's health data, 9 for app/device state and action surfaces, and one composites namespace registered last. Some share a head token: five register as `app` and two as `workout`. The source declares **238 entries**: 149 `fixed` with synchronous bodies, 8 `fixed` with awaitable bodies, 56 `parameterized`, 6 `composite` and 19 `action`.

#### 3.1.1 Key grammar

Model and resolver use the same key grammar, so no translation layer sits between them:

```
key      := token ("." token)*
token    := name | name "(" argument ")"
```

Parsing steps:

1. Trim whitespace; reject empty input.
2. Scan characters, tracking parenthesis depth. A `.` at depth 0 ends a token. A `)` that would make the depth negative is an error. A non-zero depth at the end is an error. An empty token (`a..b`, leading dot) is an error.
3. A token whose last character is `)` and which contains `(` splits into name and argument. An empty name is an error.

Dots inside arguments are therefore preserved (`session.by_date(2026.04.21)` is valid).

**Pattern matching.** The pattern is parsed with the same grammar. For each pattern token in turn, the names must be equal. If the pattern argument begins with `$`, the key's argument is captured, and a key with no argument fails. Otherwise both arguments must be equal or both absent. The pattern must have at most as many tokens as the key. Remaining key tokens become `tail`. At least one capture must occur.

**Dispatch.** The registry checks first every namespace whose `namespace` equals the key's head token, in registration order. Several namespaces may share a head. It then scans all other namespaces, which is how composites stored in `composites` resolve under keys such as `user.profile.snapshot`. If nothing matches, it returns `missing(notRecorded, "no such key")`.

**Tool name derivation.** Dots become underscores. A `($param)` section is removed and the parameter becomes a named string property on the tool: `session.by_date($date)` becomes the tool `session_by_date` with required string `date`.

#### 3.1.2 The closed value union and envelope

`FactValue` has nine cases: `integer`, `double`, `string`, `date`, `durationSec`, `boolean`, `missing(reason, detail?)`, `list`, `record`. Every tool result is serialised into one envelope with sorted keys:

```
{ "value": <typed JSON or null>,
  "missingReason": <reason, present only when absent>,
  "detail": <optional hint>,
  "asOf": <ISO-8601 with local UTC offset>,
  "confidence": "high" }
```

Serialisation rules: a non-finite double becomes `null` for that field only. Dates use the device's local offset, so the calendar day matches the `YYYY-MM-DD` arguments the tools accept. A nested `missing` inside a list or record is rendered as an inline envelope, so absence can be reported per field. On a successful result `missingReason` is omitted entirely. The presence of the key is the absence signal. The cloud tool loop and the on-device dispatcher for Apple's framework both call this serialiser, so all six providers receive the same shape.

**What the envelope does not carry.** `asOf` is the time of resolution, not the time of measurement, and `confidence` is the constant `"high"`. Neither is provenance. The real provenance signals are fields inside specific records:

- `data_source`: `sport_wide` versus `route_specific` for cross-workout baselines, or `live_healthkit_pending_acceptance` for sleep and vitals read live before the night is accepted. Each tool's description tells the model how to word comparisons for that source ("compared to your typical run" versus "on this loop").
- `comparison_safe`: false when fewer than 2 prior samples back a baseline.
- Composite attribution (3.1.5): which children are present and which are missing, and why.

#### 3.1.3 The absence taxonomy

Every resolver that cannot return a value must pick one of nine reasons. There is no free-text-only absence.

| Reason | Meaning to the model |
|---|---|
| `notRecorded` | No data for this query (most common) |
| `notYetComputed` | Data exists; the derived metric is not computed yet. Retry later |
| `outOfRange` | Parameter outside the fact's valid range |
| `sensorDropout` | Signal too noisy or sparse to trust |
| `invalidParameter` | Malformed arguments; `detail` names the parameter and accepted range |
| `internalError` | Bug or budget overrun; report unavailable and stop |
| `tooMuchData` | Result over the size cap; narrow the query |
| `rateLimited` | Same call missed repeatedly this turn, or the turn's tool budget is spent |
| `partialData` | Composite: some children missing (see 3.1.5 for how the code actually signals this) |

#### 3.1.4 No-I/O availability gating

Each entry's `availability` closure returns `{hasData, validRange?, lastUpdated?}`. It must be synchronous and metadata-only: no HealthKit, file or network access. In practice it reads in-memory archive indexes and settings flags. The schema builder runs it once per build:

1. Drop every entry with `hasData == false`. The per-entry schema then never offers a tool for data the user does not have.
2. For a parameterised entry with a `validRange`, append to the parameter description: `"Example: <example>. Data available as early as <Month YYYY>; do not request earlier dates."`. Only the month of the lower bound is given, with no rolling end date, so the text changes at most once a month per entry.

The workout-backed availability, for example, is `unavailable` until the archive holds one workout. After that it is valid from the earliest to the latest archived workout date.

#### 3.1.5 Composites with declared dependencies

A composite lists the atomic keys it reads. Composites may not depend on other composites. A test validates that every dependency names a real entry. On the asynchronous tool path:

1. Capture the composite's parameter (if parameterised) and substitute it for any `$name` in each dependency string.
2. Await each distinct dependency through the async resolver. This is where HealthKit or network children suspend.
3. Merge the results into a registry-held prefetch map, run the synchronous composite body (whose `registry.resolve(key)` calls hit the map first), and then restore the previous map. Nothing suspends between filling and restoring the map, so no other resolve sees it.
4. The body builds `{present: [{key, value}], missing: [{key, reason, detail?}]}` and adds `status: "partialData"` when any child is missing.

A synchronous walk that reaches an awaitable child it did not prefetch returns `missing(internalError, "resolves asynchronously …")`. It neither blocks nor traps.

#### 3.1.6 Registry rails

Every tool result passes through a final gate in this order:

1. **Repeat-miss rate limit.** The signature is `toolName + "::" + argsJSON`. Each *missing* result increments a per-turn counter for that signature. When the counter exceeds 2, the result is replaced by `missing(rateLimited, "Same tool+args returned missing 2 times this turn. Stop retrying…")`. The first two identical misses pass, and the third is short-circuited. Successful results do not count. Counters reset at the start of each user turn.
2. **Size cap.** A non-missing result whose serialised envelope exceeds 80,000 UTF-8 bytes is replaced by `missing(tooMuchData, "Response ~N bytes exceeds 80000-byte per-call cap. Ask a narrower query…")`.
3. **Time budget.** On the per-entry tool path, if resolution took more than 2.0 s of wall-clock time, the value is discarded and `missing(internalError, "resolver timed out…")` is returned. Over 0.5 s logs a warning. Over 4.0 s on an action logs a watchdog warning. On the compact read-tool path the budget only logs, because legitimate HealthKit and network waits can exceed 2 s.
4. **Numeric argument range checks.** Every numeric parameter is declared once with a closed range, an optional excluded lower bound and an integer flag. Parsing accepts only a finite number inside the range, and a whole number where the flag is set. Anything else, including "inf", "nan" and "1e20", returns `invalidParameter` with the requirement in words, e.g. "ordinal must be a whole number from 0 to 100000, got '-1'". Comma-separated parameter blobs must have exactly the expected field count, and empty fields are counted, so `60,,5` has three fields and is rejected.
5. **Required action arguments.** A missing required argument returns `invalidParameter` naming it, before the action body runs. Unknown argument keys are dropped.

**Catalogue hash.** The availability-filtered per-entry schema is JSON-encoded with sorted keys and hashed with SHA-256. The hash is recomputed on each send to detect drift in cache-relevant bytes. It changes only when an entry, a description or an availability result changes.

### 3.2 Compact tool layer

The model sees 39 tools, not 238:

- **21 read tools** with fixed names and string parameters. Most take a selector (`which`, `field`, `metric` or `aspect`) and route to one or more catalogue keys: `get_today`, `get_session`, `get_recovery`, `get_hrv`, `get_sleep`, `get_vitals`, `get_workout`, `list_workouts`, `get_walks`, `get_baseline`, `get_user`, `get_app_state`, `get_training_load`, `get_score_meta`, `get_breadcrumbs`, `get_routes`, `get_tags`, `get_workout_live`, `get_assistant_state`, `get_healthkit`, plus `lookup_fact`, which resolves any raw catalogue key.
- **18 action tools** keep their catalogue names (e.g. `assistant_email_compose`, `routes_library_rename`, `web_search`, `directions_routeTo`) so that each side effect stays identifiable in audit logs. Their specifications are taken from the availability-filtered per-entry schema and filtered by an explicit allow-list. The catalogue declares 19 actions. `location.roads_ahead` is not on the allow-list.

Construction: read tools are appended first, then actions. Duplicates by name are dropped, first occurrence wins, and a warning is logged, because one provider rejects duplicate tool names. The list is then sorted by name. Action input schemas list `required` sorted. Every property is a string, and the resolver converts types.

**Capability index.** The read-tool list also generates a short system-prompt section. For each tool it prints the name and the description's first sentence, capped at 170 characters. The section tells the model to call the matching tool before answering any question about the user's own data. Because it comes from the same specification list, it cannot drift from the real schema, and it is byte-stable.

**Retrieval and caps.** A BM25 ranker [13] (k1 = 1.5, b = 0.75, target 40) runs over the compact schema. At 39 tools it returns the list unchanged. The on-device provider, whose context holds only a few tools, uses the BM25 order to choose which to keep. A per-provider cap (110 for one provider) truncates the ranked list.

**Per-turn call budget.** The loop counts tool calls across rounds. When `callsSoFar + callsThisRound > 8`, *every* call in that round gets `missing(rateLimited, "tool budget exceeded for this turn")`. The model then has one more round to write a text answer, and any further tool calls are dropped. The on-device dispatcher enforces the same constant.

### 3.3 Runtime number verification

**Scope.** The verifier checks only claims about the value *now*. Two families exist:

| Family | Metrics | Source of truth | Where applied |
|---|---|---|---|
| Live workout | HR, power, DFA α1, HR drift | Live workout snapshot | Voice, each chunk before speech |
| App state | TSB, ATL, CTL, ACWR, RMSSD, recovery score, last night's sleep duration and efficiency | Training-load registry (same accessor as dashboard and tools); latest reliable overnight session; latest overnight with sleep | Chat, every tool-loop round end; voice, each chunk before speech |

**Table 2. Claim shapes and tolerances**

| Metric | Claim shape (case-insensitive, simplified) | Tolerance | Replacement format |
|---|---|---|---|
| HR | "your [current/live] HR/heart rate [is/'s]…" or "HR right now/currently/now", then filler words, then `\d{2,3} bpm` | 5 bpm | `N bpm` |
| Power | same shape, "power/wattage", `\d{2,4} W/watts` | 15 W | `N W` |
| DFA α1 | same shape, "α1/alpha 1", optional "DFA", decimal only | 0.10 | `%.2f` |
| HR drift | same shape, "[HR] drift", number + `%` | 1.5 points | `%.1f%` |
| TSB | `TSB` + optional "negative" + signed number | 2.0 | `%+.1f` |
| ATL / CTL | label + number | 3.0 | `%.1f` |
| ACWR | label + number | 0.15 | `%.2f` |
| RMSSD | `RMSSD [of] N [ms]` | 8.0 ms | `%.0f ms` |
| Recovery | `recovery N` | 4.0 on 0–100; a claim ≤ 10 within 1.0 of the 0–10 score is accepted | on the claim's scale |
| Sleep duration | "slept [for] [about] Nh [M m]", "sleep [duration] was …", "… of sleep" | 5 min if minutes or decimal hours given; 30 min for whole hours | "6h 55m" or "6 hours and 55 minutes", matching the claim |
| Sleep efficiency | "[sleep] efficiency [of/was/…] N%", "N% [sleep] efficient/efficiency", only in a sentence that mentions sleep | 1.0 point | `N%` |

Each app-state pattern rejects a number followed by a unit of time or count (`days`, `h`, `weeks`, `nights`, `minutes`, `sessions`, `workouts`), by `%`, or by more digits. "CTL 42-day window" is therefore not a claim.

**Algorithm (app-state family).**

1. **Normalise spelled numbers.** Match `\b(negative\s+)?(ones-or-teen | tens([-\s]+digit)?)(\s+point\s+digit)?\b`, with alternations sorted longest first. Replace each match with digits ("negative thirty-one point seven" → `-31.7`), keeping a list of `(originalRange, normalizedRange)` rewrites. Range: 0–99 with at most one decimal digit, English words only.
2. Run the metric regexes on the normalised text. Each regex names two groups: `value` (the number) and `claim` (number plus unit, the span to replace). The metric label is never part of the replaced span.
3. For each match, find its sentence using a sentence enumerator that does not split "17.2". Discard the match if the sentence contains a **time marker** (ago, yesterday, last week/month/…/weekday, previous(ly), earlier, before, on <weekday>) or a **target/comparison marker** (average, mean, baseline, typical, usual, target, goal, keep, stay, peak, max, min, trend, would, could, if, should, threshold, under, below, above, over, between, range, higher, lower, than, and similar).
4. If the claim reads "negative N", negate the value. Compute `|claimed − actual|` and keep the match only if it exceeds the tolerance.
5. Recovery: if `|claimed − score10| ≤ 1.0`, drop the match (same score on the 0–10 scale). If the claim is ≤ 10, report it on the 0–10 scale.
6. Sleep: drop matches in a sentence with general-norm markers ("need", "recommended", "adults", "per night", ranges such as "7-9") or other-night markers (month and weekday names, "nights", "weeks", dates). Drop overlaps.
7. **Remap** each range from normalised to original text. An offset inside a rewritten span snaps to the rewrite's original start or end, so "negative thirty-one point seven" is replaced whole.
8. Build `correctedText` by replacing claimed spans back-to-front. Every other word, including unrelated spelled numbers ("two sessions"), is unchanged.

The live-workout family follows steps 2–4 without normalisation and requires the "your X is" / "X right now" shape. A bare "150 bpm" is usually a target or a different metric.

**Application.** In chat, verification runs at the end of every tool-loop round, including rounds that end in a tool call, before the pre-tool text is rewound. Text published during that round may already have been visible. The corrected text replaces the saved turn. In voice, each chunk passes output scrub → live-workout verification → app-state verification → preamble → speech normalisation, so a corrected number is the only one spoken.

**Closed correction loop.** Every discrepancy is added to a process-wide, lock-guarded buffer. Entries with the same `(metric, claimed, actual)` are not re-added, because voice catches the same claim in the spoken chunk and again in the saved turn. Only the 4 most recent are kept. When the next system prompt is composed, the buffer is read and cleared into a variable section:

```
# Last turn correction — DO NOT FABRICATE
Your previous response contained numbers that contradicted live data. The saved reply was
corrected, but the user may already have read or heard the wrong number — if it matters,
correct it briefly. For any of these metrics next turn, CALL the appropriate tool (...) and
quote what comes back — never estimate or interpolate.
• You said TSB=-29.0 — actual was -15.5.
```

One fabrication therefore produces exactly one reminder on the very next turn. The section sits outside the cached prompt prefix.

### 3.4 Structural resolution of user-asserted values

Before the variable prompt sections are built, a detector reads the last 6 conversation turns. It keeps only user turns that are not `localOnly`, and walks them newest first. For each message:

1. Normalise spelled numbers (3.3 step 1).
2. Remove every sentence ending in `?` or `？`. Questions assert nothing.
3. For each known metric name (training load, HRV, heart rate, recovery, sleep, workout and vitals terms; longest first so "max hr 190" is not read as "hr 190"), find the *last* `\bmetric\b\s*[connector]\s*number` in the remaining text. The connector is optional except for `sleep` and `recovery`, which need one of `is/of/=/:/was/being`. The number may not be a clock time (`5 am`, `11 pm`, `5:30`, `o'clock`). Each match is blanked after it is used. The newest assertion per metric wins. Transcription variants (`bsb`, `tsp`, `tbs` → `tsb`, and so on) fold into the canonical key only if the canonical spelling gave no value.
4. Set `dashboardContradicted` if the text contains a contradiction phrase ("the dashboard says", "real numbers are", "you're wrong", "wrong number", …) or a sentence opening "no/actually, it's/it is" followed by a number or a word such as not/different/wrong/higher/lower/more/less.
5. Set `explicitOverrideRequested` on phrases such as "stop calling tools", "use these numbers", "I don't care what the dashboard…", "stop saying".

Policy, applied in the composer:

- If any signal is present, inject `# User-stated values (authoritative — fresher than any cache)` with one `- key: value` line per assertion (training-load metrics first, fixed formats). If a contradiction or override was seen, add a sentence saying the cached data is stale.
- If `dashboardContradicted` or `explicitOverrideRequested`, **omit the dashboard training-load block entirely**. The model then has no stale number to reconcile.

### 3.5 The multilingual regulated-claim lexicon

**Concept structure.** A concept has an `id`, a list of Latin-script alternatives and a list of "unbounded" alternatives. Its regex is

```
(?: \b(?:latin_1|latin_2|...)\b | (?:unbounded_1|unbounded_2|...) )
```

compiled case-insensitively against the original text, never a case-folded or diacritic-folded copy, so match ranges stay aligned with the string being rewritten. Accented forms are spelled out (`m[ée]decin`). Word boundaries apply only to Latin-script alternatives. CJK text has no inter-word boundary, so a `\b` around `心房細動` never matches in running Japanese. CJK and Arabic alternatives are therefore matched as substrings.

**Languages.** English plus ar, da, de, es, fi, fr, is, it, ja, ko, nb, nl, pt-BR, ru, sv and zh-Hans: 17 in all. A test fails if any concept has no non-Latin alternatives.

**Concepts (29).** Rhythm: atrial fibrillation, arrhythmia, irregular heartbeat. Conditions: named cardiac condition, acute cardiac event, neurovascular event. Claims: diagnosis, cure, treatment claim, prescription, regulatory clearance, pathology, clinical physiology labels, symptom of disease, speculative diagnosis. Risk framing: injury risk, overtraining, risk-zone framing. Certainty: categorical autonomic state, physiological certainty, unsupported metric verdict. Referral: medical referral. Input-side: chest pain, breathlessness, syncope, severe symptom, danger judgement, self-harm, injury. A separate two-concept offensive-language list uses the same structure.

**Benign-homonym exclusions.** These are written per alternative because the qualifier's position differs by language:

| Benign sense | Exclusion |
|---|---|
| Respiratory sinus arrhythmia (normal physiology) | EN `(?<!sinus\s)arrhythmias?`; FR `arythmies?(?!\s+sinusales?)`; ES/PT `arritmias?(?!\s+sinusal(?:es)?)`; NL/DE/DA/NB/FI `(?<!sinus)…`; RU `(?<!синусовая\s)(?<!синусовой\s)аритми[яи]`; JA `(?<!洞性)不整脈`; ZH `(?<!窦性)心律失常`; KO `(?<!동성)(?<!동성 )부정맥`; AR negative lookahead for `التنفسي` / `الجيبي`. German `Sinusarrhythmie` escapes because the compound has no inner `\b` |
| Software diagnostics ("Diagnostic log") | `diagnos…(?!\s+(?:log|logs|data|tool|tools|bundle))`, and the same on bare `diagnose` and Spanish/Portuguese forms |
| Swimming "stroke rate", "stroke of luck" | no bare `stroke`; only `(?:having|had|have)\s+a\s+stroke(?!\s+of\s)`, "stroke symptoms", "mini-stroke" |
| "Suicide sprints" (a drill) | `su[ïi]cide(?!\s+(?:sprints?|runs?|drills?|shuttles?|lines?)\b)` |
| Finnish *parantaa* ("improve"), Italian *prenditi cura* ("take care"), Icelandic *greining* ("analysis"), Germanic *Rezept/recept* ("recipe") | only disease-object or prescription-only shapes match |
| "This is your recovery score" | `(?-i:[Tt]his\s+IS\s+your)` is case-sensitive inside a case-insensitive pattern, so only the emphatic claim matches |

**Groups.** Three named groups select concepts, each for a stated reason:

- `refuseBeforeSending` (12) = rhythm (3) + emergency (chest pain, breathlessness, syncope, severe symptom, self-harm, acute cardiac event, neurovascular event) + general concern (danger judgement) + injury.
- `scrubFromOutput` (21): all rhythm, condition, claim, risk, certainty and referral concepts.
- `neverInStaticCopy` (12): rhythm (2), condition (3), regulatory clearance, cure, prescription, treatment, speculative diagnosis, pathology, clinical physiology labels.

Eight concepts are **input-only**. Chest pain, breathlessness, syncope, severe symptom, self-harm and injury are input-only because the model must be able to say these words when explaining why the app cannot help, and scrubbing them would rewrite the safety copy. Danger judgement consists of bare adjectives (`dangerous`, `gefährlich`) that the app's own educational copy uses in negating constructions ("not because the number is dangerous in itself"); assertion-shaped danger framing is covered on output by risk-zone framing. Acute cardiac event is a strict subset of named cardiac condition, which is already scrubbed. It exists so that the input guard can refuse "am I having a heart attack?" without refusing "is my resting HR bradycardia?", which is an ordinary question from an endurance athlete. Every one of the 29 concepts is in exactly one of these two roles, or in both (the rhythm and neurovascular concepts).

The `neverInStaticCopy` group excludes concepts the app's own copy uses on purpose. The localized safety redirect "Consult a doctor if consistently low" matches `medicalReferral`, and running the whole lexicon over the catalogue produced 45 such matches. The 12 selected concepts matched nothing in any locale when measured, so the group can act as a hard gate.

### 3.6 Input guard

**Classification order.** The order is a safety decision. The first group that matches wins:

1. Self-harm → crisis reply
2. Emergency group → symptom reply
3. Injury → injury reply
4. Rhythm → rhythm reply
5. Danger judgement → symptom reply
6. none → proceed

Justification for the order: an acute symptom outranks a rhythm question because its reply names an emergency number. "Skipped beats and chest tightness" must not get the reply that recommends a smartwatch ECG. A request for a risk judgement ranks *below* rhythm because "should I be worried about my AFib" is better served by the ECG pointer. Self-harm comes first because it was once classed as an emergency and got "talk to your doctor" with no crisis line.

**Replies.** Each reply is a fixed string from the string catalogue, so it is localized into all 17 languages:

- Crisis: an apology, "please reach out to someone now", the local emergency number, findahelpline.com, and 988 for the US. It does not mention a doctor.
- Symptom: "If you're exercising, stop now. Talk to your doctor about that. I can't assess your health — Emuqu is a fitness coaching app, not a medical device. If you're feeling unwell, please contact a clinician (or your local emergency number for severe symptoms)."
- Injury: stop, call the local emergency number if serious, the app cannot assess injuries, otherwise see a clinician.
- Rhythm: the app does not detect AFib or arrhythmia and is not a medical device; talk to your doctor; a clinically validated ECG feature exists for that purpose.

**Effects on a refusal.**

1. Append the user turn and the canned assistant turn, both flagged `localOnly`, and persist them.
2. Return without calling any provider, including the on-device one, and before the consent check.
3. The `localOnly` flag lives on the stored turn, not at one send site. History assembly withholds such turns before budgeting, so they are never counted as "dropped". Summarisation filters them again, and the correction detector skips them. A guarded message therefore cannot reach a provider on a later turn as history.

**Feature flag.** The guard is behind a flag that defaults on. The self-harm branch runs even when the flag is off: `if flagOn || classify(text) == selfHarm`.

**Prompt parity.** The system prompt's medical-boundary rule B asks the model to reply exactly with the symptom, self-harm and injury texts. Unit tests check that the symptom and injury replies appear verbatim in both prompt variants (cloud and on-device), after whitespace is collapsed. A user gets the same words whether the guard or the model handles the message.

**Voice echo trap.** Voice speaks the refusal aloud, and the rhythm refusal itself contains "AFib" and "arrhythmia". A transcript is therefore dropped as an echo when (a) it would trigger the same refusal that is already the last assistant turn and (b) at least 40% of its tokens overlap that reply.

### 3.7 Output guard

**Scope.** The output guard deflects sentences that name a condition for the user, speculate about one, assess rhythm, claim cure, treatment, prescription or regulatory clearance, frame risk as an injury prediction or "danger zone", assert categorical autonomic certainty, or rank a metric as truth. General physiology passes untouched: HRV, parasympathetic activity, respiratory sinus arrhythmia, training load, sleep. The prompt (rules A and D) also tells the model not to give dosing or personal prescriptions. On output, only prescription vocabulary is matched. There is no separate dosing regex.

**Negation-neutral by design.** The guard does not try to detect negation. A denial is a finding too: "This isn't AFib" rules a condition out. Negation is also spread across a sentence in ways one pattern cannot follow in 17 languages (sentence-final in Japanese and Korean, split in French, a negative verb in Finnish). Each deflection is therefore written to be true whether the replaced sentence affirmed or denied the term. For example: "Emuqu measures beat-to-beat timing; it doesn't assess heart rhythm. A clinician or a clinically validated ECG is the right place for that question." Deflections are catalogue strings and follow the in-app language. A test checks that no deflection trips any rule. The output guard has 13 distinct medical deflections: 9 specific to one concept, plus 4 shared by a group of concepts (rhythm, load, out-of-scope, and an observation fallback). One further line replaces offensive language.

**Scrub algorithm.**

```
scrub(text):
  active = medicalRules + offensiveRule (+ englishOnlyRule if it matches and reply is English)
  if text empty or firstMatch(text, active) is none: return text unchanged
  segments = split(text) so that concat(segments) == text exactly
  for each segment:
      core = segment without leading/trailing whitespace
      rule = firstMatch(core, active)
      if rule: emit leadingWS + rule.deflection + trailingWS; record (rule.reason, core)
      else:    emit segment byte-identical
  if nothing was replaced:          # match straddles a terminator
      m = rule.regex.firstMatch(original text)
      rebuilt = text with every segment overlapping m collapsed into ONE deflection
      if m found and firstMatch(rebuilt, active) is none: return tidy(rebuilt)
      else: return rule.deflection   # whole message
  return tidy(rebuilt)               # "  "->" ", " ."->".", " ,"->","

firstMatch(t, rules):
  r = first rule whose regex matches t
  if r: return r
  plain = t with every '*', '_', '`' removed
  return plain != t ? first rule matching plain : none
```

Segmentation: a segment runs to and including a terminator from `{. ! ? \n 。 ！ ？ ، ؟ …}`, then any run of further terminators (`?!`, `...`), then whitespace. A `.` after a digit is a decimal point when a digit follows. When the text ends right after it, it is undecided and does not split. A sentence is rewritten at most once, and rewritten text is never re-scanned. The pass is linear and needs no iteration cap. An earlier design used a 32-replacement cap, which let 136 of 200 prohibited sentences through.

The markdown retry exists because `You may have *atrial* fibrillation.` evades `atrial\s+fib`. It is safe because callers that need a range re-run the regex on the original text and fail closed.

**Where it runs.**

1. **Streaming buffer (chat and the voice cursor).** Deltas accumulate in a buffer that publishes at most every 33 ms. Each publish splits the buffer at its last terminator. Only the complete part is scrubbed and appended to the visible turn. The incomplete tail is held back, so a prohibited phrase never renders, even partially. The voice "speakable cursor" advances only over published text. At the end of a round, and on every exit path including errors and Stop, the tail is force-published, scrubbed.
2. **Speech.** Every utterance passes through one function before the synthesiser: scrub → number verification → preamble. That covers streamed chunks, completed turns, error lines and wake-word acknowledgements.
3. **Final pass** over the whole message after the stream ends, for text that did not go through the buffer.

### 3.8 Build-time perimeter

**Copy linter.** The linter scans the whole app source tree, the Watch app and both string catalogues. It has three properties beyond plain pattern matching:

1. **A real Swift literal scanner**, not a quote-pairing regex. It walks the source once, handling `//` comments, *nested* `/* */` comments, `"""` multi-line literals, and raw literals (`#"…"#`, `##"""…"""##`), where backslash is not an escape. Interpolations `\(expr)` are blanked before matching. A quote-pairing regex, measured on this code base, missed 93% of the characters inside multi-line literals, including all long-form help articles.
2. **Prohibition-context exemption.** The system prompt quotes forbidden framings in order to forbid them ("Never tell the user that a number 'predicts injury'…"). A match is excused only when (a) a guard pattern such as `never|don't|do not` + `tell|say|use|describe|call|label|refer|frame|claim|imply` matches inside a 3-line window of the **comment-stripped** source and the first 40 characters of the literal (at least 3) lie inside that same sentence, or (b) the sentence containing the match, inside the literal, contains a guard. A comment cannot excuse a string. String-catalogue values are never excused this way.
3. **Catalogue handling.** An allow-listed catalogue *key* also clears all its translations, so the wellness disclaimer does not fire once per locale. Two pattern sets run over every catalogue: the English build-time list (62 patterns) and, for *every locale*, the multilingual `neverInStaticCopy` concepts. The linter does not copy that second set into its configuration. It parses it out of the Swift lexicon source, taking each concept's `latin` and `unbounded` arrays with bracket matching, unescaping one level, and compiling them with the same `\b` rules as the runtime.

Fail-closed rules: a missing scan path, an unreadable file, an unparseable catalogue, a missing `neverInStaticCopy` group or zero usable concepts, or a pattern that fails to compile each exit with code 2.

**Coverage gate.** The gate proves the runtime lexicon matches every build-time term. It runs in CI:

1. Extract every literal from every `latin:`/`unbounded:` array in all lexicon files (a glob, so a file split does not hide terms). Bracket matching skips string literals, so a `]` inside a character class does not close the array. Compile each one, word-bounding Latin alternatives.
2. **Fail (exit 2)** if any alternative matches the empty string, or if fewer than 100 alternatives were extracted. Either means the parser is broken and the gate would pass vacuously. At e028039 there are 985.
3. For each build-time pattern, **synthesise a witness string**: remove `(?i)` and lookarounds; replace `\s+` with a space; remove `\s*` and `\b`; reduce character classes to one member (`\s` → space, `\x` → `x`); drop leftover quantifiers; repeatedly reduce `(a|b)?` → "", `(a|b)` → `a`, `(a)?` → "", `(a)` → `a`; remove `?`.
4. **Fail (exit 2)** if the witness does not match its own source pattern. The synthesiser would then be wrong.
5. **Fail (exit 1)** if no lexicon alternative matches the witness, listing each gap.

At e028039: 62 patterns probed against 985 alternatives, clean.

**Exported reports.** PDF reports and the post-workout Coach Report email body are built from templates, not from model output. They contain no LLM text. Their wording is covered only by the build-time linter. The runtime guards do not see them.

### 3.9 Consent and provider abstraction (context, mostly not claimed)

Each hosted provider needs its own consent before its first send. The consent key includes a schema version (currently 8) that is bumped when the disclosure changes, and removing an API key revokes consent. The on-device provider is exempt. When a provider fails, the fallback chain contains only other enabled, available, consented hosted providers, then the on-device provider. When the on-device framework refuses a request on safety grounds, the request is shown as refused and not retried on another provider. Each outbound request is recorded before provider-specific transforms in an in-memory first-in-first-out audit of 10 entries.

---

## 4. What Is New

Each statement below is limited to what survived a prior-art search made on 2026-10-08. That search covered agent-framework source code and documentation, patent databases, arXiv, vendor documentation and public code hosting. Below each statement, "Closest prior art" names the nearest public work. "Earliest dated form" gives the first commit in the author's private repository lineage (Section 7) that contains the rule. Where the current form arrived later, its date is also given. Repository names: flow-recovery-old (Jan 2026), flow-recovery (Mar–Aug 2026), emuqu-dev (Aug–Sep 2026), emuqu (public, from 2026-09-08).

N1. A fact catalogue keyed by literal dotted keys or by patterns with exactly one `$param` argument, all parsed by one depth-aware grammar that keeps dots inside parentheses. The same parse yields three things. The first is the model-facing tool name: dots become underscores, and `($param)` is removed and becomes a required string property. The second is a leading-token pattern match that passes the remaining key tokens to the resolver as a sub-key. The third is registry dispatch: namespaces sharing the key's head token are tried first, in registration order, then all others. A per-entry tool and a raw-key `lookup_fact` call therefore reach the same resolver.  
Closest prior art: the OpenAI Agents SDK derives a tool's schema and its dispatch from one function declaration [17]. That general idea is not claimed. No dotted key-pattern grammar shared by naming, matching and dispatch was found.  
Earliest dated form: flow-recovery c63d56c, 2026-04-23 ("major AI voice upgrades"); the depth-aware split was added in emuqu-dev 680bbee on 2026-08-25.

N2. An availability check per catalogue entry that is synchronous and metadata-only. It may read in-memory indexes and settings, but not HealthKit, files or the network, and it returns `{hasData, validRange, lastUpdated}`. The schema builder drops entries without data. For each parameterised entry it appends "Data available as early as <Month YYYY>; do not request earlier dates" to the parameter description. Only the month of the lower bound is given, so the description changes at most once a month. The filtered schema is then hashed (SHA-256 over sorted-key JSON) to detect drift in cache-relevant bytes.  
Closest prior art: the OpenAI Agents SDK `is_enabled` option (PR #808, 2025-06-03) hides a tool for a run by a boolean or a callable [17]. Gating tool visibility on a condition is therefore not claimed. The metadata-only constraint, the range text and its month granularity were not found.  
Earliest dated form: flow-recovery c63d56c, 2026-04-23 (same rule).

N3. A tool-result envelope whose absence channel is a closed, nine-value enumeration, each value with a defined meaning for the model. On success the `missingReason` key is omitted entirely, so its presence is the absence signal. A `missing` value nested in a list or record is serialised as its own inline envelope, so absence is reported per field. One serialiser feeds five hosted providers and the on-device dispatcher for Apple's framework.  
Closest prior art: the OpenAI Agents SDK returns tool exceptions (`failure_error_function`) and, since 2026-02-13, timeouts (`timeout_behavior="error_as_result"`) to the model as tool output [17]. Returning failures to the model as results is not claimed. A closed absence taxonomy with per-field nesting across six providers was not found.  
Earliest dated form: flow-recovery c63d56c, 2026-04-23 (nine-case taxonomy identical); on-device path flow-recovery e36fee4, 2026-05-06.

N4. A registry gate with these rules. (a) A per-turn counter on the exact `(tool name, arguments JSON)` signature, incremented only by *missing* results, replaces the third identical miss with a `rateLimited` absence that tells the model to stop retrying. The agent run is not halted. (b) A non-missing result whose serialised envelope exceeds 80,000 UTF-8 bytes becomes a `tooMuchData` absence asking for a narrower query. (c) Numeric arguments are declared once with a closed range, an optional excluded lower bound and an integer flag. Anything outside the range, non-finite or non-integral where required, and any comma-separated blob with the wrong field count (empty fields counted), becomes an `invalidParameter` absence that states the accepted range in words. A wall-clock budget sits between (a) and (b) but is not claimed.  
Closest prior art: per-tool timeouts returned as results (OpenAI Agents SDK [17]); the OpenHands stuck detector, which halts an agent after the same action and observation repeat four times or the same action errors three times [26].  
Earliest dated form: flow-recovery c63d56c, 2026-04-23 (miss counter, 80 KB cap); range-checked arguments emuqu c1d875e, 2026-10-05.

N5. Composite facts that declare their atomic dependencies. On the asynchronous path the dependencies are awaited and placed in a registry-held prefetch map. A synchronous composite body then runs against that map, and the map is restored before anything can suspend. The result is a `{present, missing}` attribution record with per-child absence reasons, plus `status: "partialData"` when any child is missing.  
Closest prior art: none found in the search described above.  
Earliest dated form: flow-recovery c63d56c, 2026-04-23 (composites with present/missing records); scoped prefetch emuqu 554540f, 2026-10-03.

N6. A two-tier model-facing tool surface. It consists of 21 fixed, polymorphic read tools and 18 allow-listed action tools taken from the availability-filtered catalogue under their original names. Duplicates by name are dropped (first wins) and the list is sorted by name for byte stability. A system-prompt capability index is generated from the same read-tool specification list, using each description's first sentence capped at 170 characters.  
Closest prior art: none found.  
Earliest dated form: flow-recovery d5d6180, 2026-05-06 (compact router); de-duplication and sorting emuqu-dev 680bbee, 2026-08-25; capability index present at emuqu-dev d4e5cf8, 2026-08-16.

N7. A free-text numeric verifier with the following properties. Checking a model's numbers against structured values with a tolerance, and correcting numeric statements before a response is returned, are public [18][19] and are not claimed. (a) Only claims about a metric's *current* value are checked. A match is discarded when its sentence carries a time marker or a target/comparison marker (lists in 3.3), or when the number is followed by a time or count unit. (b) English spelled numbers (0–99, one decimal digit, optional "negative") are normalised first. Match offsets are then mapped back to the original text, snapping into a rewritten span so that "negative thirty-one point seven" is replaced whole. (c) Only the number-and-unit span is replaced, never the metric label. (d) Recovery is checked on both scales: a claim of 10 or less within 1.0 of the 0–10 score is accepted. (e) The sleep-duration tolerance follows the precision of the claim: 5 min when minutes or decimal hours are given, 30 min for whole hours. (f) The check runs on each voice chunk before speech and at the end of every chat tool-loop round.  
Closest prior art: Proof-Carrying Numbers [18], which verifies claim-bound numeric tokens against structured claims with a tolerance policy and fails closed; US Patent 12,670,149 [19], which detects and corrects inaccurate numeric comparisons in LLM responses; PHIA [21], an agent that computes answers from wearable data with code; and US Patent 12,353,469 B1 [20], which, per a search extract, grounds generated answers with citations. None found parses spelled-out numbers in free speech or limits checking to present-value claims by sentence markers.  
Earliest dated form: flow-recovery 1b5ad2a ("hallucination guard"), 2026-05-02 (live voice chunks, tolerances, span replacement); app-state claims 10fc926, 2026-05-17; spelled numbers e8ca54a, 2026-06-02; time/target markers emuqu 554540f, 2026-10-03.

N8. A correction loop in which verified discrepancies are de-duplicated by `(metric, claimed, actual)` and capped at the four most recent. They are consumed exactly once into a variable section of the *next* turn's system prompt, outside the cached prefix. That section tells the model the user may already have seen the wrong number and to call the named tool rather than estimate. The failing reply itself is not re-generated.  
Closest prior art: US Patent 12,670,149 re-prompts the model to fix a detected numeric error [19]. Re-prompting on a detected error is not claimed.  
Earliest dated form: flow-recovery 68f32e5 ("hallucination feedback"), 2026-05-08 (cap 4, consume once); de-duplication emuqu 5c4a23d, 2026-10-04.

N9. Structural resolution of conflicts between user-stated values and cached dashboard values. The resolver detects statements, not questions, in the last six non-local user turns that assert metric values or contradict the cache. It then removes the cached training-load block from the prompt and injects a user-stated block, instead of instructing the model to prefer the user.  
Closest prior art: none found beyond the general knowledge-conflict literature, which concerns model behaviour rather than prompt construction.  
Earliest dated form: flow-recovery e8ca54a, 2026-06-02 (same mechanism).

N10. A single regulated-claim lexicon of 29 concepts in seventeen languages. Each concept is split into word-bounded Latin-script alternatives and substring-matched CJK/Arabic alternatives, with per-language, position-aware lookarounds for benign homonyms (for example sinus arrhythmia in each script). It is consumed through three named groups (input refusal, output scrubbing, never-in-static-copy) whose membership is justified per concept.  
Closest prior art: Llama Guard 3, a multilingual safety classifier (eight languages) with Specialized Advice and Self-Harm categories [22]. Multilingual safety classification is not claimed. A shared regex lexicon with per-language homonym exclusions driving three enforcement points was not found.  
Earliest dated form: emuqu-dev 8c3999d, 2026-08-26; English-only precursors flow-recovery 69ee32d (2026-04-26) and 0a3972d (2026-05-03).

N11. An input guard with these rules. (a) It classifies the current message in a fixed safety order: self-harm, acute emergency, injury, rhythm, danger judgement. (b) It answers with a fixed, catalogue-localized reply, and unit tests show that the cloud and on-device system prompts quote the reply word for word. (c) It persists both turns with a `localOnly` flag on the stored turn. That flag is honoured by history assembly (before budgeting, so withheld turns are not counted as dropped), by summarisation and by the user-assertion detector. (d) It sends nothing to any provider and runs before the consent check. (e) It answers self-harm even when the guard's feature flag is off.  
Closest prior art: Myra's published crisis protocol screens every message before the AI companion with a phrase list and a classifier, and answers with a fixed message plus crisis lines localized to the user's region [24]. A public Hugging Face Space returns a fixed crisis message on a keyword match [25]. A pre-model crisis screen with a fixed reply is not claimed.  
Earliest dated form: flow-recovery 69ee32d, 2026-04-26 (English, nothing sent); `localOnly` flag flow-recovery 9645baa, 2026-05-01; ordered classes emuqu-dev 8c3999d, 2026-08-26; self-harm class emuqu 3585687, 2026-09-30; injury class emuqu c1d875e, 2026-10-05.

N12. An on-device output guard that is negation-neutral. It replaces whole sentences with deflections written to be true whether the sentence affirmed or denied the term. It retries on markdown-stripped text. When a match straddles a sentence boundary, it collapses the overlapping segments into one deflection, or deflects the whole message if that still matches. It runs on complete sentences before display, holding back incomplete tails with a decimal-aware split, on every spoken utterance, and in a final pass.  
Closest prior art: NeMo Guardrails streaming output rails, which check chunks server-side before they reach the client [23]; NegEx [12] (not claimed). Checking streamed output before delivery is not claimed.  
Earliest dated form: flow-recovery 0a3972d, 2026-05-03 (English sentence deflection); negation-neutral multilingual form emuqu-dev 8c3999d, 2026-08-26; decimal-aware split emuqu 5c4a23d, 2026-10-04.

N13. A build-time copy linter with these parts. It uses a real Swift literal scanner (nested comments, multi-line and raw literals, blanked interpolations). Its prohibition-context exemption is evaluated only on comment-stripped source and only within the prohibiting sentence. Key-level allow-listing also covers translations. It applies multilingual patterns parsed from the runtime lexicon source to every locale of the string catalogues. It fails closed on any missing input.  
Closest prior art: none found.  
Earliest dated form: flow-recovery 0a3972d, 2026-05-03 (Swift string scanner, comment stripping, string catalogues); prohibition context emuqu-dev 59ce5da, 2026-08-26; multilingual patterns emuqu-dev 8c3999d, 2026-08-26.

N14. A coverage gate that synthesises a witness string for each build-time regex and verifies the witness against its own pattern. It then requires some runtime-lexicon alternative to match the witness. It refuses to pass when any lexicon alternative matches the empty string or fewer than one hundred alternatives were extracted.  
Closest prior art: string generation from a regular expression (exrex [27]; Hypothesis `from_regex` [28]). Generating strings from a regex is not claimed. Using the generated string to prove that a second vocabulary covers the first, with self-check and vacuity guards, was not found.  
Earliest dated form: emuqu-dev 8c3999d, 2026-08-26 (same rule).

**Changes from v1.0.** v1.0's N1 claimed a catalogue entry from which both schema and dispatch are derived, so that no resolver exists without being published. The OpenAI Agents SDK's `function_tool` and `is_enabled` [17] anticipate that general idea, so it is dropped. Its surviving specifics are merged into N1, together with v1.0's N2 (key grammar), and into N2 (metadata-only availability). v1.0's N3 and N4 are narrowed to the parts not covered by [17] and [26]. v1.0's N7, N8, N11, N12 and N14 are narrowed against [18]–[25], [27] and [28]. No statement was found fully anticipated after narrowing.

**Not claimed (prior art).** Model tool or function calling [3][4][14]; deriving tool schema, dispatch and enablement from one declaration [17]; returning tool errors and timeouts to the model as results [17]; loop detection on repeated agent actions [26]; retrieval-augmented generation [2]; provider-side prompt caching [15]; BM25 ranking [13]; regular-expression keyword filtering in general; classifier- or rail-based LLM guardrails, including multilingual classifiers and streaming output rails [10][11][22][23]; pre-model crisis screening with a fixed reply [24][25]; verification or correction of model numbers against structured values with tolerances, and re-prompting on an error [18][19]; post-hoc claim verification with model calls [5][6]; clinical negation detection [12]; generating strings from a regular expression [27][28]; multi-provider fallback; per-vendor consent prompts; instruction hierarchies [9][16].

---

## 5. Accepted Tradeoffs and Limitations

**Validation status.** The science register (`Tools/science_register/register.json`, scoring version v3.1.oct2026) holds 19 entries: 3 `validated`, 4 `supported-transfer`, 12 `awaiting-validation`. **None covers any method in this paper.** These are software controls, not physiological heuristics, and none is described here as validated. The independent PhysioNet validation reported in the companion papers does not apply here, because nothing in this paper computes a physiological quantity. The verifier tolerances are hand-set from dashboard rounding and the noise of each metric. Their false-positive and false-negative rates on real model output are unknown, because no labelled corpus of model replies has been collected; the tests below fix behaviour on constructed inputs only.

**Verification evidence.** The methods are checked by unit tests in the `EmuquTests` target and by build-time gates in CI. Counts are test functions at e028039.

| Suite | Tests | What it pins |
|---|---|---|
| `EmuquTests/CoachVoiceGuardTests.swift` | 44 | 200 identical prohibited sentences all rewritten (the old 32-replacement cap fails this); 100 clean sentences kept byte-identical among 100 prohibited ones; a prohibited "you may have atrial fibrillation" sentence intercepted in each of the 16 non-English locales; sinus arrhythmia not deflected in any locale; straddling match fails closed; decimal point does not split; a prohibited phrase is never published during streaming; no deflection trips any rule; every concept has non-Latin alternatives and compiles |
| `EmuquTests/CoachVoiceGuardNegationTests.swift` | 4 | A denial and an assertion of the same term (pairs in several languages) get the same neutral line; no deflection asserts a finding; every translated deflection exists and passes the guard |
| `EmuquTests/MedicalQueryGuardTests.swift` | 29 | Rhythm and symptom questions refused in every shipped locale; self-harm gets the crisis reply, not the symptom reply, in every locale; "suicide sprints" proceed; acute symptom outranks rhythm; rule B quotes the symptom reply verbatim; every concept in `refuseBeforeSending` is actually refused, with probes derived from the lexicon; leetspeak ("4F1B") is asserted to remain uncovered, so a change in that documented gap fails the test |
| `EmuquTests/MedicalQueryGuardTests+Injury.swift` | 6 | Injury class and reply |
| `EmuquTests/LocalOnlyTurnTests.swift` | 7 | `localOnly` survives storage; refused turns are withheld from outbound history, not reported as dropped, and stay withheld under truncation |
| `EmuquTests/HallucinationFeedbackTests.swift` | 15 | Correction buffer caps at four and clears on consume; wrong current HR, duration and efficiency corrected without the label; targets, norms, other nights and averages are not claims; spelled-out duration checked after normalising; right or rounded values left alone |
| `EmuquTests/FactValueTests.swift` | 41 | Envelope: no `missingReason` on success, non-finite double nulls only its field, nested missing carries its own envelope, sorted keys, always valid JSON |
| `EmuquTests/FactCatalogValidationTests.swift` | 8 | No duplicate tool names; valid placeholders; composite dependencies name real atomic entries; availability closures are fast; schema serialisation is deterministic; tool names valid for providers; every catalogue key round-trips through dispatch |
| `EmuquTests/FactNumericArgumentTests.swift` | 9 | Non-finite and out-of-range values rejected with the parameter and range named; wrong field counts and empty fields rejected; every numeric fact rejects hostile values without trapping |

Build-time gates: `Tools/copy_linter/lint.py` and `scripts/check_perimeter_sync.sh` run in the CI workflow. `scripts/verify_gates_fail.sh` plants a violation for each and requires the gate to go red. For the linter, the plant is a localized string reading "This can diagnose your arrhythmia." and a malformed string catalogue. For the coverage gate, it is a build-time term added to one list only.

**Lexical, not semantic.** Every perimeter element is a regular expression. A paraphrase that avoids the vocabulary passes, and the build-time list has already been evaded once ("strongly suggests" for "strong predictor"). Specific known gaps:

- **Obfuscation.** There is no normalisation of leetspeak, homoglyphs or inserted characters beyond removing `*`, `_` and backticks. The offensive list handles a few variants (`n[i1]gg…`); the medical lexicon does not.
- **Single-message input guard.** The input guard sees only the current message. A question split across turns ("I have a heart condition" … "is it atrial…") is not joined.
- **Auto-extracted memories** are written from the user and assistant texts by a background model call. They are not passed through the lexicon, and they are injected into later system prompts.
- **Model-drafted email bodies** (`assistant_email_compose`) go to the system mail composer without passing through the output guard. The user reviews the draft and sends it themselves.
- **English-only number verification.** The claim regexes and the spelled-number normaliser (0–99, one decimal digit) are English. A wrong number in a German reply is not corrected.
- **Over-deflection.** Negation-neutrality means a correct denial ("there's no sign of overtraining") is also deflected. A sentence containing a matched term anywhere loses the whole sentence.
- **Prompt and guard disagree.** Prompt rules A and C allow the model to describe a disease or AFib in general terms. The input guard refuses any message naming AFib, and the output guard deflects any sentence naming a cardiac condition. The guards win, so general information about named conditions is not delivered.

**Verification scope.** Only "value now" claims for the 11 metrics in Table 2 are checked. History, averages and targets are skipped by design, which also means a wrong historical number passes. Live-workout claims (HR, power, α1, drift) are checked only on the voice path. Chat checks app-state claims only. In chat the correction is applied at the end of the round, after the round's text has been displayed. The next-turn reminder tells the model the user may have seen the wrong number.

**Catalogue honesty.**

- `asOf` is resolve time and `confidence` is always "high". Neither carries information.
- The `partialData` reason exists in the enum, but composites report partial results as a successful record with `status: "partialData"`. No resolver returns it as the top-level reason.
- Availability gating filters the per-entry schema, which feeds the action-tool list and the catalogue hash. The 21 compact read tools are static, so they are not removed when data is absent, and the valid-range text written into per-entry parameter descriptions is not shown to the model in the compact configuration.
- The `[ACTION]` prefix is a convention, not an enforced check. One allow-listed action (`directions_routeTo`) lacks it. Several location *reads* are declared as actions.
- When a round would exceed the 8-call budget, every call in that round is refused, including calls that would have fitted.
- The 2 s time budget discards values only on the per-entry path. Compact read tools log but keep slow results.

**Build-time gates.**

- The coverage gate is one-directional: build-time terms must be covered at runtime, not the reverse. It accepts a match by *any* lexicon alternative, including input-only concepts that the output guard does not scrub. It skips a pattern whose witness reduces to an empty string.
- The linter's multilingual extraction reads only the main lexicon file and silently skips an individual concept it cannot locate or compile. It fails closed only when no concept is usable.
- Exported PDF reports contain no model text and are covered only by the build-time linter.
- The consent-schema bump depends on discipline. No automated check exists.

---

## 6. Comparison to Existing Approaches

Facts for products and libraries are limited to what their public documentation, code or filings state. Entries marked (search extract) were seen only through a search-engine extract on 2026-10-08.

| Approach | Documented behaviour | Overlap with this paper | Difference | Ref. |
|---|---|---|---|---|
| Function calling / tool use (OpenAI, Anthropic) | Model may call declared tools; output is not checked | Tool layer (3.2) | No absence taxonomy, number check or perimeter | [14][15] |
| OpenAI Agents SDK | `function_tool` builds schema and dispatch from one declaration; `is_enabled` (2025-06-03) hides tools per run; `failure_error_function` and `timeout_behavior="error_as_result"` (2026-02-13) return failures to the model as tool output | N1–N4 in general form; v1.0's N1 dropped | No key-pattern grammar, metadata-only range text, closed nine-value absence enum, or per-signature miss limit | [17] |
| OpenHands stuck detector | Halts the agent after 4 identical action–observation pairs or 3 identical erroring actions | Repeat detection (N4) | Emuqu does not halt; it counts only misses per exact signature per turn and returns an absence | [26] |
| RAG | Retrieved passages in context; output not checked | Grounding | No output check | [2] |
| RARR / FActScore | Post-hoc claim check with model calls and retrieval | Verification | Model calls, after generation; evaluated primarily in English | [5][6] |
| Proof-Carrying Numbers (Sep 2025) | Numbers bound to structured claims are verified against a source under a tolerance policy; unverified numbers never marked verified (fail-closed) | N7 general idea | Needs claim-bound tokens from the model; Emuqu parses free text and spoken spelled numbers, limits checks to present-value claims, and replaces only the number span | [18] |
| US Patent 12,670,149 | Detects and corrects inaccurate numeric comparisons in LLM responses; re-prompts to fix an error (search extract) | N7, N8 general idea | Present-value filtering, span replacement in voice chunks, and consume-once next-turn feedback not described in the material seen | [19] |
| PHIA (2024) | LLM agent answering wearable-data questions by generating and running code | Grounding in personal data | No post-generation number check or perimeter described | [21] |
| NeMo Guardrails | Programmable input/output rails; streaming output rails check chunks before they reach the client | N12 timing | Server-side; no negation-neutral deflection or decimal-aware sentence buffering documented | [11][23] |
| Llama Guard / Llama Guard 3 | Classifier over prompt and response; Llama Guard 3 covers 8 languages with categories including S6 Specialized Advice and S11 Self-Harm | N10, N11 categories | Model call per check; general taxonomy, not a regulated-claim lexicon; no build-time link | [10][22] |
| Myra crisis protocol | Every message screened before the AI (phrase list + classifier); fixed message plus region-localized crisis lines; companion never handles crisis content | N11 core idea | No ordered multi-class refusal, local-only persistence across history, or prompt-parity test documented | [24] |
| Keyword crisis gate (public Hugging Face Space) | Fixed crisis message on a keyword match | N11 core idea | English keyword list only | [25] |
| NegEx-style rules | Negation detection in clinical notes | — (not claimed) | Emuqu avoids negation detection | [12] |
| exrex; Hypothesis `from_regex` | Generate strings matching a regular expression | N14 witness step | No cross-vocabulary coverage proof or vacuity guards | [27][28] |
| WHOOP Coach | GPT-4 "fine-tuned with anonymized member data and proprietary WHOOP algorithms"; anonymized data with zero retention (search extract) | Health-data coach | Nothing public on number verification, input or output guardrails, or languages | [29] |
| Oura Advisor | LLM combined with Oura's algorithms; inputs include scores, contributors, tags, profile and past interactions (search extract); "not a medical device"; medical questions can be routed to Counsel Health's clinicians | Health-data coach; medical-question boundary | Nothing public on number verification or on how prohibited output is filtered | [30][31][32] |
| **Emuqu (this paper)** | Typed catalogue with closed absence taxonomy; present-value verifier with per-metric tolerance, span correction and next-turn feedback; one 17-language lexicon at input, output and build time | — | Regex on device, no model call; checks before display and before speech | — |

---

## 7. Provenance and Dates

**Project origin.** The following records establish when the project began. They are origin evidence, not dates for any method in this paper.

- Repository chrissharp80/AI-Fitness-Coach: 19 commits, 2025-02-16 to 2025-02-17, all by Chris Sharp. It read and displayed Apple HealthKit heart rate and HRV and streamed heart rate from a Polar H10 over Bluetooth. It contains none of the methods in this paper.
- The author's ChatGPT history contains the earliest recovered HRV-specific design exchange: a user message on 2025-02-22 at 15:44:18 UTC proposing an app that, with a Polar strap worn to bed, would "learn right before they're gonna wake up and then administer the test … similar to what WHOOP tries to do, but … actually get it right". The excerpt was recovered through conversation-history retrieval on 2026-10-08; the full transcript and a stable conversation ID are not exposed. The same day's discussion lists "HRV trends" in a fitness-app feature set. Messages on 2025-03-04 and 2025-03-05 cover the build/deploy/test workflow and a VO₂-max validation plan. None of these concern the assistant.

**Repository lineage.** All repositories are private except emuqu. The author retains all of them with full history.

| Repository | First commit | Notes |
|---|---|---|
| flow-recovery-old ("Flow HRV") | 2026-01-12 | 250 commits to 2026-01-26 |
| flow-recovery-dev | 2026-03-01 | Squashed import |
| flow-recovery ("Flow Recovery") | 2026-03-15 | 196 commits to 2026-08-12 |
| emuqu-dev | 2026-08-16 | Squashed import; to 2026-09-04 |
| emuqu (public, github.com/chrissharp80/emuqu, PolyForm Strict 1.0.0) | 2026-09-08 | Public |

**Earliest commit per statement.**

| N | First form (commit, date) | Current form (commit, date) |
|---|---|---|
| N1 | flow-recovery c63d56c, 2026-04-23 | emuqu-dev 680bbee, 2026-08-25 (depth-aware split) |
| N2 | flow-recovery c63d56c, 2026-04-23 | same |
| N3 | flow-recovery c63d56c, 2026-04-23 | flow-recovery e36fee4, 2026-05-06 (on-device path) |
| N4 | flow-recovery c63d56c, 2026-04-23 | emuqu c1d875e, 2026-10-05 (range-checked arguments) |
| N5 | flow-recovery c63d56c, 2026-04-23 | emuqu 554540f, 2026-10-03 (scoped prefetch) |
| N6 | flow-recovery d5d6180, 2026-05-06 | emuqu-dev 680bbee, 2026-08-25 (de-dup and sort) |
| N7 | flow-recovery 1b5ad2a, 2026-05-02 | emuqu 554540f, 2026-10-03 (time/target markers) |
| N8 | flow-recovery 68f32e5, 2026-05-08 | emuqu 5c4a23d, 2026-10-04 (de-duplication) |
| N9 | flow-recovery e8ca54a, 2026-06-02 | same |
| N10 | flow-recovery 69ee32d, 2026-04-26 (English precursor) | emuqu-dev 8c3999d, 2026-08-26 |
| N11 | flow-recovery 69ee32d, 2026-04-26 | emuqu c1d875e, 2026-10-05 (injury class) |
| N12 | flow-recovery 0a3972d, 2026-05-03 | emuqu 5c4a23d, 2026-10-04 (decimal-aware split) |
| N13 | flow-recovery 0a3972d, 2026-05-03 | emuqu-dev 8c3999d, 2026-08-26 (multilingual patterns) |
| N14 | emuqu-dev 8c3999d, 2026-08-26 | same |

**Dated non-git records** (the author's own Google Drive). Documents dated 2026-05-06 and uploaded on 2026-05-10 (README 2.md, VOICE_AND_TOOL_USE 2.md, flow-recovery-audit.md, audit-results-20260506) describe the fact catalogue as the tool schema (about 200 tools, 19 namespaces). They also describe availability-closure gating with the valid range in parameter descriptions, and a uniform `{value, missingReason, asOf, confidence}` envelope across Apple and cloud providers. The registry rails are there too: the third identical miss becomes `rateLimited`, an 80 KB cap gives `tooMuchData`, and resolvers have a 2 s budget. So are composite `{present, missing}` records, `[ACTION]` tools, the input guard and output regex guard, and a copy-linter term list with the `(?<!sinus\s)` lookbehind on "arrhythmia". These agree with the git dates above. Earlier Drive records under the names "Flow HRV" (report, 2026-01-12) and "Flow Recovery" (session reports 2026-02-16, 2026-02-18, 2026-03-04) concern measurement, not the assistant.

**Public disclosures.**

- TestFlight beta from 2026-01-27; 45 testers by August 2026. A public TestFlight join link appears in the project README by May 2026.
- Substack, "A Powerfully Lazy Man's Way to Better Health", 2026-05-19. It described dual internal-plus-streamed RR capture merged in the morning, DFA α1 "organized windows", and a 30–70% sleep search band picking the highest-RMSSD window. It described no method in this paper.
- Substack, "How I Build Production Software by Directing AI", 2026-08-10. It described the author's AI-directed development process, the beta (45 testers, over 6,500 sessions) and a readiness score, but no method in this paper.
- Public repository github.com/chrissharp80/emuqu, first commit 2026-09-08.
- These white papers, v1.0 and v1.1, 2026-10-08.
- Before any public release, the work was shared privately with two colleagues, in January and March 2026.

**Authorship.** Chris Sharp <chrissharp80@gmail.com> is the sole author and sole committer. He directs AI coding assistants to write the code, and some commits are attributed to "Claude"; he supplies the requirements, design direction, review, testing and acceptance.

**This paper:** v1.1, published 2026-10-08, describing source revision e028039 (2026-10-07).

---

## References

1. Ji, Z., Lee, N., Frieske, R., et al. (2023). Survey of Hallucination in Natural Language Generation. *ACM Computing Surveys* 55(12).
2. Lewis, P., Perez, E., Piktus, A., et al. (2020). Retrieval-Augmented Generation for Knowledge-Intensive NLP Tasks. *Advances in Neural Information Processing Systems (NeurIPS) 33*.
3. Schick, T., Dwivedi-Yu, J., Dessì, R., et al. (2023). Toolformer: Language Models Can Teach Themselves to Use Tools. *NeurIPS 36*.
4. Yao, S., Zhao, J., Yu, D., et al. (2023). ReAct: Synergizing Reasoning and Acting in Language Models. *International Conference on Learning Representations (ICLR)*.
5. Gao, L., Dai, Z., Pasupat, P., et al. (2023). RARR: Researching and Revising What Language Models Say, Using Language Models. *Proceedings of ACL 2023*.
6. Min, S., Krishna, K., Lyu, X., et al. (2023). FActScore: Fine-grained Atomic Evaluation of Factual Precision in Long Form Text Generation. *Proceedings of EMNLP 2023*.
7. U.S. Food and Drug Administration (2019). *General Wellness: Policy for Low Risk Devices*. Guidance for Industry and FDA Staff.
8. Apple Inc. *App Store Review Guidelines*, Guideline 1.4.1 (Physical Harm — medical apps). Public documentation.
9. Greshake, K., Abdelnabi, S., Mishra, S., et al. (2023). Not What You've Signed Up For: Compromising Real-World LLM-Integrated Applications with Indirect Prompt Injection. *Proceedings of the 16th ACM Workshop on Artificial Intelligence and Security (AISec)*.
10. Inan, H., Upasani, K., Chi, J., et al. (2023). Llama Guard: LLM-based Input-Output Safeguard for Human-AI Conversations. arXiv:2312.06674.
11. Rebedea, T., Dinu, R., Sreedhar, M., Parisien, C., Cohen, J. (2023). NeMo Guardrails: A Toolkit for Controllable and Safe LLM Applications with Programmable Rails. *Proceedings of EMNLP 2023: System Demonstrations*.
12. Chapman, W. W., Bridewell, W., Hanbury, P., Cooper, G. F., Buchanan, B. G. (2001). A Simple Algorithm for Identifying Negated Findings and Diseases in Discharge Summaries. *Journal of Biomedical Informatics* 34(5).
13. Robertson, S., Zaragoza, H. (2009). The Probabilistic Relevance Framework: BM25 and Beyond. *Foundations and Trends in Information Retrieval* 3(4).
14. OpenAI (2023). Function calling. OpenAI API documentation.
15. Anthropic (2024). Tool use and prompt caching. Anthropic API documentation.
16. Wallace, E., Xiao, K., Leike, R., et al. (2024). The Instruction Hierarchy: Training LLMs to Prioritize Privileged Instructions. arXiv:2404.13208.
17. OpenAI. OpenAI Agents SDK for Python: `function_tool`, `is_enabled` (pull request #808, merged 2025-06-03), `failure_error_function`, and `timeout_behavior="error_as_result"` (added 2026-02-13), in src/agents/tool.py. https://github.com/openai/openai-agents-python (accessed 2026-10-08).
18. Solatorio (2025). Proof-Carrying Numbers (PCN): A Protocol for Trustworthy Numeric Answers from LLMs via Claim Verification. arXiv:2509.06902. https://arxiv.org/abs/2509.06902 (accessed 2026-10-08).
19. U.S. Patent No. 12,670,149. Detection and correction of inaccurate numeric comparisons in LLM responses. United States Patent and Trademark Office. https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/12670149 (accessed 2026-10-08; assignee and filing date not recorded in this search).
20. U.S. Patent No. 12,353,469 B1 (Amazon). https://patents.google.com/patent/US12353469B1 (accessed 2026-10-08; seen via search extract only).
21. Merrill, M. A., et al. (2024). Transforming Wearable Data into Health Insights using Large Language Model Agents (PHIA). arXiv:2406.06464. https://arxiv.org/abs/2406.06464 (accessed 2026-10-08).
22. Meta (2024). Llama Guard 3 model card. https://huggingface.co/meta-llama/Llama-Guard-3-8B (accessed 2026-10-08).
23. NVIDIA. NeMo Guardrails documentation: streaming and output rails. https://docs.nvidia.com/nemo/guardrails/ (accessed 2026-10-08).
24. Myra. Myra — Crisis Response Protocol. https://sites.google.com/view/myra-privacy-policy/home/crisis-resource (accessed 2026-10-08).
25. Deva1211/chatbot, Hugging Face Space, app.py. https://huggingface.co/spaces/Deva1211/chatbot/blob/main/app.py (accessed 2026-10-08).
26. OpenHands. Agent stuck detector. https://docs.openhands.dev/sdk/guides/agent-stuck-detector (accessed 2026-10-08).
27. exrex: irregular methods on regular expressions (Python package). https://pypi.org/project/exrex/ (accessed 2026-10-08).
28. Hypothesis documentation, `hypothesis.strategies.from_regex`. https://hypothesis.readthedocs.io/ (accessed 2026-10-08).
29. OpenAI. WHOOP customer story. https://openai.com/customer-stories/whoop (accessed 2026-10-08; seen via search extract only).
30. Oura. Oura Advisor (support article). https://support.ouraring.com/hc/en-us/articles/39512345699219 (accessed 2026-10-08).
31. Oura (2025-03-31). Oura Advisor, an AI-powered Personal Health Companion, Now Rolling Out to All Oura Members. Business Wire. https://www.businesswire.com/news/home/20250331565896/en/ (accessed 2026-10-08).
32. Oura. Counsel integration in the Oura app (blog). https://ouraring.com/blog/counsel-integration-oura-app/ (accessed 2026-10-08).

---

## Appendix A: Parameter Table

| Name | Value | Unit | Role |
|---|---|---|---|
| Registered namespace resolvers | 26 | count | Registry address space |
| Declared catalogue entries | 238 (149 fixed sync, 8 fixed async, 56 parameterised, 6 composite, 19 action) | count | Catalogue size at e028039 |
| Absence reasons | 9 | count | Closed taxonomy |
| `rateLimitMissRetries` | 2 | misses | Third identical miss per turn → `rateLimited` |
| `outputSizeCapBytes` | 80,000 | bytes | Per-result cap → `tooMuchData` |
| `defaultResolveBudgetSec` | 2.0 | s | Per-entry path: overrun discards value |
| `resolveWarnBudgetSec` | 0.5 | s | Slow-resolver warning |
| `watchdogWarnSec` | 4.0 | s | Action main-thread warning |
| Valid-range text granularity | month of lower bound | — | Parameter description |
| Compact read tools | 21 | count | Model-facing schema |
| Allow-listed action tools | 18 | count | Model-facing schema |
| Capability-index purpose cap | 170 | characters | Per tool line |
| BM25 k1, b | 1.5, 0.75 | — | Tool ranking |
| BM25 target K | 40 | tools | Retriever filters only above this |
| Grok schema cap | 110 | tools | Per-provider cap |
| `maxToolCallsPerTurn` | 8 | calls | Over-budget round → all calls `rateLimited` |
| Stream publish interval | 33 | ms | Throttle; sentence-complete publishing |
| HR tolerance | 5 | bpm | Verifier |
| Power tolerance | 15 | W | Verifier |
| DFA α1 tolerance | 0.10 | — | Verifier |
| HR drift tolerance | 1.5 | percentage points | Verifier |
| TSB tolerance | 2.0 | load units | Verifier |
| ATL / CTL tolerance | 3.0 | load units | Verifier |
| ACWR tolerance | 0.15 | ratio | Verifier |
| RMSSD tolerance | 8.0 | ms | Verifier |
| Recovery tolerance | 4.0 (0–100) / 1.0 (0–10) | points | Verifier, scale disambiguation |
| Sleep duration tolerance | 5 (precise) / 30 (whole hours) | min | Verifier |
| Sleep efficiency tolerance | 1.0 | percentage points | Verifier |
| Spelled-number range | 0–99, one decimal digit | — | Normaliser |
| Pending corrections cap | 4 | entries | Next-turn reminder |
| Correction-detector window | last 6 turns (user, non-local) | turns | Assertion detection |
| Numeric arg: `starting_atl`, `starting_ctl`, `daily_trimp` | 0–10,000 | TRIMP | Range check |
| Numeric arg: `gap_trimp` | (0, 10,000] | TRIMP | Range check |
| Numeric arg: `horizon_days` | 1–365, integer | days | Range check |
| Numeric arg: `lat` / `lon` | −90–90 / −180–180 | degrees | Range check |
| Numeric arg: `radius_m` | 5–5,000 | m | Range check |
| Numeric arg: `ordinal` | 0–100,000, integer | index | Range check |
| Numeric arg: `seconds` | 1–86,400, integer | s | Range check |
| Numeric arg: `max_results` | 1–10, integer | results | Range check |
| Lexicon concepts | 29 (+2 offensive) | count | Shared vocabulary |
| Languages | 17 | count | en + 16 shipped locales |
| `refuseBeforeSending` / `scrubFromOutput` / `neverInStaticCopy` | 12 / 21 / 12 | concepts | Group sizes |
| Sentence terminators | `. ! ? \n 。 ！ ？ ، ؟ …` | — | Segmentation |
| Emphasis markers stripped on retry | `* _ \`` | — | Output guard |
| Offensive-language recogniser confidence | 0.6 | probability | English-only entries |
| Offensive-language min words | 3 | words | English-only entries |
| Voice echo overlap | 0.40 | token fraction | Refusal echo trap |
| Linter prohibition window | 3 lines (match line and 2 above) | lines | Exemption |
| Linter snippet fragment | first 40 chars, ≥ 3 | characters | Exemption |
| Build-time English patterns | 62 | count | `user_facing_prohibited` |
| Coverage-gate minimum alternatives | 100 (985 at e028039) | count | Vacuity guard |
| Consent schema version | 8 | — | Per-provider consent |
| Request audit size | 10 | entries | In-memory FIFO |

---

## Appendix B: Pseudocode

**B.1 Registry tool resolution**

```
resolveTool(name, argsJSON):
  entry = findEntry(toolName == name) or return missing(invalidParameter, "unknown tool")
  if entry is action:
      args = parse(argsJSON) keeping only declared params, numbers/bools -> strings
      for p in entry.params where p.required and p not in args:
          return gate(name, argsJSON, missing(invalidParameter, "missing required arg p"))
      v = await entry.execute(args)
      return gate(name, argsJSON, v)
  key = entry.key, or entry.pattern with "$param" replaced by args[param]
        (missing/bad arg -> missing(invalidParameter))
  t0 = now; v = await resolveAsync(key); dt = now - t0
  if dt > 2.0: v = missing(internalError, "timed out")
  return gate(name, argsJSON, v)

gate(name, argsJSON, v):
  if v is missing:
      sig = name + "::" + argsJSON; count[sig] += 1
      return count[sig] > 2 ? missing(rateLimited, ...) : v
  if utf8len(envelope(v)) > 80000: return missing(tooMuchData, ...)
  return v
```

**B.2 Composite (async path)**

```
compositeAsync(entry, key):
  param = entry.key has "(" ? capture(entry.key, key) : nil
  deps  = entry.dependencies with "$name" -> param
  values = { d: await resolveAsync(d) for d in unique(deps) }
  saved = prefetch; prefetch = prefetch ∪ values
  r = entry.body(param, registry)        # body's registry.resolve(k) reads prefetch first
  prefetch = saved
  return r                               # {present:[{key,value}], missing:[{key,reason,detail}], status?}
```

**B.3 App-state number verification**

```
verifyAppState(text):
  (norm, rewrites) = normaliseSpelledNumbers(text)
  found = []
  for (pattern, actual, tol, fmt, negateOnSpelled) in metricChecks:
      for m in pattern.matches(norm):
          s = sentenceAround(m, norm)
          if s matches timeMarkers or targetMarkers: continue
          c = number(m.value); if negateOnSpelled and m.claim contains "negative": c = -|c|
          if |c - actual| > tol: found += (metric, fmt(c), fmt(actual), m.claimRange)
  apply recovery-scale rule and sleep sentence filters
  mapped = [remap(d.range, norm -> text, rewrites) for d in found]
  corrected = replace mapped ranges back-to-front in text with d.actual
  recordCorrections(mapped)              # dedupe (metric, claimed, actual); keep last 4
  return corrected

nextPromptVariableSections():
  block = takeAndClear(pendingCorrections)
  if block nonempty: append "# Last turn correction — DO NOT FABRICATE" + one line per entry
```

**B.4 User-assertion resolution**

```
signals = {}
for msg in reversed(lastSixTurns.filter(user and not localOnly)):
  t = statementsOnly(normaliseSpelledNumbers(msg))
  for metric in knownMetricsLongestFirst:
      v = lastMatch(metric, connector required if metric in {sleep, recovery}, no clock times)
      if v and metric not in signals.values: signals.values[metric] = v; blank matches
  fold aliases into canonical if canonical absent
  signals.contradicted |= containsPhrase(t) or startsWithCorrectionReply(t)
  signals.override     |= containsOverridePhrase(t)
if signals nonempty: prompt += userStatedBlock(signals)
if not (signals.contradicted or signals.override): prompt += dashboardLoadBlock
```

**B.5 Input guard**

```
onSend(text):
  t = trim(text); if empty: reject
  trig = first of [selfHarm, emergency, injury, rhythm, dangerJudgement] whose regexes match t
  if trig and (flagOn or trig == selfHarm):
      store(userTurn(t, localOnly=true), assistantTurn(replyFor(trig, appLanguage), localOnly=true))
      return                              # no provider, no consent prompt
  continue to consent check and provider send
history(turns) = turns.filter(not localOnly and not emptyAssistant)
```

**B.6 Streaming output guard**

```
onDelta(chunk):
  buf += chunk
  if now - lastPublish < 33ms: return
  (complete, tail) = splitAtLastTerminator(buf)   # decimal-aware
  if complete empty: return
  buf = tail
  visible += scrub(complete)
  if roundHasNoToolCall and published text has terminator: speakableCursor = len(visible)
onRoundEnd / onError / onStop:
  visible += scrub(buf); buf = ""
speak(utterance):
  synthesise(preamble + verify(scrub(utterance)))
```

**B.7 Coverage gate**

```
alts = [compile(latin ? "\b(?:"+a+")\b" : a) for a in literals(latin/unbounded arrays of lexicon*)]
fail(2) if any alt matches "" or len(alts) < 100
for p in buildTimePatterns:
  w = witness(p)                          # see 3.8 step 3
  if w == "": continue
  fail(2) if not p matches w
  gaps += p if no alt matches w
fail(1) if gaps else pass
```

---

## Appendix C: Source Map

| Method | Files (repository-relative) |
|---|---|
| Entry kinds, one-line-one-fact, namespace walk, pattern matching | `Emuqu/Sources/Assistant/Facts/FactCatalog.swift` |
| Key grammar | `Emuqu/Sources/Assistant/Facts/FactKey.swift` |
| Value union, absence taxonomy, availability, envelope | `Emuqu/Sources/Assistant/Facts/FactValue.swift` |
| Registry, rails, schema, hash, composites, timeout race | `Emuqu/Sources/Assistant/Facts/FactResolverRegistry.swift` |
| Numeric argument ranges | `Emuqu/Sources/Assistant/Facts/AppFactResolver+NumericArguments.swift` |
| Namespace registration; entries | `Emuqu/Sources/Assistant/Facts/AppFactResolver.swift`, `AppFactResolver+*.swift` |
| Provenance flags (`data_source`, `comparison_safe`) | `AppFactResolver+TrainingProjections.swift`, `AppFactResolver+WorkoutLiveDerived.swift`, `AppFactResolver+Sleep.swift` |
| Compact tools, allow-list, capability index | `Emuqu/Sources/Assistant/Facts/CompactToolRouter.swift`, `CompactToolRouter+Resolvers.swift` |
| BM25 retrieval | `Emuqu/Sources/Assistant/Facts/ToolRetriever.swift` |
| Tool loop, call budget, chat verification, fallback | `Emuqu/Sources/Assistant/ViewModel/AssistantViewModel+Tools.swift` |
| On-device dispatcher | `Emuqu/Sources/Assistant/Providers/AppleToolDispatcher.swift` |
| Number verifier, correction buffer | `Emuqu/Sources/Assistant/MetricsVerifier.swift` |
| Voice verification and scrub order | `Emuqu/Sources/Assistant/VoiceConversationController+Speech.swift` |
| User-assertion detector | `Emuqu/Sources/Assistant/UserAssertedValuesParser.swift` |
| Prompt composition (cache suppression, corrections) | `Emuqu/Sources/Assistant/Providers/AIProvider+SystemPrompt.swift`; rules A–D in `AIProvider+SystemPromptText.swift` |
| Lexicon and groups | `Emuqu/Sources/Assistant/MedicalTermLexicon.swift`, `MedicalTermLexicon+Injury.swift`, `MedicalTermLexicon+MetricVerdict.swift` |
| Input guard | `Emuqu/Sources/Assistant/MedicalQueryGuard.swift`; call site `Emuqu/Sources/Assistant/ViewModel/AssistantViewModel.swift`; echo trap `VoiceConversationController+Audio.swift` |
| `localOnly` turns | `Emuqu/Sources/Assistant/Providers/AIProvider.swift` (ChatTurn); `Emuqu/Sources/Assistant/ViewModel/AssistantViewModel+Context.swift` |
| Output guard, offensive list | `Emuqu/Sources/Assistant/CoachVoiceGuard.swift` |
| Streaming buffer | `Emuqu/Sources/Assistant/ViewModel/AssistantViewModel+Context.swift` (StreamTextBuffer) |
| Final pass | `Emuqu/Sources/Assistant/ViewModel/AssistantViewModel+Routing.swift` |
| Copy linter and configuration | `Tools/copy_linter/lint.py`, `Tools/copy_linter/prohibited_terms.json` |
| Coverage gate | `scripts/check_perimeter_sync.sh` |
| Consent | `Emuqu/Sources/Assistant/ProviderConsentTracker.swift` |
| Tests cited | `EmuquTests/MedicalQueryGuardTests.swift`, `MedicalQueryGuardTests+Injury.swift`, `CoachVoiceGuardTests*.swift`, `FactCatalogValidationTests.swift` |
| Validation register | `Tools/science_register/register.json` |
