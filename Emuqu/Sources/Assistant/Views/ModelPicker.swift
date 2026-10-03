import SwiftUI

/// Compact provider/model picker shown at the top of the chat tab.
///
/// Tapping it opens a sheet listing every visible provider grouped by name,
/// with each provider's models nested underneath. Tapping a model selects it
/// and dismisses the sheet.
struct ModelPicker: View {
    var registry: ProviderRegistry
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented = true
        } label: {
            bodyLabel
        }
        .sheet(isPresented: $isPresented) {
            ModelPickerSheet(registry: registry, isPresented: $isPresented)
        }
    }

    private var bodyLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: registry.activeProvider.id.symbolName)
                .font(.caption)
            Text(registry.activeModel.displayName)
                .font(.callout)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Color(.tertiarySystemFill))
        )
        .foregroundStyle(.primary)
    }
}

private struct ModelPickerSheet: View {
    @Environment(\.dependencies) var dependencies
    var registry: ProviderRegistry
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            providerList
                .navigationTitle(String(localized: "Choose Model", bundle: LanguageManager.appBundle))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { doneToolbarItem }
        }
    }

    private var providerList: some View {
        List {
            ForEach(registry.allProviders, id: \.id) { providerSection($0) }
        }
    }

    private func providerSection(_ provider: AIProvider) -> some View {
        Section {
            providerModels(provider)
        } header: {
            providerHeader(provider)
        }
    }

    @ViewBuilder
    private func providerModels(_ provider: AIProvider) -> some View {
        if provider.isAvailable {
            ForEach(provider.availableModels) { modelRow($0) }
        } else {
            HStack {
                Text(unavailableReason(for: provider))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func modelRow(_ model: ModelOption) -> some View {
        Button {
            registry.setActive(model: model)
            isPresented = false
        } label: {
            modelRowLabel(model)
        }
    }

    private func modelRowLabel(_ model: ModelOption) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                // The catalog blurbs are English source strings; looked up in
                // the app's catalog at render time.
                Text(LocalizedStringKey(model.blurb), bundle: LanguageManager.appBundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            activeModelCheckmark(model)
        }
    }

    @ViewBuilder
    private func activeModelCheckmark(_ model: ModelOption) -> some View {
        if registry.activeModel.id == model.id {
            Image(systemName: "checkmark")
                .foregroundStyle(Color.accentColor)
        }
    }

    private func providerHeader(_ provider: AIProvider) -> some View {
        HStack(spacing: 6) {
            Image(systemName: provider.id.symbolName)
            Text(provider.id.displayName)
            freeBadge(provider)
        }
    }

    @ViewBuilder
    private func freeBadge(_ provider: AIProvider) -> some View {
        if !provider.requiresKey {
            Text(String(localized: "· FREE", bundle: LanguageManager.appBundle))
                .foregroundStyle(.green)
        }
    }

    @ToolbarContentBuilder
    private var doneToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) { isPresented = false }
        }
    }

    private func unavailableReason(for provider: AIProvider) -> String {
        if provider.id == .apple {
            return String(localized: "Requires iOS 26 with Apple Intelligence enabled.", bundle: LanguageManager.appBundle)
        }
        if provider.requiresKey, !dependencies.providers.apiKeyStore.hasKey(for: provider.id) {
            return String(localized: "Add an API key in Settings → Flo.", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Currently unavailable.", bundle: LanguageManager.appBundle)
    }
}
