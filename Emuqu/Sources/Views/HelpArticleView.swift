import SwiftUI

/// Renders a single help article with rich, typed content sections.
struct HelpArticleView: View {
    let article: HelpArticle

    var body: some View {
        ScrollView { stack }
            .zenBackground()
            .navigationTitle(article.title)
            .navigationBarTitleDisplayMode(.inline)
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 20) {
            heroHeader
            // Content sections
            ForEach(Array(article.sections.enumerated()), id: \.offset) { _, section in
                sectionView(for: section)
            }
        }
        .padding(AppTheme.padding)
        .padding(.bottom, 40)
    }

    private var heroHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: article.icon)
                .font(.title2)
                .foregroundStyle(AppTheme.primaryGradient)
                .frame(width: 44, height: 44)
                .background(AppTheme.primary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            heroTitles
        }
        .padding(.bottom, 4)
    }

    private var heroTitles: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(article.title)
                .font(.title3.weight(.bold))
                .foregroundColor(AppTheme.textPrimary)
            Text(article.summary)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    // MARK: - Section Renderer

    @ViewBuilder
    private func sectionView(for section: ArticleSection) -> some View {
        switch section {
        case let .text(text): bodyText(text)
        case let .heading(heading): headingText(heading)
        case let .tip(text): calloutCard(icon: "lightbulb.fill", iconColor: AppTheme.softGold, text: text, tint: AppTheme.softGold)
        case let .warning(text): calloutCard(icon: "exclamationmark.triangle.fill", iconColor: AppTheme.terracotta, text: text, tint: AppTheme.terracotta)
        case let .note(text): calloutCard(icon: "info.circle.fill", iconColor: AppTheme.mist, text: text, tint: AppTheme.primary)
        case let .bullets(items): bulletsView(items)
        case let .steps(items): stepsView(items)
        case let .keyValue(pairs): keyValueView(pairs)
        case .divider: Divider().padding(.vertical, 4)
        }
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundColor(AppTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func headingText(_ heading: String) -> some View {
        Text(heading)
            .font(.headline.weight(.semibold))
            .foregroundColor(AppTheme.textPrimary)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func bulletsView(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in bulletItem(item) }
        }
    }

    private func bulletItem(_ item: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(AppTheme.primary.opacity(0.5))
                .frame(width: 6, height: 6)
                .padding(.top, 7)
            Text(item)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepsView(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                stepRow(index: index, item: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.padding)
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }

    private func stepRow(index: Int, item: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index + 1)")
                .font(.caption.weight(.bold))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(AppTheme.primaryGradient)
                .clipShape(Circle())

            Text(item)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func keyValueView(_ pairs: [(label: String, value: String)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                keyValueRow(pair)
                keyValueDivider(index: index, count: pairs.count)
            }
        }
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
        .shadow(color: AppTheme.cardShadow, radius: AppTheme.cardShadowRadius / 2, x: 0, y: 1)
    }

    @ViewBuilder
    private func keyValueDivider(index: Int, count: Int) -> some View {
        if index < count - 1 {
            Divider().padding(.horizontal, AppTheme.padding)
        }
    }

    private func keyValueRow(_ pair: (label: String, value: String)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pair.label)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.textPrimary)
            Text(pair.value)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, AppTheme.padding)
    }

    // MARK: - Callout Card

    private func calloutCard(icon: String, iconColor: Color, text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(iconColor)
                .font(.subheadline)
                .frame(width: 20)
                .padding(.top, 1)

            Text(text)
                .font(.subheadline)
                .foregroundColor(AppTheme.textPrimary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(tint.opacity(0.15), lineWidth: 1)
        )
    }
}

#Preview {
    NavigationStack {
        HelpArticleView(article: HelpContent.gettingStarted.articles[0].localized)
    }
}
