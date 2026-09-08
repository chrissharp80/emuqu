import CoreLocation
import Foundation

/// Comprehensive post-workout AI Coach report.
///
/// Renders an HRVSession + workoutMetadata into a single Markdown
/// document a coach can read end-to-end. Pure function — given a
/// session it produces the same report every time, so the report
/// can either be saved or regenerated on demand from the historical
/// entry without staleness concerns.
///
/// What's in it:
///   • Header: sport, date, distance, duration, route name (if any).
///   • Effort summary: avg/peak HR, zone breakdown, TRIMP, hrTSS.
///   • Pace + cadence: avg, splits, reverse split delta, GAP for the
///     last few splits, cadence drift.
///   • Aerobic physiology: α1 distribution + first AT1 crossing, HR
///     drift, aerobic decoupling.
///   • HRR: 1-min and 2-min recovery from peak.
///   • Elevation: gain, loss, peak grade.
///   • Power: avg, normalized, IF, VI, powerTSS (when foot-pod was
///     active).
///   • Comparisons: sport-wide baseline (from history) and route-
///     specific baseline (when bound).
///   • Training load context: ATL/CTL/TSB/ACWR going into and after
///     the session.
///   • Recommendations: tomorrow's training advice based on TSB
///     trajectory + recovery hours estimate.
///
/// The report is written in plain English — coach voice, not a stat
/// dump — so a non-physiologist gets what each number means and how
/// it compares to recent context. Numbers are honest about missing
/// data: "no HRR captured" rather than fabricating a value.
enum CoachReportGenerator {
    // Members here are internal, not private: the report's sections live in
    // CoachReportGenerator+Sections.swift and +Conversational.swift, and Swift's
    // `private` does not reach across files. Same convention as
    // PDFReportGenerator+Sections.swift.

    /// Build the Markdown report. Inputs:
    ///   • `session` — the workout session being reported on.
    ///   • `archive` — optional; when present, used to compute
    ///     sport-wide and route-specific baselines from history.
    ///   • `units` — user's resolved unit preference for distance /
    ///     pace / elevation.
    ///   • `userMaxHR`, `userRestingHR` — for zone bin computation.
    @MainActor
    /// Archive-walking entry point for the full clinical report.
    ///
    /// `preferredTrainingLoad` is captured HERE, before handing off
    /// to the nonisolated overload. Reading it inside `effortSection` via
    /// `MainActor.assumeIsolated` traps when render is invoked from a
    /// detached task. Same shape as `HolisticDailyReport.liveLoadSnapshot`.
    static func render(
        session: HRVSession,
        archive: SessionArchive?,
        units: UnitsPreference,
        userMaxHR: Int,
        userRestingHR: Int
    ) -> String {
        let past: [HRVSession] = archive.map { archive in
            archive.entries
                .filter { $0.sessionType == .workout && $0.sessionId != session.id }
                .compactMap { try? archive.retrieveLightweight($0.sessionId) }
        } ?? []
        let preferredLoad: PreferredLoadSnapshot? = session.workoutMetadata?.preferredTrainingLoad.map {
            PreferredLoadSnapshot(value: $0.value, source: $0.source)
        }
        return render(
            session: session,
            pastWorkouts: past,
            units: units,
            userMaxHR: userMaxHR,
            userRestingHR: userRestingHR,
            preferredLoad: preferredLoad
        )
    }

    /// Pre-fetched-history entry point for the full clinical report.
    ///
    /// Symmetric with the `pastWorkouts:` overload of
    /// `renderConversationalSummary` — both let callers do the archive walk once
    /// on the MainActor and run the rendering itself off-actor.
    ///
    /// The section order is the document order; `nil` drops a section out.
    static func render(
        session: HRVSession,
        pastWorkouts: [HRVSession],
        units: UnitsPreference,
        userMaxHR: Int,
        userRestingHR: Int,
        preferredLoad: PreferredLoadSnapshot? = nil
    ) -> String {
        guard let meta = session.workoutMetadata else {
            return "# Coach Report\n\nNo workout metadata for this session — nothing to report on.\n"
        }
        let sections: [String?] = [
            headerSection(session: session, meta: meta, units: units),
            effortSection(session: session, meta: meta, userMaxHR: userMaxHR, userRestingHR: userRestingHR, preferredLoad: preferredLoad),
            paceCadenceSection(meta: meta, units: units),
            aerobicPhysiologySection(meta: meta),
            hrrSection(meta: meta),
            elevationSection(meta: meta, units: units),
            (meta.averagePowerWatts ?? 0) > 0 ? powerSection(meta: meta) : nil,
            pastWorkouts.isEmpty ? nil : comparisonsSection(session: session, meta: meta, pastWorkouts: pastWorkouts, units: units),
            trainingLoadSection(session: session),
            recommendationsSection(session: session, meta: meta),
            footer()
        ]
        return sections.compactMap { $0 }.joined(separator: "\n\n")
    }

    static let pdfFootnote = "---\n\n*Full clinical breakdown — splits, charts, route map, methodology — is in the attached PDF. Numbers in this email are summarised; the PDF is the source of truth.*"

    // MARK: - Conversational helpers

    // MARK: - Sections

    /// Plain-Sendable mirror of `WorkoutMetadata.preferredTrainingLoad`
    /// so nonisolated renderers can carry the value across actor
    /// boundaries without re-touching the MainActor-isolated source, so
    /// this file needs no `MainActor.assumeIsolated`.
    struct PreferredLoadSnapshot: Sendable {
        let value: Double
        let source: WorkoutMetadata.TrainingLoadSource
    }

    // MARK: - Formatters

    static func formatDistance(_ meters: Double?, units: UnitsPreference) -> String {
        guard let m = meters, m > 0 else { return "—" }
        if units == .imperial {
            return String(format: "%.2f mi", locale: .current, m / 1609.344)
        }
        return String(format: "%.2f km", locale: .current, m / 1_000)
    }

    static func formatElevation(_ meters: Double, units: UnitsPreference) -> String {
        if units == .imperial {
            return "\(Int(round(meters * UnitConstants.feetPerMeter))) ft"
        }
        return "\(Int(round(meters))) m"
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    static func formatTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Section builders
//
