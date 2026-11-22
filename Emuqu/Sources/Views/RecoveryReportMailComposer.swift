import SwiftUI

/// The mail composer for a morning recovery report: subject "Recovery
/// Report – <date>", addressed from the user's report defaults, with the
/// exported file attached.
struct RecoveryReportMailComposer: View {
    let settings: UserSettings
    /// The night the report is about (its end, else its start).
    let reportDate: Date
    let attachmentURL: URL

    var body: some View {
        let dateStr = reportDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(LanguageManager.appLocale))
        return MailComposerView(
            subject: String(localized: "Recovery Report – \(dateStr)", bundle: LanguageManager.appBundle),
            // Recovery → training → legacy generic, blank fields skipped.
            recipients: settings.resolvedDefaultEmailRecipient.map { [$0] } ?? [],
            ccRecipients: settings.resolvedDefaultEmailCC,
            attachmentURL: attachmentURL
        )
    }
}
