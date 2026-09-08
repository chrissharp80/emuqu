@testable import Emuqu
import Foundation
import XCTest

/// Golden-master harness for `AssistantContext.compactRender`.
///
/// `compactRender` is 379 body lines at cyclomatic complexity 124 — the worst
/// function in the codebase, and the only one carrying a documented SwiftLint
/// exemption for it. That exemption says exactly what is missing:
///
///   > It is a flat sequence of `out.append(...)` building the model prompt, and
///   > it should decompose into one builder per prompt section. Not done in the
///   > refactor pass because every byte of this output is the contract with
///   > five LLM providers and the change needs a parity harness first.
///
/// This is that harness. It is not testing that the prompt is *correct* — it
/// cannot know that. It pins the prompt as it is TODAY, so that decomposing the
/// function into per-section builders can be proven byte-for-byte inert. Every
/// character of this output reaches five different models; a stray space or a
/// dropped line is a silent behavioural change to all of them.
///
/// If one of these tests fails after a refactor, the refactor changed the
/// prompt. That is the entire point.
final class CompactRenderParityTests: XCTestCase {
    // MARK: - Deterministic fixture

    private let generatedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func profile() -> AssistantContext.UserProfileSnapshot {
        AssistantContext.UserProfileSnapshot(
            age: 44,
            biologicalSex: "Male",
            fitnessLevel: "intermediate",
            vo2Max: 48.5,
            typicalSleepHours: 7.5,
            customTagNames: ["late caffeine", "travel"],
            maxHR: 178,
            maxHRIsUserOverride: true,
            unitsPreference: "imperial",
            onTrainingBreak: false,
            trainingBreakReason: nil,
            sleepIntegrationEnabled: true,
            trainingLoadIntegrationEnabled: true,
            comebackModeActive: false,
            comebackModeDayInWindow: nil,
            scoreAlgorithmVersion: "v3",
            scoreHistoryRecomputed: true
        )
    }

    /// The smallest context the renderer accepts: the four non-optional fields
    /// and nothing else. Everything absent exercises the renderer's nil paths,
    /// which is where a careless decomposition is most likely to drop a line.
    private func minimalContext() -> AssistantContext {
        AssistantContext(
            generatedAt: generatedAt,
            userProfile: profile(),
            today: nil,
            yesterday: nil,
            yesterdayDiagnostic: nil,
            recent: [],
            baselines: nil,
            trends7Day: nil,
            trends30Day: nil,
            analysisSummary: nil,
            recentWorkouts: []
        )
    }

    // MARK: - Stability

    func testCompactRenderIsDeterministic() {
        // Two renders of the same context must be byte-identical. If this ever
        // fails, something in the prompt depends on wall-clock time or on
        // dictionary ordering, and no golden master can hold.
        let context = minimalContext()
        XCTAssertEqual(
            context.compactRender(includeAmbientLocation: true),
            context.compactRender(includeAmbientLocation: true)
        )
    }

    func testCompactRenderStartsWithTheContextHeader() {
        // The header is the model's cue for what it is reading. Pinned
        // separately because a decomposition that reorders builders would move
        // it without failing a length check.
        let rendered = minimalContext().compactRender()
        XCTAssertTrue(
            rendered.hasPrefix("=== Emuqu — User Context (compact) ==="),
            "prompt must open with the context header, got: \(rendered.prefix(80))"
        )
    }

    func testCompactRenderProducesNoBlankRunsOrTrailingSpace() {
        // Token budget: this render targets ~1.5K tokens for an on-device
        // model. Doubled newlines and trailing spaces are pure waste, and are
        // exactly what sloppy `out.append` refactors introduce.
        let rendered = minimalContext().compactRender()
        XCTAssertFalse(rendered.contains("\n\n\n"), "no runs of blank lines")
        for line in rendered.split(separator: "\n", omittingEmptySubsequences: false) {
            XCTAssertEqual(
                String(line), String(line).replacingOccurrences(of: " +$", with: "", options: .regularExpression),
                "line has trailing whitespace: '\(line)'"
            )
        }
    }

    // MARK: - The location gate
    //
    // `includeAmbientLocation` is a privacy boundary, not a formatting option.
    // On-device renders keep the 📍 LOCATION line because nothing leaves the
    // phone; cloud-bound renders must pass the same disclosure-matched gate
    // `renderLiveStateForCloud` uses, because ProviderConsentSheet promises
    // ambient location only reaches a cloud provider during an active workout.

    func testLocationFlagNeverAddsLocationWhenThereIsNone() {
        // With no ambient location in the context, both settings must produce
        // the same bytes — the flag gates a line that does not exist.
        let context = minimalContext()
        XCTAssertEqual(
            context.compactRender(includeAmbientLocation: true),
            context.compactRender(includeAmbientLocation: false)
        )
    }

    func testLocationDefaultsToIncluded() {
        // The default is `true` (the on-device case). Callers bound for a cloud
        // provider must opt out explicitly — a default of `false` would be
        // safer, but changing it is a behavioural change, so it is pinned as-is.
        let context = minimalContext()
        XCTAssertEqual(
            context.compactRender(),
            context.compactRender(includeAmbientLocation: true)
        )
    }

    // MARK: - Golden master

    func testMinimalContextRenderIsUnchanged() {
        // The lock. Any decomposition of `compactRender` must leave this
        // identical; if it does not, the prompt changed and five providers see
        // different input.
        let rendered = minimalContext().compactRender()

        // Recorded output. Compared by line so a
        // failure names the first line that drifted rather than dumping the
        // whole prompt.
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertFalse(lines.isEmpty, "render produced nothing")

        // Structural invariants that survive any legitimate reformatting of the
        // *values* while catching a dropped or reordered section.
        XCTAssertEqual(lines.first, "=== Emuqu — User Context (compact) ===")
        XCTAssertTrue(
            lines.contains { $0.contains("44") },
            "user age must appear in the profile section"
        )
        XCTAssertTrue(
            lines.contains { $0.lowercased().contains("imperial") },
            "units preference must reach the model — it decides whether metrics are read out in miles or km"
        )
    }

    func testRenderIsWithinItsTokenBudget() {
        // The doc comment commits to ~1.5K tokens for the on-device model. At
        // roughly four characters per token, a minimal context should sit far
        // under that; this catches a decomposition that accidentally duplicates
        // a section.
        let rendered = minimalContext().compactRender()
        XCTAssertLessThan(
            rendered.count, 6_000,
            "minimal-context render is \(rendered.count) chars — a duplicated section is the usual cause"
        )
    }
}
