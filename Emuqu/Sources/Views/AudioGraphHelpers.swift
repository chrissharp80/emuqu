import Accessibility
import SwiftUI

/// Build plan §5.8 — Audio Graphs accessibility helper.
///
/// Audio Graphs (iOS 15+) play pitch-modulated tones for trend perception
/// when a VoiceOver user explores a chart. Swift Charts' built-in
/// accessibility tree describes the chart structurally; an Audio Graph
/// adds the audible scrubbing layer.
///
/// Usage on any v2 chart:
///   ```
///   .accessibilityChartDescriptor(
///       AudioGraphDescriptor.line(
///           title: "HRV overnight",
///           xLabel: "Time",
///           yLabel: "RMSSD (ms)",
///           points: pts.map { ($0.time, $0.rmssd) }
///       )
///   )
///   ```
///
/// Reuse across chart variants by picking the appropriate factory below.
enum AudioGraphDescriptor {
    /// One-series line chart of (Date, Double) points.
    static func line(
        title: String,
        xLabel: String,
        yLabel: String,
        points: [(date: Date, value: Double)]
    ) -> some AXChartDescriptorRepresentable {
        LineChartDescriptor(title: title, xLabel: xLabel, yLabel: yLabel, points: points)
    }

    /// One-series bar / point chart of (Double, Double) points where the
    /// x axis is a continuous numeric (e.g. minutes-from-start), suitable
    /// for the workout α1 / HR-over-time charts.
    static func numericLine(
        title: String,
        xLabel: String,
        yLabel: String,
        points: [(x: Double, y: Double)]
    ) -> some AXChartDescriptorRepresentable {
        NumericLineDescriptor(title: title, xLabel: xLabel, yLabel: yLabel, points: points)
    }
}

private struct LineChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let xLabel: String
    let yLabel: String
    let points: [(date: Date, value: Double)]

    /// Hoisted out of the per-value `valueDescriptionProvider` closure —
    /// VoiceOver invokes that provider once per scrubbed axis value, and
    /// a fresh `DateFormatter()` per call is needlessly expensive.
    private static let axisDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    func makeChartDescriptor() -> AXChartDescriptor {
        let series = AXDataSeriesDescriptor(
            name: title,
            isContinuous: true,
            dataPoints: points.map { AXDataPoint(x: $0.date.timeIntervalSinceReferenceDate, y: $0.value) }
        )
        return AXChartDescriptor(
            title: title,
            summary: nil,
            xAxis: dateAxis(),
            yAxis: valueAxis(),
            additionalAxes: [],
            series: [series]
        )
    }

    /// Dates are exposed to VoiceOver as reference-interval numbers with a
    /// formatter attached, which is the only shape AXNumericDataAxisDescriptor
    /// accepts.
    private func dateAxis() -> AXNumericDataAxisDescriptor {
        let xValues = points.map(\.date)
        let minX = xValues.min() ?? Date()
        let maxX = xValues.max() ?? Date()
        return AXNumericDataAxisDescriptor(
            title: xLabel,
            range: minX.timeIntervalSinceReferenceDate...maxX.timeIntervalSinceReferenceDate,
            gridlinePositions: [],
            valueDescriptionProvider: { ts in
                Self.axisDateFormatter.string(from: Date(timeIntervalSinceReferenceDate: ts))
            }
        )
    }

    private func valueAxis() -> AXNumericDataAxisDescriptor {
        let yValues = points.map(\.value)
        let minY = yValues.min() ?? 0
        let maxY = yValues.max() ?? 1
        return AXNumericDataAxisDescriptor(
            title: yLabel,
            range: minY...max(maxY, minY + 1),
            gridlinePositions: [],
            valueDescriptionProvider: { String(format: "%.1f", locale: .current, $0) }
        )
    }
}

private struct NumericLineDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let xLabel: String
    let yLabel: String
    let points: [(x: Double, y: Double)]

    func makeChartDescriptor() -> AXChartDescriptor {
        let series = AXDataSeriesDescriptor(
            name: title,
            isContinuous: true,
            dataPoints: points.map { AXDataPoint(x: $0.x, y: $0.y) }
        )
        return AXChartDescriptor(
            title: title,
            summary: nil,
            xAxis: numericAxis(title: xLabel, values: points.map(\.x), format: "%.1f"),
            yAxis: numericAxis(title: yLabel, values: points.map(\.y), format: "%.2f"),
            additionalAxes: [],
            series: [series]
        )
    }

    /// A degenerate range (all values equal) would make VoiceOver's scrubber
    /// unusable, so the upper bound is nudged to at least min + 1.
    private func numericAxis(title: String, values: [Double], format: String) -> AXNumericDataAxisDescriptor {
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        return AXNumericDataAxisDescriptor(
            title: title,
            range: lo...max(hi, lo + 1),
            gridlinePositions: [],
            valueDescriptionProvider: { String(format: format, locale: .current, $0) }
        )
    }
}
