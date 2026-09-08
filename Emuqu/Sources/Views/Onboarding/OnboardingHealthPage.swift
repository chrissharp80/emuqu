import SwiftUI

/// Build plan §4.1 O4 — Connect Apple Health.
///
/// Dedicated page split from O3 per the spec (BP lines 476-481).
/// Critical because iOS only shows the system permission sheet ONCE
/// per scope; if the user denies in confusion, recovery requires
/// digging into Settings → Privacy → Health. This page primes the
/// user for the system sheet, fires it on tap, then verifies which
/// scopes were granted via `getRequestStatusForAuthorization` (iOS
/// hides explicit denial state, so we infer from data presence).
///
/// Layout (BP line 478):
///   • Apple Health icon at top (red-cross + heart)
///   • Headline "Connect to Apple Health"
///   • Body explaining what gets read and written
///   • Screenshot preview of the iOS system sheet so the user knows
///     what they're about to see
///   • Big "Connect" button — fires `requestAuthorization()`
///   • "Skip for now" tertiary
///
/// Post-return verification (BP line 479):
///   • Auth completed → confirmation card "You're connected" + scope
///     summary
///   • Partial grant → warning card listing what's missing and how to
///     fix in Settings
struct OnboardingHealthPage: View {
    @Environment(RRCollector.self) var collector
    let advance: () -> Void

    @State private var requesting: Bool = false
    @State private var didAttempt: Bool = false
    @State private var grantedScopes: Set<String> = []

    private var hk: HealthKitManager { collector.healthKit }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Spacer(minLength: 20)
                healthPageHeader
                dataCategoriesCard
                systemSheetPreview
                authFailureNotice
                Spacer(minLength: 24)
                connectHealthButton
                healthNavigationButtons
                    .accessibilityIdentifier("onboarding.skip")
                    .padding(.bottom, 48)
            }
            .padding(.horizontal)
        }
    }

    /// The accessibility identifier at the call site is deliberately only on
    /// "Skip for now". The Connect button above opens the Apple Health system
    /// sheet, which an automated walk-through must never be steered into.
    private var healthNavigationButtons: some View {
        skipForNowButton
            .buttonStyle(.plain)
    }

    private var healthPageHeader: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.text.square.fill")
                .font(.system(.largeTitle))
                .fontWeight(.bold)
                .minimumScaleFactor(0.5)
                .foregroundStyle(AppTheme.sage)
                .accessibilityHidden(true)

            Text(String(localized: "Connect to Apple Health", bundle: LanguageManager.appBundle))
                .font(.title2.bold())
                .foregroundColor(AppTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Text(String(localized: "Emuqu uses Apple Health for sleep, vitals, and workout history. None of this leaves your device unless you explicitly share it.", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    /// What gets read / written. Spec line 478: "body
    /// explaining what gets read and written." We list the
    /// categories so the user has informed consent before
    /// the system sheet appears.
    private var dataCategoriesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            scopeRow(glyph: "moon.zzz.fill", title: "Sleep", subtitle: "Stages, duration, in-bed time")
            scopeRow(glyph: "heart.fill", title: "Heart rate", subtitle: "Resting + workout HR")
            scopeRow(glyph: "lungs.fill", title: "Vitals", subtitle: "Respiratory rate, SpO₂, wrist temp")
            scopeRow(glyph: "figure.run", title: "Workouts", subtitle: "Read history + write new sessions")
        }
        .padding(14)
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }

    @ViewBuilder
    private var authFailureNotice: some View {
        if didAttempt {
            statusCard
        }
    }

    /// BP §O4 line 478: "big Connect button" + "Skip for now" tertiary.
    private var connectHealthButton: some View {
        Button {
            Task { await requestHealthAuthorization() }
        } label: {
            connectHealthLabel
        }
        .buttonStyle(.zen(AppTheme.sage))
        .disabled(requesting)
        .accessibilityHint(String(localized: "Open the Apple Health permission sheet", bundle: LanguageManager.appBundle))
    }

    private var connectHealthLabel: some View {
        HStack {
            if requesting {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "checkmark.shield.fill")
                Text(String(localized: "Connect", bundle: LanguageManager.appBundle))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 60)
    }

    private var skipForNowButton: some View {
        Button {
            advance()
        } label: {
            Text(String(localized: "Skip for now", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .padding(.vertical, 8)
        }
    }

    private func scopeRow(glyph: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: glyph)
                .scaledFont(size: 18)
                .foregroundStyle(AppTheme.sage)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(AppTheme.textPrimary)
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }
            Spacer()
        }
    }

    /// Screenshot-style preview of the iOS sheet (BP line 478). We can't legally
    /// embed Apple's actual sheet image; this schematic preview communicates the
    /// same intent: "the system sheet is coming, here's what it'll look like."
    private var systemSheetPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            sheetPreviewHeader
            sheetPreviewRows
        }
    }

    private var sheetPreviewHeader: some View {
        HStack {
            Image(systemName: "iphone")
                .foregroundStyle(AppTheme.textSecondary)
            Text(String(localized: "What you'll see next", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textSecondary)
            Spacer()
        }
    }

    private var sheetPreviewButtons: some View {
        HStack(spacing: 6) {
            Text(verbatim: "[ Don't Allow ]")
            Spacer()
            Text(verbatim: "[ Allow ]")
                .fontWeight(.semibold)
        }
        .font(.caption2)
        .foregroundStyle(AppTheme.textTertiary)
        .padding(.top, 6)
    }

    private var sheetPreviewRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "🍎  Health Data Access")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(String(localized: "Emuqu would like to access your Health data.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
            sheetPreviewButtons
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(AppTheme.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(AppTheme.textTertiary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                )
        )
    }

    @ViewBuilder
    private var statusCard: some View {
        if grantedScopes.count >= 4 {
            allScopesGrantedRow
        } else if grantedScopes.isEmpty {
            someScopesDeniedRow
        } else {
            scopesPendingRow
        }
    }

    private var allScopesGrantedRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.wongOptimal)
            Text(String(localized: "You're connected. Sleep + vitals + workouts will start populating tonight.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(AppTheme.wongOptimal.opacity(0.1))
        .cornerRadius(10)
    }

    private var someScopesDeniedRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.wongCaution)
            Text(String(localized: "We can't see any Health data yet. iOS hides explicit denials — you can re-enable in Settings → Privacy → Health → Emuqu.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(AppTheme.wongCaution.opacity(0.1))
        .cornerRadius(10)
    }

    private var scopesPendingRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(AppTheme.primary)
            Text(String(localized: "Partial access granted. Some data types weren't enabled — that's fine, you can adjust later in Settings → Privacy → Health.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(AppTheme.primary.opacity(0.1))
        .cornerRadius(10)
    }

    @MainActor
    private func requestHealthAuthorization() async {
        requesting = true
        do {
            try await hk.requestAuthorization()
        } catch {
            debugLog("[OnboardingHealthPage] auth request failed: \(error)", level: .warning)
        }
        // BP §O4 line 479 — verify scopes via inference from data
        // presence (iOS hides denial state). HealthKitManager exposes
        // a `verifyAuthorization` helper we call here; result drives
        // the status card above.
        await hk.verifyAuthorizationGranted()
        grantedScopes = await hk.grantedScopeSummary()
        requesting = false
        didAttempt = true
    }
}

#Preview {
    OnboardingHealthPage(advance: {})
        .environment(RRCollector())
}
