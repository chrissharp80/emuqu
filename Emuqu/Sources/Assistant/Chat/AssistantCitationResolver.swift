import Foundation
import os

/// Detects date references in assistant responses ("April 12, 2026", "Apr 12",
/// "yesterday") and rewrites them as Markdown links to a custom in-app URL
/// scheme (`flowrecovery://session/<uuid>`). The chat view intercepts that
/// scheme and opens a quick-view sheet for the matching session.
///
/// Run after the assistant text is final but before Markdown parsing so the
/// link runs flow naturally into the rendered AttributedString.
enum AssistantCitationResolver {
    static let urlScheme = "flowrecovery"
    static let sessionHost = "session"

    // Hoisted out of `annotate` so it is not allocated on every call.
    // `annotate` runs from ChatBubble's `renderedText` computed var, i.e. per
    // render — 50-200× during a streaming response. A fresh DateFormatter +
    // NSDataDetector each time is pure per-frame allocation churn.
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar.current
        f.timeZone = Calendar.current.timeZone
        return f
    }()

    private static let dateDetector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// Returns the input text with date references that match a session in
    /// the archive replaced by Markdown links. Text that doesn't match any
    /// session is returned unchanged. Text already inside markdown link syntax
    /// is skipped, so re-running on annotated text is a no-op.
    static func annotate(_ text: String, archive: SessionArchive = AppDependencies.current.storage.sessionArchive) -> String {
        guard !text.isEmpty else { return text }
        let dayToSessionId = sessionsByDay(archive)
        guard !dayToSessionId.isEmpty, let detector = Self.dateDetector else { return text }
        let nsText = text as NSString
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        // Walk matches in reverse so substring offsets stay valid as we rewrite.
        var output = text
        for match in matches.reversed() {
            guard let date = match.date,
                  let sessionId = dayToSessionId[Self.dayKeyFormatter.string(from: date)],
                  let swiftRange = Range(match.range, in: output),
                  !isTimeOnly(output[swiftRange]),
                  !isAlreadyInsideLink(output, range: swiftRange)
            else { continue }
            let original = String(output[swiftRange])
            let link = "[\(original)](\(urlScheme)://\(sessionHost)/\(sessionId.uuidString))"
            output.replaceSubrange(swiftRange, with: link)
        }
        return output
    }

    /// The day map plus what it was built from, so `annotate` — which runs
    /// per render while a reply streams — rebuilds it only when the archive
    /// gains, loses or re-dates an entry.
    private struct DayIndex: Sendable {
        let archive: ObjectIdentifier
        let signature: Int
        let map: [String: UUID]
    }

    private static let dayIndex = OSAllocatedUnfairLock<DayIndex?>(initialState: nil)

    /// A (yyyy-MM-dd) → most-recent-session-id map from the archive index,
    /// cached until any entry's id or display date changes.
    private static func sessionsByDay(_ archive: SessionArchive) -> [String: UUID] {
        let entries = archive.entries
        let signature = entrySignature(entries)
        let id = ObjectIdentifier(archive)
        if let cached = dayIndex.withLock({ $0 }), cached.archive == id, cached.signature == signature {
            return cached.map
        }
        let map = dayMap(entries)
        dayIndex.withLock { $0 = DayIndex(archive: id, signature: signature, map: map) }
        return map
    }

    /// Hash of every entry's (id, display date), in index order. Count and
    /// newest date alone missed a re-dated older entry, which left citation
    /// links opening the wrong night. Kept in memory only, so the per-process
    /// `Hasher` seed does not matter.
    private static func entrySignature(_ entries: [SessionArchiveEntry]) -> Int {
        var hasher = Hasher()
        hasher.combine(entries.count)
        for entry in entries {
            hasher.combine(entry.sessionId)
            hasher.combine(entry.displayDate)
        }
        return hasher.finalize()
    }

    /// First write wins, and the descending sort makes that the most recent
    /// session for the day.
    private static func dayMap(_ entries: [SessionArchiveEntry]) -> [String: UUID] {
        var out: [String: UUID] = [:]
        for entry in entries.sorted(by: { $0.displayDate > $1.displayDate }) {
            let key = Self.dayKeyFormatter.string(from: entry.displayDate)
            if out[key] == nil { out[key] = entry.sessionId }
        }
        return out
    }

    /// Times with no day ("7 am", "at 18:30", "noon"): the detector dates
    /// them today, which would link a time of day to today's session.
    private static let timeOnlyPattern: NSRegularExpression? = attempt("AssistantCitationResolver.timeOnly") {
        try NSRegularExpression(
            pattern: #"\b\d{1,2}(:\d{2})?\s*[ap]\.?m\.?|\b\d{1,2}:\d{2}\b|\bnoon\b|\bmidnight\b|\bat\b"#,
            options: [.caseInsensitive]
        )
    }

    /// True when the match is nothing but a time of day.
    private static func isTimeOnly(_ matched: Substring) -> Bool {
        guard let pattern = timeOnlyPattern else { return false }
        let text = String(matched)
        let stripped = pattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
        )
        return !stripped.contains { $0.isLetter || $0.isNumber }
    }

    /// Parses a `flowrecovery://session/<uuid>` URL and returns the session id.
    static func parseSessionURL(_ url: URL) -> UUID? {
        guard url.scheme == urlScheme, url.host == sessionHost else { return nil }
        let last = url.lastPathComponent
        return UUID(uuidString: last)
    }

    // MARK: - Private

    /// Crude check: is `range`'s start preceded by `[` and followed eventually
    /// by `](`? If yes, treat as already-linked and skip.
    private static func isAlreadyInsideLink(_ text: String, range: Range<String.Index>) -> Bool {
        // Cheap heuristic: scan back up to 80 chars for a `[` without `]` in between.
        let maxLookback = 80
        let start = text.index(range.lowerBound, offsetBy: -maxLookback, limitedBy: text.startIndex) ?? text.startIndex
        let prefix = text[start ..< range.lowerBound]
        if let openBracket = prefix.lastIndex(of: "[") {
            let between = prefix[openBracket ..< range.lowerBound]
            if !between.contains("]") {
                return true
            }
        }
        return false
    }
}
