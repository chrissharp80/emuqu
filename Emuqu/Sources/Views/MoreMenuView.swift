import SwiftUI

/// More menu. Houses Trends, History, Settings,
/// Help, About in the v2.0 5-tab structure.
///
/// Layout:
///   - Trends ▸
///   - History ▸  (Recent strip on Dashboard handles daily case;
///                 History remains here for full-archive search)
///   - Settings ▸
///   - Help & Learn ▸
///   - About Emuqu ▸
struct MoreMenuView: View {
    @Environment(\.dependencies) var dependencies
    let scrollToTopToken: UUID

    private var settingsManager: SettingsManager { dependencies.app.settingsManager }
    /// Exactly four entries.
    /// Trends ▸ / Settings ▸ / Help & Learn ▸ / About Emuqu ▸
    ///
    /// Load & Trajectory is reachable via the Dashboard's Load
    /// chip (D1 → D6) and the Fitness tab's "View Load &
    /// Trajectory ▸" link (F1 → D6). It is intentionally NOT in
    /// the More menu — D6 is a Surface-2 destination, not a
    /// junk-drawer item.
    ///
    /// History is reachable via the Dashboard's Recent strip
    /// "View all" footer link (D1 → D7):
    /// "History collapses into Dashboard via a Recent strip" —
    /// a standalone More-menu entry would compete with the
    /// Recent strip's primary affordance.
    ///
    /// Methodology is reachable via Help & Learn (featured card)
    /// and About Emuqu (Privacy & methodology section). One
    /// canonical entry point per spec.
    var body: some View {
        List {
            purchaseSection
            junkDrawerItemSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle(Text(String(localized: "More", bundle: LanguageManager.appBundle)))
    }

    /// Stable identifiers on the four More rows. A UI test that reaches
    /// Settings or Trends with `buttons["Settings"]` never matches: each
    /// row's accessibility label is the title AND subtitle joined
    /// ("Settings, Profile, sources, modes, coach"), so the exact-match
    /// query finds nothing and the whole Settings sub-page suite silently
    /// walks off. The identifier is the contract; the label is not.
    private var junkDrawerItemSection: some View {
        Section {
            trendsRow
            settingsRow
            helpRow
            aboutRow
        }
    }

    /// The purchase, one tap from the More tab for anyone who hasn't bought
    /// the app. App Review installs count as beta installs (no API tells
    /// the two apart), so the launch paywall never shows for them; the
    /// in-app purchase they review has to be easy to find without it.
    @ViewBuilder
    private var purchaseSection: some View {
        if StoreKitManager.paywallEnabled, !dependencies.services.storeKitManager.hasPurchasedProduct {
            Section { purchaseRow }
        }
    }

    private var purchaseRow: some View {
        NavigationLink {
            PaywallView(isGate: false)
        } label: {
            rowLabel(
                systemImage: "star.fill",
                title: String(localized: "Purchase", bundle: LanguageManager.appBundle),
                subtitle: String(localized: "One-time purchase. Restorable with your Apple ID.", bundle: LanguageManager.appBundle)
            )
        }
        .accessibilityIdentifier("more.purchase")
    }

    private var trendsRow: some View {
        NavigationLink {
            TrendsV2View()
        } label: {
            rowLabel(systemImage: "chart.line.uptrend.xyaxis", title: String(localized: "Trends", bundle: LanguageManager.appBundle), subtitle: String(localized: "Long-term patterns + How You Felt heatmap", bundle: LanguageManager.appBundle))
        }
        .accessibilityIdentifier("more.trends")
    }

    private var settingsRow: some View {
        NavigationLink {
            SettingsView(scrollToTopToken: scrollToTopToken)
        } label: {
            rowLabel(systemImage: "gearshape", title: String(localized: "Settings", bundle: LanguageManager.appBundle), subtitle: String(localized: "Profile, sources, modes, coach", bundle: LanguageManager.appBundle))
        }
        .accessibilityIdentifier("more.settings")
    }

    private var helpRow: some View {
        NavigationLink {
            HelpCenterV2View()
        } label: {
            rowLabel(systemImage: "book", title: String(localized: "Help & Learn", bundle: LanguageManager.appBundle), subtitle: String(localized: "Articles, glossary, methodology", bundle: LanguageManager.appBundle))
        }
        .accessibilityIdentifier("more.help")
    }

    private var aboutRow: some View {
        NavigationLink {
            AboutFlowView()
        } label: {
            rowLabel(systemImage: "info.circle", title: String(localized: "About Emuqu", bundle: LanguageManager.appBundle), subtitle: String(localized: "Privacy, disclaimer, credits", bundle: LanguageManager.appBundle))
        }
        .accessibilityIdentifier("more.about")
    }

    private func rowLabel(systemImage: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .scaledFont(size: 17, weight: .medium)
                .foregroundStyle(AppTheme.primary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(AppTheme.textPrimary)
                Text(verbatim: subtitle)
                    .scaledFont(size: 13)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Lightweight About destination — points to the methodology view + the
/// existing privacy/disclaimer surfaces.
struct AboutFlowView: View {
    var body: some View {
        List {
            aboutSection

            privacyMethodologySection

            Section {
                Text(verbatim: appVersionLine)
                    .scaledFont(size: 13)
                    .foregroundStyle(AppTheme.textTertiary)
            } footer: {
                // Localizable prose, not Text(verbatim:).
                Text(String(localized: "Built one block at a time. Thanks for trusting it with your data.", bundle: LanguageManager.appBundle))
                    .scaledFont(size: 13)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle(Text(String(localized: "About Emuqu", bundle: LanguageManager.appBundle)))
    }

    private var aboutSection: some View {
        Section {
            // Localizable prose, not Text(verbatim:).
            Text(String(localized: "Made by Chris Sharp.", bundle: LanguageManager.appBundle))
                .scaledFont(size: 16, weight: .medium)
                .foregroundStyle(AppTheme.textPrimary)
            Text(String(localized: "Emuqu is an HRV-based recovery and training-load app for athletes. Privacy-first by architecture: your health data stays in your iCloud and on your device unless you send a report or turn on a cloud AI provider.", bundle: LanguageManager.appBundle))
                .scaledFont(size: 14)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(String(localized: "Emuqu", bundle: LanguageManager.appBundle))
        }
    }

    private var privacyMethodologySection: some View {
        Section {
            NavigationLink {
                HealthDisclaimerView()
            } label: {
                Label(String(localized: "Health disclaimer", bundle: LanguageManager.appBundle), systemImage: "heart.text.square")
            }
            NavigationLink {
                RecoveryMethodologyView()
            } label: {
                Label(String(localized: "How Emuqu scores recovery", bundle: LanguageManager.appBundle), systemImage: "function")
            }
        } header: {
            Text(String(localized: "Privacy & methodology", bundle: LanguageManager.appBundle))
        }
    }
}

/// The bundle's own version; a hard-coded "v2.0 (May 2026)" sat in About
/// while Settings showed 1.0.
private var appVersionLine: String {
    "v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
}
