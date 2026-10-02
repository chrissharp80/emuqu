import CoreLocation
@testable import Emuqu
import XCTest

/// Pure logic from the acquisition layer — `Collection/` and `Services/`.
///
/// Those two directories sat at ~16% line coverage across 34,595 executable
/// lines while `Analysis/` was above 60%. That inversion is the wrong way
/// round: `Analysis/` consumes what acquisition produces, so a defect here
/// corrupts the *input* to the well-tested math and no amount of analysis
/// coverage catches it.
///
/// Most of that 16% is genuinely untestable — `PolarManager+Recording` is 1,928
/// lines of `async` BLE I/O against real hardware, and pretending otherwise
/// would produce tests that assert nothing. What *is* testable is the pure
/// decision logic threaded through it: sleep-window boundaries, street-name
/// normalisation, bearings. That is what this file covers.
final class AcquisitionPureLogicTests: XCTestCase {

    // MARK: - SleepSchedule window boundaries

    private let calendar = Calendar.current

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        guard let date = calendar.date(from: c) else {
            XCTFail("could not build \(y)-\(mo)-\(d) \(h):\(mi) in \(calendar.timeZone.identifier)")
            return Date()
        }
        return date
    }

    /// Wake time is bedtime + sleepHours, wrapping past midnight.
    func testWakeTimeArithmeticWrapsPastMidnight() {
        let tenPmEight = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)
        XCTAssertEqual(tenPmEight.wakeHour, 6)
        XCTAssertEqual(tenPmEight.wakeMinute, 0)

        let halfPastElevenSeven = SleepSchedule(bedtimeHour: 23, bedtimeMinute: 30, sleepHours: 7.25)
        XCTAssertEqual(halfPastElevenSeven.wakeHour, 6)
        XCTAssertEqual(halfPastElevenSeven.wakeMinute, 45)
    }

    /// A schedule that does not cross midnight at all — an afternoon napper's
    /// settings, or a night-shift worker sleeping 09:00–17:00.
    func testWakeTimeArithmeticWithoutMidnightCrossing() {
        let dayShift = SleepSchedule(bedtimeHour: 9, bedtimeMinute: 0, sleepHours: 8.0)
        XCTAssertEqual(dayShift.wakeHour, 17)
        XCTAssertEqual(dayShift.wakeMinute, 0)
    }

    /// **The invariant the whole overnight pipeline rests on**: two recordings
    /// that belong to the same biological night must resolve to the same anchor,
    /// so they are grouped as one night rather than two.
    ///
    /// A 23:30 recording and an 06:30 recording the next morning are one night.
    func testPreMidnightAndNextMorningShareAnAnchor() {
        let schedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)
        let lateNight = date(2026, 3, 10, 23, 30)
        let nextMorning = date(2026, 3, 11, 6, 30)

        XCTAssertEqual(
            schedule.overnightWindowStart(relativeTo: lateNight),
            schedule.overnightWindowStart(relativeTo: nextMorning),
            "a 23:30 reading and the 06:30 reading after it are the same night"
        )
    }

    /// The AM-bedtime case the implementation's 18-hour guard exists for: a user
    /// who goes to bed at 02:00. Bedtime-minus-two-hours lands at midnight on
    /// the same calendar day as an evening session, which without the guard
    /// would assign that evening session to the *previous* biological night.
    func testAMBedtimeGroupsTheNightCorrectly() {
        let owl = SleepSchedule(bedtimeHour: 2, bedtimeMinute: 0, sleepHours: 7.0)
        let beforeMidnight = date(2026, 5, 20, 23, 0)
        let afterMidnight = date(2026, 5, 21, 3, 0)

        XCTAssertEqual(
            owl.overnightWindowStart(relativeTo: beforeMidnight),
            owl.overnightWindowStart(relativeTo: afterMidnight),
            "23:00 and 03:00 are the same night for an 02:00 bedtime"
        )
    }

    /// The guard's own contract: the anchor is never more than 18 hours BEFORE
    /// the session it anchors. (It may sit slightly after — see
    /// `testAnchorOvershootIsBoundedBySixHours`.)
    func testAnchorIsNeverMoreThanEighteenHoursBack() {
        for bedtimeHour in 0 ... 23 {
            let schedule = SleepSchedule(bedtimeHour: bedtimeHour, bedtimeMinute: 0, sleepHours: 8.0)
            for sessionHour in 0 ... 23 {
                let session = date(2026, 7, 15, sessionHour, 0)
                let anchor = schedule.overnightWindowStart(relativeTo: session)
                let gap = session.timeIntervalSince(anchor)
                XCTAssertLessThanOrEqual(
                    gap, 18 * 3600 + 1,
                    "bedtime \(bedtimeHour):00, session \(sessionHour):00 — anchor \(gap / 3600)h back"
                )
            }
        }
    }

    /// The anchor may legitimately FOLLOW the session, and this pins why.
    ///
    /// A first pass asserted `anchor <= session` as an obvious invariant. It is
    /// not one. For an AM bedtime the window opens at bedtime−2h, so the night
    /// containing a 23:00 reading starts at 00:00 the *next* day — the reading
    /// belongs to a night that has not begun yet. "Fixing" the code to satisfy
    /// the wrong invariant split that 23:00 reading from the 03:00 reading four
    /// hours later, which is precisely the grouping the 18-hour guard exists to
    /// preserve.
    ///
    /// What actually holds is *bounded* overshoot, and the bound falls straight
    /// out of the guard: the bump moves the anchor forward exactly 24 h, and it
    /// only fires when the gap already exceeds 18 h. So the post-bump gap lands
    /// in (18 − 24, 0] — the anchor can sit at most **6 hours** ahead of the
    /// session, never more. Measured worst case: 5.25 h, at a 00:30 bedtime
    /// with a 17:15 reading.
    func testAnchorOvershootIsBoundedBySixHours() {
        for bedtimeHour in 0 ... 23 {
            let schedule = SleepSchedule(bedtimeHour: bedtimeHour, bedtimeMinute: 30, sleepHours: 7.5)
            for sessionHour in 0 ... 23 {
                let session = date(2026, 9, 2, sessionHour, 15)
                let anchor = schedule.overnightWindowStart(relativeTo: session)
                let overshoot = anchor.timeIntervalSince(session)
                XCTAssertLessThan(
                    overshoot, 6 * 3600,
                    "bedtime \(bedtimeHour):30, session \(sessionHour):15 — anchor \(overshoot / 3600)h ahead"
                )
            }
        }
    }

    /// Window ordering. These feed a HealthKit query range, and an inverted
    /// range returns nothing at all — a silently empty sleep night rather than
    /// an error.
    func testOvernightWindowIsOrdered() {
        for bedtimeHour in 0 ... 23 {
            let schedule = SleepSchedule(bedtimeHour: bedtimeHour, bedtimeMinute: 0, sleepHours: 8.0)
            let session = date(2026, 11, 4, 7, 0)
            XCTAssertLessThan(
                schedule.overnightWindowStart(relativeTo: session),
                schedule.overnightWindowEnd(relativeTo: session),
                "bedtime \(bedtimeHour):00 produced an inverted overnight window"
            )
        }
    }

    /// Regression: this window was inverted for every schedule that sleeps
    /// through midnight — including the shipped default of 22:00 + 8 h.
    /// `daytimeHRStart` shifted wake forward a day and `daytimeHREnd` did not
    /// shift bedtime, so start landed a full day after end. Both bounds go
    /// straight into an `HKQuery` predicate, so the query matched nothing and
    /// daytime resting HR silently never resolved for anybody.
    func testDaytimeHRWindowIsOrdered() {
        for bedtimeHour in 0 ... 23 {
            let schedule = SleepSchedule(bedtimeHour: bedtimeHour, bedtimeMinute: 0, sleepHours: 8.0)
            let session = date(2026, 11, 4, 12, 0)
            XCTAssertLessThan(
                schedule.daytimeHRStart(relativeTo: session),
                schedule.daytimeHREnd(relativeTo: session),
                "bedtime \(bedtimeHour):00 produced an inverted daytime-HR window"
            )
        }
    }

    /// Morning cutoff is wake + 4h, so it must sit inside the overnight window's
    /// tail (which runs to wake + 4.5h) and after the window opens.
    func testMorningCutoffSitsBetweenWindowStartAndEnd() {
        let schedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 30, sleepHours: 7.5)
        let session = date(2026, 6, 1, 6, 45)

        let start = schedule.overnightWindowStart(relativeTo: session)
        let cutoff = schedule.morningCutoff(forNightStartingAt: start)
        let end = schedule.overnightWindowEnd(relativeTo: session)

        XCTAssertLessThan(start, cutoff)
        XCTAssertLessThanOrEqual(cutoff, end)
        XCTAssertEqual(end.timeIntervalSince(cutoff), 0.5 * 3600, accuracy: 1)
    }

    /// An anchor after midnight — a morning reading, a night started at 00:15,
    /// `fetchLastNightSleep`'s start-of-day — must get THIS morning's wake.
    /// It used to get tomorrow's, so the window spanned two nights and
    /// re-scoring an old reading added both nights' sleep together.
    func testAnchorAfterMidnightWindowHoldsOneNight() {
        let schedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 30, sleepHours: 8.0)
        for anchor in [date(2026, 6, 2, 0, 0), date(2026, 6, 2, 0, 15), date(2026, 6, 2, 7, 0)] {
            let start = schedule.overnightWindowStart(relativeTo: anchor)
            let end = schedule.overnightWindowEnd(relativeTo: anchor)
            XCTAssertEqual(start, date(2026, 6, 1, 20, 30), "start for \(anchor)")
            XCTAssertEqual(end, date(2026, 6, 2, 11, 0), "end for \(anchor)")
            XCTAssertEqual(
                schedule.morningCutoff(forNightStartingAt: start), date(2026, 6, 2, 10, 30),
                "cutoff for \(anchor)"
            )
        }
    }

    /// An evening anchor is unchanged: bedtime−2h to the next wake + 4.5h.
    func testEveningAnchorWindowIsUnchanged() {
        let schedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 30, sleepHours: 8.0)
        let anchor = date(2026, 6, 1, 22, 45)
        XCTAssertEqual(schedule.overnightWindowStart(relativeTo: anchor), date(2026, 6, 1, 20, 30))
        XCTAssertEqual(schedule.overnightWindowEnd(relativeTo: anchor), date(2026, 6, 2, 11, 0))
    }

    /// An AM bedtime: 02:00 with 7 h sleep wakes at 09:00 the same calendar day
    /// as the window opens (00:00). The end used to be taken from the anchor's
    /// day without a shift, so for a 23:00 anchor it fell BEFORE the start.
    func testAMBedtimeWindowEndsAfterItsStart() {
        let schedule = SleepSchedule(bedtimeHour: 2, bedtimeMinute: 0, sleepHours: 7.0)
        let anchor = date(2026, 6, 1, 23, 0)
        let start = schedule.overnightWindowStart(relativeTo: anchor)
        XCTAssertEqual(start, date(2026, 6, 2, 0, 0))
        XCTAssertEqual(schedule.overnightWindowEnd(relativeTo: anchor), date(2026, 6, 2, 13, 30))
    }

    /// Spring forward. The US DST transition (8 March 2026) skips 02:00 → 03:00,
    /// so the civil day is 23 hours long. The window must still be ordered and
    /// still anchor the night correctly — this is the class of bug that made
    /// "did I train yesterday?" answer about the wrong day.
    func testSpringForwardKeepsWindowOrderedAndAnchored() {
        let schedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)
        let nightOf = date(2026, 3, 7, 23, 0)
        let morningAfter = date(2026, 3, 8, 7, 0)

        XCTAssertLessThan(
            schedule.overnightWindowStart(relativeTo: morningAfter),
            schedule.overnightWindowEnd(relativeTo: morningAfter)
        )
        XCTAssertEqual(
            schedule.overnightWindowStart(relativeTo: nightOf),
            schedule.overnightWindowStart(relativeTo: morningAfter),
            "the spring-forward night must still group as one night"
        )
    }

    /// Fall back — the civil day is 25 hours long and 01:00–02:00 happens twice.
    func testFallBackKeepsWindowOrderedAndAnchored() {
        let schedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)
        let nightOf = date(2026, 11, 1, 23, 0)
        let morningAfter = date(2026, 11, 2, 7, 0)

        XCTAssertLessThan(
            schedule.overnightWindowStart(relativeTo: morningAfter),
            schedule.overnightWindowEnd(relativeTo: morningAfter)
        )
        XCTAssertEqual(
            schedule.overnightWindowStart(relativeTo: nightOf),
            schedule.overnightWindowStart(relativeTo: morningAfter),
            "the fall-back night must still group as one night"
        )
    }

    /// Every day of a full year, for a spread of schedules: the window is
    /// ordered and the anchor is sane. This is the cheap way to catch a
    /// calendar edge nobody thought to name.
    func testWindowInvariantsHoldEveryDayOfTheYear() {
        let schedules = [
            SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0),
            SleepSchedule(bedtimeHour: 0, bedtimeMinute: 30, sleepHours: 6.5),
            SleepSchedule(bedtimeHour: 2, bedtimeMinute: 0, sleepHours: 7.0),
            SleepSchedule(bedtimeHour: 21, bedtimeMinute: 45, sleepHours: 9.25)
        ]
        var day = date(2026, 1, 1, 6, 30)
        for _ in 0 ..< 365 {
            for schedule in schedules {
                let start = schedule.overnightWindowStart(relativeTo: day)
                let end = schedule.overnightWindowEnd(relativeTo: day)
                XCTAssertLessThan(start, end, "inverted window on \(day)")
                XCTAssertLessThan(end.timeIntervalSince(start), 24 * 3600, "window holds two nights on \(day)")
                XCTAssertLessThanOrEqual(start, day, "anchor after session on \(day)")
                XCTAssertLessThanOrEqual(
                    day.timeIntervalSince(start), 18 * 3600 + 1,
                    "anchor too far back on \(day)"
                )
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
    }

    // MARK: - Street-name normalisation

    /// Used to decide whether two geocoder results name the same road. Over-
    /// normalising merges distinct streets; under-normalising reports a
    /// cross-street the user is already on.
    func testStreetSuffixesAreStripped() {
        XCTAssertEqual(RoadGeocodingService.normalizeStreetName("Main Street"), "main")
        XCTAssertEqual(RoadGeocodingService.normalizeStreetName("Main St"), "main")
        XCTAssertEqual(RoadGeocodingService.normalizeStreetName("MAIN STREET"), "main")
    }

    /// The point of normalising: the abbreviated and spelled-out forms of the
    /// same road must compare equal.
    func testAbbreviatedAndSpelledOutFormsMatch() {
        let pairs = [
            ("Oak Ave", "Oak Avenue"),
            ("Sunset Blvd", "Sunset Boulevard"),
            ("Cedar Rd", "Cedar Road"),
            ("Elm Dr", "Elm Drive"),
            ("Park Ln", "Park Lane"),
            ("River Pkwy", "River Parkway"),
            ("Ridge Hwy", "Ridge Highway"),
            ("Hill Ct", "Hill Court"),
            ("Vine Pl", "Vine Place"),
            ("Lake Cir", "Lake Circle"),
            ("Fox Tr", "Fox Trail"),
            ("Bay Ter", "Bay Terrace")
        ]
        for (short, long) in pairs {
            XCTAssertEqual(
                RoadGeocodingService.normalizeStreetName(short),
                RoadGeocodingService.normalizeStreetName(long),
                "\(short) and \(long) should normalise the same"
            )
        }
    }

    func testDirectionalPrefixesAreStripped() {
        XCTAssertEqual(
            RoadGeocodingService.normalizeStreetName("N Main St"),
            RoadGeocodingService.normalizeStreetName("S Main St"),
            "directionals are stripped, so N and S Main compare equal"
        )
        XCTAssertEqual(RoadGeocodingService.normalizeStreetName("NW Broadway"), "broadway")
    }

    func testMultiWordNamesSurvive() {
        XCTAssertEqual(RoadGeocodingService.normalizeStreetName("Martin Luther King Jr Blvd"),
                       "martin luther king jr")
        XCTAssertEqual(RoadGeocodingService.normalizeStreetName("Old Mill Road"), "old mill")
    }

    func testNilAndEmptyAreHandled() {
        XCTAssertEqual(RoadGeocodingService.normalizeStreetName(nil), "")
        XCTAssertEqual(RoadGeocodingService.normalizeStreetName(""), "")
        XCTAssertEqual(RoadGeocodingService.normalizeStreetName("   "), "")
    }

    /// A name made *entirely* of suffix words normalises to empty. Worth
    /// pinning: the caller must not treat "" as a match for every street.
    func testNameOfOnlySuffixWordsNormalisesToEmpty() {
        XCTAssertEqual(RoadGeocodingService.normalizeStreetName("Broadway"), "broadway")
        XCTAssertEqual(RoadGeocodingService.normalizeStreetName("Circle"), "")
        XCTAssertEqual(RoadGeocodingService.normalizeStreetName("N"), "")
    }

    func testIrregularWhitespaceIsCollapsed() {
        XCTAssertEqual(RoadGeocodingService.normalizeStreetName("  Main   Street  "), "main")
        XCTAssertEqual(RoadGeocodingService.normalizeStreetName("Main\tStreet"), "main")
    }

    // MARK: - Bearing

    private func coord(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Cardinal directions from a reference point. A sign or quadrant error here
    /// names the wrong cross-street, which reads as the assistant being
    /// confidently wrong rather than unavailable.
    func testCardinalBearings() {
        let origin = coord(40.0, -105.0)
        XCTAssertEqual(bearingDegrees(from: origin, to: coord(41.0, -105.0)), 0, accuracy: 0.5, "north")
        XCTAssertEqual(bearingDegrees(from: origin, to: coord(40.0, -104.0)), 90, accuracy: 0.5, "east")
        XCTAssertEqual(bearingDegrees(from: origin, to: coord(39.0, -105.0)), 180, accuracy: 0.5, "south")
        XCTAssertEqual(bearingDegrees(from: origin, to: coord(40.0, -106.0)), 270, accuracy: 0.5, "west")
    }

    func testDiagonalBearingsLandInTheRightQuadrant() {
        let origin = coord(40.0, -105.0)
        let ne = bearingDegrees(from: origin, to: coord(40.5, -104.5))
        let se = bearingDegrees(from: origin, to: coord(39.5, -104.5))
        let sw = bearingDegrees(from: origin, to: coord(39.5, -105.5))
        let nw = bearingDegrees(from: origin, to: coord(40.5, -105.5))

        XCTAssertTrue((0 ... 90).contains(ne), "NE was \(ne)")
        XCTAssertTrue((90 ... 180).contains(se), "SE was \(se)")
        XCTAssertTrue((180 ... 270).contains(sw), "SW was \(sw)")
        XCTAssertTrue((270 ... 360).contains(nw), "NW was \(nw)")
    }

    /// The normalisation contract: always `[0, 360)`, never negative.
    func testBearingIsAlwaysNormalised() {
        let origin = coord(51.5, -0.12)
        for latOffset in stride(from: -2.0, through: 2.0, by: 0.5) {
            for lonOffset in stride(from: -2.0, through: 2.0, by: 0.5) {
                if latOffset == 0, lonOffset == 0 { continue }
                let bearing = bearingDegrees(
                    from: origin,
                    to: coord(51.5 + latOffset, -0.12 + lonOffset)
                )
                XCTAssertGreaterThanOrEqual(bearing, 0)
                XCTAssertLessThan(bearing, 360)
                XCTAssertFalse(bearing.isNaN, "NaN bearing at \(latOffset),\(lonOffset)")
            }
        }
    }

    /// Crossing the antimeridian. A naive longitude subtraction reports the
    /// bearing 180° wrong here — the long way round the planet.
    func testBearingAcrossTheAntimeridian() {
        let west = coord(0.0, 179.5)
        let east = coord(0.0, -179.5)
        XCTAssertEqual(bearingDegrees(from: west, to: east), 90, accuracy: 1.0,
                       "179.5°E to 179.5°W is a short hop east, not a trip west")
        XCTAssertEqual(bearingDegrees(from: east, to: west), 270, accuracy: 1.0)
    }

    /// Identical points. Degenerate, but reachable: a stationary user, or two
    /// geocoder results at the same pin. Must not be NaN.
    func testBearingBetweenIdenticalPointsIsFinite() {
        let point = coord(37.77, -122.42)
        let bearing = bearingDegrees(from: point, to: point)
        XCTAssertFalse(bearing.isNaN)
        XCTAssertGreaterThanOrEqual(bearing, 0)
        XCTAssertLessThan(bearing, 360)
    }

    /// Reversing the endpoints turns the bearing by 180° (within the
    /// great-circle convergence you get at short range).
    func testReverseBearingIsRoughlyOpposite() {
        let a = coord(45.0, 9.0)
        let b = coord(45.05, 9.05)
        let forward = bearingDegrees(from: a, to: b)
        let back = bearingDegrees(from: b, to: a)
        // Signed separation normalised into [0, 360), then compared to 180.
        let separation = (back - forward + 360).truncatingRemainder(dividingBy: 360)
        XCTAssertEqual(separation, 180, accuracy: 1.0, "forward \(forward), back \(back)")
    }
}
