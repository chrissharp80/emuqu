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
        return !words.contains(where: questionWords.contains) && !matches(requestPhrases, text)
    }

    private static let statementSubjects: Set<String> = [
        "i", "i'm", "i've", "i'd", "my", "the", "this", "that", "it", "it's", "we", "we're", "our", "last", "since", "yesterday", "today"
    ]
    private static let questionWords: Set<String> = ["how", "what", "what's", "whats", "when", "which", "who", "why", "where"]
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

    static let toolPatterns: [String] = [
        #"\b(?:e-?mail|mail) (?:me|it|this|that|him|her|them|my|the|to|today|a|an|over)\b"#,
        #"\b(?:an?|by|via|in an?|write an?|draft an?|compose an?|send an?) e-?mail\b"#, #"^e-?mail\b"#,
        #"\bsend (?:me|it|this|that|my|him|her|them|the|a|an|over|today)\b"#, #"\bsend\b.*\bto (?:me|my|him|her|them)\b"#,
        #"\b(?:directions?|navigate|navigation)\b"#, #"\b(?:take|lead|guide|steer|walk|route|get|bring) me (?:home|back|to|there)\b"#,
        #"\broute (?:me|home|back)\b"#, #"\b(?:way|route) (?:home|back)\b"#, #"\bshow me the way\b"#,
        #"\bback to (?:the )?(?:start|my car|the car|where i)\b"#, #"\bhow do i get (?:to|back|home)\b"#, #"\bhead (?:back|home)\b"#,
        #"\b(?:save|keep|store|add|rename|delete|remove|list|show)\b.*\broutes?\b"#, #"\broutes?\b.*\b(?:saved|stored|do i have)\b"#,
        #"\bas a route\b"#, #"\brename\b"#,
        #"\b(?:add|delete|remove|save|new)\b.*\bcontacts?\b"#, #"\blist (?:my )?contacts\b"#, #"\bcontacts?\b.*\bdo i have\b"#,
        #"\bremember (?:that|my|i|this|to)\b"#, #"\bforget (?:what|that|about|my|i)\b"#, #"\b(?:make a note|note that|keep in mind)\b"#,
        #"\b(?:correo|courriel|sähköposti\w*|tölvupóst\w*|indicaciones|wegbeschreibung|itinéraire|indicazioni|routebeschrijving|vägbeskrivning|маршрут\w*)\b"#,
        #"メール|메일|邮件|経路|길 ?안내|导航|路线"#
    ]

    static let webPatterns: [String] = [
        #"\b(?:weather|forecast|rain|raining|rainy|snow|snowing|snowy|storms?|stormy|thunder\w*|lightning|hail|sleet|fog|foggy|humid|humidity|wind|windy|headwind|tailwind|gusts?|gusty|uv|pollen|air quality|heat advisory|heat ?wave|frost|freezing|sunrise|sunset|daylight)\b"#,
        #"\b(?:temperature|temps?|degrees|hot|cold|warm|chilly|muggy)\b.*\b(?:out|outside|today|tonight|tomorrow|now|this (?:morning|afternoon|evening))\b"#,
        #"\b(?:out|outside)\b.*\b(?:temperature|degrees|hot|cold|warm|chilly)\b"#,
        #"\b(?:buy|purchase|price|prices|pricing|cost of|cheapest|on sale|deal on|discount|where can i get|shop for)\b"#,
        #"\b(?:best|good|top|recommend\w*|which|cheap\w*|find me)\b.*\b(?:watch|watches|shoes?|trainers|sneakers|headphones|earbuds|gels?|supplements?|bike|tires|tyres|jacket)\b"#,
        #"\b(?:is|are) (?:the |it )?[a-z' ]{0,30}\b(?:open|closed)\b"#, #"\b(?:open|closed|opens|closes) (?:now|today|tonight|tomorrow|right now|late|on)\b"#,
        #"\b(?:opening|store|shop|gym|pool|business) hours\b"#,
        #"\b(?:news|headlines)\b"#, #"\bwho won\b"#, #"\b(?:race|marathon|match|game) results\b"#,
        #"\b(?:any|upcoming) (?:races|events|parkruns?|marathons)\b"#, #"\b(?:races?|events?) (?:near|around) me\b"#,
        #"\b(?:research|studies|study|science|scientific|evidence|papers?)\b"#,
        #"\b(?:the web|online|on the internet|google)\b"#, #"\blook (?:it )?up\b"#, #"\bsearch\b"#,
        #"\b(?:other (?:runners|people|athletes|riders|cyclists)|people my age|for my age|my age group|average (?:person|runner|man|woman)|compared? (?:to|with) others)\b"#,
        #"\b(?:qué tiempo|que tiempo|clima|llov\w*|lluvia|nieve|nevar\w*|pronóstico|wetter|regnet|regen|schnee|quel temps|météo|meteo|pluie|pleut|pleuvoir|neige)\b"#,
        #"\b(?:che tempo|pioggia|piove|previsão do tempo|chuva|chover|weerbericht|wat voor weer|väder\w*|vejr\w*|været|vær|sää|sään|sataa|sade)\b"#,
        #"\b(?:veður\w*|rigning|regn|погод\w*|дожд\w*|снег\w*)\b"#,
        #"天気|雨|雪|気温|날씨|비가|눈이|기온|天气|下雨|下雪|气温|طقس|مطر|أمطار"#
    ]

    static let depthPatterns: [String] = [
        "\\b\(spanLead)\\s+(?:(?:last|past)\\s+)?\(spanCount)\\s+(?:months|years|quarters)\\b",
        "\\b\(spanLead)\\s+(?:(?:last|past)\\s+)?\(weekCount)\\s+weeks\\b",
        "\\b(?:\(spanLead)|over)\\s+(?:(?:last|past)\\s+)?(?:\\d{2,3}|thirty|forty|sixty|ninety)\\s+days\\b",
        "\\b(?:last|past|previous|this) (?:month|year|quarter|season)\\b", "\\b(?:last|this) \(season)\\b",
        "\\b(?:month|year)[- ]over[- ](?:month|year)\\b", "\\byear to date\\b", "\\bytd\\b", "\\b(?:a|one|two|\\d+) (?:years?|months?) ago\\b",
        "\\ball[- ]time\\b",
        "\\bsince (?:i (?:started|began)|the (?:start|beginning)|\(month)|\(season)|the \(season)|christmas|new year|last \\w+)\\b",
        "\\bback in \(month)\\b", "\\b\(month)\\b.*\\b(?:than|vs|versus|compared to|or)\\b.*\\b\(month)\\b",
        "\\bmy best (?:week|month|year|season)\\b",
        "\\b(?:two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|\\d+)[- ]month\\b",
        "\\b\(weekCount)[- ]week (?:trend|average|history|period|block)\\b",
        #"\b(?:meses|monaten|monate|mois|mesi|maanden|månader\w*|måneder\w*|kuukau\w*|mánuð\w*|месяц\w*)\b"#,
        #"\b(?:este año|dieses jahr|cette année|quest'anno|este ano|dit jaar|i år|tänä vuonna|в этом году)\b"#,
        #"ヶ月|か月|カ月|개월|个月|個月|今年|올해|أشهر|شهور"#
    ]

    static let speculationPatterns: [String] = [
        #"\b(?:predict\w*|project(?:ed|ion|ions)|estimat\w*|speculat\w*|reckon|odds|chances?|likel(?:y|ihood)|probabl\w*|life expectancy)\b"#,
        #"\bguess\b"#, #"\bwhat if\b"#, #"\bwhat happens (?:to|if|when)\b"#, #"\bsuppose\b"#,
        #"\bif i (?:take|keep|add|rest|skip|run|do|train|drop|cut|stop|start|taper|increase|change|double|miss)\w*\b"#,
        #"\b(?:will|would) (?:i|my)\b"#, #"\bwhat (?:will|would)\b"#, #"\bwould be\b"#, #"\bcould i ever\b"#,
        #"\bhow long (?:until|till|before|will|do i have|would)\b"#, #"\bwhere will\b"#, #"\b(?:ready by|be ready)\b"#,
        #"\bin (?:a|one|two|three|four|five|six|seven|eight|nine|ten|twelve|\d+|a few|a couple of) (?:days|weeks|months|years)\b"#,
        "\\bby (?:christmas|new year|next \\w+|the (?:race|end)|race day|\(month)|\(season))\\b",
        #"\b(?:pronostic\w*|vorhersag\w*|prognos\w*|schätz\w*|prédi\w*|prévoi\w*|prevedi|previsione|stima|voorspel\w*|förutsäg\w*|gissa|forudsig\w*|gæt\w*|forutsi\w*|gjett\w*|ennust\w*|spá\w*|предска\w*|прогноз\w*)\b"#,
        #"予測|予想|예측|예상|预测|预计|توقع"#
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
