import Foundation
import UIKit

/// Two-tier memory, long-term layer.
/// Holds **persistent conversational artifacts** that
/// must outlive the chat session and survive context-window pruning:
///
///   • Bug list — open + resolved
///   • Feature requests — open + planned + shipped
///   • Decisions — "we decided X because Y on date Z"
///   • Notes — anything else worth keeping (preferences, philosophy
///     conversations, methodology choices)
///
/// **Why this exists:** the chat transcript gets pruned when the
/// conversation grows past the model's token budget. The auto-summary
/// (`AssistantViewModel.priorSummary`) preserves the *gist* of dropped
/// turns, but specific structured items — bug list bullets, decision
/// records, feature backlogs — get blurred to one-line "we discussed
/// some bugs" summaries by the LLM. This store sidesteps that by
/// holding artifacts as discrete, addressable items.
///
/// **Two-tier mental model.** Short-term = `AssistantViewModel.turns`
/// (current session only). Long-term = `UserFactsStore` (user-asserted
/// facts about themselves, e.g. "prepping for marathon") + this store
/// (running record of what we've actually been working on together).
/// The AI accesses both via fact tools (`assistant.memory.*` for facts,
/// `assistant.artifacts.*` for this).
///
/// **Storage:** JSON file in the App Group container (Documents when the
/// group is unavailable), written atomically with complete file protection.
/// Like all app data it is removed when the app is deleted. A file that
/// cannot be read (the phone has not been unlocked yet) holds saves and is
/// read again before the next change and on unlock; one that does not
/// decode is set aside (`UndecodableFile`) before the next save; a failed
/// write is retried on unlock.
@Observable
@MainActor
final class AssistantArtifactStore {
    static let shared = AssistantArtifactStore()

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case bug
        case feature
        case decision
        case note

        var id: String { rawValue }
    }

    enum Status: String, Codable, CaseIterable {
        case open
        case resolved
        case shipped     // for features
        case archived    // user dismissed without resolving
    }

    struct Artifact: Codable, Identifiable, Equatable {
        let id: UUID
        let kind: Kind
        var status: Status
        var body: String
        let createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            kind: Kind,
            status: Status = .open,
            body: String,
            createdAt: Date = Date(),
            updatedAt: Date? = nil
        ) {
            self.id = id
            self.kind = kind
            self.status = status
            self.body = body
            self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
        }
    }

    private(set) var artifacts: [Artifact] = []

    /// Delete All My Data removed the file; this drops the in-memory copy so
    /// nothing reads it afterwards and the next save cannot write it back.
    /// The read and write flags reset too: there is no file left to protect
    /// or retry, and a stale flag would hold every later save.
    func forgetAfterPurge() {
        artifacts = []
        diskState = .readable
        writePending = false
    }

    private let fileURL: URL

    /// What the last read of the file found. Saves are held unless it is
    /// `.readable`, so the user's artifacts on disk are never replaced by the
    /// partial in-memory list.
    private enum DiskState { case readable, unreadable, undecodable }
    private var diskState = DiskState.readable
    /// A save was held or failed and has not been written yet.
    private var writePending = false
    private let unlockObservers = NotificationTokens()
    private let queue = DispatchQueue(label: "com.chrissharp.flowrecovery.assistant.artifacts", qos: .userInitiated)

    private init() {
        let fm = FileManager.default
        let dir: URL = {
            if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) {
                return group.appendingPathComponent("Assistant", isDirectory: true)
            }
            return fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Assistant", isDirectory: true)
        }()
        _ = attempt("AssistantArtifactStore.create") { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        fileURL = dir.appendingPathComponent("artifacts.json")
        apply(readDisk())
        wireRecoveryOnUnlock()
    }

    /// Unlock (and becoming active, since a suspended app can miss the
    /// unlock notification) runs `recoverAfterUnlock()` on the main actor.
    private func wireRecoveryOnUnlock() {
        for name in [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification] {
            unlockObservers.add(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.scheduleRecoveryAfterUnlock()
            })
        }
    }

    nonisolated private func scheduleRecoveryAfterUnlock() {
        Task { @MainActor [weak self] in
            self?.recoverAfterUnlock()
        }
    }

    /// Reads a file that could not be read before, then writes a held or
    /// failed save.
    func recoverAfterUnlock() {
        if diskState == .unreadable { apply(readDisk()) }
        if writePending { persist() }
    }

    // MARK: - CRUD

    @discardableResult
    func add(kind: Kind, body: String) -> Artifact {
        reloadIfBlocked()
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let artifact = Artifact(kind: kind, body: trimmed)
        artifacts.append(artifact)
        persist()
        return artifact
    }

    @discardableResult
    func updateStatus(id: UUID, status: Status) -> Artifact? {
        reloadIfBlocked()
        guard let idx = artifacts.firstIndex(where: { $0.id == id }) else { return nil }
        artifacts[idx].status = status
        artifacts[idx].updatedAt = Date()
        persist()
        return artifacts[idx]
    }

    // MARK: - Queries

    func list(kind: Kind? = nil, includeResolved: Bool = false) -> [Artifact] {
        var out = artifacts
        if let kind { out = out.filter { $0.kind == kind } }
        if !includeResolved {
            out = out.filter { $0.status == .open }
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Persistence

    /// Must not catch EVERY error as "First run — file doesn't exist yet",
    /// `DecodingError` included. Doing so means a
    /// corrupt write, a truncated file, or a future schema change to `Artifact`
    /// leaves `artifacts` empty, and the next `add` / `updateStatus` calls
    /// `persist()`, which atomically overwrites the file with the empty
    /// snapshot. The user's artifact history is gone, silently, with nothing
    /// logged. A missing file is the only first run; a file that cannot be
    /// read and one that does not decode are told apart.
    private enum DiskRead {
        case missing, unreadable, undecodable
        case artifacts([Artifact])
    }

    private func readDisk() -> DiskRead {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            debugLog("[AssistantArtifactStore] artifacts.json present but unreadable (device locked?) — holding saves until it can be read: \(error)", level: .warning)
            return .unreadable
        }
        do {
            return .artifacts(try JSONDecoder().decode([Artifact].self, from: data))
        } catch {
            debugLog("[AssistantArtifactStore] artifacts.json does not decode — it is set aside before the next save: \(error)", level: .error)
            return .undecodable
        }
    }

    /// Folds a read into memory. Artifacts on disk that the list lacks are
    /// added, so a change made while the file could not be read is kept
    /// alongside everything saved before it.
    private func apply(_ read: DiskRead) {
        switch read {
        case .missing: diskState = .readable
        case .unreadable: diskState = .unreadable
        case .undecodable: diskState = .undecodable
        case let .artifacts(onDisk):
            let known = Set(artifacts.map(\.id))
            artifacts = onDisk.filter { !known.contains($0.id) } + artifacts
            diskState = .readable
        }
    }

    /// Before any change: read again a file that could not be read, and set
    /// aside one that does not decode (kept, not deleted) so saving resumes.
    private func reloadIfBlocked() {
        if diskState == .unreadable { apply(readDisk()) }
        if diskState == .undecodable, UndecodableFile.setAside(fileURL, caller: "AssistantArtifactStore") {
            diskState = .readable
        }
    }

    private func persist() {
        reloadIfBlocked()
        guard diskState == .readable else {
            writePending = true
            debugLog("[AssistantArtifactStore] save held — artifacts.json not readable yet; retried on unlock", level: .warning)
            return
        }
        writePending = false
        let snapshot = artifacts
        let url = fileURL
        queue.async {
            guard !Self.write(snapshot, to: url) else { return }
            Task { @MainActor in self.writePending = true }
        }
    }

    /// False when the write failed. The directory is created first: Delete
    /// All My Data removes it under a running store, and only init created it.
    nonisolated private static func write(_ snapshot: [Artifact], to url: URL) -> Bool {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Artifacts can quote health-adjacent context; protect at rest
            // (readable only while unlocked), matching ConversationStore.
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            debugLog("[AssistantArtifactStore] persist failed, retried on unlock or the next change: \(error)", level: .warning)
            return false
        }
    }
}
