import SwiftUI

/// Build plan §4.5 C1 — Coach home (chat interface, v2 chrome).
///
/// **Approach.** AssistantChatView is the working chat surface (streaming,
/// tool-use loop, voice, model-picker integration, fact resolution).
/// CoachHomeV2View adds the v2 chrome the spec requires WITHOUT touching
/// the chat pipeline:
///
/// 1. **Model badge** — chip below the navigation header showing the
///    active provider + on-device/cloud tag, tappable to open Choose Model.
/// 2. **Context chips strip** — small pills above the chat showing what
///    the AI sees (today's recovery, last workout, mode flags), tappable
///    to expand-and-explain.
/// 3. **Per-screen suggested prompts** — sheet button in the toolbar that
///    opens a screen-context-aware prompt list per §4.5 C1.
///
/// The actual messaging plumbing stays in AssistantChatView. This is a
/// chrome wrapper, not a fork.
struct CoachHomeV2View: View {
    @Environment(\.dependencies) var dependencies
    var scrollToBottomSignal: UUID = .init()

    @Environment(RRCollector.self) private var collector
    @Environment(ArchiveSignal.self) private var archiveSignal
    private var providerRegistry: ProviderRegistry { dependencies.providers.providerRegistry }
    private var assistantInbox: AssistantInbox { dependencies.assistant.assistantInbox }
    @State private var showingPromptSheet = false
    @State private var showingModelPicker = false
    @State private var showingContextDetail: ContextChipKind?
    /// Keyboard-perf, backed by a captured trace.
    /// As computed properties, `recoveryChip` / `workoutChip`
    /// called `collector.recentSessions(limit:)` (synchronous JSON
    /// from disk) on every body re-evaluation. Trace showed ~210 ms
    /// per cascade × three cascades = 630 ms of main-thread disk
    /// I/O just from opening the tab. The keyboard's safeArea
    /// change re-evaluates `body` and pays the same cost on every
    /// focus event. So we precompute the strings async and feed
    /// them through `@State`; body just reads two strings.
    @State private var recoveryChipText: String?
    @State private var workoutChipText: String?

    enum ContextChipKind: Hashable {
        case recovery
        case lastWorkout
        case modeFlag(String)
    }

    var body: some View {
        let _ = dependencies.app.keyboardPerfSignpost.event("CoachHomeV2View.body")
        return withCoachSheets(coachStack)
    }

    private var coachStack: some View {
        VStack(spacing: 0) {
            modelBadge
            contextChipStrip
            Divider()
            // Pass title="Coach" so the screen
            // header matches the bottom tab name. Pass showsModelChip=false
            // so the inner topBar's ModelPicker is suppressed — this view's
            // own modelBadge above is the single source of truth for model
            // choice (collapsing the duplicate-badge issue).
            AssistantChatView(
                scrollToBottomSignal: scrollToBottomSignal,
                title: "Flo",
                showsModelChip: false
            )
        }
        .navigationTitle(Text(verbatim: "Flo"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { promptsToolbarItem }
    }

    @ToolbarContentBuilder
    private var promptsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingPromptSheet = true
            } label: {
                Image(systemName: "lightbulb")
                    .scaledFont(size: 14, weight: .semibold)
            }
            .accessibilityLabel(String(localized: "Suggested prompts", bundle: LanguageManager.appBundle))
        }
    }

    /// Suggested prompts, the model picker and a context-chip detail, all of
    /// which present over the chat rather than replacing it.
    private func withCoachSheets(_ content: some View) -> some View {
        content
            .sheet(isPresented: $showingPromptSheet) {
                CoachSuggestedPromptsSheet(categories: suggestedPromptsCategorized) { prompt in
                    showingPromptSheet = false
                    dependencies.assistant.assistantInbox.pendingDraft = prompt
                    dependencies.assistant.assistantInbox.requestOpen()
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingModelPicker) {
                CoachModelPickerSheet(registry: providerRegistry)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: Binding(get: {
                showingContextDetail.map(IdentifiedChip.init)
            }, set: { showingContextDetail = $0?.kind })) { ident in
                CoachContextDetailSheet(kind: ident.kind)
                    .presentationDetents([.medium])
            }
    }

    private struct IdentifiedChip: Identifiable {
        let kind: ContextChipKind
        var id: ContextChipKind { kind }
    }

    // MARK: - Model badge

    /// Single consolidated model badge, avoiding
    /// a duplicate-badge issue (provider name in CoachHome's chrome AND
    /// model name in AssistantChatView's topBar):
    /// AssistantChatView's chip is suppressed via showsModelChip:false
    /// when wrapped here, and this badge takes on the model name as
    /// well, so a user sees ONE chip that reads
    /// "Sonnet 4.6 · Anthropic · Cloud" with a tap-to-change chevron.
    private var modelBadge: some View {
        let provider = providerRegistry.activeProvider
        let model = providerRegistry.activeModel
        let isOnDevice = provider.id == .apple
        return Button {
            showingModelPicker = true
        } label: {
            modelBadgeLabel(provider: provider, model: model, isOnDevice: isOnDevice)
        }
        .buttonStyle(.plain)
    }

    private func modelBadgeLabel(provider: AIProvider, model: ModelOption, isOnDevice: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(AppTheme.primary)
            modelNameText(model)
            Text(verbatim: "·")
                .foregroundStyle(AppTheme.textTertiary)
            providerNameText(provider)
            Text(verbatim: "·")
                .foregroundStyle(AppTheme.textTertiary)
            onDeviceText(isOnDevice)
            Spacer()
            Image(systemName: "chevron.right")
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(AppTheme.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(AppTheme.sectionTint)
    }

    private func onDeviceText(_ isOnDevice: Bool) -> some View {
        Text(isOnDevice ? String(localized: "On device", bundle: LanguageManager.appBundle) : String(localized: "Cloud", bundle: LanguageManager.appBundle))
            .scaledFont(size: 12)
            .foregroundStyle(AppTheme.textSecondary)
    }

    private func providerNameText(_ provider: AIProvider) -> some View {
        Text(verbatim: provider.id.displayName)
            .scaledFont(size: 12)
            .foregroundStyle(AppTheme.textSecondary)
            .lineLimit(1)
    }

    private func modelNameText(_ model: ModelOption) -> some View {
        Text(verbatim: model.displayName)
            .scaledFont(size: 13, weight: .semibold)
            .foregroundStyle(AppTheme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    // MARK: - Context chips

    private var contextChipStrip: some View {
        let _ = dependencies.app.keyboardPerfSignpost.event("CoachHomeV2View.contextChipStrip")
        return ScrollView(.horizontal, showsIndicators: false) {
            contextChips
        }
        .background(AppTheme.background)
        // Refresh on archive change. The id ties this
        // .task to the archive's monotonic version, so SwiftUI
        // reruns the loader exactly once per archive mutation
        // (new session arrived, edit, delete) and never on
        // unrelated body re-evals (keyboard, focus, streaming).
        .task(id: archiveSignal.version) {
            await loadChipData()
        }
    }

    private var contextChips: some View {
        HStack(spacing: 8) {
            if let recoveryChipText {
                chipButton(label: recoveryChipText, kind: .recovery)
            }
            if let workoutChipText {
                chipButton(label: workoutChipText, kind: .lastWorkout)
            }
            ForEach(modeChips, id: \.self) { mode in
                chipButton(label: mode, kind: .modeFlag(mode))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func chipButton(label: String, kind: ContextChipKind) -> some View {
        Button {
            showingContextDetail = kind
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: label)
                    .scaledFont(size: 11, weight: .medium)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(AppTheme.cardBackground))
            .foregroundStyle(AppTheme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Context-chip data

    /// Async loader for the context chips. Uses
    /// `recentSessionsAsync(limit:)` which deserializes on a
    /// detached `Task`, off the main thread, and uses the
    /// lightweight retrieval path (skips rrSeries). One round-trip
    /// for both chips so we don't double-walk the archive index.
    private func loadChipData() async {
        let recent = await collector.recentSessionsAsync(limit: 8)
        let recovery = Self.recoveryChip(recent)
        let workout = Self.workoutChip(recent)
        await MainActor.run {
            self.recoveryChipText = recovery
            self.workoutChipText = workout
        }
    }

    /// The coach chip must show the latest RELIABLE overnight
    /// recovery, not merely `recent.first` (which could be a workout, a quick
    /// spot-check, or an untrustworthy `.insufficient`/`.preSleep` partial).
    /// Mirrors the dashboard's `latestOvernightComplete`.
    private static func recoveryChip(_ recent: [HRVSession]) -> String? {
        guard let latest = recent.first(where: {
            $0.sessionType == .overnight && $0.isReliableForHRVAggregates && $0.recoveryScore != nil
        }), let score = latest.recoveryScore else { return nil }
        let scaled = ScoreVerdict.safeDisplayScore(score * 10)
        return String(localized: "Today: \(scaled) recovery", bundle: LanguageManager.appBundle)
    }

    private static func workoutChip(_ recent: [HRVSession]) -> String? {
        guard let last = recent.first(where: { $0.sessionType == .workout && $0.workoutMetadata != nil }),
              let meta = last.workoutMetadata else { return nil }
        let dist = meta.distanceMeters.map { String(format: "%.1f mi", locale: .current, $0 / 1609.34) }
            ?? String(localized: "indoor", bundle: LanguageManager.appBundle)
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        let when = f.localizedString(for: last.startDate, relativeTo: Date())
        return String(localized: "Last workout: \(meta.sport.displayName) · \(dist) · \(when)", bundle: LanguageManager.appBundle)
    }

    private var modeChips: [String] {
        var out: [String] = []
        let s = dependencies.app.settingsManager.settings
        if s.isComebackModeActive { out.append(String(localized: "🌿 Comeback", bundle: LanguageManager.appBundle)) }
        if s.intentionalOverreachActive { out.append(String(localized: "🎯 Overreach", bundle: LanguageManager.appBundle)) }
        return out
    }

    // MARK: - Prompts

    /// Plan §C3 — suggested prompts grouped by category. Per §5.10
    /// the categories are: Today, Training, Sleep, Trends, How-to.
    /// We pass the categorized list to the sheet which renders
    /// section headers; flat-list version retired with this rebuild.
    private var suggestedPromptsCategorized: [(category: String, prompts: [String])] {
        [todayPrompts, trainingPrompts, sleepPrompts, trendPrompts, howToPrompts]
    }

    private var todayPrompts: (category: String, prompts: [String]) {
        (String(localized: "Today", bundle: LanguageManager.appBundle), [
            String(localized: "How am I doing today?", bundle: LanguageManager.appBundle),
            String(localized: "Why is my score what it is?", bundle: LanguageManager.appBundle),
            String(localized: "What should I do today?", bundle: LanguageManager.appBundle),
            String(localized: "Compare today to yesterday. What changed?", bundle: LanguageManager.appBundle)
        ])
    }

    private var trainingPrompts: (category: String, prompts: [String]) {
        (String(localized: "Training", bundle: LanguageManager.appBundle), [
            String(localized: "Should I do a hard run tomorrow?", bundle: LanguageManager.appBundle),
            String(localized: "Am I ramping too fast?", bundle: LanguageManager.appBundle),
            String(localized: "What was my hardest workout this week?", bundle: LanguageManager.appBundle),
            String(localized: "Was that session too hard?", bundle: LanguageManager.appBundle)
        ])
    }

    private var sleepPrompts: (category: String, prompts: [String]) {
        (String(localized: "Sleep", bundle: LanguageManager.appBundle), [
            String(localized: "Was my deep sleep enough?", bundle: LanguageManager.appBundle),
            String(localized: "How can I improve my sleep tonight?", bundle: LanguageManager.appBundle),
            String(localized: "Why is my sleep score what it is?", bundle: LanguageManager.appBundle)
        ])
    }

    private var trendPrompts: (category: String, prompts: [String]) {
        (String(localized: "Trends", bundle: LanguageManager.appBundle), [
            String(localized: "Is my HRV trending up?", bundle: LanguageManager.appBundle),
            String(localized: "What's changed in the last 30 days?", bundle: LanguageManager.appBundle),
            String(localized: "What patterns do you see?", bundle: LanguageManager.appBundle)
        ])
    }

    private var howToPrompts: (category: String, prompts: [String]) {
        (String(localized: "How-to", bundle: LanguageManager.appBundle), [
            String(localized: "What does TRIMP mean?", bundle: LanguageManager.appBundle),
            String(localized: "How does Emuqu score recovery?", bundle: LanguageManager.appBundle),
            String(localized: "Explain DFA-α1 in plain English.", bundle: LanguageManager.appBundle)
        ])
    }
}

// MARK: - Suggested Prompts Sheet (plan §C3 — categorized)

private struct CoachSuggestedPromptsSheet: View {
    let categories: [(category: String, prompts: [String])]
    let onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            promptList
        }
    }

    private var promptList: some View {
        List {
            promptSections
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle(Text(String(localized: "Suggested prompts", bundle: LanguageManager.appBundle)))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var promptSections: some View {
        ForEach(categories, id: \.category) { group in
            promptSection(group)
        }
    }

    private func promptSection(_ group: (category: String, prompts: [String])) -> some View {
        Section(group.category) {
            promptButtons(group.prompts)
        }
    }

    private func promptButtons(_ prompts: [String]) -> some View {
        ForEach(prompts, id: \.self) { prompt in
            promptButton(prompt)
        }
    }

    private func promptButton(_ prompt: String) -> some View {
        Button {
            onPick(prompt)
        } label: {
            HStack {
                Text(verbatim: prompt)
                    .scaledFont(size: 15)
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Model Picker Sheet (semantic categories per §4.5 C2)

private struct CoachModelPickerSheet: View {
    @Environment(\.dependencies) var dependencies
    var registry: ProviderRegistry
    private var settingsManager: SettingsManager { dependencies.app.settingsManager }
    @Environment(\.dismiss) private var dismiss
    @State private var showAllProviders = false

    var body: some View {
        NavigationStack {
            List {
                routingSection
                availableSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .navigationTitle(Text(String(localized: "Choose model", bundle: LanguageManager.appBundle)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { doneToolbarItem }
        }
    }

    /// BP §C2 line 1082 — the routing-mode picker lives in this modal, not
    /// buried in Settings. Quick / Auto / Deep / Manual control how Flo picks a
    /// provider per turn.
    private var routingSection: some View {
        Section {
            routingPicker
            Text(verbatim: settingsManager.settings.routingMode.blurb)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(String(localized: "Routing", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "Quick = Apple on-device for every turn. Auto = session-sticky: Apple for lookups, paid model for reasoning. Deep = strongest paid model every turn. Manual = whatever you pick below.", bundle: LanguageManager.appBundle))
        }
    }

    private var routingPicker: some View {
        Picker(String(localized: "Routing", bundle: LanguageManager.appBundle), selection: Bindable(settingsManager).settings.routingMode) {
            ForEach(RoutingMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var availableSection: some View {
        Section {
            ForEach(registry.visibleProviders, id: \.id) { provider in
                providerRow(provider)
            }
        } header: {
            Text(String(localized: "Available", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "Apple Intelligence runs on-device — free, private, offline. Other providers need an API key set in Settings → Flo.", bundle: LanguageManager.appBundle))
        }
    }

    @ToolbarContentBuilder
    private var doneToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) { dismiss() }
        }
    }

    private func providerRow(_ provider: AIProvider) -> some View {
        Button { registry.setActive(provider: provider) } label: { providerRowContent(provider) }
            .buttonStyle(.plain)
    }

    private func providerRowContent(_ provider: AIProvider) -> some View {
        HStack(spacing: 12) {
            Image(systemName: provider.id.symbolName)
                .scaledFont(size: 16, weight: .medium)
                .foregroundStyle(AppTheme.primary)
                .frame(width: 24)
            providerCaption(provider)
            Spacer()
            providerCheckmark(provider)
        }
    }

    @ViewBuilder
    private func providerCheckmark(_ provider: AIProvider) -> some View {
        if registry.activeProvider.id == provider.id {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.wongOptimal)
        }
    }

    private func providerCaption(_ provider: AIProvider) -> some View {
        let isOnDevice = provider.id == .apple
        let subtitle = isOnDevice
            ? String(localized: "On device · free · private", bundle: LanguageManager.appBundle)
            : String(localized: "Cloud · uses your API key", bundle: LanguageManager.appBundle)
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: provider.id.displayName)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
            Text(subtitle)
                .scaledFont(size: 12)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }
}

// MARK: - Context Detail Sheet

private struct CoachContextDetailSheet: View {
    let kind: CoachHomeV2View.ContextChipKind

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(verbatim: title)
                    .scaledFont(size: 22, weight: .semibold)
                    .foregroundStyle(AppTheme.textPrimary)
                Text(verbatim: detail)
                    .scaledFont(size: 14)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var title: String {
        switch kind {
        case .recovery: String(localized: "Recovery context", bundle: LanguageManager.appBundle)
        case .lastWorkout: String(localized: "Last workout context", bundle: LanguageManager.appBundle)
        case .modeFlag(let m): m
        }
    }

    private var detail: String {
        switch kind {
        case .recovery:
            String(localized: "The Coach can read today's Recovery Score, the HRV / Sleep / Vitals factors, and your recent baseline. Ask anything about your physiology — it'll cite the actual numbers.", bundle: LanguageManager.appBundle)
        case .lastWorkout:
            String(localized: "The Coach can read your most recent workout's TRIMP, average HR, α1, splits, and decoupling. Ask 'should I do another hard one tomorrow?' and it'll factor in this session's load.", bundle: LanguageManager.appBundle)
        case .modeFlag:
            String(localized: "While this mode is active, the Coach incorporates it silently — it won't lecture you about 'rapid increase' during an Intentional Overreach block, and it'll soften load advice during Comeback.", bundle: LanguageManager.appBundle)
        }
    }
}
