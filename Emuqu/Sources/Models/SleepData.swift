import Foundation

/// Sleep data collected from HealthKit for a single night
struct SleepData: Codable, Sendable {
    let date: Date
    let inBedStart: Date? // When user got into bed (for latency calculation)
    let sleepStart: Date? // When sleep actually started (earliest across all segments)
    let sleepEnd: Date? // When sleep actually ended (latest across all segments)
    /// The consolidated NIGHT sleep (minutes). Stored under the JSON key
    /// "totalSleepMinutes" for archive/CloudKit back-compat. `private` on purpose:
    /// no consumer may read the raw field, so nobody can accidentally show/score
    /// the night when they mean the 24-hour total. Read `nightSleepMinutes`
    /// (architecture/quality) or `totalSleepIncludingNapMinutes` (display/adequacy).
    private let totalSleepMinutes: Int
    let inBedMinutes: Int
    let deepSleepMinutes: Int? // From Apple Watch or HRV-based classification
    let remSleepMinutes: Int? // From Apple Watch or HRV-based classification
    /// Qualifying daytime-nap sleep (minutes) for the waking day that led into
    /// this night, pulled from HealthKit's daytime `sleepAnalysis`. Counted toward
    /// the 24-hour sleep DURATION only — a nap discharges homeostatic sleep
    /// pressure, so a shorter night that was "front-loaded" by a nap is not sleep
    /// debt (Nature Sci Reports s41598-021-84625-8). Deliberately kept SEPARATE
    /// from `totalSleepMinutes` so the night's architecture metrics (efficiency,
    /// fragmentation, cycles, stage %) stay computed on the consolidated night
    /// alone and are never blended with a separate daytime episode. `nil` for data
    /// encoded before this field existed and for nights with no qualifying nap.
    let napSleepMinutes: Int?
    let awakeMinutes: Int
    let sleepEfficiency: Double // % of in-segment time actually asleep (gaps between segments excluded)
    let boundarySource: HealthKitManager.SleepBoundarySource // Where sleep boundaries came from
    let segments: [HealthKitManager.SleepSegment] // Per-segment breakdown for split nights (empty for single-segment)
    let stageIntervals: [HealthKitManager.SleepStageInterval] // Individual stage periods for timeline visualization
    let boundaryValidation: HealthKitManager.SleepBoundaryValidation? // HR validation metadata (nil when no RR data)
    let hrSleepQuality: HealthKitManager.HRSleepQuality? // RMSSD-derived quality (nil when no RR data)

    /// Split-gap threshold captured at creation time so computed properties don't
    /// reach for SettingsManager.shared. Defaults to 20 minutes for backward
    /// compatibility with data encoded before this field existed.
    var splitGapMinutes: Int = SleepConstants.defaultSplitGapMinutes

    /// Audit trail of user edits applied to this sleep data. Preserved in the
    /// archive; not uploaded to iCloud. The sleep editor counts the edits made in a visit
    /// by kind; no screen lists the records themselves.
    var edits: [SleepEditRecord] = []

    /// Sleep latency in minutes — time awake before the first sleep.
    ///
    /// With a stage timeline, count the awake stage before the
    /// first sleep stage, the same source every other total on the Sleep
    /// page is derived from. `sleepStart − inBedStart` arithmetic uses the
    /// recording start as "in bed", so a strap put on at 8 pm gives a
    /// 157-minute latency beside an in-bed total shorter than that. With
    /// no stages that arithmetic is the fallback, capped at the awake time
    /// the in-bed total actually contains.
    var sleepLatencyMinutes: Int? {
        guard let sleep = sleepStart else { return nil }
        if !stageIntervals.isEmpty {
            let awakeBefore = stageIntervals
                .filter { $0.stage == .awake && $0.start < sleep }
                .reduce(0.0) { $0 + min($1.end, sleep).timeIntervalSince($1.start) }
            let minutes = Int(awakeBefore / 60)
            return minutes > 0 ? minutes : nil
        }
        guard let inBed = inBedStart else { return nil }
        let latency = min(Int(sleep.timeIntervalSince(inBed) / 60), max(inBedMinutes - totalSleepMinutes, 0))
        return latency > 0 ? latency : nil
    }

    /// Sleep as a percentage of time in bed; 0 with no time in bed.
    static func efficiencyPercent(sleep: Int, inBed: Int) -> Double {
        inBed > 0 ? Double(sleep) / Double(inBed) * 100 : 0
    }

    /// "Xh Ym" (in the app's language) for the full 24-hour total (night +
    /// any qualifying nap) — the number shown to the user as "total sleep".
    var totalSleepFormatted: String {
        Self.hoursMinutes(totalSleepIncludingNapMinutes)
    }

    /// "Xh Ym" for the qualifying daytime nap, or nil when there is no nap credit.
    var napSleepFormatted: String? {
        guard let nap = napSleepMinutes, nap > 0 else { return nil }
        return Self.hoursMinutes(nap)
    }

    /// Abbreviated hours and minutes in the app's language ("7h 32m", "7 Std.
    /// 32 Min."), the English form only if the formatter returns nothing.
    private static func hoursMinutes(_ minutes: Int) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = LanguageManager.appLocale
        formatter.calendar = calendar
        formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        let total = max(0, minutes)
        return formatter.string(from: TimeInterval(total * 60))
            ?? (total >= 60 ? "\(total / 60)h \(total % 60)m" : "\(total)m")
    }

    /// Whether this was a split night with multiple sleep segments, as
    /// `effectiveSegments` resolves them (stored segments, else segments
    /// derived from the stage intervals at `splitGapMinutes`).
    var isSplitNight: Bool {
        effectiveSegments.count > 1
    }

    /// Segments for display. The resolver writes these as the canonical split
    /// representation — HealthKit's segments are informational only. For
    /// legacy archives that predate the resolver, we fall back to deriving
    /// segments from stageIntervals, and finally to a single envelope segment.
    var effectiveSegments: [HealthKitManager.SleepSegment] {
        if !segments.isEmpty {
            return segments
        }
        let stageDerived = derivedSegmentsFromStages
        if !stageDerived.isEmpty {
            return stageDerived
        }
        if let start = sleepStart, let end = sleepEnd, end > start {
            return [HealthKitManager.SleepSegment(
                sleepStart: start,
                sleepEnd: end,
                totalSleepMinutes: totalSleepMinutes,
                deepSleepMinutes: deepSleepMinutes,
                remSleepMinutes: remSleepMinutes,
                coreSleepMinutes: nil,
                awakeMinutes: awakeMinutes
            )]
        }
        return []
    }

    /// The consolidated night's sleep (minutes) — the basis for all architecture /
    /// quality math (stage %, efficiency, fragmentation, cycles) and for
    /// plausibility/overlap checks against the recording. Excludes any daytime nap.
    var nightSleepMinutes: Int {
        totalSleepMinutes
    }

    /// Total 24-hour sleep = the consolidated night plus any qualifying daytime
    /// nap. The quantity the recovery score's DURATION component and every
    /// user-facing "total sleep" display grade against. Architecture math uses
    /// `nightSleepMinutes` instead.
    var totalSleepIncludingNapMinutes: Int {
        nightSleepMinutes + max(0, napSleepMinutes ?? 0)
    }

    /// Returns a copy with the daytime-nap contribution attached. Every night-only
    /// field (boundaries, stages, efficiency, intervals) is preserved unchanged —
    /// only the separate `napSleepMinutes` is set. A non-positive value clears it.
    func withNapSleepMinutes(_ minutes: Int) -> SleepData {
        SleepData(
            date: date,
            inBedStart: inBedStart,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            totalSleepMinutes: totalSleepMinutes,
            inBedMinutes: inBedMinutes,
            deepSleepMinutes: deepSleepMinutes,
            remSleepMinutes: remSleepMinutes,
            napSleepMinutes: minutes > 0 ? minutes : nil,
            awakeMinutes: awakeMinutes,
            sleepEfficiency: sleepEfficiency,
            boundarySource: boundarySource,
            segments: segments,
            stageIntervals: stageIntervals,
            boundaryValidation: boundaryValidation,
            hrSleepQuality: hrSleepQuality,
            splitGapMinutes: splitGapMinutes,
            edits: edits
        )
    }

    /// Whether time in bed is the night's sleep plus awake: true for a night
    /// built from sleep stages (the resolver, a trim to the recording start,
    /// the sleep editor). The strap-only estimate (`hrEstimated`, written
    /// without segments) counts the whole recording as time in bed, and a
    /// passive heart-rate estimate (`healthKitHREstimated`) the sleep span.
    var timeInBedIsSleepPlusAwake: Bool {
        switch boundarySource {
        case .healthKit, .hrValidated: true
        case .hrEstimated: !segments.isEmpty
        case .healthKitHREstimated, .recordingBounds: false
        }
    }

    private var sleepPlusAwakeMinutes: Int { nightSleepMinutes + awakeMinutes }

    /// A copy whose time in bed is sleep plus awake and whose efficiency
    /// matches it; every other field is unchanged.
    func withTimeInBedFromSleepAndAwake() -> SleepData {
        SleepData(
            date: date,
            inBedStart: inBedStart,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            totalSleepMinutes: totalSleepMinutes,
            inBedMinutes: sleepPlusAwakeMinutes,
            deepSleepMinutes: deepSleepMinutes,
            remSleepMinutes: remSleepMinutes,
            napSleepMinutes: napSleepMinutes,
            awakeMinutes: awakeMinutes,
            sleepEfficiency: Self.efficiencyPercent(sleep: nightSleepMinutes, inBed: sleepPlusAwakeMinutes),
            boundarySource: boundarySource,
            segments: segments,
            stageIntervals: stageIntervals,
            boundaryValidation: boundaryValidation,
            hrSleepQuality: hrSleepQuality,
            splitGapMinutes: splitGapMinutes,
            edits: edits
        )
    }

    // MARK: - Legacy Segment Derivation

    /// Stage-derived segments using the captured split-gap threshold.
    /// Used only as a fallback for archives encoded before the resolver
    /// started writing segments directly.
    private var derivedSegmentsFromStages: [HealthKitManager.SleepSegment] {
        guard !stageIntervals.isEmpty else { return [] }
        let gapSeconds = Double(splitGapMinutes) * 60
        let groups = SleepMergingPipeline.splitStageIntervalsByAwake(stageIntervals, gap: gapSeconds)
        return groups.compactMap { SleepMergingPipeline.buildSegmentFromIntervals($0) }
    }

    // MARK: - Memberwise Init

    init(
        date: Date,
        inBedStart: Date? = nil,
        sleepStart: Date? = nil,
        sleepEnd: Date? = nil,
        totalSleepMinutes: Int,
        inBedMinutes: Int,
        deepSleepMinutes: Int? = nil,
        remSleepMinutes: Int? = nil,
        napSleepMinutes: Int? = nil,
        awakeMinutes: Int,
        sleepEfficiency: Double,
        boundarySource: HealthKitManager.SleepBoundarySource,
        segments: [HealthKitManager.SleepSegment] = [],
        stageIntervals: [HealthKitManager.SleepStageInterval] = [],
        boundaryValidation: HealthKitManager.SleepBoundaryValidation? = nil,
        hrSleepQuality: HealthKitManager.HRSleepQuality? = nil,
        splitGapMinutes: Int = SleepConstants.defaultSplitGapMinutes,
        edits: [SleepEditRecord] = []
    ) {
        self.date = date
        self.inBedStart = inBedStart
        self.sleepStart = sleepStart
        self.sleepEnd = sleepEnd
        self.totalSleepMinutes = totalSleepMinutes
        self.inBedMinutes = inBedMinutes
        self.deepSleepMinutes = deepSleepMinutes
        self.remSleepMinutes = remSleepMinutes
        self.napSleepMinutes = napSleepMinutes
        self.awakeMinutes = awakeMinutes
        self.sleepEfficiency = sleepEfficiency
        self.boundarySource = boundarySource
        self.segments = segments
        self.stageIntervals = stageIntervals
        self.boundaryValidation = boundaryValidation
        self.hrSleepQuality = hrSleepQuality
        self.splitGapMinutes = splitGapMinutes
        self.edits = edits
    }

    static let empty = SleepData(
        date: Date(),
        totalSleepMinutes: 0,
        inBedMinutes: 0,
        awakeMinutes: 0,
        sleepEfficiency: 0,
        boundarySource: .recordingBounds
    )

    /// Clamp this sleep result so it can't begin before the strap started
    /// recording. The Watch-only resolver uses a bedtime−2h (~8 PM)
    /// envelope and Apple labels sedentary pre-bed time as "asleep", so a
    /// cached result read at wake can claim sleep onset hours before the
    /// user actually went to bed (and before the strap was even on). Sleep
    /// the strap never measured isn't this session's sleep, so trim the
    /// timeline to `[recordingStart, …]` and recompute onset + durations.
    /// No-op when onset is already at/after the recording start (the common
    /// correct case), so well-formed nights are untouched.
    func clampedToRecordingStart(_ recordingStart: Date) -> SleepData {
        guard let onset = sleepStart, onset < recordingStart else { return self }
        if !stageIntervals.isEmpty {
            return clampedByStages(recordingStart)
        }
        return clampedByTotals(recordingStart, onset: onset)
    }

    /// With a per-stage timeline, re-derive every duration from the trimmed
    /// intervals rather than adjusting the stored totals.
    private func clampedByStages(_ recordingStart: Date) -> SleepData {
        let trimmed = Self.trimIntervals(stageIntervals, from: recordingStart)
        let sleepMin = Self.minutes(in: trimmed) { $0 != .awake }
        let awakeMin = Self.minutes(in: trimmed) { $0 == .awake }
        let inBed = sleepMin + awakeMin
        return SleepData(
            date: date, inBedStart: recordingStart,
            sleepStart: trimmed.filter { $0.stage != .awake }.map(\.start).min() ?? recordingStart,
            sleepEnd: sleepEnd, totalSleepMinutes: sleepMin, inBedMinutes: inBed,
            deepSleepMinutes: Self.minutes(in: trimmed) { $0 == .deep },
            remSleepMinutes: Self.minutes(in: trimmed) { $0 == .rem },
            napSleepMinutes: napSleepMinutes, awakeMinutes: awakeMin,
            sleepEfficiency: Self.efficiencyPercent(sleep: sleepMin, inBed: inBed),
            boundarySource: boundarySource,
            segments: [], // re-derived from the trimmed stageIntervals via effectiveSegments
            stageIntervals: trimmed, boundaryValidation: boundaryValidation,
            hrSleepQuality: hrSleepQuality, splitGapMinutes: splitGapMinutes, edits: edits
        )
    }

    /// No per-stage timeline (e.g. HR-estimated boundaries only): clamp the
    /// onset and subtract the trimmed-off pre-recording minutes.
    private func clampedByTotals(_ recordingStart: Date, onset: Date) -> SleepData {
        let trimmedLeadMin = max(0, Int(recordingStart.timeIntervalSince(onset) / 60))
        let newTotal = max(0, totalSleepMinutes - trimmedLeadMin)
        let inBed = newTotal + awakeMinutes
        return SleepData(
            date: date, inBedStart: recordingStart, sleepStart: recordingStart, sleepEnd: sleepEnd,
            totalSleepMinutes: newTotal, inBedMinutes: inBed,
            deepSleepMinutes: deepSleepMinutes, remSleepMinutes: remSleepMinutes,
            napSleepMinutes: napSleepMinutes, awakeMinutes: awakeMinutes,
            sleepEfficiency: Self.efficiencyPercent(sleep: newTotal, inBed: inBed),
            boundarySource: boundarySource, segments: [], stageIntervals: [],
            boundaryValidation: boundaryValidation, hrSleepQuality: hrSleepQuality,
            splitGapMinutes: splitGapMinutes, edits: edits
        )
    }

    /// Drop intervals that ended before the recording started, and clip the
    /// one that straddles the boundary.
    private static func trimIntervals(
        _ intervals: [HealthKitManager.SleepStageInterval],
        from recordingStart: Date
    ) -> [HealthKitManager.SleepStageInterval] {
        intervals.compactMap { iv in
            guard iv.end > recordingStart else { return nil } // entirely pre-recording
            let clippedStart = max(iv.start, recordingStart)
            guard iv.end > clippedStart else { return nil }
            return HealthKitManager.SleepStageInterval(
                stage: iv.stage, start: clippedStart, end: iv.end, provenance: iv.provenance
            )
        }
    }

    private static func minutes(
        in intervals: [HealthKitManager.SleepStageInterval],
        matching: (HealthKitManager.SleepStage) -> Bool
    ) -> Int {
        intervals.filter { matching($0.stage) }.reduce(0) { $0 + $1.durationMinutes }
    }

    /// Whether this sleep window plausibly belongs to a recording spanning
    /// `[recordingStart, recordingEnd]`.
    ///
    /// HealthKit's sleep query returns whole sleep blocks within a broad
    /// look-back window, independent of what the strap actually measured. For a
    /// SHORT recording — e.g. a pre-sleep clip that was paused while the user
    /// was still awake — it will happily hand back the *following* night's full
    /// 7-hour block, which starts right where the clip ended and overlaps almost
    /// none of it. Attaching that fabricates hours of "sleep" the strap never
    /// saw, jumps the session to the wrong calendar day (History slots
    /// overnights by `sleepEnd`), and rewrites the archived file — which trips
    /// its integrity hash.
    ///
    /// The test is that the recording and the sleep window are NOT largely
    /// disjoint: require the overlap to be at least `minRatio` of the SHORTER of
    /// the two spans. Using the shorter span as the denominator is what makes
    /// this both safe and effective across every real shape:
    ///   - the 12-min clip + following night's 419-min block barely overlap →
    ///     overlap ≈ 0 of a 12-min minimum → REJECT (the bug);
    ///   - a normal overnight whose recording spans the sleep → overlap = the
    ///     whole sleep → ACCEPT;
    ///   - the strap left running for hours PAST wake (recording ≫ sleep) →
    ///     overlap = the whole sleep = the shorter span → ACCEPT (this is why
    ///     the denominator is NOT the recording duration — that would wrongly
    ///     reject a long tail, a case the app explicitly supports via
    ///     `displayDate` using `sleepEnd`);
    ///   - the strap removed BEFORE wake (recording ⊂ sleep) → overlap = the
    ///     whole recording = the shorter span → ACCEPT.
    ///
    /// Returns `true` when there is no usable sleep window to check (nothing to
    /// reject) or when either span is degenerate — callers that need a positive
    /// sleep window should already have guarded `totalSleepMinutes`.
    func plausiblyBelongsToRecording(
        start recordingStart: Date,
        end recordingEnd: Date,
        minRatio: Double = SleepConstants.minSleepRecordingOverlapRatio
    ) -> Bool {
        guard let sStart = sleepStart, let sEnd = sleepEnd, sEnd > sStart else { return true }
        let recordingSeconds = recordingEnd.timeIntervalSince(recordingStart)
        let sleepSeconds = sEnd.timeIntervalSince(sStart)
        let shorterSpan = min(recordingSeconds, sleepSeconds)
        guard shorterSpan > 0 else { return true }
        let overlap = min(recordingEnd, sEnd).timeIntervalSince(max(recordingStart, sStart))
        return overlap >= shorterSpan * minRatio
    }

    // MARK: - Backward-Compatible Decoding

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(Date.self, forKey: .date)
        inBedStart = try container.decodeIfPresent(Date.self, forKey: .inBedStart)
        sleepStart = try container.decodeIfPresent(Date.self, forKey: .sleepStart)
        sleepEnd = try container.decodeIfPresent(Date.self, forKey: .sleepEnd)
        totalSleepMinutes = try container.decode(Int.self, forKey: .totalSleepMinutes)
        inBedMinutes = try container.decode(Int.self, forKey: .inBedMinutes)
        deepSleepMinutes = try container.decodeIfPresent(Int.self, forKey: .deepSleepMinutes)
        remSleepMinutes = try container.decodeIfPresent(Int.self, forKey: .remSleepMinutes)
        napSleepMinutes = try container.decodeIfPresent(Int.self, forKey: .napSleepMinutes)
        awakeMinutes = try container.decode(Int.self, forKey: .awakeMinutes)
        sleepEfficiency = try container.decode(Double.self, forKey: .sleepEfficiency)
        boundarySource = try container.decode(HealthKitManager.SleepBoundarySource.self, forKey: .boundarySource)
        segments = try container.decode([HealthKitManager.SleepSegment].self, forKey: .segments)
        stageIntervals = try container.decode([HealthKitManager.SleepStageInterval].self, forKey: .stageIntervals)
        boundaryValidation = try container.decodeIfPresent(HealthKitManager.SleepBoundaryValidation.self, forKey: .boundaryValidation)
        hrSleepQuality = try container.decodeIfPresent(HealthKitManager.HRSleepQuality.self, forKey: .hrSleepQuality)
        // New field — falls back to default for data encoded before it existed
        splitGapMinutes = container.value(Int.self, .splitGapMinutes, or: SleepConstants.defaultSplitGapMinutes)
        edits = container.value([SleepEditRecord].self, .edits, or: [])
    }
}

/// Lightweight audit record for a single user edit applied to sleep data.
struct SleepEditRecord: Codable, Identifiable, Equatable {
    /// Kind of edit. Kept as a loose string so future kinds decode on older
    /// clients as `.unknown` rather than failing the whole record.
    enum Kind: String, Codable {
        case addSegment
        case removeSegment
        case split
        case merge
        case carveAwake
        case adjustBoundary
        case unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    let id: UUID
    let timestamp: Date
    let kind: Kind
    /// English description for logs and diagnostics — e.g. "Added 45 min at
    /// 11:30 PM", "Removed 7:15 AM segment". Not shown on screen.
    let summary: String

    init(kind: Kind, summary: String, timestamp: Date = Date(), id: UUID = UUID()) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.summary = summary
    }
}
