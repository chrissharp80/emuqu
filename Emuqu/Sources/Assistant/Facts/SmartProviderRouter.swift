import Foundation
import NaturalLanguage

/// Three-tier session-sticky routing.
///
/// Per-turn cross-provider routing on keywords produces persona drift,
/// so the tier is proposed per turn but held per conversation:
///
///   1. **Capability proposal** — `CapabilityClassifier` flags what the
///      message needs (tools / web / depth / speculation), and the flag
///      count proposes a tier.
///   2. **Session-sticky** — upgrades are always taken; downgrades only
///      within the first 3 turns of a conversation, or afterwards when
///      the proposal is Quick with every capability flag clear.
///   3. **Adversarial spend cap** — per-day Tier 3 turn budget.
///
/// The router also owns the sentence embedder (`embed`) that
/// `CapabilityClassifier` uses for its prototype matching.
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
        /// Mid-tier cloud (Grok or DeepSeek when configured; see
        /// `TierProviderMapper`). For general coaching turns, "should I
        /// train hard today" reasoning at modest depth.
        case auto = 2
        /// The user's chosen cloud primary; with Apple as the primary, the
        /// consented mid-tier cloud provider (see `TierProviderMapper`), so
        /// Deep is never weaker than Auto. Multi-week analysis,
        /// periodization design, complex reasoning over time-series.
        case deep = 3

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Per-day cap on Tier 3 turns to bound the worst case if a user's
    /// classifier is somehow flipped by adversarial input (Shafran
    /// 2025 reports 88-100% white-box attack success on routers).
    /// Defensive ceiling, not a budget cap; the user's expected daily
    /// Tier 3 traffic is single-digits.
    private static let dailyTier3Cap = 50

    // MARK: - Routing

    /// Apply session stickiness on top of a fresh classification.
    /// Returns the tier this turn should run on.
    ///
    /// The proposed tier comes from `CapabilityClassifier`'s
    /// capability truth-table:
    ///   • zero capability flags  → `.quick` (fits Apple's 4K window)
    ///   • exactly one flag       → `.auto` (mid-tier cloud)
    ///   • two or more flags      → `.deep` (see `Tier.deep`)
    /// See `CapabilityClassifier` and docs/FLO_ARCHITECTURE.md §8.
    func route(message: String, in session: RoutingSessionState) -> Tier {
        let requirement = AppDependencies.current.providers.capabilityClassifier.classify(message)
        let proposed = requirement.requiredTier
        let chosen = stickyTier(proposed: proposed, requirement: requirement, session: session)
        recordTelemetry(proposed: proposed, chosen: chosen)
        debugLog("[SmartRouter] capabilities=\(requirement.debugSummary) proposed=\(proposed) → chosen=\(chosen) (turn \(session.turnCount))", level: .info)
        return chosen
    }

    /// Rules:
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
    /// lookup to the Deep tier.
    private func stickyTier(
        proposed: Tier,
        requirement: CapabilityClassifier.Requirement,
        session: RoutingSessionState
    ) -> Tier {
        if proposed > session.currentTier { return proposed }
        if session.turnCount < Self.settlingTurns { return proposed }
        if proposed == .quick, requirement == .none { return proposed }
        return session.currentTier
    }

    private static let settlingTurns = 3

    // MARK: - Embedding

    /// Lazily-initialised NL contextual embedder. Created on first use
    /// (~50ms cold) and cached for the app lifetime. Returns nil on
    /// older OS versions or unsupported devices; `embed` falls back to
    /// the word-vector embedder.
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

    /// Fallback word-vector embedder. 512-dim, no context awareness but
    /// still discriminates "what's my HRV" (lookup) vs "explain my
    /// recovery trend" (reasoning) reliably.
    private lazy var wordEmbedder: NLEmbedding? = {
        NLEmbedding.wordEmbedding(for: .english)
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
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
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

    init(initialTier: SmartProviderRouter.Tier = .quick) {
        self.currentTier = initialTier
    }
}

/// Mean of a set of embedding vectors.
///
/// The summation is bounded — `where index < vector.count` — so an embedder
/// swap that produced variable-length vectors could not walk past the buffer.
/// Used by `CapabilityClassifier.prototypeCentroids`.
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
