import Foundation
import NaturalLanguage

/// Mean-pooled English sentence embeddings, for `CapabilityClassifier`'s
/// prototype matching.
///
/// A service of its own, so the dependencies run one way: the router holds
/// the classifier, and the classifier holds this. Nothing here reaches back
/// into either, and the embedding assets load once, on first use.
@MainActor
final class SentenceEmbedder {
    /// Lazily-initialised NL contextual embedder. Created on first use
    /// (~50ms cold) and cached for the app lifetime. Nil on devices that
    /// cannot provide one or whose assets have not downloaded yet; `embed`
    /// then uses the word-vector embedder for the whole launch.
    private lazy var contextualEmbedder: NLContextualEmbedding? = Self.loadContextualEmbedder()

    /// Create and load the contextual embedder, or nil when this device cannot
    /// provide one.
    private static func loadContextualEmbedder() -> NLContextualEmbedding? {
        guard let embedder = NLContextualEmbedding(language: .english) else { return nil }
        // requestAssets() is async (downloads from CDN). If assets aren't yet
        // available, kick off the request and degrade to the word-embedding
        // fallback for this app launch; the next launch picks up the
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

    /// Mean-pooled sentence embedding, always in one vector space per launch:
    /// the contextual embedder's when it exists, else the word vectors'. A
    /// text the contextual embedder fails on gets nil, not a word-vector
    /// embedding: vectors of the two spaces differ in length and meaning, so
    /// mixing them would corrupt a prototype centroid or zero a query's
    /// similarity. `CapabilityClassifier` treats nil as "no embedding".
    func embed(_ text: String) -> [Double]? {
        guard contextualEmbedder != nil else { return wordVectorEmbedding(text) }
        return contextualEmbedding(text)
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
}
