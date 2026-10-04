@testable import Emuqu
import XCTest

/// Tests for `PhoneticOverrides` — the layer that fixes AVSpeech's
/// "live" pronunciation. Two correctness contracts:
///
/// 1. The visible chat bubble text never shows `[[word|IPA]]` markup
///    or the spoken-only respellings.
/// 2. The TTS-bound resolved text contains the respelling for matched
///    domain phrases, so voices that ignore IPA hints still pronounce
///    "live" as the adjective.
final class PhoneticOverridesTests: XCTestCase {

    // MARK: - stripForDisplay

    func testStripForDisplayRemovesAuthoredMarkup() {
        let displayed = PhoneticOverrides.stripForDisplay("Your [[live|laɪv]] HR is steady.")
        XCTAssertEqual(displayed, "Your live HR is steady.")
    }

    func testStripForDisplayLeavesPlainTextUntouched() {
        XCTAssertEqual(
            PhoneticOverrides.stripForDisplay("Heart rate is 142 bpm."),
            "Heart rate is 142 bpm."
        )
    }

    // MARK: - resolve — domain rules substitute "live" → "lyve"

    func testDomainRuleSubstitutesLiveBeforeNoun() {
        let (plain, hints) = PhoneticOverrides.resolve("Your live HR is climbing.")
        XCTAssertEqual(plain, "Your lyve HR is climbing.")
        XCTAssertEqual(hints.count, 1)
        XCTAssertEqual(hints.first?.ipa, "laɪv")
        XCTAssertEqual(hints.first?.source, .domain)
    }

    func testDomainRuleSubstitutesLiveAfterPossessive() {
        let (plain, _) = PhoneticOverrides.resolve("You're live now.")
        XCTAssertEqual(plain, "You're lyve now.")
    }

    func testDomainRuleSubstitutesLiveDataLowercase() {
        let (plain, _) = PhoneticOverrides.resolve("Reading live data.")
        XCTAssertEqual(plain, "Reading lyve data.")
    }

    func testDomainRulePreservesLeadingCapital() {
        let (plain, _) = PhoneticOverrides.resolve("Live session is recording.")
        XCTAssertEqual(plain, "Lyve session is recording.")
    }

    func testNonAdjectiveLiveIsNotSubstituted() {
        // "I live in Illinois" — verb, no domain rule should fire.
        let (plain, hints) = PhoneticOverrides.resolve("I live in Illinois.")
        XCTAssertEqual(plain, "I live in Illinois.")
        XCTAssertTrue(hints.isEmpty)
    }

    /// The "right now … live" rule respells the trailing "live", never the
    /// letters inside an earlier word, and never the verb.
    func testRightNowLiveRuleTargetsTheWholeTrailingWord() {
        let (plain, _) = PhoneticOverrides.resolve("Right now we delivered your live")
        XCTAssertEqual(plain, "Right now we delivered your lyve")
        let (verb, hints) = PhoneticOverrides.resolve("You currently live in Chicago.")
        XCTAssertEqual(verb, "You currently live in Chicago.")
        XCTAssertTrue(hints.isEmpty)
    }

    // MARK: - resolve — authored markup wins

    func testAuthoredMarkupBeatsDomainRule() {
        // Authored hint already pinned this "live"; the domain rule
        // must not fire on the same span (no double-handling, no
        // respelling clobber).
        let (plain, hints) = PhoneticOverrides.resolve("Your [[live|laɪv]] HR.")
        XCTAssertEqual(plain, "Your live HR.")
        XCTAssertEqual(hints.count, 1)
        XCTAssertEqual(hints.first?.source, .authored)
    }

    // MARK: - speechAttributedString end-to-end

    func testSpeechAttributedStringHasIPAOnRespelledLive() {
        let attr = PhoneticOverrides.speechAttributedString("Your live HR.")
        XCTAssertEqual(attr.string, "Your lyve HR.")
        // Find the IPA attribute on the "lyve" range.
        let lyveRange = (attr.string as NSString).range(of: "lyve")
        XCTAssertNotEqual(lyveRange.location, NSNotFound)
        let ipa = attr.attribute(.accessibilitySpeechIPANotation, at: lyveRange.location, effectiveRange: nil) as? String
        XCTAssertEqual(ipa, "laɪv")
    }

    // MARK: - ZIP code expansion
    //
    // User report: "it always says 'ninety-eight thousand' for my zip
    // code, 98765." AVSpeech reads bare 5-digit numbers as a single
    // number. Spacing the digits ("9 8 7 6 5") forces digit-by-digit
    // pronunciation. Only fires in unambiguous ZIP contexts so prices,
    // years, and other 5-digit numbers aren't mangled.

    func testZipCodeAfterStateCodeIsSpaced() {
        let out = PhoneticOverrides.expandZipCodes("Fairview, IL 98765")
        XCTAssertEqual(out, "Fairview, IL 9 8 7 6 5")
    }

    func testZipCodeAfterExplicitLabelIsSpaced() {
        let out = PhoneticOverrides.expandZipCodes("ZIP code 98765")
        XCTAssertEqual(out, "ZIP code 9 8 7 6 5")
    }

    func testZipCodeAfterPostalCodeLabelIsSpaced() {
        let out = PhoneticOverrides.expandZipCodes("postal code 98765")
        XCTAssertEqual(out, "postal code 9 8 7 6 5")
    }

    func testZipPlusFourPreservesDashAsPause() {
        let out = PhoneticOverrides.expandZipCodes("ZIP 98765-1234")
        XCTAssertEqual(out, "ZIP 9 8 7 6 5 dash 1 2 3 4")
    }

    /// Five-digit numbers in non-ZIP contexts MUST stay intact —
    /// otherwise prices ("$12345"), years (a number alone), and
    /// step counts ("walked 12500 steps") break.
    func testBare5DigitNumberInNonZipContextIsUntouched() {
        let out = PhoneticOverrides.expandZipCodes("walked 12500 steps")
        XCTAssertEqual(out, "walked 12500 steps")
    }

    /// Lowercase 2-letter words ("as", "to", "in") followed by digits
    /// are NOT state codes — must not trigger the state+ZIP path.
    func testLowercaseTwoLetterPlusDigitsIsNotZip() {
        let out = PhoneticOverrides.expandZipCodes("as 12345 examples")
        XCTAssertEqual(out, "as 12345 examples")
    }

    /// "live HRV" must respell to "lyve HRV". A pattern that only
    /// matches `HR\b` doesn't match inside HRV because `V` is a word
    /// char and breaks the boundary.
    func testDomainRuleSubstitutesLiveBeforeHRV() {
        let (plain, _) = PhoneticOverrides.resolve("Your live HRV is steady.")
        XCTAssertTrue(plain.contains("lyve HRV"),
            "live before HRV should respell to lyve; got: \(plain)")
    }

    /// TTSTextNormalizer expands "HRV" to "H R V" before
    /// PhoneticOverrides runs. The pattern must match the post-
    /// expansion form so the homograph fix doesn't get bypassed by
    /// our own preprocessing.
    func testDomainRuleSubstitutesLiveBeforeSpacedHRV() {
        let (plain, _) = PhoneticOverrides.resolve("Your live H R V is steady.")
        XCTAssertTrue(plain.contains("lyve H R V"),
            "live before spaced 'H R V' should respell to lyve; got: \(plain)")
    }

    /// "live BPM" — same case for B P M post-expansion.
    func testDomainRuleSubstitutesLiveBeforeSpacedBPM() {
        let (plain, _) = PhoneticOverrides.resolve("Your live B P M reading.")
        XCTAssertTrue(plain.contains("lyve B P M"),
            "live before 'B P M' should respell; got: \(plain)")
    }

    /// "live alpha one" — post-expansion of α1 / alpha-1.
    func testDomainRuleSubstitutesLiveBeforeAlphaOne() {
        let (plain, _) = PhoneticOverrides.resolve("Your live alpha one is 1.5.")
        XCTAssertTrue(plain.contains("lyve alpha one"),
            "live before 'alpha one' should respell; got: \(plain)")
    }

    /// ZIP context survives the full `resolve()` pipeline (zip
    /// expansion → markup pass → domain rules), so the speech text
    /// the synthesiser receives has spaced digits.
    func testResolveExpandsZipCodeBeforeDomainRules() {
        let (plain, _) = PhoneticOverrides.resolve("Fairview IL 98765 — your live workout.")
        XCTAssertTrue(plain.contains("9 8 7 6 5"),
            "ZIP digits should be spaced; got: \(plain)")
        // Domain rule still substitutes "live" → "lyve" alongside the ZIP fix.
        XCTAssertTrue(plain.contains("lyve workout"),
            "live-respelling should still fire after ZIP expansion; got: \(plain)")
    }
}
