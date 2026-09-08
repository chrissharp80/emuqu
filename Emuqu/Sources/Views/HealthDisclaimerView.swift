import SwiftUI

// MARK: - Shared Disclaimer Text

/// Centralized disclaimer content used by the first-launch gate, Terms of Use,
/// and any future surface that needs the health disclaimer language.
@MainActor
enum HealthDisclaimer {
    /// The disclaimer text, in reading order. Split in two only because the
    /// list is long: `legalSections` is the liability text, `ageSection` the
    /// COPPA-aligned affirmation.
    static var sections: [(heading: String, body: String)] {
        legalSections + ageSection
    }

    private static var legalSections: [(heading: String, body: String)] {
        scopeSections + riskSections
    }

    /// What the app is not: not a device, not advice, informational only.
    private static var scopeSections: [(heading: String, body: String)] {
        let bundle = LanguageManager.appBundle
        return [
            (
                String(localized: "Not a Medical Device", bundle: bundle),
                String(localized: "Emuqu is not a medical device. It is not FDA-approved, FDA-cleared, or certified by any regulatory body.", bundle: bundle)
            ),
            (
                String(localized: "Informational Purposes Only", bundle: bundle),
                String(localized: "All data, metrics, scores, and interpretations provided by this app — including heart rate variability analysis, recovery scoring, sleep staging, readiness assessments, and training load calculations — are for informational and educational purposes only.", bundle: bundle)
            ),
            (
                String(localized: "No Medical Advice", bundle: bundle),
                String(localized: "This app does not provide medical advice, diagnosis, or treatment. Nothing in this app should be interpreted as a recommendation to begin, modify, or discontinue any exercise program, medical treatment, or health-related activity.", bundle: bundle)
            )
        ]
    }

    /// What the reader is accepting: accuracy limits, professional advice,
    /// assumption of risk.
    private static var riskSections: [(heading: String, body: String)] {
        let bundle = LanguageManager.appBundle
        return [
            (
                String(localized: "Data Accuracy", bundle: bundle),
                String(localized: "Data accuracy depends on sensor hardware, placement, signal quality, and other factors outside the developer's control. Results may be inaccurate, incomplete, or missing due to sensor malfunction, signal loss, or device limitations.", bundle: bundle)
            ),
            (
                String(localized: "Consult a Professional", bundle: bundle),
                String(localized: "Always consult a qualified healthcare provider before making decisions about your health, fitness, or medical care.", bundle: bundle)
            ),
            (
                String(localized: "Assumption of Risk", bundle: bundle),
                String(localized: "By tapping \"I Agree\" you acknowledge that you use this app at your own risk and that the developer is not liable for any injury, health outcome, or decision made based on information provided by this app.", bundle: bundle)
            )
        ]
    }

    private static var ageSection: [(heading: String, body: String)] {
        let bundle = LanguageManager.appBundle
        return [
            (
                // COPPA-aligned age affirmation.
                // Emuqu is built around adult-athlete framing
                // (VO2max, lab-measured baselines, ACWR). Children under
                // 13 cannot legally consent to health-data collection in
                // the US under COPPA, and the EU GDPR sets the digital
                // consent floor at 13–16 depending on member state. We
                // gate at 13 here — the App Store rating remains the
                // wider net, this is the in-app affirmation.
                String(localized: "Age Requirement", bundle: bundle),
                String(localized: "By tapping \"I Agree\" you also confirm you are at least 13 years old. Emuqu is designed for adult athletes and is not intended for children. Parents who want their child to use a heart-rate or wellness tracker should consult their pediatrician and use an age-appropriate product.", bundle: bundle)
            )
        ]
    }
}

// MARK: - First-Launch Disclaimer Gate

/// Full-screen disclaimer that must be accepted before the user can access any functionality.
/// Appears once per device. Acceptance is stored in UserDefaults (device-local, not synced).
/// One heading-plus-body block of `HealthDisclaimer.sections`, as rendered by
/// both the onboarding disclaimer and the Terms of Use page.
struct DisclaimerSectionView: View {
    let section: (heading: String, body: String)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.heading)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.textPrimary)

            Text(section.body)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct HealthDisclaimerView: View {
    @Environment(SettingsManager.self) var settingsManager
    @State private var canAgree = false

    /// Name of the coordinate space used to track scroll position.
    private let scrollSpace = "disclaimerScroll"

    var body: some View {
        VStack(spacing: 0) {
            disclaimerHeader

            disclaimerScroll

            agreementFooter
        }
        .background(AppTheme.background.ignoresSafeArea())
        .interactiveDismissDisabled()
        // Accessibility fallback. The scroll-to-bottom gate
        // relies on a scroll-position callback that a VoiceOver user
        // navigating element-by-element may never trigger, which would lock
        // them out of this mandatory first-launch gate. VoiceOver users read
        // every element as they navigate, so enable the button up front when
        // VoiceOver is (or becomes) active.
        .onAppear { if UIAccessibility.isVoiceOverRunning { canAgree = true } }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
            if UIAccessibility.isVoiceOverRunning { canAgree = true }
        }
    }

    /// Header
    private var disclaimerHeader: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.text.clipboard")
                .font(.system(.largeTitle))
                .fontWeight(.bold)
                .minimumScaleFactor(0.5)
                .foregroundStyle(AppTheme.primary)
                .accessibilityHidden(true)

            Text(String(localized: "Health Disclaimer", bundle: LanguageManager.appBundle))
                .font(.title2.bold())
                .foregroundColor(AppTheme.textPrimary)

            Text(String(localized: "Please read before continuing", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        }
        .padding(.top, 40)
        .padding(.bottom, 20)
    }

    /// Scrollable disclaimer content
    private var disclaimerScroll: some View {
        GeometryReader { outerProxy in
            disclaimerScrollBody(outerProxy)
        }
        .mask(
            VStack(spacing: 0) {
                Color.black
                // Fade at the bottom edge hints there's more to read
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: canAgree ? 0 : 20)
            }
        )
    }

    /// Identified, because this view sits in a
    /// `fullScreenCover` over `MainTabView` and the dashboard's own
    /// scroll view is still in the hierarchy underneath. A
    /// `scrollViews.firstMatch` swipe could land on the wrong one
    /// and never enable the agree button.
    private func disclaimerScrollBody(_ outerProxy: GeometryProxy) -> some View {
        ScrollView {
            disclaimerSections(outerProxy)
        }
        .coordinateSpace(name: scrollSpace)
        .accessibilityIdentifier("disclaimer.scroll")
    }

    private func disclaimerSections(_ outerProxy: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(HealthDisclaimer.sections.enumerated()), id: \.offset) { _, section in
                DisclaimerSectionView(section: section)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .background(scrollPositionProbe(outerProxy))
    }

    /// Reports the content frame back to the scroll gate, both as the user
    /// scrolls and once on appear (content that fits entirely never scrolls, and
    /// the agree button still has to unlock).
    private func scrollPositionProbe(_ outerProxy: GeometryProxy) -> some View {
        GeometryReader { innerProxy in
            Color.clear
                .onChange(of: innerProxy.frame(in: .named(scrollSpace))) { _, frame in
                    checkScrollPosition(contentFrame: frame, viewportHeight: outerProxy.size.height)
                }
                .onAppear {
                    let frame = innerProxy.frame(in: .named(scrollSpace))
                    checkScrollPosition(contentFrame: frame, viewportHeight: outerProxy.size.height)
                }
        }
    }

    /// Agreement button
    private var agreementFooter: some View {
        VStack(spacing: 12) {
            iAgreeButton
                .buttonStyle(.zen(AppTheme.sage))
                .disabled(!canAgree)
                .opacity(canAgree ? 1.0 : 0.5)
                // Stable, non-localized UI-test handle.
                // Matching `buttons["I Agree"]` — the single most-queried
                // element in EmuquUITests — fails
                // on any of the other 16 locales. See UITestIdentifiers.swift.
                .accessibilityIdentifier("disclaimer.agree")

            if !canAgree {
                Text(String(localized: "Scroll to read the full disclaimer", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var iAgreeButton: some View {
        Button(String(localized: "I Agree", bundle: LanguageManager.appBundle)) {
            withAnimation(.easeInOut(duration: 0.3)) {
                settingsManager.hasAcceptedDisclaimer = true
            }
        }
    }

    /// Enable the "I Agree" button when the user has scrolled near the bottom,
    /// or when the content is short enough to fit without scrolling.
    private func checkScrollPosition(contentFrame: CGRect, viewportHeight: CGFloat) {
        guard !canAgree else { return }
        // Content fits entirely — no scrolling required
        let contentFits = contentFrame.height <= viewportHeight
        // User has scrolled close enough to the bottom (within 40pt)
        let bottomReached = contentFrame.maxY <= viewportHeight + 40
        if contentFits || bottomReached {
            withAnimation { canAgree = true }
        }
    }
}

#Preview {
    HealthDisclaimerView()
        .environment(AppDependencies.current.app.settingsManager)
}
