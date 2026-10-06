import SwiftUI

/// One selectable model in the Flo tab's Choose model sheet: the model's name,
/// the catalog's one-line blurb and a checkmark on the model Flo uses now.
/// Tapping it selects the model and its provider (`ProviderRegistry.setActive(model:)`),
/// and the selection is persisted and sent with every turn routed to that
/// provider.
struct ModelOptionRow: View {
    var registry: ProviderRegistry
    let model: ModelOption

    private var isSelected: Bool {
        registry.activeModel.id == model.id
    }

    var body: some View {
        Button {
            registry.setActive(model: model)
        } label: {
            rowLabel
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rowLabel: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.displayName)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(AppTheme.textPrimary)
                // The catalog blurbs are English source strings; looked up in
                // the app's catalog at render time.
                Text(LocalizedStringKey(model.blurb), bundle: LanguageManager.appBundle)
                    .scaledFont(size: 12)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            selectedMark
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var selectedMark: some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.wongOptimal)
                .accessibilityHidden(true)
        }
    }
}
