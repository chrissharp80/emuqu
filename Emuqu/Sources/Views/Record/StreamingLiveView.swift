import SwiftUI

// MARK: - Streaming Progress Panel (isolated from RecordView body evaluation)

/// Extracted as a separate View struct so that per-second timer updates and
/// heartbeat-driven state changes only re-evaluate THIS view, not the entire
/// RecordView body.
struct StreamingProgressPanel: View {
    /// Plain reference for non-observable access (onStreamingComplete).
    /// State reads go through the observable sub-objects below
    /// (`streamingLifecycle`, `polarManager`, `breathingAudio`), which SwiftUI
    /// tracks; reads through the collector's forwarders don't re-render.
    let collector: RRCollector
    var streamingLifecycle: StreamingLifecycle
    var polarManager: PolarManager
    var breathingAudio: BreathingAudioManager
    let stopStreaming: () -> Void

    private var formattedStreamingTime: String {
        let remaining = max(0, streamingLifecycle.streamingTargetSeconds - streamingLifecycle.streamingElapsedSeconds)
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    var body: some View {
        v2Body
            .onAppear { installAutoCompleteHandler() }
            .onDisappear { breathingAudio.isEnabled = false }
    }

    /// When the countdown finishes on its own, stop the session the same way
    /// the Stop button does, which saves the tags and notes current at that
    /// moment. The handler stays installed when the panel leaves the screen
    /// (another tab, say): the countdown keeps running in the collector, and
    /// without a handler the reading never ended. The next panel replaces it.
    private func installAutoCompleteHandler() {
        collector.onStreamingComplete = stopStreaming
    }

    /// Calm recording surface. Breathing mandala
    /// is the centerpiece; everything else dims to the periphery so the
    /// user actually breathes with it instead of fixating on the timer.
    private var v2Body: some View {
        VStack(spacing: 18) {
            timeRemainingReadout
            // A 16-second breathing cycle, 8s in and
            // 8s out on a smooth wave with no holds, to settle breathing
            // before the score reading.
            BreathingMandalaView.slowPacedBreathing(onPhaseUpdate: { breathingAudio.updatePhase($0) })
                .frame(width: 220, height: 220)
            liveHRReadout
            voiceGuideToggle
            stopReadingRow
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(AppTheme.background)
    }

    /// Deliberately small, bottom-left. It ends the reading early rather
    /// than discarding it: a reading of 120 beats or more is scored and saved.
    private var stopReadingRow: some View {
        HStack {
            Button(action: stopStreaming) {
                Text(String(localized: "Stop now", bundle: LanguageManager.appBundle))
                    .scaledFont(size: 13)
                    .foregroundStyle(AppTheme.textTertiary)
                    .underline()
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Stop reading now", bundle: LanguageManager.appBundle))
            .accessibilityHint(String(localized: "Ends the reading early. Two minutes or more is scored and saved.", bundle: LanguageManager.appBundle))
            Spacer()
        }
        .padding(.top, 8)
    }

    /// Time remaining — subtle, top.
    private var timeRemainingReadout: some View {
        VStack(spacing: 2) {
            Text(verbatim: formattedStreamingTime)
                .scaledFont(size: 32, weight: .light, design: .rounded, monospacedDigit: true)
                .foregroundStyle(AppTheme.textPrimary)
            Text(String(localized: "remaining", bundle: LanguageManager.appBundle))
                .scaledFont(size: 11)
                .foregroundStyle(AppTheme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.5)
        }
    }

    /// HR — small, subdued, below
    @ViewBuilder
    private var liveHRReadout: some View {
        if let hr = polarManager.currentHeartRate {
            HStack(spacing: 6) {
                Image(systemName: "heart.fill")
                    .scaledFont(size: 12)
                    .foregroundStyle(AppTheme.wongAttention.opacity(0.7))
                Text(String(localized: "\(hr) bpm", bundle: LanguageManager.appBundle))
                    .scaledFont(size: 14, weight: .medium, monospacedDigit: true)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    /// Voice guide toggle — small pill, dimmer
    private var voiceGuideToggle: some View {
        Button {
            breathingAudio.isEnabled.toggle()
        } label: {
            v2BodyLabel
                // The pill stays small; the tap area is the 44-point minimum.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var v2BodyLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: breathingAudio.isEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                .scaledFont(size: 11)
            Text(breathingAudio.isEnabled
                ? String(localized: "Voice on", bundle: LanguageManager.appBundle)
                : String(localized: "Voice off", bundle: LanguageManager.appBundle))
                .scaledFont(size: 11)
        }
        .foregroundStyle(breathingAudio.isEnabled ? AppTheme.wongOptimalText : AppTheme.textTertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(AppTheme.sectionTint))
    }

}

// MARK: - Streaming Stats Row

/// Stats row extracted so recentRRPoints changes only re-evaluate this row.
struct StreamingStatsRow: View {
    var streamingLifecycle: StreamingLifecycle
    var polarManager: PolarManager

    var body: some View {
        HStack(spacing: 12) {
            beatsPill
            elapsedPill
            averageRRPill
        }
    }

    private var beatsPill: some View {
        StreamingStatPill(
            value: "\(streamingLifecycle.pausedBeatCount + polarManager.streamedRRCount)",
            label: String(localized: "beats", bundle: LanguageManager.appBundle),
            color: AppTheme.primary
        )
    }

    private var elapsedPill: some View {
        let s = streamingLifecycle.streamingElapsedSeconds
        return StreamingStatPill(
            value: String(format: "%d:%02d", s / 60, s % 60),
            label: String(localized: "elapsed", bundle: LanguageManager.appBundle),
            color: AppTheme.sage
        )
    }

    /// Averaged over the last 20 beats, and only once enough have arrived for
    /// the number to mean anything.
    @ViewBuilder
    private var averageRRPill: some View {
        if polarManager.recentRRPoints.count > 5 {
            let recentRR = polarManager.recentRRPoints.suffix(20)
            let avgRR = recentRR.map { Double($0.rr_ms) }.reduce(0, +) / Double(recentRR.count)
            StreamingStatPill(
                value: String(format: "%.0f", locale: LanguageManager.appLocale, avgRR),
                label: String(localized: "avg RR", bundle: LanguageManager.appBundle),
                color: AppTheme.mist
            )
        }
    }
}

// MARK: - Streaming Stat Pill

/// Streaming stat pill -- value-only struct, no observation.
struct StreamingStatPill: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.subheadline, design: .rounded).bold())
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(AppTheme.sectionTint)
        .cornerRadius(8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(label): \(value)", bundle: LanguageManager.appBundle))
    }
}

// MARK: - Live Data Panel (isolated from RecordView body evaluation)

/// Separate View struct so recentRRPoints changes only re-evaluate this panel,
/// not the entire RecordView body.
struct LiveDataPanel: View {
    var polarManager: PolarManager

    var body: some View {
        VStack(spacing: 16) {
            currentHRRow
            waveformAndStats
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var currentHRRow: some View {
        if let hr = polarManager.currentHeartRate {
            HStack {
                Image(systemName: "heart.fill")
                    .foregroundColor(.red)
                Text(String(localized: "\(hr)", bundle: LanguageManager.appBundle))
                    .font(.system(.title, design: .rounded).bold())
                Text(String(localized: "bpm", bundle: LanguageManager.appBundle))
                    .foregroundColor(AppTheme.textSecondary)
                Spacer()
            }
        }
    }

    /// The waveform needs a few beats before it reads as a trace rather than
    /// noise, so both it and the stats card wait for 10.
    @ViewBuilder
    private var waveformAndStats: some View {
        if polarManager.recentRRPoints.count > 10 {
            LiveWaveformView(
                rrPoints: polarManager.recentRRPoints,
                maxPoints: 60,
                showGrid: true,
                accentColor: .green
            )
            LiveStatsCard(rrPoints: polarManager.recentRRPoints)
        }
    }
}
