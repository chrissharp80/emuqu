import Foundation

/// Local validation counters for the v2 rollout.
///
/// Tracks dashboard opens, chip drill-ins, trajectory visits, mode
/// activations and methodology views, on-device only, never uploaded. The Diagnostics page surfaces them so a single user (or a
/// TestFlight tester) can sanity-check the rollout without an analytics
/// SDK and without sharing data.
///
/// All counters auto-persist in UserDefaults. Reset all from
/// Settings → Advanced → Diagnostics → Reset telemetry.
@Observable
@MainActor
final class ValidationTelemetry {
    static let shared = ValidationTelemetry()

    private let defaults: UserDefaults

    // Keys
    private enum Keys {
        static let dashboardOpenCount = "telemetry.dashboardOpens"
        static let lastDashboardOpen = "telemetry.lastDashboardOpenAt"
        static let chipDrillIns = "telemetry.chipDrillInsByKey"
        static let trajectoryVisits = "telemetry.trajectoryVisits"
        static let lastTrajectoryVisit = "telemetry.lastTrajectoryVisit"
        static let modeActivations = "telemetry.modeActivationsByKind"
        static let methodologyViews = "telemetry.methodologyViews"
    }

    private(set) var dashboardOpens: Int
    private(set) var trajectoryVisits: Int
    private(set) var methodologyViews: Int
    private(set) var chipDrillIns: [String: Int]
    private(set) var modeActivations: [String: Int]

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dashboardOpens = defaults.integer(forKey: Keys.dashboardOpenCount)
        trajectoryVisits = defaults.integer(forKey: Keys.trajectoryVisits)
        methodologyViews = defaults.integer(forKey: Keys.methodologyViews)
        chipDrillIns = (defaults.dictionary(forKey: Keys.chipDrillIns) as? [String: Int]) ?? [:]
        modeActivations = (defaults.dictionary(forKey: Keys.modeActivations) as? [String: Int]) ?? [:]
    }

    // MARK: - Dashboard opens

    func recordDashboardOpen() {
        dashboardOpens += 1
        defaults.set(dashboardOpens, forKey: Keys.dashboardOpenCount)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.lastDashboardOpen)
    }

    // MARK: - Drill-in tap rate (metric 3)

    enum ChipKey: String {
        case hrv, sleep, vitals, load
    }

    func recordChipTap(_ chip: ChipKey) {
        chipDrillIns[chip.rawValue, default: 0] += 1
        defaults.set(chipDrillIns, forKey: Keys.chipDrillIns)
    }

    var totalDrillIns: Int { chipDrillIns.values.reduce(0, +) }

    // MARK: - Trajectory visit rate (metric 5)

    func recordTrajectoryVisit() {
        trajectoryVisits += 1
        defaults.set(trajectoryVisits, forKey: Keys.trajectoryVisits)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.lastTrajectoryVisit)
    }

    // MARK: - Mode toggle activation (metric 6)

    enum ModeKind: String {
        case comeback, intentionalOverreach
    }

    func recordModeActivation(_ kind: ModeKind) {
        modeActivations[kind.rawValue, default: 0] += 1
        defaults.set(modeActivations, forKey: Keys.modeActivations)
    }

    // MARK: - Methodology view rate (metric 7)

    func recordMethodologyView() {
        methodologyViews += 1
        defaults.set(methodologyViews, forKey: Keys.methodologyViews)
    }

    // MARK: - Diagnostics summary

    var diagnosticsSummary: String {
        [
            "Dashboard opens: \(dashboardOpens)",
            "Drill-ins: \(totalDrillIns) (\(chipDrillIns.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")))",
            "Trajectory visits: \(trajectoryVisits)",
            "Methodology views: \(methodologyViews)",
            "Mode activations: \(modeActivations.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))"
        ].joined(separator: "\n")
    }

    func reset() {
        dashboardOpens = 0
        trajectoryVisits = 0
        methodologyViews = 0
        chipDrillIns = [:]
        modeActivations = [:]
        for key in [Keys.dashboardOpenCount, Keys.lastDashboardOpen, Keys.chipDrillIns, Keys.trajectoryVisits,
                    Keys.lastTrajectoryVisit, Keys.modeActivations, Keys.methodologyViews] {
            defaults.removeObject(forKey: key)
        }
    }
}
