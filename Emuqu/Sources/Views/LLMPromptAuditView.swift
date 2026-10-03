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
        .navigationTitle(Text("AI prompt audit", bundle: LanguageManager.appBundle))
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
            Text("No AI turns recorded yet. Send a message to Flo to populate this audit.", bundle: LanguageManager.appBundle)
                .font(.callout)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var clearAuditSection: some View {
        Section {
            clearAuditLogButton
        } footer: {
            Text("Kept in memory only (the last 10 turns) and cleared when the app quits. Prompts can contain personal health data (sleep, HRV, locations, notes) — share carefully.", bundle: LanguageManager.appBundle)
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
            Text(String(localized: "Tokens: in \(usage.inputTokens) · cached \(cached) (\(hitRatio)%) · out \(usage.outputTokens)", bundle: LanguageManager.appBundle))
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.textSecondary)
        } else if entry.errorDescription != nil {
            Text("Failed", bundle: LanguageManager.appBundle)
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.wongCaution)
        }
    }

    private func shortTime(_ d: Date) -> String {
        d.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(LanguageManager.appLocale))
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
            row(String(localized: "Provider", bundle: LanguageManager.appBundle), entry.provider)
            row(String(localized: "Model", bundle: LanguageManager.appBundle), entry.model)
            row(String(localized: "Sent", bundle: LanguageManager.appBundle), entry.sentAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(LanguageManager.appLocale)))
            usageRows
            errorRow
        } header: {
            Text("Summary", bundle: LanguageManager.appBundle)
        }
    }

    @ViewBuilder
    private var usageRows: some View {
        if let usage = entry.usage {
            row(String(localized: "Input tokens", bundle: LanguageManager.appBundle), "\(usage.inputTokens)")
            row(String(localized: "Cached read", bundle: LanguageManager.appBundle), "\(usage.cachedReadTokens)")
            row(String(localized: "Cache create", bundle: LanguageManager.appBundle), "\(usage.cacheCreateTokens)")
            row(String(localized: "Output tokens", bundle: LanguageManager.appBundle), "\(usage.outputTokens)")
        }
    }

    @ViewBuilder
    private var errorRow: some View {
        if let err = entry.errorDescription {
            row(String(localized: "Error", bundle: LanguageManager.appBundle), err)
        }
    }

    @ViewBuilder
    private var promptSections: some View {
        collapsibleSection(
            title: String(localized: "System prompt", bundle: LanguageManager.appBundle),
            key: "system",
            body: entry.systemPrompt,
            language: "text"
        )
        collapsibleSection(
            title: String(localized: "Messages + tool rounds", bundle: LanguageManager.appBundle),
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
                title: String(localized: "Tool catalog (names + descriptions)", bundle: LanguageManager.appBundle),
                key: "tools",
                body: entry.toolsJSON,
                language: "json"
            )
        }
        if !entry.responseText.isEmpty {
            collapsibleSection(
                title: String(localized: "Response text", bundle: LanguageManager.appBundle),
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
            Text(String(localized: "\(charCount) characters", bundle: LanguageManager.appBundle))
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

    /// The shared file stays in English: it is a diagnostic report for
    /// whoever triages it, not screen copy.
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
