import Foundation

/// One Verity Sense recording as the SDK lists it, however many files it
/// spans on the sensor.
///
/// A long offline recording is split into sub-files (`PPI0.REC`, `PPI1.REC`,
/// …). The SDK's fast listing (from `PMDFiles.txt`) returns one entry per
/// recording, but its fallback listing — used when a sensor has no such file —
/// returns one entry per sub-file. Reading or removing an entry already covers
/// every sub-file of its recording, so each sub-file entry downloads the whole
/// recording again (the night arrives N times over, its clock restarting at
/// zero each time) and the second removal fails because the first deleted the
/// directory. Grouping by the path with the sub-file index removed is the same
/// key the SDK's fast listing uses.
enum StrapOfflineRecordingEntries {
    /// The recording a sub-file belongs to.
    static func recordingKey(forPath path: String) -> String {
        path.replacingOccurrences(of: "\\d+\\.REC$", with: ".REC", options: .regularExpression)
    }

    /// One entry per recording, in listing order.
    static func onePerRecording<Entry>(_ entries: [Entry], path: (Entry) -> String) -> [Entry] {
        var seen = Set<String>()
        return entries.filter { seen.insert(recordingKey(forPath: path($0))).inserted }
    }
}
