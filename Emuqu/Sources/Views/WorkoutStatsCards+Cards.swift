import Charts
import CoreLocation
import MapKit
import MessageUI
import SwiftUI

// Split out from FitnessPostSummaryView.swift to keep the primary
// file under the 1500-line tech-debt budget. Holds
// headline-card derived values + time-series chart cards.

extension WorkoutStatsCards {
    // MARK: - Headline-card derived values
    //
    // Pulled from the captured sample series (WorkoutMetadata.samples) with
    // fallback to aggregates. All return Strings (or nil) so the card can
    // conditionally show rows without null-check noise inline.

    func formatDuration(sec: Int) -> String {
        let h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    var avgPaceDisplay: String? {
        // Overall avg = duration / distance. More meaningful than averaging
        // per-sample pace (which can be skewed by stationary periods).
        guard let distance = session.workoutMetadata?.distanceMeters, distance > 100,
              let duration = session.duration, duration > 10
        else { return nil }
        return units.formatPace(elapsedSec: Int(duration), distanceMeters: distance)
    }

    var maxSpeedDisplay: String? {
        guard let kmh = robustMaxSpeedKmh() else { return nil }
        switch units.resolved {
        case .imperial: return String(format: "%.1f mph", locale: .current, kmh / 1.609_344)
        case .metric, .auto: return String(format: "%.1f km/h", locale: .current, kmh)
        }
    }

    /// The 95th-percentile moving speed, not the raw max.
    ///
    /// Reject single-sample outliers from GPS jitter / foot-pod glitches. A
    /// walker's "max speed" of 28 mph is the GPS reporting a 30 m teleport
    /// during one tick — not a real speed. Take the 95th percentile of valid
    /// samples (above a 0.4 m/s = 1.4 km/h floor that strips paused stretches)
    /// instead, which behaves like "max" but is immune to one bad fix.
    private func robustMaxSpeedKmh() -> Double? {
        guard let samples = session.workoutMetadata?.samples else { return nil }
        let moving = samples
            .compactMap { $0.paceSecPerKm.flatMap { $0 > 0 ? 3600.0 / $0 : nil } }
            .filter { $0 >= 1.4 } // ≥ ~0.87 mph filters paused
        let bounded = moving.sorted().filter { $0 <= sportSpeedCeiling }
        guard !bounded.isEmpty else { return nil }
        return bounded[max(0, Int(Double(bounded.count - 1) * 0.95))]
    }

    /// Sport-appropriate ceiling — anything above this is implausible and almost
    /// certainly a sensor outlier. Lets us still report "fast" but not 50 mph
    /// for a runner.
    private var sportSpeedCeiling: Double {
        switch session.sport {
        case .walk, .hike, .treadmill: return 14.0    // ~8.7 mph
        case .run, .trailRun: return 28.0             // ~17 mph (elite sprint)
        case .bike, .indoorBike: return 80.0          // ~50 mph descent
        case .none: return 50.0
        default: return 50.0
        }
    }

    var peakHRDisplay: String? {
        guard let samples = session.workoutMetadata?.samples,
              let peak = samples.compactMap({ $0.heartRate }).max()
        else { return nil }
        return "\(peak) bpm"
    }

    var avgCadenceDisplay: String? {
        guard let samples = session.workoutMetadata?.samples else { return nil }
        let values = samples.compactMap { $0.cadenceStepsPerMin }.filter { $0 > 0 }
        guard !values.isEmpty else { return nil }
        let avg = values.reduce(0, +) / Double(values.count)
        return String(format: "%.0f spm", locale: .current, avg)
    }

    /// The fastest (lowest sec/km) split in the stored splits array. Shown
    /// in the headline to surface the session's peak aerobic effort —
    /// "avg 15:59/mi" tells a misleading story when one split was 13:30.
    var bestSplitDisplay: (pace: String, caption: String)? {
        guard let splits = session.workoutMetadata?.splits, splits.count >= 2 else { return nil }
        let paced = splits.compactMap { s -> (Split, Double)? in
            guard let p = s.averagePaceSecPerKm, p > 0 else { return nil }
            return (s, p)
        }
        guard let fastest = paced.min(by: { $0.1 < $1.1 }) else { return nil }
        let isMile = fastest.0.distanceMeters > 1500
        let unitLabel = isMile ? "mi" : "km"
        guard let paceStr = units.formatPace(secondsPerMeter: fastest.1 / 1_000) else { return nil }
        let hrPart = fastest.0.averageHR.map { " · \(Int($0)) bpm" } ?? ""
        return (pace: paceStr, caption: "\(unitLabel) \(fastest.0.index)\(hrPart)")
    }

    var avgMETsDisplay: String? {
        guard let samples = session.workoutMetadata?.samples else { return nil }
        let values = samples.compactMap { $0.mets }
        guard !values.isEmpty else { return nil }
        let avg = values.reduce(0, +) / Double(values.count)
        return String(format: "%.1f", locale: .current, avg)
    }

    /// Calories from the Compendium of Physical Activities formula:
    ///   kcal = METs × 3.5 × kg × min / 200
    /// Pulls the user's body weight from Settings → Fitness (fallback to a
    /// 75 kg baseline; UI labels the row "(est)" whichever way so the user
    /// knows it's an estimate, not a calorimeter reading).
    ///
    /// Ainsworth 2011, Compendium of Physical Activities 2nd ed. — same
    /// reference the METs bands in WorkoutRecorder use.
    var estimatedCaloriesDisplay: String? {
        guard let samples = session.workoutMetadata?.samples,
              let duration = session.duration
        else { return nil }
        let metsValues = samples.compactMap { $0.mets }
        guard !metsValues.isEmpty else { return nil }
        let avgMETs = metsValues.reduce(0, +) / Double(metsValues.count)
        let weightKg = settingsManager.settings.effectiveBodyWeightKg
        let minutes = duration / 60.0
        let kcal = (avgMETs * 3.5 * weightKg * minutes) / 200.0
        return String(format: "%.0f kcal", locale: .current, kcal)
    }

    // MARK: - Time-series charts
    //
    // All three reach into `WorkoutMetadata.samples` — the per-second snapshot
    // array persisted on finalize by WorkoutRecorder.

    /// Shared X-axis upper bound. Charts' auto-scaled axis ends on
    /// whatever tick it decides on (often 75 min on a 63 min walk, leaving
    /// dead space on the right), so we clamp to the real session duration
    /// plus a small cushion and the series always fills the plotting area.
    func chartXDomain(samples: [WorkoutSample]) -> ClosedRange<Double> {
        let maxMin = Double(samples.last?.offsetSec ?? 0) / 60.0
        return 0 ... max(1.0, maxMin)
    }

    /// Heart-rate over time with Z1–Z5 background colour bands. The bands
    /// are computed from the user's effective max HR (50-60-70-80-90 %),
    /// giving a persistent visual reference that makes "where was I?"
    /// obvious at a glance without squinting at Y-axis ticks.
    func hrChartCard(samples: [WorkoutSample]) -> some View {
        let points: [(Double, Int)] = samples.compactMap { s in
            guard let hr = s.heartRate else { return nil }
            return (Double(s.offsetSec) / 60.0, hr)
        }
        let userMax = settingsManager.settings.effectiveMaxHR
        return chartShell(title: String(localized: "Heart Rate", bundle: LanguageManager.appBundle)) {
            if points.count >= 2 {
                hrChart(points: points, samples: samples, userMax: userMax)
            } else {
                emptyChartText(String(localized: "No HR samples captured.", bundle: LanguageManager.appBundle))
            }
        }
    }

    private func hrChart(points: [(Double, Int)], samples: [WorkoutSample], userMax: Int) -> some View {
        Chart {
            hrZoneBands(points: points, userMax: userMax)
            ForEach(Array(points.enumerated()), id: \.offset) { _, pt in
                LineMark(
                    x: .value("Minutes", pt.0),
                    y: .value("HR", pt.1)
                )
                .foregroundStyle(AppTheme.fitnessAccent)
                .interpolationMethod(.monotone)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartYScale(domain: hrChartDomain(points: points.map(\.1), userMax: userMax))
        .chartXScale(domain: chartXDomain(samples: samples))
        .frame(height: 150)
    }

    /// Zone backgrounds, clamped to the Y domain so a walk that never touched
    /// Z5 still lays its Z5 band down where it WOULD be, for spatial
    /// consistency across sessions.
    private func hrZoneBands(points: [(Double, Int)], userMax: Int) -> some ChartContent {
        ForEach(Array(Self.hrZones(userMax: userMax).enumerated()), id: \.offset) { _, z in
            RectangleMark(
                xStart: .value("t0", points.first?.0 ?? 0),
                xEnd: .value("t1", points.last?.0 ?? 0),
                yStart: .value("lo", z.lo),
                yEnd: .value("hi", z.hi)
            )
            .foregroundStyle(z.color)
        }
    }

    private static func hrZones(userMax: Int) -> [(lo: Int, hi: Int, color: Color)] {
        [
            (Int(Double(userMax) * 0.50), Int(Double(userMax) * 0.60), Color(red: 0.40, green: 0.80, blue: 0.55).opacity(0.10)),
            (Int(Double(userMax) * 0.60), Int(Double(userMax) * 0.70), Color(red: 0.55, green: 0.85, blue: 0.45).opacity(0.12)),
            (Int(Double(userMax) * 0.70), Int(Double(userMax) * 0.80), Color(red: 0.95, green: 0.80, blue: 0.30).opacity(0.14)),
            (Int(Double(userMax) * 0.80), Int(Double(userMax) * 0.90), Color(red: 0.95, green: 0.55, blue: 0.25).opacity(0.16)),
            (Int(Double(userMax) * 0.90), userMax + 10, Color(red: 0.90, green: 0.35, blue: 0.35).opacity(0.18))
        ]
    }

    /// Pace over time (min/km OR min/mi depending on user Units preference).
    /// Inverted Y so faster pace shows higher on the chart — common convention.
    func paceChartCard(samples: [WorkoutSample]) -> some View {
        let points = paceChartPoints(samples: samples)
        return chartShell(title: String(localized: "Pace (\(units.paceSuffix))", bundle: LanguageManager.appBundle)) {
            paceChartBody(points: points, samples: samples)
        }
    }

    @ViewBuilder
    private func paceChartBody(points: [(Double, Double)], samples: [WorkoutSample]) -> some View {
        if points.count >= 2 {
            simpleLineChart(points: points, tint: AppTheme.primary, samples: samples, height: 140)
                .chartYScale(domain: paceDomain(points: points.map(\.1)))
                .chartYAxis { Self.leadingGridAxis }
        } else {
            emptyChartText(String(localized: "Not enough movement for a pace chart.", bundle: LanguageManager.appBundle))
        }
    }

    /// Leading axis with a grid line and the default label on every mark.
    private static var leadingGridAxis: some AxisContent {
        AxisMarks(position: .leading) { _ in
            AxisGridLine()
            AxisValueLabel()
        }
    }

    /// Convert to min/km (or min/mi) and drop absurd slow values so one GPS
    /// jitter point doesn't flatten the chart.
    private func paceChartPoints(samples: [WorkoutSample]) -> [(Double, Double)] {
        samples.compactMap { s in
            guard let pace = s.paceSecPerKm, pace > 0 else { return nil }
            let kmhEquivalent = 3600.0 / pace
            guard kmhEquivalent > 1.0, kmhEquivalent < 40 else { return nil }
            return (Double(s.offsetSec) / 60.0, units.paceDisplayMinutes(from: pace))
        }
    }

    /// One monotone line over minutes-from-start, x-scaled to the session.
    /// Shared by the pace, cadence and power cards.
    func simpleLineChart(points: [(Double, Double)], tint: Color, samples: [WorkoutSample], height: CGFloat) -> some View {
        Chart(points, id: \.0) { pt in
            LineMark(
                x: .value("Minutes", pt.0),
                y: .value("Value", pt.1)
            )
            .foregroundStyle(tint)
            .interpolationMethod(.monotone)
        }
        .chartXScale(domain: chartXDomain(samples: samples))
        .frame(height: height)
    }

    /// Running power (watts) over time. Only appears when a power-capable
    /// foot pod (Stryd etc.) was connected during the session.
    func powerChartCard(samples: [WorkoutSample]) -> some View {
        let points: [(Double, Double)] = samples.compactMap { s in
            guard let w = s.powerWatts, w > 0 else { return nil }
            return (Double(s.offsetSec) / 60.0, Double(w))
        }
        return chartShell(title: String(localized: "Running Power (W)", bundle: LanguageManager.appBundle)) {
            if points.count >= 2 {
                simpleLineChart(points: points, tint: .yellow, samples: samples, height: 140)
            } else {
                emptyChartText(String(localized: "No power data.", bundle: LanguageManager.appBundle))
            }
        }
    }

    /// Cadence over time (steps / min) — foot pod if available, else pedometer.
    /// Applies a tail-spike filter: foot pods occasionally emit a final
    /// ~140+ spm reading during the workout's last second (artefact of the
    /// stop-motion vs the reporting window). We drop any reading in the
    /// last 3 seconds that's ≥ 1.6× the preceding rolling median — cleans
    /// up the visible vertical line at the end of the chart without
    /// losing any real data.
    func cadenceChartCard(samples: [WorkoutSample]) -> some View {
        let raw: [(Double, Double)] = samples.compactMap { s in
            guard let cad = s.cadenceStepsPerMin, cad > 0 else { return nil }
            return (Double(s.offsetSec) / 60.0, cad)
        }
        let points = filterCadence(raw, sport: session.sport ?? .walk)
        return chartShell(title: String(localized: "Cadence (spm)", bundle: LanguageManager.appBundle)) {
            if points.count >= 2 {
                simpleLineChart(points: points, tint: .purple, samples: samples, height: 140)
            } else {
                emptyChartText(String(localized: "No cadence data.", bundle: LanguageManager.appBundle))
            }
        }
    }

    /// Sport-aware cadence filter. Two passes:
    ///   1. Physiological cap. Walking / hiking cadence above ~125 spm
    ///      is mechanically implausible (that's jogging cadence) — foot
    ///      pods sometimes emit spurious doublings. Drop any sample
    ///      over the sport's upper bound.
    ///   2. Tail-spike rejection against the trailing 30-sample median.
    ///      Checks the last ≤ 15 samples (3 is too few — multi-sample
    ///      tail artefacts slip through), ≥ 1.5× baseline
    ///      median gets dropped.
    /// The user's complaint "I did NOT start running" on a walk where
    /// the final 5-10 samples show 140 spm maps to case 1 — foot-pod
    /// noise at stop time that a per-row threshold alone can't catch.
    func filterCadence(_ points: [(Double, Double)], sport: Sport) -> [(Double, Double)] {
        let capped = points.filter { $0.1 <= Self.cadenceCap(for: sport) }
        guard capped.count >= 20 else { return capped }
        return Self.truncatingTailSpike(capped)
    }

    /// Sport-specific plausible maxima. Walk/hike cadence tops out well below
    /// the jogging floor (~150 spm), so anything over 125 on a walk is
    /// artefact. Run / trail-run tops at ~210.
    private static func cadenceCap(for sport: Sport) -> Double {
        switch sport {
        case .walk, .hike: 125
        case .run, .trailRun: 220
        case .treadmill: 220
        case .bike, .indoorBike, .airBike: 140  // RPM, not spm, but same numeric ceiling
        case .row: 60                  // strokes per minute — elite race pace tops ~50
        case .crossFit: 60             // functional reps — generic indoor ceiling, like row
        }
    }

    /// Trailing-15 region checked against the median of the preceding 30
    /// samples. If any tail sample is ≥ 1.5× the baseline median, truncate
    /// from there.
    private static func truncatingTailSpike(_ capped: [(Double, Double)]) -> [(Double, Double)] {
        let suspectCount = min(15, capped.count / 4)
        let baselineEnd = capped.count - suspectCount
        let baselineStart = max(0, baselineEnd - 30)
        let baselineValues = Array(capped[baselineStart ..< baselineEnd]).map(\.1).sorted()
        guard !baselineValues.isEmpty else { return capped }
        let mid = baselineValues.count / 2
        let baselineMedian = baselineValues.count.isMultiple(of: 2)
            ? (baselineValues[mid - 1] + baselineValues[mid]) / 2
            : baselineValues[mid]
        let spikeThreshold = baselineMedian * 1.5
        for i in baselineEnd ..< capped.count where capped[i].1 >= spikeThreshold {
            return Array(capped[0 ..< i])
        }
        return capped
    }

    @ViewBuilder
    func chartShell(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    func emptyChartText(_ msg: String) -> some View {
        Text(msg)
            .font(.caption)
            .foregroundStyle(AppTheme.textTertiary)
    }

    /// Keep the HR chart domain tight around the actual data instead of
    /// stretching to 0–userMax, otherwise a 130-bpm walk plots in the bottom
    /// 15% of the card with all the detail invisible.
    func hrChartDomain(points: [Int], userMax: Int) -> ClosedRange<Int> {
        guard let minHR = points.min(), let maxHR = points.max() else {
            return 40 ... max(userMax, 160)
        }
        return max(40, minHR - 10) ... min(userMax + 10, maxHR + 10)
    }

    func paceDomain(points: [Double]) -> ClosedRange<Double> {
        guard let minP = points.min(), let maxP = points.max() else {
            return 0 ... 20
        }
        // Pad 10% on each side so line doesn't kiss the axis.
        let pad = max(0.1, (maxP - minP) * 0.1)
        // NOTE: Pace chart Y-axis is NOT inverted here (Chart lacks a built-in
        // reverse flag); the displayed pace is "min per km/mi" so lower is
        // faster — we let the chart render that way. If users want faster=up
        // the fix is to negate values before plotting, at the cost of
        // confusing tick labels. Leaving as-is for now.
        return max(0, minP - pad) ... (maxP + pad)
    }

    var elevationCard: some View {
        let imperial = units.resolved == .imperial
        let xLabel = imperial ? "mi" : "km"
        let yLabel = imperial ? "ft" : "m"
        let points = elevationPoints(imperial: imperial)
        let maxX = max(
            points.last?.distance ?? 0,
            (session.workoutMetadata?.distanceMeters ?? 0) * distanceScale(imperial: imperial)
        )
        return VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Elevation (\(yLabel))", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            elevationChart(points, maxX: maxX, xLabel: xLabel, yLabel: yLabel)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Unit-aware conversion: x (distance) and y (altitude) both follow the
    /// user's preference — imperial users get miles on x and feet on y.
    private func elevationPoints(imperial: Bool) -> [FitnessSummaryCards.ElevationPoint] {
        let distanceScale = distanceScale(imperial: imperial)
        let altitudeScale = imperial ? UnitConstants.feetPerMeter : 1.0
        return Self.elevationSeries(track).map { pt in
            FitnessSummaryCards.ElevationPoint(
                distance: (pt.distance * 1_000) * distanceScale, // convert back from km then apply
                altitude: pt.altitude * altitudeScale
            )
        }
    }

    @ViewBuilder
    private func elevationChart(
        _ points: [FitnessSummaryCards.ElevationPoint],
        maxX: Double,
        xLabel: String,
        yLabel: String
    ) -> some View {
        if points.count >= 2 {
            Chart(points, id: \.distance) { point in
                elevationMarks(point, xLabel: xLabel, yLabel: yLabel)
            }
            .chartXScale(domain: 0 ... max(0.1, maxX))
            .chartYAxis { elevationYAxis }
            .frame(height: 140)
        } else {
            Text(String(localized: "Not enough GPS fixes for an elevation chart.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private var elevationYAxis: some AxisContent {
        AxisMarks(position: .leading) { _ in
            AxisGridLine()
            AxisValueLabel()
        }
    }

    /// Top-of-sheet "keep the strap on" banner. Renders ONLY while the
    /// HRR capture is in flight (no samples persisted yet AND we're
    /// within the 130-second post-stop window). Counts down so the
    /// user can see how much longer to wait. Auto-dismisses when
    /// either samples land or the window passes.
    @ViewBuilder
    var hrrCaptureBanner: some View {
        let hrrSamples = session.workoutMetadata?.hrrSamples
        let captureFinished = hrrSamples != nil
        let stoppedAt = session.endDate ?? Date()
        let secondsSinceStop = Int(Date().timeIntervalSince(stoppedAt))
        let totalCaptureWindow = 130
        let remaining = max(0, totalCaptureWindow - secondsSinceStop)

        if !captureFinished, remaining > 0 {
            // 1 Hz timeline so the countdown updates without a manual timer. The
            // banner self-removes when `captureFinished` flips (the recorder's
            // detached HRR task writes samples back to the archive and the
            // parent view rebinds).
            TimelineView(.periodic(from: stoppedAt, by: 1.0)) { _ in
                hrrCountdownRow(stoppedAt: stoppedAt, window: totalCaptureWindow)
            }
        }
    }

    private func hrrCountdownRow(stoppedAt: Date, window: Int) -> some View {
        let liveRemaining = max(0, window - Int(Date().timeIntervalSince(stoppedAt)))
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "heart.text.square.fill")
                .font(.title3)
                .foregroundStyle(AppTheme.fitnessAccent)
            hrrCountdownText(remaining: liveRemaining)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AppTheme.fitnessAccent.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(AppTheme.fitnessAccent.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func hrrCountdownText(remaining: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "Keep your strap on for \(formatMMSS(remaining)) more", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(String(localized: "Capturing your heart rate recovery — drops at +1 min and +2 min from peak. Walk back to the car / sit on the porch and let the strap finish.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func formatMMSS(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    /// Heart-rate recovery — promoted to its own card because it was getting
    /// lost in the "Physiology" grab-bag below. HRR is one of the signature
    /// numbers for post-workout autonomic recovery (12+ bpm drop in the first
    /// minute = healthy parasympathetic reactivation).
    ///
    /// Capture UX: the backing task runs for up to 120 s after Stop. Rather
    /// than showing an opaque spinner — the 2026-04 user complaint that
    /// "HRR sits and spins and I have no idea what's happening" — the
    /// header shows a live `MM:SS remaining` countdown off a TimelineView
    /// and the peak HR is rendered inline so the user can sanity-check the
    /// drop once numbers arrive. When the capture finishes or fails the
    /// countdown is replaced by the usual summary chip.
    var hrrCard: some View {
        let hrrSamples = session.workoutMetadata?.hrrSamples
        let captureFinished = hrrSamples != nil
        return VStack(alignment: .leading, spacing: 10) {
            hrrCardHeader(
                captureFinished: captureFinished,
                captureFailed: captureFinished && hrrSamples?.isEmpty == true,
                oneMinDrop: hrrSamples?.bestAtOneMinute?.drop
            )
            peakHRReferenceRow
            hrrValueRow(hrrSamples)
            hrrNarrativeBlock(hrrSamples, captureFinished: captureFinished)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    /// Morning-parity header.
    private func hrrCardHeader(
        captureFinished: Bool,
        captureFailed: Bool,
        oneMinDrop: Int?
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "heart.text.square.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.fitnessAccent)
                .accessibilityHidden(true)
            Text(String(localized: "HEART RATE RECOVERY", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(AppTheme.textTertiary)
            Spacer()
            hrrStatusChip(
                captureFinished: captureFinished,
                captureFailed: captureFailed,
                oneMinDrop: oneMinDrop
            )
        }
    }

    /// Peak HR at Stop, so the user can sanity-check the drop numbers against
    /// their own sense of the effort.
    ///
    /// Computed from the persisted per-second samples: the top-level
    /// `WorkoutMetadata` struct doesn't carry a peak field (it lives per-lap /
    /// per-HRR sample), and scanning `samples` is O(n) over a few thousand
    /// entries — cheap, unmeasurable on device — which beats migrating the
    /// metadata schema just to surface one number.
    @ViewBuilder
    private var peakHRReferenceRow: some View {
        let peak = session.workoutMetadata?.samples?.compactMap(\.heartRate).max()
        if let peak, peak > 0 {
            HStack(spacing: 4) {
                Text(String(localized: "Peak HR at stop:", bundle: LanguageManager.appBundle))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
                Text(String(localized: "\(peak) bpm", bundle: LanguageManager.appBundle))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func hrrValueRow(_ hrrSamples: [HRRSample]?) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 24) {
            hrrValueBlock(
                label: "1 min",
                sample: hrrSamples?.bestAtOneMinute,
                goodThreshold: 12,
                okThreshold: 8
            )
            hrrValueBlock(
                label: "2 min",
                sample: hrrSamples?.bestAtTwoMinutes,
                goodThreshold: 22,
                okThreshold: 16
            )
        }
    }

    /// Morning cards always explain WHAT the number means. For HRR we interpret
    /// the 1-minute drop per clinical conventions (>12 bpm = strong vagal
    /// reactivation), and say so plainly while the window is still open or when
    /// the capture came back empty.
    @ViewBuilder
    private func hrrNarrativeBlock(_ hrrSamples: [HRRSample]?, captureFinished: Bool) -> some View {
        if let drop = hrrSamples?.bestAtOneMinute?.drop {
            hrrNarrativeText(hrrNarrative(drop: drop))
        } else if !captureFinished {
            hrrNarrativeText(String(localized: "Keep the strap on for about 2 minutes after Stop — your autonomic recovery rate is the HR drop at +1 min and +2 min. We'll fill this in automatically when the window closes.", bundle: LanguageManager.appBundle))
        } else if hrrSamples?.isEmpty == true {
            hrrNarrativeText(String(localized: "HRR couldn't be captured — the strap or Watch wasn't reporting HR in the 60–120 s after stop. Wear it for a couple of minutes next time.", bundle: LanguageManager.appBundle))
        }
    }

    /// Status chip at the top-right of the HRR card. Three states:
    /// `capturing MM:SS` (countdown), `no signal` (capture failed), or the
    /// quality label ("strong" / "excellent"). Countdown is driven by a
    /// 1-Hz TimelineView so no explicit timer is needed and the view stops
    /// updating the moment the capture completes (captureFinished flips).
    @ViewBuilder
    func hrrStatusChip(
        captureFinished: Bool,
        captureFailed: Bool,
        oneMinDrop: Int?
    ) -> some View {
        if !captureFinished {
            hrrCountdownChip()
        } else if captureFailed {
            Text(String(localized: "no signal", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityLabel(Text(String(localized: "Heart rate recovery capture failed, no signal", bundle: LanguageManager.appBundle)))
        } else if let drop = oneMinDrop {
            Text(hrrLabel(drop: drop))
                .font(.caption.weight(.semibold))
                .foregroundStyle(hrrColor(drop: drop, good: 12, ok: 8))
        }
    }

    /// `session.endDate` is the authoritative stop time; falls back to
    /// start+elapsed-from-last-sample if endDate is somehow missing (older
    /// pre-fix sessions).
    private func hrrCountdownChip() -> some View {
        let stopDate = session.endDate
            ?? session.workoutMetadata?.samples?.last.map { session.startDate.addingTimeInterval(Double($0.offsetSec)) }
            ?? session.startDate
        let captureEnd = stopDate.addingTimeInterval(120)
        return TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let remaining = max(0, Int(captureEnd.timeIntervalSince(ctx.date)))
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.7)
                Text(String(format: NSLocalizedString("capturing · %d:%02d", bundle: LanguageManager.appBundle, comment: ""), remaining / 60, remaining % 60))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
                    .monospacedDigit()
            }
            .accessibilityLabel(Text(String(localized: "Capturing heart rate recovery, \(remaining) seconds remaining", bundle: LanguageManager.appBundle)))
        }
    }

    func hrrLabel(drop: Int) -> String {
        if drop >= 18 { return String(localized: "excellent", bundle: LanguageManager.appBundle) }
        if drop >= 12 { return String(localized: "strong", bundle: LanguageManager.appBundle) }
        if drop >= 8 { return String(localized: "ok", bundle: LanguageManager.appBundle) }
        return String(localized: "slower", bundle: LanguageManager.appBundle)
    }

    func hrrNarrative(drop: Int) -> String {
        if drop >= 18 {
            return String(localized: "A fast one-minute drop. Faster heart-rate recovery is associated with better aerobic fitness, though a single session says less than your own trend.", bundle: LanguageManager.appBundle)
        }
        if drop >= 12 {
            return String(localized: "At or above the 12 bpm convention for 1-minute recovery. Your own trend across sessions says more than one reading.", bundle: LanguageManager.appBundle)
        }
        if drop >= 8 {
            return String(localized: "Moderate HR drop. Consider whether you're accumulating fatigue; a well-recovered day typically shows > 12 bpm drop.", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Slower-than-expected HR recovery. Can reflect fatigue, dehydration, heat, or a hard recent training block. Watch for trends.", bundle: LanguageManager.appBundle)
    }

    /// One HRR reading — big "N bpm" value on top with provenance underneath.
    /// Colour-codes against thresholds so glancing at the card conveys the
    /// recovery quality without the user reading the number.
    func hrrValueBlock(
        label: String,
        sample: HRRSample?,
        goodThreshold: Int,
        okThreshold: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.textTertiary)
            if let s = sample {
                hrrReading(s, goodThreshold: goodThreshold, okThreshold: okThreshold)
            } else {
                hrrPlaceholder
            }
        }
    }

    private func hrrReading(_ s: HRRSample, goodThreshold: Int, okThreshold: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(s.drop)")
                    .scaledFont(size: 32, weight: .semibold)
                    .foregroundStyle(hrrColor(drop: s.drop, good: goodThreshold, ok: okThreshold))
                Text(String(localized: "bpm", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Text(Self.hrrProvenanceLabel(s.provenance))
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private var hrrPlaceholder: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "—", bundle: LanguageManager.appBundle))
                .scaledFont(size: 32, weight: .semibold)
                .foregroundStyle(AppTheme.textTertiary)
            Text(String(localized: "not yet", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    func hrrColor(drop: Int, good: Int, ok: Int) -> Color {
        if drop >= good { return Color(red: 0.40, green: 0.80, blue: 0.55) }  // green
        if drop >= ok { return Color(red: 0.95, green: 0.80, blue: 0.30) }    // amber
        return Color(red: 0.95, green: 0.55, blue: 0.25)                       // orange
    }
}

// MARK: - File-scope helpers
//
// Kept outside the view. Each touches none of the view's members —
// including its private statics — and calls nothing inside it. `private`
// at file scope is fileprivate, so every call site in this file resolves.

/// The x-domain is clamped to the session's actual covered distance (from
/// stored metadata) — that prevents the chart extending past the data into
/// dead space when the last GPS fix wasn't at exactly the same mile as the
/// stored `distanceMeters` aggregate.
private func distanceScale(imperial: Bool) -> Double {
    imperial ? 1.0 / 1609.344 : 1.0 / 1_000.0
}

@ChartContentBuilder
@MainActor
private func elevationMarks(
    _ point: FitnessSummaryCards.ElevationPoint,
    xLabel: String,
    yLabel: String
) -> some ChartContent {
    AreaMark(
        x: .value("Distance (\(xLabel))", point.distance),
        y: .value("Elevation (\(yLabel))", point.altitude)
    )
    .foregroundStyle(AppTheme.fitnessAccent.opacity(0.3))
    LineMark(
        x: .value("Distance (\(xLabel))", point.distance),
        y: .value("Elevation (\(yLabel))", point.altitude)
    )
    .foregroundStyle(AppTheme.fitnessAccent)
    .interpolationMethod(.catmullRom)
}

@MainActor
private func hrrNarrativeText(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(AppTheme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: - Pure helpers moved from `+Share` (no instance state)

extension WorkoutStatsCards {
    static func elevationSeries(_ track: [CLLocation]) -> [FitnessSummaryCards.ElevationPoint] {
        guard track.count >= 2 else { return [] }
        var cumulative = 0.0
        var result: [FitnessSummaryCards.ElevationPoint] = []
        for i in 0 ..< track.count {
            if i > 0 {
                cumulative += track[i].distance(from: track[i - 1])
            }
            result.append(FitnessSummaryCards.ElevationPoint(
                distance: cumulative / 1_000,
                altitude: track[i].altitude
            ))
        }
        return result
    }

    static func hrrProvenanceLabel(_ p: HRRSample.Provenance) -> String {
        switch p {
        case .strap: String(localized: "from strap", bundle: LanguageManager.appBundle)
        case .watchSamples: String(localized: "via Apple Watch", bundle: LanguageManager.appBundle)
        case .healthKitComputed: String(localized: "via Apple Health", bundle: LanguageManager.appBundle)
        }
    }
}
