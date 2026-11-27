import Foundation

// What the user wrote on a session (tags, notes, the morning feeling and the
// perceived readiness) when it is folded into another: a same-night merge, or
// a duplicate copy retired into its keeper (`ArchiveMigrations`). Both carry
// it the same way, so an answer given on either copy is not lost.

extension SessionMerger {
    /// The imported side's user content the existing session lacks: tags it
    /// does not hold, notes (taken when it has none, appended when both
    /// differ, `mergedNotes`), and the morning feeling and perceived readiness
    /// when it has none. The existing session's own answers stay.
    static func decideUserContent(imported: HRVSession, existing: HRVSession, into outcome: inout MergeOutcome) {
        let existingTagIds = Set(existing.tags.map(\.id))
        outcome.tagsToAppend = imported.tags.filter { !existingTagIds.contains($0.id) }
        outcome.adoptNotes = mergedNotes(existing.notes, imported.notes) != existing.notes
        outcome.adoptMorningFeeling = existing.morningFeeling == nil && imported.morningFeeling != nil
        outcome.adoptPerceivedReadiness = existing.perceivedReadiness == nil && imported.perceivedReadiness != nil
    }

    /// Apply what `decideUserContent` decided. The feeling's tags come with
    /// the feeling, unless the existing session already holds some.
    static func applyUserContent(_ outcome: MergeOutcome, from imported: HRVSession, to existing: inout HRVSession) {
        existing.tags.append(contentsOf: outcome.tagsToAppend)
        if outcome.adoptNotes { existing.notes = mergedNotes(existing.notes, imported.notes) }
        if outcome.adoptMorningFeeling {
            existing.morningFeeling = imported.morningFeeling
            existing.morningFeelingTags = existing.morningFeelingTags ?? imported.morningFeelingTags
        }
        if outcome.adoptPerceivedReadiness { existing.perceivedReadiness = imported.perceivedReadiness }
    }

    /// Carry only the user content of `loser` into `keeper`. False when
    /// nothing changed. The keeper's sleep and window edits stay its own:
    /// they belong to the analysis its score was computed from.
    static func carryUserContent(from loser: HRVSession, into keeper: inout HRVSession) -> Bool {
        var outcome = MergeOutcome()
        decideUserContent(imported: loser, existing: keeper, into: &outcome)
        applyUserContent(outcome, from: loser, to: &keeper)
        return outcome.hasChanges
    }

    /// The keeper's notes with the other copy's: the copy's when the keeper
    /// has none, both, blank-line apart, when they differ. Unchanged when the
    /// keeper's paragraphs already hold the copy's notes whole: a copy carried
    /// again (a duplicate whose file could not be moved, a segment archived a
    /// second time) must not have its notes appended a second time.
    static func mergedNotes(_ keeper: String?, _ loser: String?) -> String? {
        guard let loser, !loser.isEmpty, loser != keeper else { return keeper }
        guard let keeper, !keeper.isEmpty else { return loser }
        let separator = "\n\n"
        guard !(separator + keeper + separator).contains(separator + loser + separator) else { return keeper }
        return keeper + separator + loser
    }
}
