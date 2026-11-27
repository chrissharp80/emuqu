import SwiftUI

// MARK: - SwiftUI environment

/// Computed, not a stored snapshot: a view that has no injected value reads
/// whatever `AppDependencies.current` holds at that moment, so a container
/// swapped in by a test reaches views too.
private struct DependenciesKey: EnvironmentKey {
    static var defaultValue: AppDependencies { AppDependencies.current }
}

extension EnvironmentValues {
    /// The services a view reads. Nothing injects it, so views get
    /// `AppDependencies.current`; a preview or test can still override it
    /// with `.environment(\.dependencies, ...)`.
    var dependencies: AppDependencies {
        get { self[DependenciesKey.self] }
        set { self[DependenciesKey.self] = newValue }
    }
}
