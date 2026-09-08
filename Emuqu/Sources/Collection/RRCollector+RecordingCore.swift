import Foundation

// MARK: - RecordingCore Conformance
//
// RRCollector already owns PolarManager, HealthKit, SessionArchive,
// CloudKitSyncManager, and HRVAnalysisPipeline. Declaring conformance here
// lets new recorders (WorkoutRecorder) depend on the RecordingCore protocol
// instead of on RRCollector directly — keeps the shared substrate explicit
// without rearranging the existing HRV pipeline.
extension RRCollector: RecordingCore {}
