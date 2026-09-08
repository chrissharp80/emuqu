import Foundation

/// Build plan §11 — local validation counters for the v2 rollout.
///
/// Tracks the seven metrics the plan says matter, on-device only, never
/// uploaded. The Diagnostics page surfaces them so a single user (or a
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
        static let lastVerdictAppearedAt = "telemetry.lastVerdictAt"
        static let timeToVerdictSamples = "telemetry.ttvSamples"
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

    private(set) var timeToVerdictSamples: [Double]

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dashboardOpens = defaults.integer(forKey: Keys.dashboardOpenCount)
        trajectoryVisits = defaults.integer(forKey: Keys.trajectoryVisits)
        methodologyViews = defaults.integer(forKey: Keys.methodologyViews)
        chipDrillIns = (defaults.dictionary(forKey: Keys.chipDrillIns) as? [String: Int]) ?? [:]
        modeActivations = (defaults.dictionary(forKey: Keys.modeActivations) as? [String: Int]) ?? [:]
        timeToVerdictSamples = (defaults.array(forKey: Keys.timeToVerdictSamples) as? [Double]) ?? []
    }

    // MARK: - Time-to-verdict (§11.1 metric 1)

    func recordDashboardOpen() {
        dashboardOpens += 1
        defaults.set(dashboardOpens, forKey: Keys.dashboardOpenCount)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.lastDashboardOpen)
    }

    /// Called by ScoreRing the moment its verdict glyph is on screen.
    /// Pairs with the most-recent `recordDashboardOpen` to compute TTV.
    func recordVerdictAppeared() {
        let openTs = defaults.double(forKey: Keys.lastDashboardOpen)
        guard openTs > 0 else { return }
        let elapsed = Date().timeIntervalSince1970 - openTs
        // Bound to 30 s to ignore left-tab-open situations where the ring
        // re-renders without a real "open" event.
        guard elapsed > 0, elapsed < 30 else { return }
        timeToVerdictSamples.append(elapsed)
        if timeToVerdictSamples.count > 100 { timeToVerdictSamples.removeFirst() }
        defaults.set(timeToVerdictSamples, forKey: Keys.timeToVerdictSamples)
    }

    var medianTimeToVerdict: Double? {
        guard !timeToVerdictSamples.isEmpty else { return nil }
        let sorted = timeToVerdictSamples.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: - Drill-in tap rate (§11.1 metric 3)

    enum ChipKey: String {
        case hero, hrv, sleep, vitals, load, recent
    }

    func recordChipTap(_ chip: ChipKey) {
        chipDrillIns[chip.rawValue, default: 0] += 1
        defaults.set(chipDrillIns, forKey: Keys.chipDrillIns)
    }

    var totalDrillIns: Int { chipDrillIns.values.reduce(0, +) }

    // MARK: - Trajectory visit rate (§11.1 metric 5)

    func recordTrajectoryVisit() {
        trajectoryVisits += 1
        defaults.set(trajectoryVisits, forKey: Keys.trajectoryVisits)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.lastTrajectoryVisit)
    }

    // MARK: - Mode toggle activation (§11.1 metric 6)

    enum ModeKind: String {
        case comeback, peakingDetect, intentionalOverreach
    }

    func recordModeActivation(_ kind: ModeKind) {
        modeActivations[kind.rawValue, default: 0] += 1
        defaults.set(modeActivations, forKey: Keys.modeActivations)
    }

    // MARK: - Methodology view rate (§11.1 metric 7)

    func recordMethodologyView() {
        methodologyViews += 1
        defaults.set(methodologyViews, forKey: Keys.methodologyViews)
    }

    // MARK: - Diagnostics summary

    var diagnosticsSummary: String {
        let ttv = medianTimeToVerdict.map { String(format: "%.2fs", $0) } ?? "—"
        return [
            "Dashboard opens: \(dashboardOpens)",
            "Median time-to-verdict: \(ttv)",
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
        timeToVerdictSamples = []
        for key in [Keys.dashboardOpenCount, Keys.lastDashboardOpen, Keys.lastVerdictAppearedAt,
                    Keys.timeToVerdictSamples, Keys.chipDrillIns, Keys.trajectoryVisits,
                    Keys.lastTrajectoryVisit, Keys.modeActivations, Keys.methodologyViews] {
            defaults.removeObject(forKey: key)
        }
    }
}
