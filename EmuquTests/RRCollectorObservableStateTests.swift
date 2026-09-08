import Combine
@testable import Emuqu
import Observation
import XCTest

/// Characterization tests for RRCollector's observable (`@Published`) surface.
///
/// These tests pin down current behavior of the state/signal layer so that
/// structural refactors (splitting RRCollector into narrower observables)
/// do not silently change semantics. They are intentionally behavior-level,
/// not implementation-level — they would remain meaningful if the underlying
/// property lives on a sub-object rather than the collector.
@MainActor
final class RRCollectorObservableStateTests: XCTestCase {
    /// `lazy`, not an inline initialiser: `setUp` clears persisted state first,
    /// and a stored property would be constructed before that runs — handing the
    /// collector the very state the test just asked to be rid of. Deferring to
    /// first use inside the test body keeps the original ordering.
    lazy var collector = RRCollector()
    var cancellables: Set<AnyCancellable> = []

    private func clearPersistedState() {
        PersistedRecordingState.clear()
        UserDefaults.standard.removeObject(forKey: "RRCollector.activeRecordingStartTime")
        UserDefaults.standard.removeObject(forKey: "RRCollector.activeRecordingSessionId")
        UserDefaults.standard.removeObject(forKey: "RRCollector.activeRecordingSessionType")
    }

    override func setUp() async throws {
        try await super.setUp()
        clearPersistedState()
        cancellables = []
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        if let session = collector.currentSession {
            try? collector.archive.delete(session.id)
        }
        clearPersistedState()
        try await super.tearDown()
    }

    // MARK: - archiveVersion

    /// `ArchiveSignal` COALESCES version bumps: a `notifyChanged()` does not
    /// increment `version` synchronously — it schedules a single bump at the
    /// end of an 80 ms window (`ArchiveSignal.coalesceWindow`, which
    /// exists because a CloudKit full-sync pull can fire 37 back-to-back
    /// archive notifications). Two notifies inside one window fold into ONE
    /// bump, so tests that need N distinct bumps must wait each one out
    /// before firing the next. This helper polls (yielding the main actor so
    /// the coalesce task can run) until `version` reaches the expectation.
    /// Wait for `signal.version` to reach `expected`, then assert it did.
    ///
    /// The timeout is a safety net, not a pace: the loop returns the moment the
    /// version lands, so a generous deadline costs a passing test nothing and
    /// only changes how long a genuinely broken one waits before failing.
    ///
    /// A 1.0 s deadline against an 80 ms coalescing window
    /// is ample on a developer Mac and not ample under Thread Sanitizer.
    /// CI run 33174007833 failed `testNotifyArchiveChangedForwardsToArchiveSignal`
    /// and `testArchiveSignalIsInjectable` in the sanitized job while the same
    /// tests passed unsanitized in the same run, and TSan reported zero races —
    /// so the debounce simply had not fired yet, on a build where everything
    /// runs several times slower. Ten seconds is still ~125x the window.
    private func waitForVersion(
        _ signal: ArchiveSignal,
        toReach expected: Int,
        timeout: TimeInterval = 10.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while signal.version < expected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms; window is 80 ms
        }
        XCTAssertEqual(
            signal.version, expected,
            "ArchiveSignal.version did not settle at \(expected) within \(timeout)s",
            file: file, line: line
        )
    }

    /// Deadline for the notification/observation waits in this suite.
    ///
    /// Sized for the Thread Sanitizer job, where everything runs several times
    /// slower — see `waitForVersion` for the run that proved a one-second
    /// deadline is not enough there. A waiting test returns as soon as its
    /// expectation is fulfilled, so this only bounds how long a real failure
    /// takes to report.
    private var sanitizerSafeTimeout: TimeInterval { 10.0 }

    func testArchiveVersionStartsAtZero() {
        XCTAssertEqual(collector.archiveVersion, 0)
    }

    func testNotifyArchiveChangedIncrementsVersion() async {
        let initial = collector.archiveVersion
        collector.notifyArchiveChanged()
        await waitForVersion(collector.archiveSignal, toReach: initial + 1)
        XCTAssertEqual(collector.archiveVersion, initial + 1)
        collector.notifyArchiveChanged()
        await waitForVersion(collector.archiveSignal, toReach: initial + 2)
        XCTAssertEqual(collector.archiveVersion, initial + 2)
    }

    func testNotifyArchiveChangedPostsFlowRecoveryArchiveChangedNotification() {
        let exp = expectation(forNotification: .flowRecoveryArchiveChanged, object: nil)
        collector.notifyArchiveChanged()
        wait(for: [exp], timeout: sanitizerSafeTimeout)
    }

    func testArchiveVersionPublishesWhenMutated() async {
        // ArchiveSignal is @Observable — no `$version` publisher. Verify the
        // observable `version` increments after a mutation (via the existing
        // coalesce-aware helper).
        let initial = collector.archiveSignal.version
        collector.notifyArchiveChanged()
        await waitForVersion(collector.archiveSignal, toReach: initial + 1)
        XCTAssertEqual(collector.archiveSignal.version, initial + 1)
    }

    // MARK: - ArchiveSignal back-compat forwarding

    /// A collector whose archive signal listens on a PRIVATE notification
    /// centre, so the exact-count assertions below see only the posts the
    /// test itself makes.
    ///
    /// `ArchiveSignal` observes `.flowRecoveryArchiveChanged`
    /// with `object: nil`. On `NotificationCenter.default` that is every
    /// archive write in the test process — a previous test's tearDown
    /// delete, a collector's launch-time repair — and each one is a bump.
    /// `waitForVersion(toReach: 1)` returns on `>= 1`, so a stray bump made
    /// the follow-up `== 1` fail once in a while. Isolating the centre is
    /// the fix; widening the assertion would only hide it.
    private func isolatedCollector() -> RRCollector {
        RRCollector(
            polarManager: PolarManager(),
            healthKit: HealthKitManager(),
            archiveSignal: ArchiveSignal(center: NotificationCenter())
        )
    }

    func testArchiveVersionReadsThroughArchiveSignal() async {
        let collector = isolatedCollector()
        XCTAssertEqual(collector.archiveVersion, collector.archiveSignal.version)
        collector.archiveSignal.notifyChanged()
        // The bump lands at the end of the coalesce window, not synchronously.
        await waitForVersion(collector.archiveSignal, toReach: 1)
        XCTAssertEqual(collector.archiveVersion, collector.archiveSignal.version)
        XCTAssertEqual(collector.archiveVersion, 1)
    }

    func testNotifyArchiveChangedForwardsToArchiveSignal() async {
        let collector = isolatedCollector()
        collector.notifyArchiveChanged()
        await waitForVersion(collector.archiveSignal, toReach: 1)
        XCTAssertEqual(collector.archiveSignal.version, 1)
    }

    func testArchiveSignalIsInjectable() async {
        let customSignal = ArchiveSignal(center: NotificationCenter())
        // Coalescing contract: two notifies inside one 80 ms window fold
        // into a SINGLE bump. The intent here is "a pre-incremented signal's
        // version is visible through the injected collector", so wait each
        // bump out to genuinely land version 2 before injecting.
        customSignal.notifyChanged()
        await waitForVersion(customSignal, toReach: 1)
        customSignal.notifyChanged()
        await waitForVersion(customSignal, toReach: 2)
        let injected = RRCollector(
            polarManager: PolarManager(),
            healthKit: HealthKitManager(),
            archiveSignal: customSignal
        )
        XCTAssertEqual(injected.archiveVersion, 2)
        XCTAssertTrue(injected.archiveSignal === customSignal)
    }

    // MARK: - DeviceStatus back-compat forwarding

    func testDeviceStatusProxiesMatchCollectorGetters() {
        XCTAssertEqual(collector.isDeviceConnected, collector.deviceStatus.isDeviceConnected)
        XCTAssertEqual(collector.isStreaming, collector.deviceStatus.isStreaming)
        XCTAssertEqual(collector.hasStoredExercise, collector.deviceStatus.hasStoredExercise)
        XCTAssertEqual(collector.batteryLevel, collector.deviceStatus.batteryLevel)
        XCTAssertEqual(collector.isRecordingOnDevice, collector.deviceStatus.isRecordingOnDevice)
        XCTAssertEqual(collector.connectedDeviceType, collector.deviceStatus.connectedDeviceType)
        XCTAssertEqual(collector.recordingState, collector.deviceStatus.recordingState)
        XCTAssertEqual(collector.connectionState, collector.deviceStatus.connectionState)
        // fetchProgress is a struct — just check both resolve to the same optional state.
        XCTAssertEqual(collector.fetchProgress == nil, collector.deviceStatus.fetchProgress == nil)
    }

    func testDeviceStatusWriteReflectsInCollectorGetter() {
        collector.deviceStatus.isDeviceConnected = true
        collector.deviceStatus.batteryLevel = 75
        collector.deviceStatus.connectionState = .connected
        XCTAssertTrue(collector.isDeviceConnected)
        XCTAssertEqual(collector.batteryLevel, 75)
        XCTAssertEqual(collector.connectionState, .connected)
    }

    func testDeviceStatusIsInjectable() {
        let customStatus = DeviceStatus()
        customStatus.batteryLevel = 42
        customStatus.isDeviceConnected = true
        let injected = RRCollector(
            polarManager: PolarManager(),
            healthKit: HealthKitManager(),
            deviceStatus: customStatus
        )
        XCTAssertEqual(injected.batteryLevel, 42)
        XCTAssertTrue(injected.isDeviceConnected)
        XCTAssertTrue(injected.deviceStatus === customStatus)
    }

    func testDeviceStatusPublishesWhenBatteryChanges() {
        // DeviceStatus is @Observable — no `$batteryLevel` publisher. Verify the
        // property is observable: a mutation fires the tracking onChange.
        let exp = expectation(description: "deviceStatus.batteryLevel change observed")
        withObservationTracking {
            _ = collector.deviceStatus.batteryLevel
        } onChange: {
            exp.fulfill()
        }
        collector.deviceStatus.batteryLevel = 60
        wait(for: [exp], timeout: sanitizerSafeTimeout)
        XCTAssertEqual(collector.deviceStatus.batteryLevel, 60)
    }

    func testDeviceStatusDefaultInitialValues() {
        let status = DeviceStatus()
        XCTAssertFalse(status.isDeviceConnected)
        XCTAssertFalse(status.isStreaming)
        XCTAssertFalse(status.hasStoredExercise)
        XCTAssertNil(status.batteryLevel)
        XCTAssertFalse(status.isRecordingOnDevice)
        XCTAssertNil(status.connectedDeviceType)
        XCTAssertEqual(status.recordingState, .idle)
        XCTAssertEqual(status.connectionState, .disconnected)
        XCTAssertNil(status.fetchProgress)
    }

    // MARK: - StreamingLifecycle back-compat forwarding

    func testStreamingLifecycleDefaults() {
        let lifecycle = StreamingLifecycle()
        XCTAssertFalse(lifecycle.isStreamingMode)
        XCTAssertEqual(lifecycle.streamingTargetSeconds, 180)
        XCTAssertEqual(lifecycle.streamingElapsedSeconds, 0)
        XCTAssertFalse(lifecycle.isOvernightStreaming)
        XCTAssertFalse(lifecycle.isPaused)
        XCTAssertNil(lifecycle.pausedSession)
        XCTAssertEqual(lifecycle.pausedBeatCount, 0)
    }

    func testStreamingLifecycleForwardsThroughCollector() {
        collector.streamingLifecycle.isStreamingMode = true
        collector.streamingLifecycle.streamingTargetSeconds = 300
        collector.streamingLifecycle.streamingElapsedSeconds = 42
        collector.streamingLifecycle.isOvernightStreaming = true
        collector.streamingLifecycle.isPaused = true
        collector.streamingLifecycle.pausedBeatCount = 1024

        XCTAssertTrue(collector.isStreamingMode)
        XCTAssertEqual(collector.streamingTargetSeconds, 300)
        XCTAssertEqual(collector.streamingElapsedSeconds, 42)
        XCTAssertTrue(collector.isOvernightStreaming)
        XCTAssertTrue(collector.isPaused)
        XCTAssertEqual(collector.pausedBeatCount, 1024)
    }

    func testStreamingLifecycleWritesFromCollectorSetter() {
        collector.isStreamingMode = true
        collector.streamingTargetSeconds = 240
        XCTAssertTrue(collector.streamingLifecycle.isStreamingMode)
        XCTAssertEqual(collector.streamingLifecycle.streamingTargetSeconds, 240)
    }

    func testStreamingLifecycleInjectable() {
        let custom = StreamingLifecycle()
        custom.streamingTargetSeconds = 999
        let injected = RRCollector(
            polarManager: PolarManager(),
            healthKit: HealthKitManager(),
            streamingLifecycle: custom
        )
        XCTAssertEqual(injected.streamingTargetSeconds, 999)
        XCTAssertTrue(injected.streamingLifecycle === custom)
    }

    // MARK: - MorningCoordination back-compat forwarding

    func testMorningCoordinationDefaults() {
        let coord = MorningCoordination()
        XCTAssertNil(coord.morningStatus)
        XCTAssertNil(coord.deviceRefinement)
        XCTAssertFalse(coord.isDeviceFetchInProgress)
        XCTAssertEqual(coord.sleepDataVersion, 0)
    }

    func testMorningCoordinationForwardsThroughCollector() {
        collector.morningCoordination.morningStatus = .saving(beats: 500)
        collector.morningCoordination.isDeviceFetchInProgress = true
        collector.morningCoordination.sleepDataVersion = 7

        XCTAssertEqual(collector.morningStatus, .saving(beats: 500))
        XCTAssertTrue(collector.isDeviceFetchInProgress)
        XCTAssertEqual(collector.sleepDataVersion, 7)
    }

    func testMorningCoordinationInjectable() {
        let custom = MorningCoordination()
        custom.sleepDataVersion = 42
        let injected = RRCollector(
            polarManager: PolarManager(),
            healthKit: HealthKitManager(),
            morningCoordination: custom
        )
        XCTAssertEqual(injected.sleepDataVersion, 42)
        XCTAssertTrue(injected.morningCoordination === custom)
    }

    // MARK: - SessionState back-compat forwarding

    func testSessionStateDefaults() {
        let state = SessionState()
        XCTAssertEqual(state.recordingPhase, .idle)
        XCTAssertFalse(state.isCollecting)
        XCTAssertNil(state.currentSession)
        XCTAssertTrue(state.collectedPoints.isEmpty)
        XCTAssertNil(state.lastError)
        XCTAssertNil(state.verificationResult)
        XCTAssertNil(state.recoveryWindow)
        XCTAssertFalse(state.needsAcceptance)
        XCTAssertNil(state.baselineDeviation)
        XCTAssertNil(state.recentPausedSession)
    }

    func testSessionStateForwardsThroughCollector() {
        let session = HRVSession(sessionType: .nap)
        collector.sessionState.currentSession = session
        collector.sessionState.needsAcceptance = true
        collector.sessionState.recordingPhase = .overnightStreaming

        XCTAssertEqual(collector.currentSession?.id, session.id)
        XCTAssertTrue(collector.needsAcceptance)
        XCTAssertEqual(collector.recordingPhase, .overnightStreaming)
    }

    func testSessionStateWritesFromCollectorSetter() {
        let session = HRVSession(sessionType: .quick)
        collector.currentSession = session
        collector.needsAcceptance = true
        XCTAssertEqual(collector.sessionState.currentSession?.id, session.id)
        XCTAssertTrue(collector.sessionState.needsAcceptance)
    }

    func testSessionStateInjectable() {
        let custom = SessionState()
        custom.recordingPhase = .analyzing
        let injected = RRCollector(
            polarManager: PolarManager(),
            healthKit: HealthKitManager(),
            sessionState: custom
        )
        XCTAssertEqual(injected.recordingPhase, .analyzing)
        XCTAssertTrue(injected.sessionState === custom)
    }

    // MARK: - Collector has no more observable props of its own

    func testCollectorExposesNoPublishedPropertiesDirectly() throws {
        // RRCollector's own observable surface is empty — everything is
        // forwarded through dedicated sub-observables. This test pins
        // down that invariant: the collector's `objectWillChange` is a
        // DEFAULT (never-firing) publisher, so it can't be used to
        // observe sub-object changes.
        //
        // If this test fails, a property was added directly to RRCollector
        // that should have gone on one of the sub-observables instead.
        let mirror = Mirror(reflecting: try XCTUnwrap(collector))
        let publishedChildrenOnCollector = mirror.children.filter { child in
            String(describing: type(of: child.value)).starts(with: "Published<")
        }
        XCTAssertTrue(
            publishedChildrenOnCollector.isEmpty,
            "RRCollector must not declare new properties; use a sub-observable. Found: \(publishedChildrenOnCollector.map { $0.label ?? "?" })"
        )
    }

    // MARK: - resetSession

    func testResetSessionClearsSessionAndAcceptanceState() {
        let session = HRVSession(sessionType: .overnight)
        collector.currentSession = session
        collector.collectedPoints = [RRPoint(t_ms: 0, rr_ms: 800)]
        collector.needsAcceptance = true
        collector.isPaused = true
        collector.isDeviceFetchInProgress = true

        collector.resetSession()

        XCTAssertNil(collector.currentSession)
        XCTAssertTrue(collector.collectedPoints.isEmpty)
        XCTAssertFalse(collector.needsAcceptance)
        XCTAssertFalse(collector.isPaused)
        XCTAssertNil(collector.pausedSession)
        XCTAssertNil(collector.deviceRefinement)
        XCTAssertFalse(collector.isDeviceFetchInProgress)
        XCTAssertNil(collector.verificationResult)
        XCTAssertNil(collector.recoveryWindow)
        XCTAssertNil(collector.baselineDeviation)
        XCTAssertEqual(collector.recordingPhase, .idle)
    }

    // MARK: - Device refinement

    func testDismissDeviceRefinementClearsRefinement() {
        let session = HRVSession(sessionType: .quick)
        collector.deviceRefinement = RRCollector.DeviceRefinement(
            refinedSession: session,
            originalReadiness: 50.0,
            refinedReadiness: 55.0,
            improved: true
        )
        XCTAssertNotNil(collector.deviceRefinement)

        collector.dismissDeviceRefinement()
        XCTAssertNil(collector.deviceRefinement)
    }

    func testDismissDeviceRefinementDoesNotMutateCurrentSession() {
        let original = HRVSession(sessionType: .quick)
        collector.currentSession = original
        let refined = HRVSession(sessionType: .quick)
        collector.deviceRefinement = RRCollector.DeviceRefinement(
            refinedSession: refined,
            originalReadiness: 50.0,
            refinedReadiness: 55.0,
            improved: true
        )

        collector.dismissDeviceRefinement()

        XCTAssertEqual(collector.currentSession?.id, original.id,
                       "currentSession must be untouched when dismissing refinement")
    }

    func testApplyDeviceRefinementReplacesCurrentSessionAndClearsRefinement() throws {
        let original = HRVSession(sessionType: .quick)
        collector.currentSession = original

        let refined = HRVSession(
            id: UUID(),
            startDate: Date(),
            endDate: Date(),
            state: .complete,
            sessionType: .quick,
            rrSeries: nil,
            analysisResult: nil,
            artifactFlags: nil
        )
        collector.deviceRefinement = RRCollector.DeviceRefinement(
            refinedSession: refined,
            originalReadiness: 50.0,
            refinedReadiness: 55.0,
            improved: true
        )

        collector.applyDeviceRefinement()

        XCTAssertEqual(collector.currentSession?.id, refined.id)
        XCTAssertNil(collector.deviceRefinement)

        // Side effect: refined session must be archived so the choice survives crash.
        XCTAssertTrue(collector.archive.exists(refined.id))
        try collector.archive.delete(refined.id)
    }

    func testApplyDeviceRefinementIsNoopWhenNoRefinementSet() {
        let session = HRVSession(sessionType: .quick)
        collector.currentSession = session
        collector.deviceRefinement = nil

        collector.applyDeviceRefinement()

        XCTAssertEqual(collector.currentSession?.id, session.id)
        XCTAssertNil(collector.deviceRefinement)
    }

    // MARK: - MorningProcessingStatus Equatable

    func testMorningProcessingStatusSavingEquality() {
        XCTAssertEqual(
            RRCollector.MorningProcessingStatus.saving(beats: 100),
            RRCollector.MorningProcessingStatus.saving(beats: 100)
        )
        XCTAssertNotEqual(
            RRCollector.MorningProcessingStatus.saving(beats: 100),
            RRCollector.MorningProcessingStatus.saving(beats: 200)
        )
    }

    func testMorningProcessingStatusDifferentCasesAreInequal() {
        XCTAssertNotEqual(
            RRCollector.MorningProcessingStatus.saving(beats: 100),
            RRCollector.MorningProcessingStatus.fetchingDevice(streamingBeats: 100)
        )
    }

    func testMorningProcessingStatusAnalyzingEquality() {
        let a: RRCollector.MorningProcessingStatus = .analyzing(
            beats: 100, streamedBeats: 80, deviceBeats: 20, source: "hybrid"
        )
        let b: RRCollector.MorningProcessingStatus = .analyzing(
            beats: 100, streamedBeats: 80, deviceBeats: 20, source: "hybrid"
        )
        let c: RRCollector.MorningProcessingStatus = .analyzing(
            beats: 100, streamedBeats: 80, deviceBeats: 20, source: "stream"
        )
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - DeviceRefinement Equatable

    func testDeviceRefinementEqualityMatchesSessionIdAndReadinessFields() {
        let session = HRVSession(sessionType: .quick)
        let a = RRCollector.DeviceRefinement(
            refinedSession: session,
            originalReadiness: 50.0,
            refinedReadiness: 55.0,
            improved: true
        )
        let b = RRCollector.DeviceRefinement(
            refinedSession: session,
            originalReadiness: 50.0,
            refinedReadiness: 55.0,
            improved: true
        )
        let c = RRCollector.DeviceRefinement(
            refinedSession: session,
            originalReadiness: 50.0,
            refinedReadiness: 60.0,
            improved: true
        )
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - createTrainingContext

    func testCreateTrainingContextReturnsNilWithoutCachedLoad() {
        collector.cachedTrainingLoad = nil
        XCTAssertNil(collector.createTrainingContext(relativeTo: Date()))
    }

    // MARK: - ANS configuration

    func testCurrentANSConfigUsesOverrideVO2MaxWhenPresent() {
        let originalOverride = collector.settingsManager.settings.vo2MaxOverride
        let originalUseHK = collector.settingsManager.settings.useHealthKitVO2Max
        defer {
            collector.settingsManager.settings.vo2MaxOverride = originalOverride
            collector.settingsManager.settings.useHealthKitVO2Max = originalUseHK
        }

        collector.settingsManager.settings.vo2MaxOverride = 52.0
        collector.settingsManager.settings.useHealthKitVO2Max = true  // override must still win

        let config = collector.currentANSConfig
        XCTAssertEqual(config.vo2Max, 52.0)
    }

    func testCurrentANSConfigReturnsNilVO2MaxWhenNoOverrideAndHealthKitDisabled() {
        let originalOverride = collector.settingsManager.settings.vo2MaxOverride
        let originalUseHK = collector.settingsManager.settings.useHealthKitVO2Max
        defer {
            collector.settingsManager.settings.vo2MaxOverride = originalOverride
            collector.settingsManager.settings.useHealthKitVO2Max = originalUseHK
        }

        collector.settingsManager.settings.vo2MaxOverride = nil
        collector.settingsManager.settings.useHealthKitVO2Max = false
        collector.cachedTrainingLoad = nil

        let config = collector.currentANSConfig
        XCTAssertNil(config.vo2Max)
    }

    func testCurrentANSConfigZeroAdjustmentWhenTrainingLoadDisabled() {
        let originalFlag = collector.settingsManager.settings.enableTrainingLoadIntegration
        defer { collector.settingsManager.settings.enableTrainingLoadIntegration = originalFlag }

        collector.settingsManager.settings.enableTrainingLoadIntegration = false

        let config = collector.currentANSConfig
        XCTAssertEqual(config.trainingLoadAdjustment, 0)
    }

    // MARK: - findRecentPausedSessionOffMain (pure static)

    func testFindRecentPausedSessionReturnsNilWhenMaxGapIsZero() {
        let result = RRCollector.findRecentPausedSessionOffMain(
            archive: collector.archive,
            maxGap: 0
        )
        XCTAssertNil(result)
    }

    func testFindRecentPausedSessionReturnsNilWhenMaxGapIsNegative() {
        let result = RRCollector.findRecentPausedSessionOffMain(
            archive: collector.archive,
            maxGap: -1
        )
        XCTAssertNil(result)
    }

    // MARK: - Initial published state (pins the current surface shape)

    func testInitialPublishedStateIsQuiescent() {
        XCTAssertEqual(collector.archiveVersion, 0)
        XCTAssertEqual(collector.sleepDataVersion, 0)
        XCTAssertEqual(collector.streamingElapsedSeconds, 0)
        XCTAssertEqual(collector.pausedBeatCount, 0)
        XCTAssertNil(collector.morningStatus)
        XCTAssertNil(collector.deviceRefinement)
        XCTAssertFalse(collector.isDeviceFetchInProgress)
        XCTAssertFalse(collector.isDeviceConnected)
        XCTAssertFalse(collector.isStreaming)
        XCTAssertFalse(collector.hasStoredExercise)
        XCTAssertNil(collector.batteryLevel)
        XCTAssertFalse(collector.isRecordingOnDevice)
        XCTAssertNil(collector.connectedDeviceType)
        XCTAssertEqual(collector.connectionState, .disconnected)
        XCTAssertEqual(collector.recordingState, .idle)
        XCTAssertNil(collector.recentPausedSession)
        XCTAssertNil(collector.fetchProgress)
        XCTAssertNil(collector.lastError)
        XCTAssertNil(collector.verificationResult)
        XCTAssertNil(collector.recoveryWindow)
        XCTAssertNil(collector.baselineDeviation)
    }

    func testDeviceFetchPolicyDefaultsToAutomatic() {
        if case .automatic = collector.deviceFetchPolicy {
            // OK
        } else {
            XCTFail("deviceFetchPolicy must default to .automatic")
        }
    }

    func testUseDeviceInternalBackupForOvernightStreamingDefaultsTrue() {
        XCTAssertTrue(collector.useDeviceBackupForOvernight)
    }
}
