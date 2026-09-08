@testable import Emuqu
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
}
