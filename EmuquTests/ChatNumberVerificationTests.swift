@testable import Emuqu
import XCTest

/// A number in a streamed reply is checked before it is shown, on the same
/// whole sentences the medical scrub publishes, so the user never reads a
/// value that changes afterwards and the saved turn is what was shown. A
/// correction is reported to the next prompt only if the text stays.
@MainActor
final class ChatNumberVerificationTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        MetricsVerifier.clearCorrections()
    }

    override func tearDown() async throws {
        MetricsVerifier.clearCorrections()
        try await super.tearDown()
    }

    private func live(heartRate: Int) -> AssistantContext.LiveWorkoutSnapshot {
        AssistantContext.LiveWorkoutSnapshot(
            sport: "Run", snapshotAt: Date(), sessionStartAt: Date().addingTimeInterval(-840), elapsedSeconds: 840, heartRate: heartRate, peakHR: heartRate, userMaxHR: 188,
            beatCount: 2_200, distanceMeters: 2_500, stepCount: 2_350, cadenceStepsPerMin: 168, elevationGainMeters: 18,
            alpha1: nil, alpha1Band: "Unknown", alpha1Status: "warmup", alpha1FitQualityR2: nil, strapConnected: true, strapSilentSec: nil,
            gpsFixCount: 84, gpsAccuracyMeters: 5, currentPaceSecPerKm: 330, currentSpeedMS: 2.9, powerWatts: nil, currentMETs: nil,
            recentSplitPaces: [328, 331], currentLatitude: nil, currentLongitude: nil, currentAltitudeMeters: nil,
            currentHeadingDegrees: nil, currentHeadingCardinal: nil, currentGradePercent: nil, unitsPreference: "metric", targetZone: nil
        )
    }

    private func viewModel(in directory: URL) -> AssistantViewModel {
        AssistantViewModel(
            services: ChatServices(.current),
            store: ConversationStore(fileURL: directory.appendingPathComponent("chat.json")),
            factsStore: UserFactsStore(fileURL: directory.appendingPathComponent("facts.json"))
        )
    }

    private func streamed(_ deltas: [String], rewind: Bool) async throws -> (shown: [String], saved: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChatNumbers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = viewModel(in: directory)
        let turn = ChatTurn(role: .assistant, text: "")
        model.turns.append(turn)
        let snapshot = live(heartRate: 162)
        let buffer = StreamTextBuffer(owner: model, turnID: turn.id) {
            var state = model.services.verifiedAppState
            state.liveWorkout = snapshot
            return state
        }
        var shown: [String] = []
        for delta in deltas {
            try await Task.sleep(for: .milliseconds(40))
            buffer.append(chunk: delta, thisRoundIsEmpty: true)
            shown.append(model.turns.first { $0.id == turn.id }?.text ?? "")
        }
        buffer.flush(force: true, thisRoundIsEmpty: true)
        if rewind { buffer.rewindToRoundStart() }
        buffer.commitCorrections()
        return (shown, model.turns.first { $0.id == turn.id }?.text ?? "")
    }

    func testAWrongNumberIsCorrectedBeforeItIsShown() async throws {
        let result = try await streamed(["Your HR is 1", "50 bpm, nice and steady", ". Hold it", " there."], rewind: false)
        for text in result.shown {
            XCTAssertFalse(text.contains("150 bpm"), "Shown before it was checked: \(text)")
        }
        XCTAssertEqual(result.saved, "Your HR is 162 bpm, nice and steady. Hold it there.")
        XCTAssertTrue(result.shown.allSatisfy { result.saved.hasPrefix($0) }, "Shown text changed after display")
        XCTAssertTrue(MetricsVerifier.consumePendingCorrectionsBlock()?.contains("HR=150 bpm") == true)
    }

    func testRewoundTextReportsNoCorrection() async throws {
        _ = try await streamed(["Your HR is 150 bpm.", " Let me check."], rewind: true)
        XCTAssertNil(MetricsVerifier.consumePendingCorrectionsBlock())
    }

    /// Voice and chat read the live values from one source, the broker the
    /// model's live tools read, so a spoken and a saved number agree.
    func testVoiceAndChatCheckAgainstTheSameLiveSource() {
        let broker = AppDependencies.current.assistant.liveWorkoutBroker
        broker.publish(live(heartRate: 171))
        defer { broker.clear() }
        XCTAssertEqual(VoiceServices(.current).verifiedAppState.liveWorkout?.heartRate, 171)
        XCTAssertEqual(ChatServices(.current).verifiedAppState.liveWorkout?.heartRate, 171)
    }

    /// The broker carries the drift, so a drift claim is checked in chat too.
    func testADriftClaimIsCheckedAgainstTheBroker() {
        var snapshot = live(heartRate: 162)
        snapshot.liveHRDriftPercent = 3.0
        XCTAssertEqual(MetricsVerifier.verify("Your HR drift is 9%.", againstLive: snapshot).map(\.metric), ["hr_drift_percent"])
    }
}
