# Emuqu — Architecture & Algorithms

Technical deep-dive into algorithms, design decisions, and implementation details. For API signatures, see `API_REFERENCE.md`. For data flow, see `FLOWCHART.md`. For user-facing features, see `USERS_MANUAL.md`.

> **Looking for the AI assistant ("Flo") architecture?** That moved into its own authoritative spec: [`FLO_ARCHITECTURE.md`](FLO_ARCHITECTURE.md). It describes the AI module's internal architecture and the app-specific extension points it depends on. This file (ARCHITECTURE.md) covers fitness-specific subsystems: HRV analysis, recovery score math, training load, sleep integration, etc.

---

## Table of Contents

1. [Recording Architecture](#recording-architecture)
2. [Analysis Algorithms](#analysis-algorithms)
3. [Window Selection](#window-selection)
4. [Recovery Score Calculation](#recovery-score-calculation)
5. [Sleep Pipeline](#sleep-pipeline)
6. [Baseline & Trends](#baseline--trends)
7. [Storage & Sync](#storage--sync)
8. [Localization & Translation](#localization--translation)
9. [In-App Purchase](#in-app-purchase)
10. [AI Assistant](#ai-assistant)
11. [Dependency Injection](#dependency-injection)
12. [Background Execution](#background-execution)
13. [Known Limitations](#known-limitations)

---

## Recording Architecture

### Hybrid Recording Strategy

Emuqu uses a **session-first flow** — the user picks a session type (Extended or Quick) before connecting. Overnight recording uses a **hybrid approach**:

**H10 (ECG Chest Strap):**
1. **H10 Internal Recording** = PRIMARY (more stable, survives disconnects)
2. **BLE Streaming** = BACKUP (real-time display, wall-clock timestamps)
3. **Composite Merging** = fill gaps in internal recording with streaming data

**Verity Sense (Optical PPG):**
1. **Offline PPI Recording** — survives BLE disconnects
2. **Online PPI Streaming** — real-time data over BLE
3. Quality filter: PPI samples with error estimate >20ms are rejected
4. Auto-disconnect after session to prevent battery drain

Both devices are fully interchangeable — recording, fetch, recovery, and discard all route through unified methods.

### Data Source Selection

When stopping an overnight session, preference order (`DataSourceSelector`):
1. **Internal recording** (preferred) — no Bluetooth gaps
2. **Composite** (internal + streaming gap-fill) — if internal has >5% fewer beats than streaming
3. **Streaming only** — if internal fetch failed, or if the composite could not be built
4. **RawRRBackup** — if both failed (a separate recovery path, `RRCollector+BackupRecovery`)

A source counts as usable only at `minimumValidBeats = 120` beats or more; below that it is
treated as absent. Each data path can succeed or fail independently — an H10 fetch failure
doesn't cascade to streaming.

### Composite Merging Algorithm

The gap scan decides *whether* to build a composite; the merge itself then takes both series
whole.

1. **Detect gaps**: scan internal points for a jump from one beat's end to the next beat's
   start greater than the expected RR interval + 2 seconds.
2. **Check the gaps are fillable**: a gap counts as fillable when at least one streaming point
   falls inside it, matched on `wallClockMs` (raw `t_ms` drifts after a BLE drop). If no gap
   can be filled, no composite is built and streaming is used instead.
3. **Merge**: `mergePoints` walks internal and streaming together in absolute time and emits
   every beat from both, suppressing a duplicate when two beats from different sources land
   within `duplicateToleranceMs = 50` of each other. Streaming points are rebased onto
   `wallClockMs`. This is a full two-way merge, not an insertion of gap-fill points only —
   the gap analysis is the decision, not the operation.

**Why 2-Second Threshold**: Normal RR intervals are 600-1200ms with ±200ms sinus arrhythmia variation. A 2-second buffer catches true recording gaps without flagging normal variation.

### Strap Link and Reconnection

The link is event-driven (`StrapLinkCoordinator`). SDK callbacks are pushed in order
through one stream (`StrapEventPump`) and applied on the main actor, so a disconnect can
never be applied after the reconnect that followed it.

1. **Readiness** (`StrapReadiness`): each link is a new generation. Polar SDK 8.x reports
   feature readiness only within ten seconds of service discovery; a feature it leaves
   unreported is *unconfirmed*, not unavailable, and callers go through
   `whenFeatureUsable`, which lets the SDK's own local guard decide and retries only its
   "not ready yet" refusals (`StrapErrorClassifier`).
2. **Heart-rate feed** (`StrapHeartRateFeed`): one subscription per link, opened when the
   link is established and re-opened on a short schedule until the strap delivers.
   Sessions never subscribe; they buffer what the feed delivers. A Verity Sense switches to
   PPI for a session. `scripts/check_hr_feed_subscribes_on_link.sh` keeps readiness waits out
   of it.
3. **Silence** (`StrapFeedHealth`): a linked feed that goes quiet is re-subscribed over the
   same link first; only a recording session escalates to a link reset, after the
   re-subscribe has had 30 s and at most once every 3 minutes.
4. **Drops**: `deviceDisconnected` **preserves `connectedDeviceId`** while a session is
   buffering and never touches the strap's own recording state. The SDK reconnects on its
   own (`automaticReconnection`); the app re-asserts the connect once and gives the session
   `PolarReconnectPolicy.windowSeconds` (20 min) before `reconnectExhausted` lets the
   collector save without it. A lost pairing is not retried and ends the wait at once.
5. On reconnect the session keeps every prior point and `streamingReconnectCount` increments.

### Pause & Resume (Split Sleep)

**Pause**: Streaming stops, full analysis runs, session archived as `.paused`, score preview shown, state persisted to UserDefaults.

**Resume**: New linked session created with `linkedSessionIds` pointing to parent, hybrid recording starts.

**Combined Analysis**: Both sessions' RR data is merged before window selection. The window selector sees the full night and chooses the best recovery window across both periods. The score comes from the combined analysis — not from picking the "best" of two independent scores. Sleep boundaries from HealthKit span both sessions so the 30-70% band covers the entire night.

**Auto-finalize**: Triggers on device disconnect or battery ≤5% while paused.

### Raw RR Backup Strategy

- **Initial backup**: the first tick writes immediately, whatever is buffered — `isDue` returns
  true when there is no previous backup, so nothing waits on a beat count
- **Incremental**: Every ~60 seconds (time-based, not count-based; `RawRRBackup.incrementalBackup` default `interval = 60`)
- **Force on reconnection**: Immediate backup when streaming reconnects
- Stored in the App Group container, which survives app updates but not deleting the app (iOS removes it with the last app in the group)

The time-based approach (Jan 2026 fix) replaced count-based backup which failed on reconnection when the buffer reset.

### Importing and rebuilding workouts Emuqu did not record

Two problems share one mechanism (`Sources/Import/`, surfaced by
`HealthWorkoutImportSheet` from the Fitness tab):

- **A recording that died.** A crash mid-workout leaves a stub — `WorkoutRecoveryService`
  archives whatever it had, which after an early crash is a one-second session. Apple Health
  still holds the passive record for that hour (steps, heart rate, distance, exercise minutes,
  flights), because it is sampled whether or not anything is recording.
  `HealthWorkoutImporter.rebuild` reconstructs the session from it and REUSES the stub's id, so
  the result replaces the ghost instead of sitting beside it. `ActivityBoutResolver` supplies
  the one thing the passive record cannot: when the activity ended (a bout runs until activity
  stops for longer than `defaultMaxGap = 10 min`, capped at `maxBoutDuration = 6 h`).
  `InterruptedRecordingCard` puts this on the Fitness tab when such a stub exists, rather than
  waiting for the user to find the import sheet.
- **People who record somewhere else.** Strava, Garmin, Nike Run Club and the Workout app all
  write to Apple Health. `HealthWorkoutImporter.candidates` lists workouts from the last 30 days
  that Emuqu does not already have, excluding the app's own writes at the query
  (`HKSource.default()`) so the list is not the user's own history offering to import itself.

An imported or rebuilt session carries distance, pace, route, elevation, cadence, calories and
heart rate, and carries **no RMSSD, SDNN or DFA α1**. Apple Health stores averaged heart rate,
not beat-to-beat intervals, and nothing recovers those from an average — so `rrSeries` and
`analysisResult` stay nil rather than being filled from the wrong input. Same bargain the GPX
importer makes; both funnel through `ImportedWorkoutTrack` → `ImportedWorkoutBuilder`.

Two HealthKit details the rebuild depends on, both of which were once wrong:
sample queries use an **overlap** predicate, not `.strictStartDate`, because Health writes
these quantities as batched windows and the window covering the start of a bout usually began
before it; and the cumulative distance query keeps `.strictStartDate`, because containment is
the right rule when summing over an interval.

---

## Analysis Algorithms

**File Organization**: `RecoveryScoreCalculator` keeps the composite entry points and the display helpers, with `+Composite`, `+Tiers` and `+Training` (training-load sub-score feeding the *parallel* training-readiness path — in the current scoring, `ScoringVersion.current` = `v3.oct2026`, training load is **not** a composite tier). Three pieces moved out on 2026-08-31 to take the type under the 1500-line limit: `ReadinessScoring` (training readiness), `VitalsScoring` (Tier 3 vitals sub-score + post-composite overrides) and `ScoreDetailBuilder` (tier composition and the detail sentences). Each has a forwarding extension on `RecoveryScoreCalculator` (`+ReadinessForwarding`, `+VitalsForwarding`, `+DetailForwarding`), so existing call sites are unchanged and the arithmetic is identical. `WindowSelection` is split into `+Scoring` (`findBestWindow`, `selectWindowByMethod`, `analyzeAtPosition`), `+Evaluation` (window scoring and classification) and `+Filters` (spike filtering and artifact thresholds).

### Artifact Detection

**Rolling Median Approach** — O(n × w) using insertion-sorted centered 50-beat sliding window:

| Classification | Condition | Confidence |
|---|---|---|
| Technical | RR < 300ms or > 2000ms | 1.0 |
| Extra beat | RR < median × 0.5 | ratio / threshold |
| Ectopic (short) | RR < median × (1 − 0.30) outer gate **and** deviation > 20% (`ectopicThreshold = 0.20`) | ratio / threshold |
| Ectopic (long) | RR > median × (1 + 0.20) — symmetric long-beat gate added 2026-06-22 | ratio / threshold |
| Missed beat | RR > median × (1 + 0.50) | ratio / threshold |

`minRR` was raised 200 → 300 ms on 2026-08-05 (`Constants.swift`). The 0.30 figure is the outer short gate (`extraThreshold`); the ectopic decision itself uses `ectopicThreshold = 0.20`.

### Time Domain Analysis

Requires ≥10 clean RR intervals. Metrics: meanRR, SDNN, RMSSD, pNN50, SDSD, meanHR, sdHR, minHR, maxHR, Triangular Index (N / max histogram bin, 7.8125ms bins).

### Frequency Domain Analysis

**Configuration**:
- Resampling: 4 Hz cubic spline to uniform grid (Nyquist = 2Hz > HF max 0.4Hz). Cubic spline preserves spectral characteristics better than linear interpolation.
- Welch method: 256-sample segments (64s @ 4Hz = 0.016Hz resolution) for LF and HF, 50% overlap, Hann window (-31dB side lobe attenuation), each segment linearly detrended before windowing
- Band boundaries: VLF 0.003-0.04 Hz, LF 0.04-0.15 Hz, HF 0.15-0.4 Hz
- VLF requires ≥10 min window (`minimumVLFWindowMinutes * 2`), nil otherwise. It comes from its own Welch pass with 1024-sample (256 s, 0.0039 Hz) segments; at 64-s segments the band is two bins next to DC
- Windows shorter than one segment use a single periodogram: Hann over the samples, then zero-padded, normalised by the window energy over those samples

### DFA Analysis

Detrended Fluctuation Analysis quantifies fractal-like correlation in RR time series.

1. **Integrate**: Cumulative sum of (RR - mean)
2. **Partition into Boxes**: Log-spaced sizes from 4 to N/4 (per Peng et al. 1995)
3. **Detrend Each Box**: Fit linear trend, compute RMS fluctuation from residuals
4. **Log-Log Regression**: slope of log(F) vs log(n) = α

α1 (short-term, box sizes 4-16), α2 (long-term, 16-64, requires ≥256 beats).

**Bands** (`WindowSelector.RecoveryWindow`, `HRVThresholds`):
- α1 ≈ 0.75-1.0: **Organized recovery** — the app's resting reference range
- α1 ≈ 0.6-0.75: **Flexible/unconsolidated** — below the reference range
- α1 ≈ 0.5: intervals close to uncorrelated
- α1 > 1.0: **High variability** — more correlated than the reference range
- α1 < 0.6: **Anti-correlated** — uncommon in healthy resting recordings, most often a sensor-quality artifact

These band NAMES are the app's internal vocabulary for window selection and
scoring. They are not validated readiness classifications, and the
copy that presented them as such was removed — "the gold
standard", "load-bearing", "white noise … not recovery". Two reasons, both
worth keeping in front of anyone editing these numbers:

- The published 0.75 anchor comes from **graded-exercise** protocols (Rogers &
  Gronwald), where α1 falls as intensity rises. It was never a resting
  readiness scale.
- The α1 figures this repo cites for sleep (PMC4100066, quoted on
  `optimalAlpha1Range`) put N3 — deep sleep, the stage most associated with
  physical restoration — at 0.78 ± 0.21, i.e. straddling the 0.75 lower bound.
  A band whose floor bisects the most restorative stage of the night cannot be
  the line between real recovery and noise.

The bands still drive window selection and a ±5 point Tier-1 adjustment, which
is deliberate and unchanged — there is no better-evidenced number to move them
to. `Tools/copy_linter` now blocks the verdict language from returning.

### Stress Analysis

**Baevsky Stress Index**: `SI = AMo / (2 × Mo × MxDMn)` where AMo = amplitude of mode (% in modal 50ms bin), Mo = mode, MxDMn = max-min span.

**PNS Index** (-3 to +3): Average of z-scores for meanRR (ref 926ms), RMSSD (ref 42ms), SD1 (ref 29ms).

**SNS Index** (-3 to +3): Average of z-scores for meanHR (ref 66bpm), stressIndex (ref 100), SD2 inverted (ref 65ms).

**Readiness Score** (1-10, `StressAnalyzer.computeReadinessScore`): starts at 5.0. RMSSD ratio to the baseline (the 60-day geometric baseline, VO2max-adjusted): 0.85–1.15 → +2, 0.70–1.30 → +1, below 0.60 or above 1.50 → −2, otherwise 0; absolute RMSSD bands stand in without a baseline. DFA α1: 0.75–1.0 → +2, 0.60–1.25 → +0.5, otherwise −1. PNS − SNS: ≥ +1 → +1.5, ≥ 0 → +0.5, ≥ −1 → −0.5, else −1.5. Recent hard training adds back its (negative) load adjustment. Clamped to [1, 10]. It is a nearness score: a night 31% above the baseline earns no RMSSD points, so α1 and the PNS/SNS balance can put it at 3.5 under a high Recovery Score. The Help Center describes it the same way.

### Respiration Rate Estimation

Spectral only: resample RR to 4Hz, FFT, peak in HF band → breaths/min. Needs ≥ 60 RR intervals. Sanity check: 6-40 breaths/min.

### Diagnostic Scoring

**AnalysisSummaryGenerator** (`computeDiagnosticScore`) computes a 0-100 diagnostic score from a base of 50, clamped to [0, 100]:
- RMSSD category: excellent +40, good +30, fair +20, reduced +10, low −10. With a baseline the category comes from the ratio to it (≥1.15 excellent, ≥0.85 good, ≥0.70 fair, ≥0.60 reduced, else low); without one, from the age-adjusted bands
- Stress Index: <100→+20, <150→+15, <200→+10, <300→0, ≥300→−15
- LF/HF: 0.5-2.0→+20, <0.5→+15, ≤3.0→+5, >3.0→−10
- DFA α1: 0.75-1.0→+20, otherwise 0
- ANS balance (PNS − SNS): ≥ +1→+15, ≥ 0→+10, ≥ −1→−5, else −15

The summary's headline score is the Recovery Score; the diagnostic score stands in only for a reading without one. The title and icon come from that score's `ScoreVerdict` (word and glyph: 90 Excellent, 75 Good, 60 Fair, 45 Pay attention, 30 Low, below that Very low) everywhere the summary appears: Morning Results, the PDF summary card, the assistant's context and its citations. The action steps read the same headline score (bands at 80, 60 and 40).

**Probable Causes** (60+ factors): Tag-based (alcohol, caffeine, travel, illness...), sleep-based (insufficient <6h, fragmented <80% efficiency, low deep <10%), pattern detection (consecutive declines, day-of-week), severe anomalies (>50% drop, elevated HR + low HRV).

---

## Window Selection

### Core Principle: 30-70% of Actual Sleep

Window selection operates on the **30-70% band of actual sleep duration** (from HealthKit when available), NOT recording duration.

### Selection Methods

| Method | Criteria |
|---|---|
| **Consolidated Recovery** (default) | Among organized windows, the one that scores highest under `RecoveryScoreCalculator.calculateTier1` — the ln(RMSSD) z-score model with its RHR and DFA adjustments, NOT raw RMSSD and NOT the block's own stability-weighted number. Falls back to RMSSD ranking when no 60-day baseline exists yet. |
| **Peak RMSSD** | Highest RMSSD, no organization filter |
| **Peak SDNN** | Highest total variability |
| **Peak Total Power** | Highest frequency domain power (SDNN proxy) |
| **Custom** | User tap on chart → 400-beat window, ignores 30-70% band |

Custom selections are ephemeral — never saved to archive, baseline, or trends.

### Algorithm Steps

**Config**: 400-beat target window, 40-beat slide step, clean-beat requirement = max(50, 75% of window) capped at 300 for full windows, 30-70% band, stability weight 10.0.

**Artifact rate is a two-pass rule, not one number.** Pass 1 keeps only windows at or under
`maxArtifactRateStrict = 0.10`, the bound the literature converges on (Plews 2013, Lipponen &
Tarvainen 2019, Citi 2012). Only when that pass yields zero windows does the scan re-run at
`maxArtifactRate = 0.15`, so a genuinely noisy night still produces a result instead of nil —
and `HRVDetailV2View` surfaces the rate so the user knows the reading is degraded.

**Step 1**: Build all windows within 30-70% using adaptive sizing:
- ≥400 beats in band → full 400-beat windows
- 240-399 beats → 50% of available beats
- <240 beats → 60% of available (minimum 60 beats)
- Step size: max(10, windowSize / 10)

**Step 2**: Filter isolated spikes (`isolatedSpikeRatio = 1.50` — RMSSD ≥150% of BOTH neighbours). No baseline-relative rejection, no magnitude caps. If the filter would remove every window, the unfiltered set is used instead: an all-spikes verdict is a filter failure, not a night with no recovery.

**Step 3**: Classify each window — DFA α1, LF/HF ratio, HR CV.

**Step 4**: Among Organized windows, rank by `RecoveryScoreCalculator.calculateTier1` and take the top one, breaking ties on RMSSD then position. With no baseline the ranking falls back to RMSSD. If no organized windows exist, return nil.

### Window Classification

`ScoredRecoveryBlock.isOrganizedRecovery` is deliberately tolerant, and the exact rule matters
because it decides whether a night produces a score at all:

- **α1 available, LF/HF available**: α1 ∈ [0.75, 1.0] **and** (LF/HF ≤ 1.5 **or** HR CV < 8%).
  Strong α1 plus *either* corroborating signal, not both.
- **α1 available, LF/HF missing**: α1 ∈ [0.75, 1.0] **and** HR CV < 8% — the stability
  requirement becomes mandatory so "organized" still means sustained regulation rather than an
  α1-only spike.
- **α1 unavailable** (too few beats to compute DFA): HR CV < 8% alone. Stability is the proxy.
- **Flexible/Unconsolidated**: DFA α1 ∈ [0.60, 0.75]
- **High Variability**: DFA α1 < 0.6 or > 1.0

### Peak Capacity

Computed independently — highest sustained RMSSD regardless of organization. Represents physiological ceiling. May exist even with no consolidated recovery window.

### Consolidation Score

`recoveryScore = rmssd × (1 / (1 + stabilityWeight × hrCV))`

---

## Recovery Score Calculation

Research-informed three-tier composite using ln(RMSSD) z-score normalization (Plews et al. 2013, Buchheit 2014).

> **Scale note:** every tier computes on a **0–100** scale; the result is converted via `RecoveryScoreCalculator.toTenScale` (called from `RRCollector+Analysis.swift`) to a **1–10** scale before it is stored on `HRVSession.recoveryScore`. The "0–100" here and the "1–10" in [Storage & Sync](#storage--sync) are the same number pre- and post-storage, not a contradiction.

**Architecture (May 2026):** the score is `HRV + Sleep + Vitals`. Training load is **not** in the composite — it lives on the parallel Load & Trajectory page. Rationale: per Impellizzeri et al. (2020 IJSPP 15(6); 2021 Sports Med 51:581–592) ACWR's chronic denominator carries no real injury-prediction signal (random numbers in the chronic position produce nearly identical odds ratios). Per Doherty/Altini 2025 systematic review of 14 commercial composite scores and Marco Altini's HRV4Training methodology, training load already manifests downstream as suppressed HRV / elevated RHR — folding it back into the score double-counts the same physiological event. Rule restated in `ScoringWeights` doc-comment.

### Tier 1 — HRV Only (cold start, no sleep, no vitals)

```
z = (ln(RMSSD_today) - mean_60d(ln(RMSSD))) / SD_60d(ln(RMSSD))
hrvScore = SWC band model (Plews/Buchheit, defined in `RecoveryScoreCalculator.scoringParametersV2`):
         z ≤ -3.0  →  5  (floor)
         z = -1.5  → 25
         z = -0.75 → 64  (meaningful drop only starts below −0.75 SD)
         z = -0.5  → 72  (SWC deadband floor)
         z ∈ [-0.5, +0.5] → 72  (flat deadband — within ±0.5 SD = no change, NOT inflated)
         z ≥ +1.5  → 90  (plateau — above baseline is ambiguous per HRV4Training)

Adjustments (all five are applied; `calculateTier1` sums them):
  RHR:  zHR = (HR - HR_baseline) / HR_SD → clamp(zHR × -5, -10, +10)
  DFA:  α1 ∈ [0.75, 1.0] → +5  |  α1 > 1.2 → -5  |  α1 < 0.6 → -3
  CV:   7d CV < 2% → -5 (autonomic flatlining)  |  CV > 12% → -3 (unstable)
  ANS:  PNS − SNS < -1.5 → -6  |  < -0.5 → -3  |  ≥ +1.5 → +2  (±0.5 deadband)
  Stale: no session for ≥7 days → -5, growing by 5 per further week, capped at -20
```

Missing sleep: with sleep integration and `penalizeMissingSleep` on, a Tier 1 night with no sleep data
loses `missingSleepPenalty` (10) after the factor sum, alongside the SpO2 penalty, and is listed in
`ScoreBreakdown.penalties` as "No sleep data (−10)". The perceived-readiness blend recomposes through
the same `composeFinalScore`, so it keeps both penalties.

Falls back to the raw ANS readiness score (1-10 → 10-100) when the 60-day baseline has fewer
than 3 days of data (`RecoveryBaselineStats.minimumDays`), and below that to absolute RMSSD bands (≥60 → 85, ≥45 → 70, ≥30 → 55,
≥20 → 40, else 25; 50 when there is no HRV at all).

The ANS-balance term is the one the window-ranking trace calls out as excluded — `WindowSelector`
ranks candidate windows on the other four, so a window's rank score and the session's final
composite can differ by ±3 to ±6.

### Tier 2 — HRV + Sleep (sleep present, vitals absent)

When stage data is available the sleep sub-score is `SleepScienceAnalyzer`'s enhanced score
(fragmentation, cycles, architecture, age-adjusted norms). The weighted formula below is the
FALLBACK used when no stage breakdown exists.

```
sleepScore = (durationRatio × 0.35 + efficiency × 0.25
            + deepSleepRatio × 0.25 + remRatio × 0.15) × 100

Normal:   tier1 × 0.70 + sleepScore × 0.30
Double-penalty dampening (z_hrv < -1.0 AND sleepScore < 50):
          tier1 × 0.85 + sleepScore × 0.15
```

Double-penalty dampening prevents counting the same event twice when HRV already reflects poor sleep.

### Tier 3 — HRV + Sleep + Vitals (full-signal day)

```
vitalsScore = average of available sub-scores (RHR, RR, wrist temp):
  RHR:    zHR = (RHR - HR_baseline) / HR_SD; max(0, 100 - zHR × 10) [floor 0]
          (below-baseline RHR scores 100 — no penalty for being well-rested)
  RR:     dev = RR - RR_baseline_7d; max(0, 100 - max(0, dev - 1) × 15) [floor 0]
          (within ±1 br/min of baseline scores 100)
          No personal baseline yet → graded against the population window instead:
          12–18 br/min → 100, above 18 → the same 15/br-min gradient, below 12 → flat 90
          (a very low overnight RR is the same signal as a low resting HR, not a deficit)
  Temp:   dev = tonight − mean of the 7 days before tonight (both on the same normalised scale;
          `RecoveryScoreCalculator.wristTemperatureAgainstPersonalBaseline`); no baseline → dropped
          POSITIVE deviation only — dev ≤ 0.3°C → 100  |  ≤0.5 → 75  |  ≤1.0 → 50  |  >1.0 → 25
          A cooler-than-baseline reading scores 100. It reflects bedroom temperature, lighter
          bedding, deeper SWS or cycle phase, none of which indicate impaired recovery, and an
          abs(dev) penalty has no support in the literature.
  Missing inputs are dropped — score is the average of what's available.
  All-nil vitals → returns nil → caller falls back to Tier 2.

composite = tier1 × 0.60 + sleepScore × 0.25 + vitalsScore × 0.15
```

### Comeback mode

When the user toggles `comebackModeStartDate` (Settings → Modes → "Comeback mode"), the Tier 3 weights shift for 21 days:

```
HRV 0.80 + Sleep 0.20 + Vitals 0.00
```

Rationale: RR, RHR, and wrist temperature can stay elevated for weeks after a viral infection (Apple's published RR-as-illness-precursor data shows multi-day lag). HRV is the most adaptive autonomic signal; weighting it heavier during a comeback prevents slow-recovering vitals from dragging the score down while the user re-acclimates. Vitals are still surfaced in the breakdown for visibility — they're just not contributing weight. Window auto-expires on day 21 via the computed `UserSettings.isComebackModeActive` (no setter mutation; the value type can't self-clean, so the date stays until the user manually toggles or the settings document is rewritten).

### Vitals overrides (post-composite, all tiers)

Only SpO2 retains a post-composite penalty in the current scoring:

- SpO2 <95% → −10 (flag-only signal — often reflects altitude or sleep apnea rather than recovery state)

The pre-2026-05-02 RR / temperature post-composite penalties were folded into the new Vitals factor (Tier 3) where they contribute as a continuous sub-score rather than a binary penalty.

Magic numbers for all scoring thresholds (z-score clamps, DFA bands, CV thresholds, Vitals sub-score weights, Comeback weights, SpO2 penalty, etc.) are centralized in the constants files: `ScoringWeights` lives in `Constants.swift`, while `RecoveryScoreConstants` (and the ACWR / capacity-ratio / freshness-bonus figures) lives in the `Constants+RecoveryScore.swift` extension.

### Confidence pips (cold-start UX)

Three-stage indicator next to the score on the dashboard:

```
nights 0–13:  ●○○ "Building baseline"     (score hidden on Dashboard / score detail)
nights 14–27: ●●○ "Provisional baseline"  (score shown, baseline still maturing)
nights 28+:   ●●● "Full algorithm"        (baseline keeps growing to 60 nights)
```

Tap reveals the night count + an explanation. Source: `BaselineTracker.daysCollected` (nights in the baseline). The thresholds are `ScoreAppearancePolicy` (`DashboardSessionPolicy.swift`): z-scoring starts at `personalBaselineNights` (= `RecoveryBaselineStats.minimumDays`, 3; nights 1–2 use absolute thresholds), the score is shown from `scoreShownNights` (14), full at `fullBaselineNights` (28). Help, Flo's knowledge base and onboarding state the same rule. Implemented in `ConfidencePip.swift`.

### Score feedback

No screen asks the user to rate the Recovery Score. The only morning input is the 1–5 morning feeling (the pre-score prompt and the dashboard chip), stored on the overnight session. `RecoveryScoreFeedbackStore` (App Group, `Feedback/recovery_score_feedback.json`) is never read into scoring and is cleared by "Delete all my data". Feedback is deliberately **not** wired into automatic weight adjustment (it would create a self-fulfilling prophecy — the user who consistently rates high-score-bad-day would pull the score down even when the algorithm is correct).

---

## Training Readiness Calculation

Training readiness (0-10 scale) is **independent** of the recovery score. Recovery measures morning physiological state (HRV, sleep, vitals). Readiness measures capacity to absorb additional training load based on fitness-fatigue dynamics (Banister 1975).

### Capacity Ratio Model

The primary signal is the ratio of current effective load to chronic training load:

```
acuteFatigue  = Σ TRIMP_i × 0.30 × e^(−hoursAgo_i / 24)   (workouts in the last 72 h; today's TRIMP × 0.35 without them)
effectiveLoad = ATL + acuteFatigue
capacityRatio = effectiveLoad / CTL          (when CTL ≥ 3.2)
```

Piecewise linear mapping to 0-100:

```
ratio 0.0  → 100  (fully rested)
ratio 0.8  → 85   (sweet spot — well managed load)
ratio 1.0  → 70   (matched — normal fatigue)
ratio 1.3  → 50   (overreaching)
ratio 1.5  → 30   (sharp recent increase over the chronic base)
ratio 2.0+ → 10   (extreme overload)
```

When CTL < 3.2 (no training history): `readiness = max(10, 100 - (ATL + undamped acute load) × 0.5)`, where the acute load is the decayed TRIMP sum without the 0.30 factor (`ctlThreshold` recalibrated 5.0 → 3.2 on 2026-04-23 after the TRIMP 0.64 scaling fix)

### ACWR Modifier (Training Readiness only — NOT the recovery score)

Used as a graded modifier on the live Training Readiness gauge (the secondary "should I train hard today" pill, distinct from the morning Recovery Score). Detects sharp recent load increases independent of capacity ratio:

```
ACWR 0.8–1.3: no effect (within usual range)
ACWR > 1.3:   penalty = min(5% + (ACWR - 1.3) × 50%, 40%)
ACWR < 0.8:   no penalty (detraining penalty removed; sub-0.8 readings
              are most often tapers / rest weeks / natural variation)
```

Two dampeners shipped 2026-05-01 reduce the penalty's effect when the underlying ratio is unreliable or contradicted by direct physiology:

1. **Low-CTL confidence ramp.** Penalty multiplied by `min(CTL/50, 1.0)`. At CTL=16 the ratio is mathematically noisy (one 40-TRIMP walk swings it ~0.2); the ramp prevents that noise from steamrolling the readout.
2. **Autonomic-state rescue.** When the morning recovery score is ≥70, the ACWR penalty is capped at 10%. The proxy (ACWR) shouldn't override the direct physiological signal (HRV) when they disagree on a clearly-recovered morning.

Per Impellizzeri 2020/2021 the ratio's signal value for predicting injury is weaker than the original Gabbett framing claimed; Emuqu shows it as descriptive load-range context on the Load & Trajectory page and uses it as a graded readiness modifier here, but does not surface ACWR by name in user-facing copy and does not present it as an injury predictor (rules 11 and 13 of the system prompt in `AIProvider+SystemPromptText.swift`).

### Fatigue Dissipation (intra-day)

On rest days, ATL dissipation improves readiness: `freshnessGainMultiplier = 1.5` readiness points per ATL unit of drop, capped at `freshnessGainCap = 20` (`applyFreshnessBonus`, `Emuqu/Sources/Analysis/ReadinessScoring.swift`).

### Recovery Modulation

The recovery score modulates readiness asymmetrically (`applyRecoveryModulation`). Above the recovery score, only part of the excess is kept: `recovery + gap × min(CTL/40, 1) × 0.55` — no excess at CTL 0, at most 55% of it from CTL 40. Below the recovery score, 30% of the gap is given back toward it.

### Key Difference from Recovery Score

| Metric | Scale | Based On | Updates |
|--------|-------|----------|---------|
| Recovery Score | 0-100 | HRV (60%) + Sleep (25%) + Vitals (15%); SpO2 post-penalty | Fixed at morning measurement |
| Training Readiness | 0-10 | CTL/ATL capacity ratio, today's strain, ACWR (graded with confidence ramp + autonomic rescue dampeners) | Live throughout the day |

References: Banister et al. (1975), Morton et al. (1990), Foster (1998); Plews et al. (2013), Buchheit (2014) for HRV scoring; Impellizzeri et al. (2020 IJSPP 15(6); 2021 Sports Med 51:581–592) on ACWR's actual signal value; Doherty/Altini (2025 Translational Exercise Biomedicine 2(2):128–144) on commercial composite-score architectures; Altini's HRV4Training methodology for "trust HRV when proxies disagree."

---

## Sleep Pipeline

### Sleep Boundary Resolution

Consolidated resolver with fallback chain:
1. HealthKit sleep data (primary)
2. HR-based estimation from RR data (optional)
3. Recording boundaries (final fallback)

**Fresh-data handling**: When `MorningResultsView` fetches HealthKit data covering a longer sleep period than was available at acceptance, `updateSessionSleepBoundaries()` writes the extended boundaries into the archived session (clamped to recording duration) and syncs to iCloud.

### Sleep Query Window

`fetchSleepData(for:recordingEnd:rrPoints:autoSleepExtension:)` queries the recording's own
boundaries. There is no display-vs-analysis mode switch: an earlier `extendForDisplay` flag
(false = exact boundaries, true = extend to 2pm next day) is described in older notes but does
not exist in the code. The only thing that widens the query is a supplied `autoSleepExtension`,
which — see below — nothing currently supplies.

### HRV Sleep Stage Classification

Two-path strategy in `SleepMergingPipeline`:

**Path 1 — HRV-Enhanced Watch Stages** (Watch stages + augmentation enabled):
- Uses Watch stages as anchor
- Compares each 5-minute epoch the Watch covers against RR-derived features (RMSSD, HF power, HR variance)
- Reclassifies where HRV evidence strongly disagrees (deep↔core, REM↔awake)
- Only the overridden epochs change: Watch sleep outside the strap recording, across strap dropouts, or never overridden keeps the Watch's stages and timing

**Path 2 — Full HRV Classification** (no Watch stages):
- Generates deep/core/REM/awake from RR data alone
- Uses epoch-level RMSSD, HR, and spectral features per ~5-minute window
- Requires ≥100 RR points and valid sleep boundaries

The `enableHRVSleepAugmentation` setting controls augmentation only — standalone classification (Path 2) always runs when no Watch data exists.

### Sleep Science Analysis

Based on Ohayon et al. (2004), Buysse et al. (2014), Phillips et al. (2017):

- **Fragmentation Index** (0-100): Wake episode frequency and awake time. Lower = better.
- **Sleep Cycles**: Detects NREM→REM cycles. Typical healthy: 4-5 complete.
- **Architecture**: Checks deep sleep front-loading (early night) and REM back-loading (late night).
- **Age-Adjusted Norms**: Expected deep/REM/efficiency ranges by age.
- **Enhanced Score**: Multi-factor 0-100 used by Tier 2 when stage data available.

### HR-Estimated Sleep (fallback, not extension)

When HealthKit returns **zero** sleep for a session, `MorningResultsViewModel.estimateSleepFallback`
tries to recover a night from what the passive record does hold, in this order:

1. **RR-derived estimate** from the session's own beats (`HealthKitManager.estimateSleepFromHR`),
   when the recording captured any.
2. **Apple Watch passive HR** (`estimateSleepFromHealthKitHR`), over the session window extended
   to the end of the user's sleep schedule.

This is a **coarse heuristic, not a polysomnography-validated staging model** — HR-only
sleep/wake detection is limited by the absence of motion/actigraphy, and the app makes no
validated-accuracy claim for it. It runs only to fill a night that would otherwise show nothing.

Algorithm (arithmetic in `HRSleepEstimator`):

  1. Smooth the passive-HR samples with a **20-minute rolling average** (handles sparse, noisy data)
  2. Require an HR range **≥ 8 BPM** across the window — below that there's no meaningful
     sleep/wake split, so it bails
  3. Adaptive threshold = `maxHR − (maxHR − minHR) × 0.5` — the **midpoint of the window's own
     HR range**, so it self-personalises per night
  4. Sleep onset = first **2 consecutive** smoothed points below threshold, then **clamped** to a
     plausible sleep-onset latency (2026-08-05) so deep-sleep bradycardia can't report a bogus
     late onset and shrink the night
  5. Wake = end of the **last continuous** below-threshold block (2026-07-01), so a mid-night HR
     bump (bathroom trip, REM tachycardia, BLE-gap artifact) doesn't truncate the night

```
minimumSamples      = 12 (~2 h at 10-min spacing)
minimumSleepMinutes = 120
smoothing window    = 20 minutes (rolling average)
HR-range gate       = ≥ 8 BPM
threshold           = 50% of the window's HR range (min→max midpoint)
onset rule          = first 2 consecutive smoothed points below threshold (latency-clamped)
```

> **Not implemented: post-session sleep extension.** `SleepResolver.AutoSleepExtension` exists
> and `fetchSleepData` threads it through to the merging pipeline, but **nothing in the app ever
> constructs one** — every production call site passes nil, and only `SleepResolverTests` builds
> one. So there is no "the user took the strap off, went back to bed, and the app annexed the
> extra sleep" path in the shipping build. The resolver is ready for it; the trigger was never
> written. Earlier revisions of this section described that trigger
> (`DashboardViewModel.checkForExtendedSleep`, a merge that re-froze the archive) as though it
> shipped. It did not, and `DashboardViewModel` no longer exists at all.
>
> **History (2026-08-16):** revisions before that described an
> "ECDF / P35, Walch et al. 2022, validated against polysomnography" algorithm. That algorithm
> was never implemented either — no `WatchSleepDetector`, ECDF, or percentile code exists — and
> the citation was inaccurate (the real Walch et al. paper is 2019, *SLEEP*, a machine-learning
> *staging* study, not an ECDF sleep/wake detector). The method choice was assessed and kept
> deliberately: for HR-only, motion-free detection the thresholding method is a marginal factor
> versus the HR-only accuracy ceiling, and this heuristic has been hardened against the real
> overnight artifacts above.

---

## Baseline & Trends

### 7-Day Rolling Baseline

- Rolling window: 7 days, minimum 3 samples, max 90 data points stored
- Metrics: RMSSD, SDNN, meanHR, HF, LF, LF/HF, DFA α1, Stress Index, Readiness

**Admission**: overnight sessions only (quick, nap, breathe and workout readings never enter), and only HRV-reliable, structurally sound ones.

**One slot per night**: slots are keyed by the night's wake date (`SleepSchedule.nightKey`), not the calendar day, so a night started at 23:30 and its 00:30 continuation share a slot. When a night has more than one reading, only one contributes:
- A morning reading (ends inside its own night, no later than expected wake + 4 h) always beats a non-morning one
- Otherwise the newcomer must be objectively better (consolidation, organized recovery, artifact and HR-stability gates, then >5% readiness)

### 60-Day Recovery Baseline

Separate from the 7-day baseline, used for z-score normalization:
- `lnRmssdMean`, `lnRmssdSD` over 60-day window
- `lnRmssdCV7Day` — 7-day coefficient of variation (overreaching signal)
- `meanHRBaseline`, `meanHRSD`
- Minimum 3 days for a z-score (`RecoveryBaselineStats.minimumDays`); below 7 days the SD is widened (≈1.53× at 3 days) so early scores stay near the middle
- A night is scored against the nights before it, never itself or later nights (Kiviniemi 2007, Plews 2013: the reference is built from earlier days): scoring paths use `recoveryBaselineStats(excludingNightOf:sleepSchedule:)`, which keeps only slots whose night key is earlier than the scored night's. The plain `recoveryBaselineStats` (every night) is for display

---

## Storage & Sync

### Session Archive

File-based JSON in App Group container with SHA256 integrity checking.

**Index**: `SessionArchiveEntry` stores lightweight metadata in memory — e.g. sessionId, date, endDate, recoveryScore, meanRMSSD, meanHR, stressIndex, meanSDNN, tags, sessionType, linkedSessionIds, plus `fileHash` / `filePath`, `notes`, and the sleep-index fields (`sleepEnd`, `sleepSegmentCount`, deep/rem/core/awake minutes, nocturnal-HR-dip) that make trend + AI queries possible without loading full sessions (see `Emuqu/Sources/Models/SessionMetadata.swift`, `SessionArchiveEntry` for the authoritative field list). This enables trend computation and filtering without loading full sessions from disk. A sorted cache (`sortedEntriesCache`) avoids re-sorting on every `entries` access.

**Locking**: `archiveLock` (NSLock) protects the in-memory index. All migrations use 3-phase locking — gather work items under lock, release for disk I/O, reacquire to apply patches — so the main thread is never blocked for more than a few milliseconds. `archive()`, `retrieve()`, `entries`, and other public APIs acquire/release the lock per-call.

**Lightweight Retrieval**: `retrieveLightweight()` sets `skipRRSeries = true` on the JSON decoder, skipping the heavyweight `rrSeries` field (~700KB–1.5MB for overnight sessions). All other fields (analysisResult, sleepSnapshot, vitalsSnapshot, etc.) are preserved. Used by dashboard session loading, paused session search, and trend views.

### UI Session Load Contract

Load limits are per-screen, not tab-routing-dependent: no screen inherits another screen's
list. `MainTabView` holds exactly one such list — `@State var sessions`, the dashboard's own
35-session slice, which it loads and passes into `DashboardV2View` and nowhere else. Every
other screen fetches its own.

| View | Source | Scope | Invalidation |
|------|--------|-------|--------------|
| `DashboardV2View` | `recentSessionsAsync(limit: 35)` (`MainTabView.dashboardSessionLoadLimit`) | 35 newest sessions — Recent strip needs deeper archive coverage to keep its swipe rail populated through gaps; only 8 are visible at a time. | `RRCollector.archiveVersion` + `CloudKitSyncManager.pullVersion` |
| `TrendsV2View` | `recentSessionsAsync(limit: nil)` → filter `sessionType == .overnight && analysisResult != nil` | **All qualifying overnight sessions.** No code-path cap below the selected period. | `RRCollector.archiveVersion` + `CloudKitSyncManager.pullVersion` |
| `HistoryView` | `archive.entries` (full index) + lightweight retrieval on demand | Full set, paginated display-only (`pageSize = 10`) | `RRCollector.archiveVersion` |

**Trend cap contract**: The only user-facing cap on trend input is the period selector (`twoWeeks` / `month` / `threeMonths` / `all`). No routing, tab-switch, or refresh code path may silently reduce the set below the selected period. If post-filter the set has <2 data points, `TrendsV2View` shows an explicit "need more overnight sessions" state.

**Concurrency**: Each view owns one in-flight refresh `Task`; issuing a new refresh cancels the prior one. UI state writes occur on `MainActor` after `!Task.isCancelled` is checked **both** before the MainActor hop and again inside the closure — cancellation is cooperative, and the outer guard races the hop.

**Sort orders (deliberate, not a bug)**:

| Layer | Sort | Reason |
|-------|------|--------|
| `SessionArchive.entries` | `startDate` descending (newest-first) | Primary index; `recentSessionsAsync(limit:)` walks it front-to-back. |
| `HistoryViewModel.filteredEntries` | `displayDate` (= `endDate ?? startDate`) descending | Users think of an overnight as happening on the morning it ends, not the evening it began. |
| `TrendAnalyzer.filteredDataPoints` | `date` ascending | Time-series plotting + linear regression expects left-to-right chronology. |

Each layer re-sorts only because its consumer requires a different order. Do not try to unify.

**Delete Safety**: `deletedSessionIds` prevents CloudKit sync from re-creating deleted sessions. `delete()` atomically: (1) adds to `deletedSessionIds` and persists, (2) removes from active index, (3) deletes file.

**Recovery Score**: `session.recoveryScore` stores the composite recovery score on a 1-10 scale. In the current scoring (`ScoringVersion.current` = `v3.1.oct2026`) it's HRV + Sleep + Vitals when all three are available, falling through to HRV + Sleep or HRV only when inputs are missing. Each `ScoreBreakdown` is stamped with the version that produced it (`scoringVersion`); scores stored before the stamp existed decode as `unversioned`. Older sessions may have been computed under v1 (HRV + Sleep + Training); `ScoreArchitectureChangeSheet` only discloses the change, and re-running `reanalyzeAllSessions` from Settings recomputes history if the user wants it. `ANSMetrics.readinessScore` remains available in `analysisResult` as the HRV-only readiness component. The window selector's `RecoveryWindow.recoveryScore` (RMSSD × stability) is for ranking only, not persisted.

**Deferred Migrations**: `runDeferredMigrations()` runs 7 one-time passes on a background thread at launch: `reencryptPendingSessions`, `migrateRecoveryScores`, `migrateEndDates`, `migrateMetrics` (backfills meanHR/stressIndex), `migrateSleepIndexFields` (backfills `sleepEnd` / `sleepSegmentCount`), `removeDuplicates`, and `relinkSameNightSessions`. Each is a no-op if already complete.

**File Organization**: `Archive` is split into extensions — `Archive+Migrations.swift` (deferred migrations), `SessionMerger.swift` (session merging logic), and `Archive+Repair.swift` (integrity repair utilities).

### iCloud Sync

CloudKit private database, auto-upload on every save, ZLIB compression (~80-90% reduction), full sync on launch/foreground. Deletes propagate via soft-delete flag. No third-party servers.

Edits reach devices that already hold the session. An edit (feeling, tags or notes, trim, sleep edit, reanalysis) stamps `HRVSession.modifiedAt` in whole seconds; the stamp travels in the encrypted payload and as a plain `modifiedAt` date field on the record, so a pull compares without downloading every backup. Last writer wins: a pull replaces a held copy only when the iCloud copy is strictly newer (keeping that device's HealthKit snapshots unless the sleep window changed), and an upload that meets a newer iCloud copy leaves it for the pull to import. An unstamped copy counts as older than any stamped one. Imported copies are marked uploaded, never queued again. The `modifiedAt` field must be deployed to the production CloudKit schema; until it is, uploads go without it and edits do not propagate (`CloudKitSessionFreshness`).

### Apple Health Export

Writes SDNN, mean HR, and resting HR back to Health, plus a **windowed RMSSD + SDNN series** (`exportWindowedHRV`) and a **heart-rate series** (`exportHeartRateSeries`). Sleep export creates one `HKCategorySample` per stage interval (iOS 16+ values) — plus an overall `inBed` sample — each stamped with `HKMetadataKeyExternalUUID` for idempotent re-writes. Toggling the setting on applies to all archived sessions. (Export code lives in `Collection/HealthKitManager+{HRV,HeartRate,Sleep}.swift`.)

### PDF Reports

**Overnight session report** (`PDFReportGenerator`) — Letter-sized, narrative-first:
- **Page 1**: Metrics summary (HRV hero, readiness gauge, HR stats, overnight stats, sleep analysis, training load, vitals, complete metrics grids, tags/notes)
- **Page 2**: Visualizations (HR chart, Poincaré plot, PSD graph, tachogram, data quality, window info) — only for sessions with raw RR data
- **Page 3+**: Deep-dive section — deep HRV/Sleep/Training/Vitals analytics page(s) plus a separate full-narrative page from `AnalysisSummaryGenerator`. Rendered only for the comprehensive style with deep-dive enabled (`style == .comprehensive && sections.contains(.deepDive)`).

**Workout report** (`WorkoutPDFReport`) — Letter-sized, clinical-style 6–7 page report:
- **Page 1**: Executive Summary (physician-language 2–3 paragraph clinical snapshot + 12-tile metrics grid)
- **Page 2**: Autonomic / HRV (α1 timeline with AT1/AT2 reference lines, RMSSD/pNN50/LF-HF, drift indicators)
- **Page 3**: Cardiopulmonary (HR distribution, zone time, HR drift, HRR 1-min / 2-min)
- **Page 4**: Effort & Terrain (power/pace, elevation, grade, MKMapSnapshotter route coloured by α1 band) — only when GPS is present
- **Page 5**: Splits + Derived metrics (decoupling, efficiency factor, grade-adjusted pace, stride length, power:HR)
- **Page 6**: "What This Means" — plain-language bridge (verdict / what's working / what to watch / tomorrow) via `drawWhatThisMeansPage`
- **Page 7**: Methodology & Citations

All charts are downsampled to ≤ 400 points for fast rendering.

---

## Localization & Translation

### Static Localization

All fixed UI labels, button text, and settings strings use `Localizable.xcstrings` with `String(localized:bundle:)` and `LocalizedStringKey`. 17 languages are supported.

### Dynamic Narrative Translation

Dynamically generated text (analysis summaries, recovery narratives, coaching messages) cannot be pre-translated because it's assembled at runtime from metrics. `NarrativeTranslator` handles this using Apple's on-device Translation framework (iOS 18.0+):

1. Views call `prepare([strings])` to queue English text for translation
2. A `.translationTask` modifier triggers batch translation via `TranslationSession`
3. Translated text is cached; views re-render when `cacheVersion` increments
4. `generation` drives `.onChange` → `config.invalidate()` to start new translation cycles
5. `taskRunning` flag prevents re-entrant invalidation during active translations

Cancellation requeues strings without counting as failures. Genuine errors allow max 2 retries per string.

### LanguageManager

Singleton that manages live language switching:
- Updates `locale` and `bundle` for SwiftUI environment and `String(localized:)` calls
- Resets cached date formatters on language change
- Posts `languageDidChangeNotification` so `NarrativeTranslator` can clear its cache

---

## In-App Purchase

`StoreKitManager` manages a non-consumable lifetime purchase
(`com.chrissharp.flowrecovery.lifetime`, a one-time purchase) via StoreKit 2:
- Listens for `Transaction.updates` (refunds, family sharing)
- Verifies transactions and checks `Transaction.currentEntitlements`
- `PaywallView` presents as a mandatory gate or optional settings view
- Debug builds support a persisted bypass flag

**Switched on** (`StoreKitManager.paywallEnabled = true`). Four bypasses sit
in front of the gate, checked in this order:

| Bypass | Source | Lifetime |
|---|---|---|
| Purchased | `Transaction.currentEntitlements` | permanent |
| Grandfathered beta tester | `EntitlementAnchor.isBetaTester` | permanent, follows the Apple ID |
| Developer install | `isDeveloperInstall` (DEBUG, TestFlight, or an `AppTransaction` verified as Xcode) | while that build is installed |
| Free trial | `TrialPolicy`, 30 days | until it runs out |

### The free trial is a $0 in-app purchase, 30 days long

StoreKit only attaches introductory trials to auto-renewable subscriptions.
Guideline 3.1.1 gives a paid-unlock app one sanctioned route instead: a
non-consumable at price tier 0 named "XX-day Trial", with the trial's
length, what locks at the end, and the price stated before it starts. The
trial product is `com.chrissharp.flowrecovery.trial30day`. Thirty days
because the Dashboard withholds its headline score until 14 nights and
reaches full confidence at 28: a shorter trial ends before the user has seen
what they would be buying. `PaywallGatePolicy.reminderWindowDays` keeps the
daily reminder out of all but the last week.

Nothing starts the trial automatically. After onboarding, a user with no
other route in meets the paywall, whose first button is "Start 30-Day Free
Trial" above the required terms. `StoreKitManager.startFreeTrial()` buys the
free product and adopts its `purchaseDate` as the trial start; every later
entitlement sweep adopts it again, so the App Store's copy of the clock
backs the anchor on any device. There is no other way to start it: if the
product cannot be loaded or the purchase fails, the paywall reports it like
any failed purchase and the trial does not start. The button waits for the
unlock's store price, because the terms beside it have to state it. Owning
the trial product grants nothing; `TrialPolicy` still decides whether the 30 days are
running.

App Review runs on a sandbox receipt, which is indistinguishable from
TestFlight, so a reviewer is a permanent-access user and never meets the
gate. Both products are reached from **Settings → Purchase**, which shows
the trial and purchase buttons to anyone who has not bought, under a note
that no purchase is needed when that is true. There is no beta wording on
any screen a sandbox user can reach.

### `EntitlementAnchor`

The beta cohort is closed, so the anchor infers a tester from history as well
as from a receipt: at the first launch that has not yet checked, a store build
that finds archived sessions on the device records the user as a beta tester
(`evaluatedHistory`). A fresh App Store install has no sessions at that
moment, and the check's timestamp is stored so a new user's trial-period
recordings never count later. TestFlight builds do not take that look: they
anchor the tester outright on every launch until it sticks, and a verified
sandbox `AppTransaction` anchors too. The timestamp is stored as
`storeHistoryCheckedAt`; the older `historyCheckedAt`, which TestFlight
builds wrote, is ignored so a tester whose phone was empty when an old beta
looked is looked at again on the store build.


`Emuqu/Sources/Services/EntitlementAnchor.swift` durably stores the two facts that
must outlive an app deletion — whether this Apple ID was ever a TestFlight
beta tester, and when the trial began. Two tiers, written on every change
and merged monotonically on every read:

1. **UserDefaults** — synchronous, for the launch critical path. Cache only.
2. **Keychain**, `kSecAttrSynchronizable` — survives app deletion and
   replicates across the user's devices through iCloud Keychain. This is the
   authoritative tier, and it needs no new entitlement (which is why it is
   used in preference to `NSUbiquitousKeyValueStore`, whose
   `ubiquity-kvstore-identifier` entitlement would force the provisioning
   profile to be regenerated).

`EntitlementAnchor.persist()` writes those two and `resolve()` merges those
two — **that is the whole of what this type owns.**

A third copy of `trialStartDate` exists and is deliberately *outside* the
anchor: **`UserSettings.trialStartDate`**, which already round-trips through
`CloudKitSettingsSync`. It is bridged in by
`SettingsManager.adoptTrialStart(_:)` via `adoptTrialStart(_:wallClock:)`,
which folds the value in (earliest wins) and mirrors the resolved value back
out. It backstops the trial date for a user who has
iCloud Keychain switched off. Do not remove that bridge on the assumption the
anchor covers it — the anchor does not write settings.

Merge rules make the guarantees: beta status ORs (never revoked by a tier
that has not heard of it), the trial start takes the EARLIEST value (a
reinstall resumes the original clock instead of granting a fresh 30 days), and
a high-water mark takes the LATEST wall-clock time ever observed (so winding
the device clock back does not extend the trial).

`isTestFlight` answers only "is THIS build a TestFlight build" and is
deliberately uncached — see its doc comment for the entitlement bug that
conflating the two facts used to cause.

---

## AI Assistant

The `Sources/Assistant/` module is a self-contained, provider-agnostic chat +
voice assistant ("Flo") that surfaces every metric the app produces in natural
language, via tool-use over a typed Fact Catalog, across six providers (Apple
Intelligence on-device + Anthropic / OpenAI / Gemini / Grok / DeepSeek).

**This section is deliberately short — the AI module owns its own authoritative
docs.** For the full spec — turn lifecycle, provider matrix, tiered routing,
fact/tool system, cache-aware system prompt, voice subsystem, safety gates —
see [`FLO_ARCHITECTURE.md`](FLO_ARCHITECTURE.md). For the
fact-catalog contents, the tool-use data path, and voice field-notes see
[`VOICE_AND_TOOL_USE.md`](VOICE_AND_TOOL_USE.md). **Do not restate their
internals here.** This section previously carried a full second copy of the AI
mechanics and drifted (a tool-call budget was documented as 4 here while the code
and VOICE said 8). AI mechanics live in FLO/VOICE; only the *fitness-app
integration seam* lives here.

**Naming.** The chat tab is **Flo** (`MainTabView.Tab.coach`); the audible
mid-workout trigger voice is **Coach** (`WorkoutVoiceCoach`); the auto-generated
email is a **Flo Report**. One model picker, one history surface; the
`AssistantSubsystem` enum drives bubble badges and the voice self-announcement
("Flo here." / "Coach here.").

### Fitness-app integration seam (owned here, not in FLO)

The points where the generic AI module plugs into *this* app — documented in one
place, here:

- **Workout fact sheet (`AssistantContext.compactRender()`).** What the chat AI
  sees for each of the last 14 workouts: date · sport · duration · distance ·
  pace · avgHR · maxHR · TRIMP · hrTSS · decoupling % · METs · kcal · elevation,
  plus 7-day and 30-day rollups. `avgHR` falls back to averaging
  `workoutMetadata.samples.heartRate` when `HRVSession.meanHR` is nil (workout
  sessions skip the HRV pipeline that populates `meanHR`).
- **`AnalysisSummaryCache`** — written by `MorningResultsViewModel` and by
  `ContextBuilder` when it generates a summary the cache didn't have; entries are
  keyed by session and a fingerprint, so an edited session misses. Read by the
  context builder and `CitationQuickView`.
- **`AssistantInbox`** (reached as `dependencies.assistant.assistantInbox`) — `@MainActor @Observable` with
  `pendingDraft` / `openRequestToken`; drives the Dashboard ✨ "Ask Flo" menu and
  the History long-press "Ask Flo about this session" handoff into the chat tab.
- **`flowrecovery://session/<uuid>` citations** — date mentions in model replies
  auto-resolve to archive sessions via `AssistantCitationResolver`; tapping opens
  `CitationQuickView`.
- **Live-workout voice context** — `WorkoutAIContext.asFactSheet()` (distinct
  from the chat-side `compactRender()`) feeds the mid-workout **Coach** voice with
  GPS / road / heading / grade / weather / route-topology per tick. Full detail
  under [Fitness Tab — Workout Subsystem](#fitness-tab--workout-subsystem) and
  [Navigation & Location Subsystems](#navigation--location-subsystems-2026-04-29).

**Privacy (summary).** Apple Intelligence runs fully on-device (no network).
Cloud providers (Anthropic, OpenAI, Google, xAI, DeepSeek; the user's own key,
after a consent sheet) receive the chat, the tool results the model asks for,
and two blocks attached automatically:
- the user-facts block (`UserFactsStore.systemPromptBlock()`, the things the
  user asked Flo to remember) in every system prompt;
- the live-state block (`AssistantContext.renderLiveStateForCloud()`) on every
  cloud tool round: the latest session's recovery score and tier, RMSSD, SDNN,
  mean HR, overnight HR nadir and mean, sleep duration and efficiency, and its
  score note; yesterday's score, RMSSD and mean HR; and, during a live workout,
  the user's location.

Providers without tool support get a compact render of the whole context
(`compactRender()`) instead. The archive itself stays behind tools. API keys
live in the iOS Keychain, never in UserDefaults/JSON, never iCloud-synced.
Dictation is on-device (`requiresOnDeviceRecognition = true`); voice
conversation uses on-device recognition when the device supports it and
Apple's server recognition otherwise. Full treatment in
[`FLO_ARCHITECTURE.md`](FLO_ARCHITECTURE.md) and the [README Privacy section](../README.md#privacy).

---

## Navigation & Location Subsystems (2026-04-29)

Three services + one coordinator make up the location/navigation
stack. Each has a different accuracy / power / lifecycle profile —
multiple `CLLocationManager` instances per app is supported by Apple
and the underlying GPS hardware stream is shared (no extra battery
cost from "more managers"; cost is the highest accuracy any of them
requests).

### `WorkoutLocationManager`
`kCLLocationAccuracyBestForNavigation`, `location` background mode.
Active during a recording workout. Owns the `CLAltimeter` for
barometric elevation. **Lazy-initialised** on first access — the
recorder's `init()` no longer pays the 2–3 s `CLLocationManager` +
`CMAltimeter` setup cost synchronously on `@MainActor`. First access
is `start()` for GPS sports, by which point the user has explicitly
committed to a workout.

### `BreadcrumbRecorder`
`kCLLocationAccuracyNearestTenMeters` with a 10 m `distanceFilter`
(plus a 25 m / 30 s commit gate for the trail). Active while Get Me
Back mode is engaged (independent of workouts). Heading via
`startUpdatingHeading()` for the compass arrow. Atomic JSON write to
`Breadcrumbs/active.json` in the App Group container on every commit
— survives crash, kill, day rollover.

### `BreadcrumbStore`
File-backed persistence:
- `Breadcrumbs/active.json` — engaged trail (one at a time).
- `Breadcrumbs/archive.json` — newest-first list of completed trails
  (50-trail retention cap).

`archive(_:)` appends, evicting the oldest past the cap. `archiveActive()`
moves active → archive (the GetMeBackView "End and save" action).
`clear()` is the explicit-delete path (the "Discard" action +
sleep-prompt). One-shot migration from the v1 single-file layout
(`trail.json`) is automatic on first read.

**Auto-archiving of workouts.** `WorkoutRecorder.finalizeSession`
(when sport.usesGPS) calls `archiveWorkoutTrackAsBreadcrumbTrail`
which decimates the workout's track to 25 m / 30 s (matches the live
recorder's resolution) and appends it to the archive labelled "Run on
Apr 29, 8:13 AM". The AI's `directions.routeTo origin` finds these
automatically — user can route back to where they parked for any
recent workout without having engaged Get Me Back.

### `AmbientLocationService`
`kCLLocationAccuracyHundredMeters`, 50 m `distanceFilter`,
foreground-only. Started/stopped on `scenePhase` transitions. Pure
cache-keeper for the AI's location tools — when the user asks "where
am I", the tool reads `cachedLocation()` / `cachedResolvedAddress()`
instantly (no 30 s cold-fetch).

Both `WorkoutLocationManager` and `BreadcrumbRecorder` forward their
fixes to `AmbientLocationService.record(_:)` so the cache stays warm
during a backgrounded workout-with-screen-locked (the realistic
scenario the AI was failing in: phone locked, audiobook in earbuds,
workout running, voice query times out because the foreground-only
ambient service was stopped). The push is what makes the cache fresh
in those cases.

Thread-safe (NSLock-guarded `_latestLocation`); AI fact actions read
off the main actor.

### `RoadGeocodingService`
Two-stage lookup, throttled to 15 m / 60 s (whichever first). 15 m and not 25 m because at a
fast walk 25 m is ~10 s, and at a corner crossing the cached previous road still won a query
long enough to answer with the wrong street name.
Stage 1 — `CLGeocoder.reverseGeocodeLocation` for the road / locality
/ admin / country / countryCode. Published immediately so the AI
sees the road name without waiting on stage 2. Stage 2 —
`MKLocalSearch` for the **nearest cross street** in a 200 m
bounding box, filtered against the current road via a suffix-
stripping `normalizeStreetName` helper (so "Elm St" doesn't
match "Elm Street North"). Upgrades the cached `RoadContext`
with `nearestCrossStreet` + computed `nearestIntersection` =
"Elm St & 1st Ave".

Aggressive backoff after 8 consecutive failures → 30 s recovery
retry (so a temporary network glitch doesn't kill road context for
the whole workout).

### `ActiveRouteSession`
Continuous turn-by-turn for the AI's `directions.routeTo` tool.
Holds an `MKRoute` + sticky step index in memory. `currentStep(for:)`
walks forward from the sticky index (never back, so GPS jitter can't
bounce the user backwards through the route), returns the upcoming
instruction + distance to the next turn + total remaining + an
`arrived` flag (true within 25 m of destination).

Offline-once-engaged: the `MKDirections.calculate()` round-trip happens
once when `directions.routeTo` engages a route; subsequent
`directions.next_step` queries are <10 ms with no network.

### `AudioSessionCoordinator`
Single owner of `AVAudioSession.setCategory` calls. Five claimants
declare INTENT through it:
- `VoiceConversationController.claim(.voice, mode: .voiceRecord)`
- `SpeechInputManager.claim(.dictation, mode: .voiceRecord)`
- `WorkoutVoiceCoach.claim(.workoutCoach, mode: .playback)`
- `BreathingAudioManager.claim(.breathingGuide, mode: .playback)` (the only one that ducks other audio)
- `BackgroundAudioManager.claim(.backgroundKeepalive, mode: .playback)`

Coordinator picks the strict-superset category — when voice is
active, BGAM's claim is satisfied by voice's `.playAndRecord`
session (BGAM still owns its silent player; just doesn't touch the
category). When voice ends, BGAM (if still engaged) takes over the
session at `.playback`.

The bug this fixed: BGAM's 30-second health-check would re-call
`setCategory(.playback)` while a voice chat was running, killing the
mic recogniser. The coordinator's "skip if already-applied" rule
plus the strict-superset resolution makes that a no-op now.

`isVoiceActive()` is read by BGAM before deactivating the session in
its `stop()` — without that gate, BGAM stopping mid-voice-chat would
kill the mic.

---

## Dependency Injection

**One protocol, one container, and they do different jobs.**

`Sources/Protocols/` holds a single protocol — `HealthKitServiceProtocol` — and its purpose is
test isolation: it is what `MockHealthKitService` conforms to so the analysis and view-model
tests can run without a health store. Protocols for the BLE manager, the session repository and
the analysis pipeline were considered and are deliberately absent: nothing ever wired a mock
into them, so they would have been indirection with no consumer.

`AppDependencies` (`Emuqu/Sources/Utilities/AppDependencies.swift`) is the composition root, reached
as `AppDependencies.current.{app,storage,collection,analysis,location,services,providers,assistant}`.
It holds the concrete production objects; the app builds one and hands out sub-groups.

`RRCollector` additionally exposes a designated initializer taking all of its dependencies as
parameters (`BackgroundAudioManager`, `BackgroundLocationManager` (workout GPS only),
`SettingsManager`, `SessionArchive`, plus the
protocol-typed HealthKit service). `RRCollector.makeDefault()` is the production wiring and
also publishes the weak `RRCollector.current` the fact resolvers read; a `convenience init()`
wires in the shared singletons for tests and previews.

### RRCollector decomposition (sub-objects + SwiftUI observation)

The earlier "god object" `RRCollector` was decomposed into focused
`@MainActor` `@Observable` sub-objects:

- `ArchiveSignal` — publishes `archiveVersion` for views that re-fetch
  on archive mutation
- `DeviceStatus` — publishes connection / battery / firmware / strap
  identity for the Record tab and Connection panels
- `SessionState` — the live recording state machine
- `StreamingLifecycle` — BLE streaming start / stop / reconnect
  bookkeeping
- `MorningCoordination` — morning-window detection, score reveal
  state, organized-recovery selection

All live state moved into the sub-objects; the parent `RRCollector`
itself holds no observable state of its own. Views observe the sub-object
they need (`@Environment(DeviceStatus.self)`); under `@Observable`, nested
observation flows automatically, so the old "observe the child, not the
parent" pitfall no longer exists.

**Observation framework, everywhere (completed 2026-09-03).** Every
observable type in the app is `@Observable`; there are no `ObservableObject`
conformers, no `@Published` properties and no `objectWillChange` sends, and
the `.ci/legacy_observable_object_budget.txt` ratchet sits at zero. The
Combine bindings that used to watch `$property` publishers — the collector's
device-status proxies, the HealthKit version counters, the voice controller's
streaming observers, the workout recorder's strap and heart-rate
subscriptions — became self-re-arming observation loops built on
`withObservationTracking`; the helper is `ObservationLoop` in
`Emuqu/Sources/Utilities/ObservationLoop.swift`, and it delivers on the main actor after the
mutation, exactly where `.receive(on: .main)` did. Plumbing that must not be
tracked (timers, tasks, notification tokens, BLE characteristics, audio
engines) is marked `@ObservationIgnored`.

**Swift 6 language mode, `complete` strict concurrency.** Every build
configuration compiles in Swift 6 mode with warnings as errors, so an
isolation hazard is a compile error, not a diagnostic to budget. The patterns
that got the tree there, in the order you will meet them:

- *Main-actor stores with a nonisolated snapshot.* `SettingsManager`,
  `UserFactsStore` and `DebugLogger` are `@MainActor`; each mirrors the
  state that background code needs into an `OSAllocatedUnfairLock` and
  exposes it as a `nonisolated` read (`settingsSnapshot`, `factsSnapshot`,
  the pending log lines). Views observe the actor-isolated property; analysis,
  export and assistant code read the snapshot. The `shared` instances are
  `nonisolated static let` with `nonisolated` initialisers so the composition
  root can hand them out from any isolation.
- *Analysis types are `Sendable`.* `HRVAnalysisPipeline`, `WindowSelector`,
  `ArtifactDetector`, `SleepBoundaryResolver` and the fact-resolver registry
  are immutable after construction; the two side channels that were not
  (the selector's organized zones, the registry's per-turn call counts) sit
  behind locks. Fact-catalog closures are `@Sendable`, so a namespace can be
  resolved from any task.
- *SDK objects that are thread-safe but undeclared.* The Polar SDK object is
  wrapped once in `StrapAPI` (`@unchecked Sendable`, the file is allowlisted)
  and the SDK's entry values never cross isolation: list-then-remove and
  list-then-fetch run as single `nonisolated` steps and return plain values.
- *Payloads across framework callbacks.* WatchConnectivity dictionaries cross
  to the main actor as property-list `Data`; audio-session notifications cross
  as the primitive values the handler needs; a CoreMotion result is reduced to
  a `Sendable` struct inside the callback. The overnight-chart statistics are
  computed by `OvernightStatsComputer`, a `Sendable` value that a detached task
  can own without capturing the view.
- *The theme palette is main-actor.* The members of `AppTheme` that read user
  settings are `@MainActor`, and so is every helper that builds a `Color` from
  them, which is what the compiler needs to prove no palette read races a
  settings write.

The remaining `@unchecked Sendable` / `nonisolated(unsafe)` annotations are
listed by file in `scripts/check_unchecked_sendable.sh`; each names the queue
or lock that owns its state.

### Extraction pattern for oversized types (2026-08-31)

`check_aggregate_type_size.sh` measures every type against a line threshold it
defines. Two ratchets bound the result: `.ci/aggregate_type_size_budget.txt`
caps how many types are over it, and `.ci/aggregate_type_excess_budget.txt`
caps the total overshoot. Both only ever ratchet down. The cuts that reduce
them follow one pattern:

1. **Pick the seam by ratio, not size.** What decides a good extraction is how
   many members of the parent the candidate files still need, not how many
   lines they are. `VitalsHealthQueries` was 486 lines needing six members;
   `WorkoutRecorder+Context` is 638 lines needing thirty-seven, and stays where
   it is — cutting it would move coupling around rather than remove it.
2. **Extracted helpers are values that hold the parent strongly.** The parent
   builds the helper on demand (`collector.recovery`, `generator.deepDive`) and
   does not retain it, so there is no cycle and nothing that can outlive its
   owner. They were `unowned` back-pointers until 2026-09-03, when two of them
   trapped from resumed continuations; `unowned` is now banned by
   `scripts/check_no_unowned.sh` (ADR 005). Value-type parents take the values
   they need instead: `ThresholdCards` holds the session. All-static namespaces
   need no reference at all (`VitalsScoring`, `ReadinessScoring`,
   `ScoreDetailBuilder`).
3. **Do not change what callers see.** Every extraction ships a
   `+…Forwarding.swift` extension that keeps the original API on the parent, and
   re-exports moved nested types with a typealias. SwiftUI extractions forward
   through a plain value type rather than a new `View`, so view identity — and
   therefore animation and `@State` behaviour — is unchanged.
4. **Lazy-build the sub-object.** A `.summary` PDF never draws deep-dive pages
   and never allocates that renderer.

The extracted files keep the parent's history in a header comment naming what
was cut, when, and why that seam and not another.

---

## Home-screen Widget — REMOVED (2026-07-03)

**The `EmuquWidget` extension was removed entirely on 2026-07-03.** It was
dead: the target had zero references in `Emuqu.xcodeproj/project.pbxproj`,
and its `SharedDefaults` reader was defined only inside the widget directory. The
whole `EmuquWidget/` directory (its widget entry point, its `SharedDefaults`
reader, README, privacy manifest, Info.plist and entitlements) was `git rm`'d,
and the dead Live Activity was dropped earlier
(commit `8db4540`). There is no widget, no Lock-Screen accessory, and no Live
Activity.

**Writer plumbing removed (2026-08-27).** For seven weeks after the extension
was deleted, the *writer* kept running: `WidgetDataPublisher` published today's
score, verdict, three-day trend and session count into the App Group
`UserDefaults` on every dashboard refresh, and called
`WidgetCenter.reloadAllTimelines()`, for a reader that no longer existed. That
is not merely dead code in a health app — it is health-derived data written to a
shared container on a hot path with no consumer, which data minimisation says
should not happen. The publisher, its call sites in `DashboardV2View`, and its
tests are gone.

`DataPurgeService` still erases the `widget.*` keys, deliberately. A user who
ran an earlier build still has those values on disk; deleting the writer does
not delete their data. The key list moved into the purge service, where it now
describes what must be cleaned up rather than what is being produced. Remove it
only once no supported upgrade path can still carry those keys.

The App Group entitlement stays — the archive, raw-RR backups, conversation
store, user facts and unit preferences all live in that container.

---

## Apple Watch app

The Watch companion (`EmuquWatch Watch App/`) was **re-embedded into the
iOS build on 2026-07-03** after a stretch where it was orphaned from the build
(the iOS target's "Embed Watch Content" phase had been removed to unblock iOS
builds, so the Watch app never installed on the wrist — the reason it "never
worked"). The iOS app now depends on and embeds the `Watch App` target directly.
The legacy `watchapp2-container` target, unused since then, was removed from
the project on 2026-09-29. See `project.pbxproj` (the iOS app
target's build phases) and `docs/FLOWCHART.md` for the workout wiring.

**Design: phone-mirror + wrist controls.** The iPhone owns the Polar strap and
the canonical workout record; the Watch mirrors live HR/stats relayed over
`WatchConnectivity` (`WatchConnectivityBridge.swift` on the phone,
`WatchSessionManager.swift` on the wrist) and offers start/stop/pause controls.
Files: `WatchApp.swift` (entry), `WatchLiveView.swift` (UI),
`WatchWorkoutManager.swift` (HKWorkoutSession keep-alive),
`WatchStrapConnector.swift` (direct CoreBluetooth HR client, retained for the
opt-in wrist-strap path). A second-wall punch-list of mirror-mode wiring fixes
(reachability gating, strap-state push, duplicate listeners) is pending on-device
verification.

---

## Background Execution

- Silent audio (volume 0.0) keeps app alive during overnight streaming
- Screen locks normally — no idle timer override
- Overnight keep-alive: silent audio + `bluetooth-central` wakeups (incoming Polar BLE data). `BackgroundLocationManager` is used ONLY during workout recording (`.workoutRecording` reason — real GPS track). A 2026-05 change had also activated it overnight as a pure keep-alive; removed 2026-06-10 (App Store 2.5.4 — background location must serve a user-visible location feature, and overnight HRV has none).
- Audio interruptions handled gracefully
- Keep-alive ping every 30 seconds

---

## Known Limitations

- **Per-Device Window Config**: Different device types may need different window parameters (H10 internal vs streaming-only). Not yet implemented.
- **Baseline Not Synced Across Devices**: 7-day baseline assumes same device. Switching devices invalidates baseline.
- **No Seasonal Adjustment**: HRV naturally varies with seasons; not accounted for.
- **No Training Periodization**: Training load tracked but no periodization planning.
- **TRIMPi (Manzi) Not Implemented**: Requires individual blood-lactate testing that users don't have. Banister is our accepted fallback; α1-derived LT1 estimate surfaces in the post-summary so users can field-calibrate LTHR without lab access.
- **Sex Binary in Banister k**: Banister 1991's sex-split coefficients (k = 1.92 male / 1.67 female) are the accepted defaults in the literature but don't handle non-binary / unspecified users gracefully — we fall back to male constants, noted in code.
- **Polar battery — no force-read API**: Polar's BLE SDK reports battery opportunistically and the value can stall for days while the strap is fine. We supplement the manufacturer signal with a recording-hours counter (`PolarManager.hoursRecordedSinceBatteryChanged`) against published spec capacity (H10 = 400 h, Verity Sense = 30 h). UI surfaces both numbers — "Reported 100 %, recorded 38 h since last full charge" — instead of the misleading "stale" warning that used to appear after 6 days of unchanged readings.
- **Multi-sport / triathlon transitions not supported**: Recorder owns one sport per session today; brick / triathlon transition support is intentionally held until there's user demand.
- **Custom interval editor not built**: Voice coach announces steps from a chosen `IntervalPlan`, but there's no in-app editor yet — pre-built plans only.
- **Road construction / closures**: Free APIs (Mapbox / HERE Traffic) charge per request; OSM construction data is sparse. Live coaching only sees terrain (climbs, grade, peak altitude) and weather, not roadway events.

---

## Fitness Tab — Workout Subsystem

Recording architecture is in `Emuqu/Sources/Collection/WorkoutRecorder.swift`.
Post-summary and the epic α1 report live in
`Emuqu/Sources/Views/FitnessTabView.swift` and
`Alpha1ReportCards+Report.swift`. Analysis math lives in
`Emuqu/Sources/Analysis/WorkoutAnalyzer.swift` and
`LiveDFAAnalyzer.swift`.

### Subsystems

- **WorkoutRecorder** — MainActor orchestrator. Owns a single live
  session, publishes per-tick state, drives the ticker, coordinates
  Polar RR + GPS + pedometer + foot-pod + Watch.
- **WorkoutLocationManager** — CoreLocation wrapper. Drives elevation
  gain/loss via `CMAltimeter.relativeAltitude` (barometric, ±0.5 m)
  rather than GPS altitude (±5-10 m noise). GPS altitude is a
  fallback path for devices without a barometer (pre-iPhone-6).
- **LiveDFAAnalyzer** — rolling 2-min window α1 computation every 20 s.
  Runs a Kubios-style artifact filter (`cleanRRForDFA`, ±20 %
  ectopic threshold with linear interpolation) before DFA — without
  it, raw Polar RR artifacts inflated α1 toward Brownian (1.5-2.0)
  during exercise. Emits `Status` enum so UI and AI both know *why*
  α1 is missing (warmup / stalled / fit-failed / ok) rather than
  silently hiding.
- **WorkoutAnalyzer** — pure transforms. Banister TRIMP, HRSS-style
  hrTSS, splits, decoupling, efficiency factor, polyline encoding.
- **WorkoutAlpha1Reanalyzer** — retroactive α1 regeneration for
  archived sessions. Replays the live pipeline (2-min rolling, 20-s
  cadence) using the current artifact filter against a session's
  stored RR data, replacing contaminated α1 values. One-tap action
  in the summary sheet; runs on a background Task.
- **TopoElevationService** — real terrain elevation via DEM lookup
  for sessions without barometer data. OpenTopoData USGS NED 10 m
  for US coordinates, then SRTM 30 m, and nothing else. Applies a 15 m
  sustained-climb threshold for GPS-only sessions — calibrated against
  barometric ground truth, where 10 m overcounted by ~25 %.
  Used by the Fitness summary's "Look up real elevation" action for
  retroactive repair. Fails loudly rather than silently falling back
  to GPS-noise math.
- **HRRCaptureService** — three-tier fallback: strap, Watch HR samples,
  HealthKit-computed HRR. Runs in a detached task after stop(). Strap
  streaming is kept alive through the 120 s capture window, then
  closed — previously we closed it early and Tier 1 always failed.
- **LiveWorkoutBroker** — thread-safe snapshot publisher feeding the
  AI assistant and voice coach with wall-clock time, GPS, heading,
  grade, units, α1 status. Snapshots > 12 s old treated as nil so
  post-stop state can't mislead the AI.
- **WorkoutAIContext / WorkoutTriggerEngine / WorkoutVoiceCoach** —
  the live coach rule engine. Engine is a pure evaluator; coach
  handles TTS + haptics + conversation pre-emption. Context now
  carries `routeTopology` (full climbs queue + peak altitude + total
  ascent remaining + steepest grade ahead), `weather` (MET Norway
  current conditions), `activeThresholds` + `thresholdBreachSec`
  (user-declared physiological constraints with per-threshold
  debounce / cooldown), plus `recognized_route` direction so the
  coach can speak about "Daily 1 in reverse."
- **RouteLibrary + SavedRoute / SavedRouteStore** — user-curated
  named-route library. After any GPS workout the post-summary
  surfaces "Add to my route library"; the polyline + climbs +
  cumulative distances are cached into a JSON file in the App Group
  container (`saved_routes.json`; an older Application Support copy is
  migrated on first run). On the next workout
  `RouteLibrary.findMatch(currentTrack:sport:)` runs after ~500 m
  of fresh GPS, tries each saved route in BOTH directions
  (forward + whole-route-reversed; the reversed case rebuilds the
  `Route` from reversed trackpoints so the climb queue reflects the
  climbs the user will actually hit), accepts at ≤ 30 m mean
  nearest-neighbour distance, best fit wins. The bound `Route`
  drives `routeTopology` in the AI context every tick.
- **WeatherService** — MET Norway Locationforecast 2.0 compact
  (CC BY 4.0, credited in the app) current-conditions fetcher. Sends
  the identifying User-Agent MET Norway requires and coordinates
  rounded to ~1 km; waits at least 10 minutes between requests and
  honours `Expires`, sending `If-Modified-Since` on repeats. 30-minute
  cache TTL with re-fetch on >5 km movement. Fetched off-main; failures
  are logged and the AI gets `weather = nil` once the snapshot ages out
  rather than a guess. MET symbol code → conditions string mapping;
  no apparent temperature (nil).
- **RoadGeocodingService** — Apple `CLGeocoder.reverseGeocodeLocation`
  wrapper. Turns the user's GPS into street name (`thoroughfare`),
  locality, administrative area, country + ISO code. Rate-limit-aware:
  re-geocodes only on >15 m movement OR >60 s elapsed (catches
  "turned a corner without moving the threshold"). Backs off after
  8 consecutive failures, then retries every 30 s. Free, on-device where possible, no API key.
  Used both per-tick during the workout (current road context) AND
  one-shot per climb at SavedRoute save time so the AI can say "the
  climb on Hill Rd in 0.4 miles" instead of "a climb ahead."
  The per-climb pass is paced at 600ms between requests to stay
  under CLGeocoder's ~50 reqs/min device-wide ceiling.
- **TrailDiscoveryService** — OpenStreetMap Overpass API client for
  hiking / mountain biking / road cycling trail discovery from the
  Fitness tab. POSTs Overpass QL queries with sport-specific tag
  selectors (`route=hiking` / `route=mtb` / `route=bicycle` relations
  + named `highway=path|footway|cycleway` ways), parses the JSON
  envelope (resolves nodes → ways → relations to build coordinate
  arrays), bias toward `[name]`-tagged ways to filter out random
  paths. Difficulty buckets collapse `sac_scale` (T1–T6) and
  `mtb:scale` (0–6) into Easy/Moderate/Hard/Expert. Free, no API
  key, global. Same MainActor-deadlock-avoidance pattern as
  WebSearchService (NOT @MainActor — async work runs off-MainActor).
- **WebSearchService** — Optional Tavily-backed search for the AI
  assistant. Off by default; user opts in via Settings → Flo
  + a free Tavily key. Three curated domain whitelists baked in
  (research authorities, manufacturer docs, always-excluded farms).
  Same MainActor-deadlock-avoidance pattern (NOT @MainActor) — the
  resolver bridges sync→async via Task.detached + DispatchSemaphore
  so the URLSession await runs off-MainActor and can't deadlock the
  view-model loop. System-prompt overlay enforces "never synthesise
  medical-protocol recommendations from search content; always cite
  source URLs in Markdown."
- **Concept2Manager** — BLE central for the PM5 Rowing service
  (`0x0030`). Subscribes to characteristics `0x0031` (general
  status: distance, drag factor), `0x0032` (additional status: stroke
  rate, pace) and `0x0036` (additional stroke data: stroke power,
  stroke count; power outside 1–1500 W is dropped). Adds `Sport.row` and rowing-specific
  metrics (`strokeCount`, `dragFactor`, `averageSplitSecPer500m`)
  to `WorkoutMetadata`.
- **FootPodManager (FTMS extension)** — alongside the existing
  Stryd RSC (`0x1814`) subscription, the manager now also subscribes
  to FTMS service (`0x1826`) and the Indoor Bike Data characteristic
  (`0x2AD2`). `parseIndoorBikeData()` walks the bit-flagged FTMS
  payload (instant cadence, power, total distance, resistance) so
  Wahoo Kickr / Tacx / Saris bike trainers feed power into the same
  pipeline as Stryd.
- **ZwiftPeripheralBroadcaster** — `CBPeripheralManager` that
  advertises Heart Rate Service (`0x180D`) and Cycling Power Service
  (`0x1818`). When `Settings.enableZwiftBroadcast` is on,
  `WorkoutRecorder` calls `update(heartRate:powerWatts:)` per tick
  so Zwift / TrainerRoad / Rouvy / Wahoo SYSTM see Emuqu as
  a sensor. Required `bluetooth-peripheral` UIBackgroundMode in
  `Info.plist`.
- **WorkoutThreshold (model)** — user-declared physiological
  constraints (HR / HR-zone / power / power-%FTP / pace / α1 /
  cadence) with `condition` (gt / lt), `value`, `debounceSec`
  (default 30), `cooldownSec` (default 120), and optional `userCue`.
  `evaluate(...)` returns `Bool?` (`nil` = metric unavailable, so
  the breach state machine can distinguish "not breached" from
  "no signal"). The coach claims plain `.playback` with
  `.mixWithOthers` (no ducking), so the user's audiobook keeps
  playing; it only speaks when a breach exceeds debounce.
- **WorkoutPDFReport** — on-demand 6–7-page clinical visual PDF
  generator (full page-by-page breakdown in the "Workout report"
  section above): executive summary, autonomic/HRV with the α1
  centerpiece (drawn in CoreGraphics), cardiopulmonary, effort &
  terrain with an MKMapSnapshotter route α1-band-coloured (GPS-only,
  so 6 pages without GPS), splits + derived metrics, a plain-language
  "What This Means" page, and a methodology/citations appendix. All
  series downsampled to ≤ 400 points before drawing (9× faster,
  visually identical).

### Training load math (research-backed)

- **TRIMP — Banister 1991**: `TRIMP = Σ dur_min × HRR × A × e^(k·HRR)`.
  Male: `A=0.64, k=1.92`. Female: `A=0.86, k=1.67`. Sex is taken from
  `settings.biologicalSex` and the male coefficients are NOT used as
  a default for female users (a long-standing bug fixed 2026-04-23 —
  female TRIMP / hrTSS / CTL / ATL / TSB had been ~30 % off).
  HRR = (HR − HRrest) / (HRmax − HRrest). Continuous integration;
  accepted across endurance sports. Source: https://fellrnr.com/wiki/TRIMP
- **hrTSS — HRSS formulation**: session TRIMP / 1-hour-at-LTHR TRIMP × 100.
  Intervals.icu uses equivalent derivation. Returns nil if any anchor
  (HRmax, HRrest, LTHR) is missing.
- **Power-TSS — Coggan / TrainingPeaks**: `(NP / FTP)² × hours × 100`.
  NP is the 4-second rolling average → mean of the 4th power → 4th
  root. IF (Intensity Factor) = NP / FTP. Variability Index = NP / avg
  power. Computed at session finalize when both a power source (Stryd
  RSC / FTMS / PM5 / CPS) and the matching FTP (`runningFTPWatts` or
  `cyclingFTPWatts` in `UserSettings`) are present. Returns nil
  otherwise — no fabricated denominators.
- **LTHR**: user override → `0.88 × effectiveMaxHR` (Friel 85-90 % band
  midpoint). Users who've done Friel's 30-min TT field test can enter
  the real value in Settings → Biometrics.
- **Resting HR**: user override → `baselineHR` (HRV-derived) → 60 fallback.
- **CTL / ATL / TSB fetch window** (`TrainingHealthQueries+Queries`): 180-day
  history (matches the 6-week EWMA tail), startDate anchored to start-of-day,
  seed-from-zero (the previous seed-from-average back-filled fictional
  load on first install). Sub-1-minute "ghost" workouts (Watch
  auto-detects from a 30-second walk) are dropped before TRIMP runs.

### α1-derived LT1 estimate

A validated output, not a calculated input. After each session with a
clean downward α1 crossing of 0.75, the post-summary surfaces the HR
at that crossing as an aerobic-threshold estimate. Source:

- Rogers & Gronwald 2021 (PMC7845545) — HRVT vs gas-exchange VT1 within ~2 bpm on average in 15 men (ICC 0.96 for HR; limits −12 to +8 bpm)
- Schaffarczyk 2022 (PMC9894976), Van Hooren 2023 (PMID 37916488), Sempere-Ruiz 2024 (10.3389/fphys.2024.1329360) — later cohorts agree less tightly: roughly ±10 bpm for an individual, none once fatigued

**LT1 is not LTHR, and the app no longer suggests otherwise.**

The card used to compare the estimated LT1 against the configured LTHR and
invite the user to replace it. That is a
user-facing correctness defect, and it was removed.

They are different anchors. LT1 is the first (aerobic) threshold, which DFA α1
near 0.75 is studied as a proxy for. The app's LTHR setting is described by
Friel's time-trial protocol — a substantially harder effort — and is the
one-hour reference `WorkoutAnalyzer` divides by to compute hrTSS. LT1 sits
materially below LTHR, so a user who took the advice shrank the hrTSS
denominator and inflated every subsequent training-load figure.

The estimate is still displayed, labelled as the aerobic threshold. It does
not populate, and does not recommend populating, any threshold used for load
calculation. TRIMP and hrTSS remain untouched by α1.

The cited studies validate the α1 method against laboratory LT1 in their own
cohorts. That is not the same as validating this implementation's estimate for
an arbitrary user on consumer hardware, and this section should not be read as
claiming it.

### Elevation: barometric signal processing, never raw-GPS-smoothed

Emuqu's elevation pipeline is implemented per the
sports-biomechanics sensor-fusion literature (Barczyk & Nemra 2014,
PMC4179067). The guiding principle: raw GPS altitude is too noisy
to extract signal from, regardless of smoother tuning. The right
approach is to read the iPhone's barometric pressure sensor and
process that signal correctly.

#### Live recording pipeline

1. **Collect every `CMAltimeter.relativeAltitude` sample** (1 Hz
   native rate) into a session-scoped buffer on
   [`WorkoutLocationManager`](../Emuqu/Sources/Collection/WorkoutLocationManager.swift).
   No threshold gating at collect time — the raw signal is preserved
   so the final algorithm can be upgraded without re-recording.
2. A light threshold-gated accumulator runs alongside for the **live
   ticker display only**. The ticker's number is explicitly
   advisory; the persisted value comes from the post-hoc processor.
3. At `WorkoutRecorder.finalizeSession()`, the buffered samples pass
   through [`BarometricAltitudeProcessor`](../Emuqu/Sources/Analysis/BarometricAltitudeProcessor.swift):
   - **Symmetric moving-average smoother** over 15 samples (~15 s).
     Approximates the ≈ 8 s complementary-filter time constant
     Barczyk & Nemra recommend for human motion tracking. Offline
     application → zero phase lag.
   - **Sustained-run accumulator, 2 m threshold.** Same-sign deltas
     accumulate into a running sum; the run commits to gain or loss only
     when the direction reverses AND its magnitude clears 2 m. A per-delta
     noise gate was tried first at 1 m and abandoned: HVAC, a passing
     truck, weather fronts and the smoother's own edge artifacts each
     produce isolated deltas above 1 m, and each added 1–3 m of fake
     gain — measured at ~2.3× overcount on a real 117 m walk. The run
     rule rejects those (they reverse before the run clears 2 m) while
     still counting a slow climb, whose per-sample deltas never clear
     any threshold at all.
   - Returns `(gainMeters, lossMeters, smoothedSampleCount)`.
4. The processed result is written to
   `WorkoutMetadata.elevationGainMeters` / `elevationLossMeters`.

#### Retroactive (pre-barometer-fix sessions)

Sessions recorded before the buffer existed have no barometric
samples to post-process. They fall back to
[`TopoElevationService`](../Emuqu/Sources/Analysis/TopoElevationService.swift)
— DEM lookup via OpenTopoData (USGS NED 10 m for US, SRTM 30 m
elsewhere). Applies a 15 m sustained-climb threshold empirically
calibrated against barometric ground truth in rolling neighbourhood
terrain. Always an approximation vs the live barometer.

#### No-barometer devices (rare — pre-iPhone 6)

GPS-altitude accumulator with a 5 m noise gate runs internally as a
last resort. Clearly labelled as an estimate in the UI.

#### Why never "smooth GPS altitude"

GPS vertical accuracy is ±5–10 m per fix. Over a 60-min walk with
500+ fixes this integrates to either massive overcount (tight
threshold) or undercount (loose threshold) no matter how you tune
it. The noise isn't signal to be extracted — you need a different
sensor. That's what the barometer is for.

### Data quality filters (cadence, tail-spikes)

- **Cadence**: sport-aware physiological cap (walks 125 spm, runs
  220, bikes 140 RPM). Plus a trailing-15-sample tail-spike check
  (1.5× baseline median) to catch foot-pod noise at stop time.
- **Charts**: X-domain clamped to the session's actual duration /
  distance so chart ticks never extend past the data into dead
  space on the right.

### Why not Lucia / Edwards / Stagno / TRIMPi

- **Edwards (1993)**: kept as fallback only. Arbitrary zone boundaries,
  zone-jump artifacts, ignores resting HR.
- **Lucia (2003)**: published but "no training study has been conducted
  to validate it by demonstrating dose-response relationships" (Fellrnr
  review).
- **Stagno (2007)**: validated for team sports (r = 0.8 vs ΔVO2max),
  but uses group-average zone weights — no advantage over Banister for
  endurance.
- **Manzi TRIMPi (2009)**: most predictive of race performance
  (r = 0.77-0.87) but requires individual blood-lactate testing in a
  lab. Out of reach for app users.
