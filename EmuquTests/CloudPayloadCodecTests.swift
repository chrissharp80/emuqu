import CloudKit
import CryptoKit
@testable import Emuqu
import os
import Security
import XCTest

/// The cloud write/read contract, exercised through the production codec.
///
/// ## What these pin
///
/// Two defects that a round-trip test would have caught
/// immediately, and there was no round-trip test:
///
///   • **Live backups** — RR backups were encrypted on write and decompressed on
///     read with no decrypt step. Unreadable the same day, on the same device,
///     with the key present. It surfaced as *no backup* rather than an error,
///     because the decode returned nil and `compactMap` dropped the entry.
///
///   • **Session payloads** — they used the archive key, which is
///     non-synchronizable. Another device on the account generates
///     its own key, decryption fails, and a reader with a "legacy" fallback
///     hands the ciphertext onward as if it were compressed data.
///
/// The unifying mistake is that the writer and reader each decided the framing
/// independently. Every test here goes through `CloudPayloadCodec` in both
/// directions, so the two cannot disagree.
final class CloudPayloadCodecTests: XCTestCase {
    private let payload = Data("the quick brown fox jumps over the lazy dog".utf8)

    override func setUp() {
        super.setUp()
        standInForConfirmedICloudAccount()
    }

    // MARK: - Round trip

    func testEncodedPayloadDecodesBackToTheOriginal() throws {
        let encoded = try CloudPayloadCodec.encode(payload)
        XCTAssertNotEqual(encoded, payload, "The payload was not transformed at all")
        XCTAssertEqual(try CloudPayloadCodec.decode(encoded), payload)
    }

    func testEncodedPayloadIsNotReadableAsPlaintext() throws {
        let secret = Data("RMSSD 42.7 recovery 81".utf8)
        let encoded = try CloudPayloadCodec.encode(secret)
        XCTAssertNil(String(data: encoded, encoding: .utf8).flatMap {
            $0.contains("RMSSD") ? $0 : nil
        }, "Health data is legible in the encoded payload")
    }

    func testAnEmptyPayloadRoundTrips() throws {
        XCTAssertEqual(try CloudPayloadCodec.decode(CloudPayloadCodec.encode(Data())), Data())
    }

    func testALargePayloadRoundTrips() throws {
        let big = Data((0 ..< 400_000).map { UInt8($0 % 251) })
        XCTAssertEqual(try CloudPayloadCodec.decode(try CloudPayloadCodec.encode(big)), big)
    }

    // MARK: - The envelope is identified, not inferred

    func testTheEnvelopeCarriesItsMagicAndVersion() throws {
        let encoded = try CloudPayloadCodec.encode(payload)
        XCTAssertEqual(encoded.prefix(CloudPayloadCodec.magic.count), CloudPayloadCodec.magic)
        XCTAssertEqual(encoded[encoded.index(encoded.startIndex, offsetBy: CloudPayloadCodec.magic.count)],
                       CloudPayloadCodec.version)
    }

    /// Records written before encryption existed are compressed-only. They must
    /// keep working, and must be recognised by the ABSENCE of the envelope
    /// rather than by a decryption that happened to fail — a reader that does
    /// the latter mistakes a wrong-key ciphertext for legacy data.
    func testLegacyPayloadsWithoutTheEnvelopePassThroughUnchanged() throws {
        let legacy = Data("compressed-but-not-encrypted".utf8)
        XCTAssertEqual(try CloudPayloadCodec.decode(legacy), legacy)
    }

    /// The collision a first-byte sniff cannot resolve: a byte sequence that
    /// could plausibly begin either a nonce or a legacy payload.
    func testArbitraryLeadingBytesAreTreatedAsLegacyNotAsCiphertext() throws {
        for first in [UInt8(0), 1, 64, 127, 128, 255] {
            let blob = Data([first]) + Data("payload".utf8)
            XCTAssertEqual(try CloudPayloadCodec.decode(blob), blob,
                           "Leading byte \(first) was not treated as legacy")
        }
    }

    func testAnUnknownVersionIsRejectedRatherThanGuessed() throws {
        var forged = CloudPayloadCodec.magic
        forged.append(99)
        forged.append(contentsOf: [0x01, 0x02, 0x03])
        XCTAssertThrowsError(try CloudPayloadCodec.decode(forged)) { error in
            guard case CloudPayloadCodec.CodecError.unsupportedVersion(99) = error else {
                return XCTFail("Expected unsupportedVersion, got \(error)")
            }
        }
    }

    // MARK: - Tampering

    /// AES-GCM is authenticated; a flipped bit must fail rather than decode to
    /// something plausible.
    func testATamperedPayloadFailsToDecode() throws {
        var encoded = try CloudPayloadCodec.encode(payload)
        let last = encoded.index(before: encoded.endIndex)
        encoded[last] ^= 0xFF
        XCTAssertThrowsError(try CloudPayloadCodec.decode(encoded))
    }

    func testATruncatedPayloadFailsToDecode() throws {
        let encoded = try CloudPayloadCodec.encode(payload)
        XCTAssertThrowsError(try CloudPayloadCodec.decode(encoded.prefix(encoded.count / 2)))
    }

    // MARK: - Portability, which is the point of the whole change

    /// A key must exist, and must be stable across calls.
    func testTheCloudKeyIsAvailableAndStable() throws {
        XCTAssertEqual(try CloudPayloadCodec.decode(CloudPayloadCodec.sealForUpload(payload)), payload)
        // Two encodes must be decodable by the same key — proves the key is
        // persisted rather than regenerated per call, which would make every
        // previous backup unreadable.
        let first = try CloudPayloadCodec.encode(payload)
        let second = try CloudPayloadCodec.encode(payload)
        XCTAssertEqual(try CloudPayloadCodec.decode(first), payload)
        XCTAssertEqual(try CloudPayloadCodec.decode(second), payload)
        XCTAssertNotEqual(first, second, "A fixed nonce would leak plaintext equality")
    }

    // MARK: - The live-backup chain end to end

    /// The exact sequence the live-backup defect broke: encode → compress → seal on write,
    /// unseal → decompress → decode on read.
    func testLiveBackupChainRoundTrips() throws {
        let points = (0 ..< 500).map { i -> RRPoint in
            RRPoint(t_ms: Int64(i * 850), rr_ms: 850 + (i % 7))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let written = try CloudPayloadCodec.encode(
            try DataCompression.compress(try encoder.encode(points))
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let read = try decoder.decode(
            [RRPoint].self,
            from: try DataCompression.decompress(try CloudPayloadCodec.decode(written))
        )

        XCTAssertEqual(read.count, points.count)
        XCTAssertEqual(read.map(\.rr_ms), points.map(\.rr_ms))
        XCTAssertEqual(read.map(\.t_ms), points.map(\.t_ms))
    }
    // MARK: - Key lifecycle (F4)

    /// No cloud key is created while the iCloud account is unconfirmed: the
    /// key is synchronizable, so one created after an Apple ID switch would
    /// reach the other account's Keychain. With no key held the seal fails
    /// closed instead; once the account is confirmed it creates one.
    func testNoKeyIsCreatedWhileTheAccountIsUnconfirmed() throws {
        let created = OSAllocatedUnfairLock(initialState: 0)
        let noKeys = CloudPayloadCodec.KeyStore(read: { [] }, add: {
            created.withLock { $0 += 1 }
            return SymmetricKey(size: .bits256)
        })

        XCTAssertThrowsError(try CloudPayloadCodec.sealForUpload(payload, mayCreateKey: false, in: noKeys)) { error in
            XCTAssertEqual(error as? CloudSyncError, .encryptionUnavailable)
        }
        XCTAssertEqual(created.withLock { $0 }, 0, "a key was created before the account was confirmed")

        XCTAssertNoThrow(try CloudPayloadCodec.sealForUpload(payload, mayCreateKey: true, in: noKeys))
        XCTAssertEqual(created.withLock { $0 }, 1)
    }

    /// A key already held is used whether or not the account is confirmed,
    /// and none is added beside it.
    func testAHeldKeyIsUsedWithoutCreatingAnother() throws {
        let heldBytes = Data(repeating: 7, count: 32)
        let account = CloudPayloadCodec.accountPrefix + "held"
        let store = CloudPayloadCodec.KeyStore(read: { [(account: account, key: SymmetricKey(data: heldBytes))] }, add: {
            XCTFail("a key was added beside the one held")
            return SymmetricKey(size: .bits256)
        })
        let sealed = try CloudPayloadCodec.sealForUpload(payload, mayCreateKey: false, in: store)
        let box = try AES.GCM.SealedBox(combined: sealed.dropFirst(CloudPayloadCodec.magic.count + 1))
        XCTAssertEqual(try CloudPayloadCodec.open(box, withAnyOf: [SymmetricKey(data: heldBytes)]), payload)
    }

    /// Decoding must never mint a key. A payload that cannot be opened caused
    /// a fresh key to be created, which guaranteed it could never be opened —
    /// and displaced the key other backups depended on.
    ///
    /// Checked on the Keychain itself: the accounts holding cloud keys are
    /// the same after decoding a payload this device can open and one sealed
    /// with a key it does not hold.
    func testDecodingDoesNotCreateAKey() throws {
        let sealed = try CloudPayloadCodec.encode(payload)
        let foreignBox = try AES.GCM.seal(payload, using: SymmetricKey(size: .bits256))
        let foreign = CloudPayloadCodec.magic + Data([CloudPayloadCodec.version]) + (try XCTUnwrap(foreignBox.combined))
        let accountsBefore = try cloudKeyAccounts()
        XCTAssertFalse(accountsBefore.isEmpty, "encode stores the key it sealed with")

        XCTAssertEqual(try CloudPayloadCodec.decode(sealed), payload)
        XCTAssertThrowsError(try CloudPayloadCodec.decode(foreign), "A payload sealed with a key this device lacks opened")
        XCTAssertEqual(try cloudKeyAccounts(), accountsBefore, "Decoding added or replaced a cloud key in the Keychain")
    }

    /// The accounts of the cloud keys in the Keychain, found the way the
    /// codec's private `baseQuery` finds them (its service, synchronizable).
    private func cloudKeyAccounts() throws -> Set<String> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.chrissharp.flowrecovery.cloud",
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = items as? [[String: Any]] else {
            throw CloudPayloadCodec.CodecError.keyUnreadable(status)
        }
        return Set(rows.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    /// Repeated writes must keep using the SAME key, or every earlier backup
    /// becomes unreadable the moment a new one is written.
    func testRepeatedWritesRemainMutuallyDecodable() throws {
        let first = try CloudPayloadCodec.encode(Data("first".utf8))
        let second = try CloudPayloadCodec.encode(Data("second".utf8))
        let third = try CloudPayloadCodec.encode(Data("third".utf8))
        XCTAssertEqual(try CloudPayloadCodec.decode(first), Data("first".utf8),
                       "The earliest payload stopped decoding after later writes")
        XCTAssertEqual(try CloudPayloadCodec.decode(second), Data("second".utf8))
        XCTAssertEqual(try CloudPayloadCodec.decode(third), Data("third".utf8))
    }

    /// Concurrent first use must converge on one key, not have the loser
    /// delete the winner's after a backup was already sealed with it.
    func testConcurrentEncodesAllRemainDecodable() async throws {
        let sealed = await withTaskGroup(of: Data?.self) { group -> [Data] in
            for i in 0 ..< 8 {
                group.addTask { try? CloudPayloadCodec.encode(Data("payload-\(i)".utf8)) }
            }
            var out: [Data] = []
            for await value in group { if let value { out.append(value) } }
            return out
        }
        XCTAssertEqual(sealed.count, 8, "Some concurrent encode failed outright")
        for (i, blob) in sealed.enumerated() {
            XCTAssertNoThrow(try CloudPayloadCodec.decode(blob),
                             "Payload \(i) became unreadable — a key was replaced mid-flight")
        }
    }

    // MARK: - More than one key

    /// A device that backed up before iCloud Keychain delivered the existing
    /// key made its own. Records sealed with either key must open wherever
    /// both keys are held.
    func testAPayloadOpensWithWhicheverHeldKeySealedIt() throws {
        let mine = SymmetricKey(size: .bits256)
        let theirs = SymmetricKey(size: .bits256)
        let box = try AES.GCM.seal(payload, using: theirs)

        XCTAssertEqual(try CloudPayloadCodec.open(box, withAnyOf: [mine, theirs]), payload)
    }

    /// Without the sealing key it is a distinct, retryable answer — never bytes.
    func testNoHeldKeyIsReportedAsSuch() throws {
        let box = try AES.GCM.seal(payload, using: SymmetricKey(size: .bits256))

        XCTAssertThrowsError(try CloudPayloadCodec.open(box, withAnyOf: [SymmetricKey(size: .bits256)])) { error in
            guard case CloudPayloadCodec.CodecError.noMatchingKey = error else {
                return XCTFail("expected noMatchingKey, got \(error)")
            }
        }
    }

    /// Devices whose Keychains have synced must all write with the same key,
    /// or the set of keys keeps growing.
    func testEveryDeviceChoosesTheSamePrimaryKey() {
        let a = CloudPayloadCodec.accountPrefix + "B7"
        let b = CloudPayloadCodec.accountPrefix + "A1"

        XCTAssertEqual(CloudPayloadCodec.primaryAccount(among: [a, b]), b)
        XCTAssertEqual(CloudPayloadCodec.primaryAccount(among: [b, a]), b)
        XCTAssertNil(CloudPayloadCodec.primaryAccount(among: []))
    }

    /// Devices on builds from before per-key accounts read only the shared
    /// account, so a key there is the one to keep writing with.
    func testTheSharedLegacyKeyIsPreferred() {
        let accounts = [CloudPayloadCodec.accountPrefix + "A1", CloudPayloadCodec.legacyAccount]

        XCTAssertEqual(CloudPayloadCodec.primaryAccount(among: accounts), CloudPayloadCodec.legacyAccount)
    }

}

/// The settings record: encrypted on write, and still readable when an older
/// build wrote it in the clear.
///
/// Records are built locally — a `CKRecord` needs no account or network — so
/// these run on any host. The encryption goes through the production codec
/// and the real Keychain, like the tests above.
final class CloudSettingsRecordTests: XCTestCase {
    private let zoneID = CKRecordZone.ID(zoneName: "UserSettings", ownerName: CKCurrentUserDefaultName)

    override func setUp() {
        super.setUp()
        standInForConfirmedICloudAccount()
    }

    /// A push replaces only an older cloud copy: one edited after this
    /// device's last change is kept, and so is any dated copy while this
    /// device has no change time; an undated copy never wins.
    func testOnlyAnOlderCloudCopyIsReplaced() {
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        XCTAssertTrue(CloudSettingsRecord.cloudCopyIsNewer(cloudEditedAt: later, localEditedAt: earlier))
        XCTAssertFalse(CloudSettingsRecord.cloudCopyIsNewer(cloudEditedAt: earlier, localEditedAt: later))
        XCTAssertFalse(CloudSettingsRecord.cloudCopyIsNewer(cloudEditedAt: later, localEditedAt: later))
        XCTAssertTrue(CloudSettingsRecord.cloudCopyIsNewer(cloudEditedAt: later, localEditedAt: nil))
        XCTAssertFalse(CloudSettingsRecord.cloudCopyIsNewer(cloudEditedAt: nil, localEditedAt: nil))
    }

    private func emptyRecord() -> CKRecord {
        CKRecord(recordType: "UserSettings", recordID: CKRecord.ID(recordName: "primary", zoneID: zoneID))
    }

    /// Settings with the fields that make them health information, encoded the
    /// way `SettingsManager.currentSettingsJSON` encodes them.
    private func sensitiveSettingsJSON() throws -> Data {
        var settings = UserSettings()
        settings.birthday = Date(timeIntervalSince1970: 500_000_000)
        settings.biologicalSex = .female
        settings.bodyWeightKg = 61.4
        settings.baselineRMSSD = 58.25
        settings.trainingBreakReason = "stress fracture, left tibia"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(settings)
    }

    func testSettingsRoundTripThroughAnEncryptedRecord() throws {
        let json = try sensitiveSettingsJSON()
        let record = emptyRecord()

        CloudSettingsRecord.write(try CloudPayloadCodec.sealForUpload(json), to: record, modifiedAt: Date())
        let restored = try CloudSettingsRecord.settingsJSON(from: record)

        XCTAssertEqual(restored, json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let settings = try decoder.decode(UserSettings.self, from: restored)
        XCTAssertEqual(settings.bodyWeightKg, 61.4)
        XCTAssertEqual(settings.trainingBreakReason, "stress fracture, left tibia")
    }

    /// The edit fingerprint moves with a setting the user edits and stays put
    /// when only what the app writes itself changes (baselines, the trial
    /// start, the sync switch, launch flags), so the app's own writes do not
    /// date the settings as edited.
    func testOnlyAUserEditMovesTheEditFingerprint() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        var settings = UserSettings()
        settings.maxHR = 182
        let before = try CloudSettingsRecord.editFingerprint(try encoder.encode(settings))

        var appWritten = settings
        appWritten.baselineRMSSD = 61.5
        appWritten.baselineHR = 52
        appWritten.trialStartDate = Date(timeIntervalSince1970: 1_700_000_000)
        appWritten.iCloudSyncEnabled.toggle()
        appWritten.hasCompletedOnboarding.toggle()
        appWritten.hasFixedTempAsymmetry.toggle()
        XCTAssertEqual(try CloudSettingsRecord.editFingerprint(try encoder.encode(appWritten)), before)

        var edited = settings
        edited.maxHR = 184
        XCTAssertNotEqual(try CloudSettingsRecord.editFingerprint(try encoder.encode(edited)), before)
    }

    /// Every field the fingerprint leaves out is one the settings encode, so a
    /// renamed key cannot silently turn an app write back into an edit.
    func testTheAppWrittenFieldsAreSettingsKeys() throws {
        var settings = UserSettings()
        settings.baselineRMSSD = 61.5
        settings.baselineHR = 52
        settings.trialStartDate = Date(timeIntervalSince1970: 1_700_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: try encoder.encode(settings)) as? [String: Any])
        XCTAssertEqual(CloudSettingsRecord.appWrittenFields.subtracting(object.keys), [])
    }

    /// Profile values filled from Apple Health are not in the settings that
    /// go to iCloud, and a restore keeps this device's own.
    func testHealthFilledProfileIsLeftOutOfTheUploadAndKeptOnRestore() throws {
        var settings = UserSettings()
        settings.bodyWeightKg = 61.4
        settings.biologicalSex = .female
        settings.profileFieldsFromHealth = [.bodyWeight]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let uploaded = try CloudSettingsRecord.uploadable(try encoder.encode(settings))
        let sent = try decoder.decode(UserSettings.self, from: uploaded)
        XCTAssertNil(sent.bodyWeightKg)
        XCTAssertEqual(sent.biologicalSex, .female)

        let restored = try decoder.decode(
            UserSettings.self, from: try CloudSettingsRecord.restorable(uploaded, keepingProfileOf: settings)
        )
        XCTAssertEqual(restored.bodyWeightKg, 61.4)
        XCTAssertEqual(restored.profileFieldsFromHealth, [.bodyWeight])
    }

    func testTheUploadedPayloadIsNotReadable() throws {
        let sealed = try CloudPayloadCodec.sealForUpload(try sensitiveSettingsJSON())

        XCTAssertEqual(sealed.prefix(CloudPayloadCodec.magic.count), CloudPayloadCodec.magic)
        // Searched as bytes: ciphertext is rarely valid UTF-8, so a check made
        // on a decoded string would pass by failing to decode.
        XCTAssertNil(sealed.range(of: Data("tibia".utf8)), "Free text is legible in the uploaded settings")
        XCTAssertNil(sealed.range(of: Data("bodyWeightKg".utf8)), "Field names are legible in the uploaded settings")
    }

    /// Every push removes what earlier builds wrote in the clear, in the same
    /// save — otherwise the plaintext copy sits next to the encrypted one.
    func testWritingClearsTheLegacyPlaintextFields() throws {
        let record = emptyRecord()
        record[CloudSettingsRecord.legacyJSONField] = "{\"bodyWeightKg\":80}" as CKRecordValue
        record[CloudSettingsRecord.legacyDeviceNameField] = "Jane's iPhone" as CKRecordValue

        CloudSettingsRecord.write(try CloudPayloadCodec.sealForUpload(Data("{}".utf8)), to: record, modifiedAt: Date())

        XCTAssertNil(record[CloudSettingsRecord.legacyJSONField])
        XCTAssertNil(record[CloudSettingsRecord.legacyDeviceNameField])
        XCTAssertNotNil(record[CloudSettingsRecord.payloadField] as? Data)
        XCTAssertNotNil(record[CloudSettingsRecord.modifiedAtField] as? Date)
    }

    /// A record from an older build has only the plaintext field. It must
    /// still restore.
    func testALegacyPlaintextRecordStillRestores() throws {
        let json = try sensitiveSettingsJSON()
        let record = emptyRecord()
        record[CloudSettingsRecord.legacyJSONField] = try XCTUnwrap(String(bytes: json, encoding: .utf8)) as CKRecordValue

        XCTAssertEqual(try CloudSettingsRecord.settingsJSON(from: record), json)
    }

    /// This build always clears the plaintext field, so finding it next to the
    /// encrypted one means an older build wrote last. Its copy is the newer.
    func testThePlaintextFieldWinsWhenAnOlderBuildWroteLast() throws {
        let record = emptyRecord()
        CloudSettingsRecord.write(
            try CloudPayloadCodec.sealForUpload(Data("{\"older\":true}".utf8)),
            to: record, modifiedAt: Date()
        )
        record[CloudSettingsRecord.legacyJSONField] = "{\"newer\":true}" as CKRecordValue

        XCTAssertEqual(try CloudSettingsRecord.settingsJSON(from: record), Data("{\"newer\":true}".utf8))
    }

    /// The encrypted field has only ever been written encrypted. Bytes without
    /// the envelope are damage, and are not handed on as if they were JSON.
    func testAnUnframedPayloadIsRejected() {
        let record = emptyRecord()
        record[CloudSettingsRecord.payloadField] = Data("{\"bodyWeightKg\":80}".utf8) as CKRecordValue

        XCTAssertThrowsError(try CloudSettingsRecord.settingsJSON(from: record)) { error in
            guard case CloudKitSettingsSync.RestoreError.cloudCopyMalformed = error else {
                return XCTFail("expected cloudCopyMalformed, got \(error)")
            }
        }
    }

    func testARecordWithNeitherFieldIsMalformed() {
        XCTAssertThrowsError(try CloudSettingsRecord.settingsJSON(from: emptyRecord())) { error in
            guard case CloudKitSettingsSync.RestoreError.cloudCopyMalformed = error else {
                return XCTFail("expected cloudCopyMalformed, got \(error)")
            }
        }
    }
}

/// What actually goes to iCloud, read off the records the production upload
/// paths build: a session record (`CloudKitSyncManager.buildSessionRecord`)
/// and a live backup (`CloudKitLiveBackupManager.attachUpload`).
///
/// `check_no_health_data_in_cloudkit.sh` reads the source for field writes and
/// seal calls, so a write it cannot parse, or an asset built from bytes other
/// than the sealed ones, gets past it. These build the record and read it:
/// its keys must be exactly the plain fields listed here, and its asset's
/// bytes must be ciphertext that is neither JSON nor a readable compressed
/// stream, and that opens with the cloud key to the payload.
@MainActor
final class CloudUploadRecordTests: XCTestCase {
    private let zoneID = CKRecordZone.ID(zoneName: "HRVSessions", ownerName: CKCurrentUserDefaultName)

    override func setUp() {
        super.setUp()
        standInForConfirmedICloudAccount()
    }

    func testASessionRecordCarriesOnlyItsPlainFieldsAndASealedAsset() throws {
        let session = healthSession()
        let record = try CloudKitSyncManager.buildSessionRecord(from: session, zoneID: zoneID, recordTypeName: "HRVSession")
        defer { removeAsset(record["sessionData"]) }

        // `modifiedAt` is left off once the server schema has refused it
        // (`CloudKitSessionFreshness`), so it is allowed, not required.
        let keys = Set(record.allKeys())
        XCTAssertTrue(keys.isSubset(of: ["sessionId", "startDate", "isDeleted", "modifiedAt", "sessionData"]),
                      "A session record may carry only its plain fields; health data goes in the sealed asset: \(keys.sorted())")
        XCTAssertTrue(keys.isSuperset(of: ["sessionId", "startDate", "isDeleted", "sessionData"]), "\(keys.sorted())")
        let payload = try openedAssetBytes(record["sessionData"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let uploaded = try decoder.decode(HRVSession.self, from: payload)
        XCTAssertEqual(uploaded.id, session.id)
        XCTAssertEqual(uploaded.rrSeries?.points.count, session.rrSeries?.points.count)
        XCTAssertEqual(uploaded.recoveryScore, session.recoveryScore)
    }

    func testALiveBackupCarriesOnlyItsCaptureDateAndASealedAsset() throws {
        let sessionId = UUID()
        let points = (0 ..< 200).map { RRPoint(t_ms: Int64($0) * 800, rr_ms: 800 + $0 % 7) }
        let record = CKRecord(recordType: "LiveRRBackup", recordID: CKRecord.ID(recordName: "live_\(sessionId.uuidString)", zoneID: zoneID))
        record["sessionId"] = sessionId.uuidString as CKRecordValue
        let recordingStart = Date(timeIntervalSince1970: 1_785_538_800)
        let assetURL = try CloudKitLiveBackupManager.attachUpload(of: points, recordingStart: recordingStart, sessionId: sessionId, to: record)
        defer { removeFile(assetURL) }

        XCTAssertEqual(Set(record.allKeys()), ["sessionId", "captureDate", "rrData"],
                       "A live backup may carry only these plain fields; the beats and the recording's start go in the sealed asset")
        let opened = try openedAssetBytes(record["rrData"])
        // A build that reads only the beats still opens it.
        let uploaded = try JSONDecoder().decode([RRPoint].self, from: opened)
        XCTAssertEqual(uploaded.map(\.rr_ms), points.map(\.rr_ms))
        XCTAssertEqual(try LiveBackupPayload.decode(opened).recordingStart, recordingStart,
                       "the recording's start must travel sealed with the beats; the plain capture date is the first upload's")
    }

    /// The asset's bytes, checked to be sealed and then opened with the cloud
    /// key and decompressed: what a pulling device reads.
    private func openedAssetBytes(_ value: (any CKRecordValueProtocol)?) throws -> Data {
        let asset = try XCTUnwrap(value as? CKAsset, "the record carries no asset")
        let raw = try Data(contentsOf: try XCTUnwrap(asset.fileURL))
        XCTAssertEqual(raw.prefix(CloudPayloadCodec.magic.count), CloudPayloadCodec.magic, "the asset is not in the sealed envelope")
        XCTAssertFalse(isJSON(raw), "the asset is plain JSON")
        XCTAssertFalse(decompressesToJSON(raw), "the asset is a readable compressed stream")
        let opened = try DataCompression.decompress(try CloudPayloadCodec.decode(raw))
        XCTAssertTrue(isJSON(opened), "the unsealed asset is not the JSON payload")
        return opened
    }

    /// Whether the bytes are a compressed JSON payload as they stand, with
    /// no key: ciphertext either fails to inflate or inflates to noise.
    private func decompressesToJSON(_ data: Data) -> Bool {
        do {
            return isJSON(try DataCompression.decompress(data))
        } catch {
            return false
        }
    }

    private func isJSON(_ data: Data) -> Bool {
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return true
        } catch {
            return false
        }
    }

    private func healthSession() -> HRVSession {
        let points = (0 ..< 300).map { RRPoint(t_ms: Int64($0) * 900, rr_ms: 900 + $0 % 11) }
        let id = UUID()
        var session = HRVSession(
            id: id,
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_028_800),
            state: .complete,
            sessionType: .overnight,
            rrSeries: RRSeries(points: points, sessionId: id, startDate: Date(timeIntervalSince1970: 1_700_000_000)),
            analysisResult: nil,
            artifactFlags: nil
        )
        session.recoveryScore = 7.4
        session.modifiedAt = Date(timeIntervalSince1970: 1_700_030_000)
        return session
    }

    private func removeAsset(_ value: (any CKRecordValueProtocol)?) {
        guard let url = (value as? CKAsset)?.fileURL else { return }
        removeFile(url)
    }

    private func removeFile(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            XCTFail("could not remove the asset file: \(error)")
        }
    }
}

extension XCTestCase {
    /// `CloudPayloadCodec.sealForUpload` creates a cloud key only while the
    /// signed-in iCloud account is the one sync is enabled for
    /// (`CloudAccountIdentity.isConfirmed`), and a test host has none. A test
    /// that seals stands in for one; the recorded account and any stop notice
    /// are put back when it ends.
    func standInForConfirmedICloudAccount() {
        let defaults = UserDefaults.standard
        let recorded = CloudAccountIdentity.recordedAccount
        let stopReason = defaults.string(forKey: CloudAccountIdentity.stopReasonKey)
        XCTAssertTrue(CloudAccountIdentity.adopt("emuqu-tests", generation: CloudAccountIdentity.checkGeneration))
        addTeardownBlock {
            if let recorded {
                UserDefaults.standard.set(recorded, forKey: CloudAccountIdentity.recordedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: CloudAccountIdentity.recordedKey)
            }
            if let stopReason { UserDefaults.standard.set(stopReason, forKey: CloudAccountIdentity.stopReasonKey) }
            CloudAccountIdentity.revokeConfirmation()
        }
    }
}
