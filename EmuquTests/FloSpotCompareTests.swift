import CoreLocation
@testable import Emuqu
import XCTest

/// "How am I doing on this hill compared to last time?" has an answer in the
/// app: the pace, HR and altitude each past GPS workout had at that spot.
/// Every provider sees only the compact tools and the system prompt, so the
/// answer exists for the model only if those name it and route to it.
@MainActor
final class FloSpotCompareTests: XCTestCase {
    private let hill = CLLocationCoordinate2D(latitude: 39.781, longitude: -89.652)

    // MARK: - What the model is told

    func testTheLiveToolNamesTheSpotLookback() throws {
        let live = try XCTUnwrap(CompactToolRouter.readTools().first { $0.name == "get_workout_live" })
        XCTAssertTrue(live.description.contains("'segment_lookback_at_current_position'"))
        XCTAssertTrue(live.description.contains("this hill vs last time"))
    }

    func testTheWorkoutToolOffersTheSpotCompareWithAPoint() throws {
        let workout = try XCTUnwrap(CompactToolRouter.readTools().first { $0.name == "get_workout" })
        XCTAssertTrue(workout.description.contains("'segment_compare'"))
        XCTAssertNotNil(workout.inputSchema.properties["point"], "segment_compare needs a place to compare")
    }

    func testTheCapabilityIndexMentionsSpotComparisons() {
        XCTAssertTrue(CompactToolRouter.capabilityIndex().contains("this exact spot in past workouts"))
    }

    func testTheLocationGuidanceSaysSpotComparisonsAreSupported() {
        let composed = AssistantSystemPrompt.compose(
            services: PromptServices(.current), userFacts: "", priorSummary: nil, contextRendered: "", toolMode: true
        )
        XCTAssertTrue(composed.contains("field='segment_lookback_at_current_position'"))
        XCTAssertTrue(composed.contains("which='segment_compare'"))
        XCTAssertTrue(composed.contains("never tell the user it isn't"))
        XCTAssertTrue(composed.contains("never say you can't make lists"))
        XCTAssertTrue(composed.contains("`assistant_email_compose`"))
    }

    // MARK: - What the call returns

    func testSegmentCompareWithoutAPointSaysWhatItNeeds() async {
        let router = CompactToolRouter(registry: registry(with: []))
        let value = await router.resolveTool(name: "get_workout", argsJSON: #"{"which":"segment_compare"}"#)
        guard case let .missing(reason, detail) = value else { return XCTFail("expected a missing value, got \(value)") }
        XCTAssertEqual(reason, .invalidParameter)
        XCTAssertTrue(detail?.contains("'point'") == true, detail ?? "nil")
    }

    func testSegmentCompareReturnsThePastWorkoutAtThatSpot() async throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let router = CompactToolRouter(registry: registry(with: [walkUpTheHill(start: start)]))
        let value = await router.resolveTool(
            name: "get_workout", argsJSON: #"{"which":"segment_compare","point":"\#(hill.latitude),\#(hill.longitude)"}"#
        )
        guard case let .list(matches) = value else { return XCTFail("expected a list, got \(value)") }
        XCTAssertEqual(matches.count, 1)
        guard case let .record(record) = try XCTUnwrap(matches.first) else { return XCTFail("expected a record") }
        guard case let .integer(heartRate) = record["hr_bpm_at_point"] else { return XCTFail("no heart rate at the spot: \(record)") }
        guard case let .double(altitude) = record["altitude_m_at_point"] else { return XCTFail("no altitude at the spot: \(record)") }
        XCTAssertEqual(heartRate, 140)
        XCTAssertEqual(altitude, 180)
    }

    func testSegmentCompareSaysWhenNoWorkoutPassedThere() async {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let router = CompactToolRouter(registry: registry(with: [walkUpTheHill(start: start)]))
        let value = await router.resolveTool(name: "get_workout", argsJSON: #"{"which":"segment_compare","point":"40.5,-88.0"}"#)
        guard case let .missing(reason, _) = value else { return XCTFail("expected a missing value, got \(value)") }
        XCTAssertEqual(reason, .notRecorded)
    }

    /// "How did I do on that hill yesterday compared to before": the past
    /// workout's timeline says where each stretch was, and that point is
    /// what segment_compare takes.
    func testAHillOnAPastWorkoutCanBeComparedFromItsTimeline() async throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let router = CompactToolRouter(registry: registry(with: [walkUpTheHill(start: start)]))
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = .current
        let timeline = await router.resolveTool(name: "get_workout", argsJSON: #"{"which":"timeline","date":"\#(day.string(from: start))"}"#)
        guard case let .record(envelope) = timeline, case let .list(buckets) = envelope["buckets"] else {
            return XCTFail("expected a timeline, got \(timeline)")
        }
        let middle = try XCTUnwrap(buckets.first { bucket in
            guard case let .record(rec) = bucket, case let .integer(offset) = rec["offset_sec"] else { return false }
            return (290...300).contains(offset)
        })
        guard case let .record(rec) = middle, case let .double(lat) = rec["lat"], case let .double(lon) = rec["lon"] else {
            return XCTFail("the bucket on the hill has no position: \(middle)")
        }
        XCTAssertEqual(lat, hill.latitude, accuracy: 0.0002)
        XCTAssertEqual(lon, hill.longitude, accuracy: 0.0002)
        let compared = await router.resolveTool(name: "get_workout", argsJSON: #"{"which":"segment_compare","point":"\#(lat),\#(lon)"}"#)
        guard case let .list(matches) = compared else { return XCTFail("expected matches, got \(compared)") }
        XCTAssertEqual(matches.count, 1)
    }

    /// The other variants keep the arguments they always required.
    func testTheOtherWorkoutVariantsStillNameWhatTheyNeed() async {
        let router = CompactToolRouter(registry: registry(with: []))
        let cases: [(String, String)] = [
            (#"{}"#, "requires 'which'"),
            (#"{"which":"by_ordinal"}"#, "requires 'n'"),
            (#"{"which":"timeline"}"#, "requires 'date'"),
            (#"{"which":"nonsense"}"#, "unknown which='nonsense'")
        ]
        for (args, expected) in cases {
            let value = await router.resolveTool(name: "get_workout", argsJSON: args)
            guard case let .missing(reason, detail) = value else { XCTFail("\(args): expected missing, got \(value)"); continue }
            XCTAssertEqual(reason, .invalidParameter, args)
            XCTAssertTrue(detail?.contains(expected) == true, "\(args): \(detail ?? "nil")")
        }
    }

    func testAnOrdinalStillReachesTheWorkout() async {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let router = CompactToolRouter(registry: registry(with: [walkUpTheHill(start: start)]))
        let value = await router.resolveTool(name: "get_workout", argsJSON: #"{"which":"by_ordinal","n":"0"}"#)
        if case let .missing(reason, detail) = value {
            XCTFail("the newest workout was not found: \(reason) \(detail ?? "")")
        }
    }

    // MARK: - A list that grows

    /// "Start a list… / Add another": the second save carries the first
    /// one's id and replaces its text, so the user ends with one list.
    func testAddingToAListReplacesItInsteadOfSavingACopy() async throws {
        let directory = temporaryDirectory()
        let store = AssistantArtifactStore(directory: directory)
        let viewModel = AssistantViewModel(
            services: ChatServices(.current),
            store: ConversationStore(fileURL: directory.appendingPathComponent("conversation.json")),
            factsStore: UserFactsStore(fileURL: directory.appendingPathComponent("user_facts.json"))
        )
        let dependencies = AppDependencies()
        dependencies.overrides.assistantArtifactStore = store
        dependencies.overrides.assistantViewModel = viewModel
        let installed = AppDependencies.install(dependencies)
        defer { installed.end() }
        let router = CompactToolRouter(registry: AppFactResolverFactory.build(
            archive: SessionArchive(directory: directory), settings: { UserSettings() }, services: FactServices(.current)
        ))

        viewModel.turns = [ChatTurn(role: .user, text: "Start a list of song ideas. First one: rain on the ridge.")]
        let started = await router.resolveTool(
            name: "assistant_artifacts_add",
            argsJSON: #"{"kind":"note","body":"Song ideas\n1. rain on the ridge","user_quote":"Start a list of song ideas"}"#
        )
        guard case let .record(first) = started, case let .string(id) = first["id"] else { return XCTFail("not saved: \(started)") }

        viewModel.turns.append(ChatTurn(role: .user, text: "Add another: a chorus about the hill."))
        let grown = await router.resolveTool(
            name: "assistant_artifacts_add",
            argsJSON: #"{"kind":"note","body":"Song ideas\n1. rain on the ridge\n2. a chorus about the hill","user_quote":"Add another: a chorus about the hill.","id":"\#(id)"}"#
        )
        guard case let .record(second) = grown, case .boolean(true) = second["updated"] else { return XCTFail("not updated: \(grown)") }
        XCTAssertEqual(store.list().count, 1, "the grown list was saved as a second note")
        XCTAssertEqual(store.list().first?.body, "Song ideas\n1. rain on the ridge\n2. a chorus about the hill")
    }

    func testUpdatingAnUnknownArtifactSavesNothing() async {
        let directory = temporaryDirectory()
        let store = AssistantArtifactStore(directory: directory)
        XCTAssertNil(store.updateBody(id: UUID(), body: "anything"))
        XCTAssertTrue(store.list().isEmpty, "an update of nothing created a note")
    }

    // MARK: - Fixtures

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloSpotCompareTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // swallow-ok: a test that archived nothing leaves no directory to remove.
            }
        }
        return directory
    }

    private func registry(with sessions: [HRVSession]) -> FactResolverRegistry {
        let archive = SessionArchive(directory: temporaryDirectory())
        for session in sessions {
            XCTAssertNoThrow(try archive.archive(session, skipSameNightMerge: true))
        }
        return AppFactResolverFactory.build(archive: archive, settings: { UserSettings() }, services: FactServices(.current))
    }

    /// A ten-minute walk north that passes the hill at minute five, with the
    /// heart rate and altitude it had there.
    private func walkUpTheHill(start: Date) -> HRVSession {
        var fixes: [CLLocation] = []
        for minute in 0...10 {
            let step = Double(minute)
            let latitude: Double = hill.latitude + (step - 5) * 0.0008
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: hill.longitude)
            let altitude: Double = 150 + step * 6
            let time: Date = start.addingTimeInterval(step * 60)
            fixes.append(CLLocation(coordinate: coordinate, altitude: altitude, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: time))
        }
        var samples: [WorkoutSample] = []
        for second in 0...600 {
            let onTheHill = second == 300
            let heartRate: Int = onTheHill ? 140 : 120
            let altitude: Double = onTheHill ? 180 : 150
            samples.append(WorkoutSample(
                offsetSec: second, heartRate: heartRate, distanceMeters: nil, paceSecPerKm: nil,
                cadenceStepsPerMin: nil, altitudeMeters: altitude, alpha1: nil, mets: nil, powerWatts: nil
            ))
        }
        var session = HRVSession(startDate: start, tags: [], sessionType: .workout)
        session.endDate = start.addingTimeInterval(600)
        session.state = .complete
        var metadata = WorkoutMetadata(sport: .walk)
        metadata.gpsPolyline = WorkoutAnalyzer.encodePolyline(track: fixes)
        metadata.gpsFixTimes = WorkoutAnalyzer.encodeFixTimes(track: fixes)
        metadata.samples = samples
        session.workoutMetadata = metadata
        return session
    }
}
