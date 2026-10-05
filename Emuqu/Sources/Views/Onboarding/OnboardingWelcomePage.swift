import SwiftUI

/// Brand moment. Single CTA. Tagline copy is fixed.
///
/// Hero illustration: waveform morphing into a circular
/// score ring. Animated continuously while the page is visible — the
/// waveform draws across, then collapses around its centerline into a
/// ring, then dissolves back. ~5s loop. The morph is the brand moment;
/// SF Symbols don't carry it, so we draw it in CoreGraphics-y SwiftUI.
struct OnboardingWelcomePage: View {
    let advance: () -> Void
    /// Drives the waveform↔ring morph. 0 = pure sine wave, 1 = pure ring.
    /// `.repeatForever` ping-pongs between 0 and 1 over 5s.
    @State private var morph: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OnboardingFillingScroll {
            welcomeStack
        }
        .onAppear { startMorphAnimation() }
    }

    private var welcomeStack: some View {
        VStack(spacing: 28) {
            Spacer()
            heroIllustration
                .frame(width: 200, height: 200)
                .accessibilityHidden(true)
            wordmark
            tagline
            Spacer()
            advanceButton
        }
    }

    /// Brand name stays verbatim (proper noun, not translated).
    private var wordmark: some View {
        Text(verbatim: "Emuqu")
            .scaledFont(size: 40, weight: .semibold)
            .foregroundStyle(AppTheme.textPrimary)
    }

    /// Localizable tagline (not Text(verbatim:)).
    private var tagline: some View {
        Text(String(localized: "HRV-based recovery for athletes who train.", bundle: LanguageManager.appBundle))
            .scaledFont(size: 16)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
    }

    /// Every control that moves onboarding forward carries
    /// `onboarding.advance` (or `onboarding.skip` where the control declines
    /// the step; on the Backup page that also turns iCloud sync off). UI tests have to walk this flow before they can
    /// reach anything, and matching English labels made that walk break on the
    /// app's other 16 locales.
    private var advanceButton: some View {
        getStartedButton
            .buttonStyle(.plain)
            .accessibilityIdentifier("onboarding.advance")
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
    }

    /// With Reduce Motion on, the illustration holds still on the ring.
    private func startMorphAnimation() {
        guard !reduceMotion else {
            morph = 1
            return
        }
        withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
            morph = 1
        }
    }

    private var getStartedButton: some View {
        Button(action: advance) {
            // Localizable label (not Text(verbatim:)).
            Text(String(localized: "Get started", bundle: LanguageManager.appBundle))
                .scaledFont(size: 17, weight: .semibold)
                .frame(maxWidth: .infinity)
                .frame(height: 60) // Explicit 60pt
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(AppTheme.primary)
                )
                .foregroundStyle(.white)
        }
    }

    /// Waveform-to-ring morph. The shape is a continuous Path that
    /// linearly interpolates between a 2-cycle sine wave (morph=0) and
    /// a circle (morph=1). Same control points, different mapping —
    /// users see one shape becoming the other.
    private var heroIllustration: some View {
        ZStack {
            HeroMorphShape(morph: morph)
                .stroke(
                    LinearGradient(
                        colors: [AppTheme.primary, AppTheme.primaryLight],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )
        }
    }
}

private struct HeroMorphShape: Shape {
    /// 0 = pure sine wave, 1 = pure circle. Animates via Animatable.
    var morph: Double

    var animatableData: Double {
        get { morph }
        set { morph = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let segments = 96
        var p = Path()
        for i in 0...segments {
            let point = morphedPoint(t: Double(i) / Double(segments), in: rect)
            if i == 0 {
                p.move(to: point)
            } else {
                p.addLine(to: point)
            }
        }
        return p
    }

    /// Linear blend between two curves at the same parameter `t`: a sine wave
    /// across the rect's width (centred vertically) and a circle of the same
    /// parameterisation. `morph` at 0 is all wave, at 1 all ring.
    private func morphedPoint(t: Double, in rect: CGRect) -> CGPoint {
        let cx = rect.midX
        let cy = rect.midY
        let radius = min(rect.width, rect.height) * 0.42
        let amplitude = rect.height * 0.22
        let frequency = 4.0 * .pi // 2 full cycles across the rect
        let waveX = rect.minX + t * rect.width
        let waveY = cy + sin(t * frequency) * amplitude
        let theta = t * 2 * .pi - .pi / 2
        let ringX = cx + cos(theta) * radius
        let ringY = cy + sin(theta) * radius
        return CGPoint(
            x: waveX + (ringX - waveX) * morph,
            y: waveY + (ringY - waveY) * morph
        )
    }
}
