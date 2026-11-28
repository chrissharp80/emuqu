import Foundation

/// The one rule every export or share that reads the archive's index
/// follows: it runs only over an index that loaded whole
/// (`SessionArchive.hasCompleteIndex`).
///
/// An index that did not load this launch (the file locked by data
/// protection, or sealed while the key cannot be reached) lists none, or only
/// some, of the sessions. An export over it is an empty or partial file that
/// reads as the whole history, and a report over it is measured against
/// nights it never saw. The export is refused with the reason instead.
///
/// Used by Export Data's three exports (`ExportDataView`), the Send-Report
/// menu (`MainTabView.prepareAndSendReport`), Reports → Browse
/// (`ReportsListView.renderReport`) and a night's PDF report
/// (`MorningReanalysisControls.exportPDF`, `emailReport`).
enum HistoryExportGate {
    /// Nil when the export may run; otherwise what to tell the user.
    static func refusal(indexComplete: Bool) -> String? {
        indexComplete ? nil : unreadableHistory
    }

    /// Why an export over an index that did not load is refused.
    static var unreadableHistory: String {
        String(localized: "Your history on this iPhone can't be read yet. Unlock your iPhone and try again.", bundle: LanguageManager.appBundle)
    }
}
