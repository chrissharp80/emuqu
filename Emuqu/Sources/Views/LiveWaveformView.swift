import SwiftUI

/// Live waveform display for real-time RR interval visualization
struct LiveWaveformView: View {
    let rrPoints: [RRPoint]
    let maxPoints: Int
    let showGrid: Bool
    let accentColor: Color

    init(
        rrPoints: [RRPoint],
        maxPoints: Int = 60,
        showGrid: Bool = true,
        accentColor: Color = .green
    ) {
        self.rrPoints = rrPoints
        self.maxPoints = maxPoints
        self.showGrid = showGrid
        self.accentColor = accentColor
    }

    /// Display the last N points
    private var displayPoints: [RRPoint] {
        let count = rrPoints.count
        if count <= maxPoints {
            return Array(rrPoints)
        }
        return Array(rrPoints.suffix(maxPoints))
    }

    /// Y-axis range
    private var yRange: (min: Double, max: Double) {
        let values = displayPoints.map { Double($0.rr_ms) }
        guard !values.isEmpty else { return (400, 1200) }
        // 10% padding, clamped to a plausible RR window.
        let padding = ((values.max() ?? 1200) - (values.min() ?? 400)) * 0.1
        let lo = max(300, (values.min() ?? 400) - padding)
        let hi = min(2000, (values.max() ?? 1200) + padding)
        return Self.nonDegenerateSpan(lo: lo, hi: hi)
    }

    /// Guarantee a positive, non-zero span. A flat window (all identical RR —
    /// the Polar strap can emit repeated intervals) would make hi == lo →
    /// yScale = height / 0 = ∞ → 0·∞ = NaN in the Path geometry (blank/garbage
    /// render, possible CG crash). Also covers the inverted case where clamping
    /// pushed lo above hi. Healthy data (span ≥ 1 ms) is unchanged.
    private static func nonDegenerateSpan(lo: Double, hi: Double) -> (min: Double, max: Double) {
        guard hi - lo >= 1 else {
            let mid = (lo + hi) / 2
            return (mid - 0.5, mid + 0.5)
        }
        return (lo, hi)
    }

    /// Current heart rate
    private var currentHR: Int? {
        guard let lastRR = displayPoints.last else { return nil }
        return Int(60000.0 / Double(lastRR.rr_ms))
    }

    /// Current RR
    private var currentRR: Int? {
        displayPoints.last?.rr_ms
    }

    var body: some View {
        VStack(spacing: 8) {
            waveformHeader
            waveformCanvas
            // Y-axis labels
            HStack {
                Text("\(Int(yRange.max))")
                    .font(.caption2)
                    .foregroundColor(AppTheme.textSecondary)
                Spacer()
                Text(String(localized: "RR (ms)", bundle: LanguageManager.appBundle))
                    .font(.caption2)
                    .foregroundColor(AppTheme.textSecondary)
                Spacer()
                Text(String(localized: "\(Int(yRange.min))", bundle: LanguageManager.appBundle))
                    .font(.caption2)
                    .foregroundColor(AppTheme.textSecondary)
            }
            .padding(.horizontal, 4)
        }
    }

    /// Header with current values
    private var waveformHeader: some View {
        HStack {
            currentHRReadout

            Spacer()

            currentRRReadout
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var currentHRReadout: some View {
        if let hr = currentHR {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .foregroundColor(.red)
                Text(String(localized: "\(hr)", bundle: LanguageManager.appBundle))
                    .font(.title2.monospacedDigit().bold())
                Text(String(localized: "bpm", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Heart rate: \(hr) beats per minute", bundle: LanguageManager.appBundle))
        }
    }

    @ViewBuilder
    private var currentRRReadout: some View {
        if let rr = currentRR {
            HStack(spacing: 4) {
                Text("\(rr)")
                    .font(.title2.monospacedDigit().bold())
                Text(String(localized: "ms", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "RR interval: \(rr) milliseconds", bundle: LanguageManager.appBundle))
        }
    }

    /// Waveform
    private func waveformLayers(size: CGSize) -> some View {
        ZStack {
            if showGrid {
                gridView(size: size)
            }
            waveformPath(size: size)
                .stroke(accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if !displayPoints.isEmpty {
                currentMarker(size: size)
            }
        }
    }

    private var waveformCanvas: some View {
        GeometryReader { geometry in
            waveformLayers(size: geometry.size)
        }
        .frame(height: 150)
        .background(Color.black.opacity(0.05))
        .cornerRadius(12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Live RR waveform, \(displayPoints.count) points, range \(Int(yRange.min)) to \(Int(yRange.max)) milliseconds", bundle: LanguageManager.appBundle))
    }

    // MARK: - Grid

    private func gridView(size: CGSize) -> some View {
        Canvas { context, _ in
            for i in 0 ... 4 {
                let y = size.height * CGFloat(i) / 4
                Self.strokeGridLine(context, from: CGPoint(x: 0, y: y), to: CGPoint(x: size.width, y: y))
            }
            for i in 0 ... 6 {
                let x = size.width * CGFloat(i) / 6
                Self.strokeGridLine(context, from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: size.height))
            }
        }
    }

    private static func strokeGridLine(_ context: GraphicsContext, from: CGPoint, to: CGPoint) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(path, with: .color(.gray.opacity(0.2)), lineWidth: 0.5)
    }

    // MARK: - Waveform Path

    private func waveformPath(size: CGSize) -> Path {
        var path = Path()
        guard displayPoints.count >= 2 else { return path }
        let xStep = size.width / CGFloat(maxPoints - 1)
        let yMin = yRange.min
        let yScale = size.height / (yRange.max - yMin)
        // Start offset to right-align if fewer points than max
        let startOffset = CGFloat(maxPoints - displayPoints.count) * xStep
        for (index, point) in displayPoints.enumerated() {
            let x = startOffset + CGFloat(index) * xStep
            let y = size.height - (Double(point.rr_ms) - yMin) * yScale
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }

    // MARK: - Current Marker

    private func currentMarker(size: CGSize) -> some View {
        let xStep = size.width / CGFloat(maxPoints - 1)
        let yMin = yRange.min
        let yMax = yRange.max
        let yScale = size.height / (yMax - yMin)

        let startOffset = CGFloat(maxPoints - displayPoints.count) * xStep
        let lastIndex = displayPoints.count - 1
        let lastPoint = displayPoints[lastIndex]

        let x = startOffset + CGFloat(lastIndex) * xStep
        let y = size.height - (Double(lastPoint.rr_ms) - yMin) * yScale

        return Circle()
            .fill(accentColor)
            .frame(width: 8, height: 8)
            .position(x: x, y: y)
            .shadow(color: accentColor.opacity(0.5), radius: 4)
    }
}

// MARK: - Live Stats Card

struct LiveStatsCard: View {
    let rrPoints: [RRPoint]

    private var stats: (rmssd: Double, sdnn: Double, meanHR: Double)? {
        guard rrPoints.count >= 10 else { return nil }

        let rrValues = rrPoints.suffix(30).map { Double($0.rr_ms) }
        let n = rrValues.count

        // Mean
        let mean = rrValues.reduce(0, +) / Double(n)

        // SDNN
        let variance = rrValues.map { pow($0 - mean, 2) }.reduce(0, +) / Double(n - 1)
        let sdnn = sqrt(variance)

        // RMSSD — shared helper so this live-chart metric matches the
        // canonical `TimeDomainAnalyzer.computeTimeDomain` path byte-for-byte.
        let rmssd = TimeDomainAnalyzer.rmssd(fromCleanRRs: rrValues) ?? 0

        // Mean HR
        let meanHR = 60000.0 / mean

        return (rmssd, sdnn, meanHR)
    }

    var body: some View {
        HStack(spacing: 16) {
            if let s = stats {
                StatItem(label: "RMSSD", value: String(format: "%.0f", locale: .current, s.rmssd), unit: "ms")
                StatItem(label: "SDNN", value: String(format: "%.0f", locale: .current, s.sdnn), unit: "ms")
                StatItem(label: "Avg HR", value: String(format: "%.0f", locale: .current, s.meanHR), unit: "bpm")
            } else {
                Text(String(localized: "Collecting data...", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
}

private struct StatItem: View {
    let label: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title3.monospacedDigit().bold())
                Text(unit)
                    .font(.caption2)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(label): \(value) \(unit)", bundle: LanguageManager.appBundle))
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        // Generate sample RR points
        let samplePoints: [RRPoint] = (0 ..< 50).map { i in
            let baseRR = 800 + Int.random(in: -100 ... 100)
            return RRPoint(t_ms: Int64(i * 800), rr_ms: baseRR)
        }

        LiveWaveformView(rrPoints: samplePoints)
            .padding()

        LiveStatsCard(rrPoints: samplePoints)
            .padding()
    }
}
