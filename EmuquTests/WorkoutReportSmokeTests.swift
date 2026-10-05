import CoreLocation
@testable import Emuqu
import Foundation
import PDFKit
import XCTest

/// Smoke tests for the workout PDF and the combined holistic daily report.
///
/// Same rationale as `PDFReportGeneratorSmokeTests`: ~2,300 lines of page
/// drawing that ran at zero coverage, all of it reachable from a button the
/// user presses right after a run. Rendering failures here are traps, not
/// thrown errors, so the only way to find them is to render.
///
/// Every case uses an empty GPS track. That is not laziness — a non-empty
/// track sends `renderMapSnapshot` to `MKMapSnapshotter`, which wants the
/// network, and a suite that quietly depends on connectivity is a suite that
/// goes red for reasons that have nothing to do with the code. An empty track
/// is also the real indoor-treadmill case, and it short-circuits the
/// snapshotter deterministically.
@MainActor
final class WorkoutReportSmokeTests: XCTestCase {
    // MARK: - Fixtures

    private func workoutSamples(count: Int = 1_800) -> [WorkoutSample] {
        (0 ..< count).map { i in
            let phase = Double(i) / 120.0
            return WorkoutSample(
                offsetSec: i,
                heartRate: 130 + Int((25 * sin(phase)).rounded()),
                distanceMeters: Double(i) * 3.1,
                paceSecPerKm: 320 + 25 * sin(phase),
                cadenceStepsPerMin: 172 + 6 * sin(phase / 2),
                altitudeMeters: 100 + 30 * sin(phase / 3),
                alpha1: 0.85 + 0.15 * sin(phase / 4),
                mets: 9.5
            )
        }
    }

    private func workoutSession(
        sport: Sport = .run,
        samples: [WorkoutSample]? = nil,
        distanceMeters: Double? = 5_580
    ) -> HRVSession {
        var session = HRVSession(
            id: UUID(),
            startDate: Date(timeIntervalSince1970: 1_700_040_000),
            endDate: Date(timeIntervalSince1970: 1_700_041_800),
            state: .complete,
            sessionType: .workout,
            rrSeries: nil,
            analysisResult: nil,
            artifactFlags: nil
        )
        session.workoutMetadata = WorkoutMetadata(
            sport: sport,
            distanceMeters: distanceMeters,
            elevationGainMeters: 62,
            elevationLossMeters: 58,
            samples: samples ?? workoutSamples()
        )
        return session
    }

    /// The reported night starts at 1_700_000_000; `nightsBefore` moves the
    /// session that many days earlier (negative = later), so a history is a
    /// run of distinct nights rather than one night repeated.
    private func overnightSession(nightsBefore: Int = 0, rmssd: Double = 45) -> HRVSession {
        let start = Date(timeIntervalSince1970: 1_700_000_000 - Double(nightsBefore) * 86_400)
        var result = HRVAnalysisResult(
            windowStart: 0,
            windowEnd: 600_000,
            timeDomain: TimeDomainMetrics(
                meanRR: 1_000, sdnn: 54, rmssd: rmssd, pnn50: 20,
                sdsd: rmssd * 0.95, meanHR: 60, sdHR: 3, triangularIndex: 12
            ),
            frequencyDomain: FrequencyDomainMetrics(
                vlf: 500, lf: 800, hf: 667, lfHfRatio: 1.2, totalPower: 2_100
            ),
            nonlinear: NonlinearMetrics(
                sd1: 32, sd2: 48, sd1Sd2Ratio: 0.67,
                sampleEntropy: 1.5, approxEntropy: 1.2,
                dfaAlpha1: 0.95, dfaAlpha2: 0.85, dfaAlpha1R2: 0.95
            ),
            ansMetrics: ANSMetrics(
                stressIndex: 120, pnsIndex: 1.5, snsIndex: -0.5,
                readinessScore: 7, respirationRate: 14,
                nocturnalHRDip: 12, daytimeRestingHR: 65, nocturnalMedianHR: 57
            ),
            artifactPercentage: 3.0,
            cleanBeatCount: 590,
            analysisDate: start.addingTimeInterval(10_000)
        )
        result.isConsolidated = true
        result.isOrganizedRecovery = true

        var session = HRVSession(
            id: UUID(),
            startDate: start,
            endDate: start.addingTimeInterval(28_800),
            state: .complete,
            sessionType: .overnight,
            rrSeries: nil,
            analysisResult: result,
            artifactFlags: nil
        )
        session.recoveryScore = 78
        return session
    }

    /// Renders to a throwaway file and asserts a real PDF landed there.
    private func assertRendersPDF(
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ render: (URL) async throws -> Void
    ) async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try await render(url)
        } catch {
            return XCTFail("\(label): render threw \(error)", file: file, line: line)
        }
        guard let document = PDFDocument(url: url) else {
            return XCTFail("\(label): no readable PDF at \(url.lastPathComponent)", file: file, line: line)
        }
        XCTAssertGreaterThan(document.pageCount, 0, "\(label): no pages", file: file, line: line)
    }

    private func workoutReport(
        session: HRVSession,
        units: UnitsPreference = .metric
    ) -> WorkoutPDFReport {
        WorkoutPDFReport(
            session: session,
            track: [],
            userMaxHR: 190,
            userRestingHR: 50,
            userLTHR: 168,
            units: units
        )
    }

    // MARK: - WorkoutPDFReport

    func testWorkoutReportRenders() async {
        await assertRendersPDF("workout report") { url in
            try await workoutReport(session: workoutSession()).generate(to: url)
        }
    }

    func testWorkoutReportRendersInBothUnitSystems() async {
        for units in [UnitsPreference.metric, .imperial, .auto] {
            await assertRendersPDF("workout report (\(units.rawValue))") { url in
                try await workoutReport(session: workoutSession(), units: units)
                    .generate(to: url)
            }
        }
    }

    func testWorkoutReportRendersForEverySport() async {
        // Sport drives which panels appear — cadence and pace panels are
        // meaningless on a bike, and the renderer branches on that.
        for sport in [Sport.run, .trailRun, .walk, .hike, .bike, .indoorBike, .treadmill] {
            await assertRendersPDF("workout report (\(sport.rawValue))") { url in
                try await workoutReport(session: workoutSession(sport: sport))
                    .generate(to: url)
            }
        }
    }

    func testWorkoutReportRendersWithoutSamples() async {
        // A HealthKit-imported workout carries totals but no per-second buffer.
        await assertRendersPDF("workout report, no samples") { url in
            try await workoutReport(session: workoutSession(samples: []))
                .generate(to: url)
        }
    }

    func testWorkoutReportRendersWithoutDistance() async {
        // Indoor strength work: duration and HR, nothing else. The pace and
        // split panels have to fold rather than divide by a nil distance.
        await assertRendersPDF("workout report, no distance") { url in
            try await workoutReport(session: workoutSession(distanceMeters: nil))
                .generate(to: url)
        }
    }

    func testWorkoutReportRendersFromAVeryShortEffort() async {
        await assertRendersPDF("workout report, 10 samples") { url in
            try await workoutReport(session: workoutSession(samples: workoutSamples(count: 10)))
                .generate(to: url)
        }
    }

    func testWorkoutReportRendersWithoutWorkoutMetadataAtAll() async {
        // Defensive: a session typed `.workout` whose metadata never landed.
        var bare = workoutSession()
        bare.workoutMetadata = nil
        await assertRendersPDF("workout report, no metadata") { url in
            try await workoutReport(session: bare).generate(to: url)
        }
    }

    // MARK: - HolisticDailyReport

    private func holisticReport(
        workout: HRVSession,
        overnight: HRVSession?,
        recent: [HRVSession] = []
    ) -> HolisticDailyReport {
        HolisticDailyReport(
            workoutSession: workout,
            workoutTrack: [],
            overnightSession: overnight,
            recentOvernightSessions: recent,
            userMaxHR: 190,
            userRestingHR: 50,
            userLTHR: 168,
            units: .metric
        )
    }

    func testHolisticReportRenders() async {
        await assertRendersPDF("holistic report") { url in
            try await holisticReport(
                workout: workoutSession(),
                overnight: overnightSession()
            ).generate(to: url)
        }
    }

    func testHolisticReportIsLongerThanTheWorkoutReportAlone() async {
        // The holistic report is the workout report with two bespoke pages
        // merged in front of it. If the merge ever silently drops them, the
        // page counts converge.
        let workout = workoutSession()
        let workoutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        let holisticURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: workoutURL)
            try? FileManager.default.removeItem(at: holisticURL)
        }
        do {
            try await workoutReport(session: workout).generate(to: workoutURL)
            try await holisticReport(
                workout: workout,
                overnight: overnightSession()
            ).generate(to: holisticURL)
        } catch {
            return XCTFail("render threw \(error)")
        }
        guard let workoutDoc = PDFDocument(url: workoutURL),
              let holisticDoc = PDFDocument(url: holisticURL)
        else { return XCTFail("one of the reports is not a readable PDF") }
        XCTAssertGreaterThan(holisticDoc.pageCount, workoutDoc.pageCount)
    }

    func testHolisticReportRendersWithoutAnOvernightSession() async {
        // Ran before logging a night, or the strap was never worn. The
        // recovery half of the report has nothing to say and must not crash
        // trying to say it.
        await assertRendersPDF("holistic report, no overnight") { url in
            try await holisticReport(
                workout: workoutSession(),
                overnight: nil
            ).generate(to: url)
        }
    }

    func testHolisticReportRendersWithOvernightHistory() async {
        let history = (1 ... 14).map { overnightSession(nightsBefore: $0) }
        await assertRendersPDF("holistic report, with history") { url in
            try await holisticReport(
                workout: workoutSession(),
                overnight: overnightSession(),
                recent: history
            ).generate(to: url)
        }
    }

    func testHolisticReportRendersFromAMinimalWorkout() async {
        await assertRendersPDF("holistic report, minimal workout") { url in
            try await holisticReport(
                workout: workoutSession(samples: [], distanceMeters: nil),
                overnight: overnightSession()
            ).generate(to: url)
        }
    }

    // MARK: - Right-to-left

    func testWorkoutAndHolisticReportsRenderInArabic() async {
        let original = AppLanguage.current
        LanguageManager.shared.setLanguage(.ar)
        addTeardownBlock { @MainActor in LanguageManager.shared.setLanguage(original) }
        await assertRendersPDF("workout report, Arabic") { url in
            try await workoutReport(session: workoutSession()).generate(to: url)
        }
        await assertRendersPDF("holistic report, Arabic") { url in
            try await holisticReport(
                workout: workoutSession(),
                overnight: overnightSession(),
                recent: (1 ... 7).map { overnightSession(nightsBefore: $0) }
            ).generate(to: url)
        }
    }

    /// A past day's report reads only the nights up to the reported one: the
    /// nights after it in the archive must not move its baseline.
    func testHolisticAnalysisIgnoresNightsAfterTheReportedOne() throws {
        let reported = overnightSession(rmssd: 45)
        let before = (1 ... 3).map { overnightSession(nightsBefore: $0, rmssd: 40) }
        let after = (1 ... 3).map { overnightSession(nightsBefore: -$0, rmssd: 160) }

        let withoutLater = holisticReport(workout: workoutSession(), overnight: reported, recent: before + [reported])
        let withLater = holisticReport(workout: workoutSession(), overnight: reported, recent: before + [reported] + after)

        let baseline = try XCTUnwrap(withoutLater.analysis().recoveryBaselineRMSSD)
        XCTAssertEqual(baseline, 40, accuracy: 0.001, "The reported night is left out of its own baseline")
        XCTAssertEqual(try XCTUnwrap(withLater.analysis().recoveryBaselineRMSSD), baseline, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(withLater.analysis().hrvZScore), try XCTUnwrap(withoutLater.analysis().hrvZScore), accuracy: 1e-9)
    }

    func testAsOfDisplayIsEitherAStringOrHonestlyAbsent() {
        // The cover page stamps "data as of …". It reads a cache, so in a
        // clean test environment nil is the correct answer — the contract is
        // that it never returns an empty or placeholder string.
        let label = holisticReport(
            workout: workoutSession(),
            overnight: overnightSession()
        ).loadAsOfDisplay()
        if let label {
            XCTAssertFalse(label.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
