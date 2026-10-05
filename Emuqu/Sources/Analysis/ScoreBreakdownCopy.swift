import Foundation

/// The words of a recovery score breakdown, in `NarrativeLanguage`: the
/// one-paragraph advice (`ScoreBreakdown.message`) and the penalty lines.
///
/// Factor labels are fixed English identifiers ("HRV", "Sleep", "Vitals").
/// English writes them lowercased mid-sentence, as it always has; every other
/// language names the factor as its row is titled, and each translation is
/// phrased so a name dropped in needs no article or agreement.
enum ScoreBreakdownCopy {
    typealias Breakdown = RecoveryScoreCalculator.ScoreBreakdown
    typealias Factor = RecoveryScoreCalculator.ScoreFactor

    /// The English SpO₂ line every record scored before the lines were
    /// localized carries.
    private static let englishSpO2Prefix = "Low blood oxygen"

    static var lowBloodOxygenPenalty: String {
        let points = Int(RecoveryScoreConstants.Vitals.spo2Penalty)
        return String(localized: "Low blood oxygen (−\(points))", bundle: NarrativeLanguage.bundle)
    }

    static var missingSleepPenalty: String {
        let points = Int(RecoveryScoreConstants.missingSleepPenalty)
        return String(localized: "No sleep data (−\(points))", bundle: NarrativeLanguage.bundle)
    }

    /// Whether English penalty lines include the SpO₂ deduction.
    static func listsEnglishSpO2Penalty(_ penalties: [String]) -> Bool {
        penalties.contains { $0.hasPrefix(englishSpO2Prefix) }
    }

    /// A stored penalty line in the app language: the English lines written
    /// before localization are re-worded; anything else is shown as stored.
    static func displayPenalty(_ line: String) -> String {
        if line.hasPrefix(englishSpO2Prefix) { return lowBloodOxygenPenalty }
        if line.hasPrefix("No sleep data (") { return missingSleepPenalty }
        return line
    }

    static func message(for breakdown: Breakdown) -> String {
        let weakest = breakdown.factors.min(by: { $0.score < $1.score })
        let strongest = breakdown.factors.max(by: { $0.score < $1.score })
        if let penalised = vitalsPenaltyMessage(breakdown, weakest: weakest) { return penalised }
        if let drifted = baselineDriftMessage(breakdown) { return drifted }
        return bandMessage(breakdown, weakest: weakest, strongest: strongest)
    }

    // MARK: - Penalties and drift

    /// When a penalty is dragging the score below what the factors alone
    /// would give, say which one and by how much. The SpO₂ wording is used
    /// only when the SpO₂ penalty is the only one that applied.
    private static func vitalsPenaltyMessage(_ breakdown: Breakdown, weakest: Factor?) -> String? {
        guard !breakdown.penalties.isEmpty, breakdown.gapFromFactors > 1 else { return nil }
        let points = Int(breakdown.gapFromFactors)
        let onlySpO2 = breakdown.spo2PenaltyApplied && breakdown.penalties.count == 1
        if breakdown.factors.allSatisfy({ $0.score >= 60 }) {
            guard !onlySpO2 else {
                return String(localized: "Your component scores are strong, but a SpO₂ reading below 95% reduced your score by \(points) points. Check the SpO₂ value in your vitals.", bundle: NarrativeLanguage.bundle)
            }
            let list = penaltyList(breakdown.penalties)
            return String(localized: "Your component scores are strong, but \(list) reduced your score by \(points) points.", bundle: NarrativeLanguage.bundle)
        }
        if let w = weakest, w.score < 60 {
            let name = midSentenceName(w.label)
            return String(localized: "Penalties (−\(points)) plus weak \(name) are holding your score back.", bundle: NarrativeLanguage.bundle)
        }
        return String(localized: "Good component scores, but penalties reduced your composite by \(points) points.", bundle: NarrativeLanguage.bundle)
    }

    /// The penalty names without their point values, joined for mid-sentence
    /// use: "low blood oxygen and no sleep data".
    private static func penaltyList(_ penalties: [String]) -> String {
        let names = penalties.map(displayPenalty).map { $0.components(separatedBy: " (").first ?? $0 }
        guard isEnglish else { return localeList(names) }
        return names.map { $0.prefix(1).lowercased() + $0.dropFirst() }.joined(separator: " and ")
    }

    /// A gap between factor scores and composite WITHOUT penalties happens
    /// for legacy sessions where baselines shifted since acceptance. The
    /// factor scores reflect current baselines, but the composite is the
    /// original frozen score — don't claim a penalty that doesn't exist.
    private static func baselineDriftMessage(_ breakdown: Breakdown) -> String? {
        guard breakdown.gapFromFactors > 5, breakdown.penalties.isEmpty,
              breakdown.factors.allSatisfy({ $0.score >= 60 }) else { return nil }
        return String(localized: "Your baselines have improved since this session. Today those same HRV and sleep numbers score higher, but this score reflects how you compared at the time.", bundle: NarrativeLanguage.bundle)
    }

    // MARK: - Bands

    /// The bands are `ScoreVerdict`'s, the word shown above this message:
    /// on 80/60/40 a 82 read "Good — normal training is fine" over "Go
    /// hard", and a 42 read "Low" over the middle band's message.
    private static func bandMessage(_ breakdown: Breakdown, weakest: Factor?, strongest: Factor?) -> String {
        let shown = breakdown.compositeScore.rounded()
        if shown >= 75 { return strongBandMessage(breakdown, weakest: weakest) }
        if shown >= 60 { return decentBandMessage(weakest: weakest, strongest: strongest) }
        if shown >= 45 { return mediocreBandMessage(weakest: weakest) }
        return lowBandMessage(weakest: weakest)
    }

    /// Everything is strong (the Good and Excellent verdicts), and no
    /// vitals penalties applied. "Go hard" is for Excellent only.
    ///
    /// A composite ≥ 80 can be carried by sleep and vitals while HRV
    /// itself sits under baseline (seen live: HRV 71 at −19 % vs
    /// baseline, sleep 95, vitals 96 → 81, "Go hard" two lines above
    /// "Below your baseline — pay attention"). HRV is the primary signal,
    /// so the HRV factor must be at or above its baseline score (72, the
    /// flat z = 0 band) for either of the all-clear lines. Only the
    /// factors this tier actually has are named.
    private static func strongBandMessage(_ breakdown: Breakdown, weakest: Factor?) -> String {
        if let w = weakest, w.score < 60 {
            let name = midSentenceName(w.label)
            return String(localized: "Strong overall, but \(name) is holding you back. Fix that and you're flying.", bundle: NarrativeLanguage.bundle)
        }
        let others = breakdown.factors.filter { $0.label != "HRV" }
        if let hrv = breakdown.factors.first(where: { $0.label == "HRV" }), hrv.score < 72, !others.isEmpty {
            return carriersMessage(others)
        }
        return allClearMessage(breakdown)
    }

    /// The factors other than HRV hold the score up while HRV is under its
    /// usual level.
    private static func carriersMessage(_ others: [Factor]) -> String {
        let carriers = sentenceCase(listPhrase(others.map { midSentenceName($0.label) }))
        guard others.count > 1 else {
            return String(localized: "\(carriers) is carrying the score while HRV sits under its usual level. A good day for normal training, not a green light to go hard.", bundle: NarrativeLanguage.bundle)
        }
        return String(localized: "\(carriers) are carrying the score while HRV sits under its usual level. A good day for normal training, not a green light to go hard.", bundle: NarrativeLanguage.bundle)
    }

    /// Every factor is strong, HRV included.
    private static func allClearMessage(_ breakdown: Breakdown) -> String {
        let all = listPhrase(breakdown.factors.map { midSentenceName($0.label) })
        let single = breakdown.factors.count <= 1
        guard breakdown.compositeScore.rounded() >= 90 else {
            let subject = sentenceCase(all)
            return single
                ? String(localized: "\(subject) is in a good place. Normal training is fine.", bundle: NarrativeLanguage.bundle)
                : String(localized: "\(subject) are all in a good place. Normal training is fine.", bundle: NarrativeLanguage.bundle)
        }
        return single
            ? String(localized: "Everything is clicking — \(all) is dialed in. Go hard.", bundle: NarrativeLanguage.bundle)
            : String(localized: "Everything is clicking — \(all) are all dialed in. Go hard.", bundle: NarrativeLanguage.bundle)
    }

    /// Composite is decent but something is weak.
    ///
    /// When the weakest factor is training load, "Address that to break
    /// through" is misleading: a heavy week of training legitimately
    /// depresses TSB and the right action is to RESPECT the fatigue, not
    /// "address" it. Other factors keep the actionable wording — they ARE
    /// actionable.
    private static func decentBandMessage(weakest: Factor?, strongest: Factor?) -> String {
        guard let w = weakest, w.score < 45, let s = strongest else {
            return String(localized: "Decent recovery overall. Check the component scores — the lowest one is your bottleneck.", bundle: NarrativeLanguage.bundle)
        }
        let carrier = startName(s.label)
        if w.label == "Training Load" {
            return String(localized: "\(carrier) is carrying you, but you're carrying real training fatigue — that's expected during a build. Take it easier today and let the load come off.", bundle: NarrativeLanguage.bundle)
        }
        let drag = midSentenceName(w.label)
        return String(localized: "\(carrier) is carrying you but \(drag) is dragging the score down. Address that to break through.", bundle: NarrativeLanguage.bundle)
    }

    private static func mediocreBandMessage(weakest: Factor?) -> String {
        guard let w = weakest, w.score < 40 else {
            return String(localized: "Incomplete recovery. Multiple factors are mediocre — no single fix, focus on the weakest.", bundle: NarrativeLanguage.bundle)
        }
        if w.label == "Training Load" {
            return String(localized: "You're heavily fatigued from recent training. Today's an easy day — short walk or full rest, not intervals.", bundle: NarrativeLanguage.bundle)
        }
        let name = midSentenceName(w.label)
        return String(localized: "Your \(name) score is pulling your recovery down. That's what needs to change.", bundle: NarrativeLanguage.bundle)
    }

    private static func lowBandMessage(weakest: Factor?) -> String {
        guard let w = weakest, w.score < 30 else {
            return String(localized: "Recovery is poor across the board. Rest and recover before pushing anything.", bundle: NarrativeLanguage.bundle)
        }
        let name = startName(w.label)
        return String(localized: "\(name) is critically low and tanking your score. Prioritize that above everything.", bundle: NarrativeLanguage.bundle)
    }

    // MARK: - Factor names

    private static var isEnglish: Bool {
        NarrativeLanguage.locale.language.languageCode == .english
    }

    /// The factor's name inside a sentence: "sleep", "HRV".
    private static func midSentenceName(_ label: String) -> String {
        guard isEnglish else { return catalogName(label) }
        return label == "HRV" ? label : label.lowercased()
    }

    /// The factor's name opening a sentence: "Sleep", "HRV".
    private static func startName(_ label: String) -> String {
        isEnglish ? label : catalogName(label)
    }

    /// The factor's row title.
    private static func catalogName(_ label: String) -> String {
        switch label {
        case "HRV": String(localized: "HRV", bundle: NarrativeLanguage.bundle)
        case "Sleep": String(localized: "Sleep", bundle: NarrativeLanguage.bundle)
        case "Vitals": String(localized: "Vitals", bundle: NarrativeLanguage.bundle)
        case "Training Load": String(localized: "Training Load", bundle: NarrativeLanguage.bundle)
        default: label
        }
    }

    /// "a", "a and b", "a, b, and c" in English; the language's own list
    /// otherwise.
    private static func listPhrase(_ items: [String]) -> String {
        guard isEnglish else { return localeList(items) }
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        let head = items.dropLast()
        return head.count == 1 ? "\(head.first ?? "") and \(last)" : head.joined(separator: ", ") + ", and \(last)"
    }

    /// "a, b and c" as `NarrativeLanguage.locale` writes a list.
    private static func localeList(_ items: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = NarrativeLanguage.locale
        return formatter.string(from: items) ?? items.joined(separator: ", ")
    }

    private static func sentenceCase(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
