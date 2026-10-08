# EMUQU — Real-Time DFA α1 and Dropout-Robust Training Load

**Gated live α1, window-length ectopic discrimination, route-matched load substitution and a recovery-aware readiness model**

Technical White Paper • v1.1

v1.1 (2026-10-08): adds prior-art comparison, independent validation, and full provenance.

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

The paper also states what is *not* claimed: DFA itself, the 0.75/0.50 interpretation, Banister TRIMP, Coggan TSS, hrTSS, the PMC exponentially weighted averages and the ACWR concept are all prior art. So are several live-α1 practices that open tools already publish: a rolling 120 s window recomputed every 20 s, a minimum-elapsed-time or minimum-beat-count warning, dropping or counting artifact beats, and replaying a recorded beat file through the live pipeline (FatMaxxer, Watchletic). Section 5 states, for each method, only the specific rule that survives a prior-art search.

Section 4 reports an independent check of the artifact filter and the 6 % rejection gate on PhysioNet ECG recordings, using Python ports verified against the app's own unit tests. With the filter, α1 bias under injected artifacts stays near −0.02 up to 3 %. The filter also alters 21.6 % of artifact-free resting windows, and the gate withholds α1 in 7.3 % of them. Near the 6 % limit the gate tends to publish under-corrected windows. No exercise data were used. The paper also lists the other known limitations, including a measured upward bias of the DFA implementation at short scales on synthetic signals with known exponents.

---

## 1. The Problem

### 1.1 Live DFA α1 is fragile

DFA [1] integrates a beat-interval series and measures how the detrended fluctuation F(n) grows with box size n. The log–log slope over boxes of 4–16 beats is α1. In incremental exercise tests, α1 falls with intensity and crosses about 0.75 near the first ventilatory or lactate threshold [2][3][4]. That makes it attractive as a live intensity readout that needs no laboratory. Four practical problems stand in the way.

- **Too little data.** α1 needs enough beats *and* enough time. At 160 bpm, 64 beats take about 24 s, so a beat-count gate alone lets a fit run on a fraction of the nominal two-minute window.
- **Artifacts.** A missed, extra or ectopic beat creates a large local fluctuation. Published work shows that artifact correction itself biases α1, with minimal bias below about 3 % corrected beats and only a small shift in the derived threshold at 6 % [4][5]. Left uncorrected, artifacts move α1 a long way. In resting Holter recordings (clean α1 about 1.2), injected ectopic and missed beats at only 1 % lowered α1 by 0.55 and 0.43, toward the white-noise value of 0.5 (§4.2). The direction and size of the effect during exercise, where α1 is already 0.5–1.0, were not tested in that validation run.
- **Dropouts.** A Bluetooth chest strap delivers RR intervals in notification batches. When the link drops, beats are simply lost. A timeline built as the running sum of delivered intervals then stops advancing while real time keeps going. A window cut on that timeline does not describe the last two minutes.
- **Stale numbers.** A live display that keeps its last value after the strap stops, or after a window is rejected, shows a number that is no longer being computed.

### 1.2 Interpreting α1 after the session

A single ectopic beat stays inside a 120 s rolling window for 120 s, so it can drag α1 below 0.75 for up to one window length. An "LT1 estimate" taken from the first sub-0.75 sample can therefore reflect one bad beat. Agreement between the α1 = 0.75 crossing and gas-exchange VT1 is good on average but has individual limits of agreement around ±10 bpm, and it weakens in fatigued runners [2][6][7].

### 1.3 Training load when the strap fails

Heart-rate load models (Banister TRIMP [8][9], hrTSS) need heart rate. When the strap fails partway through a workout, the recorded TRIMP can be a small fraction of the real effort; a 40-minute run can record a TRIMP of 2. That number then enters the exponentially weighted ATL/CTL averages [8][10] and pushes every later readiness and form figure down. Power-based TSS [10] avoids heart rate but needs a power meter and an FTP. Generic pace-to-load conversions without heart rate have no validated published formulation. Published platforms fall back from one load metric to another when a metric is zero or missing (§7), and intervals.icu can estimate load from average HR with a model fitted to earlier activities. None of the public material found rebuilds the load of a dropout session from the user's own history on the same route; otherwise the low number stands or the user edits the record by hand.

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
| Low-confidence constant (declared) | 0.03 (see §6) |

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

This routine differs from §3.2.2 in two ways. Its `dt` is not capped at 5 s, and it does not skip shadow samples. The 180 s rule still guarantees that a dip of 120 s or less cannot commit, but a single sample arriving after a long gap can satisfy the sustain on its own (see §6).

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

**Scale caveat.** Power TSS and hrTSS are calibrated so that 100 equals one hour at threshold. MET load is normalised to the same nominal anchor. Banister TRIMP and the route-history estimate are on the Banister TRIMP scale, which is numerically different. The ladder still places the route estimate above hrTSS (tier 2), and its value enters ATL/CTL unconverted. The application labels the source ("LOAD" or "TRIMP") but does not rescale between the two families. See §6.

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

## 4. Independent Validation

### 4.1 Scope and method

An independent check was run on 2026-10-08 against public PhysioNet recordings. Its full report is `Tools/validation/RESULTS.md`; this section reports the parts that concern this paper.

- **Code under test.** No Swift toolchain was available, so the methods were re-implemented in Python by reading the Swift source at e028039. For this paper the relevant ports are the live artifact filter of §3.1.5 (`cleanRRForDFA` and its thresholds) and the DFA core of §3.1.7.
- **Port fidelity.** A port's results were accepted as the app's only after the port reproduced the app's own unit-test expectations. Across eight test suites, 114 cases were reproduced and all 114 matched. The count includes three extra numeric checks that are not Swift tests. The relevant suites are DFAAnalysisTests (15 of 15), DFAReferenceValidationTests (9 of 9) and LiveDFAAnalyzerTests (19 of 19). The port gives the known-exponent values 0.581 / 1.088 / 1.526 exactly (§6).
- **Not ported.** The streaming analyzer object was not ported, so the beat clock, the dual gate, the status machine and the two stateful tests that exercise them are outside this check. The route estimator, the load ladder and readiness were not part of it either.
- **Data.** PhysioNet nsr2db 1.0.0 (normal sinus rhythm, 24 h ambulatory Holter) and mitdb 1.0.0 (MIT-BIH Arrhythmia Database). Beat times come from the databases' ECG beat annotations, not from a chest strap. No exercise data were used.

### 4.2 α1 under injected artifacts (nsr2db)

The design follows Rogers et al. [5]: known artifacts are inserted into clean data at fixed rates, and α1 is compared with and without correction.

- **Clean windows.** Non-overlapping 120 s windows from the nsr2db beat annotations (128 Hz, so RR is quantised to 7.8 ms). A window qualifies when every beat is annotated normal, every RR lies in 300–2000 ms, the span is at least 118 s, and the filter corrects nothing in it. Up to 20 windows were taken per record, evenly spaced: 1,080 windows from 54 records, with a mean of 153 intervals per window and a clean-window α1 of 1.20 ± 0.28.
- **Artifacts.** Inserted at 1, 3, 6 and 10 % of a window's intervals, at random non-adjacent positions, with 3 seeded repetitions (3,240 trials per cell). An *ectopic* event is a premature beat (interval −30 %) with a full compensatory pause, so it alters two intervals. A *missed beat* merges two intervals into one.
- **Conditions.** "No correction" runs DFA (boxes 4–16) on the corrupted window. "App" runs the filter and then DFA, as the live and offline analyzers do. Bias is also reported for the windows the app would publish (corrected fraction ≤ 6 %). Error is α1(condition) − α1(clean window).

| Artifact | Rate | α1 bias, no correction [95 % LoA] | α1 bias, app filter [95 % LoA] | MAE no corr. / app | Mean corrected fraction | Windows published (≤ 6 %) | α1 bias in published windows |
|---|---:|---|---|---|---:|---:|---:|
| ectopic | 1 % | −0.549 [−0.961, −0.137] | −0.005 [−0.145, +0.134] | 0.549 / 0.021 | 1.9 % | 100 % | −0.005 (n = 3238) |
| ectopic | 3 % | −0.771 [−1.198, −0.344] | −0.020 [−0.292, +0.252] | 0.771 / 0.061 | 5.9 % | 56 % | −0.051 (n = 1817) |
| ectopic | 6 % | −0.874 [−1.328, −0.421] | −0.030 [−0.397, +0.337] | 0.874 / 0.109 | 11.9 % | 0 % | n/a |
| ectopic | 10 % | −0.936 [−1.412, −0.461] | −0.067 [−0.559, +0.424] | 0.936 / 0.175 | 19.7 % | 0 % | n/a |
| missed | 1 % | −0.433 [−1.194, +0.327] | −0.008 [−0.225, +0.209] | 0.505 / 0.054 | 1.0 % | 100 % | −0.008 (n = 3239) |
| missed | 3 % | −0.590 [−1.152, −0.028] | −0.023 [−0.371, +0.324] | 0.598 / 0.097 | 3.1 % | 100 % | −0.023 (n = 3230) |
| missed | 6 % | −0.633 [−1.179, −0.086] | −0.054 [−0.527, +0.419] | 0.636 / 0.138 | 6.4 % | 12 % | −0.502 (n = 391) |
| missed | 10 % | −0.674 [−1.223, −0.125] | −0.088 [−0.675, +0.500] | 0.676 / 0.190 | 11.1 % | 0 % | n/a |

What the table shows:

- **Uncorrected artifacts lower α1.** In these resting windows, 1 % artifacts lowered α1 by 0.55 (ectopic) and 0.43 (missed). Uncorrelated jumps push the exponent toward the white-noise value of 0.5, not toward the Brownian range.
- **The filter removes most of the bias.** Bias falls to about −0.02 at rates up to 3 % and to −0.07 to −0.09 at 10 %. Precision still degrades with rate: the 95 % limits of agreement widen from about ±0.14 (1 % ectopic) to about ±0.5–0.6 (10 %).
- **The gate counts intervals, not events.** One ectopic event alters two intervals, so 3 % ectopic beats already reach about 6 % corrected. The gate withheld α1 in 44 % of those windows and in every window at 6 % or more ectopy. Missed beats up to 3 % were always published, with bias −0.02 (LoA −0.37 to +0.32).
- **Edge effect at the gate.** At 6 % missed beats, the 12 % of windows that passed the gate had a bias of −0.50. In exactly those windows the filter had touched only about 91 % as many intervals as were corrupted, so uncorrected missed beats remained. A gate on the corrected fraction cannot see artifacts the filter misses, and near the threshold it preferentially publishes under-corrected windows.

### 4.3 Corrections on artifact-free windows (nsr2db)

Of 28,001 artifact-free 120 s windows (every beat annotated normal, every RR in 300–2000 ms), the filter corrected at least one interval in 6,042 (21.6 %). In those windows the median corrected fraction was 3.6 %. 55.8 % of them exceeded 3 % and 33.9 % exceeded 6 %. The gate would therefore withhold α1 in **7.3 % of all artifact-free windows**. Where correction occurred, it moved α1 by +0.041 (95 % LoA −0.262 to +0.344). The cause is resting sinus arrhythmia that exceeds 20 % against a five-beat trailing median. During exercise, RR variability is smaller and the effect is probably smaller too; that was not tested.

### 4.4 The filter as an ectopic-beat detector (mitdb)

The filter's artifact mask was compared with the MIT-BIH beat labels. The paced records 102, 104, 107 and 217 were excluded, leaving 44 records with 100,733 annotated beats, 10,593 of them ectopic. The RR series keeps every consecutive pair of annotated beats, as a strap would deliver them. The filter ran over each whole record with its trailing-median state carried across, not per 120 s window, so the first three beats of each window are judged differently from the app.

| Scoring rule | Sensitivity | Specificity | PPV | TP | FN | FP | TN |
|---|---:|---:|---:|---:|---:|---:|---:|
| Interval (either endpoint ectopic) | 54.9 % | 86.8 % | 47.8 % | 9969 | 8203 | 10901 | 71589 |
| Beat (either adjacent interval flagged) | 71.6 % | 85.4 % | 39.9 % | 7576 | 3012 | 11432 | 66691 |

Beat-rule sensitivity by beat type: V 85.4 % (6,901 beats), a 96.0 % (150), A 51.6 % (2,544), F 24.9 % (802), J 15.7 % (83), E 11.3 % (106), S 50.0 % (2). Detection depends on prematurity, as expected of a 20 % deviation rule. The filter's specificity (86.8 % by interval) is lower than that of the overnight artifact detector run on the same data (94.9 %), because on resting recordings it also flags sinus variability.

### 4.5 Limitations of the validation

- **Rest, not exercise.** nsr2db is resting and daily-life Holter data with clean α1 about 1.2. The app uses α1 during exercise, where α1 is lower (0.5–1.0) and RR variability is smaller, so both the artifact effect and the false-correction rate may differ there. Nothing here validates live α1 during exercise or the α1–VT1 relationship.
- **Idealised artifacts.** A fixed 30 % prematurity with full compensation, and merged intervals for missed beats. Real strap errors also include extra (split) beats and noise bursts.
- **Window selection.** Requiring the filter to change nothing in a clean reference window selects lower-variability windows; 21.6 % of artifact-free windows were excluded that way.
- **Ports, not the shipped binary,** and ECG-annotated beats, not a chest strap. Bluetooth dropouts and Polar beat detection are not covered.
- **mitdb** is a selected arrhythmia population whose ectopic burden is far above a typical user's.

---

## 5. What Is New

Each statement below gives only the part that survived a prior-art search made on 2026-10-08. The search covered public source code (FatMaxxer read directly at commit 3b10aa0; GoldenCheetah), public vendor and app documentation, and the DFA α1 and training-load literature. Where a vendor page could only be seen as a search-engine extract, the reference says so. "Earliest dated form" gives the first commit in the author's private repository lineage (§8.2) that contains the rule, and, where it differs, the commit that completed the current form. All dates are author dates.

N1. Withholding a live α1 value, rather than displaying it with a reliability colour, until the rolling 120 s window holds at least 64 beats *and* its contents span at least 118 s (window length minus one maximal RR interval) as measured on the dropout-compensated beat clock of N2 rather than on elapsed session time, and showing warm-up progress as min(count/64, span/118) so that 100 % coincides with the gate passing.
Closest prior art: FatMaxxer colours α1 as "undefined" before 20 s and "unreliable" before 120 s of elapsed session time but still shows the value [21]; Watchletic computes α1 over a rolling 120 s window and requires at least 160 source beats [22].
Earliest dated form: flow-recovery 50da878, 2026-04-21 (64-beat gate, beat-only fill); current form emuqu-dev 7d6b4a6, 2026-09-03 (118 s span gate and min-of-ratios fill), measured on the N2 clock from emuqu 14ecd58, 2026-10-06.

N2. Stamping each live beat with start = max(previous beat's end, arrival time − first arrival time + first beat's start), and using that one clock both to trim the rolling window and to measure its span, together with an offline closed form (interval-sum time plus the running maximum of the wall-clock lead over the interval sum) that yields identical offsets.
Closest prior art: FatMaxxer trims its live window on arrival time, and when replaying a recorded file it rebuilds time from the RR sum, with a code comment noting that the two clocks diverge [21].
Earliest dated form: flow-recovery 95e7ae8, 2026-04-20 (window trimmed on wall-clock time); offline closed form emuqu 554540f, 2026-10-03; live beat clock emuqu 14ecd58, 2026-10-06.

N3. A live artifact filter that judges each beat against the upper median of up to five preceding *accepted* beats (rejected beats never enter the reference; at least three needed to judge; 20 % relative deviation; 300–2000 ms bounds), replaces marked beats by linear interpolation in place, returns the count of marked beats alongside the series, and withholds α1 when that count exceeds 6 % of the window.
Closest prior art: FatMaxxer drops (does not interpolate) beats more than 5 % (workout mode) or 25 % (light mode) from the immediately preceding beat, including rejected ones, and displays the dropped percentage while still showing α1 [21]; Watchletic skips windows with too many corrections [22]; AlphaHRV's documentation treats more than 5 % artifacts as affecting α1 [23]; HRV Logger reports an artifact rate [24]; Kubios uses median-referenced threshold correction [15][16].
Earliest dated form: flow-recovery 50da878, 2026-04-21 (filter rules); corrected count and 6 % refusal emuqu-dev 7d6b4a6, 2026-09-03.

N4. A five-state live α1 status (warm-up with fill fraction, ok, stalled after twice the recompute cadence of beat silence, fit failed, too many artifacts with fraction) in which the silence check runs first and every non-ok state clears the published value, so the per-second sample stream records nil instead of the last α1.
Closest prior art: FatMaxxer's elapsed-time colour states, which keep the last value on screen [21]; no public tool found clears the value on silence or rejection.
Earliest dated form: flow-recovery 50da878, 2026-04-21 (warm-up, ok, stalled, fit failed); too-many-artifacts state emuqu-dev 7d6b4a6, 2026-09-03; clearing on every non-ok state emuqu 14ecd58, 2026-10-06.

N5. Labelling a post-session α1 dip below 0.75 as an ectopic "shadow" when it recovers within one analyzer window (≤ 120 s), excluding an asymmetric span from 60 s before the dip to 120 s after recovery from α1 summary statistics and band time, and leaving unlabelled a dip still open at session end.
Closest prior art: none found in a search of public code, vendor documentation and the DFA α1 literature; public material seen states only in general terms that ectopic beats lower α1 (a Medium blog post by M. Altini, seen as a search extract only).
Earliest dated form: flow-recovery 549f747, 2026-04-23 (same 120 s limit and 60/120 s padding); shared exclusion for all summary statistics emuqu-dev 680bbee, 2026-08-25.

N6. Accepting a downward α1 threshold crossing only after α1 has stayed below the threshold for longer than the analyzer window (180 s against 120 s), counting time per sample capped at 5 s, starting only after a 120 s warm-up and only once α1 has first been seen at or above the threshold, and reporting the HR at the start of that sustained run.
Closest prior art: the HR at α1 = 0.75 as an aerobic-threshold proxy [2] (not claimed); Runalyze and AI Endurance derive a threshold HR from α1 by ramp regression or clustering (search extracts only) [26].
Earliest dated form: flow-recovery 50da878, 2026-04-21 (crossing without a sustain rule); 120 s warm-up and 180 s sustain flow-recovery 549f747, 2026-04-23; 5 s cap emuqu 554540f, 2026-10-03; armed-after-≥ 0.75 rule emuqu 5c4a23d, 2026-10-04.

N7. Within a load-source ladder, a route-history estimate tier that is promoted above every heart-rate-derived tier only when the estimate rests on at least one earlier run of the same saved route (confidence above the no-prior value 0.4) and the recorded TRIMP is below half of it, and that otherwise is used only when no other source exists.
Closest prior art: fallback ladders themselves are public: GoldenCheetah's TriScore falls back to TRIMP zonal points when the primary score is zero [25]; TrainingPeaks orders power TSS, rTSS and hrTSS, and intervals.icu sets a per-sport load priority [26].
Earliest dated form: flow-recovery b0967a8, 2026-05-12 (ladder with the route estimate last); promotion rule emuqu 554540f, 2026-10-03.

N8. Estimating the load of a workout with a failed heart-rate strap from the user's own TRIMP-per-metre on earlier runs of a user-named saved route, where the route is matched in either direction (after ≥ 500 m; start within 150 m; mean nearest-point distance ≤ 30 m from at most 300 evenly subsampled live points to a 5 m-thinned prefix of the saved route L + 200 m long), and earlier runs must end before the workout, share its sport, start within 150 m of either route end, re-match the same route over their whole track, and be neither recovered partial sessions nor themselves load-substituted dropouts.
Closest prior art: intervals.icu estimates load from average HR with a model fitted to the athlete's earlier activities, not from route history [26]; no public method found rebuilds load from same-route history.
Earliest dated form: flow-recovery fba6e27, 2026-04-26 (route matching: 500 m, ≤ 30 m, both directions); TRIMP extrapolation flow-recovery 6c127eb, 2026-04-27; estimator type flow-recovery b0967a8, 2026-05-12; prior filters emuqu 554540f, 2026-10-03; 300-point subsample and 5 m thinning emuqu 5c4a23d, 2026-10-04.

N9. Dropping earlier-run TRIMP-per-metre ratios below half their median, then choosing between no estimate (recorded ratio ≥ 0.7 × prior mean), a 60/40 prior/recorded blend, prior only, or recorded only; scaling to the recorded distance, or to the saved route distance when the recording is within ±10 % of it, missing, or possibly truncated by a crash; and attaching a confidence of min(0.85, 0.4 + 0.15·n) for n retained earlier runs, or 0.4 with none.
Closest prior art: none found in a search of public code, vendor documentation and the training-load literature.
Earliest dated form: flow-recovery 6c127eb, 2026-04-27 (ratio and min(0.85, …) confidence); 0.7 ×, 60/40 and 0.4 rules flow-recovery b0967a8, 2026-05-12; outlier drop emuqu 554540f, 2026-10-03; truncation rule emuqu 5c4a23d, 2026-10-04.

N10. Computing power TSS when a record is read, for workouts stored with normalized power but no TSS, from an FTP that is user-entered or estimated as 0.95 × the best 20-minute mean power over the last 90 days of running-family workouts, counting only 20-minute windows with at least 90 % per-second power coverage.
Closest prior art: the 0.95 × 20-minute convention [10] (not claimed); Stryd estimates critical power from about 90 days of data [26].
Earliest dated form: flow-recovery b0967a8, 2026-05-12 (0.95 × best NP; read-time power TSS); rolling 20-minute window with 90 % coverage emuqu 554540f, 2026-10-03.

N11. A training-readiness score that adds a 72 h exponentially decaying acute-fatigue term (τ = 24 h, weight 0.30, used only on days with training) to ATL inside a piecewise capacity-ratio map, switches to a strain branch below a CTL of 3.2, scales any ACWR penalty above 1.3 by min(CTL/50, 1), caps that penalty at 10 % when the morning recovery score is at least 70, adds a capped freshness bonus for ATL dissipated since morning, and blends the result asymmetrically with the recovery score (excess trust min(CTL/40, 1) × 0.55; deficit uplift 0.30).
Closest prior art: Garmin publishes the inputs of its Training Readiness score but not its formula; Polar's cardio load status compares strain with tolerance [26]; the Banister fitness–fatigue model [8].
Earliest dated form: flow-recovery-dev c48eeb9, 2026-03-01 (squashed first commit: capacity map, freshness bonus); acute fatigue and asymmetric blend flow-recovery-dev 6eddc97, 2026-03-15; CTL 3.2 branch flow-recovery c63d56c, 2026-04-23; CTL/50 ramp and rescue cap flow-recovery 6da94a6, 2026-05-01.

N12. Interpolating ATL and CTL during the day from a frozen morning snapshot toward live values by hours-since-morning/24, so that live readiness equals the frozen value at acceptance and the freshness anchor collapses once the snapshot is more than a day old.
Closest prior art: Garmin documents that Training Readiness updates through the day, without publishing how [26].
Earliest dated form: flow-recovery d69cddd, 2026-03-24; stale-anchor collapse flow-recovery 870028e, 2026-04-05.

N13. Taking RR intervals relayed by a smartwatch from a chest strap only while the phone's own strap stream has been silent for at least 5 s, still draining the relay queue while the phone is live so beats are not replayed, and at finalize interleaving the two streams by arrival time, keeping each stream's own order, before rebuilding the beat timeline as a running sum of intervals.
Closest prior art: none found in a search of public code (FatMaxxer, GoldenCheetah) and vendor documentation.
Earliest dated form: flow-recovery 7b8c540, 2026-04-30 (Watch relay without the silence gate; strap connector d381c96, 2026-04-29); merge type emuqu-dev c615ce5, 2026-09-02; 5 s gate emuqu 554540f, 2026-10-03.

N14. Re-running the live α1 filter, window, cadence and 6 % rejection offline on the gap-corrected timeline of N2 (not on the interval sum), and writing each reading back to per-second samples only while it is less than one cadence (20 s) old, clearing α1 elsewhere.
Closest prior art: FatMaxxer replays a recorded RR file through its live pipeline, rebuilding time from the RR sum [21]; intervals.icu computes DFA α1 after the ride [26].
Earliest dated form: flow-recovery 50da878, 2026-04-21 (offline re-run with the live parameters); 6 % rejection emuqu-dev 7d6b4a6, 2026-09-03; gap-corrected timeline and freshness-limited write-back emuqu 554540f, 2026-10-03.

No statement was dropped: each of N1–N14 keeps a specific rule that the search did not find in public. N1–N3 and N14 were narrowed from v1.0 because FatMaxxer and Watchletic publish the general ideas.

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

## 6. Accepted Tradeoffs and Limitations

**Validation status** (from the project's science register, scoring version v3.1.oct2026, using its exact status words):

| Register entry | Status | Scope |
|---|---|---|
| dfa-a1-exercise-threshold | supported-transfer | Live intensity band; LT1 estimate |
| dfa-artifact-rejection | validated | The 3 %/6 % correction thresholds are taken from the published bias figures [4] |
| training-load-ladder | supported-transfer | ATL, CTL, TSB |
| acwr-readiness-damper | awaiting-validation | ACWR damper and freshness bonus in readiness |

The register's "validated" status for dfa-artifact-rejection rests on the published figures. The independent check in §4 adds two qualifications. First, the app's thresholds count corrected *intervals*, and one ectopic beat alters two, so 3 % ectopic beats already reach the 6 % rejection level. Second, near 6 % the gate tends to publish windows the filter under-corrected (§4.2).

The route-history estimator, the ectopic-shadow rule, the readiness capacity map and the recovery blend have no outcome validation of their own. They are hand-set product rules. The register's allowed language for training load is "bookkeeping on training history, never a prediction of performance". For the ACWR damper it is "damper, bookkeeping", never injury risk. Nothing in this paper should be read as predicting performance or injury.

**DFA known-exponent check.** A seeded test suite (4096 samples) feeds the DFA core synthetic processes with analytic exponents of 0.5 (uncorrelated Gaussian noise), 1.0 (Voss–McCartney 1/f noise) and 1.5 (Brownian motion). Over boxes 4–16 the implementation measures **0.581 / 1.088 / 1.526**, which is biased upward at the short scale; the independent Python port reproduces these three values exactly (§4.1). The test tolerance for α1 is ±0.15. Over boxes 16–64 the α2 assertions hold to ±0.10 for white and Brownian noise and ±0.15 for pink noise. Offset and amplitude invariance hold to 1e-9. The upward short-scale bias of about 0.08 on white noise is close to the 0.50 band edge, so live values near 0.50–0.60 should be read as directional. The suite was added in commit 725da03 (2026-09-16).

**Evidence transfer.** The 0.75 crossing was established under incremental laboratory protocols. Field sessions are arbitrary, and individual agreement is about ±10 bpm, worse when fatigued [2][6][7]. In untrained adults, test–retest reliability of HR at the α1 threshold was moderate (ICC 0.52; 16 participants, two incremental cycling tests at least a week apart) [20]. The comments in the code note that agreement between a chest strap and ECG for α1 is much wider at high intensity, which is exactly where the lower bands sit. The validation in §4 used resting ECG data and does not change any of this.

**HR at the crossing.** The LT1 estimate takes HR at the *start* of the sustained run, while α1 at that moment describes the preceding 120 s window. During a ramp, HR at that instant is higher than the mean HR the window describes, so the estimate may read high. No lag correction is applied.

**Two crossing detectors.** The summary statistic (§3.2.2) caps per-sample time at 5 s and skips shadows. The crossing list and LT1 card (§3.2.3) do neither. A sample arriving after a long gap can satisfy the 180 s sustain by itself in the latter, so the LT1 card and the summary statistic can disagree on the same session.

**Offline span gate.** The offline re-analyzer has no ≥118 s span check (§3.1.9), so after long dropouts it can fit windows that live analysis would have held in warm-up.

**DFA across gaps.** Neither path inserts anything for missing beats. Beats on either side of a short dropout are adjacent in the DFA input. The beat clock fixes *which* beats are in the window, not the gap inside it.

**Filter behaviour.** The trailing median is updated only with accepted beats. An abrupt, sustained RR change of more than 20 % (for example, the first seconds of a sprint) can mark the rest of a window as artifact until the window starts after the change. That window is then rejected at 6 % rather than mis-reported. The 0.20 ratio also corrects genuine variability: on artifact-free resting windows it altered at least one interval in 21.6 % of windows and withheld α1 in 7.3 % (§4.3). Its rate during exercise is unknown, because no exercise recordings with reference beat labels were used. A diagnostic log records the corrected fraction for every window so this can be checked on device.

**Rejection gate edge effect.** The gate can only count what the filter marked. With 6 % missed beats, the few windows that passed carried a bias of −0.50, because the filter had missed some of the corruption (§4.2).

**Low-confidence constant unused.** A 3 % "low-confidence" threshold is declared alongside the 6 % rejection threshold, but at e028039 no production path reads it. Windows between 3 % and 6 % are published with no flag.

**Scale mixing in the load ladder.** Route estimates and Banister TRIMP are on a different numeric scale from TSS-family values. When tier 2 replaces hrTSS for a dropout session, ATL/CTL receive a TRIMP-scale number among TSS-scale neighbours. The app labels the source but does not convert. Some downstream constants (the low-CTL readiness branch at 3.2, Foster strain at 1600) were rescaled by the Banister 0.64 factor to fit the mixed series. That is a pragmatic choice, not a calibration.

**Route estimator scope.** The estimator needs a saved route and earlier clean runs. TRIMP-per-metre ignores pace, weather and fitness changes between runs. Matching is point-to-point, not point-to-segment, so very sparse saved routes match less tightly; the 5 m thinning bounds the added error at 2.5 m. The confidence formula is heuristic.

**MET load.** The per-sample MET lookup uses sport and speed only, not grade. Comments in the code that mention grade are out of date. The 12-MET threshold anchor is a fixed population value.

**Auto-FTP.** Only running-family workouts are used. Cycling FTP must be entered by the user.

**Readiness.** The capacity map, the low-CTL branch, the 0.30/0.35 acute weights, the freshness gain and the blend weights are hand-calibrated. The CTL/50 and CTL/40 ramps reflect the instability of ACWR at low chronic load [12]; they are not a validated dose–response.

**Sample clock.** Per-second workout samples are stamped with a moving-time counter, while the offline α1 readings use a gap-corrected beat timeline. The moving-time counter stops during a pause, but beats keep arriving and stay on the gap-corrected timeline, and the write-back step matches readings to samples by offset without consulting the recorded pause spans. After a pause of P seconds, every later sample therefore receives the α1 reading from P seconds before the moment it was taken. Sessions without pauses are unaffected. Live α1 is not affected; only the post-workout re-analysis is.

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
