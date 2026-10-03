import SwiftUI

// MARK: - Streaming Progress Panel (isolated from RecordView body evaluation)

/// Extracted as a separate View struct so that per-second timer updates and
/// heartbeat-driven state changes only re-evaluate THIS view, not the entire
/// RecordView body.
struct StreamingProgressPanel: View {
    @Environment(\.dependencies) var dependencies
    /// Plain reference for non-observable access (methods, archive, onStreamingComplete).
    /// State reads go through the observable sub-objects below
    /// (`streamingLifecycle`, `polarManager`, `breathingAudio`), which SwiftUI
    /// tracks; reads through the collector's forwarders don't re-render.
    let collector: RRCollector
    var streamingLifecycle: StreamingLifecycle
    var polarManager: PolarManager
    var breathingAudio: BreathingAudioManager
    let selectedTags: Set<ReadingTag>
    let sessionNotes: String
    let stopStreaming: () -> Void

    private var settingsManager: SettingsManager { dependencies.app.settingsManager }
    private var streamingProgress: Double {
        let target = Double(streamingLifecycle.streamingTargetSeconds)
        guard target > 0 else { return 0 }
        return min(1.0, Double(streamingLifecycle.streamingElapsedSeconds) / target)
    }

    private var formattedStreamingTime: String {
        let remaining = max(0, streamingLifecycle.streamingTargetSeconds - streamingLifecycle.streamingElapsedSeconds)
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    private var formattedElapsedTime: String {
        let s = streamingLifecycle.streamingElapsedSeconds
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        v2Body
            .onAppear { installAutoCompleteHandler() }
            .onDisappear {
                collector.onStreamingComplete = nil
                breathingAudio.isEnabled = false
            }
    }

    /// Calm recording surface. Breathing mandala
    /// is the centerpiece; everything else dims to the periphery so the
    /// user actually breathes with it instead of fixating on the timer.
    /// When the countdown finishes on its own, stop the session and carry the
    /// tags/notes the user picked before starting onto the archived reading.
    private func installAutoCompleteHandler() {
        collector.onStreamingComplete = { [weak collector] in
            guard let collector else { return }
            Task { await finishStreamingSession(collector) }
        }
    }

    private func finishStreamingSession(_ collector: RRCollector) async {
        let session = await collector.stopStreamingSession()
        guard let session, !selectedTags.isEmpty || !sessionNotes.isEmpty else { return }
        do {
            try collector.archive.updateTags(session.id, tags: Array(selectedTags), notes: sessionNotes.isEmpty ? nil : sessionNotes)
        } catch {
            debugLog("[RecordView] Failed to save tags on auto-complete: \(error)")
        }
    }

    private var v2Body: some View {
        VStack(spacing: 18) {
            timeRemainingReadout
            // A 16-second breathing cycle, 8s in and
            // 8s out on a smooth wave with no holds, to settle breathing
            // before the score reading.
            BreathingMandalaView.boxBreathing(onPhaseUpdate: { breathingAudio.updatePhase($0) })
                .frame(width: 220, height: 220)
            liveHRReadout
            voiceGuideToggle
            cancelReadingRow
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(AppTheme.background)
    }

    /// Time remaining — subtle, top
    /// Deliberately small, bottom-left, per spec.
    private var cancelReadingRow: some View {
        HStack {
            Button(action: stopStreaming) {
                Text(String(localized: "Cancel", bundle: LanguageManager.appBundle))
                    .scaledFont(size: 13)
                    .foregroundStyle(AppTheme.textTertiary)
                    .underline()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Cancel reading", bundle: LanguageManager.appBundle))
            Spacer()
        }
        .padding(.top, 8)
    }

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
                value: String(format: "%.0f", locale: .current, avgRR),
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

    private var heartRateFromRR: Double? {
        let recent = polarManager.recentRRPoints.suffix(5)
        guard recent.count >= 2 else { return nil }
        let avgRR = recent.map { Double($0.rr_ms) }.reduce(0, +) / Double(recent.count)
        guard avgRR > 0 else { return nil }
        return 60000.0 / avgRR
    }

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
