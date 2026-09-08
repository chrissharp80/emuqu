# Training Load — end-to-end calculation

Canonical reference for how Emuqu turns workouts into ATL / CTL / TSB
and the Load & Trajectory verdicts. Every step cites the source so the math is
verifiable. Last verified against source: 2026-08-16.

> **Training load does NOT feed the Recovery Score.** Since 2026-05-02 the
> recovery score is HRV + Sleep + Vitals only (`Constants.swift`,
> `ScoringWeights`). Training load lives on the parallel **Load & Trajectory**
> surface and is read by the AI coach. See "Where it does and doesn't go".

---

## The chain at a glance

```
workout ─▶ per-workout load (effectiveLoad)
              powerTSS ▸ hrTSS ▸ METs ▸ luciaTRIMP ▸ extrapolatedTRIMP
              └ else HR-only Banister TRIMP
        ─▶ daily bucket  (sum effectiveLoad per local calendar day, rest days = 0)
        ─▶ Banister EWMA over a 180-day window, seeded from 0
              ATL = 7-day  EWMA of daily load   (τ = 7 d)   "fatigue"
              CTL = 42-day EWMA of daily load   (τ = 42 d)  "fitness"
              TSB = CTL − ATL                                "form"
        ─▶ today: continuous-time exponential projection (decays intra-day)
        ─▶ interpretation: FormDescriptor, RampBand, TrajectoryVerdict
```

---

## Layer 0 — Per-workout load (the stress score of a single session)

`WorkoutSummary.effectiveLoad(restingHR:maxHR:)` — `HealthKitManager+Store.swift`

```swift
func effectiveLoad(restingHR: Double = 60, maxHR: Double? = nil) -> Double {
    if let pre = precomputedLoad, pre > 0 { return pre }   // best available source
    return calculateTrimp(restingHR: restingHR, maxHR: maxHR)  // HR-only fallback
}
```

### 0a. `precomputedLoad` — the preferred-source ladder

For sessions Emuqu recorded itself (read from `SessionArchive` via
`WorkoutSummary.fromAppArchive`, `HealthKitManager+Store.swift`), the load comes
from `WorkoutMetadata.preferredTrainingLoad` (`WorkoutMetadata.swift:620`), an
accuracy-ordered ladder. First non-nil positive value wins:

| Priority | Source (`TrainingLoadSource`) | Formula | Notes |
|---|---|---|---|
| 1 | `power` | `TSS = IF² × durationHours × 100`, `IF = NP/FTP` | Coggan. `computedPowerTSS` (`WorkoutMetadata.swift:588`) derives it at read-time from stored NP + current effective FTP, so historical sessions light up once FTP auto-estimate runs. |
| 2 | `hr` | HR-based TSS (HRSS, needs HR + LTHR) | `hrTSS` |
| 3 | `mets` | `metHours / 12 × 100`, `metHours = Σ METs·dt` | `computedMETLoad` (`WorkoutMetadata.swift:471`). Per-sample pace+grade integration, or a single distance/duration/sport bucket when samples are sparse. 12 METs = threshold anchor. |
| 4 | `banister` | HR-only Banister TRIMP | `luciaTRIMP`, legacy sessions pre-LTHR |
| 5 | `routeHistory` | Route-history extrapolation | `extrapolatedTRIMP`, for HR-dropout sessions |

All of powerTSS / hrTSS / METs are calibrated so **100 = one hour at
threshold**, which is what lets the ladder fall through them into one series.

Sharing a scale is a calibration convention, but in this case there is also
evidence behind the substitution — more than the previous wording claimed and
more than the first correction of it allowed. TSS is explicitly modelled on
Banister's TRIMP, and studies comparing load metrics against changes in aerobic
fitness put iTRIMP and TSS at the top of the range together (r ≈ .75–.81). They
are measuring the same construct.

What the literature also says is that they are not equally good at it. The
accuracy order is power-derived, then HR-derived, then time/MET estimates:
power is a direct mechanical measurement, HR tracks effort well in steady state
and less well outside it, and a MET bucket is an estimate of an estimate. That
is exactly the order this ladder tries them in.

So: substitutable enough to form one series, with real evidence behind the
construct, and noisier the further down the ladder a session was resolved. A
load history assembled from mixed sources is approximate, and the approximation
is quantified above rather than asserted either way. (2026-09-02: the doc said
"directly substitutable", which skipped the hierarchy; the first correction
said they were not substitutable at all, which skipped the evidence.)

HealthKit-sourced workouts
(from other apps) carry no `precomputedLoad` and fall to Layer 0b.

### 0b. HR-only Banister TRIMP (the fallback)

`WorkoutSummary.calculateTrimp(restingHR:maxHR:)` — `HealthKitManager+Store.swift`

```
HRR   = clamp( (avgHR − restingHR) / (maxHR − restingHR), 0, 1 )
TRIMP = durationMinutes × HRR × coefficient × e^(k × HRR)
        male:   coefficient 0.64, k 1.92
        female: coefficient 0.86, k 1.67     (biologicalSex == .female)
```

- Constants: the `b` exponents `TrainingConstants.TRIMP.maleWeighting = 1.92`,
  `femaleWeighting = 1.67` (`Constants.swift:486`). The `A` coefficients 0.64 /
  0.86 are also centralized as `TrainingConstants.TRIMP.maleScale = 0.64`,
  `femaleScale = 0.86` (`Constants.swift:494`, 2026-08-07 — no longer inline, so
  the summary-level `calculateTrimp` and the per-beat `WorkoutAnalyzer.banisterTRIMP`
  read one source).
- **No average HR → returns 0**, not a fabricated value (`HealthKitManager+Store.swift`,
  2026-06-30). Strava/manual imports with no HR contribute zero rather than
  inflating load.
- `restingHR` = Apple's HealthKit resting HR when available
  (`fetchAppleRestingHR`, `TrainingHealthQueries+Queries.swift:402`), else the
  setting. `maxHR` = passed value, else `settings.effectiveMaxHR`. **maxHR must
  be the physiological max, not the workout's peak** — using the peak inverts
  the HR-reserve scoring.

---

## Layer 1 — Daily bucket

`buildDailyTrimp` (`TrainingHealthQueries+Queries.swift:542`) — and the mirror
`TrainingMetricsCache.buildDailySeries` (`TrainingMetricsCache.swift:437`):

1. Pre-seed **every** day in the window with `0` so rest days correctly decay
   the EWMA (a missing key would silently skip the day and hold CTL high).
2. Workout set = HealthKit workouts **+** app `SessionArchive` workouts,
   deduplicated (`deduplicateWorkouts`, `TrainingHealthQueries+Queries.swift:77`):
   start times within 5 min AND (same type OR ≥60% time overlap); ties broken by
   data richness with `precomputedLoad` scored highest so the power-carrying
   archive copy wins.
3. Workouts under 1 minute are dropped as ghosts (`TrainingHealthQueries+Queries.swift:226`).
4. `dailyTrimp[startOfDay(workout.date)] += workout.effectiveLoad(effectiveRHR, userMaxHR)`.

Both builders use `effectiveLoad` (2026-07-02 alignment fix,
`TrainingMetricsCache.swift:516`) so the dashboard/PDF path and the trajectory
path can't diverge on power-backed sessions.

---

## Layer 2 — Banister EWMA → ATL / CTL / TSB

`computeEWMA` (`TrainingHealthQueries+Queries.swift:617`) and the `buildDailySeries`
loop (`TrainingMetricsCache.swift:547`):

```
atlDecay = e^(−1/7),  ctlDecay = e^(−1/42)      (exact EWMA smoothing)
for each day in window (chronological):
    atl = dayTrimp·(1 − atlDecay) + atl·atlDecay
    ctl = dayTrimp·(1 − ctlDecay) + ctl·ctlDecay
TSB = CTL − ATL
ACWR = ATL / CTL     (only when CTL > 0; TrainingMetrics.acuteChronicRatio)
```

- **Exact exponential decay** `e^(−1/τ)` (2026-08-01), not the `1/τ` linear
  approximation. The today-weight is `1 − e^(−1/7) = 0.1331`, not `1/7 = 0.1429`
  (~7% off on ATL). This is the rigorous EWMA / Banister–Busso impulse-response
  form used by WKO5 / GoldenCheetah / intervals.icu. (TrainingPeaks' own
  simplified published formula uses the `1/τ` linear step; the code follows the
  exact form for cross-tool agreement.) The Layer 2.5 continuous projection below
  deliberately uses `1/τ` because it is a *different* model (continuous-time
  `dX/dt = −X/τ`), not the discrete EWMA.

- **Window = 180 days** (`ewmaLookbackDays`, `TrainingHealthQueries+Queries.swift:609`).
  180 ≈ 4.3× the 42-day CTL constant, so a **zero seed** contributes <2% to
  today's CTL — no "seed from average" hack (that biased CTL toward the older,
  lower-volume tail).
- `computeEWMA` iterates days **strictly before today** (through yesterday).
- **Morning readings** (`forMorningReading: true`) stop at yesterday — a morning
  score reflects overnight recovery, not today's not-yet-done training.
- **Live view** (`forMorningReading: false`) applies today as one additional
  discrete EWMA step (`TrainingHealthQueries+Queries.swift:504`).
- EWMA window constants also mirrored at `Constants.swift` `TrainingConstants.EWMA`
  (`acuteDays 7`, `chronicDays 42`).

---

## Layer 2.5 — Continuous-time projection (today on Load & Trajectory)

`TrainingMetricsCache.continuousProjection(at:)` — `TrainingMetricsCache.swift:580`.
The discrete daily bucket is constant for the whole day; this makes "today"
evolve smoothly so 3 h after a walk differs from 24 h after it:

```
anchor on yesterday's cooked bucket (atl, ctl)
elapsedDays = (now − startOfToday) / 86400
atl = anchorATL · e^(−elapsedDays/7)
ctl = anchorCTL · e^(−elapsedDays/42)
for each of today's workouts (dt = now − workout.start):
    atl += trimp · (1/7)  · e^(−dt/7 days)
    ctl += trimp · (1/42) · e^(−dt/42 days)
TSB = ctl − atl
```

`LoadTrajectoryLoader.makeSamples` (`LoadTrajectoryLoader.swift:170`) overrides
**only today's** bucket with this projection; historical days keep the discrete
daily EWMA.

---

## Layer 3 — Interpretation (Load & Trajectory surface)

All in `TrajectoryVerdict.swift`. None of these feed the recovery score; none use
"danger"/red language.

**FormDescriptor(tsb)** — `TrajectoryVerdict.swift:196`
`> +10` Fresh · `−5…+10` Held · `−15…−5` Working · `−25…−15` Tired · `< −25` Very tired.

**Ramp rate** — `LoadTrajectoryLoader.computeRampRate` (`LoadTrajectoryLoader.swift`):
ordinary-least-squares slope of the **discrete daily CTL** over the trailing
`rampTrendWindowDays` (14), ×7 → **CTL points per week**.

**RampBand(rampRate)** — `TrajectoryVerdict.swift:242` (sign-aware):
`< −1.5` Easing down · `−1.5…1.5` Holding steady · `1.5…3` Conservative · `3…8` Standard · `> 8` Rapid increase.
(−1.5 deadband kept in lockstep with the verdict's detraining threshold.)

**TrajectoryVerdict.compute** — `TrajectoryVerdict.swift:133`, in order:
1. Mode toggles win: `comeback` → `overreach` → `peaking`.
2. Need `> 7` days of data + a week-ago CTL, else `buildingBaseline`.
3. `delta = rampRate` (falls back to `currentCTL − ctlOneWeekAgo` only if rampRate == 0).
4. **Deep fatigue overrides direction:** `TSB < −15` → `highStrain` (precedes the building gate, 2026-07-01).
5. `delta > 1.5` → `rapidIncrease` if rampRate > 8 else `building`.
6. `delta < −1.5` (deadband; `−1` in legacy) → `detraining`, unless `TSB < −5` (grinding through work) → `maintaining`.
7. else `maintaining`.

**Peaking heuristic** (when enabled) — `LoadTrajectoryLoader.peakingHeuristic`:
ATL < CTL by >10% sustained 4+ days.

**Foster monotony/strain** — `computeMonotony` = mean/SD of last-7-day TRIMP;
thresholds in `Constants.swift` `TrainingConstants.Training` (monotony 2.0;
strain severe 2560 / moderate 1600, recalibrated ×0.64 for the TRIMP scale).

---

## The store / source-of-truth

`TrainingMetricsCache` (`TrainingMetricsCache.swift`, `@MainActor` singleton) is
the one place both the dashboard and the AI read from, so they can't disagree:

- `current: TrainingMetrics` — today's ATL/CTL/TSB snapshot (dashboard hero, AI
  `dashboardLoadSnapshot`).
- `dailySeries: [Date: DaySample]` — the ~400-day day-by-day series (Load &
  Trajectory chart, AI history queries).
- `refresh()` fetches the 180-day HealthKit window once, folds in the archive,
  recomputes, and rebuilds the series; fast-exits when <5 min stale.
- Invalidated on any `.flowRecoveryArchiveChanged` (every workout write /
  reanalysis / merge) so the next read is fresh.
- The AI reaches these via `TrainingLoadRegistry` and the `training.load.*` tools.

---

## Where it does and doesn't go

- **Recovery Score:** NOT included. Removed 2026-05-02 (ACWR removal). The score
  is HRV 0.60 / Sleep 0.25 / Vitals 0.15 (`ScoringWeights.Tier3`). Rationale in
  the `Constants.swift` comment above `enum ScoringWeights`: training load
  already manifests downstream as suppressed HRV / elevated RHR, so scoring it
  separately double-counts the same physiological event (Impellizzeri 2020,
  Altini 2025).
- **Load & Trajectory surface:** the primary consumer (chart, verdict, form,
  ramp).
- **AI coach:** reads ATL/CTL/TSB and history via `TrainingMetricsCache` /
  `TrainingLoadRegistry`.
- **Reports:** the PDF/holistic reports read `cache.current` (same numbers).
