@testable import Emuqu
import XCTest

/// A value a newer build wrote must not make this build drop the whole
/// session, index entry or marker set holding it. Each enum case this build
/// does not know reads as its fallback, and where a re-save would write that
/// fallback over the newer value, the payload reads as newer than this build
/// so the archive refuses the re-write.
final class ForwardCompatibleDecodingTests: XCTestCase {
    // MARK: - Nested enums

    func testUnknownSleepBoundarySourceReadsAsRecordingBounds() throws {
        let decoded = try JSONDecoder().decode([SleepBoundarySource].self, from: Data(#"["HealthKit", "Future Source"]"#.utf8))
        XCTAssertEqual(decoded, [.healthKit, .recordingBounds])
    }

    func testUnknownRecordingModeReadsAsStreaming() throws {
        let decoded = try JSONDecoder().decode([DeviceProvenance.RecordingMode].self, from: Data(#"["imported", "future_mode"]"#.utf8))
        XCTAssertEqual(decoded, [.imported, .streaming])
    }

    func testUnknownScoreFactorImpactReadsAsNeutral() throws {
        let decoded = try JSONDecoder().decode(
            [RecoveryScoreCalculator.ScoreFactor.Impact].self, from: Data(#"["negative", "mixed"]"#.utf8)
        )
        XCTAssertEqual(decoded, [.negative, .neutral])
    }

    /// One beat's unknown classification must not fail the flag array: the
    /// beat keeps its artifact flag and reads as unclassified.
    func testUnknownArtifactTypeReadsAsUnclassified() throws {
        let json = #"[{"isArtifact":true,"type":"ectopic","confidence":0.9,"corrected":false},"#
            + #"{"isArtifact":true,"type":"futureKind","confidence":0.7,"corrected":true}]"#
        let flags = try JSONDecoder().decode([ArtifactFlags].self, from: Data(json.utf8))
        XCTAssertEqual(flags.map(\.type), [.ectopic, nil])
        XCTAssertEqual(flags.map(\.isArtifact), [true, true])
        XCTAssertEqual(flags.last?.corrected, true)
    }

    // MARK: - Sessions

    private func provenance() -> DeviceProvenance {
        DeviceProvenance(
            deviceId: "Polar H10 TEST", deviceModel: "Polar H10", firmwareVersion: nil, recordingMode: .streaming,
            appVersion: "1.0", osVersion: "18.0", capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func sleep() -> SleepData {
        SleepData(
            date: Date(timeIntervalSince1970: 1_700_000_000), totalSleepMinutes: 420, inBedMinutes: 450,
            awakeMinutes: 30, sleepEfficiency: 0.93, boundarySource: .healthKit
        )
    }

    /// The session encoded, with `edit` applied to its JSON object.
    private func sessionJSON(_ session: HRVSession, edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testSessionWithKnownNestedCasesReadsAsCurrent() throws {
        var session = HRVSession(deviceProvenance: provenance())
        session.sleepSnapshot = sleep()
        let decoded = try JSONDecoder().decode(HRVSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.sourceSchemaVersion, HRVSession.currentSchemaVersion)
    }

    func testSessionWithUnknownRecordingModeDecodesAndReadsAsNewer() throws {
        let json = try sessionJSON(HRVSession(deviceProvenance: provenance())) { object in
            var nested = object["deviceProvenance"] as? [String: Any] ?? [:]
            nested["recordingMode"] = "future_mode"
            object["deviceProvenance"] = nested
        }
        let decoded = try JSONDecoder().decode(HRVSession.self, from: json)
        XCTAssertEqual(decoded.deviceProvenance?.recordingMode, .streaming)
        XCTAssertEqual(decoded.sourceSchemaVersion, HRVSession.currentSchemaVersion + 1)
    }

    func testSessionWithUnknownSleepBoundarySourceDecodesAndReadsAsNewer() throws {
        var session = HRVSession()
        session.sleepSnapshot = sleep()
        let json = try sessionJSON(session) { object in
            var nested = object["sleepSnapshot"] as? [String: Any] ?? [:]
            nested["boundarySource"] = "Future Source"
            object["sleepSnapshot"] = nested
        }
        let decoded = try JSONDecoder().decode(HRVSession.self, from: json)
        XCTAssertEqual(decoded.sleepSnapshot?.boundarySource, .recordingBounds)
        XCTAssertEqual(decoded.sourceSchemaVersion, HRVSession.currentSchemaVersion + 1)
    }

    // MARK: - Index entries

    private func entryJSON(hrvDataQuality: String) -> Data {
        let json = #"{"schemaVersion":1,"sessionId":"\#(UUID().uuidString)","date":0,"#
            + #""fileHash":"h","filePath":"p","hrvDataQuality":"\#(hrvDataQuality)"}"#
        return Data(json.utf8)
    }

    func testIndexEntryWithUnknownDataQualityReadsAsNewer() throws {
        let entry = try JSONDecoder().decode(SessionArchiveEntry.self, from: entryJSON(hrvDataQuality: "futureQuality"))
        XCTAssertEqual(entry.hrvDataQuality, .insufficient)
        XCTAssertTrue(entry.isFromNewerSchema, "A re-save would otherwise write .insufficient over the newer value")
    }

    func testIndexEntryWithKnownDataQualityReadsAsStated() throws {
        let entry = try JSONDecoder().decode(SessionArchiveEntry.self, from: entryJSON(hrvDataQuality: "insufficient"))
        XCTAssertFalse(entry.isFromNewerSchema)
    }

    // MARK: - Settings

    /// A marker a newer build added is dropped on its own; the known ones
    /// stay, so the backup still leaves out the values Apple Health filled.
    func testUnknownHealthProfileFieldKeepsTheKnownMarkers() throws {
        let json = #"{"profileFieldsFromHealth":["birthday","futureField","bodyWeight"]}"#
        let settings = try JSONDecoder().decode(UserSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.profileFieldsFromHealth, [.birthday, .bodyWeight])
    }
}
