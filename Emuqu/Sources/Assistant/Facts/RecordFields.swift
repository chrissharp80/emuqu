import Foundation

/// The fields each dated overnight record carries. The latest, by-date and
/// per-period lookups of one record kind all name the same list in their
/// descriptions, so a question about any field ("my lowest heart rate this
/// week") finds every lookup that answers it, the per-period list included.
/// `RecordFieldDiscoverabilityTests` fails when a record returns a field its
/// lookups don't name.
enum RecordFields {
    static let hrv: [String] = [
        "date", "session_type", "rmssd_ms", "sdnn_ms", "pnn50_percent", "sdsd_ms", "sd_hr_bpm",
        "window_mean_hr_bpm", "window_min_hr_bpm", "window_max_hr_bpm", "artifact_percent",
        "overnight_nadir_hr_bpm", "overnight_nadir_at_iso", "overnight_min_hr_bpm", "overnight_max_hr_bpm", "overnight_mean_hr_bpm",
        "sd1_ms", "sd2_ms", "sd1_sd2_ratio", "triangular_index", "dfa_alpha1", "dfa_alpha2", "dfa_alpha1_r2",
        "sample_entropy", "approximate_entropy", "lf_power_ms2", "hf_power_ms2", "total_power_ms2", "lf_hf_ratio", "vlf_power_ms2",
        "stress_index", "readiness_score", "pns_index", "sns_index", "respiration_rate_per_min",
        "nocturnal_hr_dip_percent", "daytime_resting_hr_bpm", "nocturnal_median_hr_bpm",
        "window_start_iso", "window_end_iso", "window_selection_reason", "window_relative_position", "window_hr_stability",
        "window_classification", "is_consolidated", "is_organized_recovery", "peak_rmssd_ms", "peak_sdnn_ms", "peak_total_power_ms2"
    ]

    /// The fields only a single-night lookup returns: they need the night's
    /// RR series, which the per-period lists do not load.
    static let hrvSingleNightOnly: Set<String> = ["overnight_nadir_at_iso", "window_start_iso", "window_end_iso"]

    static let sleep: [String] = [
        "date", "session_type", "total_sleep_minutes", "in_bed_minutes", "awake_minutes", "efficiency_percent",
        "deep_minutes", "rem_minutes", "latency_minutes", "fragmentation_index", "awakening_count", "sleep_cycles",
        "architecture_score", "deep_front_loaded", "rem_back_loaded", "enhanced_sleep_score",
        "deep_in_expected_range", "rem_in_expected_range", "data_source",
        "sleep_start_iso", "sleep_end_iso", "in_bed_start_iso", "core_minutes", "nap_minutes", "segment_count",
        "avg_sleep_rmssd_ms", "min_sleep_hr_bpm", "avg_sleep_hr_bpm", "restorative_minutes", "restorative_ratio"
    ]

    static let recovery: [String] = [
        "date", "session_type", "score", "scale", "training_readiness", "data_quality", "reliable_for_trends",
        "morning_feeling", "morning_feeling_tags", "perceived_readiness", "notes", "score_tier", "factor_scores"
    ]

    static let recoveryBreakdown: [String] = [
        "date", "session_type", "score", "composite_score", "tier", "factors", "penalties", "spo2_penalty_applied",
        "scoring_version", "gap_from_factors"
    ]

    static let hrvTimeline: [String] = [
        "date", "session_type", "recording_start_iso", "recording_end_iso", "bucket_minutes", "bucket_count", "buckets"
    ]

    static let vitals: [String] = [
        "date", "session_type", "respiratory_rate_bpm", "respiratory_rate_baseline_bpm", "respiratory_deviation_bpm",
        "oxygen_saturation_percent", "oxygen_saturation_min_percent", "wrist_temperature_deviation_c",
        "resting_heart_rate_bpm", "status", "data_source"
    ]

    /// "Fields: a, b, c." for an entry description, leaving out the fields
    /// that lookup never returns.
    static func sentence(_ fields: [String], except omitted: Set<String> = []) -> String {
        "Fields: " + fields.filter { !omitted.contains($0) }.joined(separator: ", ") + "."
    }
}
