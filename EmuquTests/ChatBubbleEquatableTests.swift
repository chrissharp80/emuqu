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

/// The bubble parses replies as inline-only Markdown, which leaves block syntax
/// as typed. On-device replies arrived with `## Recovery Score Breakdown` and
/// the `#` marks showed in the bubble; `ChatMarkdown` turns headings into bold
/// lines and leaves everything else alone.
@MainActor
final class ChatMarkdownTests: XCTestCase {
    func testHeadingsOfEveryLevelBecomeBoldLines() {
        XCTAssertEqual(ChatMarkdown.displayText("## Recovery Score Breakdown"), "**Recovery Score Breakdown**")
        XCTAssertEqual(ChatMarkdown.displayText("### Probable Causes"), "**Probable Causes**")
        XCTAssertEqual(ChatMarkdown.displayText("# Title"), "**Title**")
        XCTAssertEqual(ChatMarkdown.displayText("###### Six"), "**Six**")
    }

    func testClosingHashesIndentAndExistingBoldAreDropped() {
        XCTAssertEqual(ChatMarkdown.displayText("## Sleep ##"), "**Sleep**")
        XCTAssertEqual(ChatMarkdown.displayText("   ## Indented"), "**Indented**")
        XCTAssertEqual(ChatMarkdown.displayText("## **Already bold**"), "**Already bold**")
        XCTAssertEqual(ChatMarkdown.displayText("##"), "")
    }

    func testNonHeadingsAreUnchanged() {
        for line in ["#hashtag", "####### seven", "    ## code indent", "C# is a language", "Score: #1", "- item", "1. item"] {
            XCTAssertEqual(ChatMarkdown.displayText(line), line)
        }
    }

    func testBoldAndListsSurviveAroundAHeading() {
        let reply = "## Summary\nYou slept **7 h**.\n- HRV up\n- RHR down"
        XCTAssertEqual(ChatMarkdown.displayText(reply), "**Summary**\nYou slept **7 h**.\n- HRV up\n- RHR down")
    }

    func testHeadingsInsideCodeFencesAreLeftAlone() {
        let reply = "```\n## not a heading\n```\n## Heading"
        XCTAssertEqual(ChatMarkdown.displayText(reply), "```\n## not a heading\n```\n**Heading**")
    }

    /// The converted text still parses, and the rendered characters carry no
    /// `#` marks while bold keeps its emphasis.
    func testRenderedHeadingShowsNoHashMarks() throws {
        let parsed = try AttributedString(
            markdown: ChatMarkdown.displayText("## Recovery\nYour **HRV** rose."),
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let plain = String(parsed.characters)
        XCTAssertEqual(plain, "Recovery\nYour HRV rose.")
        let heading = try XCTUnwrap(parsed.range(of: "Recovery"))
        XCTAssertEqual(parsed[heading].inlinePresentationIntent, .stronglyEmphasized)
    }
}
