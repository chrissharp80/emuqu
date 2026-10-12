@testable import Emuqu
import Foundation
import XCTest

/// Golden-master harness for `AssistantContext.compactRender`.
///
/// `compactRender` was once a single 379-line function; it is now one builder
/// per prompt section, and every byte of its output is the contract with five
/// LLM providers. This harness is what lets that kind of decomposition be
/// proven inert.
///
/// It is not testing that the prompt is *correct* — it cannot know that. It
/// pins the prompt as it is today, byte for byte, for two recorded contexts:
///
///   • the minimal context (every optional section absent), and
///   • a populated context carrying the ambient-location, baseline, 7-day
///     trend and narrative sections.
///
/// The today/yesterday, earlier-session, recent-workout and live sections are
/// not in either recording; a change confined to them is not caught here.
///
/// If one of the golden tests fails, the prompt changed. When that was
/// intended, re-record the expected lines from the new output.
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

    /// The minimal context plus an ambient location, baselines, a 7-day trend
    /// and a narrative summary. Values avoid `%.1f` rounding ties so the
    /// recorded lines below do not depend on how a tie is broken.
    private func populatedContext() -> AssistantContext {
        var context = AssistantContext(
            generatedAt: generatedAt,
            userProfile: profile(),
            today: nil,
            yesterday: nil,
            yesterdayDiagnostic: nil,
            recent: [],
            baselines: baselines(),
            trends7Day: trends(),
            trends30Day: nil,
            analysisSummary: summary(),
            recentWorkouts: []
        )
        context.ambientLocation = AssistantContext.AmbientLocationSnapshot(
            road: "Main St", nearestCrossStreet: "2nd Ave", locality: "Springfield",
            subdivision: nil, administrativeArea: "IL", country: "United States",
            headingCardinal: "N", headingDegrees: 12.7, speedMS: 1.5,
            altitudeMeters: 180.4, accuracyMeters: 5.9, ageSeconds: 30
        )
        return context
    }

    private func baselines() -> AssistantContext.BaselineSnapshot {
        AssistantContext.BaselineSnapshot(
            lnRmssdMean: nil, lnRmssdSD: nil, lnRmssdCV7Day: nil,
            meanHRBaseline: 52.4, meanHRSD: nil, daysInWindow: 7, lastDataPointDate: nil,
            rmssdBaseline: 61.3, sdnnBaseline: 70.0, dfaAlpha1Baseline: nil, stressIndexBaseline: 95.6
        )
    }

    private func trends() -> AssistantContext.TrendSnapshot {
        let rmssd = AssistantContext.TrendSnapshot.MetricTrend(
            metric: "rmssd", count: 6, mean: 58.2, standardDeviation: 4, min: 50, max: 66,
            trend: "Improving", trendSlope: 1.2, coefficientOfVariation: 0.07,
            baseline: 55, deviationFromBaseline: 5.8
        )
        let heartRate = AssistantContext.TrendSnapshot.MetricTrend(
            metric: "meanHR", count: 6, mean: 53.1, standardDeviation: 1, min: 52, max: 55,
            trend: "Stable", trendSlope: 0, coefficientOfVariation: 0.02,
            baseline: nil, deviationFromBaseline: nil
        )
        return AssistantContext.TrendSnapshot(
            period: "7 Days", dataPointCount: 6, overallTrend: "Improving",
            metrics: [rmssd, heartRate], insights: []
        )
    }

    private func summary() -> AssistantContext.AnalysisSummarySnapshot {
        AssistantContext.AnalysisSummarySnapshot(
            analysisTitle: "Well recovered",
            diagnosticScore: 82,
            analysisExplanation: "HRV is above baseline.",
            probableCauses: [
                AssistantContext.AnalysisSummarySnapshot.ProbableCause(
                    cause: "Good sleep", confidence: "High", explanation: "Eight hours in bed."
                )
            ],
            keyFindings: ["RMSSD up 6%"],
            actionableSteps: [],
            trendInsight: ""
        )
    }

    private static let headerLine = "=== Emuqu — User Context (compact) ==="
    private static let profileLine = "Profile: 44y, Male, intermediate, VO2max 48.5, maxHR 178, imperial"
    private static let algorithmLine = "Algorithm: v3 (Tier 3: HRV 60% / Sleep 25% / Vitals 15%; "
        + "Tier 2: HRV 70% / Sleep 30%, or HRV 85% / Sleep 15% on a night with HRV more than 1 SD below baseline "
        + "and a sleep score under 50; Tier 1: HRV only)"
    private static let locationLine = "📍 LOCATION: on Main St, near 2nd Ave, in Springfield, IL, United States, "
        + "heading N (12°), speed 1.5 m/s (5.4 km/h), alt 180m, GPS ±5m, (30s old)"

    /// Compares line by line so a failure names the first line that drifted
    /// rather than dumping the whole prompt, then compares the counts so a
    /// dropped or added trailing line also fails.
    private func assertLines(
        _ rendered: String, _ expected: [String], file: StaticString = #filePath, line: UInt = #line
    ) {
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, pair) in zip(lines, expected).enumerated() where pair.0 != pair.1 {
            XCTFail("line \(index) drifted:\n  got:      \(pair.0)\n  expected: \(pair.1)", file: file, line: line)
            return
        }
        XCTAssertEqual(lines.count, expected.count, "line count drifted; got:\n\(rendered)", file: file, line: line)
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

    func testLocationFlagDropsARealLocationLine() {
        // The privacy boundary itself: with an ambient location present, the
        // on-device render carries the 📍 LOCATION line and the cloud-bound
        // render (includeAmbientLocation: false) carries no trace of it.
        let context = populatedContext()
        let onDevice = context.compactRender(includeAmbientLocation: true)
        let cloudBound = context.compactRender(includeAmbientLocation: false)

        XCTAssertTrue(onDevice.contains(Self.locationLine), "on-device render must keep the location line")
        XCTAssertFalse(cloudBound.contains("📍"), "cloud-bound render must not carry the location line")
        XCTAssertFalse(cloudBound.contains("Main St"), "cloud-bound render must not carry the road name")
        XCTAssertFalse(cloudBound.contains("Springfield"), "cloud-bound render must not carry the locality")
        XCTAssertEqual(
            cloudBound,
            onDevice.replacingOccurrences(of: Self.locationLine + "\n", with: ""),
            "dropping the location must remove exactly that one line"
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
        // different input. Every optional section is absent, so only the
        // header, profile and algorithm lines render.
        assertLines(minimalContext().compactRender(), [Self.headerLine, Self.profileLine, Self.algorithmLine])
    }

    func testPopulatedContextRenderIsUnchanged() {
        // The populated sections, in the order the builders run: location
        // (above the profile), baselines, 7-day trend, narrative.
        assertLines(populatedContext().compactRender(includeAmbientLocation: true), [
            Self.headerLine,
            Self.locationLine,
            Self.profileLine,
            Self.algorithmLine,
            "",
            "--- Personal baseline (7-day rolling) ---",
            "RMSSD baseline: 61.3ms",
            "SDNN baseline: 70.0ms",
            "Mean HR baseline: 52.4bpm",
            "Stress index baseline: 95.6",
            "",
            "--- 7-day trend (6 sessions) ---",
            "Overall: Improving",
            "rmssd: mean 58.2, improving, 6% vs baseline",
            "meanHR: mean 53.1, stable",
            "",
            "--- Summary ---",
            "Well recovered — HRV is above baseline.",
            "Probable causes:",
            "  • [High] Good sleep: Eight hours in bed.",
            "Key findings:",
            "  • RMSSD up 6%"
        ])
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
