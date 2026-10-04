import Charts
import CoreLocation
import MapKit
import SwiftUI

// Split out from FitnessTabView.swift. Holds the Get Me
// Back card, strap status pill + connect affordance, and supporting
// view builders. Members on FitnessTabView are internal rather than
// private so this extension can call them.

extension FitnessTabView {
    // MARK: - Get Me Back card
    //
    // Entry point for the offline breadcrumb-trail mode.
    // When no trail is active, shows a one-tap "Drop a pin & lead me
    // back" engagement (disclaimer first time). When a trail IS
    // active, shows a live status row + "Open" so the user can re-
    // enter the navigation view at any time.
    //
    // Liability: the disclaimer modal is the only place we educate the
    // user that this is an enhancement to their awareness, not a
    // replacement for proper navigation or rescue services. Once they
    // dismiss it, we keep them honest about accuracy in
    // `GetMeBackView` — no false confidence projected anywhere.

    @ViewBuilder
    var getMeBackCard: some View {
        Button {
            tapGetMeBack()
        } label: {
            getMeBackCardLabel(breadcrumbRecorder.activeTrail)
        }
        .buttonStyle(.plain)
        .alert(String(localized: "Get Me Back — read this first", bundle: LanguageManager.appBundle), isPresented: $showGetMeBackDisclaimer) {
            Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
            iUnderstandEngageButton
        } message: {
            Text(String(localized: "This is an offline breadcrumb tool. The app drops a pin where you start, then captures your path so it can later point you back with a compass arrow. It's an aid to your awareness — not a replacement for proper navigation, search-and-rescue, or local emergency services. GPS accuracy varies (canopy, canyons, weather); the arrow may be wrong by tens of meters in poor conditions. In an emergency call your local emergency number or use iOS Emergency SOS.", bundle: LanguageManager.appBundle))
        }
        .sheet(isPresented: $showGetMeBackSheet) {
            GetMeBackView()
        }
    }

    /// First engagement shows the safety disclaimer; afterwards the tap starts
    /// (or re-opens) the trail directly.
    private func tapGetMeBack() {
        let trail = breadcrumbRecorder.activeTrail
        if trail == nil, !UserDefaults.standard.bool(forKey: Self.getMeBackDisclaimerSeenKey) {
            showGetMeBackDisclaimer = true
            return
        }
        if trail == nil {
            breadcrumbRecorder.engage()
        }
        showGetMeBackSheet = true
    }

    private var iUnderstandEngageButton: some View {
        Button(String(localized: "I understand — engage", bundle: LanguageManager.appBundle)) {
            UserDefaults.standard.set(true, forKey: Self.getMeBackDisclaimerSeenKey)
            breadcrumbRecorder.engage()
            showGetMeBackSheet = true
        }
    }

    private func getMeBackCardLabel(_ trail: BreadcrumbTrail?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: trail == nil ? "mappin.and.ellipse" : "location.north.line.fill")
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(trail == nil ? Color.orange : Color.green))
            getMeBackCardText(trail)
            Spacer()
            Image(systemName: "chevron.forward")
                .accessibilityHidden(true)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textTertiary)
        }
        .padding(12)
        .background(AppTheme.cardBackground)
        .cornerRadius(12)
    }

    private func getMeBackCardText(_ trail: BreadcrumbTrail?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(trail == nil ? String(localized: "Get Me Back", bundle: LanguageManager.appBundle) : String(localized: "Trail active — open", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(getMeBackSubtitle(for: trail))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(2)
        }
    }

    func getMeBackSubtitle(for trail: BreadcrumbTrail?) -> String {
        guard let trail else {
            return String(localized: "Drops a pin where you start. Walk freely; the compass arrow leads you back. Offline.", bundle: LanguageManager.appBundle)
        }
        let count = trail.fixes.count
        guard let dist = trail.crowFlyDistanceFromTipToOriginMeters() else {
            return String(localized: "Recording — \(count) GPS points so far", bundle: LanguageManager.appBundle)
        }
        let formatted = UnitsPreferenceStore.current.resolved.formatDistance(meters: dist)
        return String(localized: "\(formatted) from origin · \(count) GPS points", bundle: LanguageManager.appBundle)
    }

    // There is deliberately no `fitnessStatusPill`,
    // `statusPillRow`, `sourcesRow`, or `formatElapsed` here.
    // None of these belong on this tab. The dailyActivityCard
    // below already shows today's totals + 7-day picture; the
    // sources strip duplicated state already surfaced inside
    // WorkoutPreflightView's strap pill. Keeping the tab top
    // focused on the four plan items: chips, today's route,
    // coaching, start.

    /// 7-day activity card with workout-vs-passive breakdown.
    /// Replaces the original Passive Activity
    /// card the user (rightly) wanted kept. Shows daily totals
    /// (HK-aggregated, phone+watch+everything) AND splits each day
    /// into workout-attributed vs passive so the user can see at a
    /// glance "I walked 8.2k steps today, 4.8k of those were the
    /// recorded walk and 3.4k was passive movement."
    @ViewBuilder
    var dailyActivityCard: some View {
        let weekTotalSteps = dailyActivity.reduce(0) { $0 + $1.stepCount }
        if weekTotalSteps > 0 || !passiveSteps.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                dailyActivityHeader
                // Today's split row — the most relevant breakdown.
                todayBreakdownRow
                // Per-day bar chart with workout vs passive stacked.
                weeklyBarChart
                dailyActivityLegend
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var dailyActivityHeader: some View {
        HStack {
            Text(String(localized: "Daily activity", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(String(localized: "last 7 days · phone + watch", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private var dailyActivityLegend: some View {
        HStack(spacing: 14) {
            legendChip(color: AppTheme.fitnessAccent, label: String(localized: "Workout", bundle: LanguageManager.appBundle))
            legendChip(color: AppTheme.textTertiary.opacity(0.6), label: String(localized: "Passive", bundle: LanguageManager.appBundle))
            Spacer()
        }
    }

    /// Today's totals split into workout-attributed vs passive.
    /// Three-column layout: steps / distance / floors, each with
    /// the workout share underneath.
    var todayBreakdownRow: some View {
        HStack(alignment: .top, spacing: 12) {
            stepsBreakdownStat
            distanceBreakdownStat
            floorsBreakdownStat
        }
    }

    /// HealthKit's day total, else the passive-steps snapshot.
    private var todayStepTotal: Int {
        dailyActivity.first?.stepCount ?? passiveSteps.first?.stepCount ?? 0
    }

    private var todayDistanceTotal: Double {
        dailyActivity.first?.distanceMeters ?? passiveSteps.first?.distanceMeters ?? 0
    }

    /// Elevation gain converted to flights at the standard 3.05 m per floor.
    private var workoutFloorsFromElevation: Int {
        Int((todayWorkoutElevationMeters / 3.05).rounded())
    }

    /// Workout floors: the flights HealthKit counted during workouts, or the
    /// recorded elevation's floors when that is higher (a phone left behind
    /// counts no flights). Never both, since HealthKit's flights already
    /// include the ones climbed during the workout.
    private var todayWorkoutFloors: Int {
        max(todayWorkoutAttributedFlights, workoutFloorsFromElevation)
    }

    /// HealthKit flights outside the workouts.
    private var todayPassiveFloors: Int {
        let hkFlights = dailyActivity.first?.flightsClimbed ?? passiveSteps.first?.floorsAscended ?? 0
        return max(0, hkFlights - todayWorkoutAttributedFlights)
    }

    private var stepsBreakdownStat: some View {
        let workoutSteps = todayWorkoutAttributedSteps
        let passive = max(0, todayStepTotal - workoutSteps)
        return breakdownStat(
            label: String(localized: "Steps", bundle: LanguageManager.appBundle),
            total: todayStepTotal.formatted(),
            workout: String(localized: "\(workoutSteps.formatted()) workout", bundle: LanguageManager.appBundle),
            passive: String(localized: "\(passive.formatted()) passive", bundle: LanguageManager.appBundle)
        )
    }

    private var distanceBreakdownStat: some View {
        let workoutDist = todayWorkoutAttributedDistanceMeters
        let passive = max(0, todayDistanceTotal - workoutDist)
        return breakdownStat(
            label: String(localized: "Distance", bundle: LanguageManager.appBundle),
            total: unitsPreference.formatDistance(meters: todayDistanceTotal),
            workout: String(localized: "\(unitsPreference.formatDistance(meters: workoutDist)) workout", bundle: LanguageManager.appBundle),
            passive: String(localized: "\(unitsPreference.formatDistance(meters: passive)) passive", bundle: LanguageManager.appBundle)
        )
    }

    private var floorsBreakdownStat: some View {
        let workoutFloors = todayWorkoutFloors
        let passive = todayPassiveFloors
        return breakdownStat(
            label: String(localized: "Floors", bundle: LanguageManager.appBundle),
            total: String(localized: "\(workoutFloors + passive) floors", bundle: LanguageManager.appBundle),
            workout: String(localized: "\(workoutFloors) workout", bundle: LanguageManager.appBundle),
            passive: String(localized: "\(passive) passive", bundle: LanguageManager.appBundle)
        )
    }

    func breakdownStat(label: String, total: String, workout: String, passive: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppTheme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(verbatim: total)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
                .modifier(BreakdownFit())
            Text(verbatim: workout)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(AppTheme.fitnessAccent)
                .modifier(BreakdownFit())
            Text(verbatim: passive)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(AppTheme.textTertiary)
                .modifier(BreakdownFit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Single line, shrinking rather than truncating — the numbers must stay
    /// readable when a long locale-formatted total lands in a narrow column.
    private struct BreakdownFit: ViewModifier {
        func body(content: Content) -> some View {
            content
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// 7-day step bar chart, today rightmost. Only today's bar is split into
    /// workout (top) and passive (bottom) steps; past days show the total.
    /// We don't time-window HK across all 7 days (that's 7×Nworkouts
    /// queries), to keep the load light. VoiceOver reads each day's name and
    /// step count.
    var weeklyBarChart: some View {
        // Newest-first → oldest-first for left-to-right display.
        let days = Array(dailyActivity.reversed())
        let maxSteps = max(days.map(\.stepCount).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(days) { day in
                dayColumn(day, maxSteps: maxSteps)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func dayColumn(_ day: HealthKitManager.DailyActivity, maxSteps: Int) -> some View {
        let isToday = Calendar.current.isDateInToday(day.date)
        return VStack(spacing: 4) {
            dayBar(day, maxSteps: maxSteps, isToday: isToday)
            Text(verbatim: dayLabel(day.date))
                .font(.caption2.weight(.medium))
                .foregroundStyle(isToday ? AppTheme.textPrimary : AppTheme.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(LocalizedDateFormat.string(from: day.date, template: "EEEE")), \(day.stepCount) steps", bundle: LanguageManager.appBundle))
    }

    /// Workout steps stack on top of the passive remainder; only today has a
    /// workout-attributed split to draw.
    private func dayBar(_ day: HealthKitManager.DailyActivity, maxSteps: Int, isToday: Bool) -> some View {
        let totalH = max(3, CGFloat(day.stepCount) / CGFloat(maxSteps) * 50)
        let workoutH: CGFloat = isToday && todayWorkoutAttributedSteps > 0
            ? max(0, CGFloat(todayWorkoutAttributedSteps) / CGFloat(maxSteps) * 50)
            : 0
        return VStack(spacing: 0) {
            if workoutH > 0 {
                RoundedRectangle(cornerRadius: 2)
                    .fill(AppTheme.fitnessAccent)
                    .frame(width: 24, height: workoutH)
            }
            RoundedRectangle(cornerRadius: 2)
                .fill(AppTheme.textTertiary.opacity(0.5))
                .frame(width: 24, height: max(3, totalH - workoutH))
        }
    }

    func legendChip(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(verbatim: label)
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    /// One-letter (or one-character) weekday in the app language, from the
    /// calendar's very-short standalone symbols — "周一".prefix(1) would
    /// read "周" for every day in Chinese.
    func dayLabel(_ date: Date) -> String {
        var calendar = Calendar.current
        calendar.locale = LanguageManager.appLocale
        let f = DateFormatter()
        f.locale = LanguageManager.appLocale
        f.calendar = calendar
        let weekday = calendar.component(.weekday, from: date)
        return f.veryShortStandaloneWeekdaySymbols[weekday - 1]
    }

    /// Sum elevation gain from today's and the past 7 days' recorded
    /// workouts. Lightweight loader (no rrSeries decode) so this
    /// stays cheap even on a large archive. Also loads HealthKit-
    /// aggregated daily totals (phone + watch + 3rd party) and
    /// computes today's workout-vs-passive split by time-windowing
    /// HK against each recorded workout.
    @MainActor
    func loadWorkoutElevationTotals() async {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let weekAgo = cal.date(byAdding: .day, value: -7, to: today) else { return }
        let startedAt = Date()
        let archive = collector.archive
        let weekWorkoutIds = weekWorkoutSessionIds(archive: archive, since: weekAgo)
        async let workoutsTask: [HRVSession] = Task.detached(priority: .userInitiated) {
            weekWorkoutIds.compactMap { archive.retrieveLightweightOrLog($0, caller: "Fitness.elevation") }
        }.value
        // HK-aggregated daily activity (everywhere, all sources). 7 days; index 0 = today.
        async let activityTask = collector.healthKit.fetchDailyActivity(days: 7)
        let workouts = await workoutsTask
        let todaysWorkouts = workouts.filter { $0.startDate >= today }
        applyElevationTotals(workouts: workouts, todaysWorkouts: todaysWorkouts, weekAgo: weekAgo)
        applyCachedMeanHRR(workouts: workouts, archive: archive)
        dailyActivity = await activityTask
        await applyWorkoutAttribution(todaysWorkouts: todaysWorkouts)
        cacheFitnessDisplayState()
        logFitnessLoadTiming(count: weekWorkoutIds.count, startedAt: startedAt)
    }

    @MainActor
    private func applyElevationTotals(workouts: [HRVSession], todaysWorkouts: [HRVSession], weekAgo: Date) {
        todayWorkoutElevationMeters = todaysWorkouts
            .compactMap { $0.workoutMetadata?.elevationGainMeters }
            .reduce(0, +)
        weekWorkoutElevationMeters = workouts
            .filter { $0.startDate >= weekAgo }
            .compactMap { $0.workoutMetadata?.elevationGainMeters }
            .reduce(0, +)
    }

    /// Compute the "Mean HRR@1m" tile here, off the
    /// render path, reusing the sessions just decrypted above. Reproduces
    /// computeMeanHRR1m exactly — same entry filter (withinDays(entry.date, 7)
    /// & workout), same drop source, same average — but pulls each session from
    /// the already-decrypted set (the elevation window is a superset of the HRR
    /// window) and only falls back to a fresh decrypt if one is missing. Back
    /// on @MainActor here, so withinDays/entries are safe to touch.
    @MainActor
    private func applyCachedMeanHRR(workouts: [HRVSession], archive: SessionArchive) {
        let workoutById = Dictionary(workouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var drops: [Int] = []
        for entry in archive.entries where entry.sessionType == .workout && withinDays(entry.date, 7) {
            let session = workoutById[entry.sessionId]
                ?? archive.retrieveLightweightOrLog(entry.sessionId, caller: "fitness.summary.hrr")
            if let drop = session?.workoutMetadata?.hrrSamples?.bestAtOneMinute?.drop {
                drops.append(drop)
            }
        }
        meanHRR1m7d = drops.isEmpty ? nil : Double(drops.reduce(0, +)) / Double(drops.count)
    }

    /// Workout-attribution split: for each recorded workout today, query HK for
    /// the steps/distance/flights inside its [start, end] window. Sum across
    /// today's workouts. The pill then shows "TOTAL · workout X / passive Y"
    /// where Y = total − X.
    @MainActor
    private func applyWorkoutAttribution(todaysWorkouts: [HRVSession]) async {
        var attribSteps = 0
        var attribDistance: Double = 0
        var attribFlights = 0
        for workout in todaysWorkouts {
            let start = workout.startDate
            let end = workout.endDate ?? Date()
            guard end > start else { continue }
            async let s = collector.healthKit.fetchSumSteps(from: start, to: end)
            async let d = collector.healthKit.fetchSumDistance(from: start, to: end)
            async let f = collector.healthKit.fetchSumFlights(from: start, to: end)
            attribSteps += await s
            attribDistance += await d
            attribFlights += await f
        }
        todayWorkoutAttributedSteps = attribSteps
        todayWorkoutAttributedDistanceMeters = attribDistance
        todayWorkoutAttributedFlights = attribFlights
    }

    /// Cache the computed display state so the next tab-open paints instantly.
    @MainActor
    private func cacheFitnessDisplayState() {
        dependencies.storage.uiStateCache.setFitness(.init(
            todayElevationMeters: todayWorkoutElevationMeters,
            weekElevationMeters: weekWorkoutElevationMeters,
            todayAttributedSteps: todayWorkoutAttributedSteps,
            todayAttributedDistanceMeters: todayWorkoutAttributedDistanceMeters,
            todayAttributedFlights: todayWorkoutAttributedFlights
        ))
    }
}

// MARK: - File-scope helpers
//
// Kept out of FitnessTabView. Each names no member of the
// type and calls nothing that stayed behind, so none needed to be inside
// it. `private` at file scope is fileprivate, so every call site in this
// file resolves exactly as before.

/// Only the last week's WORKOUT sessions (picked from the in-memory index),
/// not the 50 most-recent of every type — elevation and attribution only
/// need this week's workouts.
@MainActor
private func weekWorkoutSessionIds(archive: SessionArchive, since weekAgo: Date) -> [UUID] {
    archive.entries
        .filter { $0.sessionType == .workout && $0.date >= weekAgo }
        .map { $0.sessionId }
}

private func logFitnessLoadTiming(count: Int, startedAt: Date) {
    debugLog("[LaunchTiming] fitness load: \(count) workouts decrypted in \(Int(Date().timeIntervalSince(startedAt) * 1000))ms", level: .info)
}
