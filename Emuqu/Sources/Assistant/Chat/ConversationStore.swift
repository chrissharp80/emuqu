import Foundation
import os
import UIKit

/// Persists the assistant's chat thread to a file in the App Group container.
///
/// A single rolling thread, cleared via the chat UI's "Clear" action.
/// Multi-thread history can layer on later without changing this file's shape.
///
/// The thread can quote HRV, heart rate, sleep and location, so the JSON is
/// sealed with `EncryptionManager` like the app's other health stores and
/// written with `NSFileProtectionCompleteUnlessOpen` (`AssistantStoreFile`):
/// the voice assistant can answer with the phone locked (a workout's voice
/// coach, a Watch voice tap), and that class lets the turn be written then,
/// while the file still cannot be read until the phone is unlocked.
/// `@unchecked Sendable`: every mutable field is read and written only on
/// `queue` (a serial DispatchQueue); see the comments on `latestTurns`. The one
/// exception, `unreadableOnDisk`, sits behind its own lock because `load()`
/// runs on the caller's thread.
final class ConversationStore: @unchecked Sendable {
    static let shared = ConversationStore()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.chrissharp.flowrecovery.assistant.conversationstore", qos: .utility)

    private init() {
        let fm = FileManager.default
        let baseURL: URL = {
            if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) {
                return group.appendingPathComponent("Assistant", isDirectory: true)
            }
            if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                return docs.appendingPathComponent("Assistant", isDirectory: true)
            }
            return fm.temporaryDirectory.appendingPathComponent("Assistant", isDirectory: true)
        }()
        _ = attempt("ConversationStore.create") { try fm.createDirectory(at: baseURL, withIntermediateDirectories: true) }
        fileURL = baseURL.appendingPathComponent("conversation.json")
        summaryURL = Self.summaryFileURL(beside: fileURL)
        saveDebounceMs = Self.defaultSaveDebounceMs
        wireRetryOnUnlock()
    }

    /// Testing-only initializer that lets a test inject its own backing file
    /// URL, so ConversationStoreTests can exercise save/load/clear without
    /// touching the singleton's App Group container.
    ///
    /// `saveDebounceMs` is injectable so tests don't have to
    /// wait out the production 750 ms coalescing window on every save —
    /// the singleton always uses `defaultSaveDebounceMs`.
    init(fileURL: URL, saveDebounceMs: Int = ConversationStore.defaultSaveDebounceMs) {
        self.fileURL = fileURL
        summaryURL = Self.summaryFileURL(beside: fileURL)
        self.saveDebounceMs = saveDebounceMs
        let parent = fileURL.deletingLastPathComponent()
        _ = attempt("ConversationStore.create") { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
    }

    // MARK: - API

    /// Synchronous load — used by `AssistantViewModel.init` where async
    /// isn't available. Not wrapped in `queue.sync`: writes are atomic, so a
    /// reader sees a whole file or none. ~10-50 KB, sub-ms.
    ///
    /// A missing file is normal (first launch). A file that can't be read
    /// (locked) or opened and decoded (truncated, newer schema) starts the
    /// chat empty and flags the file, so the next save does not write over
    /// the history this launch couldn't see: a locked file holds the save
    /// until unlock, an undecodable one is set aside first.
    func load() -> [ChatTurn] {
        switch AssistantStoreFile.read(fileURL, caller: "ConversationStore") {
        case .missing: return []
        case .unreadable, .undecodable: break
        case let .json(data):
            if let turns = Self.decodedTurns(data) { return turns }
        }
        unreadableOnDisk.withLock { $0 = true }
        debugLog("[ConversationStore] load: history unreadable or undecodable — starting empty and holding saves so the file is kept", level: .warning)
        return []
    }

    private static func decodedTurns(_ data: Data) -> [ChatTurn]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return attempt("conversationStore.decode") { try decoder.decode([ChatTurn].self, from: data) }
    }

    /// Coalesce rapid saves. Streaming responses fire
    /// `save` on every token (50-200x per response). Each save is
    /// a full JSON encode of the entire chat plus an atomic file
    /// write — even though it runs off-main, the queue gets
    /// swamped and competes for disk I/O / CPU with everything
    /// else (including the keyboard system). Coalescing caps it at
    /// one save per debounce window; the final save still happens
    /// because the trailing-edge asyncAfter fires after the burst ends.
    ///
    /// All access to `latestTurns` / `saveScheduled` happens on
    /// `queue` (a serial DispatchQueue), so we don't need explicit
    /// locks. `save` is dispatched ONTO the queue from the caller
    /// (typically MainActor); the encode + write also runs on the queue.
    func save(_ turns: [ChatTurn]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.latestTurns = turns
            if self.saveScheduled { return }
            self.saveScheduled = true
            self.queue.asyncAfter(deadline: .now() + .milliseconds(self.saveDebounceMs)) { [weak self] in
                self?.writeCoalescedSnapshot()
            }
        }
    }

    /// The trailing edge of the debounce.
    ///
    /// `clear()` resets `saveScheduled` to cancel a pending
    /// coalesced write. Without the guard the trailing fire would still run
    /// after a clear and re-create the (empty) file the user just deleted. The only
    /// writer that flips this false before the deadline is `clear()`, so
    /// skipping is exactly right.
    ///
    /// A save held because the history can't be read, or a save that fails
    /// to encode, seal or write, sets `writePending`; `retryHeldSave()` tries again once protected data
    /// is available or the app becomes active.
    private func writeCoalescedSnapshot() {
        guard saveScheduled else { return }
        saveScheduled = false
        guard let snapshot = snapshotSafeToWrite() else {
            writePending = true
            return
        }
        writePending = !write(snapshot)
    }

    /// Encodes, seals and writes the turns; false when any step failed (the
    /// key unavailable leaves the previous file as it was). The directory is
    /// created first: Delete All My Data removes it under a running store,
    /// and only init created it.
    private func write(_ turns: [ChatTurn]) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = attempt("conversationStore.encode", { try encoder.encode(turns) }) else { return false }
        return AssistantStoreFile.write(data, to: fileURL, caller: "ConversationStore")
    }

    /// Re-runs a held or failed save. Called when protected data becomes
    /// available or the app becomes active; a no-op when nothing is pending.
    func retryHeldSave() {
        queue.async { [weak self] in
            guard let self, self.writePending, !self.saveScheduled else { return }
            self.saveScheduled = true
            self.writeCoalescedSnapshot()
        }
    }

    /// Retries a held save once the history may be readable, for the
    /// lifetime of the shared store.
    private func wireRetryOnUnlock() {
        unlockObservers.observeProtectedDataMayBeAvailable { [weak self] in self?.retryHeldSave() }
    }

    private let unlockObservers = NotificationTokens()

    // MARK: - Summary

    /// The rolling summary of the turns that fell out of the send window
    /// (`AssistantViewModel.priorSummary`). It restates the conversation —
    /// the summarizer keeps injuries, illness and medications — so it is
    /// sealed and protected like the history, beside it.
    private let summaryURL: URL

    private struct StoredSummary: Codable {
        let text: String
    }

    private static func summaryFileURL(beside history: URL) -> URL {
        history.deletingLastPathComponent()
            .appendingPathComponent(history.deletingPathExtension().lastPathComponent + "_summary.json")
    }

    /// Where an older build left the summary in plain text, kept until the
    /// sealed file that replaces it is written.
    private struct LegacySummary {
        let defaults: UserDefaults
        let key: String
    }

    /// Queue-only. Set when a plain summary was found with no sealed file;
    /// cleared by the first successful `writeSummary`, which removes it.
    private var legacySummary: LegacySummary?

    /// The last `loadSummary` found the sealed file present but unreadable
    /// (the phone locked, or the seal key unavailable), and no summary has
    /// been written or cleared since.
    private let summaryUnreadable = OSAllocatedUnfairLock(initialState: false)

    /// True while the sealed summary holds text the caller could not read:
    /// `loadSummary` is worth calling again once the phone is unlocked.
    var summaryNeedsReload: Bool { summaryUnreadable.withLock { $0 } }

    /// The stored summary, or nil when there is none or it cannot be read
    /// now. A summary an older build left in plain text under `key` in
    /// `defaults` is moved into the sealed file when there is no file yet,
    /// and removed from `defaults` as soon as a sealed summary is written:
    /// by this move, or by a later `saveSummary` when this write fails (the
    /// seal key can be unavailable early in a background launch). When the
    /// sealed file is present, whether or not it can be read now, it holds
    /// a later summary than the plain one, so the plain one is removed.
    func loadSummary(migratingFrom defaults: UserDefaults, key: String) -> String? {
        let stored = AssistantStoreFile.read(summaryURL, caller: "ConversationStore")
        let unreadable: Bool
        if case .unreadable = stored { unreadable = true } else { unreadable = false }
        summaryUnreadable.withLock { $0 = unreadable }
        if case .missing = stored {
            guard let legacy = defaults.string(forKey: key) else { return nil }
            queue.sync {
                legacySummary = LegacySummary(defaults: defaults, key: key)
                _ = writeSummary(legacy)
            }
            return legacy
        }
        defaults.removeObject(forKey: key)
        guard case let .json(data) = stored else { return nil }
        return attempt("conversationStore.decodeSummary") { try JSONDecoder().decode(StoredSummary.self, from: data) }?.text
    }

    /// Seals and writes the summary on the store's queue, after any write
    /// already queued. A failed write is logged (`AssistantStoreFile.write`)
    /// and leaves the previous summary; the next summary is written afresh.
    func saveSummary(_ text: String) {
        queue.async { [weak self] in
            _ = self?.writeSummary(text)
        }
    }

    /// Queue-only. Once a summary is sealed on disk, the plain copy an older
    /// build left (`legacySummary`) is removed from its defaults, and the file
    /// no longer holds a summary the caller has not read.
    private func writeSummary(_ text: String) -> Bool {
        guard let data = attempt("conversationStore.encodeSummary", { try JSONEncoder().encode(StoredSummary(text: text)) }),
              AssistantStoreFile.write(data, to: summaryURL, caller: "ConversationStore") else { return false }
        summaryUnreadable.withLock { $0 = false }
        if let legacy = legacySummary {
            legacy.defaults.removeObject(forKey: legacy.key)
            legacySummary = nil
        }
        return true
    }

    // MARK: - Protected data

    /// The file cannot be read while the phone is locked, and `load()` then
    /// returns an empty history. When the assistant was first created in that
    /// state — a workout's voice coach, a Watch voice tap, with the phone
    /// locked — the next save wrote that empty history plus one new turn over
    /// the whole conversation. A file that reads but does not open or decode
    /// is flagged the same way; the next save moves it aside (kept, not
    /// deleted — see `AssistantStoreFile.setAside`) and then writes, so a
    /// schema change or truncated write is never overwritten and later turns
    /// are not held unsaved for good.
    private let unreadableOnDisk = OSAllocatedUnfairLock(initialState: false)

    /// True while the file on disk holds turns the caller has not seen.
    var needsReloadFromDisk: Bool { unreadableOnDisk.withLock { $0 } }

    /// `current` with every turn still on disk merged back in, or nil while the
    /// file stays unreadable.
    ///
    /// Only the view model's adoption (`acknowledging: true`) clears the flag.
    /// A save that merges on the queue leaves it set, because the view model's
    /// in-memory history still lacks those turns and its next save would
    /// otherwise write over them again.
    ///
    /// One merge runs at a time: the adoption runs on the main actor and a
    /// save's merge on `queue`, and two concurrent reads of an undecodable
    /// file would both try to set it aside, failing (and holding) the second.
    func mergedWithDisk(_ current: [ChatTurn], acknowledging: Bool = false) -> [ChatTurn]? {
        diskMerge.withLock { mergeWithDiskLocked(current, acknowledging: acknowledging) }
    }

    private let diskMerge = OSAllocatedUnfairLock()

    /// `mergedWithDisk`'s work; runs only while `diskMerge` is held.
    private func mergeWithDiskLocked(_ current: [ChatTurn], acknowledging: Bool) -> [ChatTurn]? {
        guard unreadableOnDisk.withLock({ $0 }) else { return current }
        switch AssistantStoreFile.read(fileURL, caller: "ConversationStore") {
        case .missing:
            unreadableOnDisk.withLock { $0 = false }
            return current
        case .unreadable: return nil
        case .undecodable: return setAsideUndecodable(keeping: current)
        case let .json(data): return merge(data, into: current, acknowledging: acknowledging)
        }
    }

    /// `current` with the turns in `data` it lacks, in time order; an
    /// undecodable `data` is set aside instead.
    private func merge(_ data: Data, into current: [ChatTurn], acknowledging: Bool) -> [ChatTurn]? {
        guard let onDisk = Self.decodedTurns(data) else { return setAsideUndecodable(keeping: current) }
        if acknowledging { unreadableOnDisk.withLock { $0 = false } }
        let known = Set(current.map(\.id))
        return (onDisk.filter { !known.contains($0.id) } + current).sorted { $0.createdAt < $1.createdAt }
    }

    /// Moves an undecodable history aside so saving can resume; `current`
    /// once it is moved, nil (the save stays held) when it could not be.
    private func setAsideUndecodable(keeping current: [ChatTurn]) -> [ChatTurn]? {
        guard AssistantStoreFile.setAside(fileURL, caller: "ConversationStore") else { return nil }
        unreadableOnDisk.withLock { $0 = false }
        return current
    }

    /// Nil while the history on disk is still unreadable (or undecodable and
    /// could not be moved aside): the save is held (`latestTurns` keeps it)
    /// rather than written over turns it cannot see.
    private func snapshotSafeToWrite() -> [ChatTurn]? {
        guard let merged = mergedWithDisk(latestTurns) else {
            debugLog("[ConversationStore] save held — history on disk still unreadable", level: .warning)
            return nil
        }
        latestTurns = merged
        return merged
    }

    /// Snapshot held by the coalescer. Read/written ONLY on `queue`.
    private var latestTurns: [ChatTurn] = []
    private var saveScheduled: Bool = false
    /// A save was held or failed and has not been written yet. Queue-only.
    private var writePending: Bool = false
    private let saveDebounceMs: Int
    static let defaultSaveDebounceMs: Int = 750

    /// Whether nothing of the history is left on disk once every change
    /// already queued (a `clear()` included) has run: true when the file is
    /// gone or decodes to an empty list, no set-aside copy remains and no
    /// summary is stored. A file that cannot be read or decoded counts as
    /// holding turns. Delete All My Data reads its result back with it.
    func isEmptyOnDisk() -> Bool {
        queue.sync {
            guard !AssistantStoreFile.hasSetAsideCopies(of: fileURL, caller: "ConversationStore"),
                  !FileManager.default.fileExists(atPath: summaryURL.path) else { return false }
            switch AssistantStoreFile.read(fileURL, caller: "ConversationStore") {
            case .missing: return true
            case .unreadable, .undecodable: return false
            case let .json(data): return Self.decodedTurns(data)?.isEmpty ?? false
            }
        }
    }

    /// Erases the history: every set-aside copy, then the file itself, on the
    /// queue after any write already queued. True when none of them is left.
    ///
    /// Only a complete erase resets the in-memory snapshot and cancels the
    /// pending coalesced write (`saveScheduled`), so the trailing fire cannot
    /// re-create the file. When something could not be removed the
    /// in-memory state is left as it was and false is returned: the caller
    /// still holds the turns and says the chat was not erased.
    ///
    /// The conversation summary (`saveSummary`) is erased with it.
    @discardableResult
    func clear() -> Bool {
        queue.sync {
            guard AssistantStoreFile.erase(summaryURL, caller: "ConversationStore"),
                  AssistantStoreFile.erase(fileURL, caller: "ConversationStore") else { return false }
            latestTurns = []
            saveScheduled = false
            writePending = false
            unreadableOnDisk.withLock { $0 = false }
            summaryUnreadable.withLock { $0 = false }
            return true
        }
    }
}

/// The on-disk side the assistant's stores share (`ConversationStore`,
/// `UserFactsStore`, `AssistantArtifactStore`). Each keeps one JSON file,
/// sealed with `EncryptionManager`, and a file that reads but does not open or
/// decode (a truncated write, a newer schema, a damaged seal) is renamed
/// beside the original as `<name>.undecodable-<unix time>.json` rather than
/// deleted, so nothing in it is lost and the store can save again.
enum AssistantStoreFile {
    /// What a read of a store's file found.
    enum Read {
        case missing
        /// Present but not readable now: file protection while the phone is
        /// locked, or the keychain holding the key unavailable.
        case unreadable
        /// Present, and can never be opened by this build: a damaged seal or
        /// a missing key.
        case undecodable
        /// The file's JSON: unsealed, or as written by a build that did not
        /// seal it (`EncryptionManager.openStoredJSON`).
        case json(Data)
    }

    static func read(_ url: URL, caller: String) -> Read {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            return opened(try Data(contentsOf: url), caller: caller)
        } catch {
            debugLog("[\(caller)] \(url.lastPathComponent) present but unreadable (device locked?): \(error)", level: .warning)
            return .unreadable
        }
    }

    /// A keychain failure is the phone's state and passes; any other failure
    /// to open the seal is the file's and does not.
    private static func opened(_ stored: Data, caller: String) -> Read {
        do {
            return try .json(JSONFileSeal.app.open(stored))
        } catch where JSONFileSeal.isKeyLocked(error) {
            debugLog("[\(caller)] key unavailable (\(error)); the file is read again later", level: .warning)
            return .unreadable
        } catch {
            debugLog("[\(caller)] stored file cannot be opened: \(error)", level: .error)
            return .undecodable
        }
    }

    /// Seals `json` and writes it atomically, creating the directory first
    /// (Delete All My Data removes it under a running store).
    ///
    /// `.completeFileProtectionUnlessOpen` lets the file be written while the
    /// phone is locked, which the voice assistant needs, and keeps it
    /// unreadable then. False when sealing or writing failed: the previous
    /// file is left as it was and nothing is written in plain text.
    static func write(_ json: Data, to url: URL, caller: String) -> Bool {
        do {
            let sealed = try JSONFileSeal.app.seal(json)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sealed.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            return true
        } catch {
            debugLog("[\(caller)] write failed; the previous file is kept and the write retried: \(error)", level: .error)
            return false
        }
    }

    /// Renames `url` to `<name>.undecodable-<unix time>.json`. True on success.
    static func setAside(_ url: URL, caller: String) -> Bool {
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingPathExtension().appendingPathExtension("undecodable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            debugLog("[\(caller)] undecodable file kept as \(aside.lastPathComponent); saving resumes", level: .error)
            return true
        } catch {
            debugLog("[\(caller)] could not set the undecodable file aside, saves stay held: \(error)", level: .error)
            return false
        }
    }

    /// Every copy `setAside` left beside `url`; nil when the directory exists
    /// but cannot be listed.
    static func setAsideCopies(of url: URL, caller: String) -> [URL]? {
        let directory = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let prefix = url.deletingPathExtension().lastPathComponent + ".undecodable-"
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
        } catch {
            debugLog("[\(caller)] could not list set-aside copies: \(error)", level: .error)
            return nil
        }
    }

    /// True when a set-aside copy of `url` exists, or when that cannot be
    /// ruled out because the directory cannot be listed.
    static func hasSetAsideCopies(of url: URL, caller: String) -> Bool {
        setAsideCopies(of: url, caller: caller)?.isEmpty != true
    }

    /// Removes every set-aside copy of `url`, trying each one. True when none
    /// is left.
    static func eraseSetAsideCopies(of url: URL, caller: String) -> Bool {
        guard let copies = setAsideCopies(of: url, caller: caller) else { return false }
        return !copies.map { remove($0, caller: caller) }.contains(false)
    }

    /// Removes the set-aside copies, then `url` itself; `url` is left in place
    /// when a copy could not be removed. True when nothing is left.
    static func erase(_ url: URL, caller: String) -> Bool {
        eraseSetAsideCopies(of: url, caller: caller) && remove(url, caller: caller)
    }

    /// True when `url` is gone, whether it was there or not.
    private static func remove(_ url: URL, caller: String) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            debugLog("[\(caller)] could not remove \(url.lastPathComponent): \(error)", level: .error)
            return false
        }
    }
}
