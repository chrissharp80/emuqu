import SwiftUI

/// Pre-score "How do you feel?" prompt — shown before the recovery score
/// is revealed so the answer isn't anchored to the number.
///
/// Five-point emoji scale, one tap, skippable. The value is stored as a
/// parallel signal (not blended into the composite score) and used for
/// divergence detection: when the user's feeling disagrees with their HRV,
/// the morning narrative flags it.
///
/// Research basis: Saw et al. (2016) found subjective and objective measures
/// capture different constructs and should be tracked in parallel, not blended.
/// Altini (HRV4Training) explicitly recommends against composite scores that
/// mix objective and subjective data.
struct MorningFeelingPrompt: View {
    /// Called with (feeling 1–5, optional tags). Tags empty for feelings ≥ 3.
    let onSelect: (Int, [MorningFeelingTag]) -> Void
    let onSkip: () -> Void
    /// Existing feeling, if the user has already answered and is editing.
    /// When non-nil the prompt starts with that value selected and the Skip
    /// button becomes a Cancel button (preserves the existing value).
    var existing: Int?
    var existingTags: [MorningFeelingTag] = []

    @State private var selected: Int?
    @State private var selectedTags: Set<MorningFeelingTag> = []
    /// Pending commit, cancellable if the user taps another emoji before
    /// the delay elapses. Used only for feelings ≥ 3 (no tagging path).
    @State private var pendingCommit: DispatchWorkItem?

    /// Computed, not `static let`: the labels must follow an in-app language
    /// switch, and a stored static keeps the language it first resolved in.
    private static var feelings: [(value: Int, emoji: String, label: String)] {
        (1...5).map { (value: $0, emoji: MorningFeelingDisplay.emoji(for: $0), label: MorningFeelingDisplay.label(for: $0)) }
    }

    /// True when the selected feeling is 1 or 2 — show tag chips so the
    /// user can specify WHY. Tags are optional; Done commits whatever's set.
    private var showTags: Bool {
        guard let selected else { return false }
        return selected <= 2
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(existing == nil ? String(localized: "How do you feel this morning?", bundle: LanguageManager.appBundle) : String(localized: "Change your feeling", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.textPrimary)

            feelingScale

            feelingTagPicker

            feelingPromptActions
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
        .onAppear {
            if let existing { selected = existing }
            if !existingTags.isEmpty { selectedTags = Set(existingTags) }
        }
    }

    private var feelingScale: some View {
        HStack(spacing: 0) {
            ForEach(Self.feelings, id: \.value) { feelingButton($0) }
        }
    }

    private func feelingButton(_ feeling: (value: Int, emoji: String, label: String)) -> some View {
        Button { tapFeeling(feeling.value) } label: {
            feelingLabel(feeling)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var feelingTagPicker: some View {
        if showTags {
            tagSection
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var feelingPromptActions: some View {
        HStack(spacing: 16) {
            skipFeelingButton
            doneFeelingButton
        }
    }

    private var skipFeelingButton: some View {
        Button {
            pendingCommit?.cancel()
            onSkip()
        } label: {
            Text(existing == nil ? String(localized: "Skip", bundle: LanguageManager.appBundle) : String(localized: "Cancel", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
    }

    /// Only once the tag picker is open — a bare rating commits on its own timer.
    @ViewBuilder
    private var doneFeelingButton: some View {
        if showTags {
            Spacer()
            Button {
                commitExplicit()
            } label: {
                Text(String(localized: "Done", bundle: LanguageManager.appBundle))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
    }

    private func feelingLabel(_ feeling: (value: Int, emoji: String, label: String)) -> some View {
        VStack(spacing: 4) {
            Text(feeling.emoji)
                .scaledFont(size: 28)
            Text(feeling.label)
                .font(.caption2)
                .foregroundColor(
                    selected == feeling.value
                        ? AppTheme.textPrimary
                        : AppTheme.textTertiary
                )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            selected == feeling.value
                ? MorningFeelingDisplay.color(for: feeling.value).opacity(0.15)
                : Color.clear
        )
        .cornerRadius(8)
    }

    // MARK: - Tag section

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            chipRow(
                title: String(localized: "Body", bundle: LanguageManager.appBundle),
                tags: MorningFeelingTag.allCases.filter { $0.cluster == .body }
            )

            chipRow(
                title: String(localized: "Mind", bundle: LanguageManager.appBundle),
                tags: MorningFeelingTag.allCases.filter { $0.cluster == .mind }
            )

            Text(String(localized: "Optional — helps tailor the recommendation", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    private func chipRow(title: String, tags: [MorningFeelingTag]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(1)
            chipFlow(tags)
        }
    }

    private func chipFlow(_ tags: [MorningFeelingTag]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tagChip($0) }
        }
    }

    private func tagChip(_ tag: MorningFeelingTag) -> some View {
        let isOn = selectedTags.contains(tag)
        return Button { toggle(tag, isOn: isOn) } label: { tagChipLabel(tag, isOn: isOn) }
            .buttonStyle(.plain)
    }

    private func toggle(_ tag: MorningFeelingTag, isOn: Bool) {
        withAnimation(.easeOut(duration: 0.12)) {
            if isOn { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
        }
    }

    private func tagChipLabel(_ tag: MorningFeelingTag, isOn: Bool) -> some View {
        HStack(spacing: 4) {
            Text(tag.emoji)
                .font(.footnote)
            Text(tag.localizedLabel)
                .font(.caption2.weight(.medium))
                .foregroundColor(isOn ? AppTheme.textPrimary : AppTheme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .modifier(TagChipChrome(isOn: isOn))
    }

    /// Selected chips pick up a tinted ground and a matching hairline border.
    private struct TagChipChrome: ViewModifier {
        let isOn: Bool

        func body(content: Content) -> some View {
            content
                .background(isOn ? AppTheme.primary.opacity(0.15) : AppTheme.sectionTint)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(isOn ? AppTheme.primary.opacity(0.5) : Color.clear, lineWidth: 1)
                )
                .cornerRadius(14)
        }
    }

    // MARK: - Commit flow

    /// User tapped an emoji. For feelings 3–5, auto-commit after 1s
    /// (cancellable if they re-tap a different one). For 1–2, reveal the
    /// tag section and wait for explicit Done.
    private func tapFeeling(_ value: Int) {
        withAnimation(.easeOut(duration: 0.15)) {
            selected = value
            if value >= 3 {
                // Picking a good feeling clears any previous tags.
                selectedTags = []
            }
        }
        pendingCommit?.cancel()

        if value >= 3 {
            // Fast path: auto-commit after 1s, cancellable on re-tap.
            let work = DispatchWorkItem {
                onSelect(value, [])
            }
            pendingCommit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }
        // For 1–2, no auto-commit — user must tap Done.
    }

    private func commitExplicit() {
        pendingCommit?.cancel()
        guard let value = selected else { return }
        let tags = value <= 2 ? Array(selectedTags) : []
        onSelect(value, tags)
    }
}

// MARK: - FlowLayout (wrapping chip row)

/// Simple flow layout — wraps chips to new rows when they don't fit.
/// SwiftUI has no built-in wrapping HStack, so this is the minimal one.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        return layout(subviews: subviews, maxWidth: maxWidth).size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let result = layout(subviews: subviews, maxWidth: bounds.width)
        for (idx, frame) in result.frames.enumerated() {
            subviews[idx].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func layout(subviews: Subviews, maxWidth: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxRight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxRight = max(maxRight, x - spacing)
        }
        return (CGSize(width: maxRight, height: y + rowHeight), frames)
    }
}

// MARK: - Feeling Emoji Lookup

/// Single source of truth for feeling → emoji / label mapping.
/// Used by badge, history rows, trends heatmap, and anywhere else feelings
/// are rendered so they stay consistent.
enum MorningFeelingDisplay {
    static func emoji(for feeling: Int) -> String {
        switch feeling {
        case 1: "\u{1F629}"
        case 2: "\u{1F615}"
        case 3: "\u{1F610}"
        case 4: "\u{1F60A}"
        case 5: "\u{1F525}"
        default: "\u{1F610}"
        }
    }

    static func label(for feeling: Int) -> String {
        switch feeling {
        case 1: String(localized: "Terrible", bundle: LanguageManager.appBundle)
        case 2: String(localized: "Poor", bundle: LanguageManager.appBundle)
        case 3: String(localized: "OK", bundle: LanguageManager.appBundle)
        case 4: String(localized: "Good", bundle: LanguageManager.appBundle)
        case 5: String(localized: "Great", bundle: LanguageManager.appBundle)
        default: String(localized: "OK", bundle: LanguageManager.appBundle)
        }
    }

    @MainActor static func color(for feeling: Int) -> Color {
        switch feeling {
        case 1: AppTheme.dustyRose
        case 2: AppTheme.terracotta
        case 3: AppTheme.softGold
        case 4: AppTheme.sage
        case 5: AppTheme.sage
        default: AppTheme.textSecondary
        }
    }
}

// MARK: - Feeling Badge (for dashboard / history)

/// Compact emoji badge showing the user's morning feeling.
/// Tappable — calls `onTap` to let the caller re-open the edit prompt.
struct MorningFeelingBadge: View {
    let feeling: Int
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            onTap?()
        } label: {
            badgeLabel
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }

    private var badgeLabel: some View {
        HStack(spacing: 4) {
            Text(MorningFeelingDisplay.emoji(for: feeling))
                .font(.caption)
            Text(String(localized: "Felt \(MorningFeelingDisplay.label(for: feeling).lowercased())", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
            editPencil
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var editPencil: some View {
        if onTap != nil {
            Image(systemName: "pencil")
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
    }
}
