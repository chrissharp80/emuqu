import Foundation
import os

// The hallucination guard's memory across turns: the corrections it made,
// carried into the next prompt so the model learns what it got wrong.
extension MetricsVerifier {
    // MARK: - Pending corrections (cross-turn feedback)
    //
    // The hallucination guard substitutes the correct number into the
    // spoken output, but nothing in that tells the MODEL it fabricated, so
    // it repeats the fabrication on the next turn. This buffer carries
    // corrections forward so the next turn's system prompt can
    // include "you fabricated HR=72 last turn — actual was 91; call
    // get_workout_live for HR, don't guess."
    //
    // A correction is retired only once a reply to a prompt that carried
    // it has come back, not when the prompt is composed: a send that
    // fails and is re-composed for a fallback provider must carry the
    // reminder again. `pendingCorrectionsBlock` moves pending entries to
    // `delivered` without dropping them; `verifyAppStateClaims`, which
    // every caller runs on each reply the model produces, retires the
    // delivered ones. A single fabrication still produces one reminder
    // per reply, not a perpetual one.
    //
    // Process-local; cleared on app launch and when the conversation is
    // cleared (`clearCorrections`). Lock-guarded since
    // both the speaker thread (writes) and the AssistantViewModel
    // dispatch path (reads) hit it.

    private struct CorrectionBuffer {
        /// Recorded, not yet put in a prompt.
        var pending: [Discrepancy] = []
        /// Put in a prompt whose reply has not come back yet.
        var delivered: [Discrepancy] = []
    }

    private static let corrections = OSAllocatedUnfairLock<CorrectionBuffer>(initialState: CorrectionBuffer())

    /// Record discrepancies caught by the hallucination guard so the
    /// next AI turn's system prompt can warn the model. Caps at 4
    /// entries to keep the reminder short — a model fabricating > 4
    /// numbers in one turn has bigger problems than this hint can
    /// fix. In voice mode the same claim is caught twice — in the spoken
    /// chunk and in the saved chat turn — so a correction already pending
    /// for the same metric, claim and value is not added again.
    static func recordCorrections(_ discrepancies: [Discrepancy]) {
        guard !discrepancies.isEmpty else { return }
        corrections.withLock { buffer in
            for d in discrepancies where !buffer.pending.contains(where: {
                $0.metric == d.metric && $0.claimed == d.claimed && $0.actual == d.actual
            }) {
                buffer.pending.append(d)
            }
            if buffer.pending.count > 4 { buffer.pending = Array(buffer.pending.suffix(4)) }
        }
    }

    /// The reminder for the prompt being composed: every correction not yet
    /// answered by a reply, or nil when there is none. Called by
    /// `AssistantSystemPrompt.compose` for every send. Does not retire
    /// anything, so a re-composed prompt (fallback provider, a test
    /// composing a prompt) carries the same reminder.
    static func pendingCorrectionsBlock() -> String? {
        let shown = corrections.withLock { buffer in
            buffer.delivered = Array((buffer.delivered + buffer.pending).suffix(4))
            buffer.pending = []
            return buffer.delivered
        }
        return correctionsBlock(shown)
    }

    /// Render every correction and empty the buffer, delivered or not.
    /// Returns nil when there's nothing to surface. The one-shot form,
    /// for a caller that owns the whole cycle (tests resetting state).
    static func consumePendingCorrectionsBlock() -> String? {
        let drained = corrections.withLock { buffer in
            defer { buffer = CorrectionBuffer() }
            return Array((buffer.delivered + buffer.pending).suffix(4))
        }
        return correctionsBlock(drained)
    }

    /// Drop every correction, delivered or not. Called when the conversation
    /// is cleared: the replies they correct are gone, and the first prompt of
    /// the next conversation must not tell the model it said something it
    /// never said there.
    static func clearCorrections() {
        corrections.withLock { $0 = CorrectionBuffer() }
    }

    /// A reply has come back, so the model has seen every delivered
    /// reminder: retire them. Pending ones (recorded after the prompt was
    /// composed) wait for the next prompt.
    static func acknowledgeDeliveredCorrections() {
        corrections.withLock { $0.delivered = [] }
    }

    /// One short system-prompt section: the rule, then one line per
    /// correction. Nil for none.
    private static func correctionsBlock(_ list: [Discrepancy]) -> String? {
        guard !list.isEmpty else { return nil }
        var lines: [String] = [
            "# Last turn correction — DO NOT FABRICATE",
            """
                Your previous response contained numbers that contradicted live data. The saved reply was corrected, but the user may already have read or heard the wrong number — if it matters, correct it briefly. For any of these metrics next \
                turn, CALL the appropriate tool (get_workout_live for HR / pace / location, get_training_load for TSB / ATL / CTL / ACWR, get_sleep for sleep duration / efficiency, lookup_fact for resting HR / HRV) and quote what comes back — never estimate or interpolate.
                """
        ]
        for d in list {
            lines.append("• You said \(d.metric)=\(d.claimed) — actual was \(d.actual).")
        }
        return lines.joined(separator: "\n")
    }
}
