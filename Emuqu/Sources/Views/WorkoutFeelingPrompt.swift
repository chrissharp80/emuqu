import SwiftUI

/// Post-workout subjective "how did that feel?" prompt — the workout
/// parallel to `MorningFeelingPrompt`. Captures the athlete's own
/// perception *separately* from the objective metrics (TRIMP, HRR,
/// α1) so the subjective signal is kept alongside, never blended.
///
/// Why parallel and not blended: Saw et al. 2016 (cited in the morning
/// prompt) — subjective and objective measures capture different
/// constructs and should be tracked in parallel, not combined into a
/// composite score. Same rationale here: "the numbers said the walk
/// was easy but I felt terrible" is a useful signal (approaching
/// illness? cumulative fatigue?), not noise to average out.
///
/// Behavior:
///   • 5-point emoji scale (matches the morning prompt visually so
///     the feeling scale stays consistent across contexts).
///   • Feelings 3-5 auto-commit after 1 s (cancellable by re-tapping).
///   • Feelings 1-2 reveal an optional free-text note field and an
///     explicit Done button — we want detail when things felt off.
///   • Editable: tap the commit'd badge to re-open.
struct WorkoutFeelingPrompt: View {
    /// Called with (feeling 1-5, optional note). Note is `nil` when
    /// the user didn't enter free text.
    let onSelect: (Int, String?) -> Void
    let onSkip: () -> Void
    /// Existing feeling to pre-select when the user is editing an
    /// already-submitted rating.
    var existing: Int?
    var existingNote: String?

    @State private var selected: Int?
    @State private var noteText: String = ""
    @State private var pendingCommit: DispatchWorkItem?
    @FocusState private var noteFocused: Bool

    /// Labels come from `WorkoutFeelingDisplay.localizedLabel(for:)`.
    private static let feelings: [(value: Int, emoji: String)] = [
        (1, "\u{1F629}"),
        (2, "\u{1F615}"),
        (3, "\u{1F610}"),
        (4, "\u{1F60A}"),
        (5, "\u{1F525}")
    ]

    /// True when selected is 1 or 2 — show the note field so the user
    /// can optionally capture *why* the session felt off.
    private var showNote: Bool {
        guard let selected else { return false }
        return selected <= 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            feelingPromptHeader

            feelingScale

            feelingNoteField

            feelingActions
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
        .onAppear {
            if let existing { selected = existing }
            if let existingNote { noteText = existingNote }
        }
    }

    private var feelingPromptHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "face.smiling")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.terracotta)
            Text(existing == nil ? String(localized: "HOW DID THAT FEEL?", bundle: LanguageManager.appBundle) : String(localized: "CHANGE YOUR FEELING", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private var feelingScale: some View {
        HStack(spacing: 0) {
            ForEach(Self.feelings, id: \.value) { feelingButton($0) }
        }
    }

    private func feelingButton(_ feeling: (value: Int, emoji: String)) -> some View {
        Button { tapFeeling(feeling.value) } label: {
            feelingLabel(feeling)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var feelingNoteField: some View {
        if showNote {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text(String(localized: "OPTIONAL NOTE", bundle: LanguageManager.appBundle))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.textTertiary)
                    .tracking(1)
                noteTextField
                Text(String(localized: "Helps spot patterns when subjective feeling diverges from your HR data.", bundle: LanguageManager.appBundle))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var noteTextField: some View {
        TextField(
            String(localized: "e.g. heavy legs, too hot, started too fast", bundle: LanguageManager.appBundle),
            text: $noteText,
            axis: .vertical
        )
        .font(.caption)
        .lineLimit(2 ... 4)
        .padding(10)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
        .focused($noteFocused)
    }

    private var feelingActions: some View {
        HStack {
            skipFeelingButton
            Spacer()
            saveFeelingButton
        }
    }

    private var skipFeelingButton: some View {
        Button {
            pendingCommit?.cancel()
            onSkip()
        } label: {
            Text(existing == nil ? String(localized: "Skip", bundle: LanguageManager.appBundle) : String(localized: "Cancel", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    /// Only when a note is open — a bare rating commits on its own timer.
    @ViewBuilder
    private var saveFeelingButton: some View {
        if showNote {
            Button {
                commitExplicit()
            } label: {
                Text(String(localized: "Save", bundle: LanguageManager.appBundle))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.terracottaText)
            }
        }
    }

    private func feelingLabel(_ feeling: (value: Int, emoji: String)) -> some View {
        VStack(spacing: 4) {
            Text(feeling.emoji)
                .scaledFont(size: 28)
            Text(WorkoutFeelingDisplay.localizedLabel(for: feeling.value))
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

    /// User tapped an emoji. Feelings 3-5 auto-commit after 1 s
    /// (cancellable on re-tap); 1-2 reveal the note field and wait for
    /// explicit Save so the user can choose whether to annotate.
    private func tapFeeling(_ value: Int) {
        withAnimation(.easeOut(duration: 0.15)) {
            selected = value
            if value >= 3 {
                noteText = ""
            }
        }
        pendingCommit?.cancel()
        if value >= 3 {
            let work = DispatchWorkItem {
                onSelect(value, nil)
            }
            pendingCommit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }
    }

    private func commitExplicit() {
        pendingCommit?.cancel()
        guard let value = selected else { return }
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        onSelect(value, trimmed.isEmpty ? nil : trimmed)
    }
}

/// Compact badge for a committed workout feeling — shown in the summary
/// once the user has picked, tappable to edit. Mirrors
/// `MorningFeelingBadge` visually.
struct WorkoutFeelingBadge: View {
    let feeling: Int
    let note: String?
    var onTap: (() -> Void)?

    var body: some View {
        Button { onTap?() } label: { recordedFeelingRow }
            .buttonStyle(.plain)
            .disabled(onTap == nil)
    }

    private var recordedFeelingRow: some View {
        HStack(spacing: 10) {
            Text(WorkoutFeelingDisplay.emoji(for: feeling))
                .font(.title3)
            recordedFeelingText
            Spacer()
            editHint
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkoutFeelingDisplay.color(for: feeling).opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(WorkoutFeelingDisplay.color(for: feeling).opacity(0.25), lineWidth: 1)
        )
        .cornerRadius(16)
    }

    private var recordedFeelingText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(WorkoutFeelingDisplay.feltPhrase(for: feeling))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            noteOrHint
        }
    }

    @ViewBuilder
    private var noteOrHint: some View {
        if let note, !note.isEmpty {
            Text(note)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(2)
        } else {
            Text(String(localized: "Tap to change", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    @ViewBuilder
    private var editHint: some View {
        if onTap != nil {
            Image(systemName: "pencil")
                .font(.caption)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }
}

/// Single source of truth for workout-feeling → emoji / label mapping.
/// Emoji and colour forward to `MorningFeelingDisplay` so the two contexts
/// stay visually identical; only the labels differ.
enum WorkoutFeelingDisplay {
    static func emoji(for feeling: Int) -> String {
        MorningFeelingDisplay.emoji(for: feeling)
    }

    /// Localized single-word feeling label for the emoji-scale row.
    /// Literal keys (not a dynamic `LocalizationValue`) so Xcode's
    /// catalog extractor can pick them up and translators see them.
    static func localizedLabel(for feeling: Int) -> String {
        let bundle = LanguageManager.appBundle
        switch feeling {
        case 1: return String(localized: "Terrible", bundle: bundle)
        case 2: return String(localized: "Hard", bundle: bundle)
        case 3: return String(localized: "OK", bundle: bundle)
        case 4: return String(localized: "Good", bundle: bundle)
        case 5: return String(localized: "Great", bundle: bundle)
        default: return String(localized: "OK", bundle: bundle)
        }
    }

    /// Fully-localized "Felt …" badge phrase. Built as a complete
    /// per-feeling key (not English-word interpolation into a template)
    /// so each locale can render a natural sentence — e.g. the target
    /// grammar may not lower-case an interpolated adjective.
    static func feltPhrase(for feeling: Int) -> String {
        let bundle = LanguageManager.appBundle
        switch feeling {
        case 1: return String(localized: "Felt terrible", bundle: bundle)
        case 2: return String(localized: "Felt hard", bundle: bundle)
        case 3: return String(localized: "Felt OK", bundle: bundle)
        case 4: return String(localized: "Felt good", bundle: bundle)
        case 5: return String(localized: "Felt great", bundle: bundle)
        default: return String(localized: "Felt OK", bundle: bundle)
        }
    }

    @MainActor static func color(for feeling: Int) -> Color {
        MorningFeelingDisplay.color(for: feeling)
    }
}
