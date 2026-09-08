@testable import Emuqu
import XCTest

// MARK: - TTSTextNormalizerTests
//
// Covers the composed normalization pipeline that
// runs AI text through abbreviation expansion, pace-string expansion,
// year-conversational reading, and the existing PhoneticOverrides
// homograph layer before TTS.
//
// User report context: "ZIP codes were an example. look online and
// see if there are packages we can plugin in to deal with this." We
// confirmed no off-the-shelf package exists; this normalizer is the
// composed Apple-primitives answer. Each test pins a concrete
// pronunciation behavior so future regressions are loud.

final class TTSTextNormalizerTests: XCTestCase {

    // MARK: - Domain abbreviations

    func testExpandsBPMOnly() {
        // HR has no rule (AVSpeech reads "H R" correctly), only BPM
        // gets expanded. Verifies word-boundary safety: "BPM"
        // matches but the surrounding "HR" stays intact.
        XCTAssertEqual(
            TTSTextNormalizer.expandDomainAbbreviations("Your HR is 142 BPM."),
            "Your HR is 142 B P M."
        )
    }

    func testExpandsHRV() {
        XCTAssertEqual(
            TTSTextNormalizer.expandDomainAbbreviations("HRV is 38 milliseconds."),
            "H R V is 38 milliseconds."
        )
    }

    func testExpandsVO2() {
        XCTAssertEqual(
            TTSTextNormalizer.expandDomainAbbreviations("VO2 is 48."),
            "V O two is 48."
        )
    }

    func testExpandsAlpha1Variants() {
        XCTAssertEqual(
            TTSTextNormalizer.expandDomainAbbreviations("Your α1 is steady."),
            "Your alpha one is steady."
        )
        XCTAssertEqual(
            TTSTextNormalizer.expandDomainAbbreviations("alpha-1 = 1.5"),
            "alpha one = 1.5"
        )
    }

    func testExpandsZoneAbbreviations() {
        XCTAssertEqual(
            TTSTextNormalizer.expandDomainAbbreviations("Z2 endurance"),
            "zone two endurance"
        )
        XCTAssertEqual(
            TTSTextNormalizer.expandDomainAbbreviations("between Z1 and Z3"),
            "between zone one and zone three"
        )
    }

    func testExpandsTrainingLoadAbbreviations() {
        XCTAssertEqual(
            TTSTextNormalizer.expandDomainAbbreviations("TSB -19, ATL 65, CTL 46"),
            "T S B -19, A T L 65, C T L 46"
        )
    }

    /// Word-boundary safety — abbreviations inside larger words must
    /// NOT trigger. "BPMx" or "HRVtraining" should stay intact.
    func testAbbreviationsRespectWordBoundaries() {
        XCTAssertEqual(
            TTSTextNormalizer.expandDomainAbbreviations("HRVtraining is a tag"),
            "HRVtraining is a tag"
        )
    }

    // MARK: - Pace strings

    func testPaceWithSlashMile() {
        let out = TTSTextNormalizer.expandPaceStrings("8:45/mi")
        XCTAssertEqual(out, "eight forty-five per mile")
    }

    func testPaceWithSlashKm() {
        let out = TTSTextNormalizer.expandPaceStrings("5:30/km")
        XCTAssertEqual(out, "five thirty per kilometer")
    }

    func testPaceWithMinSlashMile() {
        let out = TTSTextNormalizer.expandPaceStrings("8:45 min/mi")
        XCTAssertEqual(out, "eight forty-five per mile")
    }

    func testPaceWithPerMile() {
        let out = TTSTextNormalizer.expandPaceStrings("8:45 per mile")
        XCTAssertEqual(out, "eight forty-five per mile")
    }

    /// Sub-10 second values get "oh" prefix — "8:05" is "eight oh five",
    /// not "eight five". Matches how runners actually say it aloud.
    func testPaceWithSingleDigitSeconds() {
        let out = TTSTextNormalizer.expandPaceStrings("8:05/mi")
        XCTAssertEqual(out, "eight oh five per mile")
    }

    /// Even-minute paces use "flat" — "8:00/mi" reads as "eight flat
    /// per mile", which is the colloquial form.
    func testPaceWithFlatSeconds() {
        let out = TTSTextNormalizer.expandPaceStrings("8:00/mi")
        XCTAssertEqual(out, "eight flat per mile")
    }

    /// A bare "8:45" without a unit suffix MUST NOT be transformed
    /// (could be a clock time or a duration).
    func testBareTimeWithoutUnitIsUntouched() {
        XCTAssertEqual(
            TTSTextNormalizer.expandPaceStrings("Meeting at 8:45 today"),
            "Meeting at 8:45 today"
        )
    }

    // MARK: - Year expansion

    func testYear2026IsTwentyTwentySix() {
        XCTAssertEqual(
            TTSTextNormalizer.expandYears("Started in 2026"),
            "Started in twenty twenty-six"
        )
    }

    func testYear2003IsTwoThousandThree() {
        XCTAssertEqual(
            TTSTextNormalizer.expandYears("Year 2003"),
            "Year two thousand three"
        )
    }

    func testYear1990IsNineteenNinety() {
        XCTAssertEqual(
            TTSTextNormalizer.expandYears("born in 1990"),
            "born in nineteen ninety"
        )
    }

    func testYear1900IsNineteenHundred() {
        XCTAssertEqual(
            TTSTextNormalizer.expandYears("the 1900 census"),
            "the nineteen hundred census"
        )
    }

    /// Mid-decade — 1903 should be "nineteen oh three", not
    /// "nineteen three" (sounds wrong).
    func testYearWithSingleDigitSecondHalf() {
        XCTAssertEqual(
            TTSTextNormalizer.expandYears("the 1903 model"),
            "the nineteen oh three model"
        )
    }

    /// Years EMBEDDED in numeric / financial context must NOT be
    /// transformed. "$1990" or "1990.5" or "12:1990" stays intact.
    func testYearInsideNumericContextIsUntouched() {
        XCTAssertEqual(
            TTSTextNormalizer.expandYears("$1990"),
            "$1990"  // preceded by $, but $ isn't in our reject list — OK
        )
        XCTAssertEqual(
            TTSTextNormalizer.expandYears("1990.5"),
            "1990.5"  // followed by . — rejected
        )
        XCTAssertEqual(
            TTSTextNormalizer.expandYears("12,1990"),
            "12,1990"  // followed by digit (after comma) — rejected
        )
    }

    /// 5-digit numbers are NOT years and should pass through.
    func testFiveDigitNumberIsNotAYear() {
        XCTAssertEqual(
            TTSTextNormalizer.expandYears("walked 12500 steps"),
            "walked 12500 steps"
        )
    }

    // MARK: - End-to-end normalize() pipeline

    func testNormalizePipelineHandlesMixedText() {
        // Real-world AI Coach line: pace + zone + year + abbreviation +
        // homograph all in one. Confirms the pipeline doesn't break
        // any of them by running them in concert.
        let attributed = TTSTextNormalizer.normalize(
            "In 2026 your live workout averages 8:45/mi at HR 142 in Z2."
        )
        let spoken = attributed.string
        XCTAssertTrue(spoken.contains("twenty twenty-six"),
            "year should be conversational; got: \(spoken)")
        XCTAssertTrue(spoken.contains("eight forty-five per mile"),
            "pace should be spelled out; got: \(spoken)")
        // "live" → "lyve" via PhoneticOverrides (substitution layer).
        XCTAssertTrue(spoken.contains("lyve workout"),
            "live should respell to lyve; got: \(spoken)")
        // HR should pass through (it's already a clean two-letter
        // initialism that AVSpeech reads correctly as "H R" — we
        // didn't add a generic HR rule because it'd hit too many
        // spurious matches).
        // Z2 → "zone two"
        XCTAssertTrue(spoken.contains("zone two"),
            "Z2 should expand; got: \(spoken)")
    }

    /// stripForDisplay returns plain text — no respellings, no
    /// attributes. The chat bubble shows what the AI wrote, not what
    /// AVSpeech needs.
    func testStripForDisplayPreservesAIText() {
        XCTAssertEqual(
            TTSTextNormalizer.stripForDisplay("Your live HR is 142 BPM."),
            "Your live HR is 142 BPM."
        )
    }
}
