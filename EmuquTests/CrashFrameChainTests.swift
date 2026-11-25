@testable import Emuqu
import XCTest

/// The frame walk the crash signal handler writes into the crash log
/// (`emuqu_walk_frame_chain`), run on a hand-built stack: it follows the
/// chain up to its end and stops at a record that loops back, leaves the
/// stack, or is misaligned, instead of faulting or spinning in a handler
/// that must finish.
final class CrashFrameChainTests: XCTestCase {
    private let wordCount = 32
    private lazy var stack: UnsafeMutablePointer<UInt> = {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: wordCount * MemoryLayout<UInt>.size, alignment: 16)
        let words = raw.bindMemory(to: UInt.self, capacity: wordCount)
        words.initialize(repeating: 0, count: wordCount)
        return words
    }()

    override func tearDown() {
        stack.deinitialize(count: wordCount)
        UnsafeMutableRawPointer(stack).deallocate()
        super.tearDown()
    }

    private func address(_ word: Int) -> UInt { UInt(bitPattern: stack + word) }
    private var bounds: Range<UInt> { address(0) ..< address(wordCount) }

    /// A record at `word`: the caller's record, then the return address.
    private func record(at word: Int, next: UInt, returning returnAddress: UInt) {
        stack[word] = next
        stack[word + 1] = returnAddress
    }

    func testTheWholeChainIsWalkedInOrder() {
        record(at: 0, next: address(4), returning: 0x1000)
        record(at: 4, next: address(8), returning: 0x2000)
        record(at: 8, next: 0, returning: 0x3000)
        XCTAssertEqual(CrashLogManager.frameChain(from: address(0), stack: bounds, max: 16), [0x1000, 0x2000, 0x3000])
    }

    func testALinkBackDownTheStackEndsTheWalk() {
        record(at: 0, next: address(4), returning: 0x1000)
        record(at: 4, next: address(0), returning: 0x2000)
        XCTAssertEqual(CrashLogManager.frameChain(from: address(0), stack: bounds, max: 16), [0x1000, 0x2000])
    }

    func testARecordOffTheStackIsNotRead() {
        record(at: 0, next: address(wordCount) + 64, returning: 0x1000)
        XCTAssertEqual(CrashLogManager.frameChain(from: address(0), stack: bounds, max: 16), [0x1000])
        XCTAssertEqual(CrashLogManager.frameChain(from: address(wordCount - 1), stack: bounds, max: 16), [])
    }

    func testAMisalignedRecordIsNotRead() {
        record(at: 0, next: address(4) + 1, returning: 0x1000)
        XCTAssertEqual(CrashLogManager.frameChain(from: address(0), stack: bounds, max: 16), [0x1000])
    }

    func testTheWalkStopsAtTheFrameLimit() {
        record(at: 0, next: address(4), returning: 0x1000)
        record(at: 4, next: address(8), returning: 0x2000)
        record(at: 8, next: 0, returning: 0x3000)
        XCTAssertEqual(CrashLogManager.frameChain(from: address(0), stack: bounds, max: 2), [0x1000, 0x2000])
    }
}
