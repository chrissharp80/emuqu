import CoreLocation
import Foundation

// The HealthKit, subscription and live-coaching fact namespaces, split out of
// `AppFactResolver+Settings.swift`. Settings and web-search stay
// behind; these three answer questions about the user's health store,
// entitlement, and in-workout coaching state.

// MARK: - app.healthkit.* namespace
struct AppHealthKitNamespace: FactNamespaceResolver {
    let namespace = "app"

    var entries: [FactEntry] {
        [
            appHealthkitAvailableEntry,
            appHealthkitHeartRateLatestEntry,
            appHealthkitTodayActivityEntry,
            appHelpLookupTopicEntry
        ]
    }

    private var appHealthkitAvailableEntry: FactEntry {
        .fixed(
            key: "app.healthkit.available",
            description: "Whether HealthKit is available on this device. False on the simulator and on devices where Apple's framework is missing.",
            valueType: "Bool"
        ) {
            .boolean(AppDependencies.current.collection.healthKitManager.isHealthKitAvailable)
        }
    }

    // call "current."
    // Idle HR query (no active workout). User
    // request: "I'd like the app to know my HR from my Watch
    // if I don't have a strap." During a workout the live HR
    // is already on `workout.live.hr` (which falls back to
    // Watch wrist HR when the strap is silent). Outside a
    // workout, the AI had no path to the most recent HR
    // sample at all — only the static resting-HR setting.
    // This fact reads the most recent HR sample HealthKit has
    // (typically Watch wrist HR, sometimes phone-paired strap
    // history, occasionally manual entry). 24-hour lookback
    // window is wide enough to catch a sample even from a
    // user who hasn't worn the Watch all day; tight enough
    // that we don't return data the user would no longer
    private var appHealthkitHeartRateLatestEntry: FactEntry {
        .fixedAsync(
            key: "app.healthkit.heart_rate_latest",
            description: Self.appHealthkitHeartRateLatestDescription,
            valueType: "Record"
        ) { await self.resolveAppHealthkitHeartRateLatest() }
    }

    @MainActor private func resolveAppHealthkitHeartRateLatest() async -> FactValue {
        guard AppDependencies.current.collection.healthKitManager.isHealthKitAvailable else {
            return .missing(reason: .notRecorded, detail: "HealthKit not available on this device")
        }
        let now = Date()
        let fetched = await fetchedHeartRateSamples(since: now.addingTimeInterval(-24 * 60 * 60))
        if case let .failure(error)? = fetched {
            return .missing(reason: .notRecorded, detail: "HealthKit query failed: \(error.localizedDescription)")
        }
        // A timeout yields nil — same shape the semaphore path
        // left behind (empty result), handled by the guard below.
        let samples: [HeartRateSample]
        if case let .success(fetchedSamples)? = fetched { samples = fetchedSamples } else { samples = [] }
        guard let last = samples.max(by: { $0.date < $1.date }) else {
            return .missing(reason: .notRecorded, detail: "no HR samples in the last 24 hours")
        }
        return .record([
            "bpm": .integer(Int(last.hr.rounded())),
            "source": .string(last.source),
            "age_seconds": .integer(Int(now.timeIntervalSince(last.date)))
        ])
    }

    // Suspending fetch, not a semaphore
    // bridge. 3 s ceiling; a thrown
    // HealthKit error reports the query failure; a timeout
    // falls through to the same "no samples" envelope the
    // empty-result path produced.
    @MainActor private func fetchedHeartRateSamples(
        since dayAgo: Date
    ) async -> Result<[HeartRateSample], Error>? {
        let now = Date()
        return await FactResolveTimeout.withTimeout(seconds: 3) {
            do {
                return .success(try await AppDependencies.current.collection.healthKitManager.fetchHeartRateSamplesDetailed(from: dayAgo, to: now))
            } catch {
                return .failure(error)
            }
        }
    }

    private static let appHealthkitHeartRateLatestDescription = """
    Most recent heart rate reading from Apple Health (Watch wrist HR, paired strap history, or manual entry — whichever HealthKit has most recently). Returns the bpm value, the source name (e.g. 'Apple Watch', 'Polar H10'), \
    and how many seconds ago the sample was captured. Use when the user asks 'what's my HR right now' or 'what was my HR 5 minutes ago' OUTSIDE an active workout. Inside a workout, prefer `get_workout_live(field:'hr')` — that's \
    the live snapshot. Returns notRecorded when nothing has been written to HealthKit in the last 24 hours.
    """

    // existing weekly/monthly recovery context.
    // Idle activity rollup (steps, walking
    // distance, flights climbed for today). User request:
    // "whatever the watch knows that we can query." Apple
    // Health already aggregates these from any source (Watch,
    // iPhone CMPedometer, third-party apps) so we just read
    // and return. Today-only — for trends the AI can use the
    private var appHealthkitTodayActivityEntry: FactEntry {
        .fixedAsync(
            key: "app.healthkit.today_activity",
            description: Self.appHealthkitTodayActivityDescription,
            valueType: "Record"
        ) { await self.resolveAppHealthkitTodayActivity() }
    }

    @MainActor private func resolveAppHealthkitTodayActivity() async -> FactValue {
        guard AppDependencies.current.collection.healthKitManager.isHealthKitAvailable else {
            return .missing(reason: .notRecorded, detail: "HealthKit not available on this device")
        }
        // Suspending fetch, not a semaphore
        // bridge. 3 s ceiling; nil on timeout lands in the
        // same "rollup unavailable" envelope.
        let summary: HealthKitManager.DailyActivity? =
            await FactResolveTimeout.withTimeout(seconds: 3) {
                await AppDependencies.current.collection.healthKitManager.fetchDailyActivity(days: 1).first
            }
        guard let summary else {
            return .missing(reason: .notRecorded, detail: "today's activity rollup unavailable")
        }
        return .record([
            "step_count": .integer(summary.stepCount),
            "walking_running_distance_meters": .double(summary.distanceMeters),
            "flights_climbed": .integer(summary.flightsClimbed)
        ])
    }

    private static let appHealthkitTodayActivityDescription = """
    Today's HealthKit activity rollup: total step count, total walking/running distance (meters), and total flights climbed (CMPedometer staircase detection — does NOT capture gradual outdoor elevation gain). All values aggregated \
    across every source HealthKit knows about (Apple Watch, iPhone, third-party apps). Use when the user asks 'how many steps today', 'how far have I walked', 'how many flights have I done' — works without an active workout. \
    Returns notRecorded only when HealthKit itself is unavailable.
    """

    // documentation cost.
    // On-demand app help lookup. The full
    // AppKnowledgeBase.reference (~2,800 tokens) would otherwise ride
    // in every cloud-provider system prompt even on turns that
    // only ask "what's my TSB". The prompt carries the compact
    // 304-token form by default and the full reference is exposed
    // through this tool so coaching questions don't pay the
    private var appHelpLookupTopicEntry: FactEntry {
        .parameterized(
            pattern: "app.help.lookup($topic)",
            paramExample: "recovery_score",
            description: """
            On-demand section of the Emuqu app reference manual. Call when the user asks an app-feature, metric-explanation, or navigation question (\"what does DFA mean\", \"how do I export\", \"where's the Coach tab\", \"what's pNN50\"). \
            Valid topics: tabs, recovery_score, modes, hrv_session_flow, workout_flow, hr_zones, voice_coach, exports, metrics, settings, navigation, capabilities, scope, all. Returns the matching section as a plain-text string. Use \
            'all' to get the entire reference at once (large — only when the user asks a broad 'tell me about the app' question).
            """,
            resolve: { topic, _ in
                .string(AppKnowledgeBase.lookup(topic: topic))
            }
        )
    }
}
