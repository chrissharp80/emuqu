import Foundation

// MARK: - WebSearchService
//
// Thin client for Tavily's search API (https://tavily.com), exposed to
// the AI as the `web.search` action in the fact catalog.
//
// Why Tavily over Brave / Perplexity / Exa / Serper for THIS app:
//   • Native `include_domains` / `exclude_domains` parameters — critical
//     for a health app. We constrain searches to authoritative sources
//     (PubMed, manufacturer docs, established training-science blogs)
//     and exclude known-bad ones (supplement spam, content farms).
//   • Snippets are pre-formatted Markdown excerpts the LLM can consume
//     directly — no HTML scrubbing in Swift.
//   • REST/JSON, single endpoint. No SDK to maintain.
//   • Free tier: 1000 searches/month covers a typical user; ~$0.008/search
//     after.
//
// Off by default. The user must explicitly enable web search in
// Settings → AI Assistant AND supply a Tavily API key. The system-prompt
// overlay enforces "no medical-protocol synthesis from search results;
// always cite source URLs in the response."
//
// **Concurrency note**: this type is intentionally NOT @MainActor. The
// fact-resolver dispatch path that calls `web.search` runs on MainActor
// (the assistant view-model loop is @MainActor), and it has to bridge
// from sync to async via a semaphore wait. If `WebSearchService` were
// @MainActor, the URLSession await would suspend back to MainActor,
// which is blocked on the semaphore — classic deadlock. Keeping this
// nonisolated lets the search execute on a cooperative thread off the
// main actor and signal the semaphore from there. The class has no UI
// state so the @MainActor annotation buys nothing in exchange for that
// bug.
final class WebSearchService: Sendable {
    static let shared = WebSearchService()

    private init() {}

    /// Curated authority-domain whitelist for "research" intent searches.
    /// Anchored to peer-reviewed sources and established training-science
    /// authorities. Skips Reddit, Pinterest, Medium-flavoured wellness
    /// blogs, and supplement marketing pages by exclusion.
    static let researchAuthorityDomains: [String] = [
        // Peer-reviewed / academic
        "pubmed.ncbi.nlm.nih.gov",
        "ncbi.nlm.nih.gov",
        "scholar.google.com",
        "frontiersin.org",
        "journals.physiology.org",
        "europepmc.org",
        "nature.com",
        "sciencedirect.com",
        // Established training-science publishers
        "intervals.icu",
        "fellrnr.com",
        "trainingpeaks.com",
        "joefrielsblog.com",
        "alancouzens.com",
        "stephenseilerphd.com",
        "marcoaltini.com",
        // Sleep / HRV research labs + companies
        "kubios.com",
        "elitehrv.com",
        "hrv4training.com",
        "ouraring.com",
        // Standards bodies + clinicians
        "acsm.org",        // American College of Sports Medicine
        "uptodate.com",
        "mayoclinic.org",
        "clevelandclinic.org"
    ]

    /// Manufacturer-docs whitelist for hardware/firmware questions ("what's
    /// the H10 battery spec?", "is there a Stryd firmware update?").
    static let manufacturerAuthorityDomains: [String] = [
        "polar.com",
        "support.polar.com",
        "garmin.com",
        "support.garmin.com",
        "stryd.com",
        "concept2.com",
        "wahoofitness.com",
        "support.wahoofitness.com",
        "tacx.com",
        "saris.com",
        "apple.com",
        "support.apple.com",
        "developer.apple.com",
        "zwift.com",
        "support.zwift.com"
    ]

    /// Always-excluded domains. Supplement spam, low-effort content farms,
    /// platforms where health misinformation propagates without filter.
    /// Apply to ALL searches regardless of intent.
    static let excludeDomains: [String] = [
        "pinterest.com",
        "quora.com",
        "answers.yahoo.com",
        "wikihow.com",
        "ehow.com"
    ]

    enum Intent: String, Codable, Sendable {
        /// Research questions ("what does the literature say about α1 and
        /// LT1?"). Constrained to `researchAuthorityDomains`.
        case research
        /// Hardware/firmware/manufacturer questions. Constrained to
        /// `manufacturerAuthorityDomains`.
        case manufacturer
        /// Open web — no whitelist, only the global exclude list. Use
        /// when neither research nor manufacturer fits (rare).
        case general
    }

    struct Result: Codable, Equatable, Sendable {
        let title: String
        let url: String
        let content: String
        let score: Double
        let publishedDate: String?
    }

    enum SearchError: Error, LocalizedError, Sendable {
        case notEnabled
        case missingKey
        case network(String)
        case decode(String)
        case rateLimited

        var errorDescription: String? {
            switch self {
            case .notEnabled: return "Web search is disabled in Settings"
            case .missingKey: return "No Tavily API key set"
            case .network(let s): return "Network error: \(s)"
            case .decode(let s): return "Decode error: \(s)"
            case .rateLimited: return "Tavily rate limit hit"
            }
        }
    }

    func search(
        query: String,
        intent: Intent = .research,
        maxResults: Int = 5
    ) async throws -> [Result] {
        guard AppDependencies.current.app.settingsManager.settingsSnapshot.enableWebSearch else {
            throw SearchError.notEnabled
        }
        guard let apiKey = AppDependencies.current.providers.apiKeyStore.serviceKey(for: .tavilyWebSearch), !apiKey.isEmpty else {
            throw SearchError.missingKey
        }
        let request = try Self.tavilyRequest(
            query: query, intent: intent, maxResults: maxResults, apiKey: apiKey
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkStatus(response)
        return try Self.parse(data: data)
    }

    private static func tavilyRequest(
        query: String, intent: Intent, maxResults: Int, apiKey: String
    ) throws -> URLRequest {
        var body: [String: Any] = [
            "query": query,
            "search_depth": "basic",
            "max_results": min(max(maxResults, 1), 10),
            "exclude_domains": Self.excludeDomains,
            "include_answer": false,
            "include_raw_content": false
        ]
        let includeDomains = authorityDomains(for: intent)
        if !includeDomains.isEmpty { body["include_domains"] = includeDomains }
        guard let url = URL(string: "https://api.tavily.com/search") else {
            throw SearchError.network("malformed endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Research and manufacturer intents restrict the search to their own
    /// authority lists; a general query searches the open web.
    private static func authorityDomains(for intent: Intent) -> [String] {
        switch intent {
        case .research: researchAuthorityDomains
        case .manufacturer: manufacturerAuthorityDomains
        case .general: []
        }
    }

    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SearchError.network("non-HTTP response")
        }
        if http.statusCode == 429 {
            throw SearchError.rateLimited
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            debugLog("[WebSearchService] search HTTP failure: \(http.statusCode)", level: .warning)
            throw SearchError.network("HTTP \(http.statusCode)")
        }
    }

    /// The Tavily response shape. Field names mirror the wire format.
    private struct TavilyResponse: Decodable {
        struct Item: Decodable {
            let title: String?
            let url: String?
            let content: String?
            let score: Double?
            let published_date: String?
        }

        let results: [Item]
    }

    private static func parse(data: Data) throws -> [Result] {
        let decoded: TavilyResponse
        do {
            decoded = try JSONDecoder().decode(TavilyResponse.self, from: data)
        } catch {
            throw SearchError.decode(String(describing: error))
        }
        return decoded.results.compactMap { item in
            guard let title = item.title, let url = item.url, let content = item.content else {
                return nil
            }
            return Result(
                title: title,
                url: url,
                content: content,
                score: item.score ?? 0,
                publishedDate: item.published_date
            )
        }
    }
}
