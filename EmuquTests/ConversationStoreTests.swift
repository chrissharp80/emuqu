@testable import Emuqu
import os
import XCTest

/// Unit tests for ConversationStore — the JSON-backed persistence for the
/// AI Assistant chat thread.
///
/// The production type is a singleton bound to the App Group container; tests
/// use the package-internal `init(fileURL:)` to point at a temp file so each
/// run is hermetic and order-independent.
final class ConversationStoreTests: XCTestCase {
    /// Capture-and-restore, not fire-and-forget.
    ///
    /// `NSTimeZone.default` is **process-global**. Ten test classes set it to
    /// UTC in `class setUp()` and none of them put it back, so every test class
    /// that happened to run afterwards in the same process silently inherited
    /// UTC. `LiveReadinessTests` computes "today" from `Date()` against the
    /// current calendar, so between 19:00 and midnight US-Central (when the UTC
    /// date is already tomorrow) four of its tests failed — a genuine
    /// time-of-day flake that was invisible only because the suite used to
    /// deadlock before reaching them.
    private static let savedDefaultTimeZone = OSAllocatedUnfairLock<TimeZone?>(initialState: nil)
    override class func setUp() {
        super.setUp()
        savedDefaultTimeZone.withLock { $0 = NSTimeZone.default }
        NSTimeZone.default = TestTimeZone.utc
    }

    override class func tearDown() {
        if let saved = savedDefaultTimeZone.withLock({ $0 }) { NSTimeZone.default = saved }
        savedDefaultTimeZone.withLock { $0 = nil }
        super.tearDown()
    }

    // A unique directory per test, created when first read. Directory creation
    // moves from a throwing `setUpWithError` into the accessor; a failure here
    // surfaces on the first test that touches the store rather than aborting
    // setup, and the UUID still guarantees no two tests share a path.
    private lazy var tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private lazy var fileURL = tempDir.appendingPathComponent("conversation.json")

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Short debounce so tests don't wait out the production 750 ms
    /// coalescing window on every save. Still long enough to exercise the
    /// real coalescer path (queue hop + trailing-edge asyncAfter).
    private let testDebounceMs = 25

    private func makeStore() -> ConversationStore {
        ConversationStore(fileURL: fileURL, saveDebounceMs: testDebounceMs)
    }

    private func makeTurns(count: Int) -> [ChatTurn] {
        (0 ..< count).map { i in
            ChatTurn(
                role: i.isMultiple(of: 2) ? .user : .assistant,
                text: "turn-\(i)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
            )
        }
    }

    /// Do not wait for writes by calling `load()` as if it were a `queue.sync`
    /// barrier: load is a direct file read and `save` has a trailing-edge
    /// debounce, so such a "wait" returns before any byte hits disk and every
    /// subsequent load reads the pre-write (empty) file. Poll the
    /// observable condition instead of assuming synchronization.
    /// Poll until `predicate` holds, then fail if it never did.
    ///
    /// `ConversationStore.save` hands off to a serial queue and debounces, so
    /// nothing is on disk when it returns — that is the behaviour, not a bug,
    /// and it is why these tests poll rather than assert straight away.
    ///
    /// A 3 s deadline is generous on a developer Mac
    /// and not generous on a CI runner driving three simulator clones. Run
    /// 33191820285 failed four tests here with "have 0", i.e. the debounced
    /// write had not landed yet. A polling deadline is a safety net, not a
    /// pace: this loop returns the instant the predicate holds, so a larger
    /// number costs a passing test nothing and only bounds how long a genuine
    /// failure takes to report.
    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 30.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("Timed out waiting for \(what)", file: file, line: line)
    }

    /// Wait until the persisted file decodes to exactly `expected` turns.
    private func waitForPersistedCount(
        _ store: ConversationStore,
        _ expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitUntil("\(expected) persisted turns (have \(store.load().count))", file: file, line: line) {
            store.load().count == expected
        }
    }

    // MARK: - Basic load/save round-trip

    func testEmptyLoadReturnsEmptyArray() {
        let store = makeStore()
        XCTAssertEqual(store.load().count, 0)
    }

    func testSaveThenLoadReturnsTheSameTurns() {
        let store = makeStore()
        let turns = makeTurns(count: 4)

        store.save(turns)
        waitForPersistedCount(store, 4)

        let loaded = store.load()
        XCTAssertEqual(loaded.count, turns.count)
        XCTAssertEqual(loaded.map(\.id), turns.map(\.id))
        XCTAssertEqual(loaded.map(\.text), turns.map(\.text))
        XCTAssertEqual(loaded.map(\.role), turns.map(\.role))
    }

    func testRolesAreSerializedAndDecodedCorrectly() {
        let store = makeStore()
        let turns = [
            ChatTurn(role: .user, text: "hello"),
            ChatTurn(role: .assistant, text: "hi", providerID: .anthropic, modelID: "claude-3")
        ]
        store.save(turns)
        waitForPersistedCount(store, 2)

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2)
        // Guard before subscripting — when the debounced write hadn't landed
        // this test didn't just fail, it SIGTRAPped on `loaded[0]` against an
        // empty array. Fail cleanly instead of crashing the whole run.
        guard loaded.count == 2 else { return }
        XCTAssertEqual(loaded[0].role, .user)
        XCTAssertEqual(loaded[1].role, .assistant)
        XCTAssertEqual(loaded[1].providerID, .anthropic)
        XCTAssertEqual(loaded[1].modelID, "claude-3")
    }

    // MARK: - Clear

    func testClearRemovesPersistedFile() {
        let store = makeStore()
        store.save(makeTurns(count: 3))
        waitForPersistedCount(store, 3)

        store.clear()
        // clear() runs async on the store's queue — poll for the file's removal.
        waitUntil("conversation file removed") {
            !FileManager.default.fileExists(atPath: self.fileURL.path)
        }

        XCTAssertEqual(store.load().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Persistence across instances

    func testNewInstanceReadsPriorWrites() {
        let writer = makeStore()
        let turns = makeTurns(count: 2)
        writer.save(turns)
        waitForPersistedCount(writer, 2)

        // A fresh store pointing at the same URL should observe the saved data.
        let reader = makeStore()
        let loaded = reader.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.text), ["turn-0", "turn-1"])
    }

    func testSaveOverwritesPreviousContents() {
        let store = makeStore()
        store.save(makeTurns(count: 5))
        waitForPersistedCount(store, 5)

        let trimmed = Array(makeTurns(count: 5).suffix(2))
        store.save(trimmed)
        waitForPersistedCount(store, 2)

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2, "Save should fully overwrite, not append")
        XCTAssertEqual(loaded.map(\.text), ["turn-3", "turn-4"])
    }

    // MARK: - Undecodable history

    func testAnUndecodableHistoryIsNotOverwrittenByTheNextSave() throws {
        let corrupt = Data("[{ truncated".utf8)
        try corrupt.write(to: fileURL)
        let store = makeStore()
        XCTAssertTrue(store.load().isEmpty)

        store.save(makeTurns(count: 2))
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertEqual(try Data(contentsOf: fileURL), corrupt, "A history the store couldn't decode must be kept")
        XCTAssertTrue(store.needsReloadFromDisk)
    }

    func testClearReplacesAnUndecodableHistory() throws {
        try Data("[{ truncated".utf8).write(to: fileURL)
        let store = makeStore()
        _ = store.load()

        store.clear()
        store.save(makeTurns(count: 3))

        waitForPersistedCount(store, 3)
    }

    func testRetryingWithNothingPendingWritesNothing() {
        let store = makeStore()
        store.retryHeldSave()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Caller-side budget truncation pattern

    /// A common usage pattern: callers cap the conversation length before
    /// persisting (the "token budget" referenced by ChatTurn.truncateForSend).
    /// Verify the store faithfully persists the trimmed array — i.e. it does
    /// not re-merge with whatever was on disk before.
    func testTruncatedSaveDoesNotResurrectOldTurns() {
        let store = makeStore()
        store.save(makeTurns(count: 8))
        waitForPersistedCount(store, 8)

        // Pretend the caller decided 4 turns fit the budget and dropped the rest.
        let kept = Array(makeTurns(count: 8).suffix(4))
        store.save(kept)
        waitForPersistedCount(store, 4)

        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.text), kept.map(\.text))
    }
}
