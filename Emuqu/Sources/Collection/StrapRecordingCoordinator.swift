import Foundation
#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

/// Everything the app does with a recording held in the strap's own memory:
/// starting and stopping one, asking whether one is running, listing what is
/// stored, downloading it, and the retry/reconnect dance the SDK needs for a
/// large transfer.
///
/// ## Why this is not on `PolarManager`
///
/// Kept off it so `PolarManager` stays the BLE
/// link itself — discovery, connection, the observers, and the live stream.
///
/// Recording-to-device is a different job from streaming-to-phone. It runs on a
/// different SDK feature set, it fails in different ways (a file that will not
/// finalize, a transfer that times out at 20 MB), and it is the path that holds
/// a user's night hostage until the download succeeds.
///
/// All three files moved together because they call each other constantly —
/// `+Recording` drives the flow, `+QuickFetch` owns the retry/reconnect, and
/// `+VeritySense` handles the optical variant. Split one at a time, every one of
/// those crossings would have needed a forwarder.
///
/// Holds its owner strongly and is built on demand by the manager — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct StrapRecordingCoordinator {
    let manager: PolarManager

}
