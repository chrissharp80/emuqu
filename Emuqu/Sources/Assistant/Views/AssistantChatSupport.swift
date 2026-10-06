import SwiftUI
#if canImport(FoundationModels)
    import FoundationModels
#endif

// Scroll-position preference keys, the consent-sheet item and the chat input
// bar: supporting types the chat view uses but which carry no chat logic of
// their own.

// MARK: - Scroll-position preference keys
//
// Read the chat ScrollView's content frame + viewport size so we can compute
// whether the user is near the bottom. If they are, streaming-token updates
// autoscroll. If they've scrolled up to read earlier turns, we leave them
// alone — no more being yanked back to the bottom mid-read.
struct ChatScrollPositionKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

struct ChatViewportKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// Identifiable wrapper so SwiftUI's `.sheet(item:)` can use the
// per-provider consent request straight off the view-model's tuple.
struct ConsentSheetItem: Identifiable {
    let provider: ProviderID
    var id: String { provider.rawValue }
}

/// Identifiable wrapper so the export-chat sheet can be
/// driven by `.sheet(item:)` rather than `.sheet(isPresented:)`. The
/// item-driven sheet auto-dismisses when the URL is cleared, which
/// matches the lazy-on-tap export pattern.
struct ExportShareURL: Identifiable {
    let url: URL
    var id: String { url.path }
}

// MARK: - Chat Input Bar (extracted for keyboard performance)
//
// Owns its own `@State draft`, `@State speech`, `@FocusState
// inputFocused`, `@State voiceErrorMessage`, and `@ObservedObject
// inbox`. Sits below the parent's chat ScrollView. Each keystroke
// flips `draft`, which only re-renders THIS view — the chat history,
// scroll-position GeometryReader, voice status pill, and top bar all
// stay frozen. Before this extraction, `@State draft` lived on
// `AssistantChatView` itself and every keystroke ran the full body
// re-eval including a per-keystroke `viewModel.turns.filter { ... }`
// linear scan over the whole chat history.
//
// Public surface: takes the shared `viewModel` (so the Send button can
// dispatch) and a `isAppleActive` flag (so the Apple-only stub copy
// shows when the user has Apple Intelligence selected). Everything
// else stays internal.
struct ChatInputBar: View {
    @Environment(\.dependencies) var dependencies
    // Narrowed dependencies. An `@ObservedObject var
    // viewModel: AssistantViewModel` here makes every keystroke /
    // every streaming token re-run this body even though the bar
    // only renders against canSend + draft + focus. So the bar
    // observes only `composerState` (publishes only canSend
    // changes — at most twice per conversation). Send actions are
    // closures the parent provides, so the bar doesn't need to
    // touch the VM at all.
    var composerState: ComposerState
    let isAppleActive: Bool
    let onSend: (String) -> AssistantViewModel.SendOutcome
    let onSendPrefab: (PrefabQuestion) -> Void

    @State private var draft: String = ""
    @State private var speech = SpeechInputManager()
    @State private var voiceErrorMessage: String?
    @FocusState private var inputFocused: Bool
    private var inbox: AssistantInbox { dependencies.assistant.assistantInbox }
    var body: some View {
        let _ = dependencies.app.keyboardPerfSignpost.event("ChatInputBar.body")
        VStack(spacing: 8) {
            prefabChips
            composer
        }
        .padding(.top, 8)
        .background(Color(.systemBackground))
        .onAppear { consumeInboxIfPresent() }
        .onDisappear { stopDictationIfRecording() }
        .onChange(of: inbox.pendingDraft) { _, _ in consumeInboxIfPresent() }
        .onChange(of: composerState.canSend) { _, _ in consumeInboxIfPresent() }
        .onChange(of: composerState.returnedDraft) { _, _ in restoreReturnedDraft() }
        .onChange(of: inputFocused) { _, focused in signpostFocusChange(focused) }
    }

    /// Keyboard-perf marker. The @FocusState flip is the SwiftUI
    /// side of the focus event; the UIKit side is the textDidBeginEditing
    /// notification observed in KeyboardPerfSignpost. Capturing both anchors
    /// the trace around the user's tap.
    private func signpostFocusChange(_ focused: Bool) {
        dependencies.app.keyboardPerfSignpost.event(
            "ChatInputBar.focusChanged",
            detail: focused ? "true" : "false"
        )
    }

    /// With Apple's on-device model and no API key
    /// there is no composer at all (see the `isAppleActive` branch
    /// below); the chips *are* the input surface. A test asserting "the
    /// chat input must be reachable" has to accept either.
    private var prefabChips: some View {
        PrefabQuestionChips(
            onSelect: { question in
                onSendPrefab(question)
            },
            isEnabled: composerState.canSend
        )
        .accessibilityIdentifier("assistant.prefabChips")
    }

    @ViewBuilder
    private var composer: some View {
        if isAppleActive {
            appleOnlyComposerHint
        } else {
            fullComposer
        }
    }

    /// With no API key there is no composer, so say why rather than leaving a
    /// dead space where the field would be.
    private var appleOnlyComposerHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone")
                .font(.caption2)
            Text(String(localized: "Tap a suggestion above. Free typing requires a connected model — add an API key in Settings.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// `.bottom` alignment, not the default `.center`.
    /// The field grows vertically (`axis: .vertical`, up to 4
    /// lines); with center alignment the mic/send buttons re-centre
    /// and visibly jump every time a line is added or removed while
    /// typing. Pinning to the bottom line keeps them anchored to the
    /// send baseline and lets the field grow upward smoothly.
    private var fullComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            messageField
            micButton
            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// The composer is the one element that has to be
    /// reachable for the chat surface to be usable at all, so it gets a stable
    /// accessibility handle instead of "whatever text field happens to be first".
    private var messageField: some View {
        withComposerFieldStyle(
            TextField(String(localized: "Ask anything…", bundle: LanguageManager.appBundle), text: $draft, axis: .vertical)
                .accessibilityIdentifier("assistant.composer")
                .lineLimit(1 ... 4)
                .textFieldStyle(.plain)
                .focused($inputFocused)
        )
    }

    /// Keyboard-perf disables. Three captured traces showed
    /// first-focus blocking main for 9–18 s while iOS loads various Apple
    /// Intelligence text subsystems. Disabling the ones we don't need lets iOS
    /// skip the corresponding model loads:
    ///   • autocorrectionDisabled — also kills inline predictions per Apple docs
    ///   • textInputAutocapitalization(.never) — disables capitalization rules
    ///   • writingToolsBehavior(.disabled) — iOS 18+ text-rewrite / proofread.
    ///     This field is "ask an AI", and the AI on the other end is fine with
    ///     raw input.
    ///
    /// Deliberately no keyboard toolbar Done button
    /// (`.toolbar { ToolbarItemGroup(placement: .keyboard) }`): it renders an
    /// accessory strip above the keyboard which, depending on safeArea + chat
    /// input bar layout, sits over the Send button area, obscuring it.
    /// Tap-on-transcript dismissal (`.simultaneousGesture` on the ScrollView) is
    /// the keyboard-dismiss path.
    private func withComposerFieldStyle(_ content: some View) -> some View {
        content
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .disableWritingToolsIfAvailable()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .accessibilityLabel(String(localized: "Message input", bundle: LanguageManager.appBundle))
            .accessibilityHint(String(localized: "Type a question for the AI assistant", bundle: LanguageManager.appBundle))
    }

    private var sendButton: some View {
        Button {
            // Stop dictation first, or the next partial transcript would
            // refill the field with the text just sent.
            stopDictationIfRecording()
            let text = draft
            draft = ""
            inputFocused = false
            // No provider to send to: put the text back rather than lose it.
            if case .rejectedNoProvider = onSend(text) { draft = text }
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .scaledFont(size: 30)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .foregroundStyle(composerState.canSend && !draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.accentColor : Color(.tertiaryLabel))
        }
        .disabled(!composerState.canSend || draft.trimmingCharacters(in: .whitespaces).isEmpty)
        .accessibilityLabel(String(localized: "Send message", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Send your question to the AI assistant", bundle: LanguageManager.appBundle))
    }

    private var micButton: some View {
        Button {
            toggleDictation()
        } label: {
            Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                .scaledFont(size: 22)
                .foregroundStyle(speech.isRecording ? Color.red : Color.accentColor)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(speech.isRecording ? String(localized: "Stop dictation", bundle: LanguageManager.appBundle) : String(localized: "Start dictation", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Use your voice to compose a question", bundle: LanguageManager.appBundle))
        .alert(String(localized: "Voice input", bundle: LanguageManager.appBundle), isPresented: voiceErrorBinding) {
            Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) {}
        } message: {
            Text(voiceErrorMessage ?? "")
        }
        .onChange(of: speech.transcript) { _, newValue in
            if speech.isRecording { draft = newValue }
        }
    }

    private var voiceErrorBinding: Binding<Bool> {
        .init(get: { voiceErrorMessage != nil }, set: { if !$0 { voiceErrorMessage = nil } })
    }

    /// Stop-and-commit when already recording; otherwise start, surfacing any
    /// permission or recogniser failure in the alert above.
    private func toggleDictation() {
        if speech.isRecording {
            draft = speech.stop()
            return
        }
        Task {
            do {
                try await speech.start()
            } catch {
                voiceErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Ends recognition and turns the mic off, discarding the transcript.
    private func stopDictationIfRecording() {
        if speech.isRecording { speech.cancel() }
    }

    /// Pull any pending draft from `AssistantInbox` (set by Dashboard / History
    /// "✨ Ask AI" buttons and Coach suggestions) into the input field.
    /// Auto-sends a complete question (ends with ?, ？ or ؟), and always sends
    /// when Apple Intelligence is active, because there is no field to put a
    /// draft in; otherwise it pre-fills the field for the user to edit. With
    /// Apple active and sending unavailable, the question stays in the inbox
    /// until `canSend` turns true.
    private func consumeInboxIfPresent() {
        guard let pending = inbox.pendingDraft else { return }
        if isAppleActive, !composerState.canSend { return }
        inbox.pendingDraft = nil
        let trimmed = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        if composerState.canSend, isAppleActive || Self.endsWithQuestionMark(trimmed) {
            _ = onSend(trimmed)
        } else {
            draft = pending
        }
    }

    /// Put a message the view-model handed back (consent declined) into the
    /// field, unless the user has already started typing something else.
    private func restoreReturnedDraft() {
        guard let returned = composerState.returnedDraft else { return }
        composerState.returnedDraft = nil
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = returned }
    }

    private static func endsWithQuestionMark(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "?？؟".contains(last)
    }
}

// MARK: - Flo setup

/// What the Flo tab's input area offers for the selected model.
enum FloInputMode: Equatable {
    /// No model can answer: the setup screen replaces the suggestion chips and
    /// the text field, which would otherwise sit there disabled.
    case setup
    /// Apple Intelligence: suggestion chips and voice, no text field.
    case suggestions
    /// A connected cloud model: suggestion chips and the text field.
    case composer

    static func resolve(activeProviderAvailable: Bool, appleSelected: Bool) -> FloInputMode {
        guard activeProviderAvailable else { return .setup }
        return appleSelected ? .suggestions : .composer
    }
}

/// Where Apple Intelligence stands on this iPhone, from
/// `SystemLanguageModel.default.availability`.
enum AppleIntelligenceStatus: Equatable {
    case available
    case notEnabled
    case modelDownloading
    case unsupported

    static var current: AppleIntelligenceStatus {
        #if canImport(FoundationModels)
            if #available(iOS 26, *) {
                return status(of: SystemLanguageModel.default.availability)
            }
        #endif
        return .unsupported
    }

    #if canImport(FoundationModels)
        @available(iOS 26, *)
        static func status(of availability: SystemLanguageModel.Availability) -> AppleIntelligenceStatus {
            guard case .unavailable(let reason) = availability else { return .available }
            if case .appleIntelligenceNotEnabled = reason { return .notEnabled }
            if case .modelNotReady = reason { return .modelDownloading }
            return .unsupported
        }
    #endif

    /// One sentence for the setup screen and the Choose model sheet.
    var explanation: String {
        switch self {
        case .available:
            String(localized: "Apple Intelligence is on, so Flo can answer on this iPhone for free.", bundle: LanguageManager.appBundle)
        case .notEnabled:
            String(localized: "This iPhone supports Apple Intelligence. Turn it on in the Settings app under Apple Intelligence & Siri, and Flo answers on this iPhone for free.", bundle: LanguageManager.appBundle)
        case .modelDownloading:
            String(localized: "Apple Intelligence is still downloading to this iPhone. Once it finishes, Flo answers on this iPhone for free.", bundle: LanguageManager.appBundle)
        case .unsupported:
            String(localized: "Apple Intelligence lets Flo answer on the iPhone for free on supported iPhones (iPhone 15 Pro or later) with iOS 26. It isn't available on this one.", bundle: LanguageManager.appBundle)
        }
    }
}

/// The Flo tab while no model can answer: what Flo needs, and one button into
/// Settings → Flo to add a key. Re-reads which models can answer when it
/// appears and when the app comes back to the foreground, so turning on Apple
/// Intelligence in the Settings app takes effect on return.
struct FloSetupCard: View {
    @Environment(\.dependencies) var dependencies
    @Environment(\.scenePhase) private var scenePhase
    let onAddKey: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .scaledFont(size: 44)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(String(localized: "Set up Flo", bundle: LanguageManager.appBundle))
                .font(.title3.weight(.semibold))
            setupText
            addKeyButton
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.setup")
        .onAppear { dependencies.providers.providerRegistry.keysChanged() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { dependencies.providers.providerRegistry.keysChanged() }
        }
    }

    private var setupText: some View {
        VStack(spacing: 10) {
            Text(String(localized: "Flo answers questions about your recovery, sleep and training. It needs an AI model to answer with, and none is ready yet.", bundle: LanguageManager.appBundle))
            Text(AppleIntelligenceStatus.current.explanation)
            Text(String(localized: "Or add your own API key for Claude, ChatGPT, Gemini, Grok or DeepSeek. Usage is billed to your account with that provider, and before anything is sent Flo shows what the provider will receive and asks you.", bundle: LanguageManager.appBundle))
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var addKeyButton: some View {
        Button(action: onAddKey) {
            Label(String(localized: "Add an API key", bundle: LanguageManager.appBundle), systemImage: "key")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityHint(String(localized: "Opens Settings → Flo", bundle: LanguageManager.appBundle))
    }
}
