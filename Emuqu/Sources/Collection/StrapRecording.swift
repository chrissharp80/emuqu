import Foundation

/// A recording taken off the strap's own memory, with the time it began.
///
/// The start is what files the beats correctly: an H10 recording is a flat
/// list of intervals counted from the moment the strap was armed, and that
/// moment is often not the session's start (arming waits for the link) and
/// is sometimes not even the same night (the strap keeps a recording until
/// the next one clears it). Every flow that downloads a recording receives
/// its start with it, so none has to guess one.
struct StrapRecording: Sendable, Equatable {
    let points: [RRPoint]
    /// When the strap began this recording: the H10's id is this app's start
    /// stamp, and a Verity Sense entry carries its own start. Nil for a
    /// recording this app did not file.
    let startedAt: Date?

    /// When the recording ended: its start plus the end of its last beat, on
    /// the real clock (`wallClockMs`) where the beats carry one — an optical
    /// recording's rejected intervals take time but leave no beat — else on
    /// the beat timeline (an H10's, which has no gaps).
    var endedAt: Date? {
        startedAt.map { $0.addingTimeInterval(TimeInterval(Self.endOffsetMs(of: points)) / 1000) }
    }

    private static func endOffsetMs(of points: [RRPoint]) -> Int64 {
        guard let last = points.last else { return 0 }
        return (last.wallClockMs ?? last.t_ms) + Int64(last.rr_ms)
    }

    /// The beats on the clock of a session that started at `sessionStart`.
    ///
    /// A recording armed after the session began counts from its own start,
    /// so its beats move later by the gap; left unshifted they sit that many
    /// seconds early and a merge with the streamed beats keeps both copies of
    /// every beat. `fallbackStart` stands in when the recording carries no
    /// start of its own. A recording that began before the session is left
    /// as it is.
    func points(onClockOf sessionStart: Date, fallbackStart: Date? = nil) -> [RRPoint] {
        guard let start = startedAt ?? fallbackStart else { return points }
        let offsetMs = MillisecondOffset.between(start, and: sessionStart, fallback: 0)
        guard offsetMs > 0 else { return points }
        return points.map { $0.shifted(by: offsetMs) }
    }
}

/// The strap recordings this app has downloaded, and those whose beats it has
/// written to disk, by start time.
///
/// The strap keeps its copy after a download, by design, so "the strap holds
/// a recording" alone cannot tell the Record screen whether anything is
/// missing; without this record it offered the same, already-saved night on
/// every connect. Every download goes through `fetchRecording`, which notes
/// it here. A download is only in memory until the flow that took it writes
/// the beats to a backup or the archive and notes that (`markSaved`): only a
/// saved recording may be cleared from the strap, so an app that dies, or a
/// write that fails, between the two leaves the strap's copy recoverable.
struct StrapDownloadLedger {
    private let defaults: UserDefaults
    private static let startsKey = "strapDownloadedRecordingStarts"
    private static let savedKey = "strapSavedRecordingStarts"
    private static let sinceKey = "strapDownloadLedgerSince"
    /// Enough for weeks of nights and workouts; only the strap's current
    /// recording is ever asked about.
    private static let capacity = 60

    /// The first ledger opened on this install starts the record.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.sinceKey) == nil { defaults.set(Date(), forKey: Self.sinceKey) }
    }

    /// When the record began. Recordings older than this were downloaded or
    /// not without a note of it.
    var since: Date {
        defaults.object(forKey: Self.sinceKey) as? Date ?? .distantPast
    }

    func markDownloaded(recordingStartedAt start: Date) {
        append(Self.key(for: start), to: Self.startsKey)
    }

    func wasDownloaded(recordingStartedAt start: Date) -> Bool {
        starts(under: Self.startsKey).contains(Self.key(for: start))
    }

    /// The recording's beats are on disk, in a backup or an archived session.
    func markSaved(recordingStartedAt start: Date) {
        append(Self.key(for: start), to: Self.savedKey)
    }

    func wasSaved(recordingStartedAt start: Date) -> Bool {
        starts(under: Self.savedKey).contains(Self.key(for: start))
    }

    /// Marks saved every downloaded recording that began at or after `since`:
    /// a session that only has the downloaded beats, not the recording, saves
    /// the one it downloaded for itself (`fetchRecording(recordedSince:)`
    /// takes only a recording that began at or after the session's start).
    func markDownloadsSaved(recordedSince since: Date) {
        let floor = Self.key(for: since)
        for key in starts(under: Self.startsKey) where key >= floor {
            append(key, to: Self.savedKey)
        }
    }

    func predatesRecord(_ start: Date) -> Bool {
        start < since
    }

    private func starts(under key: String) -> [Double] {
        defaults.array(forKey: key) as? [Double] ?? []
    }

    private func append(_ start: Double, to key: String) {
        var starts = starts(under: key)
        guard !starts.contains(start) else { return }
        starts.append(start)
        defaults.set(Array(starts.suffix(Self.capacity)), forKey: key)
    }

    /// Whole seconds: the H10's id holds no more, and the same recording read
    /// twice must give the same key.
    private static func key(for start: Date) -> Double {
        start.timeIntervalSince1970.rounded(.down)
    }
}
