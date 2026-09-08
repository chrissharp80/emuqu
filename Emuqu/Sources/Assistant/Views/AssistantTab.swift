import SwiftUI

/// Top-level wrapper for the AI Assistant tab. Thin shell over
/// `AssistantChatView` — the voice entry point lives in the chat view's own
/// toolbar so it doesn't float over the input bar.
///
/// Receives the same `scrollToTopToken` that other tabs get (bumped by
/// `MainTabView` whenever the user re-taps a tab) but uses it inversely:
/// chat is the only screen that should jump the user to the *bottom* of
/// the content so the latest exchange is visible.
struct AssistantTab: View {
    var scrollToTopToken: UUID = .init()

    var body: some View {
        AssistantChatView(scrollToBottomSignal: scrollToTopToken)
    }
}
