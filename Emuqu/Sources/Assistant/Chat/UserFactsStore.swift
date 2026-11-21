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
/// Stored as sealed JSON in the App Group (`AssistantStoreFile`).
/// User-editable in Settings → Flo.
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

    /// True while a copy of an undecodable facts file (`user_facts.undecodable-*`)
    /// is still beside the live one, or the folder cannot be listed to tell.
    /// Those copies are never read back, but they are the user's notes.
    private(set) var setAsideCopiesRemain: Bool

    /// Whether anything is stored that Forget everything would erase: a fact,
    /// or a set-aside copy of an older file.
    var hasAnythingToForget: Bool { !facts.isEmpty || setAsideCopiesRemain }

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
        _setAsideCopiesRemain = AssistantStoreFile.hasSetAsideCopies(of: fileURL, caller: "UserFactsStore")
        _autoExtractEnabled = UserDefaults.standard.bool(forKey: Self.autoExtractKey)
    }

    /// App group if available, else Documents, else the temporary directory.
    nonisolated private static func storageDirectory(_ fm: FileManager) -> URL {
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) {
            return group.appendingPathComponent("Assistant", isDirectory: true)
        }
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            return docs.appendingPathComponent("Assistant", isDirectory: true)
        }
        return fm.temporaryDirectory.appendingPathComponent("Assistant", isDirectory: true)
    }

    /// Initial load (sync, but tiny file). A missing file is normal; a file
    /// that cannot be read, opened or decoded loads as empty, and
    /// `unreadableOnDisk` then holds every write so the file is preserved
    /// rather than overwritten with what this launch could read.
    ///
    /// Dedup + cap on load so a file bloated by an older build is cleaned in
    /// memory immediately — the prompt is clean THIS launch. The cleaned set is
    /// rewritten to disk on the next add/remove (persist() can't run mid-init).
    nonisolated private static func loadFacts(at url: URL) -> [Fact] {
        guard case let .json(data) = AssistantStoreFile.read(url, caller: "UserFactsStore"),
              let decoded = decodedFacts(data)
        else { return [] }
        return dedupedAndCapped(decoded)
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
        _setAsideCopiesRemain = AssistantStoreFile.hasSetAsideCopies(of: fileURL, caller: "UserFactsStore")
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

    nonisolated static let maxFacts = 25

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

    /// Removes the fact with `id` and writes the rest at once, dropping every
    /// set-aside copy (which can hold the same fact). True once that is on
    /// disk. False, with `facts` unchanged, while the saved facts cannot be
    /// read or when the write or a copy's removal failed: the fact is still
    /// stored.
    @discardableResult
    func remove(_ id: UUID) -> Bool {
        reloadIfUnreadable()
        guard !unreadableOnDisk else { return false }
        let remaining = facts.filter { $0.id != id }
        guard writeNow(remaining) else { return false }
        facts = remaining
        return true
    }

    /// Erases every fact, every set-aside copy and the copy
    /// `clearKeepingBackup()` kept. This is the path for a wipe the user made
    /// themselves (Settings, Delete All My Data), so nothing is left behind.
    ///
    /// The copies go first, then the file, on the queue after any write
    /// already queued, so an earlier write cannot land afterwards. Removal
    /// needs no read, so a file locked or undecodable is erased too. True
    /// when none of them is left; false leaves `facts` as they were, since
    /// they are still stored.
    @discardableResult
    func clear() -> Bool {
        clearedBackup = []
        let url = fileURL
        let erased = queue.sync { AssistantStoreFile.erase(url, caller: "UserFactsStore") }
        setAsideCopiesRemain = AssistantStoreFile.hasSetAsideCopies(of: url, caller: "UserFactsStore")
        guard erased else { return false }
        facts = []
        unreadableOnDisk = false
        writePending = false
        return true
    }

    /// Drops the set-aside copies and writes `snapshot`, on the queue after
    /// any write already queued. True when both are done.
    private func writeNow(_ snapshot: [Fact]) -> Bool {
        let url = fileURL
        let done = queue.sync {
            AssistantStoreFile.eraseSetAsideCopies(of: url, caller: "UserFactsStore") && Self.write(snapshot, to: url)
        }
        setAsideCopiesRemain = AssistantStoreFile.hasSetAsideCopies(of: url, caller: "UserFactsStore")
        if done { writePending = false }
        return done
    }

    /// The facts the assistant's last memory wipe removed. Held in memory
    /// only, never written to disk, so it lasts until the app quits; enough
    /// to undo a wipe right after it, without keeping a second copy of
    /// health-adjacent notes at rest.
    @ObservationIgnored private(set) var clearedBackup: [Fact] = []

    /// Erases every fact like `clear()` but keeps them for `restoreCleared()`.
    /// Returns how many facts were erased, or nil when the erase failed, in
    /// which case every fact is still stored and in `facts`.
    func clearKeepingBackup() -> Int? {
        let previous = facts
        guard clear() else { return nil }
        clearedBackup = previous
        return previous.count
    }

    /// Puts back the facts the last `clearKeepingBackup()` erased, next to any
    /// saved since (deduped and capped as on load), and drops the copy.
    /// Returns how many facts came back.
    @discardableResult
    func restoreCleared() -> Int {
        guard !clearedBackup.isEmpty else { return 0 }
        let before = facts.count
        facts = Self.dedupedAndCapped(clearedBackup + facts)
        clearedBackup = []
        persist()
        return facts.count - before
    }

    /// The facts the file holds once every write already queued has run:
    /// empty when there is no file, nil when it cannot be read or decoded.
    /// Delete All My Data reads its result back with it.
    func persistedFacts() -> [Fact]? {
        let url = fileURL
        return queue.sync {
            switch AssistantStoreFile.read(url, caller: "UserFactsStore") {
            case .missing: return []
            case .unreadable, .undecodable: return nil
            case let .json(data): return Self.decodedFacts(data)
            }
        }
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

    /// The file cannot be read while the phone is locked, and the store then
    /// starts empty. A fact added in that state was written over every fact
    /// already saved. Until the disk has been read, a write first folds what
    /// is on disk back in, and holds off entirely while it still cannot be
    /// read. A file that reads but does not open or decode (truncated, written
    /// by a newer schema, a damaged seal) is moved aside, kept rather than
    /// deleted (`AssistantStoreFile.setAside`), before the next write, so it
    /// is never replaced by this launch's partial view and saving resumes;
    /// `clear()` erases regardless.
    @ObservationIgnored private var unreadableOnDisk: Bool

    /// Set when the last write failed (the key unavailable, or the
    /// directory was gone), so `recoverAfterUnlock()` writes the facts again
    /// instead of leaving the change only in memory.
    @ObservationIgnored private var writePending = false

    nonisolated private static func isUnreadable(_ url: URL) -> Bool {
        switch AssistantStoreFile.read(url, caller: "UserFactsStore") {
        case .missing: return false
        case .unreadable, .undecodable: return true
        case let .json(data): return decodedFacts(data) == nil
        }
    }

    nonisolated private static func decodedFacts(_ data: Data) -> [Fact]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return attempt("UserFactsStore.decode") { try decoder.decode([Fact].self, from: data) }
    }

    /// Once protected data is available: fold the saved facts back in and
    /// write out anything added while they could not be read, or whose
    /// write failed.
    func recoverAfterUnlock() {
        guard unreadableOnDisk || writePending else { return }
        persist()
    }

    /// Reads the disk back in once it can be read and decoded, or sets an
    /// undecodable file aside; a file gone since leaves nothing to protect.
    /// Called before any write.
    private func reloadIfUnreadable() {
        guard unreadableOnDisk else { return }
        switch AssistantStoreFile.read(fileURL, caller: "UserFactsStore") {
        case .missing: unreadableOnDisk = false
        case .unreadable: return
        case .undecodable: setAsideUndecodable()
        case let .json(data): adopt(data)
        }
    }

    /// Folds the facts on disk in with the ones in memory, or sets the file
    /// aside when it does not decode.
    private func adopt(_ data: Data) {
        guard let onDisk = Self.decodedFacts(data) else { return setAsideUndecodable() }
        unreadableOnDisk = false
        let known = Set(facts.map(\.id))
        facts = Self.dedupedAndCapped(onDisk.filter { !known.contains($0.id) } + facts)
    }

    /// Moves the undecodable file aside so writes resume; while it cannot be
    /// moved, writes stay held.
    private func setAsideUndecodable() {
        guard AssistantStoreFile.setAside(fileURL, caller: "UserFactsStore") else { return }
        unreadableOnDisk = false
        setAsideCopiesRemain = true
    }

    private func persist() {
        reloadIfUnreadable()
        guard !unreadableOnDisk else {
            debugLog("[UserFactsStore] write held — saved facts still unreadable", level: .warning)
            return
        }
        let snapshot = facts
        writePending = false
        queue.async { [fileURL] in
            guard !Self.write(snapshot, to: fileURL) else { return }
            Task { @MainActor in self.writePending = true }
        }
    }

    /// Encodes the facts and writes them sealed (`AssistantStoreFile.write`,
    /// which creates the directory Delete All My Data can remove under a
    /// running store); false when either step failed, leaving the previous
    /// file in place.
    nonisolated private static func write(_ facts: [Fact], to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = attempt("userFactsStore.encode", { try encoder.encode(facts) }) else { return false }
        return AssistantStoreFile.write(data, to: url, caller: "UserFactsStore")
    }
}
