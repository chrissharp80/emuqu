# EMUQU — Overnight Recovery Measurement from Raw Beat Intervals

**Sleep-anchored window selection, score-ranked windows, anti-ratchet baselines and frozen, versioned scores**

Technical White Paper • v1.1

v1.1 (2026-10-08): adds prior-art comparison, independent validation, and full provenance.

October 2026

Chris Sharp

Describes Emuqu at source revision e028039 (2026-10-07); scoring version v3.1.oct2026.

---

## Executive Summary

Emuqu is an iOS app that records a night of beat-to-beat (RR) intervals from a chest strap and turns them into one morning number, the recovery score. Most of the steps involved are textbook: RMSSD, the natural log of RMSSD, a rolling personal baseline, z-scores, DFA α1. What is not textbook is everything between the raw beats and that arithmetic. That includes which few minutes of an 8-hour night to measure, how to keep a noisy or short night from moving the baseline, how to assemble one clean series from two imperfect sources, and how to make sure a score shown at 07:00 is still the same score at 19:00 and can be attributed to the algorithm that produced it.

This paper describes those steps precisely enough to re-implement them. The main methods are:

1. **Source assembly.** The strap's internal recording is preferred. It is gap-filled from the Bluetooth stream only inside its own gaps, matched on the phone's wall clock and de-duplicated within 50 ms. An undated strap file is dated by aligning an RR-detected sleep onset to the HealthKit sleep start.
2. **Sleep-anchored window search.** The analysis window is searched only within 30–70% of *measured sleep*, not of the recording. The sleep boundaries are first translated from wall-clock time onto the beat timeline, which stalls during Bluetooth dropouts.
3. **Score-ranked window selection.** Candidate windows that pass artifact, clean-beat and stability gates are ranked by the *same* HRV sub-score function that produces the final score, against the *same* prior-nights baseline. This means the app never picks a window that scores worse than another eligible window under its own scoring rule.
4. **Anti-ratchet baseline.** Nights are admitted to the baseline on structural grounds only, the same way whether they land above or below the mean. Each night has exactly one slot, keyed by wake date. Each night is scored only against earlier nights.
5. **Frozen, versioned scores.** At acceptance the score, its breakdown and its inputs are frozen and stamped with a scoring-version string. Records with no stamp are labelled `unversioned`, not assumed current. Later automatic changes follow fill-only and bounded-upgrade rules.
6. **RR-only sleep staging** by within-night rank normalisation, and a conservative Apple Watch augmentation that overrides Watch stages only on strong evidence.

Section 4 states fourteen specific novelty statements, each with the closest public prior art found and the earliest dated form in the author's repositories. Section 5 reports validation. The time-domain arithmetic is checked on every build against 20 PhysioNet records. An independent Python reimplementation, verified against 114 of the app's unit-test cases, was run on PhysioNet data: the RR-only sleep staging agrees with polysomnography at near-chance level (Cohen's κ 0.07 on slpdb, 0.15 on CAP healthy controls), and the artifact handling reduces the median absolute error of 5-min RMSSD on ectopic-laden recordings to 3.2–4.7 ms but leaves wide limits of agreement. Window selection, the baseline rules and the composite score have no outcome validation.

---

## 1. The Problem

### 1.1 What an overnight RMSSD is supposed to be

The literature on HRV-guided training uses a resting, vagally mediated index, usually ln(RMSSD), measured under repeatable conditions. Each day's value is compared with a rolling personal baseline, and a change is called meaningful only beyond a "smallest worthwhile change" of about 0.5 SD [2][3][11]. RMSSD itself is defined over successive differences between *adjacent* normal-to-normal intervals [1].

Morning spot readings get repeatability from protocol (same time, same posture, same duration). An overnight recording has no protocol. It contains wake, light sleep, deep sleep, REM, arousals, position changes, strap shifts and, for a Bluetooth stream, dropouts. "The night's RMSSD" is not one number. It depends on which part of the night is measured.

### 1.2 Sources of error

| Source | Effect on the reported value |
|---|---|
| Whole-night averaging | Mixes wake and REM (lower RMSSD) with deep NREM (higher). The value tracks sleep architecture as much as recovery. |
| Fixed clock window (e.g. "first 4 h", "02:00–03:00") | Lands at a different sleep phase each night when bedtime or sleep onset varies. |
| Window chosen relative to the *recording* | Pre-sleep wake time and early removal shift the window. A recording started 90 min before sleep places "30%" in early-night wake. |
| Bluetooth dropouts | The beat-sum timeline (cumulative RR) stops advancing while wall time continues. Wall-clock sleep boundaries compared directly with beat-sum time land on the wrong beats. |
| Ectopic beats and missed detections | One compensatory pause can add tens of ms to RMSSD. On MIT-BIH recordings, uncorrected ectopy inflated 5-min RMSSD by a median of 32 ms (Section 5.2). |
| Artifact removal by array collapse | Dropping a bad beat and differencing the shortened array creates one spurious large difference per removed beat [1]. |
| Short windows | Short windows have the largest positive RMSSD sampling error. A rule that keeps them only when they are high biases the baseline upward. |
| Scoring a night against a baseline that contains it | Pulls the z-score toward 0. Kiviniemi et al. compare a day with *earlier* measurements [6]. |
| Late-arriving sleep data | Apple Watch sleep often reaches HealthKit after the morning score is computed. Without rules, the score silently changes later, or never benefits from the better data. |
| Algorithm changes | Re-tuning a scoring rule rewrites history unless scores carry a version. |

### 1.3 Why existing approaches are incomplete

The published methods define the statistics (Task Force [1]; ln(RMSSD) and SWC [2][3]; DFA [4]), the artifact detectors (Kubios-style median-deviation classification [5][10]) and the general idea of HRV sleep staging [13][14][15]. They do not define how to choose an analysis window from an unattended overnight recording, how to keep window choice consistent with a downstream score, how to protect a rolling baseline from selection bias, or how to manage score immutability across devices and late data.

Commercial products document their nocturnal windows only coarsely. Polar's Nightly Recharge uses roughly the first 4 h of sleep and compares it with the past 28 days [19][20]. WHOOP describes an HRV average weighted toward slow-wave sleep [21]; its patent measures HRV in the last sleep phase before waking [22], and an independent study could not reproduce a "last slow-wave sleep" window [23]. WHOOP compares against a 30-day baseline [21]. Oura reports the mean of all 5-min samples during sleep [24]. HRV4Training defines a 60-day normal range [27]. A study of runners compared sleep-onset, first-4-h and whole-night windows [30]. None of these sources gives a reproducible rule for window choice within a night, baseline admission, or score versioning (Section 6).

---

## 2. Architecture Overview

| Phase | Operation | Purpose |
|---|---|---|
| A. Capture | Stream RR over Bluetooth; strap records internally in parallel; append-only JSONL backup every 60 s | No single failure loses the night |
| B. Source selection | Prefer internal recording; gap-only composite with stream; date undated files | One continuous, correctly dated series |
| C. Segment merge | Time-shift resumed segments onto the parent's timeline and concatenate | One window search across a paused night |
| D. Artifact flags | Whole-series rolling-median classifier | Mark technical, extra, missed and ectopic beats |
| E. Sleep boundaries | HealthKit → RR heart-rate estimate → Watch passive-HR estimate → recording bounds | Anchor the search to sleep, not to the recording |
| F. Band mapping | Wall-clock boundaries → beat-sum timeline; 30–70% band → index range | Correct beats despite dropouts |
| G. Window scan | Adaptive window, two-pass artifact cap, local ectopic gate, masked RMSSD, DFA α1 | Candidate windows with honest metrics |
| H. Window selection | Spike filter → organized filter → rank by HRV sub-score vs prior-nights baseline | Window agrees with the score |
| I. Analysis | Time, frequency and nonlinear metrics on the chosen window | Reported values |
| J. Scoring | Tier 1/2/3 composite, adjustments, penalties | 0–100 recovery score |
| K. Freeze | Snapshot sleep/vitals, quality decision, compute, stamp version, archive | Stable, attributable score |
| L. Baseline update | Structural admission, one slot per night | Unbiased reference for later nights |
| M. Later events | Bounded automatic rescore; fill-only merges; user edits win | Late data used without silent drift |

```
 strap memory ─┐                                   HealthKit sleep ─┐
               ├─► B source select ─► C merge ─► D flags          ├─► E boundaries
 BLE stream ───┘        (gap fill)     (pause)      │              │
                                                    ▼              ▼
                                         F map band onto beat timeline
                                                    │
                    prior-nights baseline ─────► G scan ─► H select ─► I analyse
                    (leave-current-out)  │                               │
                                         └──────────────────────────► J score ─► K freeze ─► L baseline
```

---

## 3. Methods in Detail

Notation: each beat is `RRPoint{t_ms, rr_ms, wallClockMs?, hr?}`. `t_ms` is the beat's time on the recording's beat-sum timeline (cumulative RR). `endMs = t_ms + rr_ms`. `wallClockMs` is the phone's arrival time relative to session start, present on streamed beats only. A valid RR is `300 ≤ rr_ms ≤ 2000`.

### 3.1 Capture and source selection

**3.1.1 Parallel capture and backup.** During an overnight session the app streams RR over Bluetooth and, where the strap supports it (Polar H10), arms the strap's internal recording. Streamed beats are written to an append-only JSONL file: a header file at first write, then one JSON object per beat per line. Only beats beyond the stored count are appended. A flush is due when at least 60 s have passed since the last one, and it is forced on reconnect and lifecycle events. Files use a protection class that stays writable while the phone is locked. A failed append throws, and the beats remain buffered for the next interval.

**3.1.2 Strap rescue before clear.** Starting a strap recording requires clearing its memory, which is destructive. The start sequence is fixed as `[rescueExisting, clearExisting, beginRecording]`. The rescue step downloads any stored recording that a download ledger says the app does not already hold and hands it to the backup. If that download fails, the start is aborted instead of clearing. A test asserts the invariant "rescue precedes clear" for every strap type.

**3.1.3 Source selection.** Inputs are the streamed points `S` and the internal points `I` (possibly absent).

1. A source is *valid* if it has ≥ 120 beats.
2. If `I` is invalid: use `S` if valid ("streaming (internal failed)"), else fail.
3. If `I` is valid and `S` is invalid: use `I`.
4. If both are valid, compute `diff = |#I − #S|` and `pct = 100·diff / max(#I, #S)`. If `#I < #S` and `pct > 5`, go to step 5. Otherwise use `I` (preferred).
5. **Gap detection on `I`.** For consecutive internal beats `prev, next`, a gap exists when `next.t_ms − prev.endMs > prev.rr_ms + 2000`. The gap spans `[prev.endMs, next.t_ms]`.
6. **Gap fill.** Select streamed beats whose effective time `wallClockMs ?? t_ms` lies inside any gap (inclusive). Streamed `t_ms` is not used because it lags after Bluetooth packet loss. If there are no gaps, or no streamed beat falls in any gap, the composite fails.
7. **Merge.** Two-pointer merge of `I` with the gap-fill beats, ordered by `I.t_ms` versus the streamed beat's effective time. When an internal beat is emitted, *all* following streamed beats within `|Δ| < 50 ms` of it are skipped, and vice versa (cluster-aware de-duplication). Emitted streamed beats have `t_ms` rewritten to `wallClockMs`.
8. If the composite fails, use `S` (the larger set), not `I`.

Only gap-interior streamed beats are merged. The phone's arrival clock rarely falls within 50 ms of the strap's own beat times, so merging the whole stream would duplicate most of the night.

**3.1.4 Dating an undated strap recording.** When a downloaded strap recording has no start time and no live, persisted or uniquely recoverable session claims it:

1. Query HealthKit sleep for the 24 h ending now, passing the recording's beats.
2. If HealthKit reports a sleep start `T_hk`, detect the sleep onset inside the beats (below) as `onsetMs` (0 if none).
3. Recording start = `T_hk − onsetMs`.
4. With no HealthKit sleep, recording start = `now − duration(beats)`.

*RR sleep-onset detector (adaptive ceiling):*

1. Require > 300 beats.
2. Slide a 120-beat window in 30-beat steps. For each window, keep beats with valid RR. If more than half are valid, record `HR = 60000 / mean(validRR)` at the window's middle beat time.
3. Require > 15 windows.
4. `ceiling = maxHR − 0.5·(maxHR − minHR)` over this night's windows (midpoint of the night's own HR range).
5. For `j` from 5 to `count − 11`: `before = mean(HR[j−5..j−1])`, `after = mean(HR[j..j+9])`. The first `j` with `before − after > 8 bpm` and `after < ceiling` is the onset.
6. Clamp the onset to ≤ 20 min, the plausible sleep-onset latency for a recording started at bedtime [17].

A fixed ceiling such as 65 bpm fails for anyone whose sleeping HR sits above it and has no effect for athletes. The midpoint of the night's own range adapts to each person.

### 3.2 Pause/resume concatenation

A user may pause an overnight recording (for example, on waking briefly) and resume it. A pause archives a paused session, analysed if it has enough beats and stored raw otherwise. A resume creates a child session linked to the parent. At the next pause or stop, the child's beats are merged with the parent:

1. `offsetMs = child.startDate − parent.startDate`. If `offsetMs ≤ 0` or the value cannot be represented, the merge is refused and the child is analysed alone.
2. Every child beat gets `t_ms += offsetMs` and `wallClockMs += offsetMs`.
3. Merged series = parent beats followed by shifted child beats. Session start = parent start.

The parent already carries its own parent's beats, so a chain of pauses yields the whole night in one series. The pause interval becomes a recording break (Section 3.3.3), so no successive difference is taken across it. Window selection (Section 3.5) then runs once over the whole night.

### 3.3 Artifact handling

All artifact handling *drops* beats. Nothing is interpolated.

**3.3.1 Whole-series classifier.** For each beat, compute the median of a centred window of up to 51 RR values (±25 beats, including the beat itself, truncated at the ends). With `m` = median and `r` = rr_ms:

| Condition (evaluated in order) | Flag |
|---|---|
| `r < 300` or `r > 2000` | technical artifact |
| `r < 0.5·m` | extra beat |
| `0.5·m ≤ r < 0.7·m` | ectopic |
| `r > 1.5·m` | missed beat |
| `1.2·m < r ≤ 1.5·m` | ectopic |
| `|r − m| / m > 0.20` (covers `0.7·m ≤ r < 0.8·m`) | ectopic |
| otherwise | clean |

The ectopic band is symmetric at 20%. A post-ectopic compensatory pause (20–50% long) is explicitly flagged.

**3.3.2 Per-window local ectopic gate.** Inside each candidate window, the artifact-free, range-valid RR values are listed in order. Each value is kept if `|r − med| / med ≤ 0.20`, where `med` is the median of up to 10 neighbours (5 before and 5 after in that list, **excluding the beat itself**, so a wild value cannot pull its own reference). If the window has ≤ 10 values, every beat is kept. The reported time-domain metrics apply the same gate, so the selector and the report agree.

**3.3.3 Masked RMSSD with recording breaks.** A *recording break* separates beat `i` from beat `i−1` when either

- `t_i − endMs_{i−1} > rr_{i−1} + 2000`, or
- both have wall clocks and `wall_i − wall_{i−1} > rr_i + rr_{i−1} + 2000`.

RMSSD is the root mean square of `rr_k − rr_{k−1}` over pairs where (a) both beats are kept by every gate, (b) their *original* series indices are consecutive, and (c) beat `k` does not follow a break. When no pair qualifies the value is 0 (selection) or missing (reporting). In reporting only, if the ectopic gate leaves no pair, artifact-clean adjacent pairs are used without it.

### 3.4 Sleep boundaries and the search band

**3.4.1 Boundary sources.** On the morning path, boundaries come from, in order:

1. HealthKit sleep for the recording, fetched with the RR series so the HealthKit layer can cross-check it.
2. If HealthKit gives no start: an RR heart-rate estimate. Take 5-min HR windows (≥ 10 beats each) and set `threshold = maxHR − 0.5·(maxHR − minHR)`. Onset is the first of three consecutive windows below the threshold, clamped to ≤ 20 min. Wake is the window after the last window below the threshold.
3. If no sleep data was obtained at all: an estimate from Apple Watch passive HR samples (same midpoint rule, two consecutive points, ≥ 8 bpm range required).
4. Otherwise: recording start and end.

A negative onset is clamped to 0. HealthKit/HR reconciliation, where used, lets HR move the onset earlier freely. HR can move it later only when HealthKit has no detailed stages, and only by more than 15 min. HR can only extend the wake time.

**3.4.2 Wall-clock to beat-timeline mapping.** Boundaries arrive as wall-clock offsets from session start. The scan is indexed on `t_ms`, which stalls across dropouts. Mapping: if the first beat has no wall clock (strap internal recording, which has no gaps), the offset is used unchanged. Otherwise, find the first beat with `wallClockMs ≥ firstWall + offset` and return `that.t_ms − first.t_ms`, or the last beat's offset if none qualifies.

- `sleepStart = max(0, map(sleepStartMs))`, or 0 if absent.
- `sleepEnd = min(map(wakeMs), recordingDuration)` if it is later than `sleepStart`, else `recordingDuration`.

**3.4.3 Band.** `early = sleepStart + 0.30·(sleepEnd − sleepStart)`, `late = sleepStart + 0.70·(…)`, clamped to the recording's first and last `t_ms`. The band's index range runs from the first beat with `t_ms ≥ early` to the last beat with `t_ms ≤ late`. A series under 120 beats, or an empty band, yields no window.

Rationale: the early third of sleep is dominated by deep-NREM peaks and the last third by REM and arousals. The middle 40% of *measured sleep* is the most repeatable region from night to night when bedtime, onset and wake vary.

### 3.5 Window selection

**3.5.1 Adaptive geometry.** With `B` beats in the band:

- `size = 400` if `B ≥ 400`; else `B/2` if `B ≥ 240`; else `max(60, ⌊0.6·B⌋)`.
- `step = max(10, ⌊size/10⌋)`, so 40 beats for a 400-beat window.

Windows are `[e − size, e)` for `e = bandStart + size, bandStart + size + step, …, ≤ bandEnd`. A 400-beat window is about 6–7 min at 60 bpm.

**3.5.2 Per-window evaluation.** For each window:

1. `artifactRate = (#flagged) / size`. Reject if above the current pass limit (Section 3.5.3).
2. Valid values = beats that are not flagged and are range-valid. Reject if fewer than 50.
3. Apply the local ectopic gate (Section 3.3.2). Reject if `clean < min(300, max(50, ⌊0.75·size⌋))`.
4. `RMSSD` = masked RMSSD (Section 3.3.3). `meanRR` and `SDNN` (population, divisor N) are taken over clean beats, and `CV = SDNN / meanRR`.
5. `meanHR` = 5–95% trimmed mean of sensor HR values if ≥ 10 are present, plain mean if fewer, else `60000 / meanRR`.
6. DFA α1 [4] on the clean beats if there are ≥ 64: integrate, use box sizes 4–16 log-spaced by 2^(1/8), apply linear detrend per box, and take the slope of log F(n) against log n.
7. `relativePosition = (midpoint t_ms − sleepStart) / (sleepEnd − sleepStart)`.
8. LF/HF is **not** computed per window. The field is always empty (see 3.5.4).

**3.5.3 Two-pass artifact cap.** Scan the band with a 10% artifact cap. Only if that yields **zero valid windows** of any kind, rescan with 15%.

**3.5.4 Spike filter and organized filter.**

1. *Isolated spike.* Window `i` (not first or last) is a spike if both neighbours have RMSSD > 0 and `RMSSD_i ≥ 1.5·RMSSD_{i−1}` and `RMSSD_i ≥ 1.5·RMSSD_{i+1}`. Spikes are removed. If removal leaves nothing, the unfiltered list is used.
2. *Organized.* With α1 available: `0.75 ≤ α1 ≤ 1.0` **and** `CV < 0.08`. With α1 unavailable: `CV < 0.08`. (The code also contains an alternative rule, "α1 in range and (LF/HF ≤ 1.5 or CV < 8%)", for windows that carry an LF/HF value. The production selector never supplies one, so that alternative is dormant and CV < 8% is always required. LF/HF is not treated as a sympathovagal measure in any case [7].)

"Organized" names a quiet, stable stretch that makes a good measurement window. It is not a claim about autonomic state.

**3.5.5 Ranking by the scoring function.** Let `base` be the leave-current-out baseline for this night (Section 3.6.4).

- If `base` exists, each organized window gets `s = Tier1(rmssd, meanHR, α1, base)` (Section 3.7.2, with no ANS-balance term and no legacy readiness). Sort by `s` descending, then RMSSD descending, then relative position descending (later wins).
- If no baseline exists, sort by RMSSD descending, then relative position descending.
- The first window is selected. It is marked *consolidated* if it survived the spike filter and `CV < 0.08`.

Rationale: the score is not monotone in RMSSD. The z-mapping is flat for −0.5 ≤ z ≤ +0.5 and flat again above z = +1.5. The resting-HR and α1 adjustments (±10 and +5/−3/−5 points) are window-specific. Picking the highest RMSSD can therefore pick a window that scores lower than another eligible window under the app's own rule. A logged example on one night was RMSSD 53 scoring 80 against RMSSD 45 scoring 85. Ranking with the same function and the same baseline makes window choice and score consistent by construction.

**3.5.6 Fallbacks and peak capacity.**

- If no organized window exists, a *peak-RMSSD fallback* runs over the same band: the same two-pass scan and spike filter, then the window with maximum RMSSD. Its `isOrganized` flag is its own classification, which is false in practice because the same windows have already failed the organized test.
- If even that yields nothing, the whole session is analysed and marked not organized.
- *Peak capacity* is computed independently over the entire recording, not the band. It uses a compact window rule (`400` if `B ≥ 400`; else `B/3` if `B ≥ 360`; else `max(60, ⌊0.4·B⌋)`), the 15% artifact cap, the spike filter, and no organization filter, and it reports the maximum-RMSSD window. It is shown to the user but is not scored.

### 3.6 Baseline

**3.6.1 Admission (three gates, in order).**

1. Session type is overnight.
2. Data quality is not `insufficient` and not `preSleep` (Section 3.8.3).
3. *Structural soundness:* the analysis window lasts ≥ 300 000 ms (5 min), **and** the window is organized **or** the session lasts ≥ 10 800 s (3 h).

Gate 3 deliberately ignores the direction of the reading. The display path treats a short window differently depending on whether it lands above or below baseline (Section 3.8.3), because a brief clean high reading is still worth showing. For aggregation, that asymmetry is a ratchet. Short windows have the largest positive sampling error. Admitting the high ones and rejecting the low ones raises `lnRmssdMean`, every later night scores lower against it, and the correcting samples are exactly the ones being excluded. Admission is therefore symmetric: a 4-minute window is not baseline-quality whichever side of the mean it falls on.

**3.6.2 One slot per night.** The night key is the calendar date of the first expected wake after the night's overnight window opens (from the user's sleep schedule). A 23:30 start and its 00:30 continuation share a key. If the key is new, the point is appended. Otherwise the newcomer replaces the incumbent only if:

1. **Morning reading.** If exactly one of the two ended inside the morning window, the morning reading wins.
2. **Consolidation.** If the incumbent is consolidated and the newcomer is not, the newcomer's readiness must exceed the incumbent's by more than 15%. If the newcomer is consolidated and the incumbent is not, the newcomer wins if its readiness is ≥ 90% of the incumbent's.
3. **Organized** (consolidation equal). An organized incumbent beats an unorganized newcomer. An organized newcomer wins if its readiness is ≥ 95% of the incumbent's.
4. **Quality gates.** Reject if the newcomer's artifact % exceeds `max(1.5 × incumbent's, 2.0)`, or its window CV exceeds `1.3 ×` the incumbent's.
5. **Improvement.** Replace only if readiness improves by more than 5% of the incumbent's.

Missing values default to 0 (readiness), false (flags) and 100% (artifacts). Up to 90 points are stored, sorted by date.

**3.6.3 Statistics.** Take the 60 most recent stored *nights* (a count, not calendar days). Require ≥ 3 points and ≥ 3 positive RMSSD values.

- `lnMean = mean(ln RMSSD)`.
- `lnSD = max(sampleSD(ln RMSSD) · w, 0.10)`, with `w = 1` if `n ≥ 7`, else `w = √(7/n)` (≈ 1.53 at n = 3).
- `hrMean`, `hrSD = max(sampleSD(meanHR), 0.5)`.
- `CV7 = 100 · CV(ln RMSSD of the last 7 points)` if ≥ 7 points (≥ 3 positive), else none.
- `lastDate` = date of the most recent point.

The widening keeps early z-scores near zero until the spread can be trusted, without withholding a score for the first week. The 0.10 floor reflects the documented 5–10% day-to-day noise of overnight RMSSD, so a stable user's trivial −8% night is not scored as a −8 SD event.

**3.6.4 Leave-current-out.** To score a night, only points whose night key is strictly earlier than the scored night's key are used. Re-scoring an old night therefore never reads later nights. On the live morning path this means every stored night except tonight. The same statistics feed window ranking (Section 3.5.5) and the final score.

### 3.7 Recovery score (v3.1.oct2026)

**3.7.1 z-mapping.** `z = (ln RMSSD − lnMean) / lnSD`, mapped piecewise-linearly through:

| z | −3.0 | −1.5 | −0.75 | −0.5 | +0.5 | +1.5 |
|---|---|---|---|---|---|---|
| score | 5 | 25 | 64 | 72 | 72 | 90 |

Values below −3 map to 5 and values above +1.5 map to 90. NaN maps to 50. The flat region from −0.5 to +0.5 is the smallest-worthwhile-change deadband [2][3]. The steeper slope below baseline reflects that a drop is actionable while a rise is ambiguous.

**3.7.2 Tier-1 HRV sub-score.** With a baseline and RMSSD > 0:

```
T1 = map(z)
   + clamp(−5 · (meanHR − hrMean)/hrSD, −10, +10)                  // resting HR
   + α1 term: +5 if 0.75 ≤ α1 ≤ 1.0; −5 if α1 > 1.2; −3 if α1 < 0.60; else 0
   + CV7 term: −5 if CV7 < 2%; −3 if CV7 > 12%; else 0
   + ANS term (PNS − SNS): −6 if < −1.5; −3 if < −0.5; +2 if ≥ +1.5; else 0
   − staleness: if d = days(lastDate → referenceDate) ≥ 7: min(20, 5·(1 + (d−7)/7))
T1 = clamp(T1, 0, 100)
```

Without a baseline: the legacy readiness (1–10) × 10 if present. Otherwise absolute RMSSD bands: ≥ 60 → 85, ≥ 45 → 70, ≥ 30 → 55, ≥ 20 → 40, else 25. With no RMSSD the score is 50.

**3.7.3 Tiers.** The vitals sub-score is computed first (Section 3.10). The sleep sub-score comes from the sleep analyser when sleep integration is on.

| Tier | Inputs present | Composite |
|---|---|---|
| 3 | sleep and vitals | `0.60·T1 + 0.25·Sleep + 0.15·Vitals`; comeback mode `0.80/0.20/0.00` |
| 2 | sleep only | `0.70·T1 + 0.30·Sleep`; if `z < −1` **and** Sleep < 50: `0.85/0.15` (double-penalty dampening) |
| 1 | neither | `T1` |

Comeback mode is active for 21 days from the date the user sets it. In Tier 3 the vitals factor is still shown, with weight 0. Tier 2 dampening keeps a bad-sleep night from being penalised twice, once through the HRV drop it usually causes and once through the sleep factor.

**3.7.4 Final composite.**

1. Missing sleep: in Tier 1, if sleep integration is on, the user has opted into the penalty and there is no sleep data, subtract 10.
2. Clamp to 0–100.
3. SpO₂: if a reading exists and is < 95%, subtract a flat 10 and floor at 0. This is a conservative product rule, not a clinical threshold.

Every deduction is listed in the breakdown.

**3.7.5 Training load is excluded.** Training-load metrics (acute:chronic ratio, monotony, strain) are accepted by the scoring API but not read. Day-to-day ACWR has been shown to carry little signal beyond its acute term [8]. A separate training-readiness value is frozen alongside the score and is described in another paper.

### 3.8 Score freezing

**3.8.1 Snapshot.** At acceptance, sleep (for the whole overnight window of the night the session belongs to) and vitals are fetched together with a 10-s timeout. On timeout, scoring proceeds without them. In the vitals snapshot, the **strap's analysis-window mean HR replaces HealthKit's daytime resting HR**, so the vitals HR is compared like-for-like with the baseline's `hrMean`, which is built from the same nocturnal quantity.

**3.8.2 Inputs.** RMSSD, meanHR and α1 from the selected window. ANS balance = PNS index − SNS index. Baseline = leave-current-out stats. **Reference date = session end**, not the wall clock, so the staleness term is identical whenever the score is recomputed.

**3.8.3 Quality decision.** Let `base = exp(lnMean)` (0 if no baseline), `dur` = session length and `win` = analysis-window length (session length if there is no window). The rules are evaluated in order:

1. If (`win < 5 min` or (`not organized` and `dur < 3 h`)) **and** `RMSSD < base`: quality `insufficient`, use the baseline.
2. If sleep data exists and the recording does not overlap it: quality `preSleep`, use the baseline. This applies regardless of RMSSD direction.
3. If `RMSSD < base` and `dur < 3 h`: quality `insufficient`, use the baseline.
4. Otherwise quality `good`. A long night below baseline is a real bad night.

Rules 1 and 3 are asymmetric: a short reading is replaced only when it is low. This affects *display*. Baseline admission (Section 3.6.1) is separately symmetric.

**3.8.4 Unusable-reading blend.** "Use the baseline" means scoring with `RMSSD = exp(lnMean)`, `meanHR = hrMean`, no α1 and no readiness, so T1 lands near 72 less any CV or staleness deduction. If the user has answered the subjective readiness prompt (p ∈ [0, 1], clamped), the HRV factor becomes `0.70·T1 + 0.30·(100·p)`. The composite is rebuilt through the same tail as step 3.7.4, so the missing-sleep and SpO₂ deductions still apply.

**3.8.5 What is stored.** `recoveryScore` (composite / 10), `scoreBreakdown` (composite, tier, factors, penalties, SpO₂ flag and `scoringVersion = "v3.1.oct2026"`) and the frozen training readiness. A breakdown decoded without a version field is labelled **`unversioned`**, never assumed to be the current version, because the archive cannot tell which earlier algorithm produced it.

**3.8.6 Mutation rules.**

- *User edits win.* Bulk reanalysis skips sessions whose analysis window the user picked by hand. Automatic sleep refresh never overwrites a sleep snapshot the user has edited. On a second device, where the cloud copy arrives without a snapshot, it may *fill* the snapshot but keeps the user's boundaries and does not rescore.
- *Automatic paths fill, not overwrite.* Pulled-session sleep boundaries are set only where they are missing. An imported duplicate adopts a recovery score only when the existing record has none.
- *Bounded automatic upgrade.* When HealthKit sleep changes, only the most recent overnight session that ended within the last 18 h and has already been scored is considered. Runs are serialised: overlapping triggers collapse into one trailing pass. The fresh sleep must plausibly overlap the recording. The snapshot is updated if this is the first snapshot, the end moved later by more than 60 s, total minutes increased, the onset moved by ≥ 15 min, or the boundary source upgraded from an estimate (HR, Watch HR or recording bounds) to HealthKit or HR-validated HealthKit. A **rescore** follows only for a first snapshot, a total change of ≥ 20 min, an onset move of ≥ 15 min, or a source upgrade. The scoring boundaries are updated with the snapshot so the rescore uses the new window.
- *Cross-device.* The score, breakdown (with version) and frozen readiness travel inside one encrypted session payload. The newer copy (by whole-second modification stamp) replaces the older as a unit, after which only locally held HealthKit readings are restored.

### 3.9 RR-only sleep staging

**3.9.1 Epochs and features.** Between sleep start and end, cut 5-min epochs on the beat timeline. An epoch needs ≥ 10 beats and ≥ 8 range-valid RRs, otherwise it is dropped. Per epoch: HR = 60000 / mean RR, RMSSD, population SDNN, CV = SDNN / mean RR, α1 (if ≥ 64 beats), and LF/HF and HF power from the shared spectral routine over spline-resampled beats.

**3.9.2 Within-night rank normalisation.** Each feature is replaced by its fractional rank across the night's epochs, from 0 (lowest) to 1 (highest), with ties given the mean rank. Missing values are filled before ranking (α1 → the night's median α1 or 0.85; LF/HF → 2.0; HF → 0), so a night with no α1 gives every epoch 0.5. Ranking makes the classifier scale-free: it never compares a feature with an absolute threshold, so it adapts to each person and each sensor.

**3.9.3 Scores.** `f` = night fraction of the epoch midpoint. Temporal priors: deep `T_d = 1.0` if `f < 0.4`, `0.4` if `f < 0.6`, else `0.15`. REM `T_r = 1.0` if `f > 0.6`, `0.25` if `f > 0.35`, else `0`. Writing `r_x` for the rank of feature x:

| Variant (by availability across the night) | Deep score weights on (1−r_hr, r_rmssd, 1−r_cv, r_hf, 1−r_lfhf, 1−r_α1, T_d) | REM score weights on (1−r_rmssd, r_cv, r_lfhf, 1−r_hf, r_α1, T_r) |
|---|---|---|
| LF/HF and α1 | .12, .10, .08, .15, .18, .22, .15 | .10, .10, .24, .12, .26, .18 |
| LF/HF only | .15, .13, .10, .18, .24, —, .20 | .12, .12, .30, .18, —, .28 |
| α1 only | .18, .18, .12, —, —, .32, .20 | .16, .16, —, —, .38, .30 |
| time-domain only | .25, .25, .15, —, —, —, .35 | .32, .43, —, —, —, .25 |

Awake score: with LF/HF, `.30·r_hr + .25·(1−r_rmssd) + .15·r_cv + .20·r_lfhf + .10·(1−r_hf)`. Without, `.35·r_hr + .30·(1−r_rmssd) + .20·r_cv + .15·r_α1`. The REM score is forced to 0 in the first 60 min after sleep start.

**3.9.4 Decision and smoothing.** Awake if `awake > 0.80`. Otherwise deep if `deep > 0.60` and `deep ≥ rem`. Otherwise REM if `rem > 0.63` and `rem > deep`. Otherwise core. Then, left to right, any non-awake epoch whose previous and next epochs agree on a different stage takes that stage. Awake epochs are never smoothed away.

**3.9.5 Intervals.** Consecutive same-stage epochs form an interval. A dropped epoch (a gap) also ends the interval, so a strap dropout is never counted as sleep.

**3.9.6 Watch augmentation.** When Apple Watch stages exist, the Watch is the anchor. Each RR epoch takes the Watch stage covering most of it. Epochs the Watch does not cover are left alone. Overrides:

| Watch stage | Override when | To |
|---|---|---|
| core / unspecified | deep > 0.68 and deep > rem | deep |
| core / unspecified | LF/HF present, rem > 0.63, rem > deep | REM |
| awake | LF/HF present, rem > 0.68, awake < 0.80 | REM |
| deep | LF/HF present, rem > 0.72, deep < 0.40 | REM |
| REM | deep > 0.72, rem < 0.40 | deep |

Only the part of each Watch interval that carries the overridden stage, inside the overridden epoch, is repainted and tagged as HRV-derived. All other Watch timing is kept and no smoothing touches Watch stages. REM overrides need LF/HF because time-domain features separate REM from N2 poorly [15].

### 3.10 Vitals sub-score

The vitals sub-score is the mean of whichever sub-scores exist. A missing input is dropped, not penalised. Every rule penalises in one direction only.

| Input | Sub-score |
|---|---|
| Sleep HR (strap window mean HR, Section 3.8.1) | `max(0, 100 − 10·max(0, (HR − hrMean)/hrSD))`. Requires a baseline. At or below baseline scores 100. |
| Respiratory rate with a 7-night baseline | `max(0, 100 − 15·max(0, (rate − baseline) − 1))`. Below baseline scores 100. |
| Respiratory rate without a baseline | 100 within 12–18 br/min; above 18: `100 − 15·(rate − 18)`, floor 0; below 12: 90 |
| Wrist temperature (deviation from the user's own baseline; dropped if there is no baseline) | ≤ +0.3 °C → 100; ≤ +0.5 → 75; ≤ +1.0 → 50; above → 25. Cooler than baseline scores 100. |

With no inputs, vitals is absent and the tier falls back. SpO₂ is not a factor (Section 3.7.4).

---

## 4. What Is New

Each statement below names only the part of the method that survived a prior-art search on 2026-10-08. The search covered patents, vendor support pages and white papers, peer-reviewed and preprint literature, clinical-trial protocols and open-source HRV code. Each statement refers to the exact rules in Section 3. "Closest prior art" names the overlapping public work. "Earliest dated form" gives the first commit in the author's private repository lineage (Section 7) that contains the method, and the commit that completed its current form when the two differ. Repository abbreviations: *old* = flow-recovery-old, *dev* = flow-recovery-dev, *fr* = flow-recovery, *edev* = emuqu-dev, *emuqu* = the public repository.

- **N1.** Building an overnight RR series by preferring a chest strap's internal recording and adding Bluetooth-streamed beats only when the internal file is more than 5% shorter. Streamed beats are added only inside internal gaps (next start − previous end > previous RR + 2000 ms), are matched on the phone's arrival clock rather than their own drifting beat-sum time, and are de-duplicated cluster-wise within 50 ms. If no gap can be filled, the stream is used rather than the shorter internal file.
  Closest prior art: the Polar H10 stores about 20 h of RR in internal memory as one session [18][40]; no public tool found merges it with the live stream.
  Earliest dated form: old aeaf0db, 2026-01-18 (5% rule and gap rule, matched on beat-sum time, no de-duplication). Current form: emuqu 554540f, 2026-10-03 (gap-interior-only insertion; 50 ms de-duplication dev c48eeb9 2026-03-01, cluster tolerance fr cc7c53e 2026-04-18, arrival-clock matching edev 680bbee 2026-08-25).

- **N2.** Dating a chest-strap recording that carries no start time by subtracting an RR-detected sleep onset from the HealthKit sleep start. The onset is the first sustained drop of more than 8 bpm (5-window versus 10-window means over 120-beat windows) into the lower half of that night's own HR range, clamped to 20 min.
  Closest prior art: sleep-onset detection from heart-rate change points, evaluated against polysomnography [31]; none of the sources found uses an onset to date a recording.
  Earliest dated form: old 577b937, 2026-01-14 (same back-dating and detector with a fixed 65 bpm ceiling). Current form: fr 24d2017, 2026-08-06 (adaptive midpoint ceiling; 20-min clamp fr 206870b 2026-08-05).

- **N3.** Placing the analysis-window search band at 30–70% of *measured sleep*, after translating wall-clock sleep boundaries onto the recording's beat-sum timeline through each beat's arrival timestamp, so the band lands on the correct beats across Bluetooth dropouts. (Measuring within a sub-band of the night is public: Polar's first ~4 h [19], WHOOP's last sleep phase [22], and the windows compared in [30]. The author's own article of 2026-05-19 disclosed the 30–70%-of-sleep band publicly; the arrival-clock mapping was not disclosed.)
  Closest prior art: [19][22][30].
  Earliest dated form: old 985cefe, 2026-01-13 (30–70% of the recording); anchored to measured sleep in old 0a86767 the same day. Current form: fr 8814c54, 2026-07-21 (wall-clock to beat-sum mapping).

- **N4.** A candidate-window scan whose size adapts to the beats available in the band (400; else half the band if ≥ 240; else 60% with a floor of 60) with a step of max(10, size/10), a 10% artifact cap relaxed to 15% only when the strict pass yields no window at all, and a clean-beat floor of min(300, max(50, 0.75 × size)). (Scanning or selecting segments under an artifact-share limit is public [32][33].)
  Closest prior art: valid-interval share thresholds per 5-min segment in an Oura validation study [32]; a clinical protocol that averages three 5-min periods [33].
  Earliest dated form: old 090f9c4, 2026-01-19 (same sizing and step, single 15% cap). Current form: fr a02e903, 2026-05-04 (strict 10% pass before 15%; clean-beat floor dev c48eeb9 2026-03-01).

- **N5.** Using one masked RMSSD estimator for both window selection and reporting. It takes differences only between beats that were adjacent in the original series, survived both a whole-series classifier and a self-excluding 10-neighbour 20% median gate, and are not separated by a recording break defined on both the beat timeline and the arrival clock. (The adjacency requirement itself is in [1] and is not claimed.)
  Closest prior art: deletion-based RR editing [34]; Task Force adjacency [1].
  Earliest dated form: old e5948bd, 2026-01-12 (whole-series flags and the self-excluding 10-neighbour gate; RMSSD on the collapsed array). Current form: emuqu 5c4a23d, 2026-10-04 (recording breaks; shared estimator edev 680bbee 2026-08-25).

- **N6.** Selecting among windows that are not isolated spikes (≥ 150% of both neighbours' RMSSD, with the unfiltered list kept if filtering removes everything) and are "organized" (DFA α1 in 0.75–1.0 and HR coefficient of variation < 8%, or the CV test alone when α1 is unavailable). (The author's article of 2026-05-19 disclosed α1-based "organized windows" publicly, without the thresholds.)
  Closest prior art: selection of the "256 most stable points" of a recording [35].
  Earliest dated form: old 2bf168f and a695a90, 2026-01-14 (same spike filter; organized was α1 in range and (LF/HF ≤ 1.5 or CV < 8%)). Current form: dev c48eeb9, 2026-03-01.

- **N7.** Ranking candidate analysis windows by the same HRV sub-score function that produces the final recovery score: z-mapping with a flat deadband plus resting-HR and α1 adjustments. The ranking is computed against the same leave-current-out personal baseline, ties are broken by RMSSD and then by later position, and the method falls back to RMSSD ranking only when no baseline exists.
  Closest prior art: none found in a search of vendor documentation, patents, the HRV literature and open-source HRV tools. (The author's article of 2026-05-19 described the earlier rule, highest RMSSD in the band.)
  Earliest dated form: fr be64931, 2026-04-17 (with the position tie-break, fr a1eb5bc, same day). Current form: emuqu 554540f, 2026-10-03 (leave-current-out baseline).

- **N8.** Reporting a peak-RMSSD fallback window, flagged not organized, when no organized window exists, alongside an independently computed whole-recording "peak capacity" that is displayed but never scored.
  Closest prior art: none found in a search of vendor documentation, patents, the HRV literature and open-source HRV tools.
  Earliest dated form: old c32a6e3, 2026-01-14 (peak capacity). Current form: dev c48eeb9, 2026-03-01 (peak-RMSSD fallback window).

- **N9.** Admitting nights to a rolling ln(RMSSD) baseline by a direction-independent structural test (window ≥ 5 min, and organized or session ≥ 3 h), while the display-side quality rule remains direction-dependent, specifically to prevent short high readings from ratcheting the baseline upward.
  Closest prior art: outlier filtering (Athlytic) and 7-day averaging (HRV4Training) in consumer-app documentation, seen only as search extracts; neither states an admission rule.
  Earliest dated form: fr 870028e, 2026-04-05 (same 5 min / 3 h constants, direction-dependent). Current form: edev 680bbee, 2026-08-25 (direction-independent).

- **N10.** Holding one baseline slot per night keyed by the wake date of the user's sleep schedule, with an ordered replacement rule: morning reading, then consolidation (15% / 90%), then organized (95%), then artifact and CV quality ceilings, then a 5% improvement.
  Closest prior art: none found in a search of vendor documentation, patents, the HRV literature and open-source HRV tools.
  Earliest dated form: old 52d6267, 2026-01-22 (same ordered rule, calendar-day slot; morning = before 10:00 from old abf91d6, 2026-01-18). Current form: emuqu 554540f, 2026-10-03 (wake-date key).

- **N11.** Widening the ln(RMSSD) SD of a personal baseline by √(7/n) below seven nights with a 0.10 floor, and scoring each night only against nights with an earlier night key, with the same leave-current-out statistics used for window ranking and for the score. (A 60-day normal range is public [27]; the 60-night statistics window is not claimed.)
  Closest prior art: HRV4Training's 60-day normal range of ±0.75 SD [27].
  Earliest dated form: dev c48eeb9, 2026-03-01 (60 nights, ln statistics, 0.10 floor). Current form: emuqu 554540f, 2026-10-03 (earlier-nights filter; √(7/n) fr c6d66dd 2026-06-25).

- **N12.** Freezing a recovery score at acceptance with: the strap's nocturnal window HR substituted for daytime resting HR in the vitals snapshot; a reference date equal to session end; a baseline-substitution rule for unusable readings that is triggered asymmetrically for short readings, with a 70/30 baseline/subjective blend routed through the same penalty tail; and a stored algorithm-version string, with records lacking one labelled "unversioned" rather than current.
  Closest prior art: none found; no vendor documentation found describes score versioning.
  Earliest dated form: dev c48eeb9, 2026-03-01 (frozen snapshot). Current form: edev f2e6ed1, 2026-09-03 (version string and `unversioned`; 70/30 blend fr 68b07a1 2026-03-28, asymmetric short rule fr 870028e 2026-04-05, strap nocturnal HR fr 0a3972d 2026-05-03, reference date fr d98e25f 2026-06-30; a versioned-parameters precursor fr dba6fcc 2026-05-01).

- **N13.** Bounding automatic post-freeze changes. Only the most recent overnight session ended within 18 h is eligible. Rescoring happens only on a first snapshot, a ≥ 20 min total change, a ≥ 15 min onset move, or a boundary-source upgrade from an estimate (HR, Watch HR or recording bounds) to HealthKit sleep. Scoring boundaries move with the display snapshot. User-edited boundaries and manual windows are never overwritten. Score, breakdown and version are merged across devices as one unit. (Rescoring a day when its sleep boundaries change is public [26][21] and is not claimed.)
  Closest prior art: Oura rescoring after bedtime edits [26]; WHOOP Recovery changing after sleep edits [21].
  Earliest dated form: dev c48eeb9 and 6eddc97, 2026-03-01 and 2026-03-15. Current form: emuqu 554540f, 2026-10-03 (atomic cross-device merge; ≥ 20 min rescore fr 38c4598 2026-05-13, 18 h fr cec0a25 2026-07-03, 15-min onset and Watch upgrade fr 24d2017 2026-08-06).

- **N14.** RR-only sleep staging on 5-min epochs using four weight sets chosen by which feature families exist that night, time-of-night priors with a 60-min REM lockout, single-epoch smoothing that never removes wake, and gap-terminated intervals; combined with a Watch augmentation that repaints only the overridden stage inside overridden epochs of the Watch's own intervals and requires spectral data for any REM override. (Within-night rank normalisation and time-of-night features are public [36][37][38] and are not claimed. The claim is to the method, not to its accuracy, which Section 5.2 measures as near chance.)
  Closest prior art: HRV-only staging with fractile normalisation [36]; elapsed time as a feature [37]; within-night normalisation [38]; Polar's wrist-based staging [39].
  Earliest dated form: dev c48eeb9, 2026-03-01 (ranks, four weight sets, REM lockout, smoothing, augmentation). Current form: emuqu 5c4a23d, 2026-10-04 (tie-averaged ranks; Watch-interval repaint emuqu 554540f 2026-10-03).

None of the fourteen statements was fully anticipated, so none was dropped. The parts each overlaps with are moved to the list below.

**Not claimed (prior art).** RMSSD, SDNN and pNN50 definitions and the adjacency requirement [1]. ln(RMSSD) baselines, z-scores and the 0.5 SD smallest worthwhile change [2][3][11]. Comparison with earlier days [6]. DFA and its box-size ranges [4]. Median-deviation artifact and ectopic classification and the 20% threshold [5][10][12][16]. The concept of HRV-based sleep staging, within-night rank or fractile normalisation, time-of-night features and the direction of α1 and LF/HF changes across stages [13][14][15][36][37][38]. Strap internal recording [18]. Measuring HRV in a sub-band of the night [19][22][30]. Selecting segments under an artifact-share limit [32][33]. A 60-day personal normal range [27]. Rescoring after a sleep-boundary edit [21][26]. Weighted composite readiness scores in general. The criticism of ACWR [8]. Piecewise-linear score mappings in general.

---

## 5. Validation, Accepted Tradeoffs and Limitations

### 5.1 Register status

Exact status words from `Tools/science_register/register.json`, scoring version v3.1.oct2026:

| Register entry | Status | What it covers here |
|---|---|---|
| hrv-time-domain-arithmetic | validated | RMSSD, SDNN and pNN50 arithmetic. Checked every build against 6,000 intervals from 20 PhysioNet nsr2db records [9] versus an independent Task Force implementation. This covers the arithmetic, not the strap's beat detection. |
| lnrmssd-swc-band | validated | Use of the 0.5 SD smallest worthwhile change on rolling ln(RMSSD), the published method |
| resting-dfa-a1-reference-band | awaiting-validation | The 0.75–1.0 α1 band: the +5 bonus and the organized-window test |
| lfhf-window-filter | awaiting-validation | Dormant in production (no per-window LF/HF is supplied) |
| pns-sns-gap-readiness | awaiting-validation | The ANS-balance adjustment |
| composite-weights-60-25-15 | awaiting-validation | Tier weights, RHR and CV adjustments |
| rmssd-absolute-fallback-bands | awaiting-validation | No-baseline RMSSD bands |
| baseline-staleness-penalty | awaiting-validation | Staleness deduction |
| sleep-score-six-factor | awaiting-validation | Sleep sub-score |
| hrv-sleep-staging | awaiting-validation | Section 3.9. Agreement with polysomnography is now measured (Section 5.2) and is near chance. The register entry's evidence text was written before this measurement. |
| spo2-flat-penalty | awaiting-validation | SpO₂ deduction |

The window-selection method (Sections 3.4–3.5), the baseline admission and replacement rules (Section 3.6) and the freeze rules (Section 3.8) are not separate register entries. Their correctness is defined by internal consistency (for example, the window chosen is the one the score prefers) and is enforced by unit tests. Whether the selected window or the resulting score tracks any physiological or training outcome is unknown, because no outcome data have been collected for it.

### 5.2 Independent validation on PhysioNet data

The full report, scripts and per-record results are in `Tools/validation/RESULTS.md`.

**Method.** No Swift toolchain was available, so the analysis code at e028039 was reimplemented in Python line by line. A port's results are treated as the app's only after it reproduced the app's own unit-test expectations: 114 test cases across eight suites (DFA, DFA reference, frequency domain, sleep-stage classifier, artifact detection, live-DFA cleaning, time domain, HRV reference) all matched, several to the last printed digit. The ports cover the RR-only classifier, the whole-series artifact classifier and the time-domain path with its ectopic gate and recording breaks. They do not cover the Apple Watch augmentation path, window selection or scoring. The inputs are ECG-derived beats (annotated or detected), not a chest strap, so the results do not cover strap beat detection, Bluetooth dropouts or the app's own boundary resolution. Data: PhysioNet [9] slpdb 1.0.0 [41], CAP Sleep Database (capslpdb) 1.0.0 [42], MIT-BIH Arrhythmia Database (mitdb) 1.0.0 [43]. Run date 2026-10-08.

**Sleep staging versus polysomnography (Section 3.9, RR-only path).**

- *slpdb* (primary): 18 records from 16 subjects referred for sleep apnea evaluation, almost all male, aged 32–56. RR from the reference beat annotations, normal-to-normal intervals only; a sensitivity analysis used all beats.
- *CAP*: the healthy controls n1–n15 (n16 has no ECG). R peaks detected from the ECG with wfdb-python 4.3.1 XQRS; every detected beat used.
- Reference stages mapped to Wake, Core (S1+S2), Deep (S3+S4, Rechtschaffen & Kales) and REM. Each 5-min app epoch was compared with the majority of its ten 30-s PSG epochs. "Whole recording" passes the scored recording's bounds as sleep start and end (the app's recording-bounds fallback); "sleep period" passes the true PSG sleep period.

| Dataset / variant | Records | 5-min epochs | Accuracy | Cohen's κ | Majority-class accuracy |
|---|---:|---:|---:|---:|---:|
| slpdb, NN RR, whole recording (primary) | 18 | 1018 | 38.8 % | 0.072 | 58.8 % |
| slpdb, NN RR, sleep period | 18 | 973 | 41.9 % | 0.087 | 61.5 % |
| slpdb, all-beat RR, whole recording | 18 | 1018 | 38.9 % | 0.075 | 58.8 % |
| CAP controls, detected beats, whole recording | 15 | 1505 | 41.7 % | 0.146 | 43.3 % |
| CAP controls, detected beats, sleep period | 15 | 1435 | 42.4 % | 0.142 | 45.6 % |

Per-record 5-min κ (mean ± SD): slpdb 0.037 ± 0.155; CAP 0.144 ± 0.112. The 30-s analysis gives the same picture (κ 0.069 slpdb, 0.153 CAP).

slpdb primary analysis, 5-min epochs (rows = PSG, columns = app):

| PSG \ App | Wake | Core | Deep | REM | Total |
|---|---:|---:|---:|---:|---:|
| Wake | 41 | 147 | 45 | 50 | 283 |
| Core | 8 | 300 | 228 | 63 | 599 |
| Deep | 0 | 28 | 35 | 2 | 65 |
| REM | 4 | 39 | 9 | 19 | 71 |

| Per-class, 5-min | Wake sens. / prec. | Core sens. / prec. | Deep sens. / prec. | REM sens. / prec. |
|---|---|---|---|---|
| slpdb primary | 14.5 % / 77.4 % | 50.1 % / 58.4 % | 53.8 % / 11.0 % | 26.8 % / 14.2 % |
| CAP whole recording | 4.3 % / 11.3 % | 45.5 % / 45.1 % | 48.0 % / 40.1 % | 43.2 % / 42.1 % |

| Stage minutes, app − PSG (Bland–Altman, n = records) | Bias (min) | 95 % limits of agreement (min) |
|---|---:|---|
| slpdb primary, total sleep time | +71.8 | −31.1 to 174.7 |
| slpdb primary, deep | +69.7 | 3.8 to 135.7 |
| slpdb primary, REM | +17.8 | −36.5 to 72.0 |
| CAP whole recording, total sleep time | +34.8 | −48.2 to 117.8 |
| CAP whole recording, deep | +26.0 | −51.7 to 103.7 |
| CAP whole recording, REM | +5.9 | −86.0 to 97.9 |
| CAP sleep period, total sleep time | +6.0 | −62.1 to 74.0 |

*Result.* On slpdb the classifier does not agree with polysomnography beyond chance (κ 0.07), and its accuracy is below what labelling every epoch "Core" would score. On CAP healthy controls agreement is slight (κ 0.15), again below the majority-class accuracy. For comparison, the cardiac staging studies cited in this paper report κ 0.49 with 69 % accuracy for wake, REM, light and deep sleep from ECG and respiratory effort in 48 healthy adults [13], and κ 0.61 ± 0.15 with 77 % accuracy from HRV with a long short-term memory network on 584 nights [14]. Using all beats instead of normal-to-normal intervals, or giving the classifier the true sleep period, changes κ by ≤ 0.02, so neither ectopic beats nor boundary choice explains the result. The errors follow from the design in Section 3.9:

1. Deep sleep is assigned by within-night rank plus a time-of-night prior, so every night receives a deep share whatever its N3 content. On slpdb 31 % of epochs were labelled Deep against 6.4 % on PSG (deep precision 11 %), and four nights with no PSG deep sleep received 80–105 deep minutes.
2. Wake is almost never called because the awake score rarely exceeds 0.80 (wake sensitivity 13–15 % on slpdb, 4–7 % on CAP). Total sleep time is over-reported whenever the input contains wake; on CAP the bias falls from +35 to +6 min when the true sleep period is supplied.
3. REM is weakly identified, with REM-minute limits of agreement spanning roughly ±55 min (slpdb) and ±90 min (CAP).

The method is still described in full because this paper documents what the app does. Its per-stage minutes are estimates and must not be read as measurements of deep or REM sleep. The production Watch augmentation path (Section 3.9.6) was not ported and has not been evaluated against polysomnography.

**Ectopic-beat detection and RMSSD agreement (Sections 3.3.1–3.3.3).** mitdb, 44 records (paced records 102, 104, 107 and 217 excluded), 100,733 annotated beats of which 10,593 ectopic. The RR series keeps every beat, as a strap would. An interval counts as truly distorted if either endpoint is an ectopic beat (interval rule); the beat rule counts an ectopic beat as detected if either adjacent interval is flagged.

| Method | Rule | Sensitivity | Specificity | PPV |
|---|---|---:|---:|---:|
| Whole-series classifier (3.3.1) | interval | 57.5 % | 94.9 % | 71.3 % |
| Whole-series classifier (3.3.1) | beat | 67.5 % | 92.6 % | 55.3 % |
| Classifier + local ectopic gate (3.3.2), as used for overnight RMSSD | interval | 59.8 % | 94.3 % | 69.7 % |
| Classifier + local ectopic gate (3.3.2), as used for overnight RMSSD | beat | 69.4 % | 91.8 % | 53.3 % |

Beat-rule sensitivity of the overnight exclusion by beat type: ventricular premature (V, n = 6901) 85.6 %; aberrated atrial premature (a, n = 150) 99.3 %; atrial premature (A, n = 2544) 41.2 %; fusion (F, n = 802) 26.3 %; nodal premature (J, n = 83) 30.1 %; ventricular escape (E, n = 106) 10.4 %. A supraventricular beat less than 20 % premature is, by construction, not an artifact to a 20 % median-deviation rule.

5-min RMSSD, app pipeline (whole-record classifier flags, local gate and masked estimator within each segment) versus the RMSSD of normal-to-normal intervals only (bias = app − reference):

| Segments | n (records) | Median ref. (ms) | App bias (ms) | App ratio bias [95 % LoA] | App median abs. error (ms) | App within ±10 % | No correction: ratio bias | No correction within ±10 % |
|---|---:|---:|---:|---|---:|---:|---|---:|
| All | 255 (43) | 35.8 | −21.6 | 0.93 [0.33, 2.62] | 4.7 | 51 % | 2.16 | 33 % |
| Excluding AF/flutter | 226 (40) | 32.4 | −8.6 | 1.03 [0.43, 2.51] | 3.2 | 58 % | 2.32 | 34 % |
| … no ectopic beat | 71 (17) | 32.5 | −5.8 | 0.93 [0.64, 1.35] | 0.0 | 83 % | 1.00 | 100 % |
| … ≥ 1 ectopic beat | 155 (37) | 32.1 | −9.8 | 1.09 [0.39, 3.04] | 5.8 | 46 % | 3.41 | 3 % |
| … ≥ 5 % ectopic beats | 81 (22) | 34.5 | −11.6 | 1.23 [0.35, 4.24] | 9.7 | 33 % | 5.26 | 1 % |

*Result.* Without correction, ectopy inflates 5-min RMSSD by a median of 32 ms (ratio bias 2.2). The app's drop-only handling brings the median absolute error to 4.7 ms over all segments and 3.2 ms outside AF/flutter, but the limits of agreement stay wide (ratio 0.43–2.51 outside AF/flutter). Two mechanisms remain: ectopic beats that escape detection leave large outliers (only 33 % of segments with ≥ 5 % ectopy are within ±10 %), and in segments with no ectopic beat the local gate removes genuine sinus variability in a minority of segments (83 % within ±10 %, where no correction gives 100 %). The handling is much better than none on ectopic-laden data and is not equivalent to excluding annotated non-normal beats.

**Limitations of this validation.** The ports were checked against unit tests and a line-by-line reading, not run as the shipped binary. slpdb is an apnea population, scored with Rechtschaffen & Kales rules, with several short or half-night records; CAP beats were detected, not annotated, and several CAP ECGs are sampled at 100–128 Hz. mitdb consists of 30-min excerpts selected for arrhythmia, so its ectopic burden is far higher than a typical user's night, and its annotations do not test missed or extra strap detections. Pooled epoch statistics treat epochs as independent although they cluster within records; per-record values are in the full report. The recording-break rule (Section 3.3.3) was exercised by the ported unit tests but not by these datasets, which contain no dropouts.

### 5.3 Tradeoffs and known limitations

- *A short window represents the night.* About 6–7 min of the middle of sleep stands for the whole night. This trades coverage for repeatability.
- *Selection maximises the score.* Ranking by the scoring function favours the best-scoring eligible window. Nightly scores are therefore optimistic compared with a random eligible window. This is consistent across nights but not neutral.
- *Ranking omits ANS balance.* Window ranking does not include the ANS-balance term, which the final score does include, so the two can differ by up to −6/+2 points. Ranking also evaluates staleness at the current time rather than at session end, but staleness is the same for every window and so does not change the order.
- *Organized depends on unvalidated thresholds.* The α1 band and CV < 8% are app conventions. A night with no organized window gets a fallback window.
- *The baseline is display-asymmetric but admission-symmetric.* A short high reading is shown to the user but not admitted to the baseline.
- *Estimated sleep boundaries are biased late.* HR-estimated onsets can still be early or late within the 20-min clamp. The search band shifts with them.
- *Ectopic detection is incomplete.* The 20% median-deviation rule catches most ventricular premature beats but fewer than half of atrial premature beats (Section 5.2). Undetected ectopy can still inflate a window's RMSSD.
- *RR-only sleep staging is near chance.* It over-reports deep sleep, rarely calls wake and weakly identifies REM (Section 5.2). Its stage minutes are estimates, not measurements.
- *Sleep-staging RMSSD is not masked.* Per-epoch RMSSD in the sleep classifier differences the collapsed list of valid beats and does not use the masked estimator of Section 3.3.3.
- *Population SDNN in selection.* Window CV and SDNN in selection use the population SD. The reported SDNN uses the sample SD.
- *The app is not a medical device.* No output is a diagnosis. The SpO₂ rule is a conservative product rule.
- *Single-author development.* The validation in Section 5.2 is a separate reimplementation of the code, run by the project; no third party has replicated it.

---

## 6. Comparison to Existing Approaches

Commercial entries state only what the cited public pages say. Items marked † were read through search-engine extracts of the cited page, not the full page.

| Approach | Window choice | Baseline | Artifact handling | Score versioning |
|---|---|---|---|---|
| Task Force 1996 [1] | Short-term (5 min) or 24 h recordings; no overnight window-selection rule | Not specified | Requires NN intervals; method not prescribed | n/a |
| Plews/Buchheit ln(RMSSD) monitoring [2][3][11] | Standardised morning spot reading | Rolling ln(RMSSD) mean, SWC 0.5 SD | Protocol-based | n/a |
| Kiviniemi 2007 [6] | Morning measurement | Earlier days only | Not the focus | n/a |
| Kubios HRV [10] with Lipponen-Tarvainen correction [5] | User-chosen sample or whole recording | None (analysis tool) | Classifies and *corrects* (interpolates) beats | n/a |
| HRV sleep-staging literature [13][14][15][36][37][38] | Epoch-based staging; fractile or within-night normalisation [36][38]; elapsed time as a feature [37] | Not applicable | Varies | n/a |
| Polar Nightly Recharge † [19][20] | HR, HRV and breathing rate over roughly the first 4 h of sleep | Compared with the user's past 28 days; needs 3 nights | No public description found | No public description found |
| WHOOP Recovery † [21][22][23] | HRV averaged over the night, weighted toward slow-wave sleep [21]; patent: HRV in the last sleep phase before waking [22]; an independent study could not reproduce a "last slow-wave sleep" window [23] | 30-day baseline [21] | No public description found | No public description found |
| Oura † [24][25][26] | Nightly HRV = mean of all 5-min samples during sleep [24] | HRV Balance: 14-day weighted average against a ~3-month baseline (another Oura page says 2 months) [25] | No public description found | No public description found; editing bed or wake times changes that day's scores [26] |
| Garmin HRV Status † [28] | Overnight HRV (third-party description only) | 7-day average against a ~3-week baseline | No public description found | No public description found |
| HRV4Training † [27] | Morning spot reading | 60-day normal range, ±0.75 SD | No public description found | No public description found |
| Apple Watch wrist temperature † [29] | Samples every 5 s during Sleep Focus; ≥ 4 h needed | Personal baseline after ~5 nights | No public description found | No public description found |
| Runners' window comparison † [30] | Sleep onset vs first 4 h vs whole night, compared | Study-specific | Study-specific | n/a |
| **Emuqu** | 30–70% of measured sleep on the beat timeline; adaptive windows ranked by the scoring function | Structural admission, one slot per night, 60 nights, √(7/n) widening, leave-current-out | Drop-only; whole-series classifier + self-excluding local gate; break-aware masked RMSSD (Section 5.2 reports its accuracy on mitdb) | Version string on every score; `unversioned` sentinel |

---

## 7. Provenance and Dates

**Author.** Chris Sharp <chrissharp80@gmail.com> is the sole author and sole committer of every repository listed below. The code was written by AI coding assistants under his direction (some commits are attributed to "Claude"); he supplied the requirements, design direction, review, testing and acceptance.

**(a) Project origin.** These records establish where the project came from. They are origin evidence, not dates for any method in this paper.

- Repository chrissharp80/AI-Fitness-Coach, 19 commits, 2025-02-16 to 2025-02-17: Apple HealthKit HR and HRV (SDNN) display, Polar H10 real-time HR streaming over Bluetooth, and VO₂ max estimation. It contains no RR-interval analysis and none of the methods described here.
- The earliest recovered HRV-specific design exchange is the author's ChatGPT user message of 2025-02-22 15:44:18 UTC: "If someone's willing to wear the polar to bed, then can we set up an app that can learn right before they're gonna wake up and then administer the test. I know that similar to what WHOOP tries to do, but I mean actually get it right". Follow-up messages at 15:45:05 and 15:46:01 UTC asked about less intrusive hardware than the chest strap, including watches and rings users already own. (ChatGPT user message, 2025-02-22 15:44:18 UTC; excerpt recovered through conversation-history retrieval on 2026-10-08; full transcript and stable conversation ID not exposed.) This establishes the concept of automatic overnight HRV measurement with a Polar strap, timed before waking. It does not establish the full-night RR-capture architecture or any method in this paper, which first appear in code in January 2026 (Section 7(c)); when the concept changed from a pre-waking test to full-night capture is not recovered.
- The same conversation record shows a broader fitness-app concept with "HRV trends" in its feature set (2025-02-22), a build, deploy and test workflow (2025-03-04) and a validation plan for the VO₂ max estimate (2025-03-05).

**(b) Repository lineage.** All repositories are private except the public emuqu repository; the author retains all of them with full history.

| Repository | Product name | First commit | Notes |
|---|---|---|---|
| chrissharp80/flow-recovery-old | Flow HRV | 2026-01-12 | 250 commits to 2026-01-26 |
| chrissharp80/flow-recovery-dev | Flow Recovery | 2026-03-01 | Squashed import of the Flow HRV code |
| chrissharp80/flow-recovery | Flow Recovery | 2026-03-15 | 196 commits to 2026-08-12 |
| chrissharp80/emuqu-dev | Emuqu | 2026-08-16 | Squashed import; to 2026-09-04 |
| github.com/chrissharp80/emuqu (public, PolyForm Strict 1.0.0) | Emuqu | 2026-09-08 | Squashed import; this paper describes e028039 (2026-10-07) |

History has gaps between 2026-01-26 and 2026-03-01, 2026-08-12 and 2026-08-16, and 2026-09-04 and 2026-09-08, where each new repository began with a squashed import.

**(c) Earliest commit per novelty statement.**

| N | First form (repo, commit, date) | Current form (repo, commit, date) |
|---|---|---|
| N1 | old aeaf0db, 2026-01-18 | emuqu 554540f, 2026-10-03 |
| N2 | old 577b937, 2026-01-14 | fr 24d2017, 2026-08-06 |
| N3 | old 985cefe, 2026-01-13 (sleep-anchored: old 0a86767, 2026-01-13) | fr 8814c54, 2026-07-21 |
| N4 | old 090f9c4, 2026-01-19 | fr a02e903, 2026-05-04 |
| N5 | old e5948bd, 2026-01-12 | emuqu 5c4a23d, 2026-10-04 |
| N6 | old 2bf168f / a695a90, 2026-01-14 | dev c48eeb9, 2026-03-01 |
| N7 | fr be64931, 2026-04-17 | emuqu 554540f, 2026-10-03 |
| N8 | old c32a6e3, 2026-01-14 | dev c48eeb9, 2026-03-01 |
| N9 | fr 870028e, 2026-04-05 | edev 680bbee, 2026-08-25 |
| N10 | old 52d6267, 2026-01-22 | emuqu 554540f, 2026-10-03 |
| N11 | dev c48eeb9, 2026-03-01 | emuqu 554540f, 2026-10-03 |
| N12 | dev c48eeb9, 2026-03-01 | edev f2e6ed1, 2026-09-03 |
| N13 | dev c48eeb9, 2026-03-01 (dev 6eddc97, 2026-03-15) | emuqu 554540f, 2026-10-03 |
| N14 | dev c48eeb9, 2026-03-01 | emuqu 5c4a23d, 2026-10-04 |

A dev c48eeb9 date marks a squashed import, so the method may be older than that date.

**(d) Dated records outside git** (the author's own files and messages):

- 2026-01-08, about 9 p.m. Central (Drive file created 2026-01-09 03:06:59 UTC): design document "Design: Connection + Offline RR Collection Harness (iOS + watchOS) – v9.2 FINAL", saved by the author from an AI design conversation four days before the first code commit. It is the final revision of the pre-implementation design: it changes only the spectral (FFT) computation and states that RR extraction, artifact detection (50-beat rolling median, sized for about 95,000 beats a night), time-domain and nonlinear metrics, window selection, archive and reconciliation remain as in v8.0. It lists ship-blocking acceptance tests (0.25 Hz sine placed in the HF band, total power for a known amplitude, RMSSD within 5 % of a reference implementation, reconciliation) and a 15-night field validation. Versions 1–8 have not been recovered.
- 2026-01-12 and 2026-01-14: "Flow HRV" session reports showing "Window Beats 400" and a 7.8-min analysis window.
- 2026-01-14: a private message to a colleague describing the strap recording internally while the app streams, with a report and screenshots.
- 2026-01-15: app logs pasted into a message: "Using HealthKit sleep start for window selection … No HealthKit sleep start, using recording start".
- 2026-02-16, 2026-02-18 and 2026-03-04: app-generated "Flow Recovery" PDF session reports (dates as printed in each footer) showing peak HRV separately from the analysis window.
- 2026-03-06: a private message to a second colleague describing the best consecutive 400 beats between 30% and 70% of the sleep window, and simultaneous streaming and internal strap capture with the stream scored while the strap file downloads.
- 2026-03-14: session reports sent by private message.
- 2026-03-23: "Flow Recovery - Bluetooth" screen recording.
- 2026-05-06 to 2026-05-10: project documents (including "flow-recovery-audit.md") describing score-based window ranking ("best Tier-1 score, not just the highest raw RMSSD"), frozen historical scores, rescore on manual sleep refresh, the RR-based sleep stage classifier with optional Watch refinement, the ln(RMSSD) z-score against a 60-day baseline, and an isolated-spike ratio of 1.50.

**(e) Public disclosures.**

- TestFlight beta from 2026-01-27 (over 1,500 sessions by 2026-03-06; 45 testers and over 6,500 sessions by August 2026). A public TestFlight join link appeared in the project README by May 2026.
- 2026-05-19: Substack article "A Powerfully Lazy Man's Way to Better Health". It described publicly: dual capture (internal strap recording and Bluetooth stream) merged in the morning; DFA α1 used to find "organized windows"; and a window search bounded to 30–70% of the time of sleep that picks the window with the highest RMSSD. It did not describe the gap-fill and de-duplication rules, the arrival-clock mapping, the thresholds of the organized test, score-ranked selection (in code since 2026-04-17), the baseline rules, score freezing or versioning, or sleep staging.
- 2026-08-10: Substack article "How I Build Production Software by Directing AI".
- 2026-09-08: public repository github.com/chrissharp80/emuqu.
- 2026-10-08: these white papers (v1.0 and this v1.1).

The work was also shared privately with two colleagues in January and March 2026 (items in (d)).

**Scoring versions:** v2.may2026 (public 2026-09-08) → v3.oct2026 (2026-10-03) → v3.1.oct2026 (2026-10-04).

**Validation data:** time-domain arithmetic checked against 20 PhysioNet nsr2db records (`docs/hrv-reference-data.md`); independent validation in `Tools/validation/RESULTS.md` (Section 5.2).

**This revision's publication date:** 2026-10-08.

---

## References

1. Task Force of the European Society of Cardiology and the North American Society of Pacing and Electrophysiology (1996). Heart rate variability: standards of measurement, physiological interpretation and clinical use. *Circulation* 93(5):1043–1065.
2. Plews DJ, Laursen PB, Stanley J, Kilding AE, Buchheit M (2013). Training adaptation and heart rate variability in elite endurance athletes: opening the door to effective monitoring. *Sports Medicine* 43(9):773–781.
3. Buchheit M (2014). Monitoring training status with HR measures: do all roads lead to Rome? *Frontiers in Physiology* 5:73.
4. Peng C-K, Havlin S, Stanley HE, Goldberger AL (1995). Quantification of scaling exponents and crossover phenomena in nonstationary heartbeat time series. *Chaos* 5(1):82–87.
5. Lipponen JA, Tarvainen MP (2019). A robust algorithm for heart rate variability time series artefact correction using novel beat classification. *Journal of Medical Engineering & Technology* 43(3):173–181.
6. Kiviniemi AM, Hautala AJ, Kinnunen H, Tulppo MP (2007). Endurance training guided individually by daily heart rate variability measurements. *European Journal of Applied Physiology* 101(6):743–751.
7. Billman GE (2013). The LF/HF ratio does not accurately measure cardiac sympatho-vagal balance. *Frontiers in Physiology* 4:26.
8. Impellizzeri FM, Tenan MS, Kempton T, Novak A, Coutts AJ (2020). Acute:chronic workload ratio: conceptual issues and fundamental pitfalls. *International Journal of Sports Physiology and Performance* 15(6):907–913.
9. Goldberger AL, Amaral LAN, Glass L, et al. (2000). PhysioBank, PhysioToolkit, and PhysioNet: components of a new research resource for complex physiologic signals. *Circulation* 101(23):e215–e220.
10. Tarvainen MP, Niskanen J-P, Lipponen JA, Ranta-aho PO, Karjalainen PA (2014). Kubios HRV – heart rate variability analysis software. *Computer Methods and Programs in Biomedicine* 113(1):210–220.
11. Plews DJ, Laursen PB, Kilding AE, Buchheit M (2012). Heart rate variability in elite triathletes, is variation in variability the key to effective training? A case comparison. *European Journal of Applied Physiology* 112(11):3729–3741.
12. Berntson GG, Bigger JT, Eckberg DL, et al. (1997). Heart rate variability: origins, methods, and interpretive caveats. *Psychophysiology* 34(6):623–648.
13. Fonseca P, Long X, Radha M, Haakma R, Aarts RM, Rolink J (2015). Sleep stage classification with ECG and respiratory effort. *Physiological Measurement* 36(10):2027–2040.
14. Radha M, Fonseca P, Moreau A, et al. (2019). Sleep stage classification from heart-rate variability using long short-term memory neural networks. *Scientific Reports* 9:14149.
15. Penzel T, Kantelhardt JW, Grote L, Peter JH, Bunde A (2003). Comparison of detrended fluctuation analysis and spectral analysis for heart rate variability in sleep and sleep apnea. *IEEE Transactions on Biomedical Engineering* 50(10):1143–1151.
16. Berntson GG, Quigley KS, Jang JF, Boysen ST (1990). An approach to artifact identification: application to heart period data. *Psychophysiology* 27(5):586–598.
17. Ohayon MM, Carskadon MA, Guilleminault C, Vitiello MV (2004). Meta-analysis of quantitative sleep parameters from childhood to old age in healthy individuals. *Sleep* 27(7):1255–1273.
18. Wearipedia. Polar H10 notebook (offline RR memory). https://wearipedia.readthedocs.io/en/latest/notebooks/polar_h10.html (search-engine extract), accessed 2026-10-08.
19. Polar Electro. Nightly Recharge support documentation (ANS charge from roughly the first 4 h of sleep, compared with the past 28 days). https://support.polar.com (search-engine extract), accessed 2026-10-08.
20. Polar Electro (2019). Nightly Recharge white paper. https://www.polar.com/en/science/whitepapers/nightly-recharge (search-engine extract), accessed 2026-10-08.
21. WHOOP. WHOOP Recovery (support article). https://support.whoop.com/s/article/WHOOP-Recovery (search-engine extract), accessed 2026-10-08.
22. US Patent 9,750,415 B2 (filed 2016-07-12), WHOOP, Inc. https://patents.google.com/patent/US9750415B2 (search-engine extract), accessed 2026-10-08.
23. Dial et al. (2025). *Physiological Reports*. doi:10.14814/phy2.70527 (search-engine extract), accessed 2026-10-08.
24. Oura. Heart rate variability (support article). https://support.ouraring.com/hc/en-us/articles/360025441974 (search-engine extract), accessed 2026-10-08.
25. Oura. HRV Balance (blog). https://ouraring.com/blog/hrv-balance (search-engine extract), accessed 2026-10-08.
26. Oura. Editing bedtime and wake time (support article). https://support.ouraring.com/hc/en-us/articles/360025445994 (search-engine extract), accessed 2026-10-08.
27. HRV4Training. Determining your normal range. https://www.hrv4training.com/blog2/determining-your-normal-range (search-engine extract), accessed 2026-10-08.
28. the5krunner. Third-party description of Garmin HRV Status. https://the5krunner.com (search-engine extract), accessed 2026-10-08.
29. Apple. Wrist temperature on Apple Watch (support article HT213275). https://support.apple.com/en-us/HT213275 (search-engine extract), accessed 2026-10-08.
30. Sports Medicine – Open (2024). Comparison of nocturnal HRV windows in runners. https://link.springer.com/article/10.1186/s40798-024-00779-5 (search-engine extract), accessed 2026-10-08.
31. Sleep-onset detection from heart-rate change points against polysomnography (PMC11991269). https://pmc.ncbi.nlm.nih.gov/articles/PMC11991269/ (search-engine extract), accessed 2026-10-08.
32. *Sensors* 24(23):7475 (2024). Oura validation with per-segment valid-interval thresholds. https://www.mdpi.com/1424-8220/24/23/7475 (search-engine extract), accessed 2026-10-08.
33. ClinicalTrials.gov NCT04075279 (protocol averaging three 5-min periods). https://clinicaltrials.gov/study/NCT04075279 (search-engine extract), accessed 2026-10-08.
34. RR-interval deletion editing (ResearchGate publication 6495246). https://www.researchgate.net/publication/6495246 (search-engine extract), accessed 2026-10-08.
35. Selection of the 256 most stable points (ScienceDirect S1413355517302186). https://www.sciencedirect.com/science/article/pii/S1413355517302186 (search-engine extract), accessed 2026-10-08.
36. HRV-only sleep staging with fractile normalisation (ScienceDirect S1746809413000864). https://www.sciencedirect.com/science/article/pii/S1746809413000864 (search-engine extract), accessed 2026-10-08.
37. arXiv:1910.11702 (2019). ECG-based sleep staging with elapsed time as a feature. https://arxiv.org/abs/1910.11702 (search-engine extract), accessed 2026-10-08.
38. Within-night normalisation for cardiac sleep staging (PubMed 42375153). https://pubmed.ncbi.nlm.nih.gov/42375153/ (search-engine extract), accessed 2026-10-08.
39. Polar Electro. Sleep Plus Stages white paper (wrist beat-to-beat intervals plus accelerometer). https://www.polar.com/en/science/whitepapers (search-engine extract), accessed 2026-10-08.
40. KJA88/syzygy-mission-control, GitHub issue 21 (Polar H10 offline RR memory). https://github.com/KJA88/syzygy-mission-control/issues/21 (search-engine extract), accessed 2026-10-08.
41. Ichimaru Y, Moody GB (1999). Development of the polysomnographic database on CD-ROM. *Psychiatry and Clinical Neurosciences* 53(2):175–177. PhysioNet slpdb 1.0.0, https://physionet.org/content/slpdb/1.0.0/, accessed 2026-10-08.
42. Terzano MG, Parrino L, Sherieri A, et al. (2001). Atlas, rules, and recording techniques for the scoring of cyclic alternating pattern (CAP) in human sleep. *Sleep Medicine* 2(6):537–553. PhysioNet capslpdb 1.0.0, https://physionet.org/content/capslpdb/1.0.0/, accessed 2026-10-08.
43. Moody GB, Mark RG (2001). The impact of the MIT-BIH Arrhythmia Database. *IEEE Engineering in Medicine and Biology Magazine* 20(3):45–50. PhysioNet mitdb 1.0.0, https://physionet.org/content/mitdb/1.0.0/, accessed 2026-10-08.

---

## Appendix A: Parameter Table

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
| rolling median half-window | 25 | beats | Whole-series classifier (51-value centred) |
| extra / missed thresholds | 0.5× / 1.5× | median | Classifier |
| ectopic threshold | 0.20 | fraction | Classifier and local gate |
| local median neighbours | 10 | beats | Self-excluding local gate |
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
| maxOrganizedLfHf | 1.5 | — | Dormant alternative |
| peak-capacity window | 400; B/3 if B ≥ 360; else max(60, 0.4B) | beats | Whole-recording scan |
| reliable window | 300 000 | ms | Baseline admission; quality rule |
| overnight session | 10 800 | s | Baseline admission; quality rule |
| stored points | 90 | nights | Baseline storage |
| stats window | 60 | nights | Baseline statistics |
| minimum nights | 3 | nights | Baseline exists |
| widening | √(7/n), n < 7 | — | SD widening |
| lnRmssdSDFloor | 0.10 | ln units | SD floor |
| meanHRSDFloor | 0.5 | bpm | HR SD floor |
| replacement fractions | 0.15 / 0.90 / 0.95 / 0.05 | — | Night-slot replacement |
| artifact ceiling | max(1.5×, 2.0) | % | Night-slot replacement |
| CV reject multiplier | 1.3 | × | Night-slot replacement |
| z bands | (−3,5) (−1.5,25) (−0.75,64) (−0.5,72) (0.5,72) (1.5,90) | — | z-mapping |
| RHR multiplier / clamp | −5 / ±10 | points per SD | Tier-1 adjustment |
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
| RHR vitals penalty | 10 | points per SD | Vitals |
| RR band / penalty | 1 / 15 | br/min / points per br/min | Vitals |
| RR population window / below | 12–18 / 90 | br/min / points | Vitals |
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
    kept = localGate(vals.rr, neighbours=10 excluding self, 20%)
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
    if q.useBaseline and session.perceived: bd.HRV = 0.7*bd.HRV + 0.3*100*clamp(perceived)
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

| Method | Files (under `Emuqu/Sources/`) |
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
| Validation register / data | `Tools/science_register/register.json`, `docs/hrv-reference-data.md`, `Tools/validation/RESULTS.md` |
