# Emuqu — Complete Data Flow Reference

## 1. Data Model

### RRPoint
```
t_ms:        Int64   — cumulative ms from session start (sum of all prior rr_ms)
rr_ms:       Int     — this beat's RR interval duration (ms)
wallClockMs: Int64?  — absolute wall-clock offset from session start (streaming only, nil for device recording)
hr:          Int?    — sensor-reported HR (streaming only)
endMs:       Int64   — computed: t_ms + rr_ms
```

**KEY**: `t_ms` is NOT wall time. It's the running sum of RR intervals. If beats are
dropped (BLE disconnect), `t_ms` keeps counting from where it left off — no gap in
t_ms even though wall time advanced. `wallClockMs` tracks the real elapsed time and
IS gap-aware.

### RRSeries
```
points:    [RRPoint]  — the RR data
sessionId: UUID
startDate: Date       — absolute wall-clock start of the session/segment
```

`startDate + t_ms/1000` gives the absolute time for a point (cumulative-based).
`startDate + wallClockMs/1000` gives the wall-clock-accurate time (gap-aware).

### HRVSession
```
id, startDate, endDate, state (.collecting/.analyzing/.complete/.paused/.failed)
sessionType: .overnight / .nap / .quick / .breathe / .workout
rrSeries:         RRSeries?        — the final merged/processed RR data
analysisResult:   HRVAnalysisResult? — window selection + HRV metrics + readiness
sleepStartMs:     Int64?           — HealthKit sleep start relative to startDate
sleepEndMs:       Int64?           — HealthKit sleep end relative to startDate
sleepSegments:    [SleepSegmentMs]? — multiple segments for split nights
linkedSessionIds: [UUID]?          — parent/child links (pause/resume + same-night)
pausedDate:       Date?
dataSourceSummary: DataSourceSummary?
sleepSnapshot:    SleepData?         — frozen at acceptance (prevents HealthKit drift)
vitalsSnapshot:   RecoveryVitals?    — frozen at acceptance
recoveryScore:    Double?            — composite readiness (0–10 scale)
```

### SessionArchiveEntry (in-memory index)
```
sessionId:        UUID
date:             Date               — session start
endDate:          Date?              — session end
fileHash:         String             — SHA256 integrity check
filePath:         String             — relative to archive directory
recoveryScore:    Double?
meanRMSSD:        Double?
meanHR:           Double?            — backfilled by migrateMetrics()
stressIndex:      Double?            — backfilled by migrateMetrics()
meanSDNN:         Double?
tags:             [ReadingTag]
notes:            String?
sessionType:      SessionType
linkedSessionIds: [UUID]?
```

Enables trend computation and filtering without loading full sessions from disk.
`retrieveLightweight()` skips rrSeries (~45x less JSON) — used for dashboard, history, paused session search.

---

## 2. Recording Phase

### Start: `startOvernightStreaming()`
```
User taps Record
  → Creates HRVSession(sessionType: .overnight)
  → session.startDate = Date()  [wall clock NOW]
  → Starts BLE streaming via PolarManager
  → streamingCumulativeMs = 0
  → Timer ticks every 1s for elapsed clock + incremental backup
```

### Streaming data arrives: PolarManager (`PolarManager+Streaming.swift`, the streaming RR observer)
```
For each RR sample from Polar SDK:
  wallClockNow = time since stream start (ms)
  point = RRPoint(
      t_ms:        streamingCumulativeMs,      ← running sum
      rr_ms:       rrInterval,
      wallClockMs: wallClockNow,               ← actual elapsed
      hr:          sensorHR
  )
  _streamedRRPoints.append(point)
  streamingCumulativeMs += rrInterval
```

**At this stage**: All points have t_ms starting from 0, incrementing by rr_ms.

---

## 3. Pause/Resume Flow

### Pause: `pauseOvernightStreaming()`
```
User taps Pause
  → gatherOvernightData()           ← stops streaming, gets points
  → mergeParentSessionData(data)    ← merges parent if this is a resumed child
  → processOvernightData(merged)    ← full analysis pipeline
  → session.state = .paused
  → session.pausedDate = Date()
  → Archives paused session
  → Persists paused session ID to UserDefaults
```

### Resume: `resumeOvernightStreaming(linkedSessionId:)`
```
User taps Resume
  → Creates NEW HRVSession
  → newSession.linkedSessionIds = [parentId]
  → Updates parent session in archive: parent.linkedSessionIds.append(childId)
  → Starts fresh streaming (streamingCumulativeMs resets to 0!)
  → collectedPoints = []
  → pausedBeatCount = parent's beat count (for UI display only)
```

**KEY**: The child session starts with t_ms=0 again. Its startDate is the resume
wall-clock time. The parent's data is in the archive with its own t_ms timeline.

### Finalize: `finalizeFromPause()`
```
User taps Done (without resuming)
  → session.state = .complete
  → Re-archives
  → needsAcceptance = true
```

---

## 4. Stop/Morning Processing

### Stop: `stopOvernightStreaming()`
```
User taps Stop (or morning auto-stop)
  → stopStreamingInfrastructure(), back up the streamed beats
  → If streaming >= 120 beats (any beats on a resumed child):
      → downloadMergeAndScoreNight(): strap recording + HealthKit sleep
        fetched concurrently (no strap fetch for Verity Sense),
        selectBestDataSource(), then analyzeAndFinalizeOvernight():
        mergeParentSessionData() → processOvernightData()
  → Otherwise: fallbackToDeviceFetch() — the strap recording is primary;
      the session fails if the fetch is barred or returns < 120 beats
```

### gatherOvernightData() (pause path, `RRCollector+PauseResume.swift`)
```
Stops streaming timer, background audio
Captures streamingPoints from PolarManager.stopStreaming()
Backs up raw data to disk
Optionally fetches H10 internal recording
Chooses best data source: streaming vs internal vs composite
Returns OvernightDataResult {
    points:        [RRPoint]     ← the selected RR data (t_ms from 0)
    baseSession:   HRVSession    ← the current session
    streamingBeats, deviceBeats, dataSource, reconnectCount
}
```

### mergeParentSessionData()
```
Called when this session is a resumed child (linkedSessionIds has parent)

IF baseSession.linkedSessionIds has a parentId
  AND parent exists in archive with RR data:

  OFFSET child points:
    offsetMs = child.startDate - parent.startDate (in ms)
    each child point.t_ms += offsetMs
    each child point.wallClockMs += offsetMs

  mergedPoints = parent.points + offsetChildPoints
  mergedBaseSession.startDate = parent.startDate  ← earliest

RETURN (mergedPoints, mergedBaseSession)
```

**THIS IS WHERE SEGMENTS GET COMBINED FOR PAUSE/RESUME.**
The child's t_ms values are shifted forward by the wall-clock gap between
parent start and child start, so the timeline is:
```
parent data (t_ms 0 → X) ... gap ... child data (t_ms X+gap → end)
```

---

## 5. processOvernightData() — The Main Pipeline
**(RRCollector+MorningProcessing.swift)**

**Note:** processOvernightData is now a thin wrapper in RRCollector+MorningProcessing.swift
that delegates to MorningProcessingService.swift.

```
INPUT: points, baseSession, dataSource, ...

STEP 1: Backup raw data
  rawBackup.backup(points)

STEP 2: Build initial RRSeries
  series = RRSeries(points, sessionId, baseSession.startDate)

STEP 3: Same-night merge (for SEPARATE sessions, NOT pause/resume)
  IF sessionType == .overnight:
    Find all archived .overnight sessions from the same biological night
    (using sleepSchedule.overnightWindowStart)
    SKIP sessions already in linkedSessionIds (already merged via pause/resume)

    IF found same-night sessions:
      allSegments = [(baseSession.startDate, points)] + archived segments
      Sort by startDate
      effectiveStartDate = earliest startDate

      For each segment:
        offsetMs = segment.startDate - effectiveStartDate
        offset all t_ms and wallClockMs by offsetMs

      series = RRSeries(mergedPoints, effectiveStartDate)
      sameNightLinks = [archived session IDs]

STEP 4: Detect artifacts
  flags = artifactDetector.detectArtifacts(series)

STEP 5: Verify data quality
  verification.verify(series, flags)

STEP 6: Get sleep boundaries and classify sleep stages
  sleepData = healthKit.fetchSleepData(for: effectiveStartDate)
  sleepStartMs = sleepStart relative to effectiveStartDate (ms)
  wakeTimeMs = sleepEnd relative to effectiveStartDate (ms)
  sleepSegments = multiple segments if split night

  fetchSleepData internally goes cache-first:
    1. SleepDataCache.read(coveringRecordingStart:) — persistent UserDefaults
       cache keyed by sleep-night startOfDay (14-entry max, count-pruned;
       ±1-day read tolerance). The HK sleep observer
       (HealthKitManager+SleepTrends.startObservingSleepData) warms this cache as
       Apple Watch syncs new samples overnight, so on most mornings morning
       processing gets a cache hit and skips the poll. On a cache miss it
       falls back to a bounded poll loop (MorningProcessingService
       .pollForSleepData — 15 × 2s = 30s). If the phone is still locked,
       HealthKit returns errorDatabaseInaccessible; the loop bails early, the
       score is computed sleepless, and the observer's sleepDataVersion bump
       triggers an auto-rescore once the Watch data lands and the phone is
       unlocked (see §13.2).
    2. On cache miss, queries HealthKit via querySleepSamples + the
       SleepMergingPipeline, and writes the result back to the cache.
    3. Bypasses cache when `rrPoints` or `autoSleepExtension` are supplied
       (those callers want HR-validated boundaries against the freshest
       HK samples).

  Sleep stage classification (HRVSleepStageClassifier / SleepMergingPipeline):
    Path 1 — No Apple Watch: Full HRV classification from RR data alone
      → Generates complete sleep stages (deep, REM, core, awake)
    Path 2 — Apple Watch + HRV-Enhanced Stages enabled:
      → Augments Watch stages with chest-strap RR features
      → Catches deep sleep misclassified as core, REM twitches as awake, etc.
    Path 3 — Apple Watch, no augmentation: HealthKit stages used as-is

STEP 7: Fetch training load (HealthKit workouts → TRIMP → ATL/CTL/TSB)
  fetchTrainingLoadIfEnabled()

STEP 8: Select recovery window + peak capacity
  windowResult = windowSelector.findBestWindowWithCapacity(
    series, flags, sleepStartMs, wakeTimeMs,
    baselineStats: baselineStats   ← enables Tier 1 ranking
  )
  → Searches for best 5-min window of sustained low-HR, high-HRV
  → When baselineStats provided: organized windows are ranked by
    Tier 1 recovery score (ln(RMSSD) z + DFA α1 + RHR) instead of
    raw RMSSD, so the picked window matches what the dashboard shows.
  → sleepStartMs/wakeTimeMs arrive as wall-clock offsets; resolveSleepBoundaries
    translates them onto the recording's cumulative-RR (t_ms) timeline via each
    beat's wallClockMs (tMsOffset), so overnight BLE dropouts don't drift the
    30-70% search band. Identity no-op on gapless H10 internal recordings.
  → Also finds peak capacity window
  → Captures `organizedRecoveryZones: [TimeRange]` — all regions where
    DFA α1 ∈ [0.75, 1.0] AND (LF/HF ≤ 1.5 OR HR CV < 8%). Attached to
    analysisResult for the overnight chart's green-zone overlay.

STEP 9: Run HRV analysis on selected window
  analysisResult = analyze(session, window, flags, peakCapacity)
  → TimeDomain (RMSSD, SDNN, pNN50, etc.)
  → FrequencyDomain (LF, HF, VLF)
  → Nonlinear (SD1, SD2, DFA α1)
  → ANS metrics (stress index, readiness score, respiration rate)

STEP 10: Build final session
  finalSession = HRVSession(
    startDate: effectiveStartDate,
    rrSeries: series,              ← the MERGED series
    analysisResult: analysisResult,
    sleepStartMs, sleepEndMs, sleepSegments,
    linkedSessionIds: baseSession.linkedSessionIds + sameNightLinks
  )

STEP 11: Compute recovery score
  recoveryScore = computeRecoveryScore(session, analysisResult)
  → Uses RecoveryScoreCalculator (architecture v3.oct2026)
  → Tier 1: HRV-only (ln(RMSSD) z-score, SWC band model)
  → Tier 2: HRV + Sleep (sleep present, vitals absent)
  → Tier 3: HRV + Sleep + Vitals (full-signal day, 60/25/15)
  → Comeback mode (21-day toggle): Tier 3 weights HRV 80% / Sleep 20% / Vitals 0%;
    Tier 2 keeps its weights; SpO₂ penalty still applies
  Training load is NOT in the score (lives on Surface 2 / Load & Trajectory page)
  per Impellizzeri 2020/2021, Doherty/Altini 2025.

STEP 12: Supersede same-night sessions
  supersedeSameNightSession(newSession)
  → Marks older same-night sessions as linked

STEP 13: Archive
  archive.archive(finalSession)

OUTPUT: finalSession with all analysis
```

---

## 6. Recovery Score Calculation (architecture v3.oct2026)

### RecoveryScoreCalculator (RecoveryScoreCalculator.swift)

**Architecture (May 2026):** the score is HRV + Sleep + Vitals. Training
load is NOT in the composite — it lives on the parallel Load & Trajectory
surface for planning context. Per Impellizzeri 2020/2021 the ACWR ratio's
chronic denominator carries little real signal (random numbers in the
chronic position produce nearly identical odds ratios for injury). Per
Doherty/Altini 2025 systematic review and Altini's HRV4Training
methodology, training load already manifests downstream as suppressed
HRV / elevated RHR / altered respiratory rate — counting it again as a
score factor double-counts the same physiological event.

```
Tier 1 — HRV Only (cold start / no sleep / no vitals):
  ln(RMSSD) → z-score against personal baseline → SWC band model
    z=-3 → 5, z=-1.5 → 25, z=-0.75 → 64, z=-0.5…+0.5 → 72 (flat), z=+1.5 → 90
  + DFA α1 adjustment (parasympathetic organization)
  + Resting HR adjustment
  + 7-day ln(RMSSD) CV adjustment (deductions only)
  + ANS-balance adjustment (sympathetic penalty, small parasympathetic bonus)
  − staleness penalty (old baseline)
  Weight: 100% (HRV IS the composite when no other data exists)
  NOTE: This same scoring is used by the window ranker (WindowSelection.swift)
  to rank candidate organized windows.

Tier 2 — HRV + Sleep (sleep present, vitals absent):
  Sleep duration 35%, efficiency 25%, deep 25%, REM 15%
  Double-penalty dampening: when both HRV and sleep are poor
    (z < -1.0 AND sleep < 50), weights shift to HRV 85% / Sleep 15%
  Weight: HRV 70%, Sleep 30%

Tier 3 — HRV + Sleep + Vitals (full-signal day):
  Vitals sub-score = average of available sub-inputs:
    RHR    → z-score against personal baseline; -10/SD penalty above; floor 0
    RR     → deviation from 7-day baseline; -15/br/min above ±1 band; floor 0
           → if no baseline, population-norm fallback (12–18 br/min → 100;
             above 18 graded penalty; below 12 flat 90). See Constants.swift
             RecoveryScoreConstants.respiratoryRate* family.
    Temp   → +dev only (a cooler reading is never penalised):
             ≤ 0.3°C → 100  |  ≤0.5 → 75  |  ≤1.0 → 50  |  >1.0 → 25
  Missing vitals inputs are dropped (not penalised). All-nil → falls back to Tier 2.
  Weight: HRV 60%, Sleep 25%, Vitals 15%

  Baseline persistence:
  - `RespiratoryBaselineCache` (Storage/) — UserDefaults-backed last-known
    7-day RR baseline. `HealthKitManager.fetchRespiratoryRateBaseline` writes
    on every successful HK query and reads from cache when HK is unreachable
    (locked phone at 6 AM returns `errorDatabaseInaccessible`). 30-day TTL.
  - `WristTemperatureBaselineCache` (Storage/) — same pattern for the
    7-day wrist-temperature deviation baseline.
  Without these caches, morning processing on a still-locked phone froze
  the score with "RR — no data" even when the rate itself was present —
  the population-norm fallback above is the third tier of safety after
  HK live + cache hit.

Comeback mode (21-day toggle, Settings → Modes):
  Weight: HRV 80%, Sleep 20%, Vitals 0%
  (RR/RHR/temp can stay elevated for weeks post-illness; Comeback prevents
   that slow-recovering signal from dragging the score down while HRV catches up)

+ SpO2 post-composite penalty (-10 if <95%; flag-only signal)
```

### Training Load (Load & Trajectory surface — does NOT feed the recovery score)
```
HealthKit workouts → Banister TRIMP per workout (sex-dependent)
TRIMP → EWMA → ATL (7-day), CTL (42-day), TSB (CTL - ATL)
ACWR (ATL/CTL) shown as descriptive load-range indicator
  (Below your usual / In range / Above your usual / Sharp increase)
Foster Monotony / Strain → banner on TrainingDetailView when monotony >2.0
  AND strain >200 (observational only, not a score component)
Stored as TrainingContext in analysisResult.trainingContext (frozen snapshot)
Live values come from TrainingMetricsCache, surfaced on the Training Detail page.
```

---

## 7. Chart Display

### OvernightChartsView

```
INPUT: HRVSession (with rrSeries, analysisResult)

computeOvernightStats():
  points = session.rrSeries.points
  flags = session.artifactFlags

  1. Resolve sleep boundaries (HealthKit or stored)
  2. Compute HR values:
     - Sleep-bounded: computeHRValues(rangeStart: sleepStart, rangeEnd: sleepEnd)
     - Full recording: computeHRValues(rangeStart: nil, rangeEnd: nil) → allHrValues
  3. Compute rolling RMSSD (5-min windows, step 30 beats)
  4. Find peak HRV in 30-70% sleep band
  5. Derive sleep duration

CHART RENDERING (Canvas):
  X-axis: TIME-BASED using t_ms
    firstMs = points.first.t_ms
    lastMs  = points.last.endMs
    totalDurationMs = lastMs - firstMs
    For each data point:
      x = (point.t_ms - firstMs) / totalDurationMs * chartWidth

  Y-axis: HR or RMSSD value

  GAP DETECTION:
    If gap between consecutive plot points > 300,000ms (5 min):
      Start a new line segment (break the line)
      → This creates the visual gap between segments

  X-axis LABELS:
    Uses series.startDate and series.actualEndDate
    Evenly spaced wall-clock labels across the chart

  ANALYSIS WINDOW overlay:
    Uses windowStartMs/windowEndMs (time-based positioning)

  ORGANIZED-RECOVERY ZONES overlay (green tint):
    Uses analysisResult.organizedRecoveryZones (TimeRange array).
    When the field is nil (e.g. sessions archived before zones
    were persisted), the chart falls back to
    computeOrganizedZonesOnDemand(), which re-runs the zone scan
    from the rrSeries without rewriting the archive.
```

### Key chart rendering detail:
```
The chart positions data points using t_ms relative to firstMs.
If two segments have properly offset t_ms values:

  Segment 1: t_ms 0 → 14,400,000 (4 hours)
  Gap:       no data points
  Segment 2: t_ms 21,600,000 → 32,400,000 (3 hours after 2hr gap)

  Chart width maps 0 → 32,400,000
  Segment 1 occupies left ~44%
  Gap occupies middle ~22% (no line drawn, gap > 5min threshold)
  Segment 2 occupies right ~33%

If child t_ms is NOT offset (the bug):

  Segment 1: t_ms 0 → 14,400,000
  Segment 2: t_ms 0 → 10,800,000    ← OVERLAPS segment 1!

  Chart width maps 0 → 14,400,000 (max of both)
  Both segments overlap in the same x-space
  Second segment's points draw ON TOP of first segment's
  Visually looks like only one segment
```

---

## 8. Where Segments Get Combined (Summary)

There are TWO merge paths:

### Path A: Pause/Resume (mergeParentSessionData)
```
Trigger: Session was paused, then resumed → child has linkedSessionIds with parent
When:    Called in stopOvernightStreaming/pauseOvernightStreaming BEFORE processOvernightData
What:    parent.points + offset(child.points)
```

### Path B: Same-Night Separate Sessions (processOvernightData)
```
Trigger: Multiple independent overnight sessions on the same biological night
When:    Inside processOvernightData, after series is built
What:    All same-night segments sorted by startDate, each offset from earliest start
Skip:    Sessions already in linkedSessionIds (already merged by Path A)
```

### The interaction:
```
If session was pause/resumed:
  1. mergeParentSessionData runs first → merges parent + child with offset
  2. processOvernightData receives the merged points
  3. Same-night merge SKIPS the parent (it's in linkedSessionIds)
  4. Same-night merge may still find OTHER independent sessions from same night
```

---

## 9. Full Session Lifecycle

```
START RECORDING
  └→ Creates HRVSession, starts streaming
  └→ Points accumulate: t_ms from 0, wallClockMs from 0

[Option A: Continuous recording]
  STOP
    └→ gatherOvernightData()           → raw points
    └→ mergeParentSessionData()        → no-op (no parent)
    └→ processOvernightData()          → single segment, analyze, archive

[Option B: Pause/Resume]
  PAUSE
    └→ gatherOvernightData()           → segment 1 points
    └→ mergeParentSessionData()        → no-op (no parent yet)
    └→ processOvernightData()          → analyze segment 1
    └→ Archive as .paused

  RESUME
    └→ Creates NEW session with linkedSessionIds=[parentId]
    └→ Starts fresh streaming (t_ms from 0 again)

  STOP (or PAUSE again)
    └→ gatherOvernightData()           → segment 2 points (t_ms from 0)
    └→ mergeParentSessionData()        → loads parent from archive
        └→ offsetMs = child.startDate - parent.startDate
        └→ child points shifted by offsetMs
        └→ merged = parent.points + shifted_child.points
        └→ mergedBaseSession.startDate = parent.startDate
    └→ processOvernightData(merged)    → analyzes combined data
        └→ Same-night merge skips parent (in linkedSessionIds)
        └→ Window selector searches across both segments
        └→ Archives final session

[Option C: Independent same-night sessions]
  SESSION 1: Record 11PM-3AM → analyzed, archived
  SESSION 2: Record 5AM-8AM → during processOvernightData:
    └→ Finds session 1 from same night in archive
    └→ Merges: offset session 1 + session 2
    └→ Window selector searches across combined data
    └→ Archives, supersedes session 1

[Option D: Overnight crash recovery]
  App is killed mid-recording (iOS jetsam, user-terminated, watchdog)
    └→ currentSession is gone (in-memory)
    └→ Persisted recording state may also be gone
    └→ Archive has a placeholder entry (score ≤ 1.0, meanRMSSD nil)
      from the pre-analysis live-backup write
  Morning: user opens app, strap has the full recording
    └→ resolveBaseSession() falls through:
        1. currentSession?      — nil
        2. persistedState?      — nil
        3. findRecoverableArchivedSession()
           — searches archive for overnight entries started < 24h ago
             with meanRMSSD==nil OR recoveryScore<=1.0
           — returns the newest candidate
    └→ Device-internal download uses the recovered session's ID
       (same UUID, same startDate) — no duplicate session created,
       placeholder is rewritten in place.
```

---

## 10. HR-Estimated Sleep (fallback)

Runs only when HealthKit returns **zero** sleep for the session. It fills a night that would
otherwise show nothing; it does not extend a night that already has data.

```
MorningResultsViewModel loads sleep for the session
  └→ HealthKit returned 0 sleep minutes?
      └→ NO  → use it
      └→ YES → estimateSleepFallback()
          └→ Session has RR beats? → estimateSleepFromHR(rrPoints:)
              └→ minutes > 0 → use it
          └→ else → estimateSleepFromHealthKitHR() over the session window,
                    extended to the end of the user's sleep schedule
              └→ 20-min rolling-average smoothing
              └→ Require HR range ≥ 8 BPM (else bail)
              └→ threshold = maxHR − (maxHR−minHR)×0.5
              └→ onset = first 2 consecutive points below threshold (latency-clamped)
              └→ wake  = end of the LAST continuous below-threshold block
              └→ Require ≥ 12 samples and ≥ 120 min, else nil
          └→ still nil, and the session is live → keep the loading state
                    (the Watch may not have synced yet)
```

**Not implemented: post-session sleep extension.** `SleepResolver.AutoSleepExtension` is defined
and threaded through `fetchSleepData` → `SleepMergingPipeline` → `SleepResolver`, but nothing in
the app constructs one — every production call site passes nil, and only `SleepResolverTests`
builds one. There is no "took the strap off, went back to bed, app annexed the extra sleep" path
in the shipping build. Earlier revisions of this section charted that flow
(`checkForExtendedSleep`, a merge that re-froze the archive) as though it shipped; it did not,
and `DashboardViewModel` no longer exists at all.

---

## 11. App Startup & Deferred Migrations

```
EmuquApp.init
  └→ RRCollector.init
      └→ SessionArchive.shared.loadIndex()     — in-memory index from index.json
      └→ baselineRebuild (if daysCollected == 0)
          └→ loads ALL sessions lightweight (no rrSeries)
      └→ setupBindings / setupLifecycleObservers
      └→ restorePausedStateIfNeeded()          — Task.detached (off main thread)
      └→ refreshRecentPausedSession()          — Task.detached, lightweight retrieval
      └→ repairMergeDataLoss()                 — Task.detached, gated by UserDefaults flag
          └→ Pre-filters by index linkedSessionIds (no disk I/O for unlinked sessions)
          └→ Processes one session at a time (max ~2-3MB peak)

The launch housekeeping phase (`AppLaunchTasks.scheduleMigrationJobs`,
after the dashboard's first load or a 6 s ceiling) runs two background jobs.

`archive.runDeferredMigrations()` (also run after a CloudKit pull).
Each migration uses 3-phase locking to avoid blocking the main thread:
        Phase 1 (locked):   gather entries + file URLs from index
        Phase 2 (unlocked): disk I/O (file reads, JSON decode/encode)
        Phase 3 (locked):   apply patches to index + saveIndex()

      └→ reencryptPendingSessions()
      └→ migrateRecoveryScores()   — backfill nil recoveryScore from session files
      └→ migrateEndDates()         — backfill nil endDate from session files
      └→ migrateMetrics()          — backfill nil meanHR/stressIndex from session files
      └→ migrateSleepIndexFields() — backfill sleepEnd / sleepSegmentCount on the index
      └→ removeDuplicates()        — delete same-night duplicate overnight sessions
      └→ relinkSameNightSessions() — fix unlinked same-night split-sleep segments

And `collector.runDeferredSessionMigrationsIfNeeded()`
(`SessionDataMigrations.runAllIfNeeded`), which steps through, in order:
  └→ runInsufficientDataMigrationIfNeeded()
      Guarded by UserDefaults `didRunInsufficientDataMigration_v1` —
      runs once per install. Walks the archive, flips
      hrvDataQuality = .insufficient and rescores with
      useBaselineHRV: true for sessions that meet the insufficient-
      data criteria but were archived without the quality flag set.
      Skips (without marking done) if baseline stats aren't ready
      yet, so a subsequent launch with a populated baseline retries.
  └→ runTrainingRecalibrationIfNeeded()
      Guarded by `didRunTrainingRecalibration_v1_banister064`. Recomputes
      the training snapshot of scored sessions with the current TRIMP
      formula (the earlier one lacked the 0.64 Banister factor), then
      rescores them.
  └→ runTrimpRepairMigrationIfNeeded()
      Guarded by `didRunTrimpRepairMigration_v1`. Recomputes training
      context for sessions whose `trainingSnapshot` /
      `analysisResult.trainingContext` / `frozenReadiness` were
      computed against the old broken TRIMP fallback (workout-peak HR
      as denominator instead of UserSettings.effectiveMaxHR). Skips
      if `enableTrainingLoadIntegration` is off, in which case it
      marks itself complete since there's nothing to repair.
  └→ runWorkoutSleepCleanupIfNeeded()
      Guarded by `didRunWorkoutSleepCleanup_v1`. One-shot — strips
      sleepSnapshot from `.workout`-typed sessions where the
      pre-2026-04-30 morning-reading selector erroneously attached
      one. Other workout fields untouched.
  └→ runNapRepairMigrationIfNeeded()
      Guarded by `FlowRecovery.napRepairBackfill.v1.done`. Credits a
      nap before the night against sleep debt and rescores; each
      session is marked `napRepaired` so it is never processed twice.

InsufficientData, TrimpRepair and WorkoutSleepCleanup have parity tests in
`EmuquTests/CollectorMigrationParityTests.swift`. The Archive-level migrations are covered by
`EmuquTests/ArchiveMigrationParityTests.swift`.
```

---

## 11a. UI Session Data Flow

Each non-dashboard screen owns its own archive subscription. `MainTabView`
owns and loads the dashboard's own slice (`sessions`) and `totalSessionCount`
— the latter **seeded at init** from the synchronously-loaded archive index so
an existing user's first frame shows the real count, not the new-user
onboarding state — then passes both down to `DashboardV2View`. It coalesces
reload bursts with a 50 ms guard (`lastDashboardReloadAt`) and holds no
cross-tab session state; TrendsV2View and HistoryView load independently. Every
load is driven off the same invalidation signal (`RRCollector.archiveVersion`)
and uses the same underlying API (`recentSessionsAsync(limit:)`), but each
view decides its own scope.

```
SessionArchive (single source of truth)
  │
  ├─ entries            — in-memory lightweight index, sorted newest-first
  ├─ retrieve(id)       — full session (with rrSeries) from disk
  └─ retrieveLightweight(id) — session minus rrSeries

RRCollector
  ├─ archiveVersion: Int — computed passthrough of ArchiveSignal.version, bumped on every mutation
  └─ recentSessionsAsync(limit: Int?) → lightweight sessions

Invalidation signals (every view observes these):
  RRCollector.archiveVersion        — local mutation (save/delete/reanalyze)
  CloudKitSyncManager.pullVersion   — remote pull completed

View                Load on appear + on signal           Scope
─────────────────────────────────────────────────────────────────────────
DashboardV2View     recentSessionsAsync(limit: 35)       35 newest
(loaded by MainTabView)                                  (Recent strip = 30 days)
TrendsV2View           recentSessionsAsync(limit: nil) then  ALL qualifying
                    filter .overnight && analysisResult
HistoryView         archive.entries (lightweight)         All, paginated
                                                          display-only
```

**Trend input contract**: `TrendsV2View`'s input is every loaded session
inside the user-selected `TimeRange` (`.seven` / `.fourteen` / `.thirty` /
`.ninety` / `.all`) that is `.overnight`, has an `analysisResult`, and is
`isReliableForHRVAggregates`, then narrowed by the selected tag filter, if
any. Nothing else reduces the set.

**Concurrency rules**:
- Each view owns one in-flight refresh `Task`. A new refresh cancels
  the prior one via cooperative cancellation.
- UI state writes happen on `MainActor` after
  `guard !Task.isCancelled else { return }` is checked both before
  the MainActor hop and inside the closure — cancellation is
  cooperative and the outer guard races the hop.
- `reanalyzeSession` and other mutation paths call
  `notifyArchiveChanged()` which bumps `archiveVersion`. Every
  subscribed view re-loads per its own rules. Mutation paths do not
  write session arrays directly into views.

---

## 12. Key Files Reference

| File | What it does |
|------|-------------|
| `PolarManager.swift` | Streaming RR data → RRPoint creation with t_ms/wallClockMs |
| `RRModels.swift` | RRPoint/RRSeries/metrics data structures |
| `HRVSession.swift` | Session model with all metadata |
| `RRCollector+OvernightStreaming.swift` | Start/stop streaming, gatherOvernightData, **mergeParentSessionData** |
| `RRCollector+PauseResume.swift` | pauseOvernightStreaming, resumeOvernightStreaming |
| `RRCollector+MorningProcessing.swift` | **processOvernightData** — main analysis pipeline, supersedeSameNightSession |
| `RRCollector+DeviceRecording.swift` | fetchTrainingLoadIfEnabled, device-only recording |
| `MorningProcessingService.swift` | Delegated implementation of processOvernightData pipeline |
| `RecoveryScoreCalculator.swift` | Recovery score: HRV + Sleep + Vitals tiers (v3.oct2026; training load on parallel surface) |
| `HRVSleepStageClassifier.swift` | Full sleep stage classification from RR data |
| `SleepMergingPipeline.swift` | Sleep stage merging and HRV-enhanced Watch stage augmentation |
| `SleepBoundaryResolver.swift` | Consolidated sleep boundary resolution (HealthKit → HR-based → recording bounds) |
| `OvernightChartsView.swift` | Chart data prep, HR and HRV Canvas rendering |
| `SleepTimelineEditorView.swift` | Timeline sleep editor — add/remove/split/merge/carve-awake |
| `SleepTimelineEditModel.swift` | Pure-value edit state + 5-entry undo stack |
| `AnalysisSummaryGenerator.swift` | Narrative generator (per-tag feelBadAdvice in `+Steps.swift`) |
| `ArchiveStatusComponents.swift` | Dashboard banners + status pill for archive state |
| `SessionDataMigrations+InsufficientDataMigration.swift` | One-shot quality-flag backfill across the archive |
| `MorningFeelingTag.swift` | Body/Mind tags + forward-compat Codable wrapper |

---

## 13. Post-Acceptance Mutation Contract

An archived session is **frozen** except for two narrow classes of
mutation: explicit user actions, and automatic *additive-merge*
paths that fill in late-arriving HealthKit data without overwriting
existing real values.

### 13.1 User-initiated mutations (full-overwrite allowed)

| Path | Trigger | User action required |
|------|---------|---|
| `reanalyzeSession` | "Reanalyze" button | Yes |
| `retroApplySleepSettings` | HRV-sleep-augmentation toggle | Yes |
| `applyManualAnalysis` | Manual window drag | Yes |
| `updateSessionSleepBoundaries` | Timeline editor Done | Yes |
| `repairTrainingSnapshots` | Settings → Troubleshooting → Advanced Diagnostics on → Repair Training History… | Yes |
| `runInsufficientDataMigrationIfNeeded` | First launch only, gated | No, but one-shot |
| `SessionRecoveryService` recovery fallback | App relaunch detecting an interrupted recording (rare) | No, but only fires when a recording was interrupted mid-flight — recomputes deterministically from the same inputs. |
| CloudKit merge | Sync import | No (import only) |
| Session resume | Resume button | Yes |

### 13.2 Automatic additive-merge paths (fill-in-only)

These paths run automatically when Apple Watch syncs late-arriving
samples (overnight RR, SpO2, wrist temp, sleep stages). They never
overwrite a real value with `nil`; they only fill in fields that
were `nil` at acceptance time. The session file is re-archived only
when the merge added at least one non-nil field.

| Path | Trigger | Behavior |
|------|---------|---|
| Dashboard vitals refresh | HK vitals observer fire | Fills `vitalsSnapshot` nil fields with fresh HK values. Strap-derived RHR (`session.analysisResult.timeDomain.meanHR`) always wins over HK daytime RHR. |
| `RecoveryScoreDetailView` vitals refresh | View open | Same additive merge as above, scoped to the displayed session. |
| `HealthKitManager.fetchSleepData` | Dashboard load | If frozen `sleepSnapshot.totalSleepMinutes == 0` or `sleepEnd` is impossibly in the future, refetches HK. Otherwise reads the frozen snapshot. |
| `autoRefreshTodaysSleepIfImproved` | `HealthKitManager.sleepDataVersion` bump (Apple Watch sleep sync) | Skips entirely when `session.sleepUserAdjusted == true` (2026-06-10 — user timeline edits are the source of truth; this path previously had no guard and resurrected auto boundaries over manual edits on every HK sleep arrival). Otherwise, if the fresh HK data passes the improvement gate it rewrites `session.sleepSnapshot` directly and re-archives; if the delta also crosses the rescore threshold (≥ 20 min or first snapshot) it additionally posts `.flowRecoveryRescoreNeeded` for the rescore listener. |
| `installRescoreListener` | `.flowRecoveryRescoreNeeded` notification | Reanalyzes the session via the user-initiated path; new score is captured in `PendingScoreChange` for the dashboard banner (§16.4). |

### 13.3 Integrity contract

Opening a past session (older than today) produces an identical
`recoveryScore`, `scoreBreakdown`, `frozenReadiness`, and
`trainingSnapshot` across any number of loads. Today's session may
upgrade once when Apple Watch finishes syncing, surfaced via the
score-changed banner — but never silently drifts on subsequent
loads after that single upgrade. Verified by
`SessionImmutabilityTests`.

---

## 14. Sleep Timeline Editor

```
Entry: SleepDetailV2View presents SleepTimelineEditorView(session, sleepData)

SleepTimelineEditorView
  ├─ Canvas-based segment bars (same rendering pattern as OvernightChartsView)
  ├─ Drag boundary handles — snap to 5-min grid, 44pt hit target
  ├─ Tap segment → inspector toolbar (Split / Carve Awake / Merge / Delete)
  ├─ Long-press empty area → add user-declared segment
  ├─ 5-entry undo stack (SleepTimelineUndoStack)
  └─ Done button →
      SleepScienceAnalyzer.buildSleepDataFromTimelineState(original, state)
        ├─ Re-runs SleepMergingPipeline.splitStageIntervalsByAwake
        ├─ ALL .unspecified intervals (user-declared, iPhone, Watch,
        │  HRV-derived) count toward totalSleepMinutes
        │     → do NOT count toward deep/core/REM sub-minutes
        │     (2026-06-10 — was user-provenance-only, which saved a
        │      0-minute total for iPhone-only nights and let the next
        │      automatic HK refresh overwrite the user's edit)
        ├─ Interval-less envelope segments (strap-only / HR-estimated
        │  nights) count their envelope duration as unspecified sleep
        └─ Provenance preserved per interval
      ↓
      collector.updateSessionSleepBoundaries(sessionId, sleepData,
                                             isUserAdjustment: true)
        ├─ Sets sleepUserAdjusted = true (blocks retroApplySleepSettings)
        ├─ Rescores via RecoveryScoreCalculator
        ├─ archive.archive(updatedSession)
        └─ Fires onArchiveChanged → dashboard + history propagate

SleepData.edits: [SleepEditRecord]   ← audit trail (addSegment, split,
                                       merge, carveAwake, adjustBoundary)
                                     ← shown in "View changes" disclosure

Provenance on SleepStageInterval:
  .watch / .iphone / .hrvDerived / .userAdded / .userCarved
  Rendered as stroke style in the timeline (dashed for user-added,
  glyph for user-carved) — colors stay semantic to stage.
```

---

## 15. Morning Feeling & Divergence Narrative

```
Dashboard (today only, after score hero)
  └→ MorningFeelingPrompt (5 emoji 1-5)
      ├─ User taps emoji
      │   └→ 1-second commit delay (cancellable)
      ├─ If rating ≤ 2: tag chips appear
      │   └→ Body cluster:   Infection, Allergies, Hangover,
      │                      Stomach, Sore, Tired, Headache
      │   └→ Mind cluster:   Stressed, Down
      ├─ Tap badge after commit → re-open prompt (today-only,
      │                          Dashboard-only; frozen once user leaves)
      └→ viewModel.updateMorningFeeling(rating, tags)
          └→ Writes morningFeeling + morningFeelingTags onto HRVSession
          └→ Archive write (1 extra, same archiveVersion bump path)

Scoring: NOT blended. Saw 2016 shows subjective/objective don't
correlate; Altini rejects composite scores. Instead:

AnalysisSummaryGenerator.feelBadAdvice(hrvGood:tags:feeling:)
  (AnalysisSummaryGenerator+Steps.swift)
  ├─ Divergence detected? (high score + low feeling OR reverse)
  ├─ Per-tag narrative branches:
  │   Infection    → rest; no condition named
  │   Hangover     → easy aerobic only
  │   Allergies    → aerobic OK, monitor RHR
  │   Stressed + good HRV → exercise as stress buffer
  │   Stressed + poor HRV → rest; body is already stressed
  │   Sore, Tired, Down, Stomach, Headache → distinct branches
  └─ Appended to the analysis summary string
```

---

## 16. Archive Status Visibility

```
Dashboard
  ├─ InterruptedSessionBanner (red)
  │   Shown when RRCollector detects an interrupted session.
  │   Persistent until the user acts on it.
  ├─ LostBackupsBanner (gold)
  │   Shown when RawRRBackup has unarchived RR backups on disk.
  │   Tapping offers recovery/discard.
  ├─ ScoreChangedBanner (tint = primary if delta ≥ 0, orange if < 0)
  │   Shown when PendingScoreChange.read() returns a non-nil entry.
  │   Written by recordPendingScoreChangeIfMeaningful() in the rescore
  │   listener (RRCollector+Reanalysis.swift) when an auto-rescore moves
  │   the score by ≥ 3 points (e.g. Apple Watch synced sleep at 11 AM,
  │   score climbed 67 → 74). Title text reflects the reason:
  │     "Sleep data finished syncing — score updated · 67 → 74"
  │     "Training context refreshed — score updated · 72 → 69"
  │   Single-slot (latest wins). Cleared on tap-X or after the dashboard
  │   reads it once. On-foreground load via .onAppear; live update via
  │   .pendingScoreChangeWritten NotificationCenter event.
  └─ Recovery card
      └─ ArchiveStatusLine pill (ArchiveStatusComponents.swift)
           Archive half: "Saved" or "Saving…"
           iCloud half:  "iCloud"      (uploaded)
                         "Retrying…"   (pending retry queue)
                         "Syncing…"    (upload in flight)
                         "Local only"  (not uploaded)

Settings → iCloud & Data
  ├─ Storage Summary section
  │   Counts: archived sessions, uploaded to iCloud, pending retry.
  └─ "Force iCloud Sync" button
      Manual escape valve only. Automatic 30-min-gated sync path
      is unchanged — this is NOT a retry loop. Shows success/error
      alerts on completion.

Settings → Troubleshooting → Advanced Diagnostics (toggle on)
  └─ "Repair Training History…"
      Confirmation ("Repair All Sessions") explains it mutates
      historical scores. Only manual trigger for repairTrainingSnapshots.
```

### Morning notification scheduling

```
MorningNotificationScheduler
  ├─ Fixed-time fallback (always scheduled when dailyReportEnabled)
  │   UNCalendarNotificationTrigger(repeats: true) at
  │   settings.dailyReportFixedTime. Fires every day at the same
  │   clock time regardless of actual wake.
  └─ Wake-triggered one-shot (Smart delivery only, alongside the fallback)
      HealthKitManager+SleepTrends.startObservingSleepData() observer
      callback receives sleep samples the moment Apple Watch syncs.
      For each fire:
        ├─ Delivery is Smart? (Fixed sends only at the set time) AND
        ├─ Freshest sleep-end within last 90 min? AND
        ├─ Haven't already delivered today (UserDefaults date flag)?
        └─ Deliver UNNotificationRequest with trigger=nil (immediate).
      The fallback occurrence later that morning is left in place —
      iOS doesn't support "skip today's repeating occurrence" — so
      on days where the Watch wakes the app, the user may see two
      notifications minutes apart. Acceptable v1 trade-off.
```

### Known Deferred

These features have a clear product intent but the UX strategy /
payload wording is unfinalised. Listed here so they don't masquerade
as orphaned code in the next audit.

- **14-day re-engagement push** — A single reminder fired when the user
  has not recorded an overnight HRV session for 14 consecutive days.
  Implementation outline:
  1. Add `lastOvernightSessionDate: Date?` to `UserSettings`.
  2. Update the timestamp in `SessionAcceptanceService` when an overnight
     session is archived.
  3. Schedule via `UNUserNotificationCenter`, cancel on next session.
  Effort: ~100 LOC across 3 files. Risk: minimal. Blocked on:
  notification body wording + tap-through route (dashboard vs onboarding
  prompt).
- **A/B-tested morning push format** — Beyond the current "Auto = teaser
  for first 30 sessions, full readout from 31+" gate, no further
  segmentation is implemented.

---

## 17. HealthKit Export (Write-Back)

```
HealthKitManager.exportSessionMetrics(session)  — per-metric do/catch,
each gated by its own export setting
  ├─ exportWindowedHRV(session)
  │   HKQuantitySample (SDNN), one per ~5-min window
  ├─ exportHeartRateSeries(session)
  │   One discrete HKQuantitySample per minute (not a series builder)
  ├─ exportRestingHeartRate — one per day, nocturnal median only
  ├─ exportSleepIfSoleSource → exportSleepToHealthKit
  │   Only when the boundaries were HR-estimated (the app is the only
  │   source). The timeline editor never exports.
  │   Apple HK constraint: Asleep samples must not overlap; InBed may.
  └─ Per-metric failures are isolated — a single failed write does
     not abort the remaining metrics.
```

---

## 18. Fitness Tab — Workout Recording Pipeline

```
Live workout:
  User taps Start → WorkoutRecorder.start(
        sport:, source:, intervalPlan:,
        thresholds: [WorkoutThreshold],   ← user-declared constraints
        route: Route?                     ← saved-route OR GPX import OR
                                            OSM trail discovered via the
                                            "Discover trails near me" sheet
                                            (TrailDiscoveryService → Tavily-
                                            free OSM Overpass query)
    )
    │
    ├─ Auto-reconnect previously-paired secondary sensors (2026-04-29):
    │     ├─ if source == .strap AND polarManager not connected AND
    │     │     polarManager.knownDevices.isEmpty == false:
    │     │       polarManager.connectToLastDevice()  ← fire-and-forget
    │     │       (recorder stays on .strap; HR subscription installed
    │     │       below picks up the stream when BLE callback lands)
    │     ├─ if !FootPodManager.shared.knownDevices.isEmpty AND
    │     │       FootPodManager.shared.connectionState == .disconnected:
    │     │       FootPodManager.shared.reconnectLast()
    │     └─ if sport == .row AND Concept2 known + disconnected:
    │             Concept2Manager.shared.reconnectLast()
    ├─ Optional: core.polarManager.startStreaming()    (if strap source)
    ├─ location.startTracking()                         (if GPS sport;
    │     LAZY-init of WorkoutLocationManager — first access constructs
    │     CLLocationManager + CMAltimeter. Pre-2026-04-29 this happened
    │     in WorkoutRecorder.init() and froze the tab swap for 2-3 s.)
    ├─ pedometer.start()                                (foot-based sports)
    ├─ footPodManager.start() / Concept2Manager.startScan() / FTMS subscribe
    ├─ watchBridge.startWatchWorkoutSession(sport:)     (Watch parallel)
    ├─ dfa.reset(sessionStart:)                         (live α1 analyzer)
    ├─ voiceCoach.reset()                               (trigger history)
    ├─ ZwiftPeripheralBroadcaster.shared.start()        (if enableZwiftBroadcast)
    └─ startTicker()  ─ 1 Hz incremental-backup loop

Per tick (WorkoutRecorder.incrementalBackupTick):
    │
    ├─ Read polarManager.streamedRRPoints                (new RR beats)
    ├─ dfa.ingest(points:)                              (feeds rolling window)
    │     → LiveDFAAnalyzer recomputes α1 every 20 s
    │     → Status enum: warmup(fractionReady) /
    │                    ok /
    │                    stalled(secondsSinceLastBeat) /
    │                    fitFailed
    ├─ rawBackup.incrementalBackup(points:sessionId:)   (disk + cloud)
    ├─ Distance = max(footPod, GPS, pedometer, PM5)
    ├─ workoutSamples.append(WorkoutSample(...))        (per-tick series)
    ├─ Route auto-detect (≥500 m of fresh GPS, GPS-sport only)
    │     RouteLibrary.findMatch(currentTrack:, sport:, store: SavedRouteStore.shared)
    │       For each saved route in this sport:
    │         ├─ score forward direction (saved track as-is)
    │         └─ score reverse direction (track reversed + Route rebuilt
    │                from reversed trackpoints so climb queue matches the
    │                direction the user is actually running)
    │       150 m start-point cheap-reject → mean-nearest-neighbour
    │       distance ≤ 30 m wins → bind plannedRoute + plannedRouteDirection.
    ├─ thresholdBreachSec[UUID: Int] = updateThresholdBreaches(activeThresholds:, …)
    │     For each WorkoutThreshold:
    │       evaluate(hr/hrZone/power/ftp/pace/α1/cadence) → Bool?
    │       True  → counter += dt seconds
    │       False → counter = 0   (reset)
    │       nil   → leave unchanged (metric not available)
    ├─ WeatherService.shared.refreshIfNeeded(for: location.currentLocation)
    │     30-min cache TTL, re-fetch on >5 km movement, silent on failure.
    ├─ RoadGeocodingService.shared.refreshIfNeeded(for: location.currentLocation)
    │     Apple CLGeocoder reverse-geocode → road name + locality + state
    │     + country. Re-fetch only on >15 m movement OR >60 s elapsed.
    │     Backs off after 8 consecutive failures, retrying every 30 s. Result lands in the
    │     LiveWorkoutSnapshot below.
    ├─ LiveWorkoutBroker.publish(LiveWorkoutSnapshot)   (for AI context)
    │     ├─ wall-clock snapshotAt + sessionStartAt
    │     ├─ GPS lat/lon/altitude + heading (cardinal)
    │     ├─ current grade (trailing ~100 m elevation Δ / distance)
    │     ├─ current pace / speed / power / METs / cadence
    │     ├─ recent 3 split paces
    │     ├─ α1 status + fit quality R²
    │     ├─ strap silent-seconds
    │     ├─ units preference (so AI renders in user's language)
    │     ├─ targetZone
    │     ├─ activeThresholds + thresholdBreachSec
    │     ├─ currentRoadName + currentLocality + currentAdministrativeArea
    │     │     + currentCountry + currentCountryCode + compactAddress
    │     │     (from RoadGeocodingService — Apple CLGeocoder)
    │     ├─ recognized_route name + direction (forward/reverse)
    │     ├─ routeTopology (climbs queue capped at 5, total ascent
    │     │     remaining, peak altitude, steepest grade ahead, metersToPeak)
    │     └─ weather (temp, apparent temp, wind, humidity, conditions)
    ├─ watchBridge.sendLiveState(...)                   (Watch complication)
    ├─ ZwiftPeripheralBroadcaster.shared.update(heartRate:powerWatts:)
    │     (only when enableZwiftBroadcast; broadcasts HRS+CPS to Zwift et al.)
    ├─ voiceCoach.tick(context: WorkoutAIContext)       (rule engine)
    │     WorkoutTriggerEngine.evaluate()
    │     ├─ α1 below AeT rule
    │     ├─ α1 above VT2 rule
    │     ├─ HR drift > 5 % rule
    │     ├─ HR spike with no pace change rule
    │     ├─ Terrain climb-ahead rule (now uses length + grade +
    │     │     queue-position from routeTopology — "climb in 200 yards,
    │     │     0.4 miles at about 7 percent grade. First of 3.")
    │     ├─ Zone drifted high/low rules
    │     ├─ user.threshold.breach rule (fires when any threshold's
    │     │     breach counter ≥ debounceSec, respects cooldownSec)
    │     └─ Strap dropped rule
    │     Fired events dispatched to TTS / haptics, ≥ 10-min cooldowns.
    ├─ TurnAlertEngine.evaluate() / TurnMarkerEngine.evaluate()
    │     Tier-3 route awareness layer. Requires an active
    │     ActiveRouteSession AND user toggles (enableTurnByTurnAlerts /
    │     enableTurnMarkerUpdates).
    │     TurnAlertEngine fires BEFORE a turn at three distance bands
    │     (150 m far, 60 m near, 25 m at-turn). Monotonic-once-per-
    │     band so GPS jitter doesn't re-fire (TurnAlertState tracks
    │     lastThresholdLevel 0–4). Example:
    │       "In 200 feet, turn right onto Elm."
    │     TurnMarkerEngine fires AFTER a turn with a leg-recap utterance:
    │       "You turned onto Elm. Last leg: 2:14, pace 8:45, HR 142."
    │     Both are pure evaluators — engines hold no state and return
    │     `(payload, nextState)`. The caller (WorkoutVoiceCoach) is
    │     responsible for dispatching the payload through its voice /
    │     haptic queue and persisting the TurnAlertState /
    │     TurnMarkerState across ticks.
    ├─ WorkoutMileMarkerEngine.evaluate()
    │     Tier-2 split-marker notifications, opt-in via
    │     enableMileMarkerNotifications. Distance-based (mi/km/2km/5km)
    │     or time-based (10 min blocks). On marker cross emits pace,
    │     HR zone, cadence (only if outside 165–190 spm band), elevation
    │     (only if ≥ 15 m gained this split), total distance. A 4-second
    │     utterance length is the documented design target (not a hard
    │     formatter constraint) so the cue doesn't run long enough to
    │     interrupt the next one.
    └─ intervalController.tick(totalDistanceMeters:)    (structured plan)

User taps Stop → WorkoutRecorder.stop():
  ┌─ Snapshot polarManager.streamedRRPoints (RR points)
  ├─ NOTE: we do NOT stopStreaming() yet; HRR Tier-1 needs the strap
  │         still broadcasting for the next 120 s.
  ├─ location.stopTracking(), pedometer.stop(), watchBridge.stop()
  ├─ LiveWorkoutBroker.clear()  (AI no longer reports "live")
  ├─ finalizeSession(rrPoints:stopDate:hrrSamples:[])
  │     WorkoutAnalyzer.analyze(
  │         sport:,
  │         rrPoints:,
  │         startDate:,
  │         track:,
  │         userMaxHR:,       ← Settings.effectiveMaxHR
  │         userRestingHR:,   ← Settings.effectiveRestingHR (HRV baseline)
  │         userLTHR:,        ← Settings.effectiveLTHR
  │         sex:,             ← Banister k coefficient
  │         splitDistanceMeters:
  │     ) → WorkoutMetadata
  │         ├─ Banister TRIMP (continuous, HRR-based, sex-aware:
  │         │     male A=0.64,k=1.92 / female A=0.86,k=1.67)
  │         ├─ hrTSS = session TRIMP / 1hr-at-LTHR TRIMP × 100
  │         ├─ Power-derived (when power source + matching FTP both present):
  │         │     ├─ Normalised Power (4-s rolling → mean 4th power → 4th root)
  │         │     ├─ Intensity Factor (NP / FTP)
  │         │     ├─ Power-TSS ((NP/FTP)² × hours × 100)
  │         │     ├─ Variability Index (NP / avg power)
  │         │     └─ ftpAtTimeOfSession (frozen for historical comparability)
  │         ├─ Rowing-specific (Sport.row, Concept2 PM5):
  │         │     ├─ strokeCount
  │         │     ├─ averageSplitSecPer500m
  │         │     └─ dragFactor
  │         ├─ Pa:Hr decoupling + Efficiency Factor
  │         ├─ Splits at 1 km (metric) or 1609.344 m (imperial)
  │         └─ Polyline-encoded GPS track + altitude
  │     merged with samples[], power aggregates, gpsPolyline
  │     archive.archive(session)  (CloudKit + HealthKit write-back)
  ├─ ZwiftPeripheralBroadcaster.shared.stop()
  ├─ Auto-archive workout track as breadcrumb trail (2026-04-29):
  │     if sport.usesGPS AND track.count >= 2:
  │       BreadcrumbStore.shared.archive(
  │         BreadcrumbTrail(
  │           startedAt: session.startDate,
  │           origin:    BreadcrumbFix(from: track.first!),
  │           fixes:     decimated(track, 25 m or 30 s),
  │           label:     "<Sport.displayName> on <date> <time>"
  │         )
  │       )
  │     50-trail retention cap; oldest evicted on append.
  │     Lets the AI's `directions.routeTo origin` find the start of
  │     this workout even if Get Me Back was never explicitly engaged.
  ├─ Footpod auto-disconnect (2026-04-29):
  │     if FootPodManager.shared.connectionState in [.connected, .connecting]:
  │       FootPodManager.shared.disconnect()
  │     (Footpod doesn't participate in HRR — drop it now to save
  │      battery / radio. Strap stays connected through HRR.)
  ├─ phase → .finished; summary sheet opens IMMEDIATELY
  │     Post-summary surfaces an "Add to my route library" action when
  │     the session has a polyline. Tapping it prompts for a name and:
  │       1. SavedRouteStore.shared.add(SavedRoute.from(session:, name:))
  │       2. SavedRouteStore.shared.enrichWithRoadNames(routeID:) fires
  │          a background Task that reverse-geocodes each climb's start
  │          coord (paced 600ms apart for CLGeocoder rate limit) and
  │          persists the enriched climbs onto the SavedRoute. Road
  │          names appear within ~5–15 s.
  │     Both actions also surface for ANY past workout (no recency gate)
  │     when the user opens the summary from the History tab.
  └─ Task.detached(priority: .userInitiated):
        HRRCaptureService.captureHRR(stopDate:stopHR:)  (stopHR = HR at Stop, Cole 1999)
          Tier 1 (Strap): sample polarManager.currentHeartRate at +60 s, +120 s
          Tier 2 (Watch): query HKQuantityType.heartRate in [+0, +window+15]
          Tier 3 (Apple): HKQuantityType.heartRateRecoveryOneMinute ±5 min
        AFTER capture:
          polarManager.stopStreaming()
          polarManager.disconnect()  ← 2026-04-29: drop the BLE link
                                       so the strap battery stops
                                       draining. Voice chat (if any)
                                       continues without live HR —
                                       AI handles `notRecorded` cleanly.
        archive.retrieve(sessionId) → write hrrSamples → re-archive
        MainActor.run: self.finishedSession = session  (UI refreshes)
        Empty-result case: hrrSamples = [] still written, card shows
        "no signal" instead of stuck on "capturing…".
```

### Post-summary cards data flow

```
FitnessPostSummaryView reads session.workoutMetadata:

  Headline stats       ← samples[] aggregates + meta.luciaTRIMP + meta.hrTSS
  Route map            ← gpsPolyline → GPXExporter.decode()
  HRR card             ← meta.hrrSamples?.bestAtOneMinute / bestAtTwoMinutes
  Chart cards          ← samples[] filtered by metric presence
  α1 Timeline          ← samples[].alpha1 with AT1 (0.75) / AT2 (0.50) rules
  Route by α1 Band     ← samples[].alpha1 ↔ track[i].timestamp correlation
                          → polyline segments coloured per LiveDFAAnalyzer.Band
  α1 LT1 Estimate      ← first downward α1=0.75 crossing's HR value
                          estimate, a proxy (Rogers & Gronwald 2021)
                          suggests LTHR update when heuristic-vs-measured
                          delta ≥ 5 bpm AND user hasn't set an override
  Threshold Crossings  ← iterate samples[] detecting AT1/AT2 ups/downs
  HR Zone Distribution ← samples[].heartRate vs user.effectiveMaxHR
  Derived Metrics      ← moving %, VAM, grade-adj pace, kcal/h,
                          stride length, power:HR ratio
  Physiology           ← meta.decouplingPercent, meta.efficiencyFactor
  Splits               ← meta.splits (per-km or per-mile unit-aware)
  Export               ← GPXExporter / CSVExporter / TCXExporter in .task
```

---

## 18a. Route Awareness Pipeline (where road names and turn cues come from)

Called on-demand from the AI's `facts.roadAwareness` action and during
the workout per-tick context update.

```
RoadAwarenessEngine.snap(location, course, speed)
  ├─ Gates: course accuracy ≥ 30°, speed ≥ 0.7 m/s
  │   (low-speed bearing is noisy — refuse to snap rather than mis-snap)
  ├─ Step 1: RoadGraphService.tileFor(location)
  │   ├─ 250 m grid cells, 800 m fetch radius, 6 h TTL
  │   ├─ Tile query: OSM Overpass, walkable ways only
  │   │     (residential, primary, footway, path, cycleway, track,
  │   │      pedestrian, steps, living_street)
  │   ├─ Concurrent calls for same cell coalesce to one fetch
  │   ├─ Throttle: 1.1 s min-gap between Overpass calls, 8 s timeout,
  │   │     fair-use budget ~10k/day
  │   └─ Returns RoadGraph (node + way index) — actor-isolated, serial.
  ├─ Step 2: snap to nearest way segment
  │   Confidence = 0.7 × distance_score + 0.3 × bearing_agreement
  └─ Step 3: walk graph forward up to 600 m or 3 intersections
      Output: current road name, upcoming turn list, road-continuation
              distance, confidence (0–1).
      Safety invariant: NEVER invents a road name — returns nil phrase
      when confidence is low (caller surfaces "off-route" instead).

RoadGeocodingService.reverse(location)
  Primary + fallback for the road name, plus a parallel enrichment for
  subdivision. App-launch prewarmed to eliminate first-fix latency:
    Primary:   MKLocalSearch against Apple Maps' road data (5 s timeout).
    Fallback:  CLGeocoder (5 s timeout; 30 s recovery throttle after 8
               consecutive failures).
  Cross-street search escalates over 4 radii (200, 500, 1500, 3000 m)
  to handle rural and urban grids.
  Movement gate: 15 m since last lookup.
  Time gate: 60 s since last lookup.
  Street-name normalization strips suffixes + directions so
  "Elm St" doesn't fail to match "Elm Pl" mid-step.
```

---

## 18b. Fitness — Retroactive Repair Actions

Two one-shot actions on the summary sheet repair historical sessions
recorded before quality fixes landed.

```
Look up real elevation (post-summary action)
  ├─ Resolves GPS track from decoded polyline
  ├─ TopoElevationService.elevations(for: track, maxSamples: 100)
  │     ├─ US coords: OpenTopoData USGS NED 10m DEM
  │     │             https://api.opentopodata.org/v1/ned10m
  │     └─ Else / on error: OpenTopoData SRTM 30m
  │                   https://api.opentopodata.org/v1/srtm30m
  │                   (error on failure — shown, no silent fallback)
  │     Applies a 15 m sustained-climb threshold:
  │     accumulate same-sign deltas, commit to gain/loss only
  │     once the run crosses ≥ 15 m.
  ├─ First tap: preview gain / loss values (no write yet)
  └─ Second tap: write back to archive + notifyArchiveChanged()
     FitnessTabView's hero `.task(id:)` key includes archiveVersion,
     so the hero reloads with the corrected number in the same view.

Re-analyze α1 (post-summary action)
  ├─ Loads session.rrSeries.points (the raw RR stream)
  ├─ WorkoutAlpha1Reanalyzer.reanalyze(session:)
  │     Iterates 2-min rolling windows at 20-s cadence (same as live).
  │     Each window:
  │       ├─ LiveDFAAnalyzer.cleanRRForDFA(rrs)
  │       │     Kubios-style: ±20 % ectopic threshold vs 5-beat
  │       │     rolling median, linear-interpolation replacement
  │       │     (preserves series length so DFA box sizes don't shift).
  │       └─ DFAAnalyzer.compute(cleaned) → α1 + R²
  ├─ WorkoutAlpha1Reanalyzer.applyReadings(readings, to: samples)
  │     Replaces each WorkoutSample's α1 with the nearest-in-time
  │     cleaned reading; early-in-session samples (pre-first-reading)
  │     get α1 cleared to nil rather than inheriting garbage.
  └─ archive.archive(updated) + notifyArchiveChanged()
```

## 18c. Elevation capture — pro-grade barometric pipeline

```
Live recording (new sessions):
  WorkoutLocationManager.startTracking()
    ├─ CLLocationManager.startUpdatingLocation()       (GPS fixes)
    └─ CMAltimeter.startRelativeAltitudeUpdates(.main) (barometer, 1 Hz)
         └─ every sample:
              barometricSamples.append((timestamp, altitudeMeters))  ← buffer (truth)
              + advance a rough live-display accumulator           ← UI ticker only

  (NOTHING is thresholded or discarded at collect time — every sample
   is preserved so the full algorithm runs on the complete signal
   at session finalize.)

WorkoutRecorder.stop() → finalizeSession():
  if barometerAvailable && !barometricSamples.isEmpty:
    BarometricAltitudeProcessor.process(samples:)
      ├─ Symmetric moving-average smoother, window 15 samples (~15 s)
      │   • matches ~8 s complementary-filter τ (Barczyk & Nemra 2014)
      │   • zero phase lag (offline / symmetric kernel)
      │   • endpoints clamped (no zero-padding collapse)
      ├─ Accumulate same-sign runs on the smoothed signal; commit a
      │   run to gain/loss only once it clears 2 m (Strava's
      │   barometer rule). A per-delta gate undercounts slow climbs
      │   and counts HVAC / pressure blips.
      └─ Return (gainMeters, lossMeters, smoothedSampleCount)
    → metadata.elevationGainMeters = processed.gainMeters
    → metadata.elevationLossMeters = processed.lossMeters

  else (no barometer — pre-iPhone 6 / simulator / permission denied):
    metadata.elevationGainMeters = location.elevationGainMeters (GPS fallback)

Retroactive repair (pre-barometer-buffer sessions):
  User taps "Look up and save real elevation" →
    TopoElevationService.elevations(for: track):
      ├─ If first coord in US bbox → OpenTopoData NED 10m (higher res)
      └─ Else / on NED error → OpenTopoData SRTM 30m
    → apply 15 m sustained-climb threshold (calibrated against
       barometric ground truth on rolling neighborhood terrain)
    → archive.archive(updated) + notifyArchiveChanged()
    → refreshedSession @State updated → sheet + hero refresh in place
```

**Reference**: Barczyk & Nemra 2014, "A Sensor Fusion Method for
Tracking Vertical Velocity and Height Based on Inertial and
Barometric Altimeter Measurements," PMC4179067.

## 19. Training Load Math (Research Citations)

```
TRIMP (Banister 1991):
  For each RR beat (hr_bpm, dur_sec):
    HRR = clamp((hr − HRrest) / (HRmax − HRrest), 0, 1)
    (A, k) = (0.64, 1.92)  if sex == .male
             (0.86, 1.67)  if sex == .female
    y   = A × exp(k × HRR)
    trimp += (dur_sec / 60) × HRR × y
  Range: 0-4.37 /min male, 0-4.57 /min female
  Fallback: Edwards 5-zone %HRmax (when HRrest unknown)

hrTSS (HRSS formulation):
  sessionTRIMP   = Banister(rrPoints, HRmax, HRrest, sex)
  referenceTRIMP = Banister(
                     synthetic 60 beats each 60 s at hr = LTHR,
                     HRmax, HRrest, sex
                   )
  hrTSS = sessionTRIMP / referenceTRIMP × 100
  Returns nil if HRmax, HRrest, or LTHR is missing — never guesses.

LTHR resolution:
  Settings override → 0.88 × effectiveMaxHR (Friel midpoint)
  UI surfaces α1-derived LT1 estimate as a suggested override when
  available (Rogers & Gronwald 2021; about ±10 bpm of gas-exchange VT1).
```

---

## 20. AI Dispatch Flow

The end-to-end path from "user typed or spoke a message" to "tokens
streaming back into the chat bubble." See
[`docs/VOICE_AND_TOOL_USE.md`](VOICE_AND_TOOL_USE.md) for the strategy
rationale; this section walks the actual code path.

### Entry point

```
User speaks / types
  ↓
AssistantViewModel.send(text:fromVoice:)
  ↓
trimmed = text.trimmingCharacters(.whitespacesAndNewlines)
  ↓
nextSendIsVoice = fromVoice          ← consumed by next dispatch()
  ↓
turns.append(ChatTurn(role: .user, text: trimmed))
  ↓
[fast path] DeterministicIntent.tryMatch(trimmed, ctx) → String?
  ├─ HIT  (14-pattern catalog, regex match + non-nil fact value)
  │       → append assistant turn with rendered string
  │       → telemetry: deterministic_hit
  │       → DONE — no LLM call
  └─ MISS → continue to dispatch()
```

The deterministic intent path costs zero tokens and ~50 ms. Coverage:
recovery_score_today, resting_hr_today, hrv_rmssd_today,
sleep_duration_last_night, last_workout_summary, trained_recently,
score_breakdown_today, sleep_stages_last_night, body_weight, max_hr,
lthr, sleep_latency, sleep_efficiency, total_session_count.

### Provider resolution

```
AssistantViewModel.dispatch()
  ↓
mode = SettingsManager.shared.settings.routingMode
  ↓
resolveProviderForThisTurn() → (provider, model, tier)
  (pure core: TurnRouter.route(inputs:))
  │
  ├─ if selected provider != .apple OR mode == .manual
  │     → user's picked (provider, model), tier=nil
  │       (routing modes act only while Apple Intelligence is selected)
  │
  ├─ if nextSendIsVoice:
  │     [VOICE BYPASS]
  │     cloud = first available, consented, non-Apple provider (registry order)
  │     model = cloud.availableModels.first(.isDefault) ?? .first
  │     return (cloud, model, nil)          ← skips classifier
  │     no consented cloud → stay on Apple
  │
  ├─ if mode == .quick    → tier = .quick
  ├─ if mode == .deep     → tier = .deep
  └─ if mode == .auto     → tier = SmartProviderRouter.shared.route(
                                       message: latestUser,
                                       in: sessionState
                                   )
                            sessionState.currentTier = tier
                            sessionState.turnCount  += 1
  ↓
[adversarial cap]
  if tier == .deep && Deep maps to a cloud model && !recordTier3UsageAndCheck():
      tier = .auto                          ← daily Tier-3 ceiling = 50
  ↓
mapping = TierProviderMapper.mapping(for: tier, registry: registry)
  .quick → Apple
  .auto  → consented Grok, then consented DeepSeek, else Apple
  .deep  → (Apple selected) the same consented mid-tier cloud as .auto,
           else Apple
  ↓
[action-intent override]
  if !providerSupportsTools(mapping.provider)
     && messageRequiresTools(latestUser)
     && a consented cloud provider exists:
        mapping = (first consented cloud, its default model)
                                             ← Apple-tool failures fall back
```

### Capability classification (Auto mode)

```
SmartProviderRouter.route(message, in: sessionState)
  ↓
requirement = CapabilityClassifier.shared.classify(message)
  │
  ├─ keywordHeuristic(text) → Requirement{tools, web, depth, speculation}
  │     (lowercased substring match against per-axis marker lists)
  │
  ├─ if NLContextualEmbedding available:
  │     scores = embed(text) ⋅ prototypeCentroids[axis] / |·|
  │     for each axis:
  │         needsAxis = keywordFlag[axis] AND scores[axis] >= 0.55
  │     return Requirement(...)
  │
  └─ else: return keyword-only Requirement
  ↓
proposed = requirement.requiredTier
   • flagsSet == 0 → .quick
   • flagsSet == 1 → .auto
   • flagsSet >= 2 → .deep
  ↓
[stickiness]
  if proposed > sessionState.currentTier:
      chosen = proposed                     ← upgrades always allowed
  elif sessionState.turnCount < 3:
      chosen = proposed                     ← settling window
  elif proposed == .quick && requirement == .none:
      chosen = .quick                       ← capability-clear escape
  else:
      chosen = sessionState.currentTier     ← sticky-up
  ↓
return chosen
```

### Apple Foundation send (Quick tier)

```
AssistantViewModel.dispatch() — provider.id == .apple
  ↓
AppleToolDispatcher.shared.setRegistry(factRegistry)
  ↓
provider.send(messages, model, contextRendered, systemPrompt, tools, ...)
  ↓
AppleFoundationProvider.runStream(...)
  ↓
[strip Anthropic cache marker]
  cleanedPrompt = systemPrompt without AssistantSystemPrompt.cacheSplitMarker
  instructions  = cleanedPrompt + "\n\n" + contextRendered
  ↓
[verbatim compaction]
  systemTokens     = AppleContextCompactor.estimateTokens(instructions)
  compactedMsgs    = AppleContextCompactor.compactedPromptInput(
                       messages, systemPromptTokens: systemTokens
                     )
   • drops oldest user/assistant pairs until used + cost <=
     0.70 × 4096 − systemTokens
   • always preserves the most recent user turn
  ↓
[tool wiring]
  appleTools = tools.map { spec in
      AppleToolCatalog.wrap(spec) { argsJSON in
          AppleToolDispatcher.shared.dispatch(
              name: spec.name, argumentsJSON: argsJSON
          )
      }
  }
  toolHash = sha256(JSON.sortedKeys(tools.sorted by name))
  ↓
[session cache lookup]
  (session, isFresh) = SessionCache.session(
      instructions, tools: appleTools,
      toolCatalogHash: toolHash,
      conversationLength: compactedMsgs.count
  )
   • fresh if: cache empty, instructions changed, tool-hash changed,
                turnsSinceCreation >= 20, or conversationLength <= 1
   • on hit  : reuse session, send only latest user turn
   • on miss : create LanguageModelSession(tools: appleTools, instructions:),
                send full compacted transcript
  ↓
prompt = isFresh ? buildPrompt(compactedMsgs) : latestUserText
  ↓
session.streamResponse(to: prompt, options: .default)
  ↓
[stream loop]
  for try await snapshot in stream:
      try Task.checkCancellation()
      text = mirror(snapshot, key: "content")
      delta = text.dropFirst(previous.count)
      continuation.yield(.textDelta(delta))
      previous = text
  ↓
continuation.yield(.done)
```

### Tool-call resolution path (Apple)

```
LanguageModelSession decides to call tool "session.by_date"
  ↓
AppleToolAdapter.call(arguments: AppleToolAdapter.Arguments(argumentsJSON: "{\"date\":\"2026-05-05\"}"))
  ↓
handler closure                         ← captured in AppleFoundationProvider.runStream
  ↓
AppleToolDispatcher.shared.dispatch(name: "session.by_date", argumentsJSON: ...)
  ↓
guard let registry = currentRegistry else {
    return #"{"error":"tool dispatcher has no registry","tool":"..."}"#
}
  ↓
router = CompactToolRouter(registry: registry)
value  = router.resolveTool(name:, argsJSON:)
  ↓
return value.toToolResultJSON()
  // {"value":<typed>, "missingReason":<enum?>, "asOf":<iso8601>, "confidence":"high"}
  ↓
LanguageModelSession resumes generation with tool output as PromptRepresentable
```

### Cloud provider send (Auto / Deep tier)

```
provider.send(messages, model, contextRendered, systemPrompt, tools, toolRounds)
  ↓
[provider-specific body assembly]
  • Anthropic: cache_control breakpoints on last tool def (1h TTL),
                system, last conversation turn; <live_state> block
                appended to last user message tail (NOT system role)
  • OpenAI / DeepSeek / Grok: function-tool-calling JSON
  • Gemini: function_declarations array
  ↓
[tool loop, max 8 tool calls per turn — AssistantViewModel.maxToolCallsPerTurn]
  while totalToolCalls < 8 && got tool_use blocks:
      for each tool_use:
          factValue = registry.resolveTool(name, argsJSON)
          continuation.append(tool_result, content: factValue.toToolResultJSON())
      stream next round
  ↓
[stream loop]
  for try await event in stream:
      .textDelta(s)        → append to current assistant turn
      .toolUse(...)        → buffer until round complete
      .usage(in, out, cR, cC)
                           → LLMCacheTelemetry.shared.record(provider: id, ...)
      .done                → break
```

### Telemetry sinks

```
Stream .usage event
  ↓
LLMCacheTelemetry.shared.record(
    provider: id,
    inputTokens, outputTokens,
    cachedReadTokens, cacheCreationTokens
)
  ↓
in-memory aggregation:
  • cumulative hit ratio (per provider + global)
  • last-N-turn rolling window (default N = 10)
  ↓
exposed via Settings → Troubleshooting → AI cache health card
```

```
SmartProviderRouter.route(...)
  ↓
recordTelemetry(proposed, chosen)
  ↓
in-memory counters:
  • tierCounts[chosen] += 1
  • classifierProposalCounts[proposed] += 1
  • stickinessOverrides += (proposed != chosen ? 1 : 0)
```

All telemetry stays on-device. No persistence, no off-device send.

### Voice preamble (model identity earcon)

```
VoiceConversationController.announced(_:)   (first reply of a session only)
  ↓
let model = currentModelDisplayName()   // "Apple", "Sonnet", "GPT", "Gemini", …
  ↓
"Flo here. \(model). " + reply          // "Flo here. " alone when no provider
  // e.g. "Flo here. Sonnet." | "Flo here. Apple." | "Flo here. Gemini."
```

The in-workout voice coach uses "Coach here." instead.

