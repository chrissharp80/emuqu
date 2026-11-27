import CoreLocation
import Foundation

// When a recovered workout ended and where its pauses fall: the end on the
// wall clock from every stream the crash left, and the pauses its backup
// (or the archived copy a trim rebuilds) holds.

extension WorkoutRecoveryService {
    /// The pauses the crash backup holds, else those of the archived copy a
    /// trim rebuilds (its backup is gone once the workout was saved), placed
    /// on the wall clock from its spans.
    static func pauseEvents(_ prepared: Prepared, startDate: Date) -> [PauseTimeline.Event] {
        if let backedUp = prepared.workoutRecord?.pauseEvents, !backedUp.isEmpty { return backedUp }
        var pausedBefore: TimeInterval = 0
        return (prepared.existingSession?.workoutMetadata?.pauseSpans ?? []).sorted { $0.atElapsed < $1.atElapsed }.map { span in
            let pausedAt = startDate.addingTimeInterval(TimeInterval(span.atElapsed) + pausedBefore)
            pausedBefore += span.seconds
            return PauseTimeline.Event(atElapsed: span.atElapsed, pausedAt: pausedAt, resumedAt: pausedAt.addingTimeInterval(span.seconds))
        }
    }

    /// The steps of `track` a pause makes not count, by the live rule
    /// (`WorkoutLocationManager.trackPauses`): a step ending at a fix taken
    /// inside a pause adds neither distance nor time, and the first step
    /// across a pause's end adds distance but not time.
    static func trackPauses(of track: [CLLocation], windows: [ClosedRange<Date>]) -> WorkoutAnalyzer.TrackPauses {
        var pauses = WorkoutAnalyzer.TrackPauses()
        for index in track.indices.dropFirst() {
            let (from, to) = (track[index - 1].timestamp, track[index].timestamp)
            if windows.contains(where: { $0.contains(to) }) {
                pauses.paused.insert(index)
            } else if windows.contains(where: { $0.upperBound >= from && $0.upperBound < to }) {
                pauses.gaps.insert(index)
            }
        }
        return pauses
    }

    /// Clips the GPS track to the workout's end (`resolveEndDate`), so a
    /// trimmed workout's distance matches its (shorter) duration.
    ///
    /// A Watch route is the authoritative full route and is returned whole:
    /// it did not come from the phone GPS that the crash truncated.
    static func clipTrack(_ rawTrack: [CLLocation], isOverride: Bool, endDate: Date) -> [CLLocation] {
        if isOverride { return rawTrack }
        return rawTrack.filter { $0.timestamp <= endDate }
    }

    /// When the workout actually ended, on the wall clock.
    ///
    /// The beats' own clock (`t_ms`) sums the intervals received and stands
    /// still through a strap dropout, so their end is placed on the wall
    /// clock (`WorkoutAnalyzer.gapCorrectedOffsetsMs`, from `wallClockMs`).
    /// When that end is final (`rrEndIsFinal`: a trim, or a trailing rest cut
    /// off) it is the end. Otherwise the end is the latest moment anything
    /// was still recorded: the last beat, GPS fix, per-second sample (placed
    /// on the wall clock past the `pauses` before it) or barometer reading,
    /// so a strap that dropped out or died mid-run does not cut the route
    /// and the time recorded after it. Returning `startDate` is the last
    /// resort; `rebuild` then saves nothing (see `hasRecoverableData`).
    static func resolveEndDate(
        startDate: Date,
        rrPoints: [RRPoint],
        track: [CLLocation],
        liveSamples: [WorkoutSample],
        baroSamples: [WorkoutTrackBackup.PersistedBaro],
        rrEndIsFinal: Bool = false,
        pauses: PauseTimeline = PauseTimeline()
    ) -> Date {
        let rrEnd = WorkoutAnalyzer.gapCorrectedOffsetsMs(rrPoints).last.map { startDate.addingTimeInterval(Double($0) / 1000.0) }
        if rrEndIsFinal, let rrEnd { return rrEnd }
        let evidence: [Date?] = [
            rrEnd, track.last?.timestamp,
            liveSamples.last.map { pauses.wallClock(forOffset: $0.offsetSec, sessionStart: startDate) },
            baroSamples.last?.timestamp
        ]
        return evidence.compactMap { $0 }.max() ?? startDate
    }
}
