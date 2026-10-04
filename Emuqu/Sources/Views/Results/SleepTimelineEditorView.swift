import SwiftUI

/// Timeline-based sleep editor.
///
/// Capabilities (state-of-the-art sweep: Sleep as Android / Pillow / Oura):
/// - Drag each segment's start/end boundary (snaps to a 5-minute grid; never
///   into a neighbouring segment)
/// - Tap segment to select; toolbar offers Split, Carve Awake, Merge, Delete
/// - Long-press empty timeline → add a user-declared segment
/// - 5-step undo
/// - Provenance shown by dashed stroke (user edits) vs solid (HealthKit)
///
/// On Done, the edit state is converted to SleepData via
/// `SleepScienceAnalyzer.buildSleepDataFromTimelineState` and handed back to
/// `updateSessionSleepBoundaries` — the existing rescore + archive path.
struct SleepTimelineEditorView: View {
    let sleepData: SleepData
    let onSave: (SleepData) -> Void
    /// Lets the editor pull a fresh
    /// snapshot from HealthKit (e.g., when the user has manually
    /// edited sleep in the Health app since this session was first
    /// recorded). When nil, the Refresh button is hidden — call sites
    /// that don't have HealthKit access (legacy / preview / unit
    /// tests) keep working.
    let onRefreshFromHealthKit: (() async -> SleepData?)?

    @Environment(\.dismiss) var dismiss

    @State var state: SleepTimelineState
    @State var undo = SleepTimelineUndoStack()
    @State var selectedSegmentId: UUID?
    @State var dragPreview: BoundaryDrag?
    /// Snapshot of the data the editor opened with (or last refreshed to).
    /// Used as the target of "Reset" (undoes this visit's edits) and for the
    /// summary card's "net change" computation.
    @State var originalSleepData: SleepData
    @State var refreshing: Bool = false
    @State var refreshError: String?

    /// Sheet state for add-segment and carve flows.
    @State private var pendingAdd: PendingRange?
    @State var pendingCarve: PendingRange?
    /// Split goes through a preview sheet so the user sees where the cut
    /// will land and can adjust it before committing.
    @State var pendingSplit: PendingSplit?

    init(
        sleepData: SleepData,
        onSave: @escaping (SleepData) -> Void,
        onRefreshFromHealthKit: (() async -> SleepData?)? = nil
    ) {
        self.sleepData = sleepData
        self.onSave = onSave
        self.onRefreshFromHealthKit = onRefreshFromHealthKit
        _state = State(initialValue: SleepTimelineState.initial(from: sleepData))
        _originalSleepData = State(initialValue: sleepData)
    }

    /// Derived viewport: encompasses all segments with 15-min padding on each side.
    private var viewport: (start: Date, end: Date) {
        let segStart = state.segments.map(\.start).min()
        let segEnd = state.segments.map(\.end).max()
        let base = segStart ?? originalSleepData.sleepStart ?? Date()
        let tail = segEnd ?? originalSleepData.sleepEnd ?? base.addingTimeInterval(8 * 3600)
        return (base.addingTimeInterval(-15 * 60), tail.addingTimeInterval(15 * 60))
    }

    var body: some View {
        NavigationStack {
            editorScroll
        }
    }

    private var editorScroll: some View {
        ScrollView {
            editorStack
        }
        .background(AppTheme.background)
        .navigationTitle(String(localized: "Edit Sleep", bundle: LanguageManager.appBundle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { editorToolbar }
        .sheet(item: $pendingAdd) { addSleepSheet($0) }
        .sheet(item: $pendingCarve) { carveAwakeSheet($0) }
        .sheet(item: $pendingSplit) { splitSegmentSheet($0) }
    }

    /// Undo sits in a visible spot AND has a text label. A bare arrow icon
    /// next to Done (topBarTrailing) is not recognized as "undo" — users
    /// report "no undo." Pinned next to Cancel on the
    /// leading side so it's discoverable and clearly labeled, and disabled when
    /// there's nothing to undo so it doesn't look interactive when it isn't.
    private var undoButton: some View {
        Button {
            if let previous = undo.pop() { state = previous }
        } label: {
            Label(String(localized: "Undo", bundle: LanguageManager.appBundle), systemImage: "arrow.uturn.backward")
                .labelStyle(.titleAndIcon)
        }
        .disabled(!undo.canUndo)
        .accessibilityLabel(String(localized: "Undo last edit", bundle: LanguageManager.appBundle))
    }

    private func addSleepSheet(_ range: PendingRange) -> some View {
        AddSleepSheet(range: range) { confirmed in
            apply(.addSegment(start: confirmed.start, end: confirmed.end))
            pendingAdd = nil
        } onCancel: { pendingAdd = nil }
            .presentationDetents([.medium])
    }

    private func carveAwakeSheet(_ range: PendingRange) -> some View {
        CarveAwakeSheet(range: range) { confirmed in
            apply(.carveAwake(start: confirmed.start, end: confirmed.end))
            pendingCarve = nil
        } onCancel: { pendingCarve = nil }
            .presentationDetents([.medium])
    }

    private func splitSegmentSheet(_ split: PendingSplit) -> some View {
        SplitSegmentSheet(split: split) { confirmed in
            apply(.split(segmentId: confirmed.segmentId, atTime: confirmed.atTime))
            pendingSplit = nil
        } onCancel: { pendingSplit = nil }
            .presentationDetents([.medium])
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Cancel", bundle: LanguageManager.appBundle)) { dismiss() }
        }
        ToolbarItem(placement: .topBarLeading) { undoButton }
        ToolbarItem(placement: .confirmationAction) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) { commit() }
                .fontWeight(.semibold)
        }
    }

    private var editorStack: some View {
        VStack(spacing: 16) {
            summaryCard

            timelineCard

            if let seg = selectedSegment { segmentInspector(seg) } else { hintCard }

            // A single-line summary + Reset rather than a noisy
            // "Your edits (22)" disclosure: a list that dumps
            // every drag op as a separate "End moved to 2:25 AM"
            // row is useless past 3 edits.
            if !editsThisVisit.isEmpty { editsSummaryCard }
            if onRefreshFromHealthKit != nil { refreshCard }
        }
        .padding()
    }

    // MARK: - Summary

    private var summaryCard: some View {
        let totalMinutes = editedTotalSleepMinutes
        return HStack(alignment: .firstTextBaseline) {
            totalSleepReadout(totalMinutes)
            Spacer()
            deltaBadge(totalMinutes - originalSleepData.nightSleepMinutes)
            Text("\(state.segments.count) segments", bundle: LanguageManager.appBundle)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(12)
    }

    /// `totalSleep` already sums detailed (deep/rem/core) + unspecified —
    /// user-declared segments (stored as unspecified) contribute here.
    ///
    /// Interval-less envelope segments (strap-only / HR-estimated
    /// nights) count their duration, matching what
    /// `buildSleepDataFromTimelineState` persists on Done.
    private var editedTotalSleepMinutes: Int {
        state.segments.reduce(0) { acc, seg in
            if seg.intervals.isEmpty {
                return acc + max(0, Int(seg.end.timeIntervalSince(seg.start) / 60))
            }
            return acc + SleepMergingPipeline.accumulateStageMinutes(seg.intervals).totalSleep
        }
    }

    private func totalSleepReadout(_ totalMinutes: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "TOTAL SLEEP", bundle: LanguageManager.appBundle))
                .font(.caption2.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(1)
            Text(AppTheme.formatMinutes(totalMinutes))
                .font(.title.weight(.bold))
                .monospacedDigit()
        }
    }

    /// How far the user's edits have moved the night from the stored total.
    @ViewBuilder
    private func deltaBadge(_ deltaMinutes: Int) -> some View {
        if deltaMinutes != 0 {
            Text(verbatim: (deltaMinutes > 0 ? "+" : "\u{2212}") + LocalizedDuration.hoursMinutes(minutes: abs(deltaMinutes)))
                .font(.subheadline.weight(.semibold))
                .foregroundColor(deltaMinutes > 0 ? AppTheme.sage : AppTheme.terracotta)
        }
    }

    // MARK: - Timeline canvas

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "TIMELINE", bundle: LanguageManager.appBundle))
                .font(.caption2.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(1)

            timelineCanvas

            // Time axis labels (no external chart infra — we draw our own)
            axisLabels
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(12)
    }

    private var timelineCanvas: some View {
        GeometryReader { geo in
            let vp = viewport
            let totalSeconds = vp.end.timeIntervalSince(vp.start)

            ZStack(alignment: .topLeading) {
                addSegmentLayer(vp: vp, totalSeconds: totalSeconds)
                // Hour ticks
                ticksLayer(width: geo.size.width, height: geo.size.height, vp: vp)
                segmentBars(geo: geo, vp: vp)
                dragPreviewOverlay(geo: geo, vp: vp)
            }
            .coordinateSpace(.named(Self.timelineSpace))
        }
        .frame(height: 120)
    }

    private func ticksLayer(width: CGFloat, height: CGFloat, vp: (start: Date, end: Date)) -> some View {
        let totalSeconds = vp.end.timeIntervalSince(vp.start)
        let cal = Calendar.current
        var ticks: [Date] = []
        var t = cal.nextDate(after: vp.start, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? vp.start
        while t < vp.end {
            ticks.append(t)
            t = t.addingTimeInterval(3600)
        }
        return ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.self) { tick in
                let x = CGFloat(tick.timeIntervalSince(vp.start) / totalSeconds) * width
                Rectangle()
                    .fill(AppTheme.textTertiary.opacity(0.15))
                    .frame(width: 1, height: height)
                    .offset(x: x)
            }
        }
    }

    /// Background long-press layer: add a new segment here. VoiceOver gets
    /// the same action by name, since a long press on empty space is not
    /// something it can find.
    private func addSegmentLayer(vp: (start: Date, end: Date), totalSeconds: TimeInterval) -> some View {
        Rectangle()
            .fill(AppTheme.sectionTint)
            .cornerRadius(8)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.35) {
                stagePendingAdd(vp: vp, totalSeconds: totalSeconds)
            }
            .accessibilityElement()
            .accessibilityLabel(String(localized: "Sleep timeline", bundle: LanguageManager.appBundle))
            .accessibilityAction(named: Text(String(localized: "Add Sleep", bundle: LanguageManager.appBundle))) {
                stagePendingAdd(vp: vp, totalSeconds: totalSeconds)
            }
    }

    /// The press location isn't available via the API, so pre-fill 30 minutes
    /// right after the last segment (time nothing already counts); with no
    /// segments, centre it on the viewport. The user adjusts it in the sheet.
    private func stagePendingAdd(vp: (start: Date, end: Date), totalSeconds: TimeInterval) {
        let mid = vp.start.addingTimeInterval(totalSeconds / 2)
        let start = state.segments.map(\.end).max() ?? mid.addingTimeInterval(-15 * 60)
        pendingAdd = PendingRange(start: start, end: start.addingTimeInterval(30 * 60))
    }

    private func segmentBars(geo: GeometryProxy, vp: (start: Date, end: Date)) -> some View {
        ForEach(state.segments, id: \.id) { seg in
            segmentBar(seg, width: geo.size.width, height: geo.size.height, vp: vp)
        }
    }

    /// Shown while a boundary is being dragged.
    @ViewBuilder
    private func dragPreviewOverlay(geo: GeometryProxy, vp: (start: Date, end: Date)) -> some View {
        if let preview = dragPreview, let seg = segment(for: preview.segmentId) {
            dragPreviewLabel(seg: seg, preview: preview, width: geo.size.width, height: geo.size.height, vp: vp)
        }
    }

    private var axisLabels: some View {
        let vp = viewport
        return GeometryReader { geo in
            hourLabels(geo: geo, vp: vp)
        }
        .frame(height: 14)
    }

    private func hourLabels(geo: GeometryProxy, vp: (start: Date, end: Date)) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(axisHours, id: \.self) { hourLabel($0, geo: geo, vp: vp) }
        }
    }

    /// Every other hour, to avoid crowding the axis.
    private var axisHours: [Date] {
        let vp = viewport
        let cal = Calendar.current
        var hours: [Date] = []
        var t = cal.nextDate(after: vp.start, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? vp.start
        while t < vp.end {
            hours.append(t)
            t = t.addingTimeInterval(2 * 3600)
        }
        return hours
    }

    private func hourLabel(_ tick: Date, geo: GeometryProxy, vp: (start: Date, end: Date)) -> some View {
        let totalSeconds = vp.end.timeIntervalSince(vp.start)
        let x = CGFloat(tick.timeIntervalSince(vp.start) / totalSeconds) * geo.size.width
        return Text(shortHour(tick))
            .font(.caption2.monospacedDigit())
            .foregroundColor(AppTheme.textTertiary)
            .offset(x: x - 12)
    }

    private func shortHour(_ date: Date) -> String {
        LocalizedDateFormat.string(from: date, template: "j").lowercased()
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    // MARK: - Segment bar

    private func segmentBar(
        _ seg: SleepTimelineState.Segment,
        width: CGFloat,
        height: CGFloat,
        vp: (start: Date, end: Date)
    ) -> some View {
        let total = vp.end.timeIntervalSince(vp.start)
        let (displayStart, displayEnd) = previewedBounds(seg)
        let x = CGFloat(displayStart.timeIntervalSince(vp.start) / total) * width
        let w = max(2, CGFloat(displayEnd.timeIntervalSince(displayStart) / total) * width)
        let barHeight: CGFloat = 44
        // Handle centres sit on the boundaries; on bars narrower than two touch
        // targets they are pushed outward so both stay grabbable.
        let spread = max(0, (44 - w) / 2)
        return ZStack(alignment: .leading) {
            accessibleStageFill(seg: seg, displayStart: displayStart, displayEnd: displayEnd, width: w, barHeight: barHeight)
            if seg.id == selectedSegmentId {
                boundaryHandle(seg: seg, side: .start, vp: vp, width: width, barHeight: barHeight)
                    .offset(x: -22 - spread)
                boundaryHandle(seg: seg, side: .end, vp: vp, width: width, barHeight: barHeight)
                    .offset(x: w - 22 + spread)
            }
        }
        .frame(width: w, height: barHeight, alignment: .leading)
        .offset(x: x, y: (height - barHeight) / 2)
        .onTapGesture { toggleSelection(seg) }
    }

    /// The bar as VoiceOver sees it: a button named by its time range that
    /// selects the segment, so Split, Carve, Merge and Delete are reachable.
    private func accessibleStageFill(seg: SleepTimelineState.Segment, displayStart: Date, displayEnd: Date, width: CGFloat, barHeight: CGFloat) -> some View {
        stageFill(seg: seg, displayStart: displayStart, displayEnd: displayEnd, width: width, barHeight: barHeight)
            .accessibilityElement()
            .accessibilityLabel(segmentAccessibilityLabel(seg))
            .accessibilityAddTraits(seg.id == selectedSegmentId ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { toggleSelection(seg) }
    }

    private func toggleSelection(_ seg: SleepTimelineState.Segment) {
        withAnimation(.easeOut(duration: 0.15)) {
            selectedSegmentId = (selectedSegmentId == seg.id) ? nil : seg.id
        }
    }

    private func segmentAccessibilityLabel(_ seg: SleepTimelineState.Segment) -> String {
        String(
            localized: "Sleep segment, \(SleepTimelineState.formatTime(seg.start)) – \(SleepTimelineState.formatTime(seg.end))",
            bundle: LanguageManager.appBundle
        )
    }

    /// Apply the live drag preview so the bar follows the finger.
    private func previewedBounds(_ seg: SleepTimelineState.Segment) -> (Date, Date) {
        guard let preview = dragPreview, preview.segmentId == seg.id else { return (seg.start, seg.end) }
        switch preview.side {
        case .start: return (preview.newTime, seg.end)
        case .end: return (seg.start, preview.newTime)
        }
    }

    /// A thin stack of per-stage bands clipped to this segment.
    private func stageFill(seg: SleepTimelineState.Segment, displayStart: Date, displayEnd: Date, width w: CGFloat, barHeight: CGFloat) -> some View {
        stageBands(seg: seg, displayStart: displayStart, displayEnd: displayEnd)
            .frame(width: w, height: barHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        seg.id == selectedSegmentId ? AppTheme.primary : Color.clear,
                        style: StrokeStyle(lineWidth: 2)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func stageBands(
        seg: SleepTimelineState.Segment,
        displayStart: Date,
        displayEnd: Date
    ) -> some View {
        let displayed = SleepMergingPipeline.clipIntervals(seg.intervals, to: displayStart, end: displayEnd)
        let totalDuration = max(1, displayEnd.timeIntervalSince(displayStart))
        return GeometryReader { geo in
            stageBandStack(displayed, displayStart: displayStart, totalDuration: totalDuration, width: geo.size.width)
        }
    }

    private func stageBandStack(
        _ displayed: [HealthKitManager.SleepStageInterval],
        displayStart: Date,
        totalDuration: TimeInterval,
        width: CGFloat
    ) -> some View {
        ZStack(alignment: .leading) {
            // base wash
            Rectangle().fill(SleepStageColors.color(for: .core).opacity(0.25))
            ForEach(displayed) { interval in
                stageBand(
                    interval: interval,
                    width: width * CGFloat(interval.end.timeIntervalSince(interval.start) / totalDuration),
                    offset: width * CGFloat(interval.start.timeIntervalSince(displayStart) / totalDuration)
                )
            }
        }
    }

    private func stageBand(
        interval: HealthKitManager.SleepStageInterval,
        width: CGFloat,
        offset: CGFloat
    ) -> some View {
        let userOrigin = isUserOrigin(interval.provenance)
        return Rectangle()
            .fill(SleepStageColors.color(for: interval.stage))
            .overlay {
                if userOrigin {
                    Rectangle()
                        .strokeBorder(
                            AppTheme.textPrimary.opacity(0.5),
                            style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                        )
                }
            }
            .frame(width: width)
            .offset(x: offset)
            .opacity(userOrigin ? 0.6 : 0.85)
    }

    private func isUserOrigin(_ provenance: HealthKitManager.SleepStageProvenance) -> Bool {
        switch provenance {
        case .userAdded, .userCarved, .userAdjusted: true
        case .watch, .iphone, .hrvDerived: false
        }
    }
}
