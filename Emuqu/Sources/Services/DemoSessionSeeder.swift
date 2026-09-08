import Foundation

/// Seeds one complete overnight recording so the app can be evaluated without
/// a chest strap.
///
/// ## Why this exists
///
/// Emuqu's every screen is downstream of a recording. Without one, a reviewer
/// sees empty states and cannot assess the product at all — and the reviewer
/// is exactly the person who will not have a Polar H10.
///
/// `docs/REVIEW.md` names a demo path for reviewers. Writing a
/// path into the document without an implementation would make it a false
/// claim; this makes it a true one.
///
/// ## What it produces
///
/// A synthetic but physiologically coherent night: RR intervals with a
/// realistic nocturnal HR curve and respiratory sinus arrhythmia, run through
/// the app's own analyser rather than carrying hand-written metrics. The
/// numbers a reviewer sees are therefore computed by the same code a real
/// recording uses — a fixture with pasted-in results would demo the UI while
/// bypassing everything underneath it.
///
/// Deliberately NOT wired into any production launch path. It is invoked from
/// Settings, writes one clearly-labelled session, and nothing calls it
/// automatically.
enum DemoSessionSeeder {
    /// Marks the session so it can be told apart from a real recording.
    static let demoTagName = "Demo"

    /// Beats for one night, at `intervalMs` mean spacing.
    ///
    /// Two components, both real properties of overnight HRV rather than
    /// decoration: a slow decline and recovery of heart rate across the night,
    /// and respiratory sinus arrhythmia — the beat-to-beat oscillation with
    /// breathing that is most of what RMSSD measures. A flat series with noise
    /// would produce metrics no real night produces.
    static func syntheticNight(
        beats: Int = 28_000,
        meanRR: Double = 1_050,
        startingAt start: Date
    ) -> [RRPoint] {
        var points: [RRPoint] = []
        points.reserveCapacity(beats)
        var elapsedMs: Int64 = 0
        for i in 0 ..< beats {
            let progress = Double(i) / Double(beats)
            // HR dips through the first third of the night and climbs before waking.
            let circadian = -60.0 * sin(progress * Double.pi)
            // Respiratory sinus arrhythmia: ~12 breaths/min against ~57 bpm.
            let respiratory = 28.0 * sin(Double(i) * 2 * Double.pi / 4.75)
            let rr = meanRR + circadian + respiratory
            let clamped = max(400.0, min(1_600.0, rr))
            points.append(RRPoint(t_ms: elapsedMs, rr_ms: Int(clamped.rounded())))
            elapsedMs += Int64(clamped.rounded())
        }
        return points
    }

    /// Build and archive a demo overnight session.
    ///
    /// Returns the session id so the caller can navigate to it.
    @MainActor
    @discardableResult
    static func seed(into archive: SessionArchive, analyzer: (RRSeries) async -> HRVAnalysisResult?) async throws -> UUID {
        let session = await buildSession(analyzer: analyzer)
        _ = try archive.archive(session)
        debugLog("[Demo] Seeded a demo overnight session "
            + "(\(session.rrSeries?.points.count ?? 0) beats)", level: .info)
        return session.id
    }

    /// One night, analysed by the real pipeline.
    ///
    /// A demo that pastes in metrics shows the UI working while proving
    /// nothing underneath it; running the synthetic beats through the same
    /// analyser a recording uses means the numbers on screen were computed,
    /// not authored.
    @MainActor
    private static func buildSession(analyzer: (RRSeries) async -> HRVAnalysisResult?) async -> HRVSession {
        let id = UUID()
        let end = Calendar.current.startOfDay(for: Date()).addingTimeInterval(7 * 3600)
        let start = end.addingTimeInterval(-8 * 3600)
        let series = RRSeries(points: syntheticNight(startingAt: start), sessionId: id, startDate: start)
        return HRVSession(
            id: id, startDate: start, endDate: end, state: .complete,
            sessionType: .overnight, rrSeries: series,
            analysisResult: await analyzer(series), artifactFlags: nil
        )
    }
}
