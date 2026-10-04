import SwiftUI
import UniformTypeIdentifiers

/// View for importing RR data from external files
struct ImportDataView: View {
    @Environment(RRCollector.self) var collector
    @Environment(\.dismiss) var dismiss

    @State var showingFilePicker = false
    @State var importResult: RRDataImporter.ImportResult?
    @State var eliteHRVResult: RRDataImporter.EliteHRVSummaryResult?
    @State var flowHRVResult: RRDataImporter.FlowHRVMultiSessionResult?
    @State var importedSession: HRVSession?
    @State var isImporting = false
    @State var isAnalyzing = false
    @State var isSavingBatch = false
    @State var errorMessage: String?
    @State var showingResults = false
    @State var batchImportProgress: (current: Int, total: Int)?
    /// One short, localized line about where the import is. The step-by-step
    /// detail goes to the debug log, not the screen.
    @State var importStatusMessage: String = ""
    /// The Emuqu-export sessions the archive doesn't hold yet, worked out once
    /// when the file is parsed rather than on every render.
    @State var flowNewSessions: [RRDataImporter.FlowHRVMultiSessionResult.SessionRRData] = []
    /// The same for an Elite HRV summary: only these are imported, so the
    /// button's count and the import agree.
    @State var eliteNewSessions: [RRDataImporter.EliteHRVSummaryResult.SessionSummary] = []
    @State var cachedRecentSessions: [HRVSession] = []

    let importer = RRDataImporter()

    var body: some View {
        NavigationStack {
            ScrollView {
                importStack
                    .padding()
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle(String(localized: "Import Data", bundle: LanguageManager.appBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { cancelToolbarItem }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.commaSeparatedText, .json, .plainText],
                allowsMultipleSelection: false
            ) { result in
                handleFileSelection(result)
            }
            .fullScreenCover(isPresented: $showingResults) { importedResultsCover }
        }
    }

    private var importStack: some View {
        VStack(spacing: 24) {
            headerSection
            formatInfoSection
            importButtonSection
            importPreviews
            importStatus
            importError
        }
    }

    /// One preview per supported source format — at most one is ever populated.
    @ViewBuilder
    private var importPreviews: some View {
        if let result = importResult {
            importPreviewSection(result)
        }
        if let eliteResult = eliteHRVResult {
            eliteHRVPreviewSection(eliteResult)
        }
        if let flowResult = flowHRVResult {
            flowHRVPreviewSection(flowResult)
        }
    }

    @ViewBuilder
    private var importStatus: some View {
        if isImporting || isAnalyzing || isSavingBatch || !importStatusMessage.isEmpty {
            importStatusSection
        }
    }

    @ViewBuilder
    private var importError: some View {
        if let error = errorMessage {
            errorSection(error)
        }
    }

    @ToolbarContentBuilder
    private var cancelToolbarItem: some ToolbarContent {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel", bundle: LanguageManager.appBundle)) { dismiss() }
            }
    }

    @ViewBuilder
    private var importedResultsCover: some View {
        if let session = importedSession, let analysisResult = session.analysisResult {
            importedResultsStack(session: session, result: analysisResult)
        }
    }

    private func importedResultsStack(session: HRVSession, result: HRVAnalysisResult) -> some View {
        NavigationStack {
            importedResults(session: session, result: result)
                .navigationTitle(String(localized: "Imported Reading", bundle: LanguageManager.appBundle))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { saveImportToolbarItem }
        }
    }

    private func importedResults(session: HRVSession, result: HRVAnalysisResult) -> some View {
        MorningResultsView(
            session: session,
            result: result,
            recentSessions: cachedRecentSessions,
            onDiscard: { discardImport() },
            onUpdateSleep: { sleepData in
                collector.updateSessionSleepBoundaries(sessionId: session.id, sleepData: sleepData)
            }
        )
    }

    private func discardImport() {
        importedSession = nil
        importResult = nil
        showingResults = false
    }

    @ToolbarContentBuilder
    private var saveImportToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) { saveImportButton }
    }

    private var saveImportButton: some View {
        Button(String(localized: "Done", bundle: LanguageManager.appBundle)) {
            Task { await saveImportedSession() }
        }
    }
}

// MARK: - Import Info Row

struct ImportInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.bold())
                .foregroundColor(AppTheme.textPrimary)
        }
    }
}

#Preview {
    ImportDataView()
        .environment(RRCollector())
}
