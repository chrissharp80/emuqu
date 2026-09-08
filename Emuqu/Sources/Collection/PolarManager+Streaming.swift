import CoreBluetooth
import Foundation

#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

extension PolarManager {
    // MARK: - Streaming Mode (Real-time RR/PPI Collection)

    /// Start streaming RR intervals in real-time
    /// Note: Requires app to stay in foreground. Must be called from main thread.
    @MainActor
    func startStreaming() throws {
        #if canImport(PolarBleSdk)
            guard let api, let deviceId = connectedDeviceId else {
                throw PolarError.notConnected
            }
            guard connectionState == .connected else {
                throw PolarError.notConnected
            }
            guard !isStreaming else {
                throw PolarError.alreadyRecording
            }
            cancelConnectTimeHRMonitor(on: self)
            resetStreamingState()
            startStreamingElapsedTimer()
            subscribeToStreamWhenReady(api: StrapAPI(sdk: api), deviceId: deviceId)
        #else
            throw PolarError.sdkNotAvailable
        #endif
    }

    /// Reset streaming state (safe - we're on MainActor).
    @MainActor
    private func resetStreamingState() {
        _streamedRRPoints = []
        _streamedRRPoints.reserveCapacity(32000) // Typical overnight ≈ 25K beats
        streamedRRCount = 0
        recentRRPoints = []
        lastUIUpdateBeatCount = 0
        streamingCumulativeMs = 0
        streamingStartTime = Date()
        streamingElapsedSeconds = 0
        streamingReconnectAttempts = 0
        streamingReconnectCount = 0
        isReconnectingStream = false
        reconnectExhausted = false
        isStreaming = true
    }

    /// Start elapsed time timer. Tolerance lets iOS coalesce with other
    /// 1Hz wakeups; the UI only renders seconds so ±0.25s is invisible.
    ///
    /// `.common` mode so the timer fires during user
    /// interaction (default `.scheduledTimer` runs in `.default` mode
    /// which pauses while the run loop is in `.eventTracking`).
    ///
    /// `[weak self]` on BOTH closures + invalidate
    /// any pre-existing timer before assigning a new one. The inner
    /// `DispatchQueue.main.async` must not capture `self`
    /// strongly via `guard let self`. With inner `[weak self]`,
    /// a late tick after `stopStreamingInternal()` invalidates
    /// the timer is a no-op rather than a strong-cycle write.
    ///
    /// The pre-existing-timer invalidation closes the second
    /// hazard: if a caller invoked `startStreaming` while one
    /// was already running (BLE drop + reconnect race), the
    /// previous timer reference was being dropped without
    /// `.invalidate()`, leaving it scheduled in the RunLoop
    /// forever, writing to `streamingElapsedSeconds` from
    /// multiple sources.
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

    /// Subscribe to the correct stream based on device type.
    ///
    /// PREVENT the storm at the source. Starting the H10 HR
    /// stream before the `feature_hr` observer has fired throws
    /// `notificationNotEnabled` (PolarErrors error 8), which would kick
    /// off a destructive disconnect/reconnect loop (field log: up to
    /// attempt 8/60 at overnight start, ~2 min of churn + record-screen
    /// flicker). So if the HR feature isn't ready yet, DEFER the
    /// subscription until it is (bounded) instead of subscribing
    /// prematurely. Verity (PPI) or an H10 that's already ready subscribes
    /// inline. Session state + timer are already set by the caller, so a
    /// ~1–2 s deferral only delays the first RR packet, not the recording.
    @MainActor
    private func subscribeToStreamWhenReady(api: StrapAPI, deviceId: String) {
        guard connectedDeviceType != .veritySense, !isHrStreamingReady else {
            streamingTask = subscribeToStream(api: api, deviceId: deviceId)
            return
        }
        debugLog("[PolarManager] HR feature not ready at stream start — deferring subscription until ready (prevents notificationNotEnabled → reconnect storm)")
        Task { [weak self, api, deviceId] in
            guard let self else { return }
            _ = await self.waitForHrStreamingFeature(timeout: 10.0)
            // Subscribe once ready — or after the bounded wait even if it
            // timed out (rare). Never while a reconnect is in flight: that
            // path owns `streamingTask` and this would leave TWO live streams.
            guard self.isStreaming, self.connectionState == .connected,
                  !self.isReconnectingStream, self.streamingTask == nil else { return }
            self.streamingTask = self.subscribeToStream(api: api, deviceId: deviceId)
            debugLog("[PolarManager] Deferred stream subscription started")
        }
    }

    /// Stop streaming and return collected RR points
    func stopStreaming() -> [RRPoint] {
        #if canImport(PolarBleSdk)
            stopStreamingInternal()
            let points = _streamedRRPoints
            debugLog("[PolarManager] Stopped streaming with \(points.count) RR points")
            return points
        #else
            return []
        #endif
    }

    /// Send a keep-alive ping to prevent iOS from putting BLE connection into low-power state
    /// Call this periodically during long streaming sessions (every 30-60 seconds)
    ///
    /// H10: do NOT send a keep-alive ping during streaming.
    /// The active HR stream (RR data every ~1s) already keeps the BLE
    /// link alive, so this ping is redundant for its stated purpose — and
    /// it would use `requestRecordingStatus`, a RECORDING-CONTROL query, fired
    /// every 30s at the H10's actively-writing 8-hour recording subsystem.
    /// A field log showed it timing out (waitTimeout) 30× across
    /// the night, and morning `stopH10RecordingQuick` leads with the SAME
    /// `requestRecordingStatus`, which then hung on that stressed subsystem
    /// → the user force-quit. Stop poking it. Battery liveness still runs
    /// via `checkBatteryStaleness`; a real stream drop is caught by the
    /// stream's own onError → attemptStreamingReconnect. Verity keeps its
    /// ping (getOfflineRecordingStatus, and Verity doesn't record while
    /// streaming, so no subsystem conflict).
    func sendKeepAlivePing() {
        #if canImport(PolarBleSdk)
            guard let api, let deviceId = connectedDeviceId else { return }
            guard connectionState == .connected else { return }
            guard connectedDeviceType == .veritySense else { return }
            Task { [weak self] in
                do {
                    _ = try await self?.pingOfflineRecordingStatus(api: StrapAPI(sdk: api), deviceId: deviceId)
                } catch {
                    self?.recordKeepAlivePingFailure(error)
                }
            }
        #endif
    }

    #if canImport(PolarBleSdk)
        /// Verity Sense: offline recording status doubles as a lightweight ping.
        private func pingOfflineRecordingStatus(api: StrapAPI, deviceId: String) async throws -> [PolarDeviceDataType: Bool] {
            do {
                let status = try await api.sdk.getOfflineRecordingStatus(deviceId)
                notePingSucceeded()
                return status
            } catch {
                debugLogExternal("Keep-alive ping didn't return — \(error) (transient BLE).", cause: .bluetooth)
                throw error
            }
        }

        /// A ping that answered clears the degraded-connection state. Hopped to
        /// main because the SDK's success callback isn't guaranteed to be there.
        nonisolated private func notePingSucceeded() {
            DispatchQueue.main.async {
                self.consecutivePingFailures = 0
                self.connectionHealthWarning = false
            }
        }

        /// Track consecutive failures; warn once at the threshold and force a
        /// reconnect if they keep piling up.
        @MainActor
        private func recordKeepAlivePingFailure(_ error: Error) {
            consecutivePingFailures += 1
            debugLog("[PolarManager] Keep-alive ping error (\(consecutivePingFailures)/\(maxPingFailuresBeforeWarning)): \(error)")
            if consecutivePingFailures == maxPingFailuresBeforeWarning {
                // Log the warning exactly once when the threshold is first
                // crossed — not on every subsequent failure. Repeated warnings
                // flood the error catalog during long overnight sessions.
                debugLog("[PolarManager] Keep-alive pings failing repeatedly - connection may be degraded", level: .warning)
                connectionHealthWarning = true
            }
            // Proactively trigger reconnect after sustained ping failures
            // to recover the stream before it silently dies.
            guard consecutivePingFailures >= maxPingFailuresBeforeWarning + 2,
                  isStreaming, !isReconnectingStream
            else { return }
            debugLog("[PolarManager] Triggering proactive reconnect after \(consecutivePingFailures) consecutive ping failures")
            consecutivePingFailures = 0
            Task { @MainActor in
                await self.attemptStreamingReconnect(afterError: error)
            }
        }
    #endif

    #if canImport(PolarBleSdk)
        func stopStreamingInternal() {
            streamingTask?.cancel()
            streamingTask = nil
            streamingTimer?.invalidate()
            streamingTimer = nil
            streamingStartTime = nil
            isStreaming = false
            // Reset reconnection state when explicitly stopped
            streamingReconnectAttempts = 0
            isReconnectingStream = false
            // Reset ping failure tracking
            consecutivePingFailures = 0
            connectionHealthWarning = false
            // Don't reset reconnectExhausted here — consumers need to read it first
        }

        /// Attempt to reconnect and resume streaming after an error
        /// Preserves already-collected RR points and continues from where we left off
        @MainActor
        func attemptStreamingReconnect(afterError error: Error) async {
            guard !isReconnectingStream else {
                debugLog("[PolarManager] Already attempting to reconnect stream, ignoring")
                return
            }
            streamingReconnectAttempts += 1
            if PolarReconnectPolicy.shouldGiveUp(afterAttempt: streamingReconnectAttempts) {
                handleReconnectExhausted()
                return
            }
            debugLog("[PolarManager] Streaming reconnect attempt \(streamingReconnectAttempts)/\(PolarReconnectPolicy.maxAttempts) - Error: \(error.localizedDescription)")
            debugLog("[PolarManager] Preserved \(_streamedRRPoints.count) RR points before reconnection")
            isReconnectingStream = true
            streamingTask?.cancel()
            streamingTask = nil
            await waitForReconnectBackoff()
            guard let target = reconnectTargetAfterBackoff(afterError: error) else { return }
            if await resumeOverExistingLinkIfPossible(api: target.api, deviceId: target.deviceId) { return }
            await performFullReconnectCycle(api: target.api, deviceId: target.deviceId, afterError: error)
        }

        /// Nil when streaming was stopped during the backoff, or the device went
        /// away entirely — both end the reconnect rather than continuing it.
        @MainActor
        private func reconnectTargetAfterBackoff(afterError error: Error) -> (api: StrapAPI, deviceId: String)? {
            guard isStreaming else {
                debugLog("[PolarManager] Streaming was stopped during reconnect wait")
                isReconnectingStream = false
                return nil
            }
            guard let api, let deviceId = connectedDeviceId else {
                debugLog("[PolarManager] Cannot reconnect - no API or device ID")
                lastError = error
                stopStreamingInternal()
                isReconnectingStream = false
                return nil
            }
            return (StrapAPI(sdk: api), deviceId)
        }

        /// Two ways the existing link is still good enough to just re-subscribe.
        ///
        /// First: the SDK may have auto-reconnected during the backoff.
        ///
        /// Second: still CONNECTED, only the HR streaming feature isn't
        /// ready yet (the SDK throws `notificationNotEnabled` / PolarErrors
        /// error 8 when the stream is started before `feature_hr` enables).
        /// This is NOT a dropped link, and a destructive disconnect+reconnect
        /// here RESETS the strap's feature enumeration and PROLONGS the
        /// problem: a field log showed 8 disconnect/reconnect cycles
        /// over ~2 min at bedtime before streaming settled — flickering the
        /// record screen the whole time and capturing 0 beats. Instead, stay
        /// connected and wait briefly for the feature to enable, then
        /// re-subscribe over the EXISTING link (no disconnect → no flicker).
        /// Bounded to the early attempts; if the feature genuinely never
        /// enables, the caller falls through to a real reconnect (something
        /// else is wrong).
        @MainActor
        private func resumeOverExistingLinkIfPossible(api: StrapAPI, deviceId: String) async -> Bool {
            if connectionState == .connected, isHrStreamingReady {
                resumeStreamAfterReconnect(api: api, deviceId: deviceId, method: "auto-reconnect")
                return true
            }
            guard connectionState == .connected, streamingReconnectAttempts <= 5,
                  await waitForHrStreamingFeature(timeout: 8.0),
                  connectionState == .connected, isStreaming
            else { return false }
            resumeStreamAfterReconnect(api: api, deviceId: deviceId, method: "feature-ready wait")
            return true
        }

        /// Explicit disconnect + reconnect cycle; a failure recurses into another
        /// attempt (bounded by `maxReconnectAttempts`).
        @MainActor
        private func performFullReconnectCycle(api: StrapAPI, deviceId: String, afterError error: Error) async {
            await performExplicitDisconnect(api: api, deviceId: deviceId)
            guard await connectAndWaitForReady(api: api, deviceId: deviceId) else {
                debugLog("[PolarManager] Failed to reconnect within timeout")
                isReconnectingStream = false
                await attemptStreamingReconnect(afterError: error)
                return
            }
            debugLog("[PolarManager] Resuming streaming with \(_streamedRRPoints.count) existing points")
            resumeStreamAfterReconnect(api: api, deviceId: deviceId, method: "explicit reconnect")
        }

        // MARK: - attemptStreamingReconnect Helpers

        /// Handle exhausted reconnect attempts: stop streaming and mark as exhausted.
        private func handleReconnectExhausted() {
            debugLog("[PolarManager] ❌ Reconnect attempts exhausted (\(streamingReconnectAttempts)/\(PolarReconnectPolicy.maxAttempts)) — giving up")
            debugLog("[PolarManager] Preserved \(_streamedRRPoints.count) RR points for recovery")
            stopStreamingInternal()
            // Do NOT clear `isRecordingOnDevice` here. BLE being
            // unreachable RIGHT NOW (strap out of range mid-night — the
            // toilet-trip drop) does not stop the H10's INTERNAL recording,
            // which keeps capturing the full night. Clearing the flag
            // sabotages the morning: it gates out the device download
            // (`fetchExerciseDataQuick`) and hides the manual RecoverableDataCard,
            // so the user loses the full-night recording the strap still holds.
            // The morning quick-fetch is connection-gated and bounded (no
            // futile 300 s fetch), and a reconnect re-syncs the flag from the
            // device via `checkRecordingStatus`.
            reconnectExhausted = true
        }

        /// Wait with graduated backoff. The schedule lives in
        /// `PolarReconnectPolicy` so it can be tested on its own.
        private func waitForReconnectBackoff() async {
            let backoffSeconds = PolarReconnectPolicy.backoffSeconds(
                forAttempt: streamingReconnectAttempts
            )
            debugLog("[PolarManager] Waiting \(backoffSeconds)s before reconnect...")
            await sleepIgnoringCancellation(
                UInt64(backoffSeconds * 1_000_000_000),
                context: "streaming reconnect backoff"
            )
        }

        /// Wait (bounded) for the HR streaming feature to become ready while
        /// staying CONNECTED. Returns true as soon as `isHrStreamingReady` flips
        /// (set by the `feature_hr` ready observer), false on timeout or if the
        /// link drops. Poll-based at 0.25s — plenty for a one-shot bedtime wait,
        /// and it avoids the destructive disconnect that resets feature
        /// enumeration (see the call site in `attemptStreamingReconnect`).
        private func waitForHrStreamingFeature(timeout: TimeInterval) async -> Bool {
            var waited = 0.0
            let step = 0.25
            while waited < timeout {
                if isHrStreamingReady { return true }
                if connectionState != .connected { return false }
                await sleepIgnoringCancellation(
                    UInt64(step * 1_000_000_000),
                    context: "wait for HR streaming feature"
                )
                waited += step
            }
            return isHrStreamingReady
        }

        /// Re-subscribe to stream and reset reconnect state after a successful reconnect.
        private func resumeStreamAfterReconnect(api: StrapAPI, deviceId: String, method: String) {
            streamingTask = subscribeToStream(api: api, deviceId: deviceId)
            debugLog("[PolarManager] ✅ Resumed streaming via \(method) with \(_streamedRRPoints.count) points preserved")
            isReconnectingStream = false
            streamingReconnectAttempts = 0
            streamingReconnectCount += 1
            debugLog("[PolarManager] Total reconnections this session: \(streamingReconnectCount)")
        }

        /// Disconnect from device if not already connecting, then wait for settle.
        private func performExplicitDisconnect(api: StrapAPI, deviceId: String) async {
            if connectionState != .connecting {
                debugLog("[PolarManager] Disconnecting for streaming reconnect...")
                do {
                    try api.sdk.disconnectFromDevice(deviceId)
                } catch {
                    debugLog("[PolarManager] Disconnect error during reconnect: \(error)")
                }
                await sleepIgnoringCancellation(1_000_000_000, context: "streaming reconnect disconnect settle delay")
            } else {
                debugLog("[PolarManager] Device already connecting — skipping disconnect")
            }
        }

        /// Connect to device and wait for BLE connection + HR streaming feature readiness.
        /// Returns true if ready, false if timed out.
        private func connectAndWaitForReady(api: StrapAPI, deviceId: String) async -> Bool {
            debugLog("[PolarManager] Reconnecting for streaming...")
            do {
                try api.sdk.connectToDevice(deviceId)
            } catch {
                debugLog("[PolarManager] Reconnect error: \(error)")
                lastError = error
                stopStreamingInternal()
                isReconnectingStream = false
                return false
            }
            await awaitBleConnection()
            if connectionState == .connected {
                await awaitHrFeatureReady()
            }
            return connectionState == .connected && isHrStreamingReady
        }

        /// Wait for connection (up to 15s).
        private func awaitBleConnection() async {
            for i in 0 ..< 15 {
                if connectionState == .connected {
                    debugLog("[PolarManager] Connected after \(i)s, waiting for feature readiness...")
                    return
                }
                await sleepIgnoringCancellation(1_000_000_000, context: "streaming reconnect connection wait")
            }
        }

        /// Wait for HR streaming feature ready (up to 10s, check every 500ms).
        private func awaitHrFeatureReady() async {
            for i in 0 ..< 20 {
                if isHrStreamingReady {
                    debugLog("[PolarManager] HR streaming ready after \(i * 500)ms")
                    return
                }
                await sleepIgnoringCancellation(500_000_000, context: "streaming reconnect feature-ready wait")
            }
        }

        /// Ingest one batch of H10 HR samples into the streaming buffer.
        ///
        /// The wall-clock time this batch was received is captured so gaps can be
        /// detected: if wall-clock advances faster than cumulative RR, data was
        /// dropped (BLE hiccups, app backgrounding issues, etc.).
        ///
        /// Live HR is updated from the H10's HR samples that
        /// arrive alongside RR intervals on this stream, mirroring the
        /// Verity-Sense path. Without this, the dedicated `startHrStreaming`
        /// subscription in `startHRMonitoring` is the only source of
        /// `currentHeartRate`, and `hrv_debug_log_1778677521.txt` (line 68)
        /// shows that subscription erroring at strap-connect with
        /// `notificationNotEnabled` — leaving `currentHeartRate` nil for the
        /// entire session even though RR data was flowing fine. The
        /// user-visible symptom: HR shows "—" until the workout's tick loop
        /// derives HR from the median of recent RR intervals (which can be
        /// 20+ s after Start). With this, the observable HR updates the instant
        /// the first RR batch arrives — i.e., the moment the strap was already
        /// ready to talk.
        func handleStreamedHRData(_ hrData: PolarHrData) {
            let wallClockNow = elapsedStreamingMs()
            var lastSensorHR = 0
            for sample in hrData where sample.rrAvailable {
                let sensorHR = Int(sample.hr)
                if sensorHR > 0 { lastSensorHR = sensorHR }
                guard appendStreamedBeats(sample.rrsMs, wallClockMs: wallClockNow, hr: sensorHR) else { break }
            }
            if lastSensorHR > 0 {
                currentHeartRate = lastSensorHR
            }
            publishStreamingProgress(heartbeatLabel: "beats")
        }

        /// False once the safety cap is hit, so the caller stops feeding batches.
        private func appendStreamedBeats(_ rrsMs: [Int], wallClockMs: Int64, hr: Int?) -> Bool {
            for rr in rrsMs {
                guard appendStreamedBeat(rrMs: rr, wallClockMs: wallClockMs, hr: hr) else { return false }
            }
            return true
        }

        /// Milliseconds since the stream started, or 0 before it has.
        private func elapsedStreamingMs() -> Int64 {
            guard let startTime = streamingStartTime else { return 0 }
            return Int64(Date().timeIntervalSince(startTime) * 1000.0)
        }

        /// Append one beat, advancing the cumulative clock. Returns false once the
        /// safety cap is hit so the caller stops feeding the batch.
        private func appendStreamedBeat(rrMs: Int, wallClockMs: Int64, hr: Int?) -> Bool {
            guard _streamedRRPoints.count < Self.maxStreamingBufferSize else {
                if _streamedRRPoints.count == Self.maxStreamingBufferSize {
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
        /// `recentRRPoints` window only every N beats, and log a heartbeat at
        /// most every 30 minutes so a quiet night doesn't flood the log.
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

        /// Handle streamed PPI data from Verity Sense (optical PPG)
        /// Applies quality filtering before converting to RRPoints
        func handleStreamedPpiData(_ ppiData: PolarPpiData) {
            let wallClockNow = elapsedStreamingMs()
            for sample in ppiData.samples {
                guard let ppInterval = Self.acceptedPpiInterval(
                    ppInMs: sample.ppInMs, errorEstimate: sample.ppErrorEstimate, blockerBit: sample.blockerBit
                ) else { continue }
                guard appendStreamedBeat(
                    rrMs: ppInterval, wallClockMs: wallClockNow, hr: sample.hr > 0 ? Int(sample.hr) : nil
                ) else { return }
            }
            // Update live HR from PPI samples. The HR monitor subscription dies when
            // the Verity Sense switches to PPI mode, so this is the only HR source.
            if let lastSample = ppiData.samples.last, lastSample.hr > 0 {
                currentHeartRate = Int(lastSample.hr)
            }
            publishStreamingProgress(heartbeatLabel: "PPI beats")
        }

        /// Three quality gates before an optical interval is trusted:
        ///   1. blocker bit set → the measurement is unreliable
        ///   2. error estimate above the cap
        ///   3. outside the physiological 300–2000 ms range (30–200 bpm)
        private static func acceptedPpiInterval(ppInMs: UInt16, errorEstimate: UInt16, blockerBit: Int) -> Int? {
            StrapPPIFilter.acceptedInterval(StrapPPISample(
                ppInMs: Int(ppInMs),
                ppErrorEstimate: Int(errorEstimate),
                blockerBit: blockerBit
            ))
        }

        /// Creates the correct streaming subscription based on connected device type.
        /// H10 uses HR streaming (ECG-derived RR), Verity Sense uses PPI streaming (optical PPG).
        /// Shared onError and onCompleted handlers avoid duplication between startStreaming and reconnect.
        /// Starts the correct stream for the connected device and returns the
        /// task that owns it.
        ///
        /// H10 uses HR streaming (ECG-derived RR); Verity Sense uses PPI
        /// (optical PPG). Error and completion handling is shared so the two
        /// paths cannot drift.
        ///
        /// Returns a `Task` rather than an Rx `Disposable` (Polar SDK 8.2.0).
        /// The two branches are iterated separately rather than through a
        /// common existential, because the element types differ and each
        /// sample handler is specific to its type.
        func subscribeToStream(api: StrapAPI, deviceId: String) -> Task<Void, Never> {
            let isVerity = connectedDeviceType == .veritySense
            let streamName = isVerity ? "PPI" : "HR"
            let task = Task { [weak self] in
                await Self.drainStream(api: api, deviceId: deviceId, isVerity: isVerity,
                                       streamName: streamName, manager: self)
            }
            debugLog("[PolarManager] Started \(streamName) streaming")
            return task
        }

        /// Iterate the device's sample stream until it ends, fails, or the task
        /// is cancelled.
        ///
        /// The two branches are iterated separately rather than through a
        /// common existential: the element types differ and each sample handler
        /// is specific to its type.
        private static func drainStream(
            api: StrapAPI, deviceId: String, isVerity: Bool,
            streamName: String, manager: PolarManager?
        ) async {
            do {
                try await consume(api: api, deviceId: deviceId, isVerity: isVerity, manager: manager)
                // The stream ended on its own — the strap stopped sending.
                guard !Task.isCancelled else { return }
                await MainActor.run { manager?.handleStreamCompleted(streamName: streamName) }
            } catch {
                // A cancelled task is a deliberate stop, not a stream fault.
                guard !Task.isCancelled else { return }
                await MainActor.run { manager?.handleStreamError(error, streamName: streamName) }
            }
        }

        /// Forward every sample to its handler until the stream ends.
        private static func consume(
            api: StrapAPI, deviceId: String, isVerity: Bool, manager: PolarManager?
        ) async throws {
            if isVerity {
                try await consumePpi(api: api, deviceId: deviceId, manager: manager)
            } else {
                try await consumeHr(api: api, deviceId: deviceId, manager: manager)
            }
        }

        private static func consumePpi(api: StrapAPI, deviceId: String, manager: PolarManager?) async throws {
            try await forward(api.sdk.startPpiStreaming(deviceId)) { manager?.handleStreamedPpiData($0) }
        }

        private static func consumeHr(api: StrapAPI, deviceId: String, manager: PolarManager?) async throws {
            try await forward(api.sdk.startHrStreaming(deviceId)) { manager?.handleStreamedHRData($0) }
        }

        /// Forward every element of `stream` to `handle` on the main actor,
        /// stopping early if the task is cancelled.
        ///
        /// Takes the sequence rather than the API on purpose. This is the half
        /// of the Rx→async migration that is mine rather than
        /// the SDK's — cancellation, ordering, error propagation, and stopping
        /// without running the completion path. Written against `AsyncSequence`
        /// it is testable with a synthetic stream, so none of that behaviour
        /// depends on having a strap in hand; what a strap proves is that
        /// Polar's radio code works, which is theirs to get right.
        static func forward<S: AsyncSequence>(
            _ stream: S,
            to handle: @escaping @MainActor (S.Element) -> Void
        ) async throws where S.Element: Sendable {
            for try await sample in stream {
                guard !Task.isCancelled else { return }
                await MainActor.run { handle(sample) }
            }
        }

        /// A GATT disconnection is called out explicitly because the usual cause
        /// is another app (SnoreLab, Polar Beat, …) competing for the strap.
        private func handleStreamError(_ error: Error, streamName: String) {
            debugLog("[PolarManager] \(streamName) streaming error: \(error)")
            debugLog("[PolarManager] Error type: \(type(of: error))")
            let errorDesc = error.localizedDescription.lowercased()
            if errorDesc.contains("disconnected") || errorDesc.contains("connection") {
                debugLog("[PolarManager] ⚠️ GATT disconnection detected")
                debugLog("[PolarManager] ⚠️ If you have other apps running (SnoreLab, Polar Beat, etc.), they may be competing for the connection")
            }
            Task { @MainActor in
                await self.attemptStreamingReconnect(afterError: error)
            }
        }

        /// `onCompleted` while we still believe we're streaming means the link
        /// dropped under us; otherwise it's the normal teardown.
        private func handleStreamCompleted(streamName: String) {
            debugLog("[PolarManager] \(streamName) streaming completed (onCompleted)")
            guard isStreaming else {
                Task { @MainActor in self.stopStreamingInternal() }
                return
            }
            debugLog("[PolarManager] Stream completed while still in streaming mode — attempting reconnect")
            Task { @MainActor in
                await self.attemptStreamingReconnect(afterError: PolarError.fetchFailed("Stream completed unexpectedly"))
            }
        }
    #endif
}

/// The connect-time HR monitor and the recording stream both subscribe to the
/// strap's HR notifications; running both makes the monitor finish early and
/// blank `currentHeartRate` mid-session. Kept outside `PolarManager`, which is
/// over the aggregate-size threshold.
@MainActor
private func cancelConnectTimeHRMonitor(on manager: PolarManager) {
    manager.hrMonitorTask?.cancel()
    manager.hrMonitorTask = nil
}
