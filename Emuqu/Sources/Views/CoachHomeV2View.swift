import SwiftUI

/// Coach home (chat interface, v2 chrome).
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
///    opens a screen-context-aware prompt list.
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
    /// focus event. So we precompute the chip data async and feed
    /// it through `@State`; body only formats two short strings.
    @State private var recoveryChipData: RecoveryChipData?
    @State private var workoutChipData: WorkoutChipData?

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
            // Pass title="Flo" so the screen header matches the assistant's
            // name. The modelBadge above is the one place to choose a model.
            AssistantChatView(
                scrollToBottomSignal: scrollToBottomSignal,
                title: "Flo"
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
                    assistantInbox.pendingDraft = prompt
                    assistantInbox.requestOpen()
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

    /// The one model badge on the Flo tab. It reads
    /// "Sonnet 4.6 · Claude · Cloud" with a tap-to-change chevron that opens
    /// Choose model, where each provider lists its models.
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
            Image(systemName: "chevron.forward")
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
            // Re-rendered once a minute so the "2 hr. ago" part stays current
            // while the tab stays open; the loader below only reruns when the
            // archive changes.
            TimelineView(.everyMinute) { context in
                contextChips(now: context.date)
            }
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

    private func contextChips(now: Date) -> some View {
        HStack(spacing: 8) {
            if let recoveryChipData {
                chipButton(label: recoveryChipData.label(now: now), kind: .recovery)
            }
            if let workoutChipData {
                chipButton(label: workoutChipData.label(now: now), kind: .lastWorkout)
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
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Context-chip data

    /// Async loader for the context chips. Uses
    /// `recentSessionsAsync(limit:before:type:)`, which deserializes on a
    /// detached `Task`, off the main thread, through the lightweight
    /// retrieval path (skips rrSeries). Each chip reads only its own session
    /// type, so a run of workouts or spot-checks cannot push the last good
    /// night out of the window, nor a run of nights the last workout.
    private func loadChipData() async {
        let nights = await collector.recentSessionsAsync(limit: Self.chipSessionLimit, before: .distantFuture, type: .overnight)
        let workouts = await collector.recentSessionsAsync(limit: Self.chipSessionLimit, before: .distantFuture, type: .workout)
        let recovery = Self.recoveryChip(nights, baselineNights: collector.baselineTracker.daysCollected)
        let workout = Self.workoutChip(workouts)
        await MainActor.run {
            self.recoveryChipData = recovery
            self.workoutChipData = workout
        }
    }

    /// Newest sessions of each type the chips look through.
    private static let chipSessionLimit = 8

    /// The coach chip must show the latest RELIABLE overnight recovery, picked
    /// exactly as the dashboard hero picks it
    /// (`DashboardSessionPolicy.latestOvernightComplete`: the most recent
    /// night's longest reliable, analysed overnight), so a split night shows
    /// the same score in both places. That night can be days old, so the chip
    /// names when it was recorded instead of "today". Like the dashboard ring,
    /// it shows no score until the baseline is in
    /// (`ScoreAppearancePolicy.showsScore`).
    private static func recoveryChip(_ nights: [HRVSession], baselineNights: Int) -> RecoveryChipData? {
        guard ScoreAppearancePolicy.showsScore(baselineNights: baselineNights),
              let latest = DashboardSessionPolicy.latestOvernightComplete(in: nights, calendar: .current),
              let score = latest.recoveryScore else { return nil }
        return RecoveryChipData(score: ScoreVerdict.safeDisplayScore(score * 10), recordedAt: latest.startDate)
    }

    nonisolated private static func relativeWhen(_ date: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = LanguageManager.appLocale
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }

    /// A workout with no distance is "indoor" only for a sport that has no
    /// GPS; an outdoor sport whose distance was not recorded (location
    /// denied) shows "—".
    private static func workoutChip(_ workouts: [HRVSession]) -> WorkoutChipData? {
        guard let last = workouts.first(where: { $0.workoutMetadata != nil }),
              let meta = last.workoutMetadata else { return nil }
        let dist = meta.distanceMeters.map { UnitsPreferenceStore.current.formatDistance(meters: $0) }
            ?? (meta.sport.usesGPS ? "—" : String(localized: "indoor", bundle: LanguageManager.appBundle))
        return WorkoutChipData(sportName: meta.sport.localizedName, distance: dist, recordedAt: last.startDate)
    }

    /// The recovery chip's score and when its night was recorded; the
    /// relative time is formatted at render so it does not go stale.
    private struct RecoveryChipData: Equatable {
        let score: Int
        let recordedAt: Date

        func label(now: Date) -> String {
            let when = CoachHomeV2View.relativeWhen(recordedAt, now: now)
            return String(localized: "Recovery \(score) · \(when)", bundle: LanguageManager.appBundle)
        }
    }

    /// The last-workout chip's parts; the relative time is formatted at render.
    private struct WorkoutChipData: Equatable {
        let sportName: String
        let distance: String
        let recordedAt: Date

        func label(now: Date) -> String {
            let when = CoachHomeV2View.relativeWhen(recordedAt, now: now)
            return String(localized: "Last workout: \(sportName) · \(distance) · \(when)", bundle: LanguageManager.appBundle)
        }
    }

    private var modeChips: [String] {
        var out: [String] = []
        let s = dependencies.app.settingsManager.settings
        if s.isComebackModeActive { out.append(String(localized: "🌿 Comeback", bundle: LanguageManager.appBundle)) }
        if s.isIntentionalOverreachInEffect { out.append(String(localized: "🎯 Overreach", bundle: LanguageManager.appBundle)) }
        return out
    }

    // MARK: - Prompts

    /// Suggested prompts grouped by category;
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

// MARK: - Suggested Prompts Sheet (categorized)

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

// MARK: - Model Picker Sheet (semantic categories)

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
                providerSections
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .navigationTitle(Text(String(localized: "Choose model", bundle: LanguageManager.appBundle)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { doneToolbarItem }
        }
    }

    /// The routing-mode picker lives in this modal, not
    /// buried in Settings. Quick / Auto / Deep / Manual control how Flo picks a
    /// provider per turn.
    private var routingSection: some View {
        Section {
            routingPicker
            Text(settingsManager.settings.routingMode.blurb)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(String(localized: "AI routing", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: """
                With Apple Intelligence selected: Quick answers on this iPhone, except voice turns and requests to send email, get directions or search the web, \
                which go to a cloud model whose data-sharing notice you've accepted, if you have one. Auto keeps lookups on Apple and sends questions that need more \
                reasoning to xAI Grok or DeepSeek, once you've added its key and accepted its data-sharing notice. Deep sends every turn there, and stays on this \
                iPhone without one. With another model selected, or in Manual, every turn goes to whatever you pick below. If the model a turn goes to fails, Auto \
                and Deep may answer with another model whose notice you've accepted, and Quick with Apple Intelligence; Manual and a selected cloud model never switch.
                """, bundle: LanguageManager.appBundle))
        }
    }

    private var routingPicker: some View {
        Picker(String(localized: "AI routing", bundle: LanguageManager.appBundle), selection: Bindable(settingsManager).settings.routingMode) {
            ForEach(RoutingMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    /// One section per provider Flo can use, each listing that provider's
    /// models, so the choice is provider → model. Apple Intelligence always
    /// appears; when it cannot run here its section says why instead of
    /// offering a model that would not answer.
    private var providerSections: some View {
        ForEach(registry.visibleProviders, id: \.id) { provider in
            Section {
                providerModels(provider)
            } header: {
                providerHeader(provider)
            } footer: {
                providerFooter(provider)
            }
        }
    }

    @ViewBuilder
    private func providerModels(_ provider: AIProvider) -> some View {
        if provider.isAvailable {
            ForEach(provider.availableModels) { model in
                ModelOptionRow(registry: registry, model: model)
            }
        } else if provider.id == .apple {
            Text(AppleIntelligenceStatus.current.explanation)
                .scaledFont(size: 13)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(String(localized: "Currently unavailable.", bundle: LanguageManager.appBundle))
                .scaledFont(size: 13)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    private func providerFooter(_ provider: AIProvider) -> some View {
        if provider.id == .apple {
            Text(String(localized: "Apple Intelligence runs on-device — free, private, offline. Other providers need an API key set in Settings → Flo.", bundle: LanguageManager.appBundle))
        }
    }

    @ToolbarContentBuilder
    private var doneToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) { dismiss() }
        }
    }

    private func providerHeader(_ provider: AIProvider) -> some View {
        let subtitle = provider.id == .apple
            ? String(localized: "On device · free · private", bundle: LanguageManager.appBundle)
            : String(localized: "Cloud · uses your API key", bundle: LanguageManager.appBundle)
        return HStack(spacing: 8) {
            Image(systemName: provider.id.symbolName)
                .foregroundStyle(AppTheme.primary)
            Text(verbatim: provider.id.displayName)
            Text(verbatim: "·")
            Text(subtitle)
        }
        .accessibilityElement(children: .combine)
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
            String(localized: "Flo can read today's Recovery Score, the HRV / Sleep / Vitals factors, and your recent baseline. Ask anything about your physiology — it'll cite the actual numbers.", bundle: LanguageManager.appBundle)
        case .lastWorkout:
            String(localized: "Flo can read your most recent workout's TRIMP, average HR, α1, splits, and decoupling. Ask 'should I do another hard one tomorrow?' and it'll factor in this session's load.", bundle: LanguageManager.appBundle)
        case .modeFlag:
            String(localized: "While this mode is active, Flo incorporates it silently — it won't lecture you about 'rapid increase' during an Intentional Overreach block, and it'll soften load advice during Comeback.", bundle: LanguageManager.appBundle)
        }
    }
}
