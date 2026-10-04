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
        let hr = ReportHRSettings(maxHR: inputs.maxHR, restingHR: inputs.restingHR, lthr: inputs.lthr, units: inputs.units)
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
    nonisolated static func withFullSessions(_ inputs: SendReportInputs) -> SendReportInputs {
        let archive = AppDependencies.current.storage.sessionArchive
        let full: (HRVSession) -> HRVSession = { archive.retrieveOrLog($0.id) ?? $0 }
        return SendReportInputs(
            recovery: inputs.recovery.map(full),
            workout: inputs.workout.map(full),
            pair: inputs.pair.map { (workout: full($0.workout), overnight: full($0.overnight)) },
            recentOvernight: inputs.recentOvernight,
            baselineStats: inputs.baselineStats,
            maxHR: inputs.maxHR,
            restingHR: inputs.restingHR,
            lthr: inputs.lthr,
            units: inputs.units
        )
    }

    /// The four user-profile numbers every report generator needs, bundled so
    /// the render helpers stay under the parameter-count limit.
    struct ReportHRSettings {
        let maxHR: Int
        let restingHR: Int
        let lthr: Int
        let units: UnitsPreference
    }

    /// Frozen-snapshot recovery PDF. `PDFReportGenerator` writes to its own
    /// URL, so we move it onto the deterministic temp path afterwards.
    private static func renderRecoveryReport(
        _ inputs: SendReportInputs, to pdfURL: URL, load: TrainingLoadRegistry.TrainingLoad?
    ) async throws -> RenderOutcome {
        guard let overnight = inputs.recovery else {
            return .failed(String(localized: "No recent HRV recording to report on. Record an overnight session first.", bundle: LanguageManager.appBundle))
        }
        guard let url = await recoveryPDFURL(for: overnight, inputs: inputs, load: load) else {
            return .failed(String(localized: "Couldn't render the recovery PDF. The session may not have enough data.", bundle: LanguageManager.appBundle))
        }
        if FileManager.default.fileExists(atPath: pdfURL.path) {
            _ = attempt("MainTabView+Reports.remove") { try FileManager.default.removeItem(at: pdfURL) }
        }
        try FileManager.default.moveItem(at: url, to: pdfURL)
        return .ok(pdfURL)
    }

    /// The score text is translated first, so the PDF reads in the app's
    /// language.
    nonisolated private static func recoveryPDFURL(
        for overnight: HRVSession, inputs: SendReportInputs, load: TrainingLoadRegistry.TrainingLoad?
    ) async -> URL? {
        let breakdown = overnight.scoreBreakdown
        let generator = PDFReportGenerator()
        await generator.prepareNarrative(for: breakdown)
        return generator.generateReportURL(
            for: overnight,
            sleepData: overnight.sleepSnapshot.map { PDFReportGenerator.SleepData(from: $0) },
            sleepTrend: nil,
            recentSessions: inputs.recentOvernight,
            healthKitHR: nil,
            vitals: overnight.vitalsSnapshot.map { PDFReportGenerator.VitalsData(from: $0) },
            compositeRecoveryScore: breakdown.map { Double($0.compositeScore) },
            scoreBreakdown: breakdown,
            baselineStats: inputs.baselineStats,
            liveLoadSnapshot: load,
            style: .comprehensive,
            sections: .all
        )
    }

    private static func renderDailyReport(_ pair: (workout: HRVSession, overnight: HRVSession)?, to pdfURL: URL, recent: [HRVSession], load: TrainingLoadRegistry.TrainingLoad?, hr: ReportHRSettings) async throws -> RenderOutcome {
        guard let pair else {
            return .failed(String(localized: "No workout with an overnight recording from the night before it. Daily reports need both.", bundle: LanguageManager.appBundle))
        }
        let report = HolisticDailyReport(
            workoutSession: pair.workout,
            workoutTrack: decodeTrack(for: pair.workout),
            overnightSession: pair.overnight,
            recentOvernightSessions: recent,
            userMaxHR: hr.maxHR,
            userRestingHR: hr.restingHR,
            userLTHR: hr.lthr,
            units: hr.units,
            liveLoadSnapshot: load
        )
        try await report.generate(to: pdfURL)
        return .ok(pdfURL)
    }

    private static func renderWorkoutReport(_ workout: HRVSession?, to pdfURL: URL, hr: ReportHRSettings) async throws -> RenderOutcome {
        guard let workout else {
            return .failed(String(localized: "No recent workout to report on. Finish a workout first.", bundle: LanguageManager.appBundle))
        }
        let report = WorkoutPDFReport(
            session: workout,
            track: decodeTrack(for: workout),
            userMaxHR: hr.maxHR,
            userRestingHR: hr.restingHR,
            userLTHR: hr.lthr,
            units: hr.units
        )
        try await report.generate(to: pdfURL)
        return .ok(pdfURL)
    }

    static func decodeTrack(for session: HRVSession) -> [CLLocation] {
        guard let polyline = session.workoutMetadata?.gpsPolyline else { return [] }
        return GPXExporter.decode(polyline: polyline, startDate: session.startDate, duration: session.duration ?? 0)
    }
}
