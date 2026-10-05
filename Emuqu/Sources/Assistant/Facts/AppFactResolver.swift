import CoreLocation
import Foundation
import os
#if canImport(CoreMotion)
    import CoreMotion
#endif

// MARK: - AppFactResolver
//
// Composition root for every fact namespace. Instantiate with
// references to the app's data sources and the returned
// `FactResolverRegistry` answers any key from any surface. Queries
// fan out by first-token namespace (O(1)) then walk the namespace's
// declarative entry list.
//
// Adding a new namespace is one line in `build()`. Adding a new fact
// within a namespace is one new entry in its `entries` list.
//
// **Concurrency contract.**
// Fact resolution runs on the MainActor — `AssistantViewModel` is
// @MainActor, the chat tool-dispatch path stays on it, and the AI
// provider's tool_use callback hops back to main before invoking
// `resolveTool`. That's why every `MainActor.assumeIsolated { ... }`
// inside this file is safe: the caller is always already on main.
//
// The tool path is ASYNC on the main actor.
// `FactResolverRegistry.resolveTool` / `resolveAsync` (and
// `CompactToolRouter.resolveTool`) are `@MainActor` + `async`. The
// ~226 in-memory/archive resolvers are synchronous
// closures (`FactResolveBody.sync`) and run inline on main.
// The handful of resolvers that genuinely
// wait on the outside world (Tavily search, HealthKit reads,
// Overpass/OSM fetches, CLGeocoder, cold GPS) are declared via
// `.fixedAsync` / `.actionAsync` (`FactResolveBody.awaitable`): their
// closures are `@MainActor` and SUSPEND the actor on
// `FactResolveTimeout.withTimeout(seconds:)` races — budgets and
// timeout fallbacks without a DispatchSemaphore main-thread park,
// which produces the App Watchdog kill signature (a workout
// terminated mid-session in the field).
//
// The synchronous `resolve(_:)` walk still exists for composite bodies,
// which read their children through it. On the async tool path a
// composite's declared dependencies are awaited first and served from
// `FactResolverRegistry.withPrefetchedChildren`, so async children
// (sleep, vitals, profile reads) arrive with real values. If the sync
// walk ever lands on an undeclared async-only entry it returns
// `FactEntry.syncPathUnavailable(key:)` (an `.internalError` missing
// envelope) — it never blocks and never traps. If dispatch ever moves
// off main (background thread, actor migration), the assumeIsolated
// calls will start crashing under strict concurrency — at that point
// convert TrainingMetricsCache / RoadGeocodingService snapshot reads
// to nonisolated, OR pass pre-resolved snapshots into the resolvers
// at build time.
//
// **Archive reads.** Fact resolvers read sessions through
// `archive.retrieveLightweight(_:)` — the same
// session decode minus the rrSeries Codable round-trip (~45× faster
// per session). Fact resolvers compute over `analysisResult`,
// `vitalsSnapshot`, `workoutMetadata`, etc.; none of which need the
// raw beat-stream. A "what were my last 10 workouts" query drops
// from 50ms+ resolve time to <1ms.
/// Shared period vocabulary for every namespace that takes a `$period`
/// parameter. The previous implementation had six separate copies that
/// each accepted a different subset of tokens — so a tool description
/// promising "7d / 30d / this_week" silently returned an empty list
/// when the model used those tokens against a parser that only knew
/// `last_7d`. Funneling all callers here closes that gap.
///
/// Accepted vocabulary (case-insensitive, leading "last_" optional):
///   • numeric: 7d, 14d, 30d, 60d, 90d, 180d, 365d
///   • named: today, yesterday, this_week, last_week, last_2_weeks,
///             last_month, last_quarter, last_year, all_time
///
/// `cutoff(for:)` returns only the start of the period; entries on or
/// after it are "in period". today / yesterday / this_week anchor on
/// calendar days (this_week = the start of the current week, using the
/// locale's first weekday); every other token is a rolling window back
/// from now. A start alone can't express a period that ends in the past,
/// so `interval(for:)` adds the end: yesterday ends at today's start and
/// last_week is the previous calendar week. Fact filters use
/// `interval(for:)`.
enum PeriodParser {
    /// Fast-path first: a single- or double-digit number of days that
    /// the named cases below don't catch (e.g. "2d", "3_days",
    /// "last_4d"). Without it, the AI's "what was my RMSSD the
    /// last 2 nights" question goes through `hrv.recent(2d)` →
    /// PeriodParser returns nil → resolver returns `.missing` → AI
    /// tells the user "I don't have the RMSSD numbers for the last
    /// two days right now".
    static func cutoff(for raw: String, now: Date = Date()) -> Date? {
        let cal = Calendar.current
        let key = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let days = Self.numericDayWindow(key) {
            return cal.date(byAdding: .day, value: -days, to: now)
        }
        switch key {
        case "today": return cal.startOfDay(for: now)
        case "yesterday": return cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))
        case "this_week": return cal.dateInterval(of: .weekOfYear, for: now)?.start
        case "all_time", "all": return .distantPast
        default:
            guard let days = Self.namedDayWindows[key] else { return nil }
            return cal.date(byAdding: .day, value: -days, to: now)
        }
    }

    /// Named period aliases → how many days back they reach.
    private static let namedDayWindows: [String: Int] = [
        "last_week": 7, "last_7d": 7, "7d": 7, "last_7_days": 7, "7_days": 7,
        "last_14d": 14, "14d": 14, "last_2_weeks": 14, "2_weeks": 14,
        "last_30d": 30, "30d": 30, "last_month": 30, "month": 30,
        "last_60d": 60, "60d": 60,
        "last_90d": 90, "90d": 90, "last_quarter": 90, "quarter": 90,
        "last_180d": 180, "180d": 180,
        "last_365d": 365, "365d": 365, "last_year": 365, "year": 365
    ]

    /// Start and end of the period. Same vocabulary as `cutoff(for:)`;
    /// the end is `now` except for `yesterday` (ends at the start of
    /// today) and `last_week` (the previous calendar week, so it never
    /// overlaps `this_week`).
    static func interval(for raw: String, now: Date = Date()) -> DateInterval? {
        let cal = Calendar.current
        let key = raw.lowercased().trimmingCharacters(in: .whitespaces)
        switch key {
        case "yesterday":
            let today = cal.startOfDay(for: now)
            guard let start = cal.date(byAdding: .day, value: -1, to: today) else { return nil }
            return DateInterval(start: start, end: today)
        case "last_week":
            guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: now),
                  let start = cal.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start)
            else { return nil }
            return DateInterval(start: start, end: thisWeek.start)
        default:
            guard let start = cutoff(for: raw, now: now), start <= now else { return nil }
            return DateInterval(start: start, end: now)
        }
    }

    /// Extract N from any of these shapes — `Nd`, `last_Nd`, `N_days`,
    /// `last_N_days`. Returns nil when the token doesn't match. It runs
    /// before the named lookup in `cutoff(for:)`, so `7d` / `30d` etc.
    /// resolve here; the named table only adds the word aliases
    /// (last_week, last_month, …).
    private static func numericDayWindow(_ key: String) -> Int? {
        let trimmed = key.replacingOccurrences(of: "last_", with: "")
        let candidates = [trimmed,
                          trimmed.replacingOccurrences(of: "_days", with: "d"),
                          trimmed.replacingOccurrences(of: "_day", with: "d")]
        for c in candidates where c.hasSuffix("d") {
            let digits = c.dropLast()
            if let n = Int(digits), (1 ... 365).contains(n) {
                return n
            }
        }
        return nil
    }
}

enum AppFactResolverFactory {
    /// Build a fully-populated registry. The caller hands in the
    /// singletons / repositories it already uses elsewhere (no service
    /// location inside fact code — per refactor spec's explicit
    /// dependency wiring rule).
    ///
    /// Composites go LAST so their dependencies (every atomic namespace) are
    /// already registered. Composite resolvers call back into the registry to
    /// fetch children, so the ordering is a correctness requirement: the
    /// registry has to hold every namespace a composite touches before
    /// `resolve()` runs.
    static func build(
        archive: SessionArchive,
        settings: @escaping @Sendable () -> UserSettings
    ) -> FactResolverRegistry {
        let registry = FactResolverRegistry()
        registerHealthNamespaces(on: registry, archive: archive, settings: settings)
        registerAppNamespaces(on: registry, archive: archive, settings: settings)
        registry.register(CompositesNamespace())
        return registry
    }

    /// The user's own recorded data: sessions, load, sleep, HRV, workouts.
    private static func registerHealthNamespaces(
        on registry: FactResolverRegistry,
        archive: SessionArchive,
        settings: @escaping @Sendable () -> UserSettings
    ) {
        registry.register(UserProfileNamespace(settings: settings))
        registry.register(SessionNamespace(archive: archive, settings: settings))
        registry.register(WalksNamespace(archive: archive))
        registry.register(TrainingLoadNamespace(archive: archive, settings: settings))
        registry.register(HeatAcclimationNamespace())
        registry.register(SleepNamespace(archive: archive, settings: settings))
        registry.register(HRVNamespace(archive: archive))
        registry.register(VitalsNamespace(archive: archive))
        registry.register(RecoveryNamespace(archive: archive))
        registry.register(BaselineNamespace(archive: archive))
        registry.register(WorkoutNamespace(archive: archive))
        registry.register(WorkoutLiveNamespace(archive: archive))
        registry.register(WorkoutLiveCoachingNamespace())
        registry.register(HRVLiveNamespace())
        registry.register(HRRNamespace(archive: archive))
        registry.register(TagsNamespace(archive: archive))
    }

    /// App state, device state, and the action-capable surfaces.
    private static func registerAppNamespaces(
        on registry: FactResolverRegistry,
        archive: SessionArchive,
        settings: @escaping @Sendable () -> UserSettings
    ) {
        registry.register(AppCapabilitiesNamespace())
        registry.register(RoutesLibraryNamespace(archive: archive))
        registry.register(AppNowNamespace())
        registry.register(AppDevicesNamespace())
        registry.register(AppSettingsNamespace(settings: settings))
        registry.register(AppHealthKitNamespace())
        registry.register(AssistantMemoryNamespace())
        registry.register(WebSearchNamespace())
        registry.register(BreadcrumbNamespace())
    }
}

// MARK: - user.* namespace

struct UserProfileNamespace: FactNamespaceResolver {
    let namespace = "user"
    let settings: @Sendable () -> UserSettings

    var entries: [FactEntry] {
        [
            userProfileEntries,
            userSettingsEntries,
            userProfileEntries2
        ]
        .flatMap { $0 }
    }

    private var userProfileEntries: [FactEntry] {
        [
            userProfileMaxHrEntry,
            userProfileRestingHrEntry,
            userProfileLthrEntry,
            userProfileMaxHrIsUserSetEntry,
            userProfileLthrIsUserSetEntry,
            userProfileWeightKgEntry,
            userProfileBiologicalSexEntry,
            userProfileAgeEntry
        ]
    }

    private var userSettingsEntries: [FactEntry] {
        [
            userSettingsUnitsEntry,
            userSettingsTypicalSleepHoursEntry,
            userSettingsOnTrainingBreakEntry,
            // Comeback-mode + algorithm-version facts
            // so the AI can answer questions like "why does my Vitals
            // factor say 0%?" or "why did my score change last week?"
            userSettingsComebackModeActiveEntry,
            userSettingsComebackModeDayInWindowEntry,
            scoreAlgorithmVersionEntry,
            scoreHistoryRecomputedUnderV2Entry
        ]
    }

    private var userProfileEntries2: [FactEntry] {
        [
            userProfileVo2MaxEntry,
            userProfileVo2MaxIsOverrideEntry,
            userProfileUsesHealthkitVo2maxEntry,
            userProfileVo2MaxTrendEntry
        ]
    }

    private var userProfileMaxHrEntry: FactEntry {
        .fixed(key: "user.profile.max_hr", description: "User's physiological max HR (override, else Tanaka 208 − 0.7 × age, else 180 with no birthday). bpm.", valueType: "Int") {
            .integer(self.settings().effectiveMaxHR)
        }
    }

    private var userProfileRestingHrEntry: FactEntry {
        .fixed(key: "user.profile.resting_hr", description: "User's resting HR (baseline HR from HRV readings, 60 fallback). bpm.", valueType: "Int") {
            .integer(self.settings().effectiveRestingHR)
        }
    }

    private var userProfileLthrEntry: FactEntry {
        .fixed(key: "user.profile.lthr", description: "Lactate threshold HR (override, else 0.88 × max HR heuristic). bpm.", valueType: "Int") {
            .integer(self.settings().effectiveLTHR)
        }
    }

    private var userProfileMaxHrIsUserSetEntry: FactEntry {
        .fixed(key: "user.profile.max_hr_is_user_set", description: "Whether the user explicitly set their max HR vs relying on the age-based estimate.", valueType: "Bool") {
            // Under the field's minimum reads as unset, as in `MaxHeartRate.effective`.
            .boolean((self.settings().maxHR ?? 0) >= MaxHeartRate.minimumUserEntered)
        }
    }

    private var userProfileLthrIsUserSetEntry: FactEntry {
        .fixed(key: "user.profile.lthr_is_user_set", description: "Whether the user has tested and entered an LTHR vs using the 0.88 × max-HR default.", valueType: "Bool") {
            .boolean((self.settings().lactateThresholdHR ?? 0) >= MaxHeartRate.minimumUserEntered)
        }
    }

    private var userProfileWeightKgEntry: FactEntry {
        .fixedAsync(key: "user.profile.weight_kg", description: """
        Body weight in kg: the user's Settings → Biometrics override if set, else the latest Apple Health body-mass sample. Returns notRecorded when neither has it — then say you don't have their weight on file \
        (estimates such as calories fall back to a 75 kg default, which is not the user's weight).
        """, valueType: "Double") {
            if let override = self.settings().bodyWeightKg { return .double(override) }
            if AppDependencies.current.collection.healthKitManager.isHealthKitAvailable,
               let profile = await FactResolveTimeout.withTimeout(seconds: 3, { await AppDependencies.current.collection.healthKitManager.fetchBiometricProfile() }),
               let kg = profile.bodyWeightKg {
                return .double(kg)
            }
            return .missing(reason: .notRecorded, detail: "no weight in Settings or Apple Health; estimates use a 75 kg default")
        }
    }

    private var userProfileBiologicalSexEntry: FactEntry {
        .fixedAsync(key: "user.profile.biological_sex", description: "Biological sex used for sex-dependent physiology (Banister TRIMP k-coefficient). From Settings if set, else Apple Health. Returns notRecorded when neither has it.", valueType: "String") {
            if let raw = self.settings().biologicalSex?.rawValue { return .string(raw) }
            if AppDependencies.current.collection.healthKitManager.isHealthKitAvailable,
               let profile = await FactResolveTimeout.withTimeout(seconds: 3, { await AppDependencies.current.collection.healthKitManager.fetchBiometricProfile() }),
               let sex = profile.appBiologicalSex {
                return .string(sex.rawValue)
            }
            return .missing(reason: .notRecorded, detail: "not set in Settings or Apple Health")
        }
    }

    private var userProfileAgeEntry: FactEntry {
        .fixedAsync(key: "user.profile.age", description: "Age in years, from the user's birthday in Settings if set, else Apple Health date of birth. Returns notRecorded when neither has it.", valueType: "Int") {
            if let b = self.settings().birthday {
                return .from(Calendar.current.dateComponents([.year], from: b, to: Date()).year)
            }
            if AppDependencies.current.collection.healthKitManager.isHealthKitAvailable,
               let profile = await FactResolveTimeout.withTimeout(seconds: 3, { await AppDependencies.current.collection.healthKitManager.fetchBiometricProfile() }),
               let dob = profile.dateOfBirth {
                return .from(Calendar.current.dateComponents([.year], from: dob, to: Date()).year)
            }
            return .missing(reason: .notRecorded, detail: "no birthday in Settings or Apple Health")
        }
    }

    private var userSettingsUnitsEntry: FactEntry {
        .fixed(key: "user.settings.units", description: "Unit system for distances / paces / elevations ('metric' or 'imperial').", valueType: "String") {
            .string(UnitsPreferenceStore.current.resolved == .imperial ? "imperial" : "metric")
        }
    }

    private var userSettingsTypicalSleepHoursEntry: FactEntry {
        .fixed(key: "user.settings.typical_sleep_hours", description: "User's typical target sleep duration (from onboarding).", valueType: "Double") {
            .double(self.settings().typicalSleepHours)
        }
    }

    private var userSettingsOnTrainingBreakEntry: FactEntry {
        .fixed(key: "user.settings.on_training_break", description: "Whether the user is currently on a documented training break.", valueType: "Bool") {
            .boolean(self.settings().isOnTrainingBreak)
        }
    }

    // Lets the AI explain a score built with Comeback weights
    // without having to infer it from indirect signals.
    private var userSettingsComebackModeActiveEntry: FactEntry {
        .fixed(key: "user.settings.comeback_mode_active", description: "Whether the user has enabled Comeback mode (returning from illness/injury). When true, for 21 days from start, a recovery score that includes vitals uses HRV 80% / Sleep 20% / Vitals 0% "
            + "instead of the standard 60/25/15; a score without vitals keeps its weights, and the SpO₂ penalty still applies.", valueType: "Bool") {
            .boolean(self.settings().isComebackModeActive)
        }
    }

    private var userSettingsComebackModeDayInWindowEntry: FactEntry {
        .fixed(key: "user.settings.comeback_mode_day_in_window", description: "Day index within the 21-day Comeback-mode window (0 = first day, nil if not active). The window auto-expires on day 21.", valueType: "Int") {
            guard self.settings().isComebackModeActive,
                  let start = self.settings().comebackModeStartDate else {
                return .missing(reason: .notRecorded, detail: "comeback mode not active")
            }
            let today = Calendar.current.startOfDay(for: Date())
            let startDay = Calendar.current.startOfDay(for: start)
            if let day = Calendar.current.dateComponents([.day], from: startDay, to: today).day {
                return .from(day)
            }
            return .missing(reason: .notRecorded, detail: "could not compute day-in-window")
        }
    }

    private var scoreAlgorithmVersionEntry: FactEntry {
        .fixed(key: "score.algorithm.version", description: """
        Recovery-score algorithm version. 'v3.1.oct2026' = HRV 60% + Sleep 25% + Vitals 15% (no training-load factor; ACWR removed from the score per Impellizzeri 2020/2021). Older sessions in this user's archive may have been computed under v1 \
        (HRV 50% + Sleep 20% + Training 30%) before they ran the migration recompute.
        """, valueType: "String") {
            .string(ScoringVersion.current)
        }
    }

    private var scoreHistoryRecomputedUnderV2Entry: FactEntry {
        .fixed(key: "score.history.recomputed_under_v2", description: """
        Whether the user has run the one-shot history recompute since the v1 → v2 algorithm change. False means archived session scores still reflect the older \
        algorithm; true means the whole archive was reanalyzed under HRV/Sleep/Vitals.
        """, valueType: "Bool") {
            .boolean(self.settings().hasRunScoreHistoryRecompute)
        }
    }

    private var userProfileVo2MaxEntry: FactEntry {
        .fixed(key: "user.profile.vo2_max", description: "Effective VO2 max: the user's manual override if set, else the latest HealthKit estimate when 'use HealthKit VO2max' is enabled, else nil. ml/kg/min. Mirrors the exact value the recovery/training pipeline uses.", valueType: "Double") {
            // Match the scoring path (RRCollector / WorkoutRecorder):
            // override wins; otherwise fall back to the cached HealthKit
            // estimate when the user opted into it. Returning the override
            // ONLY leaves a user who relies on HealthKit's VO2max (no manual
            // entry) getting "I don't know your VO2 max" from the assistant
            // even though the app has the value cached.
            if let override = self.settings().vo2MaxOverride {
                return .from(override)
            }
            if self.settings().useHealthKitVO2Max,
               let hk = MainActor.assumeIsolated({ AppDependencies.current.analysis.trainingMetricsCache.snapshot() })?.vo2MaxLatest {
                return .from(hk)
            }
            return .missing(reason: .notRecorded, detail: "no VO2max override and HealthKit estimate unavailable")
        }
    }

    private var userProfileVo2MaxIsOverrideEntry: FactEntry {
        .fixed(key: "user.profile.vo2_max_is_override", description: "Whether the VO2 max value is a user override vs a HealthKit estimate.", valueType: "Bool") {
            .boolean((self.settings().vo2MaxOverride ?? 0) > 0)
        }
    }

    private var userProfileUsesHealthkitVo2maxEntry: FactEntry {
        .fixed(key: "user.profile.uses_healthkit_vo2max", description: "Whether the app falls back to HealthKit's VO2max estimate when no manual override exists.", valueType: "Bool") {
            .boolean(self.settings().useHealthKitVO2Max)
        }
    }

    // VO2max trend record. Latest reading from HealthKit + 30-day
    // delta so the AI can answer "is my fitness trending up?" with
    // real numbers. Sample count gates the AI's confidence ("based
    // on 12 samples" vs "based on 2 samples").
    private var userProfileVo2MaxTrendEntry: FactEntry {
        .fixed(
            key: "user.profile.vo2_max_trend",
            description: """
            Latest VO2max plus the 30-day change from HealthKit. Returns a record { latest, change_30_days, sample_count_30_days }. Positive change = improving fitness, negative = detraining. Use to answer 'is my fitness trending up \
            or down?' Returns notRecorded when HealthKit has no VO2max samples.
            """,
            valueType: "Record"
        ) { self.resolveUserProfileVo2MaxTrend() }
    }

    private func resolveUserProfileVo2MaxTrend() -> FactValue {
        guard let metrics = MainActor.assumeIsolated({ AppDependencies.current.analysis.trainingMetricsCache.snapshot() }),
              let latest = metrics.vo2MaxLatest
        else {
            return .missing(reason: .notRecorded, detail: "no HealthKit VO2max samples")
        }
        var rec: [String: FactValue] = [
            "latest": .double(latest),
            "sample_count_30_days": .integer(metrics.vo2MaxSampleCount30Days)
        ]
        if let change = metrics.vo2MaxChange30Days {
            rec["change_30_days"] = .double(change)
        }
        return .record(rec)
    }
}

// MARK: - app.* namespace

struct AppCapabilitiesNamespace: FactNamespaceResolver {
    let namespace = "app"
    var entries: [FactEntry] { [
        .fixed(key: "app.capabilities.has_barometer", description: "Whether this device has a barometric pressure sensor (drives elevation accuracy).", valueType: "Bool") {
            .boolean(CMAltimeterIsAvailable())
        },
        .fixed(key: "app.version.schema.workout_metadata", description: "Schema version for WorkoutMetadata (for migration / debug).", valueType: "Int") {
            .integer(WorkoutMetadata.currentSchemaVersion)
        }
    ] }
}
