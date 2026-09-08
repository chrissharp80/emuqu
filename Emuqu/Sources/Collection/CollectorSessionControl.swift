import Foundation

/// Driving a capture session while it runs: the short streaming sessions, the
/// pause/resume path that lets a night be split and rejoined, and the Combine
/// bindings that republish the sub-objects' state for the views.
///
/// ## Why this is not on `RRCollector`
///
/// As extensions it would add 1,012 lines to the collector.
///
/// All three live together because pause/resume and the streaming session are
/// the same state machine seen from two directions, and the bindings republish
/// exactly what those two change.
///
/// The Combine sinks below capture `[weak collector]`: they are stored in the
/// collector's own `cancellables`, so a strong capture would be a cycle and a
/// weak one is exactly right — each no-ops once the collector is gone.
///
/// ## Ownership
///
/// This is a value, built on demand by the collector (`collector.control`),
/// holding the collector strongly. A class with an `unowned` back-pointer
/// is safe on every synchronous path and fatal on the asynchronous one: a
/// Task or a resumed continuation that keeps this object alive after the
/// collector has gone reads the reference and traps ("Attempted to read an
/// unowned reference but object … was already destroyed"). A strong
/// reference from a transient value cannot
/// outlive its owner and cannot form a cycle, so the class of bug is gone;
/// `scripts/check_no_unowned.sh` keeps it gone.
@MainActor
struct CollectorSessionControl {
    let collector: RRCollector

}
