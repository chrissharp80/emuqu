import SwiftUI

// The boundary handles, gesture handling and stage editing controls. Members
// are internal rather than `private` because Swift's `private` does not reach
// across files.

extension SleepTimelineEditorView {
    // MARK: - Boundary handle

    func boundaryHandle(
        seg: SleepTimelineState.Segment,
        side: SleepTimelineEdit.Side,
        vp: (start: Date, end: Date),
        width: CGFloat,
        barHeight: CGFloat
    ) -> some View {
        Circle()
            .fill(AppTheme.primary)
            .frame(width: 20, height: 20)
            .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
            .offset(y: (barHeight - 20) / 2)
            // Enlarge the hit area to the 44pt touch target without affecting layout.
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .gesture(boundaryDragGesture(seg: seg, side: side, vp: vp, width: width))
            .accessibilityElement()
            .accessibilityLabel(side == .start
                ? String(localized: "Start", bundle: LanguageManager.appBundle)
                : String(localized: "End", bundle: LanguageManager.appBundle))
            .accessibilityValue(SleepTimelineState.formatTime(side == .start ? seg.start : seg.end))
            .accessibilityAdjustableAction { direction in
                nudgeBoundary(segmentId: seg.id, side: side, direction: direction)
            }
    }

    /// VoiceOver's swipe up/down on a handle moves that boundary by 5 minutes.
    func nudgeBoundary(segmentId: UUID, side: SleepTimelineEdit.Side, direction: AccessibilityAdjustmentDirection) {
        guard let current = segment(for: segmentId) else { return }
        let step: TimeInterval
        switch direction {
        case .increment: step = 5 * 60
        case .decrement: step = -5 * 60
        @unknown default: return
        }
        let anchor = side == .start ? current.start : current.end
        apply(.adjustBoundary(segmentId: segmentId, side: side, newTime: anchor.addingTimeInterval(step)))
    }

    /// The timeline canvas's coordinate space. Drags are measured in it, not
    /// in the handle's own frame: the handle rides on a bar that moves and
    /// resizes with the drag preview, so its local translation shifted under
    /// the finger mid-drag.
    static let timelineSpace = "sleepTimeline"

    /// Snaps to a 5-minute grid during the drag so the handle doesn't feel
    /// jumpy — small finger movements don't cause visible time changes, and the
    /// preview label shows clean times. The preview is gesture state, so
    /// SwiftUI clears it when the drag ends or is cancelled; only a drag that
    /// ends applies the move. The state does not change mid-drag, so the
    /// anchor is the boundary as the gesture was built.
    func boundaryDragGesture(
        seg: SleepTimelineState.Segment,
        side: SleepTimelineEdit.Side,
        vp: (start: Date, end: Date),
        width: CGFloat
    ) -> some Gesture {
        let anchor = side == .start ? seg.start : seg.end
        let segmentId = seg.id
        return DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.timelineSpace))
            .updating($dragPreview) { value, preview, _ in
                preview = BoundaryDrag(
                    segmentId: segmentId, side: side, anchor: anchor,
                    translation: value.translation.width, vp: vp, width: width
                )
            }
            .onEnded { value in
                let drop = BoundaryDrag(
                    segmentId: segmentId, side: side, anchor: anchor,
                    translation: value.translation.width, vp: vp, width: width
                )
                apply(.adjustBoundary(segmentId: drop.segmentId, side: drop.side, newTime: drop.newTime))
            }
    }

    func dragPreviewLabel(
        seg _: SleepTimelineState.Segment,
        preview: BoundaryDrag,
        width: CGFloat,
        height _: CGFloat,
        vp: (start: Date, end: Date)
    ) -> some View {
        let total = vp.end.timeIntervalSince(vp.start)
        let x = CGFloat(preview.newTime.timeIntervalSince(vp.start) / total) * width
        return Text(SleepTimelineState.formatTime(preview.newTime))
            .font(.caption.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(AppTheme.textPrimary.opacity(0.85))
            .foregroundColor(AppTheme.cardBackground)
            .cornerRadius(6)
            .offset(x: x - 32, y: 0)
    }

    // MARK: - Segment inspector (toolbar below timeline)

    /// While a boundary of this segment is being dragged, the header, pills
    /// and source describe the segment as the drop would leave it.
    func segmentInspector(_ committed: SleepTimelineState.Segment) -> some View {
        let seg = previewedSegment(committed)
        let stages = SleepMergingPipeline.accumulateStageMinutes(seg.intervals)
        return VStack(alignment: .leading, spacing: 12) {
            inspectorHeader(seg)
            if stages.totalSleep > 0 || stages.awake > 0 {
                inspectorStagePills(stages)
            }
            Text("Source: \(sourceLabel(for: Set(seg.intervals.map(\.provenance))))", bundle: LanguageManager.appBundle)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
            inspectorActions(seg)
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(12)
    }

    /// `seg` as the in-progress drag would leave it, through the same
    /// transform the drop applies; `seg` itself when no drag of it is live.
    func previewedSegment(_ seg: SleepTimelineState.Segment) -> SleepTimelineState.Segment {
        guard let preview = dragPreview, preview.segmentId == seg.id else { return seg }
        let moved = state.applying(.adjustBoundary(segmentId: seg.id, side: preview.side, newTime: preview.newTime))
        return moved.segments.first { $0.id == seg.id } ?? seg
    }

    func inspectorHeader(_ seg: SleepTimelineState.Segment) -> some View {
        HStack {
            Text("\(SleepTimelineState.formatTime(seg.start)) – \(SleepTimelineState.formatTime(seg.end))")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Spacer()
            Text(AppTheme.formatMinutes(Int(seg.end.timeIntervalSince(seg.start) / 60)))
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    func inspectorStagePills(_ stages: StageMinutes) -> some View {
        HStack(spacing: 10) {
            if stages.deep > 0 { stagePill(String(localized: "Deep", bundle: LanguageManager.appBundle), minutes: stages.deep, stage: .deep) }
            if stages.core > 0 { stagePill(String(localized: "Light", bundle: LanguageManager.appBundle), minutes: stages.core, stage: .core) }
            if stages.rem > 0 { stagePill(String(localized: "REM", bundle: LanguageManager.appBundle), minutes: stages.rem, stage: .rem) }
            if stages.unspecified > 0 {
                stagePill(String(localized: "Asleep", bundle: LanguageManager.appBundle), minutes: stages.unspecified, stage: .unspecified)
            }
            if stages.awake > 0 { stagePill(String(localized: "Awake", bundle: LanguageManager.appBundle), minutes: stages.awake, stage: .awake) }
            Spacer()
        }
    }

    /// Split and Carve both seed their pending edit at the segment's midpoint —
    /// the user drags from there rather than starting from an arbitrary edge.
    func inspectorActions(_ seg: SleepTimelineState.Segment) -> some View {
        let mid = seg.start.addingTimeInterval(seg.end.timeIntervalSince(seg.start) / 2)
        return HStack(spacing: 8) {
            splitButton(seg, mid: mid)
            inspectorButton(icon: "eye.slash", label: String(localized: "Carve Awake", bundle: LanguageManager.appBundle)) {
                pendingCarve = PendingRange(start: mid.addingTimeInterval(-15 * 60), end: mid.addingTimeInterval(15 * 60))
            }
            mergeButton(seg)
            inspectorButton(icon: "trash", label: String(localized: "Delete", bundle: LanguageManager.appBundle), destructive: true) {
                apply(.removeSegment(segmentId: seg.id))
                selectedSegmentId = nil
            }
        }
    }

    /// Only offered when the segment is longer than two minutes: a split needs
    /// a minute on each side of the cut.
    @ViewBuilder
    func splitButton(_ seg: SleepTimelineState.Segment, mid: Date) -> some View {
        if seg.end.timeIntervalSince(seg.start) > 120 {
            inspectorButton(icon: "scissors", label: String(localized: "Split", bundle: LanguageManager.appBundle)) {
                pendingSplit = PendingSplit(segmentId: seg.id, segmentStart: seg.start, segmentEnd: seg.end, atTime: mid)
            }
        }
    }

    /// Only offered when there is an adjacent segment close enough to merge into.
    @ViewBuilder
    func mergeButton(_ seg: SleepTimelineState.Segment) -> some View {
        if let neighbor = nearestMergeNeighbor(of: seg) {
            inspectorButton(icon: "arrow.triangle.merge", label: String(localized: "Merge", bundle: LanguageManager.appBundle)) {
                apply(.merge(leftId: seg.id, rightId: neighbor.id))
            }
        }
    }

    /// Names in a fixed order (sensors first, then the user's edits), so the
    /// line reads the same on every render whatever order the set iterates.
    func sourceLabel(for provs: Set<HealthKitManager.SleepStageProvenance>) -> String {
        if provs.isEmpty { return String(localized: "Recording bounds", bundle: LanguageManager.appBundle) }
        let order: [HealthKitManager.SleepStageProvenance] = [.watch, .iphone, .hrvDerived, .userAdded, .userCarved, .userAdjusted]
        let names: [String] = order.filter(provs.contains).map {
            switch $0 {
            case .watch: "Watch"
            case .iphone: "iPhone"
            case .hrvDerived: "HRV"
            case .userAdded: String(localized: "You (added)", bundle: LanguageManager.appBundle)
            case .userCarved: String(localized: "You (awake)", bundle: LanguageManager.appBundle)
            case .userAdjusted: String(localized: "You (edited)", bundle: LanguageManager.appBundle)
            }
        }
        return names.joined(separator: " · ")
    }

    func stagePill(_ label: String, minutes: Int, stage: HealthKitManager.SleepStage) -> some View {
        let color = SleepStageColors.color(for: stage)
        return HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(label) \(AppTheme.formatMinutes(minutes))", bundle: LanguageManager.appBundle)
                .font(.caption2.weight(.medium))
                .foregroundColor(color)
        }
    }

    func inspectorButton(icon: String, label: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.caption2.weight(.medium))
            }
            .foregroundColor(destructive ? AppTheme.terracotta : AppTheme.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background((destructive ? AppTheme.terracotta : AppTheme.primary).opacity(0.08))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hint card (no selection)

    var hintCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "hand.tap")
                    .foregroundColor(AppTheme.primary)
                Text(String(localized: "Tap a segment to edit it", bundle: LanguageManager.appBundle))
                    .font(.caption.weight(.medium))
            }
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .foregroundColor(AppTheme.primary)
                Text(String(localized: "Long-press the timeline to add sleep", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(12)
    }

    // MARK: - Edits audit

    // A single
    // useful line: this visit's edits counted by type + a Reset button that
    // undoes them, back to the night as it was when the editor opened (or
    // was last refreshed). Edits saved on earlier visits are part of that
    // starting point, so they are neither counted nor reset. A
    // per-row "Start moved to 8:50 PM" log is net negative — past
    // a few drags it is a wall of text and doesn't help anyone.
    @ViewBuilder
    var editsSummaryCard: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            editsSummaryText
            Spacer()
            resetButton
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(12)
    }

    private var editsSummaryText: some View {
        let edits = editsThisVisit
        let summary = formatEditSummary(editKindCounts(edits))
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(edits.count) edits applied", bundle: LanguageManager.appBundle)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.textPrimary)
            if !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
    }

    private var resetButton: some View {
        Button {
            resetEditsToOriginal()
        } label: {
            Label(String(localized: "Reset", bundle: LanguageManager.appBundle), systemImage: "arrow.counterclockwise")
                .font(.caption.weight(.semibold))
        }
    }

    /// `state.edits` starts from the edits already saved on the night; only
    /// the ones after those were made here.
    var editsThisVisit: [SleepEditRecord] {
        Array(state.edits.dropFirst(originalSleepData.edits.count))
    }

    func editKindCounts(_ edits: [SleepEditRecord]) -> [SleepEditRecord.Kind: Int] {
        var counts: [SleepEditRecord.Kind: Int] = [:]
        for edit in edits { counts[edit.kind, default: 0] += 1 }
        return counts
    }

    func formatEditSummary(_ counts: [SleepEditRecord.Kind: Int]) -> String {
        let order: [SleepEditRecord.Kind] = [
            .adjustBoundary, .addSegment, .removeSegment, .split, .merge, .carveAwake, .unknown
        ]
        var parts: [String] = []
        for kind in order {
            guard let n = counts[kind], n > 0 else { continue }
            parts.append(countedLabel(for: kind, count: n))
        }
        return parts.joined(separator: " · ")
    }

    /// The count and its noun as one catalog entry per edit kind, so each
    /// language picks its own plural form (Russian, Arabic and Icelandic
    /// need more than singular and plural).
    func countedLabel(for kind: SleepEditRecord.Kind, count n: Int) -> String {
        let b = LanguageManager.appBundle
        return switch kind {
        case .adjustBoundary: String(localized: "\(n) boundary moves", bundle: b)
        case .addSegment: String(localized: "\(n) segments added", bundle: b)
        case .removeSegment: String(localized: "\(n) segments removed", bundle: b)
        case .split: String(localized: "\(n) splits", bundle: b)
        case .merge: String(localized: "\(n) merges", bundle: b)
        case .carveAwake: String(localized: "\(n) marked awake periods", bundle: b)
        case .unknown: String(localized: "\(n) edits", bundle: b)
        }
    }

    func resetEditsToOriginal() {
        // Push the current state onto undo so a misclick is recoverable.
        undo.push(state)
        state = SleepTimelineState.initial(from: originalSleepData)
    }

    @ViewBuilder
    var refreshCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            refreshFromAppleHealthSection
            if let err = refreshError {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(AppTheme.terracottaText)
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(12)
    }

    private var refreshFromAppleHealthSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.text.square")
                .font(.title3)
                .foregroundColor(AppTheme.primary)
                .frame(width: 28)
            refreshFromHealthLabel
            Spacer()
            if refreshing {
                ProgressView().scaleEffect(0.8)
            } else {
                refreshButton
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await runRefreshFromHealthKit() }
        } label: {
            Label(String(localized: "Refresh", bundle: LanguageManager.appBundle), systemImage: "arrow.clockwise")
                .font(.caption.weight(.semibold))
        }
    }

    private var refreshFromHealthLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "Refresh from Apple Health", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.textPrimary)
            Text(String(localized: "Re-pull the latest sleep snapshot. Your current edits will be discarded.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A fetch that fails keeps the timeline and shows why. A night with
    /// nothing to draw (no stages and no sleep envelope, which is what the
    /// fetch returns for a night that does not fit the recording) is refused
    /// the same way rather than blanking the timeline. A good fetch replaces
    /// the starting point and clears undo, as the card warns: undoing past
    /// it would put the old night's timeline over the new one.
    @MainActor
    func runRefreshFromHealthKit() async {
        guard let provider = onRefreshFromHealthKit else { return }
        refreshing = true
        refreshError = nil
        defer { refreshing = false }
        guard let fresh = await provider() else {
            refreshError = String(localized: "Couldn't pull sleep data from Apple Health. Check Settings → Privacy & Security → Health → Emuqu.", bundle: LanguageManager.appBundle)
            return
        }
        let freshState = SleepTimelineState.initial(from: fresh)
        guard !freshState.segments.isEmpty else {
            refreshError = String(localized: "No sleep data found for the requested period", bundle: LanguageManager.appBundle)
            return
        }
        undo.clear()
        originalSleepData = fresh
        state = freshState
        refreshedFromHealth = true
    }

    // MARK: - Apply / Undo / Commit

    func apply(_ edit: SleepTimelineEdit) {
        let before = state
        let after = state.applying(edit)
        guard after != before else { return }
        undo.push(before)
        state = after
    }

    /// Only persist when the timeline actually changed. "Done"
    /// is the normal way to CLOSE the editor after merely viewing sleep;
    /// firing `onSave` unconditionally stamps the session
    /// `sleepUserAdjusted = true` with zero edits. That permanently locks
    /// the session's sleep boundaries against automatic refinement AND feeds a
    /// later reanalyze a different search band — the root of a user reporting
    /// "I did not manually adjust sleep" yet seeing the score diverge.
    ///
    /// Compare by CONTENT against the currently-loaded timeline
    /// (`originalSleepData`), not by `==`: `SleepTimelineState.initial(from:)`
    /// mints fresh segment/interval UUIDs on every call, so
    /// `state != initial(...)` is ALWAYS true and would defeat the check.
    /// `hasSameContent` ignores identities.
    ///
    /// Baseline is `originalSleepData`, NOT the `sleepData` prop: a "Refresh
    /// from HealthKit" moves `originalSleepData`/`state` to the fresh data but
    /// leaves `sleepData` at the original. Comparing to `sleepData` would make
    /// a PURE refresh (no manual edit) look changed → fire onSave → re-lock
    /// `sleepUserAdjusted`, re-opening the "I didn't adjust sleep" bug.
    /// Against `originalSleepData`: a manual edit differs → saves + locks; a
    /// pure refresh matches → hands the refreshed night to
    /// `onRefreshAccepted` (stored without the lock); refresh-then-edit →
    /// saves.
    func commit() {
        guard !state.hasSameContent(as: SleepTimelineState.initial(from: originalSleepData)) else {
            if refreshedFromHealth { onRefreshAccepted?(originalSleepData) }
            dismiss()
            return
        }
        onSave(SleepScienceAnalyzer.buildSleepDataFromTimelineState(original: originalSleepData, state: state))
        dismiss()
    }

    // MARK: - Helpers

    var selectedSegment: SleepTimelineState.Segment? {
        guard let id = selectedSegmentId else { return nil }
        return state.segments.first(where: { $0.id == id })
    }

    func segment(for id: UUID) -> SleepTimelineState.Segment? {
        state.segments.first(where: { $0.id == id })
    }

    func nearestMergeNeighbor(of seg: SleepTimelineState.Segment) -> SleepTimelineState.Segment? {
        let maxGap = Double(SleepTimelineState.maxMergeGapMinutes) * 60
        var best: (SleepTimelineState.Segment, TimeInterval)?
        for other in state.segments where other.id != seg.id {
            let gap: TimeInterval = if other.start >= seg.end {
                other.start.timeIntervalSince(seg.end)
            } else if seg.start >= other.end {
                seg.start.timeIntervalSince(other.end)
            } else {
                -1 // overlapping: `applyingMerge` refuses these
            }
            guard gap >= 0, gap <= maxGap else { continue }
            if gap < (best?.1 ?? .infinity) {
                best = (other, gap)
            }
        }
        return best?.0
    }
}
