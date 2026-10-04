import SwiftUI

// MARK: - Shared Stage Colors

/// Consistent stage colors used across all sleep visualizations
enum SleepStageColors {
    static func color(for stage: HealthKitManager.SleepStage) -> Color {
        switch stage {
        case .deep: Color(red: 0.38, green: 0.30, blue: 0.78) // #6150C7 — vivid indigo
        case .core: Color(red: 0.45, green: 0.58, blue: 0.92) // #7394EB — bright blue
        case .rem: Color(red: 0.30, green: 0.78, blue: 0.82) // #4DC7D1 — teal
        case .awake: Color(red: 0.95, green: 0.72, blue: 0.30) // #F2B84D — amber
        case .unspecified: Color(red: 0.55, green: 0.58, blue: 0.75) // #8C94BF — muted blue
        }
    }

    /// Y position for hypnogram (0 = top/awake, 1 = bottom/deep)
    static func depth(_ stage: HealthKitManager.SleepStage) -> CGFloat {
        switch stage {
        case .awake: 0.0
        case .rem: 0.33
        case .core: 0.60
        // Unstaged sleep (user-added, or a source that reports no stages)
        // sits on its own line between Light and Deep, so it is never read
        // as Light.
        case .unspecified: 0.80
        case .deep: 1.0
        }
    }
}

// MARK: - Hypnogram Timeline

/// Canvas-drawn hypnogram showing sleep depth over time.
/// Renders as a stepped line with gradient fill — deep sleep at bottom, awake at top.
/// Gaps between sessions shown as breaks in the line.
struct SleepTimelineChart: View {
    let stageIntervals: [HealthKitManager.SleepStageInterval]
    let sleepStart: Date?
    let sleepEnd: Date?
    let inBedStart: Date?
    let boundaryValidation: HealthKitManager.SleepBoundaryValidation?
    /// Gap (minutes) that separates distinct sleep sessions in the chart.
    /// Defaults to `SleepConstants.defaultSplitGapMinutes` to stay in sync
    /// with the data layer's `SleepMergingPipeline`.
    var splitGapMinutes: Int = SleepConstants.defaultSplitGapMinutes

    private let chartHeight: CGFloat = 100
    private let topPad: CGFloat = 8
    private let bottomPad: CGFloat = 4

    private var drawHeight: CGFloat {
        chartHeight - topPad - bottomPad
    }

    private var sorted: [HealthKitManager.SleepStageInterval] {
        stageIntervals.sorted { $0.start < $1.start }
    }

    private var timelineStart: Date {
        let earliest = inBedStart ?? sorted.first?.start ?? sleepStart ?? Date()
        return min(earliest, sleepStart ?? earliest).addingTimeInterval(-10 * 60)
    }

    private var timelineEnd: Date {
        let latest = sorted.last?.end ?? sleepEnd ?? Date()
        return max(latest, sleepEnd ?? latest).addingTimeInterval(10 * 60)
    }

    private var totalDuration: TimeInterval {
        max(1, timelineEnd.timeIntervalSince(timelineStart))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Stage labels on left + canvas
            HStack(alignment: .top, spacing: 0) {
                stageLabels
                hypnogramCanvas
            }
            .frame(height: chartHeight)

            // Time axis
            timeAxis
                .padding(.leading, 34)

            // Boundary times row
            boundaryTimesRow
                .padding(.leading, 34)
                .padding(.top, 6)
        }
    }

    /// Y-axis labels, each centred on its stage's grid line.
    private var stageLabels: some View {
        ZStack(alignment: .topTrailing) {
            stageLabel(String(localized: "Awake", bundle: LanguageManager.appBundle), stage: .awake)
            stageLabel(String(localized: "REM", bundle: LanguageManager.appBundle), stage: .rem)
            stageLabel(String(localized: "Light", bundle: LanguageManager.appBundle), stage: .core)
            stageLabel(String(localized: "Deep", bundle: LanguageManager.appBundle), stage: .deep)
            if stageIntervals.contains(where: { $0.stage == .unspecified }) {
                stageLabel(String(localized: "Asleep", bundle: LanguageManager.appBundle), stage: .unspecified)
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundColor(AppTheme.textTertiary)
        .frame(width: 34, height: chartHeight)
    }

    private func stageLabel(_ title: String, stage: HealthKitManager.SleepStage) -> some View {
        Text(title)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 32, alignment: .trailing)
            .position(x: 16, y: topPad + SleepStageColors.depth(stage) * drawHeight)
    }

    private var hypnogramCanvas: some View {
        Canvas { context, size in
            drawHypnogram(context: context, size: size)
        }
        .frame(height: chartHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hypnogramAccessibilityLabel)
    }

    /// Time formatter for sleep and wake times.
    static var sleepTimeFormatter: DateFormatter { LocalizedDateFormat.formatter(template: "jmm") }

    private var hypnogramAccessibilityLabel: String {
        let unknown = String(localized: "Unknown", bundle: LanguageManager.appBundle)
        let start = sleepStart.map { Self.sleepTimeFormatter.string(from: $0) } ?? unknown
        let end = sleepEnd.map { Self.sleepTimeFormatter.string(from: $0) } ?? unknown
        return String(
            localized: "Sleep stages hypnogram showing \(sorted.count) intervals from \(start) to \(end)",
            bundle: LanguageManager.appBundle
        )
    }

    // MARK: - Canvas Drawing

    private func drawHypnogram(context: GraphicsContext, size: CGSize) {
        let w = size.width
        guard !sorted.isEmpty else { return }

        // Horizontal grid lines (subtle)
        let gridColor = Color.gray.opacity(0.15)
        for depth in [0.0, 0.33, 0.60, 1.0] as [CGFloat] {
            let y = topPad + depth * drawHeight
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: w, y: y))
            context.stroke(line, with: .color(gridColor), lineWidth: 0.5)
        }

        // Group intervals into sessions (a gap longer than `splitGapMinutes` starts a new one)
        let sessions = groupIntoSessions(sorted)

        for session in sessions {
            guard !session.isEmpty else { continue }
            drawSession(session, context: context, width: w)
        }
    }

    private func drawSession(
        _ intervals: [HealthKitManager.SleepStageInterval],
        context: GraphicsContext,
        width: CGFloat
    ) {
        guard !intervals.isEmpty else { return }
        fillUnderStages(intervals, context: context, width: width)
        strokeStageSegments(intervals, context: context, width: width)
        strokeStepConnectors(intervals, context: context, width: width)
    }

    /// Vertical gradient under the stepped hypnogram — indigo at the bottom,
    /// transparent at the top.
    private func fillUnderStages(
        _ intervals: [HealthKitManager.SleepStageInterval],
        context: GraphicsContext,
        width: CGFloat
    ) {
        guard let path = steppedFillPath(intervals, width: width) else { return }
        let gradient = Gradient(colors: [
            AppTheme.primary.opacity(0.05),
            AppTheme.primary.opacity(0.25)
        ])
        context.fill(path, with: .linearGradient(
            gradient,
            startPoint: CGPoint(x: 0, y: topPad),
            endPoint: CGPoint(x: 0, y: topPad + drawHeight)
        ))
    }

    private func steppedFillPath(_ intervals: [HealthKitManager.SleepStageInterval], width: CGFloat) -> Path? {
        guard let first = intervals.first, let last = intervals.last else { return nil }
        let baseY = topPad + drawHeight // bottom of chart
        var fillPath = Path()
        fillPath.move(to: CGPoint(x: xPos(first.start, width), y: baseY))
        fillPath.addLine(to: CGPoint(x: xPos(first.start, width), y: yForStage(first.stage)))
        for interval in intervals {
            let y = yForStage(interval.stage)
            fillPath.addLine(to: CGPoint(x: xPos(interval.start, width), y: y))
            fillPath.addLine(to: CGPoint(x: xPos(interval.end, width), y: y))
        }
        fillPath.addLine(to: CGPoint(x: xPos(last.end, width), y: baseY))
        fillPath.closeSubpath()
        return fillPath
    }

    /// One coloured horizontal run per stage interval.
    private func strokeStageSegments(
        _ intervals: [HealthKitManager.SleepStageInterval],
        context: GraphicsContext,
        width: CGFloat
    ) {
        for interval in intervals {
            let y = yForStage(interval.stage)
            var segPath = Path()
            segPath.move(to: CGPoint(x: xPos(interval.start, width), y: y))
            segPath.addLine(to: CGPoint(x: xPos(interval.end, width), y: y))
            context.stroke(
                segPath,
                with: .color(SleepStageColors.color(for: interval.stage)),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
        }
    }

    /// Thin verticals joining one stage depth to the next.
    private func strokeStepConnectors(
        _ intervals: [HealthKitManager.SleepStageInterval],
        context: GraphicsContext,
        width: CGFloat
    ) {
        // `1 ..< 0` traps when there are no staged intervals — the common
        // case for a strap-only user with no watch.
        guard intervals.count > 1 else { return }
        for i in 1 ..< intervals.count {
            let y1 = yForStage(intervals[i - 1].stage)
            let y2 = yForStage(intervals[i].stage)
            guard abs(y1 - y2) > 1 else { continue }
            let x = xPos(intervals[i].start, width)
            var stepLine = Path()
            stepLine.move(to: CGPoint(x: x, y: y1))
            stepLine.addLine(to: CGPoint(x: x, y: y2))
            context.stroke(
                stepLine,
                with: .color(AppTheme.textTertiary.opacity(0.4)),
                lineWidth: 1
            )
        }
    }

    // MARK: - Session grouping

    /// Group intervals into sessions separated by gaps exceeding `splitGapMinutes`.
    private func groupIntoSessions(
        _ intervals: [HealthKitManager.SleepStageInterval]
    ) -> [[HealthKitManager.SleepStageInterval]] {
        guard !intervals.isEmpty else { return [] }
        let gapThreshold = TimeInterval(splitGapMinutes) * 60
        var sessions: [[HealthKitManager.SleepStageInterval]] = []
        var current: [HealthKitManager.SleepStageInterval] = [intervals[0]]

        for i in 1 ..< intervals.count {
            let gap = intervals[i].start.timeIntervalSince(intervals[i - 1].end)
            if gap > gapThreshold {
                sessions.append(current)
                current = [intervals[i]]
            } else {
                current.append(intervals[i])
            }
        }
        sessions.append(current)
        return sessions
    }

    // MARK: - Coordinate mapping

    private func xPos(_ date: Date, _ width: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSince(timelineStart) / totalDuration) * width
    }

    private func yForStage(_ stage: HealthKitManager.SleepStage) -> CGFloat {
        topPad + SleepStageColors.depth(stage) * drawHeight
    }

    // MARK: - Time Axis

    private var timeAxis: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let hours = hourMarkers()

            ForEach(hours, id: \.self) { date in
                hourMarker(date, width: width)
            }
        }
        .frame(height: 18)
    }

    /// One hour tick + label, suppressed near either edge where it would
    /// collide with the boundary times.
    @ViewBuilder
    private func hourMarker(_ date: Date, width: CGFloat) -> some View {
        let x = xPos(date, width)
        if x > 16, x < width - 16 {
            VStack(spacing: 2) {
                Rectangle()
                    .fill(AppTheme.textTertiary.opacity(0.3))
                    .frame(width: 1, height: 4)
                Text(hourLabel(date))
                    .font(.caption2.weight(.medium))
                    .foregroundColor(AppTheme.textTertiary)
            }
            .position(x: x, y: 8)
        }
    }

    private func hourMarkers() -> [Date] {
        let calendar = Calendar.current
        var markers: [Date] = []
        guard var current = calendar.nextDate(
            after: timelineStart,
            matching: DateComponents(minute: 0),
            matchingPolicy: .nextTime
        ) else { return [] }
        while current < timelineEnd {
            markers.append(current)
            current = current.addingTimeInterval(3600)
        }
        return markers
    }

    /// Hoisted out of `hourLabel(_:)` — that helper runs once per hour
    /// marker on every chart render; a fresh `DateFormatter()` each call
    /// was needless allocation.
    private static var hourLabelFormatter: DateFormatter { LocalizedDateFormat.formatter(template: "j") }

    private func hourLabel(_ date: Date) -> String {
        // "10pm" rather than "10 PM": the axis is tight, and a 24-hour locale
        // gets "22" either way.
        return Self.hourLabelFormatter.string(from: date).lowercased()
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    // MARK: - Boundary Times

    private var boundaryTimesRow: some View {
        HStack {
            bedtimeLabel
            Spacer()
            wakeLabel
        }
    }

    @ViewBuilder
    private var bedtimeLabel: some View {
        if let start = sleepStart {
            HStack(spacing: 4) {
                Image(systemName: "moon.fill")
                    .font(.caption2)
                    .foregroundColor(AppTheme.primary.opacity(0.7))
                Text(start, style: .time)
                    .font(.caption.weight(.medium))
            }
        }
    }

    @ViewBuilder
    private var wakeLabel: some View {
        if let end = sleepEnd {
            HStack(spacing: 4) {
                Text(end, style: .time)
                    .font(.caption.weight(.medium))
                Image(systemName: "sun.max.fill")
                    .font(.caption2)
                    .foregroundColor(AppTheme.softGold.opacity(0.7))
            }
        }
    }
}
