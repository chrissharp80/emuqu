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
/// Two tests cover all of them: the empty payload pins every decode default
/// against `init()`, and the round trip moves every stored field off its
/// default (and checks that it did) so a field coded under mismatched keys,
/// or not decoded at all, cannot pass. That is what makes it safe to touch
/// that file at all.
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

    /// A round trip with every stored field moved off its default must survive
    /// intact. Catches a field that encodes under one key and decodes from
    /// another, and a field the decoder forgets entirely — for every field:
    /// the first assertion fails if the fixture leaves any field at its
    /// default, which a field added later without a fixture value would be.
    func testPopulatedSettingsSurviveARoundTrip() throws {
        let settings = Self.everyFieldChanged()
        let allFields = Set(Mirror(reflecting: settings).children.compactMap(\.label))
        XCTAssertEqual(
            Set(Self.differingFields(settings, UserSettings())).union(Self.notRoundTripped), allFields,
            "Every stored field must differ from init() here, or the round trip cannot see it"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(UserSettings.self, from: try encoder.encode(settings))
        // `sourceSchemaVersion` is stamped by the encoder and read back by the
        // decoder; it is nil only on settings that never went through either.
        XCTAssertEqual(Set(Self.differingFields(decoded, settings)), ["sourceSchemaVersion"])
    }

    /// Fields the round trip cannot carry off their default, each by design:
    ///
    ///   * `sourceSchemaVersion` — the encoder writes the current version
    ///     whatever the value; it is nil only before any coding.
    ///   * `defaultEmailRecipient`, `defaultEmailCC` — legacy fields the
    ///     decoder consumes into the per-category recipients and then clears.
    static let notRoundTripped: Set<String> = ["sourceSchemaVersion", "defaultEmailRecipient", "defaultEmailCC"]

    /// Every stored field except `notRoundTripped` set to a value other than
    /// `init()`'s, each within the range the decoder accepts (it clamps sleep
    /// hours, merge gap and max HR). Dates are whole seconds, as ISO 8601
    /// keeps them; the Health-marker set has one member, so its description
    /// cannot depend on set order; and it is set last, because setting a
    /// profile field clears its marker.
    static func everyFieldChanged() -> UserSettings {
        var s = UserSettings()
        s.customTags = [.morning]
        s.birthday = Date(timeIntervalSince1970: 500_000_000)
        s.fitnessLevel = .athlete
        s.biologicalSex = .female
        s.baselineRMSSD = 62.5
        s.baselineHR = 48
        s.typicalSleepHours = 7.25
        s.expectedBedtimeMinuteOfDay = 23 * 60 + 15
        s.sessionMergeMode = .custom
        s.customMergeGapHours = 6
        s.sleepSplitGapMinutes = 45
        s.defaultWindowSelectionMethod = .peakRMSSD
        s.vo2MaxOverride = 52.5
        s.useHealthKitVO2Max = true
        s.bodyWeightKg = 70
        s.homeAddress = "1 Test Street"
        s.maxHR = 185
        s.lactateThresholdHR = 165
        s.runningFTPWatts = 280
        s.cyclingFTPWatts = 250
        s.enableZwiftBroadcast = true
        s.enablePeriodicCoachUpdates = false
        s.periodicCoachCadenceSec = 600
        s.enableAutoCoachReport = true
        s.enableWebSearch = true
        s.defaultRecoveryEmailRecipient = "recovery@example.com"
        s.defaultRecoveryEmailCC = "recovery-cc@example.com"
        s.defaultTrainingEmailRecipient = "training@example.com"
        s.defaultTrainingEmailCC = "training-cc@example.com"
        s.userRestingHR = 52
        s.enableSleepIntegration = false
        s.enableHRVSleepAugmentation = true
        s.penalizeMissingSleep = true
        s.enableTrainingLoadIntegration = false
        s.trainingBreakStartDate = Date(timeIntervalSince1970: 1_700_000_000)
        s.trainingBreakEndDate = Date(timeIntervalSince1970: 1_700_600_000)
        s.trainingBreakReason = "Travel"
        s.comebackModeStartDate = Date(timeIntervalSince1970: 1_701_000_000)
        s.peakingDetectionEnabled = false
        s.dailyReportEnabled = true
        s.dailyReportDelivery = .fixed
        s.dailyReportFixedMinuteOfDay = 6 * 60 + 30
        s.dailyReportFormat = .teaser
        s.hrvAnomalyAlertsEnabled = true
        s.avatarImageData = Data([1, 2, 3])
        s.batteryLowAlertsEnabled = false
        s.coachAlertsEnabled = false
        s.preserveClipboardForPaste = false
        s.preferredSTTProvider = .whisperKit
        s.enableMileMarkerNotifications = true
        s.mileMarkerInterval = .everyKilometer
        s.enableTurnByTurnAlerts = true
        s.enableTurnMarkerUpdates = true
        s.syncFailureAlertsEnabled = false
        s.intentionalOverreachActive = true
        s.intentionalOverreachEndDate = Date(timeIntervalSince1970: 1_702_000_000)
        s.temperatureUnit = UserSettings().temperatureUnit == .celsius ? .fahrenheit : .celsius
        s.trainingGoal = .build
        s.routingMode = .auto
        s.watchDisplayOnlyMode = false
        s.hasCompletedOnboarding = true
        s.hasAcknowledgedScoreArchitectureChange = true
        s.hasRunScoreHistoryRecompute = true
        s.hasFixedTempAsymmetry = false
        s.trialStartDate = Date(timeIntervalSince1970: 1_700_000_000)
        s.iCloudSyncEnabled = true
        s.heatTrackingEnabled = true
        s.appearanceTheme = .dark
        s.colorTheme = .teal
        s.forceAIEnglish = true
        s.hideFitnessTab = true
        s.enableAIAssistant = false
        s.enableVoiceMode = false
        s.enableWatchConnectivity = false
        s.keepScreenOnDuringRecording = false
        s.enableHealthKitExport = true
        s.exportSDNN = false
        s.exportHeartRate = false
        s.exportRestingHeartRate = false
        s.exportSleepData = true
        s.defaultCaptureMode = "rr"
        s.profileFieldsFromHealth = [.bodyWeight]
        return s
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

    /// iCloud sync is opt-in (Guideline 5.1.3(ii)): off for a new install and
    /// for stored settings without the key, while a stored choice is kept.
    func testICloudSyncIsOffUnlessStoredOn() throws {
        XCTAssertFalse(UserSettings().iCloudSyncEnabled)
        XCTAssertFalse(try JSONDecoder().decode(UserSettings.self, from: Data("{}".utf8)).iCloudSyncEnabled)
        let storedOn = try JSONDecoder().decode(UserSettings.self, from: Data(#"{"iCloudSyncEnabled": true}"#.utf8))
        XCTAssertTrue(storedOn.iCloudSyncEnabled)
    }

    /// The Apple Health markers survive a round trip next to their values; the
    /// decoder must not let the values it sets first clear them.
    func testHealthProfileMarkersSurviveARoundTrip() throws {
        var settings = UserSettings()
        settings.birthday = Date(timeIntervalSince1970: 500_000_000)
        settings.bodyWeightKg = 70
        settings.profileFieldsFromHealth = [.birthday, .bodyWeight]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(UserSettings.self, from: try encoder.encode(settings))
        XCTAssertEqual(decoded.profileFieldsFromHealth, [.birthday, .bodyWeight])
        XCTAssertEqual(decoded.bodyWeightKg, 70)
    }

    /// A value typed over a Health-filled one is the user's own, so it is
    /// backed up; writing back the same value changes nothing.
    func testChangingAHealthFilledFieldClearsItsMarker() {
        var settings = UserSettings()
        settings.bodyWeightKg = 70
        settings.biologicalSex = .female
        settings.profileFieldsFromHealth = [.bodyWeight, .biologicalSex]

        settings.bodyWeightKg = 70
        XCTAssertEqual(settings.profileFieldsFromHealth, [.bodyWeight, .biologicalSex])
        settings.bodyWeightKg = 72
        XCTAssertEqual(settings.profileFieldsFromHealth, [.biologicalSex])
    }

    /// The backup leaves the Health-filled values out and keeps the user's
    /// own; a restore puts this device's values back for the fields left out.
    func testHealthFilledProfileStaysOffTheBackupAndSurvivesARestore() {
        var local = UserSettings()
        local.birthday = Date(timeIntervalSince1970: 500_000_000)
        local.bodyWeightKg = 70
        local.biologicalSex = .male
        local.profileFieldsFromHealth = [.birthday, .bodyWeight]

        let uploaded = local.withoutHealthFilledProfile()
        XCTAssertNil(uploaded.birthday)
        XCTAssertNil(uploaded.bodyWeightKg)
        XCTAssertEqual(uploaded.biologicalSex, .male)
        XCTAssertEqual(uploaded.profileFieldsFromHealth, [.birthday, .bodyWeight])

        var other = UserSettings()
        other.bodyWeightKg = 81
        other.birthday = Date(timeIntervalSince1970: 400_000_000)
        other.profileFieldsFromHealth = [.birthday]
        let restored = uploaded.keepingHealthFilledProfile(of: other)
        XCTAssertEqual(restored.bodyWeightKg, 81)
        XCTAssertEqual(restored.birthday, Date(timeIntervalSince1970: 400_000_000))
        XCTAssertEqual(restored.biologicalSex, .male)
        XCTAssertEqual(restored.profileFieldsFromHealth, [.birthday])
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
