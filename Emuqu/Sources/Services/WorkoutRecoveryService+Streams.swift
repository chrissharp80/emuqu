import CoreLocation
import Foundation

// The recorded streams a rebuild cuts to its end and recomputes every
// derived field from, and the figures it recomputes from the kept samples.

extension WorkoutRecoveryService {
    /// What a rebuild works from: the crash backup when there is one,
    /// otherwise the archived copy's own streams (a saved workout's backups
    /// are gone): its track decoded from the stored polyline at the stored
    /// fix times, its segment starts, its per-second samples and the rows
    /// marked as heart rate from Apple Health. A trim of a saved workout then
    /// recomputes distance, splits, route and elevation from what it keeps,
    /// never keeping the untrimmed figures.
    struct SourceStreams {
        let track: [CLLocation]
        let trackSegmentStarts: [Int]
        let samples: [WorkoutSample]
        let healthKitHROffsets: [Int]
        let baroSamples: [WorkoutTrackBackup.PersistedBaro]
    }

    static func sourceStreams(_ prepared: Prepared, overrideTrack: SegmentedTrack?) -> SourceStreams {
        if let record = prepared.workoutRecord {
            return SourceStreams(
                track: overrideTrack?.fixes ?? record.track, trackSegmentStarts: overrideTrack?.starts ?? [],
                samples: record.samples, healthKitHROffsets: record.healthKitHROffsets, baroSamples: record.barometricSamples
            )
        }
        let metadata = prepared.existingSession?.workoutMetadata
        return SourceStreams(
            track: overrideTrack?.fixes ?? storedTrack(prepared.existingSession),
            trackSegmentStarts: overrideTrack?.starts ?? (metadata?.gpsSegmentStarts ?? []),
            samples: metadata?.samples ?? [], healthKitHROffsets: metadata?.healthKitHROffsets ?? [], baroSamples: []
        )
    }

    /// The archived copy's GPS track: the stored polyline, each fix at the
    /// time it was taken when those were stored (`GPXExporter.timedAsRecorded`),
    /// spread across the workout otherwise. Empty without a polyline.
    static func storedTrack(_ session: HRVSession?) -> [CLLocation] {
        guard let session, let polyline = session.workoutMetadata?.gpsPolyline else { return [] }
        let decoded = GPXExporter.decode(polyline: polyline, startDate: session.startDate, duration: session.duration)
        return GPXExporter.timedAsRecorded(decoded, metadata: session.workoutMetadata)
    }

    /// The figures the kept per-second samples give, recomputed whenever the
    /// samples are: the distance a sensor counted indoors (foot pod,
    /// pedometer, the PM5's odometer: each row carries the distance shown
    /// then), and the power aggregates. Run after the samples are final.
    static func applySampleDerivedFields(to metadata: inout WorkoutMetadata, activeSeconds: TimeInterval, ftp: Int?) {
        let samples = metadata.samples ?? []
        if let counted = samples.last(where: { $0.distanceMeters != nil })?.distanceMeters, counted > (metadata.distanceMeters ?? 0) {
            metadata.distanceMeters = counted
        }
        applySamplePower(to: &metadata, samples: samples, activeSeconds: activeSeconds, ftp: ftp)
        if metadata.sport == .row, let distance = metadata.distanceMeters {
            metadata.averageSplitSecPer500m = WorkoutFinalizer.averageSplitSecPer500m(movingSeconds: Int(activeSeconds), distanceMeters: distance)
        }
    }

    /// Average, peak and normalized power, variability, and the FTP-anchored
    /// intensity and power-TSS, over the kept samples, as the live finalize
    /// computes them. Left as they are when no kept sample has power.
    private static func applySamplePower(to metadata: inout WorkoutMetadata, samples: [WorkoutSample], activeSeconds: TimeInterval, ftp: Int?) {
        let tally = WorkoutRecorder.powerTally(of: samples)
        guard let average = tally.average else { return }
        metadata.averagePowerWatts = average
        metadata.peakPowerWatts = tally.peak
        let np = WorkoutSessionLifecycle.computeNormalizedPower(samples: samples)
        metadata.normalizedPowerWatts = np
        metadata.variabilityIndex = np.flatMap { $0 > 0 && average > 0 ? $0 / average : nil }
        guard let ftp = ftp ?? metadata.ftpAtTimeOfSession, ftp > 0, let np else { return }
        let intensity = np / Double(ftp)
        metadata.intensityFactor = intensity
        metadata.powerTSS = intensity * intensity * activeSeconds / 3600.0 * 100.0
        metadata.ftpAtTimeOfSession = ftp
    }
}
