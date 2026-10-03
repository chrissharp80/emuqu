import Charts
import CoreLocation
import SwiftUI

// The Fitness-tab hero, the trajectory link card, the summary tiles and
// the recent-workouts list, split out of `FitnessTabView+Sections.swift`.

extension FitnessStrapSection {
    /// Fitness-tab hero. Loads the latest workout session (full, not index)
    /// and presents the session as a *story at a glance*: big sport icon,
    /// the headline number (distance), key badges (pace, elevation, peak
    /// HR, TRIMP, hrTSS), α1 band pill, a mini route polyline thumbnail
    /// when GPS is present, plus the α1-estimated LT1 if we captured one.
    /// Tap anywhere to open the full post-summary sheet so the hero
    /// doubles as the primary entry point into the detailed report.
    func heroCard(latest: SessionArchiveEntry?) -> some View {
        heroCardContent(latest: latest)
            .task(id: heroReloadKey) {
                // Refresh latest workout session whenever the archive's top
                // entry id changes (new recording, delete) OR the archive
                // version bumps (id-preserving rewrites from Re-smooth /
                // Re-analyze). Combining both inputs into a single Hashable
                // key lets `.task(id:)` refire across both cases, and
                // cancels a stale load when a newer one starts.
                await loadLatestWorkoutSession()
            }
    }

    @ViewBuilder
    private func heroCardContent(latest: SessionArchiveEntry?) -> some View {
        if let latest {
            if let full = latestWorkoutSession, full.id == latest.sessionId {
                // Rich hero — full session loaded, carries workoutMetadata.
                heroCardRich(session: full, latest: latest)
            } else {
                // Transitional placeholder while the full session loads
                // on first appear (or after an archive rewrite). Keeps
                // the tab from looking empty for ~a tick.
                heroCardPlaceholder(latest: latest)
            }
        } else {
            heroCardEmpty
        }
    }

    /// Trajectory entry point #2.
    /// Lives between the hero recap and the summary tile grid. Pushes
    /// the same Surface-2 destination as the Dashboard's Load chip so
    /// users on the Fitness tab can jump to fitness/fatigue/form
    /// without bouncing back to Dashboard.
    var trajectoryLinkCard: some View {
        // Show the actual fitness/fatigue/form trend inline,
        // not just a link. Reads the warmed daily training-load series;
        // when it's empty (cold cache / no workouts yet) the card degrades
        // to the original link-only label.
        let cutoff = Calendar.current.date(byAdding: .day, value: -45, to: Date()) ?? Date()
        let samples = trainingCache.samplesSince(cutoff)
        return NavigationLink {
            LoadTrajectoryLoader()
                .environment(collector)
        } label: {
            trajectoryCardLabel(samples)
        }
        .buttonStyle(.plain)
    }

    private func trajectoryCardLabel(_ samples: [TrainingMetricsCache.DaySample]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            trajectoryCardHeader
            if TrainingLoadVisibility.isPaused(settings) {
                Text(String(localized: "Training load paused", bundle: LanguageManager.appBundle))
                    .scaledFont(size: 12)
                    .foregroundStyle(AppTheme.textSecondary)
            } else if samples.count >= 2 {
                trajectorySparkline(samples)
            }
        }
        .padding(14)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var trajectoryCardTitles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "Load & Trajectory", bundle: LanguageManager.appBundle))
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
            Text(String(localized: "Fitness, fatigue, form — your training arc", bundle: LanguageManager.appBundle))
                .scaledFont(size: 12)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var trajectoryCardHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .scaledFont(size: 18, weight: .semibold)
                .foregroundStyle(AppTheme.primary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(AppTheme.primary.opacity(0.12))
                )
            trajectoryCardTitles
            Spacer()
            Image(systemName: "chevron.forward")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(AppTheme.textTertiary)
                .accessibilityHidden(true)
        }
    }

    /// Compact 45-day CTL (fitness) / ATL (fatigue) lines over a TSB (form)
    /// area — the inline exercise trend on the Fitness home.
    func trajectorySparkline(_ samples: [TrainingMetricsCache.DaySample]) -> some View {
        Chart(samples, id: \.date) { sample in
            AreaMark(
                x: .value("Date", sample.date),
                yStart: .value("Zero", 0),
                yEnd: .value("TSB", sample.tsb)
            )
            .foregroundStyle(
                (sample.tsb >= 0 ? AppTheme.wongOptimal : AppTheme.textTertiary).opacity(0.15)
            )
            trajectoryLine(sample: sample, value: sample.atl, series: "ATL", tint: AppTheme.wongCaution, width: 1.5)
            trajectoryLine(sample: sample, value: sample.ctl, series: "CTL", tint: AppTheme.wongGood, width: 2)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 56)
        .accessibilityLabel(Text(String(localized: "Training load trend, last 45 days", bundle: LanguageManager.appBundle)))
    }

    /// Empty-state hero — big sport icon, inviting copy, single CTA.
    var heroCardEmpty: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.run.circle.fill")
                .scaledFont(size: 48)
                .foregroundStyle(AppTheme.fitnessAccent)
                // Decorative empty-state art; "No workouts yet" directly below
                // carries the meaning. Without this VoiceOver reads
                // "figure.run.circle.fill".
                .accessibilityHidden(true)
            Text(String(localized: "No workouts yet", bundle: LanguageManager.appBundle))
                .font(.title3.weight(.semibold))
            Text(String(localized: "Pick a sport and tap Start above to record your first session.", bundle: LanguageManager.appBundle))
                .font(.callout)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    func heroCardPlaceholder(latest: SessionArchiveEntry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: SessionType.workout.icon)
                .font(.title2)
                .foregroundStyle(AppTheme.fitnessAccent)
                .frame(width: 44, height: 44)
                .background(AppTheme.fitnessAccent.opacity(0.15))
                .clipShape(Circle())
            placeholderCaption(latest: latest)
            Spacer()
            if !latestWorkoutLoadFailed {
                ProgressView().scaleEffect(0.7)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func placeholderCaption(latest: SessionArchiveEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "Last workout", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            Text(latestWorkoutLoadFailed
                ? String(localized: "Couldn't load this workout.", bundle: LanguageManager.appBundle)
                : relativeDate(latest.endDate ?? latest.date))
                .font(.subheadline.weight(.semibold))
        }
    }

    func heroCardRich(session: HRVSession, latest: SessionArchiveEntry) -> some View {
        let facts = heroFacts(session: session)
        return Button {
            // Tapping the hero opens the full summary sheet — most users
            // will want the report, not just the card, so the whole card
            // is the affordance.
            lastCompletedSession = session
        } label: {
            heroCardBody(session: session, latest: latest, facts: facts)
        }
        .buttonStyle(.plain)
    }

    private func heroCardBody(session: HRVSession, latest: SessionArchiveEntry, facts: HeroFacts) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heroTopRow(sport: facts.sport, latest: latest)
            heroHeadline(facts: facts)
            // Mini polyline preview when we have GPS
            if let polyline = facts.polyline {
                heroPolylinePreview(polyline: polyline, startDate: session.startDate, duration: session.duration)
            }
            // Badges — a compact "why this workout mattered" row
            heroBadgesRow(
                peakHR: facts.peakHR,
                elevation: facts.elevationGain,
                alpha1Avg: facts.alpha1Avg,
                trimp: facts.preferredLoad?.value,
                loadSource: facts.preferredLoad?.source,
                hrTSS: facts.hrTSS
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(HeroCardChrome())
    }

    /// Gradient ground, hairline accent border, rounded clip.
    private struct HeroCardChrome: ViewModifier {
        func body(content: Content) -> some View {
            content
                .background(
                    LinearGradient(
                        colors: [AppTheme.cardBackground, AppTheme.cardBackground.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(AppTheme.fitnessAccent.opacity(0.18), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    /// Everything the hero card renders, resolved once so the view body stays a
    /// layout description rather than a mix of layout and arithmetic.
    struct HeroFacts {
        let sport: Sport
        let distance: String
        let duration: String
        let pace: String?
        let peakHR: String?
        let alpha1Avg: Double?
        let preferredLoad: (value: Double, source: WorkoutMetadata.TrainingLoadSource)?
        let hrTSS: Double?
        let elevationGain: Double?
        let polyline: Data?
    }

    private func heroFacts(session: HRVSession) -> HeroFacts {
        let meta = session.workoutMetadata
        // Prefer powerTSS over luciaTRIMP via the shared resolver.
        // Power-equipped sessions show their accurate load number on the
        // hero card, matching the post-summary tile.
        return HeroFacts(
            sport: meta?.sport ?? .walk,
            distance: meta?.distanceMeters.map { units.formatDistance(meters: $0) } ?? "—",
            duration: Self.heroDurationString(session.duration),
            pace: heroPaceString(session: session, meta: meta),
            peakHR: meta?.samples?.compactMap { $0.heartRate }.max().map { String(localized: "\($0) bpm", bundle: LanguageManager.appBundle) },
            alpha1Avg: Self.heroAlpha1Average(meta: meta),
            preferredLoad: meta?.preferredTrainingLoad,
            hrTSS: meta?.hrTSS,
            elevationGain: meta?.elevationGainMeters,
            polyline: meta?.gpsPolyline
        )
    }

    private static func heroDurationString(_ duration: TimeInterval?) -> String {
        guard let d = duration else { return "—" }
        let s = Int(d)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    private func heroPaceString(session: HRVSession, meta: WorkoutMetadata?) -> String? {
        guard let d = meta?.distanceMeters, d > 100, let dur = session.duration, dur > 10 else { return nil }
        return units.formatPace(elapsedSec: Int(dur), distanceMeters: d)
    }

    private static func heroAlpha1Average(meta: WorkoutMetadata?) -> Double? {
        guard let vals = meta?.samples?.compactMap(\.alpha1), !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    /// Sport + relative time.
    private func heroTopRow(sport: Sport, latest: SessionArchiveEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: sport.icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.fitnessAccent)
                .frame(width: 40, height: 40)
                .background(AppTheme.fitnessAccent.opacity(0.14))
                .clipShape(Circle())
            heroSportLabel(sport: sport, latest: latest)
            Spacer()
            Image(systemName: "chevron.forward")
                .accessibilityHidden(true)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private func heroSportLabel(sport: Sport, latest: SessionArchiveEntry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(sport.localizedName.uppercased())
                .font(.caption.weight(.heavy))
                .tracking(1.0)
                .foregroundStyle(AppTheme.fitnessAccent)
            Text(relativeDate(latest.endDate ?? latest.date))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    /// Small visual hook — GPS polyline rendered as a stroke on a tight
    /// bounding box. Not a real map tile (too expensive to load on
    /// every hero render); a quick line trace communicates "you ran a
    /// loop / out-and-back / point-to-point" at a glance.
    @ViewBuilder
    func heroPolylinePreview(polyline: Data, startDate: Date, duration: TimeInterval?) -> some View {
        let decoded = GPXExporter.decode(polyline: polyline, startDate: startDate, duration: duration)
        if decoded.count >= 2 {
            polylineTrace(coords: decoded.map(\.coordinate))
        }
    }

    private func polylineTrace(coords: [CLLocationCoordinate2D]) -> some View {
        GeometryReader { geo in
            Path { Self.tracePolyline(&$0, coords: coords, in: geo.size) }
                .stroke(AppTheme.fitnessAccent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 64)
        .padding(.vertical, 2)
    }

    /// `decoded.count >= 2` upstream guarantees non-empty, but
    /// force-unwrap is a spec finding. Use guard so any future change to the
    /// gate condition can't introduce a crash here.
    private static func tracePolyline(_ path: inout Path, coords: [CLLocationCoordinate2D], in size: CGSize) {
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max()
        else { return }
        let latRange = max(0.0001, maxLat - minLat)
        let lonRange = max(0.0001, maxLon - minLon)
        for (i, c) in coords.enumerated() {
            let x = CGFloat((c.longitude - minLon) / lonRange) * size.width
            let y = (1 - CGFloat((c.latitude - minLat) / latRange)) * size.height
            let p = CGPoint(x: x, y: y)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
    }

    /// A row of compact metric pills for the hero. Only renders the ones
    /// we actually have data for — short walks with no HR still get a
    /// clean hero instead of "— — —" placeholders.
    func heroBadgesRow(
        peakHR: String?,
        elevation: Double?,
        alpha1Avg: Double?,
        trimp: Double?,
        loadSource: WorkoutMetadata.TrainingLoadSource?,
        hrTSS: Double?
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            heroBadges(
                peakHR: peakHR, elevation: elevation, alpha1Avg: alpha1Avg,
                trimp: trimp, loadSource: loadSource, hrTSS: hrTSS
            )
        }
    }

    @ViewBuilder
    private func heroBadges(
        peakHR: String?,
        elevation: Double?,
        alpha1Avg: Double?,
        trimp: Double?,
        loadSource: WorkoutMetadata.TrainingLoadSource?,
        hrTSS: Double?
    ) -> some View {
        HStack(spacing: 8) {
            if let peakHR {
                heroBadge(icon: "heart.fill", label: peakHR, color: AppTheme.fitnessAccent)
            }
            if let elevation, elevation >= 5 {
                heroBadge(icon: "mountain.2.fill", label: units.formatElevation(meters: elevation), color: AppTheme.sage)
            }
            if let alpha1Avg {
                heroBadge(icon: "waveform.path.ecg", label: String(format: "α1 %.2f", locale: .current, alpha1Avg), color: AppTheme.dustyRose)
            }
            if let trimp {
                loadBadge(trimp: trimp, loadSource: loadSource)
            }
            if let hrTSS {
                heroBadge(icon: "speedometer", label: String(localized: "hrTSS \(Int(hrTSS))", bundle: LanguageManager.appBundle), color: AppTheme.fitnessAccent)
            }
        }
    }

    /// TRIMP color is data-driven, not a fixed orange.
    /// The user reads orange as "warning" so a moderate session being colored
    /// orange every time was misleading. Only flips to amber when TRIMP
    /// indicates a genuinely hard session (≥150 in TRIMP-Lucia units → ~Z3
    /// sustained for 60min, or ~Z4 for 30min); below that it sits in the same
    /// fitness-accent palette as the rest of the badge row.
    ///
    /// This value is preferredTrainingLoad (power/HR
    /// TSS-preferred), not raw Lucia TRIMP, so label it by source (LOAD vs
    /// TRIMP) to match the post-summary tile.
    private func loadBadge(trimp: Double, loadSource: WorkoutMetadata.TrainingLoadSource?) -> some View {
        let trimpColor: Color = trimp >= 150 ? AppTheme.wongCaution : AppTheme.fitnessAccent
        let label = String(localized: "\(loadSource?.displayLabel ?? "LOAD") \(Int(trimp))", bundle: LanguageManager.appBundle)
        return heroBadge(icon: "flame.fill", label: label, color: trimpColor)
    }

    func heroBadge(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption.weight(.semibold))
            Text(label).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(color)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    /// Composite Hashable key driving the hero's `.task(id:)` refresh.
    /// Combining the latest entry's UUID with the archive version means
    /// re-analyze / re-smooth rewrites (same id, new version) still
    /// cause the task to fire.
    var heroReloadKey: String {
        let id = recentWorkoutEntries().first?.sessionId.uuidString ?? "empty"
        return "\(id)-\(archiveSignal.version)"
    }

    /// Awaited inside `.task(id:)`, so a load superseded by a newer key is
    /// dropped instead of overwriting the newer result. A nil read marks the
    /// load failed, which swaps the placeholder spinner for a message.
    func loadLatestWorkoutSession() async {
        guard let first = recentWorkoutEntries().first else {
            latestWorkoutSession = nil
            latestWorkoutLoadFailed = false
            return
        }
        // Lightweight (no rrSeries, no hash check) and detached: the hero
        // reads only fields outside rrSeries, and the tab must not wait on
        // archive I/O on the main actor.
        let archive = collector.archive
        let sessionId = first.sessionId
        latestWorkoutLoadFailed = false
        let full = await Task.detached(priority: .userInitiated) {
            archive.retrieveLightweightOrLog(sessionId, caller: "Fitness.loadLatest")
        }.value
        guard !Task.isCancelled else { return }
        latestWorkoutSession = full
        latestWorkoutLoadFailed = full == nil
    }

    @ViewBuilder
    func summaryTileGrid(entries: [SessionArchiveEntry]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            summaryTile(title: String(localized: "Workouts (7d)", bundle: LanguageManager.appBundle), value: "\(entries.filter { withinDays($0.date, 7) }.count)")
            summaryTile(title: String(localized: "Workouts (30d)", bundle: LanguageManager.appBundle), value: "\(entries.filter { withinDays($0.date, 30) }.count)")
            weeklyLoadTile
            meanHRRTile
        }
    }

    /// computeWeeklyTrimp sums the daily effectiveLoad
    /// (power/HR TSS-preferred), same metric as the Load & Trajectory weekly
    /// card → "LOAD", not "TRIMP".
    private var weeklyLoadTile: some View {
        if TrainingLoadVisibility.isPaused(settings) {
            return summaryTile(
                title: String(localized: "Weekly LOAD", bundle: LanguageManager.appBundle),
                value: "—",
                note: String(localized: "Paused", bundle: LanguageManager.appBundle)
            )
        }
        let weeklyTrimp = computeWeeklyTrimp()
        return summaryTile(
            title: String(localized: "Weekly LOAD", bundle: LanguageManager.appBundle),
            value: weeklyTrimp.map { "\(Int($0.rounded()))" } ?? "—",
            note: weeklyTrimp == nil ? String(localized: "no workouts in 7d", bundle: LanguageManager.appBundle) : String(localized: "last 7 days", bundle: LanguageManager.appBundle)
        )
    }

    /// Reads the value computed off the render path in
    /// `loadWorkoutElevationTotals`.
    private var meanHRRTile: some View {
        let meanHRR = meanHRR1m7d
        return summaryTile(
            title: String(localized: "Mean HRR@1m", bundle: LanguageManager.appBundle),
            value: meanHRR.map { String(localized: "\(Int($0.rounded())) bpm", bundle: LanguageManager.appBundle) } ?? "—",
            note: meanHRR == nil ? String(localized: "no HRR captured 7d", bundle: LanguageManager.appBundle) : String(localized: "last 7 days", bundle: LanguageManager.appBundle)
        )
    }

    /// Sum of TRIMP across the last 7 days from the training-metrics cache.
    /// Returns nil when the cache is cold OR there are zero workouts in
    /// the window — distinct from "0 trimp" which would imply we recorded
    /// workouts but they all somehow had TRIMP=0.
    func computeWeeklyTrimp() -> Double? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())
            ?? Date().addingTimeInterval(-7 * 24 * 3600)
        let samples = AppDependencies.current.analysis.trainingMetricsCache.samplesSince(cutoff)
        let withWork = samples.filter { $0.trimp > 0 }
        guard !withWork.isEmpty else { return nil }
        return withWork.reduce(0.0) { $0 + $1.trimp }
    }

    func summaryTile(title: String, value: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            Text(value)
                .font(.title2.weight(.semibold))
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppTheme.cardBackground)
        .cornerRadius(12)
    }

    @ViewBuilder
    func recentWorkoutsList(entries: [SessionArchiveEntry]) -> some View {
        if !entries.isEmpty {
            recentWorkoutsColumn(entries: entries)
        }
    }

    private func recentWorkoutsColumn(entries: [SessionArchiveEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Recent", bundle: LanguageManager.appBundle))
                .font(.headline)
            ForEach(entries.prefix(5), id: \.sessionId) { entry in
                recentRow(entry: entry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func recentRow(entry: SessionArchiveEntry) -> some View {
        Button {
            openRecentWorkout(entry)
        } label: {
            recentRowLabel(entry: entry)
        }
        .buttonStyle(.plain)
        .contextMenu { deleteWorkoutButton(entry, title: String(localized: "Delete Workout", bundle: LanguageManager.appBundle)) }
    }

    /// Not a sync `retrieve(...)` on main thread inside the
    /// button action. For workout sessions the rrSeries is what makes the file
    /// heavy (1+ MB on long activities), so that tap visibly froze the row while
    /// the SHA256 + decrypt ran. The summary view tolerates a lightweight load
    /// and lazy-fetches details if needed.
    private func openRecentWorkout(_ entry: SessionArchiveEntry) {
        let archive = collector.archive
        let id = entry.sessionId
        Task { @MainActor in
            let session = await Task.detached(priority: .userInitiated) {
                archive.retrieveLightweightOrLog(id, caller: "Fitness.recentRow")
            }.value
            if let session {
                selectedHistorySession = session
            }
        }
    }

    private func deleteWorkoutButton(_ entry: SessionArchiveEntry, title: String) -> some View {
        Button(role: .destructive) {
            deleteWorkout(entry.sessionId)
        } label: {
            Label(title, systemImage: "trash")
        }
    }

    private func recentRowLabel(entry: SessionArchiveEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: SessionType.workout.icon)
                .foregroundStyle(AppTheme.fitnessAccent)
                .frame(width: 28)
                .accessibilityHidden(true)
            recentRowTitle(entry: entry)
            Spacer()
            if let hr = entry.meanHR {
                Text(String(localized: "\(Int(hr)) bpm", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Image(systemName: "chevron.forward")
                .accessibilityHidden(true)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textTertiary)
        }
        .padding(12)
        .background(AppTheme.cardBackground)
        .cornerRadius(10)
    }

    private func recentRowTitle(entry: SessionArchiveEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text((entry.notes?.isEmpty == false ? entry.notes : nil) ?? String(localized: "Workout", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.textPrimary)
            Text(formattedDate(entry.date))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

}

// MARK: - File-scope helpers
//
// Kept out of FitnessTabView. Each names no member of the
// type and calls nothing that stayed behind, so none needed to be inside
// it. `private` at file scope is fileprivate, so every call site in this
// file resolves exactly as before.

private func trajectoryLine(sample: TrainingMetricsCache.DaySample, value: Double, series: String, tint: Color, width: CGFloat) -> some ChartContent {
    LineMark(
        x: .value("Date", sample.date),
        y: .value(series, value),
        series: .value("Series", series)
    )
    .foregroundStyle(tint)
    .lineStyle(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    .interpolationMethod(.monotone)
}

/// Distance + duration.
@MainActor
private func heroHeadline(facts: FitnessStrapSection.HeroFacts) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(facts.distance)
            .scaledFont(size: 40, weight: .heavy)
            .foregroundStyle(AppTheme.textPrimary)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
        Spacer()
        heroDurationAndPace(facts: facts)
    }
}

@ViewBuilder
@MainActor
private func heroDurationAndPace(facts: FitnessStrapSection.HeroFacts) -> some View {
    VStack(alignment: .trailing, spacing: 0) {
        Text(facts.duration)
            .font(.title3.monospacedDigit().weight(.semibold))
        if let pace = facts.pace {
            Text(pace)
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.textSecondary)
        }
    }
}
