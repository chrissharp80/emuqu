import Foundation

extension RRCollector {
    /// Whose recording the strap holds, and the checks against it.
    var strapGuards: StrapRecordingGuards {
        StrapRecordingGuards(
            sessionState: sessionState, streamingLifecycle: streamingLifecycle, polarManager: polarManager,
            recordingStore: recordingStore, archive: archive, rawBackup: rawBackup, recorderBox: services.recorderBox
        )
    }

    /// The services this collector records with, for a workout recorder to
    /// record with too.
    var recordingCore: RecordingCore {
        RecordingCore(
            polarManager: polarManager, healthKit: healthKit, archive: archive,
            cloudSyncManager: cloudSyncManager, rawBackup: rawBackup,
            analysisPipeline: analysisPipeline, archiveSignal: archiveSignal
        )
    }
}
