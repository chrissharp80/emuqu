@testable import Emuqu
import Foundation

/// The eval dataset as the app's own persisted sessions: each overnight with
/// its analysis, beats, sleep, vitals, score and breakdown, tags, feeling and
/// note; each partial, nap and quick reading; each workout with its splits,
/// samples, weather, feeling and heart-rate recovery.
///
/// Where the app's model needs a value the dataset does not hold, the value
/// is a neutral placeholder and is named here, so a reader of a tool result
/// knows it did not come from the dataset:
/// - HRV metrics other than RMSSD and SDNN are marked estimated
///   (`HRVAnalysisResult.estimatedMetrics`), so the records leave them out;
/// - a workout's own HRV (`hrv_rmssd_ms`, `hrv_sdnn_ms`) is 0;
/// - weather humidity is 50 %;
/// - a score factor's 0-100 sub-score is 50 plus twice its points, weight
///   0.25; its detail line states the dataset's points.
@MainActor
enum FloEvalSeeder {
    /// A session and the moment it exists for the user: when its recording ended.
    struct Item {
        let availableAt: Date
        let session: HRVSession
    }

    /// Every session the dataset holds, in the order the user had them.
    static func items(from dataset: FloEvalDataset) throws -> [Item] {
        let nights = try dataset.overnights.map(overnight)
        let partials = try dataset.partialRecordings.map(partial)
        let readings = try dataset.shortReadings.map(shortReading)
        let workouts = try dataset.workouts.map(FloEvalWorkoutSeeder.workout)
        return (nights + partials + readings + workouts).sorted { $0.availableAt < $1.availableAt }
    }

    nonisolated static func instant(_ text: String) throws -> Date {
        guard let date = EvalClock.instant(text) else { throw EvalSeedError.malformed(text) }
        return date
    }

    // MARK: - Overnights

    private static func overnight(_ night: FloEvalDataset.Overnight) throws -> Item {
        let start = try instant(night.recordingStartLocal)
        let end = try instant(night.recordingEndLocal)
        var session = HRVSession(startDate: start, tags: night.tags.map(tag), sessionType: .overnight, deviceProvenance: device(night.device, at: start))
        session.endDate = end
        session.state = .complete
        session.hrvDataQuality = .good
        session.recoveryScore = Double(night.recoveryScore0100) / 10
        session.analysisResult = try nightAnalysis(night, start: start)
        session.rrSeries = try FloEvalBeats.series(for: night, start: start, end: end, sessionId: session.id)
        session.sleepSnapshot = try sleep(night, start: start)
        session.vitalsSnapshot = vitals(night)
        session.scoreBreakdown = FloEvalBreakdown.breakdown(night)
        session.morningFeeling = night.morningFeeling15
        session.notes = night.notes
        return Item(availableAt: end, session: session)
    }

    private static func nightAnalysis(_ night: FloEvalDataset.Overnight, start: Date) throws -> HRVAnalysisResult {
        var result = analysis(rmssd: night.rmssdMs, sdnn: night.sdnnMs, meanHR: night.meanHrBpm, at: start)
        result.overnightNadirHR = night.nadirHrBpm
        result.overnightMinHR = night.nadirHrBpm
        result.overnightMaxHR = night.maxHrBpm
        result.overnightMeanHR = night.meanHrBpm
        let nadirAt = try instant(night.nadirTimeLocal)
        result.overnightNadirTimeMs = MillisecondOffset.between(nadirAt, and: start)
        return result
    }

    /// An analysis holding the dataset's RMSSD, SDNN and mean heart rate.
    /// The metrics the dataset does not hold are marked estimated, so no
    /// record reports them.
    static func analysis(rmssd: Double, sdnn: Double, meanHR: Double, at date: Date) -> HRVAnalysisResult {
        let timeDomain = TimeDomainMetrics(
            meanRR: 60000 / meanHR, sdnn: sdnn, rmssd: rmssd, pnn50: 0, sdsd: 0, meanHR: meanHR, sdHR: 0, triangularIndex: nil
        )
        let nonlinear = NonlinearMetrics(
            sd1: 0, sd2: 0, sd1Sd2Ratio: 0, sampleEntropy: nil, approxEntropy: nil, dfaAlpha1: nil, dfaAlpha2: nil, dfaAlpha1R2: nil
        )
        var result = HRVAnalysisResult(
            windowStart: 0, windowEnd: 0, timeDomain: timeDomain, frequencyDomain: nil,
            nonlinear: nonlinear, ansMetrics: nil, artifactPercentage: 0, cleanBeatCount: 0, analysisDate: date
        )
        result.estimatedMetrics = ["pnn50", "sdsd", "sdHR", "hrRange", "sd1", "sd2", "sd1Sd2Ratio", "beatCount"]
        return result
    }

    private static func sleep(_ night: FloEvalDataset.Overnight, start: Date) throws -> SleepData {
        let bedtime = try instant(night.bedtimeLocal)
        let wake = try instant(night.wakeTimeLocal)
        let efficiency = SleepData.efficiencyPercent(sleep: night.totalSleepMinutes, inBed: night.timeInBedMinutes)
        return SleepData(
            date: start, inBedStart: bedtime, sleepStart: bedtime, sleepEnd: wake,
            totalSleepMinutes: night.totalSleepMinutes, inBedMinutes: night.timeInBedMinutes,
            deepSleepMinutes: night.deepMinutes, remSleepMinutes: night.remMinutes, awakeMinutes: night.awakeMinutes,
            sleepEfficiency: efficiency, boundarySource: .healthKit
        )
    }

    /// The wrist temperature is stored as tonight's offset over a zero
    /// baseline, so the app's deviation is the dataset's deviation.
    private static func vitals(_ night: FloEvalDataset.Overnight) -> RecoveryVitals {
        RecoveryVitals(
            respiratoryRate: night.respiratoryRateBrpm, respiratoryRateBaseline: nil,
            oxygenSaturation: night.spo2AvgPct, oxygenSaturationMin: nil,
            wristTemperature: night.wristTempDeviationC, wristTemperatureBaseline: 0, restingHeartRate: night.restingHrBpm
        )
    }

    // MARK: - Partials, naps and quick readings

    /// A short segment of a night the recording lost: not reliable for trends.
    private static func partial(_ segment: FloEvalDataset.Partial) throws -> Item {
        let start = try instant(segment.startLocal)
        let end = try instant(segment.endLocal)
        var session = HRVSession(startDate: start, tags: [], sessionType: .overnight)
        session.endDate = end
        session.state = .complete
        session.hrvDataQuality = .insufficient
        session.analysisResult = analysis(rmssd: segment.rmssdMs, sdnn: 0, meanHR: segment.meanHrBpm, at: start)
        session.analysisResult?.estimatedMetrics?.append("sdnn")
        session.notes = segment.reason
        return Item(availableAt: end, session: session)
    }

    private static func shortReading(_ reading: FloEvalDataset.ShortReading) throws -> Item {
        let start = try instant(reading.startLocal)
        let end = try instant(reading.endLocal)
        var session = HRVSession(startDate: start, tags: [], sessionType: reading.kind == "nap" ? .nap : .quick)
        session.endDate = end
        session.state = .complete
        session.hrvDataQuality = .good
        session.analysisResult = analysis(rmssd: reading.rmssdMs, sdnn: 0, meanHR: reading.meanHrBpm, at: start)
        session.analysisResult?.estimatedMetrics?.append("sdnn")
        return Item(availableAt: end, session: session)
    }

    // MARK: - Tags and device

    /// The dataset's tag names as the app's system tags; "Sick" is the
    /// app's Illness tag and "Stress" its Stressed tag.
    static func tag(_ name: String) -> ReadingTag {
        let system: [String: ReadingTag] = [
            "alcohol": .alcohol, "caffeine": .caffeine, "late meal": .lateMeal, "sick": .illness, "travel": .travel, "stress": .stressed
        ]
        return system[name.lowercased()] ?? ReadingTag(name: name, colorHex: "#888888")
    }

    private static func device(_ name: String, at date: Date) -> DeviceProvenance {
        DeviceProvenance(
            deviceId: name, deviceModel: name, firmwareVersion: nil, recordingMode: .streaming,
            appVersion: "eval", osVersion: "eval", capturedAt: date
        )
    }
}
