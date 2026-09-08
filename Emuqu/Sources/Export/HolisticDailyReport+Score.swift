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

    private func frozenReadinessScore(_ breakdown: RecoveryScoreCalculator.ScoreBreakdown) -> (value: Double, tier: String, contributions: [ScoreContribution]) {
        // Canonical path: use the session's frozen breakdown so the
        // PDF and the Dashboard pill are mathematically identical.
        // ScoreBreakdown stores compositeScore on a 0–100 scale
        // and factor scores on 0–100. Convert to the 0–10 scale
        // this PDF uses for display.
        let value = breakdown.compositeScore / 10.0
        let contribs: [ScoreContribution] = breakdown.factors.map { factor in
            ScoreContribution(
                name: factor.label,
                score: factor.score / 10.0,
                weight: factor.weight,
                note: factor.detail
            )
        }
        return (value, readinessTier(for: value), contribs)
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
        // Cap the prescription tier when ACWR is in the
        // spike-injury zone. TSB enters the composite (25% weight) but
        // a user with high CTL and recently-bumped ATL can have ACWR
        // ≥ 1.5 while TSB is still mildly negative — the composite
        // could float above the "go hard" threshold via excellent HRV
        // and HRR. ACWR is the spike-specific signal; once it crosses
        // 1.5 the prescription needs to cap at moderate regardless of
        // anything else.
        let acwrCap = trainingLoadForReport()?.acuteChronicRatio.map { $0 >= 1.5 } ?? false
        return (total, readinessTier(for: total, acwrCap: acwrCap), contribs)
    }

    private func legacyHRVContribution(bundle: Bundle) -> ScoreContribution {
        // HRV vs baseline (35%)
        var hrvScore: Double = 5
        var hrvNote = String(localized: "No baseline yet — need 3+ overnight sessions", bundle: bundle)
        if let baseline = analysis().recoveryBaselineRMSSD,
           let pct = analysis().hrvPercentVsBaseline {
            // Map -20% .. +20% to 0 .. 10
            hrvScore = min(10, max(0, 5 + pct / 4))
            hrvNote = String(localized: "\(pct >= 0 ? "+" : "")\(String(format: "%.0f", locale: .current, pct))% vs your \(String(format: "%.0f", locale: .current, baseline)) ms baseline", bundle: bundle)
        }
        return ScoreContribution(name: String(localized: "HRV vs baseline", bundle: bundle), score: hrvScore, weight: 0.35, note: hrvNote)
    }

    private func legacySleepContribution(bundle: Bundle) -> ScoreContribution {
        // Sleep quality (25%)
        var sleepScore: Double = 5
        var sleepNote = String(localized: "No sleep data tonight", bundle: bundle)
        if let sleep = overnightSession?.sleepSnapshot {
            let dur = Double(sleep.nightSleepMinutes) / 60.0 // hours
            let eff = sleep.sleepEfficiency // 0-100 scale
            // dur 7-8h = full credit; eff 85+ = full credit
            let durScore = min(10, max(0, (dur - 4) / 3.5 * 10))
            let effScore = min(10, max(0, (eff - 65) / 30 * 10))
            sleepScore = durScore * 0.5 + effScore * 0.5
            sleepNote = String(localized: "\(String(format: "%.1f", locale: .current, dur))h at \(String(format: "%.0f", locale: .current, eff))% efficiency", bundle: bundle)
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
            tsbNote = String(localized: "TSB \(String(format: "%+.1f", locale: .current, snap.tsb)) (CTL \(String(format: "%.1f", locale: .current, snap.ctl)), ATL \(String(format: "%.1f", locale: .current, snap.atl)))", bundle: bundle)
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

    /// Map 0–10 readiness to a training-prescription tier. Same bands
    /// for both code paths so the verdict line is consistent regardless
    /// of which composite source fired. `acwrCap` enforces a moderate
    /// ceiling when the user's acute load is in the spike-injury zone
    /// (ACWR ≥ 1.5, Gabbett 2016). Even an otherwise-stellar composite
    /// can't recommend "go hard" when the recent-vs-chronic ratio says
    /// the body is absorbing.
    private func readinessTier(for value: Double, acwrCap: Bool = false) -> String {
        let bundle = LanguageManager.appBundle
        if acwrCap {
            // Ceiling at Tier 3 ("moderate only") regardless of the
            // underlying composite. The lower tiers still apply if the
            // composite itself argues for them.
            if value >= 5.5 { return String(localized: "Tier 3 — moderate only (load elevated)", bundle: bundle) }
            if value >= 3.5 { return String(localized: "Tier 4 — easy aerobic", bundle: bundle) }
            return String(localized: "Tier 5 — rest", bundle: bundle)
        }
        if value >= 8.5 { return String(localized: "Tier 1 — go hard", bundle: bundle) }
        if value >= 7.0 { return String(localized: "Tier 2 — quality OK", bundle: bundle) }
        if value >= 5.5 { return String(localized: "Tier 3 — moderate only", bundle: bundle) }
        if value >= 3.5 { return String(localized: "Tier 4 — easy aerobic", bundle: bundle) }
        return String(localized: "Tier 5 — rest", bundle: bundle)
    }

    func whatsHelpingPoints() -> [String] {
        let bundle = LanguageManager.appBundle
        var out: [String] = []
        if let pct = analysis().hrvPercentVsBaseline, pct >= 5 {
            out.append(String(localized: "HRV is \(Int(pct.rounded()))% above your 7-day baseline — strong autonomic state.", bundle: bundle))
        }
        if let sleep = overnightSession?.sleepSnapshot,
           sleep.sleepEfficiency >= 90,
           sleep.nightSleepMinutes >= 7 * 60 {
            out.append(String(localized: "Sleep was \(sleep.nightSleepMinutes / 60)h with \(Int(sleep.sleepEfficiency.rounded()))% efficiency — consolidated, restorative.", bundle: bundle))
        }
        if let snap = trainingLoadForReport() {
            if let acwr = snap.acuteChronicRatio, acwr >= 0.8, acwr < 1.3 {
                out.append(String(localized: "ACWR \(String(format: "%.2f", locale: .current, acwr)) — productive load band, sustainable volume.", bundle: bundle))
            }
            if snap.tsb > 5 { out.append(String(localized: "TSB \(String(format: "%+.1f", locale: .current, snap.tsb)) — fresh, ready for quality work.", bundle: bundle)) }
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
                let h = sleep.nightSleepMinutes / 60, m = sleep.nightSleepMinutes % 60
                out.append(String(localized: "Only \(h)h \(m)m of sleep — chronic short sleep degrades adaptation and recovery from training.", bundle: bundle))
            }
            if sleep.sleepEfficiency < 80 {
                out.append(String(localized: "Sleep efficiency \(Int(sleep.sleepEfficiency.rounded()))% — fragmented sleep blunts recovery.", bundle: bundle))
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
        if let load = trainingLoadForReport() {
            if let acwr = load.acuteChronicRatio, acwr >= 1.5 {
                out.append(String(localized: "ACWR \(String(format: "%.2f", locale: .current, acwr)) — past spike threshold; load needs to come down.", bundle: bundle))
            }
            if load.tsb < -15 {
                out.append(String(localized: "TSB \(String(format: "%+.1f", locale: .current, load.tsb)) — meaningfully fatigued, recovery overdue.", bundle: bundle))
            }
        }
        return out
    }
}
