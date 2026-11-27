import Foundation

// The destructive memory actions of the assistant namespace and the
// confirmation step they share with `assistant.contacts.remove`. A tool call,
// and the user_quote it carries, only start the request: content the model
// read can make it quote any span of the user's message. The change happens
// when `AssistantActionConfirmations` sees the user's next message confirm it.
// The writes whose content the model supplies (a memory fact, a contact, an
// address, a route name, a saved artifact) go through the same step every
// time. That the content appears in the user's message says nothing about
// whether they want it kept: "don't remember that I had knee surgery"
// contains the fact it refuses.

extension AssistantMemoryNamespace {

    /// What a destructive action, or a write of content the model supplied,
    /// is checked against: the pending-request store and the chat
    /// transcript, live or supplied by a test.
    @MainActor
    struct DestructiveActionContext {
        let confirmations: AssistantActionConfirmations
        let turns: [ChatTurn]
        var now = Date()

        static func live(_ services: FactServices) -> DestructiveActionContext {
            let viewModel = services.assistantViewModel
            return DestructiveActionContext(confirmations: viewModel.actionConfirmations, turns: viewModel.turns)
        }

        /// nil when the user's latest message confirms this request; otherwise
        /// the result telling the model to ask the user first.
        func gate(action: String, target: String, question: String) -> FactValue? {
            switch confirmations.evaluate(action: action, target: target, question: question, turns: turns, now: now) {
            case .confirmed:
                return nil
            case .awaitingConfirmation:
                return AssistantMemoryNamespace.confirmationRequired(question)
            case .noUserMessage:
                return FactValue.missing(
                    reason: .invalidParameter,
                    detail: "this action needs the user's confirmation in the chat, and there is no user message to confirm it"
                )
            }
        }
    }

    /// The first call's answer: nothing changed, and the question the app,
    /// not the model, wrote for the user. The app shows it under the reply
    /// itself (`AssistantActionConfirmations.showPending`) and voice chat
    /// speaks it after the reply.
    static func confirmationRequired(_ question: String) -> FactValue {
        .record([
            "status": .string("confirmation_required"),
            "executed": .boolean(false),
            "ask_user": .string(question),
            "next_step": .string("""
                Nothing has been changed. The app shows the user this exact question under your reply, and speaks it after \
                your reply in voice chat. Say in one short sentence what you are asking them to confirm, and end your reply. \
                Only if their next message is a plain yes, call this tool again with the same arguments and user_quote set to \
                that reply. Any other reply cancels it.
                """)
        ])
    }

    /// Wipes every saved fact once the user has confirmed, keeping a copy
    /// `assistant.memory.restore` can put back.
    @MainActor
    static func clearAllMemory(store: UserFactsStore, context: DestructiveActionContext) -> FactValue {
        let count = store.facts.count
        guard store.hasAnythingToForget else {
            return .record(["cleared": .boolean(false), "count_before": .integer(0), "note": .string("no saved memory facts — nothing to clear")])
        }
        let question = count > 0
            ? String(localized: "Delete all \(count) saved memory facts?", bundle: LanguageManager.appBundle)
            : String(localized: "Delete the unreadable copy of your saved memory?", bundle: LanguageManager.appBundle)
        if let unconfirmed = context.gate(action: "assistant.memory.clear", target: "all", question: question) { return unconfirmed }
        guard let cleared = store.clearKeepingBackup() else {
            return .record(["cleared": .boolean(false), "count_before": .integer(count),
                            "note": .string("the saved facts couldn't be erased, so they are all still stored — ask the user to try again")])
        }
        return .record([
            "cleared": .boolean(true),
            "count_before": .integer(cleared),
            "undo": .string("assistant.memory.restore puts them back until the app quits")
        ])
    }

    /// Deletes one saved fact once the user has confirmed.
    @MainActor
    static func removeMemoryFact(id: UUID, store: UserFactsStore, context: DestructiveActionContext) -> FactValue {
        guard let fact = store.facts.first(where: { $0.id == id }) else {
            return .missing(reason: .notRecorded, detail: "no memory fact with id \(id.uuidString)")
        }
        let question = String(localized: "Forget the saved memory fact “\(fact.text)”?", bundle: LanguageManager.appBundle)
        if let unconfirmed = context.gate(action: "assistant.memory.remove", target: id.uuidString, question: question) { return unconfirmed }
        guard store.remove(id) else {
            return .record(["removed": .boolean(false), "id": .string(id.uuidString),
                            "note": .string("the fact couldn't be removed, so it is still stored — ask the user to try again")])
        }
        return .record(["removed": .boolean(true), "id": .string(id.uuidString), "text": .string(fact.text)])
    }

    /// Puts back the facts the last confirmed wipe erased.
    @MainActor
    static func restoreClearedMemory(store: UserFactsStore) -> FactValue {
        guard !store.clearedBackup.isEmpty else {
            return .missing(reason: .notRecorded, detail: "nothing to restore: no memory wipe since the app started")
        }
        let restored = store.restoreCleared()
        return .record(["restored": .integer(restored), "count": .integer(store.facts.count)])
    }
}
