import Foundation

// A streaming session buffers the beats the strap's heart-rate feed delivers.
// It does not open or close any Bluetooth subscription — the feed is owned by
// the link (`StrapHeartRateFeed`) and runs for as long as the strap is linked —
// so starting a session never races the strap's service setup, and a session
// survives a dropped link by carrying on buffering when the link returns.

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
        guard !isStreaming else {
            throw PolarError.alreadyRecording
        }
        resetStreamingState()
        startStreamingElapsedTimer()
        if connectedDeviceType == .veritySense {
            // The Verity carries intervals on PPI, not on the HR service.
            StrapHeartRateFeed(manager: self).restart()
        }
        debugLog("[PolarManager] Session buffering started (link: \(connectionState), feed: \(feedStatus))")
    }

    /// Stop buffering and return the collected points.
    func stopStreaming() -> [RRPoint] {
        stopStreamingInternal()
        let points = _streamedRRPoints
        debugLog("[PolarManager] Stopped streaming with \(points.count) RR points")
        return points
    }

    func stopStreamingInternal() {
        let wasStreaming = isStreaming
        streamingTimer?.invalidate()
        streamingTimer = nil
        streamingStartTime = nil
        isStreaming = false
        link.sessionEnded()
        // Don't reset reconnectExhausted here — consumers need to read it first.
        if wasStreaming, connectedDeviceType == .veritySense {
            StrapHeartRateFeed(manager: self).restart()
        }
    }

    @MainActor
    private func resetStreamingState() {
        _streamedRRPoints = []
        _streamedRRPoints.reserveCapacity(32000) // Typical overnight ≈ 25K beats
        streamedRRCount = 0
        recentRRPoints = []
        lastUIUpdateBeatCount = 0
        streamingCumulativeMs = 0
        hasLoggedStreamingCap = false
        streamingStartTime = Date()
        streamingElapsedSeconds = 0
        streamingReconnectCount = 0
        reconnectExhausted = false
        isStreaming = true
    }

    /// Start elapsed time timer. Tolerance lets iOS coalesce with other
    /// 1Hz wakeups; the UI only renders seconds so ±0.25s is invisible.
    ///
    /// `.common` mode so the timer fires during user interaction (default
    /// `.scheduledTimer` runs in `.default` mode, which pauses while the run
    /// loop is in `.eventTracking`). Any previous timer is invalidated first,
    /// so two can never write `streamingElapsedSeconds`.
    @MainActor
    private func startStreamingElapsedTimer() {
        streamingTimer?.invalidate()
        streamingTimer = nil
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.scheduleElapsedSecondsUpdate()
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        streamingTimer = timer
    }

    nonisolated private func scheduleElapsedSecondsUpdate() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let startTime = self.streamingStartTime else { return }
            self.streamingElapsedSeconds = Int(Date().timeIntervalSince(startTime))
        }
    }

    // MARK: - Ingestion

    /// One batch from the strap's HR service.
    ///
    /// The strap's own heart rate is the live reading whether or not a session
    /// is running. RR intervals are buffered only during a session, and only
    /// from samples that carry them. Each beat records the wall-clock time the
    /// batch arrived, so a gap (BLE drop, suspension) shows up as wall clock
    /// advancing faster than the accumulated intervals.
    func ingestHeartRate(_ samples: [StrapHRSample], receivedAt: Date = Date()) {
        link.noteSample(at: receivedAt)
        if let reading = samples.last(where: { $0.hr > 0 }) {
            currentHeartRate = reading.hr
        }
        guard isStreaming else { return }
        let wallClockMs = elapsedStreamingMs(at: receivedAt)
        for sample in samples where sample.rrAvailable {
            guard appendStreamedBeats(sample.rrsMs, wallClockMs: wallClockMs, hr: sample.hr) else { break }
        }
        publishStreamingProgress(heartbeatLabel: "beats")
    }

    /// One batch from a Verity Sense PPI stream, quality-filtered before any
    /// interval is trusted (`StrapPPIFilter`). The PPI samples carry the
    /// sensor's heart rate, which is the live reading while PPI runs.
    func ingestPpi(_ readings: [StrapPPIReading], receivedAt: Date = Date()) {
        link.noteSample(at: receivedAt)
        if let last = readings.last, last.hr > 0 {
            currentHeartRate = last.hr
        }
        guard isStreaming else { return }
        let wallClockMs = elapsedStreamingMs(at: receivedAt)
        for reading in readings {
            guard let interval = StrapPPIFilter.acceptedInterval(StrapPPISample(
                ppInMs: reading.ppInMs, ppErrorEstimate: reading.ppErrorEstimate, blockerBit: reading.blockerBit
            )) else { continue }
            guard appendStreamedBeat(
                rrMs: interval, wallClockMs: wallClockMs, hr: reading.hr > 0 ? reading.hr : nil
            ) else { break }
        }
        publishStreamingProgress(heartbeatLabel: "PPI beats")
    }

    /// False once the safety cap is hit, so the caller stops feeding batches.
    ///
    /// A zero interval is skipped: the Heart Rate Measurement format can carry
    /// one, it is not a beat, and it reached the live screen as 60000 / 0. The
    /// PPI path already drops it through `StrapPPIFilter`.
    private func appendStreamedBeats(_ rrsMs: [Int], wallClockMs: Int64, hr: Int?) -> Bool {
        for rr in rrsMs where rr > 0 {
            guard appendStreamedBeat(rrMs: rr, wallClockMs: wallClockMs, hr: hr) else { return false }
        }
        return true
    }

    /// Milliseconds since the session started, or 0 before it has.
    private func elapsedStreamingMs(at date: Date) -> Int64 {
        guard let startTime = streamingStartTime else { return 0 }
        return MillisecondOffset.between(date, and: startTime, fallback: 0)
    }

    /// Append one beat, advancing the cumulative clock. Returns false once the
    /// safety cap is hit.
    private func appendStreamedBeat(rrMs: Int, wallClockMs: Int64, hr: Int?) -> Bool {
        guard _streamedRRPoints.count < Self.maxStreamingBufferSize else {
            // Once per session: the count stays at the cap, so without the
            // flag every later batch would log it again.
            if !hasLoggedStreamingCap {
                hasLoggedStreamingCap = true
                debugLog("[PolarManager] ⚠️ Streaming buffer reached safety cap (\(Self.maxStreamingBufferSize) points)")
            }
            return false
        }
        _streamedRRPoints.append(RRPoint(
            t_ms: streamingCumulativeMs, rr_ms: rrMs, wallClockMs: wallClockMs, hr: hr
        ))
        streamingCumulativeMs += Int64(rrMs)
        return true
    }

    /// Publish the cheap beat count every batch, refresh the expensive
    /// `recentRRPoints` window only every N beats, and log a heartbeat at most
    /// every 30 minutes so a quiet night doesn't flood the log.
    private func publishStreamingProgress(heartbeatLabel: String) {
        streamedRRCount = _streamedRRPoints.count
        if _streamedRRPoints.count - lastUIUpdateBeatCount >= Self.uiUpdateBeatInterval {
            recentRRPoints = Array(_streamedRRPoints.suffix(Self.recentRRWindowSize))
            lastUIUpdateBeatCount = _streamedRRPoints.count
        }
        let now = Date()
        guard now.timeIntervalSince(lastSignificantLogTime) >= 1800 else { return }
        debugLog("[PolarManager] ✓ Heartbeat: \(_streamedRRPoints.count) \(heartbeatLabel) collected")
        lastSignificantLogTime = now
    }

    #if DEBUG
        /// Exposes cumulative streamed time for unit tests without widening production API.
        var streamingCumulativeMsForTesting: Int64 { streamingCumulativeMs }

        /// Sets connection identity in tests so callback filtering logic can be exercised deterministically.
        func setConnectedDeviceForTesting(id: String?, type: PolarDeviceType? = nil) {
            connectedDeviceId = id
            connectedDeviceType = type
            connectionState = (id == nil) ? .disconnected : .connected
        }

        /// Feed a batch as though it arrived `elapsedMs` after the session started.
        func ingestHeartRateForTesting(_ samples: [StrapHRSample], elapsedMs: Int64) {
            let start = streamingStartTime ?? Date()
            ingestHeartRate(samples, receivedAt: start.addingTimeInterval(TimeInterval(elapsedMs) / 1000))
        }

        /// Initializes session buffering for deterministic tests without a timer.
        func prepareStreamingStateForTesting(
            startTime: Date = Date(),
            cumulativeMs: Int64 = 0,
            existingPoints: [RRPoint] = []
        ) {
            isStreaming = true
            streamingStartTime = startTime
            streamingCumulativeMs = cumulativeMs
            _streamedRRPoints = existingPoints
            streamedRRCount = _streamedRRPoints.count
            recentRRPoints = Array(_streamedRRPoints.suffix(Self.recentRRWindowSize))
            lastUIUpdateBeatCount = _streamedRRPoints.count
        }
    #endif
}
