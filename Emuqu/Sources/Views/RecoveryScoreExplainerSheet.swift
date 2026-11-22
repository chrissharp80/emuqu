import SwiftUI

/// The Help Center's "understanding-score" article from the Recovery Score
/// category, in its own navigation stack with a Done button that calls
/// `onDone`. Empty if the article is missing from `HelpContent`.
struct RecoveryScoreExplainerSheet: View {
    let onDone: () -> Void

    @ViewBuilder
    var body: some View {
        if let article = HelpContent.recoveryScore.articles.first(where: { $0.id == "understanding-score" })?.localized {
            NavigationStack { articleView(article) }
        }
    }

    private func articleView(_ article: HelpArticle) -> some View {
        HelpArticleView(article: article)
            .toolbar { doneToolbar }
    }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) {
                onDone()
            }
        }
    }
}
