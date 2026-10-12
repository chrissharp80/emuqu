import SwiftUI

// Developer-facing diagnostics screens: MetricKit history, the sampled memory
// trace and the per-session RR storage audit detail.
// Internal (not `private`) because their call sites live in other files.

// MARK: - MetricKit History (per-payload)

struct MetricKitHistoryView: View {
    let payloads: [[String: Any]]

    var body: some View {
        List {
            Section(String(localized: "What this shows", bundle: LanguageManager.appBundle)) {
                Text("Each row is a MetricKit payload from iOS. The 'summary' line categorizes any abnormal app exits — e.g. `bg_memory_resource_limit=1` means iOS killed the app once in background for exceeding the memory budget.", bundle: LanguageManager.appBundle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            ForEach(Array(payloads.enumerated()), id: \.offset) { _, payload in
                payloadRow(payload)
            }
        }
        .navigationTitle(String(localized: "MetricKit History", bundle: LanguageManager.appBundle))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func payloadRow(_ payload: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            payloadHeader(payload)
            Text(payload["summary"] as? String ?? String(localized: "(no summary)", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundStyle(.primary)
            if let begin = payload["begin"] as? String, let end = payload["end"] as? String {
                Text("Window: \(begin) → \(end)", bundle: LanguageManager.appBundle)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            payloadDetail(payload)
        }
        .padding(.vertical, 4)
    }

    private func payloadHeader(_ payload: [String: Any]) -> some View {
        HStack {
            Text((payload["kind"] as? String ?? "?").uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(payloadKindColor(payload["kind"] as? String))
            Text(payload["received_at"] as? String ?? "—")
                .font(.caption2.monospaced())
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    private func payloadDetail(_ payload: [String: Any]) -> some View {
        if let bg = payload["exit_background"] as? [String: Int] {
            exitBreakdown(String(localized: "Background exits", bundle: LanguageManager.appBundle), counts: bg)
        }
        if let fg = payload["exit_foreground"] as? [String: Int] {
            exitBreakdown(String(localized: "Foreground exits", bundle: LanguageManager.appBundle), counts: fg)
        }
        if let peak = payload["peak_memory_bytes"] as? Double {
            Text("Peak memory: \(ByteCountFormatter.string(fromByteCount: Int64(peak), countStyle: .memory))", bundle: LanguageManager.appBundle)
                .font(.caption2)
        }
    }

    @ViewBuilder
    private func exitBreakdown(_ title: String, counts: [String: Int]) -> some View {
        let nonZero = counts.filter { $0.value > 0 && $0.key != "normal" }
        if !nonZero.isEmpty {
            exitBreakdownColumn(title, rows: nonZero.sorted(by: { $0.key < $1.key }))
        }
    }

    private func exitBreakdownColumn(_ title: String, rows: [(key: String, value: Int)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.semibold))
            ForEach(rows, id: \.key) { exitBreakdownRow($0) }
        }
    }

    private func exitBreakdownRow(_ entry: (key: String, value: Int)) -> some View {
        HStack {
            Text("  \(entry.key)").font(.caption2.monospaced())
            Spacer()
            Text("\(entry.value)").font(.caption2.monospaced().bold())
                .foregroundStyle(.red)
        }
    }

    private func payloadKindColor(_ kind: String?) -> Color {
        switch kind {
        case "diagnostic": return .red
        case "metric": return .blue
        default: return .secondary
        }
    }
}

// MARK: - Memory Trace (sampled time series)

struct MemoryTraceView: View {
    let trace: [[String: Any]]

    var body: some View {
        List {
            summarySection
            recentSamplesSection
        }
        .navigationTitle(String(localized: "Memory & Thermal", bundle: LanguageManager.appBundle))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summarySection: some View {
        Section(String(localized: "Sampled every 5 s during recording", bundle: LanguageManager.appBundle)) {
            Text("`phys_footprint` is what iOS uses for memory-budget enforcement. iOS will SIGKILL background apps that exceed ~150–250 MB depending on device + system memory pressure. If you see termination correlated with a memory ramp, that's your cause.", bundle: LanguageManager.appBundle)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            summary
        }
    }

    private var recentSamplesSection: some View {
        Section(String(localized: "Recent samples (newest last)", bundle: LanguageManager.appBundle)) {
            ForEach(Array(trace.suffix(200).enumerated()), id: \.offset) { _, sample in
                sampleRow(sample)
            }
        }
    }

    /// Memory warnings across the whole trace. `memory_warnings_total` counts
    /// from 0 in each process, and the trace spans several launches, so the
    /// window's total is each process's highest count added up; a process
    /// begins at its `launch` sample. (The crash report reads one process's
    /// samples only, where the highest count is the total.)
    private var memoryWarnings: Int {
        var total = 0
        var current = 0
        for sample in trace {
            if sample["reason"] as? String == "launch" {
                total += current
                current = 0
            }
            current = max(current, sample["memory_warnings_total"] as? Int ?? 0)
        }
        return total + current
    }

    /// Peak / average memory and peak thermal come from the same
    /// `MemoryTraceSummary` the crash report uses, so the two read the trace
    /// schema one way.
    private var summary: some View {
        let traceSummary = MemoryTraceSummary(trace: trace)
        let peak = traceSummary.peakMB
        let avg = traceSummary.averageMB
        let thermal = traceSummary.peakThermal
        let warnings = memoryWarnings
        return VStack(alignment: .leading, spacing: 4) {
            HStack { Text("Peak memory", bundle: LanguageManager.appBundle).foregroundStyle(AppTheme.textSecondary); Spacer(); Text("\(String(format: "%.1f", locale: LanguageManager.appLocale, peak)) MB").bold() }
            HStack { Text("Average memory", bundle: LanguageManager.appBundle).foregroundStyle(AppTheme.textSecondary); Spacer(); Text("\(String(format: "%.1f", locale: LanguageManager.appLocale, avg)) MB") }
            HStack { Text("Peak thermal", bundle: LanguageManager.appBundle).foregroundStyle(AppTheme.textSecondary); Spacer(); Text(thermal).foregroundStyle(thermalColor(thermal)) }
            HStack { Text("Memory warnings", bundle: LanguageManager.appBundle).foregroundStyle(AppTheme.textSecondary); Spacer(); Text("\(warnings)").foregroundStyle(warnings > 0 ? .orange : .primary) }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func sampleRow(_ raw: [String: Any]) -> some View {
        let sample = MemoryTraceSample(raw)
        let ts = sample.timestamp ?? "—"
        let mb = sample.memoryMB ?? "?"
        let thermal = sample.thermal ?? "?"
        let reason = sample.reason ?? "?"
        HStack(spacing: 8) {
            Text(ts.suffix(8).description).font(.caption2.monospaced())
            Spacer()
            Text("\(mb) MB", bundle: LanguageManager.appBundle).font(.caption2.monospaced().bold())
            Text(thermal).font(.caption2)
                .foregroundStyle(thermalColor(thermal))
            Text(reason).font(.caption2).foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func thermalColor(_ thermal: String) -> Color {
        switch thermal {
        case "fair": .yellow
        case "serious": .orange
        case "critical": .red
        default: .secondary
        }
    }
}

// MARK: - RR Storage Audit Detail (per-session list)

/// Per-session detail view for the RR Storage Audit. Lists every
/// archived session with its rrSeries status (archive / backup /
/// neither), its archive and backup beat counts and its archive file size.
struct RRStorageAuditDetailView: View {
    let report: SessionStorageDiagnostic.Report

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        List {
            Section(String(localized: "Summary", bundle: LanguageManager.appBundle)) {
                Text("Tap a session to see beat counts and file paths. Status icon shows where the raw beat stream lives.", bundle: LanguageManager.appBundle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            sessionsSection
            orphanedBackupsSection
        }
        .navigationTitle(String(localized: "RR Storage Audit", bundle: LanguageManager.appBundle))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sessionsSection: some View {
        Section(String(localized: "Sessions (\(report.sessions.count))", bundle: LanguageManager.appBundle)) {
            ForEach(report.sessions, id: \.sessionId) { s in
                sessionRow(s)
            }
        }
    }

    @ViewBuilder
    private var orphanedBackupsSection: some View {
        if !report.orphanedBackupIds.isEmpty {
            Section(String(localized: "Orphaned backups (\(report.orphanedBackupIds.count))", bundle: LanguageManager.appBundle)) {
                orphanedBackupRows
                Text("These RR backups exist in the safety net but their parent session isn't in the archive index. Usually means a recording finished and was backed up but the archive write didn't complete.", bundle: LanguageManager.appBundle)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private var orphanedBackupRows: some View {
        ForEach(report.orphanedBackupIds, id: \.self) { id in
            Text(id.uuidString.prefix(8) + "…")
                .font(.system(.caption, design: .monospaced))
        }
    }

    @ViewBuilder
    private func sessionRow(_ s: SessionStorageDiagnostic.SessionReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sessionRowHeader(s)
            if let summary = s.analysisSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            sessionRowCounts(s)
            Text(s.sessionId.uuidString.prefix(8) + "…")
                .scaledFont(size: 10, design: .monospaced)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func sessionRowHeader(_ s: SessionStorageDiagnostic.SessionReport) -> some View {
        HStack {
            Image(systemName: statusIcon(s.status))
                .foregroundStyle(statusColor(s.status))
            Text(Self.dateFormatter.string(from: s.date))
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(verbatim: s.sessionType.displayName)
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func sessionRowCounts(_ s: SessionStorageDiagnostic.SessionReport) -> some View {
        HStack(spacing: 12) {
            Text("archive: \(s.archiveBeatCount) beats", bundle: LanguageManager.appBundle)
            Text("backup: \(s.backupBeatCount) beats", bundle: LanguageManager.appBundle)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: s.archiveFileSize, countStyle: .file))
        }
        .font(.caption2)
        .foregroundStyle(AppTheme.textSecondary)
    }

    private func statusIcon(_ status: SessionStorageDiagnostic.RRStatus) -> String {
        switch status {
        case .bothPresent: "checkmark.seal.fill"
        case .archivedFull: "checkmark.circle.fill"
        case .backupOnly: "exclamationmark.arrow.circlepath"
        case .neither: "xmark.octagon.fill"
        case .unreadable: "questionmark.diamond.fill"
        }
    }

    private func statusColor(_ status: SessionStorageDiagnostic.RRStatus) -> Color {
        switch status {
        case .bothPresent, .archivedFull: .green
        case .backupOnly: .orange
        case .neither, .unreadable: .red
        }
    }
}
