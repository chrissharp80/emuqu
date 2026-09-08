@testable import Emuqu
import XCTest

/// Tests for resolving typed names to email recipients.
///
/// This turns a comma-separated list —
/// often produced by the AI assistant from a spoken instruction — into the
/// addresses a PDF health report is sent to. Resolving the wrong one sends
/// somebody's sleep and heart data to the wrong person, which is not a bug
/// that can be taken back.
///
/// The three-way split matters: `unknown` and `ambiguous` must NOT silently
/// become `resolved`. A name the app is unsure about has to reach the user for
/// disambiguation rather than being guessed at.
@MainActor
final class EmailContactResolutionTests: XCTestCase {
    /// A store backed by its own throwaway file.
    ///
    /// The default `EmailContactStore()` reads and writes one shared book in
    /// Application Support. Using it here made these tests accumulate contacts
    /// across runs — a name that resolved cleanly on the first run came back
    /// ambiguous on the second, and the mutation verifier reported the whole
    /// class "already red". Each test now gets its own file.
    private func store(
        _ people: [(String, String)],
        function: String = #function
    ) -> EmailContactStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("emuqu-contacts-\(function)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let s = EmailContactStore(storeURL: url)
        for (name, email) in people {
            s.add(EmailContact(name: name, email: email))
        }
        return s
    }

    // MARK: - Straightforward resolution

    func testSingleKnownNameResolves() {
        let s = store([("Ada Testcase", "ada@example.com")])
        let out = s.resolveNames("Ada Testcase")
        XCTAssertEqual(out.resolved, ["ada@example.com"])
        XCTAssertTrue(out.unknown.isEmpty)
        XCTAssertTrue(out.ambiguous.isEmpty)
    }

    func testMatchingIsCaseInsensitive() {
        let s = store([("Grace Hopperton", "grace@example.com")])
        XCTAssertEqual(s.resolveNames("grace hopperton").resolved, ["grace@example.com"])
    }

    func testSurroundingWhitespaceIsIgnored() {
        let s = store([("Alan Turingsen", "alan@example.com")])
        XCTAssertEqual(s.resolveNames("   Alan Turingsen  ").resolved, ["alan@example.com"])
    }

    // MARK: - Unknown names must not be guessed

    func testUnknownNameIsReportedNotResolved() {
        let s = store([("Known Person", "known@example.com")])
        let out = s.resolveNames("Nobody Here")
        XCTAssertTrue(out.resolved.isEmpty, "an unknown name must never produce an address")
        XCTAssertEqual(out.unknown, ["Nobody Here"])
    }

    func testUnknownNamesDoNotBlockKnownOnes() {
        let s = store([("Real Recipient", "real@example.com")])
        let out = s.resolveNames("Real Recipient, Ghost Person")
        XCTAssertEqual(out.resolved, ["real@example.com"])
        XCTAssertEqual(out.unknown, ["Ghost Person"])
    }

    // MARK: - Ambiguity must surface, not pick one

    func testDuplicateNamesAreAmbiguousNotResolved() {
        // Two people with the same name. Picking either would send health data
        // to a coin-flip recipient.
        let s = store([
            ("Sam Ambiguous", "sam.one@example.com"),
            ("Sam Ambiguous", "sam.two@example.com")
        ])
        let out = s.resolveNames("Sam Ambiguous")
        XCTAssertTrue(out.resolved.isEmpty, "an ambiguous name must never resolve to a guess")
        XCTAssertEqual(out.ambiguous, ["Sam Ambiguous"])
    }

    // MARK: - Literal addresses pass through

    func testLiteralEmailPassesThrough() {
        // The assistant mixes names and explicit addresses.
        let s = store([])
        XCTAssertEqual(s.resolveNames("someone@example.com").resolved, ["someone@example.com"])
    }

    func testStringWithoutADotIsNotTreatedAsAnAddress() {
        // "@home" is not an address; treating it as one would send to nowhere.
        let s = store([])
        let out = s.resolveNames("@home")
        XCTAssertTrue(out.resolved.isEmpty)
        XCTAssertEqual(out.unknown, ["@home"])
    }

    // MARK: - List parsing

    func testEmptyInputResolvesToNothing() {
        let s = store([])
        let out = s.resolveNames("")
        XCTAssertTrue(out.resolved.isEmpty)
        XCTAssertTrue(out.unknown.isEmpty)
        XCTAssertTrue(out.ambiguous.isEmpty)
    }

    func testEmptyEntriesAreDroppedNotTreatedAsNames() {
        let s = store([("Solo Contact", "solo@example.com")])
        let out = s.resolveNames("Solo Contact, , ,")
        XCTAssertEqual(out.resolved, ["solo@example.com"])
        XCTAssertTrue(out.unknown.isEmpty, "empty entries must not become unknown names")
    }

    func testMultipleRecipientsAllResolve() {
        let s = store([
            ("First Person", "first@example.com"),
            ("Second Person", "second@example.com")
        ])
        let out = s.resolveNames("First Person, Second Person")
        XCTAssertEqual(Set(out.resolved), ["first@example.com", "second@example.com"])
    }
}
