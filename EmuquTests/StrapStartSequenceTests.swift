@testable import Emuqu
import XCTest

/// Tests for the order of operations when a recording starts on the strap's own
/// memory.
///
/// Clearing is destructive: it deletes a recording the user may never have
/// downloaded, which after a crash or a session started on the device itself is
/// a whole night. The Verity path guards that with a rescue first. Inverting
/// those two destroys exactly the data the rescue exists to save, and nothing
/// else would catch it.
final class StrapStartSequenceTests: XCTestCase {
    // MARK: - The invariant

    /// The one that matters: wherever a rescue exists, it must come before the
    /// clear. Written against the step's own `isDestructive` / `isRescue` flags
    /// so a newly added destructive step is covered the moment it is declared.
    func testARescueAlwaysPrecedesTheClearItProtects() {
        for device in [PolarDeviceType.veritySense, .h10] {
            let steps = StrapStartSequence.steps(for: device)
            guard let rescue = steps.firstIndex(where: \.isRescue) else { continue }
            let destructive = steps.firstIndex(where: \.isDestructive)
            XCTAssertNotNil(destructive, "\(device) rescues but never clears — the rescue is pointless")
            XCTAssertLessThan(rescue, destructive ?? .max,
                              "\(device) clears before it rescues — this deletes the night")
        }
    }

    /// Recording must be the last thing to happen: starting before the clear
    /// means the strap refuses (H10 error 106), and starting before the rescue
    /// means the rescue downloads a file that is being overwritten.
    func testRecordingBeginsLast() {
        for device in [PolarDeviceType.veritySense, .h10] {
            let steps = StrapStartSequence.steps(for: device)
            XCTAssertEqual(steps.last, .beginRecording, "\(device) must begin recording last")
        }
    }

    /// Every strap must clear before recording, or the H10 refuses to start.
    func testEveryStrapClearsBeforeRecording() {
        for device in [PolarDeviceType.veritySense, .h10] {
            let steps = StrapStartSequence.steps(for: device)
            let clear = steps.firstIndex(of: .clearExisting)
            let begin = steps.firstIndex(of: .beginRecording)
            XCTAssertNotNil(clear, "\(device) must clear before recording")
            XCTAssertLessThan(clear ?? .max, begin ?? .min)
        }
    }

    func testNoStepRunsTwice() {
        for device in [PolarDeviceType.veritySense, .h10] {
            let steps = StrapStartSequence.steps(for: device)
            XCTAssertEqual(Set(steps).count, steps.count, "\(device) repeats a step")
        }
    }

    // MARK: - The two straps, pinned

    func testVeritySenseRescuesBeforeClearing() {
        XCTAssertEqual(
            StrapStartSequence.steps(for: .veritySense),
            [.rescueExisting, .clearExisting, .beginRecording]
        )
        XCTAssertTrue(StrapStartSequence.rescuesBeforeClearing(.veritySense))
    }

    /// Was `testH10ClearsWithoutRescuingAndThatIsDeliberate`. The decision it
    /// pinned changed: arming is off the workout-start path and the download
    /// record says which file needs rescuing, so the H10 rescues too — the
    /// clear it skipped deleted a night that was never downloaded.
    func testH10RescuesBeforeClearing() {
        XCTAssertEqual(
            StrapStartSequence.steps(for: .h10),
            [.rescueExisting, .clearExisting, .beginRecording]
        )
        XCTAssertTrue(StrapStartSequence.rescuesBeforeClearing(.h10))
    }

    /// An unknown strap takes the H10 path, matching how the start decision
    /// routes it.
    func testAnUnknownStrapUsesTheH10Sequence() {
        XCTAssertEqual(StrapStartSequence.steps(for: nil), StrapStartSequence.steps(for: .h10))
    }

    /// Was `testOnlyTheH10LacksARescue`; no strap is unprotected now, and a
    /// third arriving without a rescue fails here.
    func testEveryStrapRescuesBeforeClearing() {
        let unprotected = [PolarDeviceType.veritySense, .h10]
            .filter { !StrapStartSequence.rescuesBeforeClearing($0) }
        XCTAssertEqual(unprotected, [])
    }
}
