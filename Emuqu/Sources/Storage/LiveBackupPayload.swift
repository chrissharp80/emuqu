import Foundation

/// The JSON a live backup's sealed asset holds: the night's beats, with the
/// recording's start on the first one.
///
/// A beat's `t_ms` counts from the recording's start, so the beats alone
/// cannot say when the night happened. The record's plain `captureDate` is
/// when the first upload reached iCloud, which can be hours after the start
/// (no network at bedtime, sync switched on mid-night); dated by it, a
/// restored night moved by that delay. The start travels sealed, inside the
/// payload, not as another plain field.
///
/// The payload is still a JSON array of beats, and the start is one more key
/// on the first beat's object, which `RRPoint`'s decoder ignores. A build
/// that reads only `[RRPoint]` opens a new payload, and an older payload
/// (no start) opens here with `recordingStart` nil.
enum LiveBackupPayload {
    /// `points` as the payload's JSON, the first beat carrying `recordingStart`.
    static func encode(_ points: [RRPoint], recordingStart: Date) throws -> Data {
        let startMs = milliseconds(since1970: recordingStart)
        let beats = points.enumerated().map { index, point in
            Beat(point: point, recordingStartMs: index == 0 ? startMs : nil)
        }
        return try JSONEncoder().encode(beats)
    }

    /// The beats and, when the payload carries it, the recording's start.
    static func decode(_ json: Data) throws -> (points: [RRPoint], recordingStart: Date?) {
        let beats = try JSONDecoder().decode([Beat].self, from: json)
        let start = beats.first?.recordingStartMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        return (beats.map(\.point), start)
    }

    /// Whole milliseconds since 1970; nil for a date that has none.
    private static func milliseconds(since1970 date: Date) -> Int64? {
        let ms = (date.timeIntervalSince1970 * 1000).rounded()
        guard ms.isFinite, abs(ms) < Double(Int64.max) else { return nil }
        return Int64(ms)
    }

    /// One beat as the payload writes it: `RRPoint`'s own keys, plus the
    /// start on the first.
    private struct Beat: Codable {
        let point: RRPoint
        let recordingStartMs: Int64?

        private enum StartKey: String, CodingKey {
            case recordingStartMs
        }

        init(point: RRPoint, recordingStartMs: Int64?) {
            self.point = point
            self.recordingStartMs = recordingStartMs
        }

        init(from decoder: Decoder) throws {
            point = try RRPoint(from: decoder)
            recordingStartMs = try decoder.container(keyedBy: StartKey.self).decodeIfPresent(Int64.self, forKey: .recordingStartMs)
        }

        func encode(to encoder: Encoder) throws {
            try point.encode(to: encoder)
            var container = encoder.container(keyedBy: StartKey.self)
            try container.encodeIfPresent(recordingStartMs, forKey: .recordingStartMs)
        }
    }
}
