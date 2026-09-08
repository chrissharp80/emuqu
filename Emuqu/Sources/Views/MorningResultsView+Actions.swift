import MessageUI
import QuickLook
import SwiftUI

// MARK: - MorningResultsView Actions

extension MorningResultsView {
    // MARK: - Analysis Summary

    // MARK: - Shared Analysis Summary Generator

    // Uses the shared AnalysisSummaryGenerator to ensure PDF and app show identical content.
    // Includes training context so tips are consistent with the dashboard view.
    // analysisSummary is now on MorningResultsViewModel

    var analysisSummarySection: some View {
        let summary = vm.analysisSummary
        return VStack(alignment: .leading, spacing: 16) {
            analysisSummaryHeader
            diagnosticCard(summary)
            probableCausesSection(summary)
            Divider()
            keyFindingsSection(summary)
            Divider()
            recommendationsSection(summary)
        }
        .zenCard()
    }

    private var analysisSummaryHeader: some View {
        HStack {
            Image(systemName: "stethoscope")
                .foregroundColor(AppTheme.primary)
            Text(String(localized: "What This Means", bundle: LanguageManager.appBundle))
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)
        }
    }

    /// The main diagnostic assessment.
    private func diagnosticCard(_ summary: AnalysisSummaryGenerator.AnalysisSummary) -> some View {
        DiagnosticCard(
            title: translator.t(summary.analysisTitle),
            explanation: translator.t(summary.analysisExplanation),
            icon: summary.diagnosticIcon,
            color: diagnosticColorForScore(summary.diagnosticScore)
        )
    }

    @ViewBuilder
    private func probableCausesSection(_ summary: AnalysisSummaryGenerator.AnalysisSummary) -> some View {
        if !summary.probableCauses.isEmpty {
            probableCausesList(summary.probableCauses)
        }
    }

    private func probableCausesList(_ causes: [AnalysisSummaryGenerator.ProbableCause]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Most Likely Explanations", bundle: LanguageManager.appBundle))
                .font(.subheadline.bold())
                .foregroundColor(AppTheme.textPrimary)

            ForEach(Array(causes.enumerated()), id: \.offset) { index, cause in
                probableCauseRow(rank: index + 1, cause: cause)
            }
        }
    }

    private func probableCauseRow(rank: Int, cause: AnalysisSummaryGenerator.ProbableCause) -> some View {
        ProbableCauseRow(
            rank: rank,
            cause: translator.t(cause.cause),
            confidence: translator.t(cause.confidence),
            explanation: translator.t(cause.explanation)
        )
    }

    private func keyFindingsSection(_ summary: AnalysisSummaryGenerator.AnalysisSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Key Findings", bundle: LanguageManager.appBundle))
                .font(.subheadline.bold())
                .foregroundColor(AppTheme.textPrimary)

            ForEach(summary.keyFindings, id: \.self) { keyFindingRow($0) }
        }
    }

    private func keyFindingRow(_ finding: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.caption2)
                .foregroundColor(AppTheme.primary)
                .padding(.top, 6)
            Text(translator.t(finding))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    /// Actionable recommendations.
    private func recommendationsSection(_ summary: AnalysisSummaryGenerator.AnalysisSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "What To Do", bundle: LanguageManager.appBundle))
                .font(.subheadline.bold())
                .foregroundColor(AppTheme.textPrimary)

            ForEach(summary.actionableSteps, id: \.self) { recommendationRow($0) }
        }
    }

    private func recommendationRow(_ step: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.right.circle.fill")
                .foregroundColor(AppTheme.sage)
                .font(.caption)
            Text(translator.t(step))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    // MARK: - Narrative Translation

    func collectNarrativeStrings(
        breakdown: RecoveryScoreCalculator.ScoreBreakdown
    ) -> [String] {
        guard NarrativeTranslator.isActive else { return [] }
        return scoreCardStrings(breakdown: breakdown)
            + frozenReadinessStrings()
            + analysisSummaryStrings()
    }

    /// Frozen morning snapshot — raw ATL/CTL, no EWMA step. Matches
    /// `computeFrozenReadiness`: the step hasn't happened yet at acceptance
    /// time. The dashboard's live path applies the step, so readiness improves
    /// through the day on rest days.
    private func frozenReadinessStrings() -> [String] {
        let ctx = vm.displaySession.trainingSnapshot ?? vm.displayResult.trainingContext ?? vm.liveTrainingContext
        let atl = ctx?.atl ?? 0
        let ctl = ctx?.ctl ?? 0
        let acr: Double? = ctl > 0 ? atl / ctl : nil
        let readiness100 = RecoveryScoreCalculator.calculateReadiness(
            recoveryScore: vm.compositeRecoveryScore,
            todayTrimp: 0,
            ctl: ctl,
            atl: atl,
            morningATL: atl,
            acuteChronicRatio: acr
        )
        let readiness = RecoveryScoreCalculator.toTenScale(readiness100)
        return [
            RecoveryScoreCalculator.readinessLabel(for: readiness),
            RecoveryScoreCalculator.readinessMessage(for: readiness, acuteChronicRatio: acr)
        ]
    }

    private func analysisSummaryStrings() -> [String] {
        let summary = vm.analysisSummary
        var strings = [summary.analysisTitle, summary.analysisExplanation, summary.trendInsight]
        for cause in summary.probableCauses {
            strings.append(cause.cause)
            strings.append(cause.confidence)
            strings.append(cause.explanation)
        }
        strings.append(contentsOf: summary.keyFindings)
        strings.append(contentsOf: summary.actionableSteps)
        return strings
    }

    // MARK: - Diagnostic Helpers

    @MainActor func diagnosticColorForScore(_ score: Double) -> Color {
        if score >= 80 { return AppTheme.sage }
        if score >= 60 { return AppTheme.mist }
        if score >= 40 { return AppTheme.softGold }
        return AppTheme.terracotta
    }

    // MARK: - Actions

    var actionButtons: some View {
        VStack(spacing: 12) {
            exportButtonsRow
            reanalyzeRow
            dismissButtonsRow
        }
        .padding(.top, 8)
    }

    /// Primary row: Export PDF and Export RR
    private var exportButtonsRow: some View {
        HStack(spacing: 12) {
            generatingButton
            emailReportButton
            exportRRButton
        }
    }

    @ViewBuilder
    private var emailReportButton: some View {
        if MFMailComposeViewController.canSendMail() {
            emailReportAction
        }
    }

    private var emailReportAction: some View {
        Button {
            showEmailSectionPicker = true
        } label: {
            emailReportLabel
        }
        .buttonStyle(.zenSecondary)
        .disabled(vm.isGeneratingEmailPDF)
        .sheet(isPresented: $showEmailSectionPicker) {
            emailSectionPickerSheet
        }
    }

    @ViewBuilder
    private var emailReportLabel: some View {
        if vm.isGeneratingEmailPDF {
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text(String(localized: "Preparing...", bundle: LanguageManager.appBundle))
            }
            .frame(maxWidth: .infinity)
        } else {
            Label(String(localized: "Email Report", bundle: LanguageManager.appBundle), systemImage: "envelope.fill")
                .frame(maxWidth: .infinity)
        }
    }

    private var emailSectionPickerSheet: some View {
        ReportSectionPicker(
            onGenerate: { style, sections in
                emailReport(style: style, sections: sections)
            },
            availableSections: availableReportSections
        )
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var exportRRButton: some View {
        if vm.hasRawData {
            Button {
                exportRRData()
            } label: {
                Label(String(localized: "Export RR", bundle: LanguageManager.appBundle), systemImage: "waveform.path")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.zenSecondary)
        }
    }

    /// Re-analyze row (only if we have raw data and handler)
    @ViewBuilder
    private var reanalyzeRow: some View {
        if vm.hasRawData, onReanalyze != nil {
            reanalyzeButton
        }
    }

    private var reanalyzeButton: some View {
        Button {
            showingReanalyzeConfirmation = true
        } label: {
            reanalyzeLabel
        }
        .buttonStyle(.zenSecondary)
        .disabled(vm.isReanalyzing)
    }

    @ViewBuilder
    private var reanalyzeLabel: some View {
        if vm.isReanalyzing {
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text(String(localized: "Analyzing...", bundle: LanguageManager.appBundle))
            }
            .frame(maxWidth: .infinity)
        } else {
            Label(String(localized: "Re-analyze", bundle: LanguageManager.appBundle), systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
        }
    }

    /// Secondary row: Discard/Done and Delete (if available)
    private var dismissButtonsRow: some View {
        HStack(spacing: 12) {
            doneButton
            deleteButton
        }
    }

    private var doneButton: some View {
        Button {
            // Save tags/notes before dismissing if callback provided
            onUpdateTags?(Array(vm.selectedTags), vm.notes.isEmpty ? nil : vm.notes)
            onDiscard()
        } label: {
            Label(onDelete != nil ? String(localized: "Done", bundle: LanguageManager.appBundle) : String(localized: "Discard", bundle: LanguageManager.appBundle), systemImage: onDelete != nil ? "checkmark" : "xmark")
                .frame(maxWidth: .infinity)
                .foregroundColor(onDelete != nil ? AppTheme.textPrimary : AppTheme.terracotta)
        }
        .buttonStyle(.zenSecondary)
    }

    @ViewBuilder
    private var deleteButton: some View {
        if onDelete != nil {
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label(String(localized: "Delete", bundle: LanguageManager.appBundle), systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .foregroundColor(AppTheme.terracotta)
            }
            .buttonStyle(.zenSecondary)
        }
    }

    private var generatingButton: some View {
        generatePDFButton
    }

    private var generatePDFButton: some View {
        Button {
            showReportSectionPicker = true
        } label: {
            generatePDFLabel
        }
        .buttonStyle(.zenSecondary)
        .disabled(vm.isGeneratingPDF)
        .sheet(isPresented: $showReportSectionPicker) {
            reportSectionPickerSheet
        }
    }

    @ViewBuilder
    private var generatePDFLabel: some View {
        if vm.isGeneratingPDF {
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text(String(localized: "Generating...", bundle: LanguageManager.appBundle))
            }
            .frame(maxWidth: .infinity)
        } else {
            Label(String(localized: "Export PDF", bundle: LanguageManager.appBundle), systemImage: "doc.fill")
                .frame(maxWidth: .infinity)
        }
    }

    private var reportSectionPickerSheet: some View {
        ReportSectionPicker(
            onGenerate: { style, sections in
                exportPDF(style: style, sections: sections)
            },
            availableSections: availableReportSections
        )
        .presentationDetents([.medium, .large])
    }
}

// MARK: - File-scope helpers
//
// Kept outside MorningResultsView: each names no member of the
// type and calls nothing inside it, so none needs to be a member.
// `private` at file scope is fileprivate, so every call site in this
// file resolves the same way.

private func scoreCardStrings(breakdown: RecoveryScoreCalculator.ScoreBreakdown) -> [String] {
    var strings = [breakdown.message, RecoveryScoreCalculator.label(for: breakdown.compositeScore)]
    for factor in breakdown.factors {
        strings.append(factor.label)
        strings.append(factor.detail)
    }
    strings.append(contentsOf: breakdown.penalties)
    return strings
}
