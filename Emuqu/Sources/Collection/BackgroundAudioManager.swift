import AVFoundation
import os

/// Backs the audio session for AUDIBLE workout-coach content (coach
/// alerts, mile markers, interval announcements) on indoor workouts,
/// where no GPS session exists to keep TTS deliverable with the screen
/// off. Started ONLY when an audible feature is enabled — see
/// `WorkoutRecorder.startKeepAlives` (App Store 2.5.4: the audio
/// background mode must serve audible content; this class's former role
/// as an all-night silent keep-alive is gone; overnight
/// rides on `bluetooth-central`).
@Observable
@MainActor
final class BackgroundAudioManager {
    static let shared = BackgroundAudioManager()

    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var playerNode: AVAudioPlayerNode?
    @ObservationIgnored private var silentBuffer: AVAudioPCMBuffer?
    @ObservationIgnored private var audioFormat: AVAudioFormat?
    private(set) var isRunning = false
    private(set) var wasInterrupted = false // Track if we recovered from interruption

    @ObservationIgnored private let observers = NotificationTokens()

    /// Periodic health check — detects silent engine death that no notification caught.
    /// The timer lives inside a lock so `deinit` can invalidate it without
    /// touching a non-`Sendable` stored property from a nonisolated context.
    @ObservationIgnored private let healthCheckTimerBox = OSAllocatedUnfairLock<Timer?>(uncheckedState: nil)
    private var healthCheckTimer: Timer? {
        get { healthCheckTimerBox.withLockUnchecked { $0 } }
        set { healthCheckTimerBox.withLockUnchecked { $0 = newValue } }
    }

    private init() {
        setupInterruptionObserver()
        setupRouteChangeObserver()
        setupMediaResetObserver()
    }

    deinit {
        healthCheckTimerBox.withLockUnchecked { $0?.invalidate() }
        observers.removeAll()
    }

    // MARK: - Audio Session Interruption Handling

    private func setupInterruptionObserver() {
        observers.add(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { self?.handleAudioSessionInterruption(typeValue: typeValue, optionsValue: optionsValue) }
        })
    }

    private func handleAudioSessionInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard let typeValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            debugLog("BackgroundAudioManager: Invalid interruption notification")
            return
        }
        switch type {
        case .began:
            // Audio is automatically paused by the system. We don't stop our
            // state — we'll try to resume when the interruption ends.
            debugLog("BackgroundAudioManager: Audio session interrupted (phone call, alarm, etc.)")
        case .ended:
            debugLog("BackgroundAudioManager: Audio session interruption ended")
            resumeKeepaliveAfterInterruption(optionsValue: optionsValue)
        @unknown default:
            debugLog("BackgroundAudioManager: Unknown interruption type: \(typeValue)")
        }
    }

    /// ALWAYS resume while running, regardless of the `.shouldResume` hint.
    ///
    /// The manager runs only during an indoor workout with spoken coaching on.
    /// A call or alarm often ends its interruption WITHOUT `.shouldResume`
    /// (and sometimes posts no `.ended` until it is dismissed). Waiting on the
    /// hint would leave the session paused: the coach goes quiet for the rest
    /// of the workout, the `audio` background assertion lapses, and iOS
    /// suspends the app mid-workout.
    ///
    /// Forcing resume is safe: between spoken cues the buffer is silence at
    /// volume 0, so reactivating the session never plays over another app.
    /// `resumeAfterInterruption` already catches a failed reactivation and
    /// falls back to a full restart.
    private func resumeKeepaliveAfterInterruption(optionsValue: UInt?) {
        guard isRunning else {
            debugLog("BackgroundAudioManager: Not running, won't resume after interruption")
            return
        }
        let hadShouldResume = optionsValue
            .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
        debugLog("BackgroundAudioManager: Resuming keep-alive after interruption (shouldResume=\(hadShouldResume))")
        resumeAfterInterruption()
    }

    // MARK: - Route Change Handling

    private func setupRouteChangeObserver() {
        observers.add(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.handleRouteChange(reasonValue: reasonValue) }
        })
    }

    private func handleRouteChange(reasonValue: UInt?) {
        guard isRunning else { return }

        guard let reasonValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        debugLog("BackgroundAudioManager: Route changed (reason: \(reason.rawValue))")

        // After a route change the engine may silently stop producing audio.
        // Verify it's still healthy; restart if not.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.verifyAndRestart()
        }
    }

    // MARK: - Media Services Reset Handling

    private func setupMediaResetObserver() {
        observers.add(NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        })
    }

    /// The entire audio stack is gone. All AVAudioEngine/AVAudioSession state
    /// is invalid, so we tear down and rebuild from scratch.
    private func handleMediaServicesReset() {
        guard isRunning else { return }
        debugLog("BackgroundAudioManager: ⚠️ Media services were RESET — audio engine is dead, rebuilding")
        playerNode = nil
        audioEngine = nil
        silentBuffer = nil
        audioFormat = nil
        // Rebuild after a brief delay to let the system stabilize
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.rebuildAfterMediaServicesReset()
        }
    }

    private func rebuildAfterMediaServicesReset() {
        guard isRunning else { return }
        isRunning = false
        startBackgroundAudio()
        if isRunning {
            debugLog("BackgroundAudioManager: ✅ Recovered from media services reset")
        } else {
            debugLog("BackgroundAudioManager: ❌ Failed to recover from media services reset")
        }
    }

    // MARK: - Periodic Health Check

    private func startHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.verifyAndRestart() }
        }
    }

    private func stopHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    /// Verify audio engine is actually running; restart if it died silently.
    private func verifyAndRestart() {
        guard isRunning else { return }

        let engineOK = audioEngine?.isRunning == true
        let playerOK = playerNode?.isPlaying == true

        if engineOK, playerOK { return }

        debugLog("BackgroundAudioManager: ⚠️ Health check FAILED (engine=\(engineOK) player=\(playerOK)) — restarting")
        restartAudioCompletely()
    }

    private func resumeAfterInterruption() {
        DispatchQueue.main.async { [weak self] in
            guard let self, isRunning else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try restartEngineAndPlayer()
                wasInterrupted = true // Flag that we recovered
                debugLog("BackgroundAudioManager: Successfully resumed after interruption")
            } catch {
                debugLog("BackgroundAudioManager: Failed to resume after interruption - \(error.localizedDescription)")
                // Try a full restart as last resort
                restartAudioCompletely()
            }
        }
    }

    private func restartEngineAndPlayer() throws {
        if let engine = audioEngine, !engine.isRunning {
            try engine.start()
            debugLog("BackgroundAudioManager: Restarted audio engine after interruption")
        }
        guard let player = playerNode, !player.isPlaying else { return }
        if let buffer = silentBuffer {
            player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        }
        player.play()
        debugLog("BackgroundAudioManager: Resumed player after interruption")
    }

    private func restartAudioCompletely() {
        debugLog("BackgroundAudioManager: Attempting full restart after interruption failure")

        // Stop everything
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil

        // Small delay before restart
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, isRunning else { return }

            // Restart (isRunning is still true so startBackgroundAudio will skip guard)
            isRunning = false
            startBackgroundAudio()
        }
    }

    /// Start silent audio playback to keep app alive in background
    ///
    /// The category claim is routed through the coordinator. When
    /// voice chat is active, the coordinator keeps the session at
    /// `.playAndRecord` (which still lets our silent buffer play —
    /// `.playAndRecord` is a strict superset of `.playback` for our purposes).
    /// Without this shared owner BGAM's `setCategory(.playback)` clobbered
    /// voice's mic config and the recogniser went silent.
    ///
    /// No start/stop logging here beyond the entry line — RRCollector already
    /// logs both. The screen is allowed to lock normally; the background audio
    /// is what keeps the app alive.
    func startBackgroundAudio() {
        guard !isRunning else {
            debugLog("BackgroundAudioManager: Already running")
            return
        }
        debugLog("BackgroundAudioManager: Starting background audio")
        do {
            AppDependencies.current.services.audioSessionCoordinator.claim(.backgroundKeepalive, mode: .playback)
            try AVAudioSession.sharedInstance().setActive(true)
            guard let built = makeSilentEngine() else { return }
            try startSilentLoop(built)
            isRunning = true
            startHealthCheck()
        } catch {
            debugLog("BackgroundAudioManager: Error starting audio - \(error.localizedDescription)")
        }
    }

    /// Retain the engine + player, keep the buffer and format for interruption
    /// recovery, and loop the silence indefinitely.
    private func startSilentLoop(_ built: SilentEngine) throws {
        let (engine, player, buffer) = (built.engine, built.player, built.buffer)
        audioEngine = engine
        playerNode = player
        silentBuffer = buffer
        audioFormat = built.format
        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()
    }

    /// Build the engine, player, and a one-second buffer of pure silence, wired
    /// through a main mixer at zero output volume — fully silent on both counts.
    private func makeSilentEngine() -> SilentEngine? {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let sampleRate = 44100.0
        let frameCount = AVAudioFrameCount(sampleRate * 1.0) // 1 second buffer
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            debugLog("BackgroundAudioManager: Failed to create audio format/buffer")
            return nil
        }
        buffer.frameLength = frameCount
        if let channelData = buffer.floatChannelData?[0] {
            for i in 0 ..< Int(frameCount) { channelData[i] = 0.0 }
        }
        let mainMixer = engine.mainMixerNode
        engine.connect(player, to: mainMixer, format: format)
        mainMixer.outputVolume = 0.0
        return SilentEngine(engine: engine, player: player, buffer: buffer, format: format)
    }

    /// The four pieces of the keep-alive graph, kept together so `startBackgroundAudio`
    /// can hand them to `startSilentLoop` as one value.
    private struct SilentEngine {
        @ObservationIgnored let engine: AVAudioEngine
        @ObservationIgnored let player: AVAudioPlayerNode
        @ObservationIgnored let buffer: AVAudioPCMBuffer
        @ObservationIgnored let format: AVAudioFormat
    }

    /// Stop background audio playback
    func stopBackgroundAudio() {
        guard isRunning else {
            debugLog("BackgroundAudioManager: Not running, nothing to stop")
            return
        }
        debugLog("BackgroundAudioManager: Stopping background audio")
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
        silentBuffer = nil
        audioFormat = nil
        releaseAudioSession()
        isRunning = false
        wasInterrupted = false
        stopHealthCheck()
        // No logging - start/stop already logged in RRCollector
    }

    /// Release the coordinator claim FIRST so a still-active voice
    /// chat keeps its `.playAndRecord` claim. Then deactivate the audio session
    /// ONLY if voice isn't still using it: calling `setActive(false)` while
    /// voice is mid-recording would kill the mic tap — exactly the bug we fixed
    /// elsewhere.
    private func releaseAudioSession() {
        AppDependencies.current.services.audioSessionCoordinator.release(.backgroundKeepalive)
        guard !AppDependencies.current.services.audioSessionCoordinator.isVoiceActive() else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            debugLog("BackgroundAudioManager: Error deactivating audio session - \(error.localizedDescription)")
        }
    }
}
