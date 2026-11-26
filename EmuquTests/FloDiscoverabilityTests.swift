@testable import Emuqu
import XCTest

/// A capability the model can't find doesn't exist for the user. Every
/// provider sees only the compact tools, so each catalog entry has to be
/// callable, or findable through `find_data` and readable through
/// `lookup_fact`. These fail when a new fact or action would be invisible.
@MainActor
final class FloDiscoverabilityTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloDiscoverabilityTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // swallow-ok: a test that archived nothing leaves no directory to remove.
            }
        }
        return directory
    }

    private func makeRegistry() -> FactResolverRegistry {
        AppFactResolverFactory.build(
            archive: SessionArchive(directory: temporaryDirectory()), settings: { UserSettings() }, services: FactServices(.current)
        )
    }

    // MARK: - Nothing is unreachable

    /// An action outside the allow-list can't be called, and `lookup_fact`
    /// can't read an action, so it is dead to every model.
    func testEveryCatalogActionIsCallable() {
        let actions = makeRegistry().namespaces.flatMap(\.entries).filter(\.isAction).map(FactResolverRegistry.toolName(for:))
        XCTAssertFalse(actions.isEmpty)
        for action in actions {
            XCTAssertTrue(CompactToolRouter.allowedActionNames.contains(action), "\(action) is in the catalog but no model can call it")
        }
    }

    /// `find_data` searches every entry, not a hand-kept subset, so a fact
    /// added tomorrow is findable tomorrow.
    func testFindDataSearchesTheWholeCatalog() {
        let registry = makeRegistry()
        let entries = registry.namespaces.flatMap(\.entries)
        for entry in entries {
            let found = registry.entries(matching: entry.display, limit: entries.count).map(\.display)
            XCTAssertTrue(found.contains(entry.display), "\(entry.display) can't be found by its own key")
        }
    }

    func testFindDataAndItsFallbackAreAlwaysOnTheToolList() {
        let names = CompactToolRouter.readTools().map(\.name)
        XCTAssertTrue(names.contains("find_data"))
        XCTAssertTrue(names.contains("lookup_fact"))
    }

    /// Cloud providers get every tool on every send: a schema past the
    /// retriever's target would be cut differently each turn, dropping tools
    /// and breaking the prompt cache.
    func testTheCloudSchemaIsNeverFiltered() {
        let schema = CompactToolRouter.schema(registry: makeRegistry())
        let sent = ToolRetriever.retrieve(query: "how did I sleep", tools: schema, catalogHash: "test")
        XCTAssertEqual(sent.map(\.name), schema.map(\.name))
    }

    /// Apple holds about a thousand tokens of tools, chosen per question.
    /// A question no typed tool names must still leave it a way to search.
    func testApplesTrimmedListKeepsAWayToTheAnswer() {
        let schema = CompactToolRouter.readTools().sorted { $0.name < $1.name }
        for query in ["ok thanks", "am I adapted to running in the heat", "what's my next turn", "is my heart rate recovering faster"] {
            let ranked = ToolRetriever.ranked(for: query, tools: schema)
            let kept = ToolRetriever.fitting(ranked, budget: 1024, cost: AppleToolCatalog.estimatedTokens(for:)).tools.map(\.name)
            XCTAssertTrue(kept.contains("find_data"), "'\(query)' leaves Apple no search: \(kept)")
        }
    }

    // MARK: - Real questions find the right thing

    /// What a runner actually asks, and the capability that answers it.
    func testRealQuestionsFindTheCapabilityThatAnswersThem() async {
        let router = CompactToolRouter(registry: makeRegistry())
        let cases: [(String, String)] = [
            ("heat acclimation", "heat.acclimation"),
            ("am I adapted to running in the heat", "heat.acclimation"),
            ("heart rate recovery trend", "hrr."),
            ("workout streak", "workout.streak"),
            ("next turn", "directions.next_step"),
            ("roads ahead", "location_roads_ahead"),
            ("grade adjusted pace", "workout.live.grade_adjusted_pace"),
            ("aerobic decoupling", "workout.live.aerobic_decoupling"),
            ("is it still recording", "hrv.live"),
            ("how am I doing on this hill vs last time", "segment")
        ]
        for (query, expected) in cases {
            let value = await router.resolveTool(name: "find_data", argsJSON: #"{"query":"\#(query)"}"#)
            guard case let .list(rows) = value else { XCTFail("\(query): expected matches, got \(value)"); continue }
            XCTAssertLessThanOrEqual(rows.count, CompactToolRouter.findDataLimit)
            let names = rows.compactMap { row -> String? in
                guard case let .record(record) = row else { return nil }
                if case let .string(key) = record["lookup_fact_key"] { return key }
                if case let .string(tool) = record["call_tool"] { return tool }
                return nil
            }
            XCTAssertTrue(names.contains { $0.contains(expected) }, "'\(query)' did not find \(expected): \(names)")
        }
    }

    func testAKeyFindDataReturnsReadsThroughLookupFact() async throws {
        let router = CompactToolRouter(registry: makeRegistry())
        let value = await router.resolveTool(name: "find_data", argsJSON: #"{"query":"heat acclimation"}"#)
        guard case let .list(rows) = value else { return XCTFail("expected matches, got \(value)") }
        let key = try XCTUnwrap(rows.lazy.compactMap { row -> String? in
            guard case let .record(record) = row, case let .string(key) = record["lookup_fact_key"] else { return nil }
            return key
        }.first)
        let read = await router.resolveTool(name: "lookup_fact", argsJSON: #"{"key":"\#(key)"}"#)
        if case let .missing(_, detail) = read {
            XCTAssertFalse(detail?.hasPrefix("no such key") == true, "find_data handed out a key lookup_fact can't read: \(key)")
        }
    }

    func testFindDataNeedsAQueryAndSaysWhenNothingMatches() async {
        let router = CompactToolRouter(registry: makeRegistry())
        let empty = await router.resolveTool(name: "find_data", argsJSON: #"{}"#)
        guard case let .missing(reason, _) = empty else { return XCTFail("expected missing, got \(empty)") }
        XCTAssertEqual(reason, .invalidParameter)
        let nothing = await router.resolveTool(name: "find_data", argsJSON: #"{"query":"zzqx"}"#)
        guard case let .missing(reason2, _) = nothing else { return XCTFail("expected missing, got \(nothing)") }
        XCTAssertEqual(reason2, .notRecorded)
    }

    // MARK: - Apple's malformed calls

    /// Seen from Apple's on-device model in a simulated run: an object closed
    /// twice, and one with text after it. The arguments it got right count.
    func testArgumentsSurviveAStrayBraceOrTrailingText() {
        let doubled = #"{"kind": "note", "body": "A chorus about the hill.", "user_quote": "Add another"}}"#
        XCTAssertEqual(FactResolverRegistry.stringArgs(fromJSON: doubled)["kind"], "note")
        let trailing = #"{"user_quote": "keep it slow", "id": "5a5895a1"}}}, {"#
        XCTAssertEqual(FactResolverRegistry.stringArgs(fromJSON: trailing)["id"], "5a5895a1")
        let braceInString = #"{"body": "a } inside", "kind": "note"} extra"#
        XCTAssertEqual(FactResolverRegistry.stringArgs(fromJSON: braceInString)["body"], "a } inside")
        XCTAssertTrue(FactResolverRegistry.stringArgs(fromJSON: "not json").isEmpty)
    }

    /// Also seen: a read tool's main value sent bare.
    func testABareValueFillsTheToolsMainOption() {
        XCTAssertEqual(
            FactResolverRegistry.stringArgs(fromJSON: CompactToolRouter.normalizedArgs("segment_lookback_at_current_position", tool: "get_workout_live")),
            ["field": "segment_lookback_at_current_position"]
        )
        XCTAssertEqual(FactResolverRegistry.stringArgs(fromJSON: CompactToolRouter.normalizedArgs(#""trend""#, tool: "get_recovery")), ["which": "trend"])
        XCTAssertEqual(CompactToolRouter.normalizedArgs(#"{"which":"trend"}"#, tool: "get_recovery"), #"{"which":"trend"}"#)
        XCTAssertEqual(CompactToolRouter.normalizedArgs("hello", tool: "assistant_memory_add"), "hello", "actions are left alone")
    }

    func testEveryReadToolHasABareValueOption() {
        let reads = Set(CompactToolRouter.readTools().map(\.name)).subtracting(["get_today"])
        XCTAssertEqual(reads, Set(CompactToolRouter.bareValueOption.keys))
    }

    // MARK: - Pace in the user's units

    /// A simulated run had the model read 340 s/km as "5:40 per mile";
    /// it is 9:07 per mile. Every pace now carries its display form.
    func testEveryPaceComesWithItsDisplayInTheUsersUnits() {
        let record: FactValue = .record([
            "current_pace_sec_per_km": .double(340),
            "nested": .list([.record(["pace_sec_per_km_at_point": .double(300)])])
        ])
        guard case let .record(fields) = PaceDisplay.annotate(record, units: .imperial) else { return XCTFail("expected a record") }
        XCTAssertEqual(text(fields["current_pace_display"]), "9:07 /mi")
        guard case let .list(items) = fields["nested"], case let .record(inner) = items.first else { return XCTFail("nested lost") }
        XCTAssertEqual(text(inner["pace_display_at_point"]), "8:02 /mi")
        guard case let .record(single) = PaceDisplay.annotate(.double(340), field: "pace_sec_per_km", units: .metric) else {
            return XCTFail("a bare pace becomes a record")
        }
        XCTAssertEqual(text(single["pace_display"]), "5:40 /km")
        guard case let .double(seconds) = single["pace_sec_per_km"] else { return XCTFail("the number is kept") }
        XCTAssertEqual(seconds, 340)
    }

    private func text(_ value: FactValue?) -> String? {
        if case let .string(text) = value { return text }
        return nil
    }

    // MARK: - The typed tools name what a coach needs

    func testTheTypedToolsReachTheCoachingHistory() async {
        let router = CompactToolRouter(registry: makeRegistry())
        let calls: [(String, String)] = [
            ("get_training_load", #"{"which":"heat_acclimation"}"#),
            ("get_training_load", #"{"which":"workout_streak"}"#),
            ("get_training_load", #"{"which":"workouts_this_week"}"#),
            ("get_training_load", #"{"which":"hrr_trend_1min","period":"last_30d"}"#),
            ("get_walks", #"{"which":"summary","period":"last_30d"}"#),
            ("get_routes", #"{"field":"next_step"}"#),
            ("get_workout_live", #"{"field":"grade_adjusted_pace_sec_per_km"}"#),
            ("get_workout_live", #"{"field":"aerobic_decoupling_percent"}"#)
        ]
        for (tool, args) in calls {
            let value = await router.resolveTool(name: tool, argsJSON: args)
            if case let .missing(reason, detail) = value {
                XCTAssertNotEqual(reason, .invalidParameter, "\(tool) \(args): \(detail ?? "")")
                XCTAssertFalse(detail?.hasPrefix("no such key") == true, "\(tool) \(args) points at a key that doesn't exist")
            }
        }
    }
}
