import SwiftUI

/// Inspector for the last N AI requests captured by
/// `LLMRequestAudit`. Lets the user answer "what did the AI actually
/// see, and what did it actually say" without taking screenshots and
/// asking us. Particularly useful for triaging "the number it gave me
/// doesn't match the dashboard" reports — the entry shows the full
/// `<live_state>`-shaped system prompt + the messages array + the
/// tool catalog, so the user (or we) can grep for the disagreement
/// directly.
struct LLMPromptAuditView: View {
    @Environment(\.dependencies) var dependencies
    private var audit: LLMRequestAudit { dependencies.providers.llmRequestAudit }
    var body: some View {
        List {
            auditListContent
        }
        .navigationTitle(Text(verbatim: "AI prompt audit"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var auditListContent: some View {
        if audit.entries.isEmpty {
            emptyAuditSection
        } else {
            clearAuditSection
            ForEach(audit.entries) { entrySection($0) }
        }
    }

    private var emptyAuditSection: some View {
        Section {
            Text(verbatim: "No AI turns recorded yet. Send a message to the Coach to populate this audit.")
                .font(.callout)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var clearAuditSection: some View {
        Section {
            clearAuditLogButton
        } footer: {
            Text(verbatim: "In-memory only (10-entry FIFO). Resets when the app quits. Prompts can contain PHI/PII (sleep, HRV, locations, notes) — share carefully.")
        }
    }

    private func entrySection(_ entry: LLMRequestAudit.Entry) -> some View {
        Section {
            NavigationLink {
                LLMPromptAuditDetailView(entry: entry)
            } label: {
                entryRow(entry)
            }
        }
    }

    private var clearAuditLogButton: some View {
        Button(role: .destructive) {
            audit.clear()
        } label: {
            Label(String(localized: "Clear audit log", bundle: LanguageManager.appBundle), systemImage: "trash")
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: LLMRequestAudit.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            entryHeader(entry)
            entryUsageLine(entry)
            if !entry.responseText.isEmpty {
                Text(verbatim: entry.responseText)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func entryHeader(_ entry: LLMRequestAudit.Entry) -> some View {
        HStack {
            Text(verbatim: entry.provider)
                .font(.subheadline.weight(.semibold))
            Text(verbatim: entry.model)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(verbatim: shortTime(entry.sentAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    /// Token accounting, or "failed" when the request never produced usage.
    /// The cache hit ratio is over all input tokens, cached and not.
    @ViewBuilder
    private func entryUsageLine(_ entry: LLMRequestAudit.Entry) -> some View {
        if let usage = entry.usage {
            let cached = usage.cachedReadTokens
            let total = usage.inputTokens + cached + usage.cacheCreateTokens
            let hitRatio = total > 0 ? Int(Double(cached) / Double(total) * 100) : 0
            Text(verbatim: "in \(usage.inputTokens) · cached \(cached) (\(hitRatio)%) · out \(usage.outputTokens)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.textSecondary)
        } else if entry.errorDescription != nil {
            Text(verbatim: "failed")
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.wongCaution)
        }
    }

    private func shortTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

private struct LLMPromptAuditDetailView: View {
    let entry: LLMRequestAudit.Entry
    @State private var sectionExpanded: Set<String> = ["system"]

    var body: some View {
        List {
            summarySection
            promptSections
        }
        .navigationTitle(Text(verbatim: entry.provider))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { shareToolbarItem }
    }

    private var summarySection: some View {
        Section {
            row("Provider", entry.provider)
            row("Model", entry.model)
            row("Sent", entry.sentAt.formatted(date: .abbreviated, time: .standard))
            usageRows
            errorRow
        } header: {
            Text(verbatim: "Summary")
        }
    }

    @ViewBuilder
    private var usageRows: some View {
        if let usage = entry.usage {
            row("Input tokens", "\(usage.inputTokens)")
            row("Cached read", "\(usage.cachedReadTokens)")
            row("Cache create", "\(usage.cacheCreateTokens)")
            row("Output tokens", "\(usage.outputTokens)")
        }
    }

    @ViewBuilder
    private var errorRow: some View {
        if let err = entry.errorDescription {
            row("Error", err)
        }
    }

    @ViewBuilder
    private var promptSections: some View {
        collapsibleSection(
            title: "System prompt",
            key: "system",
            body: entry.systemPrompt,
            language: "text"
        )
        collapsibleSection(
            title: "Messages + tool rounds",
            key: "messages",
            body: entry.messagesJSON,
            language: "json"
        )
        optionalPromptSections
    }

    @ViewBuilder
    private var optionalPromptSections: some View {
        if !entry.toolsJSON.isEmpty {
            collapsibleSection(
                title: "Tool catalog (names + descriptions)",
                key: "tools",
                body: entry.toolsJSON,
                language: "json"
            )
        }
        if !entry.responseText.isEmpty {
            collapsibleSection(
                title: "Response text",
                key: "response",
                body: entry.responseText,
                language: "text"
            )
        }
    }

    @ToolbarContentBuilder
    private var shareToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            ShareLink(item: shareBody) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel(String(localized: "Share prompt audit", bundle: LanguageManager.appBundle))
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: key)
                .font(.callout)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(verbatim: value)
                .font(.callout.monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func collapsibleSection(title: String, key: String, body: String, language: String) -> some View {
        Section {
            Button {
                toggleSection(key)
            } label: {
                sectionHeader(title: title, key: key, charCount: body.count)
            }
            if sectionExpanded.contains(key) {
                Text(verbatim: body)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
    }

    private func toggleSection(_ key: String) {
        if sectionExpanded.contains(key) {
            sectionExpanded.remove(key)
        } else {
            sectionExpanded.insert(key)
        }
    }

    private func sectionHeader(title: String, key: String, charCount: Int) -> some View {
        HStack {
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Text(verbatim: "\(charCount) chars")
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.textTertiary)
            Image(systemName: sectionExpanded.contains(key) ? "chevron.up" : "chevron.down")
                .font(.caption)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private var shareBody: String {
        (shareHeaderLines + shareBodyLines).joined(separator: "\n")
    }

    private var shareHeaderLines: [String] {
        var lines: [String] = []
        lines.append("# AI prompt audit — \(entry.provider) (\(entry.model))")
        lines.append("Sent: \(entry.sentAt.formatted(date: .abbreviated, time: .standard))")
        if let usage = entry.usage {
            lines.append("Tokens — in:\(usage.inputTokens) cached:\(usage.cachedReadTokens) create:\(usage.cacheCreateTokens) out:\(usage.outputTokens)")
        }
        if let err = entry.errorDescription {
            lines.append("Error: \(err)")
        }
        return lines
    }

    private var shareBodyLines: [String] {
        var lines: [String] = []
        lines.append("")
        lines.append("## System prompt")
        lines.append(entry.systemPrompt)
        lines.append("")
        lines.append("## Messages")
        lines.append(entry.messagesJSON)
        if !entry.toolsJSON.isEmpty {
            lines.append("")
            lines.append("## Tools")
            lines.append(entry.toolsJSON)
        }
        if !entry.responseText.isEmpty {
            lines.append("")
            lines.append("## Response")
            lines.append(entry.responseText)
        }
        return lines
    }
}
