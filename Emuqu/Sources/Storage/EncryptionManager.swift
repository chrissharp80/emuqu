import CryptoKit
import Foundation
import os
import Security

/// Manages encryption for sensitive health data at rest.
/// Uses AES-GCM encryption with versioned keys stored in the Keychain.
///
/// Key versioning enables safe key rotation: new data is encrypted with the
/// current key version, while old data can still be decrypted using its
/// original key. The version byte is prepended to encrypted output.
///
/// Wire format (v2+): [0x46, 0x52 (magic "FR")] [version: UInt8] [nonce + ciphertext + tag: AES-GCM combined]
/// Legacy format (v1): [version: UInt8] [nonce + ciphertext + tag: AES-GCM combined]
///   or bare:          [nonce + ciphertext + tag: AES-GCM combined]
///
/// ## Key Rotation Procedure
///
/// 1. Increment ``currentKeyVersion`` (e.g. 1 → 2). A new 256-bit key is
///    auto-generated in the Keychain under account `session-encryption-key-v2`.
/// 2. New writes use the new key automatically. Old data remains readable
///    because ``decrypt(_:)`` reads the version byte and loads the matching
///    key (it never creates one).
/// 3. To migrate existing files, call ``reEncryptIfNeeded(_:)`` on each
///    encrypted blob — it returns re-encrypted data if the version differs,
///    or nil if already current. Nothing in the app calls it yet: a rotation
///    must add the pass that walks the session and backup files.
/// 4. Once all files are migrated, the old Keychain entry can optionally be
///    deleted via `SecItemDelete` with the old account name, but leaving it
///    is harmless (in case a backup restore brings back old data).
final class EncryptionManager: Sendable {
    static let shared = EncryptionManager()

    // MARK: - Key Versioning

    /// Current key version used for new encryption operations.
    /// Increment this when rotating keys and store the new key under the new account name.
    static let currentKeyVersion: UInt8 = 1

    /// Magic prefix bytes ("FR" for Emuqu) used to unambiguously identify
    /// the new versioned format vs. legacy data where the first byte could be a random nonce byte.
    private static let magicPrefix: [UInt8] = [0x46, 0x52]

    /// Keychain service identifier (shared across all key versions)
    private let keychainService = AppConfig.keychainService

    /// In-memory memo of the symmetric key per version. The key is immutable for
    /// the process lifetime, so after the first successful keychain read we reuse
    /// it instead of a keychain IPC round-trip on EVERY decrypt. A cold dashboard
    /// load decrypts ~35 sessions; without this they serialized on 35 keychain
    /// fetches (a real cold-start cost). The lock also serializes key creation,
    /// so two first-launch writers cannot each mint a key. The KEYCHAIN remains the
    /// source of truth — a relaunch re-reads it, and only a value we actually
    /// retrieved/created is cached, so a locked-device failure still propagates
    /// and is never memoized.
    private let cachedKeys = OSAllocatedUnfairLock<[UInt8: SymmetricKey]>(initialState: [:])

    /// Keychain account name for a specific key version
    private func keychainAccount(for version: UInt8) -> String {
        if version == 1 {
            // Version 1 uses the original account name for backward compatibility
            return "session-encryption-key"
        }
        return "session-encryption-key-v\(version)"
    }

    private init() {}

    // MARK: - Public API

    /// Encrypt data using AES-GCM with the current key version.
    /// - Parameter data: Plain data to encrypt
    /// - Returns: Versioned encrypted data: [magic "FR"] + [version byte] + [nonce + ciphertext + tag]
    func encrypt(_ data: Data) throws -> Data {
        let version = Self.currentKeyVersion
        let key = try getOrCreateKey(version: version)
        let sealedBox = try AES.GCM.seal(data, using: key)

        guard let combined = sealedBox.combined else {
            throw EncryptionError.encryptionFailed
        }

        // Prepend magic prefix + version byte
        var versioned = Data(Self.magicPrefix)
        versioned.append(version)
        versioned.append(combined)
        return versioned
    }

    /// Decrypt data encrypted with encrypt().
    /// Supports both versioned (version byte prefix) and legacy (unversioned) formats.
    /// - Parameter encryptedData: Versioned or legacy encrypted data
    /// - Returns: Original plain data
    ///
    /// A bare legacy blob whose first nonce byte happens to be 1-127 parses as
    /// version-prefixed; when that reading fails, the whole blob is tried as
    /// bare with the v1 key before giving up.
    func decrypt(_ encryptedData: Data) throws -> Data {
        let (version, payload) = extractVersion(from: encryptedData)
        do {
            return try openSealed(payload, version: version)
        } catch {
            guard payload.count < encryptedData.count, magicPrefixed(encryptedData) == nil else { throw error }
            return try openSealed(encryptedData, version: 1)
        }
    }

    private func openSealed(_ combined: Data, version: UInt8) throws -> Data {
        let key = try loadKey(version: version)
        return try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: key)
    }

    /// Check if encryption is available (current key version)
    var isAvailable: Bool {
        do {
            _ = try getOrCreateKey(version: Self.currentKeyVersion)
            return true
        } catch {
            return false
        }
    }

    /// Re-encrypt data from any key version to the current key version.
    /// Returns nil if the data is already encrypted with the current version.
    /// - Parameter encryptedData: Previously encrypted data (any version)
    /// - Returns: Re-encrypted data with current key version, or nil if already current
    func reEncryptIfNeeded(_ encryptedData: Data) throws -> Data? {
        let (version, _) = extractVersion(from: encryptedData)
        guard version != Self.currentKeyVersion else { return nil }

        // Decrypt with old key, re-encrypt with current key
        let plaintext = try decrypt(encryptedData)
        return try encrypt(plaintext)
    }

    // MARK: - Version Extraction

    /// Extract key version from encrypted data.
    ///
    /// Three formats are supported (newest to oldest):
    /// 1. Magic-prefixed: [0x46, 0x52, version, AES-GCM combined...] — current format
    /// 2. Version-prefixed (legacy v1): [version(1-127), AES-GCM combined...] — old format
    /// 3. Bare (legacy v0): [AES-GCM combined...] — original unversioned format
    ///
    /// Detection: if the first two bytes are 0x46, 0x52 ("FR"), it's the new format.
    /// Otherwise fall back to the old heuristic for pre-magic data, and finally bare format.
    /// All legacy paths use version 1 (same key as the original unversioned key).
    private func extractVersion(from data: Data) -> (version: UInt8, payload: Data) {
        guard !data.isEmpty else { return (1, data) }
        if let magic = magicPrefixed(data) { return magic }
        if let legacy = legacyVersionPrefixed(data) { return legacy }
        // Bare legacy format: no version byte, entire data is AES-GCM combined.
        // Use version 1 (same key as the original unversioned key).
        return (1, data)
    }

    /// New format: magic prefix [0x46, 0x52] then a version byte.
    /// Minimum size: 2 (magic) + 1 (version) + 28 (AES-GCM minimum) = 31.
    private func magicPrefixed(_ data: Data) -> (version: UInt8, payload: Data)? {
        guard data.count >= 31,
              data[data.startIndex] == Self.magicPrefix[0],
              data[data.startIndex + 1] == Self.magicPrefix[1] else { return nil }
        return (
            data[data.startIndex + 2],
            data.subdata(in: (data.startIndex + 3) ..< data.endIndex)
        )
    }

    /// Legacy version-prefixed format (pre-magic): first byte 1-127, rest is
    /// valid AES-GCM.
    private func legacyVersionPrefixed(_ data: Data) -> (version: UInt8, payload: Data)? {
        let firstByte = data[data.startIndex]
        guard firstByte >= 1, firstByte <= 127, data.count >= 29 else { return nil }
        let payload = data.subdata(in: (data.startIndex + 1) ..< data.endIndex)
        guard payload.count >= 28 else { return nil }
        return (firstByte, payload)
    }

    // MARK: - Key Management

    /// Errors other than `keyNotFound` (e.g. errSecInteractionNotAllowed when
    /// the device is locked) propagate and are NOT cached, so a later unlocked
    /// call re-tries the keychain. We must never silently create a new key
    /// when the old one is just temporarily inaccessible.
    /// Decryption only ever reads keys. Creating one for whatever version
    /// byte a blob carries stored a new random key for every corrupt or bare
    /// legacy file, and that key could never open it.
    private func loadKey(version: UInt8) throws -> SymmetricKey {
        try cachedKeys.withLock { cache in
            if let cached = cache[version] { return cached }
            let account = keychainAccount(for: version)
            let key = SymmetricKey(data: try retrieveKeyFromKeychain(account: account))
            makeKeyMigratable(account: account)
            cache[version] = key
            return key
        }
    }

    private func getOrCreateKey(version: UInt8) throws -> SymmetricKey {
        try cachedKeys.withLock { cache in
            try loadOrCreateKey(version: version, cache: &cache)
        }
    }

    private func loadOrCreateKey(version: UInt8, cache: inout [UInt8: SymmetricKey]) throws -> SymmetricKey {
        // Reuse the memoized key if we've already retrieved/created it this
        // process (see `cachedKeys`). Skips a keychain round-trip per decrypt.
        if let cached = cache[version] {
            return cached
        }
        let account = keychainAccount(for: version)
        do {
            let key = SymmetricKey(data: try retrieveKeyFromKeychain(account: account))
            makeKeyMigratable(account: account)
            cache[version] = key
            return key
        } catch EncryptionError.keyNotFound {
            // Key genuinely doesn't exist — create one
            let newKey = SymmetricKey(size: .bits256)
            try storeKeyInKeychain(newKey, account: account)
            cache[version] = newKey
            return newKey
        }
    }

    private func storeKeyInKeychain(_ key: SymmetricKey, account: String) throws {
        let keyData = key.withUnsafeBytes { Data($0) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: Self.keyAccessibility
        ]

        // Delete any existing key first
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EncryptionError.keychainError(status)
        }
    }

    /// Not `ThisDeviceOnly`. The session files this key encrypts are in the
    /// device backup, and a this-device-only key is not: restored to a new
    /// phone, every night was listed and none could be opened, while a fresh
    /// key was minted over them. Without the suffix the key moves with an
    /// encrypted or iCloud backup and with a phone-to-phone transfer, next to
    /// the files it opens. It still never leaves the device in the clear.
    private static var keyAccessibility: CFString { kSecAttrAccessibleAfterFirstUnlock }

    /// Keys stored by earlier builds were this-device-only. Their accessibility
    /// is updated in place on first use — the key bytes do not change — so the
    /// next backup carries them. A failure is harmless and retried next launch.
    private func makeKeyMigratable(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let update: [String: Any] = [kSecAttrAccessible as String: Self.keyAccessibility]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            debugLog("[Encryption] could not make the local key migratable: \(status)", level: .warning)
        }
    }

    /// Distinguishes "key genuinely absent" from "keychain temporarily
    /// inaccessible" (e.g. device locked → errSecInteractionNotAllowed). Only
    /// `keyNotFound` should trigger key creation; all other errors must
    /// propagate to avoid overwriting an existing key with a new one.
    private func retrieveKeyFromKeychain(account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let keyData = result as? Data {
            return keyData
        }
        if status == errSecItemNotFound {
            throw EncryptionError.keyNotFound
        }
        throw EncryptionError.keychainError(status)
    }

    // MARK: - Errors

    enum EncryptionError: Error, LocalizedError {
        case encryptionFailed
        case decryptionFailed
        case keyNotFound
        case keychainError(OSStatus)

        /// Reaches Settings through the sync error line, so it is localized.
        var errorDescription: String? {
            let bundle = LanguageManager.appBundle
            return switch self {
            case .encryptionFailed:
                String(localized: "Failed to encrypt data", bundle: bundle)
            case .decryptionFailed:
                String(localized: "Failed to decrypt data", bundle: bundle)
            case .keyNotFound:
                String(localized: "Encryption key not found in keychain", bundle: bundle)
            case let .keychainError(status):
                String(localized: "Keychain error: \(Int(status))", bundle: bundle)
            }
        }
    }
}
