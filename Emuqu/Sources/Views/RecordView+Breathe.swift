import SwiftUI

// MARK: - RecordView Watch Breathe
//
// Split out of RecordView+Panels.swift to keep that file under the
// 1,000-line ceiling; the Breathe source is a self-contained capture path
// (pick the source, wait for the reading, show diagnostics, save it).

extension RecordView {
    var watchBreatheButton: some View {
        Button {
            withAnimation { quickSource = .watchBreathe }
            startWaitingForBreathe()
        } label: {
            watchBreatheTile
        }
        .buttonStyle(.plain)
    }

    var watchBreatheTile: some View {
        VStack(spacing: 8) {
            Image(systemName: "applewatch")
                .font(.title2)
                .foregroundColor(AppTheme.primary)
            Text(String(localized: "Watch Breathe", bundle: LanguageManager.appBundle))
                .font(.subheadline.bold())
                .foregroundColor(AppTheme.textPrimary)
            Text(String(localized: "SDNN — no strap needed", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.smallCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius)
                .stroke(Color(.separator), lineWidth: 1)
        )
    }

    func startWaitingForBreathe() {
        isWaitingForBreathe = true
        breatheTimedOut = false
        breatheReading = nil
        breatheSaved = false

        // The observer gives up after five minutes; the timeout ends the
        // waiting state so the spinner doesn't run on forever.
        collector.healthKit.startObservingBreatheHRV(
            onNewReading: { [self] reading in
                breatheReading = reading
                isWaitingForBreathe = false
            },
            onTimeout: { [self] in
                isWaitingForBreathe = false
                breatheTimedOut = true
            }
        )
        // Run diagnostics so the user can see if Watch data is reaching HealthKit at all
        Task { await collector.healthKit.runBreatheDiagnostics() }
    }

    func stopWaitingForBreathe() {
        isWaitingForBreathe = false
        collector.healthKit.stopObservingBreatheHRV()
    }

    func dismissBreatheReading() {
        breatheReading = nil
        breatheSaved = false
        withAnimation { quickSource = nil }
    }

    func saveBreatheSession(_ reading: HealthKitManager.BreatheHRVReading) {
        let session = Self.breatheSession(from: reading)
        do {
            try collector.archive.archive(session)
            breatheSaved = true
            collector.notifyArchiveChanged()
            Task { await AppDependencies.current.storage.cloudKitSyncManager.uploadSession(session) }
            debugLog("[RecordView] Saved Breathe HRV session: SDNN=\(reading.sdnn)ms")
        } catch {
            debugLog("[RecordView] Failed to save Breathe session: \(error)")
        }
    }

    /// An instantaneous Breathe reading has no RR stream of its own — only the
    /// SDNN Apple wrote — so the session carries imported metrics and no series.
    private static func breatheSession(from reading: HealthKitManager.BreatheHRVReading) -> HRVSession {
        HRVSession(
            id: UUID(),
            startDate: reading.date,
            endDate: reading.date,
            state: .complete,
            sessionType: .breathe,
            rrSeries: nil,
            analysisResult: nil,
            artifactFlags: nil,
            tags: [],
            importedMetrics: HRVSession.ImportedMetrics(
                rmssd: 0,
                rmssdRaw: 0,
                artifactPercent: 0,
                source: reading.sourceName,
                sdnn: reading.sdnn
            ),
            deviceProvenance: DeviceProvenance.imported(source: "Apple Watch Breathe (\(reading.sourceName))")
        )
    }
}

// MARK: - File-scope helpers
//
// Kept outside RecordView: each names no member of the
// type and calls nothing inside it, so none needs to be a member.
// `private` at file scope is fileprivate, so every call site in this
// file resolves the same way.
