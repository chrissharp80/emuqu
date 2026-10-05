import SwiftUI

/// Help & Learn: the article index with the promoted "How Emuqu scores
/// recovery" card at the top. The same page `HelpCenterView()` builds, so
/// More, Settings and Settings search cannot open different versions of it.
typealias HelpCenterV2View = HelpCenterView<HelpMethodologyHeader>

/// The featured methodology card and the "Articles" label above the index.
/// The card opens the methodology in a sheet.
struct HelpMethodologyHeader: View {
    @State private var showingMethodology = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            methodologyFeaturedCard
            Text("Articles", bundle: LanguageManager.appBundle)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(AppTheme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
        }
        .padding(.top, 18)
        .sheet(isPresented: $showingMethodology) { methodologySheet }
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
