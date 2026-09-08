import SwiftUI
import UIKit

// MARK: - Debug Log View

struct DebugLogView: View {
    @Environment(\.dependencies) var dependencies
    var logger: DebugLogger { dependencies.app.debugLogger }
    @State private var exportItem: ExportItem?
    @State private var showingClearConfirm = false
    @State private var isExporting = false

    private struct ExportItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        logList
            .toolbar { debugLogToolbar }
            .alert(String(localized: "Clear Debug Logs?", bundle: LanguageManager.appBundle), isPresented: $showingClearConfirm) {
                Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
                Button(String(localized: "Clear", bundle: LanguageManager.appBundle), role: .destructive) {
                    dependencies.app.debugLogger.clear()
                }
            } message: {
                Text(String(localized: "This will delete all \(logger.entries.count) log entries. You can't undo this.", bundle: LanguageManager.appBundle))
            }
            .sheet(item: $exportItem) { exportSheet($0) }
    }

    private var logList: some View {
        List {
            ForEach(logger.entries.reversed()) { entry in
                logRow(entry)
            }
        }
        .zenFormBackground()
        .navigationTitle(String(localized: "Debug Logs", bundle: LanguageManager.appBundle))
    }

    private func logRow(_ entry: DebugLogger.LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            logRowHeader(entry)
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
        }
        .padding(.vertical, 2)
    }

    private func logRowHeader(_ entry: DebugLogger.LogEntry) -> some View {
        HStack {
            Text(entry.category)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.accentColor)
            Spacer()
            Text(entry.timestamp, style: .time)
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    @ToolbarContentBuilder
    private var debugLogToolbar: some ToolbarContent {
        clearLogsToolbarItem
        exportLogsToolbarItem
    }

    private var clearLogsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button(role: .destructive) {
                showingClearConfirm = true
            } label: {
                Text(String(localized: "Clear", bundle: LanguageManager.appBundle))
            }
        }
    }

    private var exportLogsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            exportLogsButton
        }
    }

    private var exportLogsButton: some View {
        Button { exportLogs() } label: { exportLogsLabel }
            .disabled(isExporting)
    }

    /// Async export so the multi-megabyte disk read and concat
    /// don't freeze the toolbar tap. A transient spinner shows via
    /// `isExporting` while the work runs.
    private func exportLogs() {
        isExporting = true
        Task { await finishExport(dependencies.app.debugLogger.exportToFileAsync()) }
    }

    @MainActor
    private func finishExport(_ url: URL?) {
        isExporting = false
        if let url { exportItem = ExportItem(url: url) }
    }

    @ViewBuilder
    private var exportLogsLabel: some View {
        if isExporting {
            ProgressView()
        } else {
            Image(systemName: "square.and.arrow.up")
        }
    }

    private func exportSheet(_ item: ExportItem) -> some View {
        NavigationStack {
            exportSheetBody(item)
                .navigationTitle(String(localized: "Export Logs", bundle: LanguageManager.appBundle))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { exportDoneToolbarItem }
        }
    }

    private func exportSheetBody(_ item: ExportItem) -> some View {
        VStack {
            Text(String(localized: "Debug Log Export", bundle: LanguageManager.appBundle))
                .font(.title)
                .padding()

            Text(item.url.lastPathComponent)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)

            Spacer()

            shareLogButton(item)
        }
    }

    /// SwiftUI `ShareLink` avoids walking
    /// `UIApplication.shared.connectedScenes.first`, which could orphan the
    /// share sheet if the parent sheet dismissed between the tap and the
    /// present call. It also gets iPad popover anchoring for free.
    private func shareLogButton(_ item: ExportItem) -> some View {
        ShareLink(item: item.url) {
            Label(String(localized: "Share Log File", bundle: LanguageManager.appBundle), systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
                .padding()
        }
        .buttonStyle(.borderedProminent)
        .padding()
    }

    private var exportDoneToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) {
                exportItem = nil
            }
        }
    }
}

// ShareSheet is defined in Sources/Views/Utilities/ShareSheet.swift

// MARK: - Crash Log View

struct CrashLogView: View {
    @Environment(\.dependencies) var dependencies
    @State private var crashLog: String = ""
    @State private var showingShareSheet = false
    @State private var exportURL: URL?
    @State private var showingClearConfirm = false
    @Environment(\.dismiss) private var dismiss

    @ViewBuilder
    var body: some View {
        List {
            crashDetailsSection
            crashActionsSection
        }
        .zenFormBackground()
        .navigationTitle(String(localized: "Crash Report", bundle: LanguageManager.appBundle))
        .task { await loadCrashLog() }
        .sheet(isPresented: $showingShareSheet) {
            if let url = exportURL {
                ShareSheet(activityItems: [url])
            }
        }
        .alert(String(localized: "Delete Crash Report?", bundle: LanguageManager.appBundle), isPresented: $showingClearConfirm) {
            deleteCrashAlertActions
        } message: {
            Text(String(localized: "The crash report will be permanently deleted.", bundle: LanguageManager.appBundle))
        }
    }

    @ViewBuilder
    private var deleteCrashAlertActions: some View {
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
        Button(String(localized: "Delete", bundle: LanguageManager.appBundle), role: .destructive) {
            dependencies.app.crashLogManager.clearPreviousCrash()
            dismiss()
        }
    }

    private var crashDetailsSection: some View {
        Section {
            if crashLog.isEmpty {
                Text(String(localized: "No crash log available", bundle: LanguageManager.appBundle))
                    .foregroundColor(AppTheme.textSecondary)
            } else {
                Text(crashLog)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
        } header: {
            Text(String(localized: "Crash Details", bundle: LanguageManager.appBundle))
        } footer: {
            if !crashLog.isEmpty {
                Text(String(localized: "Share this with the developer to help investigate the issue.", bundle: LanguageManager.appBundle))
            }
        }
    }

    @ViewBuilder
    private var crashActionsSection: some View {
        if !crashLog.isEmpty {
            Section {
                shareCrashButton

                deleteCrashButton
            }
        }
    }

    private var shareCrashButton: some View {
        Button {
            if let url = dependencies.app.crashLogManager.exportCrashLog() {
                exportURL = url
                showingShareSheet = true
            }
        } label: {
            Label(String(localized: "Share Crash Report", bundle: LanguageManager.appBundle), systemImage: "square.and.arrow.up")
        }
    }

    private var deleteCrashButton: some View {
        Button(role: .destructive) {
            showingClearConfirm = true
        } label: {
            Label(String(localized: "Delete Crash Report", bundle: LanguageManager.appBundle), systemImage: "trash")
        }
    }

    /// Not `.onAppear { crashLog = ...previousCrashLog ?? "" }`:
    /// `previousCrashLog` reads a file from disk; on a cold open that is a
    /// 10–50 ms main-thread block. This runs the read off-main and assigns
    /// once, back on MainActor.
    private func loadCrashLog() async {
        let crashLogManager = dependencies.app.crashLogManager
        let log = await Task.detached(priority: .userInitiated) {
            crashLogManager.previousCrashLog ?? ""
        }.value
        crashLog = log
    }
}

// MARK: - Error Catalog View

@MainActor
struct ErrorCatalogView: View {
    @Environment(\.dependencies) var dependencies
    var logger: DebugLogger { dependencies.app.debugLogger }
    @State private var showingExport = false
    @State private var exportURL: URL?
    @State private var showingClearConfirm = false
    @State private var errorCount = 0
    @State private var isExporting = false

    @ViewBuilder
    var body: some View {
        List {
            errorSummarySection
            errorListSection
        }
        .zenFormBackground()
        .navigationTitle(String(localized: "Error Catalog", bundle: LanguageManager.appBundle))
        .toolbar { exportErrorsToolbarItem }
        .alert(String(localized: "Clear All Errors?", bundle: LanguageManager.appBundle), isPresented: $showingClearConfirm) {
            clearErrorsAlertActions
        } message: {
            Text(String(localized: "This will permanently delete all \(logger.errorCatalog.count) error records.", bundle: LanguageManager.appBundle))
        }
        .sheet(isPresented: $showingExport) {
            if let url = exportURL {
                ShareSheet(activityItems: [url])
            }
        }
    }

    @ViewBuilder
    private var clearErrorsAlertActions: some View {
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
        Button(String(localized: "Clear \(logger.errorCatalog.count) Errors", bundle: LanguageManager.appBundle), role: .destructive) {
            errorCount = logger.errorCatalog.count
            dependencies.app.debugLogger.clearErrorCatalog()
            debugLog("[ErrorCatalog] Cleared \(errorCount) errors")
        }
    }

    private var errorSummarySection: some View {
        // Always show count at top
        Section {
            HStack {
                Text(String(localized: "Total Errors", bundle: LanguageManager.appBundle))
                Spacer()
                Text("\(logger.errorCatalog.count)")
                    .foregroundColor(.red)
            }

            clearErrorsButton
        }
    }

    /// Inline rather than toolbar-only, for reliability.
    private var clearErrorsButton: some View {
        // Clear button inline for reliability
        Button(role: .destructive) {
            showingClearConfirm = true
        } label: {
            HStack {
                Image(systemName: "trash")
                Text(String(localized: "Clear All Errors", bundle: LanguageManager.appBundle))
            }
        }
        .disabled(logger.errorCatalog.isEmpty)
    }

    @ViewBuilder
    private var errorListSection: some View {
        if logger.errorCatalog.isEmpty {
            noErrorsPlaceholder
        } else {
            recentErrorsSection
        }
    }

    private var noErrorsPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 48)
                .foregroundColor(.green)
            Text(String(localized: "No Errors Recorded", bundle: LanguageManager.appBundle))
                .font(.headline)
            Text(String(localized: "All systems running smoothly", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var recentErrorsSection: some View {
        Section(String(localized: "Recent Errors (newest first)", bundle: LanguageManager.appBundle)) {
            ForEach(logger.errorCatalog.suffix(100).reversed()) { entry in
                errorRow(entry)
            }
        }
    }

    private func errorRow(_ entry: DebugLogger.LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.category)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.red)
                Spacer()
                Text(entry.timestamp, style: .date)
                    .font(.caption2)
                    .foregroundColor(AppTheme.textSecondary)
                Text(entry.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(AppTheme.textSecondary)
            }
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }

    private var exportErrorsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { exportErrorsButton }
    }

    @ViewBuilder
    private var exportErrorsButton: some View {
        if !logger.errorCatalog.isEmpty {
            Button(action: exportErrorCatalog) { exportErrorsLabel }
                .disabled(isExporting)
        }
    }

    /// The export is built and written on a background task so the main thread
    /// never blocks on file I/O. The previous synchronous write froze the UI and
    /// made subsequent share taps fail with "Failed to request default share
    /// mode" from iOS.
    private func exportErrorCatalog() {
        // Build + write the export on a background task so the
        // main thread never blocks waiting for file I/O. The
        // previous synchronous write froze the UI and caused
        // subsequent share taps to fail with
        // "Failed to request default share mode" from iOS.
        guard !isExporting else { return }
        isExporting = true
        let content = logger.exportErrorCatalog()
        let fileName = "hrv_error_catalog_\(Int(Date().timeIntervalSince1970)).txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        Task.detached(priority: .userInitiated) {
            let written = Self.writeExport(content, to: tempURL)
            await MainActor.run { finishErrorExport(written ? tempURL : nil) }
        }
    }

    /// false when the catalog could not be encoded or the write failed; the
    /// reason is logged, and the caller simply does not present a share sheet.
    nonisolated private static func writeExport(_ content: String, to url: URL) -> Bool {
        guard let data = content.data(using: .utf8) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            debugLog("[ErrorCatalog] Failed to write export file: \(error)")
            return false
        }
    }

    @MainActor
    private func finishErrorExport(_ url: URL?) {
        isExporting = false
        guard let url else { return }
        exportURL = url
        showingExport = true
    }

    @ViewBuilder
    private var exportErrorsLabel: some View {
        if isExporting {
            ProgressView().scaleEffect(0.8)
        } else {
            Image(systemName: "square.and.arrow.up")
        }
    }
}

// MARK: - Add Tag Sheet

struct AddTagSheet: View {
    @Binding var tagName: String
    @Binding var tagColor: Color
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let presetColors: [Color] = [
        .red, .orange, .yellow, .green, .mint, .teal,
        .cyan, .blue, .indigo, .purple, .pink, .brown
    ]

    var body: some View {
        NavigationStack {
            Form {
                tagNameSection
                tagColorSection
                tagPreviewSection
            }
            .zenFormBackground()
            .navigationTitle(String(localized: "New Tag", bundle: LanguageManager.appBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { addTagToolbar }
        }
    }

    private var tagNameSection: some View {
        Section(String(localized: "Tag Name", bundle: LanguageManager.appBundle)) {
            TextField(String(localized: "Enter tag name", bundle: LanguageManager.appBundle), text: $tagName)
        }
    }

    private var tagColorSection: some View {
        Section(String(localized: "Color", bundle: LanguageManager.appBundle)) {
            tagColorGrid
        }
    }

    private var tagColorGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
            tagColorSwatches
        }
        .padding(.vertical, 8)
    }

    private var tagColorSwatches: some View {
        ForEach(presetColors, id: \.self) { color in
            tagColorSwatch(color)
        }
    }

    private func tagColorSwatch(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 40, height: 40)
            .overlay(
                Circle()
                    .stroke(Color.primary, lineWidth: tagColor == color ? 3 : 0)
            )
            .onTapGesture {
                tagColor = color
            }
    }

    private var tagPreviewSection: some View {
        Section(String(localized: "Preview", bundle: LanguageManager.appBundle)) {
            HStack {
                Spacer()
                Text(tagName.isEmpty ? String(localized: "Tag Name", bundle: LanguageManager.appBundle) : tagName)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(tagColor)
                    .foregroundColor(.white)
                    .cornerRadius(16)
                Spacer()
            }
        }
    }

    @ToolbarContentBuilder
    private var addTagToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Cancel", bundle: LanguageManager.appBundle)) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(String(localized: "Save", bundle: LanguageManager.appBundle)) {
                onSave()
                dismiss()
            }
            .disabled(tagName.isEmpty)
        }
    }
}

// MARK: - Metric Explanations View

struct MetricExplanationsView: View {
    @Environment(SettingsManager.self) var settingsManager

    private var age: Int? {
        settingsManager.settings.age
    }

    var body: some View {
        List {
            ageBanner

            timeDomainMetrics
            timeDomainMetricsMore

            frequencyDomainMetrics
            frequencyDomainMetricsMore

            nonlinearMetrics

            derivedMetrics
        }
        .zenFormBackground()
        .navigationTitle(String(localized: "Metric Guide", bundle: LanguageManager.appBundle))
    }

    @ViewBuilder
    private var ageBanner: some View {
        if let age {
            Section {
                ageBannerRow(age)
            }
        }
    }

    private func ageBannerRow(_ age: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.fill")
                .foregroundStyle(AppTheme.primaryGradient)
            Text(String(localized: "Ranges shown for age \(age)", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private var timeDomainMetrics: some View {
        Section {
            MetricExplanationRow(
                metric: "RMSSD",
                fullName: String(localized: "Root Mean Square of Successive Differences", bundle: LanguageManager.appBundle),
                description: rmssdDescription,
                interpretation: rmssdInterpretation,
                action: String(localized: "A drop of 20%+ below baseline is a common rule of thumb for easing off — weigh it against training, sleep and how you feel. Consistently above your average is the pattern usually linked with being well recovered.", bundle: LanguageManager.appBundle)
            )

            MetricExplanationRow(
                metric: "SDNN",
                fullName: String(localized: "Standard Deviation of NN Intervals", bundle: LanguageManager.appBundle),
                description: String(localized: "Captures TOTAL heart rate variability — both your sympathetic (fight-or-flight) and parasympathetic (rest-and-recover) branches working together. SDNN is the big picture; RMSSD zooms into the recovery side.", bundle: LanguageManager.appBundle),
                interpretation: String(localized: "Short-term (5 min): typically 50-100+ ms. Only compare between recordings of similar duration — SDNN depends heavily on recording length. RMSSD is more consistent across different windows.", bundle: LanguageManager.appBundle),
                action: String(localized: "A declining SDNN trend alongside declining RMSSD reinforces that you need more recovery. If SDNN drops while RMSSD stays stable, your sympathetic system may be withdrawing.", bundle: LanguageManager.appBundle)
            )

        }
    }

    private var timeDomainMetricsMore: some View {
        Section {
            MetricExplanationRow(
                metric: "pNN50",
                fullName: String(localized: "Recovery Fraction", bundle: LanguageManager.appBundle),
                description: String(localized: "What fraction of your heartbeats show strong parasympathetic influence? pNN50 counts successive intervals differing by >50ms — think of it as your \"recovery fraction\" per beat.", bundle: LanguageManager.appBundle),
                interpretation: pnn50Interpretation,
                action: String(localized: "Chronically below 5%? The same interventions that boost RMSSD apply: better sleep, more aerobic base training, stress reduction. Above 15% at rest means your recovery system is firing well.", bundle: LanguageManager.appBundle)
            )
        } header: {
            Text(String(localized: "Time Domain", bundle: LanguageManager.appBundle))
        }
    }

    private var frequencyDomainMetrics: some View {
        Section {
            MetricExplanationRow(
                metric: "LF Power",
                fullName: String(localized: "Blood Pressure Regulation (0.04-0.15 Hz)", bundle: LanguageManager.appBundle),
                description: String(localized: "Often incorrectly called \"sympathetic activity\" in older references. Modern research shows LF primarily reflects your baroreceptor loop — the system that fine-tunes blood pressure — using BOTH nervous system branches.", bundle: LanguageManager.appBundle),
                interpretation: String(localized: "High LF at rest means active blood pressure regulation, not stress. Very low LF is actually concerning — it may indicate autonomic withdrawal. Don't interpret LF in isolation.", bundle: LanguageManager.appBundle)
            )

            MetricExplanationRow(
                metric: "HF Power",
                fullName: String(localized: "Vagal Signature (0.15-0.4 Hz)", bundle: LanguageManager.appBundle),
                description: String(localized: "This band is the one most closely associated with parasympathetic activity. HF oscillations come from respiratory sinus arrhythmia — your heart speeds up when you inhale and slows when you exhale. The stronger this coupling, the more vagal tone you have.", bundle: LanguageManager.appBundle),
                interpretation: String(localized: "Higher = stronger vagal tone and recovery. If you used the breathing mandala, expect elevated HF — the 5.5 breaths/min pattern specifically maximizes this effect. That's real vagal activation.", bundle: LanguageManager.appBundle),
                action: String(localized: "A rising HF trend over weeks = improving recovery capacity. Falling HF + rising LF/HF ratio = increasing stress load.", bundle: LanguageManager.appBundle)
            )

        }
    }

    private var frequencyDomainMetricsMore: some View {
        Section {
            MetricExplanationRow(
                metric: "LF/HF Ratio",
                fullName: String(localized: "Autonomic Balance Indicator", bundle: LanguageManager.appBundle),
                description: String(localized: "A rough compass pointing toward stress or recovery. Below 2.0 at rest is normal. Above 3.0 consistently suggests sympathetic dominance — stress, poor sleep, or incomplete recovery.", bundle: LanguageManager.appBundle),
                interpretation: String(localized: "Useful for spotting trends over days. A gradually climbing ratio signals increasing stress load even when individual readings look acceptable. Rely on RMSSD and DFA \u{03B1}1 for actual recovery decisions.", bundle: LanguageManager.appBundle)
            )
        } header: {
            Text(String(localized: "Frequency Domain", bundle: LanguageManager.appBundle))
        }
    }

    private var nonlinearMetrics: some View {
        Section {
            MetricExplanationRow(
                metric: "SD1 & SD2",
                fullName: String(localized: "Poincar\u{00E9} Plot Geometry", bundle: LanguageManager.appBundle),
                description: String(localized: "Your heart's visual fingerprint. SD1 (cloud width) captures rapid beat-to-beat variation — your parasympathetic signature. SD2 (cloud length) captures slower rhythms — the combined output of both ANS branches.", bundle: LanguageManager.appBundle),
                interpretation: String(localized: "Wide, spread-out comet shape = flexible, recovered nervous system. Tight, narrow cluster = rigid, stressed. Over time you'll recognize YOUR patterns in the Poincar\u{00E9} plot at a glance.", bundle: LanguageManager.appBundle)
            )

            dfaAlpha1Row
        } header: {
            Text(String(localized: "Nonlinear Analysis", bundle: LanguageManager.appBundle))
        }
    }

    /// The DFA α1 row, extracted so `nonlinearMetrics` stays under the
    /// 20-line declaration limit after this row's copy grew.
    ///
    /// This row deliberately omits the fixed resting interpretation the Help
    /// Center also omits: "separates real recovery from noise", "~0.5: Random
    /// noise — high RMSSD here is a mirage", and an action line telling the
    /// reader not to trust their own RMSSD. See
    /// `HelpScienceCatalog.dfaExplainedSections` for why none of that is
    /// supportable.
    private var dfaAlpha1Row: some View {
        MetricExplanationRow(
            metric: "DFA \u{03B1}1",
            fullName: String(localized: "Fractal Correlation (\u{03B1}1)", bundle: LanguageManager.appBundle),
            description: String(localized: "Describes the PATTERN of your beat-to-beat variation, not its size — whether successive intervals are correlated or drift independently. RMSSD misses this, so two readings with the same RMSSD can differ in \u{03B1}1.", bundle: LanguageManager.appBundle),
            interpretation: String(localized: "0.75-1.0: the app's resting reference range, where most resting readings sit. 0.60-0.75: below it. ~0.5: intervals close to uncorrelated. >1.0: more correlated than the range — seen with stress, and with slow breathing.", bundle: LanguageManager.appBundle),
            action: String(localized: "The reference range is a convention, not a validated readiness scale — the published 0.75 figure comes from graded-exercise testing. Best Recovery prefers \u{03B1}1 in that range to pick a stable stretch of the night.", bundle: LanguageManager.appBundle)
        )
    }

    private var derivedMetrics: some View {
        Section {
            MetricExplanationRow(
                metric: "Stress Index",
                fullName: String(localized: "Baevsky's Sympathetic Pressure Index", bundle: LanguageManager.appBundle),
                description: String(localized: "From Russian space medicine. Measures how rigidly your heart beats by analyzing your RR interval distribution. When stress rises, your heart rhythm narrows and becomes uniform — the Stress Index captures that compression.", bundle: LanguageManager.appBundle),
                interpretation: stressIndexInterpretation,
                action: String(localized: "Stress Index rising while RMSSD falls is a pattern of accumulated stress or early illness. If both move in the wrong direction for 2+ days, take a rest day.", bundle: LanguageManager.appBundle)
            )

            MetricExplanationRow(
                metric: "Readiness",
                fullName: String(localized: "Daily Quick Check (1-10)", bundle: LanguageManager.appBundle),
                description: String(localized: "Compares today's RMSSD to your 7-day rolling average, adjusted by DFA \u{03B1}1 quality. Available from day one, before your full 60-day baseline develops.", bundle: LanguageManager.appBundle),
                interpretation: String(localized: "7+: Above your recent norm — green light for intensity. 5-7: Average day — listen to your body. Below 5: Significantly below your recent levels — prioritize recovery.", bundle: LanguageManager.appBundle),
                action: String(localized: "When Readiness and Recovery Score disagree, that's information: Readiness only sees today's HRV, Recovery Score integrates sleep and vitals. High Readiness + low Recovery = your HRV looks fine but poor sleep or elevated breathing rate is showing up.", bundle: LanguageManager.appBundle)
            )
        } header: {
            Text(String(localized: "Composite Metrics", bundle: LanguageManager.appBundle))
        }
    }

    // MARK: - Age-Personalized Strings

    private var rmssdDescription: String {
        guard let age else {
            return "Your core recovery metric. RMSSD measures beat-to-beat heart rate variation driven by your parasympathetic nervous system — your body's brake pedal. This is the single most validated metric for daily recovery monitoring."
        }
        let ctx = rmssdContextForExplanations(age: age)
        return "Your core recovery metric. RMSSD measures beat-to-beat heart rate variation driven by your parasympathetic nervous system — your body's brake pedal. At \(age), typical resting RMSSD falls between \(ctx.range) (median \(ctx.median)). \(ctx.brief)"
    }

    private var rmssdInterpretation: String {
        guard let age else {
            return "Highly individual — ranges from 10-120+ ms depending on age and fitness. Set your birthday in Settings to see your age-specific range. Your personal trend matters more than any single number."
        }
        let ctx = rmssdContextForExplanations(age: age)
        return "Above \(ctx.median) is healthy for your age. \(ctx.athleteNote). What matters most: your personal trend over weeks, not any single reading."
    }

    private var pnn50Interpretation: String {
        if let age, age >= 50 {
            return "At \(age), a resting pNN50 above 5% indicates active parasympathetic modulation. Above 10% is strong. Lower values are more common with age — it doesn't mean the metric is broken, it means fewer heartbeats cross the 50ms threshold as overall variability decreases."
        }
        return "0-5%: Low parasympathetic activity. 5-15%: Moderate — typical resting range. 15-25%+: Strong recovery tone. Tracks closely with RMSSD but is easier to intuit: \"15% of my heartbeats show strong recovery activity.\""
    }

    private var stressIndexInterpretation: String {
        if let age, age >= 50 {
            return "Below 100 at rest is relaxed. 100-200 mildly elevated. Above 300 is significant. At \(age), some baseline elevation compared to younger adults is expected — compare to YOUR average, not population norms."
        }
        return "Below 50: Deep rest. 50-100: Relaxed. 100-150: Mildly elevated. 150-300: Moderate stress. Above 300: High stress — clear signal to recover."
    }

    /// The age-band copy the RMSSD explainer quotes.
    struct RMSSDAgeContext {
        let range: String
        let median: String
        let brief: String
        let athleteNote: String
    }

    private func rmssdContextForExplanations(age: Int) -> RMSSDAgeContext {
        switch age {
        case ..<20: RMSSDAgeContext(range: "30-120 ms", median: "~55 ms", brief: "Your ANS is at peak dynamism.", athleteNote: "Young athletes often see 70-130+ ms")
        case 20 ..< 30: RMSSDAgeContext(range: "25-105 ms", median: "~42 ms", brief: "Your ANS is near peak capacity — sleep and fitness pay off directly.", athleteNote: "Endurance athletes your age often reach 60-120+ ms")
        case 30 ..< 40: RMSSDAgeContext(range: "20-80 ms", median: "~35 ms", brief: "Aerobic fitness and sleep quality are increasingly important levers.", athleteNote: "Active athletes your age often maintain 45-90+ ms")
        case 40 ..< 50: RMSSDAgeContext(range: "15-60 ms", median: "~25 ms", brief: "An RMSSD of 25ms at \(age) reflects the same autonomic health as 42ms at 25 — the app accounts for this.", athleteNote: "Athletes your age often reach 30-75+ ms")
        case 50 ..< 60: RMSSDAgeContext(range: "10-50 ms", median: "~22 ms", brief: "Lower absolute numbers are expected. Consistent aerobic exercise is your strongest lever.", athleteNote: "Active individuals your age often maintain 25-55+ ms")
        case 60 ..< 70: RMSSDAgeContext(range: "8-40 ms", median: "~18 ms", brief: "What matters is YOUR baseline and trend. Many active people your age maintain strong relative tone.", athleteNote: "Fit individuals your age often see 20-45+ ms")
        default: RMSSDAgeContext(range: "6-35 ms", median: "~15 ms", brief: "Relative patterns still carry the same meaning. A rising trend is still improving recovery.", athleteNote: "Active individuals your age often maintain 15-35+ ms")
        }
    }
}

private struct MetricExplanationRow: View {
    let metric: String
    let fullName: String
    let description: String
    let interpretation: String
    var action: String?

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            metricHeaderButton

            metricDetail
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var metricDetail: some View {
        if isExpanded {
            VStack(alignment: .leading, spacing: 8) {
                Text(description)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                interpretationNote

                actionNote
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var actionNote: some View {
        if let action {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(AppTheme.primaryGradient)
                    .font(.caption)
                Text(action)
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(AppTheme.primary.opacity(0.08))
            .cornerRadius(8)
        }
    }

    private var interpretationNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .foregroundColor(.yellow)
                .font(.caption)
            Text(interpretation)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(Color.yellow.opacity(0.1))
        .cornerRadius(8)
    }

    private var metricHeaderButton: some View {
        Button {
            withAnimation {
                isExpanded.toggle()
            }
        } label: {
            metricHeaderLabel
        }
    }

    private var metricHeaderLabel: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(metric)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(fullName)
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
            Spacer()
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .foregroundColor(AppTheme.textSecondary)
        }
    }
}
