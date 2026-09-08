@testable import Emuqu
import Foundation
import XCTest

/// Tests for `FactValue` — the typed union every assistant fact resolver
/// returns, and the wire envelope every provider's `tool_result` carries.
///
/// Two contracts matter here and neither had a test:
///
/// 1. **Absence is structural.** A `missingReason` key present in the JSON
///    is the *only* signal the model gets that a value is absent — there is
///    no prompt rule backing it up. If that key ever leaks onto a successful
///    response, or goes missing on a failed one, the model starts
///    confabulating numbers.
/// 2. **Key order is deterministic.** Tool-result payloads sit inside the
///    cached prompt prefix on retry continuations, so unstable key ordering
///    silently busts the cache on every retry.
final class FactValueTests: XCTestCase {
    // MARK: - humanReadable: scalars

    func testIntegerRendersBare() {
        XCTAssertEqual(FactValue.integer(42).humanReadable, "42")
        XCTAssertEqual(FactValue.integer(-7).humanReadable, "-7")
        XCTAssertEqual(FactValue.integer(0).humanReadable, "0")
    }

    func testWholeDoubleDropsItsDecimalPoint() {
        XCTAssertEqual(FactValue.double(5).humanReadable, "5")
        XCTAssertEqual(FactValue.double(-12).humanReadable, "-12")
    }

    func testFractionalDoubleCapsAtTwoDecimals() {
        XCTAssertEqual(FactValue.double(5.25).humanReadable, "5.25")
        XCTAssertEqual(FactValue.double(1.234).humanReadable, "1.23")
    }

    /// Regression test for an unescaped `.` in the trailing-zero strip.
    ///
    /// The pattern was `#".?0+$"#`, where the wildcard matched the digit in
    /// front of the zeros: `5.2` formats as "5.20", the regex ate "20", and
    /// the assistant was handed "5." with the value gone. Every double whose
    /// two-decimal form ends in exactly one zero was affected — x.10 through
    /// x.90, which is most of the metrics the model quotes.
    func testSingleDecimalDoubleKeepsItsValue() {
        XCTAssertEqual(FactValue.double(5.2).humanReadable, "5.2")
        XCTAssertEqual(FactValue.double(5.10).humanReadable, "5.1")
        XCTAssertEqual(FactValue.double(-0.1).humanReadable, "-0.1")
        // The whole point of the strip: one zero goes, the digit stays.
        for tenth in 1 ... 9 {
            let value = Double(tenth) / 10.0
            XCTAssertEqual(
                FactValue.double(4 + value).humanReadable,
                "4.\(tenth)",
                "4.\(tenth) should survive the strip"
            )
        }
    }

    func testTwoDecimalDoublesAreUnaffectedByTheStrip() {
        XCTAssertEqual(FactValue.double(5.25).humanReadable, "5.25")
        XCTAssertEqual(FactValue.double(5.05).humanReadable, "5.05")
    }

    func testDoubleRoundingToZeroCollapsesToTheWholeNumber() {
        // 5.004 formats as "5.00", and stripping the trailing zeros takes
        // the decimal point with them. Pinning this so nobody "fixes" the
        // strip regex into leaving a bare "5." behind.
        XCTAssertEqual(FactValue.double(5.004).humanReadable, "5")
    }

    func testStringRendersVerbatim() {
        XCTAssertEqual(FactValue.string("elevated").humanReadable, "elevated")
        XCTAssertEqual(FactValue.string("").humanReadable, "")
    }

    func testBooleanRendersAsYesOrNo() {
        XCTAssertEqual(FactValue.boolean(true).humanReadable, "yes")
        XCTAssertEqual(FactValue.boolean(false).humanReadable, "no")
    }

    func testDateRendersAsInternetDateTime() {
        let value = FactValue.date(Date(timeIntervalSince1970: 0)).humanReadable
        XCTAssertEqual(value, "1970-01-01T00:00:00Z")
    }

    // MARK: - humanReadable: durations

    func testDurationUnderAMinuteShowsSecondsOnly() {
        XCTAssertEqual(FactValue.durationSec(0).humanReadable, "0s")
        XCTAssertEqual(FactValue.durationSec(7).humanReadable, "7s")
        XCTAssertEqual(FactValue.durationSec(59).humanReadable, "59s")
    }

    func testDurationUnderAnHourZeroPadsTheSeconds() {
        // "63m 07s", not "63m 7s" — the pad keeps a column of durations
        // aligned in the context dump.
        XCTAssertEqual(FactValue.durationSec(63).humanReadable, "1m 03s")
        XCTAssertEqual(FactValue.durationSec(600).humanReadable, "10m 00s")
        XCTAssertEqual(FactValue.durationSec(3599).humanReadable, "59m 59s")
    }

    func testDurationOverAnHourShowsAllThreeUnits() {
        XCTAssertEqual(FactValue.durationSec(3600).humanReadable, "1h 0m 0s")
        XCTAssertEqual(FactValue.durationSec(3661).humanReadable, "1h 1m 1s")
        XCTAssertEqual(FactValue.durationSec(45296).humanReadable, "12h 34m 56s")
    }

    // MARK: - humanReadable: absence

    func testMissingNamesItsReason() {
        XCTAssertEqual(
            FactValue.missing(reason: .notRecorded).humanReadable,
            "unknown (notRecorded)"
        )
        XCTAssertEqual(
            FactValue.missing(reason: .sensorDropout).humanReadable,
            "unknown (sensorDropout)"
        )
    }

    func testMissingAppendsItsDetailWhenPresent() {
        XCTAssertEqual(
            FactValue.missing(reason: .outOfRange, detail: "before first session").humanReadable,
            "unknown (outOfRange: before first session)"
        )
    }

    func testEveryMissingReasonRendersItsRawValue() {
        let reasons: [MissingReason] = [
            .notRecorded, .notYetComputed, .outOfRange, .sensorDropout,
            .invalidParameter, .internalError, .tooMuchData, .rateLimited,
            .partialData
        ]
        for reason in reasons {
            XCTAssertEqual(
                FactValue.missing(reason: reason).humanReadable,
                "unknown (\(reason.rawValue))"
            )
        }
    }

    // MARK: - humanReadable: containers

    func testListRendersBracketed() {
        let value = FactValue.list([.integer(1), .integer(2), .integer(3)])
        XCTAssertEqual(value.humanReadable, "[1, 2, 3]")
    }

    func testEmptyListRendersAsEmptyBrackets() {
        XCTAssertEqual(FactValue.list([]).humanReadable, "[]")
    }

    func testListPreservesItsOrder() {
        let value = FactValue.list([.string("c"), .string("a"), .string("b")])
        XCTAssertEqual(value.humanReadable, "[c, a, b]")
    }

    func testRecordSortsItsKeys() {
        // Swift dictionaries have no order; the sort is what makes the
        // rendering (and therefore the cached prefix) reproducible.
        let value = FactValue.record([
            "rmssd": .double(42),
            "atl": .integer(71),
            "ctl": .integer(62)
        ])
        XCTAssertEqual(value.humanReadable, "{atl: 71, ctl: 62, rmssd: 42}")
    }

    func testNestedContainersRenderInline() {
        let value = FactValue.record([
            "window": .record(["start": .integer(0), "end": .integer(10)]),
            "tags": .list([.string("a"), .string("b")])
        ])
        XCTAssertEqual(value.humanReadable, "{tags: [a, b], window: {end: 10, start: 0}}")
    }

    // MARK: - isScalar / isMissing

    func testScalarsAreScalarAndContainersAreNot() {
        let scalars: [FactValue] = [
            .integer(1), .double(1), .string("x"), .date(Date()),
            .durationSec(1), .boolean(true), .missing(reason: .notRecorded)
        ]
        for value in scalars {
            XCTAssertTrue(value.isScalar, "\(value) should be scalar")
        }
        XCTAssertFalse(FactValue.list([]).isScalar)
        XCTAssertFalse(FactValue.record([:]).isScalar)
    }

    func testOnlyMissingIsMissing() {
        XCTAssertTrue(FactValue.missing(reason: .notRecorded).isMissing)
        XCTAssertTrue(FactValue.missing(reason: .internalError, detail: "bug").isMissing)
        XCTAssertFalse(FactValue.integer(0).isMissing)
        XCTAssertFalse(FactValue.string("").isMissing)
        XCTAssertFalse(FactValue.boolean(false).isMissing)
        XCTAssertFalse(FactValue.list([]).isMissing)
    }

    func testAnEmptyValueIsNotAMissingValue() {
        // Zero, "", false and [] are all real answers. Conflating any of
        // them with absence is how a model ends up saying "no data" about
        // a genuine zero.
        XCTAssertFalse(FactValue.integer(0).isMissing)
        XCTAssertFalse(FactValue.double(0).isMissing)
        XCTAssertFalse(FactValue.durationSec(0).isMissing)
    }

    // MARK: - from(_:) builders

    func testFromWrapsNonNilScalars() {
        XCTAssertEqual(FactValue.from(42 as Int?).humanReadable, "42")
        XCTAssertEqual(FactValue.from(4.25 as Double?).humanReadable, "4.25")
        XCTAssertEqual(FactValue.from(4.5 as Double?).humanReadable, "4.5")
        XCTAssertEqual(FactValue.from("hi" as String?).humanReadable, "hi")
        XCTAssertEqual(FactValue.from(true as Bool?).humanReadable, "yes")
        XCTAssertEqual(
            FactValue.from(Date(timeIntervalSince1970: 0) as Date?).humanReadable,
            "1970-01-01T00:00:00Z"
        )
    }

    func testFromDefaultsNilToNotRecorded() {
        XCTAssertEqual(
            FactValue.from(nil as Int?).humanReadable,
            "unknown (notRecorded)"
        )
        XCTAssertEqual(
            FactValue.from(nil as Double?).humanReadable,
            "unknown (notRecorded)"
        )
        XCTAssertEqual(
            FactValue.from(nil as String?).humanReadable,
            "unknown (notRecorded)"
        )
        XCTAssertEqual(
            FactValue.from(nil as Bool?).humanReadable,
            "unknown (notRecorded)"
        )
        XCTAssertEqual(
            FactValue.from(nil as Date?).humanReadable,
            "unknown (notRecorded)"
        )
    }

    func testFromCarriesAnExplicitReasonAndDetail() {
        let value = FactValue.from(
            nil as Double?,
            reason: .invalidParameter,
            detail: "unparseable date"
        )
        XCTAssertEqual(value.humanReadable, "unknown (invalidParameter: unparseable date)")
    }

    func testFromIgnoresTheReasonWhenAValueIsPresent() {
        let value = FactValue.from(3 as Int?, reason: .internalError, detail: "should not appear")
        XCTAssertFalse(value.isMissing)
        XCTAssertEqual(value.humanReadable, "3")
    }

    // MARK: - prettyMultiline

    func testPrettyMultilineListsOneItemPerLine() {
        let value = FactValue.list([.integer(1), .integer(2)])
        XCTAssertEqual(value.prettyMultiline(), "- 1\n- 2")
    }

    func testPrettyMultilineMarksAnEmptyList() {
        XCTAssertEqual(FactValue.list([]).prettyMultiline(), "(empty)")
    }

    func testPrettyMultilineIndentsNestedRecords() {
        let value = FactValue.record([
            "atl": .integer(71),
            "window": .record(["end": .integer(10), "start": .integer(0)])
        ])
        // Note the nested block's *first* line loses its indent: the
        // recursive call trims whitespace off both ends of its own output,
        // so only the second key onward keeps the two-space pad.
        XCTAssertEqual(
            value.prettyMultiline(),
            "atl: 71\nwindow: \nend: 10\n  start: 0"
        )
    }

    func testPrettyMultilineFallsBackToHumanReadableForScalars() {
        XCTAssertEqual(FactValue.integer(5).prettyMultiline(), "5")
        XCTAssertEqual(FactValue.integer(5).prettyMultiline(indent: 2), "    5")
    }

    // MARK: - Tool-result envelope

    private func envelope(_ value: FactValue) -> [String: Any] {
        let json = value.toToolResultJSON()
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("not decodable JSON: \(json)")
            return [:]
        }
        return object
    }

    func testSuccessEnvelopeCarriesTheValueAndNoMissingReason() {
        let env = envelope(.integer(62))
        XCTAssertEqual(env["value"] as? Int, 62)
        XCTAssertNil(
            env["missingReason"],
            "a missingReason key on a successful result reads as absence to the model"
        )
        XCTAssertEqual(env["confidence"] as? String, "high")
        XCTAssertNotNil(env["asOf"])
    }

    func testMissingEnvelopeNullsTheValueAndNamesTheReason() {
        let env = envelope(.missing(reason: .sensorDropout))
        XCTAssertTrue(env["value"] is NSNull)
        XCTAssertEqual(env["missingReason"] as? String, "sensorDropout")
        XCTAssertNil(env["detail"])
    }

    func testMissingEnvelopeIncludesDetailWhenGiven() {
        let env = envelope(.missing(reason: .outOfRange, detail: "before first session"))
        XCTAssertEqual(env["detail"] as? String, "before first session")
    }

    func testEnvelopePreservesScalarTypes() {
        XCTAssertEqual(envelope(.string("elevated"))["value"] as? String, "elevated")
        XCTAssertEqual(envelope(.double(4.5))["value"] as? Double, 4.5)
        XCTAssertEqual(envelope(.boolean(true))["value"] as? Bool, true)
        XCTAssertEqual(envelope(.durationSec(90))["value"] as? Int, 90)
        XCTAssertEqual(envelope(.date(Date(timeIntervalSince1970: 0)))["value"] as? String,
                       "1970-01-01T00:00:00Z")
    }

    func testEnvelopeCarriesListsAndRecordsStructurally() {
        let list = envelope(.list([.integer(1), .integer(2)]))["value"] as? [Any]
        XCTAssertEqual(list?.count, 2)

        let record = envelope(.record(["atl": .integer(71)]))["value"] as? [String: Any]
        XCTAssertEqual(record?["atl"] as? Int, 71)
    }

    func testNestedMissingCarriesItsOwnEnvelope() {
        // Field-level absence inside a composite: the model has to be able
        // to see that `ctl` specifically is missing, not that the whole
        // record failed.
        let record = envelope(.record([
            "atl": .integer(71),
            "ctl": .missing(reason: .notYetComputed)
        ]))["value"] as? [String: Any]
        XCTAssertEqual(record?["atl"] as? Int, 71)
        let nested = record?["ctl"] as? [String: Any]
        XCTAssertEqual(nested?["missingReason"] as? String, "notYetComputed")
        XCTAssertTrue(nested?["value"] is NSNull)
    }

    func testEnvelopeKeysAreSorted() {
        // Deterministic ordering keeps tool_result payloads inside the
        // cached prompt prefix across retries.
        let json = FactValue.missing(reason: .notRecorded, detail: "d").toToolResultJSON()
        let keyOrder = ["\"asOf\"", "\"confidence\"", "\"detail\"", "\"missingReason\"", "\"value\""]
        let positions = keyOrder.compactMap { json.range(of: $0)?.lowerBound }
        XCTAssertEqual(positions.count, keyOrder.count, json)
        XCTAssertEqual(positions, positions.sorted(), json)
    }

    func testBothJSONEntryPointsAgree() {
        // `toolResultJSON` (Encodable path) and `toToolResultJSON`
        // (JSONSerialization path) exist for different providers and must
        // not drift apart.
        let values: [FactValue] = [
            .integer(62),
            .double(4.5),
            .string("elevated"),
            .boolean(false),
            .durationSec(90),
            .missing(reason: .rateLimited, detail: "asked three times"),
            .list([.integer(1), .string("a")]),
            .record(["atl": .integer(71), "note": .string("x")])
        ]
        for value in values {
            let a = strippingTimestamp(value.toolResultJSON)
            let b = strippingTimestamp(value.toToolResultJSON())
            XCTAssertEqual(a, b, "entry points disagree for \(value.humanReadable)")
        }
    }

    /// `asOf` is stamped with `Date()` at call time, so the two entry
    /// points can legitimately differ by a second. Everything else must match.
    private func strippingTimestamp(_ json: String) -> String {
        json.replacingOccurrences(
            of: "\"asOf\":\"[^\"]*\"",
            with: "\"asOf\":\"?\"",
            options: .regularExpression
        )
    }

    func testEnvelopeIsAlwaysValidJSON() throws {
        let values: [FactValue] = [
            .integer(0),
            .string("quote \" and \\ backslash"),
            .list([.missing(reason: .internalError)]),
            .record([:]),
            .list([])
        ]
        for value in values {
            let json = value.toToolResultJSON()
            let data = json.data(using: .utf8)
            XCTAssertNotNil(data, json)
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: XCTUnwrap(data)),
                "invalid JSON: \(json)"
            )
        }
    }
}
