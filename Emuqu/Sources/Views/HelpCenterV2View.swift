import SwiftUI

/// Build plan §4.6 M4 — Help & Learn (v2). Adds the promoted "How Emuqu
/// scores recovery" featured-article block at the top of the existing
/// help-articles index.
///
/// The existing `HelpCenterView` houses the article catalogue. This view
/// promotes the methodology page above the fold and routes the rest to
/// that index — minimal duplication, maximum spec compliance.
struct HelpCenterV2View: View {
    @State private var showingMethodology = false

    var body: some View {
        ScrollView { stack }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle(Text("Help & Learn", bundle: LanguageManager.appBundle))
            .sheet(isPresented: $showingMethodology) { methodologySheet }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 18) {
            methodologyFeaturedCard
            Text(verbatim: "Articles")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(AppTheme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.horizontal, 18)
            HelpCenterView()
                .frame(minHeight: 600)
        }
        .padding(.vertical, 18)
    }

    private var methodologySheet: some View {
        NavigationStack {
            RecoveryMethodologyView()
                .toolbar { methodologyDoneToolbar }
        }
    }

    @ToolbarContentBuilder
    private var methodologyDoneToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) { showingMethodology = false }
        }
    }

    private var methodologyFeaturedCard: some View {
        Button {
            showingMethodology = true
        } label: {
            methodologyFeaturedCardLabel
        }
        .buttonStyle(.plain)
    }

    private var featuredBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(AppTheme.primary)
            Text(verbatim: "Featured")
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(AppTheme.primary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
        }
    }

    private var featuredChevron: some View {
        HStack {
            Spacer()
            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(AppTheme.primary)
        }
    }

    private var methodologyFeaturedCardLabel: some View {
        VStack(alignment: .leading, spacing: 8) {
            featuredBadge
            Text(verbatim: "How Emuqu scores recovery")
                .scaledFont(size: 22, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: "What's measured (HRV 60% / Sleep 25% / Vitals 15%), what isn't (training load), why ACWR was removed, and the literature behind every choice. The most important read in the app.")
                .scaledFont(size: 13)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            featuredChevron
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(featuredCardBackground)
        .padding(.horizontal, 18)
    }

    private var featuredCardBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(AppTheme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(AppTheme.primary.opacity(0.3), lineWidth: 1)
            )
    }
}
