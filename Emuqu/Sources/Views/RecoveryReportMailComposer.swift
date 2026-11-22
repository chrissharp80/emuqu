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
            recipients: Self.recipientList(from: settings),
            ccRecipients: Self.ccList(from: settings),
            attachmentURL: attachmentURL
        )
    }

    // Reading `defaultRecoveryEmailRecipient` alone leaves the
    // field BLANK when the user has only set the legacy generic
    // `defaultEmailRecipient` ("reports pre-pop email regressed").
    // So fall back through the same `resolvedDefaultEmailRecipient`
    // chain that MainTabView's report mailer + AssistantChatView's
    // per-message mailer use (recovery → training → legacy
    // generic). Same for the CC list.
    private static func recipientList(from settings: UserSettings) -> [String] {
        if let recovery = settings.defaultRecoveryEmailRecipient,
           !recovery.trimmingCharacters(in: .whitespaces).isEmpty {
            return [recovery]
        }
        return settings.resolvedDefaultEmailRecipient.map { [$0] } ?? []
    }

    private static func ccList(from settings: UserSettings) -> [String] {
        let recoveryCC = (settings.defaultRecoveryEmailCC ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !recoveryCC.isEmpty { return recoveryCC }
        return settings.resolvedDefaultEmailCC
    }
}
