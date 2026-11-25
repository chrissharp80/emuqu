import Combine
import Foundation
import Observation

// MARK: - PolarManager State Bindings

extension CollectorBindings {
    /// Forward PolarManager state changes to RRCollector's observable proxies.
    ///
    /// There is deliberately NO throttled proxy that subscribes to
    /// `polarManager.objectWillChange` (the firehose — fires on every HR/RR
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
    /// stale combination). Each of those fields is written immediately by its
    /// own binder — no throttle, no batch race, and less main-thread work (no
    /// per-HR-update diff). Only one binder writes each field, except
    /// `isStreaming`: it is derived from the strap's flag OR streaming mode, so
    /// both `bindStreamingState` and `onStreamingModeChanged` write it, and the
    /// stop paths (the quick-reading stop, the overnight gather and discard)
    /// clear it directly as the stream ends. ⚠️ Verify the record screen on
    /// device (streaming start/stop + wake).
    func setupBindings() {
        bindPolarErrorForwarding()
        bindRecordingStateTracking()
        bindSimplePropertyProxies()
        bindConnectionState()
        bindStreamingState()
        bindHealthKitSleep()
        bindBatteryAndReconnect()
        bindCloudSyncBaseline()
        notificationObservers.add(baselineArchiveSync.observe())
    }

    // MARK: - Binding Groups

    /// Forward Polar errors to RRCollector's lastError.
    private func bindPolarErrorForwarding() {
        ObservationLoop.observe(self, read: { $0.polarManager.lastError }, onChange: { bindings, error in
            if let error { bindings.sessionState.lastError = error }
        })
    }

    /// Track H10 internal recording state and sync recording phase.
    ///
    /// `isCollecting` means "a session of this app is recording", and the
    /// recovery gates read it that way. A recording on the strap is not one by
    /// itself (a crash leaves one running with no session), so the strap
    /// starting never sets it; the device-recording start does. The strap
    /// stopping ends only a device recording's collection, not a streaming
    /// night's. A live workout's backup recording is the workout's, not a
    /// device recording, so the phase stays idle for it.
    private func bindRecordingStateTracking() {
        ObservationLoop.observe(self, initial: true, read: { $0.polarManager.isRecordingOnDevice }, onChange: { bindings, isRecording in
            bindings.deviceStatus.isRecordingOnDevice = isRecording
            if isRecording, bindings.sessionState.recordingPhase == .idle, !bindings.strapGuards.belongsToLiveWorkout {
                bindings.sessionState.recordingPhase = .deviceRecording
            } else if !isRecording, bindings.sessionState.recordingPhase == .deviceRecording {
                bindings.sessionState.isCollecting = false
                bindings.sessionState.recordingPhase = .idle
            }
        })
    }

    /// Simple 1:1 property proxies: recordingState, deviceType, fetchProgress, storedExercise.
    private func bindSimplePropertyProxies() {
        ObservationLoop.observe(self, initial: true, read: { $0.polarManager.recordingState }, onChange: { bindings, state in
            bindings.deviceStatus.recordingState = state
        })
        ObservationLoop.observe(self, initial: true, read: { $0.polarManager.connectedDeviceType }, onChange: { bindings, type in
            bindings.deviceStatus.connectedDeviceType = type
        })
        ObservationLoop.observe(self, initial: true, read: { $0.polarManager.fetchProgress }, onChange: { bindings, progress in
            bindings.deviceStatus.fetchProgress = progress
        })
        ObservationLoop.observe(self, initial: true, read: { $0.polarManager.hasStoredExercise }, onChange: { bindings, stored in
            bindings.deviceStatus.hasStoredExercise = stored
        })
    }

    /// Connection state: not throttled for fast UI response.
    ///
    /// A disconnect does not finalize a paused night. A pause is for taking
    /// the strap off (the bathroom break), or the night was paused for resume
    /// when reconnecting ran out; in both, the strap dropping or a failed
    /// reconnect attempt must not close the night and take Resume away. The
    /// night stays paused until the user resumes or finishes it.
    ///
    /// The Continue card is looked up again when the link comes up or goes
    /// down, not on each scanning and connecting step in between: the lookup
    /// scans the archive, and a reconnecting strap passes those steps over
    /// and over.
    private func bindConnectionState() {
        ObservationLoop.observe(self, initial: true, read: { $0.polarManager.connectionState }, onChange: { bindings, state in
            bindings.deviceStatus.isDeviceConnected = state == .connected
            bindings.deviceStatus.connectionState = state
            guard state == .connected || state == .disconnected else { return }
            bindings.control.refreshRecentPausedSession()
        })
    }

    /// Streaming state: observe both polarManager.isStreaming and isStreamingMode to avoid race.
    private func bindStreamingState() {
        ObservationLoop.observe(self, initial: true, read: { $0.polarManager.isStreaming }, onChange: { bindings, streaming in
            bindings.deviceStatus.isStreaming = streaming || bindings.streamingLifecycle.isStreamingMode
        })
        armStreamingModeObservation()
    }

    // MARK: - Observation bindings
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
            _ = sessionState.recordingPhase
            _ = sessionState.isCollecting
            _ = sessionState.currentSession
            _ = sessionState.collectedPoints
            _ = sessionState.lastError
            _ = sessionState.verificationResult
            _ = sessionState.recoveryWindow
            _ = sessionState.needsAcceptance
            _ = sessionState.baselineDeviation
            _ = sessionState.recentPausedSession
        } onChange: { [weak owner = self] in
            Task { @MainActor in owner?.onSessionStateChanged() }
        }
    }

    @MainActor
    func onSessionStateChanged() {
        liveHRVMirror.refresh(from: sessionState)
        armSessionStateMirrorObservation()
    }

    /// Refresh the cached paused session (resume banner) on every
    /// archive-signal bump.
    /// `withObservationTracking` fires only on change, so no `dropFirst` needed.
    func armArchiveSignalObservation() {
        withObservationTracking {
            _ = archiveSignal.version
        } onChange: { [weak owner = self] in
            Task { @MainActor in owner?.onArchiveSignalChanged() }
        }
    }

    @MainActor
    func onArchiveSignalChanged() {
        control.refreshRecentPausedSession()
        armArchiveSignalObservation()
    }

    /// Keep `deviceStatus.isStreaming` in sync with streaming mode.
    func armStreamingModeObservation() {
        withObservationTracking {
            _ = streamingLifecycle.isStreamingMode
        } onChange: { [weak owner = self] in
            Task { @MainActor in owner?.onStreamingModeChanged() }
        }
    }

    /// Observation tracking is one-shot, so every handler re-arms itself.
    @MainActor
    func onStreamingModeChanged() {
        deviceStatus.isStreaming = polarManager.isStreaming || streamingLifecycle.isStreamingMode
        armStreamingModeObservation()
    }

    /// Mirror HealthKit's sleep-data version onto `morningCoordination.sleepDataVersion`,
    /// which the morning results screen observes. The rescore of today's
    /// night when that sleep improves on its frozen snapshot is the
    /// saved-session reanalysis's own observation
    /// (`SessionReanalysisCoordinator.observeHealthKitSleep`).
    private func bindHealthKitSleep() {
        ObservationLoop.observe(self, read: { $0.healthKit.observation.sleepDataVersion }, onChange: { bindings, version in
            bindings.morningCoordination.sleepDataVersion = version
        })
        bindHealthKitVitals()
    }

    /// Same pattern for vitals (respiratory rate, SpO2, wrist temperature,
    /// resting HR). Apple Watch syncs these well after sleep ends, so
    /// the snapshot captured at acceptance is usually empty. Bumping
    /// `vitalsDataVersion` lets RecoveryDashboardView re-fetch and
    /// re-archive the session snapshot once the Watch's data lands.
    private func bindHealthKitVitals() {
        ObservationLoop.observe(self, read: { $0.healthKit.observation.vitalsDataVersion }, onChange: { bindings, version in
            bindings.morningCoordination.vitalsDataVersion = version
        })
    }

    /// Battery level proxy + auto-finalize on critical battery, auto-pause on reconnect exhaustion.
    private func bindBatteryAndReconnect() {
        ObservationLoop.observe(self, initial: true, read: { $0.polarManager.batteryLevel }, onChange: { bindings, level in
            bindings.deviceStatus.batteryLevel = level
            guard let level, bindings.streamingLifecycle.isPaused, level <= 5 else { return }
            debugLog("[RRCollector] 🪫 Battery critical (\(level)%) while paused — auto-finalizing")
            bindings.control.finalizeFromPause()
        })
        ObservationLoop.observe(self, read: { $0.polarManager.reconnectExhausted }, onChange: { bindings, exhausted in
            if exhausted { bindings.handleReconnectExhaustedDuringOvernight() }
        })
    }

    /// CRITICAL: when the H10 internal
    /// recording is running, the strap is capturing the FULL night to
    /// its own memory independently of BLE. A mid-night reconnect
    /// exhaustion — a transient iOS BLE radio reset (typically recovered
    /// in ~5s) or an out-of-range trip — must NOT pause here,
    /// because pausing runs `OvernightStreamingCoordinator.gatherOvernightData` → `fetchNightFromStrap`,
    /// which STOPS the strap recording and finalizes the night 10 min
    /// in. Leave the session streaming; the strap holds everything and
    /// the morning stop reconnects and pulls the full-night file. This
    /// is exactly the resilience the internal backup exists to provide.
    ///
    /// Streaming-only (Verity Sense, or backup disabled): there is no
    /// strap file, so the buffered live stream is the only copy — pause
    /// to save it for resume.
    private func handleReconnectExhaustedDuringOvernight() {
        guard streamingLifecycle.isOvernightStreaming else { return }
        if overnightRun.deviceBackupActive {
            debugLog("[RRCollector] Reconnect exhausted, but H10 internal backup is recording the full night — NOT pausing; the strap keeps recording and the morning stop will fetch it", level: .warning)
            polarManager.reconnectExhausted = false
            return
        }
        debugLog("[RRCollector] Reconnect exhausted during overnight streaming (no strap backup) — auto-pausing to save buffered data")
        // `[self]` keeps the controls alive for the hop.
        Task { [self] in
            _ = await self.control.pauseOvernightStreaming()
            polarManager.reconnectExhausted = false
        }
    }

    /// Rebuild baseline after CloudKit pulls new sessions (e.g. after reinstall).
    /// The baseline rebuilder's off-main rebuild: its commit re-checks the tracker,
    /// so a night the live path seeded during the decode is kept, and a later
    /// rebuild started by another pull leaves the first one's result alone.
    private func bindCloudSyncBaseline() {
        ObservationLoop.observe(self, read: { $0.cloudSyncManager.pullVersion }, onChange: { bindings, _ in
            guard bindings.baselineTracker.daysCollected == 0, !bindings.archive.store.entries.isEmpty else { return }
            bindings.baselineRebuild.rebuildOffMain()
        })
    }

}

// MARK: - Launch wiring
//
// These are the second half of `wireCollaborators()`: the Assistant snapshot
// provider, the two observation loops and the one-time merge migration.
extension CollectorBindings {
    /// Expose live recording state to the Assistant. Pull-based (rather than
    /// the workout broker's push model) so we don't wake up every RR beat just
    /// to update a snapshot; the AI queries the broker once per context build
    /// and gets fresh state on demand.
    ///
    /// The mirror is held weakly: once it is released, return nil so the AI
    /// cleanly reports "no live recording" instead of holding a dangling
    /// reference.
    ///
    /// A snapshot-mirror pattern, not a `DispatchQueue.main.sync`-based
    /// provider. The MainActor-isolated
    /// `LiveHRVMirror.refresh(from:)` writes a Sendable struct into the
    /// mirror whenever `sessionState` changes. The provider
    /// closure below reads the mirror through the lock — no actor crossing, no
    /// deadlock risk, no `dispatchPrecondition`. Stale-by-one-runloop-tick is
    /// the tradeoff; for "what's happening right now" it's invisible.
    func publishLiveHRVSnapshotsToAssistant() {
        services.liveHRVBroker.registerProvider { [weak liveHRVMirror] in
            guard let liveHRVMirror, let mirror = Self.currentLiveHRVSnapshotMirror(of: liveHRVMirror) else { return nil }
            return Self.liveSnapshot(from: mirror, now: Date())
        }
    }

    /// Read the mirror under its lock.
    ///
    /// `nonisolated` because the broker calls the provider from whatever
    /// context builds the AI's context — crossing to the main actor here is
    /// exactly the deadlock the mirror pattern exists to avoid. Safe: the
    /// property is pointer-atomic and every write is lock-protected.
    nonisolated private static func currentLiveHRVSnapshotMirror(of mirror: LiveHRVMirror) -> LiveHRVMirror.Snapshot? {
        mirror.snapshot.withLock { $0 }
    }

    /// Clock-dependent fields are recomputed at READ time so the values
    /// reflect "now", not the moment the mirror was written.
    nonisolated private static func liveSnapshot(
        from mirror: LiveHRVMirror.Snapshot,
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

    /// One-time migration: repair sessions saved by builds whose background
    /// device refinement bypassed `OvernightStreamingCoordinator.mergeParentSessionData()`.
    ///
    /// v6 also repairs v5's 0-offset double-merge, which left sessions with
    /// overlapping timestamps. `Task.detached` keeps it off the
    /// main actor at launch.
    ///
    /// The task holds the recovery coordinator strongly, so a one-time migration keeps
    /// its owner alive until it finishes. A night whose repair could not be
    /// written leaves the flag unset, so the next launch tries it again;
    /// nights already repaired read as healthy and are skipped.
    func runMergeDataLossMigrationIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: UserDefaultsKeys.mergeDataLossRepaired) else { return }
        let recovery = self.recovery
        Task.detached {
            let outcome = await recovery.repairMergeDataLoss()
            debugLog("[RRCollector] Merge data loss migration: \(outcome.repaired) sessions repaired, \(outcome.failed) failed")
            guard outcome.failed == 0 else { return }
            UserDefaults.standard.set(true, forKey: UserDefaultsKeys.mergeDataLossRepaired)
        }
    }
}
