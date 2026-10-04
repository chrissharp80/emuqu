import Foundation

/// Post-workout Coach Report email body, built from a template, not a model.
///
/// `renderConversationalSummary` turns an HRVSession + workoutMetadata into a
/// short coach-voice body for the auto Coach Report email: the headline, a
/// verdict on the effort, the physiology, a comparison with recent workouts of
/// the same sport, heart-rate recovery and tomorrow's advice. The full
/// breakdown travels as the attached PDF (`WorkoutPDFReport`), and the caller
/// appends `pdfFootnote` only when it is attached.
///
/// Pure function: given a session and its history it produces the same text
/// every time. It is honest about missing data ("no HRR captured" rather than
/// a fabricated value), and every sentence is localized in the app language.
enum CoachReportGenerator {
    // Members here are internal, not private: the sentences live in
    // CoachReportGenerator+Conversational.swift and the formatters in
    // CoachReportGenerator+Sections.swift, and Swift's `private` does not
    // reach across files.

    /// Closing line for the email body. The caller appends it only when the
    /// PDF is actually attached.
    static var pdfFootnote: String {
        "---\n\n*" + String(
            localized: "Full breakdown — splits, charts, route map, methodology — is in the attached PDF. Numbers in this email are summarised; the PDF is the source of truth.",
            bundle: LanguageManager.appBundle
        ) + "*"
    }
}
