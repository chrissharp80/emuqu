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
//   3. The app's root view observes `pendingDraft` and
//      presents the MailComposerView in a sheet
//   4. The user reviews, edits recipients, taps Send (or Cancel)
//   5. The chat dismisses the sheet and clears the draft
//
// Apple's MFMailComposeViewController owns the actual send — Emuqu
// never sends mail directly. The user is always in the loop
// before anything leaves their device.
struct AssistantEmailDraft: Equatable, Identifiable {
    let id = UUID()
    let subject: String
    let body: String
    /// `to:` recipients. Empty means the composer opens with no `to:`
    /// pre-filled, letting the user pick from their address book.
    let recipients: [String]
    /// Optional cc recipients. Empty array = no cc. Both `recipients`
    /// and `ccRecipients` get pre-populated from the user's defaults
    /// in Settings → Flo when the AI doesn't supply them.
    let ccRecipients: [String]
    /// Optional file to attach. Used by the AI Coach Report flow to
    /// ship the epic multi-page PDF alongside the conversational
    /// email body. MailComposerView reads the data lazily and
    /// attaches as application/pdf using the URL's last path
    /// component as the filename.
    let attachmentURL: URL?

    /// The first `to:` recipient, or nil when there is none.
    var recipient: String? { recipients.first }

    init(subject: String, body: String, recipients: [String], ccRecipients: [String] = [], attachmentURL: URL? = nil) {
        self.subject = subject
        self.body = body
        self.recipients = recipients
        self.ccRecipients = ccRecipients
        self.attachmentURL = attachmentURL
    }

    init(subject: String, body: String, recipient: String? = nil, ccRecipients: [String] = [], attachmentURL: URL? = nil) {
        self.init(
            subject: subject, body: body, recipients: recipient.map { [$0] } ?? [],
            ccRecipients: ccRecipients, attachmentURL: attachmentURL
        )
    }
}

@Observable
@MainActor
final class AssistantEmailBridge {
    static let shared = AssistantEmailBridge()

    var pendingDraft: AssistantEmailDraft?

    private init() {}

    /// Stage a draft for presentation. Called by the AI's email-compose
    /// action. The app's root view observes `pendingDraft` (Observation)
    /// and raises the composer.
    func stage(_ draft: AssistantEmailDraft) {
        pendingDraft = draft
    }

    /// Clear after the composer closed (user sent or cancelled).
    func clear() {
        pendingDraft = nil
    }
}
