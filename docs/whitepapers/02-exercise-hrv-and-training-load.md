# EMUQU — Real-Time DFA α1 and Dropout-Robust Training Load

**Gated live α1, window-length ectopic discrimination, route-matched load substitution and a recovery-aware readiness model**

Technical White Paper • v1.2

v1.2 (2026-10-08): restructured method-first; adds design rationale; validation detail moved to the separate validation report.

October 2026

Chris Sharp

Describes Emuqu at source revision e028039 (2026-10-07); scoring version v3.1.oct2026.

---

## Executive Summary

Emuqu is an iOS application that records workouts from a chest strap (Polar-class Bluetooth heart-rate sensor), an Apple Watch, GPS, foot pods and power meters. During exercise it shows the short-term scaling exponent of detrended fluctuation analysis (DFA α1), a heart-rate-variability index that falls with intensity and crosses about 0.75 near the first ventilatory threshold. Across days it keeps a training-load history (ATL, CTL, TSB) and a daily training-readiness score.

Both depend on a beat stream that is routinely interrupted by Bluetooth dropouts, lost skin contact, phone–Watch handovers and ectopic beats. Emuqu's approach is to make each number answer to the data that support it. A live α1 appears only when its window is full on a clock that accounts for lost time. A post-session reading discounts dips too short to be physiological. A workout whose strap failed is credited with the load the user normally produces on the same route. Readiness reconciles training load with the morning HRV recovery score. The main methods are:

1. **A gated live α1 analyzer.** A value is published only when a 120 s window holds at least 64 beats *and* spans at least 118 s on a beat clock that adds dropout time back in; the same clock trims the window. A trailing-median filter interpolates artifacts in place, a window with more than 6 % corrected beats is withheld, and a five-state status machine clears the value whenever it is not freshly computed.
2. **Ectopic discrimination by window length.** A post-session α1 dip below 0.75 that recovers within one window (120 s) is labelled an "ectopic shadow" and left out of summary statistics; a threshold crossing counts only after 180 s below the threshold.
3. **A training-load precedence ladder.** Power TSS (including read-time power TSS from stored normalized power and an automatic FTP), a route-history estimate when the heart-rate load looks like a strap dropout, hrTSS, MET load, Banister TRIMP, and the route estimate as a last resort.
4. **Route-matched load substitution.** A dropout workout's load is rebuilt from the user's own TRIMP-per-metre on earlier clean runs of the same saved route, matched in either direction, with outlier removal, a blend with the partial recording and an explicit confidence.
5. **A recovery-aware readiness model.** A 72 h decaying acute-fatigue term, the ATL/CTL capacity ratio and a damped ACWR penalty, blended asymmetrically with the morning recovery score and interpolated through the day from a frozen morning snapshot.
6. **Fusion of the two strap paths.** Watch-relayed RR is used only while the phone's strap stream is silent, so no beat is counted twice; at finalize the streams are interleaved by arrival time.

Section 5 states what is new in each method and the work it builds on. Section 4 summarises verification: Python ports of the artifact filter and DFA core reproduce the app's unit-test expectations, and on PhysioNet Holter recordings the filter holds α1 bias at −0.023 or smaller at artifact rates up to 3 %, against −0.43 to −0.77 without correction.

---

## 1. The Problem

### 1.1 Live DFA α1 needs complete, clean, current windows

DFA [1] integrates a beat-interval series and measures how the detrended fluctuation F(n) grows with box size n; the log–log slope over boxes of 4–16 beats is α1. In incremental exercise tests α1 falls with intensity and crosses about 0.75 near the first ventilatory or lactate threshold [2][3][4], which makes it attractive as a live intensity readout. Four practical problems stand in the way.

- **Too little data.** At 160 bpm, 64 beats take about 24 s, so a beat-count gate alone lets a fit run on a fraction of the nominal two-minute window.
- **Artifacts.** Artifact correction biases α1 minimally below about 3 % corrected beats and only slightly at 6 % [4][5], while uncorrected artifacts move it a long way: in resting Holter recordings, 1 % injected ectopic or missed beats lowered α1 by 0.55 and 0.43, toward the white-noise value of 0.5 (§4).
- **Dropouts.** When a Bluetooth link drops, beats are lost. A timeline built as the running sum of delivered intervals stops advancing while real time continues, so a window cut on it does not describe the last two minutes.
- **Stale numbers.** A display that keeps its last value after the strap stops, or after a window is rejected, shows a number that is no longer being computed.

### 1.2 Interpreting α1 after the session

A single ectopic beat stays inside a 120 s rolling window for 120 s, so it can drag α1 below 0.75 for up to one window length, and an "LT1 estimate" taken from the first sub-0.75 sample can reflect one bad beat. Agreement between the α1 = 0.75 crossing and gas-exchange VT1 is good on average, with individual limits of agreement around ±10 bpm that widen in fatigued runners [2][6][7], and test–retest reliability of HR at the α1 threshold in untrained adults is moderate (ICC 0.52) [20]. A post-session reading has to separate sustained physiology from transient artifact.

### 1.3 Training load when the strap fails

Heart-rate load models (Banister TRIMP [8][9], hrTSS) need heart rate. When the strap fails partway through, a 40-minute run can record a TRIMP of 2, and that number enters the exponentially weighted ATL/CTL averages [8][10] and depresses every later readiness and form figure. Power TSS [10] avoids heart rate but needs a power meter and an FTP. Published platforms fall back from one load metric to another when a metric is zero or missing (§7), and intervals.icu can estimate load from average HR with a model fitted to earlier activities. Rebuilding a dropout session's load from the user's own history on the same route is the gap addressed here.

### 1.4 Readiness and the acute:chronic ratio

The acute:chronic workload ratio (ACWR) [11] is widely used to flag load spikes, but its statistical basis and "sweet spot" have been criticised [12]. At low chronic load the ratio is numerically unstable (one walk can move it by 0.2), and undamped ACWR penalties can contradict the morning HRV-based recovery score on the same screen.

---

## 2. Architecture Overview

| Phase | Operation | Purpose |
|---|---|---|
| Acquisition (1 Hz tick) | Phone-strap RR; Watch-relayed RR only after ≥5 s of phone silence; HR arbitration (strap → Watch-relayed strap → wrist) | One beat stream, no double counting, no stale HR |
| Live HR | Median of the last 8 RR → bpm | Stable readout |
| Live α1 | Beat clock → 120 s trim → dual gate → filter → 6 % rejection → DFA → status | A value only when current and supported |
| Finalize | Interleave phone and Watch RR by wall clock; rebuild `t_ms`; TRIMP, hrTSS, power TSS, splits, decoupling | One coherent RR series |
| Route estimate | Match saved route; filter earlier runs; estimator; confidence | Recover a dropout workout's load |
| Offline α1 | Live pipeline on the gap-corrected timeline; freshness-limited write-back | Comparable live and offline numbers |
| Report | Ectopic shadows; sustained 0.75/0.50 crossings; band minutes; LT1 estimate; per-split α1 | Robust to single-beat artifacts |
| Load history | Ladder → capped daily sums → ATL/CTL EWMA → TSB | Bookkeeping of training history |
| Readiness | Acute fatigue + capacity ratio + damped ACWR + freshness + asymmetric recovery blend; frozen morning value; intra-day interpolation | Capacity for more load, consistent with recovery |

---

## 3. Methods in Detail

Appendix B gives pseudocode for each method and Appendix A every parameter.

### 3.1 Live DFA α1

Parameters: window W = 120 s; recompute cadence C = 20 s (wall clock, between ingest calls); minimum 64 beats; span slack 2 s (span gate W − 2 = 118 s); "stalled" after 2 × C = 40 s of silence; rejection when the corrected fraction exceeds 0.06.

#### 3.1.1 Beat clock (dropout compensation)

Each RR point carries `t_ms` (running sum of delivered intervals), `rr_ms` and, when available, `wallClockMs` (milliseconds since the strap stream started, at arrival). The analyzer re-stamps every beat with `start = max(nextStart, wallClockMs − originWall + originBeat)`, where `nextStart` is the previous beat's start plus its `rr_ms` (the beat's own `t_ms` for the first beat) and `originWall`, `originBeat` are recorded at the first beat carrying a wall-clock time; the second term is omitted for beats without one (Appendix B1).

Offline, the same timeline is `t_ms + correction`, where `correction` is the running maximum of `(wall − originWall) − (t_ms − origin.t_ms)`; a unit test checks that both forms give identical offsets on a stream with a dropout.

**Why it works.** A beat cannot start before the previous beat ended, nor earlier than its arrival allows; the `max` of the two bounds is the earliest consistent start. In normal streaming the interval sum leads and arrival lags by batching jitter, so spacing is untouched. After a dropout, arrival leads by the lost duration and the clock jumps forward by exactly that amount. The correction is a running maximum, so the timeline stays monotonic.

#### 3.1.2 Ingest, trim, gate and progress

On each ingest at time `now`: ignore the call if no session has started; append the re-stamped beats and, if any arrived, set `lastBeatAt = now`; remove every beat with `t_ms < newest.t_ms − W`; compute `span = (last.t_ms − first.t_ms)/1000` and `fill = min(min(1, count/64), min(1, span/118))`; recompute if at least C seconds have passed since the last recompute, otherwise only refresh the status. The recorder calls `tick(now)` once per second when no beats arrived, so the status can reach "stalled" while the strap is silent.

The dual gate is `count ≥ 64 AND span ≥ 118 s`.

**Why one clock and two conditions.** Trimming and span measurement use the same beat clock, so window membership and measured span always describe the same stretch of time; on two different clocks they would drift apart by every dropout. The beat count protects the fit (with 64 beats every α1 box size from 4 to 16 is available); the span protects the meaning, since a value labelled "the last two minutes" must cover two minutes, which at high heart rates a beat count does not guarantee. The 2 s slack equals the 2000 ms ceiling of a plausible beat, because trimming keeps the oldest beat at or after the cutoff and a full window can measure one RR interval short of 120 s. The progress bar uses the gate's own 118 s, so 100 % means the gate passes.

#### 3.1.3 Artifact filter (trailing-median relative-deviation filter)

A window of fewer than 8 values is returned unchanged with a count of 0. Otherwise:

1. **Mark.** For each beat in order: mark it if `rr < 300` or `rr > 2000` ms; else, if a reference list `recentClean` holds at least 3 values, take `med = sorted[⌊count/2⌋]` (the upper middle value for an even count) and mark the beat if `|rr − med| / med > 0.20`; else accept it. Accepted beats are appended to `recentClean`, which keeps at most 5 values. Artifacts never enter the reference.
2. **Interpolate in place.** Each marked beat at i takes `rr[l] + (rr[r] − rr[l]) · (i − l)/(r − l)` from the nearest unmarked neighbours l < i < r; with one neighbour it copies that value; with none it is left unchanged.
3. **Return** the series (same length) and `correctedCount`, the number of marked beats.

**Why it works.** A median of recent beats tracks gradual heart-rate change while ignoring a single outlier, and a relative threshold scales with heart rate. Building the reference only from accepted beats means a premature beat and its compensatory pause cannot pull the reference toward themselves. Interpolating in place keeps length and order, so DFA's boxes are not shifted by deletions. The count travels with the values because in-place interpolation hides how much was replaced. The 6 % refusal follows the published finding that correction bias is minimal below about 3 % and small at 6 % [4][5].

#### 3.1.4 Recompute and status machine

A recompute that passes the gate cleans the window; a corrected fraction above 0.06 sets `tooManyArtifacts(fraction)`, a failed DFA sets `fitFailed`, and either clears α1, band and R²; otherwise α1, R² and band are published. The status refresh checks, in order: silence over 40 s (`stalled`, clear); gate failure (`warmup(fill)`, clear); a published value (`ok`); after `stalled`, `warmup(fill)`; otherwise the current reason stands until the next recompute (Appendix B2).

Invariant: α1 is non-nil exactly when the status is `ok`. The live display, voice coach, Watch and per-second workout sample all read this field, so a rejected or stale window writes nil into the sample stream.

**Why clear instead of hold.** One field and one invariant govern every consumer. A number shown during a coaching decision should have been computed from the last two minutes; a gap tells the athlete the truth where a held value would not. The silence check runs first because a stalled strap invalidates every other state, and 40 s (two cadences) separates a dropout from notification batching.

#### 3.1.5 DFA core and bands

The DFA core is prior art [1], given for reproducibility. Require n ≥ 64; integrate `y[k] = Σ_{j≤k} (rr[j] − mean)`; generate box sizes from `lo` by ratio 2^(1/8), rounded, with consecutive duplicates dropped, up to `hi`, appending `hi` if not last (α1: `lo = 4`, `hi = min(16, ⌊n/4⌋)`, giving {4,5,6,7,8,9,10,11,12,13,15,16} for n ≥ 64; α2: `lo = 16`, `hi = min(64, ⌊n/4⌋)`). For each size s, split `y` into ⌊n/s⌋ non-overlapping boxes from the start, fit a least-squares line in each against index 0…s−1, and set `F(s) = sqrt(Σ residual² / (boxes · s))`. Regress ln F on ln s (ln F = −10 when F ≤ 0); the slope is α and R² the fit quality. α1 needs at least 3 sizes; α2 needs 3 sizes and n ≥ 256.

Bands: α1 ≥ 0.75 "Easy"; 0.50 ≤ α1 < 0.75 "Threshold"; α1 < 0.50 "Very Hard". Every surface calls one shared function. The 0.50 band is a coarse intensity label, not a claim about the second threshold.

#### 3.1.6 Offline re-analysis

For archived sessions: require at least 64 RR points and re-stamp them on the gap-corrected timeline; take duration as the stored duration, else the last offset, which must exceed 120 s; for t = 120, 140, … ≤ duration, take beats with offset in [t − 120 s, t) by a two-pointer sweep (O(n)); for windows of at least 64 beats, clean, reject above 0.06, else run DFA and emit `(t, α1, R²)`. Each per-second sample then takes the latest reading at or before its offset if that reading is less than 20 s old, else nil.

**Why the same pipeline.** Running the live filter, window, cadence and rejection offline lets older sessions benefit and keeps live and post-session numbers comparable; the gap-corrected timeline places each window where it really was. The 20 s limit is one cadence, so a sample carries only the reading that would have been on screen at that moment.

### 3.2 Post-hoc interpretation of α1

The input is the per-second samples, each carrying α1 or nil.

#### 3.2.1 Ectopic shadows

Walk the α1 samples in order. Below 0.75, open a dip at the sample's offset (`start`) if none is open, tracking the deepest point. At or above 0.75 with a dip open, let `span = offset − start`; if `0 < span ≤ 120 s`, emit a shadow over `[max(0, start − 60), offset + 120)` with the deepest point as the chart marker; close the dip either way. A dip open at session end is not labelled. Shadows are drawn with a neutral "beat artifact" marker, and samples inside them are left out of average, maximum and minimum α1 and band-time totals.

**Why window length discriminates.** An isolated bad beat affects α1 only while it is inside the 120 s window, so a dip that recovers within one window is consistent with a single artifact, while a real intensity change keeps α1 low as long as the effort lasts. The padding follows the window's geometry: 60 s before covers the approach, as α1 falls once the beat enters; 120 s after covers the recovery shoulder, still contaminated until the beat leaves. A dip open at the end has unknown duration, so it is not judged.

#### 3.2.2 Band totals and the first sustained AT1 crossing

Each sample counts for `dt = min(max(1, offset − previousOffset), 5)` s (1 for the first); shadow samples are skipped. From 120 s on, α1 ≥ 0.75 sets `armed` and resets the pending crossing and counter; α1 < 0.75 while armed records a pending offset and the HR at that sample if none is pending, adds `dt`, and at 180 s returns `(pendingOffset, pendingHR)`.

**Why these rules.** A 180 s sustain exceeds the 120 s window, so no single-beat artifact can satisfy it. The 120 s warm-up skips the first window. Arming at ≥ 0.75 makes a crossing a transition from easy to harder. The 5 s cap keeps a strap gap from counting as time in a band.

#### 3.2.3 Crossing list and the LT1 card

A second routine lists crossings of 0.75 (AT1) and 0.50 (AT2), one tracker per threshold, over samples from 120 s (the previous value may precede 120 s), with `dt = max(1, offset − previousOffset)`. Below the threshold: if the previous α1 was at or above it and nothing is pending, create a pending down-crossing with offset, α1, HR and pace; add `dt`; emit the pending down-crossing once the counter reaches 180 s. At or above: if a pending down-crossing had reached 180 s, emit an up-crossing with the current HR and pace; clear pending and counter. The first 6 events are kept.

The "α1-estimated aerobic threshold (LT1)" card shows the HR and time of the first down-AT1 crossing with an HR, labelled "estimate" with a caption giving roughly ±10 bpm lab agreement. It is deliberately not offered as an LTHR setting: LT1 sits well below LTHR, and LTHR is the hrTSS denominator, so substituting it would inflate every later load figure.

### 3.3 Training-load ladder

Every archived workout resolves one load figure and a source tag; the first applicable tier wins:

| # | Source | Rule | Scale |
|---|---|---|---|
| 1 | Power | Stored IF > 0 and moving seconds (last sample offset) > 60 → `IF² × moving_h × 100`; else stored power TSS > 0; else **read-time power TSS**: NP > 0, an FTP for the sport, moving seconds > 60 → `(NP/FTP)² × moving_h × 100` | TSS |
| 2 | Route history (replacement) | `routeEstimateReplacesHRLoad` (§3.4.4) and an estimate exists | Banister TRIMP |
| 3 | hrTSS | stored hrTSS > 0 | TSS |
| 4 | METs | computed MET load > 0 | TSS-like |
| 5 | Banister TRIMP | stored TRIMP > 0 | Banister TRIMP |
| 6 | Route history (last resort) | stored estimate > 0 | Banister TRIMP |

**Why this order.** Power measures external work directly and is unaffected by strap dropouts, so it leads. The route estimate outranks heart rate only when there is positive evidence of a dropout (§3.4.4); otherwise measured heart rate is preferred to history. hrTSS precedes MET load and raw TRIMP because it is individualised to the user's threshold. The route estimate returns last so a workout with no other source still contributes something grounded in the user's own history.

**FTP.** Running-family sports (run, trail run, walk, hike, treadmill) use the user's running FTP, else the automatic estimate; cycling (outdoor and indoor) uses only a user-entered FTP; other sports have none. The automatic running FTP: over running-family workouts of the last 90 days, build a per-second power array by sample offset (0 ≤ offset < 24 h; a second is empty unless watts > 0); slide a 1200 s window and, where it is full and holds at least ⌈0.9 × 1200⌉ = 1080 readings, take the mean of the readings present; `FTP = round(0.95 × best)` across sessions, stored with its source session, or cleared if none qualifies; recompute at most every 7 days unless forced. The coverage rule ensures the best 20 minutes is a genuinely continuous effort. Because tier 1 is evaluated when the record is read, sessions that stored NP before any FTP existed count as power TSS once one is available, with no migration.

**hrTSS** = `TRIMP_session / TRIMP_ref × 100`, where TRIMP_ref is Banister TRIMP for 60 one-minute samples at LTHR (the user's value, else `0.88 × HRmax`); it requires HRmax and resting HR.

**Banister TRIMP** [8][9]. Per beat: `HR = 60000/rr`, duration `rr/1000` s, `HRR = clamp((HR − HRrest)/(HRmax − HRrest), 0, 1)`, `TRIMP += (dur/60) · HRR · A · e^(k·HRR)`, with A = 0.64, k = 1.92 (male) and A = 0.86, k = 1.67 (female); at least 30 beats. Without both HR anchors, an Edwards five-zone %HRmax fallback is used [13].

**MET load.** Per-sample METs from a table keyed on sport and speed; load `MET_hours / 12 × 100`, reported above 0.5. The per-sample path needs at least 30 samples with METs on at least a quarter, each counting for the gap to the next sample clamped to 1–30 s. The fallback uses one bucket: distance > 50 m, mean speed 0.5–60 km/h, moving duration ≥ 60 s, METs at the mean speed.

**Scales.** Power TSS and hrTSS put 100 at one hour at threshold, and MET load uses the same nominal anchor; Banister TRIMP and the route estimate are on the Banister scale. Each workout is labelled by source ("LOAD" or "TRIMP") and enters unconverted.

**Daily series and PMC.** A workout figure is capped at 1000; workouts with no precomputed figure use a summary Banister TRIMP from average HR, else 0. Loads are summed per local day (0 on rest days), capped at 1200. `X_today = load·(1 − e^(−1/τ)) + X_yesterday·e^(−1/τ)` with τ = 7 days (ATL) and 42 days (CTL); `TSB = CTL − ATL`. This is the standard Performance Manager construction [10] and is not claimed; fitted Banister parameters are unstable [14], so fixed constants are used.

### 3.4 Route-matched load substitution

#### 3.4.1 Route matching

Only routes the user has saved and named are used; the archive is not mined. Matching runs for run, trail run, walk, hike and bike, against saved routes of the same sport:

1. Require at least 2 points and a travelled length L ≥ 500 m.
2. Test each saved route forward and reversed; the reversed candidate is rebuilt from the reversed points, so its climb profile matches the direction of travel.
3. For each direction: start gate 150 m from the candidate's first point; prefix up to L + 200 m (including the crossing point), thinned to points ≥ 5 m apart (first and last kept); live track subsampled to 300 points at ⌊i · N/300⌋ if longer; fit = mean distance from each live point to the nearest prefix point; accept at ≤ 30 m.
4. Return the accepted candidate with the lowest fit across routes and directions.

A prefix of the travelled length plus 200 m lets a route be recognised before it is finished; thinning and subsampling bound the search cost and make it independent of recording density.

#### 3.4.2 Priors and estimate

The matched route's first and last points are both start anchors. A prior must have ended at or before the current workout's first GPS fix, share its sport, not be a recovered partial session, not itself be a replaced dropout (§3.4.4), start within 150 m of either anchor, and re-match *this* route over its whole track. Each prior gives `ratio = TRIMP / distance_m` (both > 0). With more than one ratio, drop those below 0.5 × median (mean of the middle pair for an even count); `priorAvg` is the mean of the rest and n their count. With `today = recordedTRIMP / recordedDistance` when both are > 0:

1. Both exist and `today ≥ 0.7 × priorAvg`: no estimate; the recorded value stands.
2. Both exist otherwise: `(0.6·priorAvg + 0.4·today) × D`, confidence `c_p`.
3. Only `priorAvg`: `priorAvg × D`, confidence `c_p`, marked prior-dominant.
4. Only `today`: `today × D`, confidence 0.4.
5. Neither: no estimate.

`c_p = min(0.85, 0.4 + 0.15·n)`. The target distance D is the saved route distance S when the recorded distance is missing or ≤ 0, within 0.9–1.1 × S, or below S in a possibly truncated recording (crash-recovered or saved as interrupted); otherwise the recorded distance, so a partial run is credited for the distance covered and a longer run in full. Estimate, confidence and route name are stored on the workout, computed at finalize (not truncated), in crash recovery (truncated) and in a background backfill (truncated only for crash or interrupted sessions).

#### 3.4.3 Why route-matched substitution works

A run's load depends on the course and the runner. A saved route fixes the course (distance, climb, terrain), and direction-aware matching keeps the climb profile aligned. The user's own TRIMP-per-metre on that course fixes the runner, including heart-rate anchors and usual effort there. The prior filters keep the reference clean, and excluding earlier substituted dropouts means an estimate never feeds on another estimate. The median-based outlier drop removes earlier dropouts the app did not detect, which would otherwise pull the estimate toward the failure it corrects. The 0.7 threshold leaves an ordinary easy day untouched, the 60/40 blend keeps what the partial recording captured, and confidence grows with the number of supporting runs.

#### 3.4.4 When the estimate replaces the recorded load

`routeEstimateReplacesHRLoad` holds when the estimate is > 0, its confidence is > 0.4 (it rests on at least one prior), and `recordedTRIMP` (0 if absent) is < 0.5 × estimate. Because case 2 blends in 40 % of the recorded value, this means the recording is under roughly 37 % of the user's usual load on the route, which indicates a dropout rather than an easy day. The estimate then takes tier 2; otherwise it is tier 6 only. Requiring a prior means a replacement always rests on history. The UI always shows the recorded value next to the estimate.

### 3.5 Training readiness

Inputs: R_rec, the morning recovery score (0–100); todayTrimp; CTL; ATL; morningATL; ACR; and, only when todayTrimp > 0, the resolved loads of workouts in the last 72 h with hours since each (on rest days ATL already carries yesterday's load and the freshness bonus handles dissipation).

1. **Acute fatigue.** With recent loads, `raw = Σ load_i · e^(−h_i/24)`, `acute = 0.30 · raw`; without, `raw = todayTrimp`, `acute = 0.35 · todayTrimp`.
2. **Base.** If CTL ≥ 3.2, map `(ATL + acute)/CTL` piecewise-linearly through (0 → 100), (0.8 → 85), (1.0 → 70), (1.3 → 50), (1.5 → 30), (2.0 → 10), held at 10 above 2.0 (≤ 0 gives 100). Below 3.2, `max(10, 100 − 0.5·(ATL + raw))`.
3. **ACWR damper**, only if ACR > 1.3: `p = min(0.05 + 0.5·(ACR − 1.3), 0.40) · min(max(CTL, 0)/50, 1)`; if R_rec ≥ 70, `p ← min(p, 0.10)`; `readiness ← readiness · (1 − p)`. No low-ratio "detraining" penalty is applied, with reference to [12].
4. **Freshness.** If morningATL > 0, add `min(1.5 · max(0, morningATL − ATL), 20)`.
5. **Asymmetric blend.** Above R_rec: `R_rec + (readiness − R_rec) · min(max(CTL,0)/40, 1) · 0.55`. Below: `readiness + (R_rec − readiness) · 0.30`.
6. Non-finite becomes 50; clamp to 0–100. Displayed ÷10 as Ready (≥ 7), Moderate (≥ 4.5), Fatigued (≥ 2) or Rest; "Ready" becomes "Moderate" when a separate advice gate recommends an easier session.

**Frozen and live.** At morning acceptance readiness is computed once with todayTrimp = 0, morningATL = ATL and ACR = ATL/CTL, and stored on the 0–10 scale with the session. During the day, with `f = clamp(h/24, 0, 1)` for h hours since the morning session ended, `ATL_eff = ATL_m + (ATL_live − ATL_m)·f`, `CTL_eff = CTL_m + (CTL_live − CTL_m)·f` and `ACR = ATL_eff/CTL_eff` when CTL_eff > 0, with morning values from the frozen snapshot (0 if missing). The freshness anchor is ATL_m, except at f = 1, where ATL_eff is used and the bonus collapses to 0. Without training metrics, readiness equals the recovery score. The narrative says training "pulled readiness down" or rest "lifted" it when the gap to the morning score is at least 3 points.

**Why it works.** Readiness asks whether there is capacity for more load today. ATL/CTL answers relative to what the user is accustomed to. ATL updates once a day, so the 72 h acute term (τ = 24 h) makes this morning's session count now and fade on a physiological time scale. Below CTL 3.2 the ratio is meaningless, so a strain branch takes over. The ACWR penalty is scaled by CTL/50 because the ratio is unstable at low chronic load [12], and capped at 10 % when recovery is at least 70 so a ratio cannot overrule a direct autonomic measurement of good recovery. The blend is asymmetric for the same reason: an optimistic load model is only partly trusted, less so at low CTL, and a pessimistic one is lifted modestly. Freezing the morning value makes history reproducible; interpolating from it keeps the live figure continuous at acceptance.

### 3.6 Fusing the two strap paths

Each 1 s tick, in order:

1. **Phone strap.** New beats go to the α1 analyzer; live HR = `60000 / median(last 8 RR > 0)` (middle-pair mean for an even count); `lastStrapHRAt = now`.
2. **Watch-relayed strap.** Only if the Watch reported strap data within 10 s: always drain the relayed RR queue (filtered to a plausible range), but **use** it only if `lastStrapHRAt` is ≥ 5 s old or absent. Used beats get wall-clock times assigned backward from the batch's arrival by the cumulative interval sum, on the phone stream's clock; they go to a separate buffer and the α1 analyzer, the Watch-reported strap HR is shown, and `lastWatchRoutedHRAt` is stamped.
3. **Arbitration** (pure function, strap mode). After more than 10 s of silence on both strap channels, show wrist HR received within 30 s; with none, clear the HR rather than leave it stale. A "strap not connected" or "strap silent" notice appears only after 15 s of recording and only while both channels are silent. Watch mode always uses wrist HR.

**Merge at finalize.** Start from the phone buffer if the workout's source was the strap, else from nothing (an old buffer may hold another session's beats). With no Watch beats, return the phone buffer. If any point lacks a wall-clock time, concatenate and sort by `t_ms`. Otherwise interleave by `wallClockMs`, phone first on ties, each side keeping its own order (a phone batch shares one arrival time), then rebuild `t_ms` as the running sum of `rr_ms` from the first point.

**Why it works.** A strap can be linked to phone and Watch at once, so both paths can carry the same beats. Treating the phone as primary and the Watch as a standby after 5 s of phone silence gives one stream with continuity through a phone dropout; draining the queue while the phone is live stops those beats being replayed later. Arrival time is the only clock the two paths share: ordering by `t_ms` would place beats the Watch carried through a phone dropout among the phone's later beats, because the phone's `t_ms` omits the gap.

### 3.7 Per-split α1 and decoupling (standard)

A distance split's time window is found by walking the stored track to the cumulative distance of the split's end (that fix's timestamp; the split's own duration if the track does not line up), and its α1 is the mean of sample α1 in [start, end). Pa:Hr decoupling [10] halves moving time (paused steps and the step across a resume add nothing), computes `EF = (distance/seconds)/mean HR` per half on the gap-corrected timeline, and reports `(EF₁ − EF₂)/EF₁ × 100`, withheld under 5 minutes or 500 m.

---

## 4. Verification

An independent check on public PhysioNet recordings was run on 2026-10-08; the independent validation report, `Tools/validation/RESULTS.md`, gives its full method and results. The methods were re-implemented in Python from the Swift source at e028039, and a port's results were accepted as the app's only after it reproduced the app's own unit-test expectations.

**Port fidelity.** Across eight test suites, 114 of 114 cases were reproduced, including DFAAnalysisTests (15 of 15), DFAReferenceValidationTests (9 of 9) and LiveDFAAnalyzerTests (19 of 19). On the seeded known-exponent processes (white, 1/f and Brownian noise, 4096 samples), the port reproduces the app's measured α1 values exactly.

**Artifact correction (nsr2db).** 1,080 artifact-free 120 s windows from 54 normal-sinus-rhythm Holter records (clean α1 1.20 ± 0.28) received premature ectopic beats with a compensatory pause, or missed beats, at fixed rates, following the design of Rogers et al. [5], with 3,240 trials per cell.

| Artifact | Rate | α1 bias, no correction | α1 bias, app filter | MAE no correction / app |
|---|---:|---:|---:|---|
| ectopic | 1 % | −0.549 | −0.005 | 0.549 / 0.021 |
| ectopic | 3 % | −0.771 | −0.020 | 0.771 / 0.061 |
| missed | 1 % | −0.433 | −0.008 | 0.505 / 0.054 |
| missed | 3 % | −0.590 | −0.023 | 0.598 / 0.097 |

At these rates the filter removes almost all of the bias that uncorrected artifacts introduce. Beat times in this check come from ECG annotations of resting and daily-life recordings. This paper documents the live α1 method; accuracy of α1 during exercise, and agreement of the α1 crossing with laboratory thresholds for an individual user, are not claimed.

**Register status.** The project's science register (scoring version v3.1.oct2026) records:

| Register entry | Status | Scope |
|---|---|---|
| dfa-a1-exercise-threshold | supported-transfer | Live intensity band; LT1 estimate |
| dfa-artifact-rejection | validated | The 3 %/6 % correction thresholds, from the published bias figures [4] |
| training-load-ladder | supported-transfer | ATL, CTL, TSB |
| acwr-readiness-damper | awaiting-validation | ACWR damper and freshness bonus in readiness |

The register's allowed language for training load is "bookkeeping on training history, never a prediction of performance", and for the ACWR damper "damper, bookkeeping", never injury risk. Emuqu is not a medical device, and nothing in this paper predicts performance or injury.

---

## 5. What Is New

Each statement below gives only the part that is new after a prior-art search made on 2026-10-08. The search covered public source code (FatMaxxer read directly at commit 3b10aa0; GoldenCheetah), public vendor and app documentation, and the DFA α1 and training-load literature. Where a vendor page could only be seen as a search-engine extract, the reference says so. "Earliest dated record" gives the first commit in the author's private repository lineage (§8.2) that contains the rule and, where it differs, the commit that completed the current form. All dates are author dates.

N1. Withholding a live α1 value, rather than displaying it with a reliability colour, until the rolling 120 s window holds at least 64 beats *and* its contents span at least 118 s (window length minus one maximal RR interval) as measured on the dropout-compensated beat clock of N2 rather than on elapsed session time, and showing warm-up progress as min(count/64, span/118) so that 100 % coincides with the gate passing.
Builds on: FatMaxxer's elapsed-time reliability colouring ("undefined" before 20 s, "unreliable" before 120 s) [21] and Watchletic's rolling 120 s window with a minimum of 160 source beats [22]; adds withholding the value on a dual beat-count and beat-clock span gate with matching progress.
Earliest dated record: flow-recovery 50da878, 2026-04-21 (64-beat gate, beat-only fill); current form emuqu-dev 7d6b4a6, 2026-09-03 (118 s span gate and min-of-ratios fill), measured on the N2 clock from emuqu 14ecd58, 2026-10-06.

N2. Stamping each live beat with start = max(previous beat's end, arrival time − first arrival time + first beat's start), and using that one clock both to trim the rolling window and to measure its span, together with an offline closed form (interval-sum time plus the running maximum of the wall-clock lead over the interval sum) that yields identical offsets.
Builds on: FatMaxxer's live window trimmed on arrival time and its file replay that rebuilds time from the RR sum [21]; adds a single dropout-compensated clock shared by trimming and span measurement, with an equivalent offline form.
Earliest dated record: flow-recovery 95e7ae8, 2026-04-20 (window trimmed on wall-clock time); offline closed form emuqu 554540f, 2026-10-03; live beat clock emuqu 14ecd58, 2026-10-06.

N3. A live artifact filter that judges each beat against the upper median of up to five preceding *accepted* beats (rejected beats never enter the reference; at least three needed to judge; 20 % relative deviation; 300–2000 ms bounds), replaces marked beats by linear interpolation in place, returns the count of marked beats alongside the series, and withholds α1 when that count exceeds 6 % of the window.
Builds on: FatMaxxer's previous-beat deviation filter, which drops beats beyond 5 % (workout mode) or 25 % (light mode) and displays the dropped percentage [21]; Watchletic's skipping of windows with too many corrections [22]; AlphaHRV's treatment of more than 5 % artifacts as affecting α1 [23]; HRV Logger's artifact rate [24]; and Kubios median-referenced threshold correction [15][16]; adds an accepted-only trailing reference, in-place interpolation with a carried count, and refusal above 6 %.
Earliest dated record: flow-recovery 50da878, 2026-04-21 (filter rules); corrected count and 6 % refusal emuqu-dev 7d6b4a6, 2026-09-03.

N4. A five-state live α1 status (warm-up with fill fraction, ok, stalled after twice the recompute cadence of beat silence, fit failed, too many artifacts with fraction) in which the silence check runs first and every non-ok state clears the published value, so the per-second sample stream records nil instead of the last α1.
Builds on: FatMaxxer's elapsed-time colour states [21]; adds clearing the value, on screen and in the recorded samples, in every non-ok state including silence and rejection.
Earliest dated record: flow-recovery 50da878, 2026-04-21 (warm-up, ok, stalled, fit failed); too-many-artifacts state emuqu-dev 7d6b4a6, 2026-09-03; clearing on every non-ok state emuqu 14ecd58, 2026-10-06.

N5. Labelling a post-session α1 dip below 0.75 as an ectopic "shadow" when it recovers within one analyzer window (≤ 120 s), excluding an asymmetric span from 60 s before the dip to 120 s after recovery from α1 summary statistics and band time, and leaving unlabelled a dip still open at session end.
Builds on: the general observation that ectopic beats lower α1 (a Medium blog post by M. Altini, seen as a search extract only); adds a window-length rule that identifies and excludes the affected span.
Earliest dated record: flow-recovery 549f747, 2026-04-23 (same 120 s limit and 60/120 s padding); shared exclusion for all summary statistics emuqu-dev 680bbee, 2026-08-25.

N6. Accepting a downward α1 threshold crossing only after α1 has stayed below the threshold for longer than the analyzer window (180 s against 120 s), counting time per sample capped at 5 s, starting only after a 120 s warm-up and only once α1 has first been seen at or above the threshold, and reporting the HR at the start of that sustained run.
Builds on: the HR at α1 = 0.75 as an aerobic-threshold proxy [2] (not claimed), and the ramp-regression and clustering threshold estimates of Runalyze and AI Endurance (search extracts only) [26]; adds a sustain rule longer than the window for arbitrary field sessions.
Earliest dated record: flow-recovery 50da878, 2026-04-21 (crossing without a sustain rule); 120 s warm-up and 180 s sustain flow-recovery 549f747, 2026-04-23; 5 s cap emuqu 554540f, 2026-10-03; armed-after-≥ 0.75 rule emuqu 5c4a23d, 2026-10-04.

N7. Within a load-source ladder, a route-history estimate tier that is promoted above every heart-rate-derived tier only when the estimate rests on at least one earlier run of the same saved route (confidence above the no-prior value 0.4) and the recorded TRIMP is below half of it, and that otherwise is used only when no other source exists.
Builds on: public fallback ladders: GoldenCheetah's TriScore, which falls back to TRIMP zonal points when the primary score is zero [25], TrainingPeaks' order of power TSS, rTSS and hrTSS, and intervals.icu's per-sport load priority [26]; adds a conditional promotion rule driven by dropout evidence.
Earliest dated record: flow-recovery b0967a8, 2026-05-12 (ladder with the route estimate last); promotion rule emuqu 554540f, 2026-10-03.

N8. Estimating the load of a workout with a failed heart-rate strap from the user's own TRIMP-per-metre on earlier runs of a user-named saved route, where the route is matched in either direction (after ≥ 500 m; start within 150 m; mean nearest-point distance ≤ 30 m from at most 300 evenly subsampled live points to a 5 m-thinned prefix of the saved route L + 200 m long), and earlier runs must end before the workout, share its sport, start within 150 m of either route end, re-match the same route over their whole track, and be neither recovered partial sessions nor themselves load-substituted dropouts.
Builds on: intervals.icu's estimate of load from average HR with a model fitted to the athlete's earlier activities [26]; adds estimation from same-route history.
Earliest dated record: flow-recovery fba6e27, 2026-04-26 (route matching: 500 m, ≤ 30 m, both directions); TRIMP extrapolation flow-recovery 6c127eb, 2026-04-27; estimator type flow-recovery b0967a8, 2026-05-12; prior filters emuqu 554540f, 2026-10-03; 300-point subsample and 5 m thinning emuqu 5c4a23d, 2026-10-04.

N9. Dropping earlier-run TRIMP-per-metre ratios below half their median, then choosing between no estimate (recorded ratio ≥ 0.7 × prior mean), a 60/40 prior/recorded blend, prior only, or recorded only; scaling to the recorded distance, or to the saved route distance when the recording is within ±10 % of it, missing, or possibly truncated by a crash; and attaching a confidence of min(0.85, 0.4 + 0.15·n) for n retained earlier runs, or 0.4 with none.
Builds on: Banister TRIMP [8] as the per-run load measure; adds the outlier rule, case selection, distance scaling and confidence. No public estimator of this form was found in public code, vendor documentation or the training-load literature.
Earliest dated record: flow-recovery 6c127eb, 2026-04-27 (ratio and min(0.85, …) confidence); 0.7 ×, 60/40 and 0.4 rules flow-recovery b0967a8, 2026-05-12; outlier drop emuqu 554540f, 2026-10-03; truncation rule emuqu 5c4a23d, 2026-10-04.

N10. Computing power TSS when a record is read, for workouts stored with normalized power but no TSS, from an FTP that is user-entered or estimated as 0.95 × the best 20-minute mean power over the last 90 days of running-family workouts, counting only 20-minute windows with at least 90 % per-second power coverage.
Builds on: the 0.95 × 20-minute convention [10] (not claimed) and Stryd's critical-power estimate from about 90 days of data [26]; adds read-time derivation for stored history and the coverage rule.
Earliest dated record: flow-recovery b0967a8, 2026-05-12 (0.95 × best NP; read-time power TSS); rolling 20-minute window with 90 % coverage emuqu 554540f, 2026-10-03.

N11. A training-readiness score that adds a 72 h exponentially decaying acute-fatigue term (τ = 24 h, weight 0.30, used only on days with training) to ATL inside a piecewise capacity-ratio map, switches to a strain branch below a CTL of 3.2, scales any ACWR penalty above 1.3 by min(CTL/50, 1), caps that penalty at 10 % when the morning recovery score is at least 70, adds a capped freshness bonus for ATL dissipated since morning, and blends the result asymmetrically with the recovery score (excess trust min(CTL/40, 1) × 0.55; deficit uplift 0.30).
Builds on: the Banister fitness–fatigue model [8], Garmin's published Training Readiness inputs (formula not published) and Polar's cardio load status comparing strain with tolerance [26]; adds this combination and its reconciliation with the morning HRV score.
Earliest dated record: flow-recovery-dev c48eeb9, 2026-03-01 (squashed first commit: capacity map, freshness bonus); acute fatigue and asymmetric blend flow-recovery-dev 6eddc97, 2026-03-15; CTL 3.2 branch flow-recovery c63d56c, 2026-04-23; CTL/50 ramp and rescue cap flow-recovery 6da94a6, 2026-05-01.

N12. Interpolating ATL and CTL during the day from a frozen morning snapshot toward live values by hours-since-morning/24, so that live readiness equals the frozen value at acceptance and the freshness anchor collapses once the snapshot is more than a day old.
Builds on: Garmin's documented intra-day updates of Training Readiness [26]; adds a published interpolation from a frozen snapshot.
Earliest dated record: flow-recovery d69cddd, 2026-03-24; stale-anchor collapse flow-recovery 870028e, 2026-04-05.

N13. Taking RR intervals relayed by a smartwatch from a chest strap only while the phone's own strap stream has been silent for at least 5 s, still draining the relay queue while the phone is live so beats are not replayed, and at finalize interleaving the two streams by arrival time, keeping each stream's own order, before rebuilding the beat timeline as a running sum of intervals.
Builds on: standard Bluetooth heart-rate RR delivery to phone and watch; no public fusion method of this kind was found in public code (FatMaxxer, GoldenCheetah) or vendor documentation.
Earliest dated record: flow-recovery 7b8c540, 2026-04-30 (Watch relay without the silence gate; strap connector d381c96, 2026-04-29); merge type emuqu-dev c615ce5, 2026-09-02; 5 s gate emuqu 554540f, 2026-10-03.

N14. Re-running the live α1 filter, window, cadence and 6 % rejection offline on the gap-corrected timeline of N2 (not on the interval sum), and writing each reading back to per-second samples only while it is less than one cadence (20 s) old, clearing α1 elsewhere.
Builds on: FatMaxxer's replay of a recorded RR file through its live pipeline, rebuilding time from the RR sum [21], and intervals.icu's post-ride DFA α1 [26]; adds the gap-corrected timeline and freshness-limited write-back.
Earliest dated record: flow-recovery 50da878, 2026-04-21 (offline re-run with the live parameters); 6 % rejection emuqu-dev 7d6b4a6, 2026-09-03; gap-corrected timeline and freshness-limited write-back emuqu 554540f, 2026-10-03.

**Not claimed (prior art).**
- Detrended fluctuation analysis, its integration and box detrending, and the 4–16 / 16–64 scale ranges with 2^(1/8) log spacing [1].
- The interpretation of α1 ≈ 0.75 as an aerobic-threshold proxy and ≈ 0.50 as a higher-intensity marker [2][3][4].
- The published effect of artifact correction on α1 and the 3 %/6 % figures [4][5].
- Threshold-based RR artifact correction in general, including Kubios-style median-relative filters [15][16].
- Live α1 on a rolling 120 s window recomputed every 20 s; marking α1 as unreliable before a minimum elapsed time; requiring a minimum beat count; dropping artifact beats and displaying the artifact percentage; skipping windows with too many corrections; replaying a recorded RR file through the live pipeline [21][22][23][24].
- Load-metric fallback ladders as such [25][26].
- Banister TRIMP and its sex coefficients [8][9].
- The Karvonen heart-rate reserve [17].
- Edwards zone TRIMP [13].
- Coggan normalized power, intensity factor and TSS; hrTSS as TRIMP normalised to an hour at LTHR; the 0.95 × 20-minute FTP convention; LTHR ≈ 0.88 × HRmax as a population approximation; Pa:Hr decoupling and efficiency factor [10][18].
- The PMC exponentially weighted ATL/CTL/TSB [10].
- The acute:chronic workload ratio [11].
- MET values for activities [19].
- Median-of-recent-beats HR display smoothing.
- Barometric or GPS altitude handling, the "return to start" bearing aid, Bluetooth packet parsing and PDF report layout are outside this paper and are not claimed.

---

## 6. Design Tradeoffs

**Withhold rather than flag.** Live α1 shows a gap instead of a low-reliability value, at the cost of fewer published values during warm-up, after dropouts and in noisy windows.

**Conservative artifact gate.** The 6 % gate counts corrected intervals, and one ectopic beat alters two, so windows are withheld somewhat earlier than an event count would suggest.

**A simple, fixed filter.** A 20 % deviation from a five-beat trailing median is transparent and cheap on device, at the cost of also correcting some genuine sinus variability, most at rest, and of withholding windows that straddle an abrupt sustained change in heart rate.

**No synthetic beats.** The beat clock decides which beats are in a window, but nothing is inserted for a dropout, so beats on either side of a short gap are adjacent in the DFA input.

**Sustained crossings.** The 180 s sustain makes crossings robust to single beats at the cost of missing excursions shorter than three minutes, and the reported HR is taken at the start of the run without lag correction.

**Unconverted load scales.** Route estimates and Banister TRIMP enter ATL/CTL on their own scale, labelled by source, so each figure stays traceable to how it was measured at the cost of a series that mixes TSS-scale and TRIMP-scale values.

**History-based substitution.** Route substitution needs a saved route and earlier clean runs, and TRIMP-per-metre does not adjust for pace, weather or fitness change between runs.

**Hand-set product rules.** The readiness constants, the shadow padding and the route-estimator thresholds are product rules chosen for consistency with the recovery score and with each other, not fitted outcome models.

**Running-only auto-FTP.** The automatic FTP uses running-family workouts; cycling FTP is entered by the user.

---

## 7. Comparison to Existing Approaches

### 7.1 Live and post-session α1

| Aspect | Emuqu (this paper) | Published method / product (public documentation or code) |
|---|---|---|
| DFA core | Peng DFA, boxes 4–16, ratio 2^(1/8), non-overlapping forward boxes | Peng et al. [1]; PhysioNet reference implementation (same principles) |
| Window and cadence | 120 s rolling, recomputed every 20 s | FatMaxxer: 120 s window, recompute every 20 s by default (user-set, minimum 5 s) [21]. Watchletic: 120 s, updated every 5 s [22]. AlphaHRV: 200-beat window, updated every 1–5 s [23]. HRV Logger: 2-minute windows [24]. Laboratory studies: 2-minute windows on Kubios-processed data [2][3][4] |
| When a value is shown | Withheld until ≥ 64 beats AND ≥ 118 s span on the beat clock | FatMaxxer: always shown, coloured "undefined" before 20 s and "unreliable" before 120 s of elapsed session time [21]. Watchletic: requires ≥ 160 source beats [22] |
| Window clock | Dropout-compensated beat clock, same clock for trim and span | FatMaxxer: trimmed on arrival time; replay rebuilds time from the RR sum [21] |
| Artifact handling | Trailing upper median of ≤ 5 accepted beats, ±20 %, linear interpolation in place, count carried, α1 withheld above 6 % | FatMaxxer: drops beats beyond ±5 % (workout) or ±25 % (light) of the previous beat, shows the dropped percentage, keeps showing α1 [21]. Watchletic: skips windows with too many corrections [22]. AlphaHRV: treats > 5 % artifacts as affecting α1 [23]. Kubios: threshold-based and automatic correction [15][16]. Effect sizes from Rogers/Gronwald [4][5] |
| Stale or rejected value | Cleared; nil written to the sample stream | FatMaxxer: last value stays on screen with its colour [21]; others: not stated in the material found |
| Post-hoc ectopic handling | Window-length shadow rule with 60/120 s padding | None found |
| Offline re-analysis | Same pipeline on the gap-corrected timeline; write-back only within 20 s | FatMaxxer: replays a recorded RR file through the live pipeline [21]. intervals.icu: post-ride DFA α1 [26] |
| Crossing rule | 180 s sustained, armed after ≥ 0.75, after 120 s warm-up | Laboratory protocols regress α1 against HR over incremental stages [2]; Runalyze and AI Endurance use ramp or cluster analysis [26] |

### 7.2 Training load and readiness

| Aspect | Emuqu (this paper) | Published method / product (public documentation or code) |
|---|---|---|
| Load model | Ladder: power TSS → (route, if dropout) → hrTSS → METs → TRIMP → route | TSS, hrTSS and the PMC: Allen & Coggan [10]. GoldenCheetah TriScore: BikeScore, GOVSS or SwimScore, falling back to TRIMP zonal points on zero [25]. TrainingPeaks: power TSS → rTSS → hrTSS; intervals.icu: per-sport load priority [26] |
| Strap dropout | Route-matched substitution from the user's own earlier runs, with confidence | intervals.icu: load estimated from average HR with a model fitted to earlier activities [26]. No public route-based method found |
| Auto-FTP | 0.95 × best 20-min with ≥ 90 % coverage, 90 days, running | 0.95 × 20-minute test is Coggan's convention [10]; Stryd estimates critical power from about 90 days of data [26] |
| ACWR | Penalty > 1.3, damped by CTL/50, capped by recovery | Gabbett's ratio [11]; critique by Impellizzeri et al. [12] |
| Readiness | Capacity ratio + acute decay + asymmetric HRV blend; intra-day interpolation from a frozen morning value | Banister fitness–fatigue model [8]. Garmin Training Readiness: inputs published, formula not; updates through the day. Polar cardio load status: strain against tolerance [26] |
| Phone/Watch strap fusion | Watch relay used only after 5 s of phone silence; arrival-time interleave at finalize | None found |

---

## 8. Provenance and Dates

### 8.1 Project origin

These records show when the project began. They are origin evidence, not dates for any method in this paper.

- **AI-Fitness-Coach repository** (private, Chris Sharp): 19 commits on 2025-02-16 and 2025-02-17. It read HealthKit HR and HRV (SDNN) for display, streamed HR from a Polar H10 over Bluetooth, and estimated VO₂max. It contains none of the methods described here.
- **The author's ChatGPT design history.** The earliest recovered HRV-specific design exchange is a ChatGPT user message from Chris Sharp on 2025-02-22 at 15:44:18 UTC, proposing an app that has a user wear a Polar strap to bed, learns when they are about to wake and takes the HRV measurement then ("similar to what WHOOP tries to do, but I mean actually get it right"). This is a concept for timed overnight HRV measurement, not any method in this paper. The same day's exchanges place "HRV trends" in a broader fitness-app feature set; exchanges on 2025-03-04 and 2025-03-05 cover the build, deploy and test workflow and a VO₂max validation plan. (ChatGPT user messages, 2025-02-22 to 2025-03-05; excerpts recovered through conversation-history retrieval on 2026-10-08; full transcript and stable conversation ID not exposed.)

### 8.2 Repository lineage

| Repository | First commit | Notes |
|---|---|---|
| flow-recovery-old ("Flow HRV") | 2026-01-12 | 250 commits to 2026-01-26 |
| flow-recovery-dev | 2026-03-01 | Squashed first commit c48eeb9 |
| flow-recovery ("Flow Recovery") | 2026-03-15 | 196 commits to 2026-08-12 |
| emuqu-dev | 2026-08-16 | Squashed first commit d4e5cf8 |
| emuqu (github.com/chrissharp80/emuqu, PolyForm Strict 1.0.0) | 2026-09-08 | Public; first commit 9d89933 |

All repositories except emuqu are private. The author retains all of them with full history. The histories have gaps (2026-01-26 to 03-01, 08-12 to 08-16, 09-04 to 09-08) where later work arrived as a squashed first commit, so a squash date is a latest-possible date for what it contains.

### 8.3 Earliest commit per method

| N | First form (date, commit) | Current form (date, commit) |
|---|---|---|
| N1 | 2026-04-21, flow-recovery 50da878 | 2026-09-03, emuqu-dev 7d6b4a6 (on the N2 clock from 2026-10-06) |
| N2 | 2026-04-20, flow-recovery 95e7ae8 | 2026-10-06, emuqu 14ecd58 (offline form 2026-10-03, emuqu 554540f) |
| N3 | 2026-04-21, flow-recovery 50da878 | 2026-09-03, emuqu-dev 7d6b4a6 |
| N4 | 2026-04-21, flow-recovery 50da878 | 2026-10-06, emuqu 14ecd58 |
| N5 | 2026-04-23, flow-recovery 549f747 | 2026-08-25, emuqu-dev 680bbee |
| N6 | 2026-04-21, flow-recovery 50da878 (sustain rule 2026-04-23, 549f747) | 2026-10-04, emuqu 5c4a23d |
| N7 | 2026-05-12, flow-recovery b0967a8 | 2026-10-03, emuqu 554540f |
| N8 | 2026-04-26, flow-recovery fba6e27 | 2026-10-04, emuqu 5c4a23d |
| N9 | 2026-04-27, flow-recovery 6c127eb | 2026-10-04, emuqu 5c4a23d |
| N10 | 2026-05-12, flow-recovery b0967a8 | 2026-10-03, emuqu 554540f |
| N11 | 2026-03-01, flow-recovery-dev c48eeb9 (squash) | 2026-05-01, flow-recovery 6da94a6 |
| N12 | 2026-03-24, flow-recovery d69cddd | 2026-04-05, flow-recovery 870028e |
| N13 | 2026-04-30, flow-recovery 7b8c540 | 2026-10-03, emuqu 554540f |
| N14 | 2026-04-21, flow-recovery 50da878 | 2026-10-03, emuqu 554540f |

Other dated commits: the DFA known-exponent suite, 725da03, 2026-09-16 (public repository). Source revision described: e028039 (2026-10-07); scoring version v3.1.oct2026.

### 8.4 Dated non-git records (the author's own files)

- **2026-01-08, about 9 p.m. Central** (Drive file created 2026-01-09 03:06:59 UTC): the pre-implementation design document "Design: Connection + Offline RR Collection Harness (iOS + watchOS) – v9.2 FINAL", saved from an AI design conversation. It covers overnight capture and analysis (artifact detection, time-domain, nonlinear and spectral metrics); none of this paper's exercise methods appear in it.
- **2026-02-16, 2026-02-18, 2026-03-04:** app-generated "Flow_Recovery" PDF session reports (generation dates as printed in each footer) showing a readiness figure out of 10 next to CTL, ATL, TSB and ACWR. The reports do not show the formula.
- **2026-03-23:** a "Flow Recovery - Bluetooth" screen recording.
- **2026-04-24:** app screenshot IMG_5551 showing the ectopic-shadow rule in the app ("A single ectopic beat contaminates a1's 120-second rolling window for about the window's length … These dips are excluded from LT1 / threshold detection"). Earlier screenshots from the same session (IMG_5524, IMG_5526, IMG_5537) still report a crossing at 4:00, so the rule appeared that day. IMG_5527 shows "Re-analyze a1 … using the current Kubios-style filter".
- **2026-05-05:** screenshot IMG_6017, a "TRAINING READINESS 3.9 Rest" gauge.
- **2026-05-06 (uploaded 2026-05-10):** project README and "flow-recovery-audit.md" describing live α1 diagnostics (warming up with a percentage, strap silent for N seconds, fit failed), a Kubios-style ectopic filter with linear interpolation, re-analysis of α1 for old sessions, direction-agnostic route matching, power TSS, and training readiness from the recovery score plus a training-load modifier.
- **2026-05-13:** screenshots IMG_6245 and IMG_6262, "DFA a1 warming up - 0 % of 2-min window".

### 8.5 Disclosures

- **TestFlight beta** from 2026-01-27; 45 beta testers and over 6,500 sessions by 2026-08-10. Testers used the app; the beta did not publish its methods.
- **Private sharing.** The work was shared privately with two colleagues in January and March 2026.
- **Substack, 2026-05-19, "A Powerfully Lazy Man's Way to Better Health"** (public). It described overnight dual capture (internal strap recording plus a live stream, merged in the morning), resting DFA α1 "organized windows", and a search bounded to 30–70 % of sleep that picks the window with the highest RMSSD. Those are subjects of white paper 1. It did not describe any method in this paper.
- **Substack, 2026-08-10, "How I Build Production Software by Directing AI"** (public). It named the readiness score and gave the beta figures above, without describing the method.
- **Public repository** github.com/chrissharp80/emuqu, from 2026-09-08.
- **These white papers,** 2026-10-08.

### 8.6 Authorship

Chris Sharp <chrissharp80@gmail.com> is the sole author and the sole committer of every repository listed above. He directs AI coding assistants to write the code (some commits are attributed to "Claude") and supplies the requirements, design direction, review, testing and acceptance.

---

## References

1. Peng C-K, Havlin S, Stanley HE, Goldberger AL. 1995. Quantification of scaling exponents and crossover phenomena in nonstationary heartbeat time series. *Chaos* 5(1):82–87.
2. Rogers B, Giles D, Draper N, Hoos O, Gronwald T. 2021. A new detection method defining the aerobic threshold for endurance exercise and training prescription based on fractal correlation properties of heart rate variability. *Frontiers in Physiology* 11:596567.
3. Gronwald T, Rogers B, Hoos O. 2020. Fractal correlation properties of heart rate variability: a new biomarker for intensity distribution in endurance exercise and training prescription? *Frontiers in Physiology* 11:550572.
4. Rogers B, Gronwald T. 2022. Fractal correlation properties of heart rate variability as a biomarker for intensity distribution and training prescription in endurance exercise: an update. *Frontiers in Physiology* 13:879071.
5. Rogers B, Giles D, Draper N, Mourot L, Gronwald T. 2021. Influence of artefact correction and recording device type on the practical application of a non-linear heart rate variability biomarker for aerobic threshold determination. *Sensors* 21(3):821.
6. Schaffarczyk M, Rogers B, Reer R, Gronwald T. 2023. Validity of the non-linear index of heart rate variability DFA a1 to determine aerobic and anaerobic thresholds during incremental cycling exercise in women. *European Journal of Applied Physiology* 123:299–309.
7. Van Hooren B, Mennen B, Gronwald T, Bongers BC, Rogers B. 2023. Correlation properties of heart rate variability to assess the first ventilatory threshold and fatigue in runners. *Journal of Sports Sciences* (PMID 37916488).
8. Banister EW, Calvert TW, Savage MV, Bach T. 1975. A systems model of training for athletic performance. *Australian Journal of Sports Medicine* 7:57–61.
9. Morton RH, Fitz-Clarke JR, Banister EW. 1990. Modeling human performance in running. *Journal of Applied Physiology* 69(3):1171–1177.
10. Allen H, Coggan A. 2010. *Training and Racing with a Power Meter*, 2nd ed. VeloPress.
11. Gabbett TJ. 2016. The training–injury prevention paradox: should athletes be training smarter and harder? *British Journal of Sports Medicine* 50(5):273–280.
12. Impellizzeri FM, Tenan MS, Kempton T, Novak A, Coutts AJ. 2020. Acute:chronic workload ratio: conceptual issues and fundamental pitfalls. *International Journal of Sports Physiology and Performance* 15(6):907–913.
13. Edwards S. 1993. *The Heart Rate Monitor Book*. Polar Electro Oy.
14. Hellard P, Avalos M, Lacoste L, Barale F, Chatard J-C, Millet GP. 2006. Assessing the limitations of the Banister model in monitoring training. *Journal of Sports Sciences* 24(5):509–520.
15. Tarvainen MP, Niskanen J-P, Lipponen JA, Ranta-aho PO, Karjalainen PA. 2014. Kubios HRV – heart rate variability analysis software. *Computer Methods and Programs in Biomedicine* 113(1):210–220.
16. Lipponen JA, Tarvainen MP. 2019. A robust algorithm for heart rate variability time series artefact correction using novel beat classification. *Journal of Medical Engineering & Technology* 43(3):173–181.
17. Karvonen MJ, Kentala E, Mustala O. 1957. The effects of training on heart rate; a longitudinal study. *Annales Medicinae Experimentalis et Biologiae Fenniae* 35(3):307–315.
18. Friel J. *The Triathlete's Training Bible*. VeloPress (multiple editions).
19. Ainsworth BE, Haskell WL, Herrmann SD, et al. 2011. 2011 Compendium of Physical Activities: a second update of codes and MET values. *Medicine & Science in Sports & Exercise* 43(8):1575–1581.
20. Sempere-Ruiz N, Sarabia JM, Baladzhaeva S, Moya-Ramón M. 2024. Reliability and validity of a non-linear index of heart rate variability to determine intensity thresholds. *Frontiers in Physiology* 15:1329360. doi:10.3389/fphys.2024.1329360.
21. Peake I. FatMaxxer (open-source Android app for real-time DFA α1 with a Polar H10). GitHub repository IanPeake/FatMaxxer, source read directly at commit 3b10aa0 (2025-05-05); file app/src/main/java/online/fatmaxxer/publicRelease1/MainActivity.java. https://github.com/IanPeake/FatMaxxer (accessed 2026-10-08).
22. Watchletic. Blog post on reproducing DFA α1 on Apple Watch and Wear OS (app version 3.2.0), 2026. https://watchletic.com/blog/reproducing-dfa-alpha-1-on-apple-watch-and-wear-os (seen as a search-engine extract only; accessed 2026-10-08).
23. AlphaHRV (DFA α1 app). Public product documentation describing a 200-beat window, 1–5 s updates and a > 5 % artifact assumption. Seen as search-engine extracts only; the URL was not recorded (accessed 2026-10-08).
24. PubMed Central article PMC8193503 (reports HRV Logger's 2-minute windows and artifact rate). https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8193503/ (seen as a search-engine extract only; accessed 2026-10-08).
25. GoldenCheetah. TriScore metric, file src/Metrics/SwimScore.cpp: "On zero fallback to TRIMP Zonal Points for HR based score" (present since April 2018). https://github.com/GoldenCheetah/GoldenCheetah (source opened; accessed 2026-10-08).
26. Vendor and service documentation seen only as search-engine extracts in the 2026-10-08 prior-art search, URLs not recorded: TrainingPeaks (TSS source order power → rTSS → hrTSS); intervals.icu (per-sport load priority; HR-model load estimate; post-ride DFA α1); Stryd (critical power from about 90 days); Garmin (Training Readiness inputs; updates through the day); Polar (cardio load status); Runalyze and AI Endurance (α1 threshold estimation). Accessed 2026-10-08; re-check before reliance.

---

## Appendix A: Parameter Table

| Name | Value | Unit | Role |
|---|---|---|---|
| windowSec | 120 | s | Live and offline α1 window |
| cadenceSec | 20 | s | α1 recompute interval; offline sweep step; write-back freshness |
| minBeatsForFit | 64 | beats | Beat gate (live and offline) |
| windowSpanSlackSec | 2 | s | Span gate = 118 s |
| stalled threshold | 40 (2 × cadence) | s | Silence before α1 is cleared |
| cleaner minimum length | 8 | beats | Shorter series are returned unchanged |
| minRR / maxRR | 300 / 2000 | ms | Implausible-beat bounds |
| ectopicRatio | 0.20 | fraction | Relative deviation from the trailing median |
| trailing reference | ≤5 (≥3 to judge) | beats | Accepted beats used for the median |
| maxCorrectedFraction | 0.06 | fraction | Window rejection |
| α1 boxes | 4–16 | beats | Short-scale DFA |
| α2 boxes | 16–64 | beats | Long-scale DFA |
| box ratio | 2^(1/8) | — | Log spacing |
| max box | ⌊n/4⌋ | beats | Cap on box size |
| α2 minimum beats | 256 | beats | α2 reported only above this |
| alpha1AerobicThreshold | 0.75 | — | Easy/Threshold band edge; crossings; shadows |
| alpha1AnaerobicThreshold | 0.50 | — | Threshold/Very Hard band edge |
| alpha1WarmupSec | 120 | s | Ignore crossings before this |
| alpha1SustainSec | 180 | s | Sustain required for a crossing |
| crossing list cap | 6 | events | Card length |
| shadow max span | 120 | s | Dip recovery limit for a shadow |
| approachPad / recoveryPad | 60 / 120 | s | Shadow padding |
| maxSampleGapSec | 5 | s | Per-sample time cap in band totals |
| live HR median | 8 | beats | Display smoothing |
| Watch strap freshness | 10 | s | Relay considered at all |
| phone strap live | <5 | s | Watch relay ignored while live |
| wristFallbackSilenceSec | 10 | s | Fall through to wrist HR |
| wristHRMaxAgeSec | 30 | s | Wrist HR freshness |
| strapNoticeGraceSec | 15 | s | Delay before the strap notice |
| detectionTriggerMeters | 500 | m | Route matching starts |
| matchToleranceMeters | 30 | m | Mean fit limit |
| start gate | 150 | m | Start-point proximity (match and priors) |
| prefix extra | 200 | m | Saved prefix = travelled + 200 |
| maxScoredPoints | 300 | points | Live subsample |
| prefixSpacingMeters | 5 | m | Prefix thinning |
| outlier cut | 0.5 × median | — | Prior-ratio outliers |
| healthy ratio | 0.7 × prior | — | No estimate above this |
| blend | 0.6 / 0.4 | — | Prior / recorded |
| whole-loop band | 0.9–1.1 × route | — | Use the saved distance |
| confidence | min(0.85, 0.4 + 0.15·n) | — | With n priors |
| routeEstimateNoPriorConfidence | 0.4 | — | Today-only confidence; replacement floor |
| routeDropoutRecordedShare | 0.5 | — | Replacement when recorded < 0.5 × estimate |
| lookbackDays | 90 | days | Auto-FTP |
| effortWindowSeconds | 1200 | s | Auto-FTP window |
| minimumPowerCoverage | 0.9 | fraction | Auto-FTP window coverage |
| twentyMinuteToFTPFactor | 0.95 | — | Auto-FTP |
| auto-FTP refresh | 7 | days | Recompute interval |
| LTHR fallback | 0.88 × HRmax | bpm | hrTSS |
| Banister A, k (male) | 0.64, 1.92 | — | TRIMP |
| Banister A, k (female) | 0.86, 1.67 | — | TRIMP |
| minimum TRIMP beats | 30 | beats | TRIMP computed |
| MET threshold anchor | 12 | MET | MET load = MET-h / 12 × 100 |
| MET sample cap | 30 | s | Per-sample duration cap |
| MET valid share | 0.25 | fraction | Per-sample path |
| maxSingleWorkoutLoad | 1000 | load | Per-workout cap |
| maxDailyLoad | 1200 | load | Per-day cap |
| acuteDays / chronicDays | 7 / 42 | days | ATL / CTL τ |
| acute window | 72 | h | Recent loads |
| acuteFatigueTauHours | 24 | h | Acute decay |
| acuteFatigueCoefficient | 0.30 | — | With recent loads |
| acuteFatigueFallbackCoefficient | 0.35 | — | todayTrimp fallback |
| ctlThreshold | 3.2 | load | Low-CTL branch |
| novelLoadStrainCoefficient | 0.5 | — | Low-CTL branch |
| capacity map | 0→100, 0.8→85, 1.0→70, 1.3→50, 1.5→30, 2.0→10 | — | Base readiness |
| readinessFloor | 10 | points | Floor |
| acwrOverreachingThreshold | 1.3 | — | Penalty starts |
| penalty base / slope / cap | 0.05 / 0.50 / 0.40 | — | ACWR penalty |
| acwrFullConfidenceCTL | 50 | load | Confidence ramp |
| acwrRescueRecoveryThreshold | 70 | points | Rescue cap applies |
| acwrPenaltyAutonomicRescueCap | 0.10 | — | Rescue cap |
| freshnessGainMultiplier / cap | 1.5 / 20 | points | Freshness bonus |
| modelTrustDivisor / ceiling | 40 / 0.55 | — | Excess trust |
| recoveryUpliftFraction | 0.30 | — | Deficit uplift |
| labels | 7 / 4.5 / 2 | 0–10 | Ready / Moderate / Fatigued |
| narrative delta | 3 | points | "Pulled down" / "lifted" |
| decoupling minimums | 300 s, 500 m | — | Metric withheld below |

## Appendix B: Pseudocode for the Novel Methods

```
# B1 Beat clock (N2)
state: originWall=nil, originBeat=0, nextStart=nil
stamp(p):
  start = nextStart if nextStart != nil else p.t_ms
  if p.wall != nil:
    if originWall == nil: originWall = p.wall; originBeat = start
    start = max(start, p.wall - originWall + originBeat)
  nextStart = start + p.rr
  return p with t_ms = start

# B2 Live analyzer (N1, N3, N4)
ingest(points, now):
  if sessionStart == nil: return
  buf += [stamp(p) for p in points]
  if points nonempty: lastBeatAt = now
  if buf nonempty: cutoff = buf.last.t_ms - 120000; buf = [b in buf where b.t_ms >= cutoff]
  span = (buf.last.t_ms - buf.first.t_ms)/1000 if buf nonempty else 0
  fill = min(min(1, |buf|/64), min(1, span/118))
  if lastCompute != nil and now - lastCompute < 20: refresh(now); return
  lastCompute = now; recompute(now)

gate(): |buf| >= 64 and span >= 118

recompute(now):
  if not gate(): refresh(now); return
  (vals, k) = clean([b.rr for b in buf]); frac = k/|vals| (0 if empty)
  if frac > 0.06: status = TOO_MANY_ARTIFACTS(frac); clear(); return
  r = dfa(vals)
  if r == nil: status = FIT_FAILED; clear(); return
  alpha1 = r.alpha1; r2 = r.r2; band = band(alpha1); refresh(now)

refresh(now):
  if lastBeatAt != nil and now - lastBeatAt > 40: status = STALLED; clear(); return
  if not gate(): status = WARMUP(fill); clear(); return
  if alpha1 != nil: status = OK
  elif status is STALLED: status = WARMUP(fill)

clean(rr):
  if |rr| < 8: return (rr, 0)
  mask = []; recent = []
  for x in rr:
    bad = x < 300 or x > 2000
    if not bad and |recent| >= 3:
      s = sorted(recent); med = s[floor(|s|/2)]
      bad = abs(x - med)/med > 0.20
    mask.append(bad)
    if not bad: recent.append(x); if |recent| > 5: recent.pop_front()
  out = copy(rr)
  for i where mask[i]:
    l = nearest j<i with !mask[j]; r = nearest j>i with !mask[j]
    if l and r: out[i] = rr[l] + (rr[r]-rr[l])*(i-l)/(r-l)
    elif l: out[i] = rr[l]
    elif r: out[i] = rr[r]
  return (out, count(mask))

# B3 Ectopic shadows (N5)
shadows = []; dip = nil
for s in samples with s.alpha1 != nil:
  if s.alpha1 < 0.75:
    if dip == nil: dip = {start: s.t, deepT: s.t, deepA: s.alpha1}
    elif s.alpha1 < dip.deepA: dip.deepT = s.t; dip.deepA = s.alpha1
  else:
    if dip != nil:
      span = s.t - dip.start
      if 0 < span <= 120: shadows.append([max(0, dip.start-60), s.t+120), dip.deepT, dip.deepA)
      dip = nil
# an open dip at the end is discarded

# B4 First sustained AT1 crossing for summary statistics (N6)
prev = nil; armed = false; pend = nil; sus = 0; first = nil
for s in samples with s.alpha1 != nil:
  dt = 1 if prev == nil else min(max(1, s.t - prev), 5); prev = s.t
  if s.t in any shadow: continue
  addBand(s.alpha1, dt)
  if first == nil and s.t >= 120:
    if s.alpha1 >= 0.75: armed = true; pend = nil; sus = 0
    elif armed:
      if pend == nil: pend = (s.t, s.hr)
      sus += dt
      if sus >= 180: first = pend

# B5 Route match (part of N8)
match(live, sport):
  if sport not in {run, trailRun, walk, hike, bike} or |live| < 2: return nil
  L = length(live); if L < 500: return nil
  best = nil
  for route in saved(sport):
    for track in [route.points, reversed(route.points)]:
      if dist(live[0], track[0]) > 150: continue
      pre = thin(prefix(track, L + 200), 5)
      sub = live if |live| <= 300 else [live[floor(i*|live|/300)] for i in 0..299]
      fit = mean(min(dist(p, q) for q in pre) for p in sub)
      if fit <= 30 and (best == nil or fit < best.fit): best = (route, dir, fit)
  return best

# B6 Route load estimate (N8, N9)
estimate(track, sport, recTRIMP, recDist, truncated):
  m = match(track, sport); if m == nil: return nil
  anchors = [m.route.first, m.route.last]
  priors = [w in archive where w.type == workout and w.end <= track[0].time
            and w.sport == sport and w.partialReason == nil and not replaces(w)
            and min(dist(w.track[0], a) for a in anchors) <= 150
            and match(w.track, sport).route.id == m.route.id]
  ratios = [w.trimp/w.dist for w in priors if w.trimp > 0 and w.dist > 0]
  if |ratios| > 1: med = median(ratios); ratios = [r in ratios where r >= 0.5*med]
  P = mean(ratios) if ratios else nil; n = |ratios|
  T = recTRIMP/recDist if recTRIMP > 0 and recDist > 0 else nil
  if P and T and T >= 0.7*P: return nil
  S = m.route.distance
  D = S if (recDist == nil or recDist <= 0) else
      S if 0.9*S <= recDist <= 1.1*S else
      S if recDist < S and truncated else recDist
  cp = min(0.85, 0.4 + 0.15*n)
  if P and T: return ((0.6*P + 0.4*T)*D, cp)
  if P: return (P*D, cp)
  if T: return (T*D, 0.4)
  return nil

replaces(meta): meta.est > 0 and meta.conf > 0.4 and (meta.trimp or 0) < 0.5*meta.est

# B7 Load ladder (N7, N10)
load(meta, ftp):
  p = storedPowerTSS(meta) or readTimeTSS(meta, ftp); if p: return (p, POWER)
  if replaces(meta): return (meta.est, ROUTE)
  if meta.hrTSS > 0: return (meta.hrTSS, HR)
  if metLoad(meta) > 0: return (metLoad(meta), METS)
  if meta.trimp > 0: return (meta.trimp, BANISTER)
  if meta.est > 0: return (meta.est, ROUTE)
  return nil
readTimeTSS(meta, ftp): F = ftp.for(meta.sport); T = max(meta.samples.t)
  if meta.NP > 0 and F > 0 and T > 60: return (meta.NP/F)^2 * T/3600 * 100
autoFTP(): best over running-family workouts of the last 90 days of
  max over full 1200 s windows with >= 1080 power readings of the mean of readings present;
  return round(0.95*best)

# B8 Readiness (N11, N12)
readiness(Rrec, todayTrimp, CTL, ATL, mATL, ACR, loads):
  if loads: raw = sum(L.load*exp(-L.h/24)); acute = 0.30*raw
  else: raw = todayTrimp; acute = 0.35*todayTrimp
  if CTL >= 3.2: x = piecewise((ATL+acute)/CTL)
  else: x = max(10, 100 - 0.5*(ATL+raw))
  if ACR != nil and ACR > 1.3:
    p = min(0.05 + 0.5*(ACR-1.3), 0.40) * min(max(CTL,0)/50, 1)
    if Rrec >= 70: p = min(p, 0.10)
    x *= (1 - p)
  if mATL != nil and mATL > 0: x += min(1.5*max(0, mATL-ATL), 20)
  if x > Rrec: x = Rrec + (x-Rrec)*min(max(CTL,0)/40,1)*0.55
  elif x < Rrec: x = x + (Rrec-x)*0.30
  return 50 if not finite(x) else clamp(x, 0, 100)
live(Rrec, morning, liveM, now):
  f = clamp((now - morning.end)/24h, 0, 1)
  ATLe = mATL + (liveM.ATL - mATL)*f; CTLe = mCTL + (liveM.CTL - mCTL)*f
  anchor = ATLe if f >= 1 else mATL
  loads = recent72h(liveM) if liveM.todayTrimp > 0 else nil
  return readiness(Rrec, liveM.todayTrimp, CTLe, ATLe, anchor, ATLe/CTLe if CTLe>0 else nil, loads)
frozen(Rrec, ATL, CTL) = readiness(Rrec, 0, CTL, ATL, ATL, ATL/CTL if CTL>0 else nil, nil) / 10

# B9 Dual-path strap fusion (N13)
tick():
  if new phone beats: dfa.ingest(new); hr = 60000/median(last 8 rr); lastStrapAt = now
  if watchStrapAt != nil and now - watchStrapAt < 10:
    q = drain(watchQueue)
    if q nonempty and not (lastStrapAt != nil and now - lastStrapAt < 5):
      wall = watchStrapAt - sum(q) (on phone stream clock)
      pts = [] ; for rr in q: pts.append(rr, wall); wall += rr
      watchBuf += pts; dfa.ingest(pts); show watch strap HR; lastWatchAt = now
  arbitrate(silences, wristHR fresh <= 30 s)
merge(source, phone, watch):
  base = phone if source == STRAP else []
  if watch empty: return base
  if any point lacks wall: return sort_by_t(base + watch)
  out = two-pointer interleave by wall (phone wins ties, each side keeps order)
  clock = out[0].t_ms; for p in out: p.t_ms = clock; clock += p.rr
  return out

# B10 Offline re-analysis (N14)
tl = gapCorrected(rr)   # t + running max((wall-wall0) - (t - t0))
for t in 120, 140, ... <= duration:
  w = [b in tl where t-120 <= b.t/1000 < t]
  if |w| >= 64: (v,k) = clean(w.rr); if k/|v| <= 0.06 and (r = dfa(v)): emit(t, r)
for sample s: r = latest reading with r.t <= s.t
  s.alpha1 = r.alpha1 if r and s.t - r.t < 20 else nil
```

## Appendix C: Source Map

| Method | Files (repository paths at e028039) |
|---|---|
| Live α1, beat clock, filter, status | `Emuqu/Sources/Analysis/LiveDFAAnalyzer.swift` |
| DFA core | `Emuqu/Sources/Analysis/DFAAnalysis.swift`; constants in `Emuqu/Sources/Utilities/Constants.swift` (`HRVConstants.DFA`) |
| Offline α1 | `Emuqu/Sources/Analysis/WorkoutAlpha1Reanalyzer.swift`; `RRWindowSweep` in `Emuqu/Sources/Analysis/SleepBoundaryResolver.swift`; `gapCorrectedOffsetsMs` in `Emuqu/Sources/Analysis/WorkoutAnalyzer.swift` |
| Ectopic shadows, band totals, summary crossing | `Emuqu/Sources/Views/Alpha1ReportCards+Report.swift` |
| Crossing list, LT1 card | `Emuqu/Sources/Views/ThresholdCards+Cards.swift` |
| Load ladder | `Emuqu/Sources/Collection/TrainingLoadPrecedence.swift`; `Emuqu/Sources/Models/WorkoutMetadata.swift` |
| TRIMP, hrTSS, splits, decoupling | `Emuqu/Sources/Analysis/WorkoutAnalyzer.swift` |
| Auto-FTP | `Emuqu/Sources/Analysis/FTPAutoEstimator.swift` |
| METs | `Emuqu/Sources/Models/WorkoutMetadata.swift`; `Emuqu/Sources/Collection/WorkoutRecorder+Metrics.swift` |
| Route matching | `Emuqu/Sources/Analysis/RouteLibrary.swift` |
| Route load estimate | `Emuqu/Sources/Analysis/RouteTRIMPEstimator.swift`; callers in `Emuqu/Sources/Collection/WorkoutRecorder+Lifecycle.swift`, `Emuqu/Sources/Services/WorkoutRecoveryService.swift`, `Emuqu/Sources/Analysis/WorkoutLoadBackfill.swift` |
| PMC / daily load | `Emuqu/Sources/Analysis/TrainingLoadSeries.swift`; `Emuqu/Sources/Collection/HealthDataTypes.swift` |
| Readiness | `Emuqu/Sources/Analysis/ReadinessScoring.swift`; `Emuqu/Sources/Utilities/Constants+RecoveryScore.swift` |
| Live and frozen readiness | `Emuqu/Sources/Analysis/LiveReadiness.swift`; `Emuqu/Sources/Services/ReanalysisService.swift` |
| Strap fusion and arbitration | `Emuqu/Sources/Collection/WorkoutRecorder+Ticker.swift` |
| RR merge | `Emuqu/Sources/Collection/WorkoutRRMerge.swift` |
| Tests cited | `EmuquTests/DFAReferenceValidationTests.swift`, `EmuquTests/LiveDFAAnalyzerTests.swift`, `EmuquTests/LiveDFAAnalyzerStreamTests.swift`, `EmuquTests/RouteTRIMPEstimatorTests.swift`, `EmuquTests/WorkoutRRMergeTests.swift` |
| Validation register | `Tools/science_register/register.json` |
