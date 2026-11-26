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
    /// Lock-backed copy of `entries` for `exportLogs`, which runs off the main
    /// actor. With Persistent Logging off nothing reaches disk, so the export
    /// is built from this copy. Every change to `entries` goes through
    /// `mutateRingBuffer`, which applies it to both.
    @ObservationIgnored private let exportBuffer = OSAllocatedUnfairLock<[LogEntry]>(initialState: [])
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

    /// A logger holding `entries` in memory and nothing else: no log file is
    /// read or written, no flush timer runs, no app-lifecycle observer is
    /// added. The error catalog is the entries the app would catalog. For a
    /// preview or test that shows the log screens fixed lines in place of the
    /// process's own log.
    nonisolated init(inMemory entries: [LogEntry]) {
        queue = DispatchQueue(label: "com.hrv.debuglogger.inmemory", qos: .utility)
        _persistentLoggingEnabled = false
        persistentBox = OSAllocatedUnfairLock(initialState: false)
        logFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("debug_log-\(UUID().uuidString).txt")
        _entries = entries
        _errorCatalog = entries.filter { Self.shouldCatalog(message: $0.message, level: $0.level) }
    }

    /// Resolve the log file path once, preferring the shared app-group container
    /// so extensions write to the same file, then Documents, then the temporary
    /// directory.
    nonisolated private static func resolveLogFileURL() -> URL {
        AppConfig.sharedContainerURL().appendingPathComponent("debug_log.txt")
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
    /// hundreds of lines in a few seconds, and a hop per line would mutate the
    /// observed `entries` array and rescan all of it for week-old lines each
    /// time, main-thread work landing exactly when the Polar SDK's readiness check,
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
        let cap = Self.maxMemoryEntries
        mutateRingBuffer { buffer in
            Self.append(batch, to: &buffer, droppingOlderThan: sevenDaysAgo, cap: cap)
        }
    }

    /// One ring-buffer step: drop entries older than `cutoff` (only scanned
    /// when the oldest has aged out), append `batch`, keep the newest `cap`.
    nonisolated private static func append(
        _ batch: [LogEntry], to buffer: inout [LogEntry], droppingOlderThan cutoff: Date, cap: Int
    ) {
        if let oldest = buffer.first, oldest.timestamp < cutoff {
            buffer.removeAll { $0.timestamp < cutoff }
        }
        buffer.append(contentsOf: batch)
        if buffer.count > cap {
            buffer.removeFirst(buffer.count - cap)
        }
    }

    /// Applies one change to `entries` and to its lock-backed export copy, so
    /// the two always hold the same lines.
    private func mutateRingBuffer(_ change: @Sendable (inout [LogEntry]) -> Void) {
        change(&entries)
        exportBuffer.withLock { change(&$0) }
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
    /// into a shareable artefact. The scrubber keeps the metric *name* so
    /// the line stays diagnostic ("RMSSD: <redacted>" is still useful
    /// triage), and replaces the *value* and any unit after it with
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
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: logFileURL)
        } catch {
            NSLog("[DebugLog] opening the log file failed, batch dropped: %@", error.localizedDescription)
            return
        }
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

    /// Replace the health values in a log line by `<redacted>`, keeping the
    /// names and separators so the line still reads.
    ///
    /// Default-deny for named values: every `key=<number>` or
    /// `key: <number>` is redacted unless the key's last word is on
    /// `loggableKeyWords`, a short allow-list of counts and identifiers
    /// (`beatCount=`, `attempt=`, `schemaVersion=`). A key nobody listed
    /// (`nadir=`, `perceivedReadiness=`, `restingHR=`, `total=` sleep
    /// minutes) is redacted without anyone having to name it. Prose forms
    /// with no `=`/`:` ("RMSSD 42ms < baseline 55ms") are caught by metric
    /// name (`metricValuePattern`), and any number followed by `bpm` by its
    /// unit. Numbers chained to a redacted one ("42.0→51.3", "[42, 51]")
    /// go with it, and coordinates last.
    nonisolated static func scrubPHI(_ line: String) -> String {
        var out = replacing(line, metricValuePattern, with: "$1<redacted>")
        out = redactUnlistedKeyValues(in: out)
        out = replacing(out, heartRateUnitPattern, with: "<redacted>$1")
        out = redactValueChains(in: out)
        // Bare lat/lon coordinate pairs (lat=37.123 lon=-122.456 etc.)
        return replacing(
            out,
            #"(?i)(\b(?:lat|lon|latitude|longitude|coord(?:inate)?)\s*[:=]?\s*)[-+]?\d+\.\d+"#,
            with: "$1<redacted>"
        )
    }

    /// Health-metric names. `baseline` and `readiness` are included because
    /// they name a health value in our logs. `\w*score` covers bare `score=`
    /// and camel-case names such as `frozenScore=` (recovery-score values).
    /// The names matter for prose ("nadir 48", "sleep 412 min", "RR 850ms");
    /// a named `key=value` is redacted by default (`keyValuePattern`).
    /// `metricPattern` joins them, in this order, into one alternation.
    nonisolated static let metricNames: [String] = [
        #"RMSSD"#, #"SDNN"#, #"pNN50"#, #"HRV"#, #"RHR"#, #"resting\s*HR"#, #"heart\s*rate"#, #"HR"#,
        #"alpha1"#, #"DFA"#, #"SpO2"#, #"respiratory\s*rate"#, #"respiration"#, #"temperature"#,
        #"wrist\s*temp"#, #"breath"#, #"composite"#, #"recovery\s*score"#, #"readiness"#, #"sleep\s*score"#,
        #"\w*score"#, #"baseline"#, #"TSB"#, #"ATL"#, #"CTL"#, #"hrTSS"#, #"TRIMP"#, #"RR"#, #"nadir"#,
        #"sleep"#, #"deep"#, #"REM"#, #"weight"#, #"VO2\s*max"#, #"FTP"#, #"LTHR"#, #"calories"#
    ]

    nonisolated private static let metricPattern = "(?:" + metricNames.joined(separator: "|") + ")"

    nonisolated private static let unitPattern = #"(?:\s*(?:ms|bpm|BPM|%|°[CF]|min|h|points?))?"#

    /// The separator between the metric name and the number is
    /// DELIMITER-AGNOSTIC: `:`, `=`, `->`, `→`, `<`, `>`, or plain whitespace
    /// all count. Matching only `:`/`=` would let the dominant prose
    /// form ("RMSSD 42ms < baseline 55ms", "RMSSD 42.0→51.3") leak raw HRV
    /// into the user-exportable debug_log.txt.
    nonisolated private static let separatorPattern = #"\s*(?:[:=]|->|→|<|>)?\s*"#

    /// A metric name, a separator and a number with an optional unit; the
    /// number is what `scrubPHI` replaces, group 1 is what it keeps.
    nonisolated static let metricValuePattern =
        "(?i)(\\b\(metricPattern)\\b\(separatorPattern))[-+]?\\d+(?:\\.\\d+)?\(unitPattern)"

    /// A number joined to an already-redacted value by an arrow, comparator,
    /// `to`, `vs`, comma, slash or range dash; `redactValueChains` replaces
    /// the number.
    nonisolated static let valueChainPattern =
        "(?i)(<redacted>\\s*(?:->|→|<|>|to|vs\\.?|,|/|-|–)\\s*)[-+]?\\d+(?:\\.\\d+)?\(unitPattern)"

    /// A named value: group 1 the key, group 2 the number with any unit
    /// letters glued to it. The key starts with a letter and follows no word
    /// character or dot; the number may sit after `Optional(` or `[`, and
    /// must not run on into more of a word, a decimal, or a UUID's next
    /// group (`12345678-ABCD-`), so an identifier is not cut in half.
    nonisolated static let keyValuePattern =
        #"(?<![\w.])([A-Za-z_][A-Za-z0-9_]*)\s*[:=]\s*(?:Optional\()?\[?([-+]?\d+(?:\.\d+)?[A-Za-z%°]*)(?![\w]|\.\d|-[0-9A-Fa-f]{4}-)"#

    /// Any number or range ("60-70") given in beats per minute, whatever
    /// names it: the numbers go, the unit (group 1) stays.
    nonisolated static let heartRateUnitPattern = #"(?<![\w.])[-+]?\d+(?:\.\d+)?(?:\s*[-–]\s*\d+(?:\.\d+)?)?(\s*(?:bpm|BPM))\b"#

    /// Key words whose numbers are counts, identifiers or timing, not a
    /// health value, matched against a key's last word, lower-cased
    /// (`lastKeyWord`). Every other named number is redacted.
    nonisolated static let loggableKeyWords: Set<String> = [
        "count", "counts", "n", "attempt", "attempts", "retry", "retries", "tries", "failures",
        "generation", "gen", "version", "versions", "schema", "code", "status", "build",
        "bytes", "kb", "mb", "size", "index", "idx", "indices", "page", "pages", "batch", "limit", "cap",
        "queue", "pending", "tick", "ticks", "depth", "latency", "timeout", "delay",
        "session", "sessions", "id", "ids", "file", "files", "entry", "entries", "records", "items", "rows",
        "segments", "chunks", "points", "samples", "beats", "fixes", "buffers", "frames", "channels",
        "devices", "recordings", "copies", "backups", "uploaded", "deleted", "pushed", "saved", "saves",
        "removed", "written", "rewritten", "fetched", "received", "dropped", "skipped", "merged",
        "restored", "reported", "streamed"
    ]

    /// The last word of a camelCase or snake_case key, lower-cased:
    /// `beatCount` → `count`, `rr_points` → `points`, `maxHR` → `hr`.
    nonisolated static func lastKeyWord(_ key: String) -> String {
        let tail = key.split(separator: "_").last.map(String.init) ?? key
        let start = tail.indices.last { index in
            tail[index].isUppercase && (index == tail.startIndex || !tail[tail.index(before: index)].isUppercase)
        }
        return String(tail[(start ?? tail.startIndex)...]).lowercased()
    }

    /// Redacts the number of every named value whose key is not loggable.
    /// A value in brackets is a list of readings and is redacted whatever
    /// its key. Matches are replaced from the last back, so the ranges of
    /// the earlier ones stay valid.
    nonisolated private static func redactUnlistedKeyValues(in line: String) -> String {
        guard let regex = compiledPattern(keyValuePattern) else { return line }
        let text = line as NSString
        let result = NSMutableString(string: line)
        let matches = regex.matches(in: line, options: [], range: NSRange(location: 0, length: text.length))
        for match in matches.reversed() {
            let key = text.substring(with: match.range(at: 1))
            let isList = text.substring(with: match.range).contains("[")
            guard isList || !loggableKeyWords.contains(lastKeyWord(key)) else { continue }
            result.replaceCharacters(in: match.range(at: 2), with: "<redacted>")
        }
        return result as String
    }

    /// Value chains: a further number joined to an already-redacted value by
    /// an arrow / comparator (e.g. "RMSSD 42.0→51.3" or "prior 55 → new 61").
    /// Loop until stable so 3+ link chains are fully covered.
    nonisolated private static func redactValueChains(in line: String) -> String {
        var out = line
        var previous = ""
        var guardCount = 0
        while previous != out && guardCount < 8 {
            previous = out
            out = replacing(out, valueChainPattern, with: "$1<redacted>")
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

    /// If the log file exceeds `maxFileSize`, keep only the second half (most recent).
    /// The atomic rewrite is a new file, so its protection class is set again.
    nonisolated private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? Int, size > Self.maxFileSize else { return }

        guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n")
        let keepFrom = lines.count / 2
        let trimmed = lines[keepFrom...].joined(separator: "\n")
        do {
            try trimmed.write(to: logFileURL, atomically: true, encoding: .utf8)
            Self.relaxFileProtection(at: logFileURL)
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
        let cap = Self.maxMemoryEntries
        mutateRingBuffer { buffer in buffer = Array((older + buffer).suffix(cap)) }
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
    /// behind after "Delete All My Data", the next flush would write the
    /// pending lines into a new log file and Recent Problems would keep
    /// listing pre-wipe messages.
    ///
    /// The file is removed on `queue`, after any flush already running, and
    /// the caller waits for it. True when no log file is left; a failure is
    /// reported through NSLog (logging it here would write to the file being
    /// removed).
    @discardableResult
    func clear() -> Bool {
        mutateRingBuffer { $0.removeAll() }
        errorCatalog.removeAll()
        pendingLines.withLock { $0.removeAll() }
        pendingEntries.withLock { $0.removeAll() }
        return queue.sync { [logFileURL] in Self.removeLogFile(at: logFileURL) }
    }

    nonisolated private static func removeLogFile(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            NSLog("[DebugLogger] removing the log file failed: %@", error.localizedDescription)
            return false
        }
    }

    func clearErrorCatalog() {
        errorCatalog.removeAll()
    }

    /// Every caller runs off `queue` (a detached export task), so the
    /// synchronous flush cannot deadlock. Without it the export read the file
    /// before the timer's next flush and left out up to five seconds of the
    /// newest lines — the ones describing whatever the user just saw.
    ///
    /// With Persistent Logging off nothing is written to disk, so the export
    /// comes from the in-memory ring buffer instead. A log file that exists
    /// but cannot be read also exports the in-memory buffer, and its header
    /// says the file could not be read, so a failed read never passes for a
    /// log with no entries.
    nonisolated func exportLogs() -> String {
        guard persistentBox.withLock({ $0 }) else {
            return exportMemoryLogs(source: "in-memory buffer, last 7 days (Persistent Logging is off)")
        }
        flushToDiskSync()
        // Read directly from disk for completeness — memory may be a subset
        let rawContent: String
        do {
            rawContent = try Self.readLogFile(at: logFileURL)
        } catch {
            NSLog("[DebugLogger] reading the log file for export failed: %@", error.localizedDescription)
            return exportMemoryLogs(source: Self.unreadableFileSource(error))
        }
        let diskContent = Self.scrubbedLines(rawContent)
        // Count newlines instead of `components(separatedBy:)`
        // which builds an array of every line (1MB log → 14k+ String
        // allocations, multi-second hang on main thread). A single pass
        // count of "\n" chars is O(n) without allocations.
        let entryCount = diskContent.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        let source = "log file (trimmed by size, up to 2 MB)"
        return Self.exportHeader(entryCount: entryCount, source: source) + diskContent
    }

    /// The log file's text: empty when there is no file yet (nothing has
    /// been flushed since Persistent Logging was turned on); throws when a
    /// file is there but cannot be read as UTF-8 text.
    nonisolated static func readLogFile(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The export header's source line when the log file could not be read.
    nonisolated static func unreadableFileSource(_ error: Error) -> String {
        "in-memory buffer, last 7 days (the log file could not be read: \(error.localizedDescription))"
    }

    /// Every line of `content` scrubbed again on the way out: lines an
    /// earlier build flushed went through its narrower scrubber. Redaction is
    /// idempotent, so a line already scrubbed comes through unchanged. Off
    /// the main thread, as every caller is.
    nonisolated private static func scrubbedLines(_ content: String) -> String {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { scrubPHI(String($0)) }
            .joined(separator: "\n")
    }

    /// The in-memory ring buffer (last 7 days, at most `maxMemoryEntries`)
    /// plus the entries not yet moved into it, scrubbed like the disk path,
    /// under a header naming `source`.
    nonisolated private func exportMemoryLogs(source: String) -> String {
        let buffered = exportBuffer.withLock { $0 }
        let pending = pendingEntries.withLock { $0 }
        let lines = (buffered + pending).map { Self.scrubPHI($0.formatted) }
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        return Self.exportHeader(entryCount: lines.count, source: source) + body
    }

    nonisolated private static func exportHeader(entryCount: Int, source: String) -> String {
        """
        Emuqu Debug Log
        Exported: \(Date())
        Device: \(DeviceInfo.model)
        iOS: \(DeviceInfo.systemVersion)
        App Version: \(Bundle.main.appVersion)
        Build: \(Bundle.main.appBuild)
        Source: \(source)
        Entries: \(entryCount)
        ========================================

        """
    }

    func exportErrorCatalog() -> String {
        let header = """
        Emuqu Error Catalog (Since App Launch)
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
    /// across the sandbox, logging:
    ///   Failed to request default share mode for fileURL:...Documents/...
    ///   Only support loading options for CKShare and SWY types.
    ///   NSCocoaErrorDomain Code=256 "The file couldn't be opened."
    /// sharingd retry-loops ~500 ms per attempt before the sheet finally
    /// works. The
    /// temp dir is not iCloud-backed, so none of that probing happens
    /// and the file opens on the FIRST try. The RR/CSV/all-data exports
    /// use tmp for the same reason.
    ///
    /// NOTE: the LaunchServices lines (`-10814`, "Failed to locate
    /// container app bundle record", "canmaplsdatabase domain 8") are
    /// iOS-internal share-sheet noise unrelated to our file and are not
    /// something app code can suppress; the openability failure above is
    /// the part that actually blocks the share, and the temp location
    /// avoids it.
    ///
    /// The temporary folder is the export folder (`ExportFile`): the file
    /// gets complete protection like every export (the share sheet reads it
    /// while the phone is unlocked), each export replaces the previous one,
    /// and the next launch removes the last. Nil, logged, when the file
    /// cannot be written.
    nonisolated func exportToFile() -> URL? {
        let fileName = "\(Self.exportFilePrefix)\(Int(Date().timeIntervalSince1970)).txt"
        guard let data = exportLogs().data(using: .utf8) else { return nil }
        do {
            return try ExportFile.write(data, named: fileName, replacingPrefix: Self.exportFilePrefix)
        } catch {
            NSLog("[DebugLogger] writing the log export failed: %@", error.localizedDescription)
            return nil
        }
    }

    /// The start of every log export's file name.
    nonisolated private static let exportFilePrefix = "hrv_debug_log_"

    /// Async export. The sync version runs all work on
    /// the calling thread (typically main): a 14k-line log is a
    /// multi-second hang. This version reads the disk file, builds
    /// the header, and writes the temp file all on a background
    /// queue and returns the URL on main when done. Drop-in
    /// replacement for `exportToFile()` in any await-friendly
    /// caller.
    nonisolated func exportToFileAsync() async -> URL? {
        await Task.detached(priority: .userInitiated) {
            self.exportToFile()
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
