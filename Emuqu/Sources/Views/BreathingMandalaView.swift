import SwiftUI

/// Breathing mandala visualization for coherence during HRV recordings
/// Expands on inhale, contracts on exhale with multi-colored petals
struct BreathingMandalaView: View {
    /// Total breath cycle duration in seconds (inhale + exhale)
    let cycleDuration: Double

    /// Number of petals in the mandala
    var petalCount: Int = 12

    /// Whether to animate
    var isAnimating: Bool = true

    /// Optional callback for breath phase updates (0-1), called at ~60fps
    var onPhaseUpdate: ((Double) -> Void)?

    @State private var breathPhase: Double = 0 // 0-1, 0.5 is full inhale
    @State private var rotation: Double = 0

    /// Honour Settings → Accessibility → Motion →
    /// Reduce Motion. When true, the timer-driven 60 fps petal/rotation
    /// animation is suppressed; the breath-guide text still updates on a
    /// slow tick so the user can use the visual cue without continuous
    /// motion (which is contraindicated for vestibular users).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Mandala colors - calming, multi-colored palette
    private let petalColors: [Color] = [
        Color(hue: 0.55, saturation: 0.6, brightness: 0.85), // Soft blue
        Color(hue: 0.48, saturation: 0.5, brightness: 0.80), // Teal
        Color(hue: 0.75, saturation: 0.4, brightness: 0.85), // Soft purple
        Color(hue: 0.60, saturation: 0.5, brightness: 0.85), // Blue-purple
        Color(hue: 0.45, saturation: 0.45, brightness: 0.85), // Cyan
        Color(hue: 0.85, saturation: 0.35, brightness: 0.90) // Pink-lavender
    ]

    private let timer = Timer.publish(every: 0.016, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            mandalaLayers(size: size)
                .position(center)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Breathing guide: \(breathGuideText)")
        .accessibilityAddTraits(.updatesFrequently)
        .onReceive(timer) { _ in tick() }
    }

    private func mandalaLayers(size: CGFloat) -> some View {
        ZStack {
            backgroundGlow(size: size)
            petalLayers(size: size)
            centerCircle(size: size)
            breathGuideLabel
        }
    }

    private func backgroundGlow(size: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        petalColors[0].opacity(0.2 * breathScale),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: size * 0.1,
                    endRadius: size * 0.5
                )
            )
            .frame(width: size, height: size)

    }

    private func petalLayers(size: CGFloat) -> some View {
        ForEach(0..<3, id: \.self) { layer in
            PetalLayer(
                petalCount: petalCount,
                baseScale: breathScale,
                layerIndex: layer,
                colors: petalColors,
                rotation: rotation + Double(layer) * 5
            )
            .frame(width: size * (0.85 - Double(layer) * 0.15),
                   height: size * (0.85 - Double(layer) * 0.15))
        }
    }

    private func centerCircle(size: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        .white.opacity(0.9),
                        petalColors[2].opacity(0.6)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.1
                )
            )
            .frame(width: size * 0.15 * breathScale, height: size * 0.15 * breathScale)
            .shadow(color: .white.opacity(0.5), radius: 10)

    }

    private var breathGuideLabel: some View {
        VStack {
            Spacer()
            Text(breathGuideText)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(AppTheme.textSecondary)
                .padding(.bottom, 8)
        }
    }

    /// Reduce-motion: drop frame rate from 60 fps to ~6 fps and skip rotation
    /// entirely. The breath-cycle text still cycles so the user gets the
    /// inhale/exhale cue without continuous animation.
    private func tick() {
    guard isAnimating else { return }
    if reduceMotion {
        let phaseIncrement = 0.16 / cycleDuration  // ~6 fps cadence
        breathPhase = (breathPhase + phaseIncrement).truncatingRemainder(dividingBy: 1.0)
        onPhaseUpdate?(breathPhase)
        return
    }
    updateBreathPhase()
    updateRotation()
    }

    // MARK: - Computed Properties

    private var breathScale: Double {
        // Smooth sine wave for natural breathing motion
        // Maps breathPhase (0-1) to scale (0.7-1.0)
        // Shifted by 0.25 so text leads animation (hear "breathe in", then watch expand)
        let sineValue = sin((breathPhase - 0.25) * .pi * 2)
        return 0.85 + 0.15 * sineValue
    }

    private var breathGuideText: String {
        if breathPhase < 0.25 {
            return "Breathe in..."
        } else if breathPhase < 0.5 {
            return "Breathe in..."
        } else if breathPhase < 0.75 {
            return "Breathe out..."
        } else {
            return "Breathe out..."
        }
    }

    // MARK: - Animation Updates

    private func updateBreathPhase() {
        // Increment phase based on cycle duration
        // 60 fps, so each frame is ~0.016s
        let phaseIncrement = 0.016 / cycleDuration
        breathPhase = (breathPhase + phaseIncrement).truncatingRemainder(dividingBy: 1.0)
        onPhaseUpdate?(breathPhase)
    }

    private func updateRotation() {
        // Very slow rotation for subtle movement
        rotation += 0.02
        if rotation >= 360 {
            rotation = 0
        }
    }
}

// MARK: - Petal Layer

private struct PetalLayer: View {
    let petalCount: Int
    let baseScale: Double
    let layerIndex: Int
    let colors: [Color]
    let rotation: Double

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            petalRing(size: size)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }

    private func petalRing(size: CGFloat) -> some View {
        ZStack {
            ForEach(0..<petalCount, id: \.self) { petal($0, size: size) }
        }
        .frame(width: size, height: size)
    }

    private func petal(_ index: Int, size: CGFloat) -> some View {
        Petal(
            scale: baseScale,
            colorIndex: (index + layerIndex) % colors.count,
            colors: colors,
            layerOpacity: layerOpacity
        )
        .frame(width: size * 0.35, height: size * 0.55)
        .offset(y: -size * 0.2 * baseScale)
        .rotationEffect(.degrees(Double(index) * (360.0 / Double(petalCount)) + rotation))
    }

    private var layerOpacity: Double {
        switch layerIndex {
        case 0: return 0.9
        case 1: return 0.7
        default: return 0.5
        }
    }
}

// MARK: - Single Petal

private struct Petal: View {
    let scale: Double
    let colorIndex: Int
    let colors: [Color]
    let layerOpacity: Double

    var body: some View {
        Ellipse()
            .fill(
                LinearGradient(
                    colors: [
                        colors[colorIndex].opacity(layerOpacity),
                        colors[(colorIndex + 1) % colors.count].opacity(layerOpacity * 0.6)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .scaleEffect(scale)
            .shadow(color: colors[colorIndex].opacity(0.3), radius: 5, x: 0, y: 2)
    }
}

// MARK: - Preset Breathing Patterns

extension BreathingMandalaView {
    /// 4-7-8 breathing pattern (relaxation) - ~19 second cycle
    static func relaxation(onPhaseUpdate: ((Double) -> Void)? = nil) -> BreathingMandalaView {
        BreathingMandalaView(cycleDuration: 19, onPhaseUpdate: onPhaseUpdate)
    }

    /// Box breathing (4-4-4-4) - 16 second cycle
    static func boxBreathing(onPhaseUpdate: ((Double) -> Void)? = nil) -> BreathingMandalaView {
        BreathingMandalaView(cycleDuration: 16, onPhaseUpdate: onPhaseUpdate)
    }

    /// Coherence breathing (5.5 breaths/min) - ~11 second cycle
    static func coherence(onPhaseUpdate: ((Double) -> Void)? = nil) -> BreathingMandalaView {
        BreathingMandalaView(cycleDuration: 11, onPhaseUpdate: onPhaseUpdate)
    }

    /// Slow breathing (4 breaths/min) - 15 second cycle
    static func slow(onPhaseUpdate: ((Double) -> Void)? = nil) -> BreathingMandalaView {
        BreathingMandalaView(cycleDuration: 15, onPhaseUpdate: onPhaseUpdate)
    }
}

// MARK: - Preview

#Preview("Coherence") {
    VStack {
        BreathingMandalaView.coherence()
            .frame(width: 250, height: 250)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AppTheme.background)
}

#Preview("Relaxation") {
    VStack {
        BreathingMandalaView.relaxation()
            .frame(width: 250, height: 250)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AppTheme.background)
}
