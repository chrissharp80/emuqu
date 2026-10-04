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
    /// When the phase last advanced. The phase moves by the time that really
    /// passed, not a fixed step per tick, so dropped frames (BLE, charts,
    /// speech on main) do not stretch the cycle the spoken cues follow.
    @State private var lastTickAt: Date?

    /// Honour Settings → Accessibility → Motion →
    /// Reduce Motion. When true, the petals hold a fixed size and do not
    /// rotate; the breath phase still advances in real time, so the
    /// breath-guide text and the phase callback keep the same pace without
    /// continuous motion (which is contraindicated for vestibular users).
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
        .accessibilityLabel(String(localized: "Breathing guide: \(breathGuideText)", bundle: LanguageManager.appBundle))
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

    /// Reduce Motion: the phase keeps real-time pace (so the cycle length and
    /// the inhale/exhale cue stay correct) but rotation is skipped and
    /// `breathScale` holds still.
    private func tick() {
        guard isAnimating else {
            if lastTickAt != nil { lastTickAt = nil }
            return
        }
        updateBreathPhase()
        if !reduceMotion { updateRotation() }
    }

    // MARK: - Computed Properties

    private var breathScale: Double {
        if reduceMotion { return 0.85 }
        // Smooth sine wave for natural breathing motion
        // Maps breathPhase (0-1) to scale (0.7-1.0)
        // Shifted by 0.25 so text leads animation (hear "breathe in", then watch expand)
        let sineValue = sin((breathPhase - 0.25) * .pi * 2)
        return 0.85 + 0.15 * sineValue
    }

    private var breathGuideText: String {
        breathPhase < 0.5
            ? String(localized: "Breathe in", bundle: LanguageManager.appBundle)
            : String(localized: "Breathe out", bundle: LanguageManager.appBundle)
    }

    // MARK: - Animation Updates

    /// Advance by the real time since the last tick, capped at
    /// `maxTickGap` so a long stall (the app in the background) resumes the
    /// cycle where it was instead of jumping.
    private func updateBreathPhase() {
        let now = Date()
        let elapsed = lastTickAt.map { min(now.timeIntervalSince($0), Self.maxTickGap) } ?? 0
        lastTickAt = now
        breathPhase = (breathPhase + elapsed / cycleDuration).truncatingRemainder(dividingBy: 1.0)
        onPhaseUpdate?(breathPhase)
    }

    private static let maxTickGap: TimeInterval = 1.0

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
    /// A 16-second cycle, 8 s in and 8 s out on an even wave with no holds:
    /// slow paced breathing at under four breaths a minute.
    static func slowPacedBreathing(onPhaseUpdate: ((Double) -> Void)? = nil) -> BreathingMandalaView {
        BreathingMandalaView(cycleDuration: 16, onPhaseUpdate: onPhaseUpdate)
    }
}

// MARK: - Preview

#Preview("Slow paced breathing") {
    VStack {
        BreathingMandalaView.slowPacedBreathing()
            .frame(width: 250, height: 250)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AppTheme.background)
}
