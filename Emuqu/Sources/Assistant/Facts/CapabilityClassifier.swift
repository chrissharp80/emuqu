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
/// Why: asking *"how complex is this question?"* and optimising cost on
/// the assumption that simple-looking questions need only simple models
/// fails when a simple-looking question needs something the on-device model
/// can't do. For example, *"what's the weather at the trailhead"* is six
/// words and looks like a Quick lookup, but Apple Intelligence has no web
/// search (`AppleToolDispatcher` refuses `web_search`), so on the device the
/// question is unanswerable.
///
/// The axes ask *"what does this question need?"*:
///
/// 1. **`needsTools`**: explicit action verbs (email, directions,
///    save route, list contacts) OR data lookups that go beyond the
///    static context block (per-workout deep-dives, route library
///    mutations).
/// 2. **`needsWeb`**: facts outside the user's own data (weather,
///    news, product recommendations, "is X commercially licensable"),
///    and explicit requests to search the web.
/// 3. **`needsHistoricalDepth`**: comparisons against history older
///    than the static 14-workout context block ("trend over 8 weeks",
///    "month-over-month", "since I started").
/// 4. **`needsSpeculation`**: speculative reasoning that on-device
///    Apple Intelligence's safety guardrail typically refuses, but
///    that the app's `MedicalQueryGuard` permits ("best guess on…",
///    "how long will I live", "what if I rest").
///
/// Tools alone keep a question on the device. Apple Intelligence calls the
/// app's tools through `LanguageModelSession(tools:)` (`AppleToolAdapter`,
/// `AppleToolDispatcher`): every read and action tool but `web_search`,
/// the descriptions ranked against the question and cut to what its window
/// holds (`AppleFoundationProvider.fittingTools`). What it can't do is
/// search the web, hold history past its 4,096-token window, or answer what
/// its guardrail refuses: the other three axes.
///
/// Tier resolution truth table:
///   • none of web / depth / speculation → `.quick` (Apple, tools or not)
///   • one of them                         → `.auto` (mid-tier cloud: Grok, then DeepSeek, when consented)
///   • two or more flags, tools included   → `.deep` (the user's cloud primary, else the mid-tier cloud)
///
/// The flags come from the phrase patterns of `CapabilityMarkers`. An
/// optional embedding gate (`embeddingGate`) can also require each English
/// flag's cosine to its axis's prototype centroid (embeddings from
/// `SentenceEmbedder`) to reach a threshold. The eval (`RouterEvalTests`)
/// grades this classifier on a held-out split and calibrates the gate on a
/// separate tuning split.
@MainActor
final class CapabilityClassifier {
    /// The sentence embedder the prototype matching uses.
    private let embedder: SentenceEmbedder

    init(embedder: SentenceEmbedder) {
        self.embedder = embedder
    }

    /// The cosine an English marker's axis needs from the embedding; 0
    /// turns the gate off. Calibrated on the eval's tuning split
    /// (`RouterEvalTests.testTheEmbeddingIsCalibratedOnTheTuningSplit`):
    /// no gate above 0 grades it better, and letting an unmarked axis fire
    /// on its cosine alone grades it far worse at every threshold tried.
    /// Those cosines come from the word vectors the simulator loads; a phone
    /// with the assets uses the contextual embedder, which the eval cannot
    /// measure, so the embedding plays no part until it can be calibrated
    /// on that embedder.
    static let embeddingGate: Double = 0

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

        /// Map the four flags onto a router tier. Only the axes Apple
        /// Intelligence can't serve on the device move a turn off it; once one
        /// has, a tool need counts toward Deep like any other flag.
        var requiredTier: SmartProviderRouter.Tier {
            let offDevice = [needsWeb, needsHistoricalDepth, needsSpeculation].filter { $0 }.count
            guard offDevice > 0 else { return .quick }
            return offDevice + (needsTools ? 1 : 0) >= 2 ? .deep : .auto
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
    /// Stateless; the caller (`SmartProviderRouter`) layers stickiness.
    ///
    /// A message `MedicalQueryGuard` refuses is answered on the device
    /// before any routing, so it raises no flag. Otherwise the phrase
    /// patterns of `CapabilityMarkers` raise the flags, in English and the
    /// languages the app ships, and a statement raises none.
    ///
    /// For English text with an embedding, a flag also needs its prototype
    /// centroid's cosine to reach `embeddingGate`, which drops a marker
    /// matched by shared domain vocabulary. The gate is calibrated on the
    /// eval's tuning split (`RouterEvalTests.testTheEmbeddingGateIsCalibratedOnTheTuningSplit`);
    /// at 0 it is off. Text in another language is never gated: the
    /// embedder is English.
    func classify(_ message: String) -> Requirement {
        classify(message, embeddingGate: Self.embeddingGate)
    }

    /// `classify(_:)` with the embedding settings given, for the calibration.
    /// `embeddingRaise` above 0 lets an English axis with no marker fire
    /// when its cosine reaches it.
    func classify(_ message: String, embeddingGate gate: Double, embeddingRaise raise: Double = 0) -> Requirement {
        guard MedicalQueryGuard.classify(message) == nil else { return .none }
        let markers = CapabilityMarkers.requirement(of: message)
        let text = CapabilityMarkers.normalized(message)
        guard gate > 0 || raise > 0, !CapabilityMarkers.isStatement(text), Self.isLikelyEnglish(text),
              let scores = embeddingClassify(text) else { return markers }
        let decide = { (marked: Bool, axis: Axis) -> Bool in
            let score = scores[axis, default: 0]
            return marked ? score >= gate : raise > 0 && score >= raise
        }
        return Requirement(
            needsTools: decide(markers.needsTools, .tools),
            needsWeb: decide(markers.needsWeb, .web),
            needsHistoricalDepth: decide(markers.needsHistoricalDepth, .historicalDepth),
            needsSpeculation: decide(markers.needsSpeculation, .speculation)
        )
    }

    /// True unless the language recognizer is confident the text is in
    /// another language. Input under three words stays on the English
    /// keyword path: the recognizer reads a bare "hrv?" as Croatian.
    private static func isLikelyEnglish(_ text: String) -> Bool {
        guard text.split(whereSeparator: \.isWhitespace).count >= 3 else { return true }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let top = recognizer.languageHypotheses(withMaximum: 1).first else { return true }
        return top.key == .english || top.value < 0.6
    }

    // MARK: - Embedding path

    /// Cached prototype centroids — computed once on first
    /// classification.
    private lazy var prototypeCentroids: [Axis: [Double]] = {
        var out: [Axis: [Double]] = [:]
        for (axis, phrases) in Self.prototypes {
            out[axis] = EmbeddingCentroid.mean(of: phrases.compactMap { embedder.embed($0) })
        }
        return out
    }()

    private func embeddingClassify(_ text: String) -> [Axis: Double]? {
        guard let q = embedder.embed(text) else { return nil }
        let centroids = prototypeCentroids
        // A query and centroids from different embedders cannot be compared
        // (cosine would read 0 on every axis); the keyword result stands.
        guard !centroids.isEmpty, centroids.values.allSatisfy({ $0.count == q.count }) else { return nil }
        var scores: [Axis: Double] = [:]
        for (axis, centroid) in centroids {
            scores[axis] = cosineSimilarity(q, centroid)
        }
        return scores
    }

    // MARK: - Prototype phrases per axis
    //
    // Hand-curated; calibrate the threshold against a held-out eval
    // set after collecting real voice transcripts.
    // Tests in `CapabilityClassifierTests` exercise the contract.

    /// Internal so the eval can check its utterances are not these phrases.
    nonisolated static let prototypes: [Axis: [String]] = [
        .tools: [
            "Send the recovery summary off by email.",
            "Send me yesterday's recovery summary in an email.",
            "Lead me back to where I parked the car.",
            "Give me turn-by-turn directions to the hospital.",
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
            "Is this month better or worse than the one before it?",
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
