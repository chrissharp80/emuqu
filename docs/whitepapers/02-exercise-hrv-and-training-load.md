# Emuqu — Real-Time DFA α1 and Dropout-Robust Training Load

**Gated live α1, window-length ectopic discrimination, route-matched load substitution and a recovery-aware readiness model**

Technical White Paper • v1.3 • 8 October 2026

Chris Sharp • github.com/chrissharp80

Describes Emuqu (formerly Flow HRV, then Flow Recovery) at source revision e028039 (2026-10-07), scoring version v3.1.oct2026. Emuqu is a consumer wellness app, not a medical device.

Cite as: Sharp C. Emuqu — Real-Time DFA α1 and Dropout-Robust Training Load. Technical White Paper v1.3, 8 October 2026. github.com/chrissharp80/emuqu, docs/whitepapers/02-exercise-hrv-and-training-load.md.

---

## Executive Summary

Emuqu is an iOS app that records workouts from a Bluetooth chest strap such as the Polar H10, an Apple Watch, satellite positioning (GPS), foot pods and power meters. During exercise it shows DFA α1, the short-term scaling exponent of detrended fluctuation analysis (DFA). DFA α1 is a heart rate variability (HRV) index that falls with intensity and crosses about 0.75 near the first ventilatory threshold. Across days, Emuqu keeps a training-load history and a daily training-readiness score. The history consists of acute training load (ATL), chronic training load (CTL) and their difference, training stress balance (TSB).

Both depend on a stream of RR intervals (beat-to-beat intervals) that Bluetooth dropouts, lost skin contact, phone–Watch handovers and ectopic beats routinely interrupt. Emuqu ties each number to the data that support it. The main methods are:

1. **Gated live α1.** A value is published only when a 120 s window holds at least 64 beats *and* spans at least 118 s on a beat clock that adds dropout time back in; the same clock trims the window. A trailing-median filter interpolates artifacts in place, a window with more than 6% corrected beats is withheld, and a five-state status machine clears the value whenever it is not freshly computed.
2. **Ectopic discrimination by window length.** After the session, an α1 dip below 0.75 that recovers within one window (120 s) is labeled an "ectopic shadow" and left out of summary statistics; a threshold crossing counts only after 180 s below the threshold.
3. **A training-load ladder.** Power-based Training Stress Score (TSS), including TSS computed when the record is read from stored normalized power and an automatic functional threshold power (FTP); a route-history estimate when the heart-rate load looks like a strap dropout; heart-rate TSS (hrTSS); metabolic-equivalent (MET) load; Banister training impulse (TRIMP); and the route estimate as a last resort.
4. **Route-matched load substitution.** The load of a workout whose strap failed is rebuilt from the user's own TRIMP per meter on earlier clean runs of the same saved route, matched in either direction, with outlier removal, a blend with the partial recording and an explicit confidence.
5. **A recovery-aware readiness model.** A 72 h decaying acute-fatigue term, the ATL/CTL capacity ratio and a damped acute:chronic workload ratio (ACWR) penalty, blended asymmetrically with the morning recovery score and interpolated through the day from a frozen morning snapshot.
6. **Phone–Watch strap fusion.** A strap can reach the phone directly and through the Watch. Watch-relayed RR intervals are used only while the phone's own strap stream is silent, so no beat is counted twice, and at the end of the workout the two streams are interleaved by arrival time.

Section 5 states what is new in each method with its earliest dated commit (first forms from 2026-03-01, current forms by 2026-10-06), and Section 8 gives the provenance of those records. In the check reported in Section 6, the artifact filter alone keeps the magnitude of α1 bias at 0.023 or less on PhysioNet Holter recordings at artifact rates up to 3%, against 0.43–0.77 without correction.

---

## 1. The Problem

### 1.1 Live DFA α1 needs complete, clean, current windows

Detrended fluctuation analysis (DFA) [1] integrates a series of RR intervals (beat-to-beat intervals) and measures how the detrended fluctuation F(n) grows with box size n; the log–log slope over boxes of 4–16 beats is α1. In incremental exercise tests, α1 falls with intensity and crosses about 0.75 near the first ventilatory threshold (VT1) or the first lactate threshold (LT1) [2][3][4]. This makes it attractive as a live intensity readout. This paper calls a downward crossing of α1 = 0.75 an AT1 crossing and of α1 = 0.50 an AT2 crossing. Four practical problems stand in the way.

- **Too little data.** At 160 bpm, 64 beats take about 24 s, so a beat-count gate alone lets a fit run on a fraction of the nominal two-minute window.
- **Artifacts.** Artifact correction biases α1 minimally below about 3% corrected beats and only slightly at 6% [4][5]. Uncorrected artifacts move it a long way: in 24-hour Holter recordings, 1% injected ectopic or missed beats lowered α1 by 0.55 and 0.43, toward the white-noise value of 0.5 (Section 6).
- **Dropouts.** When a Bluetooth link drops, beats are lost. A timeline built as the running sum of delivered intervals stops advancing while real time continues, so a window cut on it does not describe the last two minutes.
- **Stale numbers.** A display that keeps its last value after the strap stops, or after a window is rejected, shows a number that is no longer being computed.

### 1.2 Interpreting α1 after the session

A single ectopic beat stays inside a 120 s rolling window for 120 s. It can drag α1 below 0.75 for up to one window length, so an LT1 estimate taken from the first sample below 0.75 can reflect one bad beat. Agreement between the α1 = 0.75 crossing and gas-exchange VT1 is good on average. Individual limits of agreement are around ±10 bpm and widen in fatigued runners [2][6][7]. Test–retest reliability of heart rate (HR) at the α1 threshold in untrained adults is moderate (intraclass correlation coefficient, ICC, 0.52) [8]. A post-session reading has to separate sustained physiology from transient artifact.

### 1.3 Training load when the strap fails

Heart-rate load models need heart rate. Examples are the Banister training impulse (TRIMP) [9][10] and heart-rate Training Stress Score (hrTSS). When the strap fails partway through, a 40-minute run can record a TRIMP of 2. That number enters the exponentially weighted acute and chronic training load averages (ATL and CTL) [9][11] and depresses every later readiness and form figure. Power-based Training Stress Score (TSS) [11] avoids heart rate but needs a power meter and a functional threshold power (FTP). Published platforms fall back from one load metric to another when a metric is zero or missing (Section 4.2). intervals.icu can estimate load from average HR with a model fitted to earlier activities [12]. The gap this paper addresses is rebuilding a dropout session's load from the user's own history on the same route.

### 1.4 Readiness and the acute:chronic ratio

The acute:chronic workload ratio (ACWR) [13] is widely used to flag load spikes, but its statistical basis and "sweet spot" have been criticized [14]. At low chronic load the ratio is numerically unstable: for example, one walk can move it by 0.2. Undamped ACWR penalties can also contradict the morning HRV-based recovery score on the same screen. That score is described in Paper 1, *Overnight Recovery Measurement from Raw Beat Intervals* ([link](01-overnight-recovery-measurement.md)), Section 3.7.

---

## 2. Architecture Overview

**Table 2.1.** Processing phases.

| Phase | Operation |
|---|---|
| Acquisition (1 Hz tick) | Phone-strap RR; Watch-relayed RR only after ≥ 5 s of phone silence; HR arbitration (strap → Watch-relayed strap → wrist) |
| Live HR | Median of the last 8 RR intervals → bpm |
| Live α1 | Beat clock → 120 s trim → dual gate → filter → 6% rejection → DFA → status |
| Finalize | Interleave phone and Watch RR by wall clock; rebuild `t_ms`; TRIMP, hrTSS, power TSS, splits, decoupling |
| Route estimate | Match saved route; filter earlier runs; estimator; confidence |
| Offline α1 | Live pipeline on the gap-corrected timeline; freshness-limited write-back |
| Report | Ectopic shadows; sustained AT1/AT2 crossings; band minutes; LT1 estimate; per-split α1 |
| Load history | Ladder → capped daily sums → ATL/CTL as exponentially weighted moving averages (EWMA) → training stress balance (TSB) |
| Readiness | Acute fatigue + capacity ratio + damped ACWR + freshness + asymmetric recovery blend; frozen morning value; intra-day interpolation |

---

## 3. Methods in Detail

Appendix B gives pseudocode for the methods in Section 5, and Appendix A lists every parameter.

### 3.1 Live DFA α1

Parameters:
- window W = 120 s;
- recompute cadence C = 20 s (wall clock, between ingest calls);
- minimum 64 beats;
- span slack 2 s, so the span gate is W − 2 = 118 s;
- "stalled" after 2 × C = 40 s of silence;
- rejection when the corrected fraction exceeds 0.06.

#### 3.1.1 Beat clock (dropout compensation)

Each RR point carries `t_ms` (running sum of delivered intervals), `rr_ms` and, when available, `wallClockMs` (milliseconds since the strap stream started, at arrival). The analyzer re-stamps every beat with `start = max(nextStart, wallClockMs − originWall + originBeat)`. Here `nextStart` is the previous beat's start plus its `rr_ms` (the beat's own `t_ms` for the first beat). `originWall` and `originBeat` are recorded at the first beat carrying a wall-clock time. The second term is omitted for beats without one (Appendix B1).

Offline, the same timeline is `t_ms + correction`, where `correction` is the running maximum of `(wallClockMs − originWall) − (t_ms − originT)` and `originT` is the `t_ms` of that first beat. A unit test checks that both forms give identical offsets on a stream with a dropout.

**Why it works.** A beat cannot start before the previous beat ended, nor earlier than its arrival allows; the `max` of the two bounds is the earliest consistent start. In normal streaming the interval sum leads and arrival lags by batching jitter, so spacing is untouched. After a dropout, arrival leads by the lost duration and the clock jumps forward by exactly that amount. The correction is a running maximum, so the timeline stays monotonic.

#### 3.1.2 Ingest, trim, gate and progress

On each ingest at time `now`:
1. Ignore the call if no session has started.
2. Append the re-stamped beats and, if any arrived, set `lastBeatAt = now`.
3. Remove every beat with `t_ms < newest.t_ms − W`.
4. Compute `span = (last.t_ms − first.t_ms)/1000` and `fill = min(min(1, count/64), min(1, span/118))`.
5. Recompute if at least C seconds have passed since the last recompute; otherwise only refresh the status.

The recorder calls `tick(now)` once per second when no beats arrived, so the status can reach "stalled" while the strap is silent.

The dual gate is `count ≥ 64 AND span ≥ 118 s`.

**Why one clock and two conditions.** Trimming and span measurement use the same beat clock, so window membership and measured span always describe the same stretch of time. On two different clocks they would drift apart by every dropout. The beat count protects the fit: with 64 beats every α1 box size from 4 to 16 is available. The span protects the meaning. A value labeled "the last two minutes" must cover two minutes, which a beat count does not guarantee at high heart rates. The 2 s slack equals the 2000 ms ceiling of a plausible beat: trimming keeps the oldest beat at or after the cutoff, so a full window can measure one RR interval short of 120 s. The progress bar uses the gate's own 118 s, so 100% means the gate passes.

#### 3.1.3 Artifact filter (trailing-median relative-deviation filter)

A window of fewer than 8 values is returned unchanged with a count of 0. Otherwise:

1. **Mark.** Take the beats in order and keep a reference list `recentClean` of at most 5 accepted values.
   - Mark a beat if `rr < 300` or `rr > 2000` ms.
   - Otherwise, if `recentClean` holds at least 3 values, take `med = sorted[⌊count/2⌋]` (the upper middle value for an even count). Mark the beat if `|rr − med| / med > 0.20`.
   - Otherwise accept it. Accepted beats are appended to `recentClean`; artifacts never enter it.
2. **Interpolate in place.** Each marked beat at i takes `rr[l] + (rr[r] − rr[l]) · (i − l)/(r − l)` from the nearest unmarked neighbors l < i < r; with one neighbor it copies that value; with none it is left unchanged.
3. **Return** the series (same length) and `correctedCount`, the number of marked beats.

**Why it works.** A median of recent beats tracks gradual heart-rate change while ignoring a single outlier, and a relative threshold scales with heart rate. Building the reference only from accepted beats means a premature beat and its compensatory pause cannot pull the reference toward themselves. Interpolating in place keeps length and order, so DFA's boxes are not shifted by deletions. In-place interpolation hides how much was replaced, so the count travels with the values. The 6% refusal follows the published finding that correction bias is minimal below about 3% and small at 6% [4][5].

#### 3.1.4 Recompute and status machine

A recompute that passes the gate cleans the window, then takes one of three outcomes:
- a corrected fraction above 0.06 sets `tooManyArtifacts(fraction)` and clears α1, band and R²;
- a failed DFA sets `fitFailed` and clears α1, band and R²;
- otherwise α1, R² and band are published.

The status refresh checks, in order:
1. silence over 40 s: `stalled`, and the value is cleared;
2. gate failure: `warmup(fill)`, and the value is cleared;
3. a published value: `ok`;
4. after `stalled`: `warmup(fill)`;
5. otherwise the current reason stands until the next recompute (Appendix B2).

Invariant: α1 is non-nil exactly when the status is `ok`. The live display, voice coach, Watch and per-second workout sample all read this field, so a rejected or stale window writes nil into the sample stream.

**Why clear instead of hold.** One field and one invariant govern every consumer. A number shown during a coaching decision should have been computed from the last two minutes; a gap tells the athlete the truth where a held value would not. The silence check runs first because a stalled strap invalidates every other state, and 40 s (two cadences) separates a dropout from notification batching.

#### 3.1.5 DFA core and bands

The DFA core is prior art [1], given here for reproducibility.
1. Require n ≥ 64.
2. Integrate `y[k] = Σ_{j≤k} (rr[j] − mean)`.
3. Generate box sizes from `lo` by ratio 2^(1/8), rounded, dropping consecutive duplicates, up to `hi`, and append `hi` if it is not last.
   - α1: `lo = 4`, `hi = min(16, ⌊n/4⌋)`, which gives {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15, 16} for n ≥ 64.
   - α2: `lo = 16`, `hi = min(64, ⌊n/4⌋)`.
4. For each size s, split `y` into ⌊n/s⌋ non-overlapping boxes from the start. Fit a least-squares line in each box against index 0…s−1, and set `F(s) = sqrt(Σ residual² / (boxes · s))`.
5. Regress ln F on ln s, using ln F = −10 when F ≤ 0. The slope is α, and R² is the fit quality.

α1 needs at least 3 sizes; α2 needs 3 sizes and n ≥ 256.

Bands: α1 ≥ 0.75 "Easy"; 0.50 ≤ α1 < 0.75 "Threshold"; α1 < 0.50 "Very Hard". Every surface calls one shared function. The 0.50 band is a coarse intensity label, not a claim about the second threshold.

#### 3.1.6 Offline re-analysis

For archived sessions:
1. Require at least 64 RR points and re-stamp them on the gap-corrected timeline.
2. Take the duration as the stored duration, else the last offset; it must exceed 120 s.
3. For t = 120, 140, … ≤ duration, take the beats with offset in [t − 120 s, t) by a two-pointer sweep, which is O(n).
4. For each window of at least 64 beats, clean it and reject it above 0.06; otherwise run DFA and emit `(t, α1, R²)`.
5. Each per-second sample then takes the latest reading at or before its offset if that reading is less than 20 s old, else nil.

**Why the same pipeline.** Running the live filter, window, cadence and rejection offline lets older sessions benefit and keeps live and post-session numbers comparable. The gap-corrected timeline places each window where it really was. The 20 s limit is one cadence, so a sample carries only the reading that would have been on screen at that moment.

### 3.2 Post-hoc interpretation of α1

The input is the per-second samples, each carrying α1 or nil.

#### 3.2.1 Ectopic shadows

Walk the α1 samples in order.
- **Below 0.75:** open a dip at the sample's offset (`start`) if none is open, and track the deepest point.
- **At or above 0.75 with a dip open:** let `span = offset − start`. If `0 < span ≤ 120 s`, emit a shadow over `[max(0, start − 60), offset + 120)`, with the deepest point as the chart marker. Close the dip either way.

A dip still open at session end is not labeled. Shadows are drawn with a neutral "beat artifact" marker. Samples inside them are left out of average, maximum and minimum α1 and out of band-time totals.

**Why window length discriminates.** An isolated bad beat affects α1 only while it is inside the 120 s window. A dip that recovers within one window is therefore consistent with a single artifact, while a real intensity change keeps α1 low as long as the effort lasts. The padding follows the window's geometry. The 60 s before covers the approach, as α1 falls once the beat enters. The 120 s after covers the recovery shoulder, which stays contaminated until the beat leaves. A dip open at the end has unknown duration, so it is not judged.

#### 3.2.2 Band totals and the first sustained AT1 crossing

Each sample counts for `dt = min(max(1, offset − previousOffset), 5)` s, or 1 s for the first sample; shadow samples are skipped. From 120 s on:
- α1 ≥ 0.75 sets `armed` and resets the pending crossing and the counter.
- α1 < 0.75 while armed records a pending offset and the HR at that sample if none is pending, then adds `dt`. At 180 s the routine returns `(pendingOffset, pendingHR)`.

**Why these rules.** A 180 s sustain exceeds the 120 s window, so no single-beat artifact can satisfy it. The 120 s warm-up skips the first window. Arming at ≥ 0.75 makes a crossing a transition from easy to harder. The 5 s cap keeps a strap gap from counting as time in a band.

#### 3.2.3 Crossing list and the LT1 card

A second routine lists AT1 (0.75) and AT2 (0.50) crossings, with one tracker per threshold. It runs over samples from 120 s on (the previous value may precede 120 s), with `dt = max(1, offset − previousOffset)`. This routine counts time without the 5 s cap and arms on the previous sample.
- **Below the threshold:** if the previous α1 was at or above it and nothing is pending, create a pending down-crossing with offset, α1, HR and pace. Add `dt`, and emit the pending down-crossing once the counter reaches 180 s.
- **At or above the threshold:** if a pending down-crossing had reached 180 s, emit an up-crossing with the current HR and pace. Clear the pending crossing and the counter.

The first 6 events are kept.

The "α1-estimated aerobic threshold (LT1)" card shows the HR and time of the first AT1 down-crossing that has an HR. It is labeled "estimate", with a caption giving lab agreement of roughly ±10 bpm. It is deliberately not offered as a lactate-threshold heart rate (LTHR) setting. LT1 sits well below LTHR, and LTHR is the hrTSS denominator, so substituting it would inflate every later load figure.

### 3.3 Training load

#### 3.3.1 Load ladder

Every archived workout resolves one load figure and a source tag; the first applicable tier wins.

**Table 3.1.** Training-load ladder. NP is normalized power; IF is intensity factor (NP/FTP).

| # | Source | Rule | Scale |
|---|---|---|---|
| 1 | Power | Stored IF > 0 and duration (last sample offset) > 60 s → `IF² × duration_h × 100`; else stored power TSS > 0; else **read-time power TSS**: NP > 0, an FTP for the sport, duration > 60 s → `(NP/FTP)² × duration_h × 100` | TSS |
| 2 | Route history (replacement) | `routeEstimateReplacesHRLoad` (Section 3.4.4) and an estimate exists | Banister TRIMP |
| 3 | hrTSS | stored hrTSS > 0 | TSS |
| 4 | METs | computed MET load > 0 | TSS-like |
| 5 | Banister TRIMP | stored TRIMP > 0 | Banister TRIMP |
| 6 | Route history (last resort) | stored estimate > 0 | Banister TRIMP |

**Why this order.** Power measures external work directly and is unaffected by strap dropouts, so it leads. The route estimate outranks heart rate only when there is positive evidence of a dropout (Section 3.4.4); otherwise measured heart rate is preferred to history. hrTSS precedes MET load and raw TRIMP because it is individualized to the user's threshold. The route estimate reappears as the last tier, so a workout with no other source still contributes something grounded in the user's own history.

#### 3.3.2 Functional threshold power

Running-family sports (run, trail run, walk, hike, treadmill) use the user's running FTP, else the automatic estimate. Cycling (outdoor and indoor) uses only a user-entered FTP. Other sports have none.

The automatic running FTP works as follows.
1. Over the running-family workouts of the last 90 days, build a per-second power array by sample offset (0 ≤ offset < 24 h). A second is empty unless watts > 0.
2. Slide a 1200 s window. Where it is full and holds at least ⌈0.9 × 1200⌉ = 1080 readings, take the mean of the readings present.
3. Take the best window mean across sessions and set `FTP = round(0.95 × best)`. Store it with its source session, or clear it if no window qualifies.
4. Recompute at most every 7 days unless forced.

The coverage rule ensures the best 20 minutes is a genuinely continuous effort.

Tier 1 is evaluated when the record is read. Sessions that stored NP before any FTP existed therefore count as power TSS once one is available, with no migration.

#### 3.3.3 hrTSS, Banister TRIMP and MET load

**hrTSS** = `TRIMP_session / TRIMP_ref × 100`. TRIMP_ref is Banister TRIMP for 60 one-minute samples at LTHR, using the user's value, else `0.88 × HRmax` [11][15]. hrTSS requires HRmax and resting HR.

**Banister TRIMP** [9][10]. Per beat:
- `HR = 60000/rr` and duration `rr/1000` s;
- heart rate reserve `HRR = clamp((HR − HRrest)/(HRmax − HRrest), 0, 1)` [16];
- `TRIMP += (dur/60) · HRR · A · e^(k·HRR)`, with A = 0.64 and k = 1.92 (male), or A = 0.86 and k = 1.67 (female).

At least 30 beats are required. When HRmax or resting HR is unknown, an Edwards five-zone %HRmax TRIMP is used instead [17], with the user's HRmax or, failing that, the session's peak HR.

**MET load.** Per-sample METs come from a table keyed on sport and speed [18]. The load is `MET_hours / 12 × 100` and is reported above 0.5.
- The per-sample path needs at least 30 samples, with METs on at least a quarter of them. Each sample counts for the gap to the next sample, clamped to 1–30 s.
- The fallback uses one bucket at the mean speed. It requires a distance over 50 m, a mean speed of 0.5–60 km/h and a moving duration of at least 60 s.

#### 3.3.4 Scales and the daily series

**Scales.** Power TSS and hrTSS put 100 at one hour at threshold, and MET load uses the same nominal anchor. Banister TRIMP and the route estimate are on the Banister scale. Each workout is labeled by source ("LOAD" or "TRIMP") and enters unconverted.

**Daily series and the Performance Management Chart (PMC).**
- A workout figure is capped at 1000. Workouts with no precomputed figure use a summary Banister TRIMP from average HR, else 0.
- Loads are summed per local day (0 on rest days), and each day is capped at 1200.
- `X_today = load·(1 − e^(−1/τ)) + X_yesterday·e^(−1/τ)`, with τ = 7 days for ATL and 42 days for CTL; `TSB = CTL − ATL`.

This is the standard PMC construction [11] and is not presented as new. Fitted Banister parameters are unstable [19], so fixed constants are used.

### 3.4 Route-matched load substitution

#### 3.4.1 Route matching

Only routes the user has saved and named are used; the archive is not mined. Matching runs for run, trail run, walk, hike and bike, against saved routes of the same sport.

1. Require at least 2 points and a traveled length L ≥ 500 m.
2. Test each saved route forward and reversed. The reversed candidate is rebuilt from the reversed points, so its climb profile matches the direction of travel.
3. For each direction:
   1. **Start gate.** The live track must start within 150 m of the candidate's first point.
   2. **Prefix.** Take the candidate's prefix up to L + 200 m along it, including the first point beyond that length. Thin it to points ≥ 5 m apart, keeping the first and last.
   3. **Subsample.** If the live track has more than 300 points, subsample it to 300 at ⌊i · N/300⌋.
   4. **Fit.** Take the mean distance from each live point to the nearest prefix point, and accept the candidate at ≤ 30 m.
4. Return the accepted candidate with the lowest fit across routes and directions.

A prefix of the traveled length plus 200 m lets a route be recognized before it is finished. Thinning and subsampling bound the search cost and make it independent of recording density.

#### 3.4.2 Earlier runs and the estimate

The matched route's first and last points are both start anchors. An earlier run counts as a prior only if it:
- ended at or before the current workout's first GPS fix;
- shares the current workout's sport;
- is not a recovered partial session;
- is not itself a substituted workout (Section 3.4.4);
- starts within 150 m of either anchor;
- re-matches *this* route over its whole track.

Each prior gives `ratio = TRIMP / distance_m`, where both are > 0. With more than one ratio, drop those below 0.5 × median, using the mean of the middle pair for an even count. `priorAvg` is the mean of the rest, and n is their count. When the recorded TRIMP and distance are both > 0, `today = recordedTRIMP / recordedDistance`. The estimate then follows five cases:

1. Both exist and `today ≥ 0.7 × priorAvg`: no estimate; the recorded value stands.
2. Both exist otherwise: `(0.6·priorAvg + 0.4·today) × D`, confidence `c_p`.
3. Only `priorAvg`: `priorAvg × D`, confidence `c_p`, marked prior-dominant.
4. Only `today`: `today × D`, confidence 0.4.
5. Neither: no estimate.

Here `c_p = min(0.85, 0.4 + 0.15·n)`.

The target distance D is the saved route distance S in three cases:
- the recorded distance is missing or ≤ 0;
- the recorded distance is within 0.9–1.1 × S;
- the recorded distance is below S in a possibly truncated recording (crash-recovered or saved as interrupted).

Otherwise D is the recorded distance, so a partial run is credited for the distance covered and a longer run in full.

The estimate, its confidence and the route name are stored on the workout. They are computed at three points:
- at finalize, as not truncated;
- in crash recovery, as truncated;
- in a background backfill, as truncated only for crash-recovered or interrupted sessions.

#### 3.4.3 Why route-matched substitution works

A run's load depends on the course and the runner. A saved route fixes the course (distance, climb, terrain), and direction-aware matching keeps the climb profile aligned. The user's own TRIMP per meter on that course fixes the runner, including heart-rate anchors and usual effort there. The prior filters keep the reference clean. Excluding earlier substituted workouts means an estimate never feeds on another estimate. The median-based outlier drop removes earlier dropouts the app did not detect, which would otherwise pull the estimate toward the failure it corrects. The 0.7 threshold leaves an ordinary easy day untouched. The 60/40 blend keeps what the partial recording captured, and confidence grows with the number of supporting runs.

#### 3.4.4 When the estimate replaces the recorded load

`routeEstimateReplacesHRLoad` holds when all three conditions are met:
- the estimate is > 0;
- its confidence is > 0.4, so it rests on at least one prior;
- `recordedTRIMP` (0 if absent) is < 0.5 × estimate.

Case 2 blends in 40% of the recorded value. When D is the recorded distance, the condition therefore means the recording is under 37.5% (3/8) of the user's usual TRIMP per meter on the route. That indicates a dropout rather than an easy day. The estimate then takes tier 2; otherwise it is tier 6 only. Requiring a prior means a replacement always rests on history. The app always shows the recorded value next to the estimate.

### 3.5 Training readiness

#### 3.5.1 Daily score

Inputs:
- R_rec, the morning recovery score (0–100);
- todayTrimp;
- CTL and ATL;
- anchorATL, the freshness anchor;
- ACWR (`ACR` in the code);
- only when todayTrimp > 0, the resolved loads of workouts in the last 72 h, with the hours since each.

On rest days ATL already carries yesterday's load, and the freshness bonus handles dissipation.

1. **Acute fatigue.** With recent loads, `raw = Σ load_i · e^(−h_i/24)` and `acute = 0.30 · raw`. Without them, `raw = todayTrimp` and `acute = 0.35 · todayTrimp`.
2. **Base.** If CTL ≥ 3.2, map `(ATL + acute)/CTL` piecewise-linearly through (0 → 100), (0.8 → 85), (1.0 → 70), (1.3 → 50), (1.5 → 30) and (2.0 → 10). The base is held at 10 above 2.0, and a ratio ≤ 0 gives 100. Below CTL 3.2, the base is `max(10, 100 − 0.5·(ATL + raw))`.
3. **ACWR damper.** This step applies only if ACWR > 1.3.
   - `p = min(0.05 + 0.5·(ACWR − 1.3), 0.40) · min(max(CTL, 0)/50, 1)`.
   - If R_rec ≥ 70, `p ← min(p, 0.10)`.
   - `readiness ← readiness · (1 − p)`.

   Following [14], no penalty is applied for a low ratio.
4. **Freshness.** If anchorATL > 0, add `min(1.5 · max(0, anchorATL − ATL), 20)`.
5. **Asymmetric blend.**
   - Above R_rec: `R_rec + (readiness − R_rec) · min(max(CTL,0)/40, 1) · 0.55`.
   - Below R_rec: `readiness + (R_rec − readiness) · 0.30`.
6. **Output.** A non-finite result becomes 50, and the result is clamped to 0–100. It is displayed divided by 10:
   - Ready: ≥ 7;
   - Moderate: ≥ 4.5;
   - Fatigued: ≥ 2;
   - Rest: below 2.

   "Ready" becomes "Moderate" when a separate advice gate recommends an easier session.

#### 3.5.2 Frozen morning value and live interpolation

**Frozen value.** The morning recovery session is accepted when it is saved as the day's reading. At that point readiness is computed once, with todayTrimp = 0, anchorATL = ATL and ACWR = ATL/CTL, and stored on the 0–10 scale with the session. That snapshot holds the morning values ATL_m and CTL_m.

**Live value.** Let h be the hours since the morning session ended, and `f = clamp(h/24, 0, 1)`. During the day:
- `ATL_eff = ATL_m + (ATL_live − ATL_m)·f`;
- `CTL_eff = CTL_m + (CTL_live − CTL_m)·f`;
- `ACWR = ATL_eff/CTL_eff` when CTL_eff > 0.

ATL_m and CTL_m come from the frozen snapshot, or are 0 if it is missing. The freshness anchor is ATL_m, except at f = 1, where ATL_eff is used and the bonus collapses to 0.

**Other rules.** Without training metrics, readiness equals the recovery score. When the gap to the morning score is at least 3 points, the narrative says training "pulled readiness down" or rest "lifted" it.

**Why it works.** Readiness asks whether there is capacity for more load today. ATL/CTL answers this relative to what the user is accustomed to. ATL updates once a day, so the 72 h acute term (τ = 24 h) makes this morning's session count now and fade over about a day. Below CTL 3.2 the ratio is numerically unstable, so a strain branch takes over. The ACWR penalty is scaled by CTL/50 because the ratio is unstable at low chronic load [14]. It is capped at 10% when recovery is at least 70, so a ratio cannot overrule a good morning HRV-based recovery score. The blend is asymmetric for the same reason. An optimistic load model is only partly trusted, and less so at low CTL; a pessimistic one is lifted modestly. Freezing the morning value makes history reproducible, and interpolating from it keeps the live figure continuous at acceptance.

### 3.6 Fusing the two strap paths

#### 3.6.1 Per-tick routing

Each 1 s tick runs three steps in order:

1. **Phone strap.** New beats go to the α1 analyzer. Live HR is `60000 / median(last 8 RR > 0)`, using the middle-pair mean for an even count, and `lastStrapHRAt = now`.
2. **Watch-relayed strap.** This step runs only if the Watch reported strap data within 10 s.
   - The relayed RR queue is always drained and filtered to a plausible range.
   - The drained beats are **used** only if `lastStrapHRAt` is ≥ 5 s old or absent.
   - Used beats get wall-clock times on the phone stream's clock, assigned backward from the batch's arrival by the cumulative interval sum. They go to a separate buffer and to the α1 analyzer. The Watch-reported strap HR is shown, and `lastWatchRoutedHRAt` is stamped.
3. **Arbitration** (a pure function, in strap mode).
   - After more than 10 s of silence on both strap channels, the app shows wrist HR received within the last 30 s. With none, it clears the HR rather than leave it stale.
   - A "strap not connected" or "strap silent" notice appears only after 15 s of recording, and only while both channels are silent.
   - Watch mode always uses wrist HR.

#### 3.6.2 Merge at finalize

1. Start from the phone buffer if the workout's source was the strap. Otherwise start from nothing, because an old buffer may hold another session's beats.
2. With no Watch beats, return the phone buffer.
3. If any point lacks a wall-clock time, concatenate the buffers and sort by `t_ms`.
4. Otherwise interleave by `wallClockMs`, phone first on ties. Each side keeps its own order, because a phone batch shares one arrival time.
5. Rebuild `t_ms` as the running sum of `rr_ms` from the first point.

**Why it works.** A strap can be linked to the phone and the Watch at once, so both paths can carry the same beats. The phone is primary, and the Watch is a standby after 5 s of phone silence. This gives one stream that continues through a phone dropout. Draining the queue while the phone is live stops those beats from being replayed later. Arrival time is the only clock the two paths share. Ordering by `t_ms` would place beats the Watch carried through a phone dropout among the phone's later beats, because the phone's `t_ms` omits the gap.

### 3.7 Per-split α1 and decoupling (standard)

A distance split's time window is found by walking the stored track to the cumulative distance of the split's end. The window ends at that fix's timestamp, or uses the split's own duration if the track does not line up. The split's α1 is the mean of sample α1 in [start, end).

Pa:Hr decoupling [11] works as follows:
1. Halve the moving time. Paused steps and the step across a resume add nothing.
2. Compute the efficiency factor `EF = (distance/seconds)/mean HR` for each half, on the gap-corrected timeline.
3. Report `(EF₁ − EF₂)/EF₁ × 100`.

The metric is withheld under 5 minutes or 500 m.

---

## 4. Comparison with Existing Approaches

All implementations below use the DFA of Peng et al. [1]. The PhysioNet reference implementation [20] follows the same principles. Emuqu uses non-overlapping forward boxes of 4–16 beats at ratio 2^(1/8). In the tables, "not stated" means the material found does not say.

### 4.1 Live and post-session α1

**Table 4.1.** Live α1 window, gating and staleness.

| Product or method | Window and cadence | When a value is shown | Window clock | Stale or rejected value |
|---|---|---|---|---|
| Laboratory studies [2][3][4] | 2-minute windows on Kubios-processed data | Offline analysis | — | — |
| FatMaxxer [21] | 120 s, recomputed every 20 s by default (user-set, minimum 5 s) | Always; colored "undefined" before 20 s and "unreliable" before 120 s of elapsed session time | Trimmed on arrival time; replay rebuilds time from the RR sum | Last value stays on screen with its color |
| Watchletic [22] | 120 s, updated every 5 s | ≥ 160 source beats | Not stated | Not stated |
| AlphaHRV [23] | 200 beats, updated every 1–5 s | Not stated | Not stated | Not stated |
| HRV Logger [24] | 2-minute windows | Not stated | Not stated | Not stated |
| **Emuqu** | **120 s, recomputed every 20 s** | **Withheld until ≥ 64 beats and ≥ 118 s span on the beat clock** | **Dropout-compensated beat clock, same clock for trim and span** | **Cleared; nil written to the sample stream** |

**Table 4.2.** Artifact handling during live α1.

| Product or method | Artifact handling |
|---|---|
| Kubios [25][26] | Threshold-based and automatic correction |
| Rogers and Gronwald [4][5] | Published effect sizes of artifacts and correction on α1 |
| FatMaxxer [21] | Drops beats beyond ±5% (workout mode) or ±25% (light mode) of the previous beat, shows the dropped percentage, keeps showing α1 |
| Watchletic [22] | Skips windows with too many corrections |
| AlphaHRV [23] | Treats > 5% artifacts as affecting α1 |
| HRV Logger [24] | Reports the artifact rate |
| **Emuqu** | **Trailing upper median of ≤ 5 accepted beats, ±20%, linear interpolation in place, count carried, α1 withheld above 6%** |

**Table 4.3.** Post-session α1.

| Product or method | Ectopic handling | Offline re-analysis | Threshold crossing |
|---|---|---|---|
| Laboratory protocols [2] | — | — | Regress α1 against HR over incremental stages |
| FatMaxxer [21] | Not stated | Replays a recorded RR file through the live pipeline | Not stated |
| intervals.icu [12] | Not stated | Post-ride DFA α1 | Not stated |
| Runalyze [27], AI Endurance [28] | Not stated | Not stated | Ramp regression or cluster analysis |
| **Emuqu** | **Window-length shadow rule with 60/120 s padding** | **Same pipeline on the gap-corrected timeline; write-back only within 20 s** | **180 s sustained, armed after ≥ 0.75, after a 120 s warm-up** |

### 4.2 Training load and readiness

**Table 4.4.** Training load.

| Product or method | Load model | Strap dropout | FTP |
|---|---|---|---|
| Allen and Coggan [11] | TSS, hrTSS and the PMC | — | 0.95 × 20-minute test |
| GoldenCheetah [29] | TriScore: BikeScore, GOVSS or SwimScore, falling back to TRIMP zonal points on zero | Not stated | Not stated |
| TrainingPeaks [30] | Power TSS → running TSS (rTSS) → hrTSS | Not stated | Not stated |
| intervals.icu [12] | Per-sport load priority | Load estimated from average HR with a model fitted to earlier activities | Not stated |
| Stryd [31] | — | — | Critical power estimated from about 90 days of data |
| **Emuqu** | **Power TSS → (route, if dropout) → hrTSS → METs → TRIMP → route** | **Route-matched substitution from the user's own earlier runs, with confidence** | **0.95 × best 20 minutes with ≥ 90% coverage, 90 days, running** |

**Table 4.5.** ACWR and readiness.

| Product or method | ACWR | Readiness |
|---|---|---|
| Gabbett [13]; Impellizzeri et al. [14] | Ratio; critique of the ratio | — |
| Banister et al. [9] | — | Fitness–fatigue model |
| Garmin Training Readiness [32] | Not stated | Inputs published, formula not; updates through the day |
| Polar cardio load status [33] | Not stated | Strain compared with tolerance |
| **Emuqu** | **Penalty above 1.3, damped by CTL/50, capped when recovery is good** | **Capacity ratio + acute decay + asymmetric HRV blend; intra-day interpolation from a frozen morning value** |

No public method for fusing phone and Watch strap streams was found. Emuqu uses the Watch relay only after 5 s of phone silence and interleaves the streams by arrival time at finalize.

---

## 5. What Is New

Each statement gives only the part not found in a prior-art search made on 2026-10-08 (public source code, including FatMaxxer read directly at commit 3b10aa0 and GoldenCheetah; public vendor and app documentation; and the DFA α1 and training-load literature). Commit dates are author dates in US Central time (CST = UTC−6, CDT = UTC−5). Each form of a statement was publicly disclosed when it reached the public repository: on 2026-09-08 (first commit 9d89933) for forms committed before that date, and on its commit date for later forms, unless an earlier public disclosure is noted. Statement numbering follows v1.1. The section after each label is where the method is specified.

**N1 (Section 3.1.2). Live α1 is withheld, rather than shown with a reliability color, until the rolling 120 s window holds at least 64 beats *and* spans at least 118 s on the dropout-compensated beat clock of N2.** The 118 s is the window length minus one maximal RR interval, measured on the beat clock rather than on elapsed session time. Warm-up progress is shown as min(count/64, span/118), so 100% coincides with the gate passing.

*Builds on:* FatMaxxer's elapsed-time reliability coloring and Watchletic's 160-beat minimum (Table 4.1) [21][22]; adds withholding the value on a dual beat-count and beat-clock span gate, with matching progress.

*Earliest dated record:* flow-recovery 50da878, 2026-04-21 (first form: 64-beat gate, beat-only fill); emuqu-dev 7d6b4a6, 2026-09-03 (current form: 118 s span gate and min-of-ratios fill). Measured on the N2 clock from emuqu 14ecd58, 2026-10-06.

**N2 (Section 3.1.1). Each live beat is stamped with start = max(previous beat's end, arrival time − first arrival time + first beat's start), and that one clock both trims the rolling window and measures its span.** An offline closed form gives identical offsets: interval-sum time plus the running maximum of the wall-clock lead over the interval sum.

*Builds on:* FatMaxxer's live window trimmed on arrival time, and its file replay that rebuilds time from the RR sum (Table 4.1) [21]; adds a single dropout-compensated clock shared by trimming and span measurement, with an equivalent offline form.

*Earliest dated record:* emuqu 554540f, 2026-10-03 (first form: offline closed form); emuqu 14ecd58, 2026-10-06 (current form: live beat clock). The predecessor, trimming on wall-clock time (flow-recovery 95e7ae8, 2026-04-20), is prior art.

**N3 (Section 3.1.3). A live artifact filter judges each beat against the upper median of up to five preceding *accepted* beats, interpolates marked beats in place, returns the count of marked beats with the series, and withholds α1 when that count exceeds 6% of the window.** Rejected beats never enter the reference. At least three accepted beats are needed to judge. The rule is 20% relative deviation, with 300–2000 ms bounds, and marked beats are replaced by linear interpolation.

*Builds on:* FatMaxxer's previous-beat deviation filter, Watchletic's skipping of windows with too many corrections, AlphaHRV's 5% artifact assumption, HRV Logger's artifact rate (Table 4.2) [21][22][23][24], and Kubios median-referenced threshold correction [25][26]; adds an accepted-only trailing reference, in-place interpolation with a carried count, and refusal above 6%.

*Earliest dated record:* flow-recovery 50da878, 2026-04-21 (first form: filter rules); emuqu-dev 7d6b4a6, 2026-09-03 (current form: corrected count and 6% refusal).

**N4 (Section 3.1.4). A five-state live α1 status runs the silence check first, and every non-ok state clears the published value, so the per-second sample stream records nil instead of the last α1.** The five states are:
- warm-up, with a fill fraction;
- ok;
- stalled, after twice the recompute cadence of beat silence;
- fit failed;
- too many artifacts, with the fraction.

*Builds on:* FatMaxxer's elapsed-time color states (Table 4.1) [21]; adds clearing the value, on screen and in the recorded samples, in every non-ok state, including silence and rejection.

*Earliest dated record:* flow-recovery 50da878, 2026-04-21 (first form: warm-up, ok, stalled, fit failed); emuqu 14ecd58, 2026-10-06 (current form: clearing on every non-ok state). The too-many-artifacts state was added in emuqu-dev 7d6b4a6, 2026-09-03.

**N5 (Section 3.2.1). A post-session α1 dip below 0.75 that recovers within one analyzer window (≤ 120 s) is labeled an ectopic "shadow".** An asymmetric span is excluded from α1 summary statistics and band time: from 60 s before the dip to 120 s after recovery. A dip still open at session end is left unlabeled.

*Builds on:* the general observation that ectopic beats lower α1 [34]; adds a window-length rule that identifies and excludes the affected span.

*Earliest dated record:* flow-recovery 549f747, 2026-04-23 (first form: the same 120 s limit and 60/120 s padding); emuqu-dev 680bbee, 2026-08-25 (current form: shared exclusion for all summary statistics).

**N6 (Section 3.2.2). In the post-session summary statistics, a downward α1 threshold crossing is accepted only after α1 has stayed below the threshold for longer than the analyzer window (180 s against 120 s).** Time is counted per sample, capped at 5 s. Counting starts only after a 120 s warm-up, and only once α1 has first been seen at or above the threshold. The HR at the start of that sustained run is reported.

*Builds on:* the HR at α1 = 0.75 as an aerobic-threshold proxy [2], and the ramp-regression and clustering threshold estimates of Runalyze and AI Endurance (Table 4.3) [27][28]; adds a sustain rule longer than the window, for arbitrary field sessions.

*Earliest dated record:* flow-recovery 50da878, 2026-04-21 (first form: crossing without a sustain rule); emuqu 5c4a23d, 2026-10-04 (current form: armed-after-≥ 0.75 rule). The 120 s warm-up and 180 s sustain were added in flow-recovery 549f747, 2026-04-23, and the 5 s cap in emuqu 554540f, 2026-10-03.

**N7 (Section 3.3.1). A load-source ladder contains a route-history estimate tier with a conditional position.** The tier is promoted above every heart-rate-derived tier only when two conditions hold:
- the estimate rests on at least one earlier run of the same saved route (confidence above the no-prior value of 0.4);
- the recorded TRIMP is below half of the estimate.

Otherwise the tier is used only when no other source exists.

*Builds on:* the public fallback ladders of GoldenCheetah, TrainingPeaks and intervals.icu (Table 4.4) [12][29][30]; adds a conditional promotion rule driven by dropout evidence.

*Earliest dated record:* flow-recovery b0967a8, 2026-05-12 (first form: ladder with the route estimate last); emuqu 554540f, 2026-10-03 (current form: promotion rule).

**N8 (Sections 3.4.1–3.4.2). The load of a workout with a failed heart-rate strap is estimated from the user's own TRIMP per meter on earlier runs of a user-named saved route, matched in either direction.** Matching starts after 500 m:
- the live track must start within 150 m of the route;
- up to 300 evenly subsampled live points are compared with a 5 m-thinned prefix of the saved route, L + 200 m long;
- the mean nearest-point distance must be ≤ 30 m.

An earlier run counts only if it:
- ended before the workout;
- shares the workout's sport;
- starts within 150 m of either route end;
- re-matches the same route over its whole track;
- is neither a recovered partial session nor itself a substituted workout.

*Builds on:* intervals.icu's estimate of load from average HR with a model fitted to the athlete's earlier activities (Table 4.4) [12]; adds estimation from same-route history.

*Earliest dated record:* flow-recovery fba6e27, 2026-04-26 (first form: route matching at 500 m and ≤ 30 m, both directions); emuqu 5c4a23d, 2026-10-04 (current form: 300-point subsample and 5 m thinning). Later steps:
- TRIMP extrapolation: flow-recovery 6c127eb, 2026-04-27;
- estimator type: flow-recovery b0967a8, 2026-05-12;
- prior filters: emuqu 554540f, 2026-10-03.

**N9 (Section 3.4.2). Earlier-run TRIMP-per-meter ratios below half their median are dropped, and the estimator then chooses between no estimate, a 60/40 blend, prior only and recorded only.** No estimate is made when the recorded ratio is ≥ 0.7 × the prior mean; the blend is 60/40 prior to recorded.

The estimate is scaled to the recorded distance by default. It is scaled to the saved route distance instead when the recording is:
- within ±10% of that distance;
- missing;
- shorter than that distance in a crash-recovered or interrupted session.

The confidence is min(0.85, 0.4 + 0.15·n) for n retained earlier runs, or 0.4 with none.

*Builds on:* Banister TRIMP [9] as the per-run load measure; adds the outlier rule, case selection, distance scaling and confidence. No public estimator of this form was found in public code, vendor documentation or the training-load literature.

*Earliest dated record:* flow-recovery 6c127eb, 2026-04-27 (first form: ratio and min(0.85, …) confidence); emuqu 5c4a23d, 2026-10-04 (current form: truncation rule). Later steps:
- 0.7 ×, 60/40 and 0.4 rules: flow-recovery b0967a8, 2026-05-12;
- outlier drop: emuqu 554540f, 2026-10-03.

**N10 (Section 3.3.2). Power TSS is computed when a record is read, for workouts stored with normalized power but no TSS.** The FTP is user-entered, or estimated as 0.95 × the best 20-minute mean power over the last 90 days of running-family workouts. Only 20-minute windows with at least 90% per-second power coverage count.

*Builds on:* the 0.95 × 20-minute convention [11] and Stryd's critical-power estimate from about 90 days of data (Table 4.4) [31]; adds read-time derivation for stored history and the coverage rule.

*Earliest dated record:* flow-recovery b0967a8, 2026-05-12 (first form: 0.95 × best NP; read-time power TSS); emuqu 554540f, 2026-10-03 (current form: rolling 20-minute window with 90% coverage).

**N11 (Section 3.5.1). A training-readiness score combines a capacity-ratio map with an acute-fatigue term, a low-CTL branch, a damped ACWR penalty, a freshness bonus and an asymmetric blend with the morning recovery score.** The steps are:
- **Acute fatigue.** A 72 h exponentially decaying term (τ = 24 h, weight 0.30, used only on days with training) is added to ATL inside a piecewise capacity-ratio map.
- **Low-CTL branch.** Below a CTL of 3.2, the score switches to a strain branch.
- **ACWR penalty.** Any penalty above an ACWR of 1.3 is scaled by min(CTL/50, 1) and capped at 10% when the morning recovery score is at least 70.
- **Freshness.** A capped bonus is added for ATL dissipated since the morning.
- **Blend.** The result is blended asymmetrically with the recovery score: excess trust is min(CTL/40, 1) × 0.55, and deficit uplift is 0.30.

*Builds on:* the Banister fitness–fatigue model [9], Garmin's published Training Readiness inputs (formula not published) and Polar's cardio load status (Table 4.5) [32][33]; adds this combination and its reconciliation with the morning HRV score.

*Earliest dated record:* flow-recovery-dev c48eeb9, 2026-03-01 (first form: squashed import with the capacity map and freshness bonus); flow-recovery 6da94a6, 2026-05-01 (current form: CTL/50 ramp and rescue cap). Later steps:
- acute fatigue and asymmetric blend: flow-recovery-dev 6eddc97, 2026-03-15;
- CTL 3.2 branch: flow-recovery c63d56c, 2026-04-23.

**N12 (Section 3.5.2). ATL and CTL are interpolated during the day from a frozen morning snapshot toward live values by hours-since-morning/24.** Live readiness therefore equals the frozen value at acceptance, and the freshness anchor collapses once the snapshot is more than a day old.

*Builds on:* Garmin's documented intra-day updates of Training Readiness (Table 4.5) [32]; adds interpolation from a frozen snapshot.

*Earliest dated record:* flow-recovery d69cddd, 2026-03-24 (first form); flow-recovery 870028e, 2026-04-05 (current form: stale-anchor collapse).

**N13 (Section 3.6). RR intervals relayed by a smartwatch from a chest strap are taken only while the phone's own strap stream has been silent for at least 5 s.** The relay queue is still drained while the phone is live, so beats are not replayed. At finalize, the two streams are interleaved by arrival time, each keeping its own order, before the beat timeline is rebuilt as a running sum of intervals.

*Builds on:* standard Bluetooth heart-rate RR delivery to phone and watch; no public fusion method of this kind was found in public code (FatMaxxer, GoldenCheetah) or vendor documentation.

*Earliest dated record:* flow-recovery 7b8c540, 2026-04-30 (first form: Watch relay without the silence gate); emuqu 554540f, 2026-10-03 (current form: 5 s gate). Earlier and intermediate records:
- strap connector: flow-recovery d381c96, 2026-04-29;
- merge type: emuqu-dev c615ce5, 2026-09-02.

**N14 (Section 3.1.6). The live α1 filter, window, cadence and 6% rejection are re-run offline on the gap-corrected timeline of N2, not on the interval sum.** Each reading is written back to per-second samples only while it is less than one cadence (20 s) old, and α1 is cleared elsewhere.

*Builds on:* FatMaxxer's replay of a recorded RR file through its live pipeline, rebuilding time from the RR sum, and intervals.icu's post-ride DFA α1 (Table 4.3) [12][21]; adds the gap-corrected timeline and freshness-limited write-back.

*Earliest dated record:* flow-recovery 50da878, 2026-04-21 (first form: offline re-run with the live parameters); emuqu 554540f, 2026-10-03 (current form: gap-corrected timeline and freshness-limited write-back). The 6% rejection was added in emuqu-dev 7d6b4a6, 2026-09-03.

**Prior work used, not presented as new.**
- Detrended fluctuation analysis, its integration and box detrending, and the 4–16 / 16–64 scale ranges with 2^(1/8) log spacing [1].
- The interpretation of α1 ≈ 0.75 as an aerobic-threshold proxy and ≈ 0.50 as a higher-intensity marker [2][3][4].
- The published effect of artifact correction on α1 and the 3%/6% figures [4][5].
- Threshold-based RR artifact correction in general, including Kubios-style median-relative filters [25][26].
- Live α1 on a rolling 120 s window recomputed every 20 s [21][22][23][24]. This includes marking α1 as unreliable before a minimum elapsed time, requiring a minimum beat count, dropping artifact beats and displaying the artifact percentage, skipping windows with too many corrections, and replaying a recorded RR file through the live pipeline.
- Load-metric fallback ladders as such [12][29][30].
- Banister TRIMP and its sex coefficients [9][10].
- The Karvonen heart rate reserve [16].
- Edwards zone TRIMP [17].
- Coggan normalized power, intensity factor and TSS [11].
- hrTSS as TRIMP normalized to an hour at LTHR [11][15].
- The 0.95 × 20-minute FTP convention [11].
- LTHR ≈ 0.88 × HRmax as a population approximation [11][15].
- Pa:Hr decoupling and efficiency factor [11][15].
- The PMC exponentially weighted ATL/CTL/TSB [11].
- The acute:chronic workload ratio [13].
- MET values for activities [18].
- Median-of-recent-beats HR display smoothing.
- Barometric or GPS altitude handling, the "return to start" bearing aid, Bluetooth packet parsing and PDF report layout are outside this paper.

---

## 6. Verification

On 2026-10-08 a separate reimplementation was checked on public PhysioNet recordings [20]. The cross-implementation report, `Tools/validation/RESULTS.md`, gives its full method and results. The methods were reimplemented in Python from the Swift source at e028039. A port's results were accepted as the app's only after the port reproduced the app's own unit-test expectations.

**Port fidelity.** Across eight test suites, 114 of 114 cases were reproduced. These include DFAAnalysisTests (15 of 15), DFAReferenceValidationTests (9 of 9) and LiveDFAAnalyzerTests (19 of 19). On the seeded known-exponent processes (white, 1/f and Brownian noise, 4096 samples), the port reproduces the app's measured α1 values exactly.

**Artifact correction (nsr2db).** The test windows were 1,080 artifact-free 120 s windows from 54 records of the PhysioNet Normal Sinus Rhythm RR Interval Database (nsr2db; 24-hour ambulatory Holter recordings) [20], with clean α1 of 1.20 ± 0.28. They received premature ectopic beats with a compensatory pause, or missed beats, at fixed rates, following the design of Rogers et al. [5]. Each window had three seeded placements, giving 3,240 trials per artifact type and rate.

**Table 6.1.** α1 error under injected artifacts. MAE is mean absolute error. "Published" means windows with a corrected fraction ≤ 6%, which the app would show.

| Artifact | Rate | α1 bias, no correction | α1 bias, app filter (before the 6% gate) | MAE, no correction / app filter | Windows published | α1 bias in published windows |
|---|---:|---:|---:|---|---:|---:|
| ectopic | 1% | −0.549 | −0.005 | 0.549 / 0.021 | 100% | −0.005 |
| ectopic | 3% | −0.771 | −0.020 | 0.771 / 0.061 | 56% | −0.051 |
| missed | 1% | −0.433 | −0.008 | 0.505 / 0.054 | 100% | −0.008 |
| missed | 3% | −0.590 | −0.023 | 0.598 / 0.097 | 100% | −0.023 |

At these rates the filter removes almost all of the bias that uncorrected artifacts introduce. Beat times in this check come from electrocardiogram (ECG) annotations of resting and daily-life recordings. This paper documents the live α1 method. It does not claim accuracy of α1 during exercise, or agreement of the α1 crossing with laboratory thresholds for an individual user.

Training load, TSB and the ACWR damper are bookkeeping on training history; they do not predict performance or injury. Emuqu is a consumer wellness app, not a medical device.

---

## 7. Design Tradeoffs

**Withhold rather than flag.** Live α1 shows a gap instead of a low-reliability value. The cost is fewer published values during warm-up, after dropouts and in noisy windows.

**Conservative artifact gate.** The 6% gate counts corrected intervals, and one ectopic beat alters two. Windows are therefore withheld somewhat earlier than an event count would suggest.

**A simple, fixed filter.** A 20% deviation from a five-beat trailing median is transparent and cheap on device. The cost is that it also corrects some genuine sinus variability, most at rest, and withholds windows that straddle an abrupt sustained change in heart rate.

**No synthetic beats.** The beat clock decides which beats are in a window, but nothing is inserted for a dropout, so beats on either side of a short gap are adjacent in the DFA input.

**Sustained crossings.** The 180 s sustain makes crossings robust to single beats, at the cost of missing excursions shorter than three minutes. The reported HR is taken at the start of the run without lag correction.

**Unconverted load scales.** Route estimates and Banister TRIMP enter ATL/CTL on their own scale, labeled by source. Each figure stays traceable to how it was measured, at the cost of a series that mixes TSS-scale and TRIMP-scale values.

**History-based substitution.** Route substitution needs a saved route and earlier clean runs. TRIMP per meter does not adjust for pace, weather or fitness change between runs.

**Hand-set product rules.** The readiness constants, the shadow padding and the route-estimator thresholds are product rules, not fitted outcome models. They were chosen for consistency with the recovery score and with each other.

**Running-only auto-FTP.** The automatic FTP uses running-family workouts; cycling FTP is entered by the user.

---

## 8. Provenance and Dates

The design method used to build Emuqu is described in Paper 5, *Blind-Audit Convergence: A Method for Directing AI to Produce Converged Software Designs* ([link](05-blind-audit-convergence-method.md)). The earliest dated record of each method in this paper is given with its statement in Section 5.

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

### 8.3 Dated records outside git

- **2026-02-16, 2026-02-18 and 2026-03-04.** App-generated "Flow_Recovery" PDF session reports, dated by the generation date printed in each footer. They show a readiness figure out of 10 next to CTL, ATL, TSB and ACWR (N11); they do not show the formula.
- **2026-04-24.** App screenshot IMG_5551 shows the ectopic-shadow rule in the app (N5): "A single ectopic beat contaminates a1's 120-second rolling window for about the window's length … These dips are excluded from LT1 / threshold detection". Earlier screenshots from the same session (IMG_5524, IMG_5526, IMG_5537) still report a crossing at 4:00, so the rule appeared that day. IMG_5527 shows "Re-analyze a1 … using the current Kubios-style filter" (N14).
- **2026-05-05.** Screenshot IMG_6017 shows a "TRAINING READINESS 3.9 Rest" gauge (N11).
- **2026-05-06 (uploaded 2026-05-10).** The project README and "flow-recovery-audit.md" describe the following, with the statements they relate to:
  - live α1 diagnostics: warming up with a percentage, strap silent for N seconds, fit failed (N1, N4);
  - a Kubios-style ectopic filter with linear interpolation (N3);
  - re-analysis of α1 for old sessions (N14);
  - direction-agnostic route matching (N8);
  - power TSS (N10);
  - training readiness from the recovery score plus a training-load modifier (N11).
- **2026-05-13.** Screenshots IMG_6245 and IMG_6262 show "DFA a1 warming up - 0 % of 2-min window" (N1).

### 8.4 Public disclosures
- 2026-01-27: TestFlight beta opened (over 1,500 sessions by 2026-03-06; 45 testers and over 6,500 sessions by August 2026). A public TestFlight join link appeared in the project README by May 2026.
- 2026-05-19: Substack article "A Powerfully Lazy Man's Way to Better Health" (Paper 1 lists what it disclosed).
- 2026-08-10: Substack article "How I Build Production Software by Directing AI" (Paper 5 lists what it disclosed).
- 2026-09-08: public repository github.com/chrissharp80/emuqu (first commit 9d89933).
- 2026-10-08: these white papers.

Neither Substack article disclosed any method in this paper.

### 8.5 Authorship
Chris Sharp is the sole author of these papers and of the design, and the only person who commits to the repositories above. The code was written by AI coding assistants under his direction, and some commits carry "Claude" as author or co-author; he supplied the requirements, design direction, review, testing and acceptance, and wrote no code by hand. He developed the methods described here independently and did not learn them from anyone.

### 8.6 Document history
v1.0, v1.1, v1.2 and v1.3 all published 2026-10-08. v1.1 added prior-art comparison and provenance; v1.2 restructured method-first and moved verification detail to the cross-implementation report; v1.3 applied an editorial review (series-wide format, corrected internal references, tightened claims).

---

## References

Items marked [S] were seen only through a search-engine extract on 2026-10-08.

1. Peng CK, Havlin S, Stanley HE, Goldberger AL. Quantification of scaling exponents and crossover phenomena in nonstationary heartbeat time series. Chaos. 1995;5(1):82–87. doi:10.1063/1.166141
2. Rogers B, Giles D, Draper N, Hoos O, Gronwald T. A new detection method defining the aerobic threshold for endurance exercise and training prescription based on fractal correlation properties of heart rate variability. Front Physiol. 2021;11:596567. doi:10.3389/fphys.2020.596567
3. Gronwald T, Rogers B, Hoos O. Fractal correlation properties of heart rate variability: a new biomarker for intensity distribution in endurance exercise and training prescription? Front Physiol. 2020;11:550572. doi:10.3389/fphys.2020.550572
4. Rogers B, Gronwald T. Fractal correlation properties of heart rate variability as a biomarker for intensity distribution and training prescription in endurance exercise: an update. Front Physiol. 2022;13:879071. doi:10.3389/fphys.2022.879071
5. Rogers B, Giles D, Draper N, Mourot L, Gronwald T. Influence of artefact correction and recording device type on the practical application of a non-linear heart rate variability biomarker for aerobic threshold determination. Sensors (Basel). 2021;21(3):821. doi:10.3390/s21030821
6. Schaffarczyk M, Rogers B, Reer R, Gronwald T. Validation of a non-linear index of heart rate variability to determine aerobic and anaerobic thresholds during incremental cycling exercise in women. Eur J Appl Physiol. 2023;123(2):299–309. doi:10.1007/s00421-022-05050-x
7. Van Hooren B, Mennen B, Gronwald T, Bongers BC, Rogers B. Correlation properties of heart rate variability to assess the first ventilatory threshold and fatigue in runners. J Sports Sci. 2025;43(2):125–134. Epub 2023 Nov 2. PMID: 37916488
8. Sempere-Ruiz N, Sarabia JM, Baladzhaeva S, Moya-Ramón M. Reliability and validity of a non-linear index of heart rate variability to determine intensity thresholds. Front Physiol. 2024;15:1329360. doi:10.3389/fphys.2024.1329360
9. Banister EW, Calvert TW, Savage MV, Bach T. A systems model of training for athletic performance. Aust J Sports Med. 1975;7:57–61.
10. Morton RH, Fitz-Clarke JR, Banister EW. Modeling human performance in running. J Appl Physiol. 1990;69(3):1171–1177. doi:10.1152/jappl.1990.69.3.1171
11. Allen H, Coggan A. Training and racing with a power meter. 2nd ed. Boulder (CO): VeloPress; 2010.
12. intervals.icu. Documentation of per-sport load priority, load estimated from average HR, and post-ride DFA α1 [Internet]. URL not recorded (accessed 2026-10-08) [S]
13. Gabbett TJ. The training–injury prevention paradox: should athletes be training smarter and harder? Br J Sports Med. 2016;50(5):273–280. doi:10.1136/bjsports-2015-095788
14. Impellizzeri FM, Tenan MS, Kempton T, Novak A, Coutts AJ. Acute:chronic workload ratio: conceptual issues and fundamental pitfalls. Int J Sports Physiol Perform. 2020;15(6):907–913. doi:10.1123/ijspp.2019-0864
15. Friel J. The triathlete's training bible. 4th ed. Boulder (CO): VeloPress; 2016.
16. Karvonen MJ, Kentala E, Mustala O. The effects of training on heart rate; a longitudinal study. Ann Med Exp Biol Fenn. 1957;35(3):307–315.
17. Edwards S. The heart rate monitor book. Polar Electro Oy; 1993.
18. Ainsworth BE, Haskell WL, Herrmann SD, Meckes N, Bassett DR Jr, Tudor-Locke C, et al. 2011 Compendium of Physical Activities: a second update of codes and MET values. Med Sci Sports Exerc. 2011;43(8):1575–1581. doi:10.1249/MSS.0b013e31821ece12
19. Hellard P, Avalos M, Lacoste L, Barale F, Chatard JC, Millet GP. Assessing the limitations of the Banister model in monitoring training. J Sports Sci. 2006;24(5):509–520. doi:10.1080/02640410500244697
20. Goldberger AL, Amaral LAN, Glass L, Hausdorff JM, Ivanov PCh, Mark RG, et al. PhysioBank, PhysioToolkit, and PhysioNet: components of a new research resource for complex physiologic signals. Circulation. 2000;101(23):e215–e220. doi:10.1161/01.CIR.101.23.e215
21. Peake I. FatMaxxer: open-source Android app for real-time DFA α1 with a Polar H10 [Internet]. GitHub repository IanPeake/FatMaxxer; source read directly at commit 3b10aa0 (2025-05-05), file app/src/main/java/online/fatmaxxer/publicRelease1/MainActivity.java. https://github.com/IanPeake/FatMaxxer (accessed 2026-10-08)
22. Watchletic. Blog post on reproducing DFA α1 on Apple Watch and Wear OS (app version 3.2.0) [Internet]. 2026. https://watchletic.com/blog/reproducing-dfa-alpha-1-on-apple-watch-and-wear-os (accessed 2026-10-08) [S]
23. AlphaHRV. Product documentation describing a 200-beat window, 1–5 s updates and a > 5% artifact assumption [Internet]. URL not recorded (accessed 2026-10-08) [S]
24. PubMed Central. Article PMC8193503, reporting HRV Logger's 2-minute windows and artifact rate [Internet]. https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8193503/ (accessed 2026-10-08) [S]
25. Tarvainen MP, Niskanen JP, Lipponen JA, Ranta-aho PO, Karjalainen PA. Kubios HRV – heart rate variability analysis software. Comput Methods Programs Biomed. 2014;113(1):210–220. doi:10.1016/j.cmpb.2013.07.024
26. Lipponen JA, Tarvainen MP. A robust algorithm for heart rate variability time series artefact correction using novel beat classification. J Med Eng Technol. 2019;43(3):173–181. doi:10.1080/03091902.2019.1640306
27. Runalyze. Documentation of α1 threshold estimation [Internet]. URL not recorded (accessed 2026-10-08) [S]
28. AI Endurance. Documentation of α1 threshold estimation [Internet]. URL not recorded (accessed 2026-10-08) [S]
29. GoldenCheetah. TriScore metric, file src/Metrics/SwimScore.cpp: "On zero fallback to TRIMP Zonal Points for HR based score" (present since April 2018) [Internet]. https://github.com/GoldenCheetah/GoldenCheetah (accessed 2026-10-08)
30. TrainingPeaks. Documentation of TSS source order (power TSS, rTSS, hrTSS) [Internet]. URL not recorded (accessed 2026-10-08) [S]
31. Stryd. Documentation of critical power estimated from about 90 days of data [Internet]. URL not recorded (accessed 2026-10-08) [S]
32. Garmin. Training Readiness documentation (inputs; updates through the day) [Internet]. URL not recorded (accessed 2026-10-08) [S]
33. Polar. Cardio load status documentation [Internet]. URL not recorded (accessed 2026-10-08) [S]
34. Altini M. Blog post on the effect of ectopic beats on DFA α1 [Internet]. Medium. URL not recorded (accessed 2026-10-08) [S]

---

## Appendix A: Parameters

**Table A.1.** Parameters.

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
| trailing reference | ≤ 5 (≥ 3 to judge) | beats | Accepted beats used for the median |
| maxCorrectedFraction | 0.06 | fraction | Window rejection |
| α1 boxes | 4–16 | beats | Short-scale DFA |
| α2 boxes | 16–64 | beats | Long-scale DFA |
| box ratio | 2^(1/8) | — | Log spacing |
| max box | ⌊n/4⌋ | beats | Cap on box size |
| α2 minimum beats | 256 | beats | α2 reported only at or above this |
| alpha1AerobicThreshold | 0.75 | — | Easy/Threshold band edge; AT1 crossings; shadows |
| alpha1AnaerobicThreshold | 0.50 | — | Threshold/Very Hard band edge; AT2 crossings |
| alpha1WarmupSec | 120 | s | Ignore crossings before this |
| alpha1SustainSec | 180 | s | Sustain required for a crossing |
| crossing list cap | 6 | events | Card length |
| shadow max span | 120 | s | Dip recovery limit for a shadow |
| approachPad / recoveryPad | 60 / 120 | s | Shadow padding |
| maxSampleGapSec | 5 | s | Per-sample time cap in band totals |
| live HR median | 8 | beats | Display smoothing |
| Watch strap freshness | 10 | s | Relay considered at all |
| phone strap live | < 5 | s | Watch relay ignored while live |
| wristFallbackSilenceSec | 10 | s | Fall through to wrist HR |
| wristHRMaxAgeSec | 30 | s | Wrist HR freshness |
| strapNoticeGraceSec | 15 | s | Delay before the strap notice |
| detectionTriggerMeters | 500 | m | Route matching starts |
| matchToleranceMeters | 30 | m | Mean fit limit |
| start gate | 150 | m | Start-point proximity (match and priors) |
| prefix extra | 200 | m | Saved prefix = traveled + 200 |
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

## Appendix B: Pseudocode

Pseudocode for the methods in Section 5.

```
# B1 Beat clock (N2)
state: originWall=nil, originBeat=0, nextStart=nil
stamp(p):
  start = nextStart if nextStart != nil else p.t_ms
  if p.wallClockMs != nil:
    if originWall == nil: originWall = p.wallClockMs; originBeat = start
    start = max(start, p.wallClockMs - originWall + originBeat)
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
readiness(Rrec, todayTrimp, CTL, ATL, anchorATL, ACWR, loads):
  if loads: raw = sum(L.load*exp(-L.h/24)); acute = 0.30*raw
  else: raw = todayTrimp; acute = 0.35*todayTrimp
  if CTL >= 3.2: x = piecewise((ATL+acute)/CTL)
  else: x = max(10, 100 - 0.5*(ATL+raw))
  if ACWR != nil and ACWR > 1.3:
    p = min(0.05 + 0.5*(ACWR-1.3), 0.40) * min(max(CTL,0)/50, 1)
    if Rrec >= 70: p = min(p, 0.10)
    x *= (1 - p)
  if anchorATL != nil and anchorATL > 0: x += min(1.5*max(0, anchorATL-ATL), 20)
  if x > Rrec: x = Rrec + (x-Rrec)*min(max(CTL,0)/40,1)*0.55
  elif x < Rrec: x = x + (Rrec-x)*0.30
  return 50 if not finite(x) else clamp(x, 0, 100)
live(Rrec, morning, liveM, now):
  f = clamp((now - morning.end)/24h, 0, 1)
  ATLe = ATL_m + (liveM.ATL - ATL_m)*f; CTLe = CTL_m + (liveM.CTL - CTL_m)*f
  anchor = ATLe if f >= 1 else ATL_m
  loads = recent72h(liveM) if liveM.todayTrimp > 0 else nil
  return readiness(Rrec, liveM.todayTrimp, CTLe, ATLe, anchor, ATLe/CTLe if CTLe>0 else nil, loads)
frozen(Rrec, ATL, CTL) = readiness(Rrec, 0, CTL, ATL, ATL, ATL/CTL if CTL>0 else nil, nil) / 10

# B9 Dual-path strap fusion (N13)
tick():
  if new phone beats: dfa.ingest(new); hr = 60000/median(last 8 rr); lastStrapAt = now
  if watchStrapAt != nil and now - watchStrapAt < 10:
    q = drain(watchQueue)
    if q nonempty and not (lastStrapAt != nil and now - lastStrapAt < 5):
      wallClockMs = watchStrapAt - sum(q) (on phone stream clock)
      pts = [] ; for rr in q: pts.append(rr, wallClockMs); wallClockMs += rr
      watchBuf += pts; dfa.ingest(pts); show watch strap HR; lastWatchAt = now
  arbitrate(silences, wristHR fresh <= 30 s)
merge(source, phone, watch):
  base = phone if source == STRAP else []
  if watch empty: return base
  if any point lacks wallClockMs: return sort_by_t(base + watch)
  out = two-pointer interleave by wallClockMs (phone wins ties, each side keeps order)
  clock = out[0].t_ms; for p in out: p.t_ms = clock; clock += p.rr
  return out

# B10 Offline re-analysis (N14)
tl = gapCorrected(rr)   # t_ms + running max((wallClockMs - originWall) - (t_ms - originT))
for t in 120, 140, ... <= duration:
  w = [b in tl where t-120 <= b.t/1000 < t]
  if |w| >= 64: (v,k) = clean(w.rr); if k/|v| <= 0.06 and (r = dfa(v)): emit(t, r)
for sample s: r = latest reading with r.t <= s.t
  s.alpha1 = r.alpha1 if r and s.t - r.t < 20 else nil
```

## Appendix C: Source Map

**Table C.1.** Source files for each method.

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
| Tests cited | `EmuquTests/DFAAnalysisTests.swift`, `EmuquTests/DFAReferenceValidationTests.swift`, `EmuquTests/LiveDFAAnalyzerTests.swift`, `EmuquTests/LiveDFAAnalyzerStreamTests.swift`, `EmuquTests/RouteTRIMPEstimatorTests.swift`, `EmuquTests/WorkoutRRMergeTests.swift` |
| Science register | `Tools/science_register/register.json` |
