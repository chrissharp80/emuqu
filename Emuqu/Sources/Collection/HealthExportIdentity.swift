import Foundation

/// The `HKMetadataKeyExternalUUID` scheme the app stamps on everything it
/// writes to Apple Health, and the predicates that decide which of those
/// samples a re-export deletes first.
///
/// Lifted into one place. The scheme was spelled out as string
/// interpolation at seven call sites across three files, and the relationship
/// between its two shapes existed only as a comment:
///
///     // Exact match: "-hr" must NOT swallow the "-hr-<n>" minute series.
///
/// That comment is the whole safety argument for a delete against the user's
/// permanent Health record. A summary sample is matched exactly; a series is
/// matched by prefix; and no metric's predicate may match another metric's
/// samples. Stated here, those are properties a test can hold the app to
/// instead of a warning the next reader has to notice.
enum HealthExportIdentity {
    /// Metrics the app writes. Adding a case is what makes the collision test
    /// cover it — the test enumerates this list rather than a hand-written one.
    enum Metric: String, CaseIterable {
        case heartRate = "hr"
        case restingHeartRate = "rhr"
        case sdnn
        case rmssd
        case sleep
    }

    /// The identity of a session's single summary sample for a metric.
    static func summary(sessionId: UUID, metric: Metric) -> String {
        "\(sessionId.uuidString)-\(metric.rawValue)"
    }

    /// The identity of one member of a session's series for a metric.
    static func seriesMember(sessionId: UUID, metric: Metric, index: Int) -> String {
        seriesMember(sessionId: sessionId, metric: metric, suffix: String(index))
    }

    /// Series members are usually numbered, but sleep also writes a named
    /// `-inbed` member alongside its numbered stage intervals. Both are
    /// members of the same series and are replaced together.
    static func seriesMember(sessionId: UUID, metric: Metric, suffix: String) -> String {
        "\(seriesPrefix(sessionId: sessionId, metric: metric))\(suffix)"
    }

    /// The prefix every member of that series carries. The trailing separator
    /// is what keeps `…-hr-3` out of the summary's exact match and keeps the
    /// summary `…-hr` out of this prefix.
    static func seriesPrefix(sessionId: UUID, metric: Metric) -> String {
        "\(sessionId.uuidString)-\(metric.rawValue)-"
    }

    /// Delete predicate for a summary sample: exact, so it cannot reach the
    /// series that shares its metric name.
    static func isSummary(_ externalUUID: String, sessionId: UUID, metric: Metric) -> Bool {
        externalUUID == summary(sessionId: sessionId, metric: metric)
    }

    /// Delete predicate for a series: prefix, so it reaches every member and
    /// nothing else.
    static func isSeriesMember(_ externalUUID: String, sessionId: UUID, metric: Metric) -> Bool {
        externalUUID.hasPrefix(seriesPrefix(sessionId: sessionId, metric: metric))
    }

    /// Delete predicate for everything a session wrote for one metric —
    /// summary and series together. Sleep uses this: its export is a set of
    /// stage samples plus an overall in-bed sample, replaced as a unit.
    static func belongsToSession(_ externalUUID: String, sessionId: UUID, metric: Metric) -> Bool {
        isSummary(externalUUID, sessionId: sessionId, metric: metric)
            || isSeriesMember(externalUUID, sessionId: sessionId, metric: metric)
    }
}

extension RRPoint {
    /// Where this beat sits on the session's clock for anything written out
    /// with a real date (Apple Health samples, HR-estimated sleep bounds): the
    /// wall clock when the stream recorded one, else `t_ms`. `t_ms` is a
    /// running sum of beat intervals, so after a dropped stretch of a streamed
    /// night it falls behind real time by the lost minutes; the wall clock
    /// does not. Internal-recording beats have no wall clock and use `t_ms`,
    /// which is continuous there.
    var exportTimeMs: Int64 { wallClockMs ?? t_ms }
}
