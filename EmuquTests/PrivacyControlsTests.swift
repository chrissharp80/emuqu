//
//  PrivacyControlsTests.swift
//  EmuquTests
//
//  Mutation testing removed `.localOnly` from
//  `PasteboardWriter` and every one of the 1,949 tests passed. The flag is the
//  whole reason that type was extracted. This file pins the security controls
//  that are properties of a call rather than of its output, which is the class
//  of control a behavioural test tends to walk straight past.
//

@testable import Emuqu
import UIKit
import UniformTypeIdentifiers
import XCTest

@MainActor
final class PrivacyControlsTests: XCTestCase {
    // MARK: - Pasteboard

    /// `.localOnly` keeps copied content off the Universal Clipboard, which
    /// syncs to the user's other Apple devices over iCloud. What this app
    /// copies is overnight RMSSD, DFA α1 and the debug log.
    func testPasteboardWritesAreLocalOnly() {
        let options = PasteboardWriter.pasteboardOptions()
        XCTAssertEqual(
            options[.localOnly] as? Bool, true,
            "Copied health data would sync to the user's other devices over iCloud."
        )
    }

    /// The expiry is user-configurable — some people copy a report and paste it
    /// minutes later — but when the toggle is off the 60-second security cap
    /// must apply.
    func testPasteboardExpiryFollowsTheUserSetting() {
        let original = SettingsManager.shared.settings.preserveClipboardForPaste
        defer { SettingsManager.shared.settings.preserveClipboardForPaste = original }

        SettingsManager.shared.settings.preserveClipboardForPaste = false
        let capped = PasteboardWriter.pasteboardOptions()
        let expiry = try? XCTUnwrap(capped[.expirationDate] as? Date)
        XCTAssertNotNil(expiry, "Expiry must be set when the user has not opted out.")
        if let expiry {
            let seconds = expiry.timeIntervalSinceNow
            XCTAssertGreaterThan(seconds, 50)
            XCTAssertLessThanOrEqual(seconds, 60)
        }

        SettingsManager.shared.settings.preserveClipboardForPaste = true
        XCTAssertNil(
            PasteboardWriter.pasteboardOptions()[.expirationDate],
            "The user asked for the clipboard to survive; it must not expire."
        )
    }

    /// Every write goes through `PasteboardWriter`. Four call sites existed and
    /// two of them set the flags by hand; a fifth written tomorrow would be the
    /// same defect again.
    func testNothingWritesToThePasteboardDirectly() throws {
        let root = try sourceRoot()
        var offenders: [String] = []
        for file in swiftFiles(under: root) {
            if file.lastPathComponent == "PasteboardWriter.swift" { continue }
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            // Code only. A comment that NAMES the API is documentation, and a
            // check satisfied by a comment proves nothing.
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            if code.contains(where: { $0.contains("UIPasteboard.general") }) {
                offenders.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(
            offenders, [],
            "These write to UIPasteboard directly instead of through PasteboardWriter: \(offenders)"
        )
    }

    // MARK: - Stream teardown

    /// The FDA output perimeter can only judge a whole sentence, so the stream
    /// buffer withholds an incomplete one. That means the closing flush has to
    /// run on EVERY exit path — including a provider error and the Stop button
    /// — or the user loses the last sentence they were actually sent.
    ///
    /// Turning that `defer` into a trailing statement reintroduces the defect
    /// and the whole suite still passes. Building a
    /// provider seam deep enough to drive `consumeStreamRound` from a test
    /// would mean reshaping production code for a test, so this asserts the
    /// control-flow property directly: the flush is lexically inside a `defer`.
    func testTheStreamBufferFlushIsDeferred() throws {
        let file = try sourceRoot()
            .appendingPathComponent("Assistant/ViewModel/AssistantViewModel+Tools.swift")
        let text = try String(contentsOf: file, encoding: .utf8)

        let flushLines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("buffer.flush(force: true") }
        XCTAssertFalse(flushLines.isEmpty, "The closing flush has moved or been renamed.")
        for line in flushLines {
            XCTAssertTrue(
                line.trimmingCharacters(in: .whitespaces).hasPrefix("defer {"),
                """
                The stream buffer's closing flush is not deferred:
                    \(line.trimmingCharacters(in: .whitespaces))
                A mid-stream throw would skip it and discard the held sentence.
                """
            )
        }
    }

    // MARK: - Helpers

    /// Deliberately NOT `XCTSkipUnless`. A skipped test passes
    /// without asserting, which is the thing `check_test_skip_budget.sh` exists
    /// to ration; a source-tree check that quietly skips would be a security
    /// control that reports success when it ran nothing.
    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // EmuquTests
            .deletingLastPathComponent()   // repo root
        url.appendPathComponent("Emuqu/Sources")
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Source tree not reachable at \(url.path) — this check cannot run.")
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    private func swiftFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root,
                                                          includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
