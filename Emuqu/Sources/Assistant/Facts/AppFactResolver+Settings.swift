import CoreLocation
import CoreMotion
import Foundation
import os

// The app.settings toggles and the web.search action (Tavily).

// MARK: - app.settings.* namespace (toggles)
//
// User-facing setting toggles. Useful when the AI suggests an action
// that depends on a feature being enabled (e.g. "I'd recommend turning
// on HRV-enhanced Watch sleep stages, but only if your strap is
// regularly worn overnight" — the AI can verify the toggle state first).
struct AppSettingsNamespace: FactNamespaceResolver {
    let namespace = "app"
    let settings: @Sendable () -> UserSettings

    var entries: [FactEntry] {
        [
            appSettingsSleepIntegrationOnEntry,
            appSettingsSleepHrvAugmentationOnEntry,
            appSettingsPenalizeMissingSleepOnEntry,
            trainingLoadIntegrationOnEntry,
            appSettingsZwiftBroadcastOnEntry,
            appSettingsHealthkitExportOnEntry
        ]
    }

    private var appSettingsSleepIntegrationOnEntry: FactEntry {
        .fixed(
            key: "app.settings.sleep_integration_on",
            description: "Whether HealthKit sleep data is folded into recovery scoring. When off, the score is HRV-only.",
            valueType: "Bool"
        ) { .boolean(self.settings().enableSleepIntegration) }
    }

    private var appSettingsSleepHrvAugmentationOnEntry: FactEntry {
        .fixed(
            key: "app.settings.sleep_hrv_augmentation_on",
            description: "Whether Apple Watch sleep stages get HRV-based refinement using chest-strap RR data. Off by default.",
            valueType: "Bool"
        ) { .boolean(self.settings().enableHRVSleepAugmentation) }
    }

    private var appSettingsPenalizeMissingSleepOnEntry: FactEntry {
        .fixed(
            key: "app.settings.penalize_missing_sleep_on",
            description: "Whether the recovery score is penalised when sleep integration is on but no sleep was found for the night. Off by default.",
            valueType: "Bool"
        ) { .boolean(self.settings().penalizeMissingSleep) }
    }

    private var trainingLoadIntegrationOnEntry: FactEntry {
        .fixed(
            key: "app.settings.training_load_integration_on",
            description: "Whether training load is tracked: ATL / CTL / TSB from the user's workouts, shown beside the recovery score on the Load & Trajectory page. Training load is never counted in the recovery score itself.",
            valueType: "Bool"
        ) { .boolean(self.settings().enableTrainingLoadIntegration) }
    }

    private var appSettingsZwiftBroadcastOnEntry: FactEntry {
        .fixed(
            key: "app.settings.zwift_broadcast_on",
            description: "Whether the Zwift / TrainerRoad / Rouvy BLE peripheral broadcast is enabled in Settings. The actual advertising state is at app.devices.zwift_broadcast.advertising.",
            valueType: "Bool"
        ) { .boolean(self.settings().enableZwiftBroadcast) }
    }

    private var appSettingsHealthkitExportOnEntry: FactEntry {
        .fixed(
            key: "app.settings.healthkit_export_on",
            description: "Whether Emuqu automatically writes HRV / sleep results back to Apple Health after each session.",
            valueType: "Bool"
        ) { .boolean(self.settings().enableHealthKitExport) }
    }
}

// There is no lock-protected box bridging `Task.detached` results back
// across a `DispatchSemaphore` wait: awaitable resolvers are
// `.fixedAsync` / `.actionAsync` and suspend on
// `FactResolveTimeout.withTimeout(seconds:)` (FactCatalog.swift).

// MARK: - web.* namespace (Tavily search)
//
// The AI's only window onto the open web. Two surfaces:
//   • `web.available` — cheap read; tells the AI whether web.search is
//     callable RIGHT NOW (toggle on + key set). Saves a wasted action
//     call when the user hasn't enabled it.
//   • `web.search` — the action. Multi-param (query + intent), routes
//     through `AppDependencies.current.providers.webSearchService` which gates on the Settings
//     toggle, the keychain'd Tavily key, and the curated domain
//     whitelists.
//
// Why an action and not a read entry: it has side effects (third-party
// API call, billed against the user's Tavily account) and takes
// multi-string args that the read-entry single-string-param shape
// doesn't accommodate. The system-prompt overlay's mutation-tool rules
// apply here AND `web.search` gets its own additional safety rule
// (no medical-protocol synthesis, always cite source URLs).
struct WebSearchNamespace: FactNamespaceResolver {
    let namespace = "web"

    var entries: [FactEntry] {
        [
            webAvailableEntry,
            webSearchEntry
        ]
    }

    private var webAvailableEntry: FactEntry {
        .fixed(
            key: "web.available",
            description: Self.webAvailableDescription,
            valueType: "Bool"
        ) {
            let enabled = AppDependencies.current.app.settingsManager.settingsSnapshot.enableWebSearch
            let hasTavilyKey = AppDependencies.current.providers.apiKeyStore.hasServiceKey(for: .tavilyWebSearch)
            // Anthropic's `web_search_20250305` server-side tool is
            // wired into the request body in `AnthropicProvider`.
            // It works without a Tavily key, so as long as the
            // active provider is Anthropic, web search IS available.
            // The resolver is invoked on the main actor by the
            // AssistantViewModel tool-use loop; `assumeIsolated`
            // satisfies the actor-isolation check on
            // `ProviderRegistry.activeProvider`.
            let providerHasNativeSearch = MainActor.assumeIsolated {
                AppDependencies.current.providers.providerRegistry.activeProvider.id == .anthropic
            }
            return .boolean(enabled && (hasTavilyKey || providerHasNativeSearch))
        }
    }

    private static let webAvailableDescription = """
    Whether the AI can currently search the web. True iff the user enabled web search in Settings AND ((a) a Tavily API key is set for the `web.search` action, OR (b) the active provider has built-in server-side search — Anthropic \
    Claude does as of 2026-05-07). When true on a provider with native server-side search, the model can search directly via the conversation (no `web.search` action call needed); when true with a Tavily key, the AI calls `web.search` \
    explicitly. When false, refuse 'look it up' / 'search for' requests with the suggestion 'turn on Web Search in Settings → Flo'.
    """

    private var webSearchEntry: FactEntry {
        .actionAsync(
            key: "web.search",
            description: Self.webSearchDescription,
            parameters: [
                ActionParam("query", "The search query. Plain English, 3–12 words. Example: 'DFA alpha1 lactate threshold validation'."),
                ActionParam("intent", "One of 'research', 'manufacturer', 'general'. Default 'research'.", required: false),
                ActionParam("max_results", "How many results to return (1–10). Default 5. Use fewer for narrow questions, more for surveys.", required: false)
            ]
        ) { args in await self.resolveWebSearch(args) }
    }

    @MainActor private func resolveWebSearch(_ args: [String: String]) async -> FactValue {
        guard let q = args["query"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !q.isEmpty
        else {
            return .missing(reason: .invalidParameter, detail: "query is required and must be non-empty")
        }
        let intent = searchIntent(args["intent"])
        let maxResults = Int(args["max_results"] ?? "5") ?? 5
        let webStartedAt = Date()
        debugLog("[WebSearch] action fired: query=\"\(q.prefix(60))\" intent=\(intent.rawValue) max=\(maxResults)")
        let raced = await racedSearch(query: q, intent: intent, maxResults: maxResults)
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(webStartedAt))
        guard let capturedResult = raced else {
            debugLog("[WebSearch] TIMEOUT after \(elapsed)s — Tavily didn't respond within the 15 s budget", level: .warning)
            return .missing(reason: .internalError, detail: "Tavily request timed out (>15s)")
        }
        return searchOutcome(capturedResult, query: q, intent: intent, elapsed: elapsed)
    }

    private func searchOutcome(
        _ capturedResult: Result<[WebSearchService.Result], WebSearchService.SearchError>,
        query q: String,
        intent: WebSearchService.Intent,
        elapsed: String
    ) -> FactValue {
        switch capturedResult {
        case let .success(results):
            return searchResults(results, query: q, intent: intent, elapsed: elapsed)
        case let .failure(error):
            return searchFailure(error, elapsed: elapsed)
        }
    }

    private func searchIntent(_ raw: String?) -> WebSearchService.Intent {
        switch raw?.lowercased() {
        case "manufacturer": return .manufacturer
        case "general": return .general
        default: return .research
        }
    }

    // A suspending timeout race with a 15 s budget, so the main actor is
    // never parked. WebSearchService is non-@MainActor, so the URLSession
    // await runs off-main while this resolver suspends. The budget is wider
    // than URLSession's own 12 s timeout, so a network error normally
    // arrives first; the race only stops a wedged request hanging the
    // assistant.
    //
    // Every call logs a [WebSearch] line with its outcome, because the
    // failure modes (model never calls it, Tavily key missing, Tavily
    // erroring) look identical to the user and only the log tells them apart.
    @MainActor private func racedSearch(
        query q: String,
        intent: WebSearchService.Intent,
        maxResults: Int
    ) async -> Result<[WebSearchService.Result], WebSearchService.SearchError>? {
        await FactResolveTimeout.withTimeout(seconds: 15) {
            do {
                let results = try await AppDependencies.current.providers.webSearchService.search(
                    query: q, intent: intent, maxResults: maxResults
                )
                return .success(results)
            } catch let error as WebSearchService.SearchError {
                return .failure(error)
            } catch {
                // Non-SearchError throw is unexpected (URLSession
                // errors are wrapped by WebSearchService); preserve
                // the message in a typed bucket so the switch below
                // still covers the case.
                return .failure(.network(error.localizedDescription))
            }
        }
    }

    private func searchResults(
        _ results: [WebSearchService.Result],
        query q: String,
        intent: WebSearchService.Intent,
        elapsed: String
    ) -> FactValue {
        if results.isEmpty {
            debugLog("[WebSearch] zero results in \(elapsed)s for query \"\(q.prefix(60))\" intent=\(intent.rawValue)")
            return .missing(
                reason: .notRecorded,
                detail: "no results from \(intent.rawValue) domains for query '\(q)' — broaden the query or try a different intent"
            )
        }
        debugLog("[WebSearch] OK \(results.count) results in \(elapsed)s for query \"\(q.prefix(60))\" intent=\(intent.rawValue)")
        return .record([
            "query": .string(q),
            "intent": .string(intent.rawValue),
            "result_count": .integer(results.count),
            "results": .list(results.map { searchResultRecord($0) })
        ])
    }

    private func searchResultRecord(_ r: WebSearchService.Result) -> FactValue {
        .record([
            "title": .string(r.title),
            "url": .string(r.url),
            "snippet": .string(r.content),
            "score": .double(r.score),
            "published_date": .from(r.publishedDate)
        ])
    }

    private func searchFailure(_ error: WebSearchService.SearchError, elapsed: String) -> FactValue {
        switch error {
        case .notEnabled:
            debugLog("[WebSearch] FAIL .notEnabled in \(elapsed)s — enableWebSearch is off in Settings", level: .warning)
            return .missing(reason: .notRecorded, detail: "web search is disabled — user must enable it in Settings → Flo")
        case .missingKey:
            debugLog("[WebSearch] FAIL .missingKey in \(elapsed)s — Tavily API key isn't in Keychain. Settings → Flo → Web Search.", level: .warning)
            return .missing(reason: .notRecorded, detail: "no Tavily API key configured in Settings → Flo")
        case .rateLimited:
            debugLog("[WebSearch] FAIL .rateLimited in \(elapsed)s — Tavily 429 (free tier is 1000/mo)", level: .warning)
            return .missing(reason: .rateLimited, detail: "Tavily rate limit hit — try again in a moment")
        case .network(let s):
            debugLog("[WebSearch] FAIL .network in \(elapsed)s: \(s)", level: .warning)
            return .missing(reason: .internalError, detail: "Tavily network error: \(s)")
        case .decode(let s):
            debugLog("[WebSearch] FAIL .decode in \(elapsed)s: \(s)", level: .warning)
            return .missing(reason: .internalError, detail: "Tavily response decode error: \(s)")
        }
    }

    private static let webSearchDescription = """
    [ACTION] Search the web for authoritative sources via Tavily. Use ONLY when the on-device fact catalog can't answer the question (e.g. recent research, manufacturer firmware, hardware specs you don't already have). FIVE \
    rules: (1) results are reference material, NOT medical advice — never synthesise a new training/diet/medication protocol from them; (2) MEDICAL TREATMENTS — do NOT use web search to research medications, supplements, vaccines, \
    or medical interventions, and never synthesise a dosing protocol or personal recommendation from any result. General mechanism-level discussion is governed by the system prompt's MEDICAL BOUNDARY section (information, not \
    prescription); this tool is for training-science, hardware, and research-methodology sources, not pharmacology. If the user wants to know whether or how much of a substance to take — a personal-prescription question — don't \
    search it; decline and suggest their doctor or pharmacist; (3) ALWAYS cite the source URL alongside any fact you quote so the user can verify; (4) prefer the user's own data (other facts) over web results when both are available; \
    (5) the AFib / arrhythmia / symptom-triage refusal in the system prompt's MEDICAL BOUNDARY section overrides any search result — if the user's question crosses that line, do not call this tool. The `intent` parameter constrains \
    which domains are searched: 'research' (default — peer-reviewed + established training-science blogs), 'manufacturer' (Polar/Garmin/Stryd/etc. official docs), or 'general' (open web, only when neither fits).
    """
}
