import CoreLocation
import Foundation
import PDFKit
import UIKit

// MARK: - Holistic Daily Report
//
// Combined workout + recovery PDF that tells the
// dose-response story in a single document. Page 1 fuses today's
// morning recovery state with today's training output and explains
// the loop in plain English ("you absorbed the load" / "you pushed
// the edge — back off tomorrow"). Page 2 breaks down a combined
// readiness score into its contributions. Subsequent pages are the
// upgraded WorkoutPDFReport pages, merged via PDFKit composition so
// the deep-dive content reuses the existing renderer without
// touching it.
//
// Why a separate file: this report has its own conceptual axis (the
// LOOP — recovery × training × adaptation), and PDFKit composition
// keeps the upstream renderer untouched. Adding the loop logic to
// WorkoutPDFReport would conflate single-session analysis with the
// daily-state synthesis. They're different products.
//
// Fallback behaviour: if no overnight session exists for "today"
// (e.g., evening workout with no morning HRV reading), render the
// standalone WorkoutPDFReport instead — the loop story can't be
// told without both halves.
/// Immutable after construction, so it is `Sendable` and renders on whatever
/// task the caller detaches; the drawing APIs are thread-safe.
final class HolisticDailyReport: Sendable {
    // MARK: Config — mirrors WorkoutPDFReport.Config so the unique
    // pages share the same visual vocabulary as the deep-dive pages
    // they sit on top of.

    struct Config: Sendable {
        let pageSize: CGSize = CGSize(width: 612, height: 792)
        let margin: CGFloat = 36
        let titleFont = UIFont.systemFont(ofSize: 22, weight: .heavy)
        let heroFont = UIFont.systemFont(ofSize: 26, weight: .heavy)
        let sectionFont = UIFont.systemFont(ofSize: 11, weight: .bold)
        let bodyFont = UIFont.systemFont(ofSize: 11, weight: .regular)
        let captionFont = UIFont.systemFont(ofSize: 9, weight: .regular)
        let monoFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let primary = UIColor(red: 0.79, green: 0.33, blue: 0.25, alpha: 1.0)
        let sage = UIColor(red: 0.20, green: 0.55, blue: 0.35, alpha: 1.0)
        let amber = UIColor(red: 0.55, green: 0.45, blue: 0.30, alpha: 1.0)
        let textPrimary = UIColor(white: 0.10, alpha: 1.0)
        let textSecondary = UIColor(white: 0.35, alpha: 1.0)
        let textTertiary = UIColor(white: 0.55, alpha: 1.0)
        let divider = UIColor(white: 0.88, alpha: 1.0)
    }

    // MARK: Inputs

    let workoutSession: HRVSession
    let workoutTrack: [CLLocation]
    /// Optional — if nil, the loop story degrades to workout-only and
    /// the merged output drops to just the WorkoutPDFReport pages.
    let overnightSession: HRVSession?
    /// Optional — last 7-30 days of overnight sessions for baseline
    /// computation (HRV trend, sleep trend). Used by Page 1 to render
    /// "vs baseline" deltas. Empty array means no comparisons.
    let recentOvernightSessions: [HRVSession]
    let userMaxHR: Int
    let userRestingHR: Int
    let userLTHR: Int
    let units: UnitsPreference
    /// The user's temperature unit, for the score factor lines rebuilt from
    /// their stored numbers.
    let temperatureUnit: TemperatureUnit
    let config: Config
    /// Snapshot of the canonical training-load value captured on the
    /// MainActor BEFORE this report enters its (typically `Task.detached`)
    /// render path. Stored as an immutable value type so render-time
    /// reads need no actor hop and no `MainActor.assumeIsolated` trap.
    ///
    /// Crash guard: reading
    /// `TrainingLoadRegistry.live()` inside the renderer via
    /// `MainActor.assumeIsolated` traps. PDF generation runs from
    /// `Task.detached(priority: .userInitiated)` (see
    /// `WorkoutRecorder+Lifecycle.generateHolisticReport`), so `assumeIsolated`
    /// triggers a fatal trap the moment the render touches training
    /// load. The caller captures the value on MainActor at
    /// construction time; renderers consume the stored snapshot.
    let liveLoadSnapshot: TrainingLoadRegistry.TrainingLoad?

    init(
        workoutSession: HRVSession,
        workoutTrack: [CLLocation],
        overnightSession: HRVSession?,
        recentOvernightSessions: [HRVSession] = [],
        userMaxHR: Int,
        userRestingHR: Int,
        userLTHR: Int,
        units: UnitsPreference,
        temperatureUnit: TemperatureUnit = .regionDefault,
        liveLoadSnapshot: TrainingLoadRegistry.TrainingLoad? = nil,
        config: Config = Config()
    ) {
        self.workoutSession = workoutSession
        self.workoutTrack = workoutTrack
        self.overnightSession = overnightSession
        self.recentOvernightSessions = recentOvernightSessions
        self.userMaxHR = userMaxHR
        self.userRestingHR = userRestingHR
        self.userLTHR = userLTHR
        self.units = units
        self.temperatureUnit = temperatureUnit
        // Today's live load only belongs on today's report; a past day's
        // report keeps the load frozen with that day's sessions.
        let isToday = Calendar.current.isDateInToday(workoutSession.endDate ?? workoutSession.startDate)
        self.liveLoadSnapshot = isToday ? liveLoadSnapshot : nil
        self.config = config
    }

    // MARK: Entry point

    /// Generates the combined PDF. Renders the unique pages 1+2 to a
    /// temp file, generates the upgraded WorkoutPDFReport to another
    /// temp, then merges via PDFKit so the final document is one
    /// continuous PDF.
    ///
    /// Each temp is removed as soon as it exists, whatever fails after it:
    /// the workout PDF can hold the GPS track and health data.
    func generate(to url: URL) async throws {
        let workoutTempURL = try await renderWorkoutPDF()
        defer { Self.removeTemp(workoutTempURL) }
        let coverTempURL = try renderCoverPDF()
        defer { Self.removeTemp(coverTempURL) }
        try mergePDFs(cover: coverTempURL, workout: workoutTempURL, to: url)
    }

    private static func removeTemp(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        _ = attempt("HolisticDailyReport.remove") { try FileManager.default.removeItem(at: url) }
    }

    /// The deep-dive half, rendered async because of the map snapshot.
    private func renderWorkoutPDF() async throws -> URL {
        // Render WorkoutPDFReport first (async because of map snapshot)
        let workoutTempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("holistic-workout-\(UUID().uuidString.prefix(8)).pdf")
        let workoutReport = WorkoutPDFReport(
            session: workoutSession,
            track: workoutTrack,
            userMaxHR: userMaxHR,
            userRestingHR: userRestingHR,
            userLTHR: userLTHR,
            units: units
        )
        do {
            try await workoutReport.generate(to: workoutTempURL)
        } catch {
            Self.removeTemp(workoutTempURL)
            throw error
        }
        return workoutTempURL
    }

    /// Pages 1 and 2, which only this report draws.
    private func renderCoverPDF() throws -> URL {
        // Render the unique pages (1, 2) to a separate temp file
        let coverTempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("holistic-cover-\(UUID().uuidString.prefix(8)).pdf")
        let coverRenderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: config.pageSize))
        do {
            try coverRenderer.writePDF(to: coverTempURL) { ctx in
                drawTodayInOneGlancePage(ctx: ctx)
                drawWhyYourScorePage(ctx: ctx)
            }
        } catch {
            Self.removeTemp(coverTempURL)
            throw error
        }
        return coverTempURL
    }

    /// Cover pages first, then the workout deep-dive pages.
    private func mergePDFs(cover coverTempURL: URL, workout workoutTempURL: URL, to url: URL) throws {
        // Merge: cover pages first, then workout deep-dive pages
        guard let coverDoc = PDFDocument(url: coverTempURL),
              let workoutDoc = PDFDocument(url: workoutTempURL)
        else {
            // PDFDocument failed to open one of the temps — fall back to just
            // the workout PDF (still better than nothing), but log it: the
            // user silently loses the loop-story + score pages otherwise.
            debugLog("[HolisticDailyReport] ⚠️ PDFDocument failed to open a temp (cover=\(PDFDocument(url: coverTempURL) != nil), workout=\(PDFDocument(url: workoutTempURL) != nil)) — falling back to workout-only report", level: .warning)
            try FileManager.default.copyItem(at: workoutTempURL, to: url)
            return
        }
        let combined = PDFDocument()
        let afterCover = appendPages(of: coverDoc, to: combined, from: 0)
        _ = appendPages(of: workoutDoc, to: combined, from: afterCover)
        if !combined.write(to: url) {
            // Write failed — fall back to the workout-only PDF (logged: the
            // combined report is incomplete when this fires).
            debugLog("[HolisticDailyReport] ⚠️ combined PDF write failed — falling back to workout-only report", level: .warning)
            try FileManager.default.copyItem(at: workoutTempURL, to: url)
        }
    }

    /// Copies every page of `doc` into `combined`, starting at `index`, and
    /// returns the next free index.
    private func appendPages(of doc: PDFDocument, to combined: PDFDocument, from index: Int) -> Int {
        var index = index
        for i in 0 ..< doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            combined.insert(page, at: index)
            index += 1
        }
        return index
    }

    // MARK: - Loop verdict (delegates to shared DailyLoopAnalysis)

    /// Snapshot the canonical training-load value at report-generation
    /// time. Reads through `TrainingLoadRegistry.live()` so the report
    /// matches what the Dashboard's Load card shows at the moment the
    /// PDF is rendered, not the frozen morning-acceptance value.
    ///
    /// User report: "CTL 36.4 here vs 30 in the report".
    /// Root cause: this report reading `workoutSession.trainingSnapshot`
    /// (frozen at session acceptance, pre-walk) while the dashboard
    /// shows the live cache value (post-walk). Both numbers are
    /// "correct" for their store, but the user reasonably calls the
    /// report stale. So both read through `TrainingLoadRegistry`.
    /// Falls back to the frozen session snapshot only when no live
    /// data exists (cold cache on first launch).
    ///
    /// Returns a shape-compatible `TrainingContext` so existing call
    /// sites that already understand that type can stay shape-stable —
    /// the only thing that changes is the source.
    func trainingLoadForReport() -> TrainingContext? {
        // Read from the MainActor-captured snapshot
        // (`liveLoadSnapshot`) passed into the initializer. PDF
        // generation runs on a detached task (see
        // `WorkoutRecorder+Lifecycle.generateHolisticReport`); calling
        // `MainActor.assumeIsolated` here would trap. Caller
        // captures via `TrainingLoadRegistry.live()` on MainActor
        // BEFORE entering the detached task.
        if let live = liveLoadSnapshot {
            return TrainingContext(
                atl: live.atl,
                ctl: live.ctl,
                tsb: live.tsb,
                yesterdayTrimp: workoutSession.trainingSnapshot?.yesterdayTrimp ?? 0,
                vo2Max: workoutSession.trainingSnapshot?.vo2Max,
                daysSinceHardWorkout: workoutSession.trainingSnapshot?.daysSinceHardWorkout,
                recentWorkouts: workoutSession.trainingSnapshot?.recentWorkouts
            )
        }
        return workoutSession.trainingSnapshot
            ?? overnightSession?.trainingSnapshot
    }

    /// Human-readable "as of" line for the report header (`drawLoadAsOf`):
    /// tells the reader exactly what era the load numbers in this PDF are
    /// from — the "report says one thing, dashboard says another"
    /// confusion is a missing-disclosure problem, not a bad-data problem.
    func loadAsOfDisplay() -> String? {
        liveLoadSnapshot?.disclosure
    }

    /// Build the shared analysis once per render — both this PDF and
    /// the Dashboard SwiftUI card consume it so they cannot drift.
    ///
    /// The baseline is built only from nights up to the one reported, so a
    /// past day's report is not measured against nights that came after it.
    func analysis() -> DailyLoopAnalysis {
        let reportedNight = overnightSession?.startDate ?? workoutSession.startDate
        return DailyLoopAnalysis(
            workoutSession: workoutSession,
            overnightSession: overnightSession,
            recentOvernightSessions: recentOvernightSessions.filter { $0.startDate <= reportedNight },
            userMaxHR: userMaxHR
        )
    }

    /// PDF-side colour mapping for the analysis tone — kept here so
    /// the shared model stays UIKit-free.
    func toneColor(_ tone: DailyLoopAnalysis.VerdictTone) -> UIColor {
        switch tone {
        case .positive: config.sage
        case .neutral: config.amber
        case .caution: config.primary
        }
    }
}
