import Foundation
import HealthKit

/// The app's Apple Health parts, built over one Health store: authorization,
/// the workout export backfill, the observer state, and the queries by
/// domain.
///
/// `@MainActor`, like the parts it builds. `@Observable` so views can take
/// it from the environment; the state they observe lives on
/// `authorization` and `observation`.
@Observable
@MainActor
final class HealthKitManager {
    // MARK: - Properties

    /// The Health store, the user's settings and the bounded executors every
    /// query runs through.
    nonisolated let access: HealthKitAccess

    /// The archive whose workouts the training queries merge with HealthKit's.
    nonisolated let archiveProvider: @Sendable () -> SessionArchive

    /// The observer queries and the sleep and vitals data versions.
    let observation = HealthObservation()

    /// The permission prompt, the scope summaries and the inferred-denial
    /// banner state.
    let authorization: HealthKitAuthorization

    /// Exports archived workouts that never reached Apple Health.
    @ObservationIgnored lazy var backfill = HealthKitBackfill(access: access, sampleReplacer: sampleReplacer)

    // The queries by domain. Each is a value over the parts it uses, built on
    // each access; callers name the domain they read.

    /// Heart-rate reads, stats and exports.
    var heartRate: HeartRateHealthQueries {
        HeartRateHealthQueries(access: access, sampleReplacer: sampleReplacer)
    }

    /// Sleep reads, naps and the HR-estimated sleep fallback.
    var sleepQueries: SleepHealthQueries {
        SleepHealthQueries(access: access, heartRate: heartRate)
    }

    /// Recovery vitals and daily activity.
    var vitals: VitalsHealthQueries {
        VitalsHealthQueries(access: access, heartRate: heartRate, observation: observation)
    }

    /// Workouts, routes and training load.
    var training: TrainingHealthQueries {
        TrainingHealthQueries(access: access, heartRate: heartRate, archive: archiveProvider)
    }

    /// Exports, deletes and observer queries.
    var writes: HealthWriteAndObserve {
        HealthWriteAndObserve(
            access: access, heartRate: heartRate, sleepQueries: sleepQueries,
            sampleReplacer: sampleReplacer, observation: observation
        )
    }

    /// Body mass, date of birth and biological sex.
    var profile: ProfileHealthQueries {
        ProfileHealthQueries(access: access)
    }

    /// The queries the scoring services make, behind
    /// `HealthKitServiceProtocol`.
    var service: HealthKitService {
        HealthKitService(
            heartRate: heartRate, sleepQueries: sleepQueries, vitals: vitals,
            training: training, writes: writes
        )
    }

    /// The store exports replace their samples through: the app's Health
    /// store unless one was given at init (tests give an in-memory store).
    @ObservationIgnored private let givenSampleStore: (any HealthSampleStore)?

    /// Every export and removal of a session's samples goes through this one
    /// replacer, so those for the same session run one at a time.
    @ObservationIgnored lazy var sampleReplacer = HealthSampleReplacer(
        store: givenSampleStore ?? HealthKitSampleStore(access: access)
    )

    // MARK: - Init

    /// Only one manager runs in the app (`shared`, built in the composition
    /// root): a second would allocate its own `HKHealthStore`, hold its own
    /// anchor tokens and publish its own observed state.
    nonisolated init(
        settingsProvider: @escaping @Sendable () -> UserSettings,
        archiveProvider: @escaping @Sendable () -> SessionArchive,
        sampleStore: (any HealthSampleStore)? = nil
    ) {
        let access = HealthKitAccess(store: HKHealthStore(), settingsProvider: settingsProvider)
        self.access = access
        self.authorization = HealthKitAuthorization(access: access)
        self.archiveProvider = archiveProvider
        self.givenSampleStore = sampleStore
    }

    /// Whether this device has Apple Health at all.
    nonisolated var isHealthKitAvailable: Bool {
        access.isAvailable
    }

    // MARK: - Types

    // Sleep domain types live in `Models/SleepDomain.swift` so the
    // analysis layer stops naming this I/O class in its signatures. Aliases keep
    // every existing `HealthKitManager.SleepStage` call site compiling, the same
    // way `SleepData` has been handled since it moved.
    typealias SleepBoundarySource = Emuqu.SleepBoundarySource
    typealias SleepBoundaryValidation = Emuqu.SleepBoundaryValidation
    typealias HRSleepQuality = Emuqu.HRSleepQuality
    typealias SleepSegment = Emuqu.SleepSegment
    typealias SleepStage = Emuqu.SleepStage
    typealias SleepStageProvenance = Emuqu.SleepStageProvenance
    typealias SleepStageInterval = Emuqu.SleepStageInterval
    typealias SleepData = Emuqu.SleepData
}
