import Foundation

/// The fields each archived-workout record carries, named in the
/// descriptions of every lookup that returns it, so a question about any
/// field finds the lookups that answer it. `RecordFieldDiscoverabilityTests`
/// fails when a record returns a field its lookups don't name.
enum WorkoutRecordFields {
    /// The same-day fields every single-workout record carries.
    static let sameDayNames: [String] = ["workouts_that_day", "position_that_day", "other_workout_ids_that_day"]

    /// What a workout.list item carries: the full workout record without its
    /// splits and laps, so a month of workouts fits one call.
    static let listLeavesOut: Set<String> = ["splits", "laps"]

    /// `WorkoutNamespace.deepDiveRecord` plus the same-day fields.
    static let deepDiveNames: [String] = [
        "session_id", "date", "sport", "trimp", "hr_tss", "decoupling_percent", "efficiency_factor", "intensity_factor",
        "variability_index", "recognized_route", "partial_data_reason", "elevation_loss_meters",
        "seconds_in_easy_α1", "seconds_in_threshold_α1", "seconds_in_hard_α1", "first_at1_crossing_offset_sec",
        "first_at1_crossing_hr", "dominant_α1_band", "dominant_hr_zone", "estimated_total_calories",
        "calorie_rate_per_hour", "vam_meters_per_hour", "grade_adjusted_pace_sec_per_km", "relative_effort_label"
    ] + sameDayNames

    /// The timeline envelope; each bucket's fields are named in its description.
    static let timelineNames: [String] = ["id", "date", "sport", "duration_sec", "bucket_sec", "bucket_count", "buckets"] + sameDayNames

    /// The `workout.recent` period summary.
    static let periodSummaryNames: [String] = [
        "period", "sport", "workout_count", "total_distance_m", "total_trimp", "total_hr_tss",
        "power_capable_workout_count", "total_power_tss", "avg_normalized_power_w", "max_intensity_factor",
        "max_peak_power_w", "sport_breakdown", "hardest_workout"
    ]
}
