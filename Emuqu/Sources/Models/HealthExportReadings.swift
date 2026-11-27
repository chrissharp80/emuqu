import Foundation

/// What a session's export to Apple Health is written from
/// (`HealthWriteAndObserve.exportSessionMetrics`): the beats, the analysis
/// figures the HRV, heart-rate and resting-heart-rate exports read, the end
/// date their samples are dated at, and the sleep the sleep export writes.
/// Two copies of a session with equal readings write the same samples, so a
/// write that changes none of them needs no new export, and one that changes
/// any leaves Health describing the session as it was until it is exported
/// again.
struct HealthExportReadings: Equatable {
    let sessionType: SessionType
    let endDate: Date?
    let beatCount: Int
    let firstBeatMs: Int64?
    let lastBeatMs: Int64?
    let summarySDNN: Double?
    let meanHR: Double?
    let nocturnalMedianHR: Double?
    let sleepStart: Date?
    let sleepEnd: Date?
    let sleepMinutes: Int?

    init(of session: HRVSession) {
        let points = session.rrSeries?.points ?? []
        sessionType = session.sessionType
        endDate = session.endDate
        beatCount = points.count
        firstBeatMs = points.first?.t_ms
        lastBeatMs = points.last?.t_ms
        summarySDNN = session.analysisResult?.measuredSDNN
        meanHR = session.analysisResult?.timeDomain.meanHR
        nocturnalMedianHR = session.analysisResult?.ansMetrics?.nocturnalMedianHR
        sleepStart = session.sleepSnapshot?.sleepStart
        sleepEnd = session.sleepSnapshot?.sleepEnd
        sleepMinutes = session.sleepSnapshot?.nightSleepMinutes
    }
}
