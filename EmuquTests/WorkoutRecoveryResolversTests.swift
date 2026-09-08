import CoreLocation
@testable import Emuqu
import XCTest

/// The pure decision steps inside `WorkoutRecoveryService.recover`.
///
/// `recover` reconstructs a workout the user lost to a crash, a force-quit, or
/// a dead strap battery — it is the code that decides whether those minutes
/// survive.
///
/// The three resolution steps are pure, so they are testable without a
/// simulator, a strap, or a disk backup. These tests pin their behaviour — in
/// particular the trailing-rest trim, which exists because an untrimmed strap
/// file archives a short walk as a 5.7-hour session.
@MainActor
final class WorkoutRecoveryResolversTests: XCTestCase {

    private let sessionID = TestUUID.fixed("11111111-2222-3333-4444-555555555555")
    private let start = Date(timeIntervalSince1970: 1_770_000_000)

    /// RR points at a steady heart rate, one per `rrMs`.
    private func beats(count: Int, rrMs: Int, startingAt offsetMs: Int = 0) -> [RRPoint] {
        var points: [RRPoint] = []
        var t = offsetMs
        for _ in 0 ..< count {
            points.append(RRPoint(t_ms: Int64(t), rr_ms: rrMs))
            t += rrMs
        }
        return points
    }

    // MARK: - resolveRRPoints: override path

    /// The manual trim already chose an end, so its points are used verbatim.
    /// Trimming again would silently move the end the user just set.
    func testOverridePointsAreUsedUntrimmedWhenAutoTrimIsOff() {
        let override = beats(count: 400, rrMs: 500) + beats(count: 400, rrMs: 1400, startingAt: 200_000)

        let resolved = WorkoutRecoveryService.resolveRRPoints(
            diskPoints: beats(count: 50, rrMs: 500),
            strapPoints: beats(count: 90, rrMs: 500),
            overridePoints: override,
            autoTrimOverride: false,
            sessionId: sessionID,
            startDate: start
        )

        XCTAssertEqual(resolved.count, override.count,
                       "a manual trim's endpoint must survive verbatim")
        XCTAssertEqual(resolved.last?.t_ms, override.last?.t_ms)
    }

    /// The strap-augment path merges in the full internal recording, which
    /// still carries the post-workout tail — so that one does get trimmed.
    func testOverridePointsAreTrimmedWhenAutoTrimIsOn() {
        let active = beats(count: 400, rrMs: 500)
        let rest = beats(count: 400, rrMs: 1400, startingAt: 200_000)

        let resolved = WorkoutRecoveryService.resolveRRPoints(
            diskPoints: [],
            strapPoints: nil,
            overridePoints: active + rest,
            autoTrimOverride: true,
            sessionId: sessionID,
            startDate: start
        )

        XCTAssertLessThan(resolved.count, (active + rest).count,
                          "auto-trim must cut the trailing rest tail")
        XCTAssertGreaterThan(resolved.count, 0)
    }

    /// An override is authoritative even when it is empty — the caller has
    /// stated the answer. Falling back to disk here would resurrect points the
    /// user just trimmed away.
    func testEmptyOverrideIsRespectedRatherThanFallingBackToDisk() {
        let resolved = WorkoutRecoveryService.resolveRRPoints(
            diskPoints: beats(count: 100, rrMs: 500),
            strapPoints: beats(count: 100, rrMs: 500),
            overridePoints: [],
            autoTrimOverride: false,
            sessionId: sessionID,
            startDate: start
        )

        XCTAssertTrue(resolved.isEmpty, "an explicit empty override must not fall back")
    }

    // MARK: - resolveRRPoints: single-source paths

    func testDiskOnlyIsUsedWhenNoStrapRecordingExists() {
        let disk = beats(count: 60, rrMs: 800)

        for strap in [nil, []] as [[RRPoint]?] {
            let resolved = WorkoutRecoveryService.resolveRRPoints(
                diskPoints: disk,
                strapPoints: strap,
                overridePoints: nil,
                autoTrimOverride: false,
                sessionId: sessionID,
                startDate: start
            )
            XCTAssertEqual(resolved.count, disk.count,
                           "strap=\(String(describing: strap)) should fall through to disk")
        }
    }

    /// The crash case: nothing streamed to disk, but the strap recorded
    /// internally throughout. That recording is the whole workout.
    func testStrapOnlyIsUsedWhenNothingStreamedToDisk() {
        let strap = beats(count: 60, rrMs: 800)

        let resolved = WorkoutRecoveryService.resolveRRPoints(
            diskPoints: [],
            strapPoints: strap,
            overridePoints: nil,
            autoTrimOverride: false,
            sessionId: sessionID,
            startDate: start
        )

        XCTAssertEqual(resolved.count, strap.count)
    }

    func testBothSourcesEmptyYieldsEmpty() {
        let resolved = WorkoutRecoveryService.resolveRRPoints(
            diskPoints: [],
            strapPoints: [],
            overridePoints: nil,
            autoTrimOverride: false,
            sessionId: sessionID,
            startDate: start
        )
        XCTAssertTrue(resolved.isEmpty)
    }

    /// With both sources present the merge runs. Whichever branch it takes,
    /// the result must be non-empty and no longer than everything available —
    /// recovery supplements what streamed, it does not invent beats.
    func testMergingBothSourcesProducesABoundedResult() {
        let disk = beats(count: 200, rrMs: 600)
        let strap = beats(count: 300, rrMs: 600)

        let resolved = WorkoutRecoveryService.resolveRRPoints(
            diskPoints: disk,
            strapPoints: strap,
            overridePoints: nil,
            autoTrimOverride: false,
            sessionId: sessionID,
            startDate: start
        )

        XCTAssertFalse(resolved.isEmpty, "a merge of two real sources must not come back empty")
        XCTAssertLessThanOrEqual(resolved.count, disk.count + strap.count)
    }

    // MARK: - trimTrailingRest

    /// The bug this exists for: a crash leaves the H10 recording, the user
    /// takes the strap off, and it keeps logging slow off-body beats for
    /// hours. Untrimmed, that archived a short walk as a 5.7-hour session.
    func testTrailingRestIsCutFromAWorkoutFollowedByHoursOfOffBodyBeats() {
        let active = beats(count: 600, rrMs: 500)          // ~120 bpm
        let offBody = beats(count: 2_000, rrMs: 1_500, startingAt: 300_000) // ~40 bpm

        let trimmed = WorkoutRecoveryService.trimTrailingRest(active + offBody)

        XCTAssertLessThan(trimmed.count, (active + offBody).count)
        let lastT = trimmed.last?.t_ms ?? 0
        XCTAssertLessThan(Double(lastT) / 1000.0, 3 * 3600,
                          "a trimmed session must not still span hours")
    }

    /// A workout that ends while the user is still working is not a tail.
    func testSteadyEffortThroughoutIsNotTrimmed() {
        let steady = beats(count: 800, rrMs: 520)
        XCTAssertEqual(WorkoutRecoveryService.trimTrailingRest(steady).count, steady.count)
    }

    /// Below the window threshold there is not enough signal to judge, so the
    /// series is returned untouched rather than guessed at.
    func testShortSeriesIsReturnedUnchanged() {
        for count in [0, 1, 20, 100] {
            let points = beats(count: count, rrMs: 600)
            XCTAssertEqual(WorkoutRecoveryService.trimTrailingRest(points).count, count,
                           "\(count) beats is below the judging threshold")
        }
    }

    /// Out-of-range beats (dropouts, contact noise) must not crash the mean.
    func testImplausibleIntervalsAreToleratedWithoutCrashing() {
        var points = beats(count: 400, rrMs: 500)
        points.append(contentsOf: [
            RRPoint(t_ms: 200_000, rr_ms: 5),
            RRPoint(t_ms: 200_100, rr_ms: 9_000),
            RRPoint(t_ms: 200_200, rr_ms: 0)
        ])
        points.append(contentsOf: beats(count: 400, rrMs: 1_400, startingAt: 210_000))

        let trimmed = WorkoutRecoveryService.trimTrailingRest(points)
        XCTAssertFalse(trimmed.isEmpty)
        XCTAssertLessThanOrEqual(trimmed.count, points.count)
    }

    // MARK: - clipTrack

    private func fixes(count: Int, everySec: Int) -> [CLLocation] {
        (0 ..< count).map { i in
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 40 + Double(i) * 0.001, longitude: -105),
                altitude: 1_600, horizontalAccuracy: 5, verticalAccuracy: 5,
                timestamp: start.addingTimeInterval(Double(i * everySec))
            )
        }
    }

    /// A trimmed workout's distance must match its shorter duration — GPS
    /// fixes recorded after the RR series ends are not part of it.
    func testTrackIsClippedToTheLastBeat() {
        let track = fixes(count: 100, everySec: 10)          // 0…990 s
        let rr = beats(count: 200, rrMs: 1_000)              // ends at 200 s

        let clipped = WorkoutRecoveryService.clipTrack(
            track, isOverride: false, rrPoints: rr, startDate: start
        )

        XCTAssertLessThan(clipped.count, track.count)
        let cutoff = start.addingTimeInterval(200)
        XCTAssertTrue(clipped.allSatisfy { $0.timestamp <= cutoff })
    }

    /// A Watch route is the authoritative full route — it did not come from
    /// the phone GPS the crash truncated, so it is never clipped.
    func testOverrideTrackIsReturnedWhole() {
        let track = fixes(count: 100, everySec: 10)
        let rr = beats(count: 10, rrMs: 1_000)

        let clipped = WorkoutRecoveryService.clipTrack(
            track, isOverride: true, rrPoints: rr, startDate: start
        )

        XCTAssertEqual(clipped.count, track.count)
    }

    /// With no RR series there is no endpoint to clip against; an indoor or
    /// strapless workout keeps its whole track.
    func testTrackSurvivesWhenThereAreNoBeats() {
        let track = fixes(count: 40, everySec: 15)
        let clipped = WorkoutRecoveryService.clipTrack(
            track, isOverride: false, rrPoints: [], startDate: start
        )
        XCTAssertEqual(clipped.count, track.count)
    }

    func testEmptyTrackStaysEmpty() {
        XCTAssertTrue(WorkoutRecoveryService.clipTrack(
            [], isOverride: false, rrPoints: beats(count: 50, rrMs: 600), startDate: start
        ).isEmpty)
    }

    // MARK: - resolveEndDate

    /// The last beat is the most reliable "we still had a signal" anchor, so
    /// it wins over a GPS fix that outlived it.
    func testLastBeatWinsOverEveryOtherSource() {
        let rr = beats(count: 120, rrMs: 1_000)            // ends at 120 s
        let track = fixes(count: 100, everySec: 10)        // runs to 990 s

        let end = WorkoutRecoveryService.resolveEndDate(
            startDate: start, rrPoints: rr, track: track, liveSamples: [], baroSamples: []
        )

        XCTAssertEqual(end.timeIntervalSince(start), 120, accuracy: 1)
    }

    /// A GPS-only workout — strap never connected — still gets a real duration.
    func testLastFixIsUsedWhenThereAreNoBeats() {
        let track = fixes(count: 61, everySec: 10)          // ends at 600 s

        let end = WorkoutRecoveryService.resolveEndDate(
            startDate: start, rrPoints: [], track: track, liveSamples: [], baroSamples: []
        )

        XCTAssertEqual(end.timeIntervalSince(start), 600, accuracy: 1)
    }

    /// An indoor workout with neither beats nor GPS falls back to barometry,
    /// which a stair climb or treadmill still produces.
    func testBarometerIsTheLastRealSignalBeforeGivingUp() {
        let baro = (0 ..< 30).map {
            WorkoutTrackBackup.PersistedBaro(
                timestamp: start.addingTimeInterval(Double($0 * 20)), altitudeMeters: 1_600
            )
        }

        let end = WorkoutRecoveryService.resolveEndDate(
            startDate: start, rrPoints: [], track: [], liveSamples: [], baroSamples: baro
        )

        XCTAssertEqual(end.timeIntervalSince(start), 580, accuracy: 1)
    }

    /// Nothing at all: returns `startDate`, which the caller's
    /// `endDate <= startDate` guard is there to catch. Pinned so the fallback
    /// stays a detectable sentinel rather than drifting to some plausible-but-
    /// invented duration.
    func testNoSignalAtAllReturnsTheStartDate() {
        let end = WorkoutRecoveryService.resolveEndDate(
            startDate: start, rrPoints: [], track: [], liveSamples: [], baroSamples: []
        )
        XCTAssertEqual(end, start)
    }

    /// The resolved end is never before the start for any real signal — an
    /// inverted range would produce a negative duration downstream.
    func testResolvedEndIsNeverBeforeStartForRealSignals() {
        let cases: [(String, [RRPoint], [CLLocation])] = [
            ("beats", beats(count: 300, rrMs: 700), []),
            ("track", [], fixes(count: 50, everySec: 30)),
            ("both", beats(count: 300, rrMs: 700), fixes(count: 50, everySec: 30))
        ]
        for (label, rr, track) in cases {
            let end = WorkoutRecoveryService.resolveEndDate(
                startDate: start, rrPoints: rr, track: track, liveSamples: [], baroSamples: []
            )
            XCTAssertGreaterThanOrEqual(end, start, "\(label) produced an inverted range")
        }
    }

    // MARK: - buildMetadata

    private func analyzed(distance: Double?, trimp: Double? = 90) -> WorkoutMetadata {
        var m = WorkoutMetadata(sport: .run)
        m.distanceMeters = distance
        m.luciaTRIMP = trimp
        m.splits = []
        return m
    }

    /// HealthKit's passive walking/running total beats the GPS-derived
    /// distance: the Watch logs it even when the app's own track was cut
    /// short by the crash.
    func testHealthKitDistanceOverridesTheGPSDistance() {
        let metadata = WorkoutRecoveryService.buildMetadata(
            sport: .run,
            computed: analyzed(distance: 1_200),
            baroSamples: [],
            liveSamples: [],
            reason: .appCrashed,
            overrideDistanceMeters: 4_800
        )
        XCTAssertEqual(metadata.distanceMeters, 4_800)
    }

    /// The override is guarded on `> 0` — a zero must never wipe a real
    /// distance the analyzer computed.
    func testZeroOverrideDoesNotWipeARealDistance() {
        for override in [0.0, -1.0] {
            let metadata = WorkoutRecoveryService.buildMetadata(
                sport: .run,
                computed: analyzed(distance: 1_200),
                baroSamples: [],
                liveSamples: [],
                reason: .appCrashed,
                overrideDistanceMeters: override
            )
            XCTAssertEqual(metadata.distanceMeters, 1_200,
                           "override \(override) should be ignored")
        }
    }

    func testNoOverrideKeepsTheComputedDistance() {
        let metadata = WorkoutRecoveryService.buildMetadata(
            sport: .run,
            computed: analyzed(distance: 1_200),
            baroSamples: [],
            liveSamples: [],
            reason: .appCrashed,
            overrideDistanceMeters: nil
        )
        XCTAssertEqual(metadata.distanceMeters, 1_200)
    }

    /// Elevation comes from the barometer, which keeps working when GPS does
    /// not — and is the better source for gain/loss either way.
    func testElevationIsDerivedFromBarometrySamples() {
        let climb = (0 ..< 60).map {
            WorkoutTrackBackup.PersistedBaro(
                timestamp: start.addingTimeInterval(Double($0 * 10)),
                altitudeMeters: 1_600 + Double($0) * 2
            )
        }
        let metadata = WorkoutRecoveryService.buildMetadata(
            sport: .run,
            computed: analyzed(distance: 5_000),
            baroSamples: climb,
            liveSamples: [],
            reason: .appCrashed,
            overrideDistanceMeters: nil
        )
        XCTAssertNotNil(metadata.elevationGainMeters)
        XCTAssertGreaterThan(metadata.elevationGainMeters ?? 0, 0)
    }

    func testNoBarometryLeavesElevationUnset() {
        let metadata = WorkoutRecoveryService.buildMetadata(
            sport: .run,
            computed: analyzed(distance: 5_000),
            baroSamples: [],
            liveSamples: [],
            reason: .appCrashed,
            overrideDistanceMeters: nil
        )
        XCTAssertNil(metadata.elevationGainMeters)
        XCTAssertNil(metadata.elevationLossMeters)
    }

    /// Empty live samples store as `nil`, not `[]` — the archive treats an
    /// empty array and absence differently when rendering the summary.
    func testEmptyLiveSamplesStoreAsNil() {
        let metadata = WorkoutRecoveryService.buildMetadata(
            sport: .run,
            computed: analyzed(distance: 100),
            baroSamples: [],
            liveSamples: [],
            reason: .appCrashed,
            overrideDistanceMeters: nil
        )
        XCTAssertNil(metadata.samples)
    }

    /// Every recovered session is stamped so the UI can show the "Estimated"
    /// badge and the reason it was recovered.
    func testRecoveryIsAlwaysStamped() {
        let metadata = WorkoutRecoveryService.buildMetadata(
            sport: .bike,
            computed: analyzed(distance: 100),
            baroSamples: [],
            liveSamples: [],
            reason: .strapDisconnected,
            overrideDistanceMeters: nil
        )
        XCTAssertEqual(metadata.partialDataReason, .strapDisconnected)
        XCTAssertNotNil(metadata.recoveredAt)
        XCTAssertEqual(metadata.sport, .bike)
    }

    // MARK: - backfillRouteFields

    /// The trim path: an already-recovered session is re-finalized after its
    /// GPS backup was deleted. The off-body tail being cut had no GPS, so the
    /// distance the first recovery computed must survive.
    func testBackfillRestoresDistanceWhenTheRecomputeFoundNone() {
        var fresh = WorkoutMetadata(sport: .run)
        fresh.distanceMeters = 0

        var existing = WorkoutMetadata(sport: .run)
        existing.distanceMeters = 5_400
        existing.gpsPolyline = Data("abc".utf8)
        existing.elevationGainMeters = 120
        existing.elevationLossMeters = 110

        WorkoutRecoveryService.backfillRouteFields(into: &fresh, from: existing)

        XCTAssertEqual(fresh.distanceMeters, 5_400, "a trim must not zero a real distance")
        XCTAssertEqual(fresh.gpsPolyline, Data("abc".utf8))
        XCTAssertEqual(fresh.elevationGainMeters, 120)
        XCTAssertEqual(fresh.elevationLossMeters, 110)
    }

    /// A real recomputed value always wins — backfill fills gaps, it does not
    /// overwrite.
    func testBackfillNeverOverwritesARecomputedValue() {
        var fresh = WorkoutMetadata(sport: .run)
        fresh.distanceMeters = 3_000
        fresh.gpsPolyline = Data("new".utf8)
        fresh.elevationGainMeters = 50

        var existing = WorkoutMetadata(sport: .run)
        existing.distanceMeters = 5_400
        existing.gpsPolyline = Data("old".utf8)
        existing.elevationGainMeters = 120

        WorkoutRecoveryService.backfillRouteFields(into: &fresh, from: existing)

        XCTAssertEqual(fresh.distanceMeters, 3_000)
        XCTAssertEqual(fresh.gpsPolyline, Data("new".utf8))
        XCTAssertEqual(fresh.elevationGainMeters, 50)
    }

    /// An empty splits array counts as absent — that is the shape a
    /// track-less recompute produces.
    func testEmptySplitsAreTreatedAsAbsent() {
        var fresh = WorkoutMetadata(sport: .run)
        fresh.splits = []

        var existing = WorkoutMetadata(sport: .run)
        existing.splits = [Split(
            index: 1, distanceMeters: 1_000, durationSeconds: 300,
            averageHR: 150, averagePaceSecPerKm: 300, elevationGainMeters: nil
        )]

        WorkoutRecoveryService.backfillRouteFields(into: &fresh, from: existing)

        XCTAssertEqual(fresh.splits?.count, 1)
    }

    /// Backfilling from an empty prior recovery leaves nothing behind — no
    /// invented values.
    func testBackfillFromEmptyExistingChangesNothing() {
        var fresh = WorkoutMetadata(sport: .run)
        fresh.distanceMeters = 0

        WorkoutRecoveryService.backfillRouteFields(into: &fresh, from: WorkoutMetadata(sport: .run))

        XCTAssertEqual(fresh.distanceMeters ?? 0, 0)
        XCTAssertNil(fresh.gpsPolyline)
    }
}
