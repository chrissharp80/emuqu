@testable import Emuqu
import XCTest

/// `AssistantChatView` wraps each bubble in `.equatable()`, and passes
/// `onRegenerate` only for the last assistant turn. Equality therefore has to
/// notice an action appearing or disappearing, or the long-press menu goes
/// stale while the turn text is unchanged.
@MainActor
final class ChatBubbleEquatableTests: XCTestCase {
    private let turn = ChatTurn(role: .assistant, text: "Your HRV is up this morning.")

    func testTheSameTurnWithTheSameActionsIsEqual() {
        XCTAssertEqual(ChatBubble(turn: turn, onCopy: {}), ChatBubble(turn: turn, onCopy: {}))
    }

    /// The defect this pins: comparing the turn alone kept the previous
    /// bubble's menu when Regenerate moved to a newer turn.
    func testAnActionAppearingMakesTheBubbleUnequal() {
        XCTAssertNotEqual(ChatBubble(turn: turn), ChatBubble(turn: turn, onRegenerate: {}))
        XCTAssertNotEqual(ChatBubble(turn: turn, onShare: {}), ChatBubble(turn: turn))
    }

    func testADifferentTurnIsUnequal() {
        let other = ChatTurn(role: .assistant, text: "Different text.")
        XCTAssertNotEqual(ChatBubble(turn: turn), ChatBubble(turn: other))
    }
}
