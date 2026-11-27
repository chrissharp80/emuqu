@testable import Emuqu
import HealthKit
import XCTest

/// Derived values stay one value across every path that writes or reads
/// them: a write that replaces a snapshot keeps what another path added to
/// it, a substitute is not scored or labelled as the measure it stands in
/// for, a stored figure is read on the scale it was recorded on, a reading is
/// accepted and read back by one tolerance, and a real-clock offset is
/// compared with the real clock.
@MainActor
final class DerivedValueConsistencyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - A: every sleep-snapshot writer keeps the nap credit

    private func night(napMinutes: Int?) -> SleepData {
        SleepData(
            date: start, sleepStart: start.addingTimeInterval(600), sleepEnd: start.addingTimeInterval(7 * 3600),
            totalSleepMinutes: 380, inBedMinutes: 410, napSleepMinutes: napMinutes, awakeMinutes: 30,
            sleepEfficiency: 92, boundarySource: .healthKit
        )
    }

    private func scoredNight() -> HRVSession {
        var session = HRVSession(startDate: start, sessionType: .overnight)
        session.endDate = start.addingTimeInterval(8 * 3600)
        session.sleepSnapshot = night(napMinutes: 45)
        return session
    }

    private var boundaryInputs: SleepBoundaryWrite.Inputs {
        SleepBoundaryWrite.Inputs(
            context: RescoreContext(
                baselineStats: nil, typicalSleepHours: 8,
                scoringConfig: RecoveryScoreCalculator.ScoringConfiguration(
                    enableTrainingLoadIntegration: true, isOnTrainingBreak: false,
                    enableSleepIntegration: true, penalizeMissingSleep: false, userAge: 40
                )
            ),
            fallbackTraining: nil
        )
    }

    /// A refresh, a backfill, a retro-apply and an editor save each replace
    /// the snapshot with a night read without the nap. Each keeps the 45
    /// minutes the morning pass credited, so the stored 24 h sleep, and the
    /// score a rescore reads from it, does not drop.
    func testEverySleepSnapshotWriterKeepsTheNapCredit() throws {
        let refreshed = night(napMinutes: nil)
        let edit = try XCTUnwrap(SleepBoundaryWrite.Edit(sleepData: refreshed, isUserAdjustment: true))
        let writers: [(name: String, write: (inout HRVSession) -> Void)] = [
            ("auto refresh", { SleepRefreshPolicy.applyFreshSleep(refreshed, to: &$0) }),
            ("iCloud backfill", { SleepRefreshPolicy.applyPulledSleep(refreshed, to: &$0) }),
            ("retro-apply", { ReanalysisService.applySleepBoundaries(refreshed, to: &$0, sessionStart: self.start) }),
            ("editor save", { SleepBoundaryWrite.apply(edit, to: &$0, inputs: self.boundaryInputs) })
        ]
        for writer in writers {
            var session = scoredNight()
            writer.write(&session)
            XCTAssertEqual(session.sleepSnapshot?.napSleepMinutes, 45, writer.name)
            XCTAssertEqual(session.sleepSnapshot?.totalSleepIncludingNapMinutes, 380 + 45, writer.name)
        }
    }

    /// A night that carries its own nap credit replaces the stored one.
    func testANightWithItsOwnNapCreditReplacesTheStoredOne() {
        XCTAssertEqual(night(napMinutes: 20).keepingNapCredit(of: night(napMinutes: 45)).napSleepMinutes, 20)
        XCTAssertNil(night(napMinutes: nil).keepingNapCredit(of: nil).napSleepMinutes)
    }

    /// The one fetch every frozen, refreshed or scored night is read through
    /// credits the nap of the day before.
    func testTheNightSleepFetchCreditsTheNap() async throws {
        let healthKit = NapCreditingHealthKit(night: night(napMinutes: nil), napMinutes: 30)
        let fetched = try await healthKit.fetchNightSleep(
            for: start, recordingEnd: start.addingTimeInterval(8 * 3600), rrPoints: nil, nightAnchor: start
        )
        XCTAssertEqual(fetched.napSleepMinutes, 30)
        XCTAssertEqual(healthKit.napAnchors, [start])
    }

    // MARK: - B: a substitute heart rate is not scored as sleep HR

    /// Apple Health's daytime resting HR standing in the vitals is a
    /// different measure from the strap sleep HR the baseline is built from:
    /// it is neither scored against that baseline nor quoted as "Sleep HR".
    /// The strap's own sleep HR (the recording's mean HR) is.
    func testOnlyTheStrapSleepHRIsScoredAgainstTheSleepHRBaseline() {
        let stats = BaselineTracker.RecoveryBaselineStats(
            lnRmssdMean: log(40.0), lnRmssdSD: 0.3, lnRmssdCV7Day: 6.0,
            meanHRBaseline: 50, meanHRSD: 3, daysInWindow: 30
        )
        let cases: [(name: String, restingHR: Double, scored: Bool)] = [
            ("strap sleep HR", 52, true),
            ("Apple daytime resting HR", 58, false)
        ]
        for c in cases {
            let vitals = RecoveryVitals(
                respiratoryRate: 14, respiratoryRateBaseline: 14, oxygenSaturation: nil, oxygenSaturationMin: nil,
                wristTemperature: nil, wristTemperatureBaseline: nil, restingHeartRate: c.restingHR
            )
            let breakdown = RecoveryScoreCalculator.calculateWithBreakdown(
                RecoveryScoreCalculator.ScoreInputs(
                    hrvReadiness: nil, rmssd: 40, meanHR: 52, dfaAlpha1: nil, baselineStats: stats,
                    sleepData: night(napMinutes: nil), vitals: vitals, typicalSleepHours: 7
                ),
                trainingContext: nil, config: boundaryInputs.context.scoringConfig, referenceDate: start
            )
            let facts = breakdown.factors.first { $0.label == "Vitals" }?.facts?.vitals
            XCTAssertEqual(facts?.sleepHR, c.scored ? c.restingHR : nil, c.name)
            XCTAssertEqual(facts?.sleepHRScore != nil, c.scored, c.name)
        }
    }

    /// The Deep Dive's resting-HR text says what the score does: only the
    /// strap's sleeping HR is compared with the baseline; Apple Health's
    /// resting HR is shown, not scored.
    func testTheRestingHRExplanationSaysOnlyTheStrapSleepHRIsScored() throws {
        let vitals = PDFReportGenerator.VitalsData(
            respiratoryRate: nil, respiratoryRateBaseline: nil, oxygenSaturation: nil, oxygenSaturationMin: nil,
            wristTemperature: nil, restingHeartRate: 58
        )
        let row = try XCTUnwrap(restingHeartRateRow(vitals: vitals, bundle: LanguageManager.appBundle))
        XCTAssertTrue(row.explanation.contains("only the sleeping heart rate from your strap"), row.explanation)
        XCTAssertTrue(row.explanation.contains("not scored"), row.explanation)
    }

    // MARK: - C: a training snapshot is read on the scale it was recorded on

    private let anchors = TrainingLoadSeries.HeartRateAnchors(restingHR: 60, maxHR: 180)

    /// A snapshot frozen before the TSS scale carries no stamp: it decodes as
    /// TRIMP scale and reads on the TSS scale through the hrTSS rule, while
    /// its stored figures stay as recorded.
    func testAnUnstampedSnapshotIsReadOnTheTSSScale() throws {
        let json = #"{"atl":76,"ctl":152,"tsb":76,"yesterdayTrimp":152}"#
        let old = try JSONDecoder().decode(TrainingContext.self, from: Data(json.utf8))
        XCTAssertEqual(old.scale, .trimp)
        XCTAssertEqual(old.recordedCTL, 152)
        let converted = old.onTSSScale(anchors: anchors)
        XCTAssertEqual(converted.scale, .tss)
        XCTAssertEqual(converted.ctl, anchors.tss(fromTRIMP: 152), accuracy: 1e-9)
        XCTAssertLessThan(converted.ctl, 120, "152 TRIMP is about 100 TSS at these anchors")
        XCTAssertEqual(old.ctl, WorkoutLoadRestingHR.anchors.tss(fromTRIMP: 152), accuracy: 1e-9)
    }

    /// A snapshot built now is on the TSS scale, keeps its stored key and
    /// stamp through a round trip, and a copy with its Health readings
    /// replaced (the iCloud strip and restore) keeps both the figures and
    /// the scale, instead of stamping old figures as new.
    func testTheScaleTravelsWithTheRecordedFigures() throws {
        let now = TrainingContext(
            atl: 40, ctl: 50, tsb: 10, yesterdayTrimp: 80, vo2Max: 52, daysSinceHardWorkout: 2, recentWorkouts: nil
        )
        let decoded = try JSONDecoder().decode(TrainingContext.self, from: JSONEncoder().encode(now))
        XCTAssertEqual(decoded.scale, .tss)
        XCTAssertEqual(decoded.ctl, 50)
        let old = TrainingContext(
            atl: 76, ctl: 152, tsb: 76, yesterdayTrimp: 152, vo2Max: 52, daysSinceHardWorkout: 2,
            recentWorkouts: nil, loadScale: nil
        )
        let stripped = old.withHealthReadings(vo2Max: nil, recentWorkouts: nil)
        XCTAssertNil(stripped.loadScale)
        XCTAssertEqual(stripped.recordedCTL, 152)
        XCTAssertNil(stripped.vo2Max)
    }

    /// The Deep Dive's prior-day row shows the snapshot's load on the TSS
    /// scale, labelled load and graded by the TSS daily-load bands
    /// (50 / 150 / 300), never a TSS figure under a TRIMP name. An old
    /// TRIMP-scale snapshot is shown converted.
    func testThePriorDayRowShowsLoadOnTheTSSScale() {
        let bundle = LanguageManager.appBundle
        let cases: [(context: TrainingContext, band: String)] = [
            (TrainingContext(atl: 40, ctl: 50, tsb: 10, yesterdayTrimp: 120, vo2Max: nil, daysSinceHardWorkout: nil, recentWorkouts: nil),
             "Moderate load — normal recovery expected within 24h"),
            (TrainingContext(atl: 40, ctl: 50, tsb: 10, yesterdayTrimp: 40, vo2Max: nil, daysSinceHardWorkout: nil, recentWorkouts: nil),
             "Light day — minimal recovery demand")
        ]
        for c in cases {
            let row = yesterdayLoadRow(training: c.context, bundle: bundle)
            XCTAssertFalse(row.name.contains("TRIMP"), row.name)
            XCTAssertFalse(row.explanation.contains("TRIMP"), row.explanation)
            XCTAssertEqual(row.value, String(format: "%.0f", locale: LanguageManager.appLocale, c.context.yesterdayLoad))
            XCTAssertEqual(row.interpretation, String(localized: String.LocalizationValue(c.band), bundle: bundle))
        }
        let old = TrainingContext(
            atl: 76, ctl: 152, tsb: 76, yesterdayTrimp: 152, vo2Max: nil, daysSinceHardWorkout: nil,
            recentWorkouts: nil, loadScale: nil
        )
        XCTAssertEqual(
            yesterdayLoadRow(training: old, bundle: bundle).value,
            String(format: "%.0f", locale: LanguageManager.appLocale, WorkoutLoadRestingHR.anchors.tss(fromTRIMP: 152))
        )
    }

    // MARK: - D: one tolerance for capturing and reading HRR

    /// A reading the capture stores up to `targetToleranceSec` from its
    /// target is the one the summary reads back, at one and two minutes.
    func testTheHRRReadToleranceIsTheCaptureTolerance() {
        let tolerance = HRRSample.targetToleranceSec
        XCTAssertEqual(tolerance, 15)
        for target in HRRSample.targetOffsetsSec {
            for offset in [target - tolerance, target + tolerance, target + tolerance + 1] {
                let sample = HRRSample(offsetSec: offset, hr: 120, drop: 30, peakHR: 150, provenance: .strap)
                let read = target == 60 ? [sample].bestAtOneMinute : [sample].bestAtTwoMinutes
                XCTAssertEqual(read != nil, abs(offset - target) <= tolerance, "target \(target), offset \(offset)")
                XCTAssertEqual(sample.target == target, abs(offset - target) <= tolerance, "target \(target), offset \(offset)")
            }
        }
    }

    // MARK: - E: readiness is continuous and non-decreasing in CTL

    /// For a fixed load, readiness never falls as the fitness base grows,
    /// and no small step in CTL moves it by more than a small step: there is
    /// no cliff where one model hands over to another. CTL 0 to 30 spans the
    /// fitness-base boundary and the ratio's floor.
    func testBaseReadinessIsContinuousAndMonotonicAcrossLowCTL() {
        for (atl, acute) in [(0.0, 0.0), (5.0, 9.0), (10.0, 30.0), (20.0, 60.0)] {
            var previous = ReadinessScoring.computeBaseReadiness(ctl: 0, atl: atl, acuteFatigue: acute)
            for step in 1 ... 3000 {
                let ctl = Double(step) * 0.01
                let readiness = ReadinessScoring.computeBaseReadiness(ctl: ctl, atl: atl, acuteFatigue: acute)
                XCTAssertGreaterThanOrEqual(readiness, previous - 1e-9, "load \(atl)+\(acute) at CTL \(ctl)")
                XCTAssertLessThan(abs(readiness - previous), 1.0, "load \(atl)+\(acute) jumps at CTL \(ctl)")
                previous = readiness
            }
        }
    }

    /// A beginner's light day reads as matched, not as an extreme overload,
    /// on either side of the fitness-base boundary the advice uses.
    func testABeginnerIsNotReadAsOverloadedJustAboveTheBoundary() {
        let boundary = RecoveryScoreConstants.Readiness.ctlThreshold
        for ctl in [boundary - 0.01, boundary + 0.01] {
            let readiness = ReadinessScoring.computeBaseReadiness(ctl: ctl, atl: 5, acuteFatigue: 9)
            XCTAssertGreaterThan(readiness, 65, "CTL \(ctl)")
        }
    }

    // MARK: - F: real-clock offsets meet the real clock

    /// A Verity Sense recording keeps only the intervals its gate accepts,
    /// so the beat clock ends before the recording does. A sleep end from
    /// Apple Health, wall-clock time, is clamped to the real end.
    func testSleepEndIsClampedToTheRealClockEnd() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 1000, wallClockMs: 0),
            RRPoint(t_ms: 1000, rr_ms: 1000, wallClockMs: 1000),
            RRPoint(t_ms: 2000, rr_ms: 1000, wallClockMs: 5000)
        ]
        XCTAssertEqual(BeatTimeline.endMs(points), 6000)
        var session = HRVSession(startDate: start, sessionType: .overnight)
        session.rrSeries = RRSeries(points: points, sessionId: session.id, startDate: start)
        XCTAssertEqual(ReanalysisService.recordingDurationMs(of: session), 6000)
        let sleep = SleepData(
            date: start, sleepStart: start, sleepEnd: start.addingTimeInterval(5.5),
            totalSleepMinutes: 1, inBedMinutes: 1, awakeMinutes: 0, sleepEfficiency: 100, boundarySource: .healthKit
        )
        ReanalysisService.applySleepBoundaries(sleep, to: &session, sessionStart: start)
        XCTAssertEqual(session.sleepEndMs, 5500)
    }

    /// An imported GPX hike and the app's own recording of it, started 45
    /// minutes in, are one session by time overlap however far apart they
    /// started; the whole hike counts, not the part the app recorded, even
    /// though the recording carries richer data.
    func testOverlappingWorkoutsCountOnceWhateverTheirStartGap() {
        let hike = HealthKitManager.WorkoutSummary(
            date: start, type: .hiking, durationMinutes: 180, caloriesBurned: nil, averageHR: 120, maxHR: nil
        )
        let recording = HealthKitManager.WorkoutSummary(
            date: start.addingTimeInterval(45 * 60), type: .hiking, durationMinutes: 90,
            caloriesBurned: 600, averageHR: 122, maxHR: 151
        )
        let merged = TrainingHealthQueries.mergeArchiveAuthoritative(archive: [hike, recording], healthKit: [])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.durationMinutes, 180)
        let later = HealthKitManager.WorkoutSummary(
            date: start.addingTimeInterval(181 * 60), type: .hiking, durationMinutes: 30,
            caloriesBurned: 100, averageHR: 110, maxHR: 120
        )
        XCTAssertEqual(TrainingHealthQueries.deduplicateWorkouts([hike, later]).count, 2, "a workout after the hike ends stays")
    }
}

/// Answers a night's sleep and a nap, and records the anchor the nap was
/// asked for.
@MainActor
private final class NapCreditingHealthKit: HealthKitServiceProtocol {
    let night: SleepData
    let napMinutes: Int
    private(set) var napAnchors: [Date] = []

    init(night: SleepData, napMinutes: Int) {
        self.night = night
        self.napMinutes = napMinutes
    }

    nonisolated var isHealthKitAvailable: Bool { true }

    func fetchSleepData(
        for _: Date, recordingEnd _: Date, rrPoints _: [RRPoint]?,
        autoSleepExtension _: SleepResolver.AutoSleepExtension?, rrStart _: Date?
    ) async throws -> SleepData {
        night
    }

    func fetchDaytimeNapMinutes(nightAnchoredAt nightAnchor: Date) async -> Int {
        napAnchors.append(nightAnchor)
        return napMinutes
    }

    func fetchDaytimeRestingHR(for _: Date) async throws -> Double? { nil }

    func calculateTrainingLoad(relativeTo _: Date) async -> HealthKitManager.TrainingLoad {
        HealthKitManager.TrainingLoad(
            vo2Max: nil, recentWorkouts: [], weeklyLoadScore: 0,
            daysSinceHardWorkout: nil, acuteChronicRatio: nil, metrics: nil
        )
    }

    func calculateTrainingLoadIfAnswered(relativeTo date: Date) async -> HealthKitManager.TrainingLoad? {
        await calculateTrainingLoad(relativeTo: date)
    }

    func fetchRecoveryVitals(relativeTo _: Date) async -> RecoveryVitals {
        RecoveryVitals(
            respiratoryRate: nil, respiratoryRateBaseline: nil, oxygenSaturation: nil, oxygenSaturationMin: nil,
            wristTemperature: nil, wristTemperatureBaseline: nil, restingHeartRate: nil
        )
    }

    func estimateSleepFromHealthKitHR(
        windowStart _: Date, windowEnd _: Date, minimumSamples _: Int, minimumSleepMinutes _: Int
    ) async -> SleepData? {
        nil
    }

    func exportSessionMetrics(from _: HRVSession) async throws {}
}
