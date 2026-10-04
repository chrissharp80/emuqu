import SwiftUI
import UIKit

// MARK: - Debug Log View

struct DebugLogView: View {
    @Environment(\.dependencies) var dependencies
    var logger: DebugLogger { dependencies.app.debugLogger }
    @State private var showingClearConfirm = false

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

    /// The same export as Settings › Diagnostics: the log file is written when
    /// the share sheet asks for it, so the tap opens the sheet at once.
    private var exportLogsButton: some View {
        ShareLink(item: DiagnosticLogExport(), preview: DiagnosticLogExport.preview) {
            Label(String(localized: "Export Diagnostic Log", bundle: LanguageManager.appBundle), systemImage: "square.and.arrow.up")
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
        ForEach(Array(presetColors.enumerated()), id: \.offset) { index, color in
            tagColorSwatch(color, name: Self.presetColorNames[index])
        }
    }

    /// VoiceOver names for `presetColors`, in the same order: the swatches
    /// were unlabelled circles, chosen by colour alone.
    private static var presetColorNames: [String] {
        let b = LanguageManager.appBundle
        return [
            String(localized: "Red", bundle: b), String(localized: "Orange", bundle: b),
            String(localized: "Yellow", bundle: b), String(localized: "Green", bundle: b),
            String(localized: "Mint", bundle: b), String(localized: "Teal", bundle: b),
            String(localized: "Cyan", bundle: b), String(localized: "Blue", bundle: b),
            String(localized: "Indigo", bundle: b), String(localized: "Purple", bundle: b),
            String(localized: "Pink", bundle: b), String(localized: "Brown", bundle: b)
        ]
    }

    private func tagColorSwatch(_ color: Color, name: String) -> some View {
        Circle()
            .fill(color)
            .frame(width: 40, height: 40)
            .overlay(
                Circle()
                    .stroke(Color.primary, lineWidth: tagColor == color ? 3 : 0)
            )
            // 44pt touch target around the 40pt swatch.
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .onTapGesture {
                tagColor = color
            }
            .accessibilityElement()
            .accessibilityLabel(name)
            .accessibilityAddTraits(tagColor == color ? [.isButton, .isSelected] : .isButton)
    }

    private var tagPreviewSection: some View {
        Section(String(localized: "Preview", bundle: LanguageManager.appBundle)) {
            HStack {
                Spacer()
                Text(tagName.isEmpty ? String(localized: "Tag Name", bundle: LanguageManager.appBundle) : tagName)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    // Drawn the way TagChip draws a selected tag on the Record tab:
                    // primary text on a tint, which stays readable on yellow,
                    // mint or cyan where white text did not.
                    .background(Capsule().fill(tagColor.opacity(0.35)))
                    .foregroundStyle(AppTheme.textPrimary)
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
            .disabled(tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                metric: String(localized: "LF Power", bundle: LanguageManager.appBundle),
                fullName: String(localized: "Blood Pressure Regulation (0.04-0.15 Hz)", bundle: LanguageManager.appBundle),
                description: String(
                    localized: "Often incorrectly called \"sympathetic activity\" in older references. Modern research shows LF primarily reflects your baroreceptor loop — the system that fine-tunes blood pressure — using BOTH nervous system branches.",
                    bundle: LanguageManager.appBundle
                ),
                interpretation: String(localized: "High LF at rest means active blood pressure regulation, not stress. Very low LF is uncommon at rest. Don't interpret LF in isolation — read it next to your other metrics.", bundle: LanguageManager.appBundle)
            )

            hfPowerRow
        }
    }

    /// The HF Power row of the Frequency Domain section.
    private var hfPowerRow: some View {
        MetricExplanationRow(
            metric: String(localized: "HF Power", bundle: LanguageManager.appBundle),
            fullName: String(localized: "Vagal Signature (0.15-0.4 Hz)", bundle: LanguageManager.appBundle),
            description: String(
                localized: "This band is the one most closely associated with parasympathetic activity. HF oscillations come from respiratory sinus arrhythmia — your heart speeds up when you inhale and slows when you exhale. The stronger this coupling, the more vagal tone you have.",
                bundle: LanguageManager.appBundle
            ),
            interpretation: String(
                localized: "Higher at rest generally means stronger vagal tone. Slow breathing, like the mandala's 5.5 breaths/min (about 0.09 Hz), moves breathing-linked power into the LF band, so expect LF, not HF, to rise during those sessions.",
                bundle: LanguageManager.appBundle
            ),
            action: String(
                localized: "A rising resting HF trend over weeks usually goes with improving recovery capacity. Read it alongside RMSSD rather than on its own.",
                bundle: LanguageManager.appBundle
            )
        )
    }

    private var frequencyDomainMetricsMore: some View {
        Section {
            MetricExplanationRow(
                metric: String(localized: "LF/HF Ratio", bundle: LanguageManager.appBundle),
                fullName: String(localized: "Low- to high-frequency power ratio", bundle: LanguageManager.appBundle),
                description: String(localized: "A ratio of two frequency bands. Emuqu uses it only to help choose the analysis window; it is not read as a stress or recovery measure.", bundle: LanguageManager.appBundle),
                interpretation: String(localized: "Older references read it as a stress or recovery measure; current evidence does not support that. Rely on RMSSD and DFA \u{03B1}1.", bundle: LanguageManager.appBundle)
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
            interpretation: String(
                localized: "0.75-1.0: the app's resting reference range, where most resting readings sit. 0.60-0.75: below it. ~0.5: intervals close to uncorrelated. >1.0: more correlated than the range — seen with stress, and with slow breathing.",
                bundle: LanguageManager.appBundle
            ),
            action: String(localized: "The reference range is a convention, not a validated readiness scale — the published 0.75 figure comes from graded-exercise testing. Best Recovery prefers \u{03B1}1 in that range to pick a stable stretch of the night.", bundle: LanguageManager.appBundle)
        )
    }

    private var derivedMetrics: some View {
        Section {
            stressIndexRow
            readinessRow
        } header: {
            Text(String(localized: "Composite Metrics", bundle: LanguageManager.appBundle))
        }
    }

    private var stressIndexRow: some View {
        MetricExplanationRow(
            metric: String(localized: "Stress Index", bundle: LanguageManager.appBundle),
            fullName: String(localized: "Baevsky's Sympathetic Pressure Index", bundle: LanguageManager.appBundle),
            description: String(
                localized: "From Russian space medicine. Measures how rigidly your heart beats by analyzing your RR interval distribution. When stress rises, your heart rhythm narrows and becomes uniform — the Stress Index captures that compression.",
                bundle: LanguageManager.appBundle
            ),
            interpretation: stressIndexInterpretation,
            action: String(localized: "Stress Index rising while RMSSD falls is a pattern of accumulated training or life stress, short sleep, or sometimes the start of an illness. If both move in the wrong direction for 2+ days, take a rest day.", bundle: LanguageManager.appBundle)
        )
    }

    private var readinessRow: some View {
        MetricExplanationRow(
            metric: String(localized: "Readiness", bundle: LanguageManager.appBundle),
            fullName: String(localized: "Daily Quick Check (1-10)", bundle: LanguageManager.appBundle),
            description: String(
                localized: """
                    Built from this one reading. Today's RMSSD scores best when it sits close to your usual level \
                    (your own baseline of up to 60 nights once there is one, raised for a high VO2max); a large swing \
                    either way scores lower. DFA \u{03B1}1 and the balance of the stress and rest indices then adjust \
                    it, and recent hard training lifts it, since low HRV is expected then. Available from day one.
                    """,
                bundle: LanguageManager.appBundle
            ),
            interpretation: String(localized: "7+: Today's reading is close to your usual pattern — green light for intensity. 5-7: Some signals are off — listen to your body. Below 5: Several signals are well away from your usual — prioritize recovery.", bundle: LanguageManager.appBundle),
            action: String(localized: """
                When Readiness and Recovery Score disagree, that's information: Readiness sees only this reading's \
                HRV, Recovery Score adds sleep and vitals. High Readiness + low Recovery = your HRV looks fine but \
                poor sleep or elevated breathing rate is showing up.
                """, bundle: LanguageManager.appBundle)
        )
    }

    // MARK: - Age-Personalized Strings

    private var rmssdDescription: String {
        let bundle = LanguageManager.appBundle
        guard let age else {
            return String(localized: "Your core recovery metric. RMSSD measures beat-to-beat heart rate variation driven by your parasympathetic nervous system — your body's brake pedal. It is the most widely studied HRV measure for day-to-day tracking.", bundle: bundle)
        }
        let ctx = rmssdContextForExplanations(age: age)
        return String(localized: "Your core recovery metric. RMSSD measures beat-to-beat heart rate variation driven by your parasympathetic nervous system — your body's brake pedal. At \(age), typical resting RMSSD falls between \(ctx.range) (median \(ctx.median)). \(ctx.brief)", bundle: bundle)
    }

    private var rmssdInterpretation: String {
        let bundle = LanguageManager.appBundle
        guard let age else {
            return String(localized: "Highly individual — ranges from 10-120+ ms depending on age and fitness. Set your birthday in Settings to see your age-specific range. Your personal trend matters more than any single number.", bundle: bundle)
        }
        let ctx = rmssdContextForExplanations(age: age)
        return String(localized: "Around \(ctx.median) is typical for your age band. \(ctx.athleteNote). What matters most: your personal trend over weeks, not any single reading.", bundle: bundle)
    }

    private var pnn50Interpretation: String {
        let bundle = LanguageManager.appBundle
        if let age, age >= 50 {
            return String(
                localized: "At \(age), a resting pNN50 above 5% indicates active parasympathetic modulation. Above 10% is strong. Lower values are more common with age — it doesn't mean the metric is broken, it means fewer heartbeats cross the 50ms threshold as overall variability decreases.",
                bundle: bundle
            )
        }
        return String(localized: "0-5%: Low parasympathetic activity. 5-15%: Moderate — typical resting range. 15-25%+: Strong recovery tone. Tracks closely with RMSSD but is easier to intuit: \"15% of my heartbeats show strong recovery activity.\"", bundle: bundle)
    }

    /// The bands the app labels a reading with (`HRVThresholds`), so the
    /// glossary and the score screen agree. They used to differ: an index of
    /// 120 was "normal band" in the findings and "mildly elevated" here.
    private var stressIndexInterpretation: String {
        let bundle = LanguageManager.appBundle
        let bands = String(localized: "Below 50: very low. 50-100: low. 100-150: normal. 150-200: elevated. Above 200: high, and above 300 a clear signal to recover.", bundle: bundle)
        guard let age, age >= 50 else { return bands }
        return bands + " " + String(localized: "At \(age), some baseline elevation compared to younger adults is expected — compare to YOUR average, not population norms.", bundle: bundle)
    }

    /// The age-band copy the RMSSD explainer quotes.
    struct RMSSDAgeContext {
        let range: String
        let median: String
        let brief: String
        let athleteNote: String
    }

    private func rmssdContextForExplanations(age: Int) -> RMSSDAgeContext {
        let band = Self.ageBand(age)
        return RMSSDAgeContext(range: band.range, median: band.median, brief: ageBrief(age), athleteNote: athleteNote(age))
    }

    private static func ageBand(_ age: Int) -> (range: String, median: String) {
        switch age {
        case ..<20: ("30-120 ms", "~55 ms")
        case 20 ..< 30: ("25-105 ms", "~42 ms")
        case 30 ..< 40: ("20-80 ms", "~35 ms")
        case 40 ..< 50: ("15-60 ms", "~25 ms")
        case 50 ..< 60: ("10-50 ms", "~22 ms")
        case 60 ..< 70: ("8-40 ms", "~18 ms")
        default: ("6-35 ms", "~15 ms")
        }
    }

    private func ageBrief(_ age: Int) -> String {
        let b = LanguageManager.appBundle
        switch age {
        case ..<20: return String(localized: "Your ANS is at peak dynamism.", bundle: b)
        case 20 ..< 30: return String(localized: "Your ANS is near peak capacity — sleep and fitness pay off directly.", bundle: b)
        case 30 ..< 40: return String(localized: "Aerobic fitness and sleep quality are increasingly important levers.", bundle: b)
        case 40 ..< 50: return String(localized: "An RMSSD of 25ms at \(age) reflects the same autonomic health as 42ms at 25 — the app accounts for this.", bundle: b)
        case 50 ..< 60: return String(localized: "Lower absolute numbers are expected. Consistent aerobic exercise is your strongest lever.", bundle: b)
        case 60 ..< 70: return String(localized: "What matters is YOUR baseline and trend. Many active people your age maintain strong relative tone.", bundle: b)
        default: return String(localized: "Relative patterns still carry the same meaning. A rising trend is still improving recovery.", bundle: b)
        }
    }

    private func athleteNote(_ age: Int) -> String {
        let b = LanguageManager.appBundle
        switch age {
        case ..<20: return String(localized: "Young athletes often see 70-130+ ms", bundle: b)
        case 20 ..< 30: return String(localized: "Endurance athletes your age often reach 60-120+ ms", bundle: b)
        case 30 ..< 40: return String(localized: "Active athletes your age often maintain 45-90+ ms", bundle: b)
        case 40 ..< 50: return String(localized: "Athletes your age often reach 30-75+ ms", bundle: b)
        case 50 ..< 60: return String(localized: "Active individuals your age often maintain 25-55+ ms", bundle: b)
        case 60 ..< 70: return String(localized: "Fit individuals your age often see 20-45+ ms", bundle: b)
        default: return String(localized: "Active individuals your age often maintain 15-35+ ms", bundle: b)
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
                Image(systemName: "arrow.forward.circle.fill")
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
