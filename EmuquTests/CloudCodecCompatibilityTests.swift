@testable import Emuqu
import XCTest

/// Every writer format that has ever produced a cloud record must still read.
///
/// ## Why this suite exists
///
/// Changing the framing with tests that only prove the CURRENT writer
/// round-trips is how a codec breaks its own history. A round-trip test cannot fail
/// when you break an older format, because it never encounters one.
///
/// So the fixtures here come from the actual writers, not from a hand-rolled
/// imitation of them:
///
///   • **plain** — records written before any encryption. Compressed only.
///   • **FR** — `EncryptionManager.encrypt`, the writer at commit c4670af.
///     Frames as `[0x46 0x52]` + version + AES-GCM. Still present in the
///     codebase for the local archive, so a real payload is buildable here.
///   • **EMQC** — `CloudPayloadCodec.encode`, current.
///
/// If `decode` recognises only `EMQC` and returns
/// everything else unchanged as "legacy compressed", an `FR` payload is
/// handed to `DataCompression.decompress` as if AES-GCM ciphertext were a zlib
/// stream, and every record written by the immediately preceding build becomes
/// unreadable — on the same device, with the same key.
///
/// Adding a fourth format later means adding its fixture here. That is the
/// point: this suite fails when a format is dropped, which is the failure mode
/// round-trip tests are blind to.
final class CloudCodecCompatibilityTests: XCTestCase {
    private let payload = Data("session payload: rr=[850,862,858] rmssd=41.2".utf8)

    // MARK: - Fixtures from the real writers

    /// Pre-encryption: the bytes were compressed and uploaded as-is.
    private var plainFixture: Data {
        Data("zlib-compressed-bytes-from-an-old-build".utf8)
    }

    /// The writer at c4670af — `EncryptionManager`, `FR`-framed.
    private func frFixture() throws -> Data {
        try EncryptionManager.shared.encrypt(payload)
    }

    /// The current writer.
    private func emqcFixture() throws -> Data {
        try CloudPayloadCodec.encode(payload)
    }

    // MARK: - Each format decodes

    func testCurrentFormatDecodes() throws {
        XCTAssertEqual(try CloudPayloadCodec.decode(try emqcFixture()), payload)
    }

    /// The previous encrypted format. Failing here means records written by the
    /// previous build cannot be restored.
    func testPreviousEncryptedFormatDecodes() throws {
        let fixture = try frFixture()
        XCTAssertEqual(fixture.prefix(2), Data([0x46, 0x52]), "Fixture is not FR-framed")
        XCTAssertEqual(try CloudPayloadCodec.decode(fixture), payload,
                       "An FR record written by the previous build did not decode")
    }

    func testPreEncryptionFormatPassesThrough() throws {
        XCTAssertEqual(try CloudPayloadCodec.decode(plainFixture), plainFixture)
    }

    // MARK: - The formats stay distinguishable

    /// Each writer's output must be recognised as ITS OWN format, never
    /// mistaken for another. `FR` read as plain is exactly the F3 defect.
    func testEachFormatIsIdentifiedByItsOwnFraming() throws {
        let emqc = try emqcFixture()
        let fr = try frFixture()
        XCTAssertEqual(emqc.prefix(4), CloudPayloadCodec.magic)
        XCTAssertNotEqual(fr.prefix(4), CloudPayloadCodec.magic,
                          "FR must not be mistaken for the current format")
        XCTAssertNotEqual(plainFixture.prefix(2), Data([0x46, 0x52]),
                          "Plain fixture must not collide with FR framing")
    }

    /// A corrupt or wrong-key payload must surface as an error, not be quietly
    /// reclassified as legacy and passed to the decompressor.
    func testATamperedCurrentPayloadIsAnErrorNotALegacyGuess() throws {
        var encoded = try emqcFixture()
        encoded[encoded.index(before: encoded.endIndex)] ^= 0xFF
        XCTAssertThrowsError(try CloudPayloadCodec.decode(encoded))
    }

    func testATamperedPreviousPayloadIsAnErrorNotALegacyGuess() throws {
        var fixture = try frFixture()
        fixture[fixture.index(before: fixture.endIndex)] ^= 0xFF
        XCTAssertThrowsError(try CloudPayloadCodec.decode(fixture),
                             "A damaged FR payload must not be treated as compressed data")
    }
}
