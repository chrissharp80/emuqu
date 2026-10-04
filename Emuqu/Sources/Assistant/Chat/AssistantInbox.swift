import Combine
import Foundation

/// One-way channel from anywhere in the app into the AI Assistant tab.
///
/// Use case: a "✨ Ask AI" button on the Dashboard or History wants to send
/// the user into the assistant with a question pre-filled. The assistant tab's
/// view model isn't instantiated until the tab is opened, so we can't write
/// to it directly. Instead we set `pendingDraft` here; the chat view consumes
/// and clears it on first appearance.
@Observable
@MainActor
final class AssistantInbox {
    static let shared = AssistantInbox()

    /// Text to pre-fill into the chat input when the Assistant tab opens.
    var pendingDraft: String?

    /// Bumped to a fresh UUID when something requests that the Assistant tab
    /// be opened. `MainTabView` watches this and switches tabs; the value
    /// itself isn't read for content, only for change detection.
    ///
    /// A UUID (not a `Date`) is used so two rapid, millisecond-identical
    /// "open assistant" requests always register as distinct — two `Date()`
    /// values taken in quick succession can compare equal, and an unchanged
    /// value fires no change.
    var openRequestToken: UUID?

    /// Convenience: bump the token. Callers don't have to construct UUIDs.
    func requestOpen() {
        openRequestToken = UUID()
    }

    /// A short user-facing message that the chat view (or any
    /// observer) shows as a transient banner. Cleared automatically
    /// after `transientNoticeAutoClearSeconds`. Exists
    /// so silent-drop paths (voice echo guard, smart-routing
    /// overrides) can surface a one-line explanation to the user
    /// instead of vanishing input.
    var transientNotice: String?

    private static let transientNoticeAutoClearSeconds: TimeInterval = 4.0

    func flashTransientNotice(_ message: String) {
        transientNotice = message
        Task { @MainActor [weak self] in
            await sleepQuietly(UInt64(Self.transientNoticeAutoClearSeconds * 1_000_000_000), context: "flashTransientNotice")
            // Only clear if no newer notice has replaced it.
            if self?.transientNotice == message {
                self?.transientNotice = nil
            }
        }
    }

    private init() {}
}
