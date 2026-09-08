import Foundation
import Observation

/// A self-re-arming observation of `@Observable` state, with a handle to stop it.
///
/// `withObservationTracking` is one-shot: it fires once, before the mutation,
/// and must be armed again. This wraps that into "run this on the main actor
/// every time these properties change, for as long as the owner lives" —
/// without a publisher.
@MainActor
final class ObservationHandle {
    private(set) var isCancelled = false

    /// Stops the loop after the observation currently armed has fired.
    func cancel() { isCancelled = true }
}

@MainActor
enum ObservationLoop {
    /// Calls `onChange` with the freshly read value each time the observable
    /// state read by `read` changes. Delivery happens on the main actor after
    /// the mutation, like Combine's `.receive(on: DispatchQueue.main)` did.
    ///
    /// - Parameter initial: also deliver the current value once, immediately,
    ///   which is what a `@Published` publisher did on subscription. Leave it
    ///   `false` for the sites that used `.dropFirst()`.
    ///
    /// The loop holds `owner` weakly and ends on its own when the owner is
    /// released, so a discarded handle is fine for a lifetime binding. Owners
    /// are main-actor classes, which is what makes them `Sendable` here.
    @discardableResult
    static func observe<Owner: AnyObject & Sendable, Value>(
        _ owner: Owner,
        initial: Bool = false,
        read: @escaping @MainActor @Sendable (Owner) -> Value,
        onChange: @escaping @MainActor @Sendable (Owner, Value) -> Void
    ) -> ObservationHandle {
        let handle = ObservationHandle()
        if initial { deliverInitial(owner, handle: handle, read: read, onChange: onChange) }
        arm(owner, handle: handle, read: read, onChange: onChange)
        return handle
    }

    /// Deferred one hop, like Combine's `.receive(on: .main)` replay was, so
    /// an injected initial state is not overwritten mid-initialiser.
    private static func deliverInitial<Owner: AnyObject & Sendable, Value>(
        _ owner: Owner,
        handle: ObservationHandle,
        read: @escaping @MainActor @Sendable (Owner) -> Value,
        onChange: @escaping @MainActor @Sendable (Owner, Value) -> Void
    ) {
        Task { @MainActor [weak owner] in
            guard let owner, !handle.isCancelled else { return }
            onChange(owner, read(owner))
        }
    }

    private static func arm<Owner: AnyObject & Sendable, Value>(
        _ owner: Owner,
        handle: ObservationHandle,
        read: @escaping @MainActor @Sendable (Owner) -> Value,
        onChange: @escaping @MainActor @Sendable (Owner, Value) -> Void
    ) {
        withObservationTracking {
            _ = read(owner)
        } onChange: { [weak owner] in
            Task { @MainActor in fire(owner, handle: handle, read: read, onChange: onChange) }
        }
    }

    /// One delivery, then re-arm — unless the owner is gone or the handle was cancelled.
    private static func fire<Owner: AnyObject & Sendable, Value>(
        _ owner: Owner?,
        handle: ObservationHandle,
        read: @escaping @MainActor @Sendable (Owner) -> Value,
        onChange: @escaping @MainActor @Sendable (Owner, Value) -> Void
    ) {
        guard let owner, !handle.isCancelled else { return }
        onChange(owner, read(owner))
        arm(owner, handle: handle, read: read, onChange: onChange)
    }
}
