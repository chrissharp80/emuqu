import CryptoKit
import Foundation
import Security

/// The single envelope format for everything written to iCloud.
///
/// ## Why this exists
///
/// Two defects, both from the same root cause — the writer and the reader each
/// decided independently how a payload was framed:
///
///   • **Live backups**: `CloudKitLiveBackupManager` encrypted on write and
///     decompressed on read without decrypting. A backup written today could
///     not be read back today, on the same device, with the key present. It
///     did not surface as an error either: the decode returned nil and
///     `compactMap` dropped it, so an unreadable backup looked like no backup.
///
///   • **Session payloads**: they were encrypted with the archive key, which is
///     not synchronizable — correct for local files, wrong for a cloud backup
///     whose entire purpose is restoring onto a *different* device. Phone B would generate its own key, authenticated
///     decryption would fail, and the "legacy" fallback would hand compressed
///     garbage to the decoder.
///
/// One codec, used by both directions, removes the class of bug rather than
/// the two instances.
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
/// still read, and preferred, so records and devices from before this change
/// keep working. `hasUsableKey` reports whether a key exists to encrypt with; it does
/// NOT assert that another device can decrypt, because a local Keychain read
/// cannot establish that iCloud Keychain is on and has synced.
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
    /// The single shared account every key used to live under.
    static let legacyAccount = "cloud-payload-key-v1"
    /// Keys created from now on: this prefix plus a UUID, one account per key.
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
            switch self {
            case let .keyUnreadable(status):
                return "The iCloud backup key could not be read (Keychain status \(status))."
            case .malformedEnvelope:
                return "The backup payload is not in a recognised format."
            case let .unsupportedVersion(v):
                return "The backup payload uses format version \(v), which this build cannot read."
            case .noMatchingKey:
                return "None of this device's iCloud backup keys opens the payload; the key that sealed it may not have synced here yet."
            }
        }
    }

    /// Whether a usable cloud key is present on this device.
    ///
    /// Not proof of
    /// portability, which a local Keychain read cannot establish. The item is
    /// marked synchronizable, but whether it has actually reached another
    /// device depends on iCloud Keychain being enabled and having synced —
    /// neither of which is observable from here. Apple documents
    /// synchronization as conditional and user-disableable.
    ///
    /// So this answers the question it can answer: is there a key to encrypt
    /// with. It does NOT assert that a second device can decrypt, and callers
    /// must not present it as a restore guarantee.
    ///
    /// Creates a key when the device has none, exactly as `encode` would. That
    /// never displaces a key another backup depends on: each key has its own
    /// Keychain account.
    static var hasUsableKey: Bool {
        do {
            _ = try writingKey()
            return true
        } catch {
            debugLog("[Cloud] No cloud backup key available: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    /// Wrap `payload` in the versioned, encrypted envelope.
    static func encode(_ payload: Data) throws -> Data {
        let sealed = try AES.GCM.seal(payload, using: writingKey())
        guard let combined = sealed.combined else { throw CodecError.malformedEnvelope }
        return magic + Data([version]) + combined
    }

    /// `FR` — the framing `EncryptionManager` writes.
    ///
    /// The cloud writer used it at commit c4670af, so records in that format
    /// exist and must keep decoding.
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
    /// are different answers, and conflating them is what turned a decryption
    /// failure into silent corruption.
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

    /// The key new payloads are sealed with, created when the device has none.
    ///
    /// Only genuine absence permits creating one. A Keychain that refuses the
    /// read (locked, entitlement problem) is not a first run, and a key minted
    /// over that failure would seal backups no other device can open.
    private static func writingKey() throws -> SymmetricKey {
        let keys = try storedKeys()
        if let account = primaryAccount(among: keys.map(\.account)),
           let primary = keys.first(where: { $0.account == account }) {
            return primary.key
        }
        return try create()
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
    private static func storedKeys() throws -> [(account: String, key: SymmetricKey)] {
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
    private static func keys(from rows: [[String: Any]]) -> [(account: String, key: SymmetricKey)] {
        rows.compactMap { row -> (account: String, key: SymmetricKey)? in
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
