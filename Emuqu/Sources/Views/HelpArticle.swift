import SwiftUI

// MARK: - Data Model

struct HelpCategory: Identifiable {
    let id: String
    let title: String
    let icon: String
    let color: Color
    let articles: [HelpArticle]
}

struct HelpArticle: Identifiable {
    let id: String
    let title: String
    let icon: String
    let summary: String
    let sections: [ArticleSection]

    /// Flat text for search matching
    var searchableText: String {
        let sectionText = sections.map(Self.plainText).joined(separator: " ")
        return "\(title) \(summary) \(sectionText)".lowercased()
    }

    /// The user-visible words of one section, flattened for search.
    private static func plainText(of section: ArticleSection) -> String {
        switch section {
        case let .text(t): t
        case let .heading(h): h
        case let .tip(t): t
        case let .warning(w): w
        case let .note(n): n
        case let .bullets(items): items.joined(separator: " ")
        case let .steps(items): items.joined(separator: " ")
        case let .keyValue(pairs): pairs.map { "\($0.label) \($0.value)" }.joined(separator: " ")
        case .divider: ""
        }
    }
}

enum ArticleSection {
    case text(String)
    case heading(String)
    case tip(String)
    case warning(String)
    case note(String)
    case bullets([String])
    case steps([String])
    case keyValue([(label: String, value: String)])
    case divider
}
