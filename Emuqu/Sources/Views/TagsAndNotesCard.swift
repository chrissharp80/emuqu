import SwiftUI

/// The tags row and free-text notes on the morning results screen.
///
/// Split out of `MorningResultsView`. Needs three things — the
/// notes binding, the selected tags, and a toggle callback — which is what makes
/// this worth cutting: the rest of `+DetailCards` reaches for the view model
/// fourteen times and would need a twenty-argument initialiser to move,
/// shrinking the type-size metric while making the design worse.
///
/// Deliberately NOT a `View`. It returns the same view trees the extension
/// returned, so SwiftUI view identity, animation and `@State` behaviour are
/// unchanged; wrapping them in a new `View` would have changed identity.
@MainActor
struct TagsAndNotesCard {
    @Binding var notes: String
    let selectedTags: Set<ReadingTag>
    let onToggleTag: (ReadingTag) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            tagsRow

            Divider()

            notesHeader

            TextField(String(localized: "How did you sleep? Any observations...", bundle: LanguageManager.appBundle), text: $notes, axis: .vertical)
                .padding(12)
                .background(AppTheme.sectionTint)
                .cornerRadius(AppTheme.smallCornerRadius)
                .lineLimit(3 ... 5)
        }
        .zenCard()
    }

    @ViewBuilder
    private var tagsRow: some View {
        sectionLabel(icon: "tag", title: String(localized: "Tags", bundle: LanguageManager.appBundle))

        ScrollView(.horizontal, showsIndicators: false) {
            chipRow
        }
    }

    /// Split from `tagsRow` to keep each builder within two levels of nesting,
    /// the way the original three properties in `+DetailCards` did.
    private var chipRow: some View {
        HStack(spacing: 8) {
            ForEach(ReadingTag.systemTags) { tag in
                chip(for: tag)
            }
        }
    }

    private func chip(for tag: ReadingTag) -> some View {
        TagChip(
            tag: tag,
            isSelected: selectedTags.contains(tag),
            onTap: { onToggleTag(tag) }
        )
    }

    private var notesHeader: some View {
        sectionLabel(icon: "note.text", title: String(localized: "Notes", bundle: LanguageManager.appBundle))
    }

    /// The tags and notes headers were byte-identical apart from icon and
    /// title, so they share one builder here rather than two copies.
    private func sectionLabel(icon: String, title: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(AppTheme.sage)
            Text(title)
                .font(.subheadline.bold())
                .foregroundColor(AppTheme.textPrimary)
        }
    }
}
