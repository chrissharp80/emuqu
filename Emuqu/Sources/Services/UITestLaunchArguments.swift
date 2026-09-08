import Foundation

/// Launch arguments the UI suites pass to reach surfaces a fresh Debug
/// install cannot reach on its own. Each is a no-op unless the argument is
/// present, and all of it is compiled out of Release: a store binary has no
/// way to bypass its entitlement or plant a reading.
///
/// `-UITests-FreshInstall` (handled in `AppLaunchRecovery`) wipes state so a
/// run starts as a new install. That leaves two screens unreachable: the
/// paywall, because a Debug build is a developer install with permanent
/// access, and History, whose only entry point needs one reading in the
/// archive. Tests that skipped on those conditions never ran; these arguments
/// make the conditions true instead.
enum UITestLaunchArguments {
    /// The launch gate treats the run as having no entitlement, so the
    /// paywall presents after onboarding exactly as it does for a store
    /// install whose trial has ended.
    static var forcesPaywall: Bool { isPresent("-UITests-ForcePaywall") }

    /// One synthetic overnight reading is scored by the real morning pipeline
    /// and archived before the first screen, so the dashboard shows the
    /// Recent strip and History has its entry point.
    static var seedsArchive: Bool { isPresent("-UITests-SeedArchive") }

    private static func isPresent(_ argument: String) -> Bool {
        #if DEBUG
            return CommandLine.arguments.contains(argument)
        #else
            return false
        #endif
    }
}

#if DEBUG
    /// Plants one overnight reading through the same path a real night takes:
    /// synthetic RR intervals in, `RRCollector.processOvernightData` scores
    /// them, and the result is archived. Nothing here bypasses the analysis.
    enum UITestArchiveSeed {
        /// Six hours at a resting rate near 63 bpm, with slow respiratory-band
        /// modulation and beat-to-beat jitter, so artifact detection, window
        /// selection and the DFA fit all see plausible data. Deterministic: a
        /// fixed-seed generator, so every run scores the same night.
        static func syntheticOvernightPoints(hours: Double = 6) -> [RRPoint] {
            var generator = SeededGenerator(seed: 0x5EED_2026)
            var points: [RRPoint] = []
            var tMs: Int64 = 0
            let endMs = Int64(hours * 3_600_000)
            while tMs < endMs {
                let seconds = Double(tMs) / 1000
                let respiratory = 40 * sin(2 * .pi * seconds / 4.2)
                let slowDrift = 60 * sin(2 * .pi * seconds / 5_400)
                let jitter = Double(Int(generator.next() % 41)) - 20
                let rr = max(600, min(1_300, Int((950 + respiratory + slowDrift + jitter).rounded())))
                tMs += Int64(rr)
                points.append(RRPoint(t_ms: tMs, rr_ms: rr))
            }
            return points
        }

        @MainActor
        static func plantIfRequested(into collector: RRCollector) async {
            guard UITestLaunchArguments.seedsArchive, collector.archive.index.isEmpty else { return }
            let points = syntheticOvernightPoints()
            // Background-refinement mode: the sleep-boundary poll makes one
            // HealthKit attempt instead of fifteen, since no Watch will ever
            // deliver data to a test simulator, and no status is shown.
            let session = await collector.processOvernightData(
                points: points, baseSession: baseSession(ending: Date(), points: points),
                dataSource: "streaming", reconnectCount: 0, streamingBeats: points.count,
                isBackgroundRefinement: true
            )
            archive(session, into: collector)
        }

        private static func baseSession(ending end: Date, points: [RRPoint]) -> HRVSession {
            let start = end.addingTimeInterval(-Double(points.last?.t_ms ?? 0) / 1000)
            return HRVSession(
                id: UUID(), startDate: start, endDate: end,
                state: .analyzing, sessionType: .overnight,
                rrSeries: nil, analysisResult: nil, artifactFlags: nil,
                deviceProvenance: nil, linkedSessionIds: nil, pausedDate: nil
            )
        }

        @MainActor
        private static func archive(_ session: HRVSession, into collector: RRCollector) {
            do {
                _ = try collector.archive.archive(session)
                NSLog("[App][launch] -UITests-SeedArchive — planted one scored overnight reading")
            } catch {
                NSLog("[App][launch] -UITests-SeedArchive could not archive the seed: \(error.localizedDescription)")
            }
        }

        /// A small linear congruential generator; the standard library's
        /// generator cannot be seeded.
        private struct SeededGenerator: RandomNumberGenerator {
            private var state: UInt64
            init(seed: UInt64) { state = seed }
            mutating func next() -> UInt64 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return state >> 33
            }
        }
    }
#endif
