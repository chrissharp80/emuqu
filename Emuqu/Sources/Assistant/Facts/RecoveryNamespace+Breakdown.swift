import Foundation

// The stored score breakdown of a night: why a recovery score came out as
// it did. Read from what was frozen on the session at scoring time, never
// recomputed, so it always explains the score the user saw.

extension RecoveryNamespace {
    /// Whether a value is a record, for keeping the nights that gave one.
    static func isRecord(_ value: FactValue) -> Bool {
        if case .record = value { return true }
        return false
    }

    /// The breakdown in brief for every score record: the tier and each
    /// factor's sub-score, weight and weighted contribution. Empty for a
    /// night scored before breakdowns were stored.
    static func breakdownSummary(_ session: HRVSession) -> [String: FactValue] {
        guard let breakdown = session.scoreBreakdown else { return [:] }
        let factors: [FactValue] = breakdown.factors.map { factor in
            .record([
                "label": .string(factor.label), "score": .double(factor.score),
                "weight": .double(factor.weight), "contribution": .double(factor.contribution)
            ])
        }
        return ["score_tier": .integer(breakdown.tier), "factor_scores": .list(factors)]
    }

    /// The full stored breakdown, in English for the model: every factor
    /// with its detail line and impact, the penalties, and the gap between
    /// the factors' weighted sum and the composite.
    static func breakdownRecord(for session: HRVSession?) -> FactValue {
        guard let session else { return .missing(reason: .notRecorded, detail: "no overnight session matched") }
        guard let breakdown = session.scoreBreakdown else {
            return .missing(reason: .notRecorded, detail: "no score breakdown stored on this night (not scored, or scored before breakdowns were saved)")
        }
        var record: [String: FactValue] = [
            "date": .date(session.startDate),
            "composite_score": .double(breakdown.compositeScore),
            "tier": .integer(breakdown.tier),
            "factors": .list(breakdown.factors.map(factorRecord)),
            "penalties": .list(NarrativeLanguage.english { breakdown.displayPenalties }.map(FactValue.string)),
            "spo2_penalty_applied": .boolean(breakdown.spo2PenaltyApplied),
            "scoring_version": .string(breakdown.scoringVersion),
            "gap_from_factors": .double(breakdown.gapFromFactors)
        ]
        record["score"] = scoreFields(session)["score"]
        return OvernightArchive.labeled(.record(record), session)
    }

    private static func factorRecord(_ factor: RecoveryScoreCalculator.ScoreFactor) -> FactValue {
        .record([
            "label": .string(factor.label),
            "detail": .string(NarrativeLanguage.english { factor.displayDetail(temperatureUnit: .celsius) }),
            "score": .double(factor.score),
            "weight": .double(factor.weight),
            "contribution": .double(factor.contribution),
            "impact": .string(factor.impact.rawValue)
        ])
    }

    var recoveryBreakdownByDateEntry: FactEntry {
        .parameterized(
            pattern: "recovery.breakdown.by_date($date)",
            paramExample: "2026-04-21",
            description: """
            Why the recovery score was what it was on a local date (yyyy-MM-dd): the score breakdown stored when the night was scored. Use for 'why was my score low on February 20', 'what pulled my recovery down', \
            'how much did sleep count', 'was there a penalty'. tier is the scoring tier (1 HRV only, 2 HRV + sleep, 3 HRV + sleep + vitals); factors lists each factor (HRV, sleep, vitals) with label, detail, \
            score (0-100 sub-score), weight (0-1), contribution (score x weight) and impact (positive / neutral / negative); penalties lists each deduction in words; spo2_penalty_applied says whether the flat \
            blood-oxygen deduction was taken; composite_score is the stored 0-100 composite, score the dashboard's 0-100 number; gap_from_factors is how far the factors' weighted sum sits above the composite \
            (positive: something outside the factors, such as a penalty, pulled the score down); scoring_version names the algorithm. \(RecordFields.sentence(RecordFields.recoveryBreakdown))
            """,
            availability: { OvernightArchive.availability(self.archive) },
            resolve: { param, _ in
                Self.breakdownRecord(for: OvernightArchive.anyByDate(param, archive: self.archive, scoredOnly: true))
            }
        )
    }
}
