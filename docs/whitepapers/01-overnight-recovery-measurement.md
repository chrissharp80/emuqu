# Emuqu — Overnight Recovery Measurement from Raw Beat Intervals

**Sleep-anchored, score-ranked window selection, anti-ratchet baselines and frozen, versioned scores**

Technical White Paper • v1.3 • 8 October 2026

Chris Sharp • github.com/chrissharp80

Describes Emuqu (formerly Flow HRV, then Flow Recovery) at source revision e028039 (2026-10-07), scoring version v3.1.oct2026. Emuqu is a consumer wellness app, not a medical device.

Cite as: Sharp C. Emuqu — Overnight Recovery Measurement from Raw Beat Intervals. Technical White Paper v1.3, 8 October 2026. github.com/chrissharp80/emuqu, docs/whitepapers/01-overnight-recovery-measurement.md.

---

## Executive Summary

Emuqu is an iOS app that records a night of beat-to-beat (RR) intervals from a chest strap and turns them into one morning number, the recovery score. The statistics it reports are standard: the root mean square of successive differences (RMSSD), its natural log, a rolling personal baseline, z-scores and the short-term scaling exponent of detrended fluctuation analysis (DFA α1). This paper's contribution is the measurement method between the raw beats and that arithmetic: it decides which few minutes of an 8-hour night to measure, keeps an atypical night from moving the baseline, assembles one clean series from two imperfect sources, and keeps a score shown at 07:00 the same at 19:00, attributable to the algorithm that produced it.

The method has six parts, each specified precisely enough to re-implement:

1. **Source assembly.** The strap's internal recording is preferred. Bluetooth-streamed beats fill only its own gaps, matched on the phone's arrival clock and de-duplicated within 50 ms. An undated strap file is dated by aligning an RR-detected sleep onset with the HealthKit sleep start.
2. **Sleep-anchored window search.** The analysis window is searched only within 30–70% of *measured sleep*, not of the recording, after the sleep boundaries are mapped from wall-clock time onto the beat timeline, which stalls during Bluetooth dropouts.
3. **Score-ranked window selection.** When a baseline exists, windows that pass the artifact, clean-beat and stability gates are ranked by the heart-rate-variability (HRV) sub-score function that produces the final score (less its autonomic-balance term), against the same prior-nights baseline.
4. **Anti-ratchet baseline.** Admission uses a structural test that ignores whether a reading is above or below the mean, so short high readings cannot ratchet the baseline upward; the one direction-dependent exclusion is a below-baseline session shorter than 3 h. Each night has one slot, keyed by wake date, and is scored only against earlier nights.
5. **Frozen, versioned scores.** At acceptance the score, its breakdown and its inputs are frozen and stamped with a scoring-version string; records without one are labeled `unversioned`.
6. **RR-only sleep staging** by within-night rank normalization, with a conservative Apple Watch augmentation that overrides Watch stages only on strong evidence.

Section 8 dates each method, from the project's origin in February 2025 and the full-night problem statement of December 2025 to the source revision described here. Section 6 summarizes verification: the time-domain arithmetic is checked on every build against 20 PhysioNet records, and on the MIT-BIH Arrhythmia Database the artifact pipeline brings the median absolute error of 5-min RMSSD to 4.7 ms where uncorrected ectopic beats inflate it by a median of 32 ms.

---

## 1. The Problem

### 1.1 What an overnight RMSSD is supposed to be

The literature on heart-rate-variability (HRV)-guided training uses a resting, vagally mediated index, usually the natural log of the root mean square of successive differences, ln(RMSSD), measured under repeatable conditions. Each day's value is compared with a rolling personal baseline, and a change is called meaningful only beyond a smallest worthwhile change (SWC) of about 0.5 SD [1][2][3]. RMSSD itself is defined over successive differences between *adjacent* normal-to-normal (NN) beat-to-beat (RR) intervals [4].

Morning spot readings get repeatability from protocol (same time, same posture, same duration). An overnight recording has no protocol. It contains wake, light sleep, deep sleep, rapid-eye-movement (REM) sleep, arousals, position changes, strap shifts and, for a Bluetooth stream, dropouts. "The night's RMSSD" is not one number. It depends on which part of the night is measured. The overnight problem is to supply, by rule, the repeatability that a morning protocol supplies by instruction.

### 1.2 Sources of error

**Table 1.1.** Sources of error in an overnight RMSSD.

| Source | Effect on the reported value |
|---|---|
| Whole-night averaging | Mixes wake and REM (lower RMSSD) with deep non-REM (NREM) sleep (higher). The value tracks sleep architecture as much as recovery. |
| Fixed clock window (e.g. "first 4 h", "02:00–03:00") | Lands at a different sleep phase each night when bedtime or sleep onset varies. |
| Window chosen relative to the *recording* | Pre-sleep wake time and early removal shift the window. A recording started 90 min before sleep places "30%" in early-night wake. |
| Bluetooth dropouts | The beat-sum timeline (cumulative RR) stops advancing while wall time continues. Wall-clock sleep boundaries compared directly with beat-sum time land on the wrong beats. |
| Ectopic beats and missed detections | One compensatory pause can add tens of ms to RMSSD. On MIT-BIH recordings, uncorrected ectopic beats inflated 5-min RMSSD by a median of 32 ms (Section 6). |
| Artifact removal by array collapse | Dropping a bad beat and differencing the shortened array creates one spurious large difference per removed beat [4]. |
| Short windows | Short windows have the largest sampling error, so their high readings overshoot most. A rule that keeps them only when they are high biases the baseline upward. |
| Scoring a night against a baseline that contains it | Pulls the z-score toward 0. Kiviniemi et al. compare a day with *earlier* measurements [5]. |
| Late-arriving sleep data | Apple Watch sleep often reaches HealthKit after the morning score is computed. Without rules, the score silently changes later, or never benefits from the better data. |
| Algorithm changes | Re-tuning a scoring rule rewrites history unless scores carry a version. |

### 1.3 What existing work provides, and what this paper adds

The published methods define the statistics (Task Force [4]; ln(RMSSD) and SWC [1][2]; detrended fluctuation analysis (DFA) [6]), the artifact detectors (Kubios-style median-deviation classification [7][8]) and the general idea of HRV sleep staging [9][10][11]. This paper builds on them and adds the operational rules they leave open: how to choose an analysis window from an unattended overnight recording, how to keep window choice consistent with the downstream score, how to protect a rolling baseline from selection bias, and how to keep a score immutable and attributable across devices and late data.

Commercial products describe nocturnal windows and personal baselines only at summary level (Section 4). This paper adds reproducible rules for window choice within a night, baseline admission and score versioning.

---

## 2. Architecture Overview

**Table 2.1.** Processing phases.

| Phase | Operation | Purpose |
|---|---|---|
| A. Capture | Stream RR over Bluetooth; strap records internally in parallel; append-only JSON Lines (JSONL) backup every 60 s | No single failure loses the night |
| B. Source selection | Prefer internal recording; gap-only composite with stream; date undated files | One continuous, correctly dated series |
| C. Segment merge | Time-shift resumed segments onto the parent's timeline and concatenate | One window search across a paused night |
| D. Artifact flags | Whole-series rolling-median classifier | Mark technical, extra, missed and ectopic beats |
| E. Sleep boundaries | HealthKit → RR heart-rate (HR) estimate → Watch passive-HR estimate → recording bounds | Anchor the search to sleep, not to the recording |
| F. Band mapping | Wall-clock boundaries → beat-sum timeline; 30–70% band → index range | Correct beats despite dropouts |
| G. Window scan | Adaptive window, two-pass artifact cap, local ectopic gate, masked RMSSD, DFA α1 | Candidate windows with break-aware, artifact-masked metrics |
| H. Window selection | Spike filter → organized filter → rank by HRV sub-score vs prior-nights baseline | Window agrees with the score |
| I. Analysis | Time, frequency and nonlinear metrics on the chosen window | Reported values |
| J. Scoring | Tier 1/2/3 composite, adjustments, penalties | 0–100 recovery score |
| K. Freeze | Snapshot sleep/vitals, quality decision, compute, stamp version, archive | Stable, attributable score |
| L. Baseline update | Structural admission, one slot per night | Unbiased reference for later nights |
| M. Later events | Bounded automatic rescore; fill-only merges; user edits win | Late data used without silent drift |

```
strap memory ─┐
              ├─► B source ─► C merge ─► D flags ─┐
Bluetooth ────┘                                   ├─► F map band ─► G scan
HealthKit sleep ─► E boundaries ──────────────────┘                 │
                                                                    ▼
prior-nights baseline ──┬─────────────────────────────────────────► H select
(leave-current-out)     │                                           │
                        │                                           ▼
                        └────────────────────► J score ◄─────────── I analyze
                                               │
                                               ▼
                                           K freeze ─► L update baseline
```

**Figure 2.1.** Data flow from capture to baseline update. The prior-nights baseline feeds both window selection (H) and scoring (J).

Three principles run through the design. *Every beat-to-beat difference is real:* time-domain statistics use no interpolated beats, and no difference spans a removed beat or a recording break. (Spectral features use the standard resampled series.) *One rule, used everywhere:* the estimator that selects a window is the one that reports it, and the function that ranks windows is the one that scores the night. *A score is a record:* once accepted, it changes only through stated, bounded rules, and it carries the version of the algorithm that produced it.

---

## 3. Methods

Notation: each beat is `RRPoint{t_ms, rr_ms, wallClockMs?, hr?}`. `t_ms` is the beat's time on the recording's beat-sum timeline (cumulative RR). `endMs = t_ms + rr_ms`. `wallClockMs` is the phone's arrival time relative to session start, present on streamed beats only. A valid RR is `300 ≤ rr_ms ≤ 2000`. Constants are collected in Appendix A, pseudocode in Appendix B and source files in Appendix C.

### 3.1 Capture and source selection

#### 3.1.1 Parallel capture and backup

During an overnight session the app streams RR over Bluetooth and, where the strap supports it (Polar H10), arms the strap's internal recording. Streamed beats are written to an append-only JSONL file: a header line at first write, then one JSON object per beat, one per line. Only beats beyond the stored count are appended. A flush is due when at least 60 s have passed since the last one, and it is forced on reconnect and lifecycle events. Files use a protection class that stays writable while the phone is locked. A failed append throws, and the beats remain buffered for the next interval.

#### 3.1.2 Strap rescue before clear

Starting a strap recording requires clearing its memory, which is destructive. The start sequence is fixed as `[rescueExisting, clearExisting, beginRecording]`. The rescue step downloads any stored recording that a download ledger says the app does not already hold and hands it to the backup. If that download fails, the start is aborted instead of clearing. A test asserts the invariant "rescue precedes clear" for every strap type.

#### 3.1.3 Source selection

Inputs are the streamed points `S` and the internal points `I` (possibly absent).

1. A source is *valid* if it has ≥ 120 beats.
2. If `I` is invalid: use `S` if valid ("streaming (internal failed)"), else fail.
3. If `I` is valid and `S` is invalid: use `I`.
4. If both are valid, compute `diff = |#I − #S|` and `pct = 100·diff / max(#I, #S)`. If `#I < #S` and `pct > 5`, go to step 5. Otherwise use `I` (preferred).
5. **Gap detection on `I`.** For consecutive internal beats `prev, next`, a gap exists when `next.t_ms − prev.endMs > prev.rr_ms + 2000`. The gap spans `[prev.endMs, next.t_ms]`.
6. **Gap fill.** Select streamed beats whose effective time `wallClockMs ?? t_ms` lies inside any gap (inclusive). Streamed `t_ms` is not used because it lags after Bluetooth packet loss. If there are no gaps, or no streamed beat falls in any gap, the composite fails.
7. **Merge.** Two-pointer merge of `I` with the gap-fill beats, ordered by `I.t_ms` versus the streamed beat's effective time. When an internal beat is emitted, *all* following streamed beats within `|Δ| < 50 ms` of it are skipped, and vice versa (cluster-aware de-duplication). Emitted streamed beats have `t_ms` rewritten to `wallClockMs`.
8. If the composite fails, use `S` (the larger set), not `I`.

*Why it works.* The two sources fail differently. The strap's memory is immune to Bluetooth range, phone sleep and app suspension, so it is the primary record. The stream is a live second copy that survives a strap-side interruption. Merging only inside the internal file's own gaps uses the stream exactly where it adds beats and nowhere else; the phone's arrival clock rarely falls within 50 ms of the strap's own beat times, so merging the whole stream would duplicate most of the night. Matching on the arrival clock rather than streamed `t_ms` places each filled beat at its true time, because beat-sum time stops advancing during packet loss. When the shortfall cannot be explained by fillable gaps, the larger series is the better record, so the stream is used.

#### 3.1.4 Dating an undated strap recording

When a downloaded strap recording has no start time and no session on the phone (live, saved, or uniquely matched) claims it:

1. Query HealthKit sleep for the 24 h ending now, passing the recording's beats.
2. If HealthKit reports a sleep start `T_hk`, detect the sleep onset inside the beats (below) as `onsetMs` (0 if none).
3. Recording start = `T_hk − onsetMs`.
4. With no HealthKit sleep, recording start = `now − duration(beats)`.

*RR sleep-onset detector (adaptive ceiling):*

1. Require > 300 beats.
2. Slide a 120-beat window in 30-beat steps. For each window, keep beats with valid RR. If more than half are valid, record heart rate `HR = 60000 / mean(validRR)` at the window's middle beat time.
3. Require > 15 windows.
4. `ceiling = maxHR − 0.5·(maxHR − minHR)` over this night's windows (midpoint of the night's own HR range).
5. For `j` from 5 to `count − 11`: `before = mean(HR[j−5..j−1])`, `after = mean(HR[j..j+9])`. The first `j` with `before − after > 8 bpm` and `after < ceiling` is the onset.
6. Clamp the onset to ≤ 20 min, the plausible sleep-onset latency for a recording started at bedtime [12].

*Why it works.* The strap file carries beats but no clock; HealthKit carries a clock but no beats. Sleep onset is visible in both, as a timestamp in HealthKit and as a sustained heart-rate drop in the beats, so aligning the two places the recording on the wall clock. The ceiling is the midpoint of the night's own HR range because a fixed ceiling such as 65 bpm fails for anyone whose sleeping HR sits above it and has no effect for athletes; the midpoint adapts to each person.

### 3.2 Pause/resume concatenation

A user may pause an overnight recording (for example, on waking briefly) and resume it. A pause archives a paused session, analyzed if it has enough beats and stored raw otherwise. A resume creates a child session linked to the parent. At the next pause or stop, the child's beats are merged with the parent:

1. `offsetMs = child.startDate − parent.startDate`. If `offsetMs ≤ 0` or the value cannot be represented, the merge is refused and the child is analyzed alone.
2. Every child beat gets `t_ms += offsetMs` and `wallClockMs += offsetMs`.
3. Merged series = parent beats followed by shifted child beats. Session start = parent start.

The parent already carries its own parent's beats, so a chain of pauses yields the whole night in one series. The pause interval becomes a recording break (Section 3.3.3), so no successive difference is taken across it.

*Why it works.* The 30–70% band is defined on the whole night's sleep. Analyzing each segment alone would place a separate band in each fragment; concatenating on the parent's timeline lets window selection (Section 3.5) run once over the whole night, with the band where it belongs.

### 3.3 Artifact handling

All artifact handling *drops* beats. Nothing is interpolated.

#### 3.3.1 Whole-series classifier

For each beat, compute the median of a centered window of up to 51 RR values (±25 beats, including the beat itself, truncated at the ends). With `m` = median and `r` = rr_ms:

**Table 3.1.** Whole-series beat classification.

| Condition (evaluated in order) | Flag |
|---|---|
| `r < 300` or `r > 2000` | technical artifact |
| `r < 0.5·m` | extra beat |
| `0.5·m ≤ r < 0.7·m` | ectopic |
| `r > 1.5·m` | missed beat |
| `1.2·m < r ≤ 1.5·m` | ectopic |
| `\|r − m\| / m > 0.20` (covers `0.7·m ≤ r < 0.8·m`) | ectopic |
| otherwise | clean |

The ectopic band is symmetric at 20%. A post-ectopic compensatory pause (20–50% long) is explicitly flagged.

#### 3.3.2 Per-window local ectopic gate

Inside each candidate window, the artifact-free, range-valid RR values are listed in order. Each value is kept if `|r − med| / med ≤ 0.20`, where `med` is the median of up to 10 neighbors (5 before and 5 after in that list, **excluding the beat itself**, so a wild value cannot pull its own reference). If the window has ≤ 10 values, every beat is kept. The reported time-domain metrics apply the same gate, so the selector and the report agree.

#### 3.3.3 Masked RMSSD with recording breaks

A *recording break* separates beat `i` from beat `i−1` when either

- `t_i − endMs_{i−1} > rr_{i−1} + 2000`, or
- both have wall clocks and `wall_i − wall_{i−1} > rr_i + rr_{i−1} + 2000`.

RMSSD is the root mean square of `rr_k − rr_{k−1}` over pairs where (a) both beats are kept by every gate, (b) their *original* series indices are consecutive, and (c) beat `k` does not follow a break. When no pair qualifies the value is 0 (selection) or missing (reporting). In reporting only, if the ectopic gate leaves no pair, artifact-clean adjacent pairs are used without it.

*Why it works.* RMSSD is a statistic of successive differences, so its error comes from differences that are not real. Interpolation manufactures beats and therefore differences; collapsing the array after a removal creates one spurious difference per removed beat [4]. The masked estimator avoids both: every difference it uses is between two measured beats that were adjacent in the original series and not separated by a break. The two-stage detection pairs a whole-series view (a 51-beat median that is stable across a night) with a local view (10 neighbors, self-excluded) that tracks faster changes inside a window. Selection and reporting use one estimator (with a reporting-only fallback when the gate leaves no pair), so the value that won the selection is the value the user sees.

### 3.4 Sleep boundaries and the search band

#### 3.4.1 Boundary sources

On the morning path, boundaries come from, in order:

1. HealthKit sleep for the recording, fetched with the RR series so the HealthKit layer can cross-check it.
2. If HealthKit gives no start: an RR heart-rate estimate. Take 5-min HR windows (≥ 10 beats each) and set `threshold = maxHR − 0.5·(maxHR − minHR)`. Onset is the first of three consecutive windows below the threshold, clamped to ≤ 20 min. Wake is the window after the last window below the threshold.
3. If no sleep data was obtained at all: an estimate from Apple Watch passive HR samples (same midpoint rule, two consecutive points, ≥ 8 bpm range required).
4. Otherwise: recording start and end.

A negative onset is clamped to 0. HealthKit/HR reconciliation, where used, lets HR move the onset earlier freely. HR can move it later only when HealthKit has no detailed stages, and only by more than 15 min. HR can only extend the wake time.

#### 3.4.2 Wall-clock to beat-timeline mapping

Boundaries arrive as wall-clock offsets from session start. The scan is indexed on `t_ms`, which stalls across dropouts. Mapping: if the first beat has no wall clock (strap internal recording, whose beat-sum timeline does not stall during Bluetooth dropouts), the offset is used unchanged. Otherwise, find the first beat with `wallClockMs ≥ firstWall + offset` and return `that.t_ms − first.t_ms`, or the last beat's offset if none qualifies.

- `sleepStart = max(0, map(sleepStartMs))`, or 0 if absent.
- `sleepEnd = min(map(wakeMs), recordingDuration)` if it is later than `sleepStart`, else `recordingDuration`.

#### 3.4.3 Band

`early = sleepStart + 0.30·(sleepEnd − sleepStart)`, `late = sleepStart + 0.70·(…)`, clamped to the recording's first and last `t_ms`. The band's index range runs from the first beat with `t_ms ≥ early` to the last beat with `t_ms ≤ late`. A series under 120 beats, or an empty band, yields no window.

*Why it works.* Sleep architecture is structured relative to sleep, not to the clock or to when the strap was put on. The early third of sleep is dominated by deep-NREM peaks and the last third by REM and arousals. Anchoring the band to the middle 40% of *measured sleep* places it in the same part of the sleep cycle each night, whatever the bedtime, onset latency or wake time, which is the repeatability a morning protocol provides by instruction. The boundary sources are ordered from most to least direct evidence of sleep, so the band is always defined and uses the best boundary available. Translating the boundaries through each beat's arrival time keeps the band on the right beats when Bluetooth dropouts have stalled the beat-sum timeline.

### 3.5 Window selection

#### 3.5.1 Adaptive geometry

With `B` beats in the band:

- `size = 400` if `B ≥ 400`; else `B/2` if `B ≥ 240`; else `max(60, ⌊0.6·B⌋)`.
- `step = max(10, ⌊size/10⌋)`, so 40 beats for a 400-beat window.

Windows are `[e − size, e)` for `e = bandStart + size, bandStart + size + step, …, ≤ bandEnd`. A 400-beat window lasts about 6.7 min at 60 bpm (5 min at 80 bpm).

#### 3.5.2 Per-window evaluation

For each window:

1. `artifactRate = (#flagged) / size`. Reject if above the current pass limit (Section 3.5.3).
2. Valid values = beats that are not flagged and are range-valid. Reject if fewer than 50.
3. Apply the local ectopic gate (Section 3.3.2). Reject if `clean < min(300, max(50, ⌊0.75·size⌋))`.
4. `RMSSD` = masked RMSSD (Section 3.3.3). `meanRR` and the standard deviation of NN intervals, `SDNN` (population, divisor N), are taken over clean beats, and the coefficient of variation is `CV = SDNN / meanRR`.
5. `meanHR` = 5–95% trimmed mean of sensor HR values if ≥ 10 are present, plain mean if fewer, else `60000 / meanRR`.
6. DFA α1 [6] on the clean beats if there are ≥ 64: integrate, use box sizes 4–16 log-spaced by 2^(1/8), apply linear detrend per box, and take the slope of log F(n) against log n.
7. `relativePosition = (midpoint t_ms − sleepStart) / (sleepEnd − sleepStart)`.

The ratio of low- to high-frequency spectral power (LF/HF) is not used in window selection and is not treated as a sympathovagal measure [13].

#### 3.5.3 Two-pass artifact cap

Scan the band with a 10% artifact cap. Only if that yields **zero valid windows** of any kind, rescan with 15%.

#### 3.5.4 Spike filter and organized filter

1. *Isolated spike.* Window `i` (not first or last) is a spike if both neighbors have RMSSD > 0 and `RMSSD_i ≥ 1.5·RMSSD_{i−1}` and `RMSSD_i ≥ 1.5·RMSSD_{i+1}`. Spikes are removed. If removal leaves nothing, the unfiltered list is used.
2. *Organized.* With α1 available: `0.75 ≤ α1 ≤ 1.0` **and** `CV < 0.08`. With α1 unavailable: `CV < 0.08`.

"Organized" names a quiet, stable stretch that makes a good measurement window. It is not a claim about autonomic state.

#### 3.5.5 Ranking by the scoring function

Let `base` be the leave-current-out baseline for this night (Section 3.6.4).

- If `base` exists, each organized window gets `s = Tier1(rmssd, meanHR, α1, base)` (Section 3.7.2, with no autonomic-balance term and no legacy readiness). Sort by `s` descending, then RMSSD descending, then relative position descending (later wins).
- If no baseline exists, sort by RMSSD descending, then relative position descending.
- The first window is selected. It is marked *consolidated* if it survived the spike filter and `CV < 0.08`. *Consolidated* therefore means the selected window was not an isolated spike (CV < 0.08 is already implied by "organized"); night-slot replacement uses it (Section 3.6.2).

#### 3.5.6 Fallbacks and peak capacity

- If no organized window exists, a *peak-RMSSD fallback* runs over the same band: the same two-pass scan and spike filter, then the window with maximum RMSSD, flagged not organized.
- If even that yields nothing, the whole session is analyzed and marked not organized.
- *Peak capacity* is computed separately over the entire recording, not the band. With `N` beats in the recording, it uses a compact window rule (`400` if `N ≥ 400`; else `N/3` if `N ≥ 360`; else `max(60, ⌊0.4·N⌋)`), the 15% artifact cap, the spike filter, and no organization filter, and it reports the maximum-RMSSD window. It is shown to the user but is not scored.

*Why it works.*

- *Geometry.* A 400-beat window is close to the 5-min short-term recording of the Task Force standard [4] and long enough for DFA α1. Shrinking it only when the band is short means a short night is still measured rather than skipped.
- *Strict pass first.* The 10% cap is tried first so that, whenever clean data exist, only clean data compete; 15% is a fallback that applies only when nothing would otherwise be measured.
- *Spike filter.* Adjacent windows share about 90% of their beats, so a stable physiological state appears in several neighboring windows. A window that exceeds *both* overlapping neighbors by 50% owes the excess to the few beats it does not share with them, which is the signature of a transient rather than a state.
- *Organized filter.* α1 near 1 and a low CV mark a stretch with a steady rhythm and no drift, which is what a repeatable measurement window needs.
- *Ranking by the score.* The score is not monotone in RMSSD. The z-mapping is flat for −0.5 ≤ z ≤ +0.5 and flat again above z = +1.5, and the resting-HR and α1 adjustments (±10 and +5/−3/−5 points) are window-specific. The highest-RMSSD window can therefore score lower than another eligible window under the app's own rule; a logged example on one night was RMSSD 53 scoring 80 against RMSSD 45 scoring 85. Ranking organized windows with the same sub-score function (less the autonomic-balance term) and the same baseline keeps window choice and score consistent, and the remaining tie-breaks are deterministic.
- *Fallbacks.* Every night yields a reading, and the reading says how it was obtained. Peak capacity answers a different question (the highest sustained value the night reached) and is kept out of the score so the two questions cannot mix.

### 3.6 Baseline

#### 3.6.1 Admission (three gates, in order)

1. Session type is overnight.
2. Data quality is not `insufficient` and not `preSleep` (Section 3.8.3).
3. *Structural soundness:* the analysis window lasts ≥ 5 min (300 000 ms), **and** the window is organized **or** the session lasts ≥ 3 h (10 800 s).

*Why it works.* Gate 3 deliberately ignores the direction of the reading. The display path treats a short reading differently depending on whether it lands above or below baseline (Section 3.8.3), because a brief clean high reading is still worth showing. For aggregation, that asymmetry would be a ratchet. Short windows have the largest sampling error, so their high readings overshoot most. Admitting the high ones and rejecting the low ones would raise `lnRmssdMean`, every later night would score lower against it, and the correcting samples would be exactly the ones excluded. The structural test is therefore symmetric: a 4-minute window is not baseline-quality whichever side of the mean it falls on. The one direction-dependent exclusion comes through gate 2: a below-baseline session shorter than 3 h is marked `insufficient` by quality rule 3 (`classifyHRVQuality` in `Emuqu/Sources/Services/SessionAcceptanceService.swift`) and is not admitted, while the same session above baseline is admitted if it passes gate 3.

#### 3.6.2 One slot per night

The night key is the calendar date of the first expected wake after the night's overnight window opens (from the user's sleep schedule). A 23:30 start and its 00:30 continuation share a key. If the key is new, the point is appended. Otherwise the newcomer is compared with the incumbent by the rules below, in order; the first rule that applies decides. *Readiness* here is each reading's legacy 1–10 autonomic readiness value. A *morning reading* is one that ended between the night's window start and the expected wake time plus 4 h.

1. **Morning reading.** If exactly one of the two is a morning reading, it wins.
2. **Consolidation.** If the incumbent is consolidated and the newcomer is not, the newcomer wins only if its readiness exceeds the incumbent's by more than 15%. If the newcomer is consolidated and the incumbent is not, the newcomer wins if its readiness is ≥ 90% of the incumbent's.
3. **Organized** (consolidation equal). An organized incumbent beats an unorganized newcomer. An organized newcomer wins if its readiness is ≥ 95% of the incumbent's.
4. **Quality gates.** The newcomer loses if its artifact % exceeds `max(1.5 × incumbent's, 2.0)`, or its window CV exceeds `1.3 ×` the incumbent's.
5. **Improvement.** Otherwise the newcomer wins only if readiness improves by more than 5% of the incumbent's.

Missing values default to 0 (readiness), false (flags) and 100% (artifacts). Up to 90 points are stored, sorted by date.

*Why it works.* One night, one vote: a night recorded in two pieces must not count twice. Keying by wake date groups the pieces of one sleep across midnight. The replacement order prefers the reading taken under the most comparable conditions (the morning reading), then the structurally better window, and only then a higher value, and the final 5% margin keeps a marginally higher reading from displacing a sound one.

#### 3.6.3 Statistics

Take the 60 most recent stored *nights* (a count, not calendar days). Require ≥ 3 points and ≥ 3 positive RMSSD values. Let `n` be the number of positive RMSSD values.

- `lnMean = mean(ln RMSSD)`.
- `lnSD = max(sampleSD(ln RMSSD) · w, 0.10)`, with `w = 1` if `n ≥ 7`, else `w = √(7/n)` (≈ 1.53 at n = 3).
- `hrMean`, `hrSD = max(sampleSD(meanHR), 0.5)`.
- `CV7 = 100 · CV(ln RMSSD of the last 7 points)` if ≥ 7 points (≥ 3 positive), else none.
- `lastDate` = date of the most recent point.

*Why it works.* The widening keeps early z-scores near zero until the spread can be trusted, without withholding a score for the first week. The 0.10 floor (about a 10% change in RMSSD) keeps a stable user's trivial −8% night from being scored as a −8 SD event, as it would be against an observed SD of 0.01.

#### 3.6.4 Leave-current-out

To score a night, only points whose night key is strictly earlier than the scored night's key are used. Re-scoring an old night therefore never reads later nights. On the live morning path this means every stored night except tonight. The same statistics feed window ranking (Section 3.5.5) and the final score.

*Why it works.* A night compared with a baseline that contains it is partly compared with itself, which pulls its z-score toward zero; comparing with earlier measurements only follows Kiviniemi et al. [5]. Restricting to earlier keys also makes a historical rescore reproduce what the user would have seen that morning.

### 3.7 Recovery score (v3.1.oct2026)

#### 3.7.1 z-mapping

`z = (ln RMSSD − lnMean) / lnSD`, mapped piecewise-linearly through:

**Table 3.2.** z-score to score mapping.

| z | −3.0 | −1.5 | −0.75 | −0.5 | +0.5 | +1.5 |
|---|---|---|---|---|---|---|
| score | 5 | 25 | 64 | 72 | 72 | 90 |

Values below −3 map to 5 and values above +1.5 map to 90. NaN maps to 50. The flat region from −0.5 to +0.5 is the SWC deadband [1][2]: a change inside it is treated as no change. The steeper slope below baseline reflects that a drop is actionable while a rise is ambiguous.

#### 3.7.2 Tier-1 HRV sub-score

The Tier-1 HRV sub-score, `T1`, is the HRV factor of every tier. With a baseline and RMSSD > 0:

```
T1 = map(z)
   + clamp(−5 · (meanHR − hrMean)/hrSD, −10, +10)                  // resting HR
   + α1 term: +5 if 0.75 ≤ α1 ≤ 1.0; −5 if α1 > 1.2; −3 if α1 < 0.60; else 0
   + CV7 term: −5 if CV7 < 2%; −3 if CV7 > 12%; else 0
   + ANS term (PNS − SNS): −6 if < −1.5; −3 if < −0.5; +2 if ≥ +1.5; else 0
   − staleness: if d = days(lastDate → referenceDate) ≥ 7: min(20, 5·(1 + (d−7)/7))
T1 = clamp(T1, 0, 100)
```

The autonomic nervous system (ANS) term uses the parasympathetic (PNS) and sympathetic (SNS) nervous system indices of the analysis window, built from the same input triples as Kubios' indices of the same name [8]: mean RR, RMSSD and SD1 for PNS; mean HR, Baevsky's stress index and SD2 for SNS.

Without a baseline: the legacy readiness (1–10) × 10 if present. Otherwise absolute RMSSD bands: ≥ 60 → 85, ≥ 45 → 70, ≥ 30 → 55, ≥ 20 → 40, else 25. With no RMSSD the score is 50.

#### 3.7.3 Tiers

The vitals sub-score is computed first (Section 3.10). The sleep sub-score comes from the sleep analyzer when sleep integration is on. *Comeback mode*, which the user turns on after illness, injury or a long break, lasts 21 days from the date it is set.

**Table 3.3.** Score tiers.

| Tier | Inputs present | Composite |
|---|---|---|
| 3 | sleep and vitals | `0.60·T1 + 0.25·Sleep + 0.15·Vitals`; comeback mode `0.80/0.20/0.00` |
| 2 | sleep only | `0.70·T1 + 0.30·Sleep`; if `z < −1` **and** Sleep < 50: `0.85/0.15` (double-penalty dampening) |
| 1 | no sleep (vitals, if any, are not used) | `T1` |

In comeback mode the vitals factor is still shown, with weight 0. Tier 2 dampening keeps a bad-sleep night from being penalized twice, once through the HRV drop it usually causes and once through the sleep factor. Tiering lets the score use whatever inputs a night has, while HRV remains the dominant term in every tier.

#### 3.7.4 Final composite

1. Missing sleep: in Tier 1, if sleep integration is on, the user has opted into the penalty and there is no sleep data, subtract 10.
2. Clamp to 0–100.
3. Blood-oxygen saturation (SpO₂): if a reading exists and is < 95%, subtract a flat 10 and floor at 0. This is a conservative product rule, not a clinical threshold.

Every deduction is listed in the breakdown.

#### 3.7.5 Training load is excluded

Training-load metrics (the acute:chronic workload ratio, ACWR; monotony; strain) are not inputs to the recovery score. Impellizzeri et al. argue that day-to-day ACWR carries little signal beyond its acute term [14]. A separate training-readiness value is frozen alongside the score; it is described in Paper 2, *Real-Time DFA α1 and Dropout-Robust Training Load* ([link](02-exercise-hrv-and-training-load.md)), Section 3.5.

### 3.8 Score freezing

#### 3.8.1 Snapshot

At acceptance, sleep (for the whole overnight window of the night the session belongs to) and vitals are fetched together with a 10-s timeout. On timeout, scoring proceeds without them. In the vitals snapshot, the **strap's analysis-window mean HR replaces HealthKit's daytime resting HR**, so the vitals HR is compared like-for-like with the baseline's `hrMean`, which is built from the same nocturnal quantity.

#### 3.8.2 Inputs

RMSSD, meanHR and α1 from the selected window. ANS balance = PNS index − SNS index. Baseline = leave-current-out stats. **Reference date = session end**, not the wall clock, so the staleness term is identical whenever the score is recomputed.

#### 3.8.3 Quality decision

Let `base = exp(lnMean)` (0 if no baseline), `dur` = session length and `win` = analysis-window length (session length if there is no window). The rules are evaluated in order:

1. If (`win < 5 min` or (`not organized` and `dur < 3 h`)) **and** `RMSSD < base`: quality `insufficient`, use the baseline.
2. If sleep data exists and the recording does not overlap it: quality `preSleep`, use the baseline. This applies regardless of RMSSD direction.
3. If `RMSSD < base` and `dur < 3 h`: quality `insufficient`, use the baseline.
4. Otherwise quality `good`. A long night below baseline is a real bad night.

Rules 1 and 3 are asymmetric: a short reading is replaced only when it is low. This affects *display*. Baseline admission (Section 3.6.1) applies its own direction-free structural test; through its quality gate it inherits only rule 3's exclusion of below-baseline sessions shorter than 3 h.

#### 3.8.4 Unusable-reading blend

"Use the baseline" means scoring with `RMSSD = exp(lnMean)`, `meanHR = hrMean`, no α1 and no readiness, so T1 lands near 72, adjusted by the ANS term and less any CV7 or staleness deduction. If the user has answered the perceived-readiness prompt (p ∈ [0, 1], clamped), the HRV factor becomes `0.70·T1 + 0.30·(100·p)`. The composite is rebuilt through the same tail as Section 3.7.4, so the missing-sleep and SpO₂ deductions still apply.

#### 3.8.5 What is stored

`recoveryScore` (composite / 10, a 0–10 value; the composite itself is 0–100), `scoreBreakdown` (composite, tier, factors, penalties, SpO₂ flag and `scoringVersion = "v3.1.oct2026"`) and the frozen training readiness. A breakdown decoded without a version field is labeled **`unversioned`**, never assumed to be the current version, because the archive cannot tell which earlier algorithm produced it.

#### 3.8.6 Mutation rules

- *User edits win.* Bulk reanalysis skips sessions whose analysis window the user picked by hand. Automatic sleep refresh never overwrites a sleep snapshot the user has edited. On a second device, where the cloud copy arrives without a snapshot, the refresh may *fill* the snapshot but keeps the user's boundaries and does not rescore.
- *Automatic paths fill, not overwrite.* Pulled-session sleep boundaries are set only where they are missing. An imported duplicate adopts a recovery score only when the existing record has none.
- *Bounded automatic upgrade.* When HealthKit sleep changes, only the most recent overnight session that ended within the last 18 h and has already been scored is considered. Runs are serialized: overlapping triggers collapse into one trailing pass. The fresh sleep must plausibly overlap the recording. The snapshot is updated if this is the first snapshot, the end moved later by more than 60 s, total minutes increased, the onset moved by ≥ 15 min, or the boundary source upgraded from an estimate (HR, Watch HR or recording bounds) to HealthKit sleep (alone or confirmed by the HR estimate). A **rescore** follows only for a first snapshot, a total change of ≥ 20 min, an onset move of ≥ 15 min, or a source upgrade. The scoring boundaries are updated with the snapshot so the rescore uses the new window.
- *Cross-device.* The score, breakdown (with version) and frozen readiness travel inside one encrypted session payload. Of two copies, the one with the newer modification stamp (to the whole second) replaces the other as a unit; each device then restores only the HealthKit readings it holds locally.

*Why it works.* A morning score is something the user acts on, so it is treated as a record rather than a view. Freezing the inputs (snapshot, baseline, reference date) makes recomputation reproduce the same number. The version string attributes every stored score to the algorithm that produced it, so a later rule change does not silently rewrite history, and `unversioned` keeps the archive from attributing an old score to a newer algorithm. The mutation rules let genuinely better data improve the most recent score (late Watch sleep is the common case), while the 18-h horizon and change thresholds keep history from drifting on small revisions. User edits are the strongest evidence available and are never overridden. Moving score, breakdown and version as one unit keeps a device from pairing a score with the wrong explanation.

### 3.9 RR-only sleep staging

#### 3.9.1 Epochs and features

Between sleep start and end, cut 5-min epochs on the beat timeline. An epoch needs ≥ 10 beats and ≥ 8 range-valid RRs, otherwise it is dropped; a night with fewer than 6 epochs is not staged. Per epoch: HR = 60000 / mean RR, RMSSD, population SDNN, CV = SDNN / mean RR, α1 (if ≥ 64 beats), and LF/HF and high-frequency (HF) power from the shared spectral routine over spline-resampled beats.

#### 3.9.2 Within-night rank normalization

Each feature is replaced by its fractional rank across the night's epochs, from 0 (lowest) to 1 (highest), with ties given the mean rank. Missing values are filled before ranking (α1 → the night's median α1 or 0.85; LF/HF → 2.0; HF → 0), so a night with no α1 gives every epoch 0.5.

#### 3.9.3 Scores

`f = (epoch midpoint − sleepStart) / (last epoch midpoint − sleepStart)`. Temporal priors: deep `T_d = 1.0` if `f < 0.4`, `0.4` if `f < 0.6`, else `0.15`. REM `T_r = 1.0` if `f > 0.6`, `0.25` if `f > 0.35`, else `0`. Writing `r_x` for the rank of feature x:

**Table 3.4.** Stage-score weight sets.

| Variant (by availability across the night) | Deep score weights on (1−r_hr, r_rmssd, 1−r_cv, r_hf, 1−r_lfhf, 1−r_α1, T_d) | REM score weights on (1−r_rmssd, r_cv, r_lfhf, 1−r_hf, r_α1, T_r) |
|---|---|---|
| LF/HF and α1 | .12, .10, .08, .15, .18, .22, .15 | .10, .10, .24, .12, .26, .18 |
| LF/HF only | .15, .13, .10, .18, .24, —, .20 | .12, .12, .30, .18, —, .28 |
| α1 only | .18, .18, .12, —, —, .32, .20 | .16, .16, —, —, .38, .30 |
| time-domain only | .25, .25, .15, —, —, —, .35 | .32, .43, —, —, —, .25 |

Awake score: with LF/HF, `.30·r_hr + .25·(1−r_rmssd) + .15·r_cv + .20·r_lfhf + .10·(1−r_hf)`. Without, `.35·r_hr + .30·(1−r_rmssd) + .20·r_cv + .15·r_α1`. The REM score is forced to 0 in the first 60 min after sleep start.

#### 3.9.4 Decision and smoothing

Awake if `awake > 0.80`. Otherwise deep if `deep > 0.60` and `deep ≥ rem`. Otherwise REM if `rem > 0.63` and `rem > deep`. Otherwise core. Then, left to right, any non-awake epoch whose previous and next epochs agree on a different stage takes that stage. Awake epochs are never smoothed away.

#### 3.9.5 Intervals

Consecutive same-stage epochs form an interval. A dropped epoch (a gap) also ends the interval, so a strap dropout is never counted as sleep.

#### 3.9.6 Watch augmentation

When Apple Watch stages exist, the Watch is the anchor. Each RR epoch takes the Watch stage covering most of it. Epochs the Watch does not cover are left alone. Overrides:

**Table 3.5.** Watch-stage overrides.

| Watch stage | Override when | To |
|---|---|---|
| core / unspecified | deep > 0.68 and deep > rem | deep |
| core / unspecified | LF/HF present, rem > 0.63, rem > deep | REM |
| awake | LF/HF present, rem > 0.68, awake < 0.80 | REM |
| deep | LF/HF present, rem > 0.72, deep < 0.40 | REM |
| REM | deep > 0.72, rem < 0.40 | deep |

Only the part of each Watch interval that carries the overridden stage, inside the overridden epoch, is repainted and tagged as HRV-derived. All other Watch timing is kept and no smoothing touches Watch stages.

*Why it works.* Ranking makes the classifier scale-free: it never compares a feature with an absolute threshold, so it adapts to each person and each sensor without calibration. Choosing the weight set by which feature families exist that night keeps the classifier defined when spectral or α1 features are unavailable, instead of filling them with misleading constants. The time-of-night priors and the 60-min REM lockout encode the ordinary ordering of the sleep cycle. Smoothing removes single-epoch flicker but never erases wake, and gap-terminated intervals keep a dropout from being reported as sleep. With a Watch, the Watch's own staging is kept as the anchor and repainted only on strong evidence inside the epochs concerned; REM overrides need LF/HF because time-domain features separate REM from stage N2 sleep poorly [11].

This paper documents the staging method; agreement with polysomnography is not claimed.

### 3.10 Vitals sub-score

The vitals sub-score is the mean of whichever sub-scores exist. A missing input is dropped, not penalized. Every baseline-relative rule penalizes in one direction only; the population fallback for respiratory rate (no baseline) also deducts 10 points below 12 br/min.

**Table 3.6.** Vitals sub-scores.

| Input | Sub-score |
|---|---|
| Sleep HR (strap window mean HR, Section 3.8.1) | `max(0, 100 − 10·max(0, (HR − hrMean)/hrSD))`. Requires a baseline. At or below baseline scores 100. |
| Respiratory rate with a 7-night baseline | `max(0, 100 − 15·max(0, (rate − baseline) − 1))`. Below baseline scores 100. |
| Respiratory rate without a baseline | 100 within 12–18 br/min; above 18: `100 − 15·(rate − 18)`, floor 0; below 12: 90 |
| Apple Watch wrist temperature (deviation from the user's own baseline, which Apple establishes after about 5 nights [15]; dropped if there is no baseline) | ≤ +0.3 °C → 100; ≤ +0.5 °C → 75; ≤ +1.0 °C → 50; above → 25. Cooler than baseline scores 100. |

With no inputs, vitals is absent and the tier falls back. SpO₂ is not a factor (Section 3.7.4).

*Why it works.* The vitals refine the HRV signal rather than compete with it: each rule can only deduct, a missing sensor is dropped so it is not mistaken for a bad night, and where a personal baseline exists the deduction runs in one direction relative to it.

---

## 4. Comparison with Existing Approaches

Commercial entries state only what the cited public pages say. Items marked † were read through search-engine extracts of the cited page, not the full page.

**Table 4.1.** Window choice, baseline, artifact handling and score versioning in published approaches.

| Approach | Window choice | Baseline | Artifact handling | Score versioning |
|---|---|---|---|---|
| Task Force 1996 [4] | Short-term (5 min) or 24 h recordings; no overnight window-selection rule | Not specified | Requires NN intervals; method not prescribed | n/a |
| Plews/Buchheit ln(RMSSD) monitoring [1][2][3] | Standardized morning spot reading | Rolling ln(RMSSD) mean, SWC 0.5 SD | Protocol-based | n/a |
| Kiviniemi 2007 [5] | Morning measurement | Earlier days only | Not the focus | n/a |
| Kubios HRV [8] with Lipponen-Tarvainen correction [7] | User-chosen sample or whole recording | None (analysis tool) | Classifies and *corrects* (interpolates) beats | n/a |
| HRV sleep-staging literature [9][10][11][16][17][18] | Epoch-based staging; fractile or within-night normalization [16][18]; elapsed time as a feature [17] | Not applicable | Varies | n/a |
| Polar Nightly Recharge † [19][20] | HR, HRV and breathing rate over roughly the first 4 h of sleep | Compared with the user's past 28 days; needs 3 nights | No public description found | No public description found |
| WHOOP Recovery † [21][22][23] | HRV averaged over the night, weighted toward slow-wave sleep [21]; patent: HRV in the last sleep phase before waking [22]; a separate study could not reproduce a "last slow-wave sleep" window [23] | 30-day baseline [21] | No public description found | No public description found |
| Oura † [24][25][26] | Nightly HRV = mean of all 5-min samples during sleep [24] | HRV Balance: 14-day weighted average against a ~3-month baseline (another Oura page says 2 months) [25] | No public description found | No public description found; editing bed or wake times changes that day's scores [26] |
| Garmin HRV Status † [27] | Overnight HRV (third-party description only) | 7-day average against a ~3-week baseline | No public description found | No public description found |
| HRV4Training † [28] | Morning spot reading | 60-day normal range, ±0.75 SD | No public description found | No public description found |
| Runners' window comparison † [29] | Sleep onset vs first 4 h vs whole night, compared | Study-specific | Study-specific | n/a |
| **Emuqu** | **30–70% of measured sleep on the beat timeline; adaptive windows ranked by the scoring function** | **Structural admission, one slot per night, 60 nights, √(7/n) widening, leave-current-out** | **Drop-only; whole-series classifier + self-excluding local gate; break-aware masked RMSSD (Section 3.3)** | **Version string on every score; `unversioned` sentinel** |

---

## 5. What Is New

Each statement gives only the part not found in a prior-art search made on 2026-10-08 (patents, vendor support pages and white papers, peer-reviewed and preprint literature, clinical-trial protocols and open-source HRV code). Commit dates are author dates in US Central time (CST = UTC−6, CDT = UTC−5). Each form of a statement was publicly disclosed when it reached the public repository: on 2026-09-08 (first commit 9d89933) for forms committed before that date, and on its commit date for later forms, unless an earlier public disclosure is noted. Statement numbering follows v1.1. The section after each label is where the method is specified.

**N1 (Section 3.1.3). Building an overnight RR series by preferring a chest strap's internal recording and adding Bluetooth-streamed beats only when the internal file is more than 5% shorter.** Streamed beats are added only inside internal gaps (next start − previous end > previous RR + 2000 ms), are matched on the phone's arrival clock rather than their own drifting beat-sum time, and are de-duplicated cluster-wise within 50 ms. If no gap can be filled, the stream is used rather than the shorter internal file.

*Builds on:* the Polar H10's internal memory, which stores about 20 h of RR as one session [30][31]; adds a gap-only merge with the live stream, which no public tool found performs.

*Earliest dated record:* flow-recovery-old aeaf0db, 2026-01-18 (first form: 5% rule and gap rule, matched on beat-sum time, no de-duplication); emuqu 554540f, 2026-10-03 (current form: gap-interior-only insertion). 50 ms de-duplication: flow-recovery-dev c48eeb9, 2026-03-01; cluster tolerance: flow-recovery cc7c53e, 2026-04-18; arrival-clock matching: emuqu-dev 680bbee, 2026-08-25.

**N2 (Section 3.1.4). Dating a chest-strap recording that carries no start time by subtracting an RR-detected sleep onset from the HealthKit sleep start.** The onset is the first sustained drop of more than 8 bpm (5-window versus 10-window means over 120-beat windows) into the lower half of that night's own HR range, clamped to 20 min.

*Builds on:* sleep-onset detection from heart-rate change points, evaluated against polysomnography [32]; adds the use of an onset to date a recording.

*Earliest dated record:* flow-recovery-old 577b937, 2026-01-14 (first form: same back-dating and detector with a fixed 65 bpm ceiling); flow-recovery 24d2017, 2026-08-06 (current form: adaptive midpoint ceiling). 20-min clamp: flow-recovery 206870b, 2026-08-05.

**N3 (Section 3.4). Placing the analysis-window search band at 30–70% of *measured sleep*, after translating wall-clock sleep boundaries onto the recording's beat-sum timeline through each beat's arrival timestamp, so the band lands on the correct beats across Bluetooth dropouts.** The author's article of 2026-05-19 publicly disclosed the 30–70%-of-sleep band; the arrival-clock mapping was not disclosed.

*Builds on:* nocturnal sub-band measurement (Polar's first ~4 h [19], WHOOP's last sleep phase [22], the windows compared in [29]); adds a band defined as a fraction of measured sleep and mapped onto the beat timeline.

*Earliest dated record:* flow-recovery-old 985cefe, 2026-01-13 (first form: 30–70% of the recording; anchored to measured sleep in flow-recovery-old 0a86767 the same day); flow-recovery 8814c54, 2026-07-21 (current form: wall-clock to beat-sum mapping).

**N4 (Sections 3.5.1–3.5.3). A candidate-window scan whose size adapts to the beats available in the band, with a strict-then-relaxed artifact cap and a clean-beat floor.** Size 400; else half the band if ≥ 240; else 60% with a floor of 60. Step max(10, size/10). A 10% artifact cap relaxed to 15% only when the strict pass yields no window at all. Clean-beat floor min(300, max(50, 0.75 × size)).

*Builds on:* valid-interval share thresholds per 5-min segment in an Oura validation study [33] and a clinical protocol that averages three 5-min periods [34]; adds adaptive geometry and the two-pass cap.

*Earliest dated record:* flow-recovery-old 090f9c4, 2026-01-19 (first form: same sizing and step, single 15% cap); flow-recovery a02e903, 2026-05-04 (current form: strict 10% pass before 15%). Clean-beat floor: flow-recovery-dev c48eeb9, 2026-03-01.

**N5 (Section 3.3). Using one masked RMSSD estimator for both window selection and reporting.** It takes differences only between beats that were adjacent in the original series, survived both a whole-series classifier and a self-excluding 10-neighbor 20% median gate, and are not separated by a recording break defined on both the beat timeline and the arrival clock.

*Builds on:* deletion-based RR editing [35] and Task Force adjacency [4]; adds the two-stage self-excluding gate, break detection on two clocks, and a shared estimator.

*Earliest dated record:* flow-recovery-old e5948bd, 2026-01-12 (first form: whole-series flags and the self-excluding 10-neighbor gate; RMSSD on the collapsed array); emuqu 5c4a23d, 2026-10-04 (current form: recording breaks). Shared estimator: emuqu-dev 680bbee, 2026-08-25.

**N6 (Section 3.5.4). Selecting among windows that are neither isolated spikes nor disorganized.** A spike is ≥ 150% of both neighbors' RMSSD, with the unfiltered list kept if filtering removes everything. "Organized" means DFA α1 in 0.75–1.0 and RR coefficient of variation (SDNN / mean RR) < 0.08, or the CV test alone when α1 is unavailable. The author's article of 2026-05-19 publicly disclosed α1-based "organized windows", without the thresholds.

*Builds on:* selection of the "256 most stable points" of a recording [36]; adds the neighbor-spike test and the α1/CV organized test.

*Earliest dated record:* flow-recovery-old 2bf168f and a695a90, 2026-01-14 (first form: same spike filter; organized was α1 in range and (LF/HF ≤ 1.5 or CV < 0.08)); flow-recovery-dev c48eeb9, 2026-03-01 (current form).

**N7 (Section 3.5.5). Ranking candidate analysis windows by the HRV sub-score function that produces the final recovery score, less its autonomic-balance term.** The function is the z-mapping with a flat deadband plus resting-HR and α1 adjustments. The ranking is computed against the same leave-current-out personal baseline, ties are broken by RMSSD and then by later position, and the method falls back to RMSSD ranking only when no baseline exists. The author's article of 2026-05-19 described the earlier rule, highest RMSSD in the band.

*Builds on:* the ln(RMSSD) z-score and SWC framework [1][2]; adds the score itself as the window-selection criterion. No public method doing this was found in vendor documentation, patents, the HRV literature or open-source HRV tools.

*Earliest dated record:* flow-recovery be64931, 2026-04-17 (first form; position tie-break flow-recovery a1eb5bc, same day); emuqu 554540f, 2026-10-03 (current form: leave-current-out baseline).

**N8 (Section 3.5.6). Reporting a peak-RMSSD fallback window, flagged not organized, when no organized window exists, alongside a separately computed whole-recording "peak capacity" that is displayed but never scored.**

*Builds on:* the organized-window selection of N6; adds the labeled fallback and the separation of an unscored peak from the scored window. No public method doing this was found in the same search.

*Earliest dated record:* flow-recovery-old c32a6e3, 2026-01-14 (first form: peak capacity); flow-recovery-dev c48eeb9, 2026-03-01 (current form: peak-RMSSD fallback window).

**N9 (Sections 3.6.1, 3.8.3). Admitting nights to a rolling ln(RMSSD) baseline by a structural test that ignores the direction of the reading, while the display-side quality rule stays direction-dependent, so that short high readings cannot ratchet the baseline upward.** The structural test is window ≥ 5 min, and organized or session ≥ 3 h. The one direction-dependent exclusion is a below-baseline session shorter than 3 h, which quality rule 3 marks `insufficient` (`classifyHRVQuality` in `Emuqu/Sources/Services/SessionAcceptanceService.swift`).

*Builds on:* rolling personal baselines [1][2][28]; adds an explicit admission rule whose structural test ignores direction.

*Earliest dated record:* flow-recovery 870028e, 2026-04-05 (first form: same 5 min / 3 h constants, direction-dependent); emuqu-dev 680bbee, 2026-08-25 (current form: direction-free structural test).

**N10 (Section 3.6.2). Holding one baseline slot per night keyed by the wake date of the user's sleep schedule, with an ordered replacement rule.** The order is morning reading, then consolidation (15% / 90%), then organized (95%), then artifact and CV quality ceilings, then a 5% improvement.

*Builds on:* rolling personal baselines [1][2]; adds the per-night slot and ordered replacement. No public method doing this was found in the same search.

*Earliest dated record:* flow-recovery-old 52d6267, 2026-01-22 (first form: same ordered rule, calendar-day slot; morning = before 10:00 from flow-recovery-old abf91d6, 2026-01-18); emuqu 554540f, 2026-10-03 (current form: wake-date key).

**N11 (Sections 3.6.3–3.6.4). Widening the ln(RMSSD) SD of a personal baseline by √(7/n) below seven nights with a 0.10 floor, and scoring each night only against nights with an earlier night key, with the same leave-current-out statistics used for window ranking and for the score.** The 60-night statistics window is not presented as new.

*Builds on:* HRV4Training's 60-day normal range of ±0.75 SD [28] and comparison with earlier days [5]; adds small-sample widening and shared leave-current-out statistics.

*Earliest dated record:* flow-recovery-dev c48eeb9, 2026-03-01 (first form: 60 nights, ln statistics, 0.10 floor); emuqu 554540f, 2026-10-03 (current form: earlier-nights filter). √(7/n) widening: flow-recovery c6d66dd, 2026-06-25.

**N12 (Sections 3.8.1–3.8.5). Freezing a recovery score at acceptance with frozen inputs and a per-score algorithm version.** The freeze substitutes the strap's nocturnal window HR for daytime resting HR in the vitals snapshot; sets the reference date to session end; applies a baseline-substitution rule for unusable readings that is triggered asymmetrically for short readings, with a 70/30 baseline/subjective blend routed through the same penalty tail; and stores an algorithm-version string, with records lacking one labeled `unversioned` rather than current.

*Builds on:* composite readiness scores in general; adds frozen inputs and per-score algorithm versioning, which no vendor documentation found describes.

*Earliest dated record:* flow-recovery-dev c48eeb9, 2026-03-01 (first form: frozen snapshot); emuqu-dev f2e6ed1, 2026-09-03 (current form: version string and `unversioned`). 70/30 blend: flow-recovery 68b07a1, 2026-03-28; asymmetric short rule: flow-recovery 870028e, 2026-04-05; strap nocturnal HR: flow-recovery 0a3972d, 2026-05-03; reference date: flow-recovery d98e25f, 2026-06-30; a versioned-parameters precursor: flow-recovery dba6fcc, 2026-05-01.

**N13 (Section 3.8.6). Bounding automatic post-freeze changes.** Only the most recent overnight session that ended within the last 18 h is eligible. Rescoring happens only on a first snapshot, a ≥ 20 min total change, a ≥ 15 min onset move, or a boundary-source upgrade from an estimate (HR, Watch HR or recording bounds) to HealthKit sleep. Scoring boundaries move with the display snapshot. User-edited boundaries and manual windows are never overwritten. Score, breakdown and version are merged across devices as one unit.

*Builds on:* Oura rescoring after bedtime edits [26] and WHOOP Recovery changing after sleep edits [21]; adds the eligibility horizon, change thresholds, source-upgrade rule and atomic cross-device merge.

*Earliest dated record:* flow-recovery-dev c48eeb9, 2026-03-01, and flow-recovery-dev 6eddc97, 2026-03-15 (first form); emuqu 554540f, 2026-10-03 (current form: atomic cross-device merge). ≥ 20 min rescore: flow-recovery 38c4598, 2026-05-13; 18 h horizon: flow-recovery cec0a25, 2026-07-03; 15-min onset and Watch upgrade: flow-recovery 24d2017, 2026-08-06.

**N14 (Section 3.9). RR-only sleep staging on 5-min epochs using four weight sets chosen by which feature families exist that night, combined with a Watch augmentation that repaints only the overridden stage inside overridden epochs.** The staging uses time-of-night priors with a 60-min REM lockout, single-epoch smoothing that never removes wake, and gap-terminated intervals. The Watch augmentation keeps the Watch's own intervals and requires spectral data for any REM override. The statement covers the method, not its accuracy.

*Builds on:* HRV-only staging with fractile normalization [16], elapsed time as a feature [17], within-night normalization [18] and Polar's wrist-based staging [37]; adds availability-dependent weight sets and the anchored Watch repaint.

*Earliest dated record:* flow-recovery-dev c48eeb9, 2026-03-01 (first form: ranks, four weight sets, REM lockout, smoothing, augmentation); emuqu 5c4a23d, 2026-10-04 (current form: tie-averaged ranks). Watch-interval repaint: emuqu 554540f, 2026-10-03.

**Prior work used, not presented as new.**

- RMSSD, SDNN and pNN50 definitions and the adjacency requirement [4].
- ln(RMSSD) baselines, z-scores and the 0.5 SD smallest worthwhile change [1][2][3].
- Comparison with earlier days [5].
- DFA and its box-size ranges [6].
- Median-deviation artifact and ectopic classification and the 20% threshold [7][8][38][39].
- The concept of HRV-based sleep staging, within-night rank or fractile normalization, time-of-night features and the direction of α1 and LF/HF changes across stages [9][10][11][16][17][18].
- Strap internal recording [30].
- Measuring HRV in a sub-band of the night [19][22][29].
- Selecting segments under an artifact-share limit [33][34].
- A 60-day personal normal range [28].
- Rescoring after a sleep-boundary edit [21][26].
- Weighted composite readiness scores in general.
- The criticism of ACWR [14].
- Piecewise-linear score mappings in general.

---

## 6. Verification

The cross-implementation report, with scripts and per-record results, is `Tools/validation/RESULTS.md`.

**Time-domain arithmetic.** On every build, RMSSD, SDNN and the percentage of successive differences greater than 50 ms (pNN50) are compared, on 6,000 intervals from 20 records of the PhysioNet Normal Sinus Rhythm RR Interval Database (nsr2db) [40], with a separate reference implementation of the Task Force definitions (register label `validated`). A separate Python reimplementation reproduced the stored references for mean RR and SDNN to within 4.9 × 10⁻⁷ ms. This covers the arithmetic, not the strap's beat detection.

**Separate reimplementation.** The analysis code at e028039 was reimplemented in Python and accepted as equivalent only after it reproduced the app's own unit-test expectations: 114 test cases across eight suites (DFA, DFA reference, frequency domain, sleep-stage classifier, artifact detection, live-DFA cleaning, time domain, HRV reference) all matched, several to the last printed digit. The reimplementation was run by the project.

**Artifact pipeline on recordings with ectopic beats (Sections 3.3.1–3.3.3).** On the MIT-BIH Arrhythmia Database [41] (44 records, paced records excluded; 100,733 annotated beats, 10,593 ectopic), with every beat kept as a chest strap would report it, uncorrected ectopic beats inflate 5-min RMSSD by a median of 32 ms against the normal-to-normal reference; on a ratio scale, the uncorrected values are a median 2.2 times the reference. The app's drop-only pipeline (whole-record classifier, local gate and masked estimator) brings the median absolute error to 4.7 ms over all 255 segments and 3.2 ms outside atrial fibrillation (AF) and flutter. The overnight RMSSD exclusion (whole-series classifier plus the per-window ectopic gate) detects 85.6% of ventricular premature beats, with an interval specificity of 94.3%. Detection statistics by beat type and Bland–Altman limits are in the cross-implementation report, which also covers the PhysioNet sleep datasets slpdb [42] and the Cyclic Alternating Pattern (CAP) Sleep Database [43].

**Register labels.** Exact labels from `Tools/science_register/register.json`, scoring version v3.1.oct2026. Register labels are internal: `validated` means the entry's arithmetic or literature basis has been checked against reference data or its source; `awaiting-validation` means no such check exists yet.

**Table 6.1.** Science-register entries relevant to this paper.

| Register entry | Register label | Covers |
|---|---|---|
| hrv-time-domain-arithmetic | validated | RMSSD, SDNN and pNN50 arithmetic |
| lnrmssd-swc-band | validated | 0.5 SD smallest worthwhile change on rolling ln(RMSSD) |
| resting-dfa-a1-reference-band | awaiting-validation | The 0.75–1.0 α1 band: +5 bonus and organized test |
| pns-sns-gap-readiness | awaiting-validation | ANS-balance adjustment |
| composite-weights-60-25-15 | awaiting-validation | Tier weights, resting-HR and CV adjustments |
| rmssd-absolute-fallback-bands | awaiting-validation | No-baseline RMSSD bands |
| baseline-staleness-penalty | awaiting-validation | Staleness deduction |
| sleep-score-six-factor | awaiting-validation | Sleep sub-score |
| hrv-sleep-staging | awaiting-validation | Section 3.9 |
| spo2-flat-penalty | awaiting-validation | SpO₂ deduction |

Window selection (Sections 3.4–3.5), the baseline rules (Section 3.6) and the freeze rules (Section 3.8) are specified as deterministic rules and enforced by unit tests (for example, that the window chosen is the one the score prefers). Their relation to physiological or training outcomes is not claimed. Emuqu is not a medical device, and no output is a diagnosis.

---

## 7. Design Tradeoffs

- *A short window represents the night.* About 6.7 min from the middle of sleep stands for the whole night, trading coverage for night-to-night repeatability.
- *Selection follows the score.* Ranking by the scoring function picks the best-scoring eligible window, so scores are consistent across nights but sit at the favorable end of the eligible windows rather than at a random one.
- *Drop-only artifact handling* never fabricates a difference, at the cost of fewer usable pairs in noisy windows; a 20% median rule treats beats less than 20% premature as normal.
- *Display is asymmetric; the structural admission test is not.* A short high reading is shown to the user but not admitted to the baseline unless it passes the structural test; the only direction-dependent exclusion is a below-baseline session shorter than 3 h.
- *Estimated boundaries.* When HealthKit sleep is absent, HR-estimated boundaries (clamped to a 20-min onset) set the band, which moves with them.
- *Thresholds as conventions.* The organized-window α1 band and CV < 0.08 are app conventions with register label awaiting-validation.
- *Stage minutes are estimates* derived from beat intervals, not measurements of sleep stages.

---

## 8. Provenance and Dates

The pre-code design history is described in Paper 5, *Blind-Audit Convergence: A Method for Directing AI to Produce Converged Software Designs* ([link](05-blind-audit-convergence-method.md)).

### 8.1 Project origin

The project began as a general fitness app. Repository AI-Fitness-Coach (2025-02-16 to 2025-02-17, 19 commits, private) displayed Apple HealthKit heart rate and HRV (SDNN), streamed Polar H10 heart rate over Bluetooth and estimated VO₂max; it contains no RR-interval analysis. On 2025-02-22 (15:44 UTC) the author proposed, in a ChatGPT conversation, an app that would take an HRV reading from a chest strap worn overnight just before the user wakes (excerpt recovered through conversation-history retrieval on 2026-10-08). That thread is separate from the 2025 records of the author's design-audit method, which concern another project (Paper 5). The Emuqu design itself begins with the full-night capture problem statement of December 2025 (Paper 5, Section 4).

### 8.2 Repository lineage

**Table 8.1.** Repository lineage. All repositories are owned by the author and retained with full history.

| Repository | Product name | First commit | Extent | Visibility |
|---|---|---|---|---|
| chrissharp80/AI-Fitness-Coach | (fitness app) | 2025-02-16 | 19 commits to 2025-02-17 | Private |
| chrissharp80/flow-recovery-old | Flow HRV | e5948bd, 2026-01-12 | 250 commits to 2026-01-26 | Private |
| chrissharp80/flow-recovery-dev | Flow Recovery | c48eeb9, 2026-03-01 | Squashed import; to 2026-03-15 | Private |
| chrissharp80/flow-recovery | Flow Recovery | 39bfcd4, 2026-03-15 | 196 commits to 2026-08-12 | Private |
| chrissharp80/emuqu-dev | Emuqu | d4e5cf8, 2026-08-16 | Squashed import; to 2026-09-04 | Private |
| chrissharp80/emuqu | Emuqu | 9d89933, 2026-09-08 | Squashed import; current | Public (PolyForm Strict 1.0.0) |

History has gaps from 2026-01-26 to 2026-03-01, 2026-08-12 to 2026-08-16 and 2026-09-04 to 2026-09-08, where each new repository began with a squashed import; a date at a squashed import is an upper bound for anything it contains. The pre-code design (v1 to v9.2 FINAL, completed 2026-01-08 21:06 CST) is described in Paper 5, Section 4: versions v1 and v3.0 have not been recovered; v2–v2.2 and v4.0–v9.1 survive in the author's Claude conversation record; v9.2 FINAL survives as a Google Drive document.

Scoring versions: v2.may2026 (public 2026-09-08) → v3.oct2026 (2026-10-03) → v3.1.oct2026 (2026-10-04).

### 8.3 Dated records outside git

These are the author's own files and messages that date methods in this paper. Conversation dates are the conversation's last activity and are therefore upper bounds (≤).

- ≤ 2025-12-30 14:22 CST (claude.ai conversation "Oura ring sleep tracking after waking up", 1bb09c3b): the window idea, in the author's words: "break all this […] up into 5 minute sections and then figure out the best 5 minute section", skipping the start of sleep, without relying on Apple's sleep stages to pick the section.
- ≤ 2026-01-08: the pre-code design sequence (Section 8.2) fixed the window rule as shown in Table 8.2. The v9.2 FINAL document (Google Drive file created 2026-01-09 03:06:59 UTC) specifies artifact detection by a 50-beat rolling median (sized for about 95,000 beats a night), time-domain metrics on NN intervals without interpolation, and an acceptance test requiring RMSSD within 5% of a reference implementation.
- 2026-01-12 and 2026-01-14: "Flow HRV" session reports showing "Window Beats 400" and a 7.8-min analysis window.
- 2026-01-14: a private message to a colleague describing the strap recording internally while the app streams, with a report and screenshots.
- 2026-01-15: app logs pasted into a message: "Using HealthKit sleep start for window selection … No HealthKit sleep start, using recording start".
- 2026-02-16, 2026-02-18 and 2026-03-04: app-generated "Flow Recovery" PDF session reports (dates as printed in each footer) showing peak HRV separately from the analysis window.
- 2026-03-06: a private message to a second colleague describing the best consecutive 400 beats between 30% and 70% of the sleep window, and simultaneous streaming and internal strap capture with the stream scored while the strap file downloads.
- 2026-05-06 to 2026-05-10: project documents (including "flow-recovery-audit.md") describing score-based window ranking ("best Tier-1 score, not just the highest raw RMSSD"), frozen historical scores, rescore on manual sleep refresh, the RR-based sleep stage classifier with optional Watch refinement, the ln(RMSSD) z-score against a 60-day baseline, and an isolated-spike ratio of 1.50.

**Table 8.2.** Evolution of the window rule.

| Stage | Date | Window rule |
|---|---|---|
| Design v1 (known from an audit of it) | ≤ 2026-01-08 | Window with the highest mean RR ("Recovery Segment") |
| Design v2–v2.2 | ≤ 2026-01-08 | 5-min blocks in the 60 min before wake; the last block that qualifies (artifact < 5%, mean RR > 800 ms, RMSSD > 20 ms, stability) |
| Design v6.0–v9.2 | ≤ 2026-01-08 | The best qualifying block by quality, ties to the block nearest wake |
| Code | 2026-01-13 | 30–70% band, of the recording (flow-recovery-old 985cefe) and of measured sleep (flow-recovery-old 0a86767) the same day |
| Code | 2026-04-17 | Eligible windows ranked by Tier-1 score (flow-recovery be64931) |

### 8.4 Public disclosures

- 2026-01-27: TestFlight beta opened (over 1,500 sessions by 2026-03-06; 45 testers and over 6,500 sessions by August 2026). A public TestFlight join link appeared in the project README by May 2026.
- 2026-05-19: Substack article "A Powerfully Lazy Man's Way to Better Health" (what it disclosed is listed below).
- 2026-08-10: Substack article "How I Build Production Software by Directing AI" (Paper 5 lists what it disclosed).
- 2026-09-08: public repository github.com/chrissharp80/emuqu (first commit 9d89933).
- 2026-10-08: these white papers.

The 2026-05-19 article described publicly: dual capture (internal strap recording and Bluetooth stream) merged in the morning; DFA α1 used to find "organized windows"; and a window search bounded to 30–70% of the time of sleep that picks the window with the highest RMSSD. It did not describe the gap-fill and de-duplication rules, the arrival-clock mapping, the thresholds of the organized test, score-ranked selection (in code since 2026-04-17), the baseline rules, score freezing or versioning, or sleep staging.

### 8.5 Authorship

Chris Sharp is the sole author of these papers and of the design, and the only person who commits to the repositories above. The code was written by AI coding assistants under his direction, and some commits carry "Claude" as author or co-author; he supplied the requirements, design direction, review, testing and acceptance, and wrote no code by hand. He developed the methods described here independently and did not learn them from anyone.

### 8.6 Document history

v1.0, v1.1, v1.2 and v1.3 all published 2026-10-08. v1.1 added prior-art comparison and provenance; v1.2 restructured method-first and moved verification detail to the cross-implementation report; v1.3 applied an editorial review (series-wide format, corrected internal references, tightened claims).

---

## References

Items marked [S] were seen only through a search-engine extract on 2026-10-08.

1. Plews DJ, Laursen PB, Stanley J, Kilding AE, Buchheit M. Training adaptation and heart rate variability in elite endurance athletes: opening the door to effective monitoring. Sports Med. 2013;43(9):773–781. doi:10.1007/s40279-013-0071-8
2. Buchheit M. Monitoring training status with HR measures: do all roads lead to Rome? Front Physiol. 2014;5:73.
3. Plews DJ, Laursen PB, Kilding AE, Buchheit M. Heart rate variability in elite triathletes, is variation in variability the key to effective training? A case comparison. Eur J Appl Physiol. 2012;112(11):3729–3741.
4. Task Force of the European Society of Cardiology and the North American Society of Pacing and Electrophysiology. Heart rate variability: standards of measurement, physiological interpretation and clinical use. Circulation. 1996;93(5):1043–1065.
5. Kiviniemi AM, Hautala AJ, Kinnunen H, Tulppo MP. Endurance training guided individually by daily heart rate variability measurements. Eur J Appl Physiol. 2007;101(6):743–751.
6. Peng CK, Havlin S, Stanley HE, Goldberger AL. Quantification of scaling exponents and crossover phenomena in nonstationary heartbeat time series. Chaos. 1995;5(1):82–87.
7. Lipponen JA, Tarvainen MP. A robust algorithm for heart rate variability time series artefact correction using novel beat classification. J Med Eng Technol. 2019;43(3):173–181.
8. Tarvainen MP, Niskanen JP, Lipponen JA, Ranta-aho PO, Karjalainen PA. Kubios HRV – heart rate variability analysis software. Comput Methods Programs Biomed. 2014;113(1):210–220.
9. Fonseca P, Long X, Radha M, Haakma R, Aarts RM, Rolink J. Sleep stage classification with ECG and respiratory effort. Physiol Meas. 2015;36(10):2027–2040.
10. Radha M, Fonseca P, Moreau A, et al. Sleep stage classification from heart-rate variability using long short-term memory neural networks. Sci Rep. 2019;9:14149.
11. Penzel T, Kantelhardt JW, Grote L, Peter JH, Bunde A. Comparison of detrended fluctuation analysis and spectral analysis for heart rate variability in sleep and sleep apnea. IEEE Trans Biomed Eng. 2003;50(10):1143–1151.
12. Ohayon MM, Carskadon MA, Guilleminault C, Vitiello MV. Meta-analysis of quantitative sleep parameters from childhood to old age in healthy individuals. Sleep. 2004;27(7):1255–1273.
13. Billman GE. The LF/HF ratio does not accurately measure cardiac sympatho-vagal balance. Front Physiol. 2013;4:26.
14. Impellizzeri FM, Tenan MS, Kempton T, Novak A, Coutts AJ. Acute:chronic workload ratio: conceptual issues and fundamental pitfalls. Int J Sports Physiol Perform. 2020;15(6):907–913.
15. Apple. Wrist temperature on Apple Watch (HT213275) [Internet]. n.d. https://support.apple.com/en-us/HT213275 (accessed 2026-10-08) [S]
16. [HRV-only sleep staging with fractile normalization]. ScienceDirect S1746809413000864 [Internet]. https://www.sciencedirect.com/science/article/pii/S1746809413000864 (accessed 2026-10-08) [S]
17. [ECG-based sleep staging with elapsed time as a feature]. arXiv:1910.11702 [Internet]. 2019. https://arxiv.org/abs/1910.11702 (accessed 2026-10-08) [S]
18. [Within-night normalization for cardiac sleep staging]. PubMed 42375153 [Internet]. https://pubmed.ncbi.nlm.nih.gov/42375153/ (accessed 2026-10-08) [S]
19. Polar Electro. Nightly Recharge support documentation [Internet]. n.d. https://support.polar.com (accessed 2026-10-08) [S]
20. Polar Electro. Nightly Recharge white paper [Internet]. 2019. https://www.polar.com/en/science/whitepapers/nightly-recharge (accessed 2026-10-08) [S]
21. WHOOP. WHOOP Recovery [Internet]. n.d. https://support.whoop.com/s/article/WHOOP-Recovery (accessed 2026-10-08) [S]
22. WHOOP, Inc. US Patent 9,750,415 B2, filed 2016-07-12 [Internet]. https://patents.google.com/patent/US9750415B2 (accessed 2026-10-08) [S]
23. Dial et al. Physiol Rep. 2025. doi:10.14814/phy2.70527 (accessed 2026-10-08) [S]
24. Oura. Heart rate variability [Internet]. n.d. https://support.ouraring.com/hc/en-us/articles/360025441974 (accessed 2026-10-08) [S]
25. Oura. HRV Balance [Internet]. n.d. https://ouraring.com/blog/hrv-balance (accessed 2026-10-08) [S]
26. Oura. Editing bedtime and wake time [Internet]. n.d. https://support.ouraring.com/hc/en-us/articles/360025445994 (accessed 2026-10-08) [S]
27. the5krunner. [Third-party description of Garmin HRV Status] [Internet]. n.d. https://the5krunner.com (accessed 2026-10-08) [S]
28. HRV4Training. Determining your normal range [Internet]. n.d. https://www.hrv4training.com/blog2/determining-your-normal-range (accessed 2026-10-08) [S]
29. [Comparison of nocturnal HRV windows in runners]. Sports Med Open. 2024. https://link.springer.com/article/10.1186/s40798-024-00779-5 (accessed 2026-10-08) [S]
30. Wearipedia. Polar H10 notebook (offline RR memory) [Internet]. n.d. https://wearipedia.readthedocs.io/en/latest/notebooks/polar_h10.html (accessed 2026-10-08) [S]
31. KJA88. syzygy-mission-control, GitHub issue 21 (Polar H10 offline RR memory) [Internet]. n.d. https://github.com/KJA88/syzygy-mission-control/issues/21 (accessed 2026-10-08) [S]
32. [Sleep-onset detection from heart-rate change points against polysomnography]. PMC11991269 [Internet]. https://pmc.ncbi.nlm.nih.gov/articles/PMC11991269/ (accessed 2026-10-08) [S]
33. [Oura validation with per-segment valid-interval thresholds]. Sensors. 2024;24(23):7475. https://www.mdpi.com/1424-8220/24/23/7475 (accessed 2026-10-08) [S]
34. ClinicalTrials.gov. NCT04075279 [protocol averaging three 5-min periods] [Internet]. https://clinicaltrials.gov/study/NCT04075279 (accessed 2026-10-08) [S]
35. [RR-interval deletion editing]. ResearchGate publication 6495246 [Internet]. https://www.researchgate.net/publication/6495246 (accessed 2026-10-08) [S]
36. [Selection of the 256 most stable points]. ScienceDirect S1413355517302186 [Internet]. https://www.sciencedirect.com/science/article/pii/S1413355517302186 (accessed 2026-10-08) [S]
37. Polar Electro. Sleep Plus Stages white paper (wrist beat-to-beat intervals plus accelerometer) [Internet]. n.d. https://www.polar.com/en/science/whitepapers (accessed 2026-10-08) [S]
38. Berntson GG, Bigger JT, Eckberg DL, et al. Heart rate variability: origins, methods, and interpretive caveats. Psychophysiology. 1997;34(6):623–648.
39. Berntson GG, Quigley KS, Jang JF, Boysen ST. An approach to artifact identification: application to heart period data. Psychophysiology. 1990;27(5):586–598.
40. Goldberger AL, Amaral LAN, Glass L, et al. PhysioBank, PhysioToolkit, and PhysioNet: components of a new research resource for complex physiologic signals. Circulation. 2000;101(23):e215–e220.
41. Moody GB, Mark RG. The impact of the MIT-BIH Arrhythmia Database. IEEE Eng Med Biol Mag. 2001;20(3):45–50. PhysioNet mitdb 1.0.0, https://physionet.org/content/mitdb/1.0.0/ (accessed 2026-10-08)
42. Ichimaru Y, Moody GB. Development of the polysomnographic database on CD-ROM. Psychiatry Clin Neurosci. 1999;53(2):175–177. PhysioNet slpdb 1.0.0, https://physionet.org/content/slpdb/1.0.0/ (accessed 2026-10-08)
43. Terzano MG, Parrino L, Sherieri A, et al. Atlas, rules, and recording techniques for the scoring of cyclic alternating pattern (CAP) in human sleep. Sleep Med. 2001;2(6):537–553. PhysioNet capslpdb 1.0.0, https://physionet.org/content/capslpdb/1.0.0/ (accessed 2026-10-08)

---

## Appendix A: Parameters

**Table A.1.** Parameters.

| Name | Value | Unit | Role |
|---|---|---|---|
| minimumValidBeats | 120 | beats | Source validity; minimum series for band search |
| compositeThresholdPercent | 5 | % | Internal deficit that triggers a composite |
| gap slack | 2000 | ms | Gap / recording-break tolerance beyond one RR |
| duplicateToleranceMs | 50 | ms | Cross-source duplicate window |
| backup interval | 60 | s | Append-only JSONL flush |
| onset minimum beats | > 300 | beats | Onset detector input |
| onset window / step | 120 / 30 | beats | Onset HR windows |
| onset minimum windows | > 15 | windows | Onset detector |
| onset drop | > 8 | bpm | Before (5-window) − after (10-window) mean |
| ceiling fraction | 0.5 | — | Midpoint of the night's HR range |
| max onset latency | 20 | min | Clamp on HR-estimated onset |
| boundary disagreement | 15 | min | HR vs HealthKit reconciliation |
| RR valid range | 300–2000 | ms | Physiological gate |
| rolling median half-window | 25 | beats | Whole-series classifier (51-value centered) |
| extra / missed thresholds | 0.5× / 1.5× | median | Classifier |
| ectopic threshold | 0.20 | fraction | Classifier and local gate |
| local median neighbors | 10 | beats | Self-excluding local gate |
| band | 0.30–0.70 | sleep fraction | Search band |
| beatsPerWindow | 400 | beats | Target window |
| adaptive window | B/2 if B ≥ 240; else max(60, 0.6B) | beats | Short bands |
| step | max(10, size/10) | beats | Scan step |
| artifact cap strict / fallback | 0.10 / 0.15 | fraction | Two-pass scan |
| minimum valid RRs | 50 | beats | Per window |
| minCleanBeats | min(300, max(50, 0.75·size)) | beats | Per window |
| DFA minimum | 64 | beats | α1 computed |
| α1 boxes | 4–16 (ratio 2^(1/8)) | beats | DFA α1 |
| isolatedSpikeRatio | 1.50 | × | Spike filter |
| organized α1 | 0.75–1.0 | — | Organized test |
| unstable CV | 0.08 | fraction | Organized and consolidated tests |
| peak-capacity window | 400; N/3 if N ≥ 360; else max(60, 0.4N) | beats | Whole-recording scan |
| reliable window | 5 (300 000 ms) | min | Baseline admission; quality rule |
| overnight session | 3 (10 800 s) | h | Baseline admission; quality rule |
| stored points | 90 | nights | Baseline storage |
| stats window | 60 | nights | Baseline statistics |
| minimum nights | 3 | nights | Baseline exists |
| widening | √(7/n), n < 7 | — | SD widening |
| lnRmssdSDFloor | 0.10 | ln units | SD floor |
| meanHRSDFloor | 0.5 | bpm | HR SD floor |
| replacement fractions | 0.15 / 0.90 / 0.95 / 0.05 | — | Night-slot replacement |
| morning reading | wake + 4 | h | Night-slot replacement |
| artifact ceiling | max(1.5×, 2.0) | % | Night-slot replacement |
| CV reject multiplier | 1.3 | × | Night-slot replacement |
| z bands | (−3,5) (−1.5,25) (−0.75,64) (−0.5,72) (0.5,72) (1.5,90) | — | z-mapping |
| resting-HR multiplier / clamp | −5 / ±10 | points per SD | Tier-1 adjustment |
| α1 bonus / penalties | +5 / −5 (>1.2) / −3 (<0.60) | points | Tier-1 adjustment |
| CV7 thresholds / penalties | <2 → −5; >12 → −3 | % / points | Tier-1 adjustment |
| ANS thresholds / points | <−1.5 → −6; <−0.5 → −3; ≥1.5 → +2 | — / points | Tier-1 adjustment |
| staleness | ≥7 d: min(20, 5·(1+(d−7)/7)) | points | Tier-1 deduction |
| absolute bands | 60/45/30/20 → 85/70/55/40; else 25; none 50 | ms / points | No-baseline fallback |
| Tier 3 weights | 0.60/0.25/0.15 | — | Composite |
| Comeback weights / duration | 0.80/0.20/0.00 / 21 | — / days | Composite |
| Tier 2 weights / dampened | 0.70/0.30 / 0.85/0.15 | — | Composite |
| dampening trigger | z < −1 and Sleep < 50 | — | Tier 2 |
| missing-sleep penalty | 10 | points | Tier 1 |
| SpO₂ threshold / penalty | 95 / 10 | % / points | Post-composite |
| perceived blend | 0.70 / 0.30 | — | Unusable reading |
| snapshot timeout | 10 | s | Freeze |
| auto-refresh horizon | 18 | h | Eligible session |
| rescore total delta | 20 | min | Rescore gate |
| onset move | 15 | min | Update and rescore gate |
| end-later tolerance | 60 | s | Update gate |
| staging epoch | 5 | min | Sleep staging |
| epoch minimum points / valid | 10 / 8 | beats | Sleep staging |
| minimum epochs | 6 | epochs | Sleep staging |
| REM lockout | 60 | min | Sleep staging |
| thresholds awake / deep / REM | 0.80 / 0.60 / 0.63 | — | Sleep staging |
| deep prior | <0.4 → 1.0; <0.6 → 0.4; else 0.15 | — | Sleep staging |
| REM prior | >0.6 → 1.0; >0.35 → 0.25; else 0 | — | Sleep staging |
| fills | α1 median (0.85), LF/HF 2.0, HF 0 | — | Sleep staging |
| augmentation thresholds | 0.68 / 0.63 / 0.68 / 0.72 / 0.40 | — | Watch augmentation |
| resting-HR vitals penalty | 10 | points per SD | Vitals |
| respiratory-rate band / penalty | 1 / 15 | br/min / points per br/min | Vitals |
| respiratory-rate population window / below | 12–18 / 90 | br/min / points | Vitals |
| temperature bands | 0.3 / 0.5 / 1.0 → 100/75/50/25 | °C | Vitals |

---

## Appendix B: Pseudocode

```
function selectSource(S, I):
    if count(I) < 120: return count(S) >= 120 ? S : FAIL
    if count(S) < 120: return I
    pct = 100*|#I-#S| / max(#I,#S)
    if not (#I < #S and pct > 5): return I
    gaps = [(I[k-1].end, I[k].t) for k where I[k].t - I[k-1].end > I[k-1].rr + 2000]
    fill = [s in S where any gap contains (s.wall ?? s.t)]
    if gaps empty or fill empty: return S
    return mergeDedup(I, fill, tol=50ms)       // rebase fill.t := fill.wall

function mergeDedup(A, B, tol):
    i=j=0; out=[]
    while i<|A| or j<|B|:
        if j>=|B| or (i<|A| and A[i].t <= time(B[j])):
            out += A[i]; ta=A[i].t; i++
            while j<|B| and |time(B[j]) - ta| < tol: j++
        else:
            out += rebase(B[j]); tb=time(B[j]); j++
            while i<|A| and |A[i].t - tb| < tol: i++
    return out

function detectOnset(beats):
    if |beats| <= 300: return none
    W = [(mid.t, 60000/mean(validRR)) for 120-beat windows step 30 if >60 valid]
    if |W| <= 15: return none
    ceiling = max(W.hr) - 0.5*(max(W.hr)-min(W.hr))
    for j in 5 .. |W|-11:
        if mean(W[j-5..j-1].hr) - mean(W[j..j+9].hr) > 8 and mean(W[j..j+9].hr) < ceiling:
            return min(W[j].t, 20 min)
    return none

function dateUndated(rec):
    hk = HealthKitSleep(last 24h, rec.beats)
    if hk.start: return hk.start - (detectOnset(rec.beats) ?? 0)
    return now - duration(rec.beats)

function mapWallToBeat(offset, P):
    if P[0].wall is none: return offset
    target = P[0].wall + offset
    k = first index with P[k].wall >= target
    return (k exists ? P[k].t : P[last].t) - P[0].t

function isBreak(p, q):     // q follows p
    if q.t - (p.t + p.rr) > p.rr + 2000: return true
    if p.wall and q.wall: return q.wall - p.wall > q.rr + p.rr + 2000
    return false

function maskedRMSSD(vals /*(origIndex, rr) not flagged, valid*/, kept, breaks):
    d = [vals[k].rr - vals[k-1].rr for k
         if kept[k] and kept[k-1] and vals[k].idx == vals[k-1].idx+1 and vals[k].idx not in breaks]
    return d empty ? 0 : sqrt(mean(d^2))

function selectWindow(P, flags, sleepStart?, wake?, base?):
    if |P| < 120: return none
    s = max(0, map(sleepStart)) or 0
    e = wake ? (map(wake) > s ? min(map(wake), dur) : dur) : dur
    early = clampToRec(s + 0.3(e-s)); late = clampToRec(s + 0.7(e-s))
    band = [first t>=early .. last t<=late]; B = |band|
    size = B>=400 ? 400 : (B>=240 ? B/2 : max(60, 0.6B)); step = max(10, size/10)
    C = scan(band, size, step, cap=0.10)
    if C empty: C = scan(band, size, step, cap=0.15)
    if C empty: return none
    F = removeIsolatedSpikes(C, 1.5); cand = F empty ? C : F
    O = [w in cand where organized(w)]
    if O empty: return peakRMSSDFallback(...)        // flagged not organized
    if base: sort O by (Tier1(w.rmssd, w.meanHR, w.alpha1, base) desc, rmssd desc, pos desc)
    else:    sort O by (rmssd desc, pos desc)
    w = O[0]; w.consolidated = (w in F) and w.cv < 0.08
    return w

function evalWindow(win, cap):
    if flaggedFraction(win) > cap: reject
    vals = unflagged valid beats; if |vals| < 50: reject
    kept = localGate(vals.rr, neighbors=10 excluding self, 20%)
    if count(kept) < min(300, max(50, 0.75|win|)): reject
    rmssd = maskedRMSSD(vals, kept, breaksIn(win))
    cv = popSD(keptRR)/mean(keptRR); alpha1 = count(kept) >= 64 ? DFA(keptRR) : none
    return {rmssd, cv, alpha1, meanHR, pos}

organized(w) = w.alpha1 ? (0.75 <= w.alpha1 <= 1.0 and w.cv < 0.08) : w.cv < 0.08

function admit(session, result):
    return session.overnight and quality not in {insufficient, preSleep}
       and result.windowLen >= 5 min
       and (result.organized or session.duration >= 3 h)

function baselineStats(points, scoredNightKey):
    P = [p where nightKey(p) < scoredNightKey]        // leave-current-out
    if |P| < 3: return none
    R = last 60 of P; L = [ln p.rmssd for p in R if p.rmssd > 0]; if |L| < 3: return none
    w = |L| >= 7 ? 1 : sqrt(7/|L|)
    return {lnMean: mean(L), lnSD: max(sd(L)*w, 0.10),
            hrMean: mean(R.hr), hrSD: max(sd(R.hr), 0.5),
            cv7: |R|>=7 ? 100*cv(ln of last 7) : none, last: R.last.date}

function freeze(session, result, base, config):
    sleep, vitals = fetchWithTimeout(10s)
    vitals.restingHR = result.windowMeanHR ?? vitals.restingHR
    q = qualityDecision(result, sleep, base, session)
    inputs = q.useBaseline ? (exp(base.lnMean), base.hrMean, alpha1=none) : result
    bd = composite(inputs, sleep, vitals, base, ansBalance, referenceDate=session.end)
    if q.useBaseline and session.perceived:
        bd.HRV = 0.7*bd.HRV + 0.3*100*clamp(perceived)
        bd = recomposite(bd)        // same missing-sleep and SpO₂ tail
    bd.version = "v3.1.oct2026"
    store(session.score = bd.composite/10, bd, frozenReadiness)

function autoSleepRefresh():
    s = most recent overnight with end within 18h, already scored
    if s.sleepUserAdjusted and s.snapshot exists: return
    f = HealthKitSleep(s); if not plausible(f, s): return
    upd = first or endLater>60s or more minutes or onsetMove>=15 or sourceUpgrade
    if not upd: return
    apply(f -> snapshot AND scoring boundaries)        // fill-only if user-adjusted
    if (first or |delta|>=20 or onsetMove>=15 or sourceUpgrade) and not userAdjusted: rescore(s)

function stageNight(P, s, e):
    E = 5-min epochs in [s,e) with >=10 points and >=8 valid
    if |E| < 6: return none
    R = fractionalRanks(features(E), ties=mean, fill α1->median, lfhf->2, hf->0)
    for each epoch i: f = (mid_i - s)/(lastMid - s)
        deep, rem, awake = weighted sums per Section 3.9.3; if mid_i - s < 60 min: rem = 0
        stage_i = awake>0.80 ? AWAKE : deep>0.60 and deep>=rem ? DEEP : rem>0.63 and rem>deep ? REM : CORE
    for i in 1..n-2: if stage_i != AWAKE and stage_{i-1} == stage_{i+1} != stage_i: stage_i = stage_{i-1}
    return intervals(split on stage change or epoch gap)
```

---

## Appendix C: Source Map

**Table C.1.** Source files by method (repository paths).

| Method | Files (repository paths) |
|---|---|
| Source selection, gap fill, de-duplication | `Emuqu/Sources/Collection/DataSourceSelector.swift` |
| Undated recording dating | `Emuqu/Sources/Collection/RRCollector+DeviceRecording.swift`, `Emuqu/Sources/Analysis/SleepBoundaryResolver.swift` |
| HR sleep estimate | `Emuqu/Sources/Collection/HRSleepEstimator.swift`, `Emuqu/Sources/Services/MorningProcessingService+Sleep.swift` |
| Append-only backup | `Emuqu/Sources/Storage/RawRRBackup.swift`, `Emuqu/Sources/Storage/RawRRBackup+Streaming.swift` |
| Rescue before clear | `Emuqu/Sources/Collection/StrapStartSequence.swift` |
| Pause/resume merge | `Emuqu/Sources/Collection/RRCollector+PauseResume.swift`, `Emuqu/Sources/Collection/RRCollector+OvernightStreaming.swift` |
| Artifact classifier | `Emuqu/Sources/Analysis/ArtifactDetection.swift`, `Emuqu/Sources/Utilities/Constants.swift` |
| Recording break, masked RMSSD (reporting) | `Emuqu/Sources/Analysis/TimeDomainAnalysis.swift` |
| Window scan, evaluation, gates | `Emuqu/Sources/Analysis/WindowSelection.swift`, `Emuqu/Sources/Analysis/WindowSelection+Evaluation.swift`, `Emuqu/Sources/Analysis/WindowSelection+Filters.swift`, `Emuqu/Sources/Analysis/WindowSelection+Scoring.swift`, `Emuqu/Sources/Analysis/ScoredRecoveryBlock.swift` |
| DFA | `Emuqu/Sources/Analysis/DFAAnalysis.swift` |
| Pipeline entry | `Emuqu/Sources/Analysis/HRVAnalysisPipeline.swift`, `Emuqu/Sources/Services/MorningProcessingService+Analysis.swift`, `Emuqu/Sources/Collection/RRCollector+Analysis.swift` |
| Baseline | `Emuqu/Sources/Analysis/BaselineTracker.swift`, `Emuqu/Sources/Models/SleepSchedule.swift`, `Emuqu/Sources/Utilities/Constants+SleepAndDisplay.swift` |
| Recovery score | `Emuqu/Sources/Analysis/RecoveryScoreCalculator.swift`, `Emuqu/Sources/Analysis/RecoveryScoreCalculator+Tiers.swift`, `Emuqu/Sources/Analysis/RecoveryScoreCalculator+Composite.swift`, `Emuqu/Sources/Analysis/ScoreDetailBuilder.swift`, `Emuqu/Sources/Analysis/HRVThresholds.swift`, `Emuqu/Sources/Utilities/Constants+RecoveryScore.swift`, `Emuqu/Sources/Utilities/Constants.swift` (`ScoringWeights`) |
| Vitals | `Emuqu/Sources/Analysis/VitalsScoring.swift`, `Emuqu/Sources/Models/RecoveryVitals.swift` |
| Freeze and quality decision | `Emuqu/Sources/Services/SessionAcceptanceService.swift` |
| Version | `Emuqu/Sources/Analysis/ScoringVersion.swift` |
| Automatic refresh | `Emuqu/Sources/Collection/SleepRefreshPolicy.swift`, `Emuqu/Sources/Collection/RRCollector+Reanalysis.swift` |
| Cross-device merge | `Emuqu/Sources/Storage/CloudKitSyncSupport.swift`, `Emuqu/Sources/Storage/CloudKitSessionFreshness.swift`, `Emuqu/Sources/Storage/SessionMerger.swift` |
| Manual-window preservation | `Emuqu/Sources/Services/ReanalysisService.swift` |
| Sleep staging, Watch augmentation | `Emuqu/Sources/Analysis/HRVSleepStageClassifier.swift`, `Emuqu/Sources/Analysis/HRVSleepStageClassifier+Watch.swift`, `Emuqu/Sources/Utilities/Constants+SleepAndDisplay.swift` |
| Science register / reference data | `Tools/science_register/register.json`, `docs/hrv-reference-data.md` |
