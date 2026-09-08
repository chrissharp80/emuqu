import SwiftUI

/// Main help center landing page with search and category grid.
struct HelpCenterView: View {
    @State private var searchText = ""
    @Environment(SettingsManager.self) var settingsManager

    private var categories: [HelpCategory] {
        HelpContent.categories(forAge: settingsManager.settings.age)
    }

    private var searchResults: [HelpArticle] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        return categories.flatMap(\.articles).filter { $0.searchableText.contains(query) }
    }

    private var isSearching: Bool {
        !searchText.isEmpty
    }

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    private var stack: some View {
        VStack(spacing: 20) {
            if isSearching {
                searchResultsView
            } else {
                heroCard
                categoryGrid
            }
        }
    }

    var body: some View {
        ScrollView {
            stack
                .padding(.horizontal, AppTheme.padding)
                .padding(.bottom, 40)
        }
        .searchable(text: $searchText, prompt: "Search help articles")
        .zenBackground()
        .navigationTitle(String(localized: "Help & Learn", bundle: LanguageManager.appBundle))
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            heroHeader

            Divider()
                .background(.white.opacity(0.2))

            Text(String(localized: "\(totalArticleCount) articles across \(categories.count) topics — from first reading to advanced HRV science.", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))

            startWithBasicsLink
        }
        .heroCard()
    }

    private var startWithBasicsLink: some View {
        NavigationLink {
            HelpArticleView(article: HelpContent.gettingStarted.articles[0])
        } label: {
            startWithBasicsLabel
        }
    }

    private var startWithBasicsLabel: some View {
        HStack(spacing: 6) {
            Text(String(localized: "New here? Start with the basics", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.medium))
            Image(systemName: "arrow.right")
                .font(.caption.weight(.bold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.white.opacity(0.15))
        .cornerRadius(AppTheme.smallCornerRadius)
    }

    private var heroHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.text.square")
                .font(.title)
                .foregroundColor(.white.opacity(0.9))

            heroTitleText
            Spacer()
        }
    }

    private var heroTitleText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "Emuqu", bundle: LanguageManager.appBundle))
                .font(.headline)
                .foregroundColor(.white)
            Text(String(localized: "Help & Documentation", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.75))
        }
    }

    // MARK: - Category Grid

    private var categoryGrid: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            categoryCards
        }
    }

    private var categoryCards: some View {
        ForEach(categories) { category in
            categoryLink(category)
        }
    }

    private func categoryLink(_ category: HelpCategory) -> some View {
        NavigationLink {
            HelpCategoryView(category: category)
        } label: {
            CategoryCard(category: category)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search Results

    private var searchResultsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if searchResults.isEmpty {
                noResultsPlaceholder
            } else {
                Text("\(searchResults.count) results")
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textTertiary)

                searchResultLinks
            }
        }
    }

    @ViewBuilder
    private var noResultsPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundColor(AppTheme.textTertiary)
            Text("No results for \"\(searchText)\"")
                .font(.headline)
                .foregroundColor(AppTheme.textSecondary)
            Text(String(localized: "Try different keywords", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var searchResultLinks: some View {
        ForEach(searchResults) { article in
            articleLink(article)
        }
    }

    private func articleLink(_ article: HelpArticle) -> some View {
        NavigationLink {
            HelpArticleView(article: article)
        } label: {
            ArticleRow(article: article)
        }
        .buttonStyle(.plain)
    }

    private var totalArticleCount: Int {
        categories.reduce(0) { $0 + $1.articles.count }
    }
}

// MARK: - Category Card

private struct CategoryCard: View {
    let category: HelpCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            categoryHeaderRow

            Text(category.title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Text("\(category.articles.count) articles")
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
        .shadow(color: AppTheme.cardShadow, radius: AppTheme.cardShadowRadius / 2, x: 0, y: 2)
    }

    private var categoryHeaderRow: some View {
        HStack {
            Image(systemName: category.icon)
                .font(.title3)
                .foregroundColor(category.color)
                .frame(width: 36, height: 36)
                .background(category.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Spacer()
            Text("\(category.articles.count)")
                .font(.caption.weight(.medium))
                .foregroundColor(AppTheme.textTertiary)
        }
    }
}

// MARK: - Category Detail View

struct HelpCategoryView: View {
    let category: HelpCategory

    var body: some View {
        categoryArticleList
    }

    private var categoryArticleList: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Category header
                categoryHeaderRow2

                // Article list
                categoryArticleLinks
            }
            .padding(.horizontal, AppTheme.padding)
            .padding(.bottom, 40)
        }
        .zenBackground()
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var categoryArticleLinks: some View {
        ForEach(category.articles) { article in
            categoryArticleLink(article)
        }
    }

    private func categoryArticleLink(_ article: HelpArticle) -> some View {
        NavigationLink {
            HelpArticleView(article: article)
        } label: {
            ArticleRow(article: article)
        }
        .buttonStyle(.plain)
    }

    private var categoryHeaderRow2: some View {
        HStack(spacing: 14) {
            Image(systemName: category.icon)
                .font(.title2)
                .foregroundColor(category.color)
                .frame(width: 48, height: 48)
                .background(category.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14))

            categoryHeaderText
            Spacer()
        }
        .padding(.bottom, 8)
    }

    private var categoryHeaderText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(category.title)
                .font(.title3.weight(.bold))
                .foregroundColor(AppTheme.textPrimary)
            Text("\(category.articles.count) articles")
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        }
    }
}

// MARK: - Article Row

private struct ArticleRow: View {
    let article: HelpArticle

    var body: some View {
        HStack(spacing: 14) {
            articleRowIcon

            articleRowText

            Spacer()

            Image(systemName: "chevron.right")
                .accessibilityHidden(true)
                .font(.caption.weight(.medium))
                .foregroundColor(AppTheme.textTertiary)
        }
        .padding(14)
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
        .shadow(color: AppTheme.cardShadow, radius: AppTheme.cardShadowRadius / 2, x: 0, y: 1)
    }

    private var articleRowIcon: some View {
        Image(systemName: article.icon)
            .font(.body)
            .foregroundStyle(AppTheme.primaryGradient)
            .frame(width: 36, height: 36)
            .background(AppTheme.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var articleRowText: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(article.title)
                .font(.subheadline.weight(.medium))
                .foregroundColor(AppTheme.textPrimary)
                .lineLimit(1)
            Text(article.summary)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        HelpCenterView()
    }
    .environment(AppDependencies.current.app.settingsManager)
}
