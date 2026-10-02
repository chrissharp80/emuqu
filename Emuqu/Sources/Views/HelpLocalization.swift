import Foundation
import os

/// Translates the Help Center at display time from its own string table,
/// `Help.xcstrings`, keyed by the English text.
///
/// The articles are written as plain English in `HelpContent*.swift`, about
/// six hundred strings, many of them long multi-line paragraphs. Wrapping each
/// in `String(localized:)` would have pushed hundreds of lines past the line
/// limit, and the main catalogue's gates read single-line literals only. A
/// separate table, looked up by the exact English, keeps the content files as
/// they are. `HelpLocalizationTests` holds the table to the content: every
/// string the Help Center shows must have a translation in every language,
/// and the table must hold nothing the Help Center no longer shows.
enum HelpLocalization {
    static let table = "Help"

    /// The text in the selected language; the English itself when the table
    /// has no entry.
    static func string(_ english: String) -> String {
        if english.first == formattedMark { return String(english.dropFirst()) }
        recorder.withLock { _ = $0?.insert(english) }
        return LanguageManager.appBundle.localizedString(forKey: english, value: english, table: table)
    }

    /// A template with `{token}` placeholders, translated first and filled in
    /// after, so a number or a name never becomes part of a lookup key.
    ///
    /// The result carries a leading word joiner (U+2060, invisible) so the
    /// display-time pass in `localized` knows it is already translated and
    /// passes it through instead of looking it up again.
    static func format(_ englishTemplate: String, _ values: [String: String]) -> String {
        let filled = values.reduce(string(englishTemplate)) { text, entry in
            text.replacingOccurrences(of: "{\(entry.key)}", with: entry.value)
        }
        return String(formattedMark) + filled
    }

    private static let formattedMark: Character = "\u{2060}"

    /// Off in the app. A test turns it on to list every key the Help Center
    /// looks up.
    private static let recorder = OSAllocatedUnfairLock<Set<String>?>(initialState: nil)

    static func startRecording() {
        recorder.withLock { $0 = [] }
    }

    static func stopRecording() -> Set<String> {
        recorder.withLock { keys in
            defer { keys = nil }
            return keys ?? []
        }
    }
}

extension HelpCategory {
    /// This category with every user-visible string in the selected language.
    var localized: HelpCategory {
        HelpCategory(
            id: id,
            title: HelpLocalization.string(title),
            icon: icon,
            color: color,
            articles: articles.map(\.localized)
        )
    }
}

extension HelpArticle {
    var localized: HelpArticle {
        HelpArticle(
            id: id,
            title: HelpLocalization.string(title),
            icon: icon,
            summary: HelpLocalization.string(summary),
            sections: sections.map(\.localized)
        )
    }
}

extension ArticleSection {
    var localized: ArticleSection {
        let l = HelpLocalization.string
        switch self {
        case let .text(t): return .text(l(t))
        case let .heading(h): return .heading(l(h))
        case let .tip(t): return .tip(l(t))
        case let .warning(w): return .warning(l(w))
        case let .note(n): return .note(l(n))
        case let .bullets(items): return .bullets(items.map(l))
        case let .steps(items): return .steps(items.map(l))
        case let .keyValue(pairs): return .keyValue(pairs.map { (label: l($0.label), value: l($0.value)) })
        case .divider: return .divider
        }
    }
}
