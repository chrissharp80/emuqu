@testable import Emuqu
import XCTest

// MARK: - Shared Test Data Generators

/// Create realistic RR points with sine-wave variability (deterministic).
/// - Parameters:
///   - count: Number of RR points to generate.
///   - meanRR: Mean RR interval in milliseconds (default 800).
///   - startMs: Starting timestamp in milliseconds (default 0).
/// - Returns: Array of RRPoint with physiologically clamped intervals.
func createRealisticPoints(count: Int, meanRR: Int = 800, startMs: Int64 = 0) -> [RRPoint] {
    var points: [RRPoint] = []
    var tMs = startMs
    for i in 0 ..< count {
        let variation = Int(sin(Double(i) / 50.0) * 40)
        let rr = max(300, meanRR + variation)
        points.append(RRPoint(t_ms: tMs, rr_ms: rr))
        tMs += Int64(rr)
    }
    return points
}

/// Create uniform RR points (no variability).
/// - Parameters:
///   - count: Number of RR points to generate.
///   - rrMs: Fixed RR interval in milliseconds (default 800).
/// - Returns: Array of RRPoint with identical intervals.
func createUniformPoints(count: Int, rrMs: Int = 800) -> [RRPoint] {
    (0 ..< count).map { i in
        RRPoint(t_ms: Int64(i) * Int64(rrMs), rr_ms: rrMs)
    }
}

/// Build clean artifact flags for every point.
/// - Parameter count: Number of flags to generate.
/// - Returns: Array of clean ArtifactFlags.
func cleanFlags(count: Int) -> [ArtifactFlags] {
    Array(repeating: ArtifactFlags.clean, count: count)
}

// MARK: - Language

extension XCTestCase {
    /// Sets the app's language to English for the rest of this test and
    /// registers a teardown that puts the previous choice back.
    ///
    /// Copy reaches the screen through `LanguageManager.appBundle`, which
    /// follows the host's language unless the user picked one. A test that
    /// asserts English text, or renders a snapshot reference recorded in
    /// English, calls this first so it passes on a host set to any language.
    @MainActor
    func pinEnglishLanguage() {
        guard LanguageManager.appLocale.language.languageCode != .english else { return }
        let original = AppLanguage.current
        LanguageManager.shared.setLanguage(.en)
        addTeardownBlock { @MainActor in LanguageManager.shared.setLanguage(original) }
    }
}
