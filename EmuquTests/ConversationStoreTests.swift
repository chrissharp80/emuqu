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
    /// `NSTimeZone.default` is **process-global**. A class that sets it to UTC
    /// in `class setUp()` and does not put it back leaks UTC into every test
    /// class that runs after it in the same process. `LiveReadinessTests`
    /// computes "today" from `Date()` against the current calendar, so between
    /// 19:00 and midnight US-Central (when the UTC date is already tomorrow)
    /// its tests would fail.
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

        XCTAssertTrue(store.clear())

        XCTAssertEqual(store.load().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(store.isEmptyOnDisk())
    }

    /// A set-aside copy of an older history is part of the thread: clear
    /// removes it too, and only then reports the chat as gone.
    func testClearRemovesSetAsideCopies() throws {
        try Data("[{ truncated".utf8).write(to: fileURL)
        let store = makeStore()
        _ = store.load()
        store.save(makeTurns(count: 2))
        waitForPersistedCount(store, 2)
        XCTAssertEqual(try setAsideCopies().count, 1, "Sanity: the undecodable history was set aside")
        XCTAssertFalse(store.isEmptyOnDisk(), "A set-aside copy still holds turns")

        XCTAssertTrue(store.clear())

        XCTAssertEqual(try setAsideCopies().count, 0)
        XCTAssertTrue(store.isEmptyOnDisk())
    }

    /// A clear that cannot remove the file says so and leaves the history in
    /// place, so nothing claims a wipe that did not happen.
    func testClearReportsFailureWhenTheFileCannotBeRemoved() throws {
        let store = makeStore()
        store.save(makeTurns(count: 2))
        waitForPersistedCount(store, 2)
        try makeDirectoryReadOnly()

        XCTAssertFalse(store.clear())

        XCTAssertEqual(store.load().count, 2)
    }

    // MARK: - Sealed at rest

    func testHistoryIsSealedAtRestAndRoundTrips() throws {
        let store = makeStore()
        store.save(makeTurns(count: 2))
        waitForPersistedCount(store, 2)

        let raw = try Data(contentsOf: fileURL)
        XCTAssertNotEqual(raw.first, UInt8(ascii: "["), "The history must not be written as plain JSON")
        XCTAssertNil(raw.range(of: Data("turn-0".utf8)), "Chat text must not be readable on disk")
        XCTAssertEqual(makeStore().load().map(\.text), ["turn-0", "turn-1"])
    }

    // MARK: - Summary

    /// A defaults domain of the test's own, so nothing reaches the app's.
    private func makeDefaults() throws -> UserDefaults {
        let name = "ConversationStoreTests-\(UUID().uuidString)"
        addTeardownBlock { @MainActor in UserDefaults.standard.removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private var summaryFileURL: URL { tempDir.appendingPathComponent("conversation_summary.json") }

    /// The summary restates the conversation (injuries, medications), so it is
    /// sealed beside the history like it, not left in plain defaults.
    func testSummaryIsSealedAtRestAndRoundTrips() throws {
        let defaults = try makeDefaults()
        let store = makeStore()
        store.saveSummary("Runner with a sore left knee, taking ibuprofen.")
        waitUntil("the summary to be written") { FileManager.default.fileExists(atPath: summaryFileURL.path) }

        let raw = try Data(contentsOf: summaryFileURL)
        XCTAssertNil(raw.range(of: Data("ibuprofen".utf8)), "The summary must not be readable on disk")
        XCTAssertEqual(makeStore().loadSummary(migratingFrom: defaults, key: "summary"), "Runner with a sore left knee, taking ibuprofen.")
    }

    /// A summary an older build left in defaults moves into the sealed file
    /// and leaves defaults.
    func testPlainSummaryInDefaultsIsMovedIntoTheSealedFile() throws {
        let defaults = try makeDefaults()
        defaults.set("Training for a marathon.", forKey: "summary")

        XCTAssertEqual(makeStore().loadSummary(migratingFrom: defaults, key: "summary"), "Training for a marathon.")

        XCTAssertNil(defaults.string(forKey: "summary"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryFileURL.path))
        XCTAssertEqual(makeStore().loadSummary(migratingFrom: defaults, key: "summary"), "Training for a marathon.")
    }

    /// Clear erases the summary with the history, and the chat only reads as
    /// gone once both are.
    func testClearErasesTheSummary() throws {
        let defaults = try makeDefaults()
        let store = makeStore()
        store.saveSummary("Summary text.")
        waitUntil("the summary to be written") { FileManager.default.fileExists(atPath: summaryFileURL.path) }
        XCTAssertFalse(store.isEmptyOnDisk(), "A stored summary still holds the conversation")

        XCTAssertTrue(store.clear())

        XCTAssertFalse(FileManager.default.fileExists(atPath: summaryFileURL.path))
        XCTAssertNil(store.loadSummary(migratingFrom: defaults, key: "summary"))
        XCTAssertTrue(store.isEmptyOnDisk())
    }

    /// A plain history written by a build that did not seal it still loads,
    /// and the next save replaces it sealed.
    func testPlainHistoryLoadsAndIsResealedOnTheNextSave() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(makeTurns(count: 2)).write(to: fileURL)
        let store = makeStore()
        XCTAssertEqual(store.load().map(\.text), ["turn-0", "turn-1"])

        store.save(makeTurns(count: 3))
        waitForPersistedCount(store, 3)

        XCTAssertNotEqual(try Data(contentsOf: fileURL).first, UInt8(ascii: "["))
    }

    private func setAsideCopies() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("undecodable") }
    }

    /// Nothing in the folder can be removed or created until teardown puts
    /// the permissions back.
    private func makeDirectoryReadOnly() throws {
        let dir = tempDir
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        addTeardownBlock {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        }
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

    /// The undecodable file is kept beside the original, and the new turns are
    /// saved rather than held unsaved until the next launch drops them.
    func testAnUndecodableHistoryIsSetAsideAndSavingResumes() throws {
        let corrupt = Data("[{ truncated".utf8)
        try corrupt.write(to: fileURL)
        let store = makeStore()
        XCTAssertTrue(store.load().isEmpty)

        store.save(makeTurns(count: 2))
        waitForPersistedCount(store, 2)

        let kept = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("undecodable") }
        XCTAssertEqual(kept.count, 1, "A history the store couldn't decode must be kept")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(kept.first)), corrupt)
        XCTAssertFalse(store.needsReloadFromDisk)
    }

    func testClearReplacesAnUndecodableHistory() throws {
        try Data("[{ truncated".utf8).write(to: fileURL)
        let store = makeStore()
        _ = store.load()

        XCTAssertTrue(store.clear())
        store.save(makeTurns(count: 3))

        waitForPersistedCount(store, 3)
    }

    /// `isEmptyOnDisk` runs on the store's serial queue, after the retry
    /// queued before it, so the check below sees whatever the retry wrote.
    func testRetryingWithNothingPendingWritesNothing() {
        let store = makeStore()
        store.retryHeldSave()
        XCTAssertTrue(store.isEmptyOnDisk())
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
