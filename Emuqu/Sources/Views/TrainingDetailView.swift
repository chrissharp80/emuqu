import Charts
import SwiftUI

/// Detailed training load view showing ATL/CTL trends and workout history
struct TrainingDetailView: View {
    @Environment(\.dependencies) var dependencies
    let trainingMetrics: HealthKitManager.TrainingMetrics?
    let trainingContext: TrainingContext?
    @State private var isRefreshing: Bool = false

    /// The four load numbers this screen renders. `acr` is optional because a
    /// short history can't produce an acute:chronic ratio yet.
    struct LoadMetrics {
        let atl: Double
        let ctl: Double
        let tsb: Double
        let acr: Double?

        init(_ m: HealthKitManager.TrainingMetrics) {
            self.init(atl: m.atl, ctl: m.ctl, tsb: m.tsb, acr: m.acuteChronicRatio)
        }

        init(_ c: TrainingContext) {
            self.init(atl: c.atl, ctl: c.ctl, tsb: c.tsb, acr: c.acuteChronicRatio)
        }

        init(atl: Double, ctl: Double, tsb: Double, acr: Double?) {
            self.atl = atl
            self.ctl = ctl
            self.tsb = tsb
            self.acr = acr
        }
    }

    private var metrics: LoadMetrics? {
        // Prefer the live cache, but DO NOT show a frozen
        // all-zero context as the source of truth when the live cache
        // exists. The frozen `trainingContext` is captured at session-
        // acceptance time; if HealthKit hadn't synced workouts yet
        // (common after an overnight crash), it's permanently atl=0/
        // ctl=0. Without this filter, the dashboard fell back to that
        // 0-context even when the live cache had real values, because
        // the priority order didn't account for a frozen-zero state.
        if let m = trainingMetrics, liveLooksReal(m) { return LoadMetrics(m) }
        if let c = trainingContext, frozenLooksReal(c) { return LoadMetrics(c) }
        // Both look empty / cold. Prefer live (it'll auto-refresh).
        if let m = trainingMetrics { return LoadMetrics(m) }
        if let c = trainingContext { return LoadMetrics(c) }
        return nil
    }

    private func liveLooksReal(_ m: HealthKitManager.TrainingMetrics) -> Bool {
        m.atl > 0 || m.ctl > 0 || m.recentWorkouts.isEmpty == false
    }

    private func frozenLooksReal(_ c: TrainingContext) -> Bool {
        c.atl > 0 || c.ctl > 0
    }

    var body: some View {
        withPageChrome(pageStack)
    }

    private var pageStack: some View {
        ScrollView {
            if TrainingLoadVisibility.isPaused(dependencies.app.settingsManager.settings) {
                TrainingLoadPausedCard().padding()
            } else {
                trainingCards
            }
        }
    }

    private var trainingCards: some View {
        VStack(spacing: 20) {
            monotonyBannerIfHigh

            // ACR Gauge Hero
            acrCard

            // ATL/CTL/TSB Stats
            metricsCard

            // Training Zones Explanation
            zonesExplanation

            // Recent Workouts — prefer live data (includes today, last 14 days)
            recentWorkoutsSection
        }
        .padding()
    }

    @ViewBuilder
    private var recentWorkoutsSection: some View {
        if let liveWorkouts = trainingMetrics?.recentWorkouts, !liveWorkouts.isEmpty {
            liveWorkoutsCard(liveWorkouts)
        } else if let context = trainingContext, let workouts = context.recentWorkouts, !workouts.isEmpty {
            recentWorkoutsCard(workouts)
        }
    }

    private func withPageChrome(_ content: some View) -> some View {
        content
            .background(AppTheme.background)
            .navigationTitle(String(localized: "Training Load", bundle: LanguageManager.appBundle))
            .navigationBarTitleDisplayMode(.large)
            .refreshable {
                await runRefresh()
            }
            .task { await refreshIfCold() }
    }

    /// Self-healing refresh: navigating here with a cold or missing cache
    /// repopulates it without the user tapping anything.
    private func refreshIfCold() async {
        // Auto-refresh on view appear when the
        // displayed metrics look like a cold/zero state. Self-
        // healing: the user navigates to the Training Load page
        // and the cache repopulates without them needing to
        // tap anything. The Refresh button below is the manual
        // escape hatch when something genuinely fails.
        if let m = metrics, m.atl == 0, m.ctl == 0 {
            await runRefresh()
        } else if metrics == nil {
            await runRefresh()
        }
    }

    /// Used by `.refreshable` (pull-to-refresh) and the auto-heal
    /// `.task` modifier. No explicit button — the priority-order fix
    /// in `metrics` plus the auto-fetch on view appear means the
    /// page is self-healing for all the cases the manual button was
    /// papering over.
    @MainActor
    private func runRefresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await dependencies.analysis.trainingMetricsCache.refresh(forMorningReading: false)
    }

    // MARK: - Foster Monotony Banner

    /// Foster (1998) monotony = mean(daily TRIMP) / SD(daily TRIMP) over
    /// 7 days. Values >2.0 mean training has been very same-y day-to-day
    /// (always similar intensity); paired with a heavy weekly load this
    /// is the classic accumulated-fatigue pattern. Surface as a banner
    /// only — not in the score — per the post-ACWR architecture.
    /// Foster monotony banner.
    ///
    /// Foster (1998) showed monotony >2.0 with high weekly load is associated
    /// with overtraining symptoms regardless of ACR. Surfaced as observational
    /// copy on Surface 2 — not factored into the recovery score (by design,
    /// training signals stay on this page, not the score). Hidden when monotony
    /// is in the normal range or daily-TRIMP history is too short to compute
    /// meaningfully.
    @ViewBuilder
    private var monotonyBannerIfHigh: some View {
        if let dailyTrimp = trainingMetrics?.dailyTrimp,
           let foster = RecoveryScoreCalculator.fosterMonotonyStrain(dailyTrimp: dailyTrimp),
           foster.monotony > 2.0,
           // Strain = weekly total × monotony. Floor at 200 — equivalent
           // to ~100 TRIMP/week × monotony 2.0 — so a casual user with
           // samey 30-TRIMP walks doesn't trigger the banner. This is
           // the "weekly load in top quartile" gate.
           foster.strain > 200 {
            monotonyBanner(foster)
        }
    }

    private func monotonyBanner(_ foster: (monotony: Double, strain: Double)) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "rectangle.split.3x1")
                .foregroundStyle(AppTheme.softGold)
                .font(.title3)
                .accessibilityHidden(true)
            monotonyBannerText(foster)
            Spacer(minLength: 4)
        }
        .padding(14)
        .background(AppTheme.softGold.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func monotonyBannerText(_ foster: (monotony: Double, strain: Double)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Your training has been unusually similar day-to-day this week", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(String(
                format: NSLocalizedString("Foster monotony %.1f over the last 7 days. Mixing intensities (one easy day, one hard day) helps your body absorb the work.", bundle: LanguageManager.appBundle, comment: "Monotony banner explanation"),
                locale: LanguageManager.appLocale,
                foster.monotony
            ))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - ACR Card

    private var acrCard: some View {
        VStack(spacing: 16) {
            Text(String(localized: "ACUTE:CHRONIC RATIO", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(1)

            acrReadout
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    @ViewBuilder
    private var acrReadout: some View {
        if let acr = metrics?.acr {
            acrGauge(acr)
        } else {
            acrPlaceholder
        }
    }

    @ViewBuilder
    private func acrGauge(_ acr: Double) -> some View {
        // Large ACR display
        Text(String(format: "%.2f", locale: LanguageManager.appLocale, acr))
            .font(.system(.largeTitle, design: .rounded))
            .bold()
            .minimumScaleFactor(0.5)
            .foregroundColor(acrColor(acr))

        Text(acrLabel(acr))
            .font(.headline)
            .foregroundColor(acrColor(acr))

        // Gauge bar
        ACRGaugeBar(acr: acr)
            .padding(.horizontal)
    }

    private var acrPlaceholder: some View {
        Text(String(localized: "--", bundle: LanguageManager.appBundle))
            .font(.system(.largeTitle, design: .rounded))
            .bold()
            .minimumScaleFactor(0.5)
            .foregroundColor(AppTheme.textTertiary)
    }

    // MARK: - Metrics Card

    private var metricsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "TRAINING METRICS", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(1)

            loadColumns
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    @ViewBuilder
    private var loadColumns: some View {
        if let m = metrics {
            loadColumnRow(m)
        } else {
            Text(String(localized: "No training data available", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textTertiary)
                .frame(maxWidth: .infinity)
        }
    }

    private func loadColumnRow(_ m: LoadMetrics) -> some View {
        HStack(spacing: 16) {
            MetricColumn(
                label: String(localized: "ATL", bundle: LanguageManager.appBundle),
                value: String(format: "%.0f", locale: LanguageManager.appLocale, m.atl),
                subtitle: String(localized: "Fatigue (7-day)", bundle: LanguageManager.appBundle),
                color: AppTheme.terracottaText
            )
            MetricColumn(
                label: String(localized: "CTL", bundle: LanguageManager.appBundle),
                value: String(format: "%.0f", locale: LanguageManager.appLocale, m.ctl),
                subtitle: String(localized: "Fitness (42-day)", bundle: LanguageManager.appBundle),
                color: AppTheme.sageText
            )
            MetricColumn(
                label: String(localized: "TSB", bundle: LanguageManager.appBundle),
                value: String(format: "%+.0f", locale: LanguageManager.appLocale, m.tsb),
                subtitle: String(localized: "Form", bundle: LanguageManager.appBundle),
                color: m.tsb >= 0 ? AppTheme.sageText : AppTheme.terracottaText
            )
        }
    }

    // MARK: - Zones Explanation

    /// Zone labels are descriptive ranges, not risk
    /// predictions. The colour bands carry the visual; the text honestly
    /// describes where the user is on the gauge.
    private var zoneRows: some View {
        VStack(spacing: 8) {
            belowUsualZoneRow
            maintenanceZoneRow
            inRangeZoneRow
            aboveUsualZoneRow
            sharpIncreaseZoneRow
        }
    }

    private var zonesExplanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "ACR TRAINING ZONES", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(1)

            zoneRows
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    private var sharpIncreaseZoneRow: some View {
        ZoneRow(
            range: String(localized: "> 1.5", bundle: LanguageManager.appBundle),
            label: String(localized: "Sharp increase", bundle: LanguageManager.appBundle),
            description: String(localized: "Recent load is jumping fast — easy day helps you absorb it", bundle: LanguageManager.appBundle),
            color: AppTheme.alert
        )
    }

    private var aboveUsualZoneRow: some View {
        ZoneRow(
            range: String(localized: "1.3 - 1.5", bundle: LanguageManager.appBundle),
            label: String(localized: "Above your usual", bundle: LanguageManager.appBundle),
            description: String(localized: "Heavier recent load — listen to your body", bundle: LanguageManager.appBundle),
            color: AppTheme.softGold
        )
    }

    private var inRangeZoneRow: some View {
        ZoneRow(
            range: String(localized: "1.0 - 1.3", bundle: LanguageManager.appBundle),
            label: String(localized: "In range", bundle: LanguageManager.appBundle),
            description: String(localized: "Building fitness sustainably", bundle: LanguageManager.appBundle),
            color: AppTheme.sage
        )
    }

    private var maintenanceZoneRow: some View {
        ZoneRow(
            range: String(localized: "0.8 - 1.0", bundle: LanguageManager.appBundle),
            label: String(localized: "Maintenance", bundle: LanguageManager.appBundle),
            description: String(localized: "Maintaining fitness", bundle: LanguageManager.appBundle),
            color: AppTheme.sage.opacity(0.7)
        )
    }

    private var belowUsualZoneRow: some View {
        ZoneRow(
            range: String(localized: "< 0.8", bundle: LanguageManager.appBundle),
            label: String(localized: "Below your usual", bundle: LanguageManager.appBundle),
            description: String(localized: "Recent load lower than your fitness base", bundle: LanguageManager.appBundle),
            color: AppTheme.mist
        )
    }

    // MARK: - Recent Workouts (live from HealthKit)

    /// Defense-in-depth: the data layer already drops sub-1-minute ghosts in
    /// fetchWorkouts, but if a phantom slips through (e.g. a 90-second Strava
    /// sync ghost with no HR samples), drop it here too rather than render a
    /// "TRIMP: 0" line that confuses the user.
    ///
    /// Use `effectiveLoad` (prefers the strap's precomputed
    /// hrTSS / continuous-TRIMP), NOT `calculateTrimp` (a crude re-derivation
    /// from HealthKit's arithmetic-mean avg HR + a hardcoded resting HR of 60).
    /// That re-derivation showed an H10 walk whose real load is 54/85 as ~113,
    /// disagreeing with both the workout report and the CTL/ATL math.
    private func liveWorkoutsCard(_ workouts: [HealthKitManager.WorkoutSummary]) -> some View {
        let filtered = workouts.filter { $0.durationMinutes >= 1.0 && $0.userScaledLoad > 0.5 }
        return VStack(alignment: .leading, spacing: 12) {
            recentWorkoutsHeader
            ForEach(Array(filtered.enumerated()), id: \.offset) { index, workout in
                liveWorkoutRow(workout)
                dividerUnlessLast(index: index, count: filtered.count)
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    private func liveWorkoutRow(_ workout: HealthKitManager.WorkoutSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.localizedTypeDescription)
                    .font(.subheadline.weight(.medium))
                Text(workout.date, style: .date)
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }
            Spacer()
            liveWorkoutLoad(workout)
        }
        .padding(.vertical, 8)
    }

    /// Label by the load's source (LOAD for power/HR/METs TSS; TRIMP only
    /// for the Banister fallback) — hard-coding "TRIMP" on an effective-load
    /// value prints it under the wrong name. Rounded to match everywhere
    /// else.
    private func liveWorkoutLoad(_ workout: HealthKitManager.WorkoutSummary) -> some View {
        let source = WorkoutMetadata.TrainingLoadSource(rawValue: workout.precomputedLoadSource ?? "") ?? .banister
        let label = source.displayLabel
        return VStack(alignment: .trailing, spacing: 2) {
            Text("\(formatDuration(workout.durationMinutes))")
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
            Text(String(localized: "\(label): \(Int(workout.userScaledLoad.rounded()))", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.primaryText)
        }
    }

    // MARK: - Recent Workouts (frozen snapshot fallback)

    /// `WorkoutSnapshot.trimp` holds the user-scaled load, whatever its
    /// source, so the frozen list labels it LOAD, as the live list does.
    private static var snapshotLoadLabel: String { WorkoutMetadata.TrainingLoadSource.hr.displayLabel }

    /// Same ghost filter as the live path, applied to the frozen snapshot so
    /// historical sessions don't show phantom 0-TRIMP entries either.
    private func recentWorkoutsCard(_ workouts: [WorkoutSnapshot]) -> some View {
        let filtered = Array(workouts.filter { $0.trimp > 0.5 && $0.durationMinutes >= 1.0 }.prefix(7))
        return VStack(alignment: .leading, spacing: 12) {
            recentWorkoutsHeader
            ForEach(Array(filtered.enumerated()), id: \.offset) { index, workout in
                snapshotWorkoutRow(workout)
                dividerUnlessLast(index: index, count: filtered.count)
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    private var recentWorkoutsHeader: some View {
        Text(String(localized: "RECENT WORKOUTS", bundle: LanguageManager.appBundle))
            .font(.caption.weight(.semibold))
            .foregroundColor(AppTheme.textTertiary)
            .tracking(1)
    }

    @ViewBuilder
    private func dividerUnlessLast(index: Int, count: Int) -> some View {
        if index < count - 1 { Divider() }
    }

    private func snapshotWorkoutRow(_ workout: WorkoutSnapshot) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(HealthWorkoutSummary.localizedTypeName(workout.type))
                    .font(.subheadline.weight(.medium))
                Text(workout.date, style: .date)
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(formatDuration(workout.durationMinutes))")
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
                Text(String(localized: "\(Self.snapshotLoadLabel): \(Int(workout.trimp.rounded()))", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.primaryText)
            }
        }
        .padding(.vertical, 8)
    }

    private func formatDuration(_ minutes: Double) -> String {
        // Locale-aware h/m/min abbreviations.
        let total = Int(minutes)
        return total >= 60
            ? LocalizedDuration.hoursMinutes(minutes: total)
            : LocalizedDuration.minutes(total)
    }

    // MARK: - Helpers

    /// Text colours: the ratio and its label are both words on the card.
    private func acrColor(_ acr: Double) -> Color {
        if acr < 0.8 { return AppTheme.mistText }
        if acr <= 1.3 { return AppTheme.sageText }
        if acr <= 1.5 { return AppTheme.softGoldText }
        return AppTheme.terracottaText
    }

    private func acrLabel(_ acr: Double) -> String {
        // Descriptive labels, not risk predictions.
        if acr < 0.8 { return String(localized: "Below your usual", bundle: LanguageManager.appBundle) }
        if acr <= 1.0 { return String(localized: "Maintenance", bundle: LanguageManager.appBundle) }
        if acr <= 1.3 { return String(localized: "In range", bundle: LanguageManager.appBundle) }
        if acr <= 1.5 { return String(localized: "Above your usual", bundle: LanguageManager.appBundle) }
        return String(localized: "Sharp increase", bundle: LanguageManager.appBundle)
    }
}

// MARK: - Supporting Views

/// Training load stays off screen while the user has switched it off or is on
/// a training break; the load screens show `TrainingLoadPausedCard` instead.
enum TrainingLoadVisibility {
    static func isPaused(_ settings: UserSettings) -> Bool {
        !settings.enableTrainingLoadIntegration || settings.isOnTrainingBreak
    }
}

/// Stands in for the load numbers while training load is paused, and says
/// where to turn it back on.
struct TrainingLoadPausedCard: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "pause.circle")
                .font(.title2)
                .foregroundStyle(AppTheme.textSecondary)
                .accessibilityHidden(true)
            Text(String(localized: "Training load paused", bundle: LanguageManager.appBundle))
                .font(.headline)
            Text(String(localized: "Training load is turned off, or you're on a training break. Change it in Settings → Training.", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
        .accessibilityElement(children: .combine)
    }
}

private struct MetricColumn: View {
    let label: String
    let value: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
            Text(value)
                .font(.title.weight(.bold))
                .foregroundColor(color)
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Linear 0.5–2.0 scale whose bands match the zone thresholds used for the
/// colour and label above (0.8, 1.3, 1.5). Drawn left-to-right in every
/// layout direction: it is a number line, not reading-order content.
private struct ACRGaugeBar: View {
    let acr: Double

    private static let scaleMin = 0.5
    private static let scaleMax = 2.0
    /// Upper edge of each band, in order: below usual, in range, above, high.
    @MainActor private static var bandEdges: [(upper: Double, color: Color)] {
        [(0.8, AppTheme.mist), (1.3, AppTheme.sage), (1.5, AppTheme.softGold), (2.0, AppTheme.alert)]
    }

    var body: some View {
        VStack(spacing: 8) {
            gaugeTrack
            gaugeAxisLabels
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private static func fraction(_ value: Double) -> CGFloat {
        CGFloat(min(max((value - scaleMin) / (scaleMax - scaleMin), 0), 1))
    }

    private var gaugeAxisLabels: some View {
        GeometryReader { geo in
            ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { tick in
                Text(String(format: "%.1f", locale: LanguageManager.appLocale, tick))
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
                    .fixedSize()
                    .position(x: Self.labelX(tick, width: geo.size.width), y: geo.size.height / 2)
            }
        }
        .frame(height: 14)
    }

    /// Centre each label on its tick, nudged inward at the two ends so it
    /// isn't clipped.
    private static func labelX(_ tick: Double, width: CGFloat) -> CGFloat {
        min(max(width * fraction(tick), 10), width - 10)
    }

    private var gaugeTrack: some View {
        GeometryReader { geo in
            gaugeLayers(geo)
        }
        .frame(height: 20)
    }

    private func gaugeLayers(_ geo: GeometryProxy) -> some View {
        ZStack(alignment: .leading) {
            gaugeBands(geo)
            Circle()
                .fill(.white)
                .frame(width: 20, height: 20)
                .shadow(radius: 2)
                .offset(x: geo.size.width * Self.fraction(acr) - 10)
        }
    }

    private func gaugeBands(_ geo: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.bandEdges.enumerated()), id: \.offset) { index, band in
                let lower = index == 0 ? Self.scaleMin : Self.bandEdges[index - 1].upper
                Rectangle().fill(band.color.opacity(0.4))
                    .frame(width: geo.size.width * (Self.fraction(band.upper) - Self.fraction(lower)))
            }
        }
        .cornerRadius(8)
    }
}

private struct ZoneRow: View {
    let range: String
    let label: String
    let description: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: 4, height: 36)

            zoneRowText

            Spacer()
        }
    }

    private var zoneRowText: some View {
        VStack(alignment: .leading, spacing: 2) {
            zoneRowHeading
            Text(description)
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    private var zoneRowHeading: some View {
        HStack {
            Text(range)
                .font(.caption.monospaced())
                .foregroundColor(AppTheme.textTertiary)
            Text(label)
                .font(.subheadline.weight(.medium))
        }
    }
}

#Preview {
    NavigationStack {
        TrainingDetailView(
            trainingMetrics: nil,
            trainingContext: nil
        )
    }
}
