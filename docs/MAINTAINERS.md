# Emuqu — Maintainer's Guide

> **This is the map.** Start here if you are taking over, auditing, or first
> exploring the codebase. It explains what Emuqu is, how the code is organized,
> the design rules everything follows, where every subsystem lives, and how the
> major flows move data end-to-end. It links out to the deep-dive docs rather
> than duplicating them — those are the source of truth for their subjects; this
> file is the source of truth for *how the pieces fit together and where to find
> them*.
>
> **Golden rule for this document:** it is a **map, not a mirror.** It records
> structure, responsibilities, and pointers — not algorithm internals or full
> API signatures (those live in [`ARCHITECTURE.md`](ARCHITECTURE.md) and
> [`API_REFERENCE.md`](API_REFERENCE.md)). When the code and this map disagree,
> **the code wins** — fix the map. See [§13 Keeping this document
> current](#13-keeping-this-document-current).

---

## 0. How to use this document

**If you are a human onboarding**, read §1 → §2 → §3 → §4 in order, then jump to
whichever subsystem you'll be touching (§5, §7, §8). Keep §5 (file map) and §12
(glossary) open in another tab.

**If you are an AI assistant answering a question about this repo**, use the
routing table below to jump straight to the relevant section, then follow its
`file_path:line` citations into the code. Every claim here is anchored to a file
so you can verify before answering.

### Quick routing — "I want to…"

| I want to… | Go to | Primary code |
|---|---|---|
| Understand what the app is and its external dependencies | [§1](#1-what-emuqu-is) | — |
| See the layered architecture / big picture | [§2](#2-architecture-at-a-glance) | — |
| Learn the coding rules & conventions before editing | [§3](#3-code-design-philosophy) | [`REFACTOR_SPEC.md`](REFACTOR_SPEC.md) |
| Find where a file or feature lives | [§5](#5-directory--file-map) | `Emuqu/Sources/` |
| Understand the core data types (the nouns) | [§6](#6-the-core-data-model) | `Emuqu/Sources/Models/` |
| Trace a flow end-to-end (the verbs) | [§7](#7-end-to-end-flows) | see each flow |
| Work on recording / HRV analysis / scoring | [§8.1](#81-recording--analysis) | [`ARCHITECTURE.md`](ARCHITECTURE.md) |
| Work on the AI assistant ("Flo") | [§8.4](#84-the-ai-assistant-flo) | [`FLO_ARCHITECTURE.md`](FLO_ARCHITECTURE.md) |
| Work on training-load math | [§8.2](#82-workout--training-load) | [`TRAINING_LOAD.md`](TRAINING_LOAD.md) |
| Understand storage / iCloud sync | [§8.5](#85-storage-sync--export) | [`ARCHITECTURE.md`](ARCHITECTURE.md#storage--sync) |
| Add a translation / localize a string | [§9.2](#92-localization) | [`LOCALIZATION.md`](LOCALIZATION.md) |
| Build, test, or ship | [§10](#10-build-test-ci--tooling) | `Makefile`, `.github/` |
| Handle an incident / App Store rejection / data-deletion request | [§11](#11-operations--runbooks) | [`runbooks/`](runbooks/) |
| Find the right doc for a topic | [§4](#4-documentation-map) | `docs/` |
| Look up a domain term (RMSSD, α1, TRIMP, ATL/CTL/TSB…) | [§12](#12-glossary) | — |
| Update this document correctly | [§13](#13-keeping-this-document-current) | — |

### Table of contents

1. [What Emuqu is](#1-what-emuqu-is)
2. [Architecture at a glance](#2-architecture-at-a-glance)
3. [Code-design philosophy](#3-code-design-philosophy)
4. [Documentation map](#4-documentation-map)
5. [Directory & file map](#5-directory--file-map)
6. [The core data model](#6-the-core-data-model)
7. [End-to-end flows](#7-end-to-end-flows)
8. [Subsystem reference](#8-subsystem-reference)
9. [Cross-cutting concerns](#9-cross-cutting-concerns)
10. [Build, test, CI & tooling](#10-build-test-ci--tooling)
11. [Operations & runbooks](#11-operations--runbooks)
12. [Glossary](#12-glossary)
13. [Keeping this document current](#13-keeping-this-document-current)

---

## 1. What Emuqu is

Emuqu is an **HRV (heart-rate-variability) recovery app for iOS and
watchOS**, with a live workout recorder and an integrated, provider-agnostic
AI assistant ("Flo"). It reads raw RR/PPI intervals from Polar Bluetooth
sensors, computes HRV metrics (the time-domain arithmetic is checked against
PhysioNet ECG-derived reference recordings; the composite recovery score is
not validated against outcomes, and the app says so), blends them with sleep
and vitals data from HealthKit into a daily recovery score, and lets the user
interrogate all of it in natural language.

- **@main entry:** `enum EmuquMain` (`Emuqu/EmuquApp.swift`) runs the pre-launch hooks, then hands off to `struct EmuquApp`
- **Marketing version 1.0 / build 3**, `PRODUCT_BUNDLE_IDENTIFIER com.chrissharp.flowrecovery` (`Emuqu.xcodeproj/project.pbxproj`)
- **Deployment targets:** iOS **17.0** minimum; watchOS **11.6**. Feature floors: narrative translation needs iOS 18.0, Apple Intelligence needs iOS 26.0 (hosted AI providers work on 17.0+).
- **App Group:** `group.com.chrissharp.flowrecovery` (shared container for the archive, backups, breadcrumbs, feedback).
- **UI:** SwiftUI throughout, MVVM-ish, Swift Concurrency (async/await + actors).

### System context (what talks to what)

```
                    ┌──────────────────────── iPhone (Emuqu app) ─────────────────────────┐
   Polar H10 /      │                                                                      │
   Verity Sense ───BLE──▶ Collection ──▶ Analysis ──▶ Storage ◀──CloudKit──▶ iCloud (user's │
   (RR / PPI)       │   (RRCollector,      (HRV,        (Archive,   private DB)             │
                    │    PolarManager)      scoring)     JSON+SHA)                          │
   Stryd / FTMS /   │        │                              │                              │
   Concept2 PM5 ───BLE──▶ WorkoutRecorder                   │                              │
   (power/cadence)  │        │                              ▼                              │
                    │        │                        Views (SwiftUI) ◀── ViewModels       │
   Apple Watch ──WatchConnectivity──▶ WatchConnectivityBridge   │                          │
   (mirror + HR)    │                              │            ▼                          │
                    │  HealthKit ◀── sleep/vitals/workouts ─▶ Assistant ("Flo") ──HTTPS──▶ Anthropic /
                    │  (read + write-back)                     tool-use over               OpenAI / Gemini /
                    │                                          Fact Catalog                Grok / DeepSeek
                    │  CoreLocation / MapKit / Open-Meteo / OSM (workout road + weather)   (BYO key)
                    │  Apple Intelligence (on-device LLM, iOS 26+) ◀── default provider    │
                    └──────────────────────────────────────────────────────────────────────┘
```

External systems, and where each is owned in code:

| External system | Purpose | Owned by |
|---|---|---|
| Polar H10 / Verity Sense (BLE) | Raw RR/PPI capture | `Emuqu/Sources/Collection/PolarManager.swift` |
| Stryd, FTMS trainers, Concept2 PM5 (BLE) | Workout power/cadence/rowing | `Emuqu/Sources/Collection/FootPodManager.swift`, `Concept2Manager.swift` |
| Apple HealthKit | Sleep, vitals, workouts, HR (read + write-back) | `Emuqu/Sources/Collection/HealthKitManager.swift` (+extensions) |
| Apple CloudKit (private DB) | Cross-device session backup | `Emuqu/Sources/Storage/CloudKitSyncManager.swift` |
| Apple Watch | Live workout mirror + optional strap | `Emuqu/Sources/Services/WatchConnectivityBridge.swift`, `EmuquWatch Watch App/` |
| Apple Intelligence (Foundation Models) | Default on-device LLM | `Emuqu/Sources/Assistant/Providers/AppleFoundationProvider.swift` |
| Anthropic / OpenAI / Gemini / Grok / DeepSeek | BYO-key cloud LLMs | `Assistant/Providers/*Provider.swift` |
| StoreKit 2 | Lifetime IAP ($9.99) and a 30-day free trial started by its own $0 purchase; paywall on since 2026-09-22 | `Emuqu/Sources/Services/StoreKitManager.swift`, `Emuqu/Sources/Services/EntitlementAnchor.swift` |
| Open-Meteo / OpenStreetMap / Apple Geocoder | Workout weather, trails, road names | `Emuqu/Sources/Services/WeatherService.swift`, `TrailDiscoveryService.swift`, `RoadGeocodingService.swift` |
| Tavily (optional) | Opt-in web search for the AI | `Emuqu/Sources/Services/WebSearchService.swift` |

For the full user-facing feature list see [`README.md`](../README.md) and
[`USERS_MANUAL.md`](USERS_MANUAL.md).

---

## 2. Architecture at a glance

Emuqu is a **single iOS app target** (`Emuqu`) plus a **watchOS companion**
(`EmuquWatch Watch App`), two test targets (`EmuquTests`, `EmuquUITests`), and a set of
docs/scripts. There is no backend server — the only network calls are to Apple
(CloudKit/HealthKit), the user's chosen LLM vendor, and a few free
map/weather/trail APIs during workouts.

### The layered module structure

All app source lives under `Emuqu/Sources/`, organized **by domain layer**. Data
flows roughly top-to-bottom on capture and bottom-to-top on display:

```
  Views/  ViewModels/            ← SwiftUI screens + per-screen state (the shell)
      ▲            │
      │            ▼
  Assistant/                     ← "Flo": chat + voice + tool-use over a Fact Catalog
      ▲            │
      │            ▼
  Services/                      ← cross-cutting app services (IAP, morning processing,
      ▲            │                location, notifications, translation, Watch bridge)
      │            ▼
  Analysis/  Export/  Import/     ← pure-ish physiology math, report generation, data I/O
      ▲            │
      │            ▼
  Collection/                    ← sensor capture + recording state machine (RRCollector,
      ▲            │                PolarManager, WorkoutRecorder, HealthKitManager)
      │            ▼
  Storage/                       ← on-disk JSON archive, encryption, CloudKit sync
      ▲            │
      │            ▼
  Models/  Protocols/  Utilities/ ← domain types, DI seams, Constants/Theme/Extensions
```

- **`Collection/` is the biggest and most stateful layer** — it owns the live
  hardware and the recording lifecycle. Its heart is `RRCollector`, decomposed
  into ~21 `RRCollector+*` extension files and five `@MainActor`
  `@Observable` **sub-objects** (see §9.1).
- **`Analysis/` is the physiology brain** — signal processing (artifact
  detection, time/frequency/DFA), window selection, the recovery-score
  calculator, sleep staging, baselines/trends, and workout analytics.
- **`Assistant/` is a near-self-contained module** — designed to be liftable
  into other apps; its only app-specific seam is the Fact Catalog resolvers. It
  has its own spec: [`FLO_ARCHITECTURE.md`](FLO_ARCHITECTURE.md).
- **`Views/` is the largest file count** (~203 files) but the thinnest logic —
  screens observe view models / collector sub-objects and render.

### The C4 "container" view

| Container | What it is | Key entry file |
|---|---|---|
| **Emuqu (iOS app)** | The whole product | `Emuqu/EmuquApp.swift` → `Emuqu/Sources/Views/MainTabView.swift` |
| **EmuquWatch (watchOS)** | Live-workout mirror + wrist controls + optional direct strap | `EmuquWatch Watch App/WatchApp.swift` |
| **EmuquTests** | Unit tests (192 files) | `EmuquTests/` + `Emuqu.xctestplan` |
| **EmuquUITests** | XCUITest UI tests (18 files) | `EmuquUITests/` |

### The five tabs (navigation spine)

The UI is a 5-tab bar defined by `MainTabView.Tab`
(`Emuqu/Sources/Views/MainTabView.swift`). Two tabs can be hidden (Fitness
via Settings → Modes; Flo via its master toggle), collapsing to as few as 3.

| Tab (`Tab` case) | Label | Root view | Purpose |
|---|---|---|---|
| `.dashboard` | Dashboard | `DashboardV2View` | Recovery score ring, recent sessions, "Ask Flo" + report toolbar. |
| `.record` | Record | `RecordView` | Start/monitor an HRV reading (overnight or quick); data recovery. |
| `.fitness` | Fitness | `FitnessTabView` | Live workout recording + post-workout summary/PDF. |
| `.coach` | **Flo** | `CoachHomeV2View` | Conversational AI assistant. |
| `.more` | More | `MoreMenuView` | Trends, Settings, Help, About (History nests here / under Dashboard). |

> Retired enum cases (`.assistant`, `.history`, `.trends`, `.settings`) survive
> only for deep-link/back-compat routing (`MainTabView.Tab`).

---

## 3. Code-design philosophy

The single source of truth for how code should be written here is
[`REFACTOR_SPEC.md`](REFACTOR_SPEC.md) — a **standing
specification**, not a feature list. It applies to every sweep through the code.
This section is the short version; read the spec before any non-trivial change.

### The four pillars

1. **Refactor = behavior preserved, structure upgraded.** If behavior changes,
   it is a *feature change* and must be a separate, explicit step.
2. **Functional core, imperative shell.** Pure logic inside; side effects
   (BLE, disk, network, HealthKit, UI, time, randomness) pushed to the edges.
3. **Make illegal states unrepresentable.** Encode invariants in types and
   validation, not tribal knowledge.
4. **Small, explicit, boring.** Boring code ships, debugs, and refactors well.

### Non-negotiables (enforced culturally + by CI budgets)

- **Pure functions first**, **immutable/one-directional data flow**, **single
  responsibility**, **small functions** (5–15 lines target, 20 a yellow flag),
  **meaningful names** (`calculateOvernightHrvBaseline`, not `processData`).
- **Composition over inheritance**; protocols only where they *reduce* coupling.
- **Explicit error handling** — no swallowed errors, no empty catches; the
  `.ci/try_budget.txt` guard caps silent `try?` usage.
- **Zero tolerance for magic** — no hidden global mutable state, no
  stringly-typed APIs, **no magic numbers in logic**. All thresholds live
  centralized and named in `Emuqu/Sources/Utilities/Constants.swift` (+`Constants+RecoveryScore.swift`).
- **Explicit dependency wiring** — the only place allowed to create real
  dependencies is the wiring/boundary shell. `RRCollector.makeDefault()` is the
  production composition root (there is no DI framework); the `Protocols/` seams
  exist for test doubles.

### Conventions you will see everywhere (so you can pattern-match)

| Convention | What it looks like | Why |
|---|---|---|
| **Extension file-splitting** | `Foo.swift` + `Foo+Bar.swift`, `Foo+Baz.swift` | Keep each file readable in one sitting; one concern per file. Big objects (RRCollector, HealthKitManager, AppFactResolver, PDFReportGenerator, Archive) are split this way. |
| **Centralized constants** | `Constants.swift` namespaced enums (`RecoveryScoreConstants`, `ScoringWeights`, `FeatureFlags`, …) | No magic numbers in logic; scoring thresholds auditable in one place. |
| **Centralized theme** | `Utilities`/`Views` `AppTheme` / `Theme.swift` | Colors, typography, accent themes in one surface. |
| **Per-screen archive subscription** | each screen owns its own `recentSessionsAsync(...)` refresh `Task` | Load limits are per-screen, not tab-routing-dependent (see [`ARCHITECTURE.md` → UI Session Load Contract](ARCHITECTURE.md#ui-session-load-contract)). |
| **Sub-object observation** | views observe `collector.deviceStatus`, not `collector` | The parent `RRCollector` publishes nothing after decomposition; observing it silently breaks re-render (§9.1). |
| **Kill switches, not deletions** | `FeatureFlags` per-provider/per-feature switches | Disable a risky path in a release without ripping code out (§9.5). |
| **Fail loud, degrade explicitly** | `nil` with a `missingReason`, `Status` enums (e.g. LiveDFA warmup/stalled/ok) | No silent fallbacks that hide broken data. The AI's tool envelope carries `missingReason` so absence is structural. |
| **Sorted-keys JSON on cache paths** | `JSONEncoder.outputFormatting = [.sortedKeys]` for LLM tool schemas | One byte of key-order drift misses the provider prompt cache (P0 rule). |

### What NOT to do

No sweeping rewrites, no "while I'm here" changes, no new abstraction that
doesn't delete more complexity than it adds, no new global/hidden state, no new
magic numbers. The [Refactor Completion Checklist](REFACTOR_SPEC.md#refactor-completion-checklist-hard-gate)
is the hard gate.

---

## 4. Documentation map

Everything under `docs/` plus the root docs. **This guide (`MAINTAINERS.md`) is
the index; the others are the depth.**

| Doc | Scope — read it when you need… | Size |
|---|---|---|
| [`MAINTAINERS.md`](MAINTAINERS.md) *(this file)* | Orientation: structure, file map, flows, cross-references | — |
| [`../README.md`](../README.md) | The full feature list, requirements, navigation, tech highlights | ~320 ln |
| [`USERS_MANUAL.md`](USERS_MANUAL.md) | End-user behavior of every tab, screen, and feature | ~1800 ln |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | **Algorithms & design decisions** — recording strategy, HRV math, window selection, recovery-score tiers, sleep pipeline, storage, location subsystems, workout math | ~1440 ln |
| [`API_REFERENCE.md`](API_REFERENCE.md) | **Public Swift API surface** — type signatures, model shapes, contracts | ~3240 ln |
| [`FLOWCHART.md`](FLOWCHART.md) | **Data flow**, step-by-step: recording → analysis → display, workout pipeline, AI dispatch, session lifecycle, mutation contracts | ~1660 ln |
| [`FLO_ARCHITECTURE.md`](FLO_ARCHITECTURE.md) | **The AI module spec** — turn lifecycle, provider matrix, Fact/tool system, routing, voice, safety gates | ~1180 ln |
| [`VOICE_AND_TOOL_USE.md`](VOICE_AND_TOOL_USE.md) | AI fact catalog contents, tool-use path, voice-mode design, known failure modes | ~950 ln |
| [`TRAINING_LOAD.md`](TRAINING_LOAD.md) | End-to-end ATL/CTL/TSB derivation: per-workout load → EWMA → verdicts | ~230 ln |
| [`LOCALIZATION.md`](LOCALIZATION.md) | Source-of-truth rules, how to add a translation, what not to localize | ~180 ln |
| [`REFACTOR_SPEC.md`](REFACTOR_SPEC.md) | **The coding standard** — principles, non-negotiables, completion checklist | ~430 ln |
| [`runbooks/`](runbooks/) | Operational playbooks — incident, hotfix, App Store rejection, data deletion | 5 files |

### Topic ownership — one source of truth per topic

To keep the docs non-redundant, **each topic is *stated* in exactly one doc;
every other doc *links* to it rather than restating it.** Redundancy is how docs
drift (the AI tool-call budget was once documented as `4` in ARCHITECTURE while
the code and VOICE said `8`). When you're about to write a fact that lives in
another doc's territory, link instead. The only allowed overlap is a short
orientation *summary* that points onward — never a second copy of the details.

| Topic | Single source of truth | Everyone else |
|---|---|---|
| What the app does (features) | `README.md` | link, don't restate |
| How to use each screen | `USERS_MANUAL.md` | link |
| Physiology & algorithm design (HRV, scoring, sleep, windows) | `ARCHITECTURE.md` | link |
| Training-load derivation (TRIMP → ATL/CTL/TSB) | `TRAINING_LOAD.md` | link |
| **AI module internals** (routing, tool-use, providers, voice, prompt cache) | `FLO_ARCHITECTURE.md` (+ `VOICE_AND_TOOL_USE.md` for fact-catalog contents & voice field-notes) | link — `ARCHITECTURE.md` keeps **only** the fitness-integration seam |
| Public Swift API shapes | `API_REFERENCE.md` | link |
| Step-by-step data flow | `FLOWCHART.md` | link |
| Coding standard | `REFACTOR_SPEC.md` | link |
| Localization workflow | `LOCALIZATION.md` | link |
| Ops playbooks | `runbooks/` | — |
| Where things live / how it all fits (this map) | `MAINTAINERS.md` | — |

**Precedence:** when two docs disagree, prefer the one that *owns* the topic
above. When any doc disagrees with the code, **the code wins** — fix the doc.

---

## 5. Directory & file map

The exhaustive "where does X live" reference. Counts are approximate and will
drift — treat them as scale indicators, not invariants. Directories are under
`Emuqu/Sources/` unless noted.

### 5.0 Top-level repository

| Path | Purpose |
|---|---|
| `Emuqu/` | Main iOS app target (source, `Assets.xcassets`, `Info.plist`, entitlements, `Localizable.xcstrings`). |
| `Emuqu/EmuquApp.swift` | `@main` (`EmuquMain`) and `EmuquApp` — launch, singleton wiring, deferred boot, launch-modal gating. |
| `Emuqu/Sources/` | All app Swift source, by layer (below). |
| `EmuquTests/` | Unit tests (192 files). |
| `EmuquUITests/` | XCUITest UI tests (18 files). |
| `EmuquWatch Watch App/` | watchOS companion (§8.6). |
| `Emuqu.xcodeproj/` | Xcode project (Xcode 26.1 pinned). |
| `Emuqu.xctestplan` | Test plan used by CI + `make test`. |
| `docs/` | All documentation (§4). |
| `scripts/` | CI/dev shell + python (coverage floor, lint budgets, sim destination, hook install). |
| `Tools/copy_linter/` | `lint.py` + `prohibited_terms.json` — "copy perimeter" that blocks prohibited medical-claim language. |
| `.ci/` | Plain-text numeric budgets (swiftlint warnings, large-file count, coverage floor, `try?` budget, shared-usage budget). |
| `.github/` | `workflows/` (`ci.yml`, `testflight.yml`, `performance.yml`), CODEOWNERS, dependabot, `SECURITY.md`. |
| `.githooks/pre-commit` | SwiftFormat + SwiftLint before commit (install via `make setup-hooks`). |
| `Makefile` | Dev/CI entry points (§10). |
| `README.md`, `LICENSE` | Overview; PolyForm Strict 1.0.0 source-available, no-derivatives license. |
| `.swiftlint.yml` / `.swiftlint-strict.yml` / `.swiftformat` | Lint & format config. |
| `.env.example` | Local overrides for the coverage script (SCHEME/PROJECT/MIN_COVERAGE). |

### 5.1 `Analysis/` — physiology math + scoring (~74 files)

The signal-processing and scoring engine. Mostly pure transforms.

- `HRVAnalysisPipeline.swift` — top-level orchestrator: raw RR → `AnalysisResult`.
- `RecoveryScoreCalculator.swift` (+`+Composite`, `+Tiers`, `+Training`, and the `+DetailForwarding` / `+ReadinessForwarding` / `+VitalsForwarding` shims) — composite 0-100 recovery score (HRV 60 / Sleep 25 / Vitals 15).
- Signal metrics: `TimeDomainAnalysis`, `FrequencyDomainAnalysis`, `NonlinearAnalysis`, `DFAAnalysis`, `LiveDFAAnalyzer` (rolling α1 during workouts).
- `WindowSelection.swift` (+`+Evaluation`, `+Filters`) — picks the best recovery window (score = RMSSD × stability), not raw peak RMSSD.
- Workout analytics: `WorkoutAnalyzer.swift`, `WorkoutAnalysisSnapshotBuilder.swift`, `WorkoutLiveTrends.swift`, `WorkoutAlpha1Reanalyzer`, `BarometricAltitudeProcessor`, `TopoElevationService`.
- Baselines/trends/load/sleep: `BaselineTracker`, `TrendAnalysis`, `TrainingLoadRegistry`, `HeatAcclimation`, `SleepScienceAnalyzer`, `SleepResolver`, `AnalysisSummaryGenerator` (narrative).
- Track I/O: `CSVExporter`, `GPXExporter`, `TCXExporter`, `GPXImporter`.
- **`CauseDetection/` (7 files)** — rule engines explaining *why* a score is high/low: `CauseDetector` + Metric/Pattern/Positive/Severe/Sleep/Tag detectors.

### 5.2 `Collection/` — sensor capture + recording lifecycle (~135 files)

The largest, most stateful layer. Owns hardware and the recording state machine.

- **`RRCollector.swift` + `RRCollector+*` extensions** — the core object.
  Extensions cover Lifecycle, Reanalysis, Streaming, morning processing,
  migrations, etc. Decomposed into five sub-objects (§9.1), plus two
  coordinators that own whole responsibilities rather than state slices:
  `SessionRecoveryCoordinator` (everything that rescues a recording that did
  not end cleanly) and `OvernightStreamingCoordinator` (bluetooth-central
  overnight capture — start, keep-alive, reconnect, morning gather, strap
  merge). Each is a value holding the collector strongly, built on demand
  (`collector.recovery`, `collector.overnightStreaming`); the collector keeps
  thin forwarders so call sites did not move with the split. See ADR 005 for
  why they are not `unowned` back-pointers.
- `PolarManager.swift` (+`+Streaming`, `+Recording`, `+Observers`) — Polar BLE.
- `HealthKitManager.swift` (+`+HRV`, `+HeartRate`, `+SleepTrends`, `+Store`, `+Heat`) — HealthKit read/write. Three query classes hold the reads: `VitalsHealthQueries`, `TrainingHealthQueries` and `SleepHealthQueries`. Sleep export, trend analysis and the observers stay on `+SleepTrends` — those write and observe, which is a different job with different failure modes.
- `WorkoutRecorder.swift` (+`+Lifecycle`, `+Ticker`, `+Start`, `+Stop`, `+Metrics`) — live workout; with `WorkoutLocationManager`, `WorkoutMotion`, `WorkoutPedometer`, `WorkoutHR`. `WorkoutAIContextBuilder` owns everything the assistant is told about a workout in progress (context snapshot, route topology, climbs ahead, live weather, interval progress, threshold breaches, split paces, grade) — the recorder's largest piece that is not the recording pipeline.
- Extra devices: `Concept2Manager` (PM5 rower), `FootPodManager` (Stryd RSC + FTMS bike), `ZwiftPeripheralBroadcaster`.
- Recording support: `BackgroundAudioManager`, `BackgroundLocationManager` (now a workout-only/no-op stub overnight), `BreathingAudioManager`, `IntervalController`, `SleepData`/`SleepMergingPipeline`, `TrainingLoad`/`TrainingMetrics`, `RecoveryVitals`, `SessionState`, `RecordingPhase`.
- **Pure logic lifted out of the big three** (2026-09-01). Each of these was
  `private static` on a 3,000–5,000-line class, which meant it could only be
  reached through one entry point and could not be tested at all. Each is now a
  namespace or value type with its own suite:

  | Type | What it owns | Why it left |
  |---|---|---|
  | `METLookup` | Ainsworth / Concept2 MET tables by sport and pace | Feeds active energy written to Apple Health; the tables had no test |
  | `WorkoutTickState` | `TrackBackupWatermark`, `AutoPauseDetector` | Compare-then-assign across three cursors, and two counters plus their thresholds, that only ever moved together |
  | `WorkoutStartCue` | Haptic + chime + TTS start confirmation, pre-warmed | Self-contained mechanism with a pre-warm contract stated in a comment halfway down a lifecycle extension |
  | `SleepRefreshPolicy` | May sleep be refreshed; is it an improvement; what to update | Two production regressions (2026-08-03 scoring window, 2026-08-05 onset move) in logic no test could reach |
  | `HRSleepEstimator` | Sleep boundaries inferred from heart rate alone | Its onset clamp had to be fixed three times in three sibling detectors before all of them had it |

  Where an external caller already existed, a one-line forwarder stayed behind
  (`HealthKitManager.estimateSleepFromHR`), so no call site changed meaning.

### 5.3 `Assistant/` — the "Flo" AI subsystem (~108 files)

Near-self-contained; see [`FLO_ARCHITECTURE.md`](FLO_ARCHITECTURE.md). Layout:

- **root (15):** `VoiceConversationController.swift` (+`+Audio`) — app-wide voice chat; `VoiceEchoHeuristics` — the token-overlap rules that decide whether recognised speech is the mic hearing the app's own TTS (three call sites shared this comparison and one carried its own drifting copy of the tokeniser); `WorkoutVoiceCoach`, `WorkoutTriggerEngine`, `WorkoutMileMarkerEngine`, `TurnAlertEngine`, `TurnMarkerEngine` — mid-workout spoken coaching; `MedicalQueryGuard`, `CoachVoiceGuard`, `MetricsVerifier` — safety guards; `TTSTextNormalizer`, `SpokenTextChunker`, `PhoneticOverrides` — speech prep.
- **`Providers/` (11):** `AIProvider.swift` (protocol + ToolSpec + stream event) + `AppleFoundationProvider` (on-device) and its `AppleFoundationToolAdapter`/`AppleToolDispatcher`, `AnthropicProvider`, `OpenAIProvider`, `GeminiProvider`, `GrokProvider`, `DeepSeekProvider`, `OpenAICompatibleStreamer`, `ProviderRegistry`.
- **`Facts/` (18):** `AppFactResolver.swift` (+`+Live`, `+Settings`, `+Sleep`, `+Workout`) — resolves app data into facts; `FactCatalog`, `FactKey`, `FactValue`, `CompactToolRouter`, `SmartProviderRouter`, `TierProviderMapper`, `CapabilityClassifier`, `DeterministicIntent`, `AppleContextCompactor`, `PrefetchService`, `LLMCacheTelemetry`.
- **`Chat/` (12):** `ConversationStore`, `AssistantInbox`, `SpeechInputManager`, `WhisperKitSTTBridge`/`STTProvider`, `UserFactsStore`, `AssistantEmailBridge`, `AssistantCitationResolver`, `PrefabQuestions`, `AnalysisSummaryCache`, `AssistantContextSource`.
- **`Context/` (4):** `AssistantContext`, `ContextBuilder`, `AppKnowledgeBase`, `LiveWorkoutBroker`.
- **`ViewModel/` (2):** `AssistantViewModel.swift` (+`+Tools`).
- **`Views/` (10):** `AssistantChatView`, `AssistantTab`, `ChatBubble`, `ModelPicker`, `ProviderConsentSheet`, `AIAssistantSettingsPage`, `DisclaimerSheet`, `CitationQuickView`, `TypingIndicator`, `PrefabQuestionChips`.
- **`Keys/` (1):** `APIKeyStore.swift` — Keychain-backed provider key store.

### 5.4 `Services/` — cross-cutting app services (~46 files)

- IAP + platform: `StoreKitManager` (lifetime IAP, $9.99, live) + `EntitlementAnchor` (durable trial/beta anchor), `WatchConnectivityBridge` (Watch↔phone), `WidgetDataPublisher` (orphaned writer — widget removed, §9.5), `DataPurgeService` ("Delete all my data").
- Recovery/morning pipeline: `AnalysisService`, `ReanalysisService`, `MorningProcessingService`, `MorningNotificationScheduler`, `SessionRecoveryService`, `SessionAcceptanceService`, `WorkoutRecoveryService`, `PowerStatePolicy`.
- Location/road/nav stack: `AmbientLocationService`, `RoadGeocodingService`, `RoadGraphService`, `RoadAwarenessEngine`, `DirectionsService`, `ActiveRouteSession`, `OSMNominatimService`, `LocationFinder`, `TrailDiscoveryService`, `SurroundingsPOIService`, `JourneyIntelligenceService`, `BreadcrumbRecorder`/`BreadcrumbStore`, `AudioSessionCoordinator`.
- Data/localization: `LanguageManager` (localization singleton), `NarrativeTranslator` (on-device translation), `WeatherService`, `WebSearchService`.

### 5.5 `Storage/` — persistence, encryption, sync (~31 files)

- `Archive.swift` (+`+Merge`, `+Migrations`, `+Repair`) — the on-disk session archive (JSON in the App Group, SHA-256 integrity, in-memory index).
- iCloud: `CloudKitSyncManager`, `CloudKitLiveBackupManager`, `CloudKitSyncState`, `Reconciliation`.
- Support: `EncryptionManager`, `DataCompression` (ZLIB), `RawRRBackup`, `WorkoutTrackBackup`, caches (`SleepDataCache`, `UIStateCache`, `RespiratoryBaselineCache`, `WristTemperatureBaselineCache`), `SessionStorageDiagnostic`.

### 5.6 `Models/` — domain types & settings (~28 files)

`HRVSession` (the central record), `SettingsManager`/`UserSettings` (persisted
settings singleton — drives launch gating), `RRModels`, `WorkoutMetadata` /
`WorkoutAnalysisSnapshot` / `WorkoutThreshold`, `Route` / `SavedRoute`,
`IntervalPlan`, `ScoreVerdict`, `MorningFeelingTag`, `DashboardSessionPolicy`,
`UnitsPreference`, `EmailContact`. (See §6.)

### 5.6b `Emuqu/Sources/Models/SleepSchedule.swift`

Extracted from `UserSettings.swift` 2026-08-18 when that file crossed the
1,500-line budget. Owns every derived sleep time — overnight window, morning
cutoff, daytime-HR window, nap window — all as pure functions of a reference
date. Covered by `AcquisitionPureLogicTests`, which is where a **inverted
daytime-HR window** was found: `daytimeHRStart` shifted wake forward a day and
`daytimeHREnd` did not shift bedtime, so for every ordinary schedule (including
the shipped 22:00 default) the window ran backwards, the `HKQuery` predicate
matched nothing, and daytime resting HR silently never resolved for anyone.

### 5.7 `Protocols/` — DI seams (1 file)

`HealthKitServiceProtocol` — the only load-bearing one. Injected into six
production types (`SleepBoundaryResolver`, `HRVAnalysisPipeline`,
`ReanalysisService`, `SessionRecoveryService`, `MorningProcessingService`,
`SessionAcceptanceService`) and substituted by `MockHealthKitService` in tests.

`AnalysisServiceProtocol`, `PolarManagerProtocol` and `SessionRepositoryProtocol`
were **removed 2026-08-18**. Each had a single conformer and no production call
site that used it as a type; two had no test double either. That is precisely
the "interfaces with one implementation" the refactor spec's completion
checklist forbids. Two had already been emptied to tombstone comments because
deleting a file with explicit pbxproj build membership was awkward —
`scripts/remove_swift_file.py` now does that cleanly, so they are gone.

### 5.8 `Utilities/` (~20 files)

`Constants.swift` (+`+RecoveryScore`) — **all magic numbers**; `Extensions`,
`Statistics`, `Errors`, `DebugLog`, `CrashLogManager`,
`SystemDiagnosticsManager`, keyboard helpers (`GlobalKeyboardDismissal`,
`KeyboardWarmer`, `KeyboardPerfSignpost`), `PendingScoreChange`.

### 5.9 `Views/` (~203 files) + `ViewModels/` (2 files)

> **Known deviation, not the intended layering.** 145 view files against 2 view
> models means most screens hold their logic inline. Since 2026-09-03 no view
> reaches a singleton directly: services come in through
> `@Environment(\.dependencies)` (see §9.4), which is the seam a test or a
> preview substitutes. The logic-in-views shape remains; treat it as the thing
> not to copy: when
> you touch a view for another reason, lift its computation into a testable
> free function rather than adding to the inline pile.


SwiftUI screens (thin logic). Roots: `MainTabView` (nav), `DashboardV2View`,
`RecordView`, `FitnessTabView`, `CoachHomeV2View`, `MoreMenuView`. Detail views
(`HRVDetailV2View`, `SleepDetailV2View`, `VitalsDetailV2View`,
`TrainingDetailView`, `TrendsV2View`, `RecoveryScoreDetailView`,
`WorkoutSummaryV2View`), gating UI (`PaywallView`, `HealthDisclaimerView`,
`ScoreArchitectureChangeSheet`), `SettingsView` + ~15 `*SettingsPage.swift`,
the workout flow (`FitnessStartWorkoutFlow`, `WorkoutPreflightView`,
`FitnessRecordingView`, …), `Theme.swift`, `HelpCenterV2View`, `HistoryView`,
`DiscoverTrailsView`, `GetMeBackView`, `ImportDataView`. Subdirs:
`Onboarding/` (8), `MorningResults/` (7), `Record/` (5), `Results/` (3),
`Utilities/` (6, e.g. `ShareSheet`, `PDFPreviewView`). `Components/` is
currently empty. The two view models (`HistoryViewModel`,
`MorningResultsViewModel`) live in `ViewModels/`; other screens use inline
`@State` objects or the collector sub-objects.

---

## 6. The core data model

The nouns. These are the types that get created during recording, persisted to
the archive, synced to iCloud, and surfaced to the UI and the AI. Full field
lists are in [`API_REFERENCE.md`](API_REFERENCE.md#data-models); this is the
orientation.

| Type | File | What it is |
|---|---|---|
| **`HRVSession`** | `Emuqu/Sources/Models/SessionMetadata.swift` (`HRVSession`) | **The central record.** One recording (overnight or quick) or workout. Holds `analysisResult`, `sleepSnapshot`, `vitalsSnapshot`, `rrSeries`, tags, notes, `recoveryScore` (1-10 stored), `sessionType`, `linkedSessionIds`. |
| **`SessionArchiveEntry`** | `Emuqu/Sources/Models/SessionMetadata.swift` (`SessionArchiveEntry`) | Lightweight **in-memory index** row — metadata only (no `rrSeries`) so trends/lists/AI can scan the whole archive cheaply. Carries score, means, tags, sleep-stage minutes, `sleepEnd`, `fileHash`, `filePath`. |
| **`HRVAnalysisResult`** | `Emuqu/Sources/Models/RRModels.swift` | The computed HRV payload (time/frequency/nonlinear metrics, window info, artifact %). The doc's "AnalysisResult". |
| **`ANSMetrics`** | `Emuqu/Sources/Models/RRModels.swift:456` | Autonomic metrics incl. the HRV-only `readinessScore` (1-10). |
| **`RRPoint` / RR models** | `Emuqu/Sources/Models/RRModels.swift` | Raw RR-interval primitives (`t_ms`, `rr`, wall-clock). |
| **`SleepData`** | `Emuqu/Sources/Models/SleepData.swift` (`SleepData`) | Sleep snapshot — stages, boundaries, efficiency, latency. |
| **`RecoveryVitals`** | `Emuqu/Sources/Models/RecoveryVitals.swift` | Vitals snapshot — resting HR, respiratory rate, wrist temp, SpO2. |
| **`UserSettings`** / **`SettingsManager`** | `Emuqu/Sources/Models/UserSettings.swift` | User profile + prefs (value type); `SettingsManager.shared` is the live `@Observable` store. Drives launch gating. |
| **`WorkoutMetadata` / `Sport`** | `Emuqu/Sources/Models/WorkoutMetadata.swift` | Workout type + samples (HR, power, cadence, GPS, elevation). |
| **`WorkoutAnalysisSnapshot`** | `Emuqu/Sources/Models/WorkoutAnalysisSnapshot.swift` | Persisted workout analysis (built by `Emuqu/Sources/Analysis/WorkoutAnalysisSnapshotBuilder.swift`). |
| **`WorkoutThreshold`** | `Emuqu/Sources/Models/WorkoutThreshold.swift` | User-declared physiological constraint for the live coach (HR/power/pace/α1/cadence + debounce/cooldown). |
| **`IntervalPlan` / `IntervalStep`** | `Emuqu/Sources/Models/IntervalPlan.swift` | Structured interval workout. |
| **`Route` / `SavedRoute`** | `Emuqu/Sources/Models/Route.swift`, `SavedRoute.swift` | GPS route + user-named saved route (with climb queue). |
| **`ScoreVerdict`, `MorningFeelingTag`, `UnitsPreference`, `DashboardSessionPolicy`, `EmailContact`** | `Models/` | Recovery verdict enum; subjective feeling tag; unit prefs; cold-start dashboard seeding; report email recipients. |

**Persistence shape:** an `HRVSession` is JSON-encoded to one file per session in
the App Group container, with a SHA-256 hash for integrity, and mirrored as a
compressed `CKAsset` in the user's private CloudKit database. The heavy
`rrSeries` (≈0.7–1.5 MB overnight) is skippable on decode via
`retrieveLightweight()` for list/trend loads.

---

## 7. End-to-end flows

The verbs. Each flow lists the sequence with `file_path:line` anchors and points
to the deep-flow doc ([`FLOWCHART.md`](FLOWCHART.md)) for the exhaustive version.

### 7.1 App launch & navigation

1. `EmuquApp` (`Emuqu/EmuquApp.swift`, started by `@main enum EmuquMain`) creates the shared
   observable graph as `@State` objects and injects it via `.environment`: `collector`
   (`RRCollector.makeDefault()`) + its five sub-objects, `syncManager`,
   `settingsManager`, `storeKitManager`, `languageManager`, `voiceChat`,
   `watchBridge`, `emailBridge`.
2. **Singleton inits stay lightweight**; heavy hardware/network setup is deferred
   to `boot()` methods fired after first paint via `runDeferredBoot()`
   (`EmuquApp.swift:777`). An 8 s safety timeout force-clears the splash if a
   background init hangs.
3. `MainTabView` always renders; **launch gating** is a `LaunchModal` enum
   (`EmuquApp.swift`) presented over it via `.fullScreenCover(item:)`. Order
   in `loadDataAndContinue()` (`Emuqu/Sources/Services/AppLaunchTasks.swift`): disclaimer not accepted →
   `HealthDisclaimerView`; onboarding not done → `OnboardingView`; no
   entitlement and no active trial → `PaywallView`; in-trial → `TrialReminderView`;
   score-architecture change unacknowledged → `ScoreArchitectureChangeSheet`;
   else check for an interrupted session.
4. Each tab is its own `NavigationStack`; tapping a tab resets its path
   (`MainTabView.resetPath(from:to:)`).

### 7.2 Overnight recording → recovery score → dashboard

The spine of the product. Full version: [`FLOWCHART.md` §2–§5](FLOWCHART.md).

1. **Start** — `RRCollector.startOvernightStreaming(sessionType:useDeviceInternalBackup:)`
   (`Emuqu/Sources/Collection/RRCollector+OvernightStreaming.swift:50`). Begins BLE streaming;
   on an **H10** it also arms device-internal recording as a backup (Verity Sense
   never uses internal recording). A streaming timer does time-based incremental
   raw-RR backup (~60 s) and force-backs-up on reconnect.
2. **Reconnect resilience** — the SDK reconnects a dropped strap itself;
   `StrapLinkCoordinator` (`Emuqu/Sources/Collection/StrapLinkCoordinator.swift`)
   re-asserts the connect and gives the session `PolarReconnectPolicy.windowSeconds`
   (20 min) before `reconnectExhausted`. See
   [`ARCHITECTURE.md` → Strap Link and Reconnection](ARCHITECTURE.md#strap-link-and-reconnection).
3. **Stop** — `RRCollector.gatherOvernightData()`
   (`RRCollector+OvernightStreaming.swift:311`): stops the timer, flushes
   streaming to disk, stops streaming, sets phase `.analyzing`, fetches the H10
   internal recording.
4. **Pick the best source** — `DataSourceSelector.selectBestSource(...)`
   (`Emuqu/Sources/Collection/DataSourceSelector.swift:40`): internal → composite (if internal
   has ≥5% fewer beats) → streaming → raw backup. Composite gap-fill uses a 2 s
   gap threshold (`:183`).
5. **Analyze** — `HRVAnalysisPipeline` (`Emuqu/Sources/Analysis/HRVAnalysisPipeline.swift`).
   `analyzeWithAutoWindow` (`:194`) runs `WindowSelector.findBestWindow` over the
   30–70 % band of *actual sleep*, then `analyzeWithWindow`: artifact flags →
   time domain → nonlinear/DFA → frequency domain → ANS metrics.
6. **Score** — `RRCollector.computeRecoveryScore(...)`
   (`RRCollector+Analysis.swift:13`) → `RecoveryScoreCalculator.calculateWithBreakdown`
   computes the composite **0–100** (HRV 60 / Sleep 25 / Vitals 15, with tier
   fallback and comeback-mode reweighting), then stores it **1–10** via
   `toTenScale` (`:78`). All thresholds live in `Constants+RecoveryScore.swift`.
7. **Archive + notify** — the session is pre-archived for crash safety
   (`archive.archive(finalSession)`), `archiveSignal.notifyChanged()` bumps
   `archiveVersion`, and CloudKit upload fires.
8. **Display** — `DashboardV2View` re-fetches via `recentSessionsAsync(limit: 35)`
   keyed on `archiveVersion` + `pullVersion`, and renders the score ring, cards,
   and insights.

> **Pause/Resume (split sleep)** and **same-night separate sessions** merge
> segments before window selection so the score reflects the whole night — see
> [`FLOWCHART.md` §3, §8](FLOWCHART.md) and [`ARCHITECTURE.md` → Pause & Resume](ARCHITECTURE.md).

### 7.3 Workout recording → summary

1. **Start** — `WorkoutRecorder` (`Emuqu/Sources/Collection/WorkoutRecorder.swift`, MainActor
   orchestrator) auto-reconnects the last strap + Stryd/FTMS/PM5 in parallel,
   starts GPS (`WorkoutLocationManager`) and the barometric altitude buffer, and
   drives a per-tick ticker.
2. **Live** — `LiveDFAAnalyzer` computes rolling α1 every 20 s (Kubios-style
   artifact filter first); `LiveWorkoutBroker` publishes a thread-safe snapshot
   to the AI/voice coach; `WorkoutTriggerEngine` + `WorkoutVoiceCoach` speak
   observations over long cooldowns; declared `WorkoutThreshold`s duck audio only
   on breach.
3. **Stop** — `stopStreaming()` is deferred until after a 120 s HRR capture
   window (`HRRCaptureService`); `finalizeSession()` runs `WorkoutAnalyzer`
   (Banister TRIMP, hrTSS, power-TSS, splits, decoupling), the barometric
   elevation post-processor, and archives the workout (also auto-archiving its
   GPS track as a breadcrumb trail).
4. **Summary/PDF** — `WorkoutSummaryV2View` / `FitnessPostSummaryView*` render the
   α1 "epic report"; `WorkoutPDFReport.generate` (`Emuqu/Sources/Export/WorkoutPDFReport.swift:104`)
   produces the 6–7 page clinical PDF. Training-load math and citations:
   [`TRAINING_LOAD.md`](TRAINING_LOAD.md), [`ARCHITECTURE.md` → Fitness Tab](ARCHITECTURE.md#fitness-tab--workout-subsystem).

### 7.4 An AI turn (Flo)

Full version: [`FLO_ARCHITECTURE.md` §3](FLO_ARCHITECTURE.md) and
[`FLOWCHART.md` §20](FLOWCHART.md).

1. **Input** — chip/type/dictate → `AssistantViewModel.send(text:fromVoice:)`.
   On first send of a session, Apple Foundation model is prewarmed.
2. **Deterministic shortcut** — `DeterministicIntent.tryMatch` catches the
   ~15 highest-frequency factual queries with a fact-catalog read + template,
   **zero tokens**, before any LLM call.
3. **Route** — `dispatch()` calls `resolveProviderForThisTurn()`
   (`AssistantViewModel+Routing.swift`). Voice bypasses the router (session-sticks to
   one cloud provider). Typed turns consult the `RoutingMode` (Quick/Auto/Deep/
   Manual); Auto uses `CapabilityClassifier` (4 keyword-gated embedding axes) →
   `SmartProviderRouter` tier → `TierProviderMapper` → concrete provider+model,
   with session-stickiness and a 50-turn/day Tier-3 spend cap.
4. **Tool-use loop** — `runToolUseLoop` (`AssistantViewModel+Tools.swift:47`):
   the provider streams; `.textDelta` appends, `.toolUse` accumulates; each tool
   call is resolved **locally** by `CompactToolRouter.resolveTool` over the Fact
   Catalog (no network); results go back as a continuation. Hard cap
   **`maxToolCallsPerTurn = 8`** (`AssistantViewModel+Tools.swift`), then one closing pass.
5. **Apple path** — Apple's `LanguageModelSession(tools:)` is wired through
   `AppleFoundationToolAdapter` → `AppleToolDispatcher`; transcript is
   verbatim-compacted at 70 % of the 4 K window (`AppleContextCompactor`); a
   `SessionCache` reuses the warm session, rotating after 20 turns.
6. **Side-effects** — on completion, optional auto-fact-extraction adds new facts
   to `UserFactsStore`; cache-hit telemetry is recorded.

### 7.5 Storage & iCloud sync

1. **Write** — `SessionArchive.archive(_:)` (`Emuqu/Sources/Storage/Archive.swift`) encodes the
   session to JSON in the App Group container, stores its SHA-256, updates the
   locked in-memory index, and persists the index.
2. **Sync up** — `CloudKitSyncManager.uploadSession()`
   (`Emuqu/Sources/Storage/CloudKitSyncManager.swift:521`) ZLIB-compresses the JSON into a
   `CKAsset` and writes it to the **private** database.
3. **Sync down** — `performFullSync()` (`:670`) on launch/foreground; deletes
   propagate via a soft-delete flag (`isDeleted`), and `deletedSessionIds`
   prevents re-creation of locally deleted sessions.
4. **Deferred migrations** — `runDeferredMigrations()`
   (`Emuqu/Sources/Storage/Archive+Migrations.swift:30`) runs six idempotent one-time
   migrations on a background thread at launch.

---

## 8. Subsystem reference

A compact index of each subsystem, its owner files, and the authoritative deep
doc. Use this to decide *where to read next*.

### 8.1 Recording & analysis

- **Owns:** sensor capture, the recording state machine, HRV signal processing,
  window selection, recovery scoring, sleep staging, baselines/trends.
- **Code:** `Collection/` (RRCollector, PolarManager, HealthKitManager),
  `Analysis/` (HRVAnalysisPipeline, RecoveryScoreCalculator, WindowSelection,
  DFA/time/frequency, SleepScienceAnalyzer, BaselineTracker).
- **Deep doc:** [`ARCHITECTURE.md`](ARCHITECTURE.md) (Recording, Analysis, Window
  Selection, Recovery Score, Sleep, Baseline sections);
  [`FLOWCHART.md`](FLOWCHART.md) for step-by-step data flow.
- **Key contracts:** window selection operates on 30–70 % of *actual sleep*, not
  recording duration; scores freeze at morning measurement; all magic numbers in
  `Constants+RecoveryScore.swift`.

### 8.2 Workout & training load

- **Owns:** live workout recording, GPS/barometric elevation, live α1, power/pace
  math, training load (ATL/CTL/TSB), route awareness, the voice coach.
- **Code:** `Collection/WorkoutRecorder*`, `Analysis/WorkoutAnalyzer`,
  `LiveDFAAnalyzer`, `BarometricAltitudeProcessor`, `TrainingLoadRegistry`;
  `Services/` road/nav/weather stack; `Assistant/WorkoutVoiceCoach` +
  `WorkoutTriggerEngine`.
- **Deep doc:** [`TRAINING_LOAD.md`](TRAINING_LOAD.md) (load derivation);
  [`ARCHITECTURE.md` → Fitness Tab](ARCHITECTURE.md#fitness-tab--workout-subsystem).
- **Key contracts:** Banister TRIMP is sex-dependent (never defaults female users
  to male coefficients); power-TSS only when both a power source and FTP exist
  (no fabricated denominators); elevation is barometric, never GPS-smoothed.

### 8.3 Sleep

- **Owns:** sleep-boundary resolution, HRV-based stage classification,
  Watch-based sleep extension (HR-threshold heuristic), sleep science scoring.
- **Code:** `Analysis/SleepScienceAnalyzer`, `SleepResolver`; `Collection/SleepData`,
  `SleepMergingPipeline`; `Collection/HealthKitManager+Sleep` (`estimateSleepFromHealthKitHR` / `estimateSleepFromHR`).
- **Deep doc:** [`ARCHITECTURE.md` → Sleep Pipeline](ARCHITECTURE.md#sleep-pipeline).

### 8.4 The AI assistant (Flo)

- **Owns:** chat + continuous voice, provider routing, tool-use over the Fact
  Catalog, on-device Apple Intelligence, safety/medical guards, memory.
- **Code:** `Assistant/` (all subdirs). Provider-agnostic; the only app-specific
  seam is the fact resolvers in `Facts/AppFactResolver*`.
- **Naming:** the **chat tab is "Flo"** (`Tab.coach`); the **mid-workout voice is
  "Coach"** (`WorkoutVoiceCoach`); the **auto-email is "Flo Report"** — three
  subsystems, one model picker, distinct bubble badges (`AssistantSubsystem`,
  `Emuqu/Sources/Assistant/Providers/AIProvider.swift:96`).
- **Deep docs:** [`FLO_ARCHITECTURE.md`](FLO_ARCHITECTURE.md) (module spec),
  [`VOICE_AND_TOOL_USE.md`](VOICE_AND_TOOL_USE.md) (fact catalog + voice),
  [`ARCHITECTURE.md` → AI Assistant](ARCHITECTURE.md#ai-assistant).
- **Key contracts:** system prompt is byte-stable for prompt caching (volatile
  live-state moved to the last-user-tail); tool schemas serialized sorted-keys;
  cap of 8 tool calls/turn; API keys in Keychain, never iCloud-synced.

### 8.5 Storage, sync & export

- **Owns:** the JSON archive, encryption, integrity, CloudKit sync, PDF/CSV/GPX/
  TCX export, external-format import.
- **Code:** `Storage/` (Archive, CloudKitSyncManager, EncryptionManager,
  DataCompression, RawRRBackup), `Export/`, `Import/`,
  `Analysis/{CSV,GPX,TCX}Exporter`.
- **Deep doc:** [`ARCHITECTURE.md` → Storage & Sync](ARCHITECTURE.md#storage--sync);
  [`API_REFERENCE.md` → Storage](API_REFERENCE.md#storage).
- **Key contracts:** per-screen archive subscriptions (load limits are per-screen,
  §3); the [post-acceptance mutation contract](FLOWCHART.md#13-post-acceptance-mutation-contract)
  governs when archived sessions may be rewritten (user overwrite vs. additive
  merge only).

### 8.6 The Apple Watch app

- **Owns:** live-workout mirror + wrist controls; optional direct strap.
- **Code:** `EmuquWatch Watch App/` — `WatchApp.swift` (entry),
  `WatchLiveView.swift` (UI), `WatchWorkoutManager.swift`
  (`HKWorkoutSession`), `WatchSessionManager.swift` (`WCSession` bridge),
  `WatchStrapConnector.swift` (its own CoreBluetooth central). Phone side:
  `Emuqu/Sources/Services/WatchConnectivityBridge.swift`.
- **Design:** the **iPhone owns the Polar strap and canonical record**; the Watch
  mirrors live HR/stats over `WatchConnectivity` and offers start/stop/pause.
  Re-embedded into the iOS build 2026-07-03; mirror-mode polish in progress.
- **Deep doc:** [`ARCHITECTURE.md` → Apple Watch app](ARCHITECTURE.md#apple-watch-app).

### 8.7 Navigation & location (workout-time)

- **Owns:** road context, breadcrumbs, turn-by-turn, ambient location cache,
  audio-session arbitration.
- **Code:** `Services/` — `WorkoutLocationManager`, `BreadcrumbRecorder`/`Store`,
  `AmbientLocationService`, `RoadGeocodingService`, `ActiveRouteSession`,
  `AudioSessionCoordinator`.
- **Deep doc:** [`ARCHITECTURE.md` → Navigation & Location Subsystems](ARCHITECTURE.md#navigation--location-subsystems-2026-04-29).

---

## 9. Cross-cutting concerns

### 9.1 Concurrency & the `RRCollector` sub-object model

Swift Concurrency throughout: `@MainActor` on UI-touching types, `async/await`,
actors for off-main work, cooperative `Task` cancellation.

`RRCollector` is decomposed from a "god object" into five `@MainActor`
sub-objects — `ArchiveSignal`, `DeviceStatus`, `SessionState`,
`StreamingLifecycle`, `MorningCoordination`. All live state lives on these; the
parent `RRCollector` is a dependency-wiring shell that publishes nothing.
**How to observe it:** inject and observe the relevant sub-object directly
(`@Environment(DeviceStatus.self)`). Reads of the parent's back-compat
forwarders (`collector.isOvernightStreaming`) are plain computed properties;
under `@Observable` they track through to the sub-object, but prefer the
sub-object in views so the dependency is visible.

**Observation framework, everywhere (completed 2026-09-03).** Every observable
type is `@Observable`; the `legacy_observable_object_budget` ratchet (§10) sits
at zero and new `ObservableObject` conformers fail CI. What used to be Combine
`$property` sinks — the collector's device-status proxies, the HealthKit
version counters, the voice controller's streaming observers, the workout
recorder's strap and heart-rate subscriptions, the history filter debounce —
are `ObservationLoop.observe` calls (`Emuqu/Sources/Utilities/ObservationLoop.swift`): a
self-re-arming `withObservationTracking` loop that delivers on the main actor
after the mutation and stops when its owner is released or its handle is
cancelled. `initial: true` reproduces a `@Published` publisher's replay, one
hop later. Plumbing stored on observable classes — timers, tasks, notification
tokens, BLE characteristics, audio engines — is `@ObservationIgnored`. See
[`ARCHITECTURE.md` → RRCollector decomposition](ARCHITECTURE.md#rrcollector-decomposition-sub-objects--swiftui-observation).

### 9.2 Localization

- **Static strings:** `Emuqu/Localizable.xcstrings` (Xcode String Catalog),
  English source, **17 locales** (`ar, da, de, en, es, fi, fr, is, it, ja, ko,
  nb, nl, pt-BR, ru, sv, zh-Hans`). Every UI string goes through
  `String(localized:bundle:)` / `Text(_, bundle:)`.
- **Live switching:** `Emuqu/Sources/Services/LanguageManager.swift` — swaps `locale` + `.lproj`
  bundle at runtime, resets formatters, posts `languageDidChangeNotification`,
  bumps an observable `revision`. Exposes `nonisolated` accessors so the ~3.6 k
  call sites in non-MainActor contexts compile without hops.
- **Dynamic narrative:** `Emuqu/Sources/Services/NarrativeTranslator.swift` — runtime-assembled
  text (analysis summaries, coaching) can't be pre-catalogued, so it uses Apple's
  on-device **Translation framework** (iOS 18+), with a cache + max-2-retry.
- **How to add a string / translation:** [`LOCALIZATION.md`](LOCALIZATION.md).

### 9.3 Theming & accessibility

`Emuqu/Sources/Views/Theme.swift` — a single `enum AppTheme` namespace of static color/gradient/
typography accessors resolving against the user's accent theme + light/dim/dark
mode. Status colors use a **Wong-2011 deuteranopia-safe palette**. VoiceOver
labels are pervasive; there is a `LocalizationSmokeUITests` and
`AccessibilityUITests` gate.

### 9.4 Dependency injection & testing seams

No DI framework. **Production composition root:** `AppDependencies`, with
`RRCollector.makeDefault()` wiring the collector's own graph on top of it.
**Test seam:** one live protocol in `Protocols/` — `HealthKitServiceProtocol`,
mocked by `MockHealthKitService`. `AnalysisServiceProtocol`,
`PolarManagerProtocol` and `SessionRepositoryProtocol` were deleted outright
(see §5.7): each had a single conformer and no production call site that used it
as a type, which is the "interfaces with one implementation" the refactor spec
forbids. Don't go looking for them; there are no tombstone files either.
Elsewhere: concrete types reached through **`AppDependencies`**
(`Emuqu/Sources/Utilities/AppDependencies.swift`), the composition root added
2026-09-03. It is the one place that names the singletons (`Type.shared` is
read there and nowhere else — `scripts/check_no_shared_outside_root.sh`), grouped
by layer (`app`, `analysis`, `assistant`, `collection`, `location`,
`providers`, `services`, `storage`). Every accessor resolves lazily, so no
service is built until asked for and no initialiser can recurse into the
container. Views read `@Environment(\.dependencies)`; static helpers read
`AppDependencies.current`; a test makes a fresh container, sets the substitute
on its `overrides`, assigns it to `current` in `setUp`, and calls `reset()` in
`tearDown`.

### 9.5 Feature flags & kill switches

`Constants+SleepAndDisplay.swift` (`FeatureFlags`) holds **intentional kill
switches** — per-provider AI switches (disable OpenAI/Anthropic/Gemini/Grok/
DeepSeek without deleting the key, e.g. on a leak or outage) and per-feature
switches (e.g. the Beat Consistency card). These are **not** dead code. They
live in the device's app-group defaults and there is no remote config: the
provider switches are toggles in Settings → Flo, and the others change for
everyone only by shipping a build with a different default. Distinguish them from
genuinely dead code (e.g. the orphaned `WidgetDataPublisher` writer — the
home-screen widget was removed 2026-07-03 and nothing reads its App-Group keys;
it is a documented future-cleanup candidate, [`ARCHITECTURE.md` → Home-screen
Widget — REMOVED](ARCHITECTURE.md#home-screen-widget--removed-2026-07-03)).

### 9.5a Paywall, trial, and beta grandfathering

Switched on: `StoreKitManager.paywallEnabled = true`. The lifetime
non-consumable is **$9.99**, and every new install is offered a **30-day
free trial**, which is itself a $0 non-consumable
(`com.chrissharp.flowrecovery.trial30day`) as Guideline 3.1.1 asks. Both
products must exist in App Store Connect and be attached to the version
before it is submitted.

Four bypasses sit in front of the gate — purchased, grandfathered beta
tester, developer install, active trial. See
[`ARCHITECTURE.md` → In-App Purchase](ARCHITECTURE.md#in-app-purchase) for
the table and the `EntitlementAnchor` tier design.

Two things to know before you touch this:

- **`isTestFlight` must stay uncached.** It answers "is THIS build a
  TestFlight build" and nothing else. The durable "was ever a beta tester"
  fact belongs in `EntitlementAnchor`. Merging the two is what caused the
  2026-08-22 entitlement bug, where a cached `true` survived a TestFlight →
  App Store upgrade and granted permanent free access with no proof behind it.
- **The anchor is written on proof of a sandbox receipt — with one deliberate
  exception.** `migrateLegacyTestFlightFlag` promotes the pre-2026-08-22
  `storekit.lastKnownTestFlight` UserDefaults flag into a permanent grant.
  That flag was itself only ever written from a genuine sandbox-receipt
  check, so the evidence is real, one generation removed — and this migration
  is precisely what grandfathers the EXISTING tester cohort, who would
  otherwise meet a paywall on the first launch of the paid build. Note the
  tension with the bug above: the same surviving flag that was a bug when it
  silently granted entitlement is, read deliberately and once, the migration.
- **`isDeveloperInstall` must never write the anchor.** A developer install
  is not a beta tester; stamping a permanent entitlement from it would follow
  that Apple ID onto the App Store build forever. And it grants only on
  positive evidence (DEBUG, a sandbox receipt, an `AppTransaction` verified
  as Xcode): a missing receipt file is not one, because an App Store install
  can lack it too.

**Known gap — paywall UI coverage.** The three `PaywallView` XCUITests still
skip. XCUITest runs a DEBUG build, DEBUG satisfies `isDeveloperInstall`, and
that grants the entitlement before the launch gate is consulted — so the
paywall is unreachable from the suite. (This is also why enabling the
paywall did not disturb the other 77 tests.) Making them run needs a
DEBUG-only launch flag that suppresses *every* bypass at once; it was left
out of the pricing change deliberately, because it edits the launch gate.
The paywall's logic is covered by `EntitlementAnchorTests`; only the view is
untested. Fixing this would also drop `.ci/test_skip_budget.txt` by three.

### 9.6 Background execution

Overnight keep-alive is silent audio (volume 0) + `bluetooth-central` wakeups on
incoming Polar BLE data — **not** background location (that was removed
2026-06-10; background location now serves *only* workout GPS, a user-visible
feature, per App Store rule 2.5.4). See
[`ARCHITECTURE.md` → Background Execution](ARCHITECTURE.md#background-execution).

### 9.7 Privacy & security

All health data is processed **on-device**; iCloud sync uses the user's **private**
CloudKit database (no third-party servers). AI: Apple Intelligence is fully
on-device; cloud providers receive only the chat + the specific tool results the
model asks for (not a full archive dump).

> **Keychain exception (2026-08-22).** The blanket "never iCloud-synced" below
> holds for API keys but is no longer true of the whole keychain:
> `EntitlementAnchor` stores one deliberately **synchronizable** item
> (`kSecAttrSynchronizable: true`, `kSecAttrAccessibleAfterFirstUnlock`) so a
> beta tester's grandfathered status follows their Apple ID to a new device.
> It contains no health data and no secrets — a bool and two dates.

**API keys live in the iOS Keychain**
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), never in UserDefaults/JSON,
never iCloud-synced. Speech recognition is on-device
(`requiresOnDeviceRecognition = true`). Supply-chain: GitHub Actions pinned to
SHAs, Dependabot weekly. Full posture: [`.github/SECURITY.md`](../.github/SECURITY.md).
A copy-perimeter linter (`Tools/copy_linter/`) blocks prohibited medical-claim
language in user-facing copy.

---

## 10. Build, test, CI & tooling

### Local quality loop

```bash
make format        # SwiftFormat (Swift 5.10, 4-space, strip headers)
make lint          # SwiftLint
make test          # xcodebuild test (sim auto-selected)
make test-coverage # enforces the coverage floors in .ci/min_coverage*.txt
make debt-budget   # enforce the tech-debt budgets in .ci/*.txt
make ci            # the full lint + budgets + coverage suite (what CI runs)
make setup-hooks   # install .githooks/pre-commit (SwiftFormat + SwiftLint)

make ci-local      # every gate the WORKFLOW runs, ~2 min, no simulator
make ci-local-unit # the above plus the unit suite
```

**Run `make ci-local` before every push.** macOS runners bill at 10x, and a full
hosted run is ~1,080 billable minutes. `scripts/simulate_ci.sh` parses
`.github/workflows/ci.yml` and executes its `run:` blocks in order, so it keeps
no list of its own and cannot drift from the workflow — a step added to CI is
picked up automatically, and a step it cannot run locally is a hard error rather
than a silent skip. Run it *after committing*: the budget-ratchet gate compares
`HEAD` to `HEAD~1`, so an uncommitted budget change is invisible to it exactly
as it would be on the runner.

```bash
# The two that check the checks — run these after touching a gate or a test.
./scripts/verify_gates_fail.sh   # plants a violation per gate, requires each to go red
./scripts/verify_tests_fail.sh   # mutates production behaviour, requires tests to catch it
./scripts/evidence_report.sh     # the live enforced state; never restate its numbers in a doc

# Individually, if you want to know which gate is unhappy:
make budget-monotonicity      # .ci/*.txt may only ratchet DOWN
make localization-bundle-guard # every localized lookup names appBundle
make localization-resolution-guard # every localized literal resolves to a key
make uitest-reset-guard       # every UI suite launches -UITests-FreshInstall
make skip-budget              # XCTSkip count (a skip asserts nothing)
make fixed-font-budget        # raw .font(.system(size:)) ignores Dynamic Type
```

### When a gate stops you

Every gate prints what it found, where, and what to do. None of them are advice.
The three legitimate responses, in order of preference:

**1. Fix the thing.** Usually right. The gate is describing a real defect.

**2. Waive it, with a reason.** Some gates accept an inline marker when the code
is safe by construction. The reason is mandatory — a bare marker is itself a
gate failure, because the next reader has to be able to check the claim.

```swift
// empty-range-ok: `breakpoints` is a literal table declared just above
// with a fixed set of entries; it cannot be empty.
for i in 1 ..< breakpoints.count { ... }
```

Existing markers: `empty-range-ok:`, `swallow-ok:` (empty catch),
`justified-long:` / `justified-nesting:` (refactor spec).

**3. Raise a budget, with a commit trailer.** The `.ci/*.txt` ceilings may only
go **down** without justification. `check_budget_monotonicity.sh` compares your
`HEAD` against `HEAD~1` and fails a raise unless the commit says why:

```
budget-raise-ok: .ci/shared_usage_budget.txt the FR-format decoder added for
audit F3 needs EncryptionManager.shared to open payloads written by the
previous build, and there is no way to reach that key without the singleton.
```

What is **not** a legitimate response: deleting the check, widening its scope
until it passes, or writing the current measurement into the budget file as a
matter of habit. That last one is the common failure — it silently converts a
ceiling into a high-water mark. `check_budget_monotonicity.sh` exists because it
happened here, twice.

### The two gates that check the other gates

These are the ones worth understanding before changing anything, because they
are what makes the rest trustworthy.

`verify_gates_fail.sh` takes each gate, plants a violation it is supposed to
catch, and requires it to go red. A gate that stays green with a planted
violation is reported as **"not protecting anything"** — the loudest failure in
the repo, because a check that passes while measuring nothing is worse than no
check: it is documented as protection.

`verify_tests_fail.sh` does the same to the test suite. It mutates production
behaviour — inverts a recovery label, drops an encryption flag, reverts a
formula — and requires a named suite to fail. A mutation that **survives** means
the tests execute that code without asserting anything about it.

Both treat a **skip** as a failure. A skipped check was not verified, and a run
where everything skipped would otherwise report success.

**After adding a gate, add its planted violation to `verify_gates_fail.sh`.**
**After fixing a bug, add a mutation to `verify_tests_fail.sh` that re-breaks
it.** A fix without a mutation is a fix that can silently regress.

Two traps worth knowing, both found the hard way:

- **Equivalent mutants.** If a mutation changes nothing observable — deleting a
  guard that a later check already subsumes — it can never be caught and will
  sit there as a permanent survivor. Delete it and note why, or the signal rots.
- **Run them alone.** Both scripts rebuild per case. Another `xcodebuild`
  against the same derived data produces transient build failures that read as
  "the suite was already red".

### Decomposing a long view (the remaining `spec_long_properties` budget)

`.ci/spec_long_properties_budget.txt` counts computed properties and inits
over the spec's declaration-length limit. It was measured, not aspirational, on
the day it was created, and has ratcheted since — read the current value from
the file rather than from this page. Alongside it, **0** declarations nest past
depth 2
(`.ci/spec_deep_nesting_properties_budget.txt`). Both are ratchets: CI fails if
the count rises, and the number in the file is lowered every time a file is
finished.

The three that remain are all `init(from decoder:)` Codable decoders —
`SessionMetadata` (two of them) and `WorkoutMetadata`. They are tables, one line
per stored property, and Swift will not let them be split: a struct initializer
cannot call a mutating helper, or read `self`, until every stored property is
assigned, and the alternative (a static builder returning a fully-formed value)
just moves a ~50-argument call into a `func`, where the budget is **zero**. They
are left as they are on purpose. Do not "fix" them by adding default values to
the stored properties so `self.init()` can run first — that invents state the
decoder is supposed to be reading.

The sibling counters for FUNCTIONS — `spec_long_functions` and
`spec_deep_nesting` — are at **zero, budget zero**. That asymmetry matters when
you decompose: lifting a long computed property into a `private func` moves the
violation from a bucket with headroom into one with none, so a func you extract
has to land at or under 20 lines and depth 2 in the same pass.

Worked examples, in the order they are worth reading — each of these files is at
zero on both counters:

| File | Shape it demonstrates |
| --- | --- |
| `BiometricsSettingsPage` | a `Form` of `Section`s, one property per section |
| `RecordView` + `RecordView+Sections.swift` | the same, spilled to a sibling file when the type body passed 500 lines |
| `WorkoutPreflightView` | disclosure groups, and a chip row split down to `sportChip(_:)` |
| `WorkoutSummaryV2View+Charts` | Swift Charts — plot, empty state and card kept apart |
| `TrainingDetailView` | `withPageChrome(_:)` for a long modifier chain, and a struct init pair replacing two closure-typed locals |
| `FitnessPostSummaryView+Feeling` | a 101-line tile builder turned into `append…(&tiles)` steps |
| `FitnessRecordingView+Tiles` | `GeometryReader` layers, and a hold-to-confirm button split into track / fill / label |
| `HistoryView` | a `List` of grouped sections, plus swipe/context actions lifted into `withEntryActions(_:entry:)` |
| `GetMeBackView` | `withAlerts(_:)` / `withLifecycle(_:)` peeling three alerts and three lifecycle hooks off one body |
| `LoadTrajectoryView` | `some ChartContent` helpers — the mark builders are not `some View` |
| `AppFactResolver+LiveNavigation` | non-view code: a 58-line array element split into an entry, a hoisted `static let` description and three resolver steps |
| `AnalysisSummaryGenerator+Interpretation` | a 98-line `switch` over score categories, one string-builder per case behind an `Inputs` struct |
| `MorningResultsViewModel` | statistics: averages, baselines and the 7-day trend each computed by their own function |
| `AppFactResolver+WorkoutDetail` | the fact catalogue: one property per entry, `description:` hoisted to a `static let`, the resolve closure lifted to a method |
| `AppFactResolver+LiveCoaching` | a 173-line `location.situation` resolver split into fix / address / POI / journey record builders |
| `AnalysisSummaryGenerator+Steps` | pure logic: a 236-line `[String]` builder turned into `append…(&steps, gates:)` steps over one `PushGates` value |
| `SettingsPages+DiagnosticActions` | a `Group` of `Section`s where every `Button { } label: { }` became `Button { action() } label: { … }` |
| `MorningResultsView` | the widest one: `withSheets` / `withDialogs` / `withLifecycle` peel 3 sheets, 3 dialogs and 4 lifecycle hooks off a 325-line body |

**The metric only moves when every piece lands at or under 20.** Splitting one
610-line declaration into thirteen 40-line ones turns one violation into
thirteen. A partial pass makes the number worse even though the code is better,
so finish a file or revert it.

Recipe that worked four times:

1. Lift each top-level child of the `Form` / `List` / `VStack` into its own
   property, named from its `// MARK:` comment or its `header:` literal.
2. Split any `Section { } header: { } footer: { }` still over 20 into
   `xFields` / `xFooter`.
3. Lift the input row (`HStack { Text; TextField }`) out of `xFields`.
4. For nesting, lift the innermost container — `Toggle { VStack { … } }`
   becomes `Toggle { xLabel }`.
5. If the type body then passes 500 lines, move the sections to a sibling
   `+Sections.swift` (see `RecordView+Sections.swift`).

Traps, each of which cost a build here:

- **A block that reads a closure parameter or an outer `let` cannot become a
  parameterless property.** `cannot find 'x' in scope`. Make it a function
  taking the value. Hit three times: `isImperial`, `providerID`, `entry`.
- **`private` does not reach across files.** Moving sections to `+Sections.swift`
  means widening the members they use — *and the nested types*, because a
  `private struct` also forces every property using it to stay private.
- **Two `@ViewBuilder` on one declaration is a compile error** that only surfaces
  at build time. There is now a SwiftLint rule (`stacked_result_builder`), so
  run `make lint` before `xcodebuild` — it turns a forty-minute discovery into a
  two-second one.
- **Use `scripts/add_swift_file.py`** to register a new file. Registering by hand
  put a Views file in the Models group and produced a "build input file cannot
  be found" for a path that plainly existed.
- **Check the path is new before writing it.** Writing a "new"
  `RecordView+Sections.swift` over the one that already existed destroyed 201
  lines of working view code, and only a `cannot find 'tagSelectionSection' in
  scope` from an unrelated file surfaced it.
- **Verify by counting lines against a backup, not by reading the diff.** Two
  separate scripts silently dropped whole blocks — a `.sheet(item: $emailURL)`
  in one case — and nothing failed. The file just got shorter.
- **A modifier chain belongs with the view it hangs off.** Lifting only the
  balanced `HStack { … }` block leaves `.frame(…)`/`.background(…)` dangling at
  the call site: still correct, unreadable, and it defeats the point.
- **`if let x = …` binds `x` exactly as a leading `let` does.** A block lifted
  out of that branch compiles to `cannot find 'x' in scope`; the fix is the same
  as for closure parameters — pass it in.
- **Comments count toward the 20 lines.** Several declarations sat at 22–25
  because of a paragraph explaining the first child. Move it to a `///` doc
  comment on the member it describes; that is where a reader looks for it
  anyway.
- **MapKit content is not a `View`.** `MapPolyline`/`Marker` conform to
  `MapContent`, so a lifted `-> some View` helper fails with "requires that
  'some View' conform to 'MapContent'". Give it `-> some MapContent` or leave it
  inline. The same applies to `Chart` marks (`some ChartContent`), toolbar
  items (`some ToolbarContent`, plus `@ToolbarContentBuilder`) and gestures
  (`some Gesture`).
- **A trailing-closure continuation belongs to the call above it.** `} label: {`,
  `} message: {`, `} header: {` are not new statements. Lifting a `Button { … }`
  without its `label:` leaves the label stranded and the file stops parsing —
  which SwiftFormat reports as "Unexpected token }" a long way from the cause.
- **Never rewrite identifiers with a bare regex.** Renaming `stress` to
  `v.stress` across a file turned the sentence "Combined with high stress
  markers" into "…high v.stress markers" — user-visible copy, corrupted
  silently. Pass values as parameters (or re-bind them at the top of the new
  function) so the body needs no rewriting at all.
- **Check the rebuilt member BOTH ways, not just for loss.** A one-sided
  "nothing went missing" check passed while a bad slice pasted the same block
  twice: `trainingAndVitalsSections` came back eighteen lines LONGER than it
  went in and still looked clean. Compare the line multiset before and after in
  both directions and declare every intentional structural change.
- **Take line numbers from a printed listing, never from arithmetic.** Every
  hand-computed `i + 27` in this pass was wrong at least once, and each mistake
  cost a build. Print the member with absolute indices first, then slice with
  those numbers.
- **Re-indent with SwiftFormat's `indent` rule, per file.** The repo config
  disables `indent` to avoid tree-wide churn, so a lifted block keeps whatever
  indentation it had inside its old parent. Run
  `swiftformat <file> --rules indent --indent 4 --swiftversion 5.10` on the file
  you just edited — it is whitespace-only and idempotent.
- **A run starting with `.` is a modifier chain, not a child.** Lifting one
  produces `private var x: some View { .alert(…) }`, which fails with
  "instance member 'alert' cannot be used on type 'View'".
- **A lifted block with more than one top-level statement needs
  `@ViewBuilder`** — including `let stats = …` followed by an `if`. Without it
  the compiler says "no return statements in its body from which to infer an
  underlying type". A body with an explicit `return` must NOT have it.
- **Rebuilding an `if / else if` chain is where blocks get dropped.** Replace
  each branch BODY in place, walking the branches back-to-front so the earlier
  indexes stay valid. Rewriting the whole chain in one splice ate both branches
  twice here.
- **A listing tool that prints 0-based half-open spans while your slicer is
  1-based inclusive breaks three files before you notice.** The symptom is
  always the same shape — a stray `}`, a duplicated line, a block indented one
  level too far — and it never looks like an off-by-one. Make the listing print
  the same convention the slicer consumes, once, and the whole class of bug goes
  away.
- **A capture guard belongs in the tool, not in your head.** Refuse to lift any
  block that references a name bound above it — closure parameters, `let`/`var`,
  `if let`, `for … in`, tuple patterns. Every one of those that slipped through
  came back as `cannot find 'x' in scope` at build time, minutes later.
- **Do not run a lifting tool to fixpoint over the tree.** One pass here
  produced ~4,200 `…Block` members, 833 members in a single file, a 591-link
  forwarding chain, and one real corruption (a `Section`'s `header:` text moved
  into its body). Recovering it took an inliner, a chain collapser and six files
  restored from `HEAD`. Lift one named member at a time, against a file you have
  read.
- **`@ViewBuilder` is not free to re-add.** After a splice, check the attribute
  is attached to the member you meant — a blind insert lands it on whatever
  declaration now follows the comment block, and `[Double]` does not conform to
  `View`.
- **Reuse of a member name across two types in one file is fine; across one type
  it is `invalid redeclaration`.** Two `lastSyncRow`s in `SettingsPages+Data`
  looked like different structs and were not.
- **Grouping a long argument list two-per-line is a legitimate fix.** Several
  declarations sat at 21–24 lines purely because a call site put one argument on
  each line. Pairing the ones that belong together (`avgRMSSD:` with
  `baselineRMSSD:`) reads better and lands under the limit without inventing a
  helper nobody needed.

Counting the two budgets, for a file or for the tree:

```bash
bash scripts/check_refactor_spec_conformance.sh
```


### CI/CD (`.github/workflows/`)

- **`ci.yml`** — every push to `main` + every PR. Pinned to macOS-15 /
  Xcode 26.1.
  - **Job 1 `lint-and-budgets`** — SwiftLint (0 errors, warnings under budget),
    tech-debt budgets, budget monotonicity, copy-perimeter, Info.plist drift,
    Sendable guard, SBOM drift, log redaction, localization coverage,
    localization bundle reachability, localization resolution, UI-test
    fresh-install reset, skip budget, fixed-font budget, orphan-Swift guard.
  - **Job 2 `strict-concurrency`** — proves every build configuration is in
    Swift 6 language mode with `SWIFT_STRICT_CONCURRENCY = complete` and that
    warnings are errors. The compiler is the gate; this job only makes sure
    nobody switches it off. Seconds on Ubuntu, no build.
  - **Job 3 `thread-sanitizer`** — the unit suite under TSan. The only thing
    that can show the 12 `@unchecked Sendable` / `nonisolated(unsafe)` escapes
    (each in an allowlisted file, each naming the queue or lock that owns its
    state) are actually safe, as opposed to merely no more numerous than last week.
    First run 2026-08-18: 1,444 tests, zero race reports.
  - **Job 4 `tests`** — `xcodebuild test` with coverage, against the floors in
    `.ci/min_coverage.txt` and `.ci/min_coverage_logic.txt`.
- **`gates.yml`** — on every push and pull request, ubuntu runner: the script
  gates from `make ci` that need only bash and python (no SwiftLint, no Xcode).
  About a minute at 1x billing. The macOS jobs above stay manual.
- **`performance.yml`** — `workflow_dispatch` only — `AnalysisPerformanceTests`.
- **`testflight.yml`** — `workflow_dispatch` only — TestFlight build + upload.

### Dependency upgrade constraints

`polar-ble-sdk` is on **8.3.0**, and RxSwift is no longer in the graph.

Upgraded 2026-08-31. This section previously argued for staying on 6.13.0; that
reasoning is kept below because it is still the right way to think about the
constraint, but the conclusion changed.

**The constraint.** Polar 6.13.0 pinned `RxSwift` with `.exact("6.5.0")`, and
RxSwift 6.5.0 ships no `PrivacyInfo.xcprivacy`. RxSwift is on Apple's list of
SDKs required to carry one, so an upload could draw **ITMS-91061**. The `.exact`
pin meant RxSwift could not be bumped on its own.

**Why 7.x is not the answer.** Polar 7.0.0–7.1.0 move to RxSwift 6.8.0, the
first release with the manifest — but 7.x sets `path: "Sources"` without
excluding `Sources/iOS/ios-communications/Tests/`, so the SDK's own test files
compile into the library target and the build fails on `Unable to resolve module
dependency: 'RxTest' / 'RxBlocking' / 'iOSCommunications'`. Verified by
resolving and building it: every error came from inside the SDK. That is a
packaging bug in Polar, not something callers configure around.

**What 8.2.0 changed.** It narrows the target path and drops RxSwift entirely,
which removes the manifest problem at the root rather than satisfying it. The
cost was migrating the acquisition layer off the reactive API:

- `Disposable` → `Task`, `dispose()` → `cancel()`. Cancellation now propagates
  into the `for try await` loop instead of tearing a subscription down from
  outside, so a loop body finishes its iteration rather than being cut
  mid-write.
- Every `withCheckedThrowingContinuation` wrapper around an Rx `Single` is
  gone. Those had a failure mode the new shape cannot have: a stream that
  neither completed nor errored leaked the continuation and hung the caller.
- `fetchStoredExerciseList` → `listExercises`; `getOfflineRecordingStatus` and
  `requestRecordingStatus` now return values directly.

**What 8.3.0 changed, and what the app does about 8.x.** 8.3.0 adds
`deviceDisconnected(_:info:)` with a disconnect reason and recovery action (the
app stops reconnecting on a lost pairing) and retries service discovery. The
8.x readiness contract is the one to understand: `bleSdkFeatureReady` is only
delivered inside a ten-second window after discovery, although the
documentation says late features are reported too. Gating on that report left
a slow H10 connected with no heart rate. The link now treats an unreported
feature as worth trying and lets the SDK's per-call guard refuse it locally —
see [`ARCHITECTURE.md` → Strap Link and Reconnection](ARCHITECTURE.md#strap-link-and-reconnection).

**What is verified and what is not.** The stream-consumption logic — ordering,
cancellation, error propagation, not running the completion path after a cancel
— is covered by `EmuquTests/StreamForwardingTests.swift`, which drives
`StrapHeartRateFeed.drain` with a synthetic sequence and needs no hardware. What
those tests do not and cannot establish is that Polar's SDK still talks to the
radio. Connect, stream, disconnect/reconnect and an overnight need a strap, the
same as any dependency upgrade.

### Tech-debt budgets (`.ci/*.txt`)

Numeric ceilings in `.ci/*.txt`, enforced by `scripts/enforce_tech_debt_budgets.sh`
(and friends): SwiftLint warnings, large-file count, coverage floor,
silent-`try?` count, `.shared` usage, and **legacy `ObservableObject` count**
(`legacy_observable_object_budget.txt` — ratchets new code onto `@Observable`).
Every budget is **monotonic** — it can only ever be lowered, so these axes can't
regress. That is now enforced rather than asserted:
`scripts/check_budget_monotonicity.sh` fails any diff that raises a `.ci/*.txt`
value without a `budget-raise-ok:` commit trailer. Before it existed, the
cheapest way to make CI green after adding a `try?` was to edit the budget, and
nothing told the difference between paying the debt and moving the goalpost.

**2026-08-25 — two corrections to the above, both found by audit.**

*The monotonicity gate had never run.* `GITHUB_BASE_REF` is set only on
`pull_request`, and this repo commits straight to `main`, so every run printed
"no PR baseline … Skipping" and compared nothing. `ci.yml` now passes
`github.event.before` as `BUDGET_BASE_REF` on push.

*The counters were counting prose.* `.shared`, `try?` and `ObservableObject`
were matched over raw file text, so a mention in a comment counted as a use —
documenting why a singleton is hard to remove raised the singleton count. They
now strip comments first, which is why three budgets dropped in one commit
without a line of app code changing: `.shared` 804 → **718**, `try?` 395 →
**377**, `ObservableObject` 65 → **55**. Those are the real numbers; the old
ones were inflated by roughly 11%.

They are the machine enforcement of the §3 philosophy: the way the codebase is
guaranteed to only get cleaner, never worse. When you remove `.shared` calls or
migrate a type to `@Observable`, lower the matching budget in the same change.

### Tests

- **`EmuquTests/`** (~192 files): deep unit coverage of analysis/scoring/sleep/
  AI-routing/collector-state/persistence/sync. Shared `EmuquTests/Helpers/TestHelpers.swift`
  + `Mocks/` (MockHealthKitService). Includes `WatchMessageDecodingTests`,
  which covers the phone → Watch `WCSession` contract via
  `WatchMessageDecoding` — the watch target's decode logic, extracted from
  `WatchSessionManager.apply(_:)` so it is reachable from the iOS test target.
- **`EmuquUITests/`** (~18 files): smoke/flow coverage (onboarding, each tab,
  data deletion, permission denial, accessibility, appearance,
  localization smoke) plus the surfaces that need a reading or a sensor to
  exist at all — morning results opened from History, data export/import,
  the sensor sheet.
- **`Emuqu.xctestplan`**: single config, coverage on, **random execution order**.

Notable AI-quality gates: `CapabilityClassifierTests` (routing precision),
`DeterministicIntentTests` (95 % precision contract), `MedicalQueryGuardTests`,
`FactCatalogValidationTests`.

---

## 11. Operations & runbooks

Operational playbooks live in [`docs/runbooks/`](runbooks/):

| Runbook | Use when |
|---|---|
| [`incident-response.md`](runbooks/incident-response.md) | A production incident (crash spike, data loss, sync failure). |
| [`hotfix.md`](runbooks/hotfix.md) | Shipping an urgent fix outside the normal cadence. |
| [`app-store-rejection.md`](runbooks/app-store-rejection.md) | App Review rejected a build. |
| [`data-deletion.md`](runbooks/data-deletion.md) | A user data-deletion request (GDPR/CCPA) — maps to `DataPurgeService`. |

---

## 12. Glossary

Domain terms you'll meet in the code and docs.

| Term | Meaning |
|---|---|
| **RR / PPI interval** | Time between heartbeats (ms). RR from ECG (H10), PPI from optical (Verity Sense). The raw signal everything derives from. |
| **RMSSD** | Root mean square of successive RR differences — the primary short-term HRV/parasympathetic metric. |
| **SDNN** | Standard deviation of NN intervals — overall variability. |
| **pNN50 / SDSD** | % of successive intervals differing >50 ms / SD of successive differences. |
| **LF / HF / LF:HF** | Low- / high-frequency spectral power and their ratio — autonomic balance. |
| **DFA α1** | Detrended Fluctuation Analysis short-term scaling exponent — fractal correlation of the RR series; used for recovery organization and as a workout aerobic-threshold proxy. |
| **Poincaré SD1 / SD2** | Nonlinear scatter-plot descriptors (short- / long-term variability). |
| **SWC** | Smallest Worthwhile Change — the ±0.5 SD deadband in the z-score scoring band (Plews/Buchheit). |
| **Recovery score** | Composite 0–100 (stored 1–10): HRV 60 % + Sleep 25 % + Vitals 15 %, with tier fallback and comeback-mode reweighting. |
| **Training readiness** | 0–10 "can I absorb load today" gauge — separate from recovery score; capacity ratio + ACWR modifier. |
| **TRIMP** | Training Impulse — Banister sex-dependent exponential HR-reserve load per session. |
| **hrTSS / Power-TSS / NP / IF** | HR- and power-based training-stress scores; Normalised Power; Intensity Factor. |
| **ATL / CTL / TSB** | Acute / Chronic Training Load and Training Stress Balance (form) — EWMA fitness-fatigue model. |
| **ACWR** | Acute:Chronic Workload Ratio — descriptive load-range context + a graded readiness modifier (never surfaced as an injury predictor). |
| **Window selection** | Choosing the best RR window in the 30–70 % band of actual sleep to compute the recovery metrics from. |
| **Comeback mode** | 21-day post-illness/injury reweighting (HRV 80 / Sleep 20 / Vitals 0). |
| **Fact Catalog** | The set of ~200 typed data facts the AI can read via tool-use (`Assistant/Facts/`). |
| **Tier (Quick/Auto/Deep)** | The AI routing tiers → Apple on-device / cheap cloud / strongest cloud. |
| **Flo / Coach / Flo Report** | Chat tab / mid-workout voice / auto-email — three AI subsystems, one model. |

---

## 13. Keeping this document current

This guide is a **map**. Its value is that it stays true. Rules for keeping it so:

1. **The code is the source of truth.** When this doc and the code disagree, the
   code wins — fix the doc. When a deep-dive doc (ARCHITECTURE/FLO/API/FLOWCHART)
   and the code disagree, fix that deep doc *and* any pointer here.
2. **Don't duplicate depth.** Keep algorithm internals, full API signatures, and
   exhaustive step lists in their home docs (§4). Here, record *structure,
   responsibilities, and pointers* only. If you're tempted to paste an algorithm,
   link to it instead.
3. **What to update when you change the code:**

   | If you… | Update in this doc |
   |---|---|
   | Add/rename/move a directory or a load-bearing file | §5 file map (and the §2 layer diagram if a layer changes) |
   | Add/rename a tab or root screen | §2 tab table, §5.9 |
   | Add a new external dependency/service | §1 system-context table, §5.4 |
   | Add/rename a core model type | §6 |
   | Change a major flow (recording/workout/AI/sync) | §7 (fix the anchors) |
   | Add a subsystem or move ownership | §8, §9 |
   | Add a doc under `docs/` | §4 |
   | Add a domain term | §12 |

4. **Anchors drift.** `file:line` citations go stale as files change — treat a
   wrong line number as a "refresh me" flag, not a lie. Symbol names are more
   durable than line numbers; prefer them when a line moves.
5. **Counts are indicative.** File counts (§5) drift constantly; don't treat them
   as invariants and don't chase them every commit — fix them when you're already
   editing the section.
6. **This doc is listed in the README doc index and the `refactor-spec` doc
   header** — keep those two links alive if you rename or move it.

> **For AI maintainers:** when you're asked to update the app and you touch any
> row in the table above, update the corresponding section here in the same
> change. Verify every citation you add by opening the file — never invent a line
> number.
