import CryptoKit
import Foundation

extension SessionArchiveEntry {
    /// Single factory for building a lightweight index entry from a full
    /// session.
    ///
    /// Hand-rolled 16+-argument initializer calls at each site drift into
    /// INCONSISTENT field coverage: if `_archive` populates every field while
    /// `archiveBatch`, `repairArchive`, and `reconcileOrphanFiles` drop
    /// `meanSDNN` and/or the sleep-stage + nocturnal-dip mirror fields,
    /// sessions that enter the index via batch import, repair, or orphan
    /// adoption are invisible to 30-day sleep-stage trends and AI context
    /// queries (which read the lightweight index) until something re-archives
    /// them through `_archive`.
    ///
    /// Routing every construction site through this factory prevents that
    /// index drift. Field population matches `_archive`'s construction
    /// exactly, including `SessionArchive.deriveSleepIndexFields`.
    ///
    /// - Parameters:
    ///   - overridingSessionId: `repairArchive` keys rebuilt entries by the
    ///     UUID parsed from the FILENAME (the archive's naming contract),
    ///     not the id stored inside the payload. Pass it to preserve that
    ///     behavior exactly; every other site uses `session.id`.
    ///   - recoveryScoreFallback: `repairArchive` falls back to the raw
    ///     readiness score for legacy sessions that predate the composite
    ///     recovery score. Used only when `session.recoveryScore` is nil.
    static func make(
        from session: HRVSession,
        hash: String,
        filePath: String,
        overridingSessionId: UUID? = nil,
        recoveryScoreFallback: Double? = nil
    ) -> SessionArchiveEntry {
        let sleepFields = SessionArchive.deriveSleepIndexFields(from: session)
        // Mirror sleep stages + nocturnal dip into the lightweight index so
        // 30-day trend / AI queries don't need to load each session file.
        let mirror = SleepMirror(session: session)
        return SessionArchiveEntry(
            sessionId: overridingSessionId ?? session.id,
            date: session.startDate, endDate: session.endDate,
            fileHash: hash, filePath: filePath,
            recoveryScore: session.recoveryScore ?? recoveryScoreFallback,
            meanRMSSD: session.rmssd, meanHR: session.meanHR,
            stressIndex: session.stressIndex, meanSDNN: session.importedMetrics?.sdnn,
            tags: session.tags, notes: session.notes,
            sessionType: session.sessionType, linkedSessionIds: session.linkedSessionIds,
            sleepEnd: sleepFields.sleepEnd, sleepSegmentCount: sleepFields.sleepSegmentCount,
            deepSleepMinutes: mirror.deep, remSleepMinutes: mirror.rem,
            coreSleepMinutes: mirror.core, awakeMinutes: mirror.awake,
            nocturnalDipPercent: mirror.dip, hrvDataQuality: session.hrvDataQuality,
            modifiedAt: session.modifiedAt
        )
    }

    /// Sleep-stage + nocturnal-dip mirror fields derived from a full session.
    /// Single source of truth so `make(from:)` and `mirroringSleepFields(from:)`
    /// can never drift. Dip is computed by HRVAnalysisPipeline and stored on
    /// ANSMetrics.
    struct SleepMirror {
        let deep: Int?
        let rem: Int?
        let core: Int?
        let awake: Int?
        let dip: Double?

        init(session: HRVSession) {
            let snapshot = session.sleepSnapshot
            deep = snapshot?.deepSleepMinutes
            rem = snapshot?.remSleepMinutes
            core = Self.coreMinutes(in: snapshot)
            awake = snapshot?.awakeMinutes
            dip = session.analysisResult?.ansMetrics?.nocturnalHRDip
        }

        /// Core sleep isn't a top-level SleepData field — sum across segments
        /// when present, else the night's `.core` stage intervals (nil when it
        /// has stages but none is core: plain "asleep" minutes are not core).
        /// Only a snapshot with no stage intervals at all falls back to
        /// total − deep − REM (when we have both stage values, otherwise we
        /// can't tell what's "core").
        private static func coreMinutes(in snapshot: SleepData?) -> Int? {
            guard let snapshot else { return nil }
            let fromSegments = snapshot.effectiveSegments.compactMap(\.coreSleepMinutes).reduce(0, +)
            if fromSegments > 0 { return fromSegments }
            let stages = snapshot.stageIntervals
            if !stages.isEmpty {
                let core = stages.filter { $0.stage == .core }
                return core.isEmpty ? nil : core.map(\.durationMinutes).reduce(0, +)
            }
            guard let deep = snapshot.deepSleepMinutes,
                  let rem = snapshot.remSleepMinutes else { return nil }
            return max(0, snapshot.nightSleepMinutes - deep - rem)
        }
    }

    /// Returns a copy of this entry with the sleep-stage + nocturnal-dip mirror
    /// fields, `hrvDataQuality` and `modifiedAt` taken from `session`, and every
    /// other field kept exactly.
    ///
    /// Migrations that rebuild an entry through the field-by-field initializer
    /// MUST call this, or they silently null the mirror fields that 30-day sleep
    /// trends + the AI fact catalog read straight off the lightweight index —
    /// the same drift `make(from:)` exists to prevent.
    /// The migrations keep their own per-field semantics (they patch a
    /// specific field like recoveryScore/endDate); this only overlays the
    /// fields above from the session already loaded off disk.
    func mirroringSleepFields(from session: HRVSession) -> SessionArchiveEntry {
        let mirror = SleepMirror(session: session)
        return SessionArchiveEntry(
            sessionId: sessionId,
            date: date, endDate: endDate,
            fileHash: fileHash, filePath: filePath,
            recoveryScore: recoveryScore,
            meanRMSSD: meanRMSSD, meanHR: meanHR,
            stressIndex: stressIndex, meanSDNN: meanSDNN,
            tags: tags, notes: notes,
            sessionType: sessionType, linkedSessionIds: linkedSessionIds,
            sleepEnd: sleepEnd, sleepSegmentCount: sleepSegmentCount,
            deepSleepMinutes: mirror.deep, remSleepMinutes: mirror.rem,
            coreSleepMinutes: mirror.core, awakeMinutes: mirror.awake,
            nocturnalDipPercent: mirror.dip, hrvDataQuality: session.hrvDataQuality,
            modifiedAt: session.modifiedAt
        )
    }
}

extension SessionArchiveEntry {
    /// Decoded from an index entry a newer build wrote: re-encoding it here
    /// would drop the fields this build does not know.
    var isFromNewerSchema: Bool {
        (sourceSchemaVersion ?? 0) > Self.currentSchemaVersion
    }
}

extension SessionArchiveEntry {
    /// `entries` with each session id once, the first of each kept. Two
    /// entries of one id are one recording listed twice, never a keeper and
    /// its duplicate: duplicate cleanup retiring the "loser" would quarantine
    /// the keeper's own file and tombstone its id, deleting the night on
    /// every device.
    static func oneEntryPerSession(_ entries: [SessionArchiveEntry]) -> [SessionArchiveEntry] {
        var seen = Set<UUID>()
        return entries.filter { seen.insert($0.sessionId).inserted }
    }
}
