import Foundation

// The session-merge decision lives in `SessionMerger`.
//
// These forwarders keep the archive's own call sites and the
// `ArchivePolicyTests` suite working unchanged. `MergeOutcome` is re-exported
// as a typealias for the same reason.

extension SessionArchive {
    typealias MergeOutcome = SessionMerger.MergeOutcome

    func mergeSessionData(from imported: HRVSession, into existing: inout HRVSession) -> Bool {
        SessionMerger.mergeSessionData(from: imported, into: &existing)
    }

    static func mergeOutcome(imported: HRVSession, existing: HRVSession) -> MergeOutcome {
        SessionMerger.mergeOutcome(imported: imported, existing: existing)
    }

    static func apply(
        _ outcome: MergeOutcome, from imported: HRVSession, to existing: inout HRVSession
    ) {
        SessionMerger.apply(outcome, from: imported, to: &existing)
    }
}
