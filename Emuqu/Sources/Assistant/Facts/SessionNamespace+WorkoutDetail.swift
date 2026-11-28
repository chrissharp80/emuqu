import CoreLocation
import Foundation

// The workout record beyond identity, load, α1 and HRR: average pace,
// intensity, the rest of the analysis snapshot, weather, splits and laps,
// rowing, where it started, tags and notes, and the workout's own HRV. Each
// field is present only when the workout stored it, so a list of workouts
// stays small.
extension SessionNamespace {
    /// Splits and laps a record carries; `split_count` / `lap_count` give the
    /// total, so a longer workout's later splits are known to exist.
    static let maxRecordSplits = 25
    static let maxRecordLaps = 20

    /// Every top-level field of the workout record (`fullRecord`), for the
    /// descriptions of every lookup that returns it.
    static let workoutRecordFields: [String] = [
        "id", "date", "sport", "duration_sec", "elapsed_sec", "distance_m", "avg_pace_sec_per_km", "elevation_gain_m", "elevation_loss_m",
        "mean_hr_bpm", "max_hr_bpm", "recognized_route", "workout_feeling", "workout_feeling_note", "tags", "notes", "partial_data_reason",
        "load", "load_source", "trimp", "hr_tss", "power_tss", "intensity_factor", "variability_index", "decoupling_percent", "efficiency_factor",
        "average_power_w", "normalized_power_w", "peak_power_w", "power_hr_ratio",
        "alpha1_mean", "alpha1_max", "alpha1_min", "seconds_below_at1", "seconds_between_at1_at2", "seconds_above_at2",
        "first_at1_crossing_offset_sec", "first_at1_crossing_hr", "dominant_alpha1_band", "hr_zone_seconds", "dominant_hr_zone", "dominant_hr_zone_percent",
        "relative_effort_label", "fastest_split_index", "fastest_split_pace_sec_per_km", "slowest_split_index", "slowest_split_pace_sec_per_km",
        "moving_time_sec", "moving_percent", "vam_m_per_hr", "calorie_rate_per_hr", "estimated_total_calories", "stride_length_m",
        "grade_adjusted_pace_sec_per_km", "how_you_did_narrative", "hero_narrative",
        "weather_temperature_c", "weather_feels_like_c", "weather_humidity_percent", "weather_wind_kmh", "weather_conditions",
        "split_count", "splits", "lap_count", "laps", "stroke_count", "avg_split_sec_per_500m", "drag_factor",
        "start_latitude", "start_longitude", "hrv_rmssd_ms", "hrv_sdnn_ms", "hrv_dfa_alpha1", "hrv_artifact_percent",
        "hrr_1min_drop_bpm", "hrr_1min_source", "hrr_2min_drop_bpm"
    ]

    /// What the workout record holds, in words the model can search: the
    /// field list plus what the less obvious ones mean.
    static var workoutRecordFieldsSentence: String {
        RecordFields.sentence(workoutRecordFields)
            + " avg_pace_sec_per_km is active time over distance, as the workout card shows it. hr_zone_seconds lists seconds in heart-rate zones 1 to 5. splits (per kilometre or mile: index, distance_m, duration_sec,"
            + " pace_sec_per_km, mean_hr_bpm, elevation_gain_m, alpha1_mean; the first \(maxRecordSplits), split_count is the total) and laps (index, start_offset_sec, end_offset_sec, distance_m, mean_hr_bpm, max_hr_bpm,"
            + " pace_sec_per_km) answer 'what were my splits', 'my slowest kilometre'. weather_* is the weather at the workout. start_latitude / start_longitude is where it started; never read the numbers out."
            + " hrv_* is the HRV measured during the workout. Every pace_sec_per_km comes with a pace_display in the user's units. Fields a workout did not record are left out."
    }

    static func workoutDetailFields(_ s: HRVSession, meta: WorkoutMetadata?) -> [String: FactValue] {
        let parts = [
            effortFields(s, meta: meta), snapshotDetailFields(meta?.analysisSnapshot), weatherFields(meta?.weatherSnapshot),
            segmentFields(meta), rowingFields(meta), startFields(s, meta: meta), annotationFields(s), workoutHRVFields(s.analysisResult)
        ]
        return parts.reduce(into: [:]) { record, part in record.merge(part) { current, _ in current } }
    }

    private static func effortFields(_ s: HRVSession, meta: WorkoutMetadata?) -> [String: FactValue] {
        present([
            ("avg_pace_sec_per_km", averagePaceSecPerKm(s, meta: meta).map { .double(roundedForRecord($0, places: 1)) }),
            ("intensity_factor", meta?.intensityFactor.map(FactValue.double)),
            ("variability_index", meta?.variabilityIndex.map(FactValue.double)),
            ("partial_data_reason", meta?.partialDataReason.map { .string($0.rawValue) })
        ])
    }

    /// Active (un-paused) time over distance, with the workout card's limits:
    /// over 100 m and over 10 s, so a workout without distance has no pace.
    static func averagePaceSecPerKm(_ s: HRVSession, meta: WorkoutMetadata?) -> Double? {
        guard let distance = meta?.distanceMeters, distance > 100,
              let active = WorkoutActiveTime.seconds(metadata: meta, wallClock: s.duration), active > 10 else { return nil }
        return active / (distance / 1_000)
    }

    private static func snapshotDetailFields(_ snap: WorkoutAnalysisSnapshot?) -> [String: FactValue] {
        guard let snap else { return [:] }
        return present([
            ("relative_effort_label", snap.relativeEffortLabel.map(FactValue.string)),
            ("hr_zone_seconds", snap.hrZoneSeconds.map { .list($0.map(FactValue.integer)) }),
            ("slowest_split_index", snap.slowestSplitIndex.map(FactValue.integer)),
            ("slowest_split_pace_sec_per_km", snap.slowestSplitPaceSecPerKm.map(FactValue.double)),
            ("moving_time_sec", snap.movingTimeSec.map(FactValue.integer)),
            ("moving_percent", snap.movingTimePercent.map(FactValue.integer)),
            ("power_hr_ratio", snap.powerHRRatio.map(FactValue.double)),
            ("hero_narrative", nonEmpty(snap.heroNarrative).map(FactValue.string))
        ])
    }

    private static func weatherFields(_ weather: WorkoutWeatherSnapshot?) -> [String: FactValue] {
        guard let weather else { return [:] }
        return present([
            ("weather_temperature_c", .double(weather.temperatureC)),
            ("weather_feels_like_c", weather.apparentTemperatureC.map(FactValue.double)),
            ("weather_humidity_percent", .double(weather.relativeHumidityPercent)),
            ("weather_wind_kmh", weather.windKMH.map(FactValue.double)),
            ("weather_conditions", nonEmpty(weather.conditions).map(FactValue.string))
        ])
    }

    private static func rowingFields(_ meta: WorkoutMetadata?) -> [String: FactValue] {
        present([
            ("stroke_count", meta?.strokeCount.map(FactValue.integer)),
            ("avg_split_sec_per_500m", meta?.averageSplitSecPer500m.map(FactValue.double)),
            ("drag_factor", meta?.dragFactor.map(FactValue.integer))
        ])
    }

    private static func annotationFields(_ s: HRVSession) -> [String: FactValue] {
        present([
            ("tags", s.tags.isEmpty ? nil : .list(s.tags.map { .string($0.name) })),
            ("notes", nonEmpty(s.notes).map(FactValue.string))
        ])
    }

    /// The HRV analysis of the workout's own beats, when it was analysed.
    private static func workoutHRVFields(_ result: HRVAnalysisResult?) -> [String: FactValue] {
        guard let result else { return [:] }
        return present([
            ("hrv_rmssd_ms", .double(result.timeDomain.rmssd)),
            ("hrv_sdnn_ms", .double(result.timeDomain.sdnn)),
            ("hrv_dfa_alpha1", result.nonlinear.dfaAlpha1.map(FactValue.double)),
            ("hrv_artifact_percent", .double(result.artifactPercentage))
        ])
    }

    /// The first GPS fix. The cloud consent sheet lists the start points of
    /// GPS workouts among what the assistant reads; rounded to about 10 m.
    private static func startFields(_ s: HRVSession, meta: WorkoutMetadata?) -> [String: FactValue] {
        guard let polyline = meta?.gpsPolyline,
              let first = GPXExporter.decode(polyline: polyline, startDate: s.startDate, duration: s.duration).first else { return [:] }
        return [
            "start_latitude": .double(roundedForRecord(first.coordinate.latitude, places: 4)),
            "start_longitude": .double(roundedForRecord(first.coordinate.longitude, places: 4))
        ]
    }

    // MARK: Splits and laps

    private static func segmentFields(_ meta: WorkoutMetadata?) -> [String: FactValue] {
        var out: [String: FactValue] = [:]
        if let splits = meta?.splits, !splits.isEmpty {
            out["split_count"] = .integer(splits.count)
            out["splits"] = .list(splits.sorted { $0.index < $1.index }.prefix(maxRecordSplits).map(splitRecord))
        }
        if let laps = meta?.laps, !laps.isEmpty {
            out["lap_count"] = .integer(laps.count)
            out["laps"] = .list(laps.sorted { $0.index < $1.index }.prefix(maxRecordLaps).map(lapRecord))
        }
        return out
    }

    private static func splitRecord(_ split: Split) -> FactValue {
        .record(present([
            ("index", .integer(split.index)),
            ("distance_m", .double(roundedForRecord(split.distanceMeters, places: 1))),
            ("duration_sec", .integer(Int(split.durationSeconds.rounded()))),
            ("pace_sec_per_km", split.averagePaceSecPerKm.map { .double(roundedForRecord($0, places: 1)) }),
            ("mean_hr_bpm", split.averageHR.map { .integer(Int($0.rounded())) }),
            ("elevation_gain_m", split.elevationGainMeters.map { .double(roundedForRecord($0, places: 1)) }),
            ("alpha1_mean", split.averageAlpha1.map { .double(roundedForRecord($0, places: 2)) })
        ]))
    }

    private static func lapRecord(_ lap: Lap) -> FactValue {
        .record(present([
            ("index", .integer(lap.index)),
            ("start_offset_sec", .integer(Int(lap.startOffsetSec.rounded()))),
            ("end_offset_sec", .integer(Int(lap.endOffsetSec.rounded()))),
            ("distance_m", lap.distanceMeters.map { .double(roundedForRecord($0, places: 1)) }),
            ("mean_hr_bpm", lap.averageHR.map { .integer(Int($0.rounded())) }),
            ("max_hr_bpm", lap.maxHR.map { .integer(Int($0.rounded())) }),
            ("pace_sec_per_km", lap.averagePaceSecPerKm.map { .double(roundedForRecord($0, places: 1)) })
        ]))
    }

    private static func roundedForRecord(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }
}
