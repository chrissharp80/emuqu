import SwiftUI

// SwiftUI-side helpers on AssistantSubsystem. Kept out of the model
// layer (AIProvider.swift, Foundation-only) so the assistant model
// doesn't pull in SwiftUI.
private extension AssistantSubsystem {
    @MainActor var tint: Color {
        switch self {
        case .coach: AppTheme.primary
        case .workoutVoiceCoach: AppTheme.fitnessAccent
        case .voiceConversation: AppTheme.primaryLight
        case .coachReport: AppTheme.textSecondary
        }
    }
}

// UI mapping for the routing tier shown below assistant bubbles: a
// coloured dot plus the tier's name, so the meaning never rests on colour
// alone. The tier says which routing mode classified the turn; where it
// actually ran is the provider label beside it. Kept SwiftUI-side for the
// same reason as AssistantSubsystem.tint above.
private extension SmartProviderRouter.Tier {
    @MainActor var indicatorColor: Color {
        switch self {
        case .quick: AppTheme.sage
        case .auto: AppTheme.primary
        case .deep: AppTheme.dustyRose
        }
    }

    var label: String {
        switch self {
        case .quick: String(localized: "Quick tier", bundle: LanguageManager.appBundle)
        case .auto: String(localized: "Auto tier", bundle: LanguageManager.appBundle)
        case .deep: String(localized: "Deep tier", bundle: LanguageManager.appBundle)
        }
    }
}

// The subsystem chip's name in the app language. `displayName` stays the
// English identity the voice subsystems announce; "Flo" is a name and is
// not translated.
private extension AssistantSubsystem {
    var chipName: String {
        switch self {
        case .coach, .voiceConversation: displayName
        case .workoutVoiceCoach: String(localized: "Coach", bundle: LanguageManager.appBundle)
        case .coachReport: String(localized: "Flo Report", bundle: LanguageManager.appBundle)
        }
    }
}

// SwiftUI-only accessor that decodes the persisted raw Int back into
// the Tier enum. Kept off ChatTurn itself so the model layer doesn't
// need to know about the routing taxonomy.
private extension ChatTurn {
    var routedTier: SmartProviderRouter.Tier? {
        guard let raw = routedTierRaw else { return nil }
        return SmartProviderRouter.Tier(rawValue: raw)
    }
}

struct ChatBubble: View, Equatable {
    @Environment(\.dependencies) var dependencies
    let turn: ChatTurn
    /// The report's mail link had nothing to open it.
    @State private var reportMailUnavailable = false
    var onRemember: (() -> Void)?
    var onCopy: (() -> Void)?
    var onRegenerate: (() -> Void)?
    /// Long-press menu items "Send email, Share".
    /// Optional so call sites that don't supply them (preview
    /// surfaces, tests) keep compiling. The chat tab wires the
    /// real handlers; everywhere else gets a no-op (item hidden).
    var onSendEmail: (() -> Void)?
    var onShare: (() -> Void)?
    /// Which long-press actions this bubble offers, fixed at construction.
    /// The closures are main-actor state a nonisolated `==` may not read;
    /// their presence is plain data it may.
    private let availableActions: AvailableActions

    struct AvailableActions: Equatable, Sendable {
        let remember: Bool
        let copy: Bool
        let regenerate: Bool
        let sendEmail: Bool
        let share: Bool
    }

    init(
        turn: ChatTurn,
        onRemember: (() -> Void)? = nil,
        onCopy: (() -> Void)? = nil,
        onRegenerate: (() -> Void)? = nil,
        onSendEmail: (() -> Void)? = nil,
        onShare: (() -> Void)? = nil
    ) {
        self.turn = turn
        self.onRemember = onRemember
        self.onCopy = onCopy
        self.onRegenerate = onRegenerate
        self.onSendEmail = onSendEmail
        self.onShare = onShare
        availableActions = AvailableActions(
            remember: onRemember != nil, copy: onCopy != nil, regenerate: onRegenerate != nil,
            sendEmail: onSendEmail != nil, share: onShare != nil)
    }

    // Conform to Equatable so a parent `.equatable()` wrapper can skip body
    // re-evaluation when unrelated state changes (keyboard focus, voice
    // state, scroll preference-keys) churn the parent view tree. Only the
    // turn content + available actions matter to what we render; closure
    // identity doesn't, so compare by turn + whether each action exists.
    //
    // Without this, AttributedString(markdown:) runs on every parent body
    // eval — a measurable contributor to typing lag in long chats.
    /// The chat tab passes `onRegenerate` only for the last assistant turn,
    /// so a bubble's actions do change while it is on screen; comparing the
    /// turn alone left the menu stale.
    nonisolated static func == (lhs: ChatBubble, rhs: ChatBubble) -> Bool {
        lhs.turn == rhs.turn && lhs.availableActions == rhs.availableActions
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            assistantOrUserBubble
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var assistantOrUserBubble: some View {
        if turn.role == .assistant {
            avatar
                .accessibilityHidden(true)
            labelledBubble(String(localized: "Assistant message", bundle: LanguageManager.appBundle))
            Spacer(minLength: 32)
        } else {
            Spacer(minLength: 32)
            labelledBubble(String(localized: "Your message", bundle: LanguageManager.appBundle))
            avatar
                .accessibilityHidden(true)
        }
    }

    private func labelledBubble(_ label: String) -> some View {
        bubble
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityValue(spokenText)
            .contextMenu { bubbleMenu }
            .alert(String(localized: "Report response", bundle: LanguageManager.appBundle), isPresented: $reportMailUnavailable) {
                Button(String(localized: "OK", bundle: LanguageManager.appBundle)) {}
            } message: {
                Text(String(localized: "No mail account is set up on this iPhone. Send your report to chrissharp80@gmail.com.", bundle: LanguageManager.appBundle))
            }
    }

    /// Long-press actions. Regenerate only makes sense on the assistant's last
    /// turn, so the caller decides by passing `onRegenerate` or not.
    @ViewBuilder
    private var bubbleMenu: some View {
        if let onRemember {
            Button {
                onRemember()
            } label: {
                Label(String(localized: "Remember this", bundle: LanguageManager.appBundle), systemImage: "brain")
            }
        }
        if let onCopy {
            Button { onCopy() } label: { Label(String(localized: "Copy", bundle: LanguageManager.appBundle), systemImage: "doc.on.doc") }
        }
        if let onShare {
            Button { onShare() } label: { Label(String(localized: "Share", bundle: LanguageManager.appBundle), systemImage: "square.and.arrow.up") }
        }
        if let onSendEmail {
            Button { onSendEmail() } label: { Label(String(localized: "Send email", bundle: LanguageManager.appBundle), systemImage: "envelope") }
        }
        if let onRegenerate {
            Button { onRegenerate() } label: { Label(String(localized: "Regenerate", bundle: LanguageManager.appBundle), systemImage: "arrow.clockwise") }
        }
        reportButton
    }

    @ViewBuilder
    private var reportButton: some View {
        if turn.role == .assistant, let reportURL {
            // Straight to the system, not through `openURL`: the chat view
            // overrides that to discard every non-web scheme a reply might
            // carry, and this link is the app's own, not the model's.
            Button { openReport(reportURL) } label: {
                Label(String(localized: "Report response", bundle: LanguageManager.appBundle), systemImage: "flag")
            }
        }
    }

    private func openReport(_ url: URL) {
        UIApplication.shared.open(url) { opened in
            if !opened { reportMailUnavailable = true }
        }
    }

    /// A pre-filled email to the developer quoting the reply, for anything
    /// harmful or wrong. The report mechanism App Review asks of apps that
    /// show generated content (Guidelines 1.2, 4.7). It opens in the user's
    /// mail app, where they see exactly what is sent and choose whether to.
    private var reportURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "chrissharp80@gmail.com"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Emuqu: reported AI response"),
            URLQueryItem(name: "body", value: String(localized: "What is wrong with this response?", bundle: LanguageManager.appBundle) + "\n\n\n---\n" + turn.text)
        ]
        return components.url
    }

    private var avatar: some View {
        Image(systemName: turn.roleSymbol)
            .scaledFont(size: 14, weight: .semibold)
            .frame(width: 28, height: 28)
            .foregroundStyle(turn.role == .user ? Color.white : Color.accentColor)
            .background(
                Circle()
                    .fill(turn.role == .user ? AppTheme.primaryFilled : Color(.systemGray5))
            )
    }

    private var bubble: some View {
        VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: 4) {
            assistantSubsystemHeader
            bubbleText
            providerFooter
        }
    }

    /// Subsystem header chip — sits ABOVE the bubble for assistant turns so the
    /// user can immediately tell which AI mouth is speaking (Coach / Workout
    /// Coach / Voice Coach / Coach Report). The
    /// reviewer's note that "no way to distinguish which AI instance is
    /// speaking" applies in two places: the at-a-glance UI label here, AND the
    /// audible self-announcement on first utterance, handled by the voice
    /// subsystems themselves.
    @ViewBuilder
    private var assistantSubsystemHeader: some View {
        if turn.role == .assistant {
            subsystemHeader
        }
    }

    /// User turns sit on `AppTheme.primaryFilled`, not `Color.accentColor`:
    /// white on the unset accent (system blue) is 4.02:1, under the 4.5:1 AA
    /// floor for body text; `primaryFilled` clears it.
    private var bubbleText: some View {
        renderedText
            .font(.body)
            .foregroundStyle(turn.role == .user ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(turn.role == .user ? AppTheme.primaryFilled : Color(.secondarySystemBackground))
            )
            // No `.textSelection`: on the text itself its menu takes the long
            // press, and the bubble's menu, with Copy and Report response,
            // would open only from the margins.
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Provider · model line below the bubble. Captioned so it reads as
    /// supporting metadata, not the primary identity (the subsystem header is
    /// the primary identity).
    @ViewBuilder
    private var providerFooter: some View {
        if turn.role == .assistant, let provider = turn.providerID {
            HStack(spacing: 4) {
                tierIndicatorDot
                Text(providerLabel(provider))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
        }
    }

    private func providerLabel(_ provider: ProviderID) -> String {
        let modelLabel: String = turn.modelID.map { apiID in
            dependencies.providers.providerRegistry.displayName(forApiID: apiID, providerID: provider)
        } ?? ""
        return modelLabel.isEmpty ? provider.displayName : "\(provider.displayName) · \(modelLabel)"
    }

    /// Tier indicator: a small coloured disc plus the tier's name, telling
    /// the user which routing tier classified the turn. Per the spec's
    /// "ambient indicator" requirement.
    @ViewBuilder
    private var tierIndicatorDot: some View {
        if let tier = turn.routedTier {
            Circle()
                .fill(tier.indicatorColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(tier.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Visible subsystem chip rendered above each assistant bubble.
    /// Defaults to `.coach` when the turn was produced by the main chat
    /// pipeline without an explicit subsystem tag. The chip color +
    /// glyph differ by subsystem so a quick scan of the transcript
    /// surfaces which utterances came from voice triggers vs. the main
    /// chat.
    @ViewBuilder
    private var subsystemHeader: some View {
        let sub = turn.subsystem ?? .coach
        HStack(spacing: 4) {
            Image(systemName: sub.glyph)
                .scaledFont(size: 9, weight: .semibold)
            Text(verbatim: sub.chipName)
                .scaledFont(size: 10, weight: .semibold)
        }
        .foregroundStyle(sub.tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(sub.tint.opacity(0.12))
        )
        .padding(.leading, 4)
        .padding(.bottom, 1)
    }

    /// What VoiceOver reads for the bubble: the displayed text without
    /// phonetic hints or Markdown syntax.
    private var spokenText: String {
        let stripped = PhoneticOverrides.stripForDisplay(turn.text)
        guard turn.role == .assistant else { return stripped }
        do {
            let attributed = try AttributedString(
                markdown: stripped,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
            return String(attributed.characters)
        } catch {
            // swallow-ok: text that is not valid Markdown is read as typed.
            return stripped
        }
    }

    /// Render assistant turns as inline Markdown so `**bold**`, `*italic*`,
    /// inline code and links render (block syntax such as lists stays as
    /// typed). Also rewrites date references that match a real
    /// session into tappable `flowrecovery://session/<uuid>` links — the chat
    /// view intercepts those and opens a session quick-view sheet.
    /// User turns stay plain (no surprise formatting from pasted content).
    private var renderedText: Text {
        if turn.role == .assistant, !turn.text.isEmpty {
            // Strip phonetic markup (`[[live|laɪv]]` → `live`) before any
            // other processing so citation annotation and markdown parse
            // see clean text and the bubble never shows IPA hints.
            let phoneticStripped = PhoneticOverrides.stripForDisplay(turn.text)
            let annotated = AssistantCitationResolver.annotate(phoneticStripped)
            if let attributed = try? AttributedString(
                markdown: annotated,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            ) {
                return Text(attributed)
            }
        }
        return Text(PhoneticOverrides.stripForDisplay(turn.text))
    }
}
