import Foundation

/// The phrase patterns `CapabilityClassifier` reads a message's needs from.
///
/// Each axis is a list of regular expressions over the normalized message
/// (lowercased, typographic apostrophes folded, leading fillers and hedges
/// removed). English carries most of the patterns; the languages the app
/// ships have patterns for the requests that most often need the cloud
/// (weather, spans of months, predictions) and for email and directions.
///
/// A statement ("the weather was perfect for my run yesterday", "this month
/// I ran a lot") asks for nothing, so it raises no flag even when it holds a
/// marker word. The patterns were written against the eval's tuning split
/// (`EvalUtterances.tuning`), never against its held-out split.
enum CapabilityMarkers {
    /// The flags the markers raise in `message`.
    static func requirement(of message: String) -> CapabilityClassifier.Requirement {
        let text = normalized(message)
        guard !text.isEmpty, !isStatement(text) else { return .none }
        return CapabilityClassifier.Requirement(
            needsTools: matches(tools, text),
            needsWeb: matches(web, text),
            needsHistoricalDepth: matches(depth, text),
            needsSpeculation: matches(speculation, text)
        )
    }

    // MARK: - Normalization

    /// Lowercased, apostrophes folded, then the fillers and idioms that
    /// would read as markers rewritten: "look up my" and "search for my" are
    /// lookups in the user's own data, "forecast my" is a prediction, "walk
    /// me through" is an explanation, and "I guess" is a hedge.
    static func normalized(_ message: String) -> String {
        var text = message.lowercased()
            .replacingOccurrences(of: "[\u{2018}\u{2019}\u{02BC}]", with: "'", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for (pattern, replacement) in rewrites {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let rewrites: [(String, String)] = [
        (#"^(?:(?:um+|uh+|er+|okay|ok|so|well|hey|hi|flo|quick question)[,.!]?\s+)+"#, ""),
        (#"\b(?:i guess|i suppose|i bet|what if i told you)\b"#, ""),
        (#"\blook up my\b"#, "read my"),
        (#"\blook up (?:the )?contact"#, "find the contact"),
        (#"\bsearch (?:for )?my\b"#, "find my"),
        (#"\bforecast (?:of |for )?my\b"#, "predict my"),
        (#"\bwalk me through\b"#, "explain"),
        (#"\s+"#, " ")
    ]

    /// A remark rather than a request: it opens with its subject ("I", "my",
    /// "the", "this month", "since I"), runs to four words or more, and has
    /// no question mark, no question word and no request phrase.
    static func isStatement(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        guard words.count >= 4, let first = words.first, statementSubjects.contains(first), !text.contains("?") else { return false }
        return !words.contains(where: questionWords.contains) && !matches(requestPhrases, text) && !matches(questionClauses, text)
    }

    private static let statementSubjects: Set<String> = [
        "i", "i'm", "i've", "i'd", "my", "the", "this", "that", "it", "it's", "we", "we're", "our", "last", "since", "yesterday", "today",
        "i'll", "been", "thanks", "thank", "saving", "just"
    ]
    private static let questionWords: Set<String> = ["how", "what", "what's", "whats", "when", "which", "who", "why", "where"]
    /// A question after a comma turns a remark into a request ("my pace has
    /// been slow lately, is it slower than last season").
    private static let questionClauses = compile([
        #"[,;] (?:(?:um|uh|like|so|and|but|or|okay),? )*(?:is|are|was|were|do|does|did|can|could|will|would|should|am|have|has)\b"#
    ])
    private static let requestPhrases = compile([
        #"\b(?:can|could|would|will) you\b"#, #"\bplease\b"#, #"\b(?:tell|show|give|send|remind|help|let) me\b"#,
        #"\bi (?:want|need|wanna|would like)\b"#, #"\bi'd like\b"#
    ])

    // MARK: - Patterns

    private static let spanCount = "(?:two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|couple of|couple|few|several|\\d+)"
    private static let weekCount = "(?:three|four|five|six|seven|eight|nine|ten|eleven|twelve|few|several|[3-9]|\\d{2})"
    private static let month = "(?:january|february|march|april|may|june|july|august|september|october|november|december)"
    private static let season = "(?:spring|summer|autumn|fall|winter)"
    private static let spanLead = "(?:last|past|previous|recent|over the|across the|for the|in the|from the|from)"

    static let toolPatterns: [String] = englishTools + otherLanguageTools
    static let webPatterns: [String] = englishWeb + otherLanguageWeb
    static let depthPatterns: [String] = englishDepth + otherLanguageDepth
    static let speculationPatterns: [String] = englishSpeculation + otherLanguageSpeculation

    /// Products a runner shops for.
    private static let product = "(?:shoes?|trainers|sneakers|spikes|watch(?:es)?|monitors?|straps?|boots|headphones|earbuds|gels?|supplements?|bikes?|tires|tyres|jackets?|gear|insoles|socks|foam roller|massage gun)"
    /// Events a runner enters.
    private static let event = "(?:races?|marathons?|half marathons?|10ks?|5ks?|triathlons?|parkruns?|events?|gran fondos?)"
    /// Superlatives a record question asks for.
    private static let superlative = "(?:best|worst|longest|fastest|slowest|highest|lowest|biggest|most|least|top|personal best|pr|pb|record)"

    private static let englishTools: [String] = [
        #"\b(?:e-?mail|mail),? (?:me|it|this|that|him|her|them|my|the|to|today|a|an|over)\b"#,
        #"\b(?:an?|by|via|in an?|write an?|draft an?|compose an?|send an?) e-?mail\b"#, #"^e-?mail\b"#,
        #"\bsend (?:me|it|this|that|my|him|her|them|the|a|an|over|today)\b"#, #"\bsend\b.*\bto (?:me|my|him|her|them)\b"#,
        #"^text\b"#, #"\btext (?:mum|mom|dad|my|him|her|them)\b"#,
        #"\b(?:directions?|navigate|navigation)\b"#, #"\b(?:take|lead|guide|steer|walk|route|get|bring) me (?:home|back|to|there)\b"#,
        #"\broute (?:me|home|back)\b"#, #"\b(?:way|route) (?:home|back)\b"#, #"\bshow me the way\b"#,
        #"\bback to (?:the )?(?:start|my car|the car|where i)\b"#, #"\bhow do i get (?:to|back|home)\b"#, #"\bhead (?:back|home)\b"#,
        #"\b(?:save|keep|store|add|rename|delete|remove|list|show)\b.*\broutes?\b"#, #"\broutes?\b.*\b(?:saved|stored|do i have|save)\b"#,
        #"\bas a route\b"#, #"\brename\b"#, #"\bfollow (?:the|my|that)\b"#,
        #"\b(?:add|delete|remove|save|new|find|look up)\b.*\bcontacts?\b"#, #"\blist (?:my )?contacts\b"#, #"\bcontacts?\b.*\bdo i have\b"#,
        #"\bremember (?:that|my|i|this|to|it)\b"#, #"\bforget (?:the|what|that|about|my|i|it)\b"#,
        #"\b(?:make a note|save a note|note that|keep in mind|save that)\b"#, #"\b(?:to|in) my notes\b"#,
        #"\b(?:delete|remove|clear)\b.*\b(?:memory|memories|notes?)\b"#
    ]

    private static let englishWeb: [String] = [
        #"\b(?:weather|forecast|rain|raining|rainy|snow|snowing|snowy|storms?|stormy|thunder\w*|lightning|hail|sleet|fog|foggy|humid|humidity|wind|windy|headwind|tailwind|gusts?|gusty|uv|pollen|air quality|heat advisory|heat ?wave|frost|freezing|sunrise|sunset|daylight)\b"#,
        #"\b(?:temperature|temps?|degrees|hot|cold|warm|chilly|muggy)\b.*\b(?:out|outside|today|tonight|tomorrow|now|this (?:morning|afternoon|evening))\b"#,
        #"\b(?:out|outside)\b.*\b(?:temperature|degrees|hot|cold|warm|chilly)\b"#,
        #"\b(?:buy|purchase|price|prices|pricing|cost of|cheapest|on sale|deal on|discount|where can i get|shop for)\b"#,
        "\\b(?:best|good|decent|top|recommend\\w*|which|what|cheap\\w*|find me|should i get)\\b.*(?<!my )\\b\(product)\\b",
        "\\b\(product)\\b.*\\b(?:should i get|to get|worth it|are best|is best|best right now)\\b",
        #"\b(?:is|are) (?:the |it )?[a-z' ]{0,30}\b(?:open|closed)\b"#, #"\b(?:open|closed|opens|closes|close|closing) (?:now|today|tonight|tomorrow|right now|late|on|at)\b"#,
        #"\b(?:opening|store|shop|gym|pool|business) hours\b"#, #"\bopening hours\b"#,
        #"\b(?:news|headlines)\b"#, #"\bwho won\b"#, #"\b(?:race|marathon|match|game) results\b"#,
        "(?<!my )\\b(?:any|upcoming|next|nearest|local) (?:big |good )?\(event)\\b", "\\b\(event)\\b.*\\b(?:near|around) (?:me|here)\\b",
        #"\bnear (?:me|here)\b"#, #"\bnearby\b"#, #"\b(?:nearest|closest) (?:\w+ )?(?:shop|store|gym|pool|cafe|café|pharmacy|bike shop)\b"#,
        #"\b(?:registration|sign[- ]?ups?|entry deadline|deadline|qualifying (?:standards?|times?)|course (?:record|map|profile)|elevation profile|start list)\b"#,
        #"\b(?:research|studies|study|science|scientific|evidence|papers?)\b"#,
        #"\b(?:the web|online|internet|google|according to)\b"#, #"\blook (?:it )?up\b"#, #"\bsearch\b"#, #"\bis it true\b"#,
        #"\b(?:other (?:runners|people|athletes|riders|cyclists)|(?:people|someone|men|women) my age|for my age|my age group|average (?:person|runner|man|woman)|compared? (?:to|with) others)\b"#,
        #"\bfor (?:endurance )?(?:athletes|runners|cyclists|triathletes)\b"#, #"\bbest time of (?:year|day) to\b"#
    ]

    private static let englishDepth: [String] = [
        "\\b\(spanLead)\\s+(?:(?:last|past)\\s+)?\(spanCount)\\s+(?:months|years|quarters|seasons)\\b",
        "\\b\(spanLead)\\s+(?:(?:last|past)\\s+)?\(weekCount)\\s+weeks\\b",
        "\\b(?:\(spanLead)|over)\\s+(?:(?:last|past)\\s+)?(?:\\d{2,3}|thirty|forty|sixty|ninety)\\s+days\\b",
        "\\b(?:last|past|previous|this) (?:month|year|quarter|season)\\b", "\\b(?:last|this) \(season)\\b",
        "\\b(?:month|year)[- ]over[- ](?:month|year)\\b", "\\byear to date\\b", "\\byear so far\\b", "\\bytd\\b",
        "\\b(?:a|one|two|\\d+) (?:years?|months?) ago\\b", "\\b(?:two|three|four|five|\\d+) years of\\b",
        "\\b(?:all[- ]time|lifetime|of all time|ever recorded)\\b", "\\b\(superlative)\\b.*\\bever\\b", "\\bi've ever\\b",
        "\\b(?:the whole|all|this) (?:year|season)\\b", "\\bover (?:the )?(?:months|years|seasons)\\b",
        "\\bthis month (?:with|to|vs|versus|compared)\\b", "\\bcompare (?:\\w+ ){0,4}(?:with|to) last\\b",
        "\\bsince (?:i (?:started|began)|the (?:start|beginning)|\(month)|\(season)|the \(season)|christmas|new year|last \\w+)\\b",
        "\\bback in \(month)\\b", "\\b\(month)\\b.*\\b(?:than|vs|versus|compared to|or)\\b.*\\b\(month)\\b",
        "\\bmy best (?:week|month|year|season)\\b", "\\b(?:last|when did i last) (?:hit|set|got) a (?:pr|pb|personal best)\\b",
        "\\b(?:two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|\\d+)[- ]month\\b",
        "\\b\(weekCount)[- ]week (?:trend|average|history|period|block)\\b"
    ]

    private static let englishSpeculation: [String] = [
        #"\b(?:predict\w*|project(?:ed|ion|ions)|estimat\w*|speculat\w*|reckon|odds|chances?|likel(?:y|ihood)|probabl\w*|life expectancy)\b"#,
        #"\bguess\b"#, #"\bwhat if\b"#, #"\bthen what\b"#, #"\bwhat(?:'s| is)? (?:going to|gonna) happen\b"#, #"\bwhat happens (?:to|if|when)\b"#, #"\bsuppose\b"#,
        #"\bif i (?:take|keep|add|rest|skip|run|do|train|drop|cut|stop|start|taper|increase|change|double|miss|drink|sleep|eat|go)\w*\b"#,
        #"\b(?:will|would) (?:i|my|they|it|that|this)\b"#, #"\bwhat (?:will|would)\b"#, #"\bwould be\b"#, #"\bcould i ever\b"#,
        #"\b(?:could|might) i (?:pr|pb|break|beat|run|finish|hit|make|qualify|go)\b"#, #"\bcan i (?:pr|pb|break|beat|qualify|go sub)\b"#,
        #"\bwill (?:\w+'s |my |the |this |that |tomorrow's |today's )?\w+ (?:feel|be|go|improve|recover|look|end up)\b"#,
        #"\b(?:is|are) (?:it|that|this|my \w+) (?:going to|gonna) (?:be|feel|go|affect|hurt|help|happen)\b"#,
        #"\bhow (?:bad|good|much|fast|long) (?:will|would)\b"#,
        #"\bhow long (?:until|till|before|will|do i have|would)\b"#, #"\bwhere will\b"#, #"\b(?:ready by|be ready|be recovered)\b"#,
        #"\b(?:should i aim|aim for|realistic|achievable|on track (?:for|to))\b"#,
        #"\bin (?:a|one|two|three|four|five|six|seven|eight|nine|ten|twelve|\d+|a few|a couple of) (?:days|weeks|months|years)\b"#,
        "\\bby (?:christmas|new year|next \\w+|the (?:race|end)|race day|\(month)|\(season))\\b"
    ]

    static let tools = compile(toolPatterns)
    static let web = compile(webPatterns)
    static let depth = compile(depthPatterns)
    static let speculation = compile(speculationPatterns)

    // MARK: - Matching

    private static func matches(_ patterns: [NSRegularExpression], _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    /// Every pattern compiled; a pattern that does not is a bug the marker
    /// tests catch by count (`CapabilityClassifierTests`).
    private static func compile(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.compactMap { pattern in
            do {
                return try NSRegularExpression(pattern: pattern)
            } catch {
                assertionFailure("capability marker does not compile: \(pattern): \(error)")
                return nil
            }
        }
    }
}
