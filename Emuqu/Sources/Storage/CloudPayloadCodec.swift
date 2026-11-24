import CryptoKit
import Foundation
import os
import Security

/// The single envelope format for everything written to iCloud.
///
/// ## Why one codec
///
/// When the writer and the reader each decide independently how a payload is
/// framed, they disagree:
///
///   • **Live backups**: encrypting on write and decompressing on read
///     without decrypting makes a backup unreadable even on the same device
///     with the key present, and silently so: the decode returns nil and
///     `compactMap` drops it, so an unreadable backup looks like no backup.
///
///   • **Session payloads**: the archive key is not synchronizable, correct
///     for local files but wrong for a cloud backup whose entire purpose is
///     restoring onto a *different* device. Phone B would generate its own
///     key, authenticated decryption would fail, and the "legacy" fallback
///     would hand compressed garbage to the decoder.
///
/// One codec, used by both directions, keeps the two sides in agreement.
///
/// ## Key placement
///
/// A dedicated cloud key, separate from `EncryptionManager`'s archive key:
///
///   • the archive key is not synchronizable. It moves only with a device
///     backup or a phone-to-phone transfer, alongside the local files it opens
///     (see `EncryptionManager.keyAccessibility`), never through iCloud
///     Keychain;
///   • the cloud key is `kSecAttrSynchronizable`, so it travels through the
///     iCloud Keychain to any device on the same Apple ID, which is exactly the
///     set of devices entitled to read these backups.
///
/// iCloud Keychain is end-to-end encrypted, so this does not hand Apple the
/// key. It also means a user with iCloud Keychain disabled has no portable
/// key.
///
/// ## More than one key
///
/// A device that writes a backup before iCloud Keychain has delivered the
/// existing key has to create its own. If every device stored its key under
/// the same Keychain account, sync would resolve the two items to one and
/// every record sealed with the other would be unreadable everywhere, for
/// good. So each created key gets an account of its own, sync carries all of
/// them to every device, and `decode` tries each key the device holds —
/// AES-GCM authentication rejects a wrong key outright, so trying is safe.
/// Writers all choose the same key (`primaryAccount`) once their Keychains
/// have converged, so the set stops growing. The original shared account is
/// still read, and preferred, so records and devices that use only that
/// account keep working. A key existing on this device does not show that
/// another device can decrypt, because a local Keychain read cannot establish
/// that iCloud Keychain is on and has synced.
///
/// ## Framing
///
/// A magic prefix and an explicit version byte. Inferring the format from the
/// first byte of the payload collides with a nonce byte, so a wrong-key
/// ciphertext is indistinguishable from a legacy record.
/// Recognising the envelope means a decryption failure is reported as a
/// decryption failure instead of being retried as if it were old data.
enum CloudPayloadCodec {
    /// `EMQC` — Emuqu Cloud. Chosen so no compressed or JSON payload can begin
    /// with it by accident.
    static let magic = Data([0x45, 0x4D, 0x51, 0x43])
    static let version: UInt8 = 1

    private static let keychainService = "com.chrissharp.flowrecovery.cloud"
    /// The original single shared account, still read and preferred.
    static let legacyAccount = "cloud-payload-key-v1"
    /// New keys: this prefix plus a UUID, one account per key.
    static let accountPrefix = "cloud-payload-key-id-"

    enum CodecError: LocalizedError {
        /// The Keychain refused the read or write for a reason other than
        /// absence — device locked, entitlement problem. Absence permits
        /// creating a key; this does not.
        case keyUnreadable(OSStatus)
        case malformedEnvelope
        case unsupportedVersion(UInt8)
        /// No key on this device opens the payload. Usually the key that
        /// sealed it has not arrived through iCloud Keychain yet.
        case noMatchingKey

        var errorDescription: String? {
            let b = LanguageManager.appBundle
            switch self {
            case let .keyUnreadable(status):
                return String(localized: "The iCloud backup key could not be read (Keychain status \(Int(status))).", bundle: b)
            case .malformedEnvelope:
                return String(localized: "The backup is not in a recognised format.", bundle: b)
            case .unsupportedVersion:
                return String(localized: "The backup was made by a newer version of the app. Update the app to read it.", bundle: b)
            case .noMatchingKey:
                return String(localized: "This device doesn't have the key for this backup yet. Check that iCloud Keychain is on, then try again later.", bundle: b)
            }
        }
    }

    /// Seal a payload bound for CloudKit. Every upload goes through here:
    /// session records, live backups and settings.
    ///
    /// Throws `CloudSyncError.encryptionUnavailable` when there is no key to
    /// encrypt with, rather than falling back to plaintext. App Review
    /// Guideline 5.1.3(ii) says apps "may not store personal health
    /// information in iCloud", for all health data, not only data read from
    /// HealthKit, and compression is not confidentiality. The local archive
    /// does the opposite (`Archive+SessionCodec` writes plaintext under
    /// `.completeFileProtectionUnlessOpen` and re-encrypts it later, ADR 001): a local
    /// file can be repaired in place, but an upload cannot be taken back. A
    /// skipped upload is retried on a later cycle.
    ///
    /// Creates a key when the device has none, and only while the signed-in
    /// iCloud account is the one sync is enabled for
    /// (`CloudAccountIdentity.isConfirmed`): the key is synchronizable, so one
    /// created after an Apple ID switch would travel into the new account's
    /// iCloud Keychain, and its owner would hold a key that opens every record
    /// sealed with it. That never displaces a key another backup depends on:
    /// each key has its own Keychain account. A key existing here does not
    /// prove another device can decrypt: the item is synchronizable, but
    /// whether iCloud Keychain is on and has synced is not observable from
    /// this device.
    ///
    /// `mayCreateKey` and `store` are left at their defaults by every upload;
    /// they let the key rules be exercised without the iCloud Keychain.
    static func sealForUpload(
        _ payload: Data, mayCreateKey: Bool = CloudAccountIdentity.isConfirmed, in store: KeyStore = .keychain
    ) throws -> Data {
        let key: SymmetricKey
        do {
            key = try writingKey(mayCreate: mayCreateKey, in: store)
        } catch {
            debugLog("[Cloud] No cloud backup key available: \(error.localizedDescription)", level: .error)
            throw CloudSyncError.encryptionUnavailable
        }
        return try seal(payload, with: key)
    }

    /// Wrap `payload` in the versioned, encrypted envelope. The codec's own
    /// round trip; nothing bound for iCloud uses it, every upload goes
    /// through `sealForUpload`.
    static func encode(_ payload: Data) throws -> Data {
        try seal(payload, with: writingKey(mayCreate: true))
    }

    private static func seal(_ payload: Data, with key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(payload, using: key)
        guard let combined = sealed.combined else { throw CodecError.malformedEnvelope }
        return magic + Data([version]) + combined
    }

    /// `FR` — the framing `EncryptionManager` writes: the two bytes `FR`, then
    /// `EncryptionManager`'s own envelope, sealed with the device archive key.
    /// Cloud records in that format exist and must keep decoding.
    private static let legacyEncryptedMagic = Data([0x46, 0x52])

    /// Unwrap a payload written by any writer that has produced a cloud record.
    ///
    /// Three formats, each identified by its own framing:
    ///
    ///   • `EMQC` — this codec, opened with the portable cloud key.
    ///   • `FR`   — `EncryptionManager`, opened with the device archive key.
    ///     Readable only on the device that wrote it, which is a real
    ///     limitation of that format rather than something to paper over.
    ///   • neither — pre-encryption records, compressed only, returned as-is.
    ///
    /// Recognising `EMQC` alone and returning
    /// everything else unchanged as "legacy compressed" hands an `FR` payload
    /// to the decompressor as if AES-GCM ciphertext were a zlib stream:
    /// every record written under the `FR` framing becomes
    /// unreadable — on the same device, with the same key present.
    ///
    /// A damaged payload in a RECOGNISED format throws. It is never
    /// reclassified as legacy: "this is old data" and "this failed to decrypt"
    /// are different answers, and conflating them turns a decryption failure
    /// into silent corruption.
    static func decode(_ raw: Data) throws -> Data {
        if raw.count > magic.count, raw.prefix(magic.count) == magic {
            return try openCurrent(raw)
        }
        if raw.count > legacyEncryptedMagic.count,
           raw.prefix(legacyEncryptedMagic.count) == legacyEncryptedMagic {
            // Whole payload, framing included — EncryptionManager parses its own.
            // The archive key, not the cloud key — FR payloads were sealed by
            // EncryptionManager and only it can open them.
            let archive = AppDependencies.current.storage.encryptionManager
            return try archive.decrypt(raw)
        }
        return raw
    }

    private static func openCurrent(_ raw: Data) throws -> Data {
        let versionByte = raw[raw.index(raw.startIndex, offsetBy: magic.count)]
        guard versionByte == version else { throw CodecError.unsupportedVersion(versionByte) }
        let box = try AES.GCM.SealedBox(combined: raw.dropFirst(magic.count + 1))
        return try open(box, withAnyOf: storedKeys().map(\.key))
    }

    /// Open with whichever key sealed the box.
    ///
    /// GCM authenticates: a wrong key fails with `authenticationFailure` and
    /// never yields bytes, so trying each key cannot return garbage. Any other
    /// failure is about the box, not the key, and is thrown as-is.
    static func open(_ box: AES.GCM.SealedBox, withAnyOf keys: [SymmetricKey]) throws -> Data {
        for key in keys {
            do {
                return try AES.GCM.open(box, using: key)
            } catch CryptoKitError.authenticationFailure {
                continue
            }
        }
        throw CodecError.noMatchingKey
    }

    // MARK: - Key

    /// A key this device holds, with the Keychain account it is stored under.
    typealias StoredKey = (account: String, key: SymmetricKey)

    /// Where the cloud keys are kept: the synchronizable Keychain items
    /// (`keychain`), or a stand-in that exercises the key rules on their own.
    struct KeyStore: Sendable {
        /// Every key held; throws when the store refuses the read.
        let read: @Sendable () throws -> [StoredKey]
        /// Adds a new key under an account of its own and returns it.
        let add: @Sendable () throws -> SymmetricKey

        static let keychain = KeyStore(read: { try CloudPayloadCodec.storedKeys() }, add: { try CloudPayloadCodec.create() })
    }

    /// The key new payloads are sealed with, created when the device has none.
    ///
    /// Only genuine absence permits creating one. A Keychain that refuses the
    /// read (locked, entitlement problem) is not a first run, and a key minted
    /// over that failure would seal backups no other device can open.
    ///
    /// Creation is serialized and re-checks under the lock: two first writers
    /// (settings push, session push, live backup) would otherwise each add a
    /// key under its own account. The usual path, a key already stored, takes
    /// no lock. Without `mayCreate` a missing key throws
    /// `CloudSyncError.encryptionUnavailable` instead.
    private static func writingKey(mayCreate: Bool, in store: KeyStore = .keychain) throws -> SymmetricKey {
        if let primary = try primaryKey(in: store) { return primary }
        return try keyCreation.withLock { _ in
            if let primary = try primaryKey(in: store) { return primary }
            guard mayCreate else {
                debugLog("[Cloud] No cloud backup key, and none is created before the iCloud account is confirmed", level: .warning)
                throw CloudSyncError.encryptionUnavailable
            }
            return try store.add()
        }
    }

    /// Serializes `create()` against concurrent first writers.
    private static let keyCreation = OSAllocatedUnfairLock()

    /// The key `store` holds under `primaryAccount`, or nil when there is none.
    private static func primaryKey(in store: KeyStore) throws -> SymmetricKey? {
        let keys = try store.read()
        guard let account = primaryAccount(among: keys.map(\.account)) else { return nil }
        return keys.first(where: { $0.account == account })?.key
    }

    /// Which stored key every device writes with.
    ///
    /// Deterministic in the set of accounts, so devices whose Keychains have
    /// synced agree without coordinating. The shared legacy account wins when
    /// present: devices on builds from before per-key accounts can only read
    /// that one.
    static func primaryAccount(among accounts: [String]) -> String? {
        if accounts.contains(legacyAccount) { return legacyAccount }
        return accounts.filter { $0.hasPrefix(accountPrefix) }.min()
    }

    /// Add a new key under an account of its own.
    private static func create() throws -> SymmetricKey {
        let fresh = SymmetricKey(size: .bits256)
        var query = baseQuery()
        query[kSecAttrAccount as String] = accountPrefix + UUID().uuidString
        query[kSecValueData as String] = fresh.withUnsafeBytes { Data($0) }
        // After first unlock and NOT ThisDeviceOnly — that pairing is what
        // lets the item synchronise while staying unreadable before the device
        // has been unlocked once since boot.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CodecError.keyUnreadable(status) }
        return fresh
    }

    /// Every cloud key this device holds, with its account.
    ///
    /// `errSecItemNotFound` means none; anything else is a failure to read,
    /// which is NOT the same thing. Collapsing the two is what let a locked
    /// Keychain look like a first run.
    private static func storedKeys() throws -> [StoredKey] {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            guard let rows = items as? [[String: Any]] else { throw CodecError.keyUnreadable(status) }
            return keys(from: rows)
        case errSecItemNotFound:
            return []
        default:
            throw CodecError.keyUnreadable(status)
        }
    }

    /// The primary key first, so the common case opens on the first try.
    private static func keys(from rows: [[String: Any]]) -> [StoredKey] {
        rows.compactMap { row -> StoredKey? in
            guard let account = row[kSecAttrAccount as String] as? String,
                  let data = row[kSecValueData as String] as? Data else { return nil }
            return (account, SymmetricKey(data: data))
        }
        .sorted { lhs, rhs in primaryAccount(among: [lhs.account, rhs.account]) == lhs.account }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            // The whole point: this key must reach the user's other devices.
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]
    }
}
