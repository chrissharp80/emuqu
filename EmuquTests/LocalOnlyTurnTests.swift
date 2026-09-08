@testable import Emuqu
import XCTest

/// Refused medical questions must never reach a provider — including later.
///
/// ## The defect this pins
///
/// `MedicalQueryGuard` refuses a medical question
/// locally, with no provider call, and `.github/SECURITY.md` promises such
/// questions never reach the network. The refusal was true of that request and
/// false of the conversation: the refused turn was persisted like any other, so
/// the NEXT ordinary message assembled it into the outbound history and sent it
/// to the hosted provider.
///
/// The guard stopped one request. The transcript leaked it on the following
/// one — which is worse than not having the guard, because the promise was
/// documented and users could reasonably rely on it.
///
/// ## Why a flag on the turn
///
/// There is more than one outbound path: history assembly and summarisation
/// today, and any export or diagnostic bundle later. A filter applied at each
/// call site is one someone will forget at the next one. The exposure rule
/// travels with the data.
@MainActor
final class LocalOnlyTurnTests: XCTestCase {
    private func turn(_ role: ChatTurn.Role, _ text: String, localOnly: Bool = false) -> ChatTurn {
        ChatTurn(role: role, text: text, localOnly: localOnly)
    }

    private let secret = "do I have AFib?"

    // MARK: - The exposure policy exists and defaults to sendable

    func testTurnsAreSendableByDefault() {
        XCTAssertFalse(turn(.user, "how did I sleep?").localOnly,
                       "An ordinary turn must remain sendable")
    }

    /// Transcripts written before this field existed must still decode, and
    /// must not be silently reclassified in either direction.
    func testTranscriptsWrittenBeforeTheFieldDecodeAsSendable() throws {
        let legacy = Data("""
        {"id":"\(UUID().uuidString)","role":"user","text":"hello",
         "createdAt":\(Date().timeIntervalSinceReferenceDate)}
        """.utf8)
        let decoded = try JSONDecoder().decode(ChatTurn.self, from: legacy)
        XCTAssertFalse(decoded.localOnly, "A turn with no policy must decode, defaulting to sendable")
        XCTAssertEqual(decoded.text, "hello")
    }

    func testThePolicySurvivesARoundTripThroughStorage() throws {
        let original = turn(.user, secret, localOnly: true)
        let decoded = try JSONDecoder().decode(
            ChatTurn.self, from: try JSONEncoder().encode(original)
        )
        XCTAssertTrue(decoded.localOnly,
                      "The policy must survive persistence — the leak happened on a LATER turn")
    }

    // MARK: - The outbound path withholds them

    func testRefusedTurnsAreWithheldFromTheOutboundHistory() {
        let history = [
            turn(.user, secret, localOnly: true),
            turn(.assistant, "I can't answer that.", localOnly: true),
            turn(.user, "how did I sleep?"),
            turn(.assistant, "Seven hours.")
        ]
        let (kept, dropped) = AssistantViewModel.truncateForSend(history, provider: .anthropic)
        let outbound = (kept + dropped).map { $0.text }.joined(separator: "\n")
        XCTAssertFalse(outbound.contains(secret),
                       "Refused medical text reached the outbound history")
        XCTAssertTrue(kept.contains { $0.text == "how did I sleep?" },
                      "Ordinary turns must still be sent")
    }

    /// Withheld, not truncated. `dropped` feeds summarisation, so reporting a
    /// local-only turn as dropped would send it in a different shape.
    func testWithheldTurnsAreNotReportedAsDropped() {
        let history = [
            turn(.user, secret, localOnly: true),
            turn(.assistant, "I can't answer that.", localOnly: true)
        ]
        let (kept, dropped) = AssistantViewModel.truncateForSend(history, provider: .anthropic)
        XCTAssertTrue(kept.isEmpty)
        XCTAssertTrue(dropped.isEmpty, "A withheld turn must not be handed to the summariser")
    }

    /// A long conversation truncates by token budget. A local-only turn must be
    /// excluded regardless of where the window happens to fall.
    func testExclusionHoldsUnderTruncation() {
        var history: [ChatTurn] = [turn(.user, secret, localOnly: true)]
        for i in 0 ..< 400 {
            history.append(turn(.user, "message \(i) " + String(repeating: "padding ", count: 40)))
            history.append(turn(.assistant, "reply \(i)"))
        }
        let (kept, dropped) = AssistantViewModel.truncateForSend(history, provider: .anthropic)
        let leaked = (kept + dropped).contains { $0.text.contains(self.secret) }
        XCTAssertFalse(leaked,
                       "Refused text survived truncation")
        XCTAssertFalse(kept.isEmpty, "Truncation must still keep recent ordinary turns")
    }

    /// The guard must not become a way to silently drop ordinary history.
    func testOrdinaryHistoryIsUnaffected() {
        let history = (0 ..< 6).map { turn($0.isMultiple(of: 2) ? .user : .assistant, "turn \($0)") }
        let (kept, dropped) = AssistantViewModel.truncateForSend(history, provider: .anthropic)
        XCTAssertEqual(kept.count + dropped.count, history.count,
                       "No ordinary turn may be lost")
    }
}
