import SwiftUI

/// Help & Learn (v2). Adds the promoted "How Emuqu
/// scores recovery" featured-article block at the top of the existing
/// help-articles index.
///
/// The existing `HelpCenterView` houses the article catalogue, search and
/// navigation title. This view hands it the methodology card as its header,
/// so both share one scroll view.
struct HelpCenterV2View: View {
    @State private var showingMethodology = false

    var body: some View {
        HelpCenterView { header }
            .sheet(isPresented: $showingMethodology) { methodologySheet }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            methodologyFeaturedCard
            Text("Articles", bundle: LanguageManager.appBundle)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(AppTheme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
        }
        .padding(.top, 18)
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
            Text("Featured", bundle: LanguageManager.appBundle)
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
            Image(systemName: "arrow.forward.circle.fill")
                .foregroundStyle(AppTheme.primary)
        }
    }

    private var methodologyFeaturedCardLabel: some View {
        VStack(alignment: .leading, spacing: 8) {
            featuredBadge
            Text("How Emuqu scores recovery", bundle: LanguageManager.appBundle)
                .scaledFont(size: 22, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
            Text("What's measured — HRV, sleep and vitals, weighted 60, 25 and 15 percent — what isn't (training load), why ACWR was removed, and the literature behind every choice. The most important read in the app.", bundle: LanguageManager.appBundle)
                .scaledFont(size: 13)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            featuredChevron
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(featuredCardBackground)
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
