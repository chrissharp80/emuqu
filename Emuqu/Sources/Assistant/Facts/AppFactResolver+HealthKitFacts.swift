import CoreLocation
import Foundation

// The `app.healthkit.*` facts (HealthKit availability, last known heart rate,
// today's activity) and the on-demand `app.help.lookup` reference section.

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

    // Last known HR outside a workout: the newest HealthKit heart-rate
    // sample from the past 24 hours (usually Watch wrist HR, sometimes strap
    // history or a manual entry). `vitals.hr_now` answers "right now" with a
    // 10-minute window; this one answers "what was my last reading" and
    // reports the sample's age so an hours-old value is never passed off as
    // current.
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
        // A timeout yields nil, handled by the guard below as "no samples".
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

    // 3 s ceiling. A thrown HealthKit error reports the query failure; a
    // timeout returns nil, which the caller treats as "no samples".
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
    Last known heart rate in Apple Health from the past 24 hours (Watch wrist HR, paired strap history, or manual entry). Returns the bpm value, the source name (e.g. 'Apple Watch', 'Polar H10'), and age_seconds, how long ago \
    the sample was captured; always state that age, since it can be hours old. For 'what's my HR right now' use `vitals.hr_now` (last 10 minutes only); use this for 'what was my last HR reading' or when vitals.hr_now has \
    nothing. Inside a workout, prefer `get_workout_live(field:'hr')`. Returns notRecorded when nothing has been written to HealthKit in the last 24 hours.
    """

    // Today's activity rollup (steps, walking distance, flights climbed).
    // Apple Health already aggregates these across every source (Watch,
    // iPhone pedometer, third-party apps), so this reads and returns them.
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
        // 3 s ceiling; nil on timeout lands in the "rollup unavailable" envelope.
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

    // On-demand app help lookup. The prompt carries only the compact app
    // reference; this tool returns a section of the full
    // `AppKnowledgeBase.reference` when a question needs it, so turns that
    // never ask about the app don't pay for the whole manual.
    private var appHelpLookupTopicEntry: FactEntry {
        .parameterized(
            pattern: "app.help.lookup($topic)",
            paramExample: "recovery_score",
            description: """
            On-demand section of the Emuqu app reference manual. Call when the user asks an app-feature, metric-explanation, or navigation question (\"what does DFA mean\", \"how do I export\", \"where's the Fitness tab\", \"what's pNN50\"). \
            Valid topics: tabs, recovery_score, modes, hrv_session_flow, workout_flow, hr_zones, voice_coach, exports, metrics, settings, navigation, capabilities, scope, all. Returns the matching section as a plain-text string. Use \
            'all' to get the entire reference at once (large — only when the user asks a broad 'tell me about the app' question).
            """,
            resolve: { topic, _ in
                .string(AppKnowledgeBase.lookup(topic: topic))
            }
        )
    }
}
