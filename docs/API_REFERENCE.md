# Emuqu — API Reference

> **Sleep domain types.** `SleepData`, `SleepStage`,
> `SleepStageInterval`, `SleepStageProvenance`, `SleepSegment`, `HRSleepQuality`,
> `SleepBoundarySource` and `SleepBoundaryValidation` live at top level in
> `Emuqu/Sources/Models/SleepDomain.swift`, so pure functions in `Analysis/`
> don't name the HealthKit I/O class in their signatures.
> `HealthKitManager` keeps a `typealias` for each, so the
> `HealthKitManager.SleepData` spellings below remain correct. Prefer the bare
> name in new code.


> **Observation framework.** Every observable type in
> the app is `@Observable`; none is an `ObservableObject` and nothing is
> `@Published`. `RRCollector`
> itself stores little: most of the state listed under it lives on its five
> sub-objects, and the parent's properties forward to them.

Complete Swift API surface for the Emuqu codebase. Organized by module layer.

> **Conventions**: `@MainActor` types are UI-bound and their members run on the
> main actor. `async` does **not** mean "runs on a background thread" — it means
> the call can suspend. Where work executes is decided by actor isolation, so an
> `async` method on a `@MainActor` type still runs its synchronous body on the
> main actor. Work that is genuinely moved off is done explicitly, with
> `Task.detached` or a `nonisolated` function, and is called out at that API.
> Error-throwing methods use typed errors from `Errors.swift`.

---

## Table of Contents

1. [Data Models](#data-models)
2. [Collection Layer](#collection-layer)
3. [Analysis Pipeline](#analysis-pipeline)
4. [Services](#services)
5. [Storage](#storage)
6. [Import / Export](#import--export)
7. [Protocols](#protocols)
8. [View Models](#view-models)
9. [Views](#views)
10. [Constants](#constants)
11. [AI Assistant](#ai-assistant)

---

## Data Models

### RRPoint
**File**: `Emuqu/Sources/Models/RRModels.swift`

```swift
struct RRPoint: Codable, Equatable {
    let t_ms: Int64           // Cumulative timestamp from session start (ms)
    let rr_ms: Int            // RR interval duration (ms)
    let wallClockMs: Int64?   // Absolute wall-clock timestamp (streaming only)
    let hr: Int?              // Device-reported heart rate (streaming only)

    var endMs: Int64          // t_ms + rr_ms
    var clockDriftMs: Int64?  // Wall-clock vs cumulative gap
    var isPhysiologicallyValid: Bool  // 300-2000ms range check
}
```

### RRSeries
**File**: `Emuqu/Sources/Models/RRModels.swift`

```swift
struct RRSeries: Codable {
    let points: [RRPoint]
    let sessionId: UUID
    let startDate: Date

    // Computed
    var durationMs: Int64
    var durationMinutes: Double
    var hasWallClockTimestamps: Bool
    var wallClockDurationMs: Int64?
    var estimatedDataLossPercent: Double?
    var actualEndDate: Date

    // Methods
    func detectGaps(thresholdMs: Int64 = 2000) -> [(startIndex: Int, endIndex: Int, gapDurationMs: Int64)]
    func absoluteTime(at index: Int) -> Date?
    func absoluteTimeWallClock(at index: Int) -> Date?
    func wallClockTime(forTMs tMs: Int64) -> Date
    func relativeMs(from date: Date) -> Int64
    func indexClosestToWallClock(_ date: Date) -> Int?  // Binary search
}
```

### ArtifactFlags
```swift
struct ArtifactFlags: Codable, Equatable {
    let isArtifact: Bool
    let type: ArtifactType?    // .none, .ectopic, .missed, .extra, .technical;
                               // a type from a newer build decodes as nil
    let confidence: Double     // 0.0 to 1.0
    let corrected: Bool

    static let clean: ArtifactFlags
}

    enum ArtifactType: String, Codable {
        case none, ectopic, missed, extra, technical
    }
}
```

### HRV Metrics

```swift
struct TimeDomainMetrics: Codable {
    let meanRR, sdnn, rmssd, pnn50, sdsd: Double
    let meanHR, sdHR, minHR, maxHR: Double
    let triangularIndex: Double?
}

struct FrequencyDomainMetrics: Codable {
    let vlf: Double?           // Nil if window < 10 min
    let lf, hf: Double
    let lfHfRatio: Double?
    let totalPower: Double
    var lfNu: Double? { get }  // Computed: LF/(LF+HF)*100, nil if sum is 0
    var hfNu: Double? { get }  // Computed: HF/(LF+HF)*100, nil if sum is 0
}

struct NonlinearMetrics: Codable {
    let sd1, sd2, sd1Sd2Ratio: Double
    let sampleEntropy: Double?
    let approxEntropy: Double?
    let dfaAlpha1, dfaAlpha2: Double?
    let dfaAlpha1R2: Double?
}

struct ANSMetrics: Codable {
    let stressIndex: Double?       // Baevsky Stress Index
    let pnsIndex: Double?          // Parasympathetic index (-3 to +3)
    let snsIndex: Double?          // Sympathetic index (-3 to +3)
    let readinessScore: Double?    // Recovery readiness (1-10)
    let respirationRate: Double?   // Breaths per minute
    let nocturnalHRDip: Double?    // % HR drop during sleep
    let daytimeRestingHR: Double?
    let nocturnalMedianHR: Double?
}

struct PeakCapacity: Codable {
    let peakRMSSD, peakSDNN: Double
    let peakTotalPower: Double?
    let windowDurationMinutes: Double
    let windowRelativePosition: Double?
    let windowMeanHR: Double?
}

struct TrainingContext: Codable, Sendable {
    let atl, ctl, tsb: Double      // Acute/Chronic/Balance
    let yesterdayTrimp: Double
    var vo2Max: Double?
    let daysSinceHardWorkout: Int?
    let recentWorkouts: [WorkoutSnapshot]?

    var acuteChronicRatio: Double? { get }  // Computed: ATL / CTL, nil if CTL is 0
    static let empty: TrainingContext
}

struct HRVAnalysisResult: Codable {
    // Window bounds
    let windowStart, windowEnd: Int
    var windowStartMs, windowEndMs: Int64?
    var windowMeanHR, windowHRStability: Double?
    var windowSelectionReason: String?
    var windowRelativePosition: Double?

    // Core metrics
    let timeDomain: TimeDomainMetrics
    let frequencyDomain: FrequencyDomainMetrics?
    let nonlinear: NonlinearMetrics
    let ansMetrics: ANSMetrics?

    // Quality
    let artifactPercentage: Double
    let cleanBeatCount: Int
    let analysisDate: Date

    // Classification
    var isConsolidated, isOrganizedRecovery: Bool?
    var windowClassification: String?
    var peakCapacity: PeakCapacity?
    var trainingContext: TrainingContext?
    var analysisSegmentLabel: String?
    var isReanalysis: Bool?

    // Provenance: `EstimatedMetric` raw values an importer filled without a
    // measurement (nil from the analysis pipeline). Display marks them as
    // estimates; baselines, trends, cause rules, AI context and Apple Health
    // leave them out. `isEstimated(_:)`, `measuredSDNN`, `measuredPNN50`,
    // `measured(_:as:)` and `markingEstimate(_:for:)` read it.
    var estimatedMetrics: [String]?
}

enum EstimatedMetric: String, CaseIterable {
    case sdnn, pnn50, sdsd, sdHR, hrRange, sd1, sd2, sd1Sd2Ratio
}
```

### HRVSession
**File**: `Emuqu/Sources/Models/SessionMetadata.swift` (decoding support in `HRVSession.swift`)

```swift
enum SessionState: String, Codable {
    case collecting, analyzing, complete, paused, failed
}

enum SessionType: String, Codable, CaseIterable {
    case overnight    // Primary daily reading
    case nap          // Nap recording
    case quick        // 2-5 min spot check
    case breathe      // Apple Watch Breathe (SDNN only)
    case workout      // Live workout recorded via the Fitness tab
}

struct HRVSession: Codable, Identifiable, Sendable {
    let id: UUID
    let startDate: Date
    var endDate: Date?
    var state: SessionState
    var sessionType: SessionType

    // Data
    var rrSeries: RRSeries?
    var artifactFlags: [ArtifactFlags]?
    var analysisResult: HRVAnalysisResult?
    var recoveryScore: Double?

    // Metadata
    var tags: [ReadingTag]
    var notes: String?
    var deviceProvenance: DeviceProvenance?
    var importedMetrics: ImportedMetrics?

    // Sleep boundaries (ms relative to recording start)
    var sleepStartMs, sleepEndMs: Int64?
    var sleepSegments: [SleepSegmentMs]?

    // Split sleep / pause-resume
    var linkedSessionIds: [UUID]?
    var pausedDate: Date?

    // Snapshots (frozen at session time)
    var sleepSnapshot: SleepData?
    var sleepUserAdjusted: Bool?
    var vitalsSnapshot: RecoveryVitals?
    var dataSourceSummary: DataSourceSummary?

    var isValidForAnalysis: Bool  // >= 120 beats
    var isResumable: Bool
    var duration: TimeInterval?

    static func recoveryPeriodWindow(for session: HRVSession, allSessions: [HRVSession], sleepSchedule: SleepSchedule, mergeGapSeconds: TimeInterval) -> (start: Date, end: Date)
    static func sleepFetchWindow(for session: HRVSession, allSessions: [HRVSession], sleepSchedule: SleepSchedule, mergeGapSeconds: TimeInterval) -> (start: Date, end: Date)
}
```

### ReadingTag
```swift
struct ReadingTag: Codable, Hashable, Identifiable {
    let id: UUID
    let name: String
    let colorHex: String
    let isSystem: Bool

    // 14 system tags:
    static let morning, postExercise, recovery, evening, preSleep,
               stressed, relaxed, alcohol, poorSleep, travel,
               lateMeal, caffeine, illness, menstrual: ReadingTag
    static let systemTags: [ReadingTag]
}
```

### UserSettings
**File**: `Emuqu/Sources/Models/UserSettings+Model.swift` (enums in `UserSettings.swift`)

```swift
enum FitnessLevel: String, Codable, CaseIterable, Identifiable {
    case sedentary, lightlyActive, moderatelyActive, active, veryActive, athlete
}

enum AppearanceTheme: String, Codable, CaseIterable, Identifiable {
    case light, dim, dark
}

enum ColorTheme: String, Codable, CaseIterable, Identifiable {
    case blue, teal, indigo, purple, rose, orange
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, da, de, es, fi, fr, icelandic = "is", it, ja, ko, nb, nl, ptBR = "pt-BR", ru, sv, zhHans = "zh-Hans", ar

    static var current: AppLanguage   // From UserDefaults "AppleLanguages"
    func apply()                      // Persist to UserDefaults
}

enum SessionMergeMode: String, Codable, CaseIterable, Identifiable {
    case off, defaultGap, custom
}

struct SleepSchedule {
    let bedtimeHour, bedtimeMinute: Int
    let sleepHours: Double

    var wakeHour: Int { get }   // Computed from bedtime + sleepHours
    var wakeMinute: Int { get }

    func overnightWindowStart(relativeTo date: Date) -> Date  // bedtime - 2h
    func overnightWindowEnd(relativeTo date: Date) -> Date    // wake + 4.5h
    func morningCutoff(relativeTo date: Date) -> Date         // wake + 4h
    func daytimeHRStart(relativeTo date: Date) -> Date        // wake + 4h
    func daytimeHREnd(relativeTo date: Date) -> Date          // bedtime - 1h
    func isMorningReading(endDate: Date) -> Bool
    func isInOvernightWindow(_ date: Date) -> Bool
}

struct UserSettings: Codable, Equatable {
    var birthday: Date?
    var fitnessLevel: FitnessLevel?
    var biologicalSex: BiologicalSex?
    var temperatureUnit: TemperatureUnit
    var typicalSleepHours: Double
    var expectedBedtime: Date
    var sessionMergeMode: SessionMergeMode
    var customMergeGapHours: Double
    var sleepSplitGapMinutes: Int
    var defaultWindowSelectionMethod: WindowSelectionMethod
    var enableSleepIntegration: Bool
    var enableHRVSleepAugmentation: Bool
    var penalizeMissingSleep: Bool
    var enableTrainingLoadIntegration: Bool
    var trainingBreakStartDate, trainingBreakEndDate: Date?
    var iCloudSyncEnabled: Bool
    var appearanceTheme: AppearanceTheme
    var colorTheme: ColorTheme
    var enableHealthKitExport: Bool
    var exportSDNN, exportHeartRate, exportRestingHeartRate, exportSleepData: Bool
    // ... additional properties

    var sleepSchedule: SleepSchedule      // Computed
    var age: Int?                         // Computed from birthday
    var isOnTrainingBreak: Bool           // Computed
    var allTags: [ReadingTag]             // System + custom
}

enum WindowSelectionMethod: String, Codable, CaseIterable {
    case consolidatedRecovery   // "Best Recovery (Default)"
    case peakRMSSD              // "Highest RMSSD"
    case peakSDNN               // "Highest SDNN"
    case peakTotalPower         // "Highest Total Power"
    case custom                 // "Choose Your Own Window"
}
```

---

## Collection Layer

### RRCollector (Main Orchestrator)
**File**: `Emuqu/Sources/Collection/RRCollector.swift` + extensions

```swift
@MainActor
@Observable
final class RRCollector {

    // MARK: - Published State

    var recordingPhase: RecordingPhase
    var isCollecting: Bool
    var currentSession: HRVSession?
    var collectedPoints: [RRPoint]
    var lastError: Error?
    var verificationResult: Verification.Result?
    var recoveryWindow: WindowSelector.RecoveryWindow?
    var needsAcceptance: Bool
    var baselineDeviation: BaselineTracker.BaselineDeviation?
    var isStreamingMode: Bool
    var streamingTargetSeconds: Int
    var streamingElapsedSeconds: Int
    var isOvernightStreaming: Bool
    var isPaused: Bool
    var pausedSession: HRVSession?
    var morningStatus: MorningProcessingStatus?
    var sleepDataVersion: Int
    var archiveVersion: Int
    var fetchProgress: PolarManager.FetchProgress?

    // MARK: - Hybrid Overnight Recording

    func startOvernightStreaming(sessionType: SessionType = .overnight) throws
    func stopOvernightStreaming() async -> HRVSession?

    // MARK: - Pause & Resume (Split Sleep)

    /// Pause an in-progress overnight streaming session. Persists a paused
    /// `HRVSession` to the archive and stops streaming. Returns the persisted
    /// paused session, or nil if there was nothing to pause.
    func pauseOvernightStreaming() async -> HRVSession?

    /// Resume the paused session identified by `linkedSessionId`. The new
    /// segment is linked back to the paused session for combined analysis;
    /// the parent's link is written into the archive's copy in place.
    /// Throws `alreadyRecording` while a night is still being ended
    /// (`refuseWhileEndingInProgress()`), as `startOvernightStreaming` does.
    func resumeOvernightStreaming(linkedSessionId: UUID) throws

    /// Finalize a paused session without resuming (treat the paused segment
    /// as the final session). Marks the archive's copy complete in place
    /// (`archive.update`), publishes that copy and requests a re-upload.
    func finalizeFromPause()

    /// Look up a recently paused session in the archive within `maxGap`
    /// seconds. Off-main static helper; safe to call from background tasks.
    /// A paused session an archived segment was resumed from is not returned.
    nonisolated static func findRecentPausedSessionOffMain(
        archive: SessionArchive,
        maxGap: TimeInterval
    ) -> HRVSession?

    // MARK: - Quick Streaming

    /// Throws `alreadyRecording` while a night is paused or being ended
    /// (`requireConnectedWithNoNightHeld`), like the strap-only `startSession`.
    func startStreamingSession(durationSeconds: Int = 180) throws
    func stopStreamingSession() async -> HRVSession?

    // MARK: - Device-Only Recording

    func startSession(sessionType: SessionType = .overnight) async throws
    func stopSession() async throws -> HRVSession?
    func retryFetchRecording() async throws -> HRVSession?
    func recoverFromDevice() async throws -> HRVSession?

    // MARK: - Session Management

    func acceptSession() async throws
    func rejectSession() async
    func resetSession()
    func notifyArchiveChanged()
    /// Carries a rescored night (`.reanalysisRewroteArchivedSession`) onto the review card.
    func adoptArchivedCopy(_ archived: HRVSession)

    // MARK: - Session Loading

    func recentSessionsAsync(limit: Int?) async -> [HRVSession] // nil = all
    func retrieveFullSessionAsync(_ id: UUID) async -> HRVSession?

    // MARK: - Import

    func saveImportedSession(_ session: HRVSession) async throws
    func saveImportedSessionsBatch(_ sessions: [HRVSession]) async throws -> Int

    // MARK: - Backup Recovery

    func checkForLostSessions() async -> [(id: UUID, date: Date, beatCount: Int)]
    /// `recordedType`: the type the interrupted session was recording; a
    /// non-overnight type is kept (the gate only downgrades a short night).
    func recoverFromBackup(_ sessionId: UUID, recordedType: SessionType? = nil) async -> HRVSession?
    @discardableResult
    func deleteLostSessions(_ sessionIds: [UUID]) -> Set<UUID>   // the ids whose mark was stored
    func restoreFromTrash(_ id: UUID) async -> HRVSession?
    @discardableResult
    func permanentlyDelete(_ ids: [UUID]) async -> TrashDeletionOutcome

    // MARK: - Training Context (forwarded to `scoring: SessionScoringContext`)

    /// The training load as of `referenceDate`: today's cached load, or a
    /// past day's load held for a reanalysis of that day.
    func createTrainingContext(relativeTo referenceDate: Date = Date()) -> TrainingContext?
    /// Fetches the load from HealthKit when none is held.
    func createTrainingContextEnsuringFresh(relativeTo referenceDate: Date = Date()) async -> TrainingContext?
}
```

### SessionReanalysisCoordinator
**File**: `Emuqu/Sources/Collection/SessionReanalysisCoordinator.swift` (listeners in `+Listeners`)

Built once by the composition root (`AppDependencies.collection.sessionReanalysis`,
`AppDependencies.makeSessionReanalysis(_:)`); never reaches `RRCollector`.

```swift
@MainActor
final class SessionReanalysisCoordinator {
    let service: ReanalysisService

    init(service: ReanalysisService, archive: SessionArchive, healthKit: HealthKitManager,
         scoring: SessionScoringContext, archiveSignal: ArchiveSignal,
         trainingMetricsCache: @escaping @MainActor () -> TrainingMetricsCache)  // resolved on first warm

    /// Rescore request, CloudKit snapshot backfill and HealthKit sleep listeners.
    func startListening()
    /// In-flight guard, past-day training load, warm metrics cache.
    func reanalyzeSession(_ session: HRVSession, method: WindowSelectionMethod = .consolidatedRecovery) async -> HRVSession?
    func reanalyzeAllSessions(from: Date? = nil, to: Date? = nil,
                              progress: @escaping (Int, Int) -> Void = { _, _ in }) async -> (updated: Int, skipped: Int)
    func retroApplySleepSettings(progress: @escaping (Int, Int) -> Void = { _, _ in }) async -> Int
    func repairTrainingSnapshots(progress: @escaping (Int, Int) -> Void = { _, _ in }) async -> ReanalysisService.TrainingRepairResult
    func runDeferredSessionMigrationsIfNeeded() async
    func autoRefreshTodaysSleepIfImproved() async
}
```

### RecordingPhase
**File**: `Emuqu/Sources/Collection/RecordingPhase.swift`

```swift
enum RecordingPhase: Equatable, CustomStringConvertible {
    case idle
    case streaming(targetSeconds: Int)
    case overnightStreaming
    case deviceRecording
    case paused(sessionId: UUID)
    case analyzing
    case awaitingAcceptance

    var description: String     // Human-readable phase name
}
```

### PolarManager
**File**: `Emuqu/Sources/Collection/PolarManager.swift`

```swift
@Observable
@MainActor
final class PolarManager: NSObject {

    // Connection
    var connectionState: ConnectionState
    var connectedDeviceId: String?
    var connectedDeviceType: PolarDeviceType?
    var discoveredDevices: [DiscoveredDevice]
    var knownDevices: [KnownDevice]
    var batteryLevel: Int?
    var firmwareVersion: String?
    var lastConnectedTime: Date?
    var lastError: Error?
    var readiness: StrapReadiness              // per-link feature readiness
    var feedStatus: StrapFeedHealth.Status     // waitingForStrap / settingUp / live / stalled
    var connectionHealthWarning: Bool { get }  // feedStatus == .stalled
    var link: StrapLinkCoordinator { get }     // events, readiness waits, reconnection

    // Recording
    var recordingState: RecordingState
    var isRecordingOnDevice: Bool
    var isH10RecordingFeatureReady: Bool { get }
    var isHrStreamingReady: Bool { get }
    var hasStoredExercise: Bool
    var storedExerciseDate: Date?
    var fetchProgress: FetchProgress?

    // Streaming
    var isStreaming: Bool
    var streamingElapsedSeconds: Int
    var streamedRRCount: Int
    var recentRRPoints: [RRPoint]    // Recent window for live display
    var currentHeartRate: Int?
    var streamingReconnectCount: Int
    var reconnectExhausted: Bool
    var streamedRRPoints: [RRPoint] { get }    // Full buffer

    // Methods
    func startScanning()
    func connect(deviceId: String)
    func connectToLastDevice()
    func cancelConnection()
    func disconnect()
    func startRecording() async throws
    func fetchRecording(recordedSince: Date?, budget: StrapRecordingPolicy.TransferBudget) async throws -> StrapRecording
    func fetchRecordingIfAvailable(recordedSince: Date?) async -> StrapRecording?
    func reconnectForTransfer() async -> Bool
    func beginTransfer()
    func stopDeviceRecordingIfNeeded(streamHoldsIt: Bool) async
    func cancelFetch()
    func startStreaming() throws
    func stopStreaming() -> [RRPoint]
    func checkForStoredExercises(deviceId: String?) async
}

enum PolarDeviceType: String, Codable {
    case h10            // ECG chest strap
    case veritySense    // Optical PPG sensor
}

// Nested in PolarManager (PolarManager.ConnectionState, PolarManager.RecordingState):
extension PolarManager {
    enum ConnectionState: Equatable {
        case disconnected, scanning, connecting, connected
    }

    enum RecordingState: Equatable {
        case idle, starting, recording, stopping, fetching
    }
}
```

### HealthKit write-back identity and observers
**Files**: `Emuqu/Sources/Collection/HealthExportIdentity.swift`, `HealthWriteAndObserve.swift`, `HealthKitWorkoutExport.swift`

```swift
enum HealthExportIdentity {
    enum Metric: String, CaseIterable { case heartRate, restingHeartRate, sdnn, rmssd, sleep, workout }
    /// HKMetadataKeyExternalUUID and HKMetadataKeySyncIdentifier set to the
    /// session identity, plus HKMetadataKeySyncVersion = `version`.
    static func metadata(_ externalUUID: String, version: Int, _ extra: [String: Any] = [:]) -> [String: Any]
    static func nextSyncVersion(now: Date = Date()) -> Int   // rises on every export
    static func syncIdentifier(of object: HKObject) -> String?
}

struct HealthWriteAndObserve {
    /// Delete forever: HRV, heart rate, resting HR, sleep and workouts the
    /// session exported. Every removal is tried; the first error is thrown.
    func removeExports(sessionId: UUID, from start: Date, to end: Date) async throws
}

struct HealthSampleReplacement {
    var writeTimeout: TimeInterval?   // save/delete bound; nil uses the read timeout
}

final class HealthSampleReplacer {
    /// Saves `samples`, then deletes the session's earlier ones that a save
    /// did not already replace by sync identifier (`notReplacedBySync`).
    func replace(_ samples: [HKSample], _ replacement: HealthSampleReplacement) async throws
}

enum HealthSampleWatch {
    /// HKObserverQuery whose every fire reads what was added since an anchor
    /// stored under `anchorKey` across launches (two days without one) and
    /// hands `deliver` the other sources' samples; the app's own are dropped.
    /// One read runs per anchor key at a time (ReadGate): a fire during a read
    /// has it run once more when it ends, from the anchor it kept.
    static func observerQuery(for type: HKSampleType, anchorKey: String, store: HKHealthStore,
                              deliver: @escaping @Sendable ([HKSample]) -> Void) -> HKObserverQuery
}
```

`HealthKitWorkoutExport` finds a session's earlier workouts (its
`<uuid>-workout` identity, or an identity-less workout starting in the same
second), saves the new workout, then deletes the earlier ones with their
samples and route; a failure throws so the session stays unstamped. Active
energy is written net of resting metabolism (`netMETs`: METs − 1, floored at 0).
When the earlier exports cannot be read because the phone is locked
(`EarlierExport.findUnlessLocked`), the workout is saved and the session
noted in `PendingWorkoutReplacements` (`note`, `finish(in:)`, `clear`); the
next `HealthKitManager.backfillWorkoutsToHealthKit` deletes all but the newest
copy first. The export stamp is written by
`HealthKitManager.writeExportStamp(_:at:archive:)` with
`requestingReupload: false`.

---

## Analysis Pipeline

### HRVAnalysisPipeline
**File**: `Emuqu/Sources/Analysis/HRVAnalysisPipeline.swift`

```swift
final class HRVAnalysisPipeline {

    struct ANSConfiguration {
        let baselineRMSSD: Double
        let vo2Max: Double?
        let trainingLoadAdjustment: Double
    }

    init(
        artifactDetector: ArtifactDetector,
        windowSelector: WindowSelector,
        healthKit: HealthKitServiceProtocol
    )

    /// Analyze session within a specific recovery window (primary overnight path).
    func analyzeWithWindow(
        session: HRVSession,
        window: WindowSelector.RecoveryWindow,
        flags: [ArtifactFlags],
        peakCapacity: PeakCapacity?,
        trainingContext: TrainingContext?,
        ansConfig: ANSConfiguration
    ) async -> HRVAnalysisResult?

    /// Analyze full session when no organized recovery window detected.
    func analyzeFullSession(
        session: HRVSession,
        peakCapacity: PeakCapacity?,
        trainingContext: TrainingContext?,
        ansConfig: ANSConfiguration
    ) async -> HRVAnalysisResult?

    /// Fallback: analyze session with automatic window selection and optional HealthKit boundaries.
    func analyzeWithAutoWindow(
        session: HRVSession,
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?,
        trainingContext: TrainingContext?,
        ansConfig: ANSConfiguration
    ) async -> HRVAnalysisResult?

    /// Analyze full series without window selection (streaming mode). NOT async.
    func analyzeFullSeries(
        series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int = 0,
        windowEnd: Int? = nil,
        trainingContext: TrainingContext? = nil,
        ansConfig: ANSConfiguration? = nil
    ) -> HRVAnalysisResult?

    /// Analyze full series with peak capacity metadata (overnight streaming without organized recovery).
    func analyzeFullSeriesWithCapacity(
        series: RRSeries,
        flags: [ArtifactFlags],
        peakCapacity: PeakCapacity,
        trainingContext: TrainingContext?,
        ansConfig: ANSConfiguration? = nil
    ) -> HRVAnalysisResult?

    /// Reanalyze at a specific position (manual window selection from graph interaction).
    func reanalyzeAtPosition(
        session: HRVSession,
        targetMs: Int64,
        trainingContext: TrainingContext?,
        ansConfig: ANSConfiguration
    ) async -> HRVAnalysisResult?

    // Pure computation helpers
    static func nocturnalMedianHR(from cleanRRs: [Double]) -> Double?
    static func nocturnalHRDip(daytimeHR: Double, nocturnalMedian: Double) -> Double?
    static func extractCleanRRs(
        series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int
    ) -> [Double]
}
```

### SleepBoundaryResolver
**File**: `Emuqu/Sources/Analysis/SleepBoundaryResolver.swift`

```swift
final class SleepBoundaryResolver {

    struct SleepBoundaries {
        let sleepStartMs: Int64?
        let wakeTimeMs: Int64?
    }

    init(healthKit: HealthKitServiceProtocol)

    func resolve(
        sessionStart: Date,
        recordingEnd: Date,
        rrPoints: [RRPoint]? = nil,
        useHREstimation: Bool = false
    ) async -> SleepBoundaries

    static func clamp(
        sleepStartMs: Int64?,
        sleepEndMs: Int64?,
        recordingDurationMs: Int64
    ) -> (sleepStartMs: Int64?, sleepEndMs: Int64?)

    static func detectSleepOnset(in rrPoints: [RRPoint]) -> Int64?

    /// HR may move onset earlier (later only without detailed HealthKit
    /// stages) and may only extend wake, never shorten it.
    static func validateBoundaries(
        healthKit: SleepBoundaries,
        hrEstimate: SleepBoundaries,
        hasDetailedStages: Bool = false
    ) -> SleepBoundaries
}
```

### Watch / HR-based sleep estimation
**File**: `Emuqu/Sources/Collection/HealthKitManager+Sleep.swift`

There is **no** `WatchSleepDetector` type or ECDF/percentile method (an earlier
revision of this doc described one that was never implemented). Sleep is
estimated from heart rate by two sibling heuristics that share the same
adaptive-threshold logic (threshold = midpoint of the window's HR range,
smoothing, consecutive-window onset, last-continuous-block wake). See
[`ARCHITECTURE.md` → HR-Estimated Sleep](ARCHITECTURE.md#hr-estimated-sleep-fallback-not-extension).

```swift
extension HealthKitManager {
    /// Estimate sleep from Apple Watch *passive* background HR samples
    /// (~1 every 10 min) when no native HealthKit sleep data exists.
    /// Heuristic based on the overnight HR drop — not PSG-validated.
    func estimateSleepFromHealthKitHR(
        windowStart: Date,
        windowEnd: Date,
        minimumSamples: Int = 12,      // extended-sleep callers pass 4
        minimumSleepMinutes: Int = 120
    ) async -> SleepData?

    /// Estimate sleep from the recording's own RR series (chest-strap path).
    static func estimateSleepFromHR(rrPoints: [RRPoint], recordingStart: Date) -> SleepData?
}
```

### ArtifactDetector
**File**: `Emuqu/Sources/Analysis/ArtifactDetection.swift`

```swift
final class ArtifactDetector: Sendable {
    struct Config {
        var windowSize: Int = HRVConstants.Artifacts.windowSize  // 50
        var ectopicThreshold: Double = 0.20
        var missedThreshold: Double = 0.50
        var extraThreshold: Double = 0.50
        var minRR: Int = HRVConstants.RRInterval.minimum         // 300
        var maxRR: Int = HRVConstants.RRInterval.maximum         // 2000
    }

    init(config: Config = .default)

    func detectArtifacts(in series: RRSeries) -> [ArtifactFlags]
    func artifactPercentage(_ flags: [ArtifactFlags], start: Int, end: Int) -> Double
}

```

### WindowSelector
**File**: `Emuqu/Sources/Analysis/WindowSelection.swift` + `WindowSelection+Scoring.swift` + `WindowSelection+Evaluation.swift` + `WindowSelection+Filters.swift`

Extension files split out window logic:
- **`WindowSelection+Scoring.swift`** -- `findBestWindow`, `findBestWindowWithCapacity`, `selectWindowByMethod` and `analyzeAtPosition`.
- **`WindowSelection+Evaluation.swift`** -- window evaluation and scanning logic (candidate scoring, consolidated recovery detection).
- **`WindowSelection+Filters.swift`** -- spike filtering and artifact threshold logic for candidate windows.

```swift
final class WindowSelector: Sendable {
    func findBestWindow(
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64? = nil,
        wakeTimeMs: Int64? = nil,
        baselineStats: BaselineTracker.RecoveryBaselineStats? = nil
    ) -> RecoveryWindow?

    func findBestWindowWithCapacity(
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64? = nil,
        wakeTimeMs: Int64? = nil,
        baselineStats: BaselineTracker.RecoveryBaselineStats? = nil
    ) -> WindowSelectionResult?

    func selectWindowByMethod(
        _ method: WindowSelectionMethod,
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64? = nil,
        wakeTimeMs: Int64? = nil
    ) -> RecoveryWindow?

    func analyzeAtPosition(
        in series: RRSeries,
        flags: [ArtifactFlags],
        targetMs: Int64
    ) -> RecoveryWindow?

    struct WindowSelectionResult {
        let recoveryWindow: RecoveryWindow?
        let peakCapacity: PeakCapacity?
    }
}
```

### TimeDomainAnalyzer
**File**: `Emuqu/Sources/Analysis/TimeDomainAnalysis.swift`

```swift
enum TimeDomainAnalyzer {
    static func computeTimeDomain(
        _ series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int
    ) -> TimeDomainMetrics?
    // Requires >= 10 clean RR intervals
}
```

### FrequencyDomainAnalyzer
**File**: `Emuqu/Sources/Analysis/FrequencyDomainAnalysis.swift`

```swift
enum FrequencyDomainAnalyzer {
    static func computeFrequencyDomain(
        _ series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int
    ) -> FrequencyDomainMetrics?
    // Welch method: 256-sample segments (LF/HF; 1024 for VLF), linear detrend, 50% overlap, Hann window, 4 Hz resampling
    // VLF requires >= 10 min window (2x minimum)

    /// Compute from pre-cleaned (time, RR) pairs — used by HRVSleepStageClassifier
    static func computeFromCleanPairs(times: [Double], rrValues: [Double]) -> FrequencyDomainMetrics?

    /// Direct PSD computation from uniformly sampled signal
    static func computePSD(
        signal: [Double],
        fs: Double,
        segmentLength: Int? = nil,
        usableWindowMin: Double? = nil
    ) -> FrequencyDomainMetrics

    /// Cache management for DFT setups
    static func getDFTSetup(size: Int) -> OpaquePointer?
    static func teardownDFTCache()
}
```

### NonlinearAnalyzer
**File**: `Emuqu/Sources/Analysis/NonlinearAnalysis.swift`

```swift
enum NonlinearAnalyzer {
    static func computeNonlinear(
        _ series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int
    ) -> NonlinearMetrics?
    // Poincaré SD1/SD2, Sample Entropy (m=2, r=0.2*SD), Approximate Entropy, DFA
}
```

None of the four treats a removed (artifact) beat or a recording break as
adjacency. SD1 = √(½·Var) of the time domain's successive differences
(`TimeDomainAnalyzer.successiveDifferences(in:)`: originally adjacent clean
beats, no break between them, same ectopic gate), so SD1 tracks SDSD/√2; SD2
keeps Brennan's identity with the variance of all clean beats. Entropy
templates lie inside runs of neighbouring beats. DFA interpolates removed
beats and splits at breaks (`DFAAnalyzer.compute(window:)`). Both take the
window from `TimeDomainAnalyzer.cleanWindow`, which returns a
`CleanBeatWindow` (clean beats, their series indices, the breaks). Nil when
fewer than 10 clean beats or no adjacent clean pair. A window with no removed
beat and no break gives the single-series values.

### DFAAnalyzer
**File**: `Emuqu/Sources/Analysis/DFAAnalysis.swift`

```swift
enum DFAAnalyzer {

    struct DFAResult {
        let alpha1: Double       // Short-term (4-16 beats)
        let alpha2: Double?      // Long-term (16-64 beats)
        let alpha1R2: Double     // R² fit quality for α1
        let alpha2R2: Double?    // R² fit quality for α2
    }

    static func compute(
        _ rr: [Double],
        alpha1Range: ClosedRange<Int> = HRVConstants.DFA.alpha1ScaleMin...HRVConstants.DFA.alpha1ScaleMax,
        alpha2Range: ClosedRange<Int> = HRVConstants.DFA.alpha2ScaleMin...HRVConstants.DFA.alpha2ScaleMax
    ) -> DFAResult?
    // Requires >= alpha2ScaleMax (64) beats
    // Log-spaced box sizes per Peng et al. 1995

    static func compute(window: CleanBeatWindow) -> DFAResult?
    // compute(segments: interpolatedSegments(window))

    static func compute(
        segments: [[Double]],
        alpha1Range: ClosedRange<Int> = ..., alpha2Range: ClosedRange<Int> = ...
    ) -> DFAResult?
    // One profile over all segments; no box spans two. Boxes up to 1/4 of
    // the longest segment. One segment == compute(_:).

    static func interpolatedSegments(_ window: CleanBeatWindow) -> [[Double]]
    // Split at recording breaks; removed beats inside a segment linearly
    // interpolated (Kubios; Lipponen & Tarvainen 2019); none extrapolated.
}
```

### StressAnalyzer
**File**: `Emuqu/Sources/Analysis/StressAnalysis.swift`

```swift
enum StressAnalyzer {
    static func computeStressIndex(_ rr: [Double]) -> Double?
    static func computePNSIndex(meanRR: Double, rmssd: Double, sd1: Double) -> Double
    static func computeSNSIndex(meanHR: Double, stressIndex: Double, sd2: Double) -> Double
    static func computeReadinessScore(
        rmssd: Double,
        baselineRMSSD: Double?,
        alpha1: Double?,
        pnsIndex: Double? = nil,
        snsIndex: Double? = nil,
        trainingLoadAdjustment: Double = 0,
        vo2Max: Double? = nil
    ) -> Double   // 1-10 scale
}
```

### RespirationAnalyzer
**File**: `Emuqu/Sources/Analysis/RespirationAnalysis.swift`

```swift
enum RespirationAnalyzer {
    /// Spectral: FFT HF peak at 4 Hz resampling
    static func estimateRespirationRate(_ rr: [Double], fs: Double = 4.0) -> Double?
    // Requires >= 60 RR intervals and an HF peak that is breathing, not noise or leakage
    // (isBreathingPeak); nil otherwise. Sanity check: 6-40 breaths/min
}
```

### RecoveryScoreCalculator
**File**: `Emuqu/Sources/Analysis/RecoveryScoreCalculator.swift` + extensions (`+Composite`, `+Tiers`, `+Training`, `+ReadinessForwarding`, `+VitalsForwarding`, `+DetailForwarding`)

```swift
enum RecoveryScoreCalculator {

    /// The recovery score composite is HRV+Sleep+Vitals
    /// (60/25/15). Training load is not in the composite. The
    /// `trainingMetrics` / `trainingContext` parameters stay on the
    /// API surface for caller stability but are not consumed by the
    /// score itself — they're routed through the parallel Load &
    /// Trajectory surface. See `ScoringWeights` doc-comment in
    /// `Constants.swift` for the rationale (Impellizzeri 2020/2021,
    /// Doherty/Altini 2025).
    struct ScoringConfiguration {
        let enableTrainingLoadIntegration: Bool
        let isOnTrainingBreak: Bool
        let enableSleepIntegration: Bool
        let penalizeMissingSleep: Bool
        let userAge: Int?
        /// True when the user is in the 21-day Comeback window (toggled
        /// in Settings → Modes → Comeback mode). Activates HRV 80% / Sleep 20% /
        /// Vitals 0% weighting in place of the standard 60/25/15.
        let isComebackModeActive: Bool

        init(from settings: UserSettings)
        init(enableTrainingLoadIntegration: Bool, isOnTrainingBreak: Bool,
             enableSleepIntegration: Bool, penalizeMissingSleep: Bool,
             userAge: Int?, isComebackModeActive: Bool = false)
    }

    struct ScoreBreakdown {
        let compositeScore: Double    // 0-100
        let tier: Int                 // 1 (HRV only), 2 (HRV+Sleep), 3 (HRV+Sleep+Vitals)
        let factors: [ScoreFactor]    // Labels: "HRV", "Sleep", "Vitals"
        let penalties: [String]       // Only SpO2 (-10 if <95%); RR and temperature
                                      // feed the Vitals sub-score instead.
        var scoringVersion: String    // ScoringVersion.current ("v3.3.nov2026") when built;
                                      // "unversioned" when decoded from an older record
        var refreshedFactorShift: Double  // not stored: how far a display-time vitals refresh
                                          // (VitalsScoring.breakdownRefreshingVitalsFactor) moved
                                          // the factors' weighted sum; taken back out of the
                                          // factor/composite gap the advice reads
        var message: String { get }   // Computed: factor-aware coaching advice
    }

    struct ScoreFactor: Identifiable {
        let label: String
        let detail: String
        let score: Double       // 0-100 sub-score
        let weight: Double      // 0-1 weight in composite
        let impact: Impact
        enum Impact: String, Codable { case positive, neutral, negative }
        // An impact a newer build added decodes as .neutral instead of failing the breakdown.
    }

    /// Versioned parameter snapshot for the SWC band model. Bump version
    /// when bands change so analytics / breakdowns can disambiguate.
    /// `defaultScoringParameters` points at `scoringParametersV2`.
    struct ScoringParameters: Equatable {
        let version: String
        let zScoreBands: [(z: Double, score: Double)]
    }
    static let scoringParametersV1: ScoringParameters
    static let scoringParametersV2: ScoringParameters
    static let defaultScoringParameters: ScoringParameters   // = scoringParametersV2

    /// The night's readings, gathered once for both overloads.
    struct ScoreInputs {
        let hrvReadiness: Double?
        let rmssd: Double?
        let meanHR: Double?
        let dfaAlpha1: Double?
        let baselineStats: BaselineTracker.RecoveryBaselineStats?
        let sleepData: SleepData?
        let vitals: RecoveryVitals?
        let typicalSleepHours: Double
    }

    /// Score signature for both overloads. `trainingMetrics` /
    /// `trainingContext` are accepted for API stability and so callers
    /// keep passing the same value, but do not feed the recovery
    /// composite. See ScoringWeights doc-comment for rationale.
    static func calculateWithBreakdown(
        _ inputs: ScoreInputs,
        trainingMetrics: HealthKitManager.TrainingMetrics?,  // unused for score; routed to Surface 2
        config: ScoringConfiguration,
        ansBalance: Double? = nil,
        referenceDate: Date = Date()
    ) -> ScoreBreakdown

    /// Convenience overload using TrainingContext (frozen snapshot, no daily TRIMP).
    /// `useBaselineHRV`: when true, substitutes baseline RMSSD for session RMSSD (used when
    /// HRV data quality is `.preSleep` or `.insufficient`).
    /// `perceivedReadiness`: user-reported readiness (0-1, clamped) from SubjectiveReadinessCard,
    /// blended at 30% weight with the 70% baseline HRV factor.
    static func calculateWithBreakdown(
        _ inputs: ScoreInputs,
        trainingContext: TrainingContext?,                    // unused for score
        config: ScoringConfiguration,
        useBaselineHRV: Bool = false,
        perceivedReadiness: Double? = nil,
        ansBalance: Double? = nil,
        referenceDate: Date = Date()
    ) -> ScoreBreakdown

    /// The 0–100 Vitals sub-score that feeds the
    /// composite at 15% weight. Returns nil when no vitals input is
    /// available — the caller falls back to Tier 2.
    static func calculateVitalsScore(
        vitals: HealthKitManager.RecoveryVitals?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?
    ) -> Double?

    /// Map z-score to 0–100 recovery score using SWC band model.
    /// `parameters` defaults to `defaultScoringParameters` (= `scoringParametersV2`).
    static func zToRecoveryScore(
        _ z: Double,
        parameters: ScoringParameters = defaultScoringParameters
    ) -> Double

    // Individual tier calculations.
    // Without baseline stats (< 3 nights) a reading with RMSSD is scored on the
    // absolute RMSSD bands; `readiness` (1-10 → 10-100) is used only for a night
    // with no usable RMSSD, and 50 when that is nil too.
    static func calculateTier1(
        rmssd: Double,
        meanHR: Double?,
        dfaAlpha1: Double?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        readiness: Double?
    ) -> Double  // 0-100

    static func calculateSleepScore(
        sleepData: HealthKitManager.SleepData?,
        typicalSleepHours: Double,
        userAge: Int?
    ) -> Double?  // 0-100, nil if no sleep data

    static func fosterMonotonyStrain(
        dailyTrimp: [Date: Double]
    ) -> (monotony: Double, strain: Double)?

    static func zToPercentileScore(_ z: Double) -> Double  // Normal CDF mapping
}
```

### ReadinessScoring
**File**: `Emuqu/Sources/Analysis/ReadinessScoring.swift`

Training readiness: capacity to absorb additional load, independent of recovery score. Uses a Banister fitness-fatigue model with acute fatigue decay, capacity ratio mapping, ACWR spike detection, and confidence-weighted fallback for sparse data.

```swift
extension RecoveryScoreCalculator {

    struct WorkoutLoad {
        let hoursAgo: Double
        let trimp: Double
    }

    /// Training readiness score (0-100) based on fitness-fatigue dynamics.
    static func calculateReadiness(
        recoveryScore: Double,
        todayTrimp: Double,
        ctl: Double,
        atl: Double = 0,
        morningATL: Double? = nil,
        acuteChronicRatio: Double? = nil,
        recentWorkoutLoads: [WorkoutLoad]? = nil
    ) -> Double

    static func readinessLabel(for score: Double) -> String   // "Ready" / "Moderate" / "Fatigued" / "Rest"
}

extension ReadinessScoring {
    static func readinessMessage(for rawReadiness: Double, load: TrainingAdviceGate.Load?) -> String
}
```

### VitalsScoring
**File**: `Emuqu/Sources/Analysis/VitalsScoring.swift`

Penalty-only vitals overrides (respiratory rate, wrist temperature, SpO2) and display helpers.

```swift
extension RecoveryScoreCalculator {

    /// Apply the SpO2 post-composite penalty only (-10 if SpO2 < 95%). RHR,
    /// respiratory rate and wrist temperature do not deduct here; they feed the 15% Vitals sub-score via
    /// `calculateVitalsScore`. SpO2 stays a flag-not-factor override. Returns
    /// adjusted score, min 0.
    static func applyVitalsOverrides(score: Double, vitals: HealthKitManager.RecoveryVitals?) -> Double

    /// Human-readable penalty descriptions for breakdown display (no score mutation).
    static func vitalsPenaltyDescriptions(_ vitals: HealthKitManager.RecoveryVitals?) -> [String]

    // Also contains: calculate() convenience overloads, label(for:), message(for:), toTenScale(_:)
}
```

### HRVSleepStageClassifier
**File**: `Emuqu/Sources/Analysis/HRVSleepStageClassifier.swift`

```swift
enum HRVSleepStageClassifier {

    struct ClassificationResult {
        let stageIntervals: [HealthKitManager.SleepStageInterval]
        let deepSleepMinutes: Int
        let remSleepMinutes: Int
        let coreSleepMinutes: Int
        let awakeMinutes: Int
    }

    struct AugmentationResult {
        let stageIntervals: [HealthKitManager.SleepStageInterval]
        let deepSleepMinutes: Int
        let remSleepMinutes: Int
        let coreSleepMinutes: Int
        let awakeMinutes: Int
        let augmentationCount: Int
        let augmentations: [Augmentation]
    }

    /// Classify sleep stages from RR data alone (no Apple Watch)
    static func classify(
        rrPoints: [RRPoint],
        sleepStartMs: Int64,
        sleepEndMs: Int64,
        recordingStart: Date
    ) -> ClassificationResult?

    /// Augment Apple Watch sleep stages using HRV evidence
    static func augment(
        watchIntervals: [HealthKitManager.SleepStageInterval],
        rrPoints: [RRPoint],
        sleepStartMs: Int64,
        sleepEndMs: Int64,
        recordingStart: Date
    ) -> AugmentationResult?
}
```

### SleepScienceAnalyzer
**File**: `Emuqu/Sources/Analysis/SleepScienceAnalyzer.swift`

```swift
struct SleepScienceAnalyzer {
    struct SleepAnalysis {
        let fragmentationIndex: Double    // 0-100
        let awakeningCount: Int
        let sleepCycles: [SleepCycle]
        let cycleCount: Int
        let architecture: SleepArchitecture
        let ageNorms: AgeAdjustedNorms?
        let enhancedScore: Double         // 0-100
    }

    static func analyze(
        sleepData: HealthKitManager.SleepData,
        userAge: Int?,
        typicalSleepHours: Double
    ) -> SleepAnalysis?

    static func computeFragmentation(
        intervals: [HealthKitManager.SleepStageInterval],
        totalSleepMinutes: Int,
        awakeMinutes: Int
    ) -> (index: Double, awakeningCount: Int)

    static func detectSleepCycles(
        intervals: [HealthKitManager.SleepStageInterval]
    ) -> [SleepCycle]

    static func analyzeArchitecture(
        intervals: [HealthKitManager.SleepStageInterval],
        sleepData: HealthKitManager.SleepData
    ) -> SleepArchitecture

    static func computeAgeNorms(
        age: Int,
        deepPercent: Double,
        remPercent: Double,
        efficiency: Double
    ) -> AgeAdjustedNorms
}
```

### AnalysisSummaryGenerator
**File**: `Emuqu/Sources/Analysis/AnalysisSummaryGenerator.swift`

```swift
final class AnalysisSummaryGenerator {

    struct AnalysisSummary {
        let analysisTitle: String            // the Recovery Score's ScoreVerdict word
        let diagnosticIcon: String
        let diagnosticScore: Double          // 0-100
        let headlineScore: Double
        let analysisExplanation: String
        let probableCauses: [ProbableCause]
        let keyFindings: [String]
        let actionableSteps: [String]
        let trendInsight: String             // Non-optional
    }

    struct ProbableCause {
        let cause: String
        let confidence: String
        let explanation: String
    }

    init(result: HRVAnalysisResult,
         session: HRVSession,
         recentSessions: [HRVSession] = [],
         selectedTags: Set<ReadingTag> = [],
         sleep: AnalysisSleepInput = .empty,
         sleepTrend: AnalysisSleepTrendInput? = nil,
         trainingContext: TrainingContext? = nil,
         userAge: Int? = nil,
         biologicalSex: UserSettings.BiologicalSex? = nil,
         currentReadiness: Double? = nil,
         todayTrimp: Double = 0,
         liveLoadSnapshot: TrainingLoadRegistry.TrainingLoad? = nil,
         canonicalBaselineRMSSD: Double? = nil,
         canonicalBaselineHR: Double? = nil,
         referenceDate: Date = Date())

    func generate() -> AnalysisSummary
}
```

Sleep inputs are top-level types in `Emuqu/Sources/Analysis/AnalysisSleepInputs.swift`:

```swift
struct AnalysisSleepInput {
    let totalSleepMinutes: Int
    let inBedMinutes: Int
    let deepSleepMinutes: Int?
    let remSleepMinutes: Int?
    let awakeMinutes: Int
    let sleepEfficiency: Double?
    static let empty: AnalysisSleepInput
    init(from healthKit: SleepData?)
}

struct AnalysisSleepTrendInput {
    let averageSleepMinutes: Double
    let averageDeepSleepMinutes: Double?
    let averageEfficiency: Double?
    let trend: SleepTrend
    let nightsAnalyzed: Int
    enum SleepTrend: String { case improving, declining, stable, insufficient }
    static let empty: AnalysisSleepTrendInput
    init(from healthKit: HealthKitManager.SleepTrendStats?)
    // The week of nights before `session`, from the sleep archived with
    // `sessions`; nil without a session or a night with measured sleep.
    static func recentNights(before session: HRVSession?, in sessions: [HRVSession]) -> AnalysisSleepTrendInput?
}
```

### BaselineTracker
**File**: `Emuqu/Sources/Analysis/BaselineTracker.swift`

```swift
final class BaselineTracker {

    struct Baseline: Codable {
        let date: Date
        let rmssd: Double
        let sdnn: Double
        let meanHR: Double
        let hf: Double?
        let lf: Double?
        let lfHfRatio: Double?
        let dfaAlpha1: Double?
        let stressIndex: Double?
        let readinessScore: Double?
        let sampleCount: Int
        static let minimumSamples = 3
    }

    struct BaselineDeviation: Codable {
        let rmssdDeviation: Double?       // Percentage deviation
        let sdnnDeviation: Double?
        let meanHRDeviation: Double?
        let hfDeviation: Double?
        let lfHfDeviation: Double?
        let stressDeviation: Double?
        let readinessDeviation: Double?
    }

    struct RecoveryBaselineStats {
        let lnRmssdMean: Double
        let lnRmssdSD: Double
        let lnRmssdCV7Day: Double?
        let meanHRBaseline: Double
        let meanHRSD: Double
        let daysInWindow: Int
        var lastDataPointDate: Date?      // newest night in the window (staleness)
        static let minimumDays = 3
    }

    typealias BaselineUpdater = (_ rmssd: Double, _ hr: Double) -> Void

    /// HRVBaseline.json in the app's shared container.
    convenience init(onBaselineUpdated: BaselineUpdater? = nil)
    /// The baseline in `baselineFile`, sealed with the app's key.
    convenience init(baselineFile: URL, onBaselineUpdated: BaselineUpdater? = nil)
    init(baselineFile: URL, seal: JSONFileSeal, onBaselineUpdated: BaselineUpdater?)

    /// Current baseline (computed property)
    var baseline: Baseline? { get }
    var hasValidBaseline: Bool { get }
    var daysCollected: Int { get }
    /// Every stored night: for display.
    var recoveryBaselineStats: RecoveryBaselineStats? { get }
    /// Only the nights before the scored one (its night key), for scoring.
    func recoveryBaselineStats(excludingNightOf session: HRVSession, sleepSchedule: SleepSchedule) -> RecoveryBaselineStats?

    /// One reading per night. A session already in the baseline (re-analysed,
    /// or its window re-picked) replaces its own earlier reading, matched by
    /// `BaselineDataPoint.sessionId` (by start for older points), and leaves
    /// the baseline when it no longer passes the gates. The callback runs
    /// after the lock is released.
    func update(with session: HRVSession, sleepSchedule: SleepSchedule)
    func deviation(for session: HRVSession) -> BaselineDeviation?
    func reset()

    /// √(7/n) below 7 nights, else 1 (≈1.53 at 3). Widens both the ln(RMSSD)
    /// SD and the resting-HR SD of `RecoveryBaselineStats`.
    static func smallSampleWidening(count: Int) -> Double
}
```

---

## Services

### MorningProcessingService
**File**: `Emuqu/Sources/Services/MorningProcessingService.swift`

```swift
@MainActor
final class MorningProcessingService {

    struct ProcessingResult {
        var session: HRVSession
        var verificationResult: Verification.Result?
        var recoveryWindow: WindowSelector.RecoveryWindow?
        var baselineDeviation: BaselineTracker.BaselineDeviation?
        var sameNightLinks: [UUID]
    }

    struct SettingsSnapshot {
        let sleepSchedule: SleepSchedule
        let enableTrainingLoadIntegration: Bool
        let typicalSleepHours: Double
        let scoringConfig: RecoveryScoreCalculator.ScoringConfiguration
        let ansConfig: HRVAnalysisPipeline.ANSConfiguration
        var sessionMergeMode: SessionMergeMode = .defaultGap
        var mergeGapSeconds: TimeInterval?
    }

    typealias StatusCallback = @MainActor (RRCollector.MorningProcessingStatus) -> Void
    typealias NowProvider = () -> Date
    typealias SleepProvider = (_ nanoseconds: UInt64) async -> Void

    init(
        archive: SessionArchive,
        healthKit: any HealthKitServiceProtocol,
        analysisPipeline: HRVAnalysisPipeline,
        windowSelector: WindowSelector,
        artifactDetector: ArtifactDetector,
        verification: Verification,
        baselineTracker: BaselineTracker,
        rawBackup: RawRRBackup,
        now: @escaping NowProvider = Date.init,
        sleep: @escaping SleepProvider = { nanoseconds in ... }  // wraps Task.sleep
    )

    /// Everything one morning pass works from.
    struct OvernightRequest {
        init(
            points: [RRPoint],
            baseSession: HRVSession,
            dataSource: String,
            reconnectCount: Int,
            streamingBeats: Int = 0,
            deviceBeats: Int? = nil,
            deviceId: String?,
            isBackgroundRefinement: Bool = false,
            settings: SettingsSnapshot,
            trainingContext: TrainingContext?,
            cachedTrainingLoad: HealthKitManager.TrainingLoad?,
            prefetchedSleepData: SleepData? = nil,
            statusCallback: StatusCallback? = nil
        )
    }

    func processOvernightData(_ request: OvernightRequest) async -> ProcessingResult

    func createCompositePoints(
        internalSeries: RRSeries,
        streamingSeries: RRSeries
    ) -> [RRPoint]?

    func supersedeSameNightSession(
        newSession: inout HRVSession, sleepSchedule: SleepSchedule,
        sessionMergeMode: SessionMergeMode = .defaultGap, mergeGapSeconds: TimeInterval? = nil
    )
}
```

### ReanalysisService
**File**: `Emuqu/Sources/Services/ReanalysisService.swift`

```swift
@MainActor
final class ReanalysisService {

    init(
        archive: SessionArchive,
        healthKit: HealthKitServiceProtocol,
        analysisPipeline: HRVAnalysisPipeline,
        windowSelector: WindowSelector,
        artifactDetector: ArtifactDetector,
        baselineTracker: BaselineTracker,
        settingsProvider: @escaping () -> UserSettings,
        scoringConfigProvider: @escaping () -> RecoveryScoreCalculator.ScoringConfiguration,
        ansConfigProvider: @escaping (HRVSession) -> HRVAnalysisPipeline.ANSConfiguration,
        trainingContextProvider: @escaping (Date) -> TrainingContext?,
        analyzeWithWindow: @escaping (HRVSession, WindowSelector.RecoveryWindow, [ArtifactFlags], PeakCapacity?) async -> HRVAnalysisResult?,
        analyzeFullSession: @escaping (HRVSession, PeakCapacity?) async -> HRVAnalysisResult?,
        onArchiveChanged: @escaping () -> Void,
        onSessionUploaded: @escaping (HRVSession) -> Void,
        onZonesStale: @escaping (UUID) -> Void
    )

    func reanalyzeSession(
        _ inputSession: HRVSession,
        method: WindowSelectionMethod = .consolidatedRecovery,
        preserveManualWindows: Bool = false
    ) async -> HRVSession?

    func reanalyzeAllSessions(
        sessions: [HRVSession],
        from: Date? = nil,
        to: Date? = nil,
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> (updated: Int, skipped: Int)

    func retroApplySleepSettings(
        sessions: [HRVSession],
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> Int

    func reanalyzeAtPosition(
        _ session: HRVSession,
        targetMs: Int64
    ) async -> HRVAnalysisResult?

    func applyManualAnalysis(
        _ session: HRVSession,
        result: HRVAnalysisResult
    ) async -> HRVSession?

    /// Runs off the main actor, one edit after another in the order made;
    /// the task's value is true only when the update was stored. A user
    /// adjustment's caller reports a false value; an automatic one may not.
    @discardableResult
    func updateSessionSleepBoundaries(
        sessionId: UUID,
        sleepData: SleepData,
        isUserAdjustment: Bool = false
    ) -> Task<Bool, Never>

    @discardableResult
    func unlinkSegment(segmentId: UUID, fromSession sessionId: UUID) -> Bool

    /// Shared insufficient-data classifier. Applied identically at initial
    /// scoring (MorningProcessingService) and reanalysis so a session can't
    /// be marked `.insufficient` on one path and `.ok` on the other.
    static func hasInsufficientData(
        session: HRVSession,
        analysisResult: HRVAnalysisResult,
        baselineRmssd: Double
    ) -> Bool

    static func computeFrozenReadiness(
        compositeScore: Double,
        trainingContext: TrainingContext?
    ) -> Double
}
```

### SessionAcceptanceService
**File**: `Emuqu/Sources/Services/SessionAcceptanceService.swift`

```swift
@MainActor
final class SessionAcceptanceService {

    init(
        archive: SessionArchive,
        healthKit: any HealthKitServiceProtocol,
        baselineTracker: BaselineTracker,
        rawBackup: RawRRBackup,
        onDiscardExercise: @escaping () -> Void,
        onCloudSync: @escaping (HRVSession) async -> Void,
        onCloudDelete: @escaping (UUID) async -> Void
    )

    struct AcceptanceInputs {
        let scoringConfig: RecoveryScoreCalculator.ScoringConfiguration
        let trainingContext: TrainingContext?
        let baselineStats: BaselineTracker.RecoveryBaselineStats?
        let typicalSleepHours: Double
        let sleepSchedule: SleepSchedule
    }

    func processAcceptance(
        session: HRVSession,
        inputs: AcceptanceInputs,
        enableHealthKitExport: Bool,
        clearPersistedRecordingState: () -> Void
    ) async throws -> HRVSession

    @discardableResult
    func updateCompositeRecoveryScore(
        for session: HRVSession,
        scoringConfig: RecoveryScoreCalculator.ScoringConfiguration,
        trainingContext: TrainingContext?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        typicalSleepHours: Double,
        sleepSchedule: SleepSchedule,
        exportMetrics: Bool = false,
        enableHealthKitExport: Bool = false
    ) async -> Bool

    func processRejection(
        sessionId: UUID?,
        clearPersistedRecordingState: () -> Void
    ) async

    /// The whole night's range (overnightWindowStart … morningCutoff),
    /// split or single-segment; `sessionEnd` is not read.
    func sleepFetchRange(
        for session: HRVSession,
        sessionEnd: Date,
        sleepSchedule: SleepSchedule
    ) -> (start: Date, end: Date)
}
```

**Insufficient data gate** -- During `processAcceptance`, HRV data quality is classified before scoring:

- `.insufficient` is triggered when RMSSD < baseline **and** either of the following is true:
  1. Analysed span < 5 min (`forReliableWindowMs`): the analysis window, or the whole session when it was analysed without one, **or**
  2. No organized recovery detected + session < 3 hours (`forOvernightSessionSeconds`).
- `.preSleep` is triggered when the recording does not overlap detected sleep at all.
- When either triggers: `useBaselineHRV = true` (substitutes baseline RMSSD), and `SubjectiveReadinessCard` is shown on the dashboard so the user can provide a perceived readiness value.

### SessionRecoveryService
**File**: `Emuqu/Sources/Services/SessionRecoveryService.swift` + `SessionRecoveryService+Backup.swift`

```swift
@MainActor
final class SessionRecoveryService {

    // Nested Types

    enum PatchAction {
        case addMissingData
        case reanalyzeNoResult
        case reanalyzeNoFlags
        case replaceWithNewData(existingCount: Int, newCount: Int)
    }

    // Initialization

    init(
        archive: SessionArchive,
        rawBackup: RawRRBackup,
        artifactDetector: ArtifactDetector,
        windowSelector: WindowSelector,
        cloudSyncManager: CloudKitSyncManager,
        baselineTracker: BaselineTracker
    )

    // Patch Decision

    static func patchAction(
        existingRR: RRSeries?,
        incomingPoints: [RRPoint],
        hasAnalysisResult: Bool,
        hasArtifactFlags: Bool
    ) throws -> PatchAction

    // Lost Session Detection

    func checkForLostSessions(excluding live: Set<UUID> = []) async -> [(id: UUID, date: Date, beatCount: Int)]
    func pullCloudBackupsToLocal() async
    func checkForDeletedSessions() -> [(id: UUID, date: Date, beatCount: Int)]
    func restoreFromTrash(_ sessionId: UUID)
    func restoreFromTrashFailed(_ sessionId: UUID)
    func deletedSessionSpan(_ sessionId: UUID) -> ClosedRange<Date>?
    @discardableResult
    func permanentlyDelete(_ sessionId: UUID) -> Bool
    func permanentlyDelete(
        _ ids: [UUID], removeHealthSamples: (UUID, ClosedRange<Date>) async -> Bool
    ) async -> TrashDeletionOutcome
    func deleteLostSessions(_ sessionIds: [UUID]) -> Set<UUID>  // the ids whose mark was stored

    // Backup Recovery

    func recoverFromBackup(
        _ sessionId: UUID,
        recordedType: SessionType? = nil,
        analyze: (_ session: HRVSession, _ window: WindowSelector.RecoveryWindow, _ flags: [ArtifactFlags], _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        analyzeWithCapacity: (_ session: HRVSession, _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        supersedeSameNight: (_ session: inout HRVSession) -> Void,
        computeRecoveryScore: (_ session: HRVSession, _ analysisResult: HRVAnalysisResult?) async -> RecoveryScoreOutcome? = { _, _ in nil }
    ) async -> HRVSession?

    func recoverToPausedState(
        _ sessionId: UUID,
        sessionType: SessionType,
        analyze: (_ session: HRVSession, _ window: WindowSelector.RecoveryWindow, _ flags: [ArtifactFlags], _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        analyzeWithCapacity: (_ session: HRVSession, _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?
    ) async -> HRVSession?
}
```

### PurgeGate
**File**: `Emuqu/Sources/Services/PurgeGate.swift`

```swift
enum PurgeGate {
    struct Refused: Error, LocalizedError {}
    static var isPurging: Bool { get }
    /// Runs `write` unless a purge runs (throws `Refused`), counting it in
    /// flight until it returns.
    static func admitWrite<T>(_ write: () throws -> T) throws -> T
    /// Closes the gate; returns once the writes already admitted finished.
    static func beginPurge() async
    static func endPurge()           // overlapping purges are counted
}
```

`DataPurgeService.purgeAllUserData` refuses while recording, then
`beginPurge()` (with `defer endPurge()`), turns iCloud Sync off, awaits the
remote delete, and checks again for a recording
(`Refusal.recordingStartedDuringDelete`: no local wipe, sync stays off)
before wiping the device. A rescore that finishes during or after a purge
writes nothing (`RescoreWrite` `.notArchived`: it never creates a session).

---

### LanguageManager
**File**: `Emuqu/Sources/Services/LanguageManager.swift`

```swift
@MainActor
@Observable
final class LanguageManager {
    static let shared: LanguageManager
    static let languageDidChangeNotification: Notification.Name

    // Lock-backed and read from any isolation; locale and bundle are
    // stored together by init and setLanguage.
    nonisolated var locale: Locale { get }
    nonisolated var bundle: Bundle { get }
    nonisolated var revision: Int { get }

    func setLanguage(_ language: AppLanguage)
}
```

Manages live in-app language switching. Updates the `locale` (for SwiftUI environment) and `bundle` (for `String(localized:bundle:)` calls). Resets cached formatters and posts `languageDidChangeNotification`. `revision` increments on each change so views can react.

### NarrativeLanguage
**File**: `Emuqu/Sources/Services/NarrativeLanguage.swift`

Runtime-assembled text (analysis summaries, score explanations, readiness
copy) is built from catalogue keys with `String(localized:bundle:)`, so every
sentence is reviewed and translated like any other string. `NarrativeLanguage`
supplies the bundle and locale those builders use; `NarrativeLanguage.english { }`
runs a builder in English for machine input (the assistant's context, stable keys).

### StoreKitManager
**File**: `Emuqu/Sources/Services/StoreKitManager.swift`

```swift
@MainActor
@Observable
final class StoreKitManager {
    static let shared: StoreKitManager
    static let productId = "com.chrissharp.flowrecovery.lifetime"

    private(set) var product: Product?
    private(set) var isPurchased: Bool
    private(set) var isPurchasing: Bool
    var errorMessage: String?

    func loadProducts() async
    func purchase() async                 // the lifetime unlock; nothing while the paywall is off
    func startFreeTrial() async           // buys the $0 30-day trial product
    /// AppStore.sync, then one entitlement sweep; the message for the user:
    /// restored, no purchase found, or could not restore.
    func restore() async -> String?
    func refreshStatus() async
}
```

Manages StoreKit 2 in-app purchase for a non-consumable lifetime product. Verifies transactions, listens for updates (refunds, family sharing), and exposes reactive purchase state. Debug builds support a persisted bypass flag via `debugGrantAccess()`.

### BreadcrumbStore
**File**: `Emuqu/Sources/Services/BreadcrumbStore.swift`

```swift
struct BreadcrumbFix: Codable, Equatable, Sendable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let horizontalAccuracyMeters: Double
    let altitudeMeters: Double?
    let courseDegrees: Double?
    let speedMS: Double?
    init(from loc: CLLocation)
}

struct BreadcrumbTrail: Codable, Equatable, Sendable {
    let startedAt: Date
    var origin: BreadcrumbFix?
    var fixes: [BreadcrumbFix]
    var label: String?
    var resolvedOriginLabel: String?
    var isWorkoutTrack: Bool?
    var sessionId: UUID?     // the workout a workout track was filed from
    func crowFlyDistanceFromTipToOriginMeters() -> Double?
    func walkedTrailLengthMeters() -> Double
}

final class BreadcrumbStore: @unchecked Sendable {
    static let shared: BreadcrumbStore
    static let archiveRetentionLimit = 50

    // Active trail (single, in-progress)
    func load() -> BreadcrumbTrail?
    func save(_ trail: BreadcrumbTrail)
    func archiveActive()    // active → archive; active erased only after the archive write succeeds
                            // (unreadable/unwritable archive: trail stays active, error logged)
    @discardableResult
    func clear() -> Bool    // permanent delete of active; false when the file is still there
    func hasActiveTrail() -> Bool
    func hasArchiveFile() -> Bool

    // Archive (history, newest first, capped)
    func loadArchive() -> [BreadcrumbTrail]
    func archive(_ trail: BreadcrumbTrail)
    func removeTrails(ofSession sessionId: UUID) -> Bool  // a workout deleted forever
    @discardableResult
    func eraseArchive() -> Bool  // Delete All My Data
}
```

Crash-safe persistence for Get Me Back trails + auto-archived workout
tracks. Active trail at `Breadcrumbs/active.json`, history at
`Breadcrumbs/archive.json`, both in the App Group container with
`.completeUntilFirstUserAuthentication` protection. Atomic writes on
every fix.

### BreadcrumbRecorder
**File**: `Emuqu/Sources/Services/BreadcrumbRecorder.swift`

```swift
@MainActor
@Observable
final class BreadcrumbRecorder: NSObject {
    static let shared: BreadcrumbRecorder

    private(set) var latestLocation: CLLocation?
    private(set) var latestHeading: CLHeading?
    private(set) var activeTrail: BreadcrumbTrail?
    private(set) var isEngaged: Bool
    private(set) var authorizationStatus: CLAuthorizationStatus

    func engage(label: String? = nil)
    func resume()                     // restart on a trail restored after a relaunch
    func disengage()
    func endAndArchive() -> Bool      // "End and save": file the trail, stop recording
    func clearTrail() -> Bool         // user-confirmed delete; false when the file stays
    func forgetAfterPurge()           // Delete All My Data: stop, drop the in-memory trail
}
```

CLLocationManager wrapper for Get Me Back mode. `kCLLocationAccuracyNearestTenMeters`,
10 m distance filter, 25 m / 30 s commit gate, drops fixes with
`horizontalAccuracy > 100`. Heading via `startUpdatingHeading()` for
the compass arrow. Forwards every fix to `AmbientLocationService.record(_:)`.

### AmbientLocationService
**File**: `Emuqu/Sources/Services/AmbientLocationService.swift`

```swift
final class AmbientLocationService: NSObject, @unchecked Sendable {
    static let shared: AmbientLocationService

    func start()                                        // foreground gate
    func stop()
    func record(_ location: CLLocation)                 // push from any manager
    func cachedResolvedAddress(maxAgeSec: TimeInterval = 30) -> RoadGeocodingService.RoadContext?
    func cachedLocation(maxAgeSec: TimeInterval = 60) -> CLLocation?
}
```

Cache-keeper for the AI's location tools. Foreground-only own
CLLocationManager (`kCLLocationAccuracyHundredMeters`, 50 m filter)
fed by `WorkoutLocationManager` and `BreadcrumbRecorder` push so the
cache stays warm during a backgrounded workout-with-screen-locked.
NSLock-guarded for off-main reads from AI fact actions.

### DirectionsService
**File**: `Emuqu/Sources/Services/DirectionsService.swift`

```swift
enum DirectionsService {
    enum Destination {
        case origin
        case poi(query: String)
        case address(String)
    }
    enum Mode { case walking, driving }

    struct RouteResult {
        let destinationLabel: String
        let destinationLatitude: Double
        let destinationLongitude: Double
        let distanceMeters: Double
        let durationSeconds: TimeInterval
        let mode: String
        let steps: [String]
    }

    static func resolveRoute(
        from origin: CLLocationCoordinate2D,
        to destination: Destination,
        mode: Mode
    ) async throws -> RouteResult
}
```

Backend for the AI's `directions.routeTo` tool. Resolves a destination
via `MKLocalSearch` (POI), `RoadGeocodingService.geocodeAddress`
(typed address), or `BreadcrumbStore.shared.load()?.origin`
(breadcrumb origin). Computes a route via `MKDirections`, returns the
first 3 step instructions, and ENGAGES `ActiveRouteSession` for
follow-up `directions.next_step` queries.

### ActiveRouteSession
**File**: `Emuqu/Sources/Services/ActiveRouteSession.swift`

```swift
final class ActiveRouteSession: @unchecked Sendable {
    static let shared: ActiveRouteSession

    struct Snapshot {
        let destinationLabel: String
        let destinationLatitude: Double
        let destinationLongitude: Double
        let totalDistanceMeters: Double
        let totalDurationSeconds: TimeInterval
        let stepCount: Int
        let currentStepIndex: Int
        let engagedAt: Date
    }
    struct StepResult {
        let currentStepIndex: Int
        let currentInstruction: String
        let upcomingInstruction: String
        let distanceToUpcomingStepMeters: Double
        let remainingDistanceMeters: Double
        let destinationLabel: String
        let arrived: Bool
    }

    func engage(route: MKRoute, destinationLabel: String, destinationCoord: CLLocationCoordinate2D)
    func disengage()
    func snapshot() -> Snapshot?
    func currentStep(for location: CLLocation) -> StepResult?
    func peekStep(for location: CLLocation) -> StepResult?
}
```

Continuous turn-by-turn for the AI. Holds an `MKRoute` + sticky step
index in memory. `currentStep(for:)` walks forward from the sticky
index (never back, so GPS jitter can't bounce backwards), returns
the upcoming instruction + distance + remaining + arrival state.
`peekStep(for:)` answers the same for a fix without moving the
index (assistant reads). Offline-once-engaged.

### AudioSessionCoordinator
**File**: `Emuqu/Sources/Services/AudioSessionCoordinator.swift`

```swift
final class AudioSessionCoordinator: Sendable {
    static let shared: AudioSessionCoordinator

    enum Claimant { case voice, workoutCue, dictation, workoutCoach, breathingGuide }
    enum Mode { case voiceRecord, playback }

    func claim(_ claimant: Claimant, mode: Mode)
    func release(_ claimant: Claimant)
    func hasActiveClaims() -> Bool
}
```

Single owner of `AVAudioSession.setCategory`. Voice, dictation, the
workout coach, the breathing guide and spoken workout cues (`BackgroundAudioManager`) declare INTENT through it
(only `.breathingGuide` ducks other audio); coordinator picks the strict-superset
category (voice's `.playAndRecord` wins when both are claimed).
"Skip if already-applied" rule prevents redundant `setCategory`
calls (which would reset the voice mic tap mid-conversation).

---

## Storage

### SessionArchive
**File**: `Emuqu/Sources/Storage/Archive.swift`

```swift
final class SessionArchive {
    var entries: [SessionArchiveEntry]       // cached sorted, thread-safe via archiveLock

    func archive(_ session: HRVSession) throws -> SessionArchiveEntry
    func retrieve(_ id: UUID) throws -> HRVSession?
    func retrieveLightweight(_ id: UUID) throws -> HRVSession?  // skips rrSeries (~45x less JSON)
    func retrieveOrLog(_ id: UUID) -> HRVSession?
    func retrieveLightweightOrLog(_ id: UUID) -> HRVSession?
    func delete(_ id: UUID) throws
    func exists(_ id: UUID) -> Bool
    func hasSessionNear(date: Date, toleranceMinutes: Int) -> Bool
    func updateTags(_ id: UUID, tags: [ReadingTag], notes: String?) throws
    func wasIntentionallyDeleted(_ id: UUID) -> Bool
    func linkedSegments(for session: HRVSession) -> [MorningResultsView.LinkedSegmentInfo]
    func runDeferredMigrations()             // 3-phase locking, background thread
    func repairArchive() throws -> Int       // throws when the files cannot be listed or the
                                             // rebuilt index cannot be saved
    func archivedId(of id: UUID) -> UUID     // the session a same-night fold filed `id` into
}

// Every session-file and index write (writeArchiveBytes, saveIndex) runs inside
// PurgeGate.admitWrite and throws PurgeGate.Refused while Delete All My Data runs.

struct SessionArchiveEntry: Codable {
    let sessionId: UUID
    let date: Date
    let endDate: Date?
    let fileHash: String
    let filePath: String
    let recoveryScore: Double?
    let meanRMSSD: Double?
    let meanHR: Double?          // backfilled by migrateMetrics()
    let stressIndex: Double?     // backfilled by migrateMetrics()
    let meanSDNN: Double?
    let tags: [ReadingTag]
    let notes: String?
    let sessionType: SessionType
    let linkedSessionIds: [UUID]?
    // An entry whose sessionType or hrvDataQuality holds a case from a newer
    // build is marked newer (entrySchemaVersion) and written back verbatim.
}
```

### RawRRBackup
**File**: `Emuqu/Sources/Storage/RawRRBackup.swift`

```swift
final class RawRRBackup: @unchecked Sendable {
    struct BackupEntry: Codable {
        let id: UUID
        let captureDate: Date
        let deviceId: String?
        let points: [RRPoint]
        let hash: String            // SHA256 of the RR data
        var duration: TimeInterval  // computed
        var beatCount: Int          // computed
    }

    convenience init()                      // the store in the shared container (RRBackup/)
    convenience init(directory: URL)        // a store in `directory` (tests use a folder of their own)
    init(directory: URL, notificationCenter: NotificationCenter)  // repairs on unlock/activation posted there

    @discardableResult   // runs on appendQueue (backupOnAppendQueue)
    func backup(points: [RRPoint], sessionId: UUID, deviceId: String? = nil, captureDate: Date? = nil) throws -> BackupEntry
    func appendBackup(points: [RRPoint], sessionId: UUID, deviceId: String? = nil) throws
    func incrementalBackup(points: [RRPoint], sessionId: UUID, deviceId: String? = nil, force: Bool = false, interval: TimeInterval = 60) -> Bool
    func retrieve(_ sessionId: UUID) throws -> BackupEntry?
    func allBackups() -> [BackupEntry]
    func discardBackup(_ sessionId: UUID) throws
    func purgeOldBackups(keepDays: Int = 90) throws
    func markAsArchived(_ sessionId: UUID)
    func backedUpBeatCount(_ sessionId: UUID) -> Int?
    func exportToCSV(_ sessionId: UUID) throws -> String
    func reencryptPendingBackups()
    func reconcileIndexWithFiles()
    static func terminationForensicsSummary(for sessionId: UUID) -> TerminationForensicsSummary?
}
```

Instantiated directly (`RawRRBackup()`), not a `.shared` singleton.

One-shot backups are files sealed with the archive key. The streamed format
appends JSON Lines whose lines are each sealed (`SealedJSONLines`); a line or
file written while the key was out of reach is plain, recorded in
`PendingEncryptionLedger` (`.rawBackup`), and re-sealed by
`reencryptPendingBackups`, which `init` queues. `init` also queues
`reconcileIndexWithFiles`, which lists backups on disk that the index does not
name. `discardBackup` removes every file of the session on `appendQueue` and
throws, keeping the row, when any file is still on disk; `purgeOldBackups`
drops the rows of archived backups older than `keepDays` only when all their
files went.

### CloudKitSyncManager
**File**: `Emuqu/Sources/Storage/CloudKitSyncManager.swift`

```swift
@MainActor
@Observable
final class CloudKitSyncManager {
    static let shared: CloudKitSyncManager      // bookkeeping at resolveSyncStateURL()

    /// A test builds its own manager over its archive, settings and
    /// sync-state file, so it never touches the app's bookkeeping.
    init(settingsManager: SettingsManager = ..., archive: SessionArchive = ..., syncStateURL: URL)

    private(set) var syncState: SyncState
    private(set) var pullVersion: Int
    private(set) var lastSyncDate: Date?

    /// Sync on, onboarding done, no purge running (`PurgeGate.isPurging`).
    /// Uploads and the full sync re-read it inside their serializer turn.
    var cloudUploadsAllowed: Bool { get }
    /// Confirms the signed-in Apple ID against `CloudAccountIdentity` before
    /// any read or write; a different account or a deleted zone stops sync.
    var accountGuard: CloudAccountGuard { get }
    /// Reacts to `.CKAccountChanged` (built on each access).
    var accountChange: CloudAccountChangeHandler { get }

    /// A complete session, or a workout with metadata, that was not read out
    /// of Apple Health whole: the sessions `uploadSession` uploads.
    static func takesDirectUpload(_ session: HRVSession) -> Bool
    func uploadSession(_ session: HRVSession) async
    func uploadDeletion(_ sessionId: UUID) async
    func forceReuploadSession(_ session: HRVSession) async

    /// Mark a batch of sessions as needing re-upload. Called after local
    /// migrations rewrite session files in place (e.g. `relinkSameNightSessions`).
    /// The sessions are cleared from the uploaded-set; the next sync pushes them.
    func markSessionsForReupload(_ ids: Set<UUID>) async

    func performFullSync() async             // first step: accountGuard.requireConfirmedAccount()
    func performFullSyncIfNeeded(minInterval: TimeInterval) async
    /// Keeps a session on this device only: its record is marked
    /// `keptOnDeviceMarker` (`isDeleted = 2`) with no payload.
    func markKeptOnDevice(_ recordID: CKRecord.ID) async throws

    /// The sync status shows `message` and keeps it as the permanent error.
    func showSyncStopped(_ message: String)
    /// Clears the not-signed-in error, from the status and the permanent error.
    func clearNotSignedInError()
}

/// File: `Emuqu/Sources/Storage/CloudAccountChangeHandler.swift`.
@MainActor
struct CloudAccountChangeHandler {
    let manager: CloudKitSyncManager
    /// Re-checks the CloudKit account status: .available clears the
    /// not-signed-in error and runs a full sync (with sync off and onboarding
    /// done, only the account check); .noAccount / .restricted /
    /// .couldNotDetermine shows the not-signed-in error (showSyncStopped);
    /// .temporarilyUnavailable is left for the next sync.
    func handle() async
}

/// File: `Emuqu/Sources/Storage/CloudAccountIdentity.swift`. The account sync
/// is enabled for, as `userRecordID().recordName`, in this device's
/// UserDefaults only.
enum CloudAccountIdentity {
    static var recordedAccount: String? { get }
    static var isConfirmed: Bool { get }     // checked this launch and matching
    static func noteAccountChanged()         // .CKAccountChanged: unconfirm
    /// attributeBookkeeping: nothing recorded, the account changed this
    /// launch and bookkeeping remains, so a few uploaded sessions are looked
    /// up in the signed-in account first (found: adopt; none: different).
    enum Verdict: Equatable { case sameAccount, adopt, attributeBookkeeping, differentAccount, awaitingOptIn }
    enum StopReason: String { case differentAccount, iCloudDataDeleted }   // shown under the switch
}

struct CloudAccountGuard {
    enum Check: Equatable { case confirmed, unavailable(String), stopped, differentAccount }
    func confirmAccount() async -> Check
    func requireConfirmedAccount() async throws   // throws Halt
    func zoneWasDeleted() async -> String?        // same account: stopSync(.iCloudDataDeleted); no zone recreated
    func stopSync(_ reason: CloudAccountIdentity.StopReason)  // resets per-account bookkeeping, sync off
}

/// File: `Emuqu/Sources/Storage/CloudPayloadCodec.swift`. Seals every payload
/// uploaded to iCloud with the cloud key in the iCloud Keychain.
enum CloudPayloadCodec {
    /// Where the keys are read and added; `.keychain` in the app, a stub in tests.
    struct KeyStore: Sendable {
        let read: @Sendable () throws -> [StoredKey]
        let add: @Sendable () throws -> SymmetricKey
        static let keychain: KeyStore
    }
    /// The one sealing entry for uploads, fail-closed: no new key is created
    /// unless `mayCreateKey` (the account was confirmed this launch); with no
    /// key to use it throws `CloudSyncError.encryptionUnavailable`.
    static func sealForUpload(_ payload: Data, mayCreateKey: Bool = CloudAccountIdentity.isConfirmed,
                              in store: KeyStore = .keychain) throws -> Data
}

extension Notification.Name {
    /// Posted when a local migration has mutated archived session files in
    /// place, making the CloudKit copies stale. `userInfo["sessionIds"]`
    /// carries a `Set<UUID>`; `CloudKitSyncManager` observes it and clears
    /// those IDs from its uploaded-set so the next sync pass re-uploads.
    static let flowRecoveryArchiveSessionsNeedReupload: Notification.Name
}
```

---

## Import / Export

### RRDataImporter
**File**: `Emuqu/Sources/Import/RRDataImporter.swift`

```swift
final class RRDataImporter {

    enum ImportFormat: String, CaseIterable, Identifiable {
        case csv = "CSV"
        case json = "JSON"
        case txt = "Text (RR values)"
        case kubios = "Kubios Export"
        case eliteHRV = "Elite HRV Summary"
        case flowHRVMultiSession = "Emuqu RR Export"

        var id: String { rawValue }
        var description: String
    }

    struct ImportResult {
        let rrIntervals: [Int]
        let sourceFormat: ImportFormat
        let originalFileName: String
        let recordingDate: Date?
        let metadata: [String: String]
        var beatCount: Int { rrIntervals.count }
        var durationMinutes: Double
    }

    struct EliteHRVSummaryResult {
        struct SessionSummary {
            let date: Date
            let rmssd: Double
            let rmssdRaw: Double
            let artifactPercent: Double
            let beatCount: Int
            let rrMin: Double
            let rrMax: Double
            let fileName: String
            let sdnn: Double?        // the file's Sdnn column, when it has one
            let pnn50: Double?       // the file's Pnn50 column, when it has one
            let rrRangeStated: Bool  // both RR extremes stated by the file
        }
        let sessions: [SessionSummary]
        let originalFileName: String
    }

    struct FlowHRVMultiSessionResult {
        struct SessionRRData {
            let sessionDate: String
            let date: Date
            let rrIntervals: [Int]
            let timestamps: [Int64]
            var beatCount: Int { rrIntervals.count }
            var durationMinutes: Double
        }
        let sessions: [SessionRRData]
        let originalFileName: String
    }

    enum ImportError: LocalizedError {
        case fileNotFound
        case unreadableFile
        case invalidFormat(String)
        case noRRData
        case insufficientData(found: Int, required: Int)
        case invalidRRValues(String)
        case invalidTimestamps(session: String)  // beat times that cannot be one recording
        case recordingTooLong                    // intervals add up to more than a week
    }

    // Single-file import
    func importFile(at url: URL) async throws -> ImportResult
    /// `startDate` is the file's recording date, or the date the user gives
    /// for a file that states none (CSV, Kubios, text).
    func createSession(from result: ImportResult, startingAt startDate: Date) -> HRVSession

    // EliteHRV batch import
    func isEliteHRVSummary(_ content: String) -> Bool
    func parseEliteHRVSummary(_ content: String, fileName: String) throws -> EliteHRVSummaryResult
    func createAnalyzedSession(from summary: EliteHRVSummaryResult.SessionSummary, originalFileName: String) -> HRVSession
    func importEliteHRVFile(at url: URL) async throws -> EliteHRVSummaryResult

    // Emuqu multi-session import
    func isFlowHRVMultiSession(_ content: String) -> Bool
    func parseFlowHRVMultiSession(_ content: String, fileName: String) throws -> FlowHRVMultiSessionResult
    func createSessionFromFlowHRVData(_ sessionData: FlowHRVMultiSessionResult.SessionRRData, originalFileName: String) -> HRVSession
}
```

### PDFReportGenerator
**File**: `Emuqu/Sources/Export/PDFReportGenerator.swift`

```swift
final class PDFReportGenerator {
    func generateReport(
        for session: HRVSession,
        flags: [ArtifactFlags]? = nil,
        sleepData: SleepData? = nil,
        sleepTrend: SleepTrendData? = nil,
        recentSessions: [HRVSession] = [],
        healthKitHR: HeartRateStats? = nil,
        vitals: VitalsData? = nil,
        compositeRecoveryScore: Double? = nil,
        scoreBreakdown: RecoveryScoreCalculator.ScoreBreakdown? = nil,
        baselineStats: BaselineTracker.RecoveryBaselineStats? = nil,
        liveLoadSnapshot: TrainingLoadRegistry.TrainingLoad? = nil,
        style: ReportStyle = .comprehensive,
        sections: ReportSections = .all
    ) -> Data?

    func generateReportURL(
        for session: HRVSession,
        sleepData: SleepData? = nil,
        sleepTrend: SleepTrendData? = nil,
        recentSessions: [HRVSession] = [],
        healthKitHR: HeartRateStats? = nil,
        vitals: VitalsData? = nil,
        compositeRecoveryScore: Double? = nil,
        scoreBreakdown: RecoveryScoreCalculator.ScoreBreakdown? = nil,
        baselineStats: BaselineTracker.RecoveryBaselineStats? = nil,
        liveLoadSnapshot: TrainingLoadRegistry.TrainingLoad? = nil,
        style: ReportStyle = .comprehensive,
        sections: ReportSections = .all
    ) -> URL?
}
```

### ExportFile
**File**: `Emuqu/Sources/Export/ExportFile.swift`

```swift
enum ExportFile {
    /// An export built in memory, written only when the user shares it.
    struct Pending: Sendable {
        let name: String
        let data: Data
        func write() throws -> URL               // ExportFile.write(data, named: name)
    }
    static var directory: URL                     // tmp/Exports
    /// Atomic, complete file protection; earlier copies whose names start
    /// with `replacingPrefix` are removed first.
    static func write(_ data: Data, named name: String, replacingPrefix prefix: String? = nil) throws -> URL
    static func protect(_ url: URL)               // complete protection on a file written elsewhere
    static func removeLeftovers()                 // empties the folder; EmuquApp.init
}
```

CSV, GPX and TCX exports, the report PDF (`writeReport`), the log export and the
crash export are written through it. The workout summary builds its GPX, CSV and
TCX as `Pending` exports and writes one only when it is shared
(`FileShareButton`); a shared file is deleted when its share sheet closes,
shared or cancelled (`presentFileShareSheet`).

---

## Protocols

```swift
// The queries the injected services (MorningProcessingService,
// SessionAcceptanceService, ReanalysisService, HRVAnalysisPipeline,
// SleepBoundaryResolver) make, so a test mock stubs only those. Authorization,
// observers, trends, other exports and dashboard queries are called on the
// concrete HealthKitManager and are not part of it.
@MainActor
protocol HealthKitServiceProtocol: Sendable {
    nonisolated var isHealthKitAvailable: Bool { get }

    func fetchSleepData(
        for recordingStart: Date, recordingEnd: Date,
        rrPoints: [RRPoint]?, autoSleepExtension: SleepResolver.AutoSleepExtension?,
        rrStart: Date?
    ) async throws -> SleepData
    func fetchDaytimeNapMinutes(nightAnchoredAt nightAnchor: Date) async -> Int    // default 0
    func fetchDaytimeRestingHR(for sleepDate: Date) async throws -> Double?
    func calculateTrainingLoad(relativeTo referenceDate: Date) async -> HealthKitManager.TrainingLoad
    func fetchRecoveryVitals(relativeTo referenceDate: Date) async -> RecoveryVitals
    func estimateSleepFromHealthKitHR(
        windowStart: Date, windowEnd: Date, minimumSamples: Int, minimumSleepMinutes: Int
    ) async -> SleepData?
    func estimateSleepFromRR(rrPoints: [RRPoint], recordingStart: Date) async -> SleepData?  // default detaches
    func exportSessionMetrics(from session: HRVSession) async throws
}


// Only one protocol exists. `PolarManagerProtocol`, `SessionRepositoryProtocol`
// and `AnalysisServiceProtocol` were deleted: each had a single conformer and no
// production call site that used it as a type. See MAINTAINERS.md §5.7.
```

---

## View Models

### HistoryViewModel
**File**: `Emuqu/Sources/ViewModels/HistoryViewModel.swift`

### MorningResultsViewModel
**File**: `Emuqu/Sources/ViewModels/MorningResultsViewModel.swift`

---

## Views

### SubjectiveReadinessCard
**File**: `Emuqu/Sources/Views/SubjectiveReadinessCard.swift`

Slider card shown when `hrvDataQuality` is `.preSleep` or `.insufficient`. Lets the user rate perceived readiness on a 0-10 scale. The submitted value is passed as `perceivedReadiness` to `calculateWithBreakdown`, where it is blended at 30% weight with the 70% baseline HRV factor.

```swift
struct SubjectiveReadinessCard: View {
    @Binding var perceivedReadiness: Double?
    let quality: HRVDataQuality           // .preSleep | .insufficient | .good
}
```

---

## Constants

**File**: `Emuqu/Sources/Utilities/Constants.swift`

All centralized thresholds and configuration values:

| Namespace | Key Constants |
|-----------|---------------|
| `AppConfig` | App Group ID, iCloud container, archive/backup directory names |
| `HRVConstants.RRInterval` | min: 300ms, max: 2000ms |
| `HRVConstants.MinimumBeats` | analysis: 300, streaming: 120, DFA: 256 |
| `HRVConstants.FrequencyBands` | VLF: 0.003-0.04 Hz, LF: 0.04-0.15 Hz, HF: 0.15-0.4 Hz |
| `HRVConstants.DFA` | alpha1: 4-16 beats, alpha2: 16-64, organized recovery: 0.75-1.0 |
| `HRVConstants.Artifacts` | max: 15%, warn: 5% |
| `HRVConstants.MinimumDuration` | `forReliableWindowMs`: 300,000 ms (5 min), `forOvernightSessionSeconds`: 10,800 s (3 h) |
| `TrainingConstants.ACR` | optimal: 0.8-1.1, overreaching: 1.5 |
| `TrainingConstants.EWMA` | acute: 7 days, chronic: 42 days |
| `StressNormativeConstants` | PNS/SNS reference values for z-score computation |
| `SleepClassifierConstants` | Stage thresholds, augmentation thresholds, scoring weights |

---

## AI Assistant

**Folder**: `Sources/Assistant/`

The Assistant module is a self-contained chat layer that surfaces Emuqu's analysis through one of six AI providers. See [ARCHITECTURE.md → AI Assistant](ARCHITECTURE.md#ai-assistant) for the full pipeline; this section lists the public Swift surface.

### Context

```swift
struct AssistantContext: Codable {
    let generatedAt: Date
    let userProfile: UserProfileSnapshot
    let today: SessionSnapshot?
    let yesterday: SessionSnapshot?
    let yesterdayDiagnostic: AnalysisSummarySnapshot?
    let recent: [SessionSnapshotLite]      // last 14 days, includes ATL/CTL/TSB and cached diagnosis
    let baselines: BaselineSnapshot?
    let trends7Day: TrendSnapshot?
    let trends30Day: TrendSnapshot?
    let analysisSummary: AnalysisSummarySnapshot?

    func compactRender(includeAmbientLocation: Bool = true) -> String  // ~1.5K tokens for Apple's 4K context window
    func renderLiveStateForCloud(now: Date? = nil) -> String         // today + yesterday one-liners, sent each cloud tool round
}

enum ContextBuilder {
    static func build(
        latestSession: HRVSession?,
        yesterdaySession: HRVSession? = nil,
        recentSessions: [HRVSession],
        sleepInput: AnalysisSleepInput = .empty,
        sleepTrend: AnalysisSleepTrendInput? = nil,
        trainingContext: TrainingContext? = nil,
        userSettings: UserSettings,
        customTagNames: [String] = [],
        baseline: BaselineTracker.Baseline? = nil,
        baselineStats: BaselineTracker.RecoveryBaselineStats? = nil,
        yesterdayBaselineStats: BaselineTracker.RecoveryBaselineStats? = nil,
        trends7Day: TrendAnalyzer.TrendSummary? = nil,
        trends30Day: TrendAnalyzer.TrendSummary? = nil,
        liveLoadSnapshot: TrainingLoadRegistry.TrainingLoad? = nil
    ) -> AssistantContext
}

final class AssistantContextSource: Sendable {
    static let shared: AssistantContextSource
    func currentContext() async -> AssistantContext   // rebuilt on every call, on a background queue; no cache
}
```

### Providers

```swift
enum ProviderID: String, Codable, CaseIterable, Identifiable {
    case apple, anthropic, openai, gemini, grok, deepseek
    var displayName, vendorName, symbolName: String
    var privacyPolicyURL: URL?
}

struct ModelOption: Codable, Hashable, Identifiable {
    let providerID: ProviderID
    let apiID: String
    let displayName, blurb: String
    let contextWindow: Int
    let inputPricePerMTok, outputPricePerMTok: Decimal?  // nil = free (Apple)
    let isDefault: Bool
}

struct ChatTurn: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let role: Role          // .user, .assistant
    var text: String
    let createdAt: Date
    var providerID: ProviderID?
    var modelID: String?
    let subsystem: AssistantSubsystem?   // Flo / Coach / Flo Report badge
    let routedTierRaw: Int?              // the routing tier, for the tier dot
    var localOnly: Bool = false          // answered on the device (guard, shortcut)
    var incomplete: Bool = false         // the reply stopped early
}

enum AIStreamEvent: Sendable {
    case textDelta(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case usage(
        inputTokens: Int,                  // uncached part only
        outputTokens: Int,
        cachedInputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0
    )
    case done
}

enum AIProviderError: LocalizedError {
    case missingKey(ProviderID), unsupportedOS(required: String), guardrailViolation
    case rateLimited, authFailed, network(String), invalidResponse(String)
    case modelUnavailable(String), outOfCredit(ProviderID), cancelled, unknown(String)
    case blockedReply(provider: ProviderID, reason: String)  // a provider's safety refusal
                                                             // (Gemini's every blockReason too):
                                                             // shown, never handed to another provider
}

struct ToolSpec: Hashable, Codable, Sendable {
    let name: String
    let description: String
    let inputSchema: InputSchema      // JSON-schema subset (object with properties)

    struct InputSchema: Hashable, Codable {
        let type: String              // always "object"
        let properties: [String: Property]
        let required: [String]
    }
    struct Property: Hashable, Codable {
        let type: String              // "string", "integer", "number", "boolean"
        let description: String
    }
}

struct ToolExchange: Hashable, Sendable {
    let toolUseID: String    // provider's tool_use id (round-trips on the result)
    let toolName: String
    let inputJSON: String    // as emitted by the model
    let resultJSON: String   // serialised FactValue
}

protocol AIProvider {
    var id: ProviderID { get }
    var availableModels: [ModelOption] { get }
    var requiresKey: Bool { get }
    var isAvailable: Bool { get }
    func send(
        messages: [ChatTurn],
        model: ModelOption,
        contextRendered: String,
        systemPrompt: String,
        tools: [ToolSpec],
        toolRounds: [[ToolExchange]]
    ) -> AsyncThrowingStream<AIStreamEvent, Error>
}

// A cloud provider on the user's own key: requiresKey is true, isAvailable is
// "a key is stored for id", and availableModels is the type's catalog.
protocol KeyedCloudProvider: AIProvider {
    static var models: [ModelOption] { get }
}

// A KeyedCloudProvider that speaks Chat Completions. Its send comes from the
// protocol extension and streams through OpenAICompatibleStreamer.
protocol OpenAICompatibleProvider: KeyedCloudProvider {
    static var endpoint: URL? { get }
    static var reasoning: OpenAICompatibleStreamer.Reasoning { get }
}

// Concrete implementations
final class AppleFoundationProvider: AIProvider              // iOS 26+ via FoundationModels — tool-capable
final class AnthropicProvider: KeyedCloudProvider            // Messages API + cache_control breakpoints (1h tools / 5min system / 5min history)
final class GeminiProvider: KeyedCloudProvider               // streamGenerateContent w/ functionDeclarations
final class OpenAIProvider: OpenAICompatibleProvider         // api.openai.com, reasoning .effortNone
final class GrokProvider: OpenAICompatibleProvider           // api.x.ai, reasoning .modelDefault
final class DeepSeekProvider: OpenAICompatibleProvider       // api.deepseek.com, reasoning .thinkingDisabled

enum OpenAICompatibleStreamer {                   // shared Chat Completions streamer for OpenAI/Grok/DeepSeek
    enum Endpoint { static let openAI, grok, deepSeek: URL? }
    enum Reasoning { case modelDefault, effortNone, thinkingDisabled }
    static func send(
        providerID: ProviderID,
        endpoint: URL?,                           // nil fails the stream with ProviderHTTP.badEndpoint
        reasoning: Reasoning,
        messages: [ChatTurn],
        model: ModelOption,
        contextRendered: String,
        systemPrompt: String,
        tools: [ToolSpec] = [],
        toolRounds: [[ToolExchange]] = []
    ) -> AsyncThrowingStream<AIStreamEvent, Error>
}

// What every cloud provider shares (AIProvider.swift, ProviderStream.swift)
enum ProviderHTTP {
    static let streamSession: URLSession          // waits for connectivity; 30 s request / 180 s resource
    static func streamRequest(url: URL, body: some Encodable, headers: [String: String]) throws -> URLRequest
    static func openStream(                       // the reply's lines once the status is 2xx
        _ request: URLRequest,
        provider: ProviderID,
        failure: (_ status: Int, _ body: Data) -> AIProviderError
    ) async throws -> AsyncLineSequence<URLSession.AsyncBytes>
    static func statusFailure(                    // credit exhaustion, then override, then statusError
        _ status: Int, body: Data, provider: ProviderID,
        override: StatusOverride = { _, _, _ in nil }
    ) -> AIProviderError
}

struct SSEEvents<Lines: AsyncSequence>: AsyncSequence   // the server-sent events in a reply's lines
    where Lines.Element == String { typealias Element = SSEEvent }   // SSEEvent: name?, data

enum ProviderStream {                             // runs a provider request and closes its stream
    static func make(_ operation: @escaping @Sendable (Continuation) async throws -> Void)
        -> AsyncThrowingStream<AIStreamEvent, Error>
    static func failure(from error: Error) -> Error   // cancellation → .cancelled, URLError → .network
}

extension AIProvider {
    // No-tools convenience overload for internal callers (chat
    // summarisation, auto-fact extraction). Forwards with empty arrays.
    func send(
        messages: [ChatTurn],
        model: ModelOption,
        contextRendered: String,
        systemPrompt: String
    ) -> AsyncThrowingStream<AIStreamEvent, Error>
}

@MainActor
@Observable
final class ProviderRegistry {
    static let shared: ProviderRegistry
    let apple, anthropic, openai, gemini, grok, deepseek: AIProvider
    var allProviders: [AIProvider]
    var visibleProviders: [AIProvider]            // Apple + any provider with a stored key

    private(set) var activeProvider: AIProvider
    private(set) var activeModel: ModelOption

    func setActive(provider: AIProvider, model: ModelOption? = nil)
    func setActive(model: ModelOption)
    func keysChanged()                            // re-evaluate availability after key add/remove;
                                                  // a switched-off provider never stays selected
                                                  // (falls back to Apple when nothing else is available)
    static func isEnabled(_ id: ProviderID) -> Bool        // its Settings switch
    static func canSend(to provider: AIProvider) -> Bool   // isAvailable && isEnabled; gates the composer,
                                                           // send, dispatch, routing and fact extraction
}
```

### Apple Tool wiring

Apple's `LanguageModelSession(tools:)` accepts an array of types
conforming to its `Tool` protocol. The adapter below wraps every
`ToolSpec` in a uniform shape — one `Arguments` type for the whole
catalog — and the dispatcher routes each call back through
`CompactToolRouter`.

```swift
@available(iOS 26, *)
struct AppleToolAdapter: Tool {
    let name: String
    let description: String
    let handler: @Sendable (String) async throws -> String   // argsJSON -> tool-result JSON

    @Generable
    struct Arguments {
        @Guide(description: "JSON object with the tool's arguments. Must be valid JSON matching the tool's documented schema.")
        let argumentsJSON: String
    }

    func call(arguments: Arguments) async throws -> String
}

enum AppleToolCatalog {
    /// Wrap a ToolSpec for use in LanguageModelSession(tools:).
    /// `handler` receives the model's arguments JSON and returns the
    /// rendered FactValue.toToolResultJSON() envelope.
    @available(iOS 26, *)
    static func wrap(
        _ spec: ToolSpec,
        handler: @escaping @Sendable (String) async throws -> String
    ) -> any Tool

    static func estimatedTokens(for spec: ToolSpec) -> Int
}

@MainActor
final class AppleToolDispatcher {
    static let shared: AppleToolDispatcher

    /// Set the active fact-resolver registry before each Apple-routed
    /// send. Called from `AssistantViewModel.dispatch()` immediately
    /// before `provider.send(...)` when the resolved provider is Apple.
    func setRegistry(_ registry: FactResolverRegistry?)

    /// Resolve a tool call by name + JSON args. Returns the tool's
    /// rendered `FactValue.toToolResultJSON()` envelope. When no
    /// registry is set, returns a documented error string so the model
    /// sees an explicit "no registry" rather than crashing.
    func dispatch(name: String, argumentsJSON: String) async throws -> String
}
```

### Apple context compaction

Apple's `LanguageModelSession` enforces a 4,096-token combined ceiling.
`AppleContextCompactor` drops oldest user/assistant pairs verbatim
once the transcript reaches 70% of the budget. Pure functions; safe
to call off-actor.

```swift
enum AppleContextCompactor {
    static let contextWindow: Int = 4096
    static let compactionThreshold: Double = 0.70

    /// `chars / 4 × 1.05` until iOS 26.4's `tokenCount(for:)` is gated.
    static func estimateTokens(_ text: String) -> Int

    /// Returns trimmed transcript + flag indicating whether any
    /// compaction occurred. Most-recent user turn always preserved.
    static func compact(
        _ messages: [ChatTurn],
        systemPromptTokens: Int
    ) -> (compacted: [ChatTurn], didCompact: Bool)

    /// Convenience for `AppleFoundationProvider.runStream(...)`.
    static func compactedPromptInput(
        messages: [ChatTurn],
        systemPromptTokens: Int
    ) -> [ChatTurn]
}
```

### Capability classifier

Replaces `SmartProviderRouter`'s prior length / complexity prototypes.
Four orthogonal binary capability flags, each gated by a keyword
marker AND embedding cosine ≥ 0.55 to a per-axis prototype centroid.
Reuses `SmartProviderRouter.shared.embed(_:)` for the embedder so the
asset download is shared.

```swift
@MainActor
final class CapabilityClassifier {
    static let shared: CapabilityClassifier

    enum Axis: String, CaseIterable { case tools, web, historicalDepth, speculation }

    struct Requirement: Equatable {
        let needsTools, needsWeb, needsHistoricalDepth, needsSpeculation: Bool

        var requiredTier: SmartProviderRouter.Tier  // 0 → .quick, 1 → .auto, ≥ 2 → .deep
        var debugSummary: String                    // "tools+web" / "history" / "none"
        static let none: Requirement
    }

    /// Stateless. Caller (SmartProviderRouter) layers stickiness.
    /// Keyword-gated: an axis fires only when BOTH the keyword
    /// heuristic AND the embedding cosine cross threshold. Text confidently
    /// not English opens every keyword gate; without an embedder the keyword
    /// result stands for English and `.none` is returned otherwise.
    func classify(_ message: String) -> Requirement
}
```

### Deterministic intent shortcut

14-pattern catalog mapping the highest-frequency voice queries to
fact-catalog reads + template renders. Bypasses the LLM entirely on
hit. Falls through on any miss.

```swift
@MainActor
enum DeterministicIntent {
    typealias Handler = @MainActor (_ utterance: String, _ context: MatchContext) -> String?

    struct MatchContext {
        let now: Date
        let archive: SessionArchive
        let userSettings: UserSettings
    }

    struct Pattern {
        let id: String
        let triggers: [String]                  // case-insensitive regexes
        let handler: Handler
        var compiled: [NSRegularExpression]
    }

    static let patterns: [Pattern]

    /// Returns a rendered string when a pattern matches AND its
    /// underlying fact value is non-nil. Otherwise returns nil and
    /// the caller falls through to the LLM.
    static func tryMatch(_ utterance: String, in context: MatchContext) -> String?

    /// The first pattern whose trigger matches the normalised utterance,
    /// and that utterance; nil for an empty utterance or no match.
    static func matchedPattern(for utterance: String) -> (pattern: Pattern, normalized: String)?
}
```

### Cache telemetry

```swift
@MainActor
@Observable
final class LLMCacheTelemetry {
    static let shared: LLMCacheTelemetry

    struct Totals: Equatable {
        var inputTokens, outputTokens, cachedReadTokens, cacheCreateTokens, turns: Int
    }
    private(set) var totals: Totals
    var totalInputTokens, totalOutputTokens, totalCachedReadTokens,
        totalCacheCreateTokens, totalTurns: Int { get }

    /// Called from each provider's `.usage` stream event, once per request (a
    /// turn with tool rounds counts once per round, in `totals.turns` too).
    /// Keeps the last 50 requests for the recent / per-provider figures.
    func record(provider: String, input: Int, output: Int, cachedRead: Int, cacheCreate: Int)

    /// cachedRead / (input + cachedRead + cacheCreate) across all turns.
    var cumulativeHitRatio: Double { get }

    /// The same ratio over the trailing N turns.
    func recentHitRatio(turns: Int = 10) -> Double

    /// Per-provider turns and hit ratio over the retained turns, busiest first.
    func perProviderSummary() -> [(provider: String, turns: Int, hitRatio: Double)]

    func reset()
}
```

### Routing infrastructure

Routing modes act only while Apple Intelligence is the selected model.
With any other model selected, or in Manual, every turn goes to the
selected model (`TurnRouter.preTierDecision`). With Apple selected,
voice turns go to the first consented cloud provider in registry order
(Apple if none), and Quick / Auto / Deep map as below; an action request
that needs tools Apple can't call goes to the first consented
cloud provider.

- Quick → Apple.
- Auto → `CapabilityClassifier` proposes a tier per turn; the mid tier is
  consented Grok, then DeepSeek (Apple if neither).
- Deep → with Apple as primary, the same consented mid-tier cloud as
  Auto (Apple only if none is consented).

If the model a turn goes to fails, `TurnRouter.failureFallback` decides
who may answer instead: Auto and Deep any consented model
(`.anyAccepted`), Quick only Apple Intelligence (`.onDeviceOnly`), and
Manual or a selected cloud model nothing (`.none`; the turn shows
`PickedModelFailure`).

```swift
@MainActor
final class SmartProviderRouter {
    static let shared: SmartProviderRouter

    enum Tier: Int, Comparable { case quick = 1, auto, deep }

    /// Apply session stickiness on top of a fresh classification.
    /// Returns the tier this turn should run on.
    /// (Now sourced from `CapabilityClassifier.shared.classify(_:)`.)
    func route(message: String, in session: RoutingSessionState) -> Tier

    /// Daily Tier-3 ceiling = 50. Returns true while under cap;
    /// false on overshoot so the caller can downgrade Deep → Auto
    /// for the rest of the local day.
    func recordTier3UsageAndCheck() -> Bool

    /// Shared embedder hook for CapabilityClassifier: the contextual
    /// embedder's mean-pooled vector when one exists (nil when it fails for
    /// this text), else the word-vector mean — one vector space per launch.
    func embed(_ text: String) -> [Double]?
}

/// Per-conversation routing state. Lives on the AssistantViewModel.
@MainActor
final class RoutingSessionState {
    var currentTier: SmartProviderRouter.Tier
    var turnCount: Int
    init(initialTier: SmartProviderRouter.Tier = .quick)
}

enum TierProviderMapper {
    struct Mapping {
        let provider: AIProvider
        let model: ModelOption
        let collapsed: Bool   // true when no distinct provider available for the requested tier
    }
    @MainActor
    static func mapping(
        for tier: SmartProviderRouter.Tier,
        registry: ProviderRegistry
    ) -> Mapping
}
```

### Keys

```swift
final class APIKeyStore: Sendable {
    static let shared: APIKeyStore           // the app's Keychain service
    /// Keys under `keychainService`; a test uses its own service so it never
    /// reads or removes the app's keys.
    init(keychainService: String)
    func key(for provider: ProviderID) -> String?
    func hasKey(for provider: ProviderID) -> Bool
    @discardableResult func setKey(_ key: String?, for provider: ProviderID) -> Bool
    @discardableResult func removeKey(for provider: ProviderID) -> Bool
    func maskedPreview(for provider: ProviderID) -> String?    // "•••••wxyz"
}
```

Backed by `kSecClassGenericPassword` in Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — device-local, never iCloud-synced.

### Chat layer

```swift
final class ConversationStore {
    static let shared: ConversationStore
    func load() -> [ChatTurn]
    func save(_ turns: [ChatTurn])
    @discardableResult func clear() -> Bool    // file + summary + set-aside copies; true when nothing is left
    /// The sealed rolling summary (Assistant/conversation_summary.json). A plain
    /// summary an older build left under `key` is moved in; the key is removed
    /// once the sealed write succeeds.
    func loadSummary(migratingFrom defaults: UserDefaults, key: String) -> String?
    func saveSummary(_ text: String)
}

enum PrefabQuestion: String, CaseIterable, Identifiable {
    // 10 cases: howAmIDoing, whyIsScoreThis, shouldITrainHard, whatChanged,
    // howVsBaseline, wasSleepGood, isTrainingLoadOK, focusThisWeek,
    // trendingUpDown, whatDoesHRVTellYou
    var label, prompt: String
}

final class AnalysisSummaryCache: Sendable {
    static let shared: AnalysisSummaryCache       // LRU, 32 entries keyed by (session, fingerprint)
    static func fingerprint(for session: HRVSession) -> Int
    static func fingerprint(for session: HRVSession, inputs: Int) -> Int
    func set(_ summary: AnalysisSummaryGenerator.AnalysisSummary, forSessionId id: UUID, fingerprint: Int = 0)
    func get(forSessionId id: UUID, matching fingerprint: Int) -> AnalysisSummaryGenerator.AnalysisSummary?
    func clear()
}

@Observable
final class UserFactsStore {
    static let shared: UserFactsStore
    struct Fact: Codable, Identifiable, Hashable {
        let id: UUID; var text: String; let createdAt: Date
        enum Origin: String, Codable { case user, inferred }   // inferred = auto-extraction
        let origin: Origin?            // nil: saved before origins were recorded
        var isFromUser: Bool { get }   // origin == .user
    }
    private(set) var facts: [Fact]
    var autoExtractEnabled: Bool       // off by default
    func add(_ text: String, origin: Fact.Origin)   // no default origin
    @discardableResult func remove(_ id: UUID) -> Bool   // written at once; false keeps the fact
    @discardableResult func clear() -> Bool              // facts + set-aside copies; false keeps them
    var hasAnythingToForget: Bool                        // a fact or a set-aside copy is stored
    func systemPromptBlock() -> String            // injected into every send's system prompt; the user's
                                                  // own facts and the rest under separate headings
}

@MainActor
@Observable
final class AssistantInbox {
    static let shared: AssistantInbox
    var pendingDraft: String?       // Dashboard ✨ menu / History "Ask AI" write here
    var openRequestToken: UUID?     // MainTabView observes to switch to Assistant tab
    func requestOpen()                         // Bumps openRequestToken to a fresh UUID
}

enum AssistantCitationResolver {
    static let urlScheme = "flowrecovery"
    static let sessionHost = "session"
    static func annotate(_ text: String, archive: SessionArchive = .shared) -> String
    static func parseSessionURL(_ url: URL) -> UUID?
}

@MainActor
@Observable
final class SpeechInputManager {
    private(set) var transcript: String
    private(set) var isRecording: Bool
    private(set) var lastError: String?
    var isAvailable: Bool                         // requires on-device recognition support
    func start() async throws                     // requests mic + speech permissions
    /// Stops the mic at once; returns once the final recognition result
    /// arrives or `finalResultTimeout` (1.5 s) passes.
    @discardableResult func stop() async -> String
    func cancel()
}
```

### View model

```swift
@MainActor
@Observable
final class AssistantViewModel {
    static let shared: AssistantViewModel

    private(set) var turns: [ChatTurn]
    private(set) var isStreaming: Bool
    var errorMessage: String?
    private(set) var priorSummary: String?     // auto-summary of dropped turns
    var hasAcceptedDisclaimer: Bool
    var pendingDraft: String?

    /// Which provider+model handled the most recent turn — exposed
    /// so the voice controller's "Coach here, Sonnet." earcon names
    /// the active model.
    var activeProviderID: ProviderID
    var activeModelDisplayName: String        // "Apple" / "Sonnet" / "Haiku" / "GPT" / etc.

    /// Outcome of a `send(text:)` call. Lets the voice controller know
    /// whether the user's turn dispatched immediately or got queued
    /// behind an in-flight stream.
    enum SendOutcome {
        case dispatched, queued, rejectedEmpty, rejectedNoProvider
        case requiresConsent(ProviderID)   // present ProviderConsentSheet first
    }

    var canSend: Bool

    /// `fromVoice == true` triggers the voice-mode bypass in
    /// `resolveProviderForThisTurn()` when Apple is the selected model —
    /// the turn skips `SmartProviderRouter` and goes to the first
    /// consented cloud provider in registry order (Apple if none).
    /// With any other model selected, every turn goes to that model.
    @discardableResult
    func send(text: String, fromVoice: Bool = false) -> SendOutcome

    func send(prefab question: PrefabQuestion)
    func cancel()
    func clearConversation()                   // also MetricsVerifier.clearCorrections()
    func regenerateLast()                      // dispatch(regenerating:): the old reply is removed only
                                               // once the routed provider may take the turn
    func remember(_ text: String)              // saved with origin .user
    func invalidateContext()
    func exportConversation() -> URL?          // tmp EmuquChat-*.md, complete file protection;
                                               // earlier exports deleted at init

    static func truncateForSend(_ turns: [ChatTurn], provider: ProviderID) -> (kept: [ChatTurn], dropped: [ChatTurn])
    /// The oldest of `turns` that fit one summarization call on `provider`
    /// (at least one, each cut to the budget); one batch per send.
    static func summaryBatch(_ turns: [ChatTurn], provider: ProviderID) -> [ChatTurn]
    static func estimateTokens(_ text: String) -> Int     // ~4 chars/token rough estimate
}
```

### Notifications

```swift
extension Notification.Name {
    static let flowRecoveryArchiveChanged: Notification.Name
    // Posted by SessionArchive.archive(_:) and update(_:) (object: the
    // session id), by batch archiving (per merged id, then once with nil),
    // by DataPurgeService after a purge, and by ArchiveSignal.notifyChanged().
    // Observers include ArchiveSignal, the training-load and heat-acclimation
    // caches, BeatConsistencyPriorsCache and AssistantViewModel (drops its
    // fact registry).
}
```

`SessionArchive.delete(_:)` does **not** post it: a caller that deletes
must announce the change itself (History's `SessionTrash.move` and the
recovered-workout discard do, through `ArchiveSignal.notifyChanged()`).
`SessionTrash.move(_:collector:cloudKit:) async throws` runs the archive
delete off the main actor and notifies and uploads the deletion only once
it has succeeded. A session deleted on another
device and removed here by the CloudKit pull
(`CloudKitSyncManager+Pull.swift`, `handleDeletedRecord`) only bumps
`CloudKitSyncManager.pullVersion`; observers of this notification are not
told until the next archive write.

---

> **This reference is partial and hand-maintained.** It documents the
> subsystems listed below and not the whole codebase, and it can lag the
> source. `scripts/check_doc_links.sh` verifies that every file path cited
> here exists — that check caught a section describing a type deleted eleven
> weeks earlier — but nothing verifies that a documented *signature* still
> matches its implementation. Treat the source as authoritative and this as
> orientation.

> **Known coverage gaps** — this reference is not exhaustive. The Fitness /
> Workout subsystem (`WorkoutRecorder`, `WorkoutAnalyzer`, `WorkoutPDFReport`,
> `LiveDFAAnalyzer`, `LiveWorkoutBroker`, `HRRCaptureService`,
> `BarometricAltitudeProcessor`, `TopoElevationService`, `WorkoutLocationManager`,
> `IntervalController`, `FootPodManager`, `ZwiftPeripheralBroadcaster`),
> the Fact Catalog
> (`FactCatalog`, `FactKey`, `FactValue`, `AppFactResolver`,
> `CompactToolRouter`), the Voice
> subsystem (`VoiceConversationController`, `SpokenTextChunker`), and several
> Services (`DataPurgeService`, `WatchConnectivityBridge`, `SettingsManager`,
> `CloudKitLiveBackupManager`) are documented in ARCHITECTURE.md /
> VOICE_AND_TOOL_USE.md but do not yet have full per-symbol entries here.
> The routing & cache infrastructure
> (`CapabilityClassifier`, `DeterministicIntent`, `AppleToolAdapter`,
> `AppleToolDispatcher`, `AppleContextCompactor`, `LLMCacheTelemetry`,
> `SmartProviderRouter`, `TierProviderMapper`) is
> documented above. A full pass on the remaining gaps is tracked as
> follow-up work. Quick-reference signatures for the supporting modules
> below — `WeatherService`, `RoadGeocodingService`, `TrailDiscoveryService`,
> `WebSearchService`, `Concept2Manager`, `APIKeyStore`, `SavedRouteStore`,
> plus the `WorkoutThreshold` / `Route` / `SavedRoute` model types.

### WorkoutThreshold

```swift
struct WorkoutThreshold: Codable, Identifiable, Equatable, Hashable {
    enum Metric: String, Codable, CaseIterable {
        case heartRateBPM, heartRateZone
        case powerWatts, powerPercentFTP
        case paceSecPerKm
        case alpha1
        case cadenceSPM
    }
    enum Condition: String, Codable { case greaterThan, lessThan }

    let id: UUID
    let metric: Metric
    let condition: Condition
    let value: Double
    let debounceSec: Int    // default 30
    let cooldownSec: Int    // default 120
    let userCue: String?

    func evaluate(
        hrBPM: Int?, hrZone: Int?,
        powerWatts: Int?, ftpWatts: Int?,
        paceSecPerKm: Double?, alpha1: Double?, cadenceSPM: Double?
    ) -> Bool?  // nil = metric unavailable
    func defaultCue(currentValue: Double) -> String
}
```

### Route, RouteProgress

```swift
struct Route {
    let name: String
    let trackpoints: [Trackpoint]    // lat/lon/alt/cumulativeDistance
    let totalDistanceMeters: Double
    let totalAscentMeters: Double
    let totalDescentMeters: Double
    let climbs: [Climb]              // ≥30 m gain at ≥3 % grade

    static func fromGPX(name: String, track: [CLLocation]) -> Route
}

struct RouteProgress {
    static func compute(currentLocation: CLLocation, route: Route) -> RouteProgress
    // distanceCoveredMeters, distanceRemainingMeters, percent, …
}
```

### SavedRoute / SavedRouteStore

```swift
struct SavedRoute: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    let createdAt: Date
    let sport: Sport
    let encodedPolyline: Data        // same codec as WorkoutMetadata.gpsPolyline
    let totalDistanceMeters: Double
    let totalAscentMeters: Double
    let totalDescentMeters: Double
    let climbCount: Int

    func toRoute() -> Route
    static func from(session: HRVSession, name: String) -> SavedRoute?
}

@MainActor
@Observable
final class SavedRouteStore {
    static let shared: SavedRouteStore
    private(set) var routes: [SavedRoute]

    func add(_ route: SavedRoute)
    func rename(id: UUID, to newName: String)
    @discardableResult func remove(id: UUID) -> Bool   // written at once; false keeps the route
    func routes(for sport: Sport) -> [SavedRoute]
}
```

Writes go through `LatestWinsFileWriter`: a failed write is retried after 5,
30 and 120 s unless a newer snapshot, a discard or a replace superseded it,
and the file has `.completeFileProtectionUntilFirstUserAuthentication`.

### RouteLibrary

```swift
@MainActor
enum RouteLibrary {
    static let detectionTriggerMeters: Double = 500
    static let matchToleranceMeters: Double = 30
    static let supportedSports: Set<Sport> = [.run, .trailRun, .walk, .hike, .bike]

    enum Direction: Equatable { case forward, reverse }

    struct Match: Equatable {
        let savedRoute: SavedRoute
        let route: Route
        let direction: Direction
        let meanFitMeters: Double
    }

    static func findMatch(
        currentTrack: [CLLocation],
        sport: Sport,
        store: SavedRouteStore = .shared
    ) -> Match?
}
```

### WeatherService

```swift
@MainActor
@Observable
final class WeatherService {
    static let shared: WeatherService
    init(transport: HTTPTransport = .live)
    static let cacheTTL: TimeInterval = 30 * 60
    static let minimumRequestInterval: TimeInterval = 10 * 60
    static let maxSnapshotAge: TimeInterval = 3 * 3600
    nonisolated static let userAgent: String  // "Emuqu/<version> github.com/chrissharp80/emuqu"

    var current: WorkoutAIContext.WeatherSnapshot? { get }  // nil once older than maxSnapshotAge

    func refreshIfNeeded(for location: CLLocation?)
    func forgetAfterPurge()   // Delete All My Data: drop snapshot, forecast and place; cancel a fetch in flight
    nonisolated static func fetch(at coord: CLLocationCoordinate2D, ifModifiedSince: String?,
                                  transport: HTTPTransport) async -> FetchOutcome
    nonisolated static func localizedConditions(_ english: String) -> String
}

struct MetNorwayForecast {
    let hours: [Hour]
    let lastModified: String?
    var expires: Date?

    func snapshot(at date: Date) -> WorkoutAIContext.WeatherSnapshot?
    static func parse(_ data: Data) throws -> [Hour]
    static func conditions(forSymbol symbol: String?) -> String
    static func httpDate(_ string: String) -> Date?
}
```

Backed by MET Norway Locationforecast 2.0 compact (CC BY 4.0; credit
"Weather data: MET Norway (CC BY 4.0)"). Every request carries the
identifying `userAgent` and coordinates rounded to 2 decimals. A new
request waits at least 10 minutes after the last one, and for the same
place until the cache TTL or the response's `Expires` time, whichever is
later; a repeat for the same place sends `If-Modified-Since`, and a 304
keeps the held forecast. The cache also refetches after >5 km of
movement. The snapshot is the forecast step nearest now; MET Norway gives
no apparent temperature, so that field is nil. Fetch failures are logged
and leave `current` unchanged until it ages out. Requests go through the
injected `HTTPTransport` (`.live` sends on `URLSession.shared`), so tests
answer them without the network.

### RoadGeocodingService

```swift
@MainActor
@Observable
final class RoadGeocodingService {
    static let shared: RoadGeocodingService

    private(set) var current: RoadContext?

    struct RoadContext: Equatable {
        let road: String?
        let locality: String?
        let administrativeArea: String?
        let country: String?
        let countryCode: String?
        let observedAt: Date
        let observedAtCoord: CLLocationCoordinate2D
        var compactAddress: String { get }
    }

    func refreshIfNeeded(for location: CLLocation?)
    func reset()                             // call at workout start
    func forgetAfterPurge()                  // Delete All My Data: drop the road context and where it was looked up

    /// One-shot for off-cache geocoding (used by SavedRouteStore's
    /// climb-naming pass at save time).
    static func resolveRoadName(at coord: CLLocationCoordinate2D) async -> String?
}
```

Apple `CLGeocoder` wrapper. Re-geocodes only on >15 m movement OR
>60 s elapsed. Backs off after 8 consecutive failures, then retries
every 30 s. A `CLGeocoder` request still running after its 5 s timeout
is cancelled before the queue's next turn (`geocoderRequest`). No API key
required.

### TrailDiscoveryService

```swift
final class TrailDiscoveryService: @unchecked Sendable {
    static let shared: TrailDiscoveryService

    enum Activity: String, Codable, CaseIterable, Identifiable {
        case hiking, mountainBiking, roadCycling
        var workoutSport: Sport { get }
    }

    enum Difficulty: String, Codable, Comparable, CaseIterable, Identifiable {
        case easy, moderate, hard, expert, unknown
    }

    struct DiscoveredTrail: Identifiable, Sendable {
        let id: String
        let name: String
        let activity: Activity
        let lengthMeters: Double
        let difficulty: Difficulty
        let centerCoord: CLLocationCoordinate2D
        let trackpoints: [CLLocationCoordinate2D]
        let descriptor: String?

        func distanceFrom(_ location: CLLocation) -> Double
    }

    struct SearchFilters {
        var activity: Activity
        var radiusMeters: Double = 10_000
        var minLengthMeters: Double?
        var maxLengthMeters: Double?
        var minDifficulty: Difficulty?
        var maxDifficulty: Difficulty?
        var maxResults: Int = 25
    }

    func search(near location: CLLocation, filters: SearchFilters) async throws -> [DiscoveredTrail]
}
```

OpenStreetMap Overpass API client. POSTs Overpass QL queries with
sport-specific tag selectors (route=hiking / route=mtb /
route=bicycle relations + named highway=path / footway / cycleway
ways). Free, no API key, global. Sorted results capped at 25.

### WebSearchService

```swift
final class WebSearchService: Sendable {
    static let shared: WebSearchService
    init(transport: HTTPTransport = .live)

    enum Intent: String, Codable {
        case research, manufacturer, general
    }

    struct Result: Codable, Equatable {
        let title: String
        let url: String
        let content: String
        let score: Double
        let publishedDate: String?
    }

    enum SearchError: Error, LocalizedError {
        case notEnabled, missingKey, network(String)
        case decode(String), rateLimited
    }

    func search(query: String, intent: Intent = .research, maxResults: Int = 5)
        async throws -> [Result]
    func send(query: String, intent: Intent, maxResults: Int, apiKey: String)
        async throws -> [Result]

    /// Curated authority-domain whitelists baked in:
    static let researchAuthorityDomains: [String]
    static let manufacturerAuthorityDomains: [String]
    static let excludeDomains: [String]
}
```

Tavily-backed search for the AI assistant. Off by default — gated on
`UserSettings.enableWebSearch` AND a keychain'd Tavily key, which
`search` checks before handing over to `send`. `send` builds the request
(the key in an `Authorization: Bearer` header), sends it through the
injected `HTTPTransport`, maps the HTTP status and parses the results; a
transport error is thrown unchanged. Three curated domain whitelists.
Intentionally NOT @MainActor so async work runs off-MainActor and the
resolver bridge can't deadlock.

### APIKeyStore (extended)

```swift
final class APIKeyStore {
    static let shared: APIKeyStore

    // Existing AI provider key API
    func key(for provider: ProviderID) -> String?
    func setKey(_ key: String?, for provider: ProviderID) -> Bool
    func removeKey(for provider: ProviderID) -> Bool
    func maskedPreview(for provider: ProviderID) -> String?

    // Non-AI service key API (Tavily, etc.)
    enum ServiceKeyID: String, CaseIterable {
        case tavilyWebSearch = "service.tavily_web_search"
    }

    func serviceKey(for service: ServiceKeyID) -> String?
    func hasServiceKey(for service: ServiceKeyID) -> Bool
    func setServiceKey(_ key: String?, for service: ServiceKeyID) -> Bool
    func removeServiceKey(for service: ServiceKeyID) -> Bool
    func maskedServicePreview(for service: ServiceKeyID) -> String?

    // Removes all AI provider keys + all service keys; true when every deletion succeeded
    func removeAllKeys() -> Bool
}
```

### SavedRouteStore (extended)

```swift
@MainActor
@Observable
final class SavedRouteStore {
    // Existing CRUD
    func add(_ route: SavedRoute)
    func rename(id: UUID, to newName: String)
    @discardableResult func remove(id: UUID) -> Bool
    func routes(for sport: Sport) -> [SavedRoute]

    /// Background road-name enrichment. Geocodes each climb's start
    /// coord (paced 600ms apart for CLGeocoder rate limit) and persists
    /// the enriched climbs onto the SavedRoute. Idempotent — running
    /// on an already-enriched route is a no-op.
    func enrichWithRoadNames(routeID: UUID)
}
```

### Concept2Manager (PM5 rower)

```swift
@Observable
@MainActor
final class Concept2Manager: NSObject, BLEPeripheralConnecting {
    static let shared: Concept2Manager
    private(set) var connectionState: ConnectionState
    private(set) var distanceMeters: Double?
    private(set) var paceSecPer500m: Double?
    private(set) var strokeRateSPM: Double?
    private(set) var dragFactor: Int?
    private(set) var instantaneousPowerWatts: Int?
    private(set) var strokeCount: Int?
    /// The PM5 linked now (set on attach, cleared on disconnect); the
    /// sensor row's title names it.
    private(set) var linkedDeviceId: String?

    func startScanning()
    func stopScanning()
    func reconnectLast()
    func disconnect()
}
```

BLE central; Rowing service `0x0030`, characteristics `0x0031`
(general status), `0x0032` (additional status), `0x0036` (additional
stroke data: stroke power, stroke count).

### ZwiftPeripheralBroadcaster

```swift
@Observable
@MainActor
final class ZwiftPeripheralBroadcaster: NSObject {
    static let shared: ZwiftPeripheralBroadcaster
    private(set) var isAdvertising: Bool
    private(set) var subscriberCount: Int

    func startBroadcasting()
    func stopBroadcasting()
    func update(heartRate: Int?, powerWatts: Int?)
}
```

`CBPeripheralManager` advertising Heart Rate Service (`0x180D`) +
Cycling Power Service (`0x1818`). Off by default — gated on
`UserSettings.enableZwiftBroadcast` and on this device's acceptance of the
broadcaster disclosure (`BroadcasterDisclosure.allowsBroadcast`), which is kept
outside the iCloud settings backup. `WorkoutRecorder` starts advertising
shortly after a workout starts (`deferZwiftBroadcast`) and stops it at the
end; every recorder tick (`pushZwiftBroadcasterUpdate`, ~1 Hz) calls
`update(heartRate:powerWatts:)` with the live HR and power, which notifies
subscribed centrals and is a no-op while not advertising. Required new
`bluetooth-peripheral` UIBackgroundMode.

### WorkoutAIContext (additions)

```swift
struct WorkoutAIContext: Equatable {
    // ...existing fields...
    let activeThresholds: [WorkoutThreshold]
    let thresholdBreachSec: [UUID: Int]
    let upcomingClimb: UpcomingClimb?
    let routeTopology: RouteTopology?
    let weather: WeatherSnapshot?

    struct UpcomingClimb: Equatable {
        let distanceMeters: Double      // distance ahead
        let gradePercent: Double
        var lengthMeters: Double = 0    // length of the climb itself
        var gainMeters: Double = 0
    }

    struct RouteTopology: Equatable {
        let climbsAhead: [UpcomingClimb]            // capped at 5
        let totalAscentRemainingMeters: Double
        let peakAltitudeMeters: Double
        let altitudeAboveRouteMinMeters: Double
        let steepestGradeAheadPercent: Double?
        let metersToPeak: Double
    }

    struct WeatherSnapshot: Equatable {
        let temperatureC: Double
        let apparentTemperatureC: Double
        let windKMH: Double
        let windDirectionDegrees: Double
        let humidityPercent: Double
        let conditions: String
        let observedAt: Date
    }
}
```

### UserSettings (new fields)

```swift
struct UserSettings: Codable {
    // ...existing fields...
    var runningFTPWatts: Int?
    var cyclingFTPWatts: Int?
    var enableZwiftBroadcast: Bool = false

    var effectiveRunningFTP: Int? { get }   // nil when not set — caller renders "set FTP" cue
    var effectiveCyclingFTP: Int? { get }
}
```

### WorkoutMetadata (new fields)

```swift
struct WorkoutMetadata: Codable {
    // ...existing fields...
    // Power-derived (Stryd / FTMS / PM5 / CPS)
    var powerTSS: Double?
    var intensityFactor: Double?
    var variabilityIndex: Double?
    var ftpAtTimeOfSession: Int?

    // Rowing-specific (Concept2 PM5)
    var strokeCount: Int?
    var averageSplitSecPer500m: Double?
    var dragFactor: Int?

    /// When each fix of `gpsPolyline` was taken (WorkoutAnalyzer.encodeFixTimes;
    /// read by GPXExporter.recordedFixTimes for the GPX/TCX exports). Nil for a
    /// workout recorded before it was stored: its exports spread the times evenly.
    var gpsFixTimes: Data?

    /// Seconds spent moving: the last per-second sample's offset, else
    /// `wallClockDuration` less the recorded pauses. Pace, calories and a TCX
    /// lap's timer time are measured on it.
    func movingSeconds(wallClockDuration: Double?) -> Double?
}

extension HRVSession {
    /// The one moving time every reader uses (coach, race prediction,
    /// baselines, PDF, TCX): `workoutMetadata.movingSeconds(wallClockDuration:)`,
    /// else the positive duration of a session without workout metadata.
    var activeWorkoutSeconds: Double? { get }
}

/// File: `Emuqu/Sources/Analysis/WorkoutLiveTrends.swift`. The live trends,
/// kept as the sample buffer grows (WorkoutRecorder.syncedLiveTrends()).
extension WorkoutLiveTrends {
    struct Tally {
        /// Adds the samples appended since the last call; starts over when the
        /// buffer is not the one it holds grown (new workout, trim, replace).
        mutating func catchUp(to buffer: [WorkoutSample])
        var hrDriftPercent: Double? { get }
        var cadenceDriftSpm: Double? { get }
        var aerobicDecouplingPercent: Double? { get }
        var reverseSplitDeltaSecPerKm: Double? { get }
        var recentHRSlopeBpm: Double? { get }
        var recentSplitGradeAdjustedPaces: [Double] { get }
        var kilometreChunks: [WorkoutGeometry.SplitChunk] { get }
        var projectedMinutesUntilFade: Double? { get }
        var sessionAverageHR: Double? { get }
    }
}

/// File: `Emuqu/Sources/Analysis/ArchiveAccessFailure.swift`.
enum ArchiveAccessFailure {
    /// True for a failed archive read or write that clears by itself (data
    /// protection with the device locked, a full disk, the keychain refusing
    /// the key for now); the launch scans stay unstamped only for these.
    static func mayClear(_ error: any Error) -> Bool
}

extension WorkoutRecorder {
    /// Renders the coach report PDF off the main actor and stages the email
    /// draft; the task's value is true when the PDF was attached.
    @discardableResult static func scheduleCoachReportEmail(for session: HRVSession) -> Task<Bool, Never>
}

/// `GPXImporter` (`Emuqu/Sources/Analysis/GPXImporter.swift`) and `ImportedWorkoutBuilder`
/// (`Emuqu/Sources/Import/ImportedWorkoutBuilder.swift`) are nonisolated: a GPX file is
/// parsed and built into a session off the main actor.
enum GPXImporter {
    static func parse(data: Data, defaultSport: Sport = .run) throws -> ImportedWorkoutTrack
    static func buildSession(from parsed: ImportedWorkoutTrack) -> HRVSession
}

enum Sport: String, Codable, CaseIterable, Identifiable {
    case run, trailRun, walk, hike, bike, indoorBike, treadmill, row, airBike, crossFit
}
```
>
> Signatures can still drift ahead of this reference between reviews.
> Treat the source as authoritative when the two disagree.
