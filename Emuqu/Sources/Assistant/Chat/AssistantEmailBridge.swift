import Combine
import Foundation

// MARK: - AssistantEmailDraft + AssistantEmailBridge
//
// Hand-off layer between the AI's `assistant.email.compose` action
// (which runs in the fact resolver, no UIViewController in scope) and
// the chat UI (which can present `MFMailComposeViewController`).
//
// Flow:
//   1. AI emits a tool_use call to `assistant_email_compose`
//   2. The action's closure stages an `AssistantEmailDraft` on this
//      bridge via `stage(_:)`
//   3. The chat view observes `pendingDraft` and
//      presents the MailComposerView in a sheet
//   4. The user reviews, edits recipients, taps Send (or Cancel)
//   5. The chat dismisses the sheet and clears the draft
//
// Apple's MFMailComposeViewController owns the actual send — Flow
// Recovery never sends mail directly. The user is always in the loop
// before anything leaves their device.
struct AssistantEmailDraft: Equatable, Identifiable {
    let id = UUID()
    let subject: String
    let body: String
    /// Optional recipient. Nil means the composer opens with no
    /// `to:` pre-filled, letting the user pick from their address book
    /// (or default to themselves via auto-fill).
    let recipient: String?
    /// Optional cc recipients. Empty array = no cc. Both `recipient`
    /// and `ccRecipients` get pre-populated from the user's defaults
    /// in Settings → AI Assistant when the AI doesn't supply them.
    let ccRecipients: [String]
    /// Optional file to attach. Used by the AI Coach Report flow to
    /// ship the epic multi-page PDF alongside the conversational
    /// email body. MailComposerView reads the data lazily and
    /// attaches as application/pdf using the URL's last path
    /// component as the filename.
    let attachmentURL: URL?

    init(subject: String, body: String, recipient: String? = nil, ccRecipients: [String] = [], attachmentURL: URL? = nil) {
        self.subject = subject
        self.body = body
        self.recipient = recipient
        self.ccRecipients = ccRecipients
        self.attachmentURL = attachmentURL
    }
}

@Observable

@MainActor
final class AssistantEmailBridge {
    static let shared = AssistantEmailBridge()

    var pendingDraft: AssistantEmailDraft?

    private init() {}

    /// Stage a draft for presentation. Called by the AI's email-compose
    /// action. The chat UI catches the change via Combine.
    func stage(_ draft: AssistantEmailDraft) {
        pendingDraft = draft
    }

    /// Clear after the composer closed (user sent or cancelled).
    func clear() {
        pendingDraft = nil
    }
}
