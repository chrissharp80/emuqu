//
//  HolisticDailyReport+Score.swift
//  Emuqu
//
//  The readiness composite behind page 2 — how the number is arrived at,
//  and what it is that helped or hurt it. Split out of HolisticDailyReport
//  to keep that file under 1000 lines; the drawing code stays there and
//  only the arithmetic lives here.
//

import CoreLocation
import Foundation
import PDFKit
import UIKit

extension HolisticDailyReport {
    /// One stat in the two "at a glance" columns: a caption, the number, and
    /// an optional coloured reading underneath it.
    ///
    /// A named type rather than a bare `(String, String, String?, UIColor?)`:
    /// two of the four positions share a type, so `row.2` and `row.3` would
    /// be the only thing keeping the sub-line and its colour apart.
    struct GlanceRow {
        let label: String
        let value: String
        let sub: String?
        let subColour: UIColor?

        init(_ label: String, _ value: String, _ sub: String?, _ subColour: UIColor?) {
            self.label = label
            self.value = value
            self.sub = sub
            self.subColour = subColour
        }
    }

    struct ScoreContribution {
        let name: String
        let score: Double // 0-10
        let weight: Double // 0-1
        let note: String
    }

    func combinedReadinessScore() -> (value: Double, tier: String, contributions: [ScoreContribution]) {
        // Two paths, and the difference matters: a frozen breakdown is what the
        // Dashboard pill showed, so the PDF must reproduce it rather than
        // recompute. Only archives predating the breakdown take the legacy path.
        if let breakdown = overnightSession?.scoreBreakdown {
            return frozenReadinessScore(breakdown)
        }
        return legacyReadinessScore()
    }

    /// Canonical path: the session's frozen breakdown, so the PDF and the
    /// Dashboard pill are mathematically identical. ScoreBreakdown stores the
    /// composite and factor scores on 0–100; this PDF shows 0–10.
    ///
    /// The stored label ("HRV", "Sleep", "Vitals") is an English catalog key,
    /// shown in the app's language. The detail line is rebuilt from the
    /// factor's stored numbers in the app's language and the user's
    /// temperature unit.
    private func frozenReadinessScore(_ breakdown: RecoveryScoreCalculator.ScoreBreakdown) -> (value: Double, tier: String, contributions: [ScoreContribution]) {
        let value = breakdown.compositeScore / 10.0
        let bundle = LanguageManager.appBundle
        let contribs: [ScoreContribution] = breakdown.factors.map { factor in
            ScoreContribution(
                name: bundle.localizedString(forKey: factor.label, value: factor.label, table: nil),
                score: factor.score / 10.0,
                weight: factor.weight,
                note: factor.displayDetail(temperatureUnit: temperatureUnit)
            )
        }
        let tier = readinessTier(for: value, loadLevel: adviceLoad().level, goHardAllowed: Self.allowsGoHard(breakdown))
        return (value, tier, contribs)
    }

    /// The app says "Go hard" only for an Excellent score (rounded composite
    /// 90 or more) with no vitals penalty, no factor under 60, and HRV at or
    /// above its baseline score of 72 (`ScoreBreakdown`'s strong-band
    /// message), and only when the training advice gate finds the load
    /// clear (`readinessTier`). Page 2's top tier follows the same rule, so
    /// the PDF never prescribes a hard day the app's own verdict holds back.
    static func allowsGoHard(_ breakdown: RecoveryScoreCalculator.ScoreBreakdown) -> Bool {
        guard breakdown.compositeScore.rounded() >= 90, breakdown.penalties.isEmpty else { return false }
        if let hrv = breakdown.factors.first(where: { $0.label == "HRV" }), hrv.score < 72 { return false }
        return breakdown.factors.allSatisfy { $0.score >= 60 }
    }

    /// The shared training advice gate's read of the same live load the
    /// rest of the report prints. The composite can sit above the "go hard"
    /// threshold on excellent HRV and sleep while the recent load spikes; the
    /// gate decides how far the prescription may go.
    func adviceLoad() -> TrainingAdviceGate.Assessment {
        TrainingAdviceGate.assess(adviceGateLoad())
    }

    /// The load the gate reads: the live snapshot (with its Foster monotony)
    /// when the report has one, else the frozen session load, the same
    /// precedence as `trainingLoadForReport`. The daily loop reads it too.
    func adviceGateLoad() -> TrainingAdviceGate.Load? {
        .preferring(live: liveLoadSnapshot, frozen: workoutSession.trainingSnapshot ?? overnightSession?.trainingSnapshot)
    }

    /// Legacy recompute for sessions without a frozen breakdown. Kept so old
    /// archives still render something instead of a blank section. New sessions
    /// never hit this path.
    private func legacyReadinessScore() -> (value: Double, tier: String, contributions: [ScoreContribution]) {
        let bundle = LanguageManager.appBundle
        let contribs: [ScoreContribution] = [
            legacyHRVContribution(bundle: bundle),
            legacySleepContribution(bundle: bundle),
            legacyFreshnessContribution(bundle: bundle),
            legacyCardiovascularContribution(bundle: bundle)
        ]
        // Weighted sum
        let total = contribs.reduce(0.0) { $0 + $1.score * $1.weight }
        return (total, readinessTier(for: total, loadLevel: adviceLoad().level), contribs)
    }

    private func legacyHRVContribution(bundle: Bundle) -> ScoreContribution {
        // HRV vs baseline (35%)
        var hrvScore: Double = 5
        var hrvNote = String(localized: "No baseline yet — need 3+ overnight sessions", bundle: bundle)
        if let baseline = analysis().recoveryBaselineRMSSD,
           let pct = analysis().hrvPercentVsBaseline {
            // Map -20% .. +20% to 0 .. 10
            hrvScore = min(10, max(0, 5 + pct / 4))
            hrvNote = String(localized: "\(pct >= 0 ? "+" : "")\(String(format: "%.0f", locale: LanguageManager.appLocale, pct))% vs your \(String(format: "%.0f", locale: LanguageManager.appLocale, baseline)) ms baseline", bundle: bundle)
        }
        return ScoreContribution(name: String(localized: "HRV vs baseline", bundle: bundle), score: hrvScore, weight: 0.35, note: hrvNote)
    }

    private func legacySleepContribution(bundle: Bundle) -> ScoreContribution {
        // Sleep quality (25%)
        var sleepScore: Double = 5
        var sleepNote = String(localized: "No sleep data tonight", bundle: bundle)
        if let sleep = overnightSession?.sleepSnapshot {
            let dur = Double(sleep.nightSleepMinutes) / 60.0 // hours
            let durText = String(format: "%.1f", locale: LanguageManager.appLocale, dur)
            // dur 7-8h = full credit; eff 85+ = full credit; unmeasured
            // efficiency gets neutral half credit, as in the Sleep score.
            let durScore = min(10, max(0, (dur - 4) / 3.5 * 10))
            let effScore = sleep.measuredSleepEfficiency.map { min(10, max(0, ($0 - 65) / 30 * 10)) } ?? 5
            sleepScore = durScore * 0.5 + effScore * 0.5
            sleepNote = if let eff = sleep.measuredSleepEfficiency {
                String(localized: "\(durText)h at \(String(format: "%.0f", locale: LanguageManager.appLocale, eff))% efficiency", bundle: bundle)
            } else {
                String(localized: "\(durText)h, efficiency not measured", bundle: bundle)
            }
        }
        return ScoreContribution(name: String(localized: "Sleep quality", bundle: bundle), score: sleepScore, weight: 0.25, note: sleepNote)
    }

    private func legacyFreshnessContribution(bundle: Bundle) -> ScoreContribution {
        // Training freshness via TSB (25%)
        var tsbScore: Double = 5
        var tsbNote = String(localized: "No training-load snapshot", bundle: bundle)
        if let snap = trainingLoadForReport() {
            // Map TSB -25 .. +15 to 0 .. 10 (Friel's productive range)
            tsbScore = min(10, max(0, (snap.tsb + 25) / 40 * 10))
            tsbNote = String(localized: "TSB \(String(format: "%+.1f", locale: LanguageManager.appLocale, snap.tsb)) (CTL \(String(format: "%.1f", locale: LanguageManager.appLocale, snap.ctl)), ATL \(String(format: "%.1f", locale: LanguageManager.appLocale, snap.atl)))", bundle: bundle)
        }
        return ScoreContribution(name: String(localized: "Training freshness", bundle: bundle), score: tsbScore, weight: 0.25, note: tsbNote)
    }

    private func legacyCardiovascularContribution(bundle: Bundle) -> ScoreContribution {
        // Cardiovascular trend / HRR (15%)
        var cvScore: Double = 5
        var cvNote = String(localized: "No HRR captured", bundle: bundle)
        if let one = workoutSession.workoutMetadata?.hrrSamples?.bestAtOneMinute {
            // 1-min HRR: 8 = floor, 30 = ceiling
            cvScore = min(10, max(0, Double(one.drop - 8) / 22 * 10))
            cvNote = String(localized: "Today's 1-min HRR: \(one.drop) bpm", bundle: bundle)
        }
        return ScoreContribution(name: String(localized: "Cardiovascular response", bundle: bundle), score: cvScore, weight: 0.15, note: cvNote)
    }

    /// Map 0–10 readiness to a training-prescription tier. Same bands and
    /// the same load ceiling for both code paths so the verdict line is
    /// consistent regardless of which composite source fired. When the gate
    /// says to ease off (a sharp load increase or heavy accumulated fatigue)
    /// the ceiling is moderate; when it holds the push (load above the usual
    /// range, or monotonous training) there is no "go hard" tier.
    /// `goHardAllowed` is the frozen breakdown's own verdict
    /// (`allowsGoHard`); without it a score in the top band reads as Tier 2.
    private func readinessTier(for value: Double, loadLevel: TrainingAdviceGate.LoadLevel, goHardAllowed: Bool = true) -> String {
        let bundle = LanguageManager.appBundle
        if loadLevel == .easier {
            // Ceiling at Tier 3 ("moderate only") regardless of the
            // underlying composite. The lower tiers still apply if the
            // composite itself argues for them.
            if value >= 5.5 { return String(localized: "Tier 3 — moderate only (load elevated)", bundle: bundle) }
            if value >= 3.5 { return String(localized: "Tier 4 — easy aerobic", bundle: bundle) }
            return String(localized: "Tier 5 — rest", bundle: bundle)
        }
        if value >= 8.5, goHardAllowed, loadLevel == .clear { return String(localized: "Tier 1 — go hard", bundle: bundle) }
        if value >= 7.0 { return String(localized: "Tier 2 — quality OK", bundle: bundle) }
        if value >= 5.5 { return String(localized: "Tier 3 — moderate only", bundle: bundle) }
        if value >= 3.5 { return String(localized: "Tier 4 — easy aerobic", bundle: bundle) }
        return String(localized: "Tier 5 — rest", bundle: bundle)
    }

    func whatsHelpingPoints() -> [String] {
        let bundle = LanguageManager.appBundle
        var out: [String] = []
        if let pct = analysis().hrvPercentVsBaseline, pct >= 5 {
            out.append(String(localized: "HRV is \(Int(pct.rounded()))% above your recent baseline — strong autonomic state.", bundle: bundle))
        }
        if let sleep = overnightSession?.sleepSnapshot,
           let efficiency = sleep.measuredSleepEfficiency, efficiency >= 90,
           sleep.nightSleepMinutes >= 7 * 60 {
            out.append(String(localized: "Sleep was \(sleep.nightSleepMinutes / 60)h with \(Int(efficiency.rounded()))% efficiency — consolidated, restorative.", bundle: bundle))
        }
        if let snap = trainingLoadForReport() {
            if let acwr = snap.acuteChronicRatio, acwr >= 0.8, acwr < 1.3 {
                out.append(String(localized: "ACWR \(String(format: "%.2f", locale: LanguageManager.appLocale, acwr)) — productive load band, sustainable volume.", bundle: bundle))
            }
            if snap.tsb > 5 { out.append(String(localized: "TSB \(String(format: "%+.1f", locale: LanguageManager.appLocale, snap.tsb)) — fresh, ready for quality work.", bundle: bundle)) }
        }
        if let one = workoutSession.workoutMetadata?.hrrSamples?.bestAtOneMinute, one.drop >= 18 {
            out.append(String(localized: "HRR \(one.drop) bpm — vagal recovery on point.", bundle: bundle))
        }
        return out
    }

    func whatsHurtingPoints() -> [String] {
        let bundle = LanguageManager.appBundle
        return hurtingHRVPoints(bundle: bundle)
            + hurtingSleepPoints(bundle: bundle)
            + hurtingLoadPoints(bundle: bundle)
    }

    private func hurtingHRVPoints(bundle: Bundle) -> [String] {
        var out: [String] = []
        if let pct = analysis().hrvPercentVsBaseline, pct <= -10 {
            out.append(String(localized: "HRV is \(Int(abs(pct).rounded()))% below baseline.", bundle: bundle))
        }
        return out
    }

    private func hurtingSleepPoints(bundle: Bundle) -> [String] {
        var out: [String] = []
        if let sleep = overnightSession?.sleepSnapshot {
            if sleep.nightSleepMinutes < 6 * 60 {
                let slept = reportHoursMinutes(sleep.nightSleepMinutes)
                out.append(String(localized: "Only \(slept) of sleep — chronic short sleep degrades adaptation and recovery from training.", bundle: bundle))
            }
            if let efficiency = sleep.measuredSleepEfficiency, efficiency < 80 {
                out.append(String(localized: "Sleep efficiency \(Int(efficiency.rounded()))% — fragmented sleep blunts recovery.", bundle: bundle))
            }
        }
        return out
    }

    private func hurtingLoadPoints(bundle: Bundle) -> [String] {
        var out: [String] = []
        // Read the SAME live load the rest of the report uses
        // (trainingLoadForReport), not the frozen workoutSession snapshot.
        // Mixing the two prints two contradictory TSB/ACWR numbers on one
        // page (live hero row "Balanced" vs frozen "WHAT'S HURTING").
        // The same gate reasons that cap the prescription tier above.
        let reasons = adviceLoad().reasons
        if let load = trainingLoadForReport() {
            if let acwr = load.acuteChronicRatio, reasons.contains(.sharpIncrease) {
                out.append(String(localized: "ACWR \(String(format: "%.2f", locale: LanguageManager.appLocale, acwr)) — past spike threshold; load needs to come down.", bundle: bundle))
            }
            if reasons.contains(.heavyFatigue) {
                out.append(String(localized: "TSB \(String(format: "%+.1f", locale: LanguageManager.appLocale, load.tsb)) — meaningfully fatigued, recovery overdue.", bundle: bundle))
            }
        }
        return out
    }
}
