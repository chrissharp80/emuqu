import Foundation

extension RRCollector {
    /// Whose recording the strap holds, and the checks against it.
    var strapGuards: StrapRecordingGuards {
        StrapRecordingGuards(
            sessionState: sessionState, streamingLifecycle: streamingLifecycle,
            strapLink: polarManager.linkState, strapStream: polarManager.stream, strapRecording: polarManager.deviceRecording,
            recordingStore: recordingStore, archive: archive, rawBackup: rawBackup, recorderBox: services.recorderBox
        )
    }

    /// The services this collector records with, for a workout recorder to
    /// record with too.
    var recordingCore: RecordingCore {
        RecordingCore(
            strapLink: polarManager.linkState, strapStream: polarManager.stream,
            strapRecording: polarManager.deviceRecording, strapRecorder: polarManager.recording,
            strapDiscovery: polarManager.discovery, strapBattery: polarManager.battery,
            strapPairings: polarManager.pairings, recordScreenLifecycle: streamingLifecycle, healthAccess: healthKit.access, heartRate: healthKit.heartRate,
            training: healthKit.training, healthSampleStore: healthKit.sampleReplacer.store, archive: archive,
            cloudSyncManager: cloudSyncManager, rawBackup: rawBackup,
            analysisPipeline: analysisPipeline, archiveSignal: archiveSignal
        )
    }
}
