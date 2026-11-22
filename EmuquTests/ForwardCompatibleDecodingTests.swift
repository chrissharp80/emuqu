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
        XCTAssertEqual(flags.map(\.holdsUnknownType), [false, true])
        let reencoded = try XCTUnwrap(String(data: JSONEncoder().encode(flags), encoding: .utf8))
        XCTAssertFalse(reencoded.contains("holdsUnknownType"), "The mark is not stored")
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

    /// Before, an unknown artifact type read as nil and an unknown impact as
    /// `.neutral` without marking the session, so a note or tag edit on this
    /// build wrote nil and `.neutral` over the newer build's values.
    func testSessionWithUnknownArtifactTypeDecodesAndReadsAsNewer() throws {
        var session = HRVSession()
        session.artifactFlags = [ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 0.9)]
        let json = try sessionJSON(session) { object in
            var flags = object["artifactFlags"] as? [[String: Any]] ?? []
            flags[0]["type"] = "futureKind"
            object["artifactFlags"] = flags
        }
        let decoded = try JSONDecoder().decode(HRVSession.self, from: json)
        XCTAssertEqual(decoded.artifactFlags?.first?.isArtifact, true)
        XCTAssertNil(decoded.artifactFlags?.first?.type)
        XCTAssertEqual(decoded.sourceSchemaVersion, HRVSession.currentSchemaVersion + 1)
    }

    func testSessionWithUnknownScoreFactorImpactDecodesAndReadsAsNewer() throws {
        let factor = RecoveryScoreCalculator.ScoreFactor(label: "HRV", detail: "d", score: 70, weight: 0.5, impact: .positive)
        var session = HRVSession()
        session.scoreBreakdown = RecoveryScoreCalculator.ScoreBreakdown(compositeScore: 70, tier: 1, factors: [factor], penalties: [])
        let known = try JSONDecoder().decode(HRVSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(known.sourceSchemaVersion, HRVSession.currentSchemaVersion, "A known impact leaves the session current")
        let json = try sessionJSON(session) { object in
            var breakdown = object["scoreBreakdown"] as? [String: Any] ?? [:]
            var factors = breakdown["factors"] as? [[String: Any]] ?? []
            factors[0]["impact"] = "mixed"
            breakdown["factors"] = factors
            object["scoreBreakdown"] = breakdown
        }
        let decoded = try JSONDecoder().decode(HRVSession.self, from: json)
        XCTAssertEqual(decoded.scoreBreakdown?.factors.first?.impact, .neutral)
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
