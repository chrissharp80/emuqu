import Combine
import Foundation
import Observation

// MARK: - PolarManager State Bindings

extension CollectorSessionControl {
    /// Forward PolarManager state changes to RRCollector's observable proxies.
    ///
    /// There is deliberately NO throttled proxy that subscribes to
    /// `collector.polarManager.objectWillChange` (the firehose — fires on every HR/RR
    /// update) and pushes a throttled (~3/s), BATCHED snapshot of 8
    /// DeviceStatus fields. Every one of those 8 fields is written
    /// immediately by a dedicated, targeted binder below
    /// (isDeviceConnected/connectionState → bindConnectionState; isStreaming →
    /// bindStreamingState; isRecordingOnDevice → bindRecordingStateTracking;
    /// connectedDeviceType/recordingState/hasStoredExercise → bindSimpleProperty-
    /// Proxies; batteryLevel → bindBatteryAndReconnect). A throttled proxy
    /// adds no field coverage — only a SECOND, lagged writer whose
    /// stale batch races the immediate binders. That cross-cadence race is the
    /// record-screen flicker / "collapsed to one line" at wake (the source
    /// flags flip together but the throttled mirror settles a beat later with a
    /// stale combination). Each DeviceStatus field has exactly ONE writer,
    /// updated immediately on its own publisher — no throttle, no batch race,
    /// and less main-thread work (no per-HR-update diff). ⚠️ Verify the record
    /// screen on device (streaming start/stop + wake).
    func setupBindings() {
        bindPolarErrorForwarding()
        bindRecordingStateTracking()
        bindSimplePropertyProxies()
        bindConnectionState()
        bindStreamingState()
        bindHealthKitSleep()
        bindBatteryAndReconnect()
        bindCloudSyncBaseline()
    }

    // MARK: - Binding Groups

    /// Forward Polar errors to RRCollector's lastError.
    private func bindPolarErrorForwarding() {
        ObservationLoop.observe(collector, read: { $0.polarManager.lastError }, onChange: { collector, error in
            if let error { collector.lastError = error }
        })
    }

    /// Track H10 internal recording state and sync recording phase.
    private func bindRecordingStateTracking() {
        ObservationLoop.observe(collector, initial: true, read: { $0.polarManager.isRecordingOnDevice }, onChange: { collector, isRecording in
            collector.isCollecting = isRecording
            collector.deviceStatus.isRecordingOnDevice = isRecording
            if isRecording, collector.recordingPhase == .idle {
                collector.recordingPhase = .deviceRecording
            } else if !isRecording, collector.recordingPhase == .deviceRecording {
                collector.recordingPhase = .idle
            }
        })
    }

    /// Simple 1:1 property proxies: recordingState, deviceType, fetchProgress, storedExercise.
    private func bindSimplePropertyProxies() {
        ObservationLoop.observe(collector, initial: true, read: { $0.polarManager.recordingState }, onChange: { collector, state in
            collector.deviceStatus.recordingState = state
        })
        ObservationLoop.observe(collector, initial: true, read: { $0.polarManager.connectedDeviceType }, onChange: { collector, type in
            collector.deviceStatus.connectedDeviceType = type
        })
        ObservationLoop.observe(collector, initial: true, read: { $0.polarManager.fetchProgress }, onChange: { collector, progress in
            collector.deviceStatus.fetchProgress = progress
        })
        ObservationLoop.observe(collector, initial: true, read: { $0.polarManager.hasStoredExercise }, onChange: { collector, stored in
            collector.deviceStatus.hasStoredExercise = stored
        })
    }

    /// Connection state: not throttled for fast UI response.
    ///
    /// A disconnect no longer finalizes a paused night. A pause is for
    /// taking the strap off (the bathroom break), and the night was paused
    /// for resume when reconnecting ran out; in both, the strap dropping or a
    /// failed reconnect attempt then closed the night for good and took
    /// Resume away. The night stays paused until the user resumes or
    /// finishes it.
    private func bindConnectionState() {
        ObservationLoop.observe(collector, initial: true, read: { $0.polarManager.connectionState }, onChange: { collector, state in
            collector.deviceStatus.isDeviceConnected = state == .connected
            collector.deviceStatus.connectionState = state
            collector.control.refreshRecentPausedSession()
        })
    }

    /// Streaming state: observe both polarManager.isStreaming and isStreamingMode to avoid race.
    private func bindStreamingState() {
        ObservationLoop.observe(collector, initial: true, read: { $0.polarManager.isStreaming }, onChange: { collector, streaming in
            collector.deviceStatus.isStreaming = streaming || collector.isStreamingMode
        })
        armStreamingModeObservation()
    }

    // MARK: - Observation-framework replacements for removed Combine sinks
    //
    // The five recording sub-objects are `@Observable` (Observation framework),
    // so there is no Combine `objectWillChange` / `$property` publisher to sink.
    // These self-re-arming `withObservationTracking` loops fire on any change.
    // `withObservationTracking` is one-shot, so each `onChange` re-arms; work is
    // deferred to a `@MainActor` Task so it reads post-mutation state.

    /// Refresh the live-HRV mirror on any SessionState mutation. Reads every observable
    /// field so a change to any of them re-fires.
    func armSessionStateMirrorObservation() {
        withObservationTracking {
            _ = collector.sessionState.recordingPhase
            _ = collector.sessionState.isCollecting
            _ = collector.sessionState.currentSession
            _ = collector.sessionState.collectedPoints
            _ = collector.sessionState.lastError
            _ = collector.sessionState.verificationResult
            _ = collector.sessionState.recoveryWindow
            _ = collector.sessionState.needsAcceptance
            _ = collector.sessionState.baselineDeviation
            _ = collector.sessionState.recentPausedSession
        } onChange: { [weak owner = collector] in
            Task { @MainActor in owner?.control.onSessionStateChanged() }
        }
    }

    @MainActor
    func onSessionStateChanged() {
        collector.refreshLiveHRVSnapshotMirror()
        armSessionStateMirrorObservation()
    }

    /// Refresh the cached paused session (resume banner) on every
    /// archive-signal bump.
    /// `withObservationTracking` fires only on change, so no `dropFirst` needed.
    func armArchiveSignalObservation() {
        withObservationTracking {
            _ = collector.archiveSignal.version
        } onChange: { [weak owner = collector] in
            Task { @MainActor in owner?.control.onArchiveSignalChanged() }
        }
    }

    @MainActor
    func onArchiveSignalChanged() {
        refreshRecentPausedSession()
        armArchiveSignalObservation()
    }

    /// Keep `collector.deviceStatus.isStreaming` in sync with streaming mode.
    func armStreamingModeObservation() {
        withObservationTracking {
            _ = collector.streamingLifecycle.isStreamingMode
        } onChange: { [weak owner = collector] in
            Task { @MainActor in owner?.control.onStreamingModeChanged() }
        }
    }

    /// Observation tracking is one-shot, so every handler re-arms itself.
    @MainActor
    func onStreamingModeChanged() {
        collector.deviceStatus.isStreaming = collector.polarManager.isStreaming || collector.streamingLifecycle.isStreamingMode
        armStreamingModeObservation()
    }

    /// Forward HealthKit sleep data arrival notifications.
    ///
    /// Auto-rescore wiring. Merely bumping
    /// `collector.sleepDataVersion` leaves nobody on the V2 dashboard
    /// reacting, the score stale, and the user tapping
    /// "Reanalyze" every morning. The old dashboard view-model posted
    /// `.flowRecoveryRescoreNeeded` from its own sleep refresh; `DashboardV2View`
    /// never used it and it no longer exists, so that chain is gone. Instead,
    /// every sleep-data-version bump checks today's
    /// morning session against the freshly-arrived
    /// HealthKit sleep, and posts the rescore notification
    /// when the new data materially improves on the
    /// frozen snapshot. The existing rescore listener
    /// (`installRescoreListener`) picks it up and reanalyzes.
    private func bindHealthKitSleep() {
        ObservationLoop.observe(collector, read: { $0.healthKit.sleepDataVersion }, onChange: { collector, version in
            collector.sleepDataVersion = version
            Task { @MainActor in await collector.autoRefreshTodaysSleepIfImproved() }
        })
        bindHealthKitVitals()
    }

    /// Same pattern for vitals (respiratory rate, SpO2, wrist temperature,
    /// resting HR). Apple Watch syncs these well after sleep ends, so
    /// the snapshot captured at acceptance is usually empty. Bumping
    /// `vitalsDataVersion` lets RecoveryDashboardView re-fetch and
    /// re-archive the session snapshot once the Watch's data lands.
    private func bindHealthKitVitals() {
        ObservationLoop.observe(collector, read: { $0.healthKit.vitalsDataVersion }, onChange: { collector, version in
            collector.morningCoordination.vitalsDataVersion = version
        })
    }

    /// Battery level proxy + auto-finalize on critical battery, auto-pause on reconnect exhaustion.
    private func bindBatteryAndReconnect() {
        ObservationLoop.observe(collector, initial: true, read: { $0.polarManager.batteryLevel }, onChange: { collector, level in
            collector.deviceStatus.batteryLevel = level
            guard let level, collector.isPaused, level <= 5 else { return }
            debugLog("[RRCollector] 🪫 Battery critical (\(level)%) while paused — auto-finalizing")
            collector.control.finalizeFromPause()
        })
        ObservationLoop.observe(collector, read: { $0.polarManager.reconnectExhausted }, onChange: { collector, exhausted in
            if exhausted { collector.control.handleReconnectExhaustedDuringOvernight() }
        })
    }

    /// CRITICAL (a whole night was once lost here): when the H10 internal
    /// recording is running, the strap is capturing the FULL night to
    /// its own memory independently of BLE. A mid-night reconnect
    /// exhaustion — a transient iOS BLE radio reset (recovered in ~5s
    /// in the field log) or an out-of-range trip — must NOT pause here,
    /// because pausing runs `collector.gatherOvernightData` → `fetchExerciseDataQuick`,
    /// which STOPS the strap recording and finalizes the night 10 min
    /// in. Leave the session streaming; the strap holds everything and
    /// the morning stop reconnects and pulls the full-night file. This
    /// is exactly the resilience the internal backup exists to provide.
    ///
    /// Streaming-only (Verity Sense, or backup disabled): there is no
    /// strap file, so the buffered live stream is the only copy — pause
    /// to save it for resume.
    private func handleReconnectExhaustedDuringOvernight() {
        guard collector.isOvernightStreaming else { return }
        if collector.overnightDeviceBackupActive {
            debugLog("[RRCollector] Reconnect exhausted, but H10 internal backup is recording the full night — NOT pausing; the strap keeps recording and the morning stop will fetch it", level: .warning)
            collector.polarManager.reconnectExhausted = false
            return
        }
        debugLog("[RRCollector] Reconnect exhausted during overnight streaming (no strap backup) — auto-pausing to save buffered data")
        // `[collector]` keeps the owner alive for the hop.
        Task { [collector] in
            _ = await self.pauseOvernightStreaming()
            collector.polarManager.reconnectExhausted = false
        }
    }

    /// Rebuild baseline after CloudKit pulls new sessions (e.g. after reinstall).
    private func bindCloudSyncBaseline() {
        ObservationLoop.observe(collector, read: { $0.cloudSyncManager.pullVersion }, onChange: { collector, _ in
            guard collector.baselineTracker.daysCollected == 0 else { return }
            let archive = collector.archive
            let tracker = collector.baselineTracker
            let schedule = collector.settingsManager.settings.sleepSchedule
            Task.detached(priority: .utility) {
                Self.rebuildBaselineAfterSync(archive: archive, tracker: tracker, schedule: schedule)
            }
        })
    }

    /// Off-main: decode every archived session and rebuild the baseline from it.
    nonisolated private static func rebuildBaselineAfterSync(
        archive: SessionArchive, tracker: BaselineTracker, schedule: SleepSchedule
    ) {
        let entries = archive.entries
        guard !entries.isEmpty else { return }
        let sessions = entries.compactMap { archive.retrieveLightweightOrLog($0.sessionId, caller: "baselineRebuildAfterSync") }
        tracker.rebuildFromSessions(sessions, sleepSchedule: schedule)
    }

    /// Refresh the cached recentPausedSession on a background thread.
    /// Archive I/O (index scan, file reads, SHA256, JSON decode) runs off-main.
    /// Only hops to main to publish the result.
    func refreshRecentPausedSession() {
        // Capture what we need before leaving the MainActor. `owner` is weak
        // so a background refresh never keeps the collector alive.
        let archive = collector.archive
        let maxGap = collector.settingsManager.settings.effectiveMergeGapSeconds

        Task.detached(priority: .utility) { [weak owner = collector] in
            let result = CollectorSessionControl.findRecentPausedSessionOffMain(archive: archive, maxGap: maxGap)
            await MainActor.run { [weak owner] in
                owner?.recentPausedSession = result
            }
        }
    }

    /// Pure function that searches the archive for a recent paused/complete overnight
    /// session. Runs entirely off the main thread — no actor isolation needed.
    /// Uses lightweight retrieval (skips rrSeries) since only state/dates are checked.
    ///
    /// The index scan + disk loads happen here, off the main thread.
    /// Lightweight loads skip rrSeries (~700KB per session) since we only
    /// need state, pausedDate, and endDate for the search.
    ///
    /// Paused sessions win over recently-completed ones — a pause is an
    /// explicit "I'm coming back to this."
    nonisolated static func findRecentPausedSessionOffMain(archive: SessionArchive, maxGap: TimeInterval) -> HRVSession? {
        guard maxGap > 0 else { return nil }
        let now = Date()
        let cutoff = now.addingTimeInterval(-maxGap)
        let loaded = archive.entries
            .filter { $0.sessionType == .overnight && $0.date >= cutoff }
            .compactMap { archive.retrieveLightweightOrLog($0.sessionId) }
        let paused = loaded.first {
            $0.state == .paused && now.timeIntervalSince($0.pausedDate ?? .distantPast) <= maxGap
        }
        if let paused { return paused }
        return loaded.first {
            $0.state == .complete && now.timeIntervalSince($0.endDate ?? .distantPast) <= maxGap
        }
    }
}

// MARK: - Launch wiring
//
// These are the second half of `wireCollaborators()`: the Assistant snapshot
// provider, the two observation loops and the one-time merge migration. They
// live here rather than in `RRCollector.swift` because that class body sits
// against SwiftLint's 500-line `type_body_length` rule, and because binding and
// observation is what this file is for.
extension CollectorSessionControl {
    /// Expose live recording state to the Assistant. Pull-based (rather than
    /// the workout broker's push model) so we don't wake up every RR beat just
    /// to update a snapshot; the AI queries the broker once per context build
    /// and gets fresh state on demand.
    ///
    /// `weak self` — if the collector is ever released, return nil so the AI
    /// cleanly reports "no live recording" instead of holding a dangling
    /// reference.
    ///
    /// A snapshot-mirror pattern, not a `DispatchQueue.main.sync`-based
    /// provider. The MainActor-isolated
    /// `collector.refreshLiveHRVSnapshotMirror()` writes a Sendable struct into
    /// `collector._liveHRVSnapshotMirror` whenever `collector.sessionState` changes. The provider
    /// closure below reads the mirror through the lock — no actor crossing, no
    /// deadlock risk, no `dispatchPrecondition`. Stale-by-one-runloop-tick is
    /// the tradeoff; for "what's happening right now" it's invisible.
    func publishLiveHRVSnapshotsToAssistant() {
        AppDependencies.current.assistant.liveHRVBroker.registerProvider { [weak collector] in
            guard let collector, let mirror = Self.currentLiveHRVSnapshotMirror(of: collector) else { return nil }
            return Self.liveSnapshot(from: mirror, now: Date())
        }
    }

    /// Read the mirror under its lock.
    ///
    /// `nonisolated` because the broker calls the provider from whatever
    /// context builds the AI's context — crossing to the main actor here is
    /// exactly the deadlock the mirror pattern exists to avoid. Safe: the
    /// property is pointer-atomic and every write is lock-protected.
    nonisolated private static func currentLiveHRVSnapshotMirror(of collector: RRCollector) -> RRCollector.LiveHRVSnapshotMirror? {
        collector.liveHRVSnapshotMirror.withLock { $0 }
    }

    /// Clock-dependent fields are recomputed at READ time so the values
    /// reflect "now", not the moment the mirror was written.
    nonisolated private static func liveSnapshot(
        from mirror: RRCollector.LiveHRVSnapshotMirror,
        now: Date
    ) -> AssistantContext.LiveHRVSnapshot {
        AssistantContext.LiveHRVSnapshot(
            phase: mirror.phaseLabel,
            phaseDescription: mirror.phaseDescription,
            isCollecting: mirror.isCollecting,
            beatCount: mirror.beatCount,
            elapsedSeconds: mirror.sessionStartAt.map { Int(now.timeIntervalSince($0)) },
            sessionStartAt: mirror.sessionStartAt,
            snapshotAt: now,
            lastErrorDescription: mirror.lastErrorDescription
        )
    }

    /// Live-HRV mirror (refresh on every SessionState mutation) + resume banner
    /// refresh (on every archive-signal bump). `SessionState` and
    /// `ArchiveSignal` are `@Observable`, so there is no Combine
    /// `objectWillChange` / `$version` publisher — these self-re-arming
    /// `withObservationTracking` loops fire on any change, deferred one
    /// runloop tick to read post-mutation state.
    /// Defined in `RRCollector+Bindings`.
    func armObservationLoops() {
        armSessionStateMirrorObservation()
        armArchiveSignalObservation()
    }

    /// One-time migration: repair sessions affected by the merge data-loss bug
    /// where background device refinement bypassed `collector.mergeParentSessionData()`.
    ///
    /// v6 fixes v5's 0-offset double-merge, which created corrupted 399K-beat
    /// sessions with overlapping timestamps. `Task.detached` keeps it off the
    /// main actor at launch.
    ///
    /// The task holds the collector strongly, so a one-time migration keeps
    /// its owner alive until it finishes.
    func runMergeDataLossMigrationIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: UserDefaultsKeys.mergeDataLossRepaired) else { return }
        let collector = self.collector
        Task.detached {
            let count = await collector.recovery.repairMergeDataLoss()
            debugLog("[RRCollector] Merge data loss migration complete: \(count) sessions repaired")
            UserDefaults.standard.set(true, forKey: UserDefaultsKeys.mergeDataLossRepaired)
        }
    }
}
