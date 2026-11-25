# ADR 009 — An accepted session is frozen

**Status.** Accepted.

**Context.** A recovery score is a record of a morning. If opening a past
night, a late Apple Watch sync or a new build could change it silently, the
history would not mean what it says, and trends drawn from it would move under
the user.

**Decision.**
An archived session is **frozen** except for explicit user actions,
the one-shot launch migrations below, the automatic sleep refresh of
today's session, and automatic *additive-merge* paths that fill
in late-arriving HealthKit data without overwriting existing real
values.

**User-initiated changes (may overwrite).**

| Path | Trigger | User action required |
|------|---------|---|
| `reanalyzeSession` | "Reanalyze" button | Yes |
| `retroApplySleepSettings` | HRV-sleep-augmentation toggle | Yes |
| `applyManualAnalysis` | Manual window drag | Yes |
| `updateSessionSleepBoundaries` | Timeline editor Done | Yes |
| `repairTrainingSnapshots` | Settings → Troubleshooting → Advanced Diagnostics on → Repair Training History…; also once at launch through `runTrimpRepairMigrationIfNeeded` (below) | Yes, except the launch run |
| Launch one-shot migrations (`SessionDataMigrations.runAllIfNeeded`) | App launch, each flag-gated so it runs once per install | No, but one-shot. InsufficientData rescores reclassified nights; TrainingRecalibration and TrimpRepair (`didRunTrimpRepairMigration_v1`, only with training-load integration on) rewrite the training snapshot and frozen readiness but not the recovery score; WorkoutSleepCleanup strips sleep snapshots from workouts; NapRepair and TimeInBed recompute scores (`recomputeScoreOnly`). |
| `SessionRecoveryService` recovery fallback | App relaunch detecting an interrupted recording (rare) | No, but only fires when a recording was interrupted mid-flight — recomputes deterministically from the same inputs. |
| CloudKit merge | Sync import | No (import only) |
| Session resume | Resume button | Yes |

**Automatic fill-in paths (fill only what was nil).**

These paths run automatically when Apple Watch syncs late-arriving
samples (overnight RR, SpO2, wrist temp, sleep stages). They never
overwrite a real value with `nil`; they only fill in fields that
were `nil` at acceptance time. The session file is re-archived only
when the merge added at least one non-nil field.

| Path | Trigger | Behavior |
|------|---------|---|
| `RecoveryScoreDetailView` vitals refresh | View open, and each HK vitals observer fire (`MorningCoordination.vitalsDataVersion`) while it is open | Fills `vitalsSnapshot` nil fields with fresh HK values (`RecoveryVitalsBackfill`), scoped to the displayed session. Strap-derived RHR (`session.analysisResult.timeDomain.meanHR`) always wins over HK daytime RHR. This is the only path that writes late vitals to the archive: there is no dashboard refresh, so vitals that arrive after acceptance reach Trends, the Coach context and PDFs only once this screen has been opened for that session. (`VitalsDetailV2View` re-fetches on the same signal for display only and writes nothing.) |
| Frozen `sleepSnapshot` at scoring | Reanalysis / rescore | Any non-nil frozen snapshot is used unchanged, even an empty one (`MorningProcessingService.scoringHealthData`, `RRCollector+Analysis`); HK is fetched only when there is no snapshot. Nothing heals an empty or corrupt snapshot except `autoRefreshTodaysSleepIfImproved`, and only for today's session. |
| `autoRefreshTodaysSleepIfImproved` | `HealthObservation.sleepDataVersion` bump (Apple Watch sleep sync) | Skips entirely when `session.sleepUserAdjusted == true` (user timeline edits are the source of truth, so an HK sleep arrival never puts auto boundaries back over a manual edit). Otherwise, if the fresh HK data passes the improvement gate it rewrites `session.sleepSnapshot` directly and re-archives; if the delta also crosses the rescore threshold (≥ 20 min or first snapshot) it additionally posts `.flowRecoveryRescoreNeeded` for the rescore listener. |
| `installRescoreListener` | `.flowRecoveryRescoreNeeded` notification | Reanalyzes the session via the user-initiated path; new score is captured in `PendingScoreChange` for the dashboard banner. |

**The contract.**

Opening a past session (older than today) produces an identical
`recoveryScore`, `scoreBreakdown`, `frozenReadiness`, and
`trainingSnapshot` across any number of loads (the one-shot launch migrations aside). Today's session is different: every HK sleep bump
that passes `SleepRefreshPolicy.sleepRefreshVerdict` (total moved by
20 min or more, the onset moved, the source upgraded to Watch, or the
first snapshot) posts `.flowRecoveryRescoreNeeded`, with no once-only
guard, so it can be rescored several times while Apple Watch syncs.
The score-changed banner is written only when the displayed score
moves by 3 or more (0.3 on the stored 0–10 scale); smaller changes are
applied without a banner. Merely loading a session never rescores it.
Verified by `SessionImmutabilityTests`.
