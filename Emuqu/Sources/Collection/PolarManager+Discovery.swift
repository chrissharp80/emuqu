import Foundation

// BLE scanning and connect/disconnect live on `StrapDiscoveryCoordinator`.

extension PolarManager {
    /// Built on demand from the parts it uses. The SDK handle is created on
    /// the first scan or connect; the closure holds the manager weakly, so the
    /// coordinator never keeps it alive.
    var discovery: StrapDiscoveryCoordinator {
        StrapDiscoveryCoordinator(
            link: link, found: discoveryResults, pairings: pairings,
            prepareRadio: { [weak self] in self?.ensureApiReady() }
        )
    }
}
