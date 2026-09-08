import SwiftUI

/// One-time disclosure modal shown to existing users
/// the first time they open Emuqu after the recovery-score architecture
/// changed from HRV+Sleep+Training (50/20/30 with ACWR) to HRV+Sleep+
/// Vitals (60/25/15). The modal exists so users aren't blindsided by
/// score numbers shifting from one launch to the next; it links to the
/// methodology page for the full rationale.
///
/// Triggered by `UserSettings.hasAcknowledgedScoreArchitectureChange`.
/// Default `false` for upgrading users — modal fires once, dismissal
/// flips the flag to `true`. New installs encode `true` directly so the
/// modal is silently skipped (their first score is already under the new
/// algorithm).
///
/// **What it intentionally does NOT do**: it does not auto-recompute
/// historical sessions. Older session scores stay as they were when the
/// archive was written under the old algorithm. New sessions use the
/// new algorithm. This is the safer migration path — auto-recomputing a
/// year of history with a fresh code path risks destroying a user's
/// trend data if any single edge case is wrong.
struct ScoreArchitectureChangeSheet: View {
    @Binding var isPresented: Bool
    /// Retained for source compat with EmuquApp's existing wiring.
    /// Build plan §4.1a: no in-modal "Recalculate now" choice — the
    /// dismiss path always sets `.later` so the Settings entry stays
    /// available for users who want to recompute history.
    @Binding var recomputeChoice: RecomputeChoice

    enum RecomputeChoice {
        case undecided
        case runNow
        case later
    }

    var body: some View {
        NavigationStack {
            changeScroll
        }
        .interactiveDismissDisabled()
    }

    private var changeScroll: some View {
        ScrollView {
            changeStack
        }
        .background(AppTheme.background)
        .navigationBarHidden(true)
    }

    private var changeStack: some View {
        VStack(alignment: .leading, spacing: 18) {
            changeHeadline
            changeBodyBlock

            Spacer(minLength: 12)

            changeActionButtons
        }
        .padding(20)
    }

    /// Build plan §4.1a verbatim body block.
    private var changeHeadline: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "heart.text.square")
                .scaledFont(size: 44)
                .foregroundStyle(AppTheme.sage)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 12)
                .accessibilityHidden(true)

            Text(String(localized: "We've updated how Emuqu scores recovery", bundle: LanguageManager.appBundle))
                .font(.title2.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private var changeBodyBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Your recovery score now uses HRV (60%), sleep (25%), and vitals (15%) — and training load lives on its own surface instead of being mixed into the score.")
                .font(.callout)
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "Why? Because counting load in the score penalized the same physiological event twice. The HRV signal already reflects how hard you trained.")
                .font(.callout)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "Your past readings keep their original scores — nothing is rewritten automatically. New readings use the updated methodology, and you can recompute your history anytime from Settings. The full math is on the methodology page.")
                .font(.callout)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    /// Build plan §4.1a buttons: "Show me the methodology"
    /// (deep-link to the credibility doc) and "Got it"
    /// (dismiss → Dashboard).
    private var changeActionButtons: some View {
        VStack(spacing: 10) {
            showMeTheMethodologyLink
            gotItButton
        }
        .padding(.top, 8)
    }

    private var showMeTheMethodologyLink: some View {
        NavigationLink {
            RecoveryMethodologyView()
        } label: {
            Text(String(localized: "Show me the methodology", bundle: LanguageManager.appBundle))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.zen(AppTheme.sage))
    }

    private var gotItButton: some View {
        Button {
            recomputeChoice = .later
            isPresented = false
        } label: {
            Text(String(localized: "Got it", bundle: LanguageManager.appBundle))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.textSecondary)
    }
}
