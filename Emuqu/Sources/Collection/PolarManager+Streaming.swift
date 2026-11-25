import Foundation

// A streaming session buffers the beats the strap's heart-rate feed delivers
// (`StrapStreamSession`). It does not open or close any Bluetooth subscription
// — the feed is owned by the link (`StrapHeartRateFeed`) and runs for as long
// as the strap is linked — so starting a session never races the strap's
// service setup, and a session survives a dropped link by carrying on
// buffering when the link returns.

extension PolarManager {
    // MARK: - Session

    /// Start buffering RR intervals (H10) or PPI intervals (Verity Sense).
    ///
    /// Needs a strap this app knows, not a live link: a workout started while
    /// the strap is still reconnecting begins buffering the moment it is back.
    @MainActor
    func startStreaming() throws {
        guard connectedDeviceId != nil || !knownDevices.isEmpty else {
            throw PolarError.notConnected
        }
        guard !stream.isStreaming else {
            throw PolarError.alreadyRecording
        }
        stream.resetStreamingState()
        stream.startStreamingElapsedTimer()
        if connectedDeviceType == .veritySense {
            // The Verity carries intervals on PPI, not on the HR service.
            linkEvents.feed.restart()
        }
        debugLog("[PolarManager] Session buffering started (link: \(connectionState), feed: \(feedStatus))")
    }

    /// Stop buffering and return the collected points.
    func stopStreaming() -> [RRPoint] {
        stopStreamingInternal()
        let points = stream._streamedRRPoints
        debugLog("[PolarManager] Stopped streaming with \(points.count) RR points")
        return points
    }

    func stopStreamingInternal() {
        let wasStreaming = stream.isStreaming
        stream.endStreaming()
        link.sessionEnded()
        // Don't reset reconnectExhausted here — consumers need to read it first.
        if wasStreaming, connectedDeviceType == .veritySense {
            linkEvents.feed.restart()
        }
    }

    #if DEBUG
        /// Sets connection identity in tests so callback filtering logic can be exercised deterministically.
        func setConnectedDeviceForTesting(id: String?, type: PolarDeviceType? = nil) {
            linkState.connectedDeviceId = id
            linkState.connectedDeviceType = type
            linkState.connectionState = (id == nil) ? .disconnected : .connected
        }
    #endif
}
