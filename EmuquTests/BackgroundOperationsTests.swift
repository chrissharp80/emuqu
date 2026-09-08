@testable import Emuqu
import XCTest

/// Tests for background audio and location managers.
///
/// These tests verify:
/// - Audio session activation/deactivation and state tracking
/// - Location service lifecycle and authorization checks
/// - Idempotent start/stop behavior
/// - Interruption recovery tracking
@MainActor
final class BackgroundOperationsTests: XCTestCase {
    // MARK: - Background Audio Tests

    /// Test audio session starts and stops, tracking isRunning state
    func testAudioSessionLifecycle() {
        let audioManager = BackgroundAudioManager.shared

        // Initial state
        XCTAssertFalse(audioManager.isRunning, "Audio should not be running initially")

        // Start background audio
        audioManager.startBackgroundAudio()
        XCTAssertTrue(audioManager.isRunning, "Audio should be running after start")

        // Stop background audio
        audioManager.stopBackgroundAudio()
        XCTAssertFalse(audioManager.isRunning, "Audio should not be running after stop")
    }

    /// Test that starting audio twice doesn't cause issues (idempotent)
    func testAudioIdempotentStart() {
        let audioManager = BackgroundAudioManager.shared

        audioManager.startBackgroundAudio()
        audioManager.startBackgroundAudio()
        XCTAssertTrue(audioManager.isRunning, "Should still be running after double start")

        audioManager.stopBackgroundAudio()
        XCTAssertFalse(audioManager.isRunning)
    }

    /// Test that stopping audio twice doesn't cause issues (idempotent)
    func testAudioIdempotentStop() {
        let audioManager = BackgroundAudioManager.shared

        audioManager.startBackgroundAudio()
        audioManager.stopBackgroundAudio()
        audioManager.stopBackgroundAudio()
        XCTAssertFalse(audioManager.isRunning, "Should still be stopped after double stop")
    }

    /// Test wasInterrupted tracking
    func testAudioInterruptionTracking() {
        let audioManager = BackgroundAudioManager.shared

        // Initially no interruption
        XCTAssertFalse(audioManager.wasInterrupted, "Should not be interrupted initially")

        // Start audio — wasInterrupted should reset
        audioManager.startBackgroundAudio()
        XCTAssertFalse(audioManager.wasInterrupted, "Should not be interrupted after fresh start")

        audioManager.stopBackgroundAudio()
    }

    // MARK: - Background Location Tests

    /// Test location service starts and stops, tracking isRunning state
    func testLocationServiceLifecycle() {
        let locationManager = BackgroundLocationManager.shared

        // Initial state
        XCTAssertFalse(locationManager.isRunning, "Location should not be running initially")

        // Start location updates
        locationManager.startBackgroundLocation(reason: .workoutRecording)

        // Whether isRunning becomes true depends on authorization status,
        // but calling start should not crash
        let isRunning = locationManager.isRunning

        // Stop location updates
        locationManager.stopBackgroundLocation()
        XCTAssertFalse(locationManager.isRunning, "Location should not be running after stop")

        // If it was running, verify it stopped
        if isRunning {
            XCTAssertFalse(locationManager.isRunning)
        }
    }

    /// Test that stopping location twice doesn't cause issues (idempotent)
    func testLocationIdempotentStop() {
        let locationManager = BackgroundLocationManager.shared

        locationManager.startBackgroundLocation(reason: .workoutRecording)
        locationManager.stopBackgroundLocation()
        locationManager.stopBackgroundLocation()
        XCTAssertFalse(locationManager.isRunning, "Should still be stopped after double stop")
    }

    /// Test canUseLocationServices property is accessible
    func testLocationCanUseServices() {
        let locationManager = BackgroundLocationManager.shared
        // Should not crash — just verifying the property exists and is accessible
        _ = locationManager.canUseLocationServices
    }

}
