import Foundation

/// Three-tier session-sticky routing.
///
/// Per-turn cross-provider routing on keywords produces persona drift,
/// so the tier is proposed per turn but held per conversation:
///
///   1. **Capability proposal** — `CapabilityClassifier` flags what the
///      message needs (tools / web / depth / speculation), and the flags
///      Apple Intelligence can't serve propose a tier.
///   2. **Session-sticky** — upgrades are always taken; downgrades only
///      within the first 3 turns of a conversation, or afterwards when
///      the proposal is Quick with every capability flag clear.
///   3. **Adversarial spend cap** — per-day Tier 3 turn budget, kept in
///      UserDefaults so relaunching the app does not reset it.
///
/// Tier mapping is dynamic: tiers map to whatever providers the user
/// has actually configured. If only Apple Intelligence is available,
/// every tier maps to Apple.
@MainActor
final class SmartProviderRouter {
    /// What proposes each turn's tier.
    private let classifier: @MainActor () -> CapabilityClassifier

    init(classifier: @escaping @MainActor () -> CapabilityClassifier) {
        self.classifier = classifier
    }

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
    /// capability truth-table (`Requirement.requiredTier`):
    ///   • no web, depth or speculation flag, tools or not → `.quick` (Apple)
    ///   • one of them, and no other flag                  → `.auto` (mid-tier cloud)
    ///   • two or more flags, at least one of them         → `.deep` (see `Tier.deep`)
    /// See `CapabilityClassifier` and docs/FLO_ARCHITECTURE.md §8.
    func route(message: String, in session: RoutingSessionState) -> Tier {
        let requirement = classifier().classify(message)
        let proposed = requirement.requiredTier
        let chosen = stickyTier(proposed: proposed, requirement: requirement, session: session)
        debugLog("[SmartRouter] capabilities=\(requirement.debugSummary) proposed=\(proposed) → chosen=\(chosen) (turn \(session.turnCount))", level: .info)
        return chosen
    }

    /// Rules:
    ///   • Upgrades (proposed > current) → always allowed.
    ///   • Within the settling window (turns 1–3; the caller counts the
    ///     current turn before routing) → take the proposal.
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
        if session.turnCount <= Self.settlingTurns { return proposed }
        if proposed == .quick, requirement == .none { return proposed }
        return session.currentTier
    }

    private static let settlingTurns = 3

    // MARK: - Adversarial cap

    /// The day the stored Tier 3 count belongs to, and the count. Persisted
    /// so a force-quit does not reset the daily ceiling.
    private static let tier3DayKey = "assistant.router.tier3Day"
    private static let tier3CountKey = "assistant.router.tier3Count"

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
    /// Only TODAY's count is ever read, so one day and one count are
    /// stored: a stored count from another day starts over at zero.
    func recordTier3UsageAndCheck() -> Bool {
        let defaults = UserDefaults.standard
        let key = dayKey()
        let stored = defaults.string(forKey: Self.tier3DayKey) == key ? defaults.integer(forKey: Self.tier3CountKey) : 0
        let count = stored + 1
        defaults.set(key, forKey: Self.tier3DayKey)
        defaults.set(count, forKey: Self.tier3CountKey)
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
