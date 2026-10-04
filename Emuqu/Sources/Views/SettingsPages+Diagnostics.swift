import SwiftUI
import UIKit

// The Troubleshooting page: problem reports, crash report, reanalysis and,
// behind Advanced Diagnostics, the engineering read-outs. Its actions live in
// SettingsPages+DiagnosticActions.swift.

// MARK: - Troubleshooting Page (consumer-facing)

struct TroubleshootingPage: View {
    @Environment(\.dependencies) var dependencies
    @Environment(RRCollector.self) var collector
    @Environment(LanguageManager.self) private var languageManager
    var logger: DebugLogger { dependencies.app.debugLogger }
    var preScoreTelemetry: PreScorePromptTelemetry { dependencies.services.preScorePromptTelemetry }
    var validationTelemetry: ValidationTelemetry { dependencies.services.validationTelemetry }
    var cacheTelemetry: LLMCacheTelemetry { dependencies.providers.llmCacheTelemetry }
    @AppStorage("debugModeEnabled") var debugModeEnabled = false
    @State var logCopiedConfirmation = false
    @State var showingRepairAlert = false
    @State var repairMessage = ""
    @State var showingTrainingRepairAlert = false
    @State var showingTrainingRepairConfirm = false
    @State var trainingRepairMessage = ""
    @State var isRepairingTraining = false
    @State var isRebuildingLoad = false
    @State var trainingRepairProgress = 0
    @State var trainingRepairTotal = 0
    @State var isReanalyzing = false
    @State var reanalyzeMessage = ""
    @State var showingReanalyzeAlert = false
    @State var reanalyzeStopped = false
    @State var reanalyzeProgress = 0
    @State var reanalyzeTotal = 0
    @State var reanalyzeTask: Task<Void, Never>?
    @State var showingReanalyzeConfirm = false
    @State var reanalyzeDateRange = false
    @State var reanalyzeFromDate = Calendar.current.date(byAdding: .weekOfYear, value: -2, to: Date()) ?? Date()
    @State var reanalyzeToDate = Date()

    var body: some View {
        List { diagnosticsSections }
            .zenFormBackground()
            .navigationTitle(String(localized: "Troubleshooting", bundle: LanguageManager.appBundle))
            .alert(
                String(localized: "Log copied", bundle: LanguageManager.appBundle),
                isPresented: $logCopiedConfirmation
            ) { logCopiedAction } message: { logCopiedMessage }
    }

    @ViewBuilder
    private var diagnosticsSections: some View {
        developerSections
        problemsSection
        recentProblemsSection
        crashReportSection
        actionSections
    }

    /// Engineering read-outs (keyboard capture, cache and telemetry counters,
    /// raw prompts) appear only with Advanced Diagnostics on. Shown to everyone, they
    /// read as a development build (Guideline 2.2), and none of them helps a
    /// user fix anything.
    @ViewBuilder
    private var developerSections: some View {
        if debugModeEnabled {
            keyboardCaptureSection
            archiveReadHealthSection
            aiCacheHealthSection
            aiPromptAuditSection
            preScoreTelemetrySection
            rolloutTelemetrySection
        }
    }

    private var logCopiedAction: some View {
        Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) {}
    }

    private var logCopiedMessage: some View {
        Text("The full diagnostic log is on your clipboard — paste it into a message or email.", bundle: LanguageManager.appBundle)
    }

    // Keyboard-focus hang investigation, shown with Advanced Diagnostics on:
    // captures a trace of the chat input render path. See KeyboardCaptureView
    // for the workflow.
    private var keyboardCaptureSection: some View {
        Section {
            NavigationLink {
                KeyboardCaptureView()
            } label: {
                Label(String(localized: "Capture keyboard performance profile", bundle: LanguageManager.appBundle), systemImage: "keyboard.badge.ellipsis")
            }
        } header: {
            Text("Keyboard performance", bundle: LanguageManager.appBundle)
        } footer: {
            Text("Records a timeline of the chat input render path until you tap Stop, at most 10 minutes, so we can find what's blocking the keyboard. Tap, follow the on-screen steps, share the trace.", bundle: LanguageManager.appBundle)
        }
    }

    // MARK: Archive read health
    //
    // Surfaces the EPERM-storm pattern seen in a user's debug
    // log — 1,557 file-permission errors over 7 days against
    // session JSON files
    // in the App Group container, silently breaking trends and
    // the AI's historical context. The card only renders when
    // `hasReadHealthIssue` is true (>10 EPERM failures AND
    // failure rate > 50%) so a one-off transient doesn't
    // alarm the user. Counters are app-launch-scoped.
    @ViewBuilder
    private var archiveReadHealthSection: some View {
        if dependencies.storage.sessionArchive.hasReadHealthIssue {
            Section {
                archiveReadHealthBody
            } header: {
                Text(verbatim: "Archive read health")
            }
        }
    }

    private var archiveReadHealthBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(String(localized: "Sessions can't be read", bundle: LanguageManager.appBundle), systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.wongCaution)
            // Locked pair read — the two counters increment together
            // under `archiveLock`; reading them as separate property
            // accesses could render a torn "X of Y" pair.
            let counters = dependencies.storage.sessionArchive.readHealthCounters
            Text(verbatim: "iOS is denying read access to \(counters.permissionDenied) of \(counters.attempts) session-file reads this launch. Trends and the AI assistant lose history when this happens.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            Text(verbatim: "Quitting and reopening the app re-runs the protection-class repair. If it persists across reopens, file a bug report from this page.")
                .font(.caption)
                .foregroundStyle(AppTheme.textTertiary)
            resetReadHealthButton
        }
        .padding(.vertical, 4)
    }

    private var resetReadHealthButton: some View {
        Button {
            dependencies.storage.sessionArchive.resetReadHealthCounters()
        } label: {
            Text(verbatim: "Reset read-health counters")
                .font(.callout)
        }
    }

    // MARK: AI cache health
    // Surfaces `LLMCacheTelemetry` rolling counters so cache
    // regressions are visible without reading the runtime
    // log. Healthy state: cumulative hit ratio ≥ 75%, recent
    // (last 10 turns) ratio similar. Below 75% means the
    // cache prefix is changing per turn — usually a sign
    // dynamic content leaked into the cacheable zone.
    private var aiCacheHealthSection: some View {
        Section {
            cacheHealthBody

        } header: {
            Text(verbatim: "AI cache health")
        } footer: {
            Text(verbatim: "Healthy target ≥ 75% after a few warmup turns. Lower means the cache prefix is changing per turn — usually dynamic content leaking into the cacheable zone. On-device only; never uploaded.")
        }
    }

    @ViewBuilder
    private var cacheHealthBody: some View {
        if cacheTelemetry.totalTurns == 0 {
            Text(verbatim: "No turns recorded yet. Send a message to the AI assistant to populate this.")
                .font(.callout)
                .foregroundStyle(AppTheme.textSecondary)
        } else {
            hitRatioRows
            turnCountRow
            tokenCountRow
            perProviderRows
            resetTelemetryButton
        }
    }

    @ViewBuilder
    private var hitRatioRows: some View {
        let cumulative = Int(cacheTelemetry.cumulativeHitRatio * 100)
        let warningColor: Color = cumulative >= 75 ? AppTheme.wongOptimal : AppTheme.wongCaution
        cumulativeHitRow(cumulative, color: warningColor)
        recentHitRow(Int(cacheTelemetry.recentHitRatio() * 100))
    }

    @ViewBuilder
    private var perProviderRows: some View {
        let perProvider = cacheTelemetry.perProviderSummary()
        if perProvider.count > 1 {
            Divider()
            ForEach(Array(perProvider.enumerated()), id: \.offset) { _, row in
                perProviderRow(row)
            }
        }
    }

    private var resetTelemetryButton: some View {
        Button(role: .destructive) {
            cacheTelemetry.reset()
        } label: {
            Text(verbatim: "Reset cache telemetry")
        }
    }

    private func cumulativeHitRow(_ cumulative: Int, color warningColor: Color) -> some View {
        HStack {
            Text(verbatim: "Cumulative hit ratio")
            Spacer()
            Text(verbatim: "\(cumulative)%")
                .font(.body.monospacedDigit())
                .foregroundStyle(warningColor)
        }
    }

    private func recentHitRow(_ recent: Int) -> some View {
        HStack {
            Text(verbatim: "Last 10 turns")
            Spacer()
            Text(verbatim: "\(recent)%")
                .font(.body.monospacedDigit())
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var turnCountRow: some View {
        HStack {
            Text(verbatim: "Total turns")
            Spacer()
            Text(verbatim: "\(cacheTelemetry.totalTurns)")
                .font(.body.monospacedDigit())
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var tokenCountRow: some View {
        HStack {
            Text(verbatim: "Tokens cached / new")
            Spacer()
            Text(verbatim: "\(cacheTelemetry.totalCachedReadTokens) / \(cacheTelemetry.totalInputTokens)")
                .font(.body.monospacedDigit())
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func perProviderRow(_ row: (provider: String, turns: Int, hitRatio: Double)) -> some View {
        HStack {
            Text(verbatim: row.provider)
                .font(.callout)
            Spacer()
            Text(verbatim: "\(row.turns) turns · \(Int(row.hitRatio * 100))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    // MARK: AI prompt audit
    //
    // Captures the system prompt, message history, tool catalog,
    // and final response for the last 10 AI turns. Lets the
    // user answer "what did the AI actually see when it gave
    // me that wrong answer?" without guessing — open the
    // detail screen, read the prompt verbatim.
    //
    // In-memory only (no disk write — prompts contain PHI), so
    // the list resets every app launch.
    private var aiPromptAuditSection: some View {
        Section {
            promptAuditLink
        } header: {
            Text("AI prompt audit", bundle: LanguageManager.appBundle)
        } footer: {
            Text("Captures the last 10 AI turns: exactly what the model received and exactly what it returned. Use to verify the AI is reading the same numbers the dashboard shows. In-memory only — never uploaded, cleared on app quit.", bundle: LanguageManager.appBundle)
        }
    }

    private var promptAuditLink: some View {
        NavigationLink { LLMPromptAuditView() } label: { promptAuditLabel }
    }

    private var promptAuditLabel: some View {
        HStack {
            Label(String(localized: "AI prompt audit", bundle: LanguageManager.appBundle), systemImage: "doc.text.magnifyingglass")
            Spacer()
            Text(verbatim: "\(dependencies.providers.llmRequestAudit.entries.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    // MARK: Pre-score prompt telemetry
    // Local A/B-style read-out for the morning subjective prompt's
    // completion rate. Plan threshold: > 20% drop vs un-gated
    // baseline triggers the skip-prominent fallback. One-tap Reset re-baselines the counters.
    private var preScoreTelemetrySection: some View {
        Section {
            Text(verbatim: preScoreTelemetry.diagnosticsSummary)
                .font(.callout)
                .foregroundStyle(AppTheme.textSecondary)
            resetPreScoreButton
        } header: {
            Text(verbatim: "Pre-score prompt")
        } footer: {
            Text(verbatim: "Local-only counters for the morning subjective prompt. Used to spot completion regressions; never uploaded.")
        }
    }

    @ViewBuilder
    private var resetPreScoreButton: some View {
        if preScoreTelemetry.shownCount > 0 {
            Button(role: .destructive) {
                preScoreTelemetry.reset()
            } label: {
                Text(verbatim: "Reset pre-score telemetry")
            }
        }
    }

    // Usage counters: dashboard opens, drill-ins, Trajectory visits, mode
    // activations, methodology views. Local only.
    private var rolloutTelemetrySection: some View {
        Section {
            Text(verbatim: validationTelemetry.diagnosticsSummary)
                .scaledFont(size: 12, design: .monospaced)
                .foregroundStyle(AppTheme.textSecondary)
            Button(role: .destructive) {
                validationTelemetry.reset()
            } label: {
                Text("Reset usage counts", bundle: LanguageManager.appBundle)
            }
        } header: {
            Text("Usage counts", bundle: LanguageManager.appBundle)
        } footer: {
            Text(
                "Counts of dashboard opens, drill-ins, trajectory visits, mode activations and methodology views. Kept on this device, never uploaded.",
                bundle: LanguageManager.appBundle
            )
        }
    }

    // MARK: Problems

    @ViewBuilder
    private var problemsSection: some View {
        if logger.errorCatalog.isEmpty, !dependencies.app.crashLogManager.hasPreviousCrash {
            noProblemsSection
        }
    }

    private var noProblemsSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(size: 48)
                    .foregroundColor(.green)
                    .accessibilityHidden(true)
                Text("No Problems Found", bundle: LanguageManager.appBundle)
                    .font(.headline)
                Text("Everything is running smoothly", bundle: LanguageManager.appBundle)
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("No problems found. Everything is running smoothly.", bundle: LanguageManager.appBundle))
        }
    }

    // "Recent problems" hidden by default;
    // shown only when Advanced Diagnostics is on. The catalog is still
    // captured silently so a user enabling Advanced Diagnostics can see
    // historical entries; we just don't surface them by default.
    @ViewBuilder
    private var recentProblemsSection: some View {
        if !logger.errorCatalog.isEmpty, debugModeEnabled {
            Section { recentProblemRows } header: { recentProblemsHeader }
        }
    }

    private var recentProblemsHeader: some View {
        HStack {
            Text("Recent Problems", bundle: LanguageManager.appBundle)
            Spacer()
            Text("\(logger.errorCatalog.count) total", bundle: LanguageManager.appBundle)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private var recentProblemRows: some View {
        ForEach(logger.errorCatalog.suffix(20).reversed()) { entry in
            problemRow(entry)
        }
    }

    private func problemRow(_ entry: DebugLogger.LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            problemRowHeader(entry)
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func problemRowHeader(_ entry: DebugLogger.LogEntry) -> some View {
        HStack {
            Text(entry.category)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.red)
            Spacer()
            Text(entry.timestamp, style: .relative)
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var crashReportSection: some View {
        if dependencies.app.crashLogManager.hasPreviousCrash {
            Section {
                crashReportLink
            } header: {
                Text("Crash Report", bundle: LanguageManager.appBundle)
            }
        }
    }

    private var crashReportLink: some View {
        NavigationLink { CrashLogView() } label: { crashReportLabel }
    }

    private var crashReportLabel: some View {
        Label(
            String(localized: "View Crash Report", bundle: LanguageManager.appBundle),
            systemImage: "exclamationmark.triangle"
        )
        .foregroundColor(AppTheme.alert)
    }

    func startReanalysis() {
        isReanalyzing = true
        reanalyzeProgress = 0
        reanalyzeTotal = 0
        // "From" means from the start of that day, not from this time of day.
        let from = reanalyzeDateRange ? Calendar.current.startOfDay(for: reanalyzeFromDate) : nil
        let to = reanalyzeDateRange ? reanalyzeToDate : nil
        reanalyzeTask = Task {
            let result = await collector.reanalyzeAllSessions(from: from, to: to) {
                publishReanalyzeProgress($0, total: $1)
            }
            let stopped = Task.isCancelled
            await MainActor.run { finishReanalysis(result, stopped: stopped) }
        }
    }

    private func publishReanalyzeProgress(_ completed: Int, total: Int) {
        Task { @MainActor in
            reanalyzeProgress = completed
            reanalyzeTotal = total
        }
    }

    @MainActor
    private func finishReanalysis(_ result: (updated: Int, skipped: Int), stopped: Bool) {
        isReanalyzing = false
        reanalyzeStopped = stopped
        reanalyzeMessage = reanalysisMessage(result, stopped: stopped)
        showingReanalyzeAlert = true
    }

    /// `result.updated` counts only sessions actually rewritten; the progress
    /// counter also includes skipped and failed ones.
    @MainActor
    private func reanalysisMessage(_ result: (updated: Int, skipped: Int), stopped: Bool) -> String {
        if stopped {
            return String(localized: "Stopped early. Sessions updated: \(result.updated).", bundle: LanguageManager.appBundle)
        }
        if result.skipped > 0 {
            return String(localized: "Reanalyzed \(result.updated) sessions. \(result.skipped) with manual windows preserved.", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Reanalyzed \(result.updated) sessions with updated scoring.", bundle: LanguageManager.appBundle)
    }

    func repairArchive() {
        // The synchronous file-scan repair must not run on the main thread
        // inside the Button action (watchdog risk on a large archive).
        // Mirror the sibling repair/reanalyze paths: do the work
        // off-main, then hop back to set the message + show the alert.
        let archive = collector.archive
        Task {
            let count = await Task.detached { archive.repairArchive() }.value
            await MainActor.run {
                repairMessage = String(localized: "Removed corrupted files and rebuilt the index.\nSessions recovered: \(count)", bundle: LanguageManager.appBundle)
                showingRepairAlert = true
            }
        }
    }

    func repairTrainingSnapshots() {
        isRepairingTraining = true
        trainingRepairProgress = 0
        trainingRepairTotal = 0
        Task {
            let r = await collector.repairTrainingSnapshots { publishTrainingRepairProgress($0, total: $1) }
            await MainActor.run { finishTrainingRepair(r) }
        }
    }

    /// The callback arrives off the main actor, so the published counters are
    /// updated in a hop rather than assigned directly.
    private func publishTrainingRepairProgress(_ completed: Int, total: Int) {
        Task { @MainActor in
            trainingRepairProgress = completed
            trainingRepairTotal = total
        }
    }

    @MainActor
    private func finishTrainingRepair(_ result: ReanalysisService.TrainingRepairResult) {
        isRepairingTraining = false
        trainingRepairMessage = Self.trainingRepairSummary(result)
        showingTrainingRepairAlert = true
    }

    /// Developer-facing (Diagnostics), so this copy stays unlocalized.
    private static func trainingRepairSummary(_ r: ReanalysisService.TrainingRepairResult) -> String {
        var msg = "\(r.totalSessions) sessions, \(r.candidates) eligible, \(r.repaired) updated"
        if r.nilContext > 0 { msg += ", \(r.nilContext) no metrics" }
        if r.errors > 0 { msg += ", \(r.errors) errors" }
        if !r.sampleLog.isEmpty { msg += "\n\n\(r.sampleLog)" }
        return msg
    }
}
