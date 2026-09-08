import CoreLocation
import Foundation

// The assistant-memory namespace, split out of
// `AppFactResolver+RoutesAndDevices.swift` to keep that file under the
// 1,000-line ceiling.

// MARK: - assistant.memory.* namespace (UserFactsStore)
//
// The cross-session "remember this" store the user curates from the AI
// chat. Exposed so the AI itself can answer "what do you remember about
// me?" instead of users having to dig through Settings.
struct AssistantMemoryNamespace: FactNamespaceResolver {
    let namespace = "assistant"

    var entries: [FactEntry] {
        [
            assistantMemoryCountEntry,
            assistantMemoryListEntry,
            assistantMemoryAutoExtractEnabledEntry,
            assistantMemoryAddEntry,
            assistantMemoryRemoveEntry,
            assistantMemoryClearEntry,
            assistantArtifactsCountEntry,
            assistantArtifactsListEntry,
            assistantArtifactsListAllEntry,
            assistantArtifactsAddEntry,
            assistantArtifactsUpdateStatusEntry,
            // MARK: contacts.* — address book the AI uses to resolve
            //
            assistantContactsListEntry,
            assistantContactsAddEntry,
            assistantContactsRemoveEntry,
            assistantEmailComposeEntry
        ]
    }

    private var assistantMemoryCountEntry: FactEntry {
        .fixed(
            key: "assistant.memory.count",
            description: "How many cross-session memory facts the user has saved for the AI to remember.",
            valueType: "Int"
        ) {
            .integer(AppDependencies.current.assistant.userFactsStore.factsSnapshot.count)
        }
    }

    private var assistantMemoryListEntry: FactEntry {
        .fixed(
            key: "assistant.memory.list",
            description: "Every cross-session memory fact, newest first. Each entry has id, text, created_at. These are also injected into every system prompt — listing them lets you transparently answer 'what do you remember about me?'.",
            valueType: "List"
        ) {
            let facts = AppDependencies.current.assistant.userFactsStore.factsSnapshot
            if facts.isEmpty {
                return .missing(reason: .notRecorded, detail: "user has no saved memory facts")
            }
            let dateFmt = ISO8601DateFormatter()
            dateFmt.formatOptions = [.withInternetDateTime]
            let sorted = facts.sorted { $0.createdAt > $1.createdAt }
            return .list(sorted.map { f in
                .record([
                    "id": .string(f.id.uuidString),
                    "text": .string(f.text),
                    "created_at": .string(dateFmt.string(from: f.createdAt))
                ])
            })
        }
    }

    private var assistantMemoryAutoExtractEnabledEntry: FactEntry {
        .fixed(
            key: "assistant.memory.auto_extract_enabled",
            description: "Whether the AI is allowed to auto-extract memory facts from conversation. When false, only user-tapped 'Remember this' adds entries.",
            valueType: "Bool"
        ) {
            .boolean(MainActor.assumeIsolated { AppDependencies.current.assistant.userFactsStore.autoExtractEnabled })
        }
    }

    // Bidirectional memory: the AI can WRITE to UserFactsStore,
    // not just read it. Otherwise the user has to tap "Remember
    // this" in chat or edit the facts list manually in Settings,
    // and any context the AI learns mid-conversation evaporates
    // when the chat ends.
    // These three actions close the loop. Mirror the existing
    // `assistant.artifacts.add` / `update_status` shape so
    // the toolset is consistent.
    private var assistantMemoryAddEntry: FactEntry {
        .action(
            key: "assistant.memory.add",
            description: Self.assistantMemoryAddDescription,
            parameters: [
                ActionParam("text", "The fact to remember about this user. Plain English. Keep it tight.")
            ]
        ) { args in
            guard let text = args["text"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return .missing(reason: .invalidParameter, detail: "text required")
            }
            MainActor.assumeIsolated {
                AppDependencies.current.assistant.userFactsStore.add(text)
            }
            return .record([
                "added": .boolean(true),
                "text": .string(text)
            ])
        }
    }

    private static let assistantMemoryAddDescription = """
    [ACTION] Save a short cross-session memory fact about this user. Use this when the user explicitly tells you to remember something OR when they share a durable fact that should outlive this conversation (training goal, ongoing \
    health context, hard preference, recurring constraint). EXAMPLES: 'remember I'm training for a marathon in October' → text='Training for a marathon in October 2026'. 'I had ablation surgery last year, take it easy with HR \
    cues' → text='Cardiac ablation surgery 2025; be cautious with HR-spike alerts'. Required param: text (the thing to remember, plain English, ≤160 chars; the system prompt re-injects this on every future send). De-duplicates \
    against existing facts case-insensitively.
    """

    private var assistantMemoryRemoveEntry: FactEntry {
        .action(
            key: "assistant.memory.remove",
            description: "[ACTION] Delete a single saved memory fact by id. Use when the user says 'forget that I'm training for a marathon' or 'remove the note about my surgery' — first call `assistant.memory.list` to find the matching id. Required param: id (UUID from the list tool).",
            parameters: [
                ActionParam("id", "Fact UUID (from assistant.memory.list).")
            ]
        ) { args in self.resolveAssistantMemoryRemove(args) }
    }

    private func resolveAssistantMemoryRemove(_ args: [String: String]) -> FactValue {
        guard let idStr = args["id"], let id = UUID(uuidString: idStr) else {
            return .missing(reason: .invalidParameter, detail: "id must be a UUID")
        }
        let removed: Bool = MainActor.assumeIsolated {
            let before = AppDependencies.current.assistant.userFactsStore.facts.contains(where: { $0.id == id })
            AppDependencies.current.assistant.userFactsStore.remove(id)
            return before
        }
        guard removed else {
            return .missing(reason: .notRecorded, detail: "no memory fact with id \(idStr)")
        }
        return .record([
            "removed": .boolean(true),
            "id": .string(idStr)
        ])
    }

    private var assistantMemoryClearEntry: FactEntry {
        .action(
            key: "assistant.memory.clear",
            description: """
            [ACTION] Wipe ALL saved memory facts about this user. Destructive; only invoke when the user explicitly says 'forget everything you know about me' / 'clear my memory' / 'wipe my facts'. Echo a clear confirmation ('Cleared \
            all N memory facts.') before assuming the user wanted this.
            """,
            parameters: []
        ) { _ in
            let cleared: Int = MainActor.assumeIsolated {
                let count = AppDependencies.current.assistant.userFactsStore.facts.count
                AppDependencies.current.assistant.userFactsStore.clear()
                return count
            }
            return .record([
                "cleared": .boolean(true),
                "count_before": .integer(cleared)
            ])
        }
    }

    // MARK: artifacts.* — long-term memory tier (Features 4–7
    // from the May 5 list). Bug list / feature requests /
    // decisions / notes that must outlive the chat-session
    // token window. Persisted in JSON under the App Group.
    // The AI uses these as its durable memory between
    // conversations: when context gets pruned mid-conversation,
    // these survive; when a new conversation starts, the AI
    // can call `assistant.artifacts.list` to know what's open.
    private var assistantArtifactsCountEntry: FactEntry {
        .fixed(
            key: "assistant.artifacts.count",
            description: "Total open artifacts across all kinds (bug, feature, decision, note). Cheap; call this first to gate the list.",
            valueType: "Int",
            resolve: { .integer(self.openArtifactCount()) }
        )
    }

    private func openArtifactCount() -> Int {
        MainActor.assumeIsolated { AppDependencies.current.assistant.assistantArtifactStore.artifacts.filter { $0.status == .open }.count }
    }

    private var assistantArtifactsListEntry: FactEntry {
        .fixed(
            key: "assistant.artifacts.list",
            description: Self.assistantArtifactsListDescription,
            valueType: "List"
        ) { self.resolveAssistantArtifactsList() }
    }

    private func resolveAssistantArtifactsList() -> FactValue {
        let items = MainActor.assumeIsolated {
            AppDependencies.current.assistant.assistantArtifactStore.list(includeResolved: false)
        }
        if items.isEmpty {
            return .missing(reason: .notRecorded, detail: "no open artifacts")
        }
        let dateFmt = ISO8601DateFormatter()
        dateFmt.formatOptions = [.withInternetDateTime]
        return .list(items.map { a in
            .record([
                "id": .string(a.id.uuidString),
                "kind": .string(a.kind.rawValue),
                "status": .string(a.status.rawValue),
                "body": .string(a.body),
                "created_at": .string(dateFmt.string(from: a.createdAt)),
                "updated_at": .string(dateFmt.string(from: a.updatedAt))
            ])
        })
    }

    private static let assistantArtifactsListDescription = """
    Every OPEN persistent artifact the AI has been asked to remember — bugs the user is tracking, feature requests, key decisions, notes. Each entry: id / kind (bug|feature|decision|note) / status / body / created_at / updated_at. \
    Read this at the start of conversations + when the user references something ongoing ('did I mention…', 'remember the bug with…'). Returns an empty list when nothing is open. Resolved / archived items are excluded — call \
    assistant.artifacts.list_all if you specifically need them.
    """

    private var assistantArtifactsListAllEntry: FactEntry {
        .fixed(
            key: "assistant.artifacts.list_all",
            description: "All artifacts including resolved / archived / shipped — full history. Use only when the user asks 'what bugs have we fixed' / 'what features did we ship'.",
            valueType: "List"
        ) { self.resolveAssistantArtifactsListAll() }
    }

    private func resolveAssistantArtifactsListAll() -> FactValue {
        let items = MainActor.assumeIsolated {
            AppDependencies.current.assistant.assistantArtifactStore.list(includeResolved: true)
        }
        if items.isEmpty {
            return .missing(reason: .notRecorded, detail: "no artifacts")
        }
        let dateFmt = ISO8601DateFormatter()
        dateFmt.formatOptions = [.withInternetDateTime]
        return .list(items.map { a in
            .record([
                "id": .string(a.id.uuidString),
                "kind": .string(a.kind.rawValue),
                "status": .string(a.status.rawValue),
                "body": .string(a.body),
                "created_at": .string(dateFmt.string(from: a.createdAt)),
                "updated_at": .string(dateFmt.string(from: a.updatedAt))
            ])
        })
    }

    private var assistantArtifactsAddEntry: FactEntry {
        .action(
            key: "assistant.artifacts.add",
            description: Self.assistantArtifactsAddDescription,
            parameters: [
                ActionParam("kind", "'bug', 'feature', 'decision', or 'note'"),
                ActionParam("body", "The artifact text (plain English).")
            ]
        ) { args in self.resolveAssistantArtifactsAdd(args) }
    }

    private func resolveAssistantArtifactsAdd(_ args: [String: String]) -> FactValue {
        guard let kindStr = args["kind"], let kind = AssistantArtifactStore.Kind(rawValue: kindStr) else {
            return .missing(reason: .invalidParameter, detail: "kind must be one of: bug, feature, decision, note")
        }
        guard let body = args["body"]?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else {
            return .missing(reason: .invalidParameter, detail: "body required")
        }
        let added = MainActor.assumeIsolated {
            AppDependencies.current.assistant.assistantArtifactStore.add(kind: kind, body: body)
        }
        return .record([
            "id": .string(added.id.uuidString),
            "kind": .string(added.kind.rawValue),
            "status": .string(added.status.rawValue),
            "body": .string(added.body),
            "created": .boolean(true)
        ])
    }

    private static let assistantArtifactsAddDescription = """
    [ACTION] Save a new artifact to long-term memory. Use this WHENEVER the user tells you to track / remember a bug, feature request, decision, or note that should outlive this conversation. EXAMPLES: 'add a bug — HR alert \
    fires uphill' → call with kind=bug body='HR alert fires uphill'. 'remember we decided to keep coherence breathing not box' → kind=decision, body='Use coherence breathing 5.5/min over box (user pref, evidence-based)'. Required \
    params: kind ('bug' | 'feature' | 'decision' | 'note'), body (the thing to remember, plain English).
    """

    private var assistantArtifactsUpdateStatusEntry: FactEntry {
        .action(
            key: "assistant.artifacts.update_status",
            description: "[ACTION] Mark an artifact as resolved / shipped / archived. Use when the user tells you a bug is fixed, a feature is shipped, or to dismiss an item. Required: id (the artifact's UUID, from the list tool), status ('open' | 'resolved' | 'shipped' | 'archived').",
            parameters: [
                ActionParam("id", "Artifact UUID (from assistant.artifacts.list)."),
                ActionParam("status", "'open' / 'resolved' / 'shipped' / 'archived'.")
            ]
        ) { args in self.resolveAssistantArtifactsUpdateStatus(args) }
    }

    private func resolveAssistantArtifactsUpdateStatus(_ args: [String: String]) -> FactValue {
        guard let idStr = args["id"], let id = UUID(uuidString: idStr) else {
            return .missing(reason: .invalidParameter, detail: "id must be a UUID")
        }
        guard let statusStr = args["status"], let status = AssistantArtifactStore.Status(rawValue: statusStr) else {
            return .missing(reason: .invalidParameter, detail: "status must be one of: open, resolved, shipped, archived")
        }
        let updated = MainActor.assumeIsolated {
            AppDependencies.current.assistant.assistantArtifactStore.updateStatus(id: id, status: status)
        }
        guard let updated else {
            return .missing(reason: .notRecorded, detail: "no artifact with id \(idStr)")
        }
        return .record([
            "id": .string(updated.id.uuidString),
            "status": .string(updated.status.rawValue),
            "updated": .boolean(true)
        ])
    }
}
