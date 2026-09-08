import Foundation

/// Re-scoring sessions that are already archived: a settings change that should
/// apply retroactively, a manually chosen window, sleep data that arrived after
/// the night was scored, and the listeners that notice those events.
///
/// ## Why this is not on `RRCollector`
///
/// As a 612-line extension it would be, on the largest type in the
/// codebase.
///
/// Reanalysis is the archive's editor, not the recorder's: it never touches a
/// live capture. The coupling was measured before the move rather than assumed —
/// 29 collector members, mostly the archive, the settings and the analysis
/// pipeline it re-runs.
///
/// The twelve `[weak self]` captures inside are provider closures of the shape
/// `{ [weak self] in self?.something ?? fallback }`, handed to `ReanalysisService`
/// so it can read current settings without holding the collector. They now
/// weakly hold this object; equivalent, because the collector is the only strong
/// reference and every one already falls back on a nil self.
///
/// Holds its owner strongly and is built on demand by the collector — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct SessionReanalysisCoordinator {
    let collector: RRCollector

}
