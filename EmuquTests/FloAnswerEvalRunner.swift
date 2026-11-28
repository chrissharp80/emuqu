@testable import Emuqu
import XCTest

/// Asks Flo every question of the held-out eval seed, through the app's own
/// tool loop and a real provider, over the seed's dataset archived as the
/// app's own sessions, and grades each reply deterministically.
///
/// Skipped unless `EMUQU_EVAL_DIR` names the seed folder and a provider key
/// is set (`EMUQU_EVAL_GROK_KEY`, `EMUQU_EVAL_ANTHROPIC_KEY` or
/// `EMUQU_EVAL_OPENAI_KEY`), so CI never calls a provider; `EMUQU_EVAL_DRY_RUN=1`
/// runs it over a stub provider instead. Run it with
/// `scripts/run_flo_eval.sh`. It measures and does not judge: it fails only
/// when it cannot run or cannot write its results.
@MainActor
final class FloAnswerEvalRunner: XCTestCase {
    func testFloAnswersTheEvalSeedQuestions() async throws {
        guard let config = FloEvalConfig.fromEnvironment() else {
            throw XCTSkip("Set EMUQU_EVAL_DIR and a provider key (EMUQU_EVAL_GROK_KEY, EMUQU_EVAL_ANTHROPIC_KEY or EMUQU_EVAL_OPENAI_KEY), or EMUQU_EVAL_DRY_RUN=1, to run the Flo answer eval.")
        }
        let world = try FloEvalWorld(config: config)
        defer { world.tearDown() }
        let outcomes = try await FloEvalRun(config: config, world: world).answerAll()
        XCTAssertFalse(outcomes.isEmpty, "the seed held no questions")
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.outputDirectory.appendingPathComponent("results.json").path))
    }
}

/// Where the seed is, which provider answers and where results go, from the
/// test process's environment (`xcodebuild` passes `TEST_RUNNER_<NAME>` on
/// as `<NAME>`).
struct FloEvalConfig {
    let seedDirectory: URL
    let outputDirectory: URL
    let provider: ProviderID
    let key: String
    let modelID: String?
    /// `EMUQU_EVAL_DRY_RUN=1`: a stub provider answers (`FloEvalDryRunProvider`), no key needed.
    let dryRun: Bool

    private static let keyNames: [(ProviderID, String)] = [
        (.grok, "EMUQU_EVAL_GROK_KEY"), (.anthropic, "EMUQU_EVAL_ANTHROPIC_KEY"), (.openai, "EMUQU_EVAL_OPENAI_KEY")
    ]

    /// Nil unless the seed folder and a key for the chosen provider are
    /// set, or a dry run is asked for. `EMUQU_EVAL_PROVIDER` (grok,
    /// anthropic, openai) picks one when several keys are; otherwise the
    /// first set, Grok first.
    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> FloEvalConfig? {
        guard let seed = nonEmpty(environment["EMUQU_EVAL_DIR"]) else { return nil }
        let dryRun = environment["EMUQU_EVAL_DRY_RUN"] == "1"
        guard let (provider, key) = dryRun ? (.openai, "dry-run") : providerKey(environment) else { return nil }
        let seedDirectory = URL(fileURLWithPath: seed, isDirectory: true)
        let output = nonEmpty(environment["EMUQU_EVAL_OUT"]).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? seedDirectory.appendingPathComponent("results-\(stamp())", isDirectory: true)
        return FloEvalConfig(
            seedDirectory: seedDirectory, outputDirectory: output, provider: provider, key: key,
            modelID: nonEmpty(environment["EMUQU_EVAL_MODEL"]), dryRun: dryRun
        )
    }

    private static func providerKey(_ environment: [String: String]) -> (ProviderID, String)? {
        let chosen = environment["EMUQU_EVAL_PROVIDER"].flatMap { name in keyNames.first { $0.0.rawValue == name.lowercased() } }
        guard let (provider, keyName) = chosen ?? keyNames.first(where: { nonEmpty(environment[$0.1]) != nil }),
              let key = nonEmpty(environment[keyName]) else { return nil }
        return (provider, key)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

/// The app as the eval runs it: a container over a temporary archive,
/// settings, baseline and training-load cache of its own, the provider key
/// in a keychain service of its own, the provider switched on and its
/// consent given, and the dataset's time zone, all put back by `tearDown`.
@MainActor
final class FloEvalWorld {
    let dependencies = AppDependencies()
    let directory: URL
    let archive: SessionArchive
    let settings: SettingsManager
    private let baseline: BaselineTracker
    private let keys = APIKeyStore(keychainService: "com.chrissharp.flowrecovery.eval.\(UUID().uuidString)")
    private var archived: [HRVSession] = []
    private var restorers: [() -> Void] = []
    private var scope: AppDependencies.InstalledScope?
    let config: FloEvalConfig

    init(config: FloEvalConfig) throws {
        self.config = config
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloEval-\(UUID().uuidString)", isDirectory: true)
        settings = SettingsManager(settingsURL: directory.appendingPathComponent("user_settings.json"))
        archive = SessionArchive(directory: directory.appendingPathComponent("Archive", isDirectory: true))
        baseline = BaselineTracker(baselineFile: directory.appendingPathComponent("HRVBaseline.json"))
        try installServices()
        try useDatasetTimeZone()
        allowProvider()
        scope = AppDependencies.install(dependencies)
    }

    private func installServices() throws {
        let (archive, settings) = (archive, settings)
        dependencies.overrides.settingsManager = settings
        dependencies.overrides.sessionArchive = archive
        dependencies.overrides.baselineTracker = baseline
        dependencies.overrides.archiveSignal = ArchiveSignal()
        dependencies.overrides.apiKeyStore = keys
        dependencies.overrides.trainingMetricsCache = TrainingMetricsCache(
            archive: { archive }, settings: { settings.settings }, persistenceURL: directory.appendingPathComponent("TrainingMetricsCache.json")
        )
        guard keys.setKey(config.key, for: config.provider) else { throw EvalSeedError.malformed("the provider key could not be stored") }
    }

    /// The dataset's local times are Denver's; the app files nights by the
    /// device's time zone, so the run uses that one.
    private func useDatasetTimeZone() throws {
        let previous = NSTimeZone.default
        NSTimeZone.default = EvalClock.timeZone
        restorers.append { NSTimeZone.default = previous }
        guard TimeZone.current.identifier == EvalClock.timeZone.identifier else {
            throw EvalSeedError.malformed("time zone is \(TimeZone.current.identifier); run with TZ=America/Denver")
        }
    }

    private func allowProvider() {
        let flags = dependencies.app.featureFlags
        let flag: FeatureFlags.Key = switch config.provider {
        case .anthropic: .providerAnthropicEnabled
        case .openai: .providerOpenAIEnabled
        default: .providerGrokEnabled
        }
        let wasOn = flags.value(for: flag)
        flags.set(true, for: flag)
        let consent = dependencies.providers.providerConsentTracker
        let hadConsent = !consent.requiresConsent(config.provider)
        consent.acknowledge(config.provider)
        restorers.append { [provider = config.provider] in
            flags.set(wasOn, for: flag)
            if !hadConsent { consent.revoke(provider) }
        }
    }

    /// Archives every session the user had by `moment`, then rebuilds the
    /// baseline from them the way the app's sample-data import does.
    func archiveSessions(upTo moment: Date, from pending: inout [FloEvalSeeder.Item]) throws {
        let due = pending.prefix { $0.availableAt <= moment }
        guard !due.isEmpty else { return }
        for item in due {
            _ = try archive.archive(item.session, skipSameNightMerge: true)
            archived.append(item.session)
        }
        pending.removeFirst(due.count)
        baseline.rebuildFromSessions(archived, sleepSchedule: settings.settings.sleepSchedule)
    }

    func provider() -> any AIProvider {
        if config.dryRun { return FloEvalDryRunProvider() }
        let services = AIProviderServices(dependencies)
        return switch config.provider {
        case .anthropic: AnthropicProvider(services: services)
        case .openai: OpenAIProvider(services: services)
        default: GrokProvider(services: services)
        }
    }

    /// `EMUQU_EVAL_MODEL` when set (a catalog model by its API id, else that
    /// id as given), otherwise the provider's default model.
    func model(of provider: any AIProvider) -> ModelOption? {
        guard let id = config.modelID else { return provider.availableModels.first { $0.isDefault } ?? provider.availableModels.first }
        return provider.availableModels.first { $0.apiID == id } ?? ModelOption(
            providerID: provider.id, apiID: id, displayName: id, blurb: "eval", contextWindow: 200_000,
            inputPricePerMTok: nil, outputPricePerMTok: nil, isDefault: false
        )
    }

    func tearDown() {
        keys.removeAllKeys()
        scope?.end()
        scope = nil
        for restore in restorers.reversed() { restore() }
        restorers = []
        _ = settings.flushPendingWritesSynchronously()
        attempt("FloEval.removeTemporaryFolder") { try FileManager.default.removeItem(at: directory) }
    }
}

/// One pass over the questions, in `as_of` order so the archive grows the
/// way the user's did: before each question, every session that had ended
/// by its `as_of` is archived, and the assistant's clock is pinned there.
@MainActor
struct FloEvalRun {
    let config: FloEvalConfig
    let world: FloEvalWorld

    func answerAll() async throws -> [FloEvalOutcome] {
        let seedFile = config.seedDirectory.appendingPathComponent("dataset.json")
        var pending = try FloEvalSeeder.items(from: FloEvalDataset.load(from: seedFile))
        let questions = try FloEvalQuestion.load(from: config.seedDirectory.appendingPathComponent("questions.json"))
        let grader = FloEvalGrader(datasetNumbers: try EvalJSON.load(from: seedFile).allNumbers.map { String($0) }.joined(separator: " "))
        let (driver, info) = try makeDriver(questionCount: questions.count)
        let splits = FloEvalSplit.assign(questions)
        var outcomes: [FloEvalOutcome] = []
        for question in questions.sorted(by: { ($0.asOf, $0.id) < ($1.asOf, $1.id) }) {
            guard let moment = EvalClock.asOf(question.asOf) else { throw EvalSeedError.malformed("as_of \(question.id)") }
            try world.archiveSessions(upTo: moment, from: &pending)
            let transcript = await ask(question.question, at: moment, driver: driver)
            let grade = grader.grade(question, transcript: transcript)
            outcomes.append(FloEvalOutcome(question: question, split: splits[question.id] ?? .heldout, transcript: transcript, grade: grade))
            try FloEvalReport.write(outcomes, run: info, to: config.outputDirectory)
        }
        return outcomes
    }

    private func makeDriver(questionCount: Int) throws -> (FloEvalTurnDriver, FloEvalRunInfo) {
        let provider = world.provider()
        guard let model = world.model(of: provider) else { throw EvalSeedError.malformed("no model for \(provider.id.rawValue)") }
        let driver = FloEvalTurnDriver(services: ChatServices(world.dependencies), provider: provider, model: model, directory: world.directory)
        let info = FloEvalRunInfo(
            provider: provider.id.rawValue, model: model.apiID, startedAt: ISO8601DateFormatter().string(from: Date()), questionCount: questionCount
        )
        return (driver, info)
    }

    private func ask(_ question: String, at moment: Date, driver: FloEvalTurnDriver) async -> FloEvalTranscript {
        let pinned = AppClock.pin(moment)
        defer { pinned.end() }
        return await driver.ask(question)
    }
}
