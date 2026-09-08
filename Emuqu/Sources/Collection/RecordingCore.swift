import Foundation

// MARK: - Recording Core
//
// Shared substrate for anything that records a session backed by an HRVSession:
// HRV (overnight/nap/quick/breathe) and workouts all need the same handful of
// services — Polar BLE, archive persistence, CloudKit sync, HealthKit access.
//
// This protocol is the single "logical location" for those shared dependencies.
// RRCollector conforms to it (see RRCollector+RecordingCore.swift) so the
// existing HRV pipeline keeps working unchanged, and new recorders
// (WorkoutRecorder) depend on the protocol rather than on RRCollector directly.
//
// Intentionally narrow: only the capabilities every recorder needs. Recorder-
// specific state (overnight device-refinement, workout GPS, etc.) lives on the
// concrete recorders, not here.
//
// @MainActor because every conformer (RRCollector today) is itself MainActor-
// isolated, and the consumers (WorkoutRecorder, view models) all touch this
// from the main actor. Without the annotation Swift 6 flags the conformance
// as a data race risk.
@MainActor
protocol RecordingCore: AnyObject {
    /// BLE device controller (H10, Verity Sense).
    var polarManager: PolarManager { get }

    /// HealthKit read/write (workouts, sleep, vitals).
    var healthKit: HealthKitManager { get }

    /// On-disk session archive.
    var archive: SessionArchive { get }

    /// CloudKit synchronization.
    var cloudSyncManager: CloudKitSyncManager { get }

    /// Append-only raw RR backup. Shared across recorders so crash-recovery
    /// (SessionRecoveryService) can enumerate everything the device has
    /// captured — HRV AND workout — from one place. Workouts additionally
    /// lean on it for the "don't lose my 4-mile walk" guarantee: every ~60s
    /// during a workout we append the latest beats here before attempting
    /// CloudKit upload, so an iOS kill or crash can be restored from disk.
    var rawBackup: RawRRBackup { get }

    /// Shared HRV analysis pipeline — workouts use the same time-domain /
    /// frequency-domain / DFA machinery as overnight sessions; what differs is
    /// the window and downstream interpretation, not the analysis itself.
    var analysisPipeline: HRVAnalysisPipeline { get }

    /// Called after a session is archived so downstream observers (dashboard,
    /// trends, history) re-render. Currently backed by RRCollector's
    /// `archiveVersion` observable counter.
    func notifyArchiveChanged()
}
