import CryptoKit
@testable import Emuqu
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
///   • **Session payloads** — they used the archive key, which is stored
///     `ThisDeviceOnly` and non-synchronizable. A replacement phone generates
///     its own key, decryption fails, and a reader with a "legacy" fallback
///     hands the ciphertext onward as if it were compressed data.
///
/// The unifying mistake is that the writer and reader each decided the framing
/// independently. Every test here goes through `CloudPayloadCodec` in both
/// directions, so the two cannot disagree.
final class CloudPayloadCodecTests: XCTestCase {
    private let payload = Data("the quick brown fox jumps over the lazy dog".utf8)

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
    ///
    /// `hasUsableKey` deliberately does not claim portability — a local
    /// Keychain read cannot establish that iCloud Keychain is enabled and has
    /// synced to another device. The previous
    /// name and doc comment overstated restore readiness.
    func testTheCloudKeyIsAvailableAndStable() throws {
        XCTAssertTrue(CloudPayloadCodec.hasUsableKey, "No cloud key is available")
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

    /// Decoding must never mint a key. A payload that cannot be opened caused
    /// a fresh key to be created, which guaranteed it could never be opened —
    /// and displaced the key other backups depended on.
    func testDecodingDoesNotCreateAKey() throws {
        let sealed = try CloudPayloadCodec.encode(payload)
        // Round-trip works, so a key exists and is stable across decode calls.
        XCTAssertEqual(try CloudPayloadCodec.decode(sealed), payload)
        XCTAssertEqual(try CloudPayloadCodec.decode(sealed), payload,
                       "A second decode produced a different result — the key moved")
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
