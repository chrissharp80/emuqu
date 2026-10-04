import Foundation
import os
import UIKit

/// Debug logger with configurable disk persistence.
///
/// In **Debug** builds disk logging is always on. In **Release/TestFlight** builds
/// disk logging is **off by default** and can be enabled by the user via
/// Settings → Troubleshooting → "Persistent Logging". When off, entries are kept
/// only in a bounded in-memory ring buffer (`maxMemoryEntries`) for the error catalog
/// and export UI.
///
/// When disk persistence is enabled, logs are append-only to a file in the App
/// Group container, rotated on launch if the file exceeds `maxFileSize`.
@Observable
@MainActor
final class DebugLogger {
    nonisolated static let shared = DebugLogger()

    nonisolated private static let maxFileSize = 2 * 1024 * 1024 // 2 MB — ~7 days of normal logging
    nonisolated private static let maxMemoryEntries = 5000 // In-memory cap for export UI
    nonisolated private static let flushInterval: TimeInterval = 5 // Seconds between disk flushes
    @ObservationIgnored private let queue: DispatchQueue

    /// Whether log entries are written to disk. Always true in DEBUG builds.
    /// In Release builds, defaults to false; user can opt in via Settings.
    var persistentLoggingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(persistentLoggingEnabled, forKey: UserDefaultsKeys.persistentLoggingEnabled)
            let enabled = persistentLoggingEnabled
            persistentBox.withLock { $0 = enabled }
        }
    }

    /// Lock-backed mirror of `persistentLoggingEnabled` for the flush path,
    /// which runs on `queue`.
    @ObservationIgnored private let persistentBox: OSAllocatedUnfairLock<Bool>

    private(set) var entries: [LogEntry] = []
    private(set) var errorCatalog: [LogEntry] = []

    nonisolated static let significantLogPosted = Notification.Name("DebugLogger.SignificantLog")

    /// Log severity levels — only `.warning` and `.error` appear in the
    /// user-facing "Recent Problems" section of Troubleshooting.
    enum LogLevel: Int, Comparable, Sendable {
        case debug = 0
        case info = 1
        case warning = 2
        case error = 3

        static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct LogEntry: Identifiable, Sendable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let category: String
        let level: LogLevel

        var formatted: String {
            "[\(DebugLogger.lineDateStyle.format(timestamp))] [\(category)] \(message)"
        }
    }

    /// Shared formatter — creating DateFormatter on every log entry is expensive
    /// `yyyy-MM-dd HH:mm:ss.SSS` in local time; a value type, so it is safe
    /// to use from any isolation.
    nonisolated static let lineDateStyle = Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(3))",
        timeZone: .current,
        calendar: .current
    )

    // Disk persistence
    @ObservationIgnored private let pendingLines = OSAllocatedUnfairLock<[String]>(initialState: [])
    /// Entries logged since the last main-actor hop, recorded together.
    @ObservationIgnored private let pendingEntries = OSAllocatedUnfairLock<[LogEntry]>(initialState: [])
    @ObservationIgnored private var flushTimer: Timer?
    private let logFileURL: URL

    nonisolated private init() {
        queue = DispatchQueue(label: "com.hrv.debuglogger", qos: .utility)

        // Disk persistence: always on in DEBUG, opt-in in Release
        #if DEBUG
            let enabled = true
        #else
            let enabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.persistentLoggingEnabled)
        #endif
        _persistentLoggingEnabled = enabled
        persistentBox = OSAllocatedUnfairLock(initialState: enabled)

        logFileURL = Self.resolveLogFileURL()
        Self.relaxFileProtection(at: logFileURL)
        if enabled { deferDiskLoad() }
        Task { @MainActor in self.startFlushTimer() }
        observeAppLifecycle()
    }

    /// Resolve the log file path once, preferring the shared app-group container
    /// so extensions write to the same file.
    nonisolated private static func resolveLogFileURL() -> URL {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier
        ) {
            return container.appendingPathComponent("debug_log.txt")
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("debug_log.txt")
    }

    /// Not `.complete`. The log file MUST be writable while the
    /// device is locked (overnight HRV recording, screen-locked workout) —
    /// otherwise every log write fails with "Operation not permitted" while the
    /// user sleeps, and any diagnostic captures from that period are empty. Use
    /// `.completeUntilFirstUserAuthentication` so the file is still encrypted at
    /// rest but stays accessible after first unlock.
    nonisolated private static func relaxFileProtection(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            // NSLog, never `attempt`/`debugLog`: this runs inside
            // `DebugLogger.shared`'s own initialiser, and logging the failure
            // through the logger would re-enter that initialiser and hang the
            // launch.
            NSLog("[DebugLogger] relaxing file protection failed: %@", error.localizedDescription)
        }
    }

    /// Not sync on the calling thread (DebugLogger is initialised
    /// eagerly at app launch). For a busy 7-day log file (~5 MB+), the combined
    /// read + line-split + write is a 1–3 s main-thread hang at every cold start
    /// — and the same hang re-triggers if anyone touches the shared logger
    /// before the file exists.
    ///
    /// Both calls are idempotent and self-contained: rotate checks file size and
    /// trims; load reads the file into the in-memory ring buffer used by the
    /// export UI. Deferring both to the logger's serial queue is safe because the
    /// flush timer and write path don't depend on either having completed (writes
    /// append; reads only matter for the export sheet, which already runs async).
    /// The in-memory entries appearing "after a moment" on first
    /// Settings → Troubleshooting open is invisible to the user.
    nonisolated private func deferDiskLoad() {
        queue.async { [weak self] in
            self?.rotateIfNeeded()
            self?.loadFromDisk()
        }
    }

    /// Periodic flush timer (only flushes when `persistentLoggingEnabled`).
    private func startFlushTimer() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
            self?.flushToDisk()
        }
    }

    /// Flush on background / termination so we never lose foreground logs.
    nonisolated private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification, object: nil
        )
    }

    @objc private func appWillResignActive() {
        flushToDisk()
    }

    @objc private func appWillTerminate() {
        flushToDiskSync()
    }

    // MARK: - Logging

    nonisolated func log(_ message: String, category: String = "App", level: LogLevel = .info) {
        let entry = LogEntry(timestamp: Date(), message: message, category: category, level: level)
        let line = entry.formatted
        pendingLines.withLock { $0.append(line) }
        let startsBatch = pendingEntries.withLock { pending -> Bool in
            pending.append(entry)
            return pending.count == 1
        }
        guard startsBatch else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.recordPendingEntries() }
        }
    }

    /// Main-actor half of `log`: appends everything logged since the last
    /// hop to the in-memory ring buffer, posts the significant-event
    /// notification, and files genuine problems into the user-facing "Recent
    /// Problems" catalog.
    ///
    /// One hop per burst, not one per line. A strap connect or a sync logs
    /// hundreds of lines in a few seconds, and each hop used to mutate the
    /// observed `entries` array and rescan all of it for week-old lines —
    /// main-thread work landing exactly when the Polar SDK's readiness check,
    /// which runs on the main run loop against a ten-second deadline, needs
    /// the thread.
    private func recordPendingEntries() {
        let batch = pendingEntries.withLock { pending -> [LogEntry] in
            defer { pending.removeAll() }
            return pending
        }
        guard !batch.isEmpty else { return }
        appendToRingBuffer(batch)
        if batch.contains(where: { Self.isSignificant(message: $0.message, level: $0.level) }) {
            NotificationCenter.default.post(name: DebugLogger.significantLogPosted, object: nil)
        }
        let problems = batch.filter { Self.shouldCatalog(message: $0.message, level: $0.level) }
        guard !problems.isEmpty else { return }
        errorCatalog.append(contentsOf: problems)
        if errorCatalog.count > 1000 {
            errorCatalog.removeFirst(errorCatalog.count - 1000)
        }
    }

    /// Keeps a week of entries, capped at `maxMemoryEntries`. The age scan
    /// runs only when the oldest entry has actually aged out.
    private func appendToRingBuffer(_ batch: [LogEntry]) {
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        if let oldest = entries.first, oldest.timestamp < sevenDaysAgo {
            entries.removeAll { $0.timestamp < sevenDaysAgo }
        }
        entries.append(contentsOf: batch)
        if entries.count > Self.maxMemoryEntries {
            entries.removeFirst(entries.count - Self.maxMemoryEntries)
        }
    }

    /// Worth waking the Diagnostics badge for.
    nonisolated private static func isSignificant(message: String, level: LogLevel) -> Bool {
        level >= .warning ||
            message.contains("❌") || message.contains("✅") ||
            message.contains("⚠️") || message.contains("disconnected")
    }

    /// Error catalog (user-facing "Recent Problems") — only genuine issues.
    /// Catches: explicit .warning/.error level, emoji markers developers
    /// already use for real failures, and all-caps ERROR/WARNING labels.
    nonisolated private static func shouldCatalog(message: String, level: LogLevel) -> Bool {
        if level >= .warning { return true }
        return message.contains("❌") || message.contains("⚠️") ||
            message.contains("ERROR") || message.contains("WARNING")
    }

    // MARK: - Disk I/O

    /// Flush pending lines to disk (async, off main thread)
    nonisolated private func flushToDisk() {
        queue.async { [weak self] in
            self?.flushPendingLines()
        }
    }

    /// Flush synchronously — used during termination and export. Must not be
    /// called on `queue` itself, which would deadlock.
    nonisolated private func flushToDiskSync() {
        queue.sync { [weak self] in
            self?.flushPendingLines()
        }
    }

    /// Must be called on `queue`
    ///
    /// Scrub PHI before persisting. The
    /// in-memory ring buffer is debug-only and per-process, but once a
    /// line lands on disk the user can export it (Settings →
    /// Troubleshooting → Export logs) and the file leaves the device.
    /// We must not bake HRV / heart rate / sleep / location values
    /// into a shareable artefact. The scrubber preserves the metric
    /// *name* and the unit so the line stays diagnostic ("RMSSD: ms"
    /// is still useful triage), but replaces the *value* with
    /// `<redacted>` so the export carries no PHI.
    nonisolated private func flushPendingLines() {
        let lines = pendingLines.withLock { lines -> [String] in
            defer { lines.removeAll() }
            return lines
        }
        guard !lines.isEmpty, persistentBox.withLock({ $0 }) else { return }
        let batch = lines.map { Self.scrubPHI($0) }.joined(separator: "\n") + "\n"
        guard let data = batch.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            append(data)
        } else {
            createLogFile(with: data)
        }
    }

    /// Throwing calls: the legacy `write(_:)` raises an uncatchable exception
    /// on a full disk. NSLog on failure, for the reason `createLogFile` gives.
    nonisolated private func append(_ data: Data) {
        guard let handle = try? FileHandle(forWritingTo: logFileURL) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            NSLog("[DebugLog] append failed: \(error)")
            do { try handle.close() } catch { NSLog("[DebugLog] close failed: \(error)") }
        }
    }

    /// NSLog, not `attempt`/`debugLog`: this IS the logger, and routing a flush
    /// failure back through it would append to the buffer whose flush just
    /// failed. NSLog goes straight to the system log and cannot re-enter.
    ///
    /// Same rule as the init path: a `.complete` protection class makes the
    /// log file unwritable while the device is locked.
    /// `.completeUntilFirstUserAuthentication` lets background
    /// recording sessions keep logging.
    nonisolated private func createLogFile(with data: Data) {
        do {
            try data.write(to: logFileURL, options: .atomic)
        } catch {
            NSLog("[DebugLogger] flush to disk failed: %@", error.localizedDescription)
        }
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: logFileURL.path
            )
        } catch {
            NSLog("[DebugLogger] setting log file protection failed: %@", error.localizedDescription)
        }
    }

    // MARK: - PHI scrub

    /// Replace numeric values that look like HRV / HR / sleep / location
    /// readings with `<redacted>` while keeping the metric name + unit
    /// intact. Conservative: only matches well-formed `<key>: <number>
    /// <unit>` patterns common in our log lines, plus bare-number RMSSD
    /// / SDNN sweeps. False positives would degrade triage usefulness;
    /// false negatives leak PHI. The current pattern set was chosen by
    /// grep'ing 100% of debugLog call sites for value emissions.
    nonisolated static func scrubPHI(_ line: String) -> String {
        var out = replacing(line, "(?i)(\\b\(metricPattern)\\b\(separatorPattern))[-+]?\\d+(?:\\.\\d+)?\(unitPattern)", with: "$1<redacted>")
        out = redactValueChains(in: out)
        // Bare lat/lon coordinate pairs (lat=37.123 lon=-122.456 etc.)
        return replacing(
            out,
            #"(?i)(\b(?:lat|lon|latitude|longitude|coord(?:inate)?)\s*[:=]?\s*)[-+]?\d+\.\d+"#,
            with: "$1<redacted>"
        )
    }

    /// Health-metric names. `baseline` and `readiness` are included because
    /// they name a health value in our logs.
    nonisolated private static let metricPattern = #"(?:RMSSD|SDNN|pNN50|HRV|RHR|resting\s*HR|heart\s*rate|HR|alpha1|DFA|SpO2|respiratory\s*rate|respiration|temperature|wrist\s*temp|breath|composite|recovery\s*score|readiness|sleep\s*score|baseline|TSB|ATL|CTL|hrTSS|TRIMP)"#

    nonisolated private static let unitPattern = #"(?:\s*(?:ms|bpm|BPM|%|°[CF]|min|h|points?))?"#

    /// The separator between the metric name and the number is
    /// DELIMITER-AGNOSTIC: `:`, `=`, `->`, `→`, `<`, `>`, or plain whitespace
    /// all count. Matching only `:`/`=` would let the dominant prose
    /// form ("RMSSD 42ms < baseline 55ms", "RMSSD 42.0→51.3") leak raw HRV
    /// into the user-exportable debug_log.txt.
    nonisolated private static let separatorPattern = #"\s*(?:[:=]|->|→|<|>)?\s*"#

    /// Value chains: a further number joined to an already-redacted value by
    /// an arrow / comparator (e.g. "RMSSD 42.0→51.3" or "prior 55 → new 61").
    /// Loop until stable so 3+ link chains are fully covered.
    nonisolated private static func redactValueChains(in line: String) -> String {
        let chain = "(<redacted>\\s*(?:->|→|<|>|to|vs\\.?|,|/)\\s*)[-+]?\\d+(?:\\.\\d+)?\(unitPattern)"
        var out = line
        var previous = ""
        var guardCount = 0
        while previous != out && guardCount < 8 {
            previous = out
            out = replacing(out, "(?i)\(chain)", with: "$1<redacted>")
            guardCount += 1
        }
        return out
    }

    /// Compiled redaction patterns, cached by source string.
    ///
    /// Two problems with compiling on every call:
    ///
    ///   1. **Silent failure.** A `try?` returning nil makes `replacing` hand back
    ///      the text unmodified, so a malformed pattern turns redaction OFF
    ///      with no signal at all. In a health app whose debug log is
    ///      user-exportable, that is the worst possible way for this to break —
    ///      it fails open. `RedactionPatternTests` compiles every pattern
    ///      this file uses and fails the build if one is malformed, and the
    ///      miss is logged at runtime instead of swallowed.
    ///   2. **Cost.** `redactValueChains` loops up to 8 times per line, and
    ///      every iteration would rebuild an `NSRegularExpression` from the same
    ///      string. Redaction runs on every log line.
    nonisolated private static let compiledPatterns =
        OSAllocatedUnfairLock<[String: NSRegularExpression]>(initialState: [:])

    nonisolated static func compiledPattern(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression? {
        let key = "\(options.rawValue)|\(pattern)"
        if let cached = compiledPatterns.withLock({ $0[key] }) { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            // Deliberately not silent: redaction failing open is a privacy bug.
            NSLog("[DebugLog] REDACTION PATTERN FAILED TO COMPILE — redaction is degraded: %@", pattern)
            return nil
        }
        compiledPatterns.withLock { $0[key] = regex }
        return regex
    }

    nonisolated private static func replacing(_ text: String, _ pattern: String, with template: String) -> String {
        guard let regex = compiledPattern(pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    /// If the log file exceeds `maxFileSize`, keep only the second half (most recent)
    nonisolated private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? Int, size > Self.maxFileSize else { return }

        guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n")
        let keepFrom = lines.count / 2
        let trimmed = lines[keepFrom...].joined(separator: "\n")
        do {
            try trimmed.write(to: logFileURL, atomically: true, encoding: .utf8)
        } catch {
            // Same reentrancy reasoning as the flush path above. A failed trim
            // means the log file keeps growing past `maxFileSize`, which is
            // worth knowing about before it fills the container.
            NSLog("[DebugLogger] log rotation failed, file will keep growing: %@", error.localizedDescription)
        }
    }

    /// Load existing log entries from disk into memory (called once at init)
    nonisolated private func loadFromDisk() {
        guard let content = try? String(contentsOf: logFileURL, encoding: .utf8),
              !content.isEmpty else { return }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        var parsed = lines.compactMap { Self.parseLogLine($0, notBefore: sevenDaysAgo) }
        // Cap to maxMemoryEntries (keep most recent)
        if parsed.count > Self.maxMemoryEntries {
            parsed = Array(parsed.suffix(Self.maxMemoryEntries))
        }
        let loaded = parsed
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.prependLoaded(loaded) }
        }
    }

    /// Put the lines read from disk in front of the ones logged since launch,
    /// instead of replacing them. A loaded line at or after the first live
    /// entry was already flushed from this run, so it is dropped as a duplicate.
    private func prependLoaded(_ loaded: [LogEntry]) {
        let older = entries.first.map { first in loaded.filter { $0.timestamp < first.timestamp } } ?? loaded
        entries = Array((older + entries).suffix(Self.maxMemoryEntries))
    }

    /// Parse one persisted line back into a LogEntry, or nil when it doesn't
    /// have the shape we wrote or is older than `notBefore`.
    /// Format: [YYYY-MM-DD HH:mm:ss.SSS] [Category] [line] message
    /// A line in another format (an older log, a foreign line) parses as nil.
    nonisolated private static func parseLineDate(_ text: String) -> Date? {
        do { return try lineDateStyle.parseStrategy.parse(text) } catch { return nil }
    }

    nonisolated private static func parseLogLine(_ line: String, notBefore: Date) -> LogEntry? {
        // Extract timestamp: first [...] block
        guard line.hasPrefix("["),
              let closeBracket = line.firstIndex(of: "]") else { return nil }
        let dateStr = String(line[line.index(after: line.startIndex) ..< closeBracket])
        guard let date = parseLineDate(dateStr), date > notBefore else { return nil }
        // Extract category: second [...] block
        let afterFirst = line[line.index(after: closeBracket)...]
        guard let openCat = afterFirst.firstIndex(of: "["),
              let closeCat = afterFirst[afterFirst.index(after: openCat)...].firstIndex(of: "]")
        else { return nil }
        let category = String(afterFirst[afterFirst.index(after: openCat) ..< closeCat])
        // Rest is the message
        let message = String(afterFirst[afterFirst.index(after: closeCat)...])
            .trimmingCharacters(in: .whitespaces)
        return LogEntry(timestamp: date, message: message, category: category, level: .info)
    }

    // MARK: - Export & Clear

    /// Everything held, on disk and in memory: the entries, the lines and
    /// entries waiting for the next flush, and the error catalog. Left
    /// behind after "Delete All My Data", the next flush wrote the pending
    /// lines into a new log file and Recent Problems kept listing pre-wipe
    /// messages.
    func clear() {
        entries.removeAll()
        errorCatalog.removeAll()
        pendingLines.withLock { $0.removeAll() }
        pendingEntries.withLock { $0.removeAll() }
        queue.async { [logFileURL] in
            do {
                try FileManager.default.removeItem(at: logFileURL)
            } catch {
                NSLog("[DebugLogger] removing the log file failed: %@", error.localizedDescription)
            }
        }
    }

    func clearErrorCatalog() {
        errorCatalog.removeAll()
    }

    /// Every caller runs off `queue` (a detached export task), so the
    /// synchronous flush cannot deadlock. Without it the export read the file
    /// before the timer's next flush and left out up to five seconds of the
    /// newest lines — the ones describing whatever the user just saw.
    nonisolated func exportLogs() -> String {
        flushToDiskSync()
        // Read directly from disk for completeness — memory may be a subset
        let diskContent = (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""

        // Count newlines instead of `components(separatedBy:)`
        // which builds an array of every line (1MB log → 14k+ String
        // allocations, multi-second hang on main thread). A single pass
        // count of "\n" chars is O(n) without allocations.
        let entryCount = diskContent.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        return Self.exportHeader(entryCount: entryCount) + diskContent
    }

    nonisolated private static func exportHeader(entryCount: Int) -> String {
        """
        Emuqu Debug Log (Last 7 Days)
        Exported: \(Date())
        Device: \(DeviceInfo.model)
        iOS: \(DeviceInfo.systemVersion)
        App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
        Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
        Entries: \(entryCount)
        ========================================

        """
    }

    func exportErrorCatalog() -> String {
        let header = """
        Emuqu Error Catalog (Permanent)
        Exported: \(Date())
        Device: \(DeviceInfo.model)
        iOS: \(DeviceInfo.systemVersion)
        Total Errors Recorded: \(errorCatalog.count)
        ========================================

        """
        // Scrub PHI before this leaves the device (share sheet). The in-memory
        // catalog holds raw `.warning`/`.error` lines — several embed health
        // values (recovery score, HRV sample presence, session UUIDs) — so it
        // must go through the same redaction as the main log export (the one
        // the disk-flush path applies).
        return header + errorCatalog.map { Self.scrubPHI($0.formatted) }.joined(separator: "\n")
    }

    /// Share the log from a TEMP subdirectory, NEVER from
    /// Documents. `.noFileProtection` on a Documents file does NOT fix
    /// the share-sheet stall, because the real trigger is
    /// the LOCATION, not the protection. Documents is an iCloud-eligible,
    /// backed-up container, so the share sheet (sharingd) probes every
    /// file there for a CloudKit share mode and then fails to open it
    /// across the sandbox — the exact console spam the user reported:
    ///   Failed to request default share mode for fileURL:...Documents/...
    ///   Only support loading options for CKShare and SWY types.
    ///   NSCocoaErrorDomain Code=256 "The file couldn't be opened."
    /// sharingd retry-loops ~500 ms per attempt before the sheet finally
    /// works — "all these errors before they finally are ready." The
    /// temp dir is not iCloud-backed, so none of that probing happens
    /// and the file opens on the FIRST try. (This is also why the
    /// RR/CSV/all-data exports, which already use tmp, never hit this —
    /// the log export was the lone Documents outlier.)
    ///
    /// NOTE: the LaunchServices lines (`-10814`, "Failed to locate
    /// container app bundle record", "canmaplsdatabase domain 8") are
    /// iOS-internal share-sheet noise unrelated to our file and are not
    /// something app code can suppress; the openability failure above is
    /// the part that actually blocked the share, and that's what this fixes.
    nonisolated func exportToFile() -> URL? {
        let fileName = "hrv_debug_log_\(Int(Date().timeIntervalSince1970)).txt"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-export", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("[DebugLogger] creating the export directory failed: %@", error.localizedDescription)
        }
        let fileURL = dir.appendingPathComponent(fileName)
        guard let data = exportLogs().data(using: .utf8) else { return nil }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return nil
        }
        Self.dropFileProtection(at: fileURL)
        return fileURL
    }

    /// Belt-and-suspenders on top of the location fix: set protection
    /// EXPLICITLY rather than trusting a write-option (which didn't
    /// take before). Scrubbed diagnostic text carries no health values — the
    /// metric values are redacted; session IDs are random UUIDs and are
    /// kept, since they tie lines to a session — so `.none` is safe and
    /// guarantees sharingd can open it regardless of lock state.
    nonisolated private static func dropFileProtection(at fileURL: URL) {
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.none],
                ofItemAtPath: fileURL.path
            )
        } catch {
            NSLog("[DebugLogger] dropping export file protection failed: %@", error.localizedDescription)
        }
    }

    /// Async export. The sync version runs all work on
    /// the calling thread (typically main): a 14k-line log is a
    /// multi-second hang. This version reads the disk file, builds
    /// the header, and writes the temp file all on a background
    /// queue and returns the URL on main when done. Drop-in
    /// replacement for `exportToFile()` in any await-friendly
    /// caller.
    nonisolated func exportToFileAsync() async -> URL? {
        await Task.detached(priority: .userInitiated) {
            AppDependencies.current.app.debugLogger.exportToFile()
        }.value
    }
}

/// Logging function — always buffers in memory; writes to disk only when
/// `persistentLoggingEnabled` is true (always in DEBUG, opt-in in Release).
/// Console print is DEBUG-only.
///
/// Use `level:` to control whether the message appears in the user-facing
/// "Recent Problems" section of Troubleshooting:
///   - `.info` (default) — internal diagnostics, never shown as a "problem"
///   - `.warning` — notable issues worth surfacing to the user
///   - `.error` — failures that need attention
@inline(__always)
func debugLog(
    _ message: @autoclosure () -> String,
    level: DebugLogger.LogLevel = .info,
    file: String = #file,
    line: Int = #line
) {
    let filename = (file as NSString).lastPathComponent
    let category = filename.replacingOccurrences(of: ".swift", with: "")
    let msg = correlationTagged(message())
    #if DEBUG
        print("[\(filename):\(line)] \(msg)")
    #endif
    // Always buffer in DebugLogger (memory). Disk flush only when enabled.
    AppDependencies.current.app.debugLogger.log("[\(line)] \(msg)", category: category, level: level)
}

/// Correlation tag, applied here rather than at the ~1,400 call sites.
/// `LogCorrelation.current` is nil outside a flow — app lifecycle and UI
/// logging — and those lines are left unprefixed rather than carrying a
/// "none" marker that would be noise on the majority of the stream.
@inline(__always)
func correlationTagged(_ raw: String) -> String {
    guard let correlation = LogCorrelation.current else { return raw }
    return "[\(correlation)] \(raw)"
}

/// Names the not-our-fault culprit for `debugLogExternal`. These are
/// conditions the app cannot control — external hardware, the OS, the radio,
/// or a remote service. The `rawValue` is what prints in the log tag.
enum ExternalCause: String {
    case strap          // Polar H10 / Verity Sense hardware + firmware
    case os = "iOS"     // HealthKit lag, AVAudioSession, LaunchServices, share sheet
    case bluetooth      // BLE radio resets / power cycles
    case iCloud         // CloudKit service / schema / account state
    case network        // reachability / remote endpoints
}

/// Log a condition that is **not the app's fault** — external hardware, the
/// OS, Bluetooth, or a remote service. Recorded for diagnostics but framed as
/// an external event, NOT an app error: it logs at `.info` and carries an
/// `[external · <cause>]` tag, so it never lands in the user-facing "Recent
/// Problems" catalog and never reads as something we broke. Do NOT put words
/// like "failed"/"error" in `message` — describe what the external thing did
/// and what we did about it (e.g. "H10 didn't finalize in time — used the live
/// stream instead"). If the app itself is at fault, use `debugLog(…, level:
/// .warning/.error)` instead.
@inline(__always)
func debugLogExternal(
    _ message: @autoclosure () -> String,
    cause: ExternalCause,
    file: String = #file,
    line: Int = #line
) {
    debugLog("[external · \(cause.rawValue)] \(message())", level: .info, file: file, line: line)
}
