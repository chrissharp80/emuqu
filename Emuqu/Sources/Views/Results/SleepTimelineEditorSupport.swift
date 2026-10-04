import SwiftUI

// Drag state, pending-range and the add-sleep sheet, split out of
// `SleepTimelineEditorView.swift` at a top-level type boundary.
// Supporting types the editor uses; none carry editing logic.

// MARK: - Drag preview struct

struct BoundaryDrag: Equatable {
    let segmentId: UUID
    let side: SleepTimelineEdit.Side
    let newTime: Date
}

struct PendingRange: Identifiable {
    let id = UUID()
    var start: Date
    var end: Date
}

// MARK: - Add sleep sheet

struct AddSleepSheet: View {
    let range: PendingRange
    let onConfirm: (PendingRange) -> Void
    let onCancel: () -> Void

    @State private var start: Date
    @State private var end: Date

    init(range: PendingRange, onConfirm: @escaping (PendingRange) -> Void, onCancel: @escaping () -> Void) {
        self.range = range
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
            .navigationTitle(String(localized: "Add Sleep", bundle: LanguageManager.appBundle))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var rangeSection: some View {
        Section(String(localized: "Add Sleep Segment", bundle: LanguageManager.appBundle)) {
            DatePicker(String(localized: "Start", bundle: LanguageManager.appBundle), selection: $start, displayedComponents: [.hourAndMinute, .date])
            DatePicker(String(localized: "End", bundle: LanguageManager.appBundle), selection: $end, in: start ... Date.distantFuture, displayedComponents: [.hourAndMinute, .date])
        }
    }

    private var noteSection: some View {
        Section {
            Text(String(localized: "User-declared sleep counts toward your total but is stored without stage detail (no deep/REM).", bundle: LanguageManager.appBundle))
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
        Button(String(localized: "Add", bundle: LanguageManager.appBundle)) {
            onConfirm(PendingRange(start: start, end: end))
        }
        .disabled(end <= start)
        .fontWeight(.semibold)
    }
}

// MARK: - Carve awake sheet

struct CarveAwakeSheet: View {
    let range: PendingRange
    let onConfirm: (PendingRange) -> Void
    let onCancel: () -> Void

    @State private var start: Date
    @State private var end: Date

    init(range: PendingRange, onConfirm: @escaping (PendingRange) -> Void, onCancel: @escaping () -> Void) {
        self.range = range
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
            .navigationTitle(String(localized: "Carve Awake", bundle: LanguageManager.appBundle))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var rangeSection: some View {
        Section(String(localized: "Awake Window", bundle: LanguageManager.appBundle)) {
            DatePicker(String(localized: "Start", bundle: LanguageManager.appBundle), selection: $start, displayedComponents: [.hourAndMinute, .date])
            DatePicker(String(localized: "End", bundle: LanguageManager.appBundle), selection: $end, in: start ... Date.distantFuture, displayedComponents: [.hourAndMinute, .date])
        }
    }

    private var noteSection: some View {
        Section {
            Text(String(localized: "Any sleep overlapping this range is replaced with awake time.", bundle: LanguageManager.appBundle))
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
        Button(String(localized: "Carve", bundle: LanguageManager.appBundle)) {
            onConfirm(PendingRange(start: start, end: end))
        }
        .disabled(end <= start)
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
        .disabled(atTime <= split.segmentStart || atTime >= split.segmentEnd)
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
