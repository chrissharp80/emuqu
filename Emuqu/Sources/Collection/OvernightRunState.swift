import Foundation
import Observation

/// The state of the night being recorded: whether the strap's own memory
/// backs it up, whether that backup has started, whether the night has begun
/// to end, and the arming loop that starts the backup.
///
/// Owned by `RRCollector` (`overnightRun`) and written by the overnight
/// coordinators. The Record tab reads the backup choice from it.
@MainActor
@Observable
final class OvernightRunState {
    /// Whether this night's processing fetches the strap's own recording;
    /// set by the Record screen's Skip.
    var deviceFetchPolicy: RRCollector.DeviceFetchPolicy = .automatic

    /// Whether overnight streaming also records to the strap's internal
    /// memory as a backup. Off means streaming only: no internal recording
    /// and no morning download.
    var usesDeviceBackup: Bool = true

    /// True once the strap's internal recording has actually started for
    /// this night (the `.both` capture mode on an H10). While this holds, the
    /// strap is capturing the whole night to its own flash memory
    /// independently of the BLE link, so a mid-night reconnect exhaustion
    /// (a transient iOS BLE reset, a trip out of range) must not pause and
    /// fetch: fetching stops the recording and ends the night early. It gates
    /// the `reconnectExhausted` auto-pause in `RRCollector+Bindings`, so
    /// those nights stay alive and are recovered from the strap at wake.
    /// Reset at the start of every session and once the ending's strap gate
    /// has read it (`fetchNightFromStrap`), which downloads only a night that
    /// armed the strap.
    var deviceBackupActive: Bool = false

    /// Set first thing when a night begins to end (the morning stop or a
    /// pause), before streaming stops or the link changes, and cleared when
    /// a night or a resumed segment starts. The arming loop and
    /// `startFreshRecording` refuse to arm while it is set.
    var isEnding = false

    /// The night's arming loop, so the end of the night can cancel it and
    /// wait for it before the strap is stopped and downloaded.
    @ObservationIgnored var armingTask: Task<Void, Never>?

    /// How long the arming loop waits, on a link that does not change,
    /// before trying again after a refusal that can clear up.
    @ObservationIgnored var armingRetryInterval: TimeInterval = StrapRecordingPolicy.armingRetryIntervalSeconds
}
