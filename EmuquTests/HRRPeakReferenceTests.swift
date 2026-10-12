@testable import Emuqu
import XCTest

/// HRR drops are measured from the workout's peak heart rate. These pin the
/// repair for readings that builds measuring from the heart rate at Stop
/// stored, using the Oct 6 walk: peak 161, 143 at Stop, 125 a minute later.
final class HRRPeakReferenceTests: XCTestCase {
    private func metadata(peak: Int, readings: [HRRSample]) -> WorkoutMetadata {
        let samples = [140, peak, 150, 143].enumerated().map { WorkoutSample(offsetSec: $0.offset, heartRate: $0.element) }
        return WorkoutMetadata(sport: .walk, samples: samples, hrrSamples: readings)
    }

    private let stopReferenced = [
        HRRSample(offsetSec: 60, hr: 125, drop: 18, peakHR: 143, provenance: .strap),
        HRRSample(offsetSec: 120, hr: 112, drop: 31, peakHR: 143, provenance: .strap)
    ]

    func testStopReferencedReadingsAreRemeasuredFromThePeak() throws {
        let remeasured = try XCTUnwrap(metadata(peak: 161, readings: stopReferenced).hrrRemeasuredFromPeak())
        XCTAssertEqual(remeasured.map(\.drop), [36, 49])
        XCTAssertEqual(remeasured.map(\.peakHR), [161, 161])
        XCTAssertEqual(remeasured.map(\.hr), [125, 112], "the measured heart rates do not change")
    }

    func testPeakReferencedReadingsAreLeftAlone() {
        let peakReferenced = [HRRSample(offsetSec: 60, hr: 125, drop: 36, peakHR: 161, provenance: .strap)]
        XCTAssertNil(metadata(peak: 161, readings: peakReferenced).hrrRemeasuredFromPeak())
    }

    /// Apple's value is a drop, so it keeps the drop and the heart rate moves.
    func testAppleComputedReadingKeepsItsDrop() throws {
        let apple = [HRRSample(offsetSec: 60, hr: 123, drop: 20, peakHR: 143, provenance: .healthKitComputed)]
        let remeasured = try XCTUnwrap(metadata(peak: 161, readings: apple).hrrRemeasuredFromPeak())
        XCTAssertEqual(remeasured.first?.drop, 20)
        XCTAssertEqual(remeasured.first?.hr, 141)
        XCTAssertEqual(remeasured.first?.peakHR, 161)
    }

    func testRepairRewritesTheArchivedWalk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HRRPeakRepair-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        UserDefaults.standard.removeObject(forKey: ArchiveMigrations.hrrPeakRepairDone)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: ArchiveMigrations.hrrPeakRepairDone) }
        let archive = SessionArchive(directory: directory)
        let walk = walkSession(start: ArchiveMigrations.stopReferencedHRRSince.addingTimeInterval(3 * 86_400))
        _ = try archive.archive(walk)

        ArchiveMigrations(archive: archive).repairStopReferencedHRR()

        let stored = try XCTUnwrap(archive.retrieve(walk.id)?.workoutMetadata?.hrrSamples)
        XCTAssertEqual(stored.map(\.drop), [36, 49])
    }

    private func walkSession(start: Date) -> HRVSession {
        var session = HRVSession(startDate: start, sessionType: .workout)
        session.endDate = start.addingTimeInterval(3600)
        session.state = .complete
        let points = (0 ..< 150).map { RRPoint(t_ms: Int64($0 * 800), rr_ms: 800) }
        session.rrSeries = RRSeries(points: points, sessionId: session.id, startDate: start)
        session.workoutMetadata = metadata(peak: 161, readings: stopReferenced)
        return session
    }
}
