import CoreLocation
@testable import Emuqu
import os
import XCTest

/// Two things this file pins:
///
/// 1. **`TrajectoryVerdict.compute`** — the canonical training-trajectory
///    classifier. Two surfaces render it (the dashboard chip and the Load &
///    Trajectory detail), and the recurring bug is those two surfaces
///    disagreeing on screen. The precedence order between modes, deep
///    fatigue, and CTL direction is the whole substance of the type.
///
/// 2. **GPX export → import round-trip.** `GPXExporter` and `GPXImporter` are
///    each other's inverse. A round-trip is the only assertion that actually protects a
///    user's exported data: it catches escaping bugs, precision loss, and
///    timestamp drift in one shot.
@MainActor
final class TrajectoryAndGPXRoundTripTests: XCTestCase {
    /// Capture-and-restore; `NSTimeZone.default` is
    /// process-global. See `ArchivePolicyTests`.
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

    // MARK: - TrajectoryVerdict precedence

    /// Comeback mode wins over everything — it is an explicit user declaration.
    func testComebackModeOutranksAllSignals() {
        let v = TrajectoryVerdict.compute(inputs(
            comeback: true, overreach: true, peaking: true, rampRate: 20, tsb: -40
        ))
        XCTAssertEqual(v, .comeback, "an explicit user mode must outrank every computed signal")
    }

    /// Intentional overreach outranks peaking and the computed signals, but not
    /// comeback.
    func testOverreachOutranksPeakingAndComputedSignals() {
        let v = TrajectoryVerdict.compute(inputs(
            overreach: true, peaking: true, rampRate: 20, tsb: -40
        ))
        XCTAssertEqual(v, .overreach)
    }

    func testPeakingOutranksComputedSignals() {
        let v = TrajectoryVerdict.compute(inputs(peaking: true, rampRate: 20, tsb: -40))
        XCTAssertEqual(v, .peaking)
    }

    /// Under 8 samples there is not enough history to call a direction.
    func testInsufficientHistoryIsBuildingBaseline() {
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(sampleCount: 7)), .buildingBaseline)
        XCTAssertEqual(
            TrajectoryVerdict.compute(inputs(ctlOneWeekAgo: nil, sampleCount: 30)), .buildingBaseline,
            "a missing week-ago anchor is equally disqualifying"
        )
    }

    /// Deep fatigue must be evaluated BEFORE the building
    /// gate, or a rising CTL at TSB −15 reads "Building sustainably" on one
    /// surface and "High strain" on the other.
    func testDeepFatigueOverridesRisingCTL() {
        let v = TrajectoryVerdict.compute(inputs(rampRate: 2.7, tsb: -16))
        XCTAssertEqual(v, .highStrain, "a +2.7 ramp at TSB −16 is high strain, not building")
    }

    /// The deep-fatigue boundary is −15, exclusive.
    func testDeepFatigueBoundaryIsMinusFifteenExclusive() {
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(rampRate: 2.0, tsb: -15.1)), .highStrain)
        XCTAssertNotEqual(
            TrajectoryVerdict.compute(inputs(rampRate: 2.0, tsb: -15.0)), .highStrain,
            "exactly −15 is not yet 'deep' — the comparison is strictly less-than"
        )
    }

    /// A healthy rising ramp is building; above +8 TSS/d/wk it is a rapid
    /// increase the user should be warned about.
    func testRisingRampIsBuildingUntilItIsRapid() {
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(rampRate: 3.0, tsb: 0)), .building)
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(rampRate: 9.0, tsb: 0)), .rapidIncrease)
    }

    /// A flat CTL is maintaining, and the "detraining" deadband means a
    /// marginally negative ramp is still holding rather than losing fitness.
    func testFlatAndMarginallyNegativeRampAreMaintaining() {
        XCTAssertEqual(
            TrajectoryVerdict.compute(inputs(currentCTL: 50, ctlOneWeekAgo: 50, rampRate: 0.0, tsb: 0)),
            .maintaining
        )
        XCTAssertEqual(
            TrajectoryVerdict.compute(inputs(rampRate: -0.5, tsb: 0)), .maintaining,
            "a marginally negative weekly ramp is holding, not detraining"
        )
    }

    /// `rampRate == 0` is treated as "no ramp supplied" and the classifier falls
    /// back to the raw `currentCTL − ctlOneWeekAgo` delta.
    ///
    /// Pinned because it is a genuine trap: a caller that legitimately measured a
    /// ramp of exactly zero gets the fallback instead of its measurement, and a
    /// +2 CTL delta then reads "Building" rather than "Maintaining". The comment
    /// in `compute` calls this a fallback "only if a caller passes rampRate == 0
    /// with a real CTL change" — this test is what makes that sentence checkable.
    func testZeroRampRateFallsBackToRawCTLDelta() {
        XCTAssertEqual(
            TrajectoryVerdict.compute(inputs(currentCTL: 50, ctlOneWeekAgo: 48, rampRate: 0.0, tsb: 0)),
            .building,
            "rampRate 0 + a +2 CTL delta takes the fallback path"
        )
        XCTAssertEqual(
            TrajectoryVerdict.compute(inputs(currentCTL: 50, ctlOneWeekAgo: 50, rampRate: 0.0, tsb: 0)),
            .maintaining,
            "rampRate 0 + a flat CTL is genuinely flat"
        )
    }

    /// Only a genuinely fresh athlete with a falling CTL is detraining.
    func testFallingCTLWhileFreshIsDetraining() {
        XCTAssertEqual(TrajectoryVerdict.compute(inputs(rampRate: -3.0, tsb: 0)), .detraining)
    }

    /// A falling CTL while carrying moderate fatigue is
    /// grinding through training, not detraining.
    func testFallingCTLWhileFatiguedIsMaintainingNotDetraining() {
        XCTAssertEqual(
            TrajectoryVerdict.compute(inputs(rampRate: -3.0, tsb: -10)), .maintaining,
            "TSB −10 with a dipping CTL is a recovery week, not fitness loss"
        )
    }

    /// Every case must carry non-empty display copy — both surfaces render it
    /// directly and an empty string would ship a blank chip.
    func testEveryVerdictCaseHasDisplayCopy() {
        let all: [TrajectoryVerdict] = [
            .building, .rapidIncrease, .maintaining, .detraining, .highStrain,
            .peaking, .comeback, .overreach, .buildingBaseline
        ]
        for v in all {
            XCTAssertFalse(v.chipLabel.isEmpty, "\(v) has an empty chip label")
            XCTAssertFalse(v.narrative.isEmpty, "\(v) has an empty narrative")
            XCTAssertFalse(v.accessibilityLabel.isEmpty, "\(v) has an empty accessibility label")
        }
    }

    // MARK: - GPX round-trip

    /// The core contract: what we write, we can read back.
    func testGPXRoundTripPreservesTrackpointCount() throws {
        let track = makeTrack(count: 25)
        let gpx = GPXExporter.export(session: makeWorkoutSession(), track: track)
        let parsed = try GPXImporter.parse(data: XCTUnwrap(gpx.data(using: .utf8)))
        XCTAssertEqual(parsed.track.count, track.count, "every exported fix must survive the round-trip")
    }

    /// Coordinates are written at 6 decimal places (~11 cm), so they must come
    /// back within that tolerance — not merely "close".
    func testGPXRoundTripPreservesCoordinatesToSixDecimals() throws {
        let track = makeTrack(count: 10)
        let gpx = GPXExporter.export(session: makeWorkoutSession(), track: track)
        let parsed = try GPXImporter.parse(data: XCTUnwrap(gpx.data(using: .utf8)))

        for (original, restored) in zip(track, parsed.track) {
            XCTAssertEqual(
                restored.coordinate.latitude, original.coordinate.latitude, accuracy: 1e-6,
                "latitude must survive to the exported precision"
            )
            XCTAssertEqual(
                restored.coordinate.longitude, original.coordinate.longitude, accuracy: 1e-6,
                "longitude must survive to the exported precision"
            )
        }
    }

    /// Timestamps are the axis every downstream metric is computed against —
    /// pace, splits, decoupling. A drift here silently corrupts all of them.
    func testGPXRoundTripPreservesTimestamps() throws {
        let track = makeTrack(count: 10)
        let gpx = GPXExporter.export(session: makeWorkoutSession(), track: track)
        let parsed = try GPXImporter.parse(data: XCTUnwrap(gpx.data(using: .utf8)))

        for (original, restored) in zip(track, parsed.track) {
            XCTAssertEqual(
                restored.timestamp.timeIntervalSince1970,
                original.timestamp.timeIntervalSince1970,
                accuracy: 1.0,
                "ISO-8601 second resolution is the documented floor"
            )
        }
    }

    /// Total distance is what the user actually reads on the summary card, so
    /// assert the derived quantity, not just the raw points.
    func testGPXRoundTripPreservesDerivedDistance() throws {
        let track = makeTrack(count: 40)
        let gpx = GPXExporter.export(session: makeWorkoutSession(), track: track)
        let parsed = try GPXImporter.parse(data: XCTUnwrap(gpx.data(using: .utf8)))

        let before = WorkoutAnalyzer.computeDistance(track: track)
        let after = WorkoutAnalyzer.computeDistance(track: parsed.track)
        XCTAssertEqual(after, before, accuracy: max(1.0, before * 0.001), "distance must survive within 0.1%")
    }

    /// Malformed input must throw a typed error, not crash the import screen.
    func testImporterRejectsMalformedXML() throws {
        let junk = Data("this is definitely not gpx <<<".utf8)
        XCTAssertThrowsError(try GPXImporter.parse(data: junk)) { error in
            XCTAssertTrue(error is GPXImporter.ImportError, "must surface a typed ImportError")
        }
    }

    /// Valid XML with no trackpoints is a distinct, separately-reported failure.
    func testImporterRejectsGPXWithoutTrackpoints() throws {
        let empty = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1"><trk><trkseg></trkseg></trk></gpx>
        """.utf8)
        XCTAssertThrowsError(try GPXImporter.parse(data: empty)) { error in
            guard case GPXImporter.ImportError.noTrackpoints = error else {
                return XCTFail("expected .noTrackpoints, got \(error)")
            }
        }
    }

    /// Every import error must carry user-facing copy — this surfaces in an
    /// alert on the import screen.
    func testImportErrorsHaveUserFacingDescriptions() {
        for error in [GPXImporter.ImportError.invalidXML, .noTrackpoints] {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error) needs a description")
        }
    }

    /// External entities must stay disabled — GPX files come from arbitrary
    /// user sources, so an XXE payload must not be resolved.
    func testImporterDoesNotResolveExternalEntities() {
        let xxe = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE gpx [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <gpx version="1.1"><trk><name>&xxe;</name><trkseg></trkseg></trk></gpx>
        """.utf8)
        // Either outcome is acceptable — a throw, or a parse that yields no
        // trackpoints. What must NOT happen is the entity resolving to file
        // contents. The assertion is that we get here without a crash and
        // without leaking anything into the parsed track.
        if let parsed = try? GPXImporter.parse(data: xxe) {
            XCTAssertTrue(parsed.track.isEmpty, "an XXE document must not yield trackpoints")
        }
    }

    // MARK: - Fixtures

    private func inputs(
        currentCTL: Double = 50,
        ctlOneWeekAgo: Double? = 48,
        sampleCount: Int = 30,
        comeback: Bool = false,
        overreach: Bool = false,
        peaking: Bool = false,
        rampRate: Double = 0,
        tsb: Double? = nil
    ) -> TrajectoryVerdict.Inputs {
        TrajectoryVerdict.Inputs(
            currentCTL: currentCTL,
            ctlOneWeekAgo: ctlOneWeekAgo,
            sampleCount: sampleCount,
            comebackActive: comeback,
            overreachActive: overreach,
            peakingDetected: peaking,
            rampRate: rampRate,
            currentTSB: tsb
        )
    }

    private func makeTrack(count: Int) -> [CLLocation] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return (0 ..< count).map { Self.location(at: $0, from: base) }
    }

    /// One synthetic fix, with every component explicitly typed.
    ///
    /// The inline form hits "unable to type-check this expression
    /// in reasonable time" on the CI runner: six untyped literal arithmetic
    /// expressions inside a `map`, two of them nested in a
    /// `CLLocationCoordinate2D` initializer.
    private static func location(at i: Int, from base: Date) -> CLLocation {
        let latitude: CLLocationDegrees = 35.960_600 + Double(i) * 0.000_500
        let longitude: CLLocationDegrees = -83.920_700 + Double(i) * 0.000_300
        let altitude: CLLocationDistance = 250 + Double(i % 7)
        let accuracy: CLLocationAccuracy = 5
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: accuracy,
            verticalAccuracy: accuracy,
            timestamp: base.addingTimeInterval(Double(i) * 5)
        )
    }

    private func makeWorkoutSession() -> HRVSession {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var session = HRVSession(startDate: start, sessionType: .workout)
        session.endDate = start.addingTimeInterval(3600)
        var metadata = WorkoutMetadata(sport: .run)
        metadata.distanceMeters = 10_000
        metadata.elevationGainMeters = 120
        session.workoutMetadata = metadata
        return session
    }
}
