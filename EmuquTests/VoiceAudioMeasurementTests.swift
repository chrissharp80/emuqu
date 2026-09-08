import AVFoundation
@testable import Emuqu
import XCTest

/// Tests for the barge-in audio measurement.
///
/// `rms` is the measurement barge-in detection rests on: it decides whether the
/// user is talking over the assistant. Too sensitive and the assistant cuts
/// itself off on room noise; too dull and it talks over the user.
@MainActor
final class VoiceAudioMeasurementTests: XCTestCase {
    /// A mono buffer filled by `sample(i)`.
    private func buffer(frames: Int, _ sample: (Int) -> Float) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        guard let data = buf.floatChannelData?[0] else { return nil }
        for i in 0 ..< frames { data[i] = sample(i) }
        return buf
    }

    func testSilenceMeasuresZero() throws {
        let buf = try XCTUnwrap(buffer(frames: 512) { _ in 0 })
        let rms = try XCTUnwrap(VoiceConversationController.rms(of: buf))
        XCTAssertEqual(rms, 0, accuracy: 1e-6, "silence must not read as speech")
    }

    func testConstantAmplitudeEqualsThatAmplitude() throws {
        // RMS of a constant signal is its magnitude.
        let buf = try XCTUnwrap(buffer(frames: 512) { _ in 0.5 })
        let rms = try XCTUnwrap(VoiceConversationController.rms(of: buf))
        XCTAssertEqual(rms, 0.5, accuracy: 1e-5)
    }

    func testSignIsIgnored() throws {
        // A negative half-cycle is just as loud as a positive one; if the sign
        // leaked through, speech would measure quieter than it is.
        let buf = try XCTUnwrap(buffer(frames: 512) { $0.isMultiple(of: 2) ? 0.5 : -0.5 })
        let rms = try XCTUnwrap(VoiceConversationController.rms(of: buf))
        XCTAssertEqual(rms, 0.5, accuracy: 1e-5)
    }

    func testLouderSignalMeasuresHigher() throws {
        let quiet = try XCTUnwrap(buffer(frames: 512) { _ in 0.1 })
        let loud = try XCTUnwrap(buffer(frames: 512) { _ in 0.8 })
        let q = try XCTUnwrap(VoiceConversationController.rms(of: quiet))
        let l = try XCTUnwrap(VoiceConversationController.rms(of: loud))
        XCTAssertGreaterThan(l, q)
    }

    func testSineWaveMatchesTheAnalyticRMS() throws {
        // RMS of a sine of amplitude A is A / sqrt(2). Speech is not a sine,
        // but this pins the arithmetic against a value with a closed form.
        let amplitude: Float = 0.7
        let buf = try XCTUnwrap(buffer(frames: 4_800) {
            amplitude * sinf(2 * .pi * 100 * Float($0) / 48_000)
        })
        let rms = try XCTUnwrap(VoiceConversationController.rms(of: buf))
        XCTAssertEqual(rms, amplitude / Float(2.0).squareRoot(), accuracy: 0.01)
    }

    func testBufferWithNoFramesMeasuresNothing() throws {
        // A tap can deliver a buffer that carries no frames. Averaging over
        // zero would divide by zero; nil is the honest answer.
        //
        // Allocated with capacity and then emptied: AVAudioPCMBuffer refuses
        // to allocate with a capacity of zero at all.
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buf.frameLength = 0
        XCTAssertNil(VoiceConversationController.rms(of: buf))
    }
}
