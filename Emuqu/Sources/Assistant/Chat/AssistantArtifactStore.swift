import Foundation

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
/// Like all app data it is removed when the app is deleted.
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
    func forgetAfterPurge() {
        artifacts = []
    }

    private let fileURL: URL

    /// True when `load()` found a file it could not decode. Blocks `persist()`
    /// so a corrupt or newer-schema file is preserved rather than overwritten.
    private var loadFailed = false
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
        load()
    }

    // MARK: - CRUD

    @discardableResult
    func add(kind: Kind, body: String) -> Artifact {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let artifact = Artifact(kind: kind, body: trimmed)
        artifacts.append(artifact)
        persist()
        return artifact
    }

    @discardableResult
    func updateStatus(id: UUID, status: Status) -> Artifact? {
        guard let idx = artifacts.firstIndex(where: { $0.id == id }) else { return nil }
        artifacts[idx].status = status
        artifacts[idx].updatedAt = Date()
        persist()
        return artifacts[idx]
    }

    @discardableResult
    func updateBody(id: UUID, body: String) -> Artifact? {
        guard let idx = artifacts.firstIndex(where: { $0.id == id }) else { return nil }
        artifacts[idx].body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        artifacts[idx].updatedAt = Date()
        persist()
        return artifacts[idx]
    }

    func remove(id: UUID) {
        artifacts.removeAll { $0.id == id }
        persist()
    }

    func removeAll(kind: Kind? = nil) {
        if let kind {
            artifacts.removeAll { $0.kind == kind }
        } else {
            artifacts.removeAll()
        }
        persist()
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

    var counts: [Kind: Int] {
        var out: [Kind: Int] = [:]
        for k in Kind.allCases {
            out[k] = artifacts.filter { $0.kind == k && $0.status == .open }.count
        }
        return out
    }

    // MARK: - Persistence

    /// Must not catch EVERY error as "First run — file doesn't exist yet",
    /// `DecodingError` included. Doing so means a
    /// corrupt write, a truncated file, or a future schema change to `Artifact`
    /// leaves `artifacts` empty, and the next `add` / `updateStatus` /
    /// `updateBody` / delete calls `persist()`, which atomically overwrites the
    /// file with the empty snapshot. The user's artifact history is gone,
    /// silently, with nothing logged.
    ///
    /// `SavedRouteStore` already had the right shape 200 lines away: mark the
    /// load as failed and refuse to save rather than clobber a recoverable
    /// file. Same pattern here.
    private func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            artifacts = try JSONDecoder().decode([Artifact].self, from: data)
            loadFailed = false
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // Genuine first run. The only case the original comment described.
            loadFailed = false
        } catch {
            loadFailed = true
            debugLog(
                "[AssistantArtifactStore] artifacts.json present but unreadable — keeping in-memory list and blocking saves so the file is not clobbered: \(error)",
                level: .error
            )
        }
    }

    private func persist() {
        // Never overwrite a store file we could not decode — that destroys a
        // recoverable library. Mirrors `SavedRouteStore.save()`.
        guard !loadFailed else {
            debugLog("[AssistantArtifactStore] skipping save — prior load failed; refusing to clobber the on-disk file", level: .warning)
            return
        }
        let snapshot = artifacts
        let url = fileURL
        queue.async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                // Artifacts can quote health-adjacent context; protect at rest
                // (readable only while unlocked), matching ConversationStore.
                try data.write(to: url, options: [.atomic, .completeFileProtection])
            } catch {
                debugLog("[AssistantArtifactStore] persist failed: \(error)", level: .warning)
            }
        }
    }
}
