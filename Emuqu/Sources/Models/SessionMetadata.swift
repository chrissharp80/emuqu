import Foundation
import UIKit

// Device provenance, session type and data-quality types, split out of
// `HRVSession.swift` at a top-level type boundary. The session
// itself and its reading tags stay behind; these describe where a session came
// from and how good it is.

// MARK: - Device Provenance

/// Metadata about the source device for RR data
struct DeviceProvenance: Codable, Equatable {
    /// Device identifier (e.g., "Polar H10 A1B2C3D4")
    let deviceId: String
    /// Device model (e.g., "Polar H10")
    let deviceModel: String
    /// Firmware version if available (e.g., "5.0.0")
    let firmwareVersion: String?
    /// Recording mode used
    let recordingMode: RecordingMode
    /// App version that collected the data
    let appVersion: String
    /// iOS version at time of collection
    let osVersion: String
    /// Timestamp when provenance was captured
    let capturedAt: Date

    enum RecordingMode: String, Codable {
        case deviceInternal = "device_internal" // H10 internal memory recording
        case streaming // Real-time BLE streaming
        case imported // Imported from external source
    }

    /// Sampling assumptions for this device/mode
    var samplingNotes: String {
        switch deviceModel.lowercased() {
        case let model where model.contains("polar h10"):
            "Polar H10: RR intervals at 1ms resolution, ECG-derived, no interpolation"
        case let model where model.contains("verity") || model.contains("sense"):
            "Polar Verity Sense: PP intervals from optical PPG, quality-filtered (error < 20ms, no blocker)"
        case let model where model.contains("polar"):
            "Polar device: RR intervals, optical or ECG-derived"
        default:
            "Unknown device: RR interval accuracy may vary"
        }
    }

    /// Create provenance for current device
    static func current(deviceId: String, deviceModel: String, firmwareVersion: String? = nil, recordingMode: RecordingMode) -> DeviceProvenance {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let osVersion = DeviceInfo.systemVersion
        return DeviceProvenance(
            deviceId: deviceId,
            deviceModel: deviceModel,
            firmwareVersion: firmwareVersion,
            recordingMode: recordingMode,
            appVersion: appVersion,
            osVersion: osVersion,
            capturedAt: Date()
        )
    }

    /// Create provenance for imported data
    static func imported(source: String) -> DeviceProvenance {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let osVersion = DeviceInfo.systemVersion
        return DeviceProvenance(
            deviceId: "imported",
            deviceModel: source,
            firmwareVersion: nil,
            recordingMode: .imported,
            appVersion: appVersion,
            osVersion: osVersion,
            capturedAt: Date()
        )
    }
}

// MARK: - Session Type

/// Type of HRV session - affects how it's stored and analyzed
enum SessionType: String, Codable, CaseIterable {
    case overnight // Primary daily reading (used in trends)
    case nap // Nap recording (separate from daily readings)
    case quick // Quick spot-check readings (2-5 min)
    case breathe // Apple Watch Breathe app HRV reading (SDNN only)
    case workout // Fitness effort capture — pairs with HRVSession.workoutMetadata

    var displayName: String {
        switch self {
        case .overnight: String(localized: "Overnight", bundle: LanguageManager.appBundle)
        case .nap: String(localized: "Nap", bundle: LanguageManager.appBundle)
        case .quick: String(localized: "Quick Reading", bundle: LanguageManager.appBundle)
        case .breathe: String(localized: "Watch Breathe", bundle: LanguageManager.appBundle)
        case .workout: String(localized: "Workout", bundle: LanguageManager.appBundle)
        }
    }

    var icon: String {
        switch self {
        case .overnight: "moon.stars.fill"
        case .nap: "powersleep"
        case .quick: "bolt.fill"
        case .breathe: "applewatch"
        case .workout: "figure.run"
        }
    }
}

// MARK: - HRV Data Quality

/// Quality classification of HRV recording relative to actual sleep.
/// Used to decide whether recorded HRV should drive the score or be
/// replaced with baseline + subjective input.
enum HRVDataQuality: String, Codable {
    /// Recording overlaps with HealthKit sleep — normal scoring path
    case good
    /// Recording ended before sleep started (strap disconnected pre-sleep)
    case preSleep
    /// Recording too short for reliable analysis (< 2 minutes of clean data)
    case insufficient
}

// MARK: - HRV Session

/// Represents a complete HRV collection session
struct HRVSession: Codable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    /// Schema version read from the payload during decode; nil for sessions
    /// constructed in memory (never decoded). Transient — deliberately NOT
    /// encoded: `encode(to:)` always writes `currentSchemaVersion`, because a
    /// re-encode by this build produces this build's schema.
    ///
    /// Decode must not DISCARD the version (`_ = decodeIfPresent`):
    /// that makes newer-format payloads silently destructible. A v2 session
    /// pulled from CloudKit onto an older build decodes lossily (unknown keys
    /// dropped), and the next re-archive would overwrite the file with the
    /// lossy copy, permanently destroying the v2-only fields. Decoding still
    /// SUCCEEDS for display compatibility; `SessionArchive._archive` consults
    /// this flag and refuses the destructive re-write.
    var sourceSchemaVersion: Int?

    let id: UUID
    let startDate: Date
    var endDate: Date?
    var state: SessionState
    var sessionType: SessionType
    var rrSeries: RRSeries?
    var artifactFlags: [ArtifactFlags]?
    var analysisResult: HRVAnalysisResult?
    /// Composite recovery score on a 0-10 scale (maps to ReadinessConstants).
    /// Under the v3.oct2026 architecture: combines HRV readiness, sleep
    /// quality, and vitals (resp rate / wrist temp / sleep HR dip) via
    /// RecoveryScoreCalculator. Comeback mode shifts the weights to
    /// HRV 80 / Sleep 20 / Vitals 0 for 21 days. Initially set to the
    /// HRV-only readiness (ANSMetrics.readinessScore) as a fallback until
    /// the full composite is computed by RRCollector.computeRecoveryScore().
    var recoveryScore: Double?
    var tags: [ReadingTag]
    var notes: String?
    var importedMetrics: ImportedMetrics?
    /// Device provenance - tracks source device, firmware, and collection method
    var deviceProvenance: DeviceProvenance?
    /// Sleep start time in milliseconds relative to recording start (from HealthKit)
    /// Used to filter pre-sleep data from overnight stats (nadir HR, peak HRV, etc.)
    var sleepStartMs: Int64?
    /// Sleep end time in milliseconds relative to recording start (from HealthKit)
    var sleepEndMs: Int64?
    /// Sleep segments for split nights (nil for single-segment sessions or legacy data)
    /// Each segment is a (startMs, endMs) pair relative to recording start
    var sleepSegments: [SleepSegmentMs]?
    /// IDs of sessions linked to this one (same recovery period, pause/resume chain)
    var linkedSessionIds: [UUID]?
    /// When this session was paused (nil if never paused)
    var pausedDate: Date?
    /// Summary of which data source was chosen and why (nil for non-overnight sessions)
    var dataSourceSummary: DataSourceSummary?
    /// Frozen sleep data snapshot from acceptance time.
    /// When present, dashboard and PDF use this instead of re-fetching from HealthKit,
    /// ensuring recovery score and sleep metrics stay stable throughout the day.
    var sleepSnapshot: SleepData?
    /// Whether the user explicitly adjusted sleep data (excluded segments, changed
    /// boundaries). When true, the snapshot is the source of truth and HealthKit
    /// must NOT overwrite it. When false (auto-captured at acceptance), HealthKit
    /// can still update the snapshot if it finds more complete data (e.g. a second
    /// sleep segment that synced after acceptance).
    var sleepUserAdjusted: Bool?
    /// Whether the user explicitly selected a custom analysis window via
    /// DraggableAnalysisWindow. When true, "Reanalyze All" will skip this
    /// session to preserve the user's manual selection.
    var windowUserAdjusted: Bool?
    /// Set by the one-time nap-repair backfill once it has evaluated this
    /// overnight session for daytime-nap sleep (and, if a qualifying nap existed,
    /// folded it into the recovery score's duration). `true` means "already
    /// checked" — the per-session idempotency guard — regardless of whether a nap
    /// was actually found, so the backfill never reprocesses a session. Also lets
    /// the app surface which nights were nap-adjusted.
    var napRepaired: Bool?
    /// The recovery result the app AUTO-selected before the user picked their
    /// own analysis window. Captured on the FIRST manual pick so the UI can
    /// show a persistent "you chose X (score N) vs auto picked Y (score M)"
    /// comparison. Local-only — stripped from the iCloud payload. nil when the
    /// window was never user-adjusted.
    var autoWindowResult: HRVAnalysisResult?
    /// Recovery score (0–10) of the auto-selected window, paired with
    /// `autoWindowResult`. Stored explicitly because the score is not part of
    /// HRVAnalysisResult and `recoveryScore` gets overwritten by the manual pick.
    var autoWindowScore: Double?
    /// Frozen recovery vitals snapshot from acceptance time.
    /// Prevents vitals changes during the day from altering the displayed recovery score.
    var vitalsSnapshot: RecoveryVitals?
    /// Frozen training context captured at waking (ATL/CTL/TSB through yesterday).
    /// Once set, this NEVER changes — history always reads from this field.
    /// The dashboard shows live training metrics separately.
    var trainingSnapshot: TrainingContext?
    /// Frozen score breakdown captured at acceptance time.
    /// Stores the exact factor scores and penalties that produced the frozen
    /// `recoveryScore`, preventing live baseline drift from making the
    /// breakdown inconsistent with the displayed composite.
    var scoreBreakdown: RecoveryScoreCalculator.ScoreBreakdown?
    /// Frozen training readiness (0-10) captured at acceptance time.
    /// Ensures history and dashboard show the same readiness for a given session.
    /// The dashboard may show a different *live* readiness for today if the user exercises.
    var frozenReadiness: Double?

    /// Quality classification of the HRV recording relative to sleep.
    /// Set during acceptance when the recording doesn't overlap with actual sleep.
    var hrvDataQuality: HRVDataQuality?

    /// Whether this session's HRV is trustworthy enough to feed ROLLING
    /// AGGREGATES — the rolling baseline, trend charts, "vs your average"
    /// cards, the dashboard/notification HRV headline, and the AI fact layer.
    ///
    /// Excludes both quality flags the analyzer sets when it can't trust the
    /// measured HRV (`SessionAcceptanceService` forces `useBaselineHRV` for
    /// exactly these):
    ///   - `.insufficient` — awake / too-short partial (e.g. a pre-sleep
    ///     recording paused while the user was still up). Its depressed RMSSD
    ///     is not a real overnight value.
    ///   - `.preSleep` — the recording ended before sleep began, so the raw
    ///     RMSSD is an AWAKE reading, not overnight recovery.
    /// `.good` and legacy `nil`-quality sessions qualify. This is the single
    /// canonical gate — every aggregation site should use it rather than an
    /// ad-hoc `!= .insufficient`, so `.insufficient` and `.preSleep` are always
    /// treated consistently.
    var isReliableForHRVAggregates: Bool {
        hrvDataQuality != .insufficient && hrvDataQuality != .preSleep
    }

    /// Timestamp of when this workout was successfully
    /// pushed to HealthKit as an `HKWorkout`. nil = never exported (or
    /// exported under an older build that didn't track it). Used by
    /// `HealthKitManager.backfillWorkoutsToHealthKit()` so we can
    /// scan the archive for un-exported sessions after the user
    /// finally grants workout-write permission, without double-publishing.
    var healthKitExportedAt: Date?

    /// Count of failed HealthKit export attempts. Bumped
    /// each time the backfill retry hits this session and HK rejects
    /// the write. After `HRVSession.healthKitExportRetryCeiling` the
    /// backfill loop stops re-trying so the same 2-of-27 doesn't
    /// hammer the API every cycle. Reset to nil on a successful
    /// export (so re-granting a missing permission gives the session
    /// a fresh start).
    var healthKitExportFailureCount: Int?
    static let healthKitExportRetryCeiling: Int = 5

    /// When the content of this session was last changed by an edit that is
    /// sent to iCloud (a feeling, tags or notes, a trim, a sleep edit, a
    /// reanalysis). Set by the archive when a write requests a re-upload, and
    /// uploaded with the session, so a device that already holds an older copy
    /// replaces it only with a strictly newer one (last writer wins). nil for
    /// sessions never edited since the field was added.
    var modifiedAt: Date?

    /// Frozen AI-context snapshot for the
    /// session. Flat string→string dictionary for third-party interop:
    /// keys are simple, self-describing, machine-readable; values are
    /// stringified primitives (numbers as decimal strings, booleans as
    /// "true"/"false", ISO-8601 dates). Captured at session finalize
    /// from the live snapshot the AI was reasoning over (sport,
    /// elapsed_sec, recovery_score, training_readiness, atl, ctl, tsb,
    /// units_preference, etc.).
    ///
    /// **Not surfaced in the UI** — this is a developer / data-export
    /// concern, not user-facing. Included in the full data export so
    /// third-party integrators have the same view of the session the
    /// AI did when it generated coaching for it. Optional so older
    /// sessions decode cleanly.
    var aiContext: [String: String]?

    /// User's subjective readiness (0.0 = terrible, 1.0 = peak).
    /// Offered when HRV data quality is poor. Blended into the HRV factor
    /// at 30% weight alongside the 70% baseline fallback.
    var perceivedReadiness: Double?

    /// User's morning feeling (1–5 scale: 1=Terrible … 5=Great).
    /// Asked *before* the score is revealed so the answer isn't anchored to
    /// the number. Stored as a parallel signal — NOT blended into the
    /// composite score. Used for divergence detection: when the user's
    /// feeling disagrees with their HRV by >1 category, the morning
    /// narrative flags it ("Your HRV looks good but you reported feeling
    /// poor — consider a lighter day").
    var morningFeeling: Int?

    /// Optional context tags when morningFeeling is 1 or 2. Lets the
    /// divergence narrative route to specific advice (e.g. viral infection
    /// → rest, allergies → train expecting less, hangover → easy day).
    /// Empty or nil on good-feeling days and when the user skipped tagging.
    var morningFeelingTags: [MorningFeelingTag]?

    /// Workout-specific fields, populated only when `sessionType == .workout`.
    /// Contains sport, GPS track, splits/laps, HRR samples, decoupling, TRIMP/TSS.
    /// RR data continues to live in `rrSeries`; HRV analysis continues to live
    /// in `analysisResult`. See WorkoutMetadata.swift.
    var workoutMetadata: WorkoutMetadata?

    /// Records which data source was selected for overnight analysis and the comparison stats
    struct DataSourceSummary: Codable, Equatable {
        /// Which source was ultimately used: "internal", "streaming", or "composite"
        let selectedSource: String
        /// Number of beats from BLE streaming
        let streamingBeats: Int
        /// Number of beats from device internal memory (nil if not fetched)
        let deviceBeats: Int?
        /// Total beats used for analysis (may exceed both if composite filled gaps)
        let totalBeats: Int
        /// Percentage difference between streaming and device beat counts (nil if device unavailable)
        let beatDifferencePercent: Double?
        /// Number of BLE reconnections during the recording
        let reconnectCount: Int
        /// Device model name (e.g. "Polar H10", "Polar Verity Sense") — nil for legacy data
        let deviceModel: String?

        /// Backward-compatible initializer (deviceModel defaults to nil)
        init(
            selectedSource: String,
            streamingBeats: Int,
            deviceBeats: Int?,
            totalBeats: Int,
            beatDifferencePercent: Double?,
            reconnectCount: Int,
            deviceModel: String? = nil
        ) {
            self.selectedSource = selectedSource
            self.streamingBeats = streamingBeats
            self.deviceBeats = deviceBeats
            self.totalBeats = totalBeats
            self.beatDifferencePercent = beatDifferencePercent
            self.reconnectCount = reconnectCount
            self.deviceModel = deviceModel
        }

        private var isVeritySense: Bool {
            guard let model = deviceModel?.lowercased() else { return false }
            return model.contains("verity") || model.contains("sense")
        }

        /// What happened to the data, in the app's language, for the Morning
        /// Results data-source card.
        var description: String {
            let b = LanguageManager.appBundle
            switch selectedSource {
            case "composite":
                let pct = beatDifferencePercent.map { String(format: "%.1f", locale: LanguageManager.appLocale, $0) } ?? "?"
                return String(localized: "Streamed + strap merged — \(pct)% more beats recovered", bundle: b)
            case "internal":
                if let db = deviceBeats, streamingBeats > 0 {
                    return String(localized: "Strap recording (\(db) beats)", bundle: b)
                }
                return String(localized: "Strap recording", bundle: b)
            case "streaming":
                return streamingDescription
            default:
                return String(localized: "\(selectedSource) data used", bundle: b)
            }
        }

        private var streamingDescription: String {
            let b = LanguageManager.appBundle
            if isVeritySense {
                return String(localized: "Streamed from Verity Sense", bundle: b)
            }
            if let db = deviceBeats {
                return String(localized: "Streamed (\(streamingBeats) streamed, \(db) on strap)", bundle: b)
            }
            return String(localized: "Streamed from strap", bundle: b)
        }
    }

    /// A sleep segment boundary in milliseconds relative to recording start
    struct SleepSegmentMs: Codable, Equatable {
        let startMs: Int64
        let endMs: Int64
    }

    enum SessionState: String, Codable {
        case collecting
        case analyzing
        case complete
        case paused // Scored, archived, resumable
        case failed
    }

    /// Whether this session can be resumed
    var isResumable: Bool {
        state == .paused
    }

    /// Metrics imported from external sources (e.g., Elite HRV summary)
    struct ImportedMetrics: Codable {
        let rmssd: Double
        let rmssdRaw: Double
        let artifactPercent: Double
        let source: String
        /// SDNN value (ms) — used by Apple Watch Breathe sessions which only provide SDNN
        let sdnn: Double?

        init(rmssd: Double, rmssdRaw: Double, artifactPercent: Double, source: String, sdnn: Double? = nil) {
            self.rmssd = rmssd
            self.rmssdRaw = rmssdRaw
            self.artifactPercent = artifactPercent
            self.source = source
            self.sdnn = sdnn
        }
    }

    init(startDate: Date = Date(), tags: [ReadingTag] = [], sessionType: SessionType = .overnight, deviceProvenance: DeviceProvenance? = nil) {
        id = UUID()
        self.startDate = startDate
        state = .collecting
        self.sessionType = sessionType
        self.tags = tags
        self.deviceProvenance = deviceProvenance
    }

    init(
        id: UUID,
        startDate: Date,
        endDate: Date?,
        state: SessionState,
        sessionType: SessionType = .overnight,
        rrSeries: RRSeries?,
        analysisResult: HRVAnalysisResult?,
        artifactFlags: [ArtifactFlags]?,
        recoveryScore: Double? = nil,
        tags: [ReadingTag] = [],
        notes: String? = nil,
        importedMetrics: ImportedMetrics? = nil,
        deviceProvenance: DeviceProvenance? = nil,
        sleepStartMs: Int64? = nil,
        sleepEndMs: Int64? = nil,
        sleepSegments: [SleepSegmentMs]? = nil,
        linkedSessionIds: [UUID]? = nil,
        pausedDate: Date? = nil,
        dataSourceSummary: DataSourceSummary? = nil
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.state = state
        self.sessionType = sessionType
        self.rrSeries = rrSeries
        self.analysisResult = analysisResult
        self.artifactFlags = artifactFlags
        self.recoveryScore = recoveryScore
        self.tags = tags
        self.notes = notes
        self.importedMetrics = importedMetrics
        self.deviceProvenance = deviceProvenance
        self.sleepStartMs = sleepStartMs
        self.sleepEndMs = sleepEndMs
        self.sleepSegments = sleepSegments
        self.linkedSessionIds = linkedSessionIds
        self.pausedDate = pausedDate
        self.dataSourceSummary = dataSourceSummary
    }

    /// Validate perceived readiness at the trust boundary.
    ///
    /// The documented domain is 0.0...1.0 and the UI honours
    /// it (`SubjectiveReadinessCard` divides a bounded slider by 10), but this
    /// decoder is also fed by CloudKit-synced records and by archive files
    /// written by other builds. An out-of-domain value reaching
    /// `RecoveryScoreCalculator.subjectiveScore` produces composites like
    /// -99.6 and 3050.4. Out-of-domain is treated as ABSENT rather than
    /// clamped: a value we cannot trust should not silently become a
    /// plausible-looking answer the user never gave.
    static func validPerceivedReadiness(_ raw: Double?) -> Double? {
        raw.flatMap { (0.0 ... 1.0).contains($0) ? $0 : nil }
    }

    // spec:long-function A 40-field Codable decoder cannot be decomposed in
    // Swift. Stored properties must all be initialized before any method on
    // `self` may be called, so `private mutating func decodeSleep(...)` is
    // rejected with "variable 'self.state' captured by a closure before being
    // initialized"; and `id`/`startDate` are `let`, which only `init` may
    // assign. The alternatives are to default every property in its
    // declaration (which weakens the type — a missing assignment stops being a
    // compile error) or to restructure the on-disk JSON into nested groups
    // (a migration, for a formatting rule). Neither is worth it.
    //
    // The order deliberately mirrors `encodeIdentity` /
    // `encodeSleep` / `encodeScoring` / `encodeSubjective`, and the MARK-style
    // group comments below are the read-order contract, so a field added to one
    // side has an obvious home on the other.
    /// Custom decoder to handle missing fields in old data.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // MARK: identity — mirrors encodeIdentity
        // Schema version: absent in legacy data → defaults to 0. Kept on the
        // session (not discarded) so the archive can refuse to destructively
        // re-write payloads from a NEWER schema than this build.
        sourceSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        id = try container.decode(UUID.self, forKey: .id)
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        state = try container.decode(SessionState.self, forKey: .state)
        sessionType = try container.decodeIfPresent(SessionType.self, forKey: .sessionType) ?? .overnight
        // Skip heavyweight rrSeries when the lightweight flag is set (dashboard loading)
        rrSeries = decoder.userInfo[.skipRRSeries] as? Bool == true
            ? nil
            : try container.decodeIfPresent(RRSeries.self, forKey: .rrSeries)
        artifactFlags = try container.decodeIfPresent([ArtifactFlags].self, forKey: .artifactFlags)
        analysisResult = try container.decodeIfPresent(HRVAnalysisResult.self, forKey: .analysisResult)
        recoveryScore = try container.decodeIfPresent(Double.self, forKey: .recoveryScore)
        tags = try container.decodeIfPresent([ReadingTag].self, forKey: .tags) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes)

        // MARK: sleep — mirrors encodeSleep. All nil for legacy data.
        importedMetrics = try container.decodeIfPresent(ImportedMetrics.self, forKey: .importedMetrics)
        deviceProvenance = try container.decodeIfPresent(DeviceProvenance.self, forKey: .deviceProvenance)
        sleepStartMs = try container.decodeIfPresent(Int64.self, forKey: .sleepStartMs)
        sleepEndMs = try container.decodeIfPresent(Int64.self, forKey: .sleepEndMs)
        sleepSegments = try container.decodeIfPresent([SleepSegmentMs].self, forKey: .sleepSegments)
        linkedSessionIds = try container.decodeIfPresent([UUID].self, forKey: .linkedSessionIds)
        pausedDate = try container.decodeIfPresent(Date.self, forKey: .pausedDate)
        dataSourceSummary = try container.decodeIfPresent(DataSourceSummary.self, forKey: .dataSourceSummary)
        sleepSnapshot = try container.decodeIfPresent(SleepData.self, forKey: .sleepSnapshot)
        sleepUserAdjusted = try container.decodeIfPresent(Bool.self, forKey: .sleepUserAdjusted)

        // MARK: scoring — mirrors encodeScoring. `trainingSnapshot` migrates
        // out of `analysisResult` for sessions written before it was frozen.
        napRepaired = try container.decodeIfPresent(Bool.self, forKey: .napRepaired)
        vitalsSnapshot = try container.decodeIfPresent(RecoveryVitals.self, forKey: .vitalsSnapshot)
        trainingSnapshot = try container.decodeIfPresent(TrainingContext.self, forKey: .trainingSnapshot)
            ?? analysisResult?.trainingContext
        scoreBreakdown = try container.decodeIfPresent(RecoveryScoreCalculator.ScoreBreakdown.self, forKey: .scoreBreakdown)
        frozenReadiness = try container.decodeIfPresent(Double.self, forKey: .frozenReadiness)
        windowUserAdjusted = try container.decodeIfPresent(Bool.self, forKey: .windowUserAdjusted)
        autoWindowResult = try container.decodeIfPresent(HRVAnalysisResult.self, forKey: .autoWindowResult)
        autoWindowScore = try container.decodeIfPresent(Double.self, forKey: .autoWindowScore)
        hrvDataQuality = try container.decodeIfPresent(HRVDataQuality.self, forKey: .hrvDataQuality)

        // MARK: subjective — mirrors encodeSubjective
        aiContext = try container.decodeIfPresent([String: String].self, forKey: .aiContext)
        perceivedReadiness = Self.validPerceivedReadiness(
            try container.decodeIfPresent(Double.self, forKey: .perceivedReadiness)
        )
        morningFeeling = try container.decodeIfPresent(Int.self, forKey: .morningFeeling)
        // Decode via MorningFeelingTagArray so unknown tags (from a newer
        // build that added tags) are silently dropped rather than failing.
        morningFeelingTags = try (container.decodeIfPresent(MorningFeelingTagArray.self, forKey: .morningFeelingTags))?.tags
        workoutMetadata = try container.decodeIfPresent(WorkoutMetadata.self, forKey: .workoutMetadata)
        healthKitExportedAt = try container.decodeIfPresent(Date.self, forKey: .healthKitExportedAt)
        healthKitExportFailureCount = try container.decodeIfPresent(Int.self, forKey: .healthKitExportFailureCount)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeIdentity(into: &container)
        try encodeSleep(into: &container)
        try encodeScoring(into: &container)
        try encodeSubjective(into: &container)
    }

    /// Schema, identity and lifecycle state.
    private func encodeIdentity(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        try container.encode(state, forKey: .state)
        try container.encode(sessionType, forKey: .sessionType)
        try container.encodeIfPresent(rrSeries, forKey: .rrSeries)
        try container.encodeIfPresent(artifactFlags, forKey: .artifactFlags)
        try container.encodeIfPresent(analysisResult, forKey: .analysisResult)
        try container.encodeIfPresent(recoveryScore, forKey: .recoveryScore)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(notes, forKey: .notes)
    }

    /// Sleep boundaries, segments and the frozen sleep snapshot.
    private func encodeSleep(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encodeIfPresent(importedMetrics, forKey: .importedMetrics)
        try container.encodeIfPresent(deviceProvenance, forKey: .deviceProvenance)
        try container.encodeIfPresent(sleepStartMs, forKey: .sleepStartMs)
        try container.encodeIfPresent(sleepEndMs, forKey: .sleepEndMs)
        try container.encodeIfPresent(sleepSegments, forKey: .sleepSegments)
        try container.encodeIfPresent(linkedSessionIds, forKey: .linkedSessionIds)
        try container.encodeIfPresent(pausedDate, forKey: .pausedDate)
        try container.encodeIfPresent(dataSourceSummary, forKey: .dataSourceSummary)
        try container.encodeIfPresent(sleepSnapshot, forKey: .sleepSnapshot)
        try container.encodeIfPresent(sleepUserAdjusted, forKey: .sleepUserAdjusted)
    }

    /// Frozen scoring inputs and results — the snapshot set that keeps a
    /// stored score reproducible even as the live calculators change.
    private func encodeScoring(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encodeIfPresent(napRepaired, forKey: .napRepaired)
        try container.encodeIfPresent(vitalsSnapshot, forKey: .vitalsSnapshot)
        try container.encodeIfPresent(trainingSnapshot, forKey: .trainingSnapshot)
        try container.encodeIfPresent(scoreBreakdown, forKey: .scoreBreakdown)
        try container.encodeIfPresent(frozenReadiness, forKey: .frozenReadiness)
        try container.encodeIfPresent(windowUserAdjusted, forKey: .windowUserAdjusted)
        try container.encodeIfPresent(autoWindowResult, forKey: .autoWindowResult)
        try container.encodeIfPresent(autoWindowScore, forKey: .autoWindowScore)
        try container.encodeIfPresent(hrvDataQuality, forKey: .hrvDataQuality)
    }

    /// What the user told us, plus workout and HealthKit-export state.
    /// Empty tag arrays are omitted rather than written as `[]`.
    private func encodeSubjective(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encodeIfPresent(aiContext, forKey: .aiContext)
        try container.encodeIfPresent(perceivedReadiness, forKey: .perceivedReadiness)
        try container.encodeIfPresent(morningFeeling, forKey: .morningFeeling)
        if let tags = morningFeelingTags, !tags.isEmpty {
            try container.encode(MorningFeelingTagArray(tags), forKey: .morningFeelingTags)
        }
        try container.encodeIfPresent(workoutMetadata, forKey: .workoutMetadata)
        try container.encodeIfPresent(healthKitExportedAt, forKey: .healthKitExportedAt)
        try container.encodeIfPresent(healthKitExportFailureCount, forKey: .healthKitExportFailureCount)
        try container.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id, startDate, endDate, state, sessionType, rrSeries, artifactFlags
        case analysisResult, recoveryScore, tags, notes, importedMetrics, deviceProvenance
        case sleepStartMs, sleepEndMs, sleepSegments, linkedSessionIds, pausedDate
        case dataSourceSummary, sleepSnapshot, sleepUserAdjusted, napRepaired, vitalsSnapshot, trainingSnapshot
        case scoreBreakdown, windowUserAdjusted, frozenReadiness
        case autoWindowResult, autoWindowScore
        case hrvDataQuality, perceivedReadiness, morningFeeling, morningFeelingTags
        case aiContext
        case workoutMetadata
        case healthKitExportedAt
        case healthKitExportFailureCount
        case modifiedAt
    }

    /// Duration of the session
    var duration: TimeInterval? {
        guard let endDate else { return nil }
        return endDate.timeIntervalSince(startDate)
    }

    /// Check if session has valid data for analysis
    var isValidForAnalysis: Bool {
        guard let series = rrSeries else { return false }
        return series.points.count >= 120
    }

    // MARK: - Analysis Convenience Accessors

    /// RMSSD from the analysis result (ms)
    var rmssd: Double? {
        analysisResult?.timeDomain.rmssd
    }

    /// Mean heart rate from the analysis result (bpm)
    var meanHR: Double? {
        analysisResult?.timeDomain.meanHR
    }

    /// HRV readiness score (0-10 scale) from ANS metrics
    var readinessScore: Double? {
        analysisResult?.ansMetrics?.readinessScore
    }

    /// Stress index from ANS metrics
    var stressIndex: Double? {
        analysisResult?.ansMetrics?.stressIndex
    }

    // MARK: - Workout Convenience

    /// Whether this session represents a workout (fitness/effort capture).
    var isWorkout: Bool { sessionType == .workout }

    /// Sport for workout sessions; nil for all other session types.
    var sport: Sport? { workoutMetadata?.sport }
}

/// Offline session for sync
struct OfflineSession: Codable, Identifiable {
    let id: UUID
    let session: HRVSession
    let createdAt: Date
    var syncedAt: Date?
    var syncAttempts: Int
    var lastError: String?

    init(session: HRVSession) {
        id = session.id
        self.session = session
        createdAt = Date()
        syncAttempts = 0
    }

    var needsSync: Bool {
        syncedAt == nil && syncAttempts < 3
    }
}

/// Session archive entry with quick-access metadata
/// Sendable so background tasks (e.g.
/// HistoryViewModel's BFS dedup) can carry `[SessionArchiveEntry]`
/// across actor boundaries. All fields are value types or already
/// Sendable.
struct SessionArchiveEntry: Codable, Sendable {
    static let currentSchemaVersion = 1

    let sessionId: UUID
    let date: Date
    /// When the recording ended (for overnight sessions, this is the meaningful "reading time")
    let endDate: Date?
    let fileHash: String
    let filePath: String
    /// Composite recovery score (0-10 scale). See HRVSession.recoveryScore for details.
    let recoveryScore: Double?
    let meanRMSSD: Double?
    /// Mean heart rate (bpm) for trend computation without loading sessions
    let meanHR: Double?
    /// Stress index for trend computation without loading sessions
    let stressIndex: Double?
    /// SDNN value (ms) for Apple Watch Breathe sessions
    let meanSDNN: Double?
    let tags: [ReadingTag]
    let notes: String?
    let sessionType: SessionType
    /// IDs of sessions linked to this one (pause/resume chain). Nil for standalone sessions.
    let linkedSessionIds: [UUID]?
    /// Actual sleep end time from the snapshot (or resolved boundaries). Used
    /// as the display "wake time" in history. Falls back to `endDate` when
    /// nil (legacy entries, non-overnight sessions).
    let sleepEnd: Date?
    /// Number of meaningful sleep segments from the snapshot's effective
    /// segments (or stored `sleepSegments`). Used by history to decide
    /// whether to render the split-night badge — linked *recording* sessions
    /// alone don't prove the user's *sleep* was split. Nil/1 means single
    /// continuous sleep; badge suppressed.
    let sleepSegmentCount: Int?

    // MARK: - Sleep stage minutes (from session.sleepSnapshot)
    //
    // Mirrored into the lightweight index so trend queries and the AI
    // assistant can reason about deep / REM / core / awake across the full
    // 30-day archive without having to load each session's RR file.
    let deepSleepMinutes: Int?
    let remSleepMinutes: Int?
    let coreSleepMinutes: Int?
    let awakeMinutes: Int?

    // MARK: - Nocturnal HR dip (from session.nocturnalHRDip)
    //
    // Percentage drop from pre-sleep waking HR to mean sleeping HR. Healthy
    // 10–20%; persistently low (<10%) suggests incomplete autonomic recovery.
    let nocturnalDipPercent: Double?

    /// Mirrors `HRVSession.hrvDataQuality` into the lightweight index so the AI
    /// fact layer and the deterministic voice path can exclude untrustworthy
    /// readings (`.insufficient` / `.preSleep`) WITHOUT loading each session's
    /// RR file. Nil for legacy entries (back-fillable by re-archiving); nil is
    /// treated as reliable so legacy data is never wrongly hidden.
    let hrvDataQuality: HRVDataQuality?

    /// Mirrors `HRVSession.modifiedAt`, so an iCloud pull can tell whether a
    /// remote copy is newer than this device's without opening the file.
    let modifiedAt: Date?

    /// The date to display in history — prefers the actual sleep end so
    /// sessions whose recording ran long past wake (e.g. user forgot to
    /// stop) still show "wake time" in the row. Falls back to the recording
    /// end date, then the start date.
    var displayDate: Date {
        if sessionType == .overnight {
            if let sleepEnd { return sleepEnd }
            if let end = endDate { return end }
        }
        return date
    }

    /// Index-side mirror of `HRVSession.isReliableForHRVAggregates`, for
    /// aggregation paths that operate on `SessionArchiveEntry` (AI facts,
    /// voice intents) rather than full sessions.
    var isReliableForHRVAggregates: Bool {
        hrvDataQuality != .insufficient && hrvDataQuality != .preSleep
    }

    // spec:long-function A memberwise initializer is one assignment per stored
    // property and nothing else — no branches, no calls, no logic to extract.
    // Swift additionally forbids calling a helper on `self` before every stored
    // property is initialized, so the body cannot be split even mechanically.
    // Splitting the TYPE would be the real fix; that is tracked separately and
    // is not a formatting change.
    init(
        sessionId: UUID,
        date: Date,
        endDate: Date? = nil,
        fileHash: String,
        filePath: String,
        recoveryScore: Double? = nil,
        meanRMSSD: Double? = nil,
        meanHR: Double? = nil,
        stressIndex: Double? = nil,
        meanSDNN: Double? = nil,
        tags: [ReadingTag] = [],
        notes: String? = nil,
        sessionType: SessionType = .overnight,
        linkedSessionIds: [UUID]? = nil,
        sleepEnd: Date? = nil,
        sleepSegmentCount: Int? = nil,
        deepSleepMinutes: Int? = nil,
        remSleepMinutes: Int? = nil,
        coreSleepMinutes: Int? = nil,
        awakeMinutes: Int? = nil,
        nocturnalDipPercent: Double? = nil,
        hrvDataQuality: HRVDataQuality? = nil,
        modifiedAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.date = date
        self.endDate = endDate
        self.fileHash = fileHash
        self.filePath = filePath
        self.recoveryScore = recoveryScore
        self.meanRMSSD = meanRMSSD
        self.meanHR = meanHR
        self.stressIndex = stressIndex
        self.meanSDNN = meanSDNN
        self.tags = tags
        self.notes = notes
        self.sessionType = sessionType
        self.linkedSessionIds = linkedSessionIds
        self.deepSleepMinutes = deepSleepMinutes
        self.remSleepMinutes = remSleepMinutes
        self.coreSleepMinutes = coreSleepMinutes
        self.awakeMinutes = awakeMinutes
        self.nocturnalDipPercent = nocturnalDipPercent
        self.sleepEnd = sleepEnd
        self.sleepSegmentCount = sleepSegmentCount
        self.hrvDataQuality = hrvDataQuality
        self.modifiedAt = modifiedAt
    }

    // spec:long-function A Codable decoder cannot be decomposed in Swift:
    // every stored property must be initialized before any method on `self`
    // may be called, so a `private mutating func decodeX(...)` helper is
    // rejected outright, and `let` properties can only be assigned by `init`.
    // The alternatives are defaulting every property in its declaration (which
    // turns a missing assignment from a compile error into a silent nil) or
    // restructuring the on-disk JSON (a data migration, for a formatting rule).
    // Body is one assignment per field, in the same order as the encoder.
    /// Custom decoder to handle missing fields in old data.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Schema version: absent in legacy data → defaults to 0
        _ = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        sessionId = try container.decode(UUID.self, forKey: .sessionId)
        date = try container.decode(Date.self, forKey: .date)
        endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        fileHash = try container.decode(String.self, forKey: .fileHash)
        filePath = try container.decode(String.self, forKey: .filePath)
        recoveryScore = try container.decodeIfPresent(Double.self, forKey: .recoveryScore)
        meanRMSSD = try container.decodeIfPresent(Double.self, forKey: .meanRMSSD)
        meanHR = try container.decodeIfPresent(Double.self, forKey: .meanHR)
        stressIndex = try container.decodeIfPresent(Double.self, forKey: .stressIndex)
        meanSDNN = try container.decodeIfPresent(Double.self, forKey: .meanSDNN)
        tags = try container.decodeIfPresent([ReadingTag].self, forKey: .tags) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        // Default to overnight for existing data that doesn't have sessionType
        sessionType = try container.decodeIfPresent(SessionType.self, forKey: .sessionType) ?? .overnight
        linkedSessionIds = try container.decodeIfPresent([UUID].self, forKey: .linkedSessionIds)
        sleepEnd = try container.decodeIfPresent(Date.self, forKey: .sleepEnd)
        sleepSegmentCount = try container.decodeIfPresent(Int.self, forKey: .sleepSegmentCount)
        // Sleep stages + nocturnal dip — nil for legacy entries (back-fillable
        // by re-archiving any session whose snapshot has them).
        deepSleepMinutes = try container.decodeIfPresent(Int.self, forKey: .deepSleepMinutes)
        remSleepMinutes = try container.decodeIfPresent(Int.self, forKey: .remSleepMinutes)
        coreSleepMinutes = try container.decodeIfPresent(Int.self, forKey: .coreSleepMinutes)
        awakeMinutes = try container.decodeIfPresent(Int.self, forKey: .awakeMinutes)
        nocturnalDipPercent = try container.decodeIfPresent(Double.self, forKey: .nocturnalDipPercent)
        hrvDataQuality = try container.decodeIfPresent(HRVDataQuality.self, forKey: .hrvDataQuality)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeIdentity(into: &container)
        try encodeMetrics(into: &container)
        try encodeSleepSummary(into: &container)
    }

    /// Schema, identity and where the session's file lives.
    private func encodeIdentity(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(date, forKey: .date)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        try container.encode(fileHash, forKey: .fileHash)
        try container.encode(filePath, forKey: .filePath)
    }

    /// The summary metrics History rows and charts read without
    /// deserializing the whole session.
    private func encodeMetrics(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encodeIfPresent(recoveryScore, forKey: .recoveryScore)
        try container.encodeIfPresent(meanRMSSD, forKey: .meanRMSSD)
        try container.encodeIfPresent(meanHR, forKey: .meanHR)
        try container.encodeIfPresent(stressIndex, forKey: .stressIndex)
        try container.encodeIfPresent(meanSDNN, forKey: .meanSDNN)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(notes, forKey: .notes)
    }

    /// Session type, links, and the per-stage sleep rollup.
    private func encodeSleepSummary(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encode(sessionType, forKey: .sessionType)
        try container.encodeIfPresent(linkedSessionIds, forKey: .linkedSessionIds)
        try container.encodeIfPresent(sleepEnd, forKey: .sleepEnd)
        try container.encodeIfPresent(sleepSegmentCount, forKey: .sleepSegmentCount)
        try container.encodeIfPresent(deepSleepMinutes, forKey: .deepSleepMinutes)
        try container.encodeIfPresent(remSleepMinutes, forKey: .remSleepMinutes)
        try container.encodeIfPresent(coreSleepMinutes, forKey: .coreSleepMinutes)
        try container.encodeIfPresent(awakeMinutes, forKey: .awakeMinutes)
        try container.encodeIfPresent(nocturnalDipPercent, forKey: .nocturnalDipPercent)
        // Written so a pre-sleep or insufficient partial still reads back as
        // unreliable for HRV aggregates after the index is reloaded.
        try container.encodeIfPresent(hrvDataQuality, forKey: .hrvDataQuality)
        try container.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sessionId, date, endDate, fileHash, filePath, recoveryScore, meanRMSSD, meanHR, stressIndex, meanSDNN, tags, notes, sessionType, linkedSessionIds
        case sleepEnd, sleepSegmentCount
        case deepSleepMinutes, remSleepMinutes, coreSleepMinutes, awakeMinutes
        case nocturnalDipPercent
        case hrvDataQuality
        case modifiedAt
    }
}
