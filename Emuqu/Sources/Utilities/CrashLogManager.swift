import Foundation
import UIKit

/// Captures uncaught exceptions and signals, persists crash logs for later export
/// Works in Release builds - users can share crash logs via Settings
/// Stateless: paths are computed and the log lives on disk, so it is `Sendable`.
final class CrashLogManager: Sendable {
    static let shared = CrashLogManager()

    private let crashLogFileName = "crash_log.txt"
    private let previousCrashFileName = "previous_crash.txt"

    private var crashLogURL: URL {
        storageDirectory.appendingPathComponent(crashLogFileName)
    }

    private var previousCrashURL: URL {
        storageDirectory.appendingPathComponent(previousCrashFileName)
    }

    private var storageDirectory: URL {
        AppConfig.sharedContainerURL()
    }

    /// Returns true if there's a crash log from a previous session
    var hasPreviousCrash: Bool {
        FileManager.default.fileExists(atPath: previousCrashURL.path)
    }

    /// Returns the previous crash log content, if any
    var previousCrashLog: String? {
        try? String(contentsOf: previousCrashURL, encoding: .utf8)
    }

    private init() {}

    /// Call this once at app startup to install crash handlers
    func install() {
        // Move any existing crash log to "previous" before we start
        promoteCurrentCrashLog()

        // Install exception handler for NSExceptions and Swift errors that bridge
        NSSetUncaughtExceptionHandler { exception in
            AppDependencies.current.app.crashLogManager.writeCrashLog(
                type: "Exception",
                name: exception.name.rawValue,
                reason: exception.reason ?? "Unknown",
                stackTrace: exception.callStackSymbols.joined(separator: "\n")
            )
        }

        // Install signal handlers for crashes that don't throw exceptions
        installSignalHandlers()
    }

    /// Clears the previous crash log (call after user has seen/exported it)
    func clearPreviousCrash() {
        do {
            try FileManager.default.removeItem(at: previousCrashURL)
        } catch let nsError as NSError where nsError.domain == NSCocoaErrorDomain &&
            nsError.code == NSFileNoSuchFileError {
            // Nothing to clear.
        } catch {
            debugLog("[CrashLogManager] Failed to clear previous crash log: \(error)")
        }
    }

    /// Remove both the live and rolled-over crash logs. Used by the
    /// "Delete All My Data" flow so no HR / session-id traces survive a
    /// wipe. Failures are collected into the thrown error so the caller can
    /// surface them in the purge report.
    func clearAll() throws {
        var collected: [Error] = []
        let fm = FileManager.default
        for url in [crashLogURL, previousCrashURL] {
            do { try fm.removeItem(at: url) } catch let nsError as NSError where nsError.domain == NSCocoaErrorDomain &&
                nsError.code == NSFileNoSuchFileError {
                // nothing to clear
            } catch { collected.append(error) }
        }
        if let first = collected.first { throw first }
    }

    /// Record that iOS terminated the app during an active session.
    /// SIGKILL from iOS (background time expiry, memory pressure) can't be caught by
    /// signal handlers, so we detect it on next launch via orphaned persisted state.
    func recordTermination(sessionId: UUID, sessionStart: Date, sessionType: String) {
        // Don't overwrite a real crash log (with stack trace) — it's more valuable
        guard !hasPreviousCrash else {
            debugLog("[CrashLogManager] Skipping termination report — real crash log already exists")
            return
        }
        writeTerminationReport([
            sessionInfoBlock(sessionId: sessionId, sessionStart: sessionStart, sessionType: sessionType),
            Self.terminationCauseBlock,
            forensicsBlock(sessionId: sessionId, sessionStart: sessionStart),
            diagnosticContextBlock()
        ].joined(separator: "\n\n"))
    }

    /// Scrub PHI at write time (see writeCrashLog) — the report is stored in
    /// the shared App Group container before the user ever exports it. Written
    /// as the "previous" crash, since this is detected on the NEXT launch.
    private func writeTerminationReport(_ content: String) {
        let scrubbed = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { DebugLogger.scrubPHI(String($0)) }
            .joined(separator: "\n")
        do {
            try scrubbed.write(to: previousCrashURL, atomically: true, encoding: .utf8)
        } catch {
            debugLog("[CrashLogManager] Failed to write termination report: \(error)")
        }
    }

    /// Report banner plus the identity of the session that was cut short.
    private func sessionInfoBlock(sessionId: UUID, sessionStart: Date, sessionType: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        let header = formatLogHeader(title: "EMUQU TERMINATION REPORT", timestamp: Date())
        return """
        \(header)

        --------------------------------------------------------------------------------
        SESSION INFO
        --------------------------------------------------------------------------------

        Session ID: \(sessionId.uuidString)
        Session Type: \(sessionType)
        Session Started: \(dateFormatter.string(from: sessionStart))
        """
    }

    /// Why a SIGKILL is not a code crash, said in the report itself.
    private static let terminationCauseBlock = """
        --------------------------------------------------------------------------------
        CAUSE
        --------------------------------------------------------------------------------

        The app was terminated by iOS while a recording session was active.
        No signal or exception was caught — this indicates a SIGKILL from iOS, typically
        caused by: background execution time expiry, memory pressure, or thermal shutdown.

        This is NOT a code crash. The persisted recording state survived and was detected
        on the next app launch.
        """

    /// Forensics from the RawRRBackup index for THIS
    /// session ID. Answers two questions: WHEN did the crash
    /// happen (last_backup_time ≈ time of death, within the
    /// incremental-backup interval), and WHERE is the user's data
    /// (count + bytes on disk + recovered-into-archive flag), so a
    /// SIGKILL log shows whether the recording survived at all.
    private func forensicsBlock(sessionId: UUID, sessionStart: Date) -> String {
        let recordingForensics = Self.formatRecordingForensics(
            sessionId: sessionId,
            sessionStart: sessionStart
        )
        return """
        --------------------------------------------------------------------------------
        RECORDING FORENSICS (approximate time of death + data preserved)
        --------------------------------------------------------------------------------

        \(recordingForensics)
        """
    }

    /// Pull in the diagnostic context that
    /// SystemDiagnosticsManager has accumulated. We can't know
    /// the exact iOS exit reason synchronously (MetricKit
    /// delivers payloads asynchronously, often a day later) but
    /// we CAN show: last-sampled memory footprint, last thermal
    /// state, memory warning count, and the last few minutes of
    /// memory trace so the user / developer can see whether the
    /// app was approaching a memory limit at termination.
    private func diagnosticContextBlock() -> String {
        let diagnostics = Self.formatDiagnosticContext()
        return """
        --------------------------------------------------------------------------------
        DIAGNOSTIC CONTEXT (last sampled before termination)
        --------------------------------------------------------------------------------

        \(diagnostics)

        Note: MetricKit's MXMetricPayload (with the categorized exit reason —
        memory_resource_limit / cpu_resource_limit / background_task_assertion_timeout /
        app_watchdog) typically lands on the FOLLOWING launch, not this one. Check
        Settings → Help & Diagnostics → System Diagnostics in 24 h.

        ================================================================================
        END OF TERMINATION REPORT
        ================================================================================
        """
    }

    /// Exports crash log to a shareable file, returns URL
    ///
    /// Scrubs PHI before writing the export
    /// file. Crash content can include stack-frame variable dumps with
    /// HRV / heart rate / location values from the active session;
    /// those must not leave the device through a shared text file. Uses
    /// the same scrubber as the persistent debug log.
    func exportCrashLog() -> URL? {
        guard let content = previousCrashLog else { return nil }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let fileName = "Emuqu_Crash_\(timestamp).txt"
        let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        let scrubbed = content
            .components(separatedBy: "\n")
            .map { DebugLogger.scrubPHI($0) }
            .joined(separator: "\n")

        do {
            try scrubbed.write(to: exportURL, atomically: true, encoding: .utf8)
            return exportURL
        } catch {
            return nil
        }
    }

    // MARK: - Private

    /// One window's worth of memory + thermal history, summarized.
    private struct TraceSummary {
        var peakMB: Double = 0
        var finalMB: Double = 0
        var peakThermal: String = "nominal"
        var warnings: Int = 0
    }

    /// Build the diagnostic-context block included in
    /// termination reports. Reads the most recent samples from
    /// `SystemDiagnosticsManager`'s memory_trace.jsonl and surfaces
    /// the trailing window so the user can see what the app's
    /// memory + thermal state was right before iOS killed it.
    private static func formatDiagnosticContext() -> String {
        // Read the most recent ~30 samples (~2.5 minutes at 5 s
        // cadence — enough to see a memory-pressure ramp).
        let trace = AppDependencies.current.app.systemDiagnosticsManager.readRecentMemoryTrace(limit: 30)
        guard !trace.isEmpty else {
            return "No memory/thermal samples recorded for this session."
        }
        let summary = summarize(trace: trace)
        return """
        Peak memory:        \(String(format: "%.1f", summary.peakMB)) MB (phys_footprint)
        Final memory:       \(String(format: "%.1f", summary.finalMB)) MB
        Peak thermal state: \(summary.peakThermal)
        Memory warnings:    \(summary.warnings)
        Samples in window:  \(trace.count)

        Trailing samples (most recent last):
        \(traceTimeline(trace).joined(separator: "\n"))
        """
    }

    /// Peak memory in the window, final memory, thermal peak, and the highest
    /// memory-warning count observed.
    private static func summarize(trace: [[String: Any]]) -> TraceSummary {
        var summary = TraceSummary()
        for sample in trace {
            if let mb = megabytes(in: sample) {
                summary.peakMB = max(summary.peakMB, mb)
                summary.finalMB = mb
            }
            summary.peakThermal = hotterThermal(summary.peakThermal, sample["thermal"] as? String)
            summary.warnings = max(summary.warnings, sample["memory_warnings_total"] as? Int ?? 0)
        }
        return summary
    }

    /// Thermal state is an ordered ladder, not a number, so "peak" means the
    /// later rung on nominal → fair → serious → critical.
    private static func hotterThermal(_ current: String, _ candidate: String?) -> String {
        let order = ["nominal": 0, "fair": 1, "serious": 2, "critical": 3]
        guard let candidate, (order[candidate] ?? 0) > (order[current] ?? 0) else { return current }
        return candidate
    }

    /// `memory_bytes` decodes as UInt64 or Int depending on how JSONSerialization
    /// sized the number, so both spellings are accepted.
    private static func megabytes(in sample: [String: Any]) -> Double? {
        if let bytes = sample["memory_bytes"] as? UInt64 { return Double(bytes) / 1_048_576 }
        if let bytes = sample["memory_bytes"] as? Int { return Double(bytes) / 1_048_576 }
        return nil
    }

    /// Trailing 5 samples as raw timeline.
    private static func traceTimeline(_ trace: [[String: Any]]) -> [String] {
        trace.suffix(5).map { sample in
            let ts = (sample["ts"] as? String) ?? "?"
            let mb = (sample["memory_mb"] as? String) ?? "?"
            let thermal = (sample["thermal"] as? String) ?? "?"
            let reason = (sample["reason"] as? String) ?? "?"
            return "  \(ts) — \(mb) MB · thermal=\(thermal) · \(reason)"
        }
    }

    /// The header time on this report is when iOS *detected* the
    /// orphaned recording on the NEXT launch — not when the crash
    /// happened. The header date can be many hours after the actual
    /// kill (overnight recordings stretch ~9 h). This block makes
    /// the *real* termination time visible.
    private static func formatRecordingForensics(sessionId: UUID, sessionStart: Date) -> String {
        guard let summary = RawRRBackup.terminationForensicsSummary(for: sessionId) else {
            return noBackupIndexExplanation
        }
        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let lastBackupStr = summary.lastBackupTime.map { isoFormatter.string(from: $0) } ?? "(never — no incremental write completed)"
        let archiveStatus = summary.isArchived
            ? "✓ Already folded into a finalized HRVSession — recovery complete."
            : "⚠ Not yet folded into a session. Backup file is intact on disk; SessionRecoveryService should pick it up on next dashboard open."
        return """
        Estimated time of termination: \(lastBackupStr)
          (= last successful incremental backup write before the process was killed)
        Recording duration before kill: \(elapsedDescription(from: sessionStart, to: summary.lastBackupTime))
        Beats claimed in header:        \(summary.beatCount)
        Beats written to backup file:   \(summary.backedUpCount.map { "\($0)" } ?? "(legacy single-file format)")
        Backup file size on disk:       \(byteDescription(summary.pointsFileSize))
        Archive status:                 \(archiveStatus)
        """
    }

    /// Shown when the session never made it into the backup index at all.
    private static let noBackupIndexExplanation = """
    No RawRRBackup index entry found for this session ID.
    Possible causes:
      • Recording was killed before the first incremental backup tick (typically <2 s).
      • The App Group container is unreachable / not configured on this build.
      • The backup index was wiped between the crash and this launch.
    User-visible impact: recording data is likely lost. Check
      Settings → Diagnostics → Archive Diagnostics for orphaned files.
    """

    /// How long the recording actually ran, as h/m/s. A backup timestamp that
    /// precedes the session start means the clock moved, not that time ran
    /// backwards, so say so rather than printing a negative duration.
    private static func elapsedDescription(from sessionStart: Date, to lastBackup: Date?) -> String {
        guard let lastBackup else { return "(unknown)" }
        let elapsed = lastBackup.timeIntervalSince(sessionStart)
        guard elapsed >= 0 else { return "(negative — clock skew?)" }
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        let seconds = Int(elapsed) % 60
        if hours > 0 { return "\(hours)h \(minutes)m \(seconds)s" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    private static func byteDescription(_ bytes: Int64?) -> String {
        guard let bytes else { return "(file missing or unreadable)" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// Shared header for all crash/termination reports
    private func formatLogHeader(title: String, timestamp: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        return """
        ================================================================================
        \(title)
        ================================================================================

        \(title == "EMUQU CRASH LOG" ? "Timestamp" : "Detected"): \(dateFormatter.string(from: timestamp))

        Device: \(DeviceInfo.model) (\(DeviceInfo.systemName))
        iOS Version: \(DeviceInfo.systemVersion)
        App Version: \(appVersion) (\(buildNumber))
        """
    }

    private func promoteCurrentCrashLog() {
        let fm = FileManager.default
        // If there's a crash log from last run, move it to previous
        guard fm.fileExists(atPath: crashLogURL.path) else { return }
        do {
            if fm.fileExists(atPath: previousCrashURL.path) {
                try fm.removeItem(at: previousCrashURL)
            }
            try fm.moveItem(at: crashLogURL, to: previousCrashURL)
        } catch {
            debugLog("[CrashLogManager] Failed to promote crash log: \(error)")
        }
    }

    /// Install the fatal-signal handlers.
    ///
    /// The handler itself is in C (`CrashSignalHandler.c`) and is deliberately
    /// minimal. A Swift closure that builds interpolated strings, walks
    /// `Thread.callStackSymbols`, runs the PHI scrubber's regexes over every
    /// line, and writes the result with `String.write(to:)` allocates at every
    /// step. A signal handler runs on the crashing thread, and the
    /// commonest reason for SIGSEGV or SIGABRT is heap corruption, which means the
    /// thread is frequently already inside malloc holding its lock. Allocating
    /// there does not fail; it deadlocks. The app then stops without dying, writes
    /// no log at all, and sits until the watchdog kills it — the one outcome worse
    /// than having no handler.
    ///
    /// The C handler calls only open/write/close, `backtrace`, and `raise`, and
    /// emits raw return addresses; symbolication is an offline job and the file it
    /// writes explains how. The report is terse and it actually arrives.
    ///
    /// `NSSetUncaughtExceptionHandler` above keeps the full, PHI-scrubbed report:
    /// it runs during ordinary Objective-C exception unwinding, not in signal
    /// context, so allocation there is legitimate.
    private func installSignalHandlers() {
        let installed = crashLogURL.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return emuqu_install_crash_signal_handlers(path)
        }
        if !installed {
            // NSLog, not debugLog: this is startup and the failure is worth
            // seeing in Console even in Release.
            NSLog("[CrashLogManager] failed to install signal handlers")
        }
    }

    private func writeCrashLog(type: String, name: String, reason: String, stackTrace: String) {
        persistCrashLog([
            crashInfoBlock(type: type, name: name, reason: reason),
            Self.stackTraceBlock(stackTrace)
        ].joined(separator: "\n\n"))
    }

    private func crashInfoBlock(type: String, name: String, reason: String) -> String {
        let header = formatLogHeader(title: "EMUQU CRASH LOG", timestamp: Date())
        return """
        \(header)

        --------------------------------------------------------------------------------
        CRASH INFO
        --------------------------------------------------------------------------------

        Type: \(type)
        Name: \(name)
        Reason: \(reason)
        """
    }

    private static func stackTraceBlock(_ stackTrace: String) -> String {
        """
        --------------------------------------------------------------------------------
        STACK TRACE
        --------------------------------------------------------------------------------

        \(stackTrace)

        ================================================================================
        END OF CRASH LOG
        ================================================================================
        """
    }

    /// Scrub PHI at write time so the at-rest file (in the shared App Group
    /// container, reachable by the widget/watch extension) is already
    /// redacted — an assert/precondition `reason` can interpolate health
    /// values. The export-time scrub in `exportCrashLog()` then becomes
    /// belt-and-suspenders. Line-wise to match `scrubPHI`'s contract.
    ///
    /// The write is synchronous — we're crashing, so async won't complete.
    ///
    /// NSLog rather than `attempt`/`debugLog` on the failure path: this runs
    /// inside a signal/exception handler where the process is already going
    /// down, and debugLog allocates, formats a Date, and dispatches to two
    /// queues that may never drain. NSLog is the most that is safe here, and
    /// a lost crash log with no trace is the one failure that would make the
    /// next crash report unexplainable.
    private func persistCrashLog(_ content: String) {
        let scrubbed = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { DebugLogger.scrubPHI(String($0)) }
            .joined(separator: "\n")
        do {
            try scrubbed.write(to: crashLogURL, atomically: false, encoding: .utf8)
        } catch {
            NSLog("[CrashLogManager] could not persist crash log: %@", error.localizedDescription)
        }
    }
}
