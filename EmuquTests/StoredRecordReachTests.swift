@testable import Emuqu
import XCTest

/// "It's a database: give the AI all of it." The named lookups pick their
/// fields; `get_stored_record` returns every session as the archive saved
/// it, so a field nobody picked, or one added later, is still reachable.
@MainActor
final class StoredRecordReachTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoredRecordReachTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // swallow-ok: a test that archived nothing leaves no directory to remove.
            }
        }
        return directory
    }

    // MARK: - Seeds

    /// A value no named lookup returns: the streamed beat count of the
    /// night's data-source summary.
    private let streamedBeats = 31_337
    /// Another: the route a workout's estimated load was taken from.
    private let estimateRoute = "Ridge Loop Estimate"

    private var nightStart: Date {
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date()
        return Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: twoDaysAgo) ?? twoDaysAgo
    }

    /// The day the night is filed under: its midpoint, the next morning.
    private var nightDay: String {
        FactLocalDay.formatter().string(from: nightStart.addingTimeInterval(4 * 3600))
    }

    private func moment(hour: Int) -> Date {
        let morning = nightStart.addingTimeInterval(9 * 3600)
        return Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: morning) ?? morning
    }

    private func analysis(at date: Date) -> HRVAnalysisResult {
        let timeDomain = TimeDomainMetrics(meanRR: 1000, sdnn: 55, rmssd: 45, pnn50: 20, sdsd: 40, meanHR: 60, sdHR: 5, triangularIndex: 12)
        let nonlinear = NonlinearMetrics(sd1: 30, sd2: 60, sd1Sd2Ratio: 0.5, sampleEntropy: 1.5, approxEntropy: 1.3, dfaAlpha1: 0.9, dfaAlpha2: 0.8, dfaAlpha1R2: 0.95)
        let ans = ANSMetrics(
            stressIndex: 120, pnsIndex: 0.5, snsIndex: -0.3, readinessScore: 7,
            respirationRate: 14, nocturnalHRDip: 12, daytimeRestingHR: 65, nocturnalMedianHR: 57
        )
        return HRVAnalysisResult(
            windowStart: 0, windowEnd: 400, timeDomain: timeDomain,
            frequencyDomain: FrequencyDomainMetrics(vlf: 300, lf: 900, hf: 700, lfHfRatio: 1.3, totalPower: 1900),
            nonlinear: nonlinear, ansMetrics: ans, artifactPercentage: 1, cleanBeatCount: 400, analysisDate: date
        )
    }

    /// A night with every stored property set, so the reflection check below
    /// sees each one come back or sit on the deny-list.
    private func fullNight() -> HRVSession {
        let start = nightStart
        let provenance = DeviceProvenance(
            deviceId: "Polar H10 TEST", deviceModel: "Polar H10", firmwareVersion: "5.0.0", recordingMode: .streaming,
            appVersion: "1.0", osVersion: "26.0", capturedAt: start
        )
        var session = HRVSession(startDate: start, tags: [ReadingTag(name: "Late meal", colorHex: "#FF0000")], sessionType: .overnight, deviceProvenance: provenance)
        session.endDate = start.addingTimeInterval(8 * 3600)
        session.state = .complete
        session.hrvDataQuality = .good
        session.recoveryScore = 7.2
        session.analysisResult = analysis(at: start)
        session.artifactFlags = [ArtifactFlags.clean]
        session.notes = "Slept with the window open"
        session.importedMetrics = HRVSession.ImportedMetrics(rmssd: 40, rmssdRaw: 42, artifactPercent: 1, source: "Test")
        fillSleep(&session, start: start)
        fillScoring(&session, start: start)
        fillSubjective(&session, start: start)
        return session
    }

    private func fillSleep(_ session: inout HRVSession, start: Date) {
        session.sleepStartMs = 600_000
        session.sleepEndMs = 27_000_000
        session.sleepSegments = [HRVSession.SleepSegmentMs(startMs: 600_000, endMs: 27_000_000)]
        session.linkedSessionIds = [UUID()]
        session.pausedDate = start.addingTimeInterval(3600)
        session.dataSourceSummary = HRVSession.DataSourceSummary(
            selectedSource: "streaming", streamingBeats: streamedBeats, deviceBeats: nil, totalBeats: 30_000,
            beatDifferencePercent: nil, reconnectCount: 2, deviceModel: "Polar H10"
        )
        session.sleepSnapshot = SleepData(
            date: start, sleepStart: start.addingTimeInterval(600), sleepEnd: start.addingTimeInterval(7.5 * 3600),
            totalSleepMinutes: 420, inBedMinutes: 450, napSleepMinutes: nil, awakeMinutes: 30,
            sleepEfficiency: 93, boundarySource: .healthKit
        )
        session.sleepUserAdjusted = true
    }

    private func fillScoring(_ session: inout HRVSession, start: Date) {
        session.napRepaired = true
        session.vitalsSnapshot = RecoveryVitals(
            respiratoryRate: 14.5, respiratoryRateBaseline: 14, oxygenSaturation: 97, oxygenSaturationMin: 93,
            wristTemperature: 0.2, wristTemperatureBaseline: 0.1, restingHeartRate: 52
        )
        session.trainingSnapshot = TrainingContext(atl: 40, ctl: 50, tsb: 10, yesterdayTrimp: 80, vo2Max: 52, daysSinceHardWorkout: 2, recentWorkouts: nil)
        session.scoreBreakdown = RecoveryScoreCalculator.ScoreBreakdown(compositeScore: 72, tier: 1, factors: [], penalties: [])
        session.frozenReadiness = 7
        session.windowUserAdjusted = true
        session.autoWindowResult = analysis(at: start)
        session.autoWindowScore = 6.5
    }

    private func fillSubjective(_ session: inout HRVSession, start: Date) {
        session.aiContext = ["sport": "none"]
        session.perceivedReadiness = 0.6
        session.morningFeeling = 4
        session.morningFeelingTags = [.allergies]
        session.healthKitExportedAt = start
        session.healthKitExportFailureCount = 1
        session.modifiedAt = start.addingTimeInterval(9 * 3600)
    }

    private func nap() -> HRVSession {
        var session = HRVSession(startDate: moment(hour: 14), tags: [], sessionType: .nap)
        session.endDate = session.startDate.addingTimeInterval(30 * 60)
        session.state = .complete
        session.analysisResult = analysis(at: session.startDate)
        return session
    }

    private func workout() -> HRVSession {
        var session = HRVSession(startDate: moment(hour: 17), tags: [], sessionType: .workout)
        session.endDate = session.startDate.addingTimeInterval(45 * 60)
        session.state = .complete
        var meta = WorkoutMetadata(sport: .run)
        meta.distanceMeters = 8000
        meta.extrapolationRouteName = estimateRoute
        meta.samples = [WorkoutSample(offsetSec: 0, heartRate: 120), WorkoutSample(offsetSec: 1, heartRate: 122)]
        meta.healthKitHROffsets = [1]
        meta.gpsPolyline = Data([1, 2, 3])
        meta.gpsFixTimes = Data([4, 5, 6])
        meta.gpsSegmentStarts = [0]
        session.workoutMetadata = meta
        session.healthKitExportedAt = session.startDate
        return session
    }

    private struct Seeded {
        let router: CompactToolRouter
        let night: HRVSession
        let workout: HRVSession
    }

    private func seed(_ extra: [HRVSession] = []) throws -> Seeded {
        let archive = SessionArchive(directory: temporaryDirectory())
        let night = fullNight()
        let workout = workout()
        for session in [night, nap(), workout] + extra {
            _ = try archive.archive(session, skipSameNightMerge: true)
        }
        let registry = AppFactResolverFactory.build(archive: archive, settings: { UserSettings() }, services: FactServices(.current))
        return Seeded(router: CompactToolRouter(registry: registry), night: night, workout: workout)
    }

    private func stored(_ router: CompactToolRouter, _ args: [String: String]) async throws -> FactValue {
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8))
        return await router.resolveTool(name: "get_stored_record", argsJSON: json)
    }

    // MARK: - Tree helpers

    private func fields(_ value: FactValue) -> [String: FactValue] {
        if case let .record(fields) = value { return fields }
        return [:]
    }

    private func items(_ value: FactValue) -> [FactValue] {
        if case let .list(items) = value { return items }
        if case let .record(fields) = value, case let .list(items)? = fields["items"] { return items }
        return []
    }

    private func text(_ value: FactValue?) -> String? {
        if case let .string(text)? = value { return text }
        return nil
    }

    private func integer(_ value: FactValue?) -> Int? {
        if case let .integer(number)? = value { return number }
        return nil
    }

    /// Every dotted key path in a tree; list items share their list's path.
    private func storedPaths(_ value: FactValue, prefix: String = "") -> [String] {
        switch value {
        case let .record(fields):
            return fields.flatMap { key, child -> [String] in
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                return [path] + storedPaths(child, prefix: path)
            }
        case let .list(items):
            return items.flatMap { storedPaths($0, prefix: prefix) }
        default:
            return []
        }
    }

    // MARK: - (a) A field no named lookup returns

    func testAFieldNoNamedLookupReturnsComesBackByDateAndByID() async throws {
        let seeded = try seed()
        let session = await seeded.router.resolveTool(name: "get_session", argsJSON: #"{"which":"by_date","date":"\#(nightDay)"}"#)
        XCTAssertFalse(session.toolResultJSON.contains("\(streamedBeats)"), "the premise: get_session does not return the streamed beat count")

        let byDate = try await stored(seeded.router, ["date": nightDay, "kind": "overnight"])
        let night = try XCTUnwrap(items(byDate).first, "the night is filed under \(nightDay): \(byDate)")
        XCTAssertEqual(integer(fields(fields(night)["dataSourceSummary"] ?? .list([]))["streamingBeats"]), streamedBeats)

        let byID = try await stored(seeded.router, ["id": seeded.night.id.uuidString])
        XCTAssertEqual(integer(fields(fields(byID)["dataSourceSummary"] ?? .list([]))["streamingBeats"]), streamedBeats)
        XCTAssertEqual(text(fields(byID)["id"]), seeded.night.id.uuidString)
        XCTAssertEqual(text(fields(byID)["session_type"]), "overnight")
        XCTAssertEqual(text(fields(byID)["date"]), nightDay)
    }

    func testAWorkoutFieldNoNamedLookupReturnsComesBackByID() async throws {
        let seeded = try seed()
        let id = seeded.workout.id.uuidString
        for which in ["by_id", "deep_dive"] {
            let named = await seeded.router.resolveTool(name: "get_workout", argsJSON: #"{"which":"\#(which)","id":"\#(id)"}"#)
            XCTAssertFalse(named.toolResultJSON.contains(estimateRoute), "the premise: get_workout \(which) does not return extrapolationRouteName")
        }
        let byID = try await stored(seeded.router, ["id": id])
        XCTAssertEqual(text(fields(fields(byID)["workoutMetadata"] ?? .list([]))["extrapolationRouteName"]), estimateRoute)
    }

    /// Dates are written in the user's own time zone, the form the rest of the
    /// catalog uses, and still name the same moment.
    func testDatesAreWrittenInTheUsersTimeZone() throws {
        let night = fullNight()
        let tree = fields(StoredSessionTree.storedRecordTree(of: night))
        let written = try XCTUnwrap(text(tree["startDate"]))
        XCTAssertEqual(written, FactValue.localISO8601(night.startDate))
        let parsed = try Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: .current).parse(written)
        XCTAssertEqual(parsed.timeIntervalSince1970, night.startDate.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - (b) The deny-list never leaks

    func testDenyListedPathsNeverAppear() async throws {
        var night = fullNight()
        night.rrSeries = RRSeries(points: [RRPoint(t_ms: 0, rr_ms: 1000, wallClockMs: 0)], sessionId: night.id, startDate: night.startDate)
        let raw = try JSONSerialization.jsonObject(with: StoredSessionTree.storedSessionJSONEncoder().encode(night)) as? [String: Any]
        XCTAssertNotNil(raw?["rrSeries"], "the premise: the stored JSON holds the beats")
        let rawWorkout = try JSONSerialization.jsonObject(with: StoredSessionTree.storedSessionJSONEncoder().encode(workout())) as? [String: Any]
        let rawMeta = rawWorkout?["workoutMetadata"] as? [String: Any]
        XCTAssertNotNil(rawMeta?["gpsPolyline"], "the premise: the stored JSON holds the GPS track")

        let seeded = try seed()
        let trees = [
            StoredSessionTree.storedRecordTree(of: night), StoredSessionTree.storedRecordTree(of: workout()),
            try await stored(seeded.router, ["period": "last_30d"])
        ]
        let leaked = trees.flatMap { storedPaths($0) }.filter { path in
            StoredSessionTree.isStoredPathDenied(path, key: path.components(separatedBy: ".").last ?? path)
        }
        XCTAssertEqual(Set(leaked).sorted(), [], "deny-listed stored paths reached the assistant")
        let neverShared: Set<String> = [
            "rrSeries", "artifactFlags", "aiContext", "healthKitExportedAt", "healthKitExportFailureCount", "workoutMetadata.samples",
            "workoutMetadata.healthKitHROffsets", "workoutMetadata.gpsPolyline", "workoutMetadata.gpsFixTimes", "workoutMetadata.gpsSegmentStarts"
        ]
        XCTAssertEqual(Set(trees.flatMap { storedPaths($0) }).intersection(neverShared).sorted(), [], "raw beats, samples, positions or bookkeeping reached the assistant")
        XCTAssertFalse(trees.flatMap { storedPaths($0) }.contains { $0.hasSuffix("schemaVersion") })
    }

    // MARK: - (c) Every stored property is returned or deny-listed

    /// A property added to HRVSession later fails here until it is seeded
    /// above, and then it is returned automatically unless it is put on the
    /// deny-list: a stored field cannot silently go missing.
    func testEveryStoredPropertyIsReturnedOrDenyListed() async throws {
        let seeded = try seed()
        let night = try await stored(seeded.router, ["id": seeded.night.id.uuidString])
        let workout = try await stored(seeded.router, ["id": seeded.workout.id.uuidString])
        let returned = Set(fields(night).keys).union(fields(workout).keys)
        let denied = StoredSessionTree.storedRecordDenyList

        var encodedKeys = Set<String>()
        for session in [seeded.night, seeded.workout] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: SessionArchive.sessionEncoder.encode(session)) as? [String: Any])
            encodedKeys.formUnion(object.keys)
        }
        let unaccounted = encodedKeys.filter { !returned.contains($0) && !StoredSessionTree.isStoredPathDenied($0, key: $0) }
        XCTAssertEqual(unaccounted.sorted(), [], "stored keys neither returned nor deny-listed")

        // The transient decode stamp is never written, so it has no stored key.
        let transient: Set<String> = ["sourceSchemaVersion"]
        let properties = Set(Mirror(reflecting: seeded.night).children.compactMap(\.label)).subtracting(transient)
        let missing = properties.filter { !returned.contains($0) && !denied.contains($0) }
        XCTAssertEqual(missing.sorted(), [], "HRVSession properties the stored record does not return; seed them above or deny-list them")
    }

    // MARK: - (d) Kind filter and period list

    func testKindKeepsOneKindAndADateListsEveryKind() async throws {
        let seeded = try seed()
        let all = try await stored(seeded.router, ["date": nightDay])
        XCTAssertEqual(Set(items(all).compactMap { text(fields($0)["session_type"]) }), ["overnight", "nap", "workout"])
        let naps = try await stored(seeded.router, ["date": nightDay, "kind": "nap"])
        XCTAssertEqual(items(naps).compactMap { text(fields($0)["session_type"]) }, ["nap"])
        let unknown = try await stored(seeded.router, ["date": nightDay, "kind": "swim"])
        guard case .missing(.invalidParameter, _) = unknown else { return XCTFail("an unknown kind is the caller's error: \(unknown)") }
    }

    func testAPeriodListsNewestFirstAndKindFilters() async throws {
        let seeded = try seed()
        let period = try await stored(seeded.router, ["period": "last_30d"])
        let types = items(period).compactMap { text(fields($0)["session_type"]) }
        XCTAssertEqual(types, ["workout", "nap", "overnight"], "newest first")
        let workouts = try await stored(seeded.router, ["period": "last_30d", "kind": "workout"])
        XCTAssertEqual(items(workouts).compactMap { text(fields($0)["id"]) }, [seeded.workout.id.uuidString])
    }

    /// A period too large for one call comes back cut, with markers, not refused.
    func testALongPeriodComesBackTruncatedNotRefused() async throws {
        let long = String(repeating: "x", count: 6000)
        let quicks: [HRVSession] = (1 ... 20).map { offset in
            var quick = HRVSession(startDate: Date().addingTimeInterval(-Double(offset) * 3 * 3600), tags: [], sessionType: .quick)
            quick.endDate = quick.startDate.addingTimeInterval(300)
            quick.state = .complete
            quick.notes = long
            return quick
        }
        let seeded = try seed(quicks)
        let value = try await stored(seeded.router, ["period": "last_30d", "kind": "quick"])
        guard case let .record(cut) = value else { return XCTFail("expected a truncated list, got \(value)") }
        guard case .boolean(true)? = cut["truncated"] else { return XCTFail("the cut list says it was cut: \(cut)") }
        XCTAssertGreaterThan(items(value).count, 0)
        XCTAssertGreaterThan(integer(cut["omitted_count"]) ?? 0, 0)
    }

    // MARK: - (e) Fields projection

    func testFieldsKeepOnlyTheNamedStoredKeys() async throws {
        let seeded = try seed()
        let value = try await stored(seeded.router, ["id": seeded.night.id.uuidString, "fields": "dataSourceSummary"])
        XCTAssertEqual(Set(fields(value).keys), ["dataSourceSummary", "date", "session_type", "id"])
        let list = try await stored(seeded.router, ["date": nightDay, "fields": "startDate"])
        for item in items(list) {
            XCTAssertEqual(Set(fields(item).keys), ["startDate", "date", "session_type", "id"])
        }
    }

    // MARK: - Discoverable

    func testTheToolIsListedAndFindDataFindsTheStoredLookups() async throws {
        XCTAssertTrue(CompactToolRouter.readTools().contains { $0.name == "get_stored_record" })
        XCTAssertEqual(CompactToolRouter.bareValueOption["get_stored_record"], "date")
        let seeded = try seed()
        let found = await seeded.router.resolveTool(name: "find_data", argsJSON: #"{"query":"full stored record every field saved"}"#)
        XCTAssertTrue(found.toolResultJSON.contains("stored."), "find_data should reach the stored lookups: \(found)")
    }
}
