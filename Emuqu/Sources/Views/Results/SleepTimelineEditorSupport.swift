import SwiftUI

// Drag state, pending-range and the range and split sheets, split out of
// `SleepTimelineEditorView.swift` at a top-level type boundary.
// Supporting types the editor uses; none carry editing logic.

// MARK: - Drag preview struct

struct BoundaryDrag: Equatable {
    let segmentId: UUID
    let side: SleepTimelineEdit.Side
    let newTime: Date
}

extension BoundaryDrag {
    /// The boundary under the finger: `anchor` moved by a horizontal drag of
    /// `translation` points on a canvas `width` points wide that shows `vp`,
    /// snapped to 5 minutes so small finger movements don't change the time.
    /// The finger may run up to one canvas width past either edge, so one
    /// drag can pull a boundary well beyond the 15-minute padding around the
    /// outermost segment; the edit model still stops it at a neighbour.
    init(
        segmentId: UUID,
        side: SleepTimelineEdit.Side,
        anchor: Date,
        translation: CGFloat,
        vp: (start: Date, end: Date),
        width: CGFloat
    ) {
        let total = vp.end.timeIntervalSince(vp.start)
        let anchorX = CGFloat(anchor.timeIntervalSince(vp.start) / total) * width
        let newX = max(-width, min(2 * width, anchorX + translation))
        let raw = vp.start.addingTimeInterval(Double(newX / width) * total)
        let step: TimeInterval = 5 * 60
        let snapped = (raw.timeIntervalSinceReferenceDate / step).rounded() * step
        self.init(segmentId: segmentId, side: side, newTime: Date(timeIntervalSinceReferenceDate: snapped))
    }
}

struct PendingRange: Identifiable {
    let id = UUID()
    var start: Date
    var end: Date
}

// MARK: - Hour axis

/// Whole-hour marks and their compact labels for a sleep timeline axis.
enum SleepTimelineAxis {
    /// Whole hours in `[start, end)`, every `stepHours` hours from the first.
    static func wholeHours(from start: Date, to end: Date, stepHours: Int) -> [Date] {
        guard let first = Calendar.current.nextDate(
            after: start, matching: DateComponents(minute: 0), matchingPolicy: .nextTime
        ) else { return [] }
        return Array(stride(from: first, to: end, by: TimeInterval(stepHours) * 3600))
    }

    /// "10pm" rather than "10 PM": the axis is tight, and a 24-hour locale
    /// gets "22" either way.
    static func compactHourLabel(_ date: Date) -> String {
        LocalizedDateFormat.string(from: date, template: "j").lowercased()
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}

// MARK: - Time range sheet (add sleep / carve awake)

/// The sheet behind both range edits: pick a start and end, then confirm.
/// `purpose` supplies the wording; `canConfirm` says whether the picked range
/// would change the timeline, so a range that adds or carves nothing cannot
/// be confirmed (the sheet would otherwise close with nothing done).
struct SleepRangeSheet: View {
    enum Purpose {
        case addSleep, carveAwake
    }

    let purpose: Purpose
    let range: PendingRange
    let canConfirm: (PendingRange) -> Bool
    let onConfirm: (PendingRange) -> Void
    let onCancel: () -> Void

    @State private var start: Date
    @State private var end: Date

    init(
        purpose: Purpose,
        range: PendingRange,
        canConfirm: @escaping (PendingRange) -> Bool,
        onConfirm: @escaping (PendingRange) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.purpose = purpose
        self.range = range
        self.canConfirm = canConfirm
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _start = State(initialValue: range.start)
        _end = State(initialValue: range.end)
    }

    var body: some View {
        NavigationStack {
            Form {
                rangeSection
                noteSection
            }
            .toolbar { sheetToolbar }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var title: String {
        switch purpose {
        case .addSleep: String(localized: "Add Sleep", bundle: LanguageManager.appBundle)
        case .carveAwake: String(localized: "Carve Awake", bundle: LanguageManager.appBundle)
        }
    }

    private var sectionTitle: String {
        switch purpose {
        case .addSleep: String(localized: "Add Sleep Segment", bundle: LanguageManager.appBundle)
        case .carveAwake: String(localized: "Awake Window", bundle: LanguageManager.appBundle)
        }
    }

    private var note: String {
        switch purpose {
        case .addSleep:
            String(localized: "User-declared sleep counts toward your total but is stored without stage detail (no deep/REM).", bundle: LanguageManager.appBundle)
        case .carveAwake:
            String(localized: "Any sleep overlapping this range is replaced with awake time.", bundle: LanguageManager.appBundle)
        }
    }

    private var confirmLabel: String {
        switch purpose {
        case .addSleep: String(localized: "Add", bundle: LanguageManager.appBundle)
        case .carveAwake: String(localized: "Carve", bundle: LanguageManager.appBundle)
        }
    }

    private var rangeSection: some View {
        Section(sectionTitle) {
            DatePicker(String(localized: "Start", bundle: LanguageManager.appBundle), selection: $start, displayedComponents: [.hourAndMinute, .date])
            DatePicker(String(localized: "End", bundle: LanguageManager.appBundle), selection: $end, in: start ... Date.distantFuture, displayedComponents: [.hourAndMinute, .date])
        }
    }

    private var noteSection: some View {
        Section {
            Text(note)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    @ToolbarContentBuilder
    private var sheetToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), action: onCancel)
        }
        ToolbarItem(placement: .confirmationAction) {
            confirmButton
        }
    }

    private var confirmButton: some View {
        let picked = PendingRange(start: start, end: end)
        return Button(confirmLabel) {
            onConfirm(picked)
        }
        .disabled(end <= start || !canConfirm(picked))
        .fontWeight(.semibold)
    }
}

// MARK: - Split (preview before commit)

struct PendingSplit: Identifiable {
    let id = UUID()
    let segmentId: UUID
    let segmentStart: Date
    let segmentEnd: Date
    var atTime: Date
}

/// Preview-state sheet for the Split action.
///
/// Shows the segment's bounds and a draggable cut-point. The user sees
/// where the split will land and can adjust it before committing, rather
/// than the split landing at the midpoint unseen.
struct SplitSegmentSheet: View {
    let split: PendingSplit
    let onConfirm: (PendingSplit) -> Void
    let onCancel: () -> Void

    @State private var atTime: Date

    init(split: PendingSplit, onConfirm: @escaping (PendingSplit) -> Void, onCancel: @escaping () -> Void) {
        self.split = split
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _atTime = State(initialValue: split.atTime)
    }

    private var firstHalfMinutes: Int {
        max(0, Int(atTime.timeIntervalSince(split.segmentStart) / 60))
    }

    private var secondHalfMinutes: Int {
        max(0, Int(split.segmentEnd.timeIntervalSince(atTime) / 60))
    }

    var body: some View {
        NavigationStack {
            Form {
                cutAtSection
                firstHalfSection
            }
            .toolbar { splitToolbar }
            .navigationTitle(String(localized: "Split Segment", bundle: LanguageManager.appBundle))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ToolbarContentBuilder
    private var splitToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), action: onCancel)
        }
        ToolbarItem(placement: .confirmationAction) {
            splitButton
        }
    }

    private var splitButton: some View {
        Button(String(localized: "Split", bundle: LanguageManager.appBundle)) {
            var confirmed = split
            confirmed.atTime = atTime
            onConfirm(confirmed)
        }
        .disabled(!SleepTimelineState.canSplit(segmentStart: split.segmentStart, segmentEnd: split.segmentEnd, at: atTime))
        .fontWeight(.semibold)
    }

    /// Valid cut points: at least a minute from each end. Segments shorter than
    /// two minutes collapse to the midpoint so the range never inverts.
    private var cutRange: ClosedRange<Date> {
        let lower = split.segmentStart.addingTimeInterval(60)
        let upper = split.segmentEnd.addingTimeInterval(-60)
        guard lower <= upper else {
            let mid = split.segmentStart.addingTimeInterval(split.segmentEnd.timeIntervalSince(split.segmentStart) / 2)
            return mid...mid
        }
        return lower...upper
    }

    private var cutAtSection: some View {
        Section {
            DatePicker(
                String(localized: "Cut at", bundle: LanguageManager.appBundle),
                selection: $atTime,
                in: cutRange,
                displayedComponents: [.hourAndMinute, .date]
            )
        } header: {
            Text(String(localized: "Split point", bundle: LanguageManager.appBundle))
        }
    }

    private func halfRow(_ label: String, minutes: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(verbatim: AppTheme.formatMinutes(minutes))
                .monospacedDigit()
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var firstHalfSection: some View {
        Section {
            halfRow(String(localized: "First half", bundle: LanguageManager.appBundle), minutes: firstHalfMinutes)
            halfRow(String(localized: "Second half", bundle: LanguageManager.appBundle), minutes: secondHalfMinutes)
        } header: {
            Text(String(localized: "Preview", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "Splitting creates two segments at the cut point. Stage data is preserved on each side; nothing is deleted.", bundle: LanguageManager.appBundle))
                .font(.caption)
        }
    }
}
