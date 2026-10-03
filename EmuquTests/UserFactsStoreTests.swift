@testable import Emuqu
import os
import XCTest

/// Unit tests for UserFactsStore — the persistent cross-session memory the
/// AI Assistant injects into every system prompt.
///
/// Uses the package-internal `init(fileURL:)` so each test gets a clean
/// temp file and never touches the singleton's App Group container.
@MainActor
final class UserFactsStoreTests: XCTestCase {
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
    nonisolated private static let savedDefaultTimeZone = OSAllocatedUnfairLock<TimeZone?>(initialState: nil)
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

    // A unique directory per test, created when first read. The UUID means two
    // tests can never share a path; `lazy` is what lets `fileURL` be derived
    // from it.
    private lazy var tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserFactsStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private lazy var fileURL = tempDir.appendingPathComponent("user_facts.json")

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Add

    func testAddInsertsTrimmedFact() {
        let store = UserFactsStore(fileURL: fileURL)

        store.add("  I'm training for a marathon  ")

        XCTAssertEqual(store.facts.count, 1)
        XCTAssertEqual(store.facts.first?.text, "I'm training for a marathon")
    }

    func testAddIgnoresWhitespaceOnlyEntries() {
        let store = UserFactsStore(fileURL: fileURL)

        store.add("")
        store.add("   \n\t  ")

        XCTAssertTrue(store.facts.isEmpty)
    }

    func testAddDeDupesCaseInsensitively() {
        let store = UserFactsStore(fileURL: fileURL)

        store.add("Vegetarian diet")
        store.add("vegetarian diet")
        store.add("VEGETARIAN DIET")

        XCTAssertEqual(store.facts.count, 1)
        XCTAssertEqual(store.facts.first?.text, "Vegetarian diet")
    }

    func testAddPreservesOrderOfInsertion() {
        let store = UserFactsStore(fileURL: fileURL)

        store.add("First")
        store.add("Second")
        store.add("Third")

        XCTAssertEqual(store.facts.map(\.text), ["First", "Second", "Third"])
    }

    /// The ~20% prompt-bloat bug: punctuation-/case-only twins both
    /// survive if dedup is only exact case-insensitive.
    func testAddDeDupesPunctuationAndCaseVariants() {
        let store = UserFactsStore(fileURL: fileURL)

        store.add("Acute load is high right now")
        store.add("acute load is high right now.") // trailing period only
        store.add("ACUTE LOAD IS HIGH RIGHT NOW") // case only

        XCTAssertEqual(store.facts.count, 1, "punctuation-/case-only twins must collapse to one fact")
    }

    /// A file bloated by an older build (dupes + over-cap) must be cleaned on
    /// LOAD, not only when the next `add` happens to prune it.
    func testLoadDedupesAndCapsLegacyBloat() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        // (a) punctuation/case twins collapse on load (small list, no cap).
        let dupes: [UserFactsStore.Fact] = [
            .init(text: "acute load is high right now"),
            .init(text: "acute load is high right now."), // trailing period
            .init(text: "ACUTE LOAD IS HIGH RIGHT NOW"), // case
            .init(text: "you're on Willow Grove"),
            .init(text: "You're on Willow Grove.") // period + case
        ]
        try encoder.encode(dupes).write(to: fileURL)
        let s1 = UserFactsStore(fileURL: fileURL)
        XCTAssertEqual(s1.facts.count, 2, "5 facts with punctuation/case twins must collapse to 2 on load")

        // (b) an over-cap file is trimmed to maxFacts on load.
        let many = (0 ..< 40).map { UserFactsStore.Fact(text: "unique fact \($0)") }
        try encoder.encode(many).write(to: fileURL)
        let s2 = UserFactsStore(fileURL: fileURL)
        XCTAssertEqual(s2.facts.count, 25, "load must cap a bloated file at maxFacts")
    }

    // MARK: - Remove

    func testRemoveDeletesById() throws {
        let store = UserFactsStore(fileURL: fileURL)
        store.add("alpha")
        store.add("beta")
        let id = try XCTUnwrap(store.facts.first { $0.text == "alpha" }).id

        store.remove(id)

        XCTAssertEqual(store.facts.map(\.text), ["beta"])
    }

    func testRemoveUnknownIdIsNoOp() {
        let store = UserFactsStore(fileURL: fileURL)
        store.add("alpha")
        store.remove(UUID())

        XCTAssertEqual(store.facts.count, 1)
    }

    // MARK: - Clear

    func testClearEmptiesFacts() {
        let store = UserFactsStore(fileURL: fileURL)
        store.add("a")
        store.add("b")

        store.clear()

        XCTAssertTrue(store.facts.isEmpty)
    }

    // MARK: - Persistence

    func testPersistenceRoundTrip() {
        do {
            let store = UserFactsStore(fileURL: fileURL)
            store.add("Persisted fact #1")
            store.add("Persisted fact #2")
        }

        // Wait for the async write.
        //
        // Do not schedule ONE check 0.5 s out and fulfil an
        // expectation only if the file happened to exist at that instant. When
        // it did not, nothing ever fulfilled and the wait timed out — no
        // retry, so the test was betting on a guessed moment rather than
        // waiting for an outcome. It lost that bet under Thread Sanitizer,
        // where everything runs several times slower.
        //
        // Polling until the file appears is both stricter and stable: it
        // returns the instant the write lands, so the generous deadline costs
        // a passing test nothing and only bounds how long a real failure takes
        // to report.
        // Poll on the OUTCOME, not on the file. Waiting for the file to exist
        // is not the same thing: it appears after the FIRST fact is flushed,
        // so a reopen at that moment sees one fact and the assertion fails —
        // which is what happened when this waited on existence alone.
        let reopened = waitForStore(at: fileURL, toHold: 2)
        XCTAssertEqual(reopened.facts.count, 2)
        XCTAssertEqual(reopened.facts.map(\.text).sorted(), ["Persisted fact #1", "Persisted fact #2"])
    }

    func testAnUndecodableFileIsNotOverwrittenByTheNextAdd() throws {
        let corrupt = Data("{ not facts".utf8)
        try corrupt.write(to: fileURL)
        let store = UserFactsStore(fileURL: fileURL)
        XCTAssertTrue(store.facts.isEmpty)

        store.add("New fact")
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertEqual(try Data(contentsOf: fileURL), corrupt, "A file the store couldn't decode must be kept")
    }

    func testClearReplacesAnUndecodableFile() throws {
        try Data("{ not facts".utf8).write(to: fileURL)
        let store = UserFactsStore(fileURL: fileURL)

        store.clear()
        store.add("Fresh start")

        let reopened = waitForStore(at: fileURL, toHold: 1)
        XCTAssertEqual(reopened.facts.first?.text, "Fresh start")
    }

    // MARK: - System prompt rendering

    func testSystemPromptBlockIsEmptyWhenNoFacts() {
        let store = UserFactsStore(fileURL: fileURL)
        XCTAssertEqual(store.systemPromptBlock(), "")
    }

    func testSystemPromptBlockListsAllFacts() {
        let store = UserFactsStore(fileURL: fileURL)
        store.add("I sleep 6 hours during the week")
        store.add("Allergic to penicillin")

        let block = store.systemPromptBlock()
        XCTAssertTrue(block.contains("I sleep 6 hours during the week"))
        XCTAssertTrue(block.contains("Allergic to penicillin"))
        XCTAssertTrue(block.contains("Things to remember about this user"))
    }

    /// Re-open the store until it hydrates `expected` facts from disk.
    ///
    /// `UserFactsStore` writes off the calling thread and each `add(_:)`
    /// schedules its own flush, so neither the file's existence nor its first
    /// version means every fact has landed. The only stable signal is the one
    /// the test actually asserts on, so that is what this waits for.
    ///
    /// The deadline is a safety net rather than a pace — this returns the
    /// instant the count matches, so a generous value costs a passing test
    /// nothing and only bounds how long a real failure takes to report. It was
    /// a single check scheduled 0.5 s out, which reported a pass only if the
    /// write happened to have landed at that exact moment.
    private func waitForStore(
        at url: URL,
        toHold expected: Int,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> UserFactsStore {
        let deadline = Date().addingTimeInterval(timeout)
        var store = UserFactsStore(fileURL: url)
        while store.facts.count != expected, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            store = UserFactsStore(fileURL: url)
        }
        XCTAssertEqual(store.facts.count, expected,
                       "Store never hydrated \(expected) facts within \(timeout)s", file: file, line: line)
        return store
    }

}
