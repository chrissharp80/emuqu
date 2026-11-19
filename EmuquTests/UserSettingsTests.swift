@testable import Emuqu
import XCTest

final class UserSettingsTests: XCTestCase {
    // MARK: - Defaults

    func testDefaultSettings() {
        let settings = UserSettings()
        XCTAssertNil(settings.fitnessLevel, "Fitness level should default to nil")
        XCTAssertEqual(settings.temperatureUnit, .regionDefault)
        XCTAssertFalse(settings.hasCompletedOnboarding)
        XCTAssertNil(settings.trialStartDate, "Trial should not be started by default")
    }

    // MARK: - Codable Roundtrip

    func testCodableRoundtrip() throws {
        var settings = UserSettings()
        settings.fitnessLevel = .athlete
        settings.temperatureUnit = .celsius
        settings.hasCompletedOnboarding = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(settings)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(UserSettings.self, from: data)

        XCTAssertEqual(decoded.fitnessLevel, .athlete)
        XCTAssertEqual(decoded.temperatureUnit, .celsius)
        XCTAssertTrue(decoded.hasCompletedOnboarding)
    }

    func testLegacyDecodingMissingFields() throws {
        // Minimal JSON — all optional fields should get defaults
        let json = "{}"
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(UserSettings.self, from: data)

        XCTAssertNil(decoded.fitnessLevel, "Should default to nil when missing")
        XCTAssertEqual(decoded.temperatureUnit, .regionDefault, "Should default to the region's unit")
        XCTAssertNil(decoded.trialStartDate, "Should default to nil when missing")
    }

    func testTrialStartDateRoundtrip() throws {
        var settings = UserSettings()
        let now = Date()
        settings.trialStartDate = now

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(settings)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(UserSettings.self, from: data)

        XCTAssertNotNil(decoded.trialStartDate)
        XCTAssertEqual(
            try XCTUnwrap(decoded.trialStartDate?.timeIntervalSince1970),
            now.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    // MARK: - TemperatureUnit

    func testTemperatureUnitConvert() {
        // Celsius deviation stays the same
        XCTAssertEqual(TemperatureUnit.celsius.convert(0.5), 0.5, accuracy: 0.01)

        // Fahrenheit conversion: deviation * 9/5
        XCTAssertEqual(TemperatureUnit.fahrenheit.convert(0.5), 0.9, accuracy: 0.01)
    }

    func testTemperatureUnitAbsoluteFromDeviation() {
        // Baseline is ~36.5°C for wrist
        let celsiusAbsolute = TemperatureUnit.celsius.absoluteFromDeviation(0.0)
        XCTAssertEqual(celsiusAbsolute, 36.5, accuracy: 0.1)

        let fahrenheitAbsolute = TemperatureUnit.fahrenheit.absoluteFromDeviation(0.0)
        XCTAssertEqual(fahrenheitAbsolute, 97.7, accuracy: 0.1)
    }

    func testTemperatureUnitSymbol() {
        XCTAssertEqual(TemperatureUnit.celsius.symbol, "°C")
        XCTAssertEqual(TemperatureUnit.fahrenheit.symbol, "°F")
    }

    func testTemperatureUnitAllCases() {
        XCTAssertEqual(TemperatureUnit.allCases.count, 2)
    }

    // MARK: - SleepSchedule

    func testSleepScheduleWakeTimeIsBedtimePlusSleepHours() {
        let schedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)
        // 22:00 plus 8 hours wraps past midnight to 06:00.
        XCTAssertEqual(schedule.bedtimeHour, 22)
        XCTAssertEqual(schedule.wakeHour, 6)
        XCTAssertEqual(schedule.wakeMinute, 0)
    }

    func testSleepScheduleIsInOvernightWindow() throws {
        let schedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0) // 22:00 bedtime, 06:00 wake

        // Create a date at 2 AM (should be in overnight window)
        let cal = Calendar.current
        var components = cal.dateComponents([.year, .month, .day], from: Date())
        components.hour = 2
        components.minute = 0
        let nightDate = try XCTUnwrap(cal.date(from: components))

        XCTAssertTrue(
            schedule.isInOvernightWindow(nightDate),
            "2 AM should be in overnight window"
        )

        // 10:30 AM is the overnight window end (wake 06:00 + 4.5h), so 11 AM should be outside
        components.hour = 11
        components.minute = 0
        let latemorning = try XCTUnwrap(cal.date(from: components))

        XCTAssertFalse(
            schedule.isInOvernightWindow(latemorning),
            "11 AM is past the window end (wake 06:00 + 4.5h = 10:30)"
        )

        // 5 PM should be outside: overnightWindowStart anchors to current-day bedtime
        // minus 2h (20:00), which is AFTER 17:00, so 5 PM falls before the next window starts
        // and after the previous window ended at 10:30 AM.
        components.hour = 17
        let afternoon = try XCTUnwrap(cal.date(from: components))

        XCTAssertFalse(
            schedule.isInOvernightWindow(afternoon),
            "5 PM should NOT be in overnight window"
        )
    }

    // MARK: - FitnessLevel

    func testFitnessLevelAllCases() {
        XCTAssertGreaterThan(FitnessLevel.allCases.count, 0)
        for level in FitnessLevel.allCases {
            XCTAssertFalse(level.localizedName.isEmpty)
        }
    }

    // MARK: - WindowUserAdjusted & SleepUserAdjusted Codable

    func testWindowUserAdjustedRoundtrip() throws {
        var session = makeMinimalSession()
        session.windowUserAdjusted = true
        session.sleepUserAdjusted = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HRVSession.self, from: data)

        XCTAssertEqual(decoded.windowUserAdjusted, true, "windowUserAdjusted should survive roundtrip")
        XCTAssertEqual(decoded.sleepUserAdjusted, true, "sleepUserAdjusted should survive roundtrip")
    }

    func testWindowUserAdjustedDefaultsToNil() throws {
        let session = makeMinimalSession()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HRVSession.self, from: data)

        XCTAssertNil(decoded.windowUserAdjusted, "windowUserAdjusted should default to nil")
        XCTAssertNil(decoded.sleepUserAdjusted, "sleepUserAdjusted should default to nil")
    }

    // MARK: - Settings file that cannot be read

    // `SettingsManager` itself has a private initializer on the app's own
    // settings file, so these exercise the static load and copy it runs at
    // launch, on temporary files. The held saves that follow from
    // `.unreadableNotPreserved` live on the instance and are not covered here.

    /// A settings file in its own temporary directory, removed after the test.
    private func unreadableSettingsFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsLoad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
                try FileManager.default.removeItem(at: directory)
            } catch {
                // swallow-ok: the directory is temporary.
            }
        }
        let file = directory.appendingPathComponent("user_settings.json")
        try Data("not settings".utf8).write(to: file)
        return file
    }

    /// An unreadable file is copied aside before anything saves over it, and
    /// the new copy replaces the one an earlier failure kept.
    func testAnUnreadableSettingsFileIsCopiedAsideReplacingTheEarlierCopy() throws {
        let file = try unreadableSettingsFile()
        let backup = file.deletingLastPathComponent().appendingPathComponent(SettingsManager.unreadableBackupName)
        try Data("earlier copy".utf8).write(to: backup)

        let (loaded, outcome) = SettingsManager.load(from: file)

        XCTAssertNil(loaded)
        XCTAssertEqual(outcome, .unreadableOther)
        XCTAssertEqual(try Data(contentsOf: backup), Data("not settings".utf8))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)),
                       [SettingsManager.unreadableBackupName, "user_settings.json"],
                       "No temporary copy is left behind")
    }

    /// When the copy cannot be made, the load says so, which holds saves, and
    /// the copy an earlier failure kept is still there: it is replaced only
    /// by a copy that exists.
    func testAFailedCopyHoldsSavesAndKeepsTheEarlierCopy() throws {
        let file = try unreadableSettingsFile()
        let directory = file.deletingLastPathComponent()
        let backup = directory.appendingPathComponent(SettingsManager.unreadableBackupName)
        try Data("earlier copy".utf8).write(to: backup)
        // A read-only directory: no copy can be created in it.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        let (loaded, outcome) = SettingsManager.load(from: file)

        XCTAssertNil(loaded)
        XCTAssertEqual(outcome, .unreadableNotPreserved)
        XCTAssertEqual(try Data(contentsOf: backup), Data("earlier copy".utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data("not settings".utf8))
    }

    /// A Cocoa read error wrapping a POSIX code, as `Data(contentsOf:)` reports one.
    private func readError(posix code: Int32) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))])
    }

    /// A read that fails for a reason that can pass (an I/O error, out of
    /// file descriptors) leaves a file that may be intact: saves are held,
    /// and nothing is written beside it.
    func testAReadFailureThatCanPassHoldsSaves() throws {
        let file = try unreadableSettingsFile()
        for code in [EIO, EMFILE, ENFILE] {
            let error = readError(posix: code)
            let (loaded, outcome) = SettingsManager.load(from: file, read: { _ in throw error })
            XCTAssertNil(loaded)
            XCTAssertEqual(outcome, .unreadableNotPreserved, "POSIX \(code) must hold saves")
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("not settings".utf8), "The file must be left as it was")
    }

    /// An EISDIR read error (a directory at the path) is classified as one
    /// that can never give bytes back: nothing to keep, saves go ahead, and no
    /// copy is written.
    func testAnEISDIRReadErrorLeavesNothingToKeep() throws {
        let file = try unreadableSettingsFile()
        let error = readError(posix: EISDIR)

        let (loaded, outcome) = SettingsManager.load(from: file, read: { _ in throw error })

        XCTAssertNil(loaded)
        XCTAssertEqual(outcome, .unreadableOther)
        let backup = file.deletingLastPathComponent().appendingPathComponent(SettingsManager.unreadableBackupName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "There were no bytes to keep a copy of")
    }

    /// File protection's refusal is a locked file; a file gone by the time it
    /// is read is not present; a file too large to read leaves nothing to keep.
    func testReadErrorsThatAreNotTransient() {
        let locked = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        XCTAssertEqual(SettingsManager.outcome(forReadError: locked), .blockedByProtection)
        XCTAssertEqual(SettingsManager.outcome(forReadError: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)), .fileNotPresent)
        XCTAssertEqual(SettingsManager.outcome(forReadError: readError(posix: ENOENT)), .fileNotPresent)
        XCTAssertEqual(SettingsManager.outcome(forReadError: NSError(domain: NSCocoaErrorDomain, code: NSFileReadTooLargeError)), .unreadableOther)
    }

    // MARK: - Held saves on a manager instance

    /// A reader the test controls: it fails with `error` while one is set and
    /// reads the file otherwise, counting every read. Used only on the main
    /// actor, by the test and by the manager it reads for.
    private final class SettingsReader {
        var error: NSError?
        private(set) var reads = 0

        func read(_ url: URL) throws -> Data {
            reads += 1
            if let error { throw error }
            return try Data(contentsOf: url)
        }
    }

    /// A settings file holding `maxHR` 170 in its own temporary directory,
    /// and a manager on it whose first read fails with EIO, so saves are held.
    @MainActor
    private func heldManager() throws -> (SettingsManager, SettingsReader, URL) {
        let file = try unreadableSettingsFile()
        var onDisk = UserSettings()
        onDisk.maxHR = 170
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(onDisk).write(to: file)
        let reader = SettingsReader()
        reader.error = readError(posix: EIO)
        let manager = SettingsManager(settingsURL: file, read: { try reader.read($0) })
        XCTAssertEqual(manager.loadOutcome, .unreadableNotPreserved, "Sanity: an EIO read holds saves")
        return (manager, reader, file)
    }

    /// The settings the file holds once every pending write has landed.
    @MainActor
    private func settingsOnDisk(_ manager: SettingsManager, file: URL) throws -> UserSettings {
        XCTAssertNil(manager.flushPendingWritesSynchronously())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UserSettings.self, from: Data(contentsOf: file))
    }

    /// Lets the main-actor tasks the manager scheduled (the observer
    /// installation) run.
    @MainActor
    private func drainMainActor() async {
        for _ in 0 ..< 5 { await Task.yield() }
    }

    /// A change made while saves are held reads the file again; once it reads,
    /// the change is merged onto the file's settings and saved, not the other
    /// way round.
    @MainActor
    func testAHeldChangeIsMergedOntoTheFileOnceItReads() async throws {
        let (manager, reader, file) = try heldManager()
        reader.error = nil

        manager.settings.bodyWeightKg = 80

        XCTAssertEqual(manager.loadOutcome, .loaded)
        XCTAssertEqual(manager.settings.maxHR, 170, "The file's settings were not adopted")
        XCTAssertEqual(manager.settings.bodyWeightKg, 80, "The change made while held was lost")
        let saved = try settingsOnDisk(manager, file: file)
        XCTAssertEqual(saved.maxHR, 170)
        XCTAssertEqual(saved.bodyWeightKg, 80)
    }

    /// A hold lifted before the retry observers are installed leaves none
    /// behind, and a retry when nothing is held reads nothing: a later read
    /// failure can no longer swap the file's settings in over a change.
    @MainActor
    func testARetryAfterTheHoldLiftedReadsNothingAndKeepsTheChange() async throws {
        let (manager, reader, file) = try heldManager()
        reader.error = nil
        manager.settings.bodyWeightKg = 80   // lifts the hold in the same turn as init
        await drainMainActor()
        XCTAssertTrue(manager.heldRetryObservers.isEmpty, "An observer was installed after the hold lifted")

        reader.error = readError(posix: EIO)
        let readsBefore = reader.reads
        manager.retryLoadAfterUnlock()
        XCTAssertEqual(reader.reads, readsBefore, "A retry with nothing held read the file")
        XCTAssertEqual(manager.loadOutcome, .loaded)

        manager.settings.maxHR = 180
        XCTAssertEqual(try settingsOnDisk(manager, file: file).maxHR, 180, "The change after the hold lifted was not saved")
    }

    /// While held, the observers are installed; the first change reads the
    /// file once and later changes do not; becoming active (the observers'
    /// handler) adopts the file as soon as it reads, keeping every held change
    /// and dropping the observers.
    @MainActor
    func testAHeldLoadIsRetriedOnActivationWithoutAReadPerChange() async throws {
        let (manager, reader, file) = try heldManager()
        await drainMainActor()
        XCTAssertFalse(manager.heldRetryObservers.isEmpty, "No retry observers while saves are held")

        let readsAtLaunch = reader.reads
        manager.settings.bodyWeightKg = 80
        manager.settings.userRestingHR = 48
        XCTAssertEqual(reader.reads, readsAtLaunch + 1, "Only the first held change reads the file again")
        XCTAssertEqual(manager.loadOutcome, .unreadableNotPreserved)

        reader.error = nil
        manager.retryLoadAfterUnlock()

        XCTAssertEqual(manager.loadOutcome, .loaded)
        XCTAssertTrue(manager.heldRetryObservers.isEmpty)
        let saved = try settingsOnDisk(manager, file: file)
        XCTAssertEqual(saved.maxHR, 170)
        XCTAssertEqual(saved.bodyWeightKg, 80)
        XCTAssertEqual(saved.userRestingHR, 48)
    }

    // MARK: - Helpers

    private func makeMinimalSession() -> HRVSession {
        HRVSession(
            startDate: Date(),
            sessionType: .overnight
        )
    }
}
