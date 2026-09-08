import AVFoundation
import Foundation

/// Logs AVAudioSession route changes that happen while the strap is live.
///
/// Users report the strap dropping when another app activates AirPods:
/// Bluetooth A2DP/HFP renegotiation can briefly preempt BLE on the shared
/// radio. The disconnect auto-reconnects, so the only thing missing is proof
/// of the correlation — every route change during a live stream prints the
/// reason and the previous route, so "AirPods → strap drop" can be confirmed
/// from a field log rather than guessed at.
///
/// Its own type because `PolarManager` is over the aggregate type-size
/// threshold and none of this is about Polar: it is an audio-session
/// observation that happens to be interesting while a strap is connected.
enum StrapAudioRouteWatch {
    @MainActor
    static func observe(on manager: PolarManager, into observers: NotificationTokens) {
        observers.add(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main,
            using: { [weak manager] in handle($0, manager: manager) }
        ))
    }

    /// Reads the reason and the previous route off-actor — both are plain
    /// values — then hops before anything touches the manager's isolated
    /// state. Reading it immediately is an isolation error under strict
    /// concurrency.
    private static func handle(_ notification: Notification, manager: PolarManager?) {
        let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let previous = (notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
            as? AVAudioSessionRouteDescription).map { describeRoute($0) } ?? "unknown"
        Task { @MainActor in
            guard let manager else { return }
            log(reasonRaw: reasonRaw, previous: previous, manager: manager)
        }
    }

    /// Silent unless the strap is actually live — a route change with no
    /// session running is just the phone being a phone.
    @MainActor
    private static func log(reasonRaw: UInt, previous prev: String, manager: PolarManager) {
        guard manager.isStreaming || manager.connectionState == .connected else { return }
        let curr = describeRoute(AVAudioSession.sharedInstance().currentRoute)
        debugLog("[PolarManager] Audio route changed during streaming — reason=\(reasonName(reasonRaw)), previous=\(prev), current=\(curr) (will tolerate any transient BLE drop within reconnect window)")
    }

    private static func reasonName(_ raw: UInt) -> String {
        switch AVAudioSession.RouteChangeReason(rawValue: raw) {
        case .newDeviceAvailable: "newDeviceAvailable"
        case .oldDeviceUnavailable: "oldDeviceUnavailable"
        case .categoryChange: "categoryChange"
        case .override: "override"
        case .wakeFromSleep: "wakeFromSleep"
        case .noSuitableRouteForCategory: "noSuitableRouteForCategory"
        case .routeConfigurationChange: "routeConfigurationChange"
        case .unknown, .none: "unknown"
        @unknown default: "raw=\(raw)"
        }
    }

    /// Port type + name, comma-joined. Enough to identify AirPods against a
    /// speaker without printing the whole route description.
    nonisolated static func describeRoute(_ route: AVAudioSessionRouteDescription) -> String {
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }
        var parts: [String] = []
        if !outputs.isEmpty { parts.append("out=[\(outputs.joined(separator: ","))]") }
        if !inputs.isEmpty { parts.append("in=[\(inputs.joined(separator: ","))]") }
        return parts.isEmpty ? "(none)" : parts.joined(separator: " ")
    }
}
