import Foundation
import NaturalLanguage

/// Capability-axis routing.
///
/// Gives `SmartProviderRouter` **four orthogonal binary capability
/// flags** instead of length / complexity prototypes. The short version of
/// the reasoning:
///
/// > "Cosine-to-curated-prototypes is the correct architecture; it
/// > just needs to be pointed at capability prototypes, not complexity
/// > prototypes."
///
/// Why: the prior design asked *"how complex is this question?"* and
/// optimised cost on the assumption that simple-looking questions need
/// only simple models. That collapsed when a simple-looking question
/// turned out to need a tool the cheap model didn't have. Real
/// failure mode: the user asks *"can you see the top of the last
/// hill"* — eight words, looks like a Quick lookup — but answering it
/// requires a tool that fetches per-tick GPS + altitude samples from
/// a workout JSON. Apple Intelligence (the Quick tier) discards the
/// `tools` array; question is unanswerable.
///
/// The fix axes ask *"what does this question need?"*:
///
/// 1. **`needsTools`** — explicit action verbs (email, directions,
///    save route, list contacts) OR data lookups that go beyond the
///    static context block (per-workout deep-dives, full archive
///    history, route library mutations).
/// 2. **`needsWeb`** — facts outside the user's own data (weather,
///    news, product recommendations, "is X commercially licensable").
/// 3. **`needsHistoricalDepth`** — comparisons against history older
///    than the static 14-workout context block ("trend over 8 weeks",
///    "month-over-month", "since I started").
/// 4. **`needsSpeculation`** — speculative reasoning that on-device
///    Apple Intelligence's safety guardrail typically refuses, but
///    that the app's `MedicalQueryGuard` permits ("best guess on…",
///    "how long will I live", "what if I rest").
///
/// Tier resolution truth table:
///   • any one flag set  → `.auto` (cheap cloud — Haiku 4.5 / Flash Lite)
///   • two or more flags → `.deep` (best cloud — Sonnet / Opus)
///   • zero flags        → `.quick` (Apple, fits in 4K window)
///
/// The classifier reuses the same `NLContextualEmbedding` asset
/// `SmartProviderRouter` already loads. Cosine similarity to
/// per-axis prototype centroids; threshold per axis is 0.55 (raised
/// from the prior router's 0.40 based on the research's TIAGE-style
/// hysteresis recommendation — at 0.40 we'd false-positive on every
/// question that mentions a number).
@MainActor
final class CapabilityClassifier {
    static let shared = CapabilityClassifier()

    /// Cosine similarity threshold per axis. The research recommends
    /// calibrating against a 200-utterance held-out set; 0.55 is the
    /// initial value pre-calibration. Lower → more false positives →
    /// more cost. Higher → more false negatives → user asks for X,
    /// Apple says it can't — the frustration this routing exists to avoid.
    private static let axisThreshold: Double = 0.55

    /// The four capability axes.
    enum Axis: String, CaseIterable {
        case tools
        case web
        case historicalDepth
        case speculation
    }

    /// Per-turn classification result.
    struct Requirement: Equatable {
        let needsTools: Bool
        let needsWeb: Bool
        let needsHistoricalDepth: Bool
        let needsSpeculation: Bool

        /// Map the four flags onto a router tier.
        var requiredTier: SmartProviderRouter.Tier {
            let count = [needsTools, needsWeb, needsHistoricalDepth, needsSpeculation].filter { $0 }.count
            if count >= 2 { return .deep }
            if count >= 1 { return .auto }
            return .quick
        }

        /// Compact debug string for telemetry.
        var debugSummary: String {
            var parts: [String] = []
            if needsTools { parts.append("tools") }
            if needsWeb { parts.append("web") }
            if needsHistoricalDepth { parts.append("history") }
            if needsSpeculation { parts.append("speculate") }
            return parts.isEmpty ? "none" : parts.joined(separator: "+")
        }

        static let none = Requirement(needsTools: false, needsWeb: false, needsHistoricalDepth: false, needsSpeculation: false)
    }

    // MARK: - Public API

    /// Classify a single user message into a capability requirement.
    /// Stateless — caller (SmartProviderRouter) layers stickiness.
    ///
    /// An embedding-only path over-triggers on plain lookups:
    /// *"what's my recovery score"* embeds close to the
    /// historical-depth prototypes (the word "recovery" is a strong
    /// shared term) and a single Quick lookup gets escalated to Deep.
    /// Hence **keyword-gated embedding**:
    /// a capability axis only fires if BOTH the embedding cosine
    /// crosses the threshold AND at least one keyword marker for that
    /// axis is present. Eliminates false positives from semantic-
    /// adjacency on shared domain vocabulary while still catching
    /// paraphrases the keyword list would miss.
    ///
    /// On older OS where `NLContextualEmbedding` is unavailable, the
    /// keyword heuristic is the sole signal — same conservative
    /// false-negative bias.
    func classify(_ message: String) -> Requirement {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return .none }

        let kw = keywordHeuristic(trimmed)

        // Embedding path: gate each axis on a corresponding keyword
        // hit. If keyword AND embedding both think the axis applies,
        // it does. Either alone isn't enough.
        if let scores = embeddingClassify(trimmed) {
            return Requirement(
                needsTools: kw.needsTools && scores[.tools, default: 0] >= Self.axisThreshold,
                needsWeb: kw.needsWeb && scores[.web, default: 0] >= Self.axisThreshold,
                needsHistoricalDepth: kw.needsHistoricalDepth && scores[.historicalDepth, default: 0] >= Self.axisThreshold,
                needsSpeculation: kw.needsSpeculation && scores[.speculation, default: 0] >= Self.axisThreshold
            )
        }
        return kw
    }

    // MARK: - Embedding path

    /// Reuses the embedder from `SmartProviderRouter` — the asset
    /// download is shared at the OS level (`NLContextualEmbedding(language:)`
    /// is a singleton-like accessor) so we don't pay double initialization.
    private func embed(_ text: String) -> [Double]? {
        AppDependencies.current.providers.smartProviderRouter.embed(text)
    }

    /// Cached prototype centroids — computed once on first
    /// classification.
    private lazy var prototypeCentroids: [Axis: [Double]] = {
        var out: [Axis: [Double]] = [:]
        for (axis, phrases) in Self.prototypes {
            out[axis] = EmbeddingCentroid.mean(of: phrases.compactMap { embed($0) })
        }
        return out
    }()

    private func embeddingClassify(_ text: String) -> [Axis: Double]? {
        guard let q = embed(text) else { return nil }
        let centroids = prototypeCentroids
        guard !centroids.isEmpty else { return nil }
        var scores: [Axis: Double] = [:]
        for (axis, centroid) in centroids {
            scores[axis] = cosineSimilarity(q, centroid)
        }
        return scores
    }

    // MARK: - Keyword heuristic fallback
    //
    // Used when the embedder isn't available (asset still downloading
    // on first launch, older device). Conservative — false-negative bias.
    // The thresholds for the embedder are stricter; here we only trip
    // when the marker is unambiguous.

    private func keywordHeuristic(_ text: String) -> Requirement {
        Requirement(
            needsTools: Self.toolMarkers.contains { text.contains($0) },
            needsWeb: Self.webMarkers.contains { text.contains($0) },
            needsHistoricalDepth: Self.depthMarkers.contains { text.contains($0) },
            needsSpeculation: Self.speculationMarkers.contains { text.contains($0) }
        )
    }

    private static let toolMarkers: [String] = [
        "email", "send a", "send me", "compose", "draft a",
        "directions", "navigate", "lead me", "route me", "take me back", "head back",
        "save route", "save this route", "rename route", "save as a route",
        "as a route", // catches "save this workout as a route called X"
        "add contact", "remove contact", "list contacts", "list my contacts",
        "search the web", "look up online", "google", "search for"
    ]

    private static let webMarkers: [String] = [
        "weather", "raining", "temperature outside", "wind",
        "news", "latest", "what's new",
        "commercially licensable", "license", "buy", "purchase",
        "is open", "open now", "open today",
        "currency", "exchange rate", "stock", "price of"
    ]

    private static let depthMarkers: [String] = [
        "last month", "past month", "this month",
        "8 weeks", "12 weeks", "quarter",
        "since i started", "since february", "since january",
        "trend over", "month-over-month", "year-over-year", "compared to a",
        "across the past", "across the last", "year ago"
    ]

    private static let speculationMarkers: [String] = [
        "predict", "best guess", "guess", "speculate",
        "how long will", "how long am i", "how long do i have",
        "what if i", "would i", "could i", "will i ever",
        "if i kept", "if i continue", "if i keep"
    ]

    // MARK: - Prototype phrases per axis
    //
    // Hand-curated; calibrate the threshold against a held-out eval
    // set after collecting real voice transcripts.
    // Tests in `CapabilityClassifierTests` exercise the contract.

    private static let prototypes: [Axis: [String]] = [
        .tools: [
            "Email this report to my coach.",
            "Send me yesterday's recovery summary in an email.",
            "Lead me back to where I parked the car.",
            "Navigate me to the nearest hospital.",
            "Take me back to the start of this trail.",
            "Save this workout as a route called Morning Loop.",
            "Rename Daily 1 to Sunset Loop.",
            "Add a contact for my wife with phone number 555-1234.",
            "List my saved routes.",
            "Compose an email to support@example.com with the bug report."
        ],
        .web: [
            "What's the weather right now?",
            "Is the supermarket open at this hour?",
            "Are there AI voices I can buy and use commercially?",
            "What's the latest research on HRV and meditation?",
            "What's a good recovery supplement to look at?",
            "What does the news say about the storm tonight?",
            "Look up the temperature in Boulder for tomorrow.",
            "Search the web for endurance-training plans."
        ],
        .historicalDepth: [
            "How does this month compare to last month?",
            "What's my recovery trend over the last 8 weeks?",
            "Since I started running again in January, how have I improved?",
            "Compare my heart rate response to high-intensity weeks across the past two months.",
            "Across the past quarter, when did I peak?",
            "How does my sleep this month compare to a year ago?",
            "What patterns do you see across my training cycles?"
        ],
        .speculation: [
            "Best guess on how long I'm going to live based on my data.",
            "Predict what my recovery will look like next week.",
            "What if I rested for five days straight, how would I respond?",
            "Would I improve more if I added a long run on Sundays?",
            "If I keep training like this, what happens in six months?",
            "How long do I have if I keep my current habits?"
        ]
    ]

    // MARK: - Math

    private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0
        var na = 0.0
        var nb = 0.0
        for i in 0 ..< a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot()) * (nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }
}
