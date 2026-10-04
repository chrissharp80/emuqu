import Foundation
import os.signpost
import UIKit

/// Always-on signpost emitter + opt-in in-memory ring buffer for the
/// keyboard-focus hang investigation.
///
/// Symptom under investigation: tapping any TextField (Coach chat,
/// Settings email field, etc.) hangs the main thread for several
/// seconds before the keyboard appears, then the first character
/// typed hangs again briefly. Per the investigation hand-off, no
/// patches without measurement — this is the measurement surface.
///
/// **Two ways to capture.** Pick whichever is convenient.
/// 1. **Xcode → Instruments → real device**, Logging or Time Profiler
///    template, filter to subsystem `com.chrissharp.flowrecovery`,
///    category `keyboard-perf`. Highest fidelity. Requires a Mac +
///    cable. Use this when you need stack traces.
/// 2. **In-app capture button** (Settings → Troubleshooting →
///    Capture keyboard performance profile). Records a window (`captureWindowSeconds`) of every
///    signpost event to an in-memory buffer, then writes a JSONL
///    trace the user can share. Lower fidelity than Instruments
///    (no stack traces) but always available — no host machine
///    required, ships with TestFlight builds.
///
/// **Cost when not capturing.** `os_signpost` is a kernel trap that
/// no-ops when no trace is attached (~50 ns). The in-memory buffer
/// only fills while a capture is running, so always-on signpost
/// calls in render paths are effectively free.
///
/// **Thread-safety.** All buffer mutations go through a serial
/// dispatch queue. Public emit methods are safe to call from any
/// thread; SwiftUI body sites are on main, notification observers
/// dispatch onto main.
/// Capture lifetime is NOT tied to a SwiftUI view: stopping on
/// `.onDisappear` would end the capture the moment the user
/// navigated to the Coach tab to actually trigger the focus event,
/// producing two short, useless traces in a row. Instead:
///   • capture is global singleton state, fully decoupled from any
///     view's lifecycle;
///   • the singleton publishes `isCapturing` and `lastTraceURL` so
///     the UI can re-attach when the user comes back;
///   • the only ways to stop are: tap Stop, the auto-stop after
///     `captureWindowSeconds`, or
///     the explicit `stopCapture()` API.
@Observable
/// `@unchecked Sendable`: the ring buffer and capture flags are confined
/// to `queue`; only the observable mirrors are touched on the main actor.
final class KeyboardPerfSignpost: @unchecked Sendable {
    static let shared = KeyboardPerfSignpost()

    /// Subsystem matches the cold-start log in `EmuquApp.swift`
    /// so a single Instruments filter (`com.chrissharp.flowrecovery`)
    /// shows both launch and focus signposts.
    private let log = OSLog(subsystem: "com.chrissharp.flowrecovery", category: "keyboard-perf")

    /// Serializes all writes to the event buffer + capture state.
    private let queue = DispatchQueue(label: "com.chrissharp.flowrecovery.kpsbuffer", qos: .utility)

    @MainActor private(set) var isCapturing: Bool = false
    @MainActor private(set) var captureStartedAt: Date?
    @MainActor private(set) var lastTraceURL: URL?
    @MainActor private(set) var lastTraceEventCount: Int = 0

    /// Hot-path capture flag, owned by the serial queue. Mirrors to
    /// `isCapturing` on main for the UI; the queue copy is what the
    /// `record(...)` fast path checks.
    ///
    /// The queue-owned state is `@ObservationIgnored`: the UI reads only the
    /// main-actor mirrors, and tracking `events` made every heartbeat and
    /// event (about 5 a second) schedule a SwiftUI update during a capture
    /// meant to find main-thread stalls.
    @ObservationIgnored private var capturing: Bool = false
    @ObservationIgnored private var captureStartMonoNs: UInt64 = 0
    @ObservationIgnored private var captureStartWall: Date = .distantPast
    @ObservationIgnored private var captureAutoStopWorkItem: DispatchWorkItem?
    @ObservationIgnored private var events: [Entry] = []

    /// Main-thread heartbeat. Fires every 200 ms while a capture is
    /// running. If a heartbeat goes missing for more than ~250 ms
    /// in the trace, the main thread was busy with something
    /// SwiftUI doesn't surface — UIKit work, file I/O, system
    /// framework calls. This is how we tell "main was idle waiting
    /// on iOS" from "main was blocked by our code" during the
    /// keyboard-focus gap.
    @ObservationIgnored private var heartbeatTimer: DispatchSourceTimer?

    /// Hard cap on retained events. 20000 rather than 5000 so
    /// longer windows can be captured. At ~30
    /// events/sec on a busy chat path, 20000 events ≈ 10 minutes
    /// of activity. Memory cost is bounded — each entry is small
    /// (~100 bytes), so 20000 ≈ 2 MB.
    static let maxEvents = 20000

    /// Watchdog ceiling for runaway captures (10 minutes). If the
    /// user forgets to tap Stop AND closes the app, we don't want
    /// to keep capturing forever. Long enough to test at length; the
    /// user is expected to tap Stop when they're done.
    static let captureWindowSeconds: TimeInterval = 600

    /// One captured event. Times are stored as nanoseconds since
    /// the start of the capture so JSONL serialization is cheap and
    /// the relative ordering is exact.
    struct Entry {
        let offsetNs: UInt64
        let kind: Kind
        let name: String
        let durationNs: UInt64?
        let detail: String?

        enum Kind: String {
            case event
            case begin
            case end
            case marker
        }
    }

    private init() {
        installNotificationObservers()
    }

    // MARK: - Public emit API

    /// Instant signpost event. Cheap; emit liberally inside render
    /// paths. The sole side effect is a kernel-trap call to
    /// `os_signpost(.event, ...)` plus, IF a capture is running, a
    /// queue.async record into the ring buffer.
    func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
        record(name: "\(name)", kind: .event, durationNs: nil, detail: nil)
    }

    /// Variant carrying a runtime `detail` string, surfaced in
    /// Instruments via the `%{public}s` format and stored in the
    /// JSONL trace's `detail` field.
    func event(_ name: StaticString, detail: String) {
        os_signpost(.event, log: log, name: name, "%{public}s", detail)
        record(name: "\(name)", kind: .event, durationNs: nil, detail: detail)
    }

    /// Run a synchronous block measuring its wall-clock duration.
    /// Emits begin/end signposts and a buffered begin/end pair.
    @discardableResult
    func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let id = OSSignpostID(log: log)
        let start = DispatchTime.now().uptimeNanoseconds
        os_signpost(.begin, log: log, name: name, signpostID: id)
        record(name: "\(name)", kind: .begin, durationNs: nil, detail: nil)
        defer {
            let durationNs = DispatchTime.now().uptimeNanoseconds &- start
            os_signpost(.end, log: log, name: name, signpostID: id)
            record(name: "\(name)", kind: .end, durationNs: durationNs, detail: nil)
        }
        return try body()
    }

    // MARK: - Capture API

    /// Most recent number of events recorded during the active or
    /// just-completed capture. Used by the UI to show progress.
    func currentEventCount() -> Int {
        queue.sync { events.count }
    }

    /// Begin a capture window. Returns false if a capture was
    /// already running. Auto-stops after `captureWindowSeconds`.
    /// The auto-stop now ALSO writes the trace and updates
    /// `lastTraceURL` so the user can navigate away and come back
    /// to a finished trace without losing it.
    @discardableResult
    func startCapture() -> Bool {
        let started: Bool = queue.sync { beginCaptureLocked() }
        guard started else { return false }
        let wall = queue.sync { captureStartWall }
        Task { @MainActor in
            self.isCapturing = true
            self.captureStartedAt = wall
            self.installHeartbeat()
        }
        return true
    }

    /// Reset the buffer and arm the auto-stop. Must be called on `queue`.
    private func beginCaptureLocked() -> Bool {
        guard !capturing else { return false }
        events.removeAll(keepingCapacity: true)
        captureStartMonoNs = DispatchTime.now().uptimeNanoseconds
        captureStartWall = Date()
        capturing = true
        let work = DispatchWorkItem { [weak self] in
            self?.autoStop()
        }
        captureAutoStopWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.captureWindowSeconds,
            execute: work
        )
        os_signpost(.event, log: log, name: "capture.start")
        return true
    }

    /// Install the main-thread heartbeat for the active capture.
    /// Uses a `DispatchSourceTimer` on main so it stops firing
    /// the moment main is blocked — gaps in the heartbeat
    /// stream tell us exactly when the main thread stalled.
    @MainActor
    private func installHeartbeat() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.event("main.heartbeat")
        }
        timer.resume()
        heartbeatTimer = timer
    }

    @MainActor
    private func tearDownHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    /// Stop a running capture and return the collected events.
    /// Returns an empty array if no capture was running.
    ///
    /// The main-actor state is reset whenever a capture was running, even
    /// one that recorded nothing: a Stop within the first heartbeat left
    /// the UI saying "capturing" and the heartbeat timer running.
    @discardableResult
    func stopCapture() -> [Entry] {
        let stopped: (wasCapturing: Bool, entries: [Entry]) = queue.sync {
            guard capturing else { return (false, []) }
            capturing = false
            captureAutoStopWorkItem?.cancel()
            captureAutoStopWorkItem = nil
            os_signpost(.event, log: log, name: "capture.stop")
            return (true, events)
        }
        if stopped.wasCapturing {
            Task { @MainActor in
                self.isCapturing = false
                self.tearDownHeartbeat()
            }
        }
        return stopped.entries
    }

    /// Stop the capture, write a JSONL trace to the temp dir, and
    /// return the file URL. Returns nil if no capture was running
    /// or the file write failed. The caller is responsible for
    /// presenting a ShareLink / Share sheet on the URL. Side-effect:
    /// publishes the URL to `lastTraceURL` so a re-mounted view can
    /// pick it up.
    @discardableResult
    func stopCaptureAndExportTrace() -> URL? {
        let entries = stopCapture()
        guard !entries.isEmpty else { return nil }
        let url = writeTrace(entries: entries)
        if let url {
            let count = entries.count
            Task { @MainActor in
                self.lastTraceURL = url
                self.lastTraceEventCount = count
            }
        }
        return url
    }

    /// Internal: fired by the auto-stop DispatchWorkItem `captureWindowSeconds` after
    /// `startCapture`. Writes the trace and publishes the URL so the
    /// UI can re-attach when the user returns.
    private func autoStop() {
        _ = stopCaptureAndExportTrace()
    }

    // MARK: - Internal record + write

    private func record(name: String, kind: Entry.Kind, durationNs: UInt64?, detail: String?) {
        let now = DispatchTime.now().uptimeNanoseconds
        queue.async { [weak self] in
            guard let self, self.capturing else { return }
            let offset = now &- self.captureStartMonoNs
            self.events.append(Entry(
                offsetNs: offset,
                kind: kind,
                name: name,
                durationNs: durationNs,
                detail: detail
            ))
            if self.events.count > Self.maxEvents {
                self.events.removeFirst(self.events.count - Self.maxEvents)
            }
        }
    }

    private func writeTrace(entries: [Entry]) -> URL? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyboard-perf-\(stamp).jsonl")
        var lines = [Self.jsonLine(traceHeader(entryCount: entries.count, formatter: formatter))]
        lines += entries.map { Self.jsonLine(Self.traceLine($0)) }
        let content = lines.compactMap { $0 }.joined(separator: "\n") + "\n"
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// First JSONL line: what device produced this trace and when.
    private func traceHeader(entryCount: Int, formatter: ISO8601DateFormatter) -> [String: Any] {
        [
            "kind": "header",
            "subsystem": "com.chrissharp.flowrecovery",
            "category": "keyboard-perf",
            "captured_at": formatter.string(from: captureStartWall),
            "device_model": DeviceInfo.model,
            "system_name": DeviceInfo.systemName,
            "system_version": DeviceInfo.systemVersion,
            "event_count": entryCount
        ]
    }

    private static func traceLine(_ entry: Entry) -> [String: Any] {
        var dict: [String: Any] = [
            "kind": entry.kind.rawValue,
            "name": entry.name,
            "offset_ms": Double(entry.offsetNs) / 1_000_000.0
        ]
        if let duration = entry.durationNs {
            dict["duration_ms"] = Double(duration) / 1_000_000.0
        }
        if let detail = entry.detail {
            dict["detail"] = detail
        }
        return dict
    }

    private static func jsonLine(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Notification observers (markers)

    /// Hooks the system notifications that bracket a focus event:
    ///   • `UITextField.textDidBeginEditing` — moment the user tap
    ///     was accepted as a first-responder change
    ///   • `keyboardWillShow` / `keyboardDidShow` — the animation
    ///     in/out endpoints
    ///   • `keyboardWillHide` / `keyboardDidHide`
    ///   • `UITextField.textDidEndEditing`
    /// These markers anchor the timeline so when reading the trace
    /// we can answer "between user tap and willShow, who ran?".
    private func installNotificationObservers() {
        let nc = NotificationCenter.default
        let pairs: [(Notification.Name, String)] = [
            (UIResponder.keyboardWillShowNotification, "keyboard.willShow"),
            (UIResponder.keyboardDidShowNotification, "keyboard.didShow"),
            (UIResponder.keyboardWillHideNotification, "keyboard.willHide"),
            (UIResponder.keyboardDidHideNotification, "keyboard.didHide"),
            (UITextField.textDidBeginEditingNotification, "textField.didBeginEditing"),
            (UITextField.textDidEndEditingNotification, "textField.didEndEditing")
        ]
        for (name, marker) in pairs {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.marker(marker)
            }
        }
    }

    private func marker(_ name: String) {
        os_signpost(.event, log: log, name: "marker", "%{public}s", name)
        record(name: name, kind: .marker, durationNs: nil, detail: nil)
    }
}
