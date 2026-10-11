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

    /// The latest overnight session in `all`, only if it is last night's.
    /// Returning whatever was newest labelled a recording from days ago as
    /// "today".
    private static func lastNight(in all: [Sample], now: Date = Date()) -> Sample? {
        guard let latest = all.last, now.timeIntervalSince(latest.date) <= 36 * 3600 else { return nil }
        return latest
    }

    /// All overnight sessions with analysis results, sorted oldest → newest.
    /// Excludes untrustworthy-HRV readings so the AI's rolling
    /// RMSSD baseline matches the app's `BaselineTracker` (which does too).
    /// Each resolver reads this once and derives everything else from it.
    private func samples() -> [Sample] {
        archive.entries
            .filter { $0.sessionType == .overnight && $0.isReliableForHRVAggregates }
            .sorted { $0.date < $1.date }
            .compactMap { sample(for: $0) }
    }

    /// From the index's mirror of the session's RMSSD and mean HR (written
    /// from the same analysis result) when it carries both, so no session
    /// file is read; else from the session file.
    private func sample(for entry: SessionArchiveEntry) -> Sample? {
        if let rmssd = entry.meanRMSSD, let hr = entry.meanHR {
            return rmssd > 0 ? Sample(date: entry.date, rmssd: rmssd, hr: hr) : nil
        }
        guard let session = archive.retrieveLightweightOrLog(entry.sessionId),
              let td = session.analysisResult?.timeDomain,
              td.rmssd > 0
        else { return nil }
        return Sample(date: session.startDate, rmssd: td.rmssd, hr: td.meanHR)
    }

    /// The samples within the trailing `days` days (7 matches
    /// BaselineTracker's `baselineWindowDays`, its short display window).
    private static func window(_ all: [Sample], days: Int) -> [Sample] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else {
            return []
        }
        return all.filter { $0.date >= cutoff }
    }

    /// Last night's RMSSD as a % deviation from the geometric mean of the
    /// earlier sessions within `days`.
    private func rmssdDeviationPct(days: Int) -> FactValue {
        let all = samples()
        guard let today = Self.lastNight(in: all) else {
            return .missing(reason: .notRecorded, detail: "no overnight session from last night")
        }
        let prior = Self.window(all, days: days).filter { $0.date < today.date }.map(\.rmssd)
        guard let baseline = Self.geometricMean(prior), baseline > 0 else {
            return .missing(reason: .notYetComputed, detail: "no prior \(days)-day data to compare against")
        }
        return .double(((today.rmssd - baseline) / baseline) * 100.0)
    }

    /// Geometric mean of RMSSD over the trailing `days`.
    private func rmssdMean(days: Int) -> FactValue {
        guard let gm = Self.geometricMean(Self.window(samples(), days: days).map(\.rmssd)) else {
            return .missing(reason: .notYetComputed, detail: "fewer than 1 valid overnight session in the last \(days) days")
        }
        return .double(gm)
    }

    /// Arithmetic mean of overnight mean HR over the trailing `days`.
    private func hrMean(days: Int) -> FactValue {
        let recent = Self.window(samples(), days: days).map(\.hr)
        guard !recent.isEmpty else {
            return .missing(reason: .notYetComputed, detail: "fewer than 1 valid overnight session in the last \(days) days")
        }
        return .double(recent.reduce(0, +) / Double(recent.count))
    }

    /// Distinct nights among the usable sessions, keyed the way
    /// `BaselineTracker` keys its one point per night
    /// (`SleepSchedule.nightKey`), so two recordings of one night count once.
    private func usableNightCount() -> Int {
        let schedule = AppDependencies.current.app.settingsManager.settingsSnapshot.sleepSchedule
        return Set(samples().map { schedule.nightKey(for: $0.date) }).count
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
            resolve: { self.rmssdMean(days: 7) }
        )
    }

    private var baselineRmssdDeviationPctTodayEntry: FactEntry {
        .fixed(
            key: "baseline.rmssd.deviation_pct_today",
            description: "Today's latest session RMSSD as a percentage deviation from the 7-day geometric mean baseline. Positive = above baseline. %.",
            valueType: "Double",
            availability: { self.baselineAvailability() },
            resolve: { self.rmssdDeviationPct(days: 7) }
        )
    }

    private var baselineHrMean7dEntry: FactEntry {
        .fixed(
            key: "baseline.hr.mean_7d",
            description: "Mean overnight heart rate (each session's analysis-window mean) across the trailing 7 days. bpm. Not Apple's resting HR — don't compare the two.",
            valueType: "Double",
            availability: { self.baselineAvailability() },
            resolve: { self.hrMean(days: 7) }
        )
    }

    private var baselineRmssdMean30dEntry: FactEntry {
        .fixed(
            key: "baseline.rmssd.mean_30d",
            description: "Geometric mean of RMSSD across the trailing 30 days of overnight sessions. ms.",
            valueType: "Double",
            availability: { self.baselineAvailability() },
            resolve: { self.rmssdMean(days: 30) }
        )
    }

    private var baselineRmssdDeviationPctTodayVs30dEntry: FactEntry {
        .fixed(
            key: "baseline.rmssd.deviation_pct_today_vs_30d",
            description: "Today's latest session RMSSD as a percentage deviation from the 30-day geometric mean baseline. Positive = above the long-term baseline. %.",
            valueType: "Double",
            availability: { self.baselineAvailability() },
            resolve: { self.rmssdDeviationPct(days: 30) }
        )
    }

    private var baselineHrMean30dEntry: FactEntry {
        .fixed(
            key: "baseline.hr.mean_30d",
            description: "Mean overnight heart rate (each session's analysis-window mean) across the trailing 30 days. bpm. Use to answer 'has my overnight HR drifted up?'. Not Apple's resting HR — don't compare the two.",
            valueType: "Double",
            availability: { self.baselineAvailability() },
            resolve: { self.hrMean(days: 30) }
        )
    }

    private var baselineHrDeviationPctTodayVs30dEntry: FactEntry {
        .fixed(
            key: "baseline.hr.deviation_pct_today_vs_30d",
            description: "Last night's overnight mean HR as a percentage deviation from the prior 30-day overnight mean. Positive = elevated (often seen with stress, fatigue or a hard training block). %.",
            valueType: "Double",
            availability: { self.baselineAvailability() },
            resolve: {
                let all = self.samples()
                guard let today = Self.lastNight(in: all) else {
                    return .missing(reason: .notRecorded, detail: "no overnight session from last night")
                }
                let prior = Self.window(all, days: 30).filter { $0.date < today.date }.map(\.hr)
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
            description: """
            Number of nights with a usable overnight reading, up to the 60 most recent the recovery score's baseline reads, whatever their age (one per night however many recordings it has; readings with untrustworthy HRV \
            excluded). Counted from the session archive the way the score's baseline keys nights, so it can differ from the score's own count when a night was recorded but never added to the baseline.
            """,
            valueType: "Int",
            availability: { self.baselineAvailability() },
            resolve: {
                .integer(min(self.usableNightCount(), 60))
            }
        )
    }

    private var baselineIsEstablishedEntry: FactEntry {
        .fixed(
            key: "baseline.is_established",
            description: """
            Whether the personal baseline is established, by the app's rule: usable overnight readings on at least 3 different nights. Before that the recovery score has no baseline to compare against. Confidence keeps \
            growing until about 7 nights. Counted from the session archive like baseline.days_of_history, so in rare cases it can say true a night before the score's own baseline does.
            """,
            valueType: "Bool",
            availability: { self.baselineAvailability() },
            resolve: {
                .boolean(self.usableNightCount() >= BaselineTracker.RecoveryBaselineStats.minimumDays)
            }
        )
    }
}
