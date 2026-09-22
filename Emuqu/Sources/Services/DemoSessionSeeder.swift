import Foundation

/// Seeds three weeks of synthetic overnight recordings so the app can be
/// evaluated without a chest strap.
///
/// ## Why this exists
///
/// Emuqu's every screen is downstream of a recording. Without one, a reviewer
/// sees empty states and cannot assess the product at all — and the reviewer
/// is exactly the person who will not have a Polar H10.
///
/// One night is not enough either. The recovery score is withheld until a
/// baseline of 14 nights exists, and trends need a history to draw, so a
/// single sample night demonstrates the "building your baseline" screen and
/// nothing else. `defaultNightCount` nights clear that threshold with room for
/// the trend charts to show a shape.
///
/// ## What it produces
///
/// Synthetic but physiologically coherent nights: RR intervals shaped by a
/// sleep-stage sequence (deep sleep early, REM late, brief awakenings), a
/// nocturnal heart-rate dip and respiratory sinus arrhythmia. Each night is
/// run through the app's own sleep estimator and analyser rather than
/// carrying hand-written metrics, so the numbers on screen were computed by
/// the same code a real recording uses. A fixture with pasted-in results would
/// demo the UI while bypassing everything underneath it.
///
/// The nights tell a story rather than being noise: recovery drifts upward
/// across the weeks, weekend nights dip, and three nights go badly for a named
/// reason (tagged, so the tag-based explanations have something to explain).
///
/// ## Telling it apart from real data
///
/// Every seeded session carries `demoTag`, identified by a fixed id rather
/// than its name, because a user can create a tag called "Demo" themselves
/// and removal must never touch a session they tagged. Removal also accepts
/// the ids this device seeded, so a sample night whose tag was edited away is
/// still found.
///
/// Deliberately NOT wired into any launch path. Nothing calls it
/// automatically; `SampleDataLibrary` runs it when the user asks.
enum DemoSessionSeeder {
    /// Name of the tag that marks a session as sample data.
    static let demoTagName = "Demo"

    /// The tag every seeded session carries. Matched by `id`, never by name.
    static let demoTag = ReadingTag(id: demoTagId, name: demoTagName, colorHex: "#8E8E93")

    /// A literal that is a valid UUID by inspection; trapping with a named
    /// reason beats a bare `!` if it is ever edited into one that is not.
    private static let demoTagId: UUID = {
        guard let id = UUID(uuidString: "5A3D0000-DE30-4000-8000-000000000001") else {
            preconditionFailure("Sample-data tag id is not a valid UUID")
        }
        return id
    }()

    /// Three weeks: past the 14-night baseline gate with a week of scored
    /// nights beyond it and three weeks for the trends to draw. More nights
    /// would add little and make the wait longer — each is seconds of analysis.
    static let defaultNightCount = 21

    /// Kept clear of any existing recording on either side, so a sample night
    /// can never be mistaken for, or merged into, a real one.
    static let occupancyPadding: TimeInterval = 3 * 3600

    /// Whether these tags mark a session as sample data.
    static func isSampleData(_ tags: [ReadingTag]) -> Bool {
        tags.contains { $0.id == demoTag.id }
    }

    /// Every archived session that is sample data: it carries the sample tag,
    /// or it is one of the ids this device seeded. Nothing else qualifies.
    static func sampleSessionIds(in entries: [SessionArchiveEntry], seededIds: Set<UUID>) -> [UUID] {
        entries
            .filter { isSampleData($0.tags) || seededIds.contains($0.sessionId) }
            .map(\.sessionId)
    }

    // MARK: - Pipeline seam

    /// The two pieces of the app's pipeline a night goes through before it is
    /// scored. Production passes the real window selection and analysis; the
    /// sleep estimate defaults to the app's strap-only estimator, which is
    /// what a reviewer without an Apple Watch would see on a real night.
    struct NightPipeline: Sendable {
        var analyze: @Sendable (HRVSession) async -> HRVAnalysisResult?
        var estimateSleep: @Sendable ([RRPoint], Date) -> SleepData? = { points, start in
            HRSleepEstimator.estimateSleepFromHR(rrPoints: points, recordingStart: start)
        }
    }

    // MARK: - Seeding

    /// Build, score and archive one sample night per plan, oldest first.
    ///
    /// Nights are built off the main actor, a few at once — the analysis is
    /// seconds of work per night. Scoring then runs in date order on the main
    /// actor through `finalize`, because each night is scored against the
    /// baseline the nights before it built, exactly as mornings are. Only then
    /// is anything written, so a failure part-way leaves nothing half-seeded
    /// behind.
    ///
    /// Returns the ids written. Plans that collide with an existing recording
    /// are skipped, so the count can be lower than `plans.count`.
    @MainActor
    static func seed(
        _ plans: [NightPlan],
        into archive: SessionArchive,
        pipeline: NightPipeline,
        finalize: @MainActor (HRVSession) async -> HRVSession,
        progress: @MainActor (Int, Int) -> Void
    ) async throws -> [UUID] {
        let nights = await buildAll(unoccupied(plans, in: archive.entries), pipeline: pipeline, progress: progress)
        var finished: [HRVSession] = []
        for night in withVitals(nights) {
            finished.append(await finalize(night))
        }
        let toWrite = finished
        try await Task.detached(priority: .userInitiated) { try writeAll(toWrite, to: archive) }.value
        debugLog("[SampleData] Seeded \(toWrite.count) sample nights", level: .info)
        return toWrite.map(\.id)
    }

    /// Nights built at once. They are independent, so a few can be in flight;
    /// more than that only competes with the interface for the same cores.
    static let parallelNights = 3

    /// Every night built, returned oldest first. The pipeline must be safe to
    /// call concurrently; production gives each night its own window selector.
    @MainActor
    private static func buildAll(
        _ plans: [NightPlan], pipeline: NightPipeline, progress: @MainActor (Int, Int) -> Void
    ) async -> [HRVSession] {
        await withTaskGroup(of: HRVSession.self) { group in
            var pending = plans[...]
            var built: [HRVSession] = []
            startNext(from: &pending, in: &group, pipeline: pipeline, count: parallelNights)
            for await night in group {
                built.append(night)
                progress(built.count, plans.count)
                startNext(from: &pending, in: &group, pipeline: pipeline, count: 1)
            }
            return built.sorted { $0.startDate < $1.startDate }
        }
    }

    private static func startNext(
        from pending: inout ArraySlice<NightPlan>, in group: inout TaskGroup<HRVSession>, pipeline: NightPipeline, count: Int
    ) {
        for _ in 0 ..< count {
            guard let plan = pending.popFirst() else { return }
            group.addTask(priority: .userInitiated) { await buildNight(plan, pipeline: pipeline) }
        }
    }

    /// Plans whose night, padded by `occupancyPadding`, overlaps no archived
    /// session.
    static func unoccupied(_ plans: [NightPlan], in entries: [SessionArchiveEntry]) -> [NightPlan] {
        plans.filter { plan in
            let earliest = plan.start.addingTimeInterval(-occupancyPadding)
            let latest = plan.end.addingTimeInterval(occupancyPadding)
            return !entries.contains { ($0.endDate ?? $0.date) >= earliest && $0.date <= latest }
        }
    }

    /// One night: beats, the sleep inferred from them, and the analysis.
    static func buildNight(_ plan: NightPlan, pipeline: NightPipeline) async -> HRVSession {
        let id = UUID()
        let points = syntheticNight(plan)
        var session = HRVSession(
            id: id, startDate: plan.start, endDate: plan.end, state: .complete, sessionType: .overnight,
            rrSeries: RRSeries(points: points, sessionId: id, startDate: plan.start),
            analysisResult: nil, artifactFlags: nil, tags: [demoTag] + plan.tags
        )
        attachSleep(pipeline.estimateSleep(points, plan.start), to: &session)
        session.analysisResult = await pipeline.analyze(session)
        return session
    }

    private static func attachSleep(_ sleep: SleepData?, to session: inout HRVSession) {
        let start = session.startDate
        session.sleepSnapshot = sleep
        session.sleepStartMs = sleep?.sleepStart.flatMap { MillisecondOffset.between($0, and: start) }
        session.sleepEndMs = sleep?.sleepEnd.flatMap { MillisecondOffset.between($0, and: start) }
    }

    /// Overnight vitals as a strap night supplies them: the analysis window's
    /// heart rate standing in for resting HR, and the breathing rate the
    /// analysis found, against the mean of up to seven nights before it.
    static func withVitals(_ nights: [HRVSession]) -> [HRVSession] {
        var recentBreathing: [Double] = []
        return nights.map { night in
            var session = night
            let breathing = night.analysisResult?.ansMetrics?.respirationRate
            session.vitalsSnapshot = RecoveryVitals(
                respiratoryRate: breathing,
                respiratoryRateBaseline: weekMean(recentBreathing),
                oxygenSaturation: nil, oxygenSaturationMin: nil,
                wristTemperature: nil, wristTemperatureBaseline: nil,
                restingHeartRate: night.analysisResult?.timeDomain.meanHR
            )
            if let breathing { recentBreathing.append(breathing) }
            return session
        }
    }

    /// Mean of the last seven values, or nil before there are any.
    private static func weekMean(_ values: [Double]) -> Double? {
        let week = values.suffix(7)
        return week.isEmpty ? nil : week.reduce(0, +) / Double(week.count)
    }

    /// Written as-is, never merged. A same-night merge could fold a sample
    /// night into a real recording, and removing the sample would then take the
    /// real one with it. `unoccupied` already keeps sample nights off nights
    /// that hold a recording; skipping the merge makes certain.
    nonisolated private static func writeAll(_ sessions: [HRVSession], to archive: SessionArchive) throws {
        var written: [UUID] = []
        do {
            for session in sessions {
                _ = try archive.archive(session, skipSameNightMerge: true)
                written.append(session.id)
            }
        } catch {
            _ = remove(written, from: archive)
            throw error
        }
    }

    // MARK: - Removal

    /// Delete these sessions through the archive's ordinary delete, which
    /// tombstones each id so a sync pull cannot bring it back. Returns the ids
    /// actually removed; a failure is logged and left for the caller to report.
    nonisolated static func remove(_ ids: [UUID], from archive: SessionArchive) -> [UUID] {
        ids.compactMap { id in
            do {
                try archive.delete(id)
                return id
            } catch {
                let shortId = id.uuidString.prefix(8)
                debugLog("[SampleData] Could not remove sample night \(shortId): \(error.localizedDescription)", level: .warning)
                return nil
            }
        }
    }
}

// MARK: - Night plans

extension DemoSessionSeeder {
    /// Everything that makes one sample night different from the others.
    struct NightPlan: Sendable, Equatable {
        /// 0 is the oldest night.
        let index: Int
        let start: Date
        let end: Date
        /// 0 is a wrecked night, 1 as well as this sleeper ever recovers.
        let recovery: Double
        let breathsPerMinute: Double
        /// Context tags on the bad nights, so the explanations have a cause.
        let tags: [ReadingTag]

        var duration: TimeInterval { end.timeIntervalSince(start) }
        var seed: UInt64 { UInt64(index + 1) &* 0x9E37_79B9_7F4A_7C15 }
    }

    /// A night that goes badly, counted back from the newest, and why.
    private struct HardNight {
        let nightsBeforeNewest: Int
        let recovery: Double
        let tag: ReadingTag
    }

    private static let hardNights = [
        HardNight(nightsBeforeNewest: 4, recovery: 0.14, tag: .alcohol),
        HardNight(nightsBeforeNewest: 11, recovery: 0.22, tag: .lateMeal),
        HardNight(nightsBeforeNewest: 19, recovery: 0.17, tag: .travel)
    ]

    /// Consecutive nights, oldest first, the newest ending this morning — or
    /// yesterday morning, when this morning's wake time has not happened yet.
    static func nightPlans(count: Int = defaultNightCount, now: Date, calendar: Calendar = .current) -> [NightPlan] {
        let plans = nightPlans(count: count, newestDaysBack: 0, calendar: calendar, now: now)
        guard let newest = plans.last, newest.end > now else { return plans }
        return nightPlans(count: count, newestDaysBack: 1, calendar: calendar, now: now)
    }

    private static func nightPlans(count: Int, newestDaysBack: Int, calendar: Calendar, now: Date) -> [NightPlan] {
        let today = calendar.startOfDay(for: now)
        return (0 ..< max(0, count)).compactMap { index in
            let daysBack = count - 1 - index + newestDaysBack
            guard let morning = calendar.date(byAdding: .day, value: -daysBack, to: today) else { return nil }
            return plan(index: index, count: count, morning: morning, calendar: calendar)
        }
    }

    private static func plan(index: Int, count: Int, morning: Date, calendar: Calendar) -> NightPlan {
        var rng = SampleRandom(seed: UInt64(index + 1) &* 0xD1B5_4A32_D192_ED03)
        let hard = hardNights.first { count - 1 - index == $0.nightsBeforeNewest }
        let weekday = calendar.component(.weekday, from: morning)
        let isWeekendNight = weekday == 1 || weekday == 7
        let recovery = hard?.recovery ?? usualRecovery(index: index, count: count, weekend: isWeekendNight, rng: &rng)
        let hours = 6.5 + 1.4 * recovery + rng.uniform(-0.25, 0.25) + (isWeekendNight ? 0.4 : 0)
        let wake = morning.addingTimeInterval((6.4 + rng.uniform(0, 0.7) + (isWeekendNight ? 0.8 : 0)) * 3600)
        return NightPlan(
            index: index, start: wake.addingTimeInterval(-hours * 3600), end: wake, recovery: recovery,
            breathsPerMinute: 15.3 - 1.8 * recovery + rng.uniform(-0.3, 0.3), tags: hard.map { [$0.tag] } ?? []
        )
    }

    /// An upward drift as fitness builds, a dip on weekend nights, and a
    /// little night-to-night scatter.
    private static func usualRecovery(index: Int, count: Int, weekend: Bool, rng: inout SampleRandom) -> Double {
        let trend = 0.42 + 0.26 * Double(index) / Double(max(1, count - 1))
        let scatter = rng.uniform(-0.07, 0.07)
        return min(0.92, max(0.08, trend + scatter - (weekend ? 0.12 : 0)))
    }
}

// MARK: - Synthetic beats

extension DemoSessionSeeder {
    /// Beats for one night.
    ///
    /// Each component is a real property of overnight HRV rather than
    /// decoration: heart rate falls across the first half of the night and
    /// climbs toward waking; deep sleep slows and steadies it, REM and waking
    /// quicken and roughen it; and respiratory sinus arrhythmia — the
    /// beat-to-beat oscillation with breathing that is most of what RMSSD
    /// measures — is strongest on a well-recovered night. A flat series with
    /// noise would produce metrics no real night produces.
    static func syntheticNight(_ plan: NightPlan) -> [RRPoint] {
        let stages = hypnogram(for: plan)
        let totalMs = MillisecondOffset.between(plan.end, and: plan.start, fallback: 0)
        var rng = SampleRandom(seed: plan.seed ^ 0x00BE_A75E)
        var model = BeatModel(plan: plan)
        var cursor = 0
        var points: [RRPoint] = []
        points.reserveCapacity(Int(max(0, totalMs / 900)))
        while model.elapsedMs < totalMs {
            let progress = Double(model.elapsedMs) / Double(max(1, totalMs))
            let stage = stages.stage(at: model.elapsedMs, cursor: &cursor)
            let interval = model.nextInterval(stage: stage, progress: progress, rng: &rng)
            points.append(RRPoint(t_ms: model.elapsedMs, rr_ms: interval))
            model.elapsedMs += Int64(interval)
        }
        return points
    }

    /// The night's sleep stages: a spell awake, then ~90-minute cycles in
    /// which deep sleep shrinks and REM grows as the night goes on, with brief
    /// awakenings more likely on a poorly recovered night.
    static func hypnogram(for plan: NightPlan) -> Hypnogram {
        var rng = SampleRandom(seed: plan.seed ^ 0x0005_7A6E)
        var segments: [(stage: SleepStage, minutes: Double)] = [
            (.awake, 8 + 14 * (1 - plan.recovery) + rng.uniform(0, 5))
        ]
        let sleepMinutes = plan.duration / 60 - 10
        var cycle = 0
        while segments.reduce(0, { $0 + $1.minutes }) < sleepMinutes {
            segments += sleepCycle(cycle, recovery: plan.recovery, rng: &rng)
            cycle += 1
        }
        return Hypnogram(segments: segments)
    }

    private static func sleepCycle(
        _ cycle: Int, recovery: Double, rng: inout SampleRandom
    ) -> [(stage: SleepStage, minutes: Double)] {
        let slot = min(cycle, 4)
        let deep = max(0, [38.0, 28, 16, 8, 3][slot] * (0.55 + 0.7 * recovery) + rng.uniform(-3, 3))
        let rem = [9.0, 17, 24, 29, 33][slot] + rng.uniform(-3, 3)
        var stages: [(stage: SleepStage, minutes: Double)] = [
            (.core, 14 + rng.uniform(0, 8)), (.deep, deep), (.core, 8 + rng.uniform(0, 6)), (.rem, rem)
        ]
        if rng.uniform(0, 1) < 0.15 + 0.5 * (1 - recovery) {
            stages.append((.awake, rng.uniform(2, 7)))
        }
        return stages
    }

    /// Sleep stages as the millisecond offsets at which each one ends.
    struct Hypnogram: Sendable {
        let stages: [SleepStage]
        let endsMs: [Int64]

        init(segments: [(stage: SleepStage, minutes: Double)]) {
            var elapsed = 0.0
            stages = segments.map(\.stage)
            endsMs = segments.map { segment in
                elapsed += segment.minutes
                return Int64((elapsed * 60_000).rounded())
            }
        }

        /// The stage at `ms`, advancing `cursor` (beats arrive in order). Awake
        /// once the cycles run out, which is the morning.
        func stage(at ms: Int64, cursor: inout Int) -> SleepStage {
            while cursor < endsMs.count, endsMs[cursor] <= ms {
                cursor += 1
            }
            return cursor < stages.count ? stages[cursor] : .awake
        }
    }

    /// How a stage moves the beat: interval offset, breathing-driven swing,
    /// and irregularity.
    private struct StageTarget {
        let intervalOffset: Double
        let swingScale: Double
        let irregularity: Double

        static func of(_ stage: SleepStage) -> StageTarget {
            switch stage {
            case .deep: StageTarget(intervalOffset: 45, swingScale: 1.35, irregularity: 5)
            case .rem: StageTarget(intervalOffset: -40, swingScale: 0.6, irregularity: 18)
            case .awake: StageTarget(intervalOffset: -170, swingScale: 0.45, irregularity: 24)
            case .core, .unspecified: StageTarget(intervalOffset: 0, swingScale: 0.95, irregularity: 12)
            }
        }
    }

    /// Beat generator state. Stage changes are eased in over tens of beats, as
    /// the autonomic shift is; a step change would read as an artifact.
    private struct BeatModel {
        let plan: NightPlan
        var elapsedMs: Int64 = 0
        private var offset = StageTarget.of(.awake).intervalOffset
        private var swing = StageTarget.of(.awake).swingScale
        private var irregularity = StageTarget.of(.awake).irregularity
        private var breathPhase = 0.0
        private var slowPhase = 0.0

        init(plan: NightPlan) {
            self.plan = plan
        }

        mutating func nextInterval(stage: SleepStage, progress: Double, rng: inout SampleRandom) -> Int {
            ease(toward: StageTarget.of(stage))
            let base = 950 + 150 * plan.recovery + 20 * sin(progress * .pi)
            let breathing = (18 + 36 * plan.recovery) * swing * sin(breathPhase)
            let slowWave = 9 * swing * sin(slowPhase)
            let raw = base + offset + breathing + slowWave + irregularity * rng.gaussian()
            let interval = min(1_500, max(450, raw.rounded()))
            breathPhase += 2 * .pi * plan.breathsPerMinute / 60 * interval / 1000
            slowPhase += 2 * .pi * 0.1 * interval / 1000
            return Int(interval)
        }

        private mutating func ease(toward target: StageTarget) {
            let rate = 1.0 / 40
            offset += (target.intervalOffset - offset) * rate
            swing += (target.swingScale - swing) * rate
            irregularity += (target.irregularity - irregularity) * rate
        }
    }

    /// SplitMix64. The standard library's generator cannot be seeded, and the
    /// sample nights must come out the same on every device so a reviewer, a
    /// support conversation and the tests all see the same nights.
    struct SampleRandom: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }

        mutating func uniform(_ low: Double, _ high: Double) -> Double {
            low + (high - low) * Double(next() >> 11) / Double(UInt64(1) << 53)
        }

        /// Standard normal, by Box–Muller.
        mutating func gaussian() -> Double {
            let radius = sqrt(-2 * log(max(uniform(0, 1), .leastNonzeroMagnitude)))
            return radius * cos(2 * .pi * uniform(0, 1))
        }
    }
}
