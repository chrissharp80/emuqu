import SwiftUI

/// Build plan §4.1 O6 — disclaimer page. Six section headings + bodies
/// verbatim from §6.2 / §7.5. "I Agree" is disabled until scroll-to-
/// bottom (BP line 494). "I Don't Agree" exits the app per BP line 1504.
/// Allowlisted in copy linter (it must contain the prohibited terms in
/// their negated forms — that's the entire point of the page).
///
/// This file is allowlisted in `Tools/copy_linter/prohibited_terms.json`.
struct OnboardingDisclaimerPage: View {
    let advance: () -> Void

    /// Scroll-to-bottom gate. Tied to a GeometryReader-based detector so
    /// it only flips after the user has actually scrolled the bottom
    /// marker into view (not on
    /// `.onAppear` of the marker, which fires even when the marker
    /// renders off-screen and the user hasn't seen it).
    @State private var hasScrolledToBottom: Bool = false
    /// Don't-agree confirmation alert.
    @State private var showDoNotAgreeAlert: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Text(loc("Before we start"))
                .scaledFont(size: 28, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.top, 24)
            Text(loc("Please read."))
                .scaledFont(size: 14)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.top, 4)

            disclaimerScroll

            disclaimerActions
        }
        .alert(loc("You can't use Emuqu without agreeing"), isPresented: $showDoNotAgreeAlert) {
            Button(loc("OK"), role: .cancel) {}
        } message: {
            Text(loc("Emuqu requires you to agree to the disclaimer before using the app. You can leave anytime via the home indicator and reopen later to review."))
        }
    }

    private var disclaimerScroll: some View {
        ScrollView {
            disclaimerBody
        }
        .onPreferenceChange(BottomMarkerKey.self) { y in
            // The marker enters the visible region when its global
            // minY drops below the screen height. Trip-once: flip
            // hasScrolledToBottom and never reset.
            let screenH = UIScreen.main.bounds.height
            if !hasScrolledToBottom, y > 0, y < screenH - 80 {
                hasScrolledToBottom = true
            }
        }
    }

    private var disclaimerBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            scopeSections
            riskSections
            bottomMarker
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    /// What the app is not: not a device, not advice, informational only.
    @ViewBuilder
    private var scopeSections: some View {
        section(
            heading: loc("Not a Medical Device."),
            body: loc("Emuqu is not a medical device. It is not FDA-approved, FDA-cleared, or certified by any regulatory body.")
        )
        section(
            heading: loc("Informational Purposes Only."),
            body: loc("All data, metrics, scores, and interpretations provided by this app are for informational and educational purposes only.")
        )
        section(
            heading: loc("No Medical Advice."),
            body: loc("This app does not provide medical advice, diagnosis, or treatment. Nothing in this app should be interpreted as a recommendation to begin, modify, or discontinue any exercise program, medical treatment, or health-related activity.")
        )
    }

    /// What the reader is accepting: professional advice, assumption of risk,
    /// and the age affirmation.
    @ViewBuilder
    private var riskSections: some View {
        section(
            heading: loc("Consult a Professional."),
            body: loc("Always consult a qualified healthcare provider before making decisions about your health, fitness, or medical care.")
        )
        section(
            heading: loc("Assumption of Risk."),
            body: loc("By tapping \"I Agree\" you acknowledge that you use this app at your own risk and that the developer is not liable for any injury, health outcome, or decision made based on information provided by this app.")
        )
        section(
            heading: loc("Age Requirement."),
            body: loc("By tapping \"I Agree\" you also confirm you are at least 13 years old. Emuqu is designed for adult athletes and is not intended for children.")
        )
    }

    /// Bottom marker — flips the gate ONLY when the
    /// marker actually scrolls into the visible viewport.
    /// GeometryReader + a frame check inside .onChange
    /// ensures we don't flip on mere render.
    private var bottomMarker: some View {
        GeometryReader { geo in
            Color.clear
                .preference(
                    key: BottomMarkerKey.self,
                    value: geo.frame(in: .global).minY
                )
        }
        .frame(height: 1)
    }

    private var disclaimerActions: some View {
        VStack(spacing: 10) {
            agreeButton

            doNotAgreeButton
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 48)
    }

    private var agreeButton: some View {
        Button(action: advance) {
            Text(loc("I Agree"))
                .scaledFont(size: 17, weight: .semibold)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(hasScrolledToBottom ? AppTheme.wongOptimal : AppTheme.textTertiary.opacity(0.4))
                )
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!hasScrolledToBottom)
        .accessibilityIdentifier("onboarding.advance")
    }

    /// Does not call
    /// `exit(0)` from the destructive alert path. Apple HIG
    /// explicitly says "Don't programmatically quit your
    /// app." The user can leave by swiping up; surfacing a
    /// clear message is friendlier and review-safer.
    private var doNotAgreeButton: some View {
        Button {
            showDoNotAgreeAlert = true
        } label: {
            Text(loc("I Don't Agree"))
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    /// Route disclaimer copy through the in-app language picker's bundle (not
    /// just the device locale) so this mandatory legal gate is presented in the
    /// user's chosen language — informed consent can't be gated behind English.
    private func loc(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: LanguageManager.appBundle)
    }

    private func section(heading: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // `heading`/`body` are already localized by the caller; render the
            // String value verbatim (Text(_: String) does not re-localize).
            Text(heading)
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
            Text(body)
                .scaledFont(size: 14)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct BottomMarkerKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
