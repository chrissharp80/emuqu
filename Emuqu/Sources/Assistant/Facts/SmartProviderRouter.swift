import Foundation
import NaturalLanguage

/// Three-tier session-sticky routing.
///
/// Replaces the v1 keyword router (which the spec explicitly rejects:
/// per-turn cross-provider routing produced GPT-5's August 2025
/// rollback and Character.AI's documented persona drift). This v2:
///
///   1. **NLContextualEmbedding classifier** (single-digit ms on the
///      ANE). Cosine similarity to hand-curated prototype phrases per
///      tier. Falls back to NLEmbedding (iOS 14+) on devices without
///      the contextual encoder, then to a keyword heuristic on devices
///      without either.
///   2. **Session-sticky** — tier persists once chosen. Downgrades
///      only allowed in the first 3 turns of a conversation; upgrades
///      require high classifier confidence (margin ≥ 0.15).
///   3. **Topic-shift detection** — cosine distance > 0.4 between
///      session-summary embedding and a new turn re-classifies.
///   4. **Adversarial spend cap** — per-day Tier 3 turn budget.
///
/// Tier mapping is dynamic: tiers map to whatever providers the user
/// has actually configured. If only Apple Intelligence is available,
/// every tier maps to Apple. The spec's "work with what's there."
@MainActor
final class SmartProviderRouter {
    static let shared = SmartProviderRouter()

    enum Tier: Int, Comparable {
        /// On-device. Free, fast, private. For lookups, summaries,
        /// email composition, simple acknowledgments.
        case quick = 1
        /// Cheap cloud (Haiku 4.5 / Flash-Lite class). For general
        /// coaching turns, "should I train hard today" reasoning at
        /// modest depth.
        case auto = 2
        /// Most-capable cloud (Sonnet / GPT-5 / Gemini Pro class).
        /// Multi-week analysis, periodization design, complex
        /// reasoning over time-series.
        case deep = 3

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Per-day cap on Tier 3 turns to bound the worst case if a user's
    /// classifier is somehow flipped by adversarial input (Shafran
    /// 2025 reports 88-100% white-box attack success on routers).
    /// Defensive ceiling, not a budget cap; the user's expected daily
    /// Tier 3 traffic is single-digits.
    private static let dailyTier3Cap = 50

    // MARK: - Classification

    /// Classify a single user message into a tier. Stateless — the
    /// session-stickiness layer is a separate decision applied on top
    /// (see `route(message:in:)`).
    func classify(_ message: String) -> (tier: Tier, confidence: Double) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return (.quick, 1.0) }

        if let scores = embeddingClassify(trimmed) {
            let sorted = scores.sorted { $0.value > $1.value }
            let top = sorted[0]
            let runnerUp = sorted.count > 1 ? sorted[1] : (key: top.key, value: 0.0)
            return (top.key, top.value - runnerUp.value)
        }
        return heuristicClassify(trimmed)
    }

    /// Apply session stickiness on top of a fresh classification.
    /// Returns the tier this turn should run on.
    ///
    /// `route` is
    /// driven by `CapabilityClassifier` (4-axis capability flags)
    /// rather than length / complexity prototypes. The
    /// behavioural contract is the same — stickiness, settling
    /// window, topic-shift detection — but the proposed tier comes
    /// from a capability truth-table:
    ///   • zero capability flags  → `.quick` (fits Apple's 4K window)
    ///   • exactly one flag       → `.auto` (cheap cloud)
    ///   • two or more flags      → `.deep` (best cloud)
    /// See `CapabilityClassifier` and docs/FLO_ARCHITECTURE.md §8.
    func route(message: String, in session: RoutingSessionState) -> Tier {
        let requirement = AppDependencies.current.providers.capabilityClassifier.classify(message)
        let proposed = requirement.requiredTier
        let chosen = stickyTier(proposed: proposed, requirement: requirement, message: message, session: session)
        recordTelemetry(proposed: proposed, chosen: chosen)
        debugLog("[SmartRouter] capabilities=\(requirement.debugSummary) proposed=\(proposed) → chosen=\(chosen) (turn \(session.turnCount))", level: .info)
        return chosen
    }

    /// Rules (unchanged from the prior length classifier — only the
    /// proposal source changed):
    ///   • Topic shift (cosine > shiftThreshold) → take the proposal
    ///     as-is (re-classified context).
    ///   • Upgrades (proposed > current) → always allowed.
    ///   • Within the settling window → take the proposal.
    ///   • Post-settle downgrades → only when the proposal is `.quick`
    ///     and ALL four capability flags are clear (no false-positive
    ///     risk on tools/web/depth/speculation). Otherwise sticky-up.
    ///
    /// That last rule is the explicit
    /// capability-clear escape from sticky-up: the classifier returned zero
    /// flags AND the proposal is Quick, so the question is unambiguously a
    /// small lookup that fits in Apple's 4K window. Without it, a single
    /// Tier-3 question early in the conversation locks every subsequent simple
    /// lookup to Sonnet.
    private func stickyTier(
        proposed: Tier,
        requirement: CapabilityClassifier.Requirement,
        message: String,
        session: RoutingSessionState
    ) -> Tier {
        if let summary = session.summaryEmbedding,
           let turn = embed(message),
           cosineDistance(summary, turn) > Self.topicShiftThreshold {
            return proposed
        }
        if proposed > session.currentTier { return proposed }
        if session.turnCount < Self.settlingTurns { return proposed }
        if proposed == .quick, requirement == .none { return proposed }
        return session.currentTier
    }

    private static let confidenceMargin: Double = 0.15
    /// Separate, stricter threshold for breaking the
    /// post-settle stickiness DOWNWARD. Higher than `confidenceMargin`
    /// so we only override the lock when the classifier is decisive.
    /// At 0.3 it requires the top-tier classification to beat the
    /// runner-up by 30+ percentage points of cosine similarity —
    /// well past the noise floor on factual lookups vs analytical
    /// reasoning.
    private static let confidentDowngradeMargin: Double = 0.3
    private static let topicShiftThreshold: Double = 0.4
    private static let settlingTurns = 3

    // MARK: - Embedding

    /// Lazily-initialised NL contextual embedder. Created on first use
    /// (~50ms cold) and cached for the app lifetime. Returns nil on
    /// older OS versions or unsupported devices; callers fall back to
    /// the heuristic.
    private lazy var contextualEmbedder: NLContextualEmbedding? = {
        guard #available(iOS 17.0, *) else { return nil }
        return Self.loadContextualEmbedder()
    }()

    /// Create and load the contextual embedder, or nil when this device cannot
    /// provide one.
    ///
    /// Split out of the stored closure above, which would otherwise hold
    /// three levels of nesting (`if #available` / `guard` / `catch`) where the
    /// spec allows two.
    @available(iOS 17.0, *)
    private static func loadContextualEmbedder() -> NLContextualEmbedding? {
        guard let embedder = NLContextualEmbedding(language: .english) else { return nil }
        // requestAssets() is async (downloads from CDN). If assets aren't yet
        // available, kick off the request and degrade to the word-embedding
        // fallback for this app launch — next launch will pick up the
        // fully-loaded contextual embedder.
        guard embedder.hasAvailableAssets else {
            // A fresh instance inside the task keeps the non-Sendable embedder
            // from crossing isolation.
            Task.detached { try? await NLContextualEmbedding(language: .english)?.requestAssets() }
            return nil
        }
        do {
            try embedder.load()
            return embedder
        } catch {
            return nil
        }
    }

    /// Fallback word-vector embedder (iOS 14+). 512-dim, no context
    /// awareness but still discriminates "what's my HRV" (lookup) vs
    /// "explain my recovery trend" (reasoning) reliably.
    private lazy var wordEmbedder: NLEmbedding? = {
        NLEmbedding.wordEmbedding(for: .english)
    }()

    /// Cached prototype centroids — computed once on first classification.
    ///
    /// The averaging lives in `EmbeddingCentroid.mean`, shared with
    /// `CapabilityClassifier`. Assigning nil for an empty phrase list removes
    /// the key, which is what the previous `continue` did.
    private lazy var prototypeCentroids: [Tier: [Double]] = {
        var out: [Tier: [Double]] = [:]
        for (tier, phrases) in Self.prototypes {
            out[tier] = EmbeddingCentroid.mean(of: phrases.compactMap { embed($0) })
        }
        return out
    }()

    /// Mean-pooled sentence embedding. Prefers the contextual embedder and
    /// falls through to the word-vector path when it's unavailable or throws.
    func embed(_ text: String) -> [Double]? {
        contextualEmbedding(text) ?? wordVectorEmbedding(text)
    }

    /// Average the contextual embedder's per-token vectors.
    private func contextualEmbedding(_ text: String) -> [Double]? {
        guard let e = contextualEmbedder,
              let result = try? e.embeddingResult(for: text, language: .english) else { return nil }
        var sum: [Double] = []
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex ..< text.endIndex) { vector, _ in
            if sum.isEmpty { sum = [Double](repeating: 0, count: vector.count) }
            for i in 0 ..< min(sum.count, vector.count) { sum[i] += vector[i] }
            count += 1
            return true
        }
        guard count > 0, !sum.isEmpty else { return nil }
        return sum.map { $0 / Double(count) }
    }

    /// Average the static word vectors for each lowercased alphabetic token.
    private func wordVectorEmbedding(_ text: String) -> [Double]? {
        guard let w = wordEmbedder else { return nil }
        let tokens = text.split(whereSeparator: { !$0.isLetter }).map { String($0).lowercased() }
        let vectors = tokens.compactMap { w.vector(for: $0) }
        guard var sum = vectors.first else { return nil }
        for v in vectors.dropFirst() {
            for i in 0 ..< sum.count { sum[i] += v[i] }
        }
        return sum.map { $0 / Double(vectors.count) }
    }

    private func embeddingClassify(_ text: String) -> [Tier: Double]? {
        guard let q = embed(text) else { return nil }
        let centroids = prototypeCentroids
        guard !centroids.isEmpty else { return nil }
        var scores: [Tier: Double] = [:]
        for (tier, centroid) in centroids {
            scores[tier] = cosineSimilarity(q, centroid)
        }
        return scores
    }

    // MARK: - Heuristic fallback

    private func heuristicClassify(_ text: String) -> (Tier, Double) {
        for marker in deepMarkers where text.contains(marker) {
            return (.deep, 0.6)
        }
        for marker in autoMarkers where text.contains(marker) {
            return (.auto, 0.4)
        }
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        if words <= 12 { return (.quick, 0.5) }
        return (.auto, 0.2)
    }

    private let deepMarkers = [
        "explain", "compare", "trend", "vs ", "versus",
        "design a", "plan a", "periodize", "periodization",
        "predict", "forecast", "what does it mean that",
        "is this normal", "diagnose", "analyze",
        "over the last", "across the last", "across the past",
        "8 weeks", "12 weeks", "month"
    ]

    private let autoMarkers = [
        "why", "should i", "would i", "could i", "recommend",
        "suggest", "what if", "how come",
        "am i ready", "am i improving", "do you think"
    ]

    // MARK: - Prototype phrases
    //
    // Hand-curated; the spec recommends 6-10 per tier.
    private static let prototypes: [Tier: [String]] = [
        .quick: [
            "What's my HRV today?",
            "What's my recovery score?",
            "How was my sleep last night?",
            "What's my resting heart rate?",
            "Email me today's recovery report.",
            "Send me a summary of yesterday.",
            "Summarize my last week.",
            "List my workouts this week.",
            "Show me my baseline HRV.",
            "Tell me my training load."
        ],
        .auto: [
            "Why is my recovery score low today?",
            "Should I train hard today?",
            "Am I ready for a long run?",
            "How does today compare to yesterday?",
            "What's been pulling my score down?",
            "Is my sleep improving?",
            "Is my training load higher than usual?",
            "How recovered am I after yesterday's workout?"
        ],
        .deep: [
            "Explain my recovery trend over the last 8 weeks.",
            "Design a 4-week deload plan based on my recent fatigue.",
            "Compare my response to high-intensity vs zone-2 weeks across the past two months.",
            "What patterns do you see in my HRV across my training cycles?",
            "Analyze my readiness across the last quarter and tell me when I peaked.",
            "Build me a periodized plan for the next race based on my history."
        ]
    ]

    // MARK: - Math

    private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = sqrt(na) * sqrt(nb)
        return denom > 0 ? dot / denom : 0
    }

    private func cosineDistance(_ a: [Double], _ b: [Double]) -> Double {
        1.0 - cosineSimilarity(a, b)
    }

    // MARK: - Telemetry

    /// Best-effort, in-memory counters of how often each tier was
    /// chosen and how often the classifier proposed a different tier
    /// than the session was sticking to (an "escalation/de-escalation
    /// signal"). Used for /diagnose-style debug overlays — never sent
    /// off-device. Bumped from `route(...)`.
    private(set) var tierCounts: [Tier: Int] = [.quick: 0, .auto: 0, .deep: 0]
    private(set) var classifierProposalCounts: [Tier: Int] = [.quick: 0, .auto: 0, .deep: 0]
    private(set) var stickinessOverrides: Int = 0

    private func recordTelemetry(proposed: Tier, chosen: Tier) {
        classifierProposalCounts[proposed, default: 0] += 1
        tierCounts[chosen, default: 0] += 1
        if proposed != chosen { stickinessOverrides += 1 }
    }

    // MARK: - Adversarial cap

    private var tier3CountByDay: [String: Int] = [:]

    private func dayKey(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Increment + check the daily Tier 3 count. Returns true if the
    /// turn is allowed at Tier 3; false if the daily cap is hit and
    /// the caller should downgrade to Tier 2.
    ///
    /// `tier3CountByDay` must not keep one entry per
    /// distinct day forever (one new key each calendar day, never
    /// evicted), or the dictionary grows unbounded over the app's
    /// lifetime. Only TODAY's count is ever read, so collapse the map
    /// to a single { todayKey: count } entry — yesterday's bucket is
    /// dead weight the moment the date rolls over.
    func recordTier3UsageAndCheck() -> Bool {
        let key = dayKey()
        let count = (tier3CountByDay[key] ?? 0) + 1
        tier3CountByDay = [key: count]
        return count <= Self.dailyTier3Cap
    }
}

/// Per-conversation routing state. Lives on the AssistantViewModel.
@MainActor
final class RoutingSessionState {
    var currentTier: SmartProviderRouter.Tier
    var turnCount: Int = 0
    /// Embedding of the running summary; updated when a new summary
    /// is computed. Drives topic-shift detection.
    var summaryEmbedding: [Double]?

    init(initialTier: SmartProviderRouter.Tier = .quick) {
        self.currentTier = initialTier
    }
}

/// Mean of a set of embedding vectors.
///
/// The summation is bounded — `where index < vector.count` — so an embedder
/// swap that produced variable-length vectors could not walk past the buffer.
/// One implementation shared by `SmartProviderRouter` and
/// `CapabilityClassifier.prototypeCentroids`, so there is no parity to keep.
enum EmbeddingCentroid {
    static func mean(of vectors: [[Double]]) -> [Double]? {
        guard let first = vectors.first else { return nil }
        let dimension = first.count
        var centroid = [Double](repeating: 0, count: dimension)
        for vector in vectors {
            for index in 0 ..< dimension where index < vector.count {
                centroid[index] += vector[index]
            }
        }
        for index in 0 ..< dimension { centroid[index] /= Double(vectors.count) }
        return centroid
    }
}
