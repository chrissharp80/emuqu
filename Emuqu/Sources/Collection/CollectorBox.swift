import Foundation

/// Holds the app's recording collector once it is built, for the parts that
/// ask about the live HRV recording without being handed the collector: the
/// assistant's context and device facts, and Delete All My Data's check for a
/// recording in progress. Weak, so it never extends a collector's lifetime;
/// empty until `RRCollector.makeDefault` binds it, and in tests and previews
/// that build their own collector.
@MainActor
final class CollectorBox {
    weak var collector: RRCollector?

    nonisolated init() {}
}
