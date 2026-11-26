import Foundation

// A streaming session buffers the beats the strap's heart-rate feed delivers
// (`StrapStreamSession`, which also starts and stops it). It does not open or
// close any Bluetooth subscription — the feed is owned by the link
// (`StrapHeartRateFeed`) and runs for as long as the strap is linked — so
// starting a session never races the strap's service setup, and a session
// survives a dropped link by carrying on buffering when the link returns.

extension PolarManager {
    #if DEBUG
        /// Sets connection identity in tests so callback filtering logic can be exercised deterministically.
        func setConnectedDeviceForTesting(id: String?, type: PolarDeviceType? = nil) {
            linkState.connectedDeviceId = id
            linkState.connectedDeviceType = type
            linkState.connectionState = (id == nil) ? .disconnected : .connected
        }
    #endif
}
