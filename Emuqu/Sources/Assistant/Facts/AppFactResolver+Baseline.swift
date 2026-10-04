// Split out of AppFactResolver+Sleep.swift to keep that file under
// the 1,000-line ceiling. The baseline.* namespace is self-contained.

import CoreLocation
import CoreMotion
import Foundation
import os

// MARK: - baseline.* namespace
//
// Rolling 7-day and 30-day personal baselines for "how am I trending"
// questions. Neither is the recovery score's baseline, which is the ln-mean
// of up to the 60 most recent usable nights before the scored one
// (`BaselineTracker.recoveryBaselineStats`). The tracker's persisted data isn't directly reachable
// from the fact resolver (would require threading the RRCollector
// through), but every data point it uses comes from overnight sessions
// in the archive — we can reconstruct the same rolling averages here
// synchronously from sessions' analysisResult.timeDomain.
//
// This intentionally stays a small shim rather than importing
// BaselineTracker's logic: the resolver is read-only, doesn't need
// quality gating (consolidated / organized / artifact filtering), and
// doesn't need to replace data points — just the geometric mean of RMSSD
// and the arithmetic mean of overnight mean HR over the trailing window.

struct BaselineNamespace: FactNamespaceResolver {
    let namespace = "baseline"
    let archive: SessionArchive

    private struct Sample {
        let date: Date
        let rmssd: Double
        let hr: Double
    }

    /// The latest overnight session, only if it is last night's. Returning
    /// whatever was newest labelled a recording from days ago as "today".
    private func lastNightSample(now: Date = Date()) -> Sample? {
        guard let latest = samples().last, now.timeIntervalSince(latest.date) <= 36 * 3600 else { return nil }
        return latest
    }

    /// All overnight sessions with analysis results, sorted oldest → newest.
    /// Excludes untrustworthy-HRV readings so the AI's rolling
    /// RMSSD baseline matches the app's `BaselineTracker` (which does too).
    private func samples() -> [Sample] {
        let entries = archive.entries
            .filter { $0.sessionType == .overnight && $0.isReliableForHRVAggregates }
            .sorted { $0.date < $1.date }
        return entries.compactMap { entry -> Sample? in
            guard let session = archive.retrieveLightweightOrLog(entry.sessionId),
                  let td = session.analysisResult?.timeDomain,
                  td.rmssd > 0
            else { return nil }
            return Sample(date: session.startDate, rmssd: td.rmssd, hr: td.meanHR)
        }
    }

    /// Samples within the trailing `days` days (the 7-day default matches
    /// BaselineTracker's `baselineWindowDays`, its short display window).
    private func recentSamples(days: Int = 7) -> [Sample] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else {
            return []
        }
        return samples().filter { $0.date >= cutoff }
    }

    /// Geometric mean of a positive series = exp(mean(ln(x))). Falls back
    /// to nil on empty / non-positive input.
    private static func geometricMean(_ xs: [Double]) -> Double? {
        let positives = xs.filter { $0 > 0 }
        guard !positives.isEmpty else { return nil }
        let meanLn = positives.map(log).reduce(0, +) / Double(positives.count)
        return exp(meanLn)
    }

    private func baselineAvailability() -> Availability {
        let entries = archive.entries.filter { $0.sessionType == .overnight }
        guard !entries.isEmpty,
              let earliest = entries.map(\.date).min(),
              let latest = entries.map(\.date).max()
        else { return .unavailable }
        return Availability(hasData: true, validRange: earliest ... latest, lastUpdated: latest)
    }

    var entries: [FactEntry] {
        return [
            baselineRmssdMean7dEntry,
            baselineRmssdDeviationPctTodayEntry,
            baselineHrMean7dEntry,
            // 30-day baseline variants. The 7-day surface above is the
            // short-term view (the recovery score itself uses its own ln-mean
            // baseline, not this figure); the 30-day surface is
            // for "is my fitness trending up over the month?" questions
            // (Whoop / Garmin both expose this prominently).
            baselineRmssdMean30dEntry,
            baselineRmssdDeviationPctTodayVs30dEntry,
            baselineHrMean30dEntry,
            baselineHrDeviationPctTodayVs30dEntry,
            baselineDaysOfHistoryEntry,
            baselineIsEstablishedEntry
        ]
    }

    private var baselineRmssdMean7dEntry: FactEntry {
        .fixed(
            key: "baseline.rmssd.mean_7d",
            description: "Geometric mean of RMSSD across the trailing 7 days of overnight sessions. ms.",
            valueType: "Double",
            availability: { self.baselineAvailability() },
            resolve: {
                let recent = self.recentSamples(days: 7).map(\.rmssd)
                guard let gm = Self.geometricMean(recent) else {
                    return .missing(reason: .notYetComputed, detail: "fewer than 1 valid overnight session in the last 7 days")
                }
                return .double(gm)
            }
        )
    }

    private var baselineRmssdDeviationPctTodayEntry: FactEntry {
        .fixed(
            key: "baseline.rmssd.deviation_pct_today",
            description: "Today's latest session RMSSD as a percentage deviation from the 7-day geometric mean baseline. Positive = above baseline. %.",
            valueType: "Double",
            availability: { self.baselineAvailability() },
            resolve: {
                guard let today = self.lastNightSample() else {
                    return .missing(reason: .notRecorded, detail: "no overnight session from last night")
                }
                let prior = self.recentSamples(days: 7).filter { $0.date < today.date }.map(\.rmssd)
                guard let baseline = Self.geometricMean(prior), baseline > 0 else {
                    return .missing(reason: .notYetComputed, detail: "no prior 7-day data to compare against")
                }
                let pct = ((today.rmssd - baseline) / baseline) * 100.0
                return .double(pct)
            }
        )
    }

    private var baselineHrMean7dEntry: FactEntry {
        .fixed(
            key: "baseline.hr.mean_7d",
            description: "Mean overnight heart rate (each session's analysis-window mean) across the trailing 7 days. bpm. Not Apple's resting HR — don't compare the two.",
            valueType: "Double",
            availability: { self.baselineAvailability() },
            resolve: {
                let recent = self.recentSamples(days: 7).map(\.hr)
                guard !recent.isEmpty else {
                    return .missing(reason: .notYetComputed, detail: "fewer than 1 valid overnight session in the last 7 days")
                }
                let mean = recent.reduce(0, +) / Double(recent.count)
                return .double(mean)
            }
        )
    }

    private var baselineRmssdMean30dEntry: FactEntry {
        .fixed(
            key: "baseline.rmssd.mean_30d",
            description: "Geometric mean of RMSSD across the trailing 30 days of overnight sessions. ms.",
            valueType: "Double",
            availability: { self.baselineAvailability() },
            resolve: {
                let recent = self.recentSamples(days: 30).map(\.rmssd)
                guard let gm = Self.geometricMean(recent) else {
                    return .missing(reason: .notYetComputed, detail: "fewer than 1 valid overnight session in the last 30 days")
                }
                return .double(gm)
            }
        )
    }

    private var baselineRmssdDeviationPctTodayVs30dEntry: FactEntry {
        .fixed(
            key: "baseline.rmssd.deviation_pct_today_vs_30d",
            description: "Today's latest session RMSSD as a percentage deviation from the 30-day geometric mean baseline. Positive = above the long-term baseline. %.",
            valueType: "Double",
            availability: { self.baselineAvailability() },
            resolve: {
                guard let today = self.lastNightSample() else {
                    return .missing(reason: .notRecorded, detail: "no overnight session from last night")
                }
                let prior = self.recentSamples(days: 30).filter { $0.date < today.date }.map(\.rmssd)
                guard let baseline = Self.geometricMean(prior), baseline > 0 else {
                    return .missing(reason: .notYetComputed, detail: "no prior 30-day data to compare against")
                }
                let pct = ((today.rmssd - baseline) / baseline) * 100.0
                return .double(pct)
            }
        )
    }

    private var baselineHrMean30dEntry: FactEntry {
        .fixed(
            key: "baseline.hr.mean_30d",
            description: "Mean overnight heart rate (each session's analysis-window mean) across the trailing 30 days. bpm. Use to answer 'has my overnight HR drifted up?'. Not Apple's resting HR — don't compare the two.",
            valueType: "Double",
            availability: { self.baselineAvailability() },
            resolve: {
                let recent = self.recentSamples(days: 30).map(\.hr)
                guard !recent.isEmpty else {
                    return .missing(reason: .notYetComputed, detail: "fewer than 1 valid overnight session in the last 30 days")
                }
                let mean = recent.reduce(0, +) / Double(recent.count)
                return .double(mean)
            }
        )
    }

    private var baselineHrDeviationPctTodayVs30dEntry: FactEntry {
        .fixed(
            key: "baseline.hr.deviation_pct_today_vs_30d",
            description: "Last night's overnight mean HR as a percentage deviation from the prior 30-day overnight mean. Positive = elevated (often seen with stress, fatigue or a hard training block). %.",
            valueType: "Double",
            availability: { self.baselineAvailability() },
            resolve: {
                guard let today = self.lastNightSample() else {
                    return .missing(reason: .notRecorded, detail: "no overnight session from last night")
                }
                let prior = self.recentSamples(days: 30).filter { $0.date < today.date }.map(\.hr)
                guard !prior.isEmpty else {
                    return .missing(reason: .notYetComputed, detail: "no prior 30-day data to compare against")
                }
                let baseline = prior.reduce(0, +) / Double(prior.count)
                guard baseline > 0 else { return .missing(reason: .notYetComputed) }
                let pct = ((today.hr - baseline) / baseline) * 100.0
                return .double(pct)
            }
        )
    }

    private var baselineDaysOfHistoryEntry: FactEntry {
        .fixed(
            key: "baseline.days_of_history",
            description: "Number of usable overnight sessions the recovery score's baseline draws on: the most recent ones, up to 60, whatever their age (sessions with untrustworthy HRV excluded).",
            valueType: "Int",
            availability: { self.baselineAvailability() },
            resolve: {
                .integer(min(self.samples().count, 60))
            }
        )
    }

    private var baselineIsEstablishedEntry: FactEntry {
        .fixed(
            key: "baseline.is_established",
            description: "Whether the personal baseline is established, by the app's rule: at least 3 usable overnight sessions recorded. Before that the recovery score has no baseline to compare against. Confidence keeps growing until about 7 nights.",
            valueType: "Bool",
            availability: { self.baselineAvailability() },
            resolve: {
                .boolean(self.samples().count >= BaselineTracker.RecoveryBaselineStats.minimumDays)
            }
        )
    }
}
