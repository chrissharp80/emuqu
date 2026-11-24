import Foundation
import HealthKit
import os

/// The `HKMetadataKeyExternalUUID` scheme the app stamps on everything it
/// writes to Apple Health, and the predicates that decide which of those
/// samples a re-export deletes first.
///
/// A summary sample is matched exactly ("-hr" must NOT swallow the "-hr-<n>"
/// minute series); a series is matched by prefix; and no metric's predicate
/// may match another metric's samples. That is the whole safety argument for
/// a delete against the user's permanent Health record, so the scheme lives
/// in one place where a test can hold the app to it.
///
/// Health data written by earlier builds may carry the single summary SDNN
/// under the bare session UUID. It is written as
/// `summary(sessionId:metric: .sdnn)`, and the HRV cleanup
/// (`HealthWriteAndObserve.isOurHRVExport`) also removes the bare form.
enum HealthExportIdentity {
    /// Metrics the app writes. Adding a case is what makes the collision test
    /// cover it — the test enumerates this list rather than a hand-written one.
    enum Metric: String, CaseIterable {
        case heartRate = "hr"
        case restingHeartRate = "rhr"
        case sdnn
        case rmssd
        case sleep
        /// A saved `HKWorkout` (the summary identity) and the samples and
        /// route saved with it (series members named by kind and index).
        case workout
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

    // MARK: - HealthKit's own de-duplication

    /// The metadata every sample and workout the app writes carries: its
    /// identity as `HKMetadataKeyExternalUUID`, the same identity as
    /// `HKMetadataKeySyncIdentifier`, `version` as `HKMetadataKeySyncVersion`,
    /// and `extra`.
    ///
    /// The identity is derived from the session id, so the same session
    /// exported again, on this device or on another one on the same Health
    /// account, carries the same sync identifier. HealthKit then replaces the
    /// earlier object with the new one when the new version is greater,
    /// instead of keeping both. HealthKit requires the version whenever the
    /// identifier is given.
    static func metadata(_ externalUUID: String, version: Int, _ extra: [String: Any] = [:]) -> [String: Any] {
        var metadata = extra
        metadata["Source"] = "Emuqu"
        metadata[HKMetadataKeyExternalUUID] = externalUUID
        metadata[HKMetadataKeySyncIdentifier] = externalUUID
        metadata[HKMetadataKeySyncVersion] = version
        return metadata
    }

    /// The sync identifier an object the app wrote carries; nil for one
    /// written before the app gave one.
    static func syncIdentifier(of object: HKObject) -> String? {
        object.metadata?[HKMetadataKeySyncIdentifier] as? String
    }

    /// The sync version an object the app wrote carries; nil for one
    /// written before the app gave one.
    static func syncVersion(of object: HKObject) -> Int? {
        object.metadata?[HKMetadataKeySyncVersion] as? Int
    }

    /// The last version `nextSyncVersion(now:)` handed out.
    private static let lastSyncVersion = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// The sync version for an export starting `now`: milliseconds since
    /// 1970, and always above the last one handed out, so a later export of a
    /// session replaces an earlier one even within the same millisecond.
    static func nextSyncVersion(now: Date = Date()) -> Int {
        let millis = Int((now.timeIntervalSince1970 * 1000).rounded(.down))
        return lastSyncVersion.withLock { last in
            last = max(millis, last + 1)
            return last
        }
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
