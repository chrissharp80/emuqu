@testable import Emuqu
import XCTest

/// A score factor's detail line and a breakdown's penalty lines are written
/// when they are shown, from the numbers stored with the night, so a language
/// or temperature-unit change reaches every night already scored.
///
/// Before, the lines were stored as text in the language active at scoring
/// time: after switching the app to German, history, the detail screen and
/// the PDF still read "Sleep HR 52 at baseline → 100".
@MainActor
final class ScoreFactorFactsTests: XCTestCase {
    private var pinnedLanguage: AppLanguage = .system

    override func setUp() async throws {
        pinnedLanguage = AppLanguage.current
        LanguageManager.shared.setLanguage(.en)
    }

    override func tearDown() async throws {
        LanguageManager.shared.setLanguage(pinnedLanguage)
    }

    private var baseline: BaselineTracker.RecoveryBaselineStats {
        BaselineTracker.RecoveryBaselineStats(
            lnRmssdMean: log(40.0), lnRmssdSD: 0.3, lnRmssdCV7Day: 6.0,
            meanHRBaseline: 58.0, meanHRSD: 3.0, daysInWindow: 30
        )
    }

    private func vitals(wristTemperature: Double? = nil, restingHeartRate: Double? = 61) -> RecoveryVitals {
        RecoveryVitals(
            respiratoryRate: nil, respiratoryRateBaseline: nil,
            oxygenSaturation: nil, oxygenSaturationMin: nil,
            wristTemperature: wristTemperature, wristTemperatureBaseline: nil,
            restingHeartRate: restingHeartRate
        )
    }

    private func englishVitalsFactor(_ vitals: RecoveryVitals) -> RecoveryScoreCalculator.ScoreFactor {
        NarrativeLanguage.english {
            VitalsScoring.vitalsFactor(vitals: vitals, baselineStats: baseline, score: 80, weight: 0.15)
        }
    }

    private func englishHRVFactor() -> RecoveryScoreCalculator.ScoreFactor {
        NarrativeLanguage.english {
            ScoreDetailBuilder.hrvFactor(
                tier1: 70,
                detail: ScoreDetailBuilder.describeHRV(
                    rmssd: 40, baselineStats: baseline, meanHR: 61, dfaAlpha1: 0.9, hrvReadiness: nil
                ),
                weight: 0.6
            )
        }
    }

    private func roundTripped(_ factor: RecoveryScoreCalculator.ScoreFactor) throws -> RecoveryScoreCalculator.ScoreFactor {
        try JSONDecoder().decode(RecoveryScoreCalculator.ScoreFactor.self, from: JSONEncoder().encode(factor))
    }

    // MARK: - Language

    /// Scored in English, stored, read back and shown in German: the line is
    /// German, and the same line a German scoring pass would have written.
    func testVitalsLineScoredInEnglishIsShownInTheAppLanguage() throws {
        let stored = try roundTripped(englishVitalsFactor(vitals()))
        XCTAssertTrue(stored.detail.hasPrefix("Sleep HR"), "The stored line is the scoring-time English")

        LanguageManager.shared.setLanguage(.de)
        let shown = stored.displayDetail(temperatureUnit: .celsius)
        let germanScoring = VitalsScoring.buildVitalsDetail(vitals: vitals(), baselineStats: baseline, score: 80)
        XCTAssertEqual(shown, germanScoring)
        XCTAssertTrue(shown.hasPrefix("Schlaf-HF"), "Expected German, got \(shown)")
    }

    func testHRVLineScoredInEnglishIsShownInTheAppLanguage() throws {
        let stored = try roundTripped(englishHRVFactor())
        XCTAssertTrue(stored.detail.contains("near your average"))

        LanguageManager.shared.setLanguage(.de)
        let shown = stored.displayDetail(temperatureUnit: .celsius)
        XCTAssertTrue(shown.contains("nahe deinem Durchschnitt"), "Expected German, got \(shown)")
        XCTAssertFalse(shown.contains("near your average"))
    }

    func testFixedLinesFollowTheAppLanguage() throws {
        let noSleep = NarrativeLanguage.english {
            ScoreDetailBuilder.sleepFactor(sleep: 0, sleepData: nil, typicalSleepHours: 8, weight: 0.3)
        }
        let stored = try roundTripped(noSleep)
        XCTAssertEqual(stored.detail, "No sleep data")
        LanguageManager.shared.setLanguage(.de)
        XCTAssertEqual(stored.displayDetail(temperatureUnit: .celsius), "Keine Schlafdaten")
    }

    /// The assistant reads English whatever the app language.
    func testEnglishScopeStillWritesEnglish() throws {
        let stored = try roundTripped(englishVitalsFactor(vitals()))
        LanguageManager.shared.setLanguage(.de)
        let machine = NarrativeLanguage.english { stored.displayDetail(temperatureUnit: .celsius) }
        XCTAssertEqual(machine, stored.detail)
    }

    // MARK: - Stored text fallback

    /// A factor scored before facts were stored is shown as it was stored.
    func testFactorWithoutFactsShowsItsStoredLine() {
        let legacy = RecoveryScoreCalculator.ScoreFactor(
            label: "Sleep", detail: "7.5h at 92% efficiency", score: 88, weight: 0.25, impact: .positive
        )
        XCTAssertEqual(legacy.displayDetail(temperatureUnit: .fahrenheit), "7.5h at 92% efficiency")
    }

    /// An adjustment kind added by a later build must neither fail the decode
    /// nor drop out of the line silently: the stored line is shown instead.
    func testUnknownAdjustmentKindFallsBackToTheStoredLine() throws {
        let factor = englishHRVFactor()
        var json = try XCTUnwrap(String(data: JSONEncoder().encode(factor), encoding: .utf8))
        json = json.replacingOccurrences(of: "\"alphaBalanced\"", with: "\"someFutureKind\"")
        let decoded = try JSONDecoder().decode(RecoveryScoreCalculator.ScoreFactor.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.displayDetail(temperatureUnit: .celsius), factor.detail)
    }

    /// A breakdown archived before `facts` existed still decodes.
    func testFactorArchivedWithoutFactsDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","label":"HRV","detail":"42ms","score":70,"weight":0.6,"impact":"positive"}
        """
        let decoded = try JSONDecoder().decode(RecoveryScoreCalculator.ScoreFactor.self, from: Data(json.utf8))
        XCTAssertNil(decoded.facts)
        XCTAssertEqual(decoded.displayDetail(temperatureUnit: .celsius), "42ms")
    }

    // MARK: - Temperature unit

    /// The wrist-temperature deviation follows the user's unit. A deviation
    /// converts by 9/5 with no +32 offset: +0.5 °C is +0.9 °F.
    func testTemperatureDeviationIsShownInTheUsersUnit() {
        let factor = englishVitalsFactor(vitals(wristTemperature: 0.5))
        let fahrenheit = NarrativeLanguage.english { factor.displayDetail(temperatureUnit: .fahrenheit) }
        let celsius = NarrativeLanguage.english { factor.displayDetail(temperatureUnit: .celsius) }
        XCTAssertTrue(fahrenheit.contains("+0.9°F"), fahrenheit)
        XCTAssertFalse(fahrenheit.contains("°C"), fahrenheit)
        XCTAssertTrue(celsius.contains("+0.5°C"), celsius)
    }

    // MARK: - Penalties

    /// A penalty line stored in German is shown in English after a switch.
    func testPenaltyStoredInAnotherLanguageIsShownInTheAppLanguage() {
        LanguageManager.shared.setLanguage(.de)
        let german = [ScoreBreakdownCopy.lowBloodOxygenPenalty, ScoreBreakdownCopy.missingSleepPenalty]
        LanguageManager.shared.setLanguage(.en)
        let breakdown = RecoveryScoreCalculator.ScoreBreakdown(
            compositeScore: 50, tier: 1, factors: [], penalties: german, spo2PenaltyApplied: true
        )
        XCTAssertEqual(
            breakdown.displayPenalties,
            [ScoreBreakdownCopy.lowBloodOxygenPenalty, ScoreBreakdownCopy.missingSleepPenalty]
        )
        XCTAssertTrue(breakdown.displayPenalties[0].hasPrefix("Low blood oxygen"))
    }

    func testUnrecognisedPenaltyLineIsShownAsStored() {
        XCTAssertEqual(ScoreBreakdownCopy.displayPenalty("Something else (−4)"), "Something else (−4)")
    }
}
