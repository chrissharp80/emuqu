import CoreLocation
import SwiftUI

// Report rendering for the Send-Report menu: the PDF dispatch and its three
// per-kind renderers. `renderReport` is internal rather than `private` because
// Swift's `private` does not reach across files.

extension MainTabView {
    /// Pure-ish render dispatch. Detached so PDF rendering doesn't
    /// pin the main thread. Returns either a temp-file URL ready for
    /// `MailComposerView` or a user-presentable failure message.
    static func renderReport(
        kind: SendReportKind,
        inputs: SendReportInputs,
        liveLoadSnapshot: TrainingLoadRegistry.TrainingLoad?
    ) async -> RenderOutcome {
        let stem = "emuqu-report-\(Int(Date().timeIntervalSince1970))"
        let pdfURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(stem).pdf")
        let hr = ReportRenderer.Profile(
            maxHR: inputs.maxHR, restingHR: inputs.restingHR, lthr: inputs.lthr,
            units: inputs.units, temperatureUnit: inputs.temperatureUnit
        )
        let recent = inputs.recentOvernight
        do {
            switch kind {
            case .recovery:
                return try await renderRecoveryReport(inputs, to: pdfURL, load: liveLoadSnapshot)
            case .daily:
                return try await renderDailyReport(inputs.pair, to: pdfURL, recent: recent, load: liveLoadSnapshot, hr: hr)
            case .workout:
                return try await renderWorkoutReport(inputs.workout, to: pdfURL, hr: hr)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The dashboard holds lightweight sessions (RR series stripped); the PDFs
    /// need the full ones, or every raw-RR section drops out. Called inside the
    /// detached task so the decrypt stays off the main actor. Falls back to the
    /// lightweight copy if a full read fails.
    ///
    /// The baseline nights are re-read from the whole archive: up to 60
    /// overnights strictly before the reported night (`ReportBaselineNights`),
    /// as Reports → Browse builds them, not the reliable overnights of the
    /// dashboard's 35-session slice, which included the reported night itself.
    nonisolated static func withFullSessions(_ inputs: SendReportInputs, kind: SendReportKind) -> SendReportInputs {
        let archive = AppDependencies.current.storage.sessionArchive
        let full: (HRVSession) -> HRVSession = { archive.retrieveOrLog($0.id) ?? $0 }
        let night: Date? = switch kind {
        case .recovery: inputs.recovery?.startDate
        case .daily: inputs.pair?.overnight.startDate
        case .workout: nil
        }
        return SendReportInputs(
            recovery: inputs.recovery.map(full),
            workout: inputs.workout.map(full),
            pair: inputs.pair.map { (workout: full($0.workout), overnight: full($0.overnight)) },
            recentOvernight: night.map { ReportBaselineNights.before($0, archive: archive) } ?? inputs.recentOvernight,
            baselineStats: inputs.baselineStats,
            maxHR: inputs.maxHR,
            restingHR: inputs.restingHR,
            lthr: inputs.lthr,
            units: inputs.units,
            temperatureUnit: inputs.temperatureUnit
        )
    }

    /// Frozen-snapshot recovery PDF (`ReportRenderer.renderRecovery`).
    private static func renderRecoveryReport(
        _ inputs: SendReportInputs, to pdfURL: URL, load: TrainingLoadRegistry.TrainingLoad?
    ) async throws -> RenderOutcome {
        guard let overnight = inputs.recovery else {
            return .failed(String(localized: "No recent HRV recording to report on. Record an overnight session first.", bundle: LanguageManager.appBundle))
        }
        let rendered = try await ReportRenderer.renderRecovery(
            overnight, recentOvernight: inputs.recentOvernight, baselineStats: inputs.baselineStats, load: load, to: pdfURL
        )
        guard rendered else {
            return .failed(String(localized: "Couldn't render the recovery PDF. The session may not have enough data.", bundle: LanguageManager.appBundle))
        }
        return .ok(pdfURL)
    }

    private static func renderDailyReport(_ pair: (workout: HRVSession, overnight: HRVSession)?, to pdfURL: URL, recent: [HRVSession], load: TrainingLoadRegistry.TrainingLoad?, hr: ReportRenderer.Profile) async throws -> RenderOutcome {
        guard let pair else {
            return .failed(String(localized: "No workout with an overnight recording from the night before it. Daily reports need both.", bundle: LanguageManager.appBundle))
        }
        try await ReportRenderer.renderDaily(
            workout: pair.workout, track: decodeTrack(for: pair.workout), overnight: pair.overnight,
            recentOvernight: recent, profile: hr, load: load, to: pdfURL
        )
        return .ok(pdfURL)
    }

    private static func renderWorkoutReport(_ workout: HRVSession?, to pdfURL: URL, hr: ReportRenderer.Profile) async throws -> RenderOutcome {
        guard let workout else {
            return .failed(String(localized: "No recent workout to report on. Finish a workout first.", bundle: LanguageManager.appBundle))
        }
        try await ReportRenderer.renderWorkout(workout, track: decodeTrack(for: workout), profile: hr, to: pdfURL)
        return .ok(pdfURL)
    }

    static func decodeTrack(for session: HRVSession) -> [CLLocation] {
        guard let polyline = session.workoutMetadata?.gpsPolyline else { return [] }
        return GPXExporter.decode(polyline: polyline, startDate: session.startDate, duration: session.duration ?? 0)
    }
}

/// The overnights a report's baseline reaches back over, strictly before the
/// reported night, newest first, so a report is measured against the nights
/// before it and never against itself. Read (lightweight, from the archive
/// index) until `count` of them are reliable: the daily loop drops
/// unreliable nights, and its baseline must cover the same 60 reliable
/// nights (`DailyLoopAnalysis.baselineNightLimit`) as the recovery score's.
/// Shared by the Send-Report menu and Reports → Browse.
enum ReportBaselineNights {
    static let count = 60

    static func before(_ night: Date, archive: SessionArchive) -> [HRVSession] {
        let entries = archive.entries
            .filter { $0.sessionType == .overnight && $0.date < night }
            .sorted { $0.date > $1.date }
        var nights: [HRVSession] = []
        var reliableCount = 0
        for entry in entries where reliableCount < count {
            guard let session = archive.retrieveLightweightOrLog(entry.sessionId) else { continue }
            nights.append(session)
            if session.isReliableForHRVAggregates { reliableCount += 1 }
        }
        return nights
    }
}

/// The PDF renders the Send-Report menu (`MainTabView.renderReport`) and
/// Reports → Browse (`ReportsListView`) share, so a change to a report's
/// inputs is made once. Nonisolated: the drawing runs off the main actor.
enum ReportRenderer {
    /// The user-profile numbers every report generator needs, bundled so the
    /// render helpers stay under the parameter-count limit.
    struct Profile {
        let maxHR: Int
        let restingHR: Int
        let lthr: Int
        let units: UnitsPreference
        var temperatureUnit: TemperatureUnit = .regionDefault
    }

    /// Frozen-snapshot comprehensive recovery PDF (no live HealthKit query),
    /// moved onto `pdfURL` (`PDFReportGenerator` writes to its own URL);
    /// false when the session couldn't be rendered. `baselineStats` is the
    /// baseline before the reported night.
    static func renderRecovery(
        _ overnight: HRVSession, recentOvernight: [HRVSession],
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        load: TrainingLoadRegistry.TrainingLoad?, to pdfURL: URL
    ) async throws -> Bool {
        guard let url = recoveryPDFURL(for: overnight, recentOvernight: recentOvernight, baselineStats: baselineStats, load: load) else {
            return false
        }
        try replace(pdfURL, with: url)
        return true
    }

    private static func recoveryPDFURL(
        for overnight: HRVSession, recentOvernight: [HRVSession],
        baselineStats: BaselineTracker.RecoveryBaselineStats?, load: TrainingLoadRegistry.TrainingLoad?
    ) -> URL? {
        let breakdown = overnight.scoreBreakdown
        return PDFReportGenerator().generateReportURL(
            for: overnight,
            sleepData: overnight.sleepSnapshot.map { PDFReportGenerator.SleepData(from: $0) },
            sleepTrend: nil,
            recentSessions: recentOvernight,
            healthKitHR: nil,
            vitals: overnight.vitalsSnapshot.map { PDFReportGenerator.VitalsData(from: $0) },
            compositeRecoveryScore: breakdown.map { Double($0.compositeScore) },
            scoreBreakdown: breakdown,
            baselineStats: baselineStats,
            liveLoadSnapshot: load,
            style: .comprehensive,
            sections: .all
        )
    }

    private static func replace(_ destination: URL, with source: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = attempt("ReportRenderer.remove") { try FileManager.default.removeItem(at: destination) }
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    /// The holistic daily report: a workout and the night before it.
    static func renderDaily(
        workout: HRVSession, track: [CLLocation], overnight: HRVSession?, recentOvernight: [HRVSession],
        profile: Profile, load: TrainingLoadRegistry.TrainingLoad?, to pdfURL: URL
    ) async throws {
        let report = HolisticDailyReport(
            workoutSession: workout,
            workoutTrack: track,
            overnightSession: overnight,
            recentOvernightSessions: recentOvernight,
            userMaxHR: profile.maxHR,
            userRestingHR: profile.restingHR,
            userLTHR: profile.lthr,
            units: profile.units,
            temperatureUnit: profile.temperatureUnit,
            liveLoadSnapshot: load
        )
        try await report.generate(to: pdfURL)
    }

    static func renderWorkout(_ workout: HRVSession, track: [CLLocation], profile: Profile, to pdfURL: URL) async throws {
        let report = WorkoutPDFReport(
            session: workout,
            track: track,
            userMaxHR: profile.maxHR,
            userRestingHR: profile.restingHR,
            userLTHR: profile.lthr,
            units: profile.units
        )
        try await report.generate(to: pdfURL)
    }
}
