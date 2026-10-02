import Foundation
import os

/// Persistent cross-session memory for the AI Assistant.
///
/// Each fact is a short text snippet the user (or the model, when allowed)
/// flagged as worth remembering across conversations: ongoing health context,
/// training goals, preferences ("explain things briefly", "I'm a clinician,
/// don't dumb it down"), recent events ("I had a cold last week").
///
/// Facts are injected into the system prompt of every send so the assistant
/// always knows about them — Apple, Claude, GPT, Gemini, Grok, DeepSeek alike.
///
/// Stored as JSON in the App Group. User-editable in Settings → Flo.
@Observable
@MainActor
final class UserFactsStore {
    nonisolated static let shared = UserFactsStore()

    struct Fact: Codable, Identifiable, Hashable {
        let id: UUID
        var text: String
        let createdAt: Date

        init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
            self.id = id
            self.text = text
            self.createdAt = createdAt
        }
    }

    private(set) var facts: [Fact] {
        didSet {
            let snapshot = facts
            factsBox.withLock { $0 = snapshot }
        }
    }

    /// Lock-backed mirror of `facts` for readers off the main actor (the
    /// assistant's fact resolvers run on background tasks).
    @ObservationIgnored private let factsBox: OSAllocatedUnfairLock<[Fact]>

    nonisolated var factsSnapshot: [Fact] { factsBox.withLock { $0 } }

    /// When true, the AssistantViewModel runs an extraction pass after each
    /// completed response and adds proposed facts automatically. Off by default —
    /// users prefer explicit control over health-adjacent memory.
    var autoExtractEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoExtractEnabled, forKey: Self.autoExtractKey)
        }
    }

    nonisolated private static let autoExtractKey = "assistant.autoExtractFacts"

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.chrissharp.flowrecovery.assistant.facts", qos: .utility)

    nonisolated private init() {
        let fm = FileManager.default
        let baseURL = Self.storageDirectory(fm)
        _ = attempt("UserFactsStore.create") { try fm.createDirectory(at: baseURL, withIntermediateDirectories: true) }
        fileURL = baseURL.appendingPathComponent("user_facts.json")
        unreadableOnDisk = Self.isUnreadable(fileURL)
        let loaded = Self.loadFacts(at: fileURL)
        _facts = loaded
        factsBox = OSAllocatedUnfairLock(initialState: loaded)
        _autoExtractEnabled = UserDefaults.standard.bool(forKey: Self.autoExtractKey)
    }

    /// App group if available (the widget reads the same file), else Documents,
    /// else the temporary directory.
    nonisolated private static func storageDirectory(_ fm: FileManager) -> URL {
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) {
            return group.appendingPathComponent("Assistant", isDirectory: true)
        }
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            return docs.appendingPathComponent("Assistant", isDirectory: true)
        }
        return fm.temporaryDirectory.appendingPathComponent("Assistant", isDirectory: true)
    }

    /// Initial load (sync, but tiny file). Missing file is normal; a decode
    /// failure means the user's remembered facts are being silently dropped
    /// — log it rather than swallowing.
    ///
    /// Dedup + cap on load so a file bloated by an older build is cleaned in
    /// memory immediately — the prompt is clean THIS launch. The cleaned set is
    /// rewritten to disk on the next add/remove (persist() can't run mid-init).
    nonisolated private static func loadFacts(at url: URL) -> [Fact] {
        guard let data = try? Data(contentsOf: url) else {
            if FileManager.default.fileExists(atPath: url.path) {
                debugLog("[UserFactsStore] facts present but unreadable (device locked?) — writes will merge, not overwrite", level: .warning)
            }
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return dedupedAndCapped(try decoder.decode([Fact].self, from: data))
        } catch {
            debugLog("[UserFactsStore] load: decode failed, dropping remembered facts: \(error)", level: .error)
            return []
        }
    }

    /// Testing-only initializer that lets a test inject its own backing file
    /// URL, so UserFactsStoreTests can exercise add/remove/clear/persist
    /// without touching the singleton's App Group container.
    nonisolated init(fileURL: URL) {
        self.fileURL = fileURL
        let parent = fileURL.deletingLastPathComponent()
        _ = attempt("UserFactsStore.create") { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        unreadableOnDisk = Self.isUnreadable(fileURL)

        // Missing file is normal (first launch). A file that exists and does not
        // decode is the user's saved facts being dropped, which they would
        // otherwise discover only by noticing the assistant had forgotten them.
        let loaded = Self.loadFacts(at: fileURL)
        _facts = loaded
        factsBox = OSAllocatedUnfairLock(initialState: loaded)
        _autoExtractEnabled = UserDefaults.standard.bool(forKey: Self.autoExtractKey)
    }

    // MARK: - Mutations (main-actor isolated)

    /// Add a new fact unless an identical one already exists.
    ///
    /// Capped at `maxFacts` (FIFO prune of the oldest). Every fact rides
    /// in the system prompt of every AI turn, so unbounded growth
    /// silently inflates prompt token cost over time. 25 fits ~250
    /// tokens — enough to remember a useful profile without dominating
    /// the static prefix.
    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = Self.normalizedKey(trimmed)
        // Dedup on the NORMALIZED key so punctuation-/case-only twins
        // ("…right now" vs "…right now.") collapse to one fact instead of both
        // riding in every prompt — that was ~20% of the memory-block bloat.
        guard !key.isEmpty, !facts.contains(where: { Self.normalizedKey($0.text) == key }) else { return }
        facts.append(Fact(text: trimmed))
        if facts.count > Self.maxFacts {
            facts.removeFirst(facts.count - Self.maxFacts)
        }
        persist()
    }

    nonisolated private static let maxFacts = 25

    /// Case- and trailing-punctuation-insensitive dedup key. Strips terminal
    /// ". , ; : ! ? …" and surrounding whitespace so the same sentence with a
    /// different terminal punctuation counts as one fact.
    nonisolated static func normalizedKey(_ s: String) -> String {
        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?…"))
        return s.lowercased().trimmingCharacters(in: trimSet)
    }

    /// Dedup (newest phrasing of a duplicate wins) + cap to `maxFacts`.
    /// Applied on LOAD so a file bloated by an older build gets cleaned on the
    /// next launch, not only when the next `add` happens to prune it.
    nonisolated static func dedupedAndCapped(_ input: [Fact]) -> [Fact] {
        var seen = Set<String>()
        var result: [Fact] = []
        for fact in input.reversed() {
            let key = normalizedKey(fact.text)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(fact)
        }
        result.reverse()
        if result.count > maxFacts { result.removeFirst(result.count - maxFacts) }
        return result
    }

    func remove(_ id: UUID) {
        facts.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        facts = []
        // Clearing is the one write that must not wait to read what it replaces.
        unreadableOnDisk = false
        persist()
    }

    /// Renders the facts as a system-prompt block. Empty string when no facts.
    /// Returns something like:
    ///   "Things to remember about this user (set by them earlier):\n• I'm training for a marathon\n• I had a cold last week"
    func systemPromptBlock() -> String {
        guard !facts.isEmpty else { return "" }
        var lines = ["Things to remember about this user (they set these in earlier conversations or via the Remember action):"]
        for fact in facts {
            lines.append("• \(fact.text)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    /// The file is written with complete protection, so it cannot be read while
    /// the phone is locked, and the store then starts empty. A fact added in
    /// that state was written over every fact already saved. Until the disk has
    /// been read, a write first folds what is on disk back in, and holds off
    /// entirely while it still cannot be read.
    @ObservationIgnored private var unreadableOnDisk: Bool

    nonisolated private static func isUnreadable(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            && attempt("UserFactsStore.probe", { try Data(contentsOf: url) }) == nil
    }

    /// Once protected data is available: fold the saved facts back in and
    /// write out anything added while they could not be read.
    func recoverAfterUnlock() {
        guard unreadableOnDisk else { return }
        persist()
    }

    /// Reads the disk back in once it can be read. Called before any write.
    private func reloadIfUnreadable() {
        guard unreadableOnDisk, let data = attempt("UserFactsStore.reload", { try Data(contentsOf: fileURL) }) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let onDisk = attempt("UserFactsStore.decodeReload") { try decoder.decode([Fact].self, from: data) } ?? []
        unreadableOnDisk = false
        let known = Set(facts.map(\.id))
        facts = Self.dedupedAndCapped(onDisk.filter { !known.contains($0.id) } + facts)
    }

    private func persist() {
        reloadIfUnreadable()
        guard !unreadableOnDisk else {
            debugLog("[UserFactsStore] write held — saved facts still unreadable", level: .warning)
            return
        }
        let snapshot = facts
        queue.async { [fileURL] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            guard let data = attempt("userFactsStore.encode", { try encoder.encode(snapshot) }) else { return }
            // Holds ongoing health context injected into every prompt; protect
            // at rest (readable only while unlocked), matching ConversationStore.
            do {
                try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            } catch {
                debugLog("[UserFactsStore] persist: write failed, fact update may be lost: \(error)", level: .error)
            }
        }
    }
}
