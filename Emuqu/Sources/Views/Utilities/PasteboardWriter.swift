import UIKit
import UniformTypeIdentifiers

/// The single place the app writes to the pasteboard.
///
/// Every write sets `[.localOnly: true]` plus a
/// 60-second expiry (unless the user opts out via
/// `preserveClipboardForPaste`). Scattered write sites drift: a bare
/// `UIPasteboard.general.string = …` hands the content to the Universal
/// Clipboard — synced to the user's other Apple devices over iCloud, with no
/// expiry. Both of those carry health data: overnight RMSSD and DFA α1 in the
/// first case, the whole debug log in the second.
///
/// The hardening pattern already existed. It was applied to two sites and not
/// the other two, which is the shape of defect a shared helper prevents by
/// construction.
enum PasteboardWriter {
    /// Copy `text` local-only, with the user-configurable expiry.
    ///
    /// `.localOnly` keeps it off the Universal Clipboard. The expiry is skipped
    /// when the user has turned on `preserveClipboardForPaste` — some people
    /// copy a report and paste it minutes later into another app, and a
    /// clipboard that empties itself reads as a bug to them.
    @MainActor
    static func copy(_ text: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]],
                                      options: pasteboardOptions())
    }

    /// The options `copy` writes with, split out so they can be asserted.
    ///
    /// Removing `.localOnly` must fail a test.
    /// That flag is the entire reason this type exists: without
    /// it the clipboard contents go to the Universal Clipboard, synced to the
    /// user's other devices over iCloud with no expiry, and what gets copied
    /// here is overnight RMSSD, DFA α1 and the debug log. A security control
    /// nothing asserts is a comment.
    @MainActor
    static func pasteboardOptions() -> [UIPasteboard.OptionsKey: Any] {
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        if !AppDependencies.current.app.settingsManager.settings.preserveClipboardForPaste {
            options[.expirationDate] = Date().addingTimeInterval(expirySeconds)
        }
        return options
    }

    /// The security cap the two already-hardened sites used.
    private static let expirySeconds: TimeInterval = 60
}
