import CryptoKit
@testable import Emuqu
import XCTest

// The duplicate-prevention, codec round-trip, factory and schema-gate cases.
// XCTest discovers test methods declared in an extension exactly as it does
// ones in the class body.

extension ArchiveIntegrityTests {
    // MARK: - Same-Night Duplicate Prevention

    /// A date `daysAgo` days back, at 23:00 local.
    ///
    /// 23:00 sits comfortably inside its own recovery night: the archive
    /// groups a night by the schedule's `overnightWindowStart` (20:00 for the
    /// 22:00 bedtime these tests inject), so 23:00 and 01:00 the next morning
    /// share one window, while no nearby hour straddles the boundary.
    static func nightAnchoredDate(daysAgo: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return calendar.date(bySettingHour: 23, minute: 0, second: 0, of: day) ?? day
    }

    /// Archiving a second overnight session from the same sleep (different
    /// UUID, 2 h later, well inside the 4.5 h merge gap) merges into the
    /// existing one instead of creating a duplicate — on one clock. This test
    /// used to check only the entry count, so it passed while the merge laid
    /// both recordings over each other at t = 0.
    func testSameNightDuplicatePrevention() throws {
        // Two overnight sessions starting the same night (2 hours apart, same recovery night)
        //
        // The start time is pinned to 23:00 local. It used
        // to be `Date() - 10 days`, i.e. whatever time of day the suite
        // happened to run at, so on some runs the second session (start + 2 h)
        // crossed into the next night's window, the merge correctly did not
        // happen, and the test failed at certain times of day.
        let nightStart = Self.nightAnchoredDate(daysAgo: 10)
        let session1 = createTestSession(startDate: nightStart, sessionType: .overnight)
        let session2 = createTestSession(startDate: nightStart.addingTimeInterval(2 * 3600), sessionType: .overnight)
        testSessionIds.append(session1.id)
        testSessionIds.append(session2.id)

        // Archive first session
        _ = try archive.archive(session1)

        // Archive second same-night session — should merge, not duplicate
        _ = try archive.archive(session2)

        // Only one overnight entry should exist for that night
        let nightEntries = try nightEntries(anchoredAt: nightStart)
        XCTAssertEqual(nightEntries.count, 1, "Should have exactly one entry per recovery night, got \(nightEntries.count)")

        // Both recordings' beats, the second one 2 h along the first one's clock.
        let merged = try XCTUnwrap(archive.retrieve(session1.id)?.rrSeries)
        let firstCount = session1.rrSeries?.points.count ?? 0
        XCTAssertEqual(merged.points.count, firstCount + (session2.rrSeries?.points.count ?? 0))
        XCTAssertEqual(merged.points[firstCount].t_ms, 7_200_000, "the second recording starts 2 h in")
        XCTAssertEqual(MergeClockFixture.beatsTooSoon(merged.points), 0, "no interleaved beats")
    }

    /// The failure path of the same-night merge: it throws.
    ///
    /// When the merge target cannot be read back — a transient decrypt or
    /// decode failure — falling through to the standalone write would create
    /// exactly the same-night duplicate the merge exists to prevent. It used
    /// to return the existing entry instead, which callers took as success:
    /// they flagged the new night's backup archived and cleared the recording
    /// marker, so the night was lost. Throwing keeps the existing entry, writes
    /// no duplicate, and leaves the new night's backup unarchived for recovery.
    func testAnUnreadableMergeTargetDoesNotProduceASameNightDuplicate() throws {
        let nightStart = Self.nightAnchoredDate(daysAgo: 11)
        let session1 = createTestSession(startDate: nightStart, sessionType: .overnight)
        let session2 = createTestSession(startDate: nightStart.addingTimeInterval(2 * 3600), sessionType: .overnight)
        testSessionIds.append(session1.id)
        testSessionIds.append(session2.id)

        _ = try archive.archive(session1)

        // Make the merge target unreadable, exactly as a decrypt/decode
        // failure would. The index entry stays; only the file is broken.
        let file = archive.archiveDirectory.appendingPathComponent("\(session1.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "fixture: session1 was not written")
        try Data("not json".utf8).write(to: file)

        XCTAssertThrowsError(try archive.archive(session2), "an unreadable merge target must not report success")

        let nightEntries = try nightEntries(anchoredAt: nightStart)
        XCTAssertEqual(
            nightEntries.count, 1,
            "an unreadable merge target must not fall through to a standalone write"
        )
        XCTAssertEqual(
            nightEntries.first?.sessionId, session1.id,
            "the existing entry is kept so the next re-archive can retry the merge"
        )
    }

    /// Entries belonging to the recovery night that `start` falls in, grouped
    /// the way the archive groups them: by the injected schedule's
    /// `overnightWindowStart`, so a 01:00 start belongs to the night before.
    private func nightEntries(anchoredAt start: Date) throws -> [SessionArchiveEntry] {
        let schedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)
        let night = schedule.overnightWindowStart(relativeTo: start)
        return archive.entries
            .filter { $0.sessionType == .overnight }
            .filter { schedule.overnightWindowStart(relativeTo: $0.date) == night }
    }

    /// Sessions from different nights should both be kept.
    func testDifferentNightsNotDeduplicated() throws {
        // Pinned for the same reason as `testSameNightDuplicatePrevention`, and
        // stepped by calendar day rather than by 86,400 seconds so a DST
        // boundary cannot pull the two nights into the same anchored day.
        let night1 = Self.nightAnchoredDate(daysAgo: 15)
        let night2 = Calendar.current.date(byAdding: .day, value: 1, to: night1) ?? night1.addingTimeInterval(86_400)
        let session1 = createTestSession(startDate: night1, sessionType: .overnight)
        let session2 = createTestSession(startDate: night2, sessionType: .overnight)
        testSessionIds.append(session1.id)
        testSessionIds.append(session2.id)

        _ = try archive.archive(session1)
        _ = try archive.archive(session2)

        XCTAssertTrue(archive.exists(session1.id))
        XCTAssertTrue(archive.exists(session2.id))
    }

    /// Linked segments should ignore tiny fragments and collapse near-identical
    /// duplicate ranges to a single meaningful segment.
    func testLinkedSegmentsFiltersTinyAndDedupesOverlap() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(-86400 * 30)

        var duplicateShorter = createTestSession(startDate: base, sessionType: .quick)
        duplicateShorter.endDate = base.addingTimeInterval(10 * 3600)

        var duplicateLonger = createTestSession(startDate: base, sessionType: .quick)
        duplicateLonger.endDate = base.addingTimeInterval(10 * 3600 + 60)

        let tinyStart = base.addingTimeInterval(10 * 3600 + 70)
        var tinyFragment = createTestSession(startDate: tinyStart, sessionType: .quick)
        tinyFragment.endDate = tinyStart.addingTimeInterval(2 * 60)

        var parent = createTestSession(startDate: base.addingTimeInterval(10 * 3600), sessionType: .quick)
        parent.endDate = base.addingTimeInterval(11 * 3600)
        parent.linkedSessionIds = [duplicateShorter.id, duplicateLonger.id, tinyFragment.id]

        testSessionIds.append(contentsOf: [duplicateShorter.id, duplicateLonger.id, tinyFragment.id, parent.id])

        _ = try archive.archive(duplicateShorter)
        _ = try archive.archive(duplicateLonger)
        _ = try archive.archive(tinyFragment)
        _ = try archive.archive(parent)

        let storedParent = try XCTUnwrap(archive.retrieve(parent.id))
        let linked = archive.linkedSegments(for: storedParent)

        XCTAssertEqual(linked?.count, 1, "Only one meaningful deduped linked segment should remain")
        XCTAssertEqual(linked?.first?.id, duplicateLonger.id, "Longer near-duplicate range should be kept")
    }

    /// Linked segment list should be nil when all linked ranges are tiny artifacts.
    func testLinkedSegmentsReturnsNilWhenAllLinksAreTiny() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(-86400 * 20)

        var tiny = createTestSession(startDate: base, sessionType: .quick)
        tiny.endDate = base.addingTimeInterval(3 * 60)

        var parent = createTestSession(startDate: base.addingTimeInterval(600), sessionType: .quick)
        parent.endDate = base.addingTimeInterval(2 * 3600)
        parent.linkedSessionIds = [tiny.id]

        testSessionIds.append(contentsOf: [tiny.id, parent.id])

        _ = try archive.archive(tiny)
        _ = try archive.archive(parent)

        let storedParent = try XCTUnwrap(archive.retrieve(parent.id))
        XCTAssertNil(archive.linkedSegments(for: storedParent))
    }

    // MARK: - SessionFileCodec Round-Trip Parity

    /// The codec's returned hash must be the SHA256 of the bytes exactly as
    /// they will be written — the integrity contract `_retrieve` verifies.
    /// Independently recomputed here with CryptoKit so the test doesn't
    /// trust the codec's own helper.
    func testCodecHashMatchesBytesAsWritten() throws {
        let session = createTestSession()
        let (bytes, hash, format) = try SessionArchive.SessionFileCodec.encodeForDisk(
            session,
            encoder: SessionArchive.sessionEncoder
        )
        // The codec reports whether it actually
        // encrypted. On a simulator with a working Keychain it always should;
        // a `.plaintextPendingEncryption` here means the fallback fired, which
        // is exactly the condition this test exists to surface.
        if EncryptionManager.shared.isAvailable {
            XCTAssertEqual(format, .encrypted, "Encryption was available; the codec must not have fallen back")
        }
        let independent = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, independent, "Codec hash must be SHA256 of the bytes-as-written")
        XCTAssertEqual(hash.count, 64)
        if EncryptionManager.shared.isAvailable {
            XCTAssertTrue(
                SessionArchive.looksEncrypted(bytes),
                "With encryption available, codec output must be ciphertext (hash covers ciphertext, not plaintext)"
            )
        }
    }

    /// Codec output written to disk must decode back to an equal session
    /// via the production read path (`loadAndDecodeSessionFile`), for both
    /// write encoders in use (`_archive`'s compact, `archiveBatch`/relink's
    /// pretty-printed).
    func testCodecRoundTripDecodesEqualSession() throws {
        let session = createTestSession()
        for encoder in [SessionArchive.sessionEncoder, SessionArchive.indexEncoder] {
            let (bytes, hash, _) = try SessionArchive.SessionFileCodec.encodeForDisk(session, encoder: encoder)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).json")
            try bytes.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            // Hash-over-bytes-as-written: re-reading the file and hashing
            // must reproduce the codec's hash (what verifyIntegrity does).
            let onDisk = try Data(contentsOf: url)
            XCTAssertEqual(SessionArchive.SessionFileCodec.sha256Hex(onDisk), hash)

            let decoded = try SessionArchive.loadAndDecodeSessionFile(at: url, decoder: SessionArchive.sessionDecoder)
            XCTAssertEqual(decoded.id, session.id)
            XCTAssertEqual(
                decoded.startDate.timeIntervalSince1970,
                session.startDate.timeIntervalSince1970,
                accuracy: 1.0
            )
            XCTAssertEqual(decoded.rrSeries?.points.count, session.rrSeries?.points.count)
            XCTAssertEqual(decoded.rrSeries?.points.first, session.rrSeries?.points.first)
            XCTAssertEqual(decoded.rrSeries?.points.last, session.rrSeries?.points.last)
        }
    }

    /// Guards the PRESERVED divergence: `_archive` writes compact
    /// `sortedKeys` JSON while `archiveBatch` writes pretty-printed —
    /// batch-written files legitimately hash differently than
    /// `_archive`-written ones. The encoders are deliberately NOT unified
    /// (that would change bytes on disk); both formats must stay
    /// decodable by the shared session decoder.
    func testWriteEncodersRemainDivergentAndBothDecode() throws {
        let session = createTestSession()
        let compact = try SessionArchive.sessionEncoder.encode(session)
        let pretty = try SessionArchive.indexEncoder.encode(session)
        XCTAssertNotEqual(compact, pretty, "Per-site encoder divergence is expected and preserved")
        XCTAssertEqual(try SessionArchive.sessionDecoder.decode(HRVSession.self, from: compact).id, session.id)
        XCTAssertEqual(try SessionArchive.sessionDecoder.decode(HRVSession.self, from: pretty).id, session.id)
    }

    // MARK: - SessionArchiveEntry Factory Completeness

    /// Every index field must be populated from the session exactly the way
    /// `_archive` does — including `meanSDNN` and the
    /// sleep-stage/nocturnal-dip mirrors, which a separate `archiveBatch` or
    /// `repairArchive` entry builder silently drops.
    func testEntryFactoryPopulatesEveryIndexField() {
        let ans = ANSMetrics(
            stressIndex: 42, pnsIndex: 1.2, snsIndex: -0.4,
            readinessScore: 8.0, respirationRate: 14.0,
            nocturnalHRDip: 15.5, daytimeRestingHR: 60, nocturnalMedianHR: 51
        )
        var session = createTestSession(sessionType: .overnight, ansMetrics: ans)
        XCTAssertNotNil(session.analysisResult, "Fixture must carry an analysis result for the dip mirror")
        session.recoveryScore = 7.5
        session.importedMetrics = HRVSession.ImportedMetrics(
            rmssd: 55, rmssdRaw: 52, artifactPercent: 2, source: "test", sdnn: 48.5
        )
        session.tags = [ReadingTag.morning]
        session.notes = "factory completeness"
        session.linkedSessionIds = [UUID()]
        let sleepEnd = session.startDate.addingTimeInterval(7 * 3600)
        session.sleepSnapshot = SleepData(
            date: session.startDate,
            sleepStart: session.startDate.addingTimeInterval(600),
            sleepEnd: sleepEnd,
            totalSleepMinutes: 400,
            inBedMinutes: 420,
            deepSleepMinutes: 80,
            remSleepMinutes: 90,
            awakeMinutes: 20,
            sleepEfficiency: 95,
            boundarySource: .recordingBounds
        )

        let entry = SessionArchiveEntry.make(from: session, hash: "test-hash", filePath: "test.json")

        XCTAssertEqual(entry.sessionId, session.id)
        XCTAssertEqual(entry.date, session.startDate)
        XCTAssertEqual(entry.endDate, session.endDate)
        XCTAssertEqual(entry.fileHash, "test-hash")
        XCTAssertEqual(entry.filePath, "test.json")
        XCTAssertEqual(entry.recoveryScore, 7.5)
        XCTAssertEqual(entry.meanRMSSD, session.rmssd)
        XCTAssertEqual(entry.meanHR, session.meanHR)
        XCTAssertEqual(entry.stressIndex, session.stressIndex)
        XCTAssertEqual(entry.meanSDNN, 48.5, "meanSDNN was dropped by batch/repair before the factory")
        XCTAssertEqual(entry.tags.map(\.id), session.tags.map(\.id))
        XCTAssertEqual(entry.notes, "factory completeness")
        XCTAssertEqual(entry.sessionType, .overnight)
        XCTAssertEqual(entry.linkedSessionIds, session.linkedSessionIds)
        XCTAssertEqual(entry.sleepEnd, sleepEnd)
        XCTAssertEqual(entry.sleepSegmentCount, 1, "Snapshot without segments counts as one block")
        XCTAssertEqual(entry.deepSleepMinutes, 80)
        XCTAssertEqual(entry.remSleepMinutes, 90)
        XCTAssertEqual(entry.coreSleepMinutes, 400 - 80 - 90, "Core derived from total − deep − REM")
        XCTAssertEqual(entry.awakeMinutes, 20)
        XCTAssertEqual(entry.nocturnalDipPercent, 15.5, "Dip mirror was dropped by batch/repair before the factory")

        // Repair-specific overrides: filename-keyed id + readiness fallback.
        let renamedId = UUID()
        var legacy = session
        legacy.recoveryScore = nil
        let repaired = SessionArchiveEntry.make(
            from: legacy,
            hash: "test-hash",
            filePath: "test.json",
            overridingSessionId: renamedId,
            recoveryScoreFallback: legacy.readinessScore
        )
        XCTAssertEqual(repaired.sessionId, renamedId)
        XCTAssertEqual(repaired.recoveryScore, 8.0, "Nil composite score must fall back to readiness (repair path)")
    }

    /// End-to-end index-drift guard: a session entering the archive via
    /// `archiveBatch` must carry the same index fields as one entering via
    /// `_archive`.
    func testBatchArchiveEntryGainsPreviouslyDroppedFields() throws {
        var session = createTestSession(
            startDate: Date(timeIntervalSince1970: 1_700_900_000),
            sessionType: .overnight
        )
        session.importedMetrics = HRVSession.ImportedMetrics(
            rmssd: 55, rmssdRaw: 52, artifactPercent: 2, source: "test", sdnn: 48.5
        )
        session.sleepSnapshot = SleepData(
            date: session.startDate,
            sleepStart: session.startDate.addingTimeInterval(600),
            sleepEnd: session.startDate.addingTimeInterval(7 * 3600),
            totalSleepMinutes: 400,
            inBedMinutes: 420,
            deepSleepMinutes: 80,
            remSleepMinutes: 90,
            awakeMinutes: 20,
            sleepEfficiency: 95,
            boundarySource: .recordingBounds
        )
        testSessionIds.append(session.id)

        let count = try archive.archiveBatch([session])
        XCTAssertEqual(count, 1)

        let entry = try XCTUnwrap(archive.entries.first { $0.sessionId == session.id })
        XCTAssertEqual(entry.meanSDNN, 48.5)
        XCTAssertEqual(entry.deepSleepMinutes, 80)
        XCTAssertEqual(entry.remSleepMinutes, 90)
        XCTAssertEqual(entry.coreSleepMinutes, 400 - 80 - 90)
        XCTAssertEqual(entry.awakeMinutes, 20)
    }

    // MARK: - Schema-Version Decode Gate

    /// A payload stamped with a NEWER schema version must still decode
    /// (display compatibility on older builds) and must surface that
    /// version via `sourceSchemaVersion` instead of discarding it.
    func testDecodingNewerSchemaVersionSucceedsAndSetsSourceSchemaVersion() throws {
        let newerVersion = HRVSession.currentSchemaVersion + 1
        let session = createTestSession()
        let json = try sessionJSON(session, overridingSchemaVersion: newerVersion)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HRVSession.self, from: json)

        XCTAssertEqual(decoded.sourceSchemaVersion, newerVersion)
        XCTAssertEqual(decoded.id, session.id, "Decode must remain lossless for known fields")
    }

    /// Archiving a newer-schema session must throw `newerSchemaVersion` —
    /// re-encoding it on this build would silently destroy the fields this
    /// build can't decode (the CloudKit pull-onto-older-build scenario).
    func testArchivingNewerSchemaSessionThrowsNewerSchemaVersion() throws {
        let newerVersion = HRVSession.currentSchemaVersion + 1
        let session = createTestSession()
        let json = try sessionJSON(session, overridingSchemaVersion: newerVersion)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HRVSession.self, from: json)
        testSessionIds.append(decoded.id)

        XCTAssertThrowsError(try archive.archive(decoded)) { error in
            guard case let SessionArchive.ArchiveError.newerSchemaVersion(version) = error else {
                return XCTFail("Expected ArchiveError.newerSchemaVersion, got \(error)")
            }
            XCTAssertEqual(version, newerVersion)
        }
        XCTAssertFalse(archive.exists(decoded.id), "Gate must reject before any index/file write")
    }

    /// Current-version round trip: encode always stamps
    /// `currentSchemaVersion`, so a decoded copy carries exactly the current
    /// version and re-archiving must NOT trip the newer-schema gate.
    func testCurrentSchemaVersionRoundTripDoesNotTripGate() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)
        XCTAssertNil(session.sourceSchemaVersion, "In-memory sessions carry no decoded source version")

        _ = try archive.archive(session)
        let retrieved = try XCTUnwrap(archive.retrieve(session.id))

        XCTAssertEqual(retrieved.sourceSchemaVersion, HRVSession.currentSchemaVersion)
        XCTAssertNoThrow(try archive.archive(retrieved), "Equal versions must pass the gate")
    }

    /// Encode the session with the archive's date strategy, then rewrite the
    /// `schemaVersion` field to simulate a payload from a different build.
    func sessionJSON(_ session: HRVSession, overridingSchemaVersion version: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(session)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = version
        return try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Helper Methods

    func createTestSession(
        startDate: Date? = nil,
        sessionType: SessionType = .quick,
        ansMetrics: ANSMetrics? = nil
    ) -> HRVSession {
        let sessionStartDate: Date
        if let providedStart = startDate {
            sessionStartDate = providedStart
        } else {
            sessionStartDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(sessionCounter * 7200))
            sessionCounter += 1
        }
        var points: [RRPoint] = []
        points.reserveCapacity(200)
        var tMs: Int64 = 0
        for i in 0 ..< 200 {
            let rrMs = 800 + ((i % 5) - 2) * 10
            points.append(RRPoint(t_ms: tMs, rr_ms: rrMs))
            tMs += Int64(rrMs)
        }

        let series = RRSeries(
            points: points,
            sessionId: UUID(),
            startDate: sessionStartDate
        )

        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let timeDomain = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        // Create a basic nonlinear metrics object
        let nonlinear = NonlinearMetrics(
            sd1: 50.0,
            sd2: 100.0,
            sd1Sd2Ratio: 0.5,
            sampleEntropy: 1.5,
            approxEntropy: 1.2,
            dfaAlpha1: 1.0,
            dfaAlpha2: 1.0,
            dfaAlpha1R2: 0.95
        )

        return HRVSession(
            id: UUID(),
            startDate: series.startDate,
            endDate: series.startDate.addingTimeInterval(Double(points.count) * 0.8),
            state: .complete,
            sessionType: sessionType,
            rrSeries: series,
            analysisResult: timeDomain.map { td in
                HRVAnalysisResult(
                    windowStart: 0,
                    windowEnd: points.count,
                    timeDomain: td,
                    frequencyDomain: nil,
                    nonlinear: nonlinear,
                    ansMetrics: ansMetrics,
                    artifactPercentage: 0,
                    cleanBeatCount: points.count,
                    analysisDate: series.startDate.addingTimeInterval(60),
                    windowStartMs: 0,
                    windowEndMs: Int64(points.count * 800),
                    windowMeanHR: nil,
                    windowHRStability: nil,
                    windowSelectionReason: nil,
                    windowRelativePosition: nil,
                    isConsolidated: nil,
                    isOrganizedRecovery: true,
                    windowClassification: "Organized Recovery",
                    peakCapacity: nil
                )
            },
            artifactFlags: flags,
            tags: [],
            notes: nil,
            deviceProvenance: nil
        )
    }
}
