import Foundation
import os
import UIKit

/// Persists the assistant's chat thread to a JSON file in the App Group container.
///
/// MVP: a single rolling thread, cleared via the chat UI's "Clear" action.
/// Multi-thread history can layer on later without changing this file's shape.
///
/// Writes are protected at the strongest level
/// the iOS data-protection API supports — `NSFileProtectionComplete`.
/// The file is unreadable while the device is locked. Chat history (which
/// can quote HRV / heart rate / sleep / location) is not needed during
/// overnight recording (the assistant tab is not open while sleeping),
/// so the stricter protection level is the right trade-off vs the App
/// Group default (`UntilFirstUserAuthentication`).
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
        self.saveDebounceMs = saveDebounceMs
        let parent = fileURL.deletingLastPathComponent()
        _ = attempt("ConversationStore.create") { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
    }

    // MARK: - API

    /// Synchronous load — used by `AssistantViewModel.init` where async
    /// isn't available. Deliberately NOT wrapped in `queue.sync`
    /// (synchronous dispatch through a utility-priority serial queue):
    /// that doubles the cost on the caller's thread for no correctness
    /// benefit, because writes use atomic + complete-file-protection,
    /// so the OS guarantees readers see a fully-written file or
    /// nothing — no need for our own mutex on the read path. Direct
    /// read, ~10-50 KB JSON file, sub-ms.
    func load() -> [ChatTurn] {
        // Missing file is normal (first launch) — stay quiet. A file that
        // can't be read (locked) or decoded (truncated, newer schema) starts
        // the chat empty and flags the file, so saves are held instead of
        // writing over the history this launch couldn't see.
        guard let data = try? Data(contentsOf: fileURL) else {
            noteUnreadableIfPresent()
            return []
        }
        guard let turns = Self.decodedTurns(data) else {
            unreadableOnDisk.withLock { $0 = true }
            debugLog("[ConversationStore] load: decode failed — starting empty and holding saves so the file is kept", level: .error)
            return []
        }
        return turns
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
    /// A save held because the history can't be read, or a write that fails
    /// (the phone locked under complete file protection), sets `writePending`;
    /// `retryHeldSave()` tries again once protected data is available.
    private func writeCoalescedSnapshot() {
        guard saveScheduled else { return }
        saveScheduled = false
        guard let snapshot = snapshotSafeToWrite() else {
            writePending = true
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = attempt("conversationStore.encode", { try encoder.encode(snapshot) }) else { return }
        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            writePending = false
        } catch {
            writePending = true
            debugLog("[ConversationStore] save: write failed, retrying when the phone is unlocked: \(error)", level: .error)
        }
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

    /// Observes unlock (and becoming active, since a suspended app can miss
    /// the unlock notification) for the lifetime of the shared store.
    private func wireRetryOnUnlock() {
        for name in [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification] {
            unlockObservers.add(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.retryHeldSave()
            })
        }
    }

    private let unlockObservers = NotificationTokens()

    // MARK: - Protected data

    /// The file is written with complete protection, so it cannot be read while
    /// the phone is locked, and `load()` then returns an empty history. When the
    /// assistant was first created in that state — a workout's voice coach, a
    /// Watch voice tap, with the phone locked — the next save wrote that empty
    /// history plus one new turn over the whole conversation. A file that reads
    /// but does not decode is flagged the same way and stays flagged until
    /// `clear()`, so a schema change or truncated write can't be overwritten.
    private let unreadableOnDisk = OSAllocatedUnfairLock(initialState: false)

    /// True while the file on disk holds turns the caller has not seen.
    var needsReloadFromDisk: Bool { unreadableOnDisk.withLock { $0 } }

    private func noteUnreadableIfPresent() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        unreadableOnDisk.withLock { $0 = true }
        debugLog("[ConversationStore] history present but unreadable (device locked?) — saves will merge, not overwrite", level: .warning)
    }

    /// `current` with every turn still on disk merged back in, or nil while the
    /// file stays unreadable.
    ///
    /// Only the view model's adoption (`acknowledging: true`) clears the flag.
    /// A save that merges on the queue leaves it set, because the view model's
    /// in-memory history still lacks those turns and its next save would
    /// otherwise write over them again.
    func mergedWithDisk(_ current: [ChatTurn], acknowledging: Bool = false) -> [ChatTurn]? {
        guard unreadableOnDisk.withLock({ $0 }) else { return current }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            unreadableOnDisk.withLock { $0 = false }
            return current
        }
        guard let data = attempt("conversationStore.readBeforeWrite", { try Data(contentsOf: fileURL) }),
              let onDisk = Self.decodedTurns(data)
        else { return nil }
        if acknowledging { unreadableOnDisk.withLock { $0 = false } }
        let known = Set(current.map(\.id))
        return (onDisk.filter { !known.contains($0.id) } + current).sorted { $0.createdAt < $1.createdAt }
    }

    /// Nil while the history on disk is still unreadable or undecodable: the
    /// save is held (`latestTurns` keeps it) rather than written over turns it
    /// cannot see.
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

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            _ = attempt("ConversationStore.remove") { try FileManager.default.removeItem(at: self.fileURL) }
            // Reset the in-memory snapshot so any trailing save from
            // the coalescer doesn't resurrect the cleared chat.
            self.latestTurns = []
            self.saveScheduled = false
            self.writePending = false
            self.unreadableOnDisk.withLock { $0 = false }
        }
    }
}
