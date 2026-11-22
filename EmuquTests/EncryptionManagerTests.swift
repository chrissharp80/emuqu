import CryptoKit
@testable import Emuqu
import Security
import XCTest

final class EncryptionManagerTests: XCTestCase {
    // MARK: - Encrypt/Decrypt Roundtrip

    func testEncryptDecryptRoundtrip() throws {
        let manager = EncryptionManager.shared
        let original = Data("Sensitive health data for testing".utf8)

        let encrypted = try manager.encrypt(original)
        let decrypted = try manager.decrypt(encrypted)

        XCTAssertEqual(decrypted, original)
    }

    func testEncryptDecryptLargeData() throws {
        let manager = EncryptionManager.shared
        // Simulate a large session JSON (~50KB)
        let json = String(repeating: "{\"rr_ms\":800,\"t_ms\":12345},", count: 2000)
        let original = try XCTUnwrap(json.data(using: .utf8))

        let encrypted = try manager.encrypt(original)
        let decrypted = try manager.decrypt(encrypted)

        XCTAssertEqual(decrypted, original)
    }

    func testEncryptDecryptEmptyData() throws {
        let manager = EncryptionManager.shared
        let original = Data()

        let encrypted = try manager.encrypt(original)
        let decrypted = try manager.decrypt(encrypted)

        XCTAssertEqual(decrypted, original)
    }

    // MARK: - Wire Format

    func testEncryptedDataHasMagicPrefix() throws {
        let manager = EncryptionManager.shared
        let original = Data("test".utf8)

        let encrypted = try manager.encrypt(original)

        // First two bytes should be magic prefix "FR" (0x46, 0x52)
        XCTAssertGreaterThanOrEqual(encrypted.count, 3)
        XCTAssertEqual(encrypted[0], 0x46, "First byte should be 'F'")
        XCTAssertEqual(encrypted[1], 0x52, "Second byte should be 'R'")
    }

    func testEncryptedDataHasVersionByte() throws {
        let manager = EncryptionManager.shared
        let original = Data("test".utf8)

        let encrypted = try manager.encrypt(original)

        // Third byte should be current key version
        XCTAssertEqual(encrypted[2], EncryptionManager.currentKeyVersion)
    }

    func testEncryptedDataLargerThanOriginal() throws {
        let manager = EncryptionManager.shared
        let original = Data("short".utf8)

        let encrypted = try manager.encrypt(original)

        // Encrypted should be larger (magic + version + nonce + tag overhead)
        XCTAssertGreaterThan(encrypted.count, original.count)
    }

    // MARK: - Determinism

    func testEncryptProducesDifferentCiphertexts() throws {
        let manager = EncryptionManager.shared
        let original = Data("same plaintext".utf8)

        let encrypted1 = try manager.encrypt(original)
        let encrypted2 = try manager.encrypt(original)

        // AES-GCM uses random nonce, so same plaintext should produce different ciphertext
        XCTAssertNotEqual(
            encrypted1,
            encrypted2,
            "Same plaintext should produce different ciphertexts (random nonce)"
        )

        // But both should decrypt to the same value
        let decrypted1 = try manager.decrypt(encrypted1)
        let decrypted2 = try manager.decrypt(encrypted2)
        XCTAssertEqual(decrypted1, decrypted2)
    }

    // MARK: - Availability

    func testIsAvailable() {
        XCTAssertTrue(
            EncryptionManager.shared.isAvailable,
            "Encryption should be available in test environment"
        )
    }

    // MARK: - Re-encryption

    func testReEncryptIfNeededReturnNilForCurrentVersion() throws {
        let manager = EncryptionManager.shared
        let original = Data("test data".utf8)

        let encrypted = try manager.encrypt(original)
        let reEncrypted = try manager.reEncryptIfNeeded(encrypted)

        XCTAssertNil(reEncrypted, "Should return nil when already at current version")
    }

    // MARK: - Error Descriptions

    func testEncryptionErrorDescriptions() throws {
        let errors: [EncryptionManager.EncryptionError] = [
            .encryptionFailed,
            .decryptionFailed,
            .keyNotFound,
            .keychainError(-25300)
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(try XCTUnwrap(error.errorDescription?.isEmpty))
        }
    }

    // MARK: - Binary Data

    func testEncryptDecryptBinaryData() throws {
        let manager = EncryptionManager.shared
        // Random-ish binary data
        var bytes = [UInt8](repeating: 0, count: 4096)
        for i in 0 ..< bytes.count {
            bytes[i] = UInt8((i * 7 + 13) % 256)
        }
        let original = Data(bytes)

        let encrypted = try manager.encrypt(original)
        let decrypted = try manager.decrypt(encrypted)

        XCTAssertEqual(decrypted, original)
    }

    // MARK: - Older formats on disk

    /// The AES-GCM box of a current-format blob: what an older build wrote
    /// after its version byte (v1) or on its own (bare).
    private func sealedBox(of original: Data) throws -> Data {
        let framed = try EncryptionManager.shared.encrypt(original)
        XCTAssertEqual(Array(framed.prefix(3)), [0x46, 0x52, EncryptionManager.currentKeyVersion])
        return framed.subdata(in: 3 ..< framed.count)
    }

    /// A v1 blob, one version byte and no "FR" frame, still opens with the
    /// v1 key.
    func testAVersionPrefixedLegacyBlobDecrypts() throws {
        let original = Data("written by a v1 build".utf8)
        let legacy = try Data([1]) + sealedBox(of: original)

        XCTAssertEqual(try EncryptionManager.shared.decrypt(legacy), original)
    }

    /// A bare blob, no frame and no version byte, opens whatever its first
    /// (random nonce) byte is. When that byte reads as a version (1-127) the
    /// framed reading fails and the whole blob is opened as bare; otherwise
    /// it is bare from the start. Both kinds are made, until each has been
    /// seen.
    func testABareLegacyBlobDecryptsWhateverItsFirstByteReadsAs() throws {
        var openedAfterAFramedReading = false
        var openedAsBareAtOnce = false
        for index in 0 ..< 200 where !(openedAfterAFramedReading && openedAsBareAtOnce) {
            let original = Data("night \(index)".utf8)
            let bare = try sealedBox(of: original)
            XCTAssertEqual(try EncryptionManager.shared.decrypt(bare), original, "a bare blob starting \(bare[0]) did not open")
            if (1 ... 127).contains(bare[0]), bare[0] != 0x46 {
                openedAfterAFramedReading = true
            } else if bare[0] != 0x46 {
                openedAsBareAtOnce = true
            }
        }
        XCTAssertTrue(openedAfterAFramedReading, "no bare blob read first as framed")
        XCTAssertTrue(openedAsBareAtOnce, "no bare blob read as bare at once")
    }

    /// Tampered ciphertext fails authentication in every reading, framed and
    /// bare, so decrypt throws rather than returning other bytes.
    func testTamperedCiphertextIsRejected() throws {
        var framed = try EncryptionManager.shared.encrypt(Data("intact".utf8))
        framed[framed.count - 1] ^= 0x01
        XCTAssertThrowsError(try EncryptionManager.shared.decrypt(framed))

        var bare = try sealedBox(of: Data("intact".utf8))
        bare[bare.count / 2] ^= 0x80
        XCTAssertThrowsError(try EncryptionManager.shared.decrypt(bare))
    }

    /// Every older format uses the v1 key, the current one, so none of them
    /// is re-encrypted; a frame naming a version this install has no key for
    /// cannot be opened and is reported, and decrypting it never creates that
    /// key (a key made for a version byte could never open the blob).
    func testReEncryptionOfOlderFormatsAndOfAnUnknownVersion() throws {
        let box = try sealedBox(of: Data("old".utf8))
        XCTAssertNil(try EncryptionManager.shared.reEncryptIfNeeded(Data([1]) + box), "a v1 blob was re-encrypted")
        XCTAssertNil(try EncryptionManager.shared.reEncryptIfNeeded(box), "a bare blob was re-encrypted")

        let unknownVersion: UInt8 = 0x7E
        let future = Data([0x46, 0x52, unknownVersion]) + box
        XCTAssertThrowsError(try EncryptionManager.shared.reEncryptIfNeeded(future))
        XCTAssertThrowsError(try EncryptionManager.shared.decrypt(future))
        XCTAssertEqual(keychainStatus(account: "session-encryption-key-v\(unknownVersion)"), errSecItemNotFound,
                       "decrypting a blob of an unknown version created a key for it")
    }

    /// The key is stored backup-eligible (`kSecAttrAccessibleAfterFirstUnlock`,
    /// not `ThisDeviceOnly`), so it moves to a new phone with the session
    /// files it opens; a key an older build stored this-device-only is
    /// migrated to that class on first use.
    func testTheKeyIsStoredSoItMovesWithTheDeviceBackup() throws {
        try requireEncryptionKey()
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfig.keychainService,
            kSecAttrAccount as String: "session-encryption-key",
            kSecReturnAttributes as String: true
        ]
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlock as String)
    }

    /// Only the keychain refusing the key for now counts as locked; a key
    /// that is not there, or bytes that fail authentication, do not.
    func testOnlyAKeychainErrorReadsAsALockedKey() {
        XCTAssertTrue(JSONFileSeal.isKeyLocked(EncryptionManager.EncryptionError.keychainError(errSecInteractionNotAllowed)))
        XCTAssertFalse(JSONFileSeal.isKeyLocked(EncryptionManager.EncryptionError.keyNotFound))
        XCTAssertFalse(JSONFileSeal.isKeyLocked(EncryptionManager.EncryptionError.decryptionFailed))
        XCTAssertFalse(JSONFileSeal.isKeyLocked(CryptoKitError.authenticationFailure))
    }

    private func keychainStatus(account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfig.keychainService,
            kSecAttrAccount as String: account
        ]
        return SecItemCopyMatching(query as CFDictionary, nil)
    }
}
