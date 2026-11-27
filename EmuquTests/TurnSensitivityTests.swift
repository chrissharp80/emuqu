@testable import Emuqu
import XCTest

/// A reply produced with context only some providers may see carries that
/// context to whatever its text is sent to next. Apple's on-device render has
/// the street the user is on at any time, a cloud provider only during a
/// workout, so an Apple reply quoting the street outside one is marked
/// (`ChatTurn.sensitivity`) and kept from every provider not allowed the
/// street: in later history after a provider switch, a routed tier or a
/// fallback, in the summary any provider reads, and in memory facts taken
/// from it.
@MainActor
final class TurnSensitivityTests: XCTestCase {
    private let street = "You're on Main St near 2nd Ave in Springfield."

    private func exchange() -> [ChatTurn] {
        var reply = ChatTurn(role: .assistant, text: street, providerID: .apple)
        reply.sensitivity = .ambientLocation
        return [ChatTurn(role: .user, text: "Where am I?"), reply, ChatTurn(role: .user, text: "How did I sleep?")]
    }

    func testOnlyAppleIsSentAReplyCarryingTheStreet() {
        for provider in ProviderID.allCases {
            let kept = AssistantViewModel.truncateForSend(exchange(), provider: provider).kept
            XCTAssertEqual(kept.contains { $0.text == street }, provider == .apple, "\(provider.rawValue)")
            XCTAssertEqual(kept.last?.text, "How did I sleep?", "\(provider.rawValue) lost the question")
        }
    }

    func testTheRuleCoversEveryProvider() {
        for provider in ProviderID.allCases {
            XCTAssertEqual(TurnSensitivity.ambientLocation.allows(provider), provider == .apple, provider.rawValue)
            XCTAssertTrue(ChatTurn(role: .assistant, text: "ok").maySend(to: provider))
        }
        var refused = ChatTurn(role: .assistant, text: "no", localOnly: true)
        XCTAssertFalse(refused.maySend(to: .apple))
        refused.localOnly = false
        refused.sensitivity = .ambientLocation
        XCTAssertFalse(refused.maySendToEveryProvider)
    }

    func testTheMarkSurvivesStorageAndAnOldTranscriptHasNone() throws {
        let marked = try XCTUnwrap(exchange().dropFirst().first)
        let decoded = try JSONDecoder().decode(ChatTurn.self, from: JSONEncoder().encode(marked))
        XCTAssertEqual(decoded.sensitivity, .ambientLocation)
        let legacy = Data("""
        {"id":"\(UUID().uuidString)","role":"assistant","text":"hi","createdAt":\(Date().timeIntervalSinceReferenceDate)}
        """.utf8)
        XCTAssertNil(try JSONDecoder().decode(ChatTurn.self, from: legacy).sensitivity)
    }

    /// The summary is sent to whichever provider answers next, so Apple's
    /// summary of its own history leaves the street out.
    func testTheSummaryLeavesOutWhatNotEveryProviderMaySee() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sensitivity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AssistantViewModel(
            services: ChatServices(.current),
            store: ConversationStore(fileURL: directory.appendingPathComponent("chat.json")),
            factsStore: UserFactsStore(fileURL: directory.appendingPathComponent("facts.json"))
        )
        let dropped = AssistantViewModel.truncateForSend(exchange(), provider: .apple).kept
        let prompt = model.summarizationPrompt(dropped)
        XCTAssertFalse(prompt.contains("Main St"))
        XCTAssertTrue(prompt.contains("Where am I?"))
    }

    /// A memory fact rides in every later system prompt, so none is taken
    /// from a reply not every provider may see.
    func testNoFactIsTakenFromAMarkedReply() {
        var turns = exchange()
        turns.removeLast()
        XCTAssertNil(AssistantTurnRouter.factExtractionExchange(in: turns, at: 1, completed: true))
        turns[1].sensitivity = nil
        XCTAssertEqual(AssistantTurnRouter.factExtractionExchange(in: turns, at: 1, completed: true)?.assistantText, street)
    }

    // MARK: - What marks a reply

    private func context(location: Bool, workout: Bool) -> AssistantContext {
        var context = AssistantContext(
            generatedAt: Date(), userProfile: profile(), today: nil, yesterday: nil, yesterdayDiagnostic: nil, recent: [],
            baselines: nil, trends7Day: nil, trends30Day: nil, analysisSummary: nil, recentWorkouts: []
        )
        if location {
            context.ambientLocation = AssistantContext.AmbientLocationSnapshot(
                road: "Main St", nearestCrossStreet: "2nd Ave", locality: "Springfield", subdivision: nil, administrativeArea: "IL",
                country: "United States", headingCardinal: nil, headingDegrees: nil, speedMS: nil, altitudeMeters: nil, accuracyMeters: nil, ageSeconds: 30
            )
        }
        if workout { context.liveWorkout = live() }
        return context
    }

    /// Only a render that shows the street outside a workout marks its reply:
    /// during a workout every consented provider may have the street.
    func testARenderMarksItsReplyOnlyWhenItShowsTheStreetOutsideAWorkout() {
        XCTAssertEqual(context(location: true, workout: false).sensitivity(ofRenderIncludingAmbientLocation: true), .ambientLocation)
        XCTAssertNil(context(location: true, workout: false).sensitivity(ofRenderIncludingAmbientLocation: false))
        XCTAssertNil(context(location: true, workout: true).sensitivity(ofRenderIncludingAmbientLocation: true))
        XCTAssertNil(context(location: false, workout: false).sensitivity(ofRenderIncludingAmbientLocation: true))
    }

    private func profile() -> AssistantContext.UserProfileSnapshot {
        AssistantContext.UserProfileSnapshot(
            age: 44, biologicalSex: "Male", fitnessLevel: "intermediate", vo2Max: 48.5, typicalSleepHours: 7.5, customTagNames: [],
            maxHR: 178, maxHRIsUserOverride: true, unitsPreference: "metric", onTrainingBreak: false, trainingBreakReason: nil,
            sleepIntegrationEnabled: true, trainingLoadIntegrationEnabled: true, comebackModeActive: false, comebackModeDayInWindow: nil,
            scoreAlgorithmVersion: "v3", scoreHistoryRecomputed: true
        )
    }

    private func live() -> AssistantContext.LiveWorkoutSnapshot {
        AssistantContext.LiveWorkoutSnapshot(
            sport: "Run", snapshotAt: Date(), sessionStartAt: Date().addingTimeInterval(-840), elapsedSeconds: 840, heartRate: 150, peakHR: 150, userMaxHR: 188,
            beatCount: 2_200, distanceMeters: 2_500, stepCount: 2_350, cadenceStepsPerMin: 168, elevationGainMeters: 18,
            alpha1: nil, alpha1Band: "Unknown", alpha1Status: "warmup", alpha1FitQualityR2: nil, strapConnected: true, strapSilentSec: nil,
            gpsFixCount: 84, gpsAccuracyMeters: 5, currentPaceSecPerKm: 330, currentSpeedMS: 2.9, powerWatts: nil, currentMETs: nil,
            recentSplitPaces: [328, 331], currentLatitude: nil, currentLongitude: nil, currentAltitudeMeters: nil,
            currentHeadingDegrees: nil, currentHeadingCardinal: nil, currentGradePercent: nil, unitsPreference: "metric", targetZone: nil
        )
    }
}
