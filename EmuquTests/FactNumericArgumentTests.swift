@testable import Emuqu
import XCTest

/// Model-supplied numeric tool arguments must never trap.
///
/// `Double(String)` accepts "inf", "nan" and "1e20", and `Int(Double)` traps on
/// each of them. Two Flo tools built a reply string with `Int(daily)` and
/// `Int(radius)` from such a value, so one made-up number crashed the app
/// mid-chat. Every numeric parameter now goes through `FactNumericArgument`;
/// these tests feed each tool the values a model could invent and require an
/// `.invalidParameter` reply.
@MainActor
final class FactNumericArgumentTests: XCTestCase {
    private static let hostileValues = ["inf", "-inf", "infinity", "nan", "1e20", "-1", "1e309", "abc", ""]

    private func makeRegistry() -> FactResolverRegistry {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FactNumericArgumentTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return AppFactResolverFactory.build(
            archive: SessionArchive(directory: directory),
            settings: { UserSettings() }
        )
    }

    private func assertInvalidParameter(
        _ value: FactValue,
        _ key: String,
        mentioning parameter: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .missing(reason, detail) = value else {
            return XCTFail("\(key) should be rejected, got \(value)", file: file, line: line)
        }
        XCTAssertEqual(reason, .invalidParameter, "\(key) should be an invalidParameter reply", file: file, line: line)
        if let parameter {
            XCTAssertTrue(detail?.contains(parameter) == true, "\(key) should name \(parameter), got \(detail ?? "nil")", file: file, line: line)
        }
    }

    // MARK: - Parser

    func testParserRejectsNonFiniteAndOutOfRangeValues() {
        for raw in Self.hostileValues {
            XCTAssertThrowsError(try FactNumericArgument.dailyTrimp.value(raw), "daily_trimp accepted '\(raw)'")
        }
        XCTAssertThrowsError(try FactNumericArgument.gapTrimp.value("0"), "gap_trimp must be above 0")
        XCTAssertThrowsError(try FactNumericArgument.horizonDays.integer("14.5"), "a day count must be whole")
        XCTAssertThrowsError(try FactNumericArgument.latitude.value("91"))
        XCTAssertThrowsError(try FactNumericArgument.longitude.value("-180.5"))
    }

    func testParserAcceptsValuesInsideTheDeclaredRange() throws {
        XCTAssertEqual(try FactNumericArgument.dailyTrimp.value(" 60 "), 60)
        XCTAssertEqual(try FactNumericArgument.gapTrimp.value("0.5"), 0.5)
        XCTAssertEqual(try FactNumericArgument.horizonDays.integer("365"), 365)
        XCTAssertEqual(try FactNumericArgument.latitude.value("-89.9"), -89.9)
        XCTAssertEqual(try FactNumericArgument.ordinal.integer("0"), 0)
    }

    func testRejectionNamesTheParameterAndItsRange() {
        do throws(FactArgumentError) {
            _ = try FactNumericArgument.horizonDays.integer("1e20")
            XCTFail("1e20 days must be rejected")
        } catch {
            XCTAssertTrue(error.detail.contains("horizon_days"))
            XCTAssertTrue(error.detail.contains("from 1 to 365"))
            guard case .missing(.invalidParameter, _) = error.factValue else {
                return XCTFail("the reply must be an invalidParameter envelope")
            }
        }
    }

    func testFieldListRejectsTheWrongCountAndEmptyFields() {
        XCTAssertThrowsError(try FactNumericArgument.fields("60", counts: [2], format: "x"))
        XCTAssertThrowsError(try FactNumericArgument.fields("60,,5", counts: [2], format: "x"))
        XCTAssertEqual(try FactNumericArgument.fields("60, 5", counts: [2], format: "x"), ["60", "5"])
    }

    // MARK: - Every numeric tool

    /// Each key puts the hostile value in the slot that used to reach
    /// `Int(_:)`, a day count, an index or a distance.
    private static func hostileKeys(_ bad: String) -> [String] {
        [
            "training.days_until_atl_converges(\(bad),5)",
            "training.days_until_atl_converges(60,\(bad))",
            "training.days_until_converged_from(\(bad),70,60,5)",
            "training.days_until_converged_from(65,70,\(bad),5)",
            "training.days_until_converged_from(65,70,60,\(bad))",
            "training.project_from(65,70,\(bad),14)",
            "training.project_from(65,\(bad),60,14)",
            "training.project_from(65,70,60,\(bad))",
            "training.projected_tsb(\(bad))",
            "workout.segment_compare(39.78,-89.65,\(bad))",
            "session.by_ordinal(\(bad))",
            "workout.by_ordinal(\(bad))",
            "workout.live.timeline(\(bad))"
        ]
    }

    func testEveryNumericFactRejectsHostileValuesWithoutTrapping() {
        let registry = makeRegistry()
        for bad in ["inf", "nan", "1e20", "-1"] {
            for key in Self.hostileKeys(bad) {
                assertInvalidParameter(registry.resolve(key), key)
            }
        }
    }

    /// "-1" is a real latitude and longitude, so the coordinate slots get
    /// their own out-of-range values.
    func testSegmentCompareRejectsHostileCoordinates() {
        let registry = makeRegistry()
        let keys = ["inf", "nan", "1e20", "-91"].map { "workout.segment_compare(\($0),-89.65)" }
            + ["inf", "nan", "1e20", "-181"].map { "workout.segment_compare(39.78,\($0))" }
        for key in keys {
            assertInvalidParameter(registry.resolve(key), key)
        }
    }

    func testWebSearchRejectsAHostileResultCountBeforeAnyRequest() async {
        let registry = makeRegistry()
        for bad in ["inf", "nan", "1e20", "-1"] {
            let args = #"{"query":"tempo run","max_results":"\#(bad)"}"#
            let value = await registry.resolveTool(name: "web_search", argsJSON: args)
            assertInvalidParameter(value, "web_search max_results=\(bad)", mentioning: "max_results")
        }
    }

    func testValidProjectionStillResolves() {
        let value = makeRegistry().resolve("training.project_from(65.4,72.1,80,14)")
        guard case let .record(fields) = value else {
            return XCTFail("a valid projection must return a record, got \(value)")
        }
        XCTAssertNotNil(fields["final_atl"])
    }

    // MARK: - Hospital routes

    /// A hospital route is never an emergency service: the result tells the
    /// model to give the local emergency number first, on success or failure.
    func testHospitalDestinationCarriesTheEmergencyNumberFirst() {
        guard let notice = WorkoutLiveCoachingNamespace.medicalSafetyNotice(for: .poi(query: "hospital")) else {
            return XCTFail("a hospital destination must carry a safety notice")
        }
        XCTAssertTrue(notice.contains(GetMeBackView.emergencyNumbersShown(dialling: GetMeBackView.emergencyNumber(currentCountry: nil))))
        XCTAssertTrue(notice.contains("emergency number"))
        XCTAssertNil(WorkoutLiveCoachingNamespace.medicalSafetyNotice(for: .poi(query: "parking lot")))
        XCTAssertNil(WorkoutLiveCoachingNamespace.medicalSafetyNotice(for: .origin))

        let routed = WorkoutLiveCoachingNamespace.withSafetyNotice(.record(["mode": .string("walking")]), notice)
        guard case let .record(fields) = routed, case let .string(first)? = fields["safety_first"] else {
            return XCTFail("the route record must carry safety_first")
        }
        XCTAssertEqual(first, notice)

        let failed = WorkoutLiveCoachingNamespace.withSafetyNotice(.missing(reason: .notRecorded, detail: "offline"), notice)
        guard case let .missing(_, detail?) = failed else { return XCTFail("a failed lookup stays missing") }
        XCTAssertTrue(detail.hasPrefix(notice), "the notice must come before the failure detail")
    }
}
