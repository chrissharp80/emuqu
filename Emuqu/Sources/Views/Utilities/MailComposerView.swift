import MessageUI
import SwiftUI

/// SwiftUI wrapper for MFMailComposeViewController.
///
/// Supports two callers:
///   • Existing PDF-export paths (Recovery / Workout reports) —
///     pass `subject` + `attachmentURL`, body defaults empty,
///     recipients defaults empty (user picks from address book).
///   • AI's `assistant.email.compose` action — pass `subject` +
///     `body` + optional `recipients`, attachmentURL nil. Body
///     is plain text or inline Markdown; the Markdown is flattened
///     to plain text before it reaches the composer.
///
/// Apple's MFMailComposeViewController owns the actual send. Emuqu
/// never sends mail directly — the user always reviews before
/// tapping Send.
struct MailComposerView: UIViewControllerRepresentable {
    let subject: String
    var body: String = ""
    var recipients: [String] = []
    var ccRecipients: [String] = []
    var attachmentURL: URL?
    /// Called when the composer dismisses (sent, saved, or
    /// cancelled). Used by the AI email path to clear the staged
    /// draft on `AssistantEmailBridge`.
    var onDismiss: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss, onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        // No Mail account configured (or a device that can't send mail):
        // MFMailComposeViewController would present but silently do
        // nothing on Send. Fall back to the system share sheet so the
        // user can still route the report/body through Messages, Files,
        // AirDrop, etc. — and dismiss cleanly if there's nothing to share.
        guard MFMailComposeViewController.canSendMail() else {
            return shareSheetFallback()
        }
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        fill(composer)
        attach(to: composer)
        return composer
    }

    private func fill(_ composer: MFMailComposeViewController) {
        composer.setSubject(subject)
        if !recipients.isEmpty { composer.setToRecipients(recipients) }
        if !ccRecipients.isEmpty { composer.setCcRecipients(ccRecipients) }
        if !body.isEmpty {
            // Plain-text body, so it reads the same in every mail client.
            composer.setMessageBody(Self.plainText(fromMarkdown: body), isHTML: false)
        }
    }

    private func attach(to composer: MFMailComposeViewController) {
        guard let attachmentURL, let data = try? Data(contentsOf: attachmentURL) else { return }
        composer.addAttachmentData(
            data,
            mimeType: "application/pdf",
            fileName: attachmentURL.lastPathComponent
        )
    }

    private func shareSheetFallback() -> UIViewController {
        var items: [Any] = []
        if let attachmentURL { items.append(attachmentURL) }
        if !body.isEmpty { items.append(Self.plainText(fromMarkdown: body)) }
        guard !items.isEmpty else {
            // Nothing to hand off — dismiss on the next runloop and notify the
            // caller so any staged draft is cleared.
            DispatchQueue.main.async { [dismiss, onDismiss] in
                dismiss()
                onDismiss?()
            }
            return UIViewController()
        }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.completionWithItemsHandler = { [dismiss, onDismiss] _, _, _, _ in
            dismiss()
            onDismiss?()
        }
        return activity
    }

    func updateUIViewController(_: UIViewController, context _: Context) {}

    /// Flo writes inline Markdown, which a plain-text body would show as
    /// literal `*` and `_`. Parses it and keeps the text, with each link's
    /// address in parentheses after its words. Unparseable text is sent as
    /// written.
    static func plainText(fromMarkdown markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        do {
            let parsed = try AttributedString(markdown: markdown, options: options)
            return parsed.runs.map { plainText(of: $0, in: parsed) }.joined()
        } catch {
            debugLog("[MailComposerView] Markdown parse failed, sending body as written: \(error)")
            return markdown
        }
    }

    private static func plainText(of run: AttributedString.Runs.Run, in text: AttributedString) -> String {
        let words = String(text[run.range].characters)
        guard let link = run.link, link.absoluteString != words else { return words }
        return "\(words) (\(link.absoluteString))"
    }

    // `@preconcurrency`: MessageUI calls back on the main thread; the
    // protocol is not annotated, so the conformance says so.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency MFMailComposeViewControllerDelegate {
        let dismiss: DismissAction
        let onDismiss: (() -> Void)?

        init(dismiss: DismissAction, onDismiss: (() -> Void)?) {
            self.dismiss = dismiss
            self.onDismiss = onDismiss
        }

        func mailComposeController(_: MFMailComposeViewController, didFinishWith _: MFMailComposeResult, error _: Error?) {
            dismiss()
            onDismiss?()
        }
    }
}
