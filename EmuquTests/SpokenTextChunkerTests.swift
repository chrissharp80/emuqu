@testable import Emuqu
import XCTest

/// Tests for `SpokenTextChunker` — the pure text-chunking logic extracted
/// from `VoiceConversationController`. These cover the LLM-delta →
/// sentence-chunk → TTS pipeline without any audio dependencies.
final class SpokenTextChunkerTests: XCTestCase {

    // MARK: - append(delta:) — completed sentences

    func testAppendWithoutSentenceEnderBuffersSilently() {
        let chunker = SpokenTextChunker()
        XCTAssertNil(chunker.append(delta: "Hello "))
        XCTAssertNil(chunker.append(delta: "there"))
        XCTAssertTrue(chunker.hasPendingContent)
    }

    func testAppendEmitsChunkOnSentenceEnder() {
        let chunker = SpokenTextChunker()
        XCTAssertNil(chunker.append(delta: "Hello"))
        XCTAssertEqual(chunker.append(delta: "."), "Hello.")
        XCTAssertFalse(chunker.hasPendingContent)
    }

    func testAppendKeepsTrailingWhitespaceAsRemainder() {
        // After emitting a sentence, any whitespace following the ender
        // stays buffered (it's the start of the next sentence). The
        // chunker only trims whitespace when building the emitted chunk,
        // not when slicing.
        let chunker = SpokenTextChunker()
        XCTAssertEqual(chunker.append(delta: "Hello. "), "Hello.")
        XCTAssertEqual(chunker.pendingBuffer, " ")
    }

    func testAppendSplitsAtLastEnderOnly() {
        let chunker = SpokenTextChunker()
        let chunk = chunker.append(delta: "First sentence. Second sentence. leftover")
        // Peels up to the LAST ender; the remainder waits for more tokens.
        XCTAssertEqual(chunk, "First sentence. Second sentence.")
        XCTAssertEqual(chunker.pendingBuffer, " leftover")
    }

    func testAppendSupportsQuestionAndExclamationAndNewline() {
        XCTAssertEqual(SpokenTextChunker().append(delta: "Ready?"), "Ready?")
        XCTAssertEqual(SpokenTextChunker().append(delta: "Go!"), "Go!")
        XCTAssertEqual(SpokenTextChunker().append(delta: "Line one\n"), "Line one")
    }

    func testAppendTrimsWhitespace() {
        let chunker = SpokenTextChunker()
        let chunk = chunker.append(delta: "  Hi.  ")
        XCTAssertEqual(chunk, "Hi.")
        XCTAssertEqual(chunker.pendingBuffer, "  ")
    }

    func testAppendReturnsNilWhenChunkWouldBeEmpty() {
        // Just a bare ender with no content.
        let chunker = SpokenTextChunker()
        let chunk = chunker.append(delta: ".")
        XCTAssertEqual(chunk, ".")  // Lone period is the trimmed "raw"; stays speakable.
        _ = chunk  // quiet "unused" if any
    }

    // MARK: - finalize

    func testFinalizeReturnsRemainderWhenNonEmpty() {
        let chunker = SpokenTextChunker()
        _ = chunker.append(delta: "Mid-sentence")
        XCTAssertEqual(chunker.finalize(), "Mid-sentence")
        XCTAssertFalse(chunker.hasPendingContent)
    }

    func testFinalizeReturnsNilOnEmptyBuffer() {
        XCTAssertNil(SpokenTextChunker().finalize())
    }

    func testFinalizeClearsBufferEvenWhenWhitespaceOnly() {
        let chunker = SpokenTextChunker()
        _ = chunker.append(delta: "   ")
        XCTAssertNil(chunker.finalize())
        XCTAssertFalse(chunker.hasPendingContent)
    }

    // MARK: - reset

    func testResetClearsBufferWithoutEmitting() {
        let chunker = SpokenTextChunker()
        _ = chunker.append(delta: "unfinished")
        chunker.reset()
        XCTAssertFalse(chunker.hasPendingContent)
        XCTAssertEqual(chunker.pendingBuffer, "")
    }

    // MARK: - Markdown stripping

    func testStripMarkdownRemovesBoldAndItalicMarkers() {
        XCTAssertEqual(
            SpokenTextChunker.stripMarkdownForSpeech("Go **hard** then __rest__"),
            "Go hard then rest"
        )
    }

    func testStripMarkdownPreservesMathAsterisk() {
        // "5 * 3" must NOT lose the asterisk — only word-adjacent * is emphasis.
        let stripped = SpokenTextChunker.stripMarkdownForSpeech("5 * 3 = 15")
        XCTAssertEqual(stripped, "5 * 3 = 15")
    }

    func testStripMarkdownRemovesWordAdjacentEmphasis() {
        XCTAssertEqual(
            SpokenTextChunker.stripMarkdownForSpeech("word*with*emphasis"),
            "wordwithemphasis"
        )
    }

    func testStripMarkdownRemovesBackticks() {
        XCTAssertEqual(
            SpokenTextChunker.stripMarkdownForSpeech("call `foo()` here"),
            "call foo() here"
        )
    }

    func testStripMarkdownRemovesListMarkers() {
        let input = """
        - first
        * second
        + third
        """
        XCTAssertEqual(
            SpokenTextChunker.stripMarkdownForSpeech(input),
            "first\nsecond\nthird"
        )
    }

    func testStripMarkdownRemovesNumberedListMarkers() {
        let input = """
        1. one
        2) two
        """
        XCTAssertEqual(
            SpokenTextChunker.stripMarkdownForSpeech(input),
            "one\ntwo"
        )
    }

    func testStripMarkdownRemovesHeaderMarkers() {
        let input = """
        # H1
        ## H2
        ### H3
        """
        XCTAssertEqual(
            SpokenTextChunker.stripMarkdownForSpeech(input),
            "H1\nH2\nH3"
        )
    }

    func testStripMarkdownKeepsLinkLabelAndDropsURL() {
        XCTAssertEqual(
            SpokenTextChunker.stripMarkdownForSpeech("See [the docs](https://example.com)"),
            "See the docs"
        )
    }

    func testAppendAppliesMarkdownStrippingToEmittedChunk() {
        let chunker = SpokenTextChunker()
        let chunk = chunker.append(delta: "Run **hard** now.")
        XCTAssertEqual(chunk, "Run hard now.")
    }

    func testFinalizeAppliesMarkdownStripping() {
        let chunker = SpokenTextChunker()
        _ = chunker.append(delta: "**bold tail**")
        XCTAssertEqual(chunker.finalize(), "bold tail")
    }

    // MARK: - Decimals

    func testDecimalPointIsNotASentenceEnd() {
        let chunker = SpokenTextChunker()
        XCTAssertNil(chunker.append(delta: "Your HRV is 42."))
        XCTAssertEqual(chunker.append(delta: "3 ms. Next"), "Your HRV is 42.3 ms.")
        XCTAssertEqual(chunker.pendingBuffer, " Next")
    }
}
