import Foundation
import MetricKit
import UIKit

/// Answers the question "why did iOS kill us?" with
/// hard data instead of speculation.
///
/// Three independent diagnostic streams converge here:
///
/// 1. **MetricKit (`MXMetricManager`)** — Apple's official mechanism
///    for delivering post-mortem app exit data. After a SIGKILL,
///    `MXMetricPayload.applicationExitMetrics.backgroundExitData`
///    contains a categorized count of why iOS terminated the app:
///      • `cumulativeMemoryResourceLimitExitCount` — exceeded the iOS
///        memory budget (Jetsam killed for memory pressure)
///      • `cumulativeCPUResourceLimitExitCount` — exceeded the iOS
///        CPU budget (energy / thermal throttle)
///      • `cumulativeBackgroundTaskAssertionTimeoutExitCount` —
///        background task assertion expired (the audio / location
///        background mode lapsed)
///      • `cumulativeAppWatchdogExitCount` — main thread blocked
///        for too long (watchdog kill, ~20 s)
///      • `cumulativeBadAccessExitCount` — EXC_BAD_ACCESS (segfault)
///      • `cumulativeIllegalInstructionExitCount` — illegal opcode
///        (Swift fatal trap, e.g. force-unwrap on nil, integer
///        overflow, array bounds)
///      • `cumulativeAbnormalExitCount` — anything else uncategorized
///    Payloads land asynchronously, typically once per day at first
///    launch. We persist every payload received so the user can see
///    a history of WHY their app has been getting killed.
///
/// 2. **`MXDiagnosticPayload`** (iOS 14+) — for in-flight diagnostics
///    when iOS captures a crash, hang, CPU exception, or disk-write
///    exception. Includes call stack + signal info. Complements the
///    aggregated counters from `MXMetricPayload` with per-event
///    detail.
///
/// 3. **Real-time sampling** during recording — periodic
///    `task_info(MACH_TASK_BASIC_INFO)` for resident memory + thermal
///    state notifications + memory warning notifications. We log
///    these to the debug log on each tick AND to a structured
///    in-memory sample buffer so a workout that gets killed has its
///    last-known memory/thermal trace visible in the next launch's
///    diagnostics. Without this, we know iOS killed the app but
///    have no idea what its memory footprint was at the time.
///
/// Wired into `EmuquApp.init` next to `CrashLogManager.install()`.
/// `@unchecked Sendable`: the sampler state, the counters and every
/// memory-trace write run on `samplingQueue` (the notification handlers and
/// `install` hop onto it), and MetricKit delivers payloads on its own serial
/// queue.
final class SystemDiagnosticsManager: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = SystemDiagnosticsManager()

    /// Storage location for persisted MetricKit payloads + memory
    /// trace samples. Lives in the app group container so the
    /// Settings → Diagnostics page can read it.
    private var diagnosticsDirectory: URL {
        AppConfig.sharedContainerURL().appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private var metricKitLogURL: URL {
        diagnosticsDirectory.appendingPathComponent("metrickit_history.jsonl")
    }

    private var memoryTraceURL: URL {
        diagnosticsDirectory.appendingPathComponent("memory_trace.jsonl")
    }

    /// Background sampling timer — driven by a DispatchSourceTimer so
    /// it fires regardless of run-loop activity (which matters during
    /// background recording when there's no UI tick).
    private var samplingTimer: DispatchSourceTimer?
    private let samplingQueue = DispatchQueue(label: "com.chrissharp.flowrecovery.diagnostics", qos: .utility)

    /// Last-seen memory footprint for stop-recording reconciliation.
    /// Reads from `task_info`, in bytes.
    @objc dynamic var lastResidentMemoryBytes: UInt64 = 0
    @objc dynamic var lastThermalStateRaw: Int = ProcessInfo.ThermalState.nominal.rawValue
    @objc dynamic var memoryWarningCount: Int = 0

    override private init() {
        super.init()
    }

    // MARK: - Install

    /// Called from `EmuquApp.init` once per launch.
    func install() {
        // Make sure the directory exists; ignore if already present.
        _ = attempt("SystemDiagnosticsManager.create") {
            try FileManager.default.createDirectory(
                at: diagnosticsDirectory,
                withIntermediateDirectories: true
            )
        }
        // Subscribe to MetricKit. Apple delivers payloads on a
        // background thread; we just persist on receipt.
        MXMetricManager.shared.add(self)
        installSystemObservers()
        // Take an initial sample so the trace has a baseline. Synchronous, so
        // it is on disk before the termination report reads the trace and
        // tells this launch's samples from the previous process's by it.
        samplingQueue.sync { sampleMemoryAndThermal(reason: "launch") }
    }

    /// Memory warning observer — when iOS posts the warning notification, the
    /// app is one step away from a memory kill. Log every warning so a workout
    /// that eventually gets killed has the warning history visible in the
    /// post-mortem.
    ///
    /// Thermal state observer — `serious` and `critical` thermal states are
    /// correlated with iOS's CPU-budget enforcement killing background apps.
    /// Log transitions.
    private func installSystemObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThermalChange),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
    }

    deinit {
        MXMetricManager.shared.remove(self)
        NotificationCenter.default.removeObserver(self)
        samplingTimer?.cancel()
    }

    // MARK: - Real-time sampling (start/stop)

    /// Start periodic memory + thermal sampling. Call when a recording
    /// session begins. Pre-existing timer is cancelled and replaced.
    /// 5-second cadence is dense enough to catch a 30-second-warning →
    /// kill window but light enough that 4 hours of sampling is ~3000
    /// samples = ~120 KB of JSONL.
    func startSamplingDuringRecording() {
        samplingQueue.async { [weak self] in
            guard let self else { return }
            self.samplingTimer?.cancel()
            self.trimMemoryTraceIfNeeded()
            let timer = DispatchSource.makeTimerSource(queue: self.samplingQueue)
            timer.schedule(deadline: .now() + 5, repeating: 5.0)
            timer.setEventHandler { [weak self] in
                self?.sampleMemoryAndThermal(reason: "tick")
            }
            timer.resume()
            self.samplingTimer = timer
            debugLog("[Diagnostics] memory/thermal sampler started (5 s cadence)")
        }
    }

    /// Stop sampling. Call when recording ends normally so we don't
    /// run the timer in the foreground app indefinitely.
    func stopSamplingAfterRecording() {
        samplingQueue.async { [weak self] in
            self?.samplingTimer?.cancel()
            self?.samplingTimer = nil
            self?.sampleMemoryAndThermal(reason: "stop")
            debugLog("[Diagnostics] memory/thermal sampler stopped")
        }
    }

    // MARK: - MXMetricManagerSubscriber

    /// Aggregated metrics — delivered ~daily on launch. Contains the
    /// `applicationExitMetrics` we care about for "why did iOS kill us".
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            persistMetricPayload(payload)
        }
    }

    /// Per-event diagnostics — crash, hang, CPU exception, disk write
    /// exception. iOS 14+. Provides call stacks + signal info.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            persistDiagnosticPayload(payload)
        }
    }

    // MARK: - Payload persistence

    private func persistMetricPayload(_ payload: MXMetricPayload) {
        let summary = summarizeMetricPayload(payload)
        appendJSONLine(at: metricKitLogURL, line: summary)
        debugLog("[Diagnostics] MXMetricPayload received: \(summary["summary"] as? String ?? "(no summary)")")
    }

    private func persistDiagnosticPayload(_ payload: MXDiagnosticPayload) {
        let summary = summarizeDiagnosticPayload(payload)
        appendJSONLine(at: metricKitLogURL, line: summary)
        debugLog("[Diagnostics] MXDiagnosticPayload received: \(summary["summary"] as? String ?? "(no summary)")")
        for crash in payload.crashDiagnostics ?? [] { logCrashCallStack(crash) }
    }

    /// Write the crashing call stack into the debug log, one frame per line.
    ///
    /// The summary above reduces a crash to `signal=[5]`, which says "a Swift
    /// runtime trap happened" and nothing else. The in-process handler in
    /// `CrashSignalHandler.c` cannot do better — it runs in signal context, so
    /// it can only emit raw return addresses, and those are readable only
    /// against the exact dSYM for the exact build the user is running. This
    /// payload already carries the thing that IS readable: each frame's binary
    /// name, its UUID, and its offset into that binary's text segment. Offsets
    /// are slide-independent and the UUID names the build, so `atos -o <dSYM>
    /// -l 0x100000000 0x100000000+<offset>` resolves them against any archive.
    ///
    /// It goes into the debug log because that is the artifact users export,
    /// and the same frames are saved with the payload in
    /// `metrickit_history.jsonl` (`persistedFrames`) because the debug log is
    /// only kept on disk when persistent logging is on. A lost walk once arrived here
    /// as the number 5, and the stack that would have explained it was
    /// discarded on the same line that logged the 5.
    private func logCrashCallStack(_ crash: MXCrashDiagnostic) {
        let meta = crash.metaData.jsonRepresentation()
        let build = (Self.jsonObject(meta)?["appBuildVersion"] as? String) ?? "?"
        debugLog(
            "[Diagnostics][crash] signal=\(crash.signal?.stringValue ?? "?") "
                + "exception=\(crash.exceptionType?.stringValue ?? "?")/"
                + "\(crash.exceptionCode?.stringValue ?? "?") "
                + "termination=\(crash.terminationReason ?? "?") build=\(build)",
            level: .warning
        )
        let frames = MetricKitCrashStack.frames(fromCallStackTree: crash.callStackTree.jsonRepresentation())
        guard !frames.isEmpty else {
            debugLog("[Diagnostics][crash] no call stack in payload", level: .warning)
            return
        }
        logFrames(frames)
    }

    /// Default level, NOT `.warning`.
    ///
    /// `.warning` and above land in the error catalog — the user-facing
    /// "Recent Problems" list — and each one posts the notification that wakes
    /// the Diagnostics badge. Logging forty stack frames at warning level
    /// buries the user's actual recent problems under a wall of hex and fires
    /// forty notifications for one event. The header line is the warning;
    /// these are its detail, and they still reach the debug log the user
    /// exports, which is the whole point of keeping them.
    private func logFrames(_ frames: [String]) {
        for (index, frame) in frames.prefix(Self.maxLoggedCrashFrames).enumerated() {
            debugLog("[Diagnostics][crash] #\(index) \(frame)")
        }
    }

    /// Frames past this are noise: the deepest 40 cover the crashing thread's
    /// own stack and the dispatch/pthread tail that got it there.
    private static let maxLoggedCrashFrames = 40

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        let parsed = attempt("metrickit.metaData.parse") {
            try JSONSerialization.jsonObject(with: data)
        }
        guard let parsed else { return nil }
        return parsed as? [String: Any]
    }

    /// Reduce an `MXMetricPayload` to the fields that matter for "why
    /// did iOS kill us". The full payload has dozens of fields; we
    /// keep the exit-data counters + a couple of CPU/memory rollups
    /// that contextualize them. The full JSON dictionary is also
    /// preserved as a fallback in case future fields prove useful.
    private func summarizeMetricPayload(_ payload: MXMetricPayload) -> [String: Any] {
        var dict: [String: Any] = [
            "kind": "metric",
            "received_at": ISO8601DateFormatter().string(from: Date()),
            "begin": ISO8601DateFormatter().string(from: payload.timeStampBegin),
            "end": ISO8601DateFormatter().string(from: payload.timeStampEnd)
        ]
        if #available(iOS 14.0, *), let exit = payload.applicationExitMetrics {
            let bgCounts = Self.exitCounts(background: exit.backgroundExitData)
            let fgCounts = Self.exitCounts(foreground: exit.foregroundExitData)
            dict["exit_background"] = bgCounts
            dict["exit_foreground"] = fgCounts
            dict["summary"] = summarizeExitCounts(bg: bgCounts, fg: fgCounts)
        }
        addResourceRollups(payload, to: &dict)
        return dict
    }

    /// A couple of CPU/memory rollups that contextualize the exit counters.
    private func addResourceRollups(_ payload: MXMetricPayload, to dict: inout [String: Any]) {
        if let cpu = payload.cpuMetrics {
            dict["cpu_seconds"] = cpu.cumulativeCPUTime.converted(to: .seconds).value
        }
        if let mem = payload.memoryMetrics {
            dict["peak_memory_bytes"] = mem.peakMemoryUsage.converted(to: .bytes).value
            dict["avg_suspended_memory_bytes"] = mem.averageSuspendedMemory.averageMeasurement.converted(to: .bytes).value
        }
    }

    /// Note: MXBackgroundExitData fields differ across iOS versions. We stick
    /// to the ones present in iOS 14+ that matter for our case.
    /// (BackgroundURLSession / BackgroundFetch timeout counters are surfaced
    /// through diagnostics, not here.)
    @available(iOS 14.0, *)
    private static func exitCounts(background bg: MXBackgroundExitData) -> [String: Int] {
        [
            "memory_resource_limit": bg.cumulativeMemoryResourceLimitExitCount,
            "cpu_resource_limit": bg.cumulativeCPUResourceLimitExitCount,
            "background_task_assertion_timeout": bg.cumulativeBackgroundTaskAssertionTimeoutExitCount,
            "bad_access": bg.cumulativeBadAccessExitCount,
            "abnormal": bg.cumulativeAbnormalExitCount,
            "illegal_instruction": bg.cumulativeIllegalInstructionExitCount,
            "app_watchdog": bg.cumulativeAppWatchdogExitCount,
            "suspended_with_locked_file": bg.cumulativeSuspendedWithLockedFileExitCount,
            "normal": bg.cumulativeNormalAppExitCount
        ]
    }

    @available(iOS 14.0, *)
    private static func exitCounts(foreground fg: MXForegroundExitData) -> [String: Int] {
        [
            "memory_resource_limit": fg.cumulativeMemoryResourceLimitExitCount,
            "bad_access": fg.cumulativeBadAccessExitCount,
            "abnormal": fg.cumulativeAbnormalExitCount,
            "illegal_instruction": fg.cumulativeIllegalInstructionExitCount,
            "app_watchdog": fg.cumulativeAppWatchdogExitCount,
            "normal": fg.cumulativeNormalAppExitCount
        ]
    }

    /// Format an exit-count dict into a human-readable one-liner —
    /// "iOS killed the app for memory pressure 3× in background"
    /// rather than a raw counter dump.
    private func summarizeExitCounts(bg: [String: Int], fg: [String: Int]) -> String {
        var parts: [String] = []
        for (key, count) in bg where count > 0 && key != "normal" {
            parts.append("bg_\(key)=\(count)")
        }
        for (key, count) in fg where count > 0 && key != "normal" {
            parts.append("fg_\(key)=\(count)")
        }
        if parts.isEmpty { return "no abnormal exits this period" }
        return parts.sorted().joined(separator: " · ")
    }

    private func summarizeDiagnosticPayload(_ payload: MXDiagnosticPayload) -> [String: Any] {
        var dict: [String: Any] = [
            "kind": "diagnostic",
            "received_at": ISO8601DateFormatter().string(from: Date()),
            "begin": ISO8601DateFormatter().string(from: payload.timeStampBegin),
            "end": ISO8601DateFormatter().string(from: payload.timeStampEnd)
        ]
        var summaryParts: [String] = []
        summaryParts += crashAndHangFields(payload, into: &dict)
        if let cpu = payload.cpuExceptionDiagnostics, !cpu.isEmpty {
            dict["cpu_exception_count"] = cpu.count
            summaryParts.append("\(cpu.count) CPU exception(s)")
        }
        if let disk = payload.diskWriteExceptionDiagnostics, !disk.isEmpty {
            dict["disk_write_exception_count"] = disk.count
            summaryParts.append("\(disk.count) disk-write exception(s)")
        }
        dict["summary"] = summaryParts.isEmpty ? "no diagnostic events" : summaryParts.joined(separator: " · ")
        return dict
    }

    /// Crash and hang counters, written into `dict` and described in the
    /// returned summary fragments.
    private func crashAndHangFields(
        _ payload: MXDiagnosticPayload, into dict: inout [String: Any]
    ) -> [String] {
        var parts: [String] = []
        if let crashes = payload.crashDiagnostics, !crashes.isEmpty {
            dict["crash_count"] = crashes.count
            let signals = crashes.compactMap { $0.signal?.intValue }
            dict["crash_signals"] = signals
            dict["crash_frames"] = crashes.map(Self.persistedFrames)
            parts.append("\(crashes.count) crash diagnostic(s) signal=\(signals)")
        }
        if let hangs = payload.hangDiagnostics, !hangs.isEmpty {
            dict["hang_count"] = hangs.count
            let durations = hangs.map { $0.hangDuration.converted(to: .seconds).value }
            dict["hang_durations_s"] = durations
            parts.append("\(hangs.count) hang(s) max=\(String(format: "%.1f", durations.max() ?? 0)) s")
        }
        return parts
    }

    /// The crash's symbolicatable frames, kept in `metrickit_history.jsonl` as
    /// well as the debug log: persistent debug logging is off by default in
    /// Release, so the log copy alone is lost when the app quits.
    private static func persistedFrames(_ crash: MXCrashDiagnostic) -> [String] {
        let frames = MetricKitCrashStack.frames(fromCallStackTree: crash.callStackTree.jsonRepresentation())
        return Array(frames.prefix(maxLoggedCrashFrames))
    }

    // MARK: - Memory + thermal sampling

    /// Both handlers hop onto `samplingQueue`: they are called on main and on
    /// whatever thread posts the thermal notification, and two writers
    /// seeking to the same end of the trace file overwrote each other's line.
    @objc private func handleMemoryWarning() {
        samplingQueue.async { [weak self] in
            guard let self else { return }
            self.memoryWarningCount += 1
            self.sampleMemoryAndThermal(reason: "memory_warning")
            debugLog("[Diagnostics] ⚠️ memory warning #\(self.memoryWarningCount)", level: .warning)
        }
    }

    @objc private func handleThermalChange() {
        samplingQueue.async { [weak self] in
            guard let self else { return }
            let state = ProcessInfo.processInfo.thermalState
            self.sampleMemoryAndThermal(reason: "thermal_\(self.thermalStateName(state))")
            debugLog("[Diagnostics] thermal state → \(self.thermalStateName(state))", level: .info)
        }
    }

    private func sampleMemoryAndThermal(reason: String) {
        let bytes = currentResidentMemoryBytes()
        let thermal = ProcessInfo.processInfo.thermalState
        lastResidentMemoryBytes = bytes
        lastThermalStateRaw = thermal.rawValue
        let sample: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "reason": reason,
            "memory_bytes": bytes,
            "memory_mb": String(format: "%.1f", Double(bytes) / 1_048_576),
            "thermal": thermalStateName(thermal),
            "memory_warnings_total": memoryWarningCount
        ]
        appendJSONLine(at: memoryTraceURL, line: sample)
        logHeartbeat(reason: reason, bytes: bytes, thermal: thermal)
    }

    /// SIGKILL diagnostics — also emit a coarse
    /// heartbeat to the regular debug log. The JSONL trace is
    /// great for the in-app diagnostics chart but invisible to
    /// the user's exported debug log; when iOS SIGKILLs the app
    /// mid-workout, the user's next walk's debug log is the
    /// primary triage surface and a 16-second silent gap (a real
    /// termination report's pattern) tells nobody
    /// anything. Heartbeat once a minute (every 12th tick @ 5 s
    /// cadence) plus immediately on any non-nominal thermal state or
    /// a memory warning since the last heartbeat. Costs 1 log line per minute during
    /// recording; gains: a visible trail right up to the moment
    /// iOS kills the process.
    ///
    /// `fair` is iOS's lowest non-nominal thermal level ("slightly
    /// elevated, apps and system function normally") and routinely
    /// ticks during a normal cold launch on a warm day. Logging it
    /// as a warning put it in the persistent error catalog where it
    /// looked like a real problem; only `serious`/`critical` thermal
    /// or a real memory-warning event should escalate the level.
    ///
    /// A memory warning escalates only the heartbeat that follows it: the
    /// count lives for the whole process, so keying on `> 0` turned one early
    /// warning into a warning-level line every 5 s for the rest of the night.
    private func logHeartbeat(reason: String, bytes: UInt64, thermal: ProcessInfo.ThermalState) {
        let hasNewMemoryWarning = memoryWarningCount > lastHeartbeatMemoryWarningCount
        lastHeartbeatMemoryWarningCount = memoryWarningCount
        let isNonNominal = thermal != .nominal || hasNewMemoryWarning
        guard isNonNominal || isHeartbeatTick(reason: reason) else { return }
        let isAlarming = thermal == .serious || thermal == .critical || hasNewMemoryWarning
        let mb = String(format: "%.1f", Double(bytes) / 1_048_576)
        debugLog(
            "[Diagnostics] heartbeat reason=\(reason) mem=\(mb) MB thermal=\(thermalStateName(thermal)) mem_warnings=\(memoryWarningCount)",
            level: isAlarming ? .warning : .info
        )
    }

    private func isHeartbeatTick(reason: String) -> Bool {
        if reason != "tick" { return true } // start/stop always log
        samplerTickCounter &+= 1
        return samplerTickCounter % 12 == 0 // every 12th 5-s tick = ~60 s
    }

    /// `memoryWarningCount` as of the last heartbeat; read and written only on
    /// `samplingQueue`, like the count itself.
    private var lastHeartbeatMemoryWarningCount = 0

    /// Counter for the once-per-minute heartbeat above.
    /// Wraps with `&+=` so a 24-hour ultra session can't overflow it.
    private var samplerTickCounter: UInt64 = 0

    /// Read the app's current resident memory size via Mach.
    /// Returns 0 on failure (rare — task_info is well-supported).
    private func currentResidentMemoryBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        // `phys_footprint` is what iOS uses for memory-budget enforcement
        // — closer to the Jetsam threshold than `resident_size`. Available
        // on iOS 13+. See WWDC 2018 "iOS Memory Deep Dive."
        return info.phys_footprint
    }

    private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    // MARK: - Read-back API for Settings UI

    /// Read all persisted MetricKit payload summaries (one per JSONL
    /// line) so the diagnostics UI can render a list. Newest first.
    func readMetricKitHistory() -> [[String: Any]] {
        readJSONLines(at: metricKitLogURL).reversed()
    }

    /// Read recent memory trace samples for the diagnostics chart.
    /// `limit` caps the read to keep the UI responsive — a 4-hour
    /// recording produces ~3000 samples; default 1000 is enough for
    /// most views.
    func readRecentMemoryTrace(limit: Int = 1000) -> [[String: Any]] {
        // Only the tail is read: the trace gains a sample every 5 s of every
        // recording, and this runs on the main thread from the diagnostics
        // view and the post-crash launch report.
        let all = readJSONLines(from: tail(of: memoryTraceURL, maxBytes: limit * Self.approximateSampleBytes))
        return Array(all.suffix(limit))
    }

    /// A sample line is about 180 bytes; the margin keeps `limit` lines in reach.
    private static let approximateSampleBytes = 256

    /// Past this the trace is cut back to its most recent half, at the start
    /// of a recording. It otherwise grew by about 0.8 MB a night, forever.
    private static let memoryTraceMaxBytes = 2_000_000

    private func trimMemoryTraceIfNeeded() {
        let url = memoryTraceURL
        guard let size = attempt("diagnostics.size", {
            try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        }) ?? nil, size > Self.memoryTraceMaxBytes else { return }
        let kept = tail(of: url, maxBytes: Self.memoryTraceMaxBytes / 2)
        // Drop the partial first line the byte cut landed in.
        guard let firstBreak = kept.firstIndex(of: 0x0A) else { return }
        createDiagnosticsFile(at: url, first: Data(kept[kept.index(after: firstBreak)...]))
    }

    /// The last `maxBytes` of a file, read without loading the rest.
    private func tail(of url: URL, maxBytes: Int) -> Data {
        guard FileManager.default.fileExists(atPath: url.path),
              let handle = attempt("diagnostics.openTail", { try FileHandle(forReadingFrom: url) }) else { return Data() }
        defer { attempt("diagnostics.close") { try handle.close() } }
        return attempt("diagnostics.tail") { () throws -> Data in
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0)
            return try handle.readToEnd() ?? Data()
        } ?? Data()
    }

    /// Truncate the trace files. Used by the "Delete All My Data"
    /// flow + manual "Clear" buttons in diagnostics UI.
    func clearAll() {
        _ = attempt("SystemDiagnosticsManager.remove") { try FileManager.default.removeItem(at: metricKitLogURL) }
        _ = attempt("SystemDiagnosticsManager.remove") { try FileManager.default.removeItem(at: memoryTraceURL) }
    }

    // MARK: - JSONL helpers

    private func appendJSONLine(at url: URL, line: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: []) else { return }
        var lineData = data
        lineData.append(0x0A) // newline
        guard FileManager.default.fileExists(atPath: url.path) else {
            createDiagnosticsFile(at: url, first: lineData)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        // Throwing calls: the legacy `write(_:)` raises an uncatchable
        // exception on a full disk, and this runs every 5 s of a recording.
        attempt("diagnostics.append") {
            try handle.seekToEnd()
            try handle.write(contentsOf: lineData)
        }
        attempt("diagnostics.close") { try handle.close() }
    }

    /// Match the rest of the app's data protection class — use
    /// `.completeUntilFirstUserAuthentication` so this file stays
    /// writable while the device is locked (these get appended
    /// to during background recording).
    private func createDiagnosticsFile(at url: URL, first lineData: Data) {
        attempt("diagnostics.write") { try lineData.write(to: url, options: .atomic) }
        _ = attempt("SystemDiagnosticsManager.setAttributes") {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        }
    }

    private func readJSONLines(at url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return readJSONLines(from: data)
    }

    /// Split on newline bytes, not decoded text: a tail read can start inside
    /// a multi-byte character, and decoding the whole buffer first would then
    /// fail or mangle it. A line cut short at either end simply fails to parse
    /// and is skipped.
    private func readJSONLines(from data: Data) -> [[String: Any]] {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .compactMap { line -> [String: Any]? in
                try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            }
    }
}
