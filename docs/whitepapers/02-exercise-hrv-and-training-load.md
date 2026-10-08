# EMUQU — Real-Time DFA α1 and Dropout-Robust Training Load

**Gated live α1, window-length ectopic discrimination, route-matched load substitution and a recovery-aware readiness model**

Technical White Paper • v1.0

October 2026

Chris Sharp

Describes Emuqu at source revision e028039 (2026-10-07); scoring version v3.1.oct2026.

---

## Executive Summary

Emuqu is an iOS application that records workouts from a chest strap (Polar-class Bluetooth heart-rate sensor), an Apple Watch, GPS, foot pods and power meters. It turns that data into two kinds of numbers. During exercise it shows the short-term scaling exponent of detrended fluctuation analysis (DFA α1). Across days it keeps a training-load history (ATL, CTL, TSB) and a daily training-readiness score. Both depend on a beat stream that is often interrupted. Bluetooth drops beats, straps lose skin contact, the phone and the Watch take turns holding the link, and one ectopic beat can move α1 for two minutes.

This paper sets out how the application handles those failures. It is meant to be specific enough that an engineer could rebuild each method. The main methods are:

1. **A gated live α1 analyzer.** A value is published only when a 120 s window holds at least 64 beats *and* spans at least 118 s. The span is measured on a beat clock that adds the time lost to Bluetooth dropouts back in, and the same clock is used to trim the window. Beats go through a trailing-median relative-deviation filter that interpolates in place. A window with more than 6 % corrected beats is rejected. A five-state status machine clears the displayed value whenever it is not freshly computed.
2. **Ectopic discrimination by window length, after the session.** A dip of α1 below 0.75 that recovers within one analyzer window (120 s) is labelled an "ectopic shadow". The label is padded by 60 s before and 120 s after, and the padded span is left out of summary statistics. A threshold crossing counts only if α1 stays below the threshold for 180 s, which is longer than the window.
3. **A training-load precedence ladder.** Power TSS comes first, including power TSS derived at read time from stored normalized power and an automatically estimated FTP. Next comes a route-history estimate, used only when the recorded heart-rate load looks like a strap dropout. Then hrTSS, MET-based load, Banister TRIMP, and finally the route-history estimate as a last resort.
4. **Route-matched load substitution.** When the strap fails on a route the user has saved, the workout's load is rebuilt from that user's own TRIMP-per-metre on earlier clean runs of the same route. Route matching works in either direction. Earlier runs are filtered, outliers are dropped, the estimate is blended with or replaced by the partial recording, and it carries an explicit confidence value.
5. **A readiness model that accounts for recovery.** It combines a 72 h exponentially decaying acute-fatigue term with the ATL/CTL capacity ratio and a damped ACWR penalty. The result is blended asymmetrically with the morning HRV recovery score and interpolated through the day from a frozen morning snapshot.
6. **Fusion of the two strap paths.** RR intervals relayed by the Watch are used only while the phone's own strap stream is silent, so no beat is counted twice. At finalize, the two streams are interleaved by wall-clock arrival time and the beat timeline is rebuilt.

The paper also states what is *not* claimed: DFA itself, the 0.75/0.50 interpretation, Banister TRIMP, Coggan TSS, hrTSS, the PMC exponentially weighted averages and the ACWR concept are all prior art. It also lists the known limitations, including a measured upward bias of the DFA implementation at short scales on synthetic signals with known exponents.

---

## 1. The Problem

### 1.1 Live DFA α1 is fragile

DFA [1] integrates a beat-interval series and measures how the detrended fluctuation F(n) grows with box size n. The log–log slope over boxes of 4–16 beats is α1. In incremental exercise tests, α1 falls with intensity and crosses about 0.75 near the first ventilatory or lactate threshold [2][3][4]. That makes it attractive as a live intensity readout that needs no laboratory. Four practical problems stand in the way.

- **Too little data.** α1 needs enough beats *and* enough time. At 160 bpm, 64 beats take about 24 s, so a beat-count gate alone lets a fit run on a fraction of the nominal two-minute window.
- **Artifacts.** A missed, extra or ectopic beat creates a large local fluctuation. Published work shows that artifact correction itself biases α1, with minimal bias below about 3 % corrected beats and only a small shift in the derived threshold at 6 % [4][5]. Uncorrected artifacts push α1 toward the Brownian range (1.5 or more) during exercise.
- **Dropouts.** A Bluetooth chest strap delivers RR intervals in notification batches. When the link drops, beats are simply lost. A timeline built as the running sum of delivered intervals then stops advancing while real time keeps going. A window cut on that timeline does not describe the last two minutes.
- **Stale numbers.** A live display that keeps its last value after the strap stops, or after a window is rejected, shows a number that is no longer being computed.

### 1.2 Interpreting α1 after the session

A single ectopic beat stays inside a 120 s rolling window for 120 s, so it can drag α1 below 0.75 for up to one window length. An "LT1 estimate" taken from the first sub-0.75 sample can therefore reflect one bad beat. Agreement between the α1 = 0.75 crossing and gas-exchange VT1 is good on average but has individual limits of agreement around ±10 bpm, and it weakens in fatigued runners [2][6][7].

### 1.3 Training load when the strap fails

Heart-rate load models (Banister TRIMP [8][9], hrTSS) need heart rate. When the strap fails partway through a workout, the recorded TRIMP can be a small fraction of the real effort; a 40-minute run can record a TRIMP of 2. That number then enters the exponentially weighted ATL/CTL averages [8][10] and pushes every later readiness and form figure down. Power-based TSS [10] avoids heart rate but needs a power meter and an FTP. Generic pace-to-load conversions without heart rate have no validated published formulation. The existing approaches either accept the low number or ask the user to fix the record by hand.

### 1.4 Readiness and the acute:chronic ratio

The acute:chronic workload ratio (ACWR) [11] became popular as a way to flag load spikes, but its statistical basis and its "sweet spot" band have been criticised as flawed [12]. At low chronic load the ratio is numerically unstable: one walk can move it by 0.2. A readiness score that applies ACWR penalties without damping can contradict the morning HRV-based recovery score on the same screen.

---

## 2. Architecture Overview

| Phase | Operation | Purpose |
|---|---|---|
| Acquisition (1 Hz tick) | Ingest new phone-strap RR; take Watch-relayed RR only if the phone strap has been silent for ≥5 s; arbitrate the displayed HR (strap → Watch-relayed strap → wrist) | One beat stream with no double counting; a displayed HR that is never stale |
| Live HR | Median of the last 8 RR intervals → bpm | A stable readout that does not jitter beat to beat |
| Live α1 | Beat clock → 120 s trim → dual gate → artifact filter → 6 % rejection → DFA → status machine | A value is shown only when it is current and supported by the data |
| Finalize | Interleave phone and Watch RR by wall clock; rebuild `t_ms`; compute TRIMP, hrTSS, power TSS, splits, decoupling | A single coherent RR series for every downstream metric |
| Route estimate | Match a saved route; gather and filter earlier runs; three-case estimator; confidence | Recover the load of a workout whose strap failed |
| Offline α1 | Re-run the live pipeline on the gap-corrected timeline; write readings back to samples | Repair older sessions; keep live and offline numbers comparable |
| Report | Ectopic-shadow detection; sustained 0.75/0.50 crossings; band minutes; LT1 estimate; per-split α1 | A post-hoc reading that is robust to single-beat artifacts |
| Load history | Precedence ladder per workout → daily sums (capped) → ATL/CTL EWMA → TSB | Bookkeeping of training history |
| Readiness | 72 h acute fatigue + capacity ratio + damped ACWR + freshness + asymmetric recovery blend; intra-day interpolation; frozen morning value | A daily "capacity for more load" figure that matches the recovery score |

```
 phone strap RR ─┐                       ┌─► live HR (median of 8)
                 ├─► tick (1 s) ─────────┼─► LiveDFA: beat clock → trim → gate → clean → DFA → status
 Watch-relayed ──┘   (Watch RR only if   └─► samples (1/s, carry current α1 or nil)
 strap RR            phone silent ≥5 s)
                         │ finalize
                         ▼
          wall-clock interleave → rebuilt t_ms → TRIMP / hrTSS / NP / splits
                         │                         │
                         ▼                         ▼
              route matcher + estimator      offline α1 re-analysis
                         │                         │
                         ▼                         ▼
           load ladder → daily load → ATL/CTL  ectopic shadows → crossings → LT1 estimate
                         │
                         ▼
               readiness (frozen at morning acceptance; live interpolation)
```

---

## 3. Methods in Detail

### 3.1 Live DFA α1

#### 3.1.1 Parameters

| Parameter | Value |
|---|---|
| Window length W | 120 s |
| Recompute cadence C | 20 s (wall clock, measured between ingest calls) |
| Minimum beats for a fit | 64 |
| Span slack | 2 s (so the span gate is W − 2 = 118 s) |
| Silence before "stalled" | 2 × C = 40 s |
| Rejection threshold (corrected fraction) | > 0.06 |
| Low-confidence constant (declared) | 0.03 (see §5) |

#### 3.1.2 Beat clock (dropout compensation)

Each RR point carries `t_ms` (the running sum of delivered intervals), `rr_ms` and, when available, `wallClockMs` (milliseconds since the strap stream started, taken at arrival). The analyzer re-stamps every incoming beat:

1. Let `start = nextStart` if a previous beat exists, else the beat's own `t_ms`.
2. If the beat has `wallClockMs`: on the first such beat, record `originWall = wallClockMs` and `originBeat = start`. Then set `start = max(start, wallClockMs − originWall + originBeat)`.
3. Set `nextStart = start + rr_ms`. Store the beat with `t_ms = start`.

A beat therefore starts no earlier than the previous beat ended and no earlier than its arrival time allows. Time lost in a dropout is added back, and batching jitter, where arrival lags the interval sum, is absorbed by the `max`. Offline, the same timeline is computed in closed form as `t_ms + correction`, where `correction` is the running maximum of `(wall − originWall) − (t_ms − origin.t_ms)` over all beats so far. A unit test checks that the two produce identical offsets on a stream with a dropout.

#### 3.1.3 Ingest, trim and progress

On each ingest of new points, given a current time `now`:

1. Ignore the call if no session start has been set.
2. Append the re-stamped beats to the rolling buffer. If any points arrived, set `lastBeatAt = now`.
3. **Trim on the beat clock:** remove every beat with `t_ms < newest.t_ms − W`. Trimming and span measurement use the same clock. An earlier version cut on wall time while measuring span on beat time, and every dropout then left the span permanently short of the gate.
4. **Progress:** `byBeats = min(1, count/64)`, `byTime = min(1, span/118)`, where `span = (last.t_ms − first.t_ms)/1000`. Publish `fill = min(byBeats, byTime)`. The denominator is the same 118 s the gate uses, so 100 % means the gate passes.
5. If fewer than C seconds have passed since the last recompute, only refresh the status. Otherwise record the recompute time and recompute.

The recording ticker calls `tick(now)` once per second when no new beats arrived, so the status can move to "stalled" even when the strap is silent.

#### 3.1.4 Dual gate

`hasEnoughDataForFit = count ≥ 64 AND span ≥ 118 s`. Both conditions must hold. The 2 s slack exists because trimming keeps the oldest beat at or after the cutoff, so a full window measures up to one RR interval less than 120 s. The slack equals the 2000 ms ceiling of a plausible beat.

#### 3.1.5 Artifact filter ("trailing-median relative-deviation filter")

Input: the window's RR values in order. If there are fewer than 8 values, return them unchanged with a corrected count of 0.

*Pass 1, marking:* keep a list `recentClean` holding at most 5 values. For each beat `rr` in order:
- If `rr < 300` ms or `rr > 2000` ms, mark it as an artifact.
- Otherwise, if `recentClean` holds at least 3 values, sort it and take `med = sorted[⌊count/2⌋]`. For an even count this is the upper of the two middle values. Mark the beat as an artifact if `|rr − med| / med > 0.20`.
- Otherwise (fewer than 3 clean values so far) accept the beat.
- Append every accepted beat to `recentClean`, dropping the oldest when it exceeds 5. Artifacts never enter the reference.

*Pass 2, interpolation in place:* for each artifact at index i, find the nearest non-artifact index l < i and r > i. If both exist, `out[i] = rr[l] + (rr[r] − rr[l]) · (i − l)/(r − l)`. If only l exists, copy `rr[l]`. If only r exists, copy `rr[r]`. If neither exists, leave the value unchanged.

Output: the corrected series, which has the same length as the input, and `correctedCount`, the number of marked beats. The count is returned together with the values because in-place interpolation hides how much of the series was invented: comparing lengths would always show zero.

#### 3.1.6 Recompute and status machine

Recompute:
1. If the dual gate fails, refresh the status and stop.
2. Clean the window and store `correctedFraction = correctedCount / n`, which is 0 for an empty series.
3. If `correctedFraction > 0.06`, set status to `tooManyArtifacts(fraction)` and clear α1, band and R². Stop.
4. Run DFA (§3.1.7). If it returns nothing, set status to `fitFailed` and clear. Stop.
5. Otherwise publish α1, R² and the band (§3.1.8), record `lastComputeAt = now`, and refresh the status.

Status refresh, in this order:
1. If `now − lastBeatAt > 40 s`, set `stalled(seconds)` and clear the published value.
2. Else, if the dual gate fails, set `warmup(fill)` and clear.
3. Else, if a value is published, set `ok`.
4. Else, if the status was `stalled`, set `warmup(fill)`, meaning beats are back and the window is waiting for its fit. Otherwise keep the current reason (`tooManyArtifacts` or `fitFailed`) until the next recompute.

Invariant: α1 is non-nil exactly when the status is `ok`. The value shown live, spoken by the voice coach, sent to the Watch and written to the per-second workout sample is this field, so a rejected or stale window writes nil into the sample stream.

#### 3.1.7 DFA core

Prior art [1]; listed here so the implementation can be reproduced exactly.

1. Require n ≥ 64.
2. Integrate: `y[k] = Σ_{j≤k} (rr[j] − mean)`.
3. Box sizes: generate a log-spaced sequence from `lo` with ratio 2^(1/8), rounding each to an integer and dropping consecutive duplicates, while the rounded value is ≤ `hi`; append `hi` if it is not already last. For α1, `lo = 4` and `hi = min(16, ⌊n/4⌋)`. This gives {4,5,6,7,8,9,10,11,12,13,15,16} whenever n ≥ 64, which is always the case live. For α2, `lo = 16` and `hi = min(64, ⌊n/4⌋)`.
4. For each box size s: split `y` into ⌊n/s⌋ non-overlapping boxes from the start, discarding the remainder. Fit a least-squares line to each box against the index 0…s−1 and sum the squared residuals. `F(s) = sqrt(total / (boxes · s))`.
5. Regress ln F(s) on ln s by ordinary least squares, replacing ln F with −10 when F ≤ 0. The slope is α and R² is the fit quality.
6. α1 needs at least 3 box sizes. α2 is reported only with at least 3 sizes and n ≥ 256.

#### 3.1.8 Display bands

Bands: α1 ≥ 0.75 is "Easy"; 0.50 ≤ α1 < 0.75 is "Threshold"; α1 < 0.50 is "Very Hard". The live badge, voice coach, Watch and post-workout screens all call one shared function. The 0.50 band is presented as a coarse intensity label, not as a claim about the second threshold.

#### 3.1.9 Offline re-analysis

For archived sessions, the same pipeline runs offline:

1. Require at least 64 RR points. Re-stamp them on the gap-corrected timeline (§3.1.2).
2. Session duration is the stored duration, else the last offset. It must exceed 120 s.
3. For t = 120, 140, 160, … ≤ duration, take the beats with offset in [t − 120 s, t). This uses a two-pointer sweep, so the total cost is O(n).
4. If the window has at least 64 beats, clean it (§3.1.5). Reject it if the corrected fraction is above 0.06; otherwise run DFA and emit `(t, α1, R²)`.
5. Write back: each per-second sample takes the latest reading at or before its offset, but only if that reading is less than 20 s older than the sample. Otherwise the sample's α1 is set to nil, so a rejected stretch never inherits a value from minutes earlier.

**Difference from live:** the offline path checks beat count but **not** the ≥118 s span. Its windows are always 120 s of timeline, but after a long dropout a window can hold ≥64 beats covering much less than 120 s of actual signal. The live analyzer would report "warming up" for that window; the offline path fits it.

### 3.2 Post-hoc interpretation of α1

The input is the per-second workout samples, each carrying α1 or nil.

#### 3.2.1 Ectopic-shadow detection

1. Walk the samples that carry α1, in time order.
2. When α1 < 0.75: if no dip is open, open one at this sample's offset (`start`) and record it as the deepest point. Otherwise update the deepest point if this value is lower.
3. When α1 ≥ 0.75 and a dip is open: let `span = offset − start`. If `0 < span ≤ 120 s`, emit a shadow covering `[max(0, start − 60), offset + 120)`, with the deepest point recorded for the chart marker. Close the dip either way.
4. A dip still open when the session ends is not labelled.

The reasoning is that an isolated bad beat can depress α1 only while it is inside the 120 s window, so a dip that recovers within one window length is consistent with an artifact. The asymmetric padding covers the "approach" (α1 falls quickly once the beat enters the window) and the "recovery shoulder" (values such as 0.87 that are still contaminated until the beat leaves the window). The comments in the code record that padding of 30 s and then 60 s still let artifacts through in real sessions.

Shadows are drawn on the chart with a neutral "beat artifact" marker. Samples inside a shadow are left out of the average, maximum and minimum α1 and out of the band-time totals.

#### 3.2.2 Band totals and the first sustained AT1 crossing (summary statistics)

Each α1 sample counts for `dt = min(max(1, offset − previousOffset), 5)` seconds (1 for the first sample), so a strap gap is never counted as time in a band. Shadow samples are skipped. Band seconds accumulate as in §3.1.8. The first sustained AT1 crossing is found by a detector that considers only samples at or after 120 s:
- At α1 ≥ 0.75: set `armed`, reset the pending crossing and the sustained counter.
- At α1 < 0.75 and armed: if nothing is pending, record the pending offset and the **HR at this sample**. Add `dt` to the sustained counter. Once the counter reaches 180 s, return `(pendingOffset, pendingHR)`.

A session that is already below 0.75 at 2:00 never registers a crossing, because the detector has to see α1 at or above 0.75 first.

#### 3.2.3 Crossing list and the LT1 card

A second routine lists crossings of both 0.75 (AT1) and 0.50 (AT2). It runs one tracker per threshold over samples at or after 120 s. The "previous" value can come from a sample before 120 s. Per sample, with `dt = max(1, offset − previousOffset)`:
- If α1 < threshold: when the previous α1 was ≥ threshold and nothing is pending, create a pending down-crossing with that sample's offset, α1, HR and pace. Add `dt` to the sustained counter. If something is pending, the counter is at least 180 s, and that down-crossing has not already been emitted, emit it.
- If α1 ≥ threshold: if a pending down-crossing had reached 180 s, emit an up-crossing with the current sample's HR and pace. Clear the pending crossing and the counter.
- Keep at most the first 6 events.

The "α1-estimated aerobic threshold (LT1)" card shows the HR of the first down-AT1 crossing that has an HR, together with its time. It is labelled "estimate" and carries a caption giving roughly ±10 bpm lab agreement. **The current code does not offer this value as an LTHR setting.** A comment in the source explains why the suggestion was removed: LT1 sits well below LTHR, and LTHR is the hrTSS denominator, so substituting LT1 would inflate every later load figure.

This routine differs from §3.2.2 in two ways. Its `dt` is not capped at 5 s, and it does not skip shadow samples. The 180 s rule still guarantees that a dip of 120 s or less cannot commit, but a single sample arriving after a long gap can satisfy the sustain on its own (see §5).

### 3.3 Training-load ladder

Every archived workout resolves one load figure and a source tag. The tiers are tried in order, and the first that applies wins:

| # | Source | Rule | Scale |
|---|---|---|---|
| 1 | Power | `storedPowerTSS`: if a stored intensity factor IF > 0 and moving seconds (last sample offset) > 60, use `IF² × moving_h × 100`; else the stored power TSS if > 0. Otherwise **read-time power TSS**: NP > 0, an FTP for the sport, moving seconds > 60 → `(NP/FTP)² × moving_h × 100`. | TSS |
| 2 | Route history (replacement) | `routeEstimateReplacesHRLoad` (§3.4.6) and an estimate exists | Banister TRIMP |
| 3 | hrTSS | stored hrTSS > 0 | TSS |
| 4 | METs | computed MET load > 0 | TSS-like |
| 5 | Banister TRIMP | stored TRIMP > 0 | Banister TRIMP |
| 6 | Route history (last resort) | stored estimate > 0 | Banister TRIMP |

**FTP anchors.** Running-family sports (run, trail run, walk, hike, treadmill) use the user's running FTP if one is set, else the automatic estimate. Cycling (outdoor and indoor) uses only a user-entered cycling FTP. Other sports have no FTP.

**Automatic running FTP.**
1. Take workouts from the last 90 days whose sport is in the running family.
2. For each workout, build a per-second power array indexed by sample offset (0 ≤ offset < 24 h); a second is empty unless watts > 0.
3. Slide a 1200 s window. At each position where the window is full and holds at least ⌈0.9 × 1200⌉ = 1080 power readings, compute the mean of the readings present. Keep the session's best.
4. Take the best across sessions; `FTP = round(0.95 × best)`. Store it with the source session. If no session qualifies, clear the estimate.
5. Recompute at most once every 7 days unless forced.

Because tier 1 is computed when the record is read, historical sessions that stored NP before any FTP existed are counted as power TSS once an FTP becomes available. No migration is needed.

**hrTSS.** `hrTSS = TRIMP_session / TRIMP_ref × 100`. TRIMP_ref is Banister TRIMP for 60 one-minute samples at LTHR. LTHR is the user's value, else `0.88 × HRmax`. hrTSS requires both HRmax and resting HR.

**Banister TRIMP** [8][9]. Per beat: `HR = 60000/rr`, duration `rr/1000` s, `HRR = clamp((HR − HRrest)/(HRmax − HRrest), 0, 1)`, and `TRIMP += (dur/60) · HRR · A · e^(k·HRR)`. Coefficients are A = 0.64, k = 1.92 for males and A = 0.86, k = 1.67 for females. At least 30 beats are needed. Without both HR anchors, an Edwards five-zone %HRmax fallback is used [13].

**MET load.** Per-sample METs come from a lookup table keyed on sport and speed; the current code does not use grade. Load is `MET_hours / 12 × 100`, reported only if it exceeds 0.5. The per-sample path needs at least 30 samples and METs on at least a quarter of them. Each sample counts for the gap to the next sample, clamped to 1–30 s. The fallback uses one bucket: total distance > 50 m, mean speed between 0.5 and 60 km/h, moving duration ≥ 60 s, and METs looked up at the mean speed.

**Scale caveat.** Power TSS and hrTSS are calibrated so that 100 equals one hour at threshold. MET load is normalised to the same nominal anchor. Banister TRIMP and the route-history estimate are on the Banister TRIMP scale, which is numerically different. The ladder still places the route estimate above hrTSS (tier 2), and its value enters ATL/CTL unconverted. The application labels the source ("LOAD" or "TRIMP") but does not rescale between the two families. See §5.

**Daily series and PMC.** Per workout, a figure above 1000 is capped at 1000. Workouts with no precomputed figure use a summary Banister TRIMP from average HR, or 0 if there is no average HR. Loads are summed per local calendar day; days without a workout count as 0, and a day is capped at 1200. ATL and CTL are exponentially weighted averages: `X_today = load·(1 − e^(−1/τ)) + X_yesterday·e^(−1/τ)`, with τ = 7 days for ATL and 42 days for CTL, and `TSB = CTL − ATL`. This is the standard Performance Manager construction [10] and is not claimed; fitted Banister parameters are known to be unstable [14].

### 3.4 Route-matched load substitution

#### 3.4.1 Saved routes

Matching uses only routes the user has explicitly saved and named in a route library. The archive is not mined for routes. Matching runs only for run, trail run, walk, hike and bike, and only against saved routes of the same sport.

#### 3.4.2 Route matching

Input: the live (or recorded) GPS track.

1. Require at least 2 points and a travelled length L ≥ 500 m.
2. For each saved route, test it forward and reversed. The reversed candidate is rebuilt as a new route from the reversed points, so its climb profile matches the direction of travel.
3. For each direction:
   a. **Start gate:** the first live fix must be within 150 m of the candidate's first point.
   b. **Prefix:** take the candidate's points from the start until the cumulative length reaches L + 200 m (inclusive of the point that crosses it).
   c. **Thinning:** walk the prefix and keep a point only if it is at least 5 m from the last kept point. Always keep the first and last points.
   d. **Live subsample:** if the live track has more than 300 points, take 300 at indices ⌊i · N/300⌋.
   e. **Fit:** the mean, over subsampled live points, of the distance to the nearest *point* of the thinned prefix.
   f. Accept if the fit is ≤ 30 m.
4. Return the accepted candidate with the lowest fit, across all routes and both directions.

#### 3.4.3 Selecting earlier runs (priors)

For the matched route, take the start anchors to be its first and last points, since a prior may have run it in either direction. A prior must satisfy all of the following:
- It is a workout in the archive that ended at or before the current workout's first GPS fix.
- It is the same sport.
- It is not a recovered partial session.
- It is not itself a dropout whose load was already replaced by a route estimate (§3.4.6).
- Its first GPS fix is within 150 m of either anchor.
- Running the full matcher (§3.4.2) on the prior's whole track returns *this* saved route.

For each prior, `ratio = TRIMP / distance_m`, using that session's stored Banister TRIMP and distance, both > 0.

#### 3.4.4 Outlier drop

If more than one ratio exists, compute the median (the mean of the two middle values for an even count) and drop ratios below 0.5 × median. This removes earlier dropouts the app did not detect, which would otherwise pull the estimate toward the failure it is meant to correct. `priorAvg` is the arithmetic mean of the remaining ratios, and n is their count.

#### 3.4.5 Estimation cases

Let `today = recordedTRIMP / recordedDistance` when both are > 0, else none.

1. If both `priorAvg` and `today` exist and `today ≥ 0.7 × priorAvg`: **no estimate**; the recorded value stands.
2. If both exist (today < 0.7 × priorAvg): `estimate = (0.6·priorAvg + 0.4·today) × D`, confidence `c_p`.
3. Only `priorAvg`: `estimate = priorAvg × D`, confidence `c_p`, marked as prior-dominant.
4. Only `today`: `estimate = today × D`, confidence 0.4.
5. Neither: no estimate.

Here `c_p = min(0.85, 0.4 + 0.15·n)`.

**Target distance D:**
- No recorded distance (or ≤ 0): use the saved route distance S.
- `0.9·S ≤ recorded ≤ 1.1·S` (the whole loop): use S.
- `recorded < S` and the recording may be truncated (a crash-recovered session, or one the user saved as interrupted): use S.
- Otherwise use the recorded distance. This covers a partial run of the route, which is credited only for the distance covered, and a run longer than the route, which is credited in full.

The estimate, its confidence and the route name are stored on the workout. It is computed at finalize (not treated as truncated), in crash recovery (truncated), and in a background backfill over archived workouts (truncated only for crash or interrupted sessions).

#### 3.4.6 When the estimate replaces the recorded load

`routeEstimateReplacesHRLoad` is true when all three hold:
- estimate > 0
- confidence > 0.4 (it rests on at least one prior)
- `recordedTRIMP` (taken as 0 if absent) < 0.5 × estimate

Because case 2 blends in 40 % of the recorded value, a recorded load below half the blended estimate means the recording is under roughly 37 % of the user's usual load on the route, which indicates a dropout rather than an easy day. When the condition holds, the estimate takes ladder tier 2, above hrTSS and every other heart-rate-derived tier. Otherwise it is used only as tier 6. The UI always shows the recorded value next to the estimate.

### 3.5 Training readiness

#### 3.5.1 Inputs

- R_rec: the morning recovery score (0–100).
- todayTrimp.
- CTL and ATL.
- morningATL.
- ACR: the acute:chronic ratio.
- Recent workout loads: each workout's resolved load and the hours since it, within the last 72 h. These are supplied only when todayTrimp > 0, because on rest days ATL already carries yesterday's load and the freshness bonus handles dissipation.

#### 3.5.2 Computation

1. **Acute fatigue.** With recent loads: `raw = Σ load_i · e^(−h_i/24)` and `acute = 0.30 · raw`. Without them: `raw = todayTrimp` and `acute = 0.35 · todayTrimp`.
2. **Base readiness.**
   - If CTL ≥ 3.2: `ratio = (ATL + acute)/CTL`, mapped piecewise-linearly through (0 → 100), (0.8 → 85), (1.0 → 70), (1.3 → 50), (1.5 → 30), (2.0 → 10), and held at 10 above 2.0. A ratio ≤ 0 gives 100.
   - If CTL < 3.2 (no established base): `max(10, 100 − 0.5·(ATL + raw))`.
3. **ACWR damper**, only if ACR > 1.3:
   - `p = min(0.05 + 0.5·(ACR − 1.3), 0.40)`
   - `p ← p · min(max(CTL, 0)/50, 1)`
   - if R_rec ≥ 70, `p ← min(p, 0.10)`
   - `readiness ← readiness · (1 − p)`
   - No penalty applies below 0.8; the earlier "detraining" penalty was removed with reference to [12].
4. **Freshness bonus.** If morningATL > 0: `readiness += min(1.5 · max(0, morningATL − ATL), 20)`.
5. **Asymmetric recovery blend.**
   - If readiness > R_rec: `R_rec + (readiness − R_rec) · min(max(CTL,0)/40, 1) · 0.55`.
   - If readiness < R_rec: `readiness + (R_rec − readiness) · 0.30`.
6. A non-finite result becomes 50. Otherwise clamp to 0–100. The display divides by 10 and labels the result Ready (≥ 7), Moderate (≥ 4.5), Fatigued (≥ 2) or Rest. "Ready" is downgraded to "Moderate" when a separate advice gate recommends an easier session.

#### 3.5.3 Frozen and live values

**Frozen.** When the morning session is accepted, readiness is computed once with todayTrimp = 0, morningATL = ATL (so no freshness bonus) and ACR = ATL/CTL. It is stored on the 0–10 scale with the session, so history and the dashboard agree for that day.

**Live (intra-day).** With h hours since the morning session ended, `f = clamp(h/24, 0, 1)`:
- `ATL_eff = ATL_m + (ATL_live − ATL_m)·f`
- `CTL_eff = CTL_m + (CTL_live − CTL_m)·f`
- `ACR = ATL_eff/CTL_eff` when CTL_eff > 0

The morning values come from the frozen snapshot, or 0 if it is missing. The freshness anchor is ATL_m, except when f = 1 (a stale session), where ATL_eff is used and the bonus collapses to 0. At acceptance time the live figure equals the frozen one, and it then relaxes toward the live training state over the day. If no training metrics are available, readiness equals the recovery score. The narrative says today's training "pulled readiness down" or that rest "lifted" it when the gap to the morning score is at least 3 points.

### 3.6 Fusing the two strap paths

The recorder ticks once per second, in this order:

1. **Phone strap.** If new beats arrived, pass them to the α1 analyzer. Set the live HR to `60000 / median(last 8 RR > 0)`, using the mean of the two middle values for an even count. Record `lastStrapHRAt = now`.
2. **Watch-relayed strap.** Proceed only if the Watch reported strap data within the last 10 s. Always drain the queue of relayed RR values, filtered to a plausible range. **Use** them only if the phone strap is not live, meaning `lastStrapHRAt` is ≥ 5 s old or absent. A strap can be linked to the phone and the Watch at the same time, so both paths carry the same beats; using both would count every beat twice. Draining while the phone is live also stops those beats from being replayed later. Each beat used is given a wall-clock time, assigned backward from the batch's arrival time by the cumulative interval sum and expressed on the phone stream's clock. The beats are appended to a separate buffer, passed to the α1 analyzer, and the Watch-reported strap HR is shown. `lastWatchRoutedHRAt` is a separate freshness stamp.
3. **Arbitration** (pure function). In strap mode:
   - If both strap channels have been silent for more than 10 s, display the Watch's wrist HR, but only if it was received within the last 30 s.
   - If wrist HR is also missing, clear the displayed HR rather than leave a stale value.
   - Raise a "strap not connected" or "strap silent" notice only after 15 s of recording and only while both strap channels are silent.
   In Watch mode, wrist HR is always used.

**Merge at finalize.**
- If the workout's source was the strap, start from the phone buffer; otherwise start from nothing, since an old buffer may hold another session's beats.
- With no Watch-relayed beats, return the phone buffer unchanged.
- If any point lacks a wall-clock time, concatenate and sort by `t_ms`.
- Otherwise interleave the two lists by `wallClockMs`, preferring phone on ties and keeping each side's own order (a phone batch shares one arrival time). Then rebuild `t_ms` as the running sum of `rr_ms` from the first point's `t_ms`.

Ordering by `t_ms` alone would put beats the Watch carried through a phone dropout among the phone's later beats, because the phone's `t_ms` leaves out the gap.

### 3.7 Per-split α1 and decoupling (brief, standard)

**Per-split α1.**
- Splits are distance segments from GPS. Each split's time window is found by walking the stored track until the cumulative distance reaches the split's end; the end time is that fix's timestamp. If the track does not line up, the split's own duration is used.
- The split's α1 is the arithmetic mean of sample α1 values with offsets in [start, end).

**Pa:Hr decoupling** [10].
- Moving time is divided in half; paused steps and the step across a resume add no time or HR.
- `EF = (distance/seconds)/mean HR` for each half, using HR samples on the gap-corrected timeline.
- `decoupling % = (EF₁ − EF₂)/EF₁ × 100`.
- The figure is withheld for tracks under 5 minutes or under 500 m.

---

## 4. What Is New

The following are, to the author's knowledge, not described in the published literature or in public product documentation in this combination and form.

N1. Publishing a live DFA α1 value only when a rolling window satisfies both a minimum beat count (64) and a minimum elapsed span (window length minus one maximal RR interval, 118 s of a 120 s window), and reporting readiness progress as the minimum of the two fill ratios, so that 100 % coincides with the gate passing.

N2. Re-stamping each live beat on a dropout-compensating clock, where a beat's start is the later of the previous beat's end and its arrival time relative to the first arrival, and using that same clock both to trim the rolling window and to measure its span, so that dropouts neither freeze the window nor shorten it, while matching an offline gap correction defined as the running maximum of the wall-clock lead over the interval sum.

N3. Carrying the count of interpolated beats out of an in-place trailing-median relative-deviation filter (rejection outside 300–2000 ms; a beat more than 20 % from the upper median of up to five preceding accepted beats, once at least three exist), and refusing to publish α1 when the corrected fraction exceeds 6 %.

N4. A five-state live α1 status machine (warm-up with fill fraction, ok, stalled after twice the recompute cadence of silence, fit failed, too many artifacts with fraction) in which the silence check runs first and every non-ok state clears the published value, so the per-second sample stream records nil instead of a stale α1.

N5. Classifying a post-session α1 excursion below 0.75 as an ectopic artifact ("shadow") when it recovers within at most one analyzer window length (120 s), marking an asymmetric interval of 60 s before the dip and 120 s after recovery, excluding that interval from α1 summary statistics and band time, and leaving unlabelled any dip still open at session end.

N6. Accepting a downward α1 threshold crossing only after α1 has stayed below the threshold for a period strictly longer than the analyzer window (180 s versus 120 s), counting time per sample capped at 5 s, starting only after a 120 s warm-up and only once α1 has first been observed at or above the threshold, and reporting the HR at the start of the sustained run as a field aerobic-threshold estimate.

N7. A training-load precedence ladder in which a route-history load estimate is placed above all heart-rate-derived tiers only when it rests on at least one earlier run of the same saved route (confidence above the no-prior floor of 0.4) and the recorded heart-rate TRIMP is less than half of it, and otherwise is used only when no other load source exists.

N8. Estimating the load of a workout with a failed heart-rate strap from the user's own TRIMP-per-metre on earlier runs of a user-named saved route, where the route is matched in both directions (after ≥500 m; start within 150 m; mean nearest-point distance ≤30 m from at most 300 evenly subsampled live points to a 5 m-thinned prefix of the saved route L + 200 m long), and earlier runs must end before the workout, share its sport, start within 150 m of either route end, re-match the same route over their whole track, and be neither recovered partial sessions nor themselves load-substituted dropouts.

N9. Dropping earlier-run TRIMP-per-metre ratios below half their median, then choosing between no estimate (recorded ratio ≥ 0.7 × prior mean), a 60/40 prior/recorded blend, prior only, or recorded only; scaling to the recorded distance, or to the saved route distance when the recording is within ±10 % of it, missing, or possibly truncated by a crash; and attaching a confidence of min(0.85, 0.4 + 0.15·n) for n retained earlier runs, or 0.4 with none.

N10. Deriving power TSS when a record is read, for workouts stored with normalized power but no TSS, from an FTP that is either user-entered or automatically estimated as 0.95 × the best 20-minute mean power over the last 90 days of running-family workouts, counting only 20-minute windows with at least 90 % per-second power coverage.

N11. A training-readiness score that adds a 72 h exponentially decaying acute-fatigue term (τ = 24 h, weight 0.30, used only on days with training) to ATL inside a piecewise capacity-ratio map. It switches to a strain branch below a CTL of 3.2, scales any ACWR penalty above 1.3 by min(CTL/50, 1), caps that penalty at 10 % when the morning recovery score is at least 70, adds a capped freshness bonus for ATL dissipated since morning, and blends the result asymmetrically with the recovery score (excess trust min(CTL/40, 1) × 0.55; deficit uplift 0.30).

N12. Interpolating ATL and CTL during the day from a frozen morning snapshot toward live values by hours-since-morning/24, so that live readiness equals the frozen value at acceptance and the freshness anchor collapses once the snapshot is more than a day old.

N13. Taking RR intervals relayed by a smartwatch from a chest strap only while the phone's own strap stream has been silent for at least 5 s, still draining the relay queue while the phone is live so beats are not replayed, and at finalize interleaving the two streams by arrival time, keeping each stream's own order, before rebuilding the beat timeline as a running sum of intervals.

N14. Re-running the live α1 pipeline offline on the gap-corrected timeline with the same window, cadence, filter and rejection threshold, and writing each reading back to per-second samples only while it is less than one cadence old, clearing α1 elsewhere.

**Not claimed (prior art).**
- Detrended fluctuation analysis, its integration and box detrending, and the 4–16 / 16–64 scale ranges with 2^(1/8) log spacing [1].
- The interpretation of α1 ≈ 0.75 as an aerobic-threshold proxy and ≈ 0.50 as a higher-intensity marker [2][3][4].
- The published effect of artifact correction on α1 and the 3 %/6 % figures [4][5].
- Threshold-based RR artifact correction in general, including Kubios-style median-relative filters [15][16].
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

## 5. Accepted Tradeoffs and Limitations

**Validation status** (from the project's science register, scoring version v3.1.oct2026, using its exact status words):

| Register entry | Status | Scope |
|---|---|---|
| dfa-a1-exercise-threshold | supported-transfer | Live intensity band; LT1 estimate |
| dfa-artifact-rejection | validated | The 3 %/6 % correction thresholds are taken from the published bias figures [4] |
| training-load-ladder | supported-transfer | ATL, CTL, TSB |
| acwr-readiness-damper | awaiting-validation | ACWR damper and freshness bonus in readiness |

The route-history estimator, the ectopic-shadow rule, the readiness capacity map and the recovery blend have no outcome validation of their own. They are hand-set product rules. The register's allowed language for training load is "bookkeeping on training history, never a prediction of performance". For the ACWR damper it is "damper, bookkeeping", never injury risk. Nothing in this paper should be read as predicting performance or injury.

**DFA known-exponent check.** A seeded test suite (4096 samples) feeds the DFA core synthetic processes with analytic exponents of 0.5 (uncorrelated Gaussian noise), 1.0 (Voss–McCartney 1/f noise) and 1.5 (Brownian motion). Over boxes 4–16 the implementation measures **0.581 / 1.088 / 1.526**, which is biased upward at the short scale. The test tolerance for α1 is ±0.15. Over boxes 16–64 the α2 assertions hold to ±0.10 for white and Brownian noise and ±0.15 for pink noise. Offset and amplitude invariance hold to 1e-9. The upward short-scale bias of about 0.08 on white noise is close to the 0.50 band edge, so live values near 0.50–0.60 should be read as directional. The suite was added in commit 725da03 (2026-09-16).

**Evidence transfer.** The 0.75 crossing was established under incremental laboratory protocols. Field sessions are arbitrary, and individual agreement is about ±10 bpm, worse when fatigued [2][6][7]. The comments in the code note that agreement between a chest strap and ECG for α1 is much wider at high intensity, which is exactly where the lower bands sit.

**HR at the crossing.** The LT1 estimate takes HR at the *start* of the sustained run, while α1 at that moment describes the preceding 120 s window. During a ramp, HR at that instant is higher than the mean HR the window describes, so the estimate may read high. No lag correction is applied.

**Two crossing detectors.** The summary statistic (§3.2.2) caps per-sample time at 5 s and skips shadows. The crossing list and LT1 card (§3.2.3) do neither. A sample arriving after a long gap can satisfy the 180 s sustain by itself in the latter, so the LT1 card and the summary statistic can disagree on the same session.

**Offline span gate.** The offline re-analyzer has no ≥118 s span check (§3.1.9), so after long dropouts it can fit windows that live analysis would have held in warm-up.

**DFA across gaps.** Neither path inserts anything for missing beats. Beats on either side of a short dropout are adjacent in the DFA input. The beat clock fixes *which* beats are in the window, not the gap inside it.

**Filter behaviour.** The trailing median is updated only with accepted beats. An abrupt, sustained RR change of more than 20 % (for example, the first seconds of a sprint) can mark the rest of a window as artifact until the window starts after the change. That window is then rejected at 6 % rather than mis-reported. The 0.20 ratio may also over-correct real high-intensity variability. A diagnostic log records the corrected fraction for every window so this can be checked.

**Low-confidence constant unused.** A 3 % "low-confidence" threshold is declared alongside the 6 % rejection threshold, but at e028039 no production path reads it. Windows between 3 % and 6 % are published with no flag.

**Scale mixing in the load ladder.** Route estimates and Banister TRIMP are on a different numeric scale from TSS-family values. When tier 2 replaces hrTSS for a dropout session, ATL/CTL receive a TRIMP-scale number among TSS-scale neighbours. The app labels the source but does not convert. Some downstream constants (the low-CTL readiness branch at 3.2, Foster strain at 1600) were rescaled by the Banister 0.64 factor to fit the mixed series. That is a pragmatic choice, not a calibration.

**Route estimator scope.** The estimator needs a saved route and earlier clean runs. TRIMP-per-metre ignores pace, weather and fitness changes between runs. Matching is point-to-point, not point-to-segment, so very sparse saved routes match less tightly; the 5 m thinning bounds the added error at 2.5 m. The confidence formula is heuristic.

**MET load.** The per-sample MET lookup uses sport and speed only, not grade. Comments in the code that mention grade are out of date. The 12-MET threshold anchor is a fixed population value.

**Auto-FTP.** Only running-family workouts are used. Cycling FTP must be entered by the user.

**Readiness.** The capacity map, the low-CTL branch, the 0.30/0.35 acute weights, the freshness gain and the blend weights are hand-calibrated. The CTL/50 and CTL/40 ramps reflect the instability of ACWR at low chronic load [12]; they are not a validated dose–response.

**Sample clock.** Per-second workout samples are stamped with a moving-time counter, while the offline α1 readings use a gap-corrected beat timeline. In sessions with manual pauses the two clocks may diverge. This was not evaluated for this paper.

---

## 6. Comparison to Existing Approaches

| Aspect | Emuqu (this paper) | Published method / product (public documentation only) |
|---|---|---|
| DFA core | Peng DFA, boxes 4–16, ratio 2^(1/8), non-overlapping forward boxes | Peng et al. [1]; PhysioNet reference implementation (same principles) |
| α1 window | 120 s rolling, 20 s cadence, live | Rogers/Gronwald studies use 2-minute windows on Kubios-processed data [2][3][4]; exact live recompute schemes in consumer apps are not publicly documented |
| Readiness gate | ≥64 beats AND ≥118 s span on a dropout-compensated clock | Not publicly documented in the products the author is aware of |
| Artifact correction | Trailing median of up to 5 accepted beats, ±20 %, linear interpolation in place, reject > 6 % | Kubios: threshold-based and automatic correction (Lipponen & Tarvainen) [15][16]; the 3 %/6 % effects are from Rogers/Gronwald [4][5] |
| Post-hoc ectopic handling | Window-length shadow rule with 60/120 s padding | Not publicly documented |
| Crossing rule | 180 s sustained, after 120 s warm-up | Laboratory protocols use incremental stages and regression of α1 against HR [2] |
| Load model | Ladder: power TSS → (route, if dropout) → hrTSS → METs → TRIMP → route | TSS, hrTSS and the PMC are documented by Allen & Coggan and TrainingPeaks [10]; the order of fallback sources in commercial platforms is not publicly documented |
| Strap dropout | Route-matched substitution from the user's own earlier runs, with confidence | No published method found by the author; commercial handling is not publicly documented |
| Auto-FTP | 0.95 × best 20-min with ≥90 % coverage, 90 days, running | 0.95 × 20-minute test is Coggan's convention [10]; Stryd and others document their own estimators |
| ACWR | Penalty > 1.3, damped by CTL/50, capped by recovery | Gabbett's ratio [11]; critique by Impellizzeri et al. [12] |
| Readiness | Capacity ratio + acute decay + asymmetric HRV blend | Banister fitness–fatigue model [8]; vendors' readiness algorithms are not publicly documented |

---

## 7. Provenance and Dates

- **Author and sole committer:** Chris Sharp <chrissharp80@gmail.com>.
- **Private development repository** chrissharp80/emuqu-dev: first commit 2026-08-16 (squashed from earlier work).
- **Public repository** github.com/chrissharp80/emuqu (licence PolyForm Strict 1.0.0): first commit 2026-09-08.
- **First appearance of each component in emuqu-dev history:**

| Component | First added |
|---|---|
| Live DFA analyzer | 2026-08-16 |
| Route TRIMP estimator | 2026-08-16 |
| Offline α1 re-analyzer | 2026-08-16 |
| Threshold-crossing and LT1 cards | 2026-08-31 |
| α1 report cards (ectopic shadows, band statistics) | 2026-08-31 |
| Training-load precedence ladder (as its own type) | 2026-09-02 |
| Phone/Watch RR merge (as its own type) | 2026-09-02 |

- **DFA known-exponent validation:** commit 725da03, 2026-09-16, public repository.
- **Earlier product name "Flow Recovery"** (the author's own records): app-generated "Flow_Recovery_<date>.pdf" session reports in the author's Google Drive dated 2026-02-15, 2026-02-17 and 2026-03-03; a "Flow Recovery - Bluetooth" screen recording dated 2026-03-23; and a "flow-recovery-audit.md" dated 2026-05-10.
- **Source revision described:** e028039 (2026-10-07); scoring version v3.1.oct2026.
- **Publication date of this paper:** 2026-10-08.

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
| lowConfidenceCorrectedFraction | 0.03 | fraction | Declared; not read by production code |
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
