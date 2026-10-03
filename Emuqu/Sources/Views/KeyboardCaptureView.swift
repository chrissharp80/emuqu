import SwiftUI
import UIKit

/// Settings → Troubleshooting → Keyboard performance.
///
/// Records an os_signpost timeline of the chat-input render path,
/// the keyboard show/hide notifications, and the textfield focus
/// events. User taps Start, exercises the keyboard, taps Stop —
/// or the 10-minute watchdog stops the capture if they forget.
///
/// **Design.** Capture lifetime is not tied to `.onDisappear` (that
/// stopped on tab switch), and there is no 60 s auto-stop, which the
/// user (rightly) called arbitrary; they wanted longer windows. So:
///   • capture runs until the user taps Stop, with a 10-minute
///     safety ceiling for runaway sessions;
///   • leaving the screen does not stop the capture;
///   • share uses the app's existing UIActivityViewController
///     wrapper (faster than SwiftUI's ShareLink, which spends time
///     generating a preview thumbnail);
///   • the file path is shown in the UI so the user can grab the
///     trace via Files / AirDrop / iTunes file sharing if the
///     share sheet is being slow.
struct KeyboardCaptureView: View {
    @Environment(\.dependencies) var dependencies
    private var perf: KeyboardPerfSignpost { dependencies.app.keyboardPerfSignpost }
    @State private var elapsed: TimeInterval = 0
    @State private var elapsedTimer: Timer?
    @State private var sharePresented = false

    var body: some View {
        Form {
            captureControlsSection
            howToCaptureSection
            traceSectionBody
            lastTraceSection
        }
        .navigationTitle(String(localized: "Keyboard performance", bundle: LanguageManager.appBundle))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $sharePresented) { traceShareSheet }
        .onAppear {
            if perf.isCapturing { installElapsedTimer() }
        }
        .onDisappear {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
        }
    }

    @ViewBuilder
    private var traceShareSheet: some View {
        if let url = perf.lastTraceURL {
            ShareSheet(activityItems: [url])
        }
    }

    private var captureControlsSection: some View {
        Section {
            Text("Records the chat view's render path, keyboard show/hide notifications, textfield focus events, and a 200 ms main-thread heartbeat. Used to find what's blocking the keyboard.", bundle: LanguageManager.appBundle)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var traceSectionBody: some View {
        Section {
            if perf.isCapturing {
                capturingRow
                traceSectionRows
            } else {
                startCaptureButton
            }
        }
    }

    private var capturingRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
            Text(verbatim: formattedElapsed(elapsed))
                .font(.system(.body, design: .rounded).monospacedDigit())
            Spacer()
            Text(Self.eventsText(perf.currentEventCount()))
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var traceSectionRows: some View {
        Button(String(localized: "Stop capture", bundle: LanguageManager.appBundle), role: .destructive) {
            stopCapture()
        }
    }

    @ViewBuilder
    private var lastTraceSection: some View {
        if let url = perf.lastTraceURL {
            lastTraceBody(url)
        }
    }

    private func lastTraceBody(_ url: URL) -> some View {
        Section(String(localized: "Last trace", bundle: LanguageManager.appBundle)) {
            capturedAtLabel
            Text(Self.eventsText(perf.lastTraceEventCount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.textSecondary)
            shareTraceButton
            Text(verbatim: url.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var capturedAtLabel: some View {
        if let captured = perf.captureStartedAt {
            let when = captured.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(LanguageManager.appLocale))
            Text(String(localized: "Captured \(when)", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var howToCaptureSection: some View {
        Section(String(localized: "How to capture", bundle: LanguageManager.appBundle)) {
            stepRow(1, "Tap **Start capture**.")
            stepRow(2, "Go exercise the keyboard wherever you want — Flo tab, Settings email, anywhere.")
            stepRow(3, "Come back and tap **Stop**. There's no rush; capture runs as long as you want (up to 10 min).")
            stepRow(4, "Tap **Share** and send the trace.")
        }
    }

    private var shareTraceButton: some View {
        Button {
            sharePresented = true
        } label: {
            Label(String(localized: "Share trace…", bundle: LanguageManager.appBundle), systemImage: "square.and.arrow.up")
        }
    }

    private var startCaptureButton: some View {
        Button {
            startCapture()
        } label: {
            Label(String(localized: "Start capture", bundle: LanguageManager.appBundle), systemImage: "record.circle")
        }
    }

    // MARK: - Actions

    private func startCapture() {
        guard perf.startCapture() else { return }
        installElapsedTimer()
    }

    private func stopCapture() {
        _ = perf.stopCaptureAndExportTrace()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        elapsed = 0
    }

    /// `Timer.scheduledTimer` adds the timer to the *current* run loop
    /// in default mode; we're called from a SwiftUI button on @MainActor,
    /// so the closure fires on the main run loop. The closure parameter
    /// is `@Sendable`, so we bridge into the main actor explicitly.
    private func installElapsedTimer() {
        let start = perf.captureStartedAt ?? Date()
        elapsed = Date().timeIntervalSince(start)
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { tickElapsed(since: start) }
        }
    }

    /// Stops itself once the capture ends, so a dismissed sheet doesn't leave
    /// a timer running.
    @MainActor
    private func tickElapsed(since start: Date) {
        elapsed = Date().timeIntervalSince(start)
        guard !perf.isCapturing else { return }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        elapsed = 0
    }

    // MARK: - Formatting

    private func formattedElapsed(_ s: TimeInterval) -> String {
        let time = Duration.seconds(Int(s))
            .formatted(.time(pattern: .minuteSecond).locale(LanguageManager.appLocale))
        return String(localized: "Capturing… \(time)", bundle: LanguageManager.appBundle)
    }

    private static func eventsText(_ count: Int) -> String {
        String(localized: "\(count) events", bundle: LanguageManager.appBundle)
    }

    // MARK: - Steps

    /// `text` is a catalog key; `Text(_:bundle:)` renders its markdown bold.
    private func stepRow(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(n).")
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(.tint)
                .frame(width: 18, alignment: .leading)
            Text(text, bundle: LanguageManager.appBundle)
                .scaledFont(size: 14)
            Spacer(minLength: 0)
        }
    }
}
