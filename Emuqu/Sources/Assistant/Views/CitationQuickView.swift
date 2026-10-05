import SwiftUI

/// Minimal read-only sheet shown when the user taps a date citation in an
/// assistant response. Pulls a one-screen summary from the session's frozen
/// snapshots and the cached `AnalysisSummary` if one is cached for the
/// session's current state.
///
/// Intentionally lightweight — no editing, no charts, no re-analysis. For deep
/// review the user opens the session from the History tab.
struct CitationQuickView: View {
    @Environment(\.dependencies) var dependencies
    let session: HRVSession

    private var cachedSummary: AnalysisSummaryGenerator.AnalysisSummary? {
        dependencies.assistant.analysisSummaryCache.get(
            forSessionId: session.id,
            matching: AnalysisSummaryCache.fingerprint(for: session)
        )
    }

    var body: some View {
        List {
            headerSection
            analysisSection
            sleepSection
            trainingSection
            summarySection
        }
        .navigationTitle(String(localized: "Session Detail", bundle: LanguageManager.appBundle))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerSection: some View {
        Section {
            sessionFields
        } header: {
            Text(String(localized: "Session", bundle: LanguageManager.appBundle))
        }
    }

    @ViewBuilder
    private var sessionFields: some View {
        LabeledContent(String(localized: "Date", bundle: LanguageManager.appBundle)) {
            Text(session.startDate.formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(LanguageManager.appLocale)))
        }
        if let score = session.recoveryScore {
            LabeledContent(String(localized: "Recovery score", bundle: LanguageManager.appBundle)) {
                // 0–100, the number the dashboard ring and history show.
                Text(ScoreVerdict.safeDisplayScore(score * 10), format: .number.locale(LanguageManager.appLocale))
            }
        }
        if let tier = session.scoreBreakdown?.tier {
            LabeledContent(String(localized: "Tier", bundle: LanguageManager.appBundle)) { Text(String(localized: "Tier \(tier)", bundle: LanguageManager.appBundle)) }
        }
    }

    @ViewBuilder
    private var analysisSection: some View {
        if let result = session.analysisResult {
            Section {
                hrvFields(result)
            } header: {
                Text(String(localized: "HRV", bundle: LanguageManager.appBundle))
            }
        }
    }

    @ViewBuilder
    private func hrvFields(_ result: HRVAnalysisResult) -> some View {
        LabeledContent(String(localized: "RMSSD", bundle: LanguageManager.appBundle)) { Text(String(format: "%.1f ms", locale: LanguageManager.appLocale, result.timeDomain.rmssd)) }
        LabeledContent(String(localized: "SDNN", bundle: LanguageManager.appBundle)) { Text(String(format: "%.1f ms", locale: LanguageManager.appLocale, result.timeDomain.sdnn)) }
        LabeledContent(String(localized: "Mean HR", bundle: LanguageManager.appBundle)) { Text(String(format: "%.0f bpm", locale: LanguageManager.appLocale, result.timeDomain.meanHR)) }
        if let stress = result.ansMetrics?.stressIndex {
            LabeledContent(String(localized: "Stress index", bundle: LanguageManager.appBundle)) { Text(String(format: "%.0f", locale: LanguageManager.appLocale, stress)) }
        }
        if let dfa = result.nonlinear.dfaAlpha1 {
            LabeledContent(String(localized: "DFA α1", bundle: LanguageManager.appBundle)) { Text(String(format: "%.2f", locale: LanguageManager.appLocale, dfa)) }
        }
    }

    @ViewBuilder
    private var sleepSection: some View {
        if let sleep = session.sleepSnapshot {
            Section {
                sleepFields(sleep)
            } header: {
                Text(String(localized: "Sleep", bundle: LanguageManager.appBundle))
            }
        }
    }

    @ViewBuilder
    private func sleepFields(_ sleep: SleepData) -> some View {
        LabeledContent(String(localized: "Total", bundle: LanguageManager.appBundle)) {
            Text(verbatim: LocalizedDuration.hoursMinutes(minutes: sleep.nightSleepMinutes))
        }
        LabeledContent(String(localized: "Efficiency", bundle: LanguageManager.appBundle)) {
            Text(verbatim: SleepDetailV2View.efficiencyText(sleep))
        }
        if let deep = sleep.deepSleepMinutes {
            LabeledContent(String(localized: "Deep", bundle: LanguageManager.appBundle)) { Text(verbatim: LocalizedDuration.hoursMinutes(minutes: deep)) }
        }
        if let rem = sleep.remSleepMinutes {
            LabeledContent(String(localized: "REM", bundle: LanguageManager.appBundle)) { Text(verbatim: LocalizedDuration.hoursMinutes(minutes: rem)) }
        }
    }

    @ViewBuilder
    private var trainingSection: some View {
        if let training = session.trainingSnapshot {
            Section {
                trainingFields(training)
            } header: {
                Text(String(localized: "Training", bundle: LanguageManager.appBundle))
            }
        }
    }

    @ViewBuilder
    private func trainingFields(_ training: TrainingContext) -> some View {
        LabeledContent(String(localized: "ATL (fatigue)", bundle: LanguageManager.appBundle)) { Text(String(format: "%.0f", locale: LanguageManager.appLocale, training.atl)) }
        LabeledContent(String(localized: "CTL (fitness)", bundle: LanguageManager.appBundle)) { Text(String(format: "%.0f", locale: LanguageManager.appLocale, training.ctl)) }
        LabeledContent(String(localized: "TSB (form)", bundle: LanguageManager.appBundle)) { Text(String(format: "%.1f", locale: LanguageManager.appLocale, training.tsb)) }
        LabeledContent(String(localized: "Yesterday TRIMP", bundle: LanguageManager.appBundle)) { Text(String(format: "%.0f", locale: LanguageManager.appLocale, training.yesterdayTrimp)) }
    }

    @ViewBuilder
    private var summarySection: some View {
        if let summary = cachedSummary {
            Section {
                summaryFields(summary)
            } header: {
                Text(String(localized: "Analysis", bundle: LanguageManager.appBundle))
            }
        } else {
            Section {
                Text(String(localized: "Open this session from the History tab to compute its full analysis.", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func summaryFields(_ summary: AnalysisSummaryGenerator.AnalysisSummary) -> some View {
        Text(verbatim: summary.analysisTitle).font(.headline)
        Text(verbatim: summary.analysisExplanation).font(.callout)
        if !summary.keyFindings.isEmpty {
            keyFindingsList(summary.keyFindings)
        }
    }

    private func keyFindingsList(_ findings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Key findings", bundle: LanguageManager.appBundle)).font(.subheadline.weight(.semibold))
            ForEach(findings.prefix(5), id: \.self) { finding in
                Text(verbatim: "• \(finding)").font(.caption)
            }
        }
    }
}
