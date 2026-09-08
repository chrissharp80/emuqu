@testable import Emuqu
import XCTest

/// Tests for `METLookup`, the published MET tables behind active-energy
/// estimation. These numbers are written to Apple Health, so the tables are
/// checked for structural invariants as well as spot values.
final class METLookupTests: XCTestCase {
    // MARK: - Table invariants

    /// Every table must terminate at `.infinity`, or a fast enough athlete
    /// falls off the end of the lookup and gets no MET value at all.
    func testEveryTableTerminatesAtInfinity() {
        for table in METLookup.allTables {
            XCTAssertEqual(
                table.bands.last?.upperKmh, .infinity,
                "\(table.name) table does not terminate at .infinity"
            )
        }
    }

    /// Bands are consumed by `first(where: kmh < upperKmh)`, so an out-of-order
    /// ceiling would make a row unreachable and silently mis-score a speed.
    func testBandCeilingsAreStrictlyAscending() {
        for table in METLookup.allTables {
            let ceilings = table.bands.map(\.upperKmh)
            XCTAssertEqual(
                ceilings, ceilings.sorted(),
                "\(table.name) ceilings are not ascending"
            )
            XCTAssertEqual(
                Set(ceilings).count, ceilings.count,
                "\(table.name) has a duplicate ceiling, making a row unreachable"
            )
        }
    }

    /// Harder effort must never score fewer METs than easier effort.
    func testMETsIncreaseWithSpeed() {
        for table in METLookup.allTables {
            let mets = table.bands.map(\.mets)
            XCTAssertEqual(mets, mets.sorted(), "\(table.name) METs are not monotonic")
        }
    }

    /// A resting adult is 1.0 MET. Any band at or below that would report a
    /// moving athlete as burning no more than they would asleep.
    func testEveryBandIsAboveRestingMetabolicRate() {
        for table in METLookup.allTables {
            for band in table.bands {
                XCTAssertGreaterThan(
                    band.mets, 1.0,
                    "\(table.name) has a band at or below resting metabolic rate"
                )
            }
        }
    }

    // MARK: - Lookup boundaries

    /// Below a walking crawl the pace calculation is sitting on the GPS-jitter
    /// gate; a METs number there is noise, so the lookup declines to guess.
    func testSpeedBelowWalkingCrawlReturnsNil() {
        XCTAssertNil(METLookup.mets(sport: .walk, speedKmh: 1.19))
        XCTAssertNil(METLookup.mets(sport: .run, speedKmh: 0))
        XCTAssertNil(METLookup.mets(sport: .bike, speedKmh: -5))
    }

    func testSpeedAtWalkingCrawlFloorIsScored() {
        XCTAssertEqual(METLookup.mets(sport: .walk, speedKmh: 1.2), 2.0)
    }

    /// `Double.nan` and `.infinity` reach here from a pace division; neither
    /// may produce a number that gets written to Health.
    func testNonFiniteSpeedReturnsNil() {
        XCTAssertNil(METLookup.mets(sport: .run, speedKmh: .nan))
        XCTAssertNil(METLookup.mets(sport: .run, speedKmh: .infinity))
        XCTAssertNil(METLookup.mets(sport: .run, speedKmh: -.infinity))
    }

    /// `.greatestFiniteMagnitude` is finite, so it passes the guard and must
    /// land in the terminal band rather than falling through to nil.
    func testAbsurdlyFastSpeedLandsInTerminalBand() {
        XCTAssertEqual(METLookup.mets(sport: .run, speedKmh: .greatestFiniteMagnitude), 16.0)
    }

    /// Bands are half-open: `kmh < upperKmh`, so a speed exactly on a ceiling
    /// belongs to the band above it.
    func testCeilingSpeedBelongsToTheNextBandUp() {
        XCTAssertEqual(METLookup.mets(sport: .walk, speedKmh: 2.99), 2.0)
        XCTAssertEqual(METLookup.mets(sport: .walk, speedKmh: 3.0), 3.0)
    }

    // MARK: - Per-sport spot values

    func testWalkBandsMatchCompendium() {
        XCTAssertEqual(METLookup.mets(sport: .walk, speedKmh: 2.0), 2.0)   // stroll
        XCTAssertEqual(METLookup.mets(sport: .walk, speedKmh: 5.0), 3.5)   // brisk
        XCTAssertEqual(METLookup.mets(sport: .walk, speedKmh: 20.0), 5.0)  // terminal
    }

    func testRunBandsMatchCompendium() {
        XCTAssertEqual(METLookup.mets(sport: .run, speedKmh: 6.0), 6.0)    // slow jog
        XCTAssertEqual(METLookup.mets(sport: .run, speedKmh: 12.0), 11.8)  // 5:00/km
        XCTAssertEqual(METLookup.mets(sport: .run, speedKmh: 20.0), 16.0)  // terminal
    }

    func testBikeBandsMatchCompendium() {
        XCTAssertEqual(METLookup.mets(sport: .bike, speedKmh: 10.0), 4.0)  // leisure
        XCTAssertEqual(METLookup.mets(sport: .bike, speedKmh: 25.0), 10.0)
        XCTAssertEqual(METLookup.mets(sport: .bike, speedKmh: 45.0), 15.8) // terminal
    }

    func testHikeBandsMatchCompendium() {
        XCTAssertEqual(METLookup.mets(sport: .hike, speedKmh: 3.0), 4.0)
        XCTAssertEqual(METLookup.mets(sport: .hike, speedKmh: 4.5), 5.3)
        XCTAssertEqual(METLookup.mets(sport: .hike, speedKmh: 8.0), 7.0)
    }

    /// Concept2 table by 500 m split. 12 km/h ≈ 2:30/500m ≈ vigorous.
    func testRowBandsMatchConcept2Table() {
        XCTAssertEqual(METLookup.mets(sport: .row, speedKmh: 5.0), 4.5)
        XCTAssertEqual(METLookup.mets(sport: .row, speedKmh: 11.9), 8.5)
        XCTAssertEqual(METLookup.mets(sport: .row, speedKmh: 15.0), 12.0)  // race pace
    }

    /// Sports without a pace table fall back to a constant rather than nil,
    /// so a distance-bearing energy estimate still gets a sane number.
    func testCrossFitUsesTheConstantFallback() {
        XCTAssertNil(METLookup.bands(for: .crossFit))
        XCTAssertEqual(METLookup.mets(sport: .crossFit, speedKmh: 5.0), METLookup.crossFitConstantMETs)
        XCTAssertEqual(METLookup.mets(sport: .crossFit, speedKmh: 25.0), METLookup.crossFitConstantMETs)
        // The floor still applies: no motion, no estimate.
        XCTAssertNil(METLookup.mets(sport: .crossFit, speedKmh: 0.5))
    }

    /// Sport gained cases in the past; a new one silently defaulting to the
    /// wrong table would misreport energy, so pin the mapping explicitly.
    func testEverySportResolvesToItsIntendedTable() {
        XCTAssertEqual(METLookup.bands(for: .walk), METLookup.walk)
        XCTAssertEqual(METLookup.bands(for: .hike), METLookup.hike)
        XCTAssertEqual(METLookup.bands(for: .row), METLookup.row)
        for sport in [Sport.run, .trailRun, .treadmill] {
            XCTAssertEqual(METLookup.bands(for: sport), METLookup.run, "\(sport) should use the run table")
        }
        for sport in [Sport.bike, .indoorBike, .airBike] {
            XCTAssertEqual(METLookup.bands(for: sport), METLookup.bike, "\(sport) should use the bike table")
        }
    }

    /// Every enum case must be covered — a case added without a table entry
    /// would not compile in `bands(for:)`, but this also pins that no case
    /// was quietly routed to `nil` to make the switch exhaustive.
    func testOnlyCrossFitLacksAPaceTable() {
        let tableless = Sport.allCases.filter { METLookup.bands(for: $0) == nil }
        XCTAssertEqual(tableless, [.crossFit])
    }

    // MARK: - Recorder delegation

    /// `WorkoutRecorder.estimateMETs` takes pace in sec/km; check the
    /// conversion to km/h survived the extraction.
    func testRecorderConvertsPaceToSpeedBeforeLookup() {
        // 360 sec/km = 10 km/h → run table row with ceiling 11.3 → 11.0 METs
        XCTAssertEqual(
            WorkoutRecorder.estimateMETs(sport: .run, paceSecPerKm: 360, heartRate: nil, userMaxHR: 190),
            11.0
        )
    }

    func testRecorderRejectsNonPositivePace() {
        XCTAssertNil(WorkoutRecorder.estimateMETs(sport: .run, paceSecPerKm: nil, heartRate: nil, userMaxHR: 190))
        XCTAssertNil(WorkoutRecorder.estimateMETs(sport: .run, paceSecPerKm: 0, heartRate: nil, userMaxHR: 190))
        XCTAssertNil(WorkoutRecorder.estimateMETs(sport: .run, paceSecPerKm: -60, heartRate: nil, userMaxHR: 190))
    }

    /// A pace so slow the division underflows to below the crawl floor must
    /// not produce a METs number.
    func testRecorderRejectsGlacialPace() {
        XCTAssertNil(WorkoutRecorder.estimateMETs(sport: .walk, paceSecPerKm: 100_000, heartRate: nil, userMaxHR: 190))
    }
}
