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
///     stored `ThisDeviceOnly` and not synchronizable — correct for local
///     files, wrong for a cloud backup whose entire purpose is restoring onto
///     a *different* device. Phone B would generate its own key, authenticated
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
///   • the archive key stays `ThisDeviceOnly` — local files never leave, and
///     weakening their protection to solve a sync problem would be backwards;
///   • the cloud key is `kSecAttrSynchronizable`, so it travels through the
///     iCloud Keychain to any device on the same Apple ID, which is exactly the
///     set of devices entitled to read these backups.
///
/// iCloud Keychain is end-to-end encrypted, so this does not hand Apple the
/// key. It also means a user with iCloud Keychain disabled has no portable
/// key. `hasUsableKey` reports whether a key exists to encrypt with; it does
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
    private static let keychainAccount = "cloud-payload-key-v1"

    enum CodecError: LocalizedError {
        case keyUnavailable
        case keyAlreadyExists
        /// The Keychain refused the read for a reason other than absence —
        /// device locked, entitlement problem. Distinct from `keyUnavailable`
        /// because absence permits creating a key and a read failure does not.
        case keyUnreadable(OSStatus)
        case malformedEnvelope
        case unsupportedVersion(UInt8)

        var errorDescription: String? {
            switch self {
            case .keyUnavailable:
                return "No iCloud backup key exists on this device yet."
            case .keyAlreadyExists:
                return "An iCloud backup key already exists."
            case let .keyUnreadable(status):
                return "The iCloud backup key could not be read (Keychain status \(status))."
            case .malformedEnvelope:
                return "The backup payload is not in a recognised format."
            case let .unsupportedVersion(v):
                return "The backup payload uses format version \(v), which this build cannot read."
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
    /// Reads only. It never creates a key, because "can I encrypt right now"
    /// should not have the side effect of minting something that displaces a
    /// key an existing backup depends on.
    static var hasUsableKey: Bool {
        do {
            _ = try loadOrCreate()
            return true
        } catch {
            debugLog("[Cloud] No cloud backup key available: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    /// Wrap `payload` in the versioned, encrypted envelope.
    static func encode(_ payload: Data) throws -> Data {
        let sealed = try AES.GCM.seal(payload, using: loadOrCreate())
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
        return try AES.GCM.open(box, using: existingKey())
    }

    // MARK: - Key

    /// The key for READING. Never creates one.
    ///
    /// Decoding must not call the create-if-missing
    /// path: a payload that could not be opened would cause a brand-new key to
    /// be minted — guaranteeing it could never be opened. Decryption asks
    /// "what sealed this"; a fresh random key is never the answer.
    private static func existingKey() throws -> SymmetricKey {
        try load()
    }

    /// The key for WRITING, created on first use.
    ///
    /// `SecItemAdd` is the arbiter, not a prior read. Two callers racing on
    /// first use both see no key; if the loser then deletes and re-adds, it
    /// removes the winner's key after a backup has already been sealed with
    /// it. A duplicate means someone else won, and the winning item is
    /// re-read rather than replaced.
    private static func loadOrCreate() throws -> SymmetricKey {
        do {
            return try load()
        } catch CodecError.keyUnavailable {
            // Genuinely absent — the only case where creating one is correct.
            // Every other error (locked device, entitlement problem) propagates,
            // because minting a key over a temporary read failure is precisely
            // the F4 defect.
            return try create()
        }
    }

    /// Add a key, deferring to whoever won a concurrent race.
    private static func create() throws -> SymmetricKey {
        do {
            let fresh = SymmetricKey(size: .bits256)
            try add(fresh)
            return fresh
        } catch CodecError.keyAlreadyExists {
            return try load()
        }
    }

    /// Read the stored key.
    ///
    /// `errSecItemNotFound` means absent; anything else is a failure to read,
    /// which is NOT the same thing. Collapsing the two is what let a locked
    /// Keychain look like a first run.
    private static func load() throws -> SymmetricKey {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw CodecError.keyUnreadable(status) }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            throw CodecError.keyUnavailable
        default:
            throw CodecError.keyUnreadable(status)
        }
    }

    /// Add the key only if absent.
    ///
    /// Deliberately NOT delete-then-add. That sequence destroyed a key an
    /// existing backup still needed whenever two callers raced, or whenever a
    /// transient read failure was mistaken for absence — an encryption key is
    /// never safe to replace as a side effect of looking for one.
    private static func add(_ key: SymmetricKey) throws {
        var query = baseQuery()
        query[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        // After first unlock and NOT ThisDeviceOnly — that pairing is what
        // lets the item synchronise while staying unreadable before the device
        // has been unlocked once since boot.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        switch SecItemAdd(query as CFDictionary, nil) {
        case errSecSuccess: return
        case errSecDuplicateItem: throw CodecError.keyAlreadyExists
        default: throw CodecError.keyUnavailable
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            // The whole point: this key must reach the user's other devices.
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]
    }
}
