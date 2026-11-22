import SwiftUI

/// Graceful empty/error state for a session that couldn't
/// produce a usable analysis (no HRV metrics, no score), instead of
/// a row of near-blank "—" cards. Offers a re-analyze retry when
/// `canReanalyze` (raw beat data is on disk), and a delete when
/// `canDelete`; otherwise the user dismisses it. Kept inside the app's card
/// style + the shared EmptyState component used elsewhere.
struct UnreadableReadingState: View {
    let canReanalyze: Bool
    let canDelete: Bool
    @Binding var perceivedReadiness: Double?
    let quality: HRVDataQuality
    let onReanalyze: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                emptyState

                // Subjective fallback so the morning still has a takeaway
                // even when the physiological read failed.
                SubjectiveReadinessCard(perceivedReadiness: $perceivedReadiness, quality: quality)
            }
            .padding()
        }
        .background(AppTheme.background.ignoresSafeArea())
    }

    private var emptyState: some View {
        EmptyState(
            glyph: "waveform.path.ecg",
            headline: String(localized: "This reading didn't process", bundle: LanguageManager.appBundle),
            message: String(localized: "We couldn't pull usable heart-rate variability from this session — it may have been too short, too noisy, or interrupted before enough clean data was captured. Your raw data is safe.", bundle: LanguageManager.appBundle),
            primaryLabel: canReanalyze
                ? String(localized: "Re-analyze", bundle: LanguageManager.appBundle)
                : nil,
            primaryAction: onReanalyze,
            secondaryLabel: canDelete
                ? String(localized: "Delete reading", bundle: LanguageManager.appBundle)
                : nil,
            secondaryAction: onDelete
        )
        .padding(.top, 40)
    }
}
