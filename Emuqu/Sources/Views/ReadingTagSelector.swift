import SwiftUI

/// The horizontal strip of reading-type chips above a recording, plus the
/// "More" button that opens the full tag picker.
///
/// Its own type because it needs exactly two things from the record screen —
/// which tags are selected and what to do when one is tapped — and `RecordView`
/// is over the aggregate type-size threshold.
struct ReadingTagSelector: View {
    let selectedTags: Set<ReadingTag>
    let onToggle: (ReadingTag) -> Void
    /// Opens the full picker; the sheet itself stays with the record screen
    /// that presents it.
    let onMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Reading Type", bundle: LanguageManager.appBundle))
                .font(.headline)

            tagChipStrip
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private var tagChipStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            tagChipRow
        }
    }

    private var tagChipRow: some View {
        HStack(spacing: 8) {
            ForEach(ReadingTag.systemTags) { tag in
                chip(for: tag)
            }
            moreTagsButton
        }
    }

    private func chip(for tag: ReadingTag) -> some View {
        TagChip(
            tag: tag,
            isSelected: selectedTags.contains(tag),
            onTap: { onToggle(tag) }
        )
    }

    private var moreTagsButton: some View {
        Button {
            onMore()
        } label: {
            moreTagsLabel
                // The chip stays compact; the tap area is the 44-point minimum.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
    }

    private var moreTagsLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "plus")
            Text(String(localized: "More", bundle: LanguageManager.appBundle))
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.gray.opacity(0.2))
        .foregroundColor(.primary)
        .cornerRadius(16)
    }
}
