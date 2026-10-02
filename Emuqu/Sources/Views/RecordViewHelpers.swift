import SwiftUI

// MARK: - Supporting Views

/// The tag's colour marks the chip but never carries the text: coloured text
/// on its own tint, or white on a light hue, fails contrast for most tags.
struct TagChip: View {
    let tag: ReadingTag
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(tag.name)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(AppTheme.textPrimary)
                .background(Capsule().fill(tag.color.opacity(isSelected ? 0.35 : 0.12)))
                .overlay(Capsule().strokeBorder(isSelected ? tag.color : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

}

struct TagPickerSheet: View {
    @Binding var selectedTags: Set<ReadingTag>
    let availableTags: [ReadingTag]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                systemTagsSection
                customTagsSection
            }
            .navigationTitle(String(localized: "Select Tags", bundle: LanguageManager.appBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { doneToolbar }
        }
    }

    @ViewBuilder
    private var customTagsSection: some View {
        let customTags = availableTags.filter { !$0.isSystem }
        if !customTags.isEmpty {
            Section(String(localized: "Custom Tags", bundle: LanguageManager.appBundle)) {
                customTagRows(customTags)
            }
        }
    }

    private func customTagRows(_ tags: [ReadingTag]) -> some View {
        ForEach(tags) { tag in
            tagRow(tag)
        }
    }

    private func tagRow(_ tag: ReadingTag) -> some View {
        TagRow(tag: tag, isSelected: selectedTags.contains(tag)) {
            toggleTag(tag)
        }
    }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) { dismiss() }
        }
    }

    private var systemTagsSection: some View {
        Section(String(localized: "System Tags", bundle: LanguageManager.appBundle)) {
            ForEach(ReadingTag.systemTags) { tag in
                tagRow(tag)
            }
        }
    }

    private func toggleTag(_ tag: ReadingTag) {
        selectedTags.toggle(tag)
    }
}

extension Set {
    /// Removes `member` when present, inserts it otherwise — what a tap on a
    /// tag chip does to the selection.
    mutating func toggle(_ member: Element) {
        if contains(member) {
            remove(member)
        } else {
            insert(member)
        }
    }
}

private struct TagRow: View {
    let tag: ReadingTag
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack {
            Circle()
                .fill(tag.color)
                .frame(width: 12, height: 12)

            Text(tag.name)
                .foregroundColor(.primary)

            Spacer()

            checkmark
        }
    }

    @ViewBuilder
    private var checkmark: some View {
        if isSelected {
            Image(systemName: "checkmark")
                .foregroundColor(.blue)
        }
    }
}

struct MetricPreviewCard: View {
    let title: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.title2, design: .rounded).bold())
                    .foregroundColor(color)
                Text(unit)
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
            Text(title)
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.tertiarySystemGroupedBackground))
        .cornerRadius(12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(title): \(value) \(unit)", bundle: LanguageManager.appBundle))
    }
}
