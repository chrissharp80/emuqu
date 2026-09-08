import Foundation
import HealthKit

// Sleep READS live in `SleepHealthQueries` — 456 lines out of
// HealthKitManager, following the seam that took the vitals and training
// queries out.
//
// These forwarders keep every existing call site working. Sleep export, trend
// analysis and the observers stayed on `+SleepTrends.swift`.

extension HealthKitManager {
    /// The sleep-query subsystem. Lazy — a launch that never opens a morning
    /// reading never builds it.
    var sleepQueries: SleepHealthQueries {
        SleepHealthQueries(manager: self)
    }

    func sleepReadExcludingOwnWrites(dateRange: NSPredicate) -> NSPredicate {
        sleepQueries.sleepReadExcludingOwnWrites(dateRange: dateRange)
    }

    func fetchLastNightSleep(relativeTo referenceDate: Date = Date()) async throws -> SleepData {
        try await sleepQueries.fetchLastNightSleep(relativeTo: referenceDate)
    }

    func fetchSleepData(
        for recordingStart: Date,
        recordingEnd: Date,
        rrPoints: [RRPoint]? = nil,
        autoSleepExtension: SleepResolver.AutoSleepExtension? = nil
    ) async throws -> SleepData {
        try await sleepQueries.fetchSleepData(
            for: recordingStart, recordingEnd: recordingEnd,
            rrPoints: rrPoints, autoSleepExtension: autoSleepExtension
        )
    }

    func fetchDaytimeNapMinutes(nightAnchoredAt nightAnchor: Date) async -> Int {
        await sleepQueries.fetchDaytimeNapMinutes(nightAnchoredAt: nightAnchor)
    }

    func findAdditionalSleepRange(after anchor: Date, before cutoff: Date) async -> (start: Date, end: Date)? {
        await sleepQueries.findAdditionalSleepRange(after: anchor, before: cutoff)
    }

    func estimateSleepFromHealthKitHR(
        windowStart: Date,
        windowEnd: Date,
        minimumSamples: Int = 12,
        minimumSleepMinutes: Int = 120
    ) async -> SleepData? {
        await sleepQueries.estimateSleepFromHealthKitHR(
            windowStart: windowStart, windowEnd: windowEnd,
            minimumSamples: minimumSamples, minimumSleepMinutes: minimumSleepMinutes
        )
    }

    /// Pure statics — no manager state — so they forward to the type, not an
    /// instance.
    nonisolated static func estimateSleepFromHR(rrPoints: [RRPoint], recordingStart: Date) -> SleepData? {
        SleepHealthQueries.estimateSleepFromHR(rrPoints: rrPoints, recordingStart: recordingStart)
    }

    nonisolated static func qualifyingNapMinutes(
        asleepIntervals: [(start: Date, end: Date)],
        episodeGapSeconds: TimeInterval,
        floorSeconds: TimeInterval
    ) -> Int {
        SleepHealthQueries.qualifyingNapMinutes(
            asleepIntervals: asleepIntervals,
            episodeGapSeconds: episodeGapSeconds,
            floorSeconds: floorSeconds
        )
    }
}
