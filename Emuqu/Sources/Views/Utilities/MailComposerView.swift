import MessageUI
import SwiftUI
import UniformTypeIdentifiers

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
    /// Called, after `onDismiss`, with what went wrong when the attachment
    /// could not be read (the composer is not opened) or Mail reports the
    /// send failed. Both are logged whether or not a caller listens.
    var onFailure: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss, onDismiss: onDismiss, onFailure: onFailure)
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
        do {
            try attach(to: composer)
        } catch {
            // A report email without the report: close instead of opening it.
            debugLog("[MailComposerView] Attachment unreadable, composer not opened: \(error.localizedDescription)", level: .error)
            return closeOnNextRunLoop(failure: error.localizedDescription)
        }
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

    /// Attaches `attachmentURL`, if any, typed by its extension. Throws when
    /// the file cannot be read.
    private func attach(to composer: MFMailComposeViewController) throws {
        guard let attachmentURL else { return }
        let data = try Data(contentsOf: attachmentURL)
        composer.addAttachmentData(
            data,
            mimeType: Self.mimeType(of: attachmentURL),
            fileName: attachmentURL.lastPathComponent
        )
    }

    /// The MIME type for the file's extension (`application/pdf` for the
    /// reports); generic binary when the extension names no type, since the
    /// assistant's attachment is not constrained to PDF.
    static func mimeType(of url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// A blank controller that closes the sheet on the next runloop, then
    /// tells the caller (`onDismiss`, and `onFailure` when there is a failure).
    private func closeOnNextRunLoop(failure: String?) -> UIViewController {
        DispatchQueue.main.async { [dismiss, onDismiss, onFailure] in
            dismiss()
            onDismiss?()
            if let failure { onFailure?(failure) }
        }
        return UIViewController()
    }

    private func shareSheetFallback() -> UIViewController {
        var items: [Any] = []
        if let attachmentURL { items.append(attachmentURL) }
        if !body.isEmpty { items.append(Self.plainText(fromMarkdown: body)) }
        guard !items.isEmpty else {
            // Nothing to hand off — dismiss on the next runloop and notify the
            // caller so any staged draft is cleared.
            return closeOnNextRunLoop(failure: nil)
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
        let onFailure: ((String) -> Void)?

        init(dismiss: DismissAction, onDismiss: (() -> Void)?, onFailure: ((String) -> Void)?) {
            self.dismiss = dismiss
            self.onDismiss = onDismiss
            self.onFailure = onFailure
        }

        /// Closes the composer. A failed send is logged and reported through
        /// `onFailure` instead of closing exactly like a sent one.
        func mailComposeController(_: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            dismiss()
            onDismiss?()
            guard result == .failed else { return }
            let message = error?.localizedDescription ?? String(localized: "Email failed", bundle: LanguageManager.appBundle)
            debugLog("[MailComposerView] Mail reported the send failed: \(message)", level: .error)
            onFailure?(message)
        }
    }
}
