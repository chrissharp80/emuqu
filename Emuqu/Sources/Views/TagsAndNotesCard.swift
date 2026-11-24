import SwiftUI

/// The tags row and free-text notes on the morning results screen.
///
/// Needs three things: the notes binding, the selected tags, and a toggle
/// callback.
///
/// Deliberately NOT a `View`: it returns view trees into the host view's
/// body, so SwiftUI view identity, animation and `@State` stay the host's;
/// wrapping them in a new `View` would change identity.
@MainActor
struct TagsAndNotesCard {
    @Binding var notes: String
    let selectedTags: Set<ReadingTag>
    /// The user's own tags, listed after the system tags.
    let customTags: [ReadingTag]
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

    /// Split from `tagsRow` to keep each builder within two levels of nesting.
    private var chipRow: some View {
        HStack(spacing: 8) {
            ForEach(stripTags) { tag in
                chip(for: tag)
            }
        }
    }

    /// The system tags, then the user's custom tags, then any tag on the
    /// session that is neither (a custom tag since deleted), so every tag can
    /// be applied here and every selection shows as selected and can be removed.
    private var stripTags: [ReadingTag] {
        let listed = ReadingTag.systemTags + customTags
        let listedIds = Set(listed.map(\.id))
        let extra = selectedTags.filter { !listedIds.contains($0.id) }.sorted { $0.name < $1.name }
        return listed + extra
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

    /// The tags and notes headers are identical apart from icon and
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
