import SwiftUI
import UniformTypeIdentifiers

/// The chat view that lives inside the AI Assistant tab.
///
/// Top: model picker chip + Clear button.
/// Middle: scrollable bubbles, autoscrolls to the latest token as it streams.
/// Bottom: pre-fab question chips above a free-text input + send button.
struct AssistantChatView: View {
    @Environment(\.dependencies) var dependencies
    /// Bumped by the parent (MainTabView's `scrollToTopToken`) whenever the
    /// Assistant tab is re-tapped. The chat scrolls to the BOTTOM on every
    /// change — opposite of what other tabs do — so the latest exchange is
    /// always what the user lands on.
    var scrollToBottomSignal: UUID = .init()
    /// Navigation title shown by the embedded chat. Defaults to "Assistant"
    /// for AssistantTab; CoachHomeV2View passes "Coach" so the v2
    /// wrapper's tab matches the screen header (a bottom tab saying
    /// "Coach" over a header saying "Assistant" reads as a mismatch).
    var title: LocalizedStringKey = "Assistant"
    /// When false, the in-chat model picker chip is suppressed. The v2
    /// Coach wrapper renders its own (richer) model badge above the
    /// chat, so showing both duplicates the badge. AssistantTab keeps it true.
    var showsModelChip: Bool = true

    var viewModel: AssistantViewModel { dependencies.assistant.assistantViewModel }
    var registry: ProviderRegistry { dependencies.providers.providerRegistry }
    private var emailBridge: AssistantEmailBridge { dependencies.assistant.assistantEmailBridge }
    @State var modelPickerPresented = false
    @State private var showClearConfirm = false
    @State private var disclaimerPresented = false
    @State private var citationSession: HRVSession?
    var voice: VoiceConversationController { dependencies.assistant.voiceConversationController }
    // Keyboard perf: `draft`, `inputFocused`, `speech`,
    // `voiceErrorMessage`, and the inbox observation live inside
    // `ChatInputBar` so each keystroke only re-renders that subview, not
    // the whole chat (parent re-renders cascaded into the LazyVStack
    // closure, the per-keystroke `viewModel.turns.filter`, and the
    // GeometryReader preference plumbing — every character cost 5–10×
    // what it should).

    // Scroll-position tracking. `isPinnedToBottom` is true when the user is
    // within ~150pt of the bottom; only then do per-token streaming updates
    // auto-scroll. If they've scrolled up to read history we leave them.
    @State var isPinnedToBottom: Bool = true
    @State var chatViewportHeight: CGFloat = 0
    /// Last time the streaming-token scroll fired. Scrolling
    /// per token (up to ~50 times per response)
    /// thrashes SwiftUI layout and fights the user's scroll
    /// gestures, so they can't actually scroll down once a stream
    /// is running. Throttled to once every 250ms.
    @State var lastStreamingScrollAt: Date = .distantPast
    /// BP §C1 line 1054 — per-message Email + Share state. The chat
    /// view's existing email-bridge sheet is for full-transcript
    /// emails; these are the per-bubble forwards.
    @State var perMessageEmailText: String?
    @State var perMessageEmailPresented: Bool = false
    /// Not a `String?` + `Bool` pair: with those, the sheet body
    /// re-evaluates `if let body = perMessageShareText` at present
    /// time, and if @State batching lands the bool flip BEFORE the
    /// text assignment is visible to the closure (or a separate
    /// path nils the text), the sheet renders an EmptyView and
    /// the user sees a "dark screen". `.sheet(item:)` only presents
    /// when the item is non-nil, so the wrapper guarantees content
    /// or no sheet — never both states out-of-sync.
    struct ShareableText: Identifiable {
        let id = UUID()
        let body: String
    }
    @State var perMessageShareItem: ShareableText?
    /// Keyboard perf. The toolbar Menu's body must not contain
    ///   if let url = viewModel.exportConversation() { ShareLink(item: url, ...) }
    /// SwiftUI evaluates Menu body whenever the parent's body re-runs.
    /// `exportConversation()` walks every turn, builds Markdown, and
    /// writes a temp file to disk on every call. With a long chat,
    /// every parent re-render — including focus state changes when
    /// you tap the input field — pays that cost synchronously, the
    /// primary contributor to "tap input → keyboard takes a
    /// beat" and "first character lags." So: lazy-generate the URL
    /// only when the user taps Export, drive a sheet from a single
    /// transient @State.
    @State private var exportShareURL: URL?

    var body: some View {
        let _ = dependencies.app.keyboardPerfSignpost.event("AssistantChatView.body")
        NavigationStack {
            withChatSheets(withChatChrome(chatStack))
                .onAppear { onChatAppear() }
        }
    }

    private var chatStack: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            messages
            voiceStatusPill
            errorBanner
            Divider()
            chatInputBar
        }
    }

    /// Title, toolbar, the clear-conversation confirmation, and the URL policy
    /// for links the model emits.
    private func withChatChrome(_ content: some View) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                chatToolbar
            }
            .alert(String(localized: "Clear conversation?", bundle: LanguageManager.appBundle), isPresented: $showClearConfirm) {
                Button(String(localized: "Clear", bundle: LanguageManager.appBundle), role: .destructive) { viewModel.clearConversation() }
                Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
            } message: {
                Text(String(localized: "This wipes the chat thread. Your API keys and recovery data are not affected.", bundle: LanguageManager.appBundle))
            }
            .environment(\.openURL, OpenURLAction { handleAssistantURL($0) })
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        // Intentionally NO `.toolbar(placement: .keyboard) { Done }`.
        // That placement builds a UIInputAccessoryView every time
        // focus changes, which stalls the keyboard for ~300-600ms on
        // cold present and sits on top of the input field. Dismissal
        // is already covered by `.scrollDismissesKeyboard(.interactively)`
        // on the transcript, tapping the send button, or a return-key
        // newline — the Done button was pure friction.
        ToolbarItem(placement: .topBarTrailing) { chatOptionsMenu }
        ToolbarItem(placement: .topBarLeading) { voiceToggleButton }
    }

    private var chatOptionsMenu: some View {
        Menu {
            exportChatButton
            refreshDataContextButton
            Divider()
            clearConversationButton
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(String(localized: "More options", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Export or clear the chat, or refresh data context", bundle: LanguageManager.appBundle))
    }

    private var voiceToggleButton: some View {
        Button {
            // Voice runs INLINE in the chat view — no sheet.
            // Toggling here starts/stops the controller; chat
            // continues unchanged, voice turns just appear in
            // the same thread as typed turns.
            voice.toggle()
        } label: {
            Image(systemName: voiceIcon)
                .foregroundStyle(voiceColor)
                .symbolEffect(.pulse, isActive: voiceIsActive)
        }
        .accessibilityLabel(String(localized: "Toggle voice chat", bundle: LanguageManager.appBundle))
    }

    /// Assistant text is model-generated and rendered as markdown, so a
    /// hallucinated or crafted `[x](scheme:…)` link could carry any scheme.
    /// Session citations are resolved in-app; only real web links reach the
    /// system; everything else (javascript:, file:, data:, tel:, …) is
    /// discarded rather than auto-opened.
    private func handleAssistantURL(_ url: URL) -> OpenURLAction.Result {
        if let sessionId = AssistantCitationResolver.parseSessionURL(url) {
            if let session = dependencies.storage.sessionArchive.retrieveOrLog(sessionId, caller: "AssistantChatView.citationTap") {
                citationSession = session
            }
            return .handled
        }
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return .systemAction
        }
        return .discarded
    }

    private func withChatSheets(_ content: some View) -> some View {
        content
            .sheet(item: $citationSession) { citationSheet($0) }
            .sheet(isPresented: $disclaimerPresented) { disclaimerSheet }
            .sheet(item: pendingConsentBinding) { consentSheet($0) }
            .sheet(isPresented: $perMessageEmailPresented) { perMessageEmailSheet }
            .sheet(item: $perMessageShareItem) { ShareSheet(activityItems: [$0.body]) }
            .sheet(item: exportShareBinding) { ShareSheet(activityItems: [$0.url]) }
    }

    private func citationSheet(_ session: HRVSession) -> some View {
        NavigationStack {
            CitationQuickView(session: session)
                .toolbar { citationDoneButton }
        }
    }

    @ToolbarContentBuilder
    private var citationDoneButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) { citationSession = nil }
        }
    }

    private var disclaimerSheet: some View {
        DisclaimerSheet(
            isPresented: $disclaimerPresented,
            onAccept: { viewModel.hasAcceptedDisclaimer = true }
        )
        .interactiveDismissDisabled()
    }

    /// Per-provider PHI/PII sharing consent.
    /// Fires when the user sends to a provider they haven't yet
    /// acknowledged. Acceptance is remembered per provider in
    /// UserDefaults via ProviderConsentTracker — this sheet appears
    /// exactly once per provider per user.
    private var pendingConsentBinding: Binding<ConsentSheetItem?> {
        Binding(
            get: { viewModel.pendingConsentRequest.map { ConsentSheetItem(provider: $0.provider) } },
            set: { if $0 == nil { viewModel.cancelPendingConsent() } }
        )
    }

    private func consentSheet(_ item: ConsentSheetItem) -> some View {
        ProviderConsentSheet(
            provider: item.provider,
            onAccept: { viewModel.acknowledgeConsentAndContinue() },
            onDecline: { viewModel.cancelPendingConsent() }
        )
    }

    /// No email-compose sheet here — only the one at app root.
    /// A local `.sheet(item:)` produced "Email compose sheet dismissed
    /// itself before user could tap Send": it
    /// and the matching one at app root (EmuquApp.body)
    /// both bind to the same `observable pendingDraft`. When
    /// a draft is staged, both sheets try to present; iOS
    /// resolves the conflict by dismissing one of them, which
    /// fires that sheet's `onDismiss { emailBridge.clear() }`,
    /// which nils out `pendingDraft`, which re-evaluates the
    /// OTHER sheet's binding to nil and dismisses IT too —
    /// cascading early dismiss with the user's draft still
    /// in the composer. The app-root sheet is sufficient
    /// (works regardless of which tab is active and is the
    /// design intent for auto-Coach-Report).
    /// BP §C1 line 1054 — per-message Email + Share sheets.
    /// Distinct from the AI-staged email bridge above; these
    /// fire on long-press of any chat bubble.
    @ViewBuilder
    private var perMessageEmailSheet: some View {
        if let body = perMessageEmailText {
            // Pre-fill the To / CC fields from
            // the user's saved defaults, so the per-message
            // email path doesn't open blank when the user has
            // configured a default address. The resolver tries the
            // generic default, then the recovery default,
            // then training — stops at the first set value.
            let defaults = dependencies.app.settingsManager.settings
            let to = defaults.resolvedDefaultEmailRecipient.map { [$0] } ?? []
            let cc = defaults.resolvedDefaultEmailCC
            MailComposerView(
                subject: String(localized: "Note from Emuqu", bundle: LanguageManager.appBundle),
                body: body,
                recipients: to,
                ccRecipients: cc,
                attachmentURL: nil,
                onDismiss: { perMessageEmailText = nil }
            )
        }
    }

    /// Paired with the Export-chat button in the
    /// toolbar Menu. URL is generated lazily on tap (not on
    /// every parent body evaluation) so the keyboard doesn't
    /// pay for the transcript walk + temp-file write on every
    /// focus event. URL is reset to nil when the sheet
    /// dismisses so the next export builds a fresh file.
    private var exportShareBinding: Binding<ExportShareURL?> {
        Binding(
            get: { exportShareURL.map { ExportShareURL(url: $0) } },
            set: { exportShareURL = $0?.url }
        )
    }

    private func onChatAppear() {
        if !viewModel.hasAcceptedDisclaimer {
            disclaimerPresented = true
        }
        startAmbientLocation()
        prewarmAssistantContext()
    }

    /// Start the ambient location stream
    /// lazily when the user opens Coach, not on every
    /// app foreground: that pays the
    /// geocoder pipeline cost (8-26s in real-user logs)
    /// on launches where the user never makes a location query.
    /// Keep `stop()` in EmuquApp's background
    /// transition so leaving the app actually tears down.
    ///
    /// Only with permission already given: opening a tab is not a request
    /// for location. The prompt comes when a question needs a fix, from
    /// `LocationFinder`, with the question on screen to explain it.
    private func startAmbientLocation() {
        dependencies.location.ambientLocationService.startIfAuthorized()
    }

    /// Pre-warm AssistantContextSource. The
    /// builder reads up to 30 lightweight session files
    /// (decrypt + decode each), runs 7-day + 30-day trend
    /// analyzers, and populates `AnalysisSummaryCache`.
    /// Doing it on Coach-tab open instead of on first send
    /// means the user pays this 100–500 ms cost during the
    /// 1–2 s window between tapping the tab and starting
    /// to type, not in time-to-first-token. Idempotent —
    /// each call rebuilds, but the sub-caches it warms
    /// stay warm for the actual send.
    private func prewarmAssistantContext() {
        Task.detached(priority: .userInitiated) {
            _ = await dependencies.assistant.assistantContextSource.currentContext()
        }
    }

    private var refreshDataContextButton: some View {
        Button {
            viewModel.invalidateContext()
        } label: {
            Label(String(localized: "Refresh data context", bundle: LanguageManager.appBundle), systemImage: "arrow.clockwise")
        }
    }

    private var clearConversationButton: some View {
        Button(role: .destructive) {
            showClearConfirm = true
        } label: {
            Label(String(localized: "Clear conversation", bundle: LanguageManager.appBundle), systemImage: "trash")
        }
    }

    private var exportChatButton: some View {
        // Not `if let url = viewModel.exportConversation() { ShareLink ... }`
        // — that runs a full transcript walk + temp-file
        // write on every Menu body evaluation, including
        // every parent re-render triggered by focus
        // state changes — a major contributor to the
        // slow-keyboard-on-tap problem. Instead: a Button
        // that generates the URL on tap and presents a
        // share sheet via the `exportShareURL` state.
        Button {
            // Compute on the main actor (the function is
            // sync). Sub-millisecond for normal chat
            // length; deferring it from EVERY render to
            // ONE per export tap is the win.
            exportShareURL = viewModel.exportConversation()
        } label: {
            Label(String(localized: "Export chat", bundle: LanguageManager.appBundle), systemImage: "square.and.arrow.up")
        }
    }

    // MARK: - Voice status pill (inline, above input bar)

    @ViewBuilder
    private var voiceStatusPill: some View {
        if voice.state != .idle {
            HStack(spacing: 8) {
                Image(systemName: voiceIcon)
                    .foregroundStyle(voiceColor)
                    .symbolEffect(.pulse, isActive: voiceIsActive)
                Text(voiceStatusText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                partialTranscriptText
                pushToTalkButton
                Spacer()
                endVoiceChatButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(voiceColor.opacity(0.1))
        }
    }

    @ViewBuilder
    private var partialTranscriptText: some View {
        if !voice.partialTranscript.isEmpty, voice.state == .listening {
            Text("“\(voice.partialTranscript)”")
                .font(.caption.italic())
                .foregroundStyle(AppTheme.textTertiary)
                .lineLimit(1)
        }
    }

    /// Push-to-talk fallback per spec §1: always visible in voice UI so if VAD
    /// is flaking (wind, crowd, recognizer stall) the user can force-commit
    /// whatever’s been captured, without having to memorise that the main
    /// voice button toggles meaning based on state.
    @ViewBuilder
    private var pushToTalkButton: some View {
        if voice.state == .listening {
            Button {
                voice.forceFinalizeTurn()
            } label: {
                Image(systemName: "paperplane.circle.fill")
                    .foregroundStyle(AppTheme.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Send now", bundle: LanguageManager.appBundle))
        }
    }

    private var endVoiceChatButton: some View {
        Button {
            voice.stop()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(AppTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "End voice chat", bundle: LanguageManager.appBundle))
    }

    private var voiceIcon: String {
        switch voice.state {
        case .idle: "mic.circle.fill"
        case .starting: "ellipsis.circle.fill"
        case .listening: "waveform.circle.fill"
        case .thinking: "ellipsis.circle.fill"
        case .speaking: "speaker.wave.3.fill"
        case .triggerSpeaking: "exclamationmark.triangle.fill"
        }
    }

    private var voiceColor: Color {
        switch voice.state {
        case .idle: AppTheme.primary
        case .starting: AppTheme.mist
        case .listening: AppTheme.sage
        case .thinking: AppTheme.mist
        case .speaking: AppTheme.dustyRose
        case .triggerSpeaking: AppTheme.terracotta
        }
    }

    private var voiceIsActive: Bool {
        switch voice.state {
        case .starting, .listening, .thinking, .speaking: true
        default: false
        }
    }

    private var voiceStatusText: String {
        switch voice.state {
        case .idle: return ""
        case .starting: return String(localized: "Connecting…", bundle: LanguageManager.appBundle)
        case .listening: return voice.partialTranscript.isEmpty ? String(localized: "Listening", bundle: LanguageManager.appBundle) : String(localized: "Hearing you", bundle: LanguageManager.appBundle)
        case .thinking: return String(localized: "Thinking…", bundle: LanguageManager.appBundle)
        case .speaking: return String(localized: "Speaking — tap mic to interrupt", bundle: LanguageManager.appBundle)
        case .triggerSpeaking: return String(localized: "Alert", bundle: LanguageManager.appBundle)
        }
    }
}

// MARK: - Modifiers

extension View {
    /// Apply `writingToolsBehavior(.disabled)` only when the API is
    /// available (iOS 18+). The deployment target is iOS 17, so the
    /// modifier needs an availability gate. Skipping it on iOS 17
    /// is harmless — iOS 17 doesn't have Writing Tools at all.
    @ViewBuilder
    func disableWritingToolsIfAvailable() -> some View {
        if #available(iOS 18.0, *) {
            self.writingToolsBehavior(.disabled)
        } else {
            self
        }
    }
}
