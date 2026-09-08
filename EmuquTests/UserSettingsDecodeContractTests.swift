@testable import Emuqu
import XCTest

/// The decoder's contract, pinned field by field.
///
/// `UserSettings+Codable` is the app's forward/backward compatibility surface:
/// every field decodes with a default so a schema change never drops a user's
/// settings. That makes a changed default a silent behaviour change for
/// existing users rather than a formatting choice — and until now only four of
/// roughly eighty fields were asserted anywhere.
///
/// These two tests cover all of them at once, which is what makes it safe to
/// touch that file at all.
final class UserSettingsDecodeContractTests: XCTestCase {
    /// An empty payload must produce exactly the designated initializer's
    /// settings. Any decoder default that drifts from its `init()` counterpart
    /// fails here, whichever field it is.
    func testEmptyPayloadDecodesToTheDesignatedDefaults() throws {
        let decoded = try JSONDecoder().decode(UserSettings.self, from: Data("{}".utf8))
        let differing = Set(Self.differingFields(decoded, UserSettings()))
        XCTAssertEqual(differing, Self.justifiedDecodeOnlyDefaults, """
            A decoder default drifted from the designated one. Either the
            change is intended — in which case name the field in
            `justifiedDecodeOnlyDefaults` with the reason — or an existing
            user's setting silently changes on their next launch.
            """)
    }

    /// A populated round trip must survive intact. Catches a field that
    /// encodes under one key and decodes from another, and a field the
    /// decoder forgets entirely.
    func testPopulatedSettingsSurviveARoundTrip() throws {
        var settings = UserSettings()
        settings.fitnessLevel = .athlete
        settings.biologicalSex = .female
        settings.birthday = Date(timeIntervalSince1970: 500_000_000)
        settings.temperatureUnit = .celsius
        settings.hasCompletedOnboarding = true
        settings.baselineRMSSD = 62.5
        settings.baselineHR = 48
        settings.typicalSleepHours = 7.25
        settings.customTags = [.morning]
        settings.trialStartDate = Date(timeIntervalSince1970: 1_700_000_000)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(UserSettings.self, from: try encoder.encode(settings))
        // `sourceSchemaVersion` is stamped by the encoder and read back by the
        // decoder; it is nil only on settings that never went through either.
        XCTAssertEqual(Set(Self.differingFields(decoded, settings)), ["sourceSchemaVersion"])
    }

    /// A value of the wrong TYPE is not a missing value. The decoder is
    /// deliberately tolerant — a corrupt field falls back to its default
    /// rather than failing the whole payload and losing every other setting.
    func testAMalformedFieldFallsBackWithoutLosingTheRest() throws {
        let json = #"{"typicalSleepHours": "not a number", "hasCompletedOnboarding": true}"#
        let decoded = try JSONDecoder().decode(UserSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.typicalSleepHours, UserSettings().typicalSleepHours)
        XCTAssertTrue(decoded.hasCompletedOnboarding)
    }

    /// The fields where the decoder deliberately disagrees with `init()`.
    ///
    /// Each is a documented decision in `UserSettings+Codable`, and each is
    /// about a user who ALREADY has stored settings:
    ///
    ///   * `sourceSchemaVersion` — nil means "never decoded from a payload".
    ///   * `hasCompletedOnboarding` — an existing user without the key has
    ///     obviously onboarded; defaulting false would send them back through
    ///     it.
    ///   * `hasFixedTempAsymmetry` — false on decode so a returning user runs
    ///     the one-time rescore exactly once, while a fresh install takes
    ///     `true` from `init()` and skips it. The other two migration flags
    ///     decode to false as well, but their `init()` default is false too,
    ///     so they are not drift and are deliberately NOT listed here.
    ///
    /// Anything else appearing here is drift, not design.
    static let justifiedDecodeOnlyDefaults: Set<String> = [
        "sourceSchemaVersion",
        "hasCompletedOnboarding",
        "hasFixedTempAsymmetry"
    ]

    /// Mirror-based, so a failure names the field rather than dumping two
    /// eighty-field structs at the reader.
    static func differingFields(_ lhs: UserSettings, _ rhs: UserSettings) -> [String] {
        let a = Array(Mirror(reflecting: lhs).children)
        let b = Array(Mirror(reflecting: rhs).children)
        var out: [String] = []
        for (index, child) in a.enumerated() where index < b.count {
            if String(describing: child.value) != String(describing: b[index].value) {
                out.append(child.label ?? "?")
            }
        }
        return out
    }

}
