import Foundation
import os

/// The session files that could not be read while one tool call resolved.
/// `SessionArchive.retrieveOrLog` and `retrieveLightweightOrLog` report
/// each failure here, so the assistant can tell "the user has no data"
/// from "the data is there but could not be read just now".
final class SessionReadFailures: Sendable {
    private let failures = OSAllocatedUnfairLock(initialState: 0)

    var count: Int { failures.withLock { $0 } }

    func record() {
        failures.withLock { $0 += 1 }
    }
}

/// The failure log of the tool call resolving on this task, nil outside one.
enum SessionReadWatch {
    @TaskLocal static var failures: SessionReadFailures?
}

extension FactValue {
    /// This answer once `unread` session files it needed could not be
    /// read. A "no data" answer becomes `.unreadable`, so the model does not
    /// tell the user they recorded nothing; any other answer carries the
    /// count, so totals and lists are not taken as complete.
    func accountingFor(unreadSessions unread: Int) -> FactValue {
        guard unread > 0 else { return self }
        let note = "\(unread) recorded session(s) could not be read just now and are left out"
        switch self {
        case .missing(reason: .notRecorded, _):
            return .missing(reason: .unreadable, detail: note)
        case .missing:
            return self
        case var .record(fields):
            fields["unreadable_sessions"] = .integer(unread)
            fields["unreadable_note"] = .string(note)
            return .record(fields)
        default:
            return .record(["value": self, "unreadable_sessions": .integer(unread), "unreadable_note": .string(note)])
        }
    }
}
