@testable import Emuqu
import XCTest

/// `MetricKitCrashStack` is the parser that turns the one artifact iOS hands
/// the app after a crash — the MetricKit call-stack tree — into frames a human
/// can symbolicate. It only ever runs after a real crash, ~24 h later, so
/// these tests are the only place its behaviour is observable before it
/// matters.
final class MetricKitCrashStackTests: XCTestCase {
    // MARK: - Helpers

    private func frame(
        _ name: String,
        _ offset: Int,
        uuid: String = "57679B65-9A46-318E-ABBD-03832B58E2A7",
        subFrames: [[String: Any]] = []
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "binaryName": name,
            "binaryUUID": uuid,
            "offsetIntoBinaryTextSegment": offset
        ]
        if !subFrames.isEmpty { dict["subFrames"] = subFrames }
        return dict
    }

    private func tree(_ stacks: [[String: Any]]) -> [String: Any] {
        ["callStacks": stacks, "callStackPerThread": true]
    }

    // MARK: - Frame rendering

    func testFrameRendersBinaryOffsetAndUUID() {
        XCTAssertEqual(
            MetricKitCrashStack.describe(frame("Emuqu", 0x24ED48, uuid: "ABC")),
            "Emuqu +0x24ed48 (ABC)"
        )
    }

    /// A frame missing a field is still a frame. Dropping it would renumber
    /// every frame below the hole, which is worse than printing `?`.
    func testIncompleteFrameKeepsItsPlaceWithQuestionMarks() {
        XCTAssertEqual(MetricKitCrashStack.describe([:]), "? +? (?)")
        XCTAssertEqual(
            MetricKitCrashStack.describe(["binaryName": "Emuqu"]),
            "Emuqu +? (?)"
        )
    }

    func testZeroOffsetIsPrintedNotTreatedAsMissing() {
        XCTAssertEqual(
            MetricKitCrashStack.describe(frame("dyld", 0, uuid: "D")),
            "dyld +0x0 (D)"
        )
    }

    // MARK: - Tree flattening

    /// MetricKit nests callees under `subFrames`. The flattened order is
    /// outermost-first, which is the order the frames must be read in.
    func testNestedSubFramesFlattenOutermostFirst() {
        let stack: [String: Any] = [
            "threadAttributed": true,
            "callStackRootFrames": [
                frame("libsystem_pthread.dylib", 0x10, uuid: "P", subFrames: [
                    frame("libdispatch.dylib", 0x20, uuid: "D", subFrames: [
                        frame("Emuqu", 0x30, uuid: "E")
                    ])
                ])
            ]
        ]
        XCTAssertEqual(
            MetricKitCrashStack.frames(fromCallStackTree: tree([stack])),
            [
                "libsystem_pthread.dylib +0x10 (P)",
                "libdispatch.dylib +0x20 (D)",
                "Emuqu +0x30 (E)"
            ]
        )
    }

    /// Only the attributed thread crashed; the others are noise that would
    /// bury it.
    func testOnlyTheAttributedThreadIsFlattenedWhenOneIsMarked() {
        let crashing: [String: Any] = [
            "threadAttributed": true,
            "callStackRootFrames": [frame("Emuqu", 0xAAA, uuid: "E")]
        ]
        let idle: [String: Any] = [
            "threadAttributed": false,
            "callStackRootFrames": [frame("Emuqu", 0xBBB, uuid: "E")]
        ]
        XCTAssertEqual(
            MetricKitCrashStack.frames(fromCallStackTree: tree([idle, crashing])),
            ["Emuqu +0xaaa (E)"]
        )
    }

    /// Payload shapes have varied across iOS releases. A tree with no thread
    /// marked must still produce a readable stack — a long one beats none.
    func testUnattributedTreeFallsBackToEveryThread() {
        let first: [String: Any] = ["callStackRootFrames": [frame("Emuqu", 0x1, uuid: "E")]]
        let second: [String: Any] = ["callStackRootFrames": [frame("Emuqu", 0x2, uuid: "E")]]
        XCTAssertEqual(
            MetricKitCrashStack.frames(fromCallStackTree: tree([first, second])),
            ["Emuqu +0x1 (E)", "Emuqu +0x2 (E)"]
        )
    }

    // MARK: - Hostile input

    /// The tree comes from outside the app and is walked by recursion. A
    /// pathological payload must cost a truncated stack, not a stack overflow
    /// inside the code whose entire job is explaining crashes.
    func testPathologicallyDeepTreeIsTruncatedRatherThanOverflowing() {
        var frame: [String: Any] = self.frame("Emuqu", 0, uuid: "E")
        for _ in 0 ..< (MetricKitCrashStack.maxDepth + 200) {
            frame = self.frame("Emuqu", 0, uuid: "E", subFrames: [frame])
        }
        let stack: [String: Any] = ["threadAttributed": true, "callStackRootFrames": [frame]]
        let frames = MetricKitCrashStack.frames(fromCallStackTree: tree([stack]))
        XCTAssertEqual(frames.count, MetricKitCrashStack.maxDepth + 1)
    }

    // MARK: - Malformed input

    func testMalformedPayloadsYieldNoFramesRatherThanThrowing() {
        XCTAssertTrue(MetricKitCrashStack.frames(fromCallStackTree: Data()).isEmpty)
        XCTAssertTrue(MetricKitCrashStack.frames(fromCallStackTree: Data("not json".utf8)).isEmpty)
        XCTAssertTrue(MetricKitCrashStack.frames(fromCallStackTree: [:]).isEmpty)
        XCTAssertTrue(MetricKitCrashStack.frames(fromCallStackTree: ["callStacks": "wrong type"]).isEmpty)
    }

    func testDataAndDictionaryEntryPointsAgree() throws {
        let root = tree([[
            "threadAttributed": true,
            "callStackRootFrames": [frame("Emuqu", 0x24ED48, uuid: "U")]
        ]])
        let data = try JSONSerialization.data(withJSONObject: root)
        XCTAssertEqual(
            MetricKitCrashStack.frames(fromCallStackTree: data),
            MetricKitCrashStack.frames(fromCallStackTree: root)
        )
    }
}
