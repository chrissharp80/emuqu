import SwiftUI
import UniformTypeIdentifiers

// The chat transcript, composer and sheet sections. Members are internal
// rather than `private` because Swift's `private` does not reach across files.

extension AssistantChatView {
    // MARK: - Sections

    var topBar: some View {
        HStack {
            modelPickerChip
            Spacer()
            stopGeneratingButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var modelPickerChip: some View {
        if showsModelChip {
            ModelPicker(registry: registry, isPresented: $modelPickerPresented)
                .accessibilityLabel(String(localized: "Model picker", bundle: LanguageManager.appBundle))
                .accessibilityHint(String(localized: "Choose which AI model answers your questions", bundle: LanguageManager.appBundle))
        }
    }

    @ViewBuilder
    private var stopGeneratingButton: some View {
        if viewModel.isStreaming {
            Button {
                viewModel.cancel()
            } label: {
                Label(String(localized: "Stop", bundle: LanguageManager.appBundle), systemImage: "stop.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            .accessibilityLabel(String(localized: "Stop generating", bundle: LanguageManager.appBundle))
            .accessibilityHint(String(localized: "Cancel the current AI response", bundle: LanguageManager.appBundle))
        }
    }
    var messages: some View {
        let _ = dependencies.app.keyboardPerfSignpost.event("AssistantChatView.messages")
        return ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                transcriptScroll(proxy)
                scrollToLatestButton(proxy)
            }
        }
    }

    private func transcriptScroll(_ proxy: ScrollViewProxy) -> some View {
        withAutoScroll(withScrollReporting(ScrollView { transcript }), proxy: proxy)
    }

    /// The scroll container’s own wiring: the coordinate space the position
    /// preference is measured in, viewport-height reporting, and the two ways
    /// the keyboard gets dismissed.
    private func withScrollReporting(_ content: some View) -> some View {
        content
            .coordinateSpace(name: "chatScroll")
            .overlay(viewportHeightReporter)
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(keyboardDismissTap)
            .onPreferenceChange(ChatScrollPositionKey.self) { updatePinnedState(contentFrame: $0) }
            .onPreferenceChange(ChatViewportKey.self) { chatViewportHeight = $0 }
    }

    /// A non-conflicting tap-to-dismiss as
    /// a backup. .scrollDismissesKeyboard(.interactively)
    /// handles drag-to-dismiss but only fires when the
    /// transcript actually has scrollable content. Early in
    /// a conversation (or after Clear) the messages fit in
    /// the viewport with no scroll required, leaving users
    /// with no way to dismiss the keyboard except the Send
    /// button. simultaneousGesture composes with the scroll
    /// recognizer rather than competing — the original
    /// comment about "competed with scroll gestures" applied
    /// to a regular .onTapGesture, which IS exclusive.
    private var keyboardDismissTap: some Gesture {
        TapGesture().onEnded {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
    }

    private func withAutoScroll(_ content: some View, proxy: ScrollViewProxy) -> some View {
        content
            .onChange(of: viewModel.turns.last?.text) { _, _ in scrollForStreamedToken(proxy) }
            // A new turn arrived — animate to it even if the user had scrolled up.
            .onChange(of: viewModel.turns.count) { _, _ in jumpToBottom(proxy) }
            // User re-tapped the Assistant tab — jump to the latest message.
            .onChange(of: scrollToBottomSignal) { _, _ in jumpToBottom(proxy) }
            .onChange(of: voice.state) { _, _ in scrollForVoiceState(proxy) }
            .onChange(of: chatViewportHeight) { _, _ in scrollForViewportResize(proxy) }
            .task {
                // First time this view appears (or returns after being discarded)
                // — land at the bottom so the user sees the latest exchange.
                // .task runs after layout, so the proxy is ready to scroll.
                proxy.scrollTo("bottom", anchor: .bottom)
                isPinnedToBottom = true
            }
    }

    /// `frame` is the LazyVStack content's frame in the
    /// chatScroll coordinate space. When at the bottom of a
    /// scrolled-tall content view, `frame.maxY` equals the
    /// viewport height (so distance is 0). When scrolled UP to
    /// read history, `frame.maxY > viewportHeight` (the bottom
    /// of content sits below the visible area), so the gap to
    /// the bottom is `frame.maxY - viewportHeight`. Reversing
    /// the sign makes `isPinnedToBottom` always true once content
    /// exceeds the viewport — every streamed token then yanks the
    /// user back to the bottom even when they are reading earlier
    /// turns. (User report: "won't scroll".)
    private func updatePinnedState(contentFrame frame: CGRect) {
        let distanceFromBottom = frame.maxY - chatViewportHeight
        if distanceFromBottom.isNaN {
            isPinnedToBottom = true
        } else {
            isPinnedToBottom = distanceFromBottom <= 150
        }
    }

    /// Streaming-token updates: scroll WITHOUT animation, and only
    /// if the user is currently pinned to the bottom. Animations
    /// per-token were the root cause of the sluggish feel.
    private func scrollForStreamedToken(_ proxy: ScrollViewProxy) {
        guard isPinnedToBottom else { return }
        // Throttle to 250ms. Per-token scrollTo
        // fires layout passes faster than the user's
        // finger can compete, making it impossible to
        // scroll up to read history during a long response.
        let now = Date()
        guard now.timeIntervalSince(lastStreamingScrollAt) >= 0.25 else { return }
        lastStreamingScrollAt = now
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    /// Animate to the newest message. After snapping to a new turn the user
    /// IS at the bottom, so re-pin.
    private func jumpToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
        isPinnedToBottom = true
    }

    /// When the voice status pill appears or
    /// disappears, the messages area shrinks/grows. Without a
    /// re-scroll, the latest content gets clipped behind the
    /// pill (user report: "this scrolling is fucked up" with a
    /// screenshot of the AI response cut off mid-sentence above
    /// the Speaking pill). Re-scroll to bottom whenever voice
    /// state changes so the latest content stays visible.
    private func scrollForVoiceState(_ proxy: ScrollViewProxy) {
        guard isPinnedToBottom else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    /// Also re-pin when the viewport itself resizes (keyboard
    /// show/hide, voice pill toggle, anything that changes the
    /// message area's height). Without this, content scrolled
    /// off the bottom stays hidden when the viewport grows.
    private func scrollForViewportResize(_ proxy: ScrollViewProxy) {
        guard isPinnedToBottom else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    /// Floating "scroll to latest" button. Shows
    /// only when the user has scrolled UP from the bottom.
    /// Real bug repro: with the streaming-token scroll fight,
    /// some users got stuck above the latest content and
    /// couldn't catch up. Tapping this guarantees a jump
    /// to the bottom regardless of layout state.
    @ViewBuilder
    private func scrollToLatestButton(_ proxy: ScrollViewProxy) -> some View {
        if !isPinnedToBottom {
            Button {
                jumpToBottom(proxy)
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white, Color.accentColor)
                    .background(Circle().fill(Color(.systemBackground)))
                    .shadow(radius: 4)
            }
            .padding(.trailing, 16)
            .padding(.bottom, 12)
            .accessibilityLabel(String(localized: "Scroll to latest message", bundle: LanguageManager.appBundle))
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var transcript: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if viewModel.turns.isEmpty {
                emptyState
                    .padding(.top, 60)
            } else {
                turnBubbles
                typingIndicator
            }
            Color.clear
                .frame(height: 1)
                .id("bottom")
        }
        .padding(.vertical, 12)
        .background(scrollPositionReporter)
    }

    /// Per-frame scroll-position readings so we only autoscroll when
    /// the user is ALREADY near the bottom. If they've scrolled up
    /// to read earlier messages we leave them alone.
    private var scrollPositionReporter: some View {
        GeometryReader { contentGeo in
            Color.clear.preference(
                key: ChatScrollPositionKey.self,
                value: contentGeo.frame(in: .named("chatScroll"))
            )
        }
    }

    /// Reports the scroll viewport’s height so the pinned-to-bottom test has
    /// something to measure the content frame against.
    private var viewportHeightReporter: some View {
        GeometryReader { scrollGeo in
            Color.clear.preference(
                key: ChatViewportKey.self,
                value: scrollGeo.size.height
            )
        }
    }

    /// Skip rendering empty assistant turns — they were placeholders
    /// for the in-flight stream and look like a blank avatar before
    /// the first token arrives. Show the typing indicator instead.
    private var turnBubbles: some View {
        let visibleTurns = viewModel.turns.filter { !($0.role == .assistant && $0.text.isEmpty) }
        return ForEach(Array(visibleTurns.enumerated()), id: \.element.id) { idx, turn in
            chatBubble(turn, isLast: idx == visibleTurns.count - 1)
        }
    }

    /// `.equatable()` lets SwiftUI short-circuit body
    /// evaluation for bubbles whose turn content hasn't
    /// changed. Without this, markdown re-parses for
    /// every visible bubble whenever ANY parent state
    /// churns (keyboard focus, voice state, scroll
    /// preference callbacks) — the single biggest
    /// contributor to "lag when I tap into the chat."
    private func chatBubble(_ turn: ChatTurn, isLast: Bool) -> some View {
        ChatBubble(
            turn: turn,
            onRemember: { viewModel.remember(turn.text) },
            onCopy: { copyToPasteboard(turn.text) },
            onRegenerate: (turn.role == .assistant && isLast && !viewModel.isStreaming)
                ? { viewModel.regenerateLast() }
                : nil,
            // BP §C1 line 1054 — long-press menu items
            // Send email / Share. Per-message rather
            // than whole-conversation: the user often
            // wants to forward ONE specific reply
            // (e.g. a coach insight to a teammate),
            // not the entire transcript.
            onSendEmail: { presentEmail(for: turn) },
            onShare: { presentShare(for: turn) }
        )
        .equatable()
        .id(turn.id)
    }

    /// Chat content can include
    /// user-supplied health context. Skip copy while the
    /// screen is being recorded/mirrored.
    ///
    /// Clipboard expiration is
    /// user-controllable via
    /// `preserveClipboardForPaste` (default true —
    /// ideas don't get auto-erased while the user
    /// is searching for them across apps). When
    /// off, the original 60 s security expiration
    /// applies.
    private func copyToPasteboard(_ text: String) {
        if UIScreen.main.isCaptured {
            debugLog("[AssistantChat] Copy skipped — screen capture active", level: .info)
            return
        }
        // The screen-capture check above is a decision about WHETHER to copy and
        // stays here; the `.localOnly` + expiry policy is about HOW and lives in
        // `PasteboardWriter`.
        PasteboardWriter.copy(text)
    }

    /// Typing indicator while waiting for the first token of the
    /// current assistant turn (which is still empty so it was
    /// filtered out of `visibleTurns` above).
    @ViewBuilder
    private var typingIndicator: some View {
        if viewModel.isStreaming, let last = viewModel.turns.last,
           last.role == .assistant, last.text.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .scaledFont(size: 14, weight: .semibold)
                    .frame(width: 28, height: 28)
                    .foregroundStyle(Color.accentColor)
                    .background(Circle().fill(Color(.systemGray5)))
                TypingIndicator()
                Spacer(minLength: 32)
            }
            .padding(.horizontal, 12)
            .id("typingIndicator")
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    /// Workout-aware empty state. User report:
    /// "Coach didn't acknowledge active workout at session open."
    /// Pulls the live broker snapshot at render time. If a workout
    /// is in flight the heading and body acknowledge it directly
    /// instead of the generic "Ask about your recovery" copy. Cheap
    /// — broker.currentSnapshot() is a lock-protected read, no
    /// disk / network. When no workout is active the original
    /// copy is preserved.
    var emptyState: some View {
        let liveWorkout = dependencies.assistant.liveWorkoutBroker.currentSnapshot()
        return VStack(spacing: 16) {
            Image(systemName: liveWorkout != nil ? "figure.run" : "sparkles")
                .scaledFont(size: 44)
                .foregroundStyle(Color.accentColor)
            Text(workoutAwareTitle(for: liveWorkout))
                .font(.title3.weight(.semibold))
            Text(workoutAwareBody(for: liveWorkout))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            emptyStateError
        }
        .frame(maxWidth: .infinity)
    }

    /// The last error, shown under the empty state so a failure that happens
    /// before any turn exists is still visible.
    @ViewBuilder
    private var emptyStateError: some View {
        if let error = viewModel.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 32)
                .multilineTextAlignment(.center)
        }
    }

    func workoutAwareTitle(for live: AssistantContext.LiveWorkoutSnapshot?) -> String {
        guard let live else { return String(localized: "Ask about your recovery", bundle: LanguageManager.appBundle) }
        let mins = live.elapsedSeconds / 60
        if mins < 1 {
            return String(localized: "You just started a \(live.sport)", bundle: LanguageManager.appBundle)
        }
        return String(localized: "\(mins) min into your \(live.sport)", bundle: LanguageManager.appBundle)
    }

    func workoutAwareBody(for live: AssistantContext.LiveWorkoutSnapshot?) -> String {
        guard let live else {
            return emptyStateBody
        }
        var parts: [String] = []
        if let hr = live.heartRate { parts.append("\(hr) bpm") }
        if live.peakHR > 0 { parts.append("peak \(live.peakHR)") }
        if live.distanceMeters > 50 {
            let km = live.distanceMeters / 1000
            parts.append(String(format: "%.2f km", km))
        }
        let stat = parts.isEmpty ? "" : " (\(parts.joined(separator: " · ")))"
        return String(localized: "Ask about pace, HR, α1, splits — anything live\(stat). Tap a suggestion below or type a question.", bundle: LanguageManager.appBundle)
    }

    /// Persistent error banner. Rendering errors only
    /// inside the empty-state body means that once the user has any
    /// chat history a failed send (out of credits, 401, 429, network) silently
    /// drops — they sit watching for a response that never comes. This banner
    /// sits right above the input bar so any error from the last send is
    /// impossible to miss.
    /// Persistent error banner sitting between the transcript and
    /// the input bar. Shows the last error in red, with a Dismiss
    /// button so the user can clear it once seen. The empty-state
    /// rendering still shows errors too (for users who hit a problem
    /// before any successful turn), but this banner is what catches
    /// the silent-failure case where the user has prior history.
    @ViewBuilder
    var errorBanner: some View {
        if let error = viewModel.errorMessage, !error.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .scaledFont(size: 13, weight: .semibold)
                errorText(error)
                Spacer()
                dismissErrorButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.red.opacity(0.12))
        }
    }

    private func errorText(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(error)
                .scaledFont(size: 13)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dismissErrorButton: some View {
        Button {
            viewModel.clearError()
        } label: {
            Image(systemName: "xmark")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Dismiss error", bundle: LanguageManager.appBundle))
    }

    var emptyStateBody: String {
        if registry.activeProvider.isAvailable {
            return String(localized: "Tap a suggestion below or type a question. Your data stays ", bundle: LanguageManager.appBundle) +
                (registry.activeProvider.id == .apple ? String(localized: "on this device.", bundle: LanguageManager.appBundle) : String(localized: "between you and \(registry.activeProvider.id.vendorName).", bundle: LanguageManager.appBundle))
        }
        return String(localized: "No model is set up yet. Tap the model picker above to choose one, or add an API key in Settings → AI Assistant.", bundle: LanguageManager.appBundle)
    }

    var isAppleActive: Bool {
        registry.activeProvider.id == .apple
    }

    /// Extracted to keep `body` under SwiftUI's type-check budget.
    /// The closures + four parameters were tipping the type-checker
    /// over its complexity limit when nested inside the parent body.
    var chatInputBar: some View {
        ChatInputBar(
            composerState: viewModel.composerState,
            isAppleActive: isAppleActive,
            onSend: { viewModel.send(text: $0) },
            onSendPrefab: { viewModel.send(prefab: $0) }
        )
    }

    // The input bar and mic button live in
    // `ChatInputBar` (defined below) — keeping the
    // input-owning state in a child view stops every keystroke from
    // re-rendering the parent's chat ScrollView. The parent just
    // mounts `ChatInputBar(viewModel:isAppleActive:)`.

    // MARK: - Per-message Email + Share (BP §C1 line 1054)

    /// Prepare a single chat turn for forwarding via the system mail
    /// composer. Pre-fills the body with the turn text + a "From Flo"
    /// attribution; subject, To, Cc are left empty so the user picks
    /// recipients. Skipped on screen-capture.
    fileprivate func presentEmail(for turn: ChatTurn) {
        if UIScreen.main.isCaptured { return }
        perMessageEmailText = forwardingBody(for: turn)
        perMessageEmailPresented = true
    }

    fileprivate func presentShare(for turn: ChatTurn) {
        if UIScreen.main.isCaptured { return }
        let body = forwardingBody(for: turn)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        perMessageShareItem = ShareableText(body: body)
    }

    func forwardingBody(for turn: ChatTurn) -> String {
        let attribution: String = {
            switch turn.role {
            case .assistant: return String(localized: "From Flo (Emuqu):", bundle: LanguageManager.appBundle)
            case .user: return String(localized: "From me (via Emuqu):", bundle: LanguageManager.appBundle)
            }
        }()
        return "\(attribution)\n\n\(turn.text)"
    }
}
