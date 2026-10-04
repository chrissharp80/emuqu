import Foundation
import SwiftUI
@preconcurrency import Translation

// MARK: - NarrativeTranslator

/// Translates dynamically generated English narrative text (analysis summaries,
/// score breakdowns, readiness messages) into the user's language using Apple's
/// on-device Translation framework (iOS 18.0+).
///
/// Static UI labels use Localizable.xcstrings. This handles the generated text
/// that can't be pre-translated because it's assembled at runtime from metrics.
@Observable
@MainActor
final class NarrativeTranslator {
    /// Whether translation is active (selected language is not English AND iOS 18.0+)
    static var isActive: Bool {
        guard #available(iOS 18.0, *) else { return false }
        let langId = AppDependencies.current.services.languageManager.locale.language.languageCode?.identifier ?? "en"
        return langId != "en"
    }

    // MARK: - State

    @ObservationIgnored private let observers = NotificationTokens()

    /// Strings queued for translation on next session activation
    private var pending: Set<String> = []

    /// Strings currently being translated (moved out of pending, not yet cached)
    private var inFlight: Set<String> = []

    /// English → translated text cache
    private var cache: [String: String] = [:]

    /// Tracks consecutive genuine failures per string to cap retries.
    private var failureCounts: [String: Int] = [:]

    /// Maximum retry attempts before a string is permanently skipped.
    private static let maxRetries = 2

    /// Whether a `.translationTask` closure is currently executing.
    /// While true, `prepare()` suppresses `generation` bumps — preventing
    /// `config.invalidate()` from cancelling the in-flight translation session.
    private(set) var taskRunning = false

    /// Bumped by every language change. A batch started before the change
    /// finishes in the old language, so its results are dropped rather than
    /// cached as translations into the new one.
    private var languageEpoch = 0

    /// `languageEpoch` when the running batch was taken. One batch runs at a
    /// time (`taskRunning`), so one value covers it.
    private var batchEpoch = 0

    /// Bumped each time new strings are queued — drives .onChange in the modifier.
    private(set) var generation: Int = 0

    /// Bumped after translations land in cache — triggers view re-render so
    /// `t()` picks up the translated text. Separate from `generation` so it
    /// does NOT fire `config.invalidate()` (which would start a new task).
    private(set) var cacheVersion: Int = 0

    init() {
        observers.add(NotificationCenter.default.addObserver(
            forName: LanguageManager.languageDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clearCache() }
        })
    }

    deinit { observers.removeAll() }

    // MARK: - Public API

    /// Look up the translated version of a string. Returns the original if
    /// no translation is cached yet (the view will re-render when it arrives).
    func t(_ english: String) -> String {
        cache[english] ?? english
    }

    /// Queue English strings for translation. Call this whenever narrative
    /// data changes (new session, score recalculated, etc.).
    ///
    /// Safe to call from within a SwiftUI `body`. Strings are added to
    /// `pending` synchronously. A deferred `generation` bump is only
    /// scheduled when no translation task is currently running — preventing
    /// `config.invalidate()` from cancelling an in-flight session. Strings
    /// that arrive while a task is running are picked up by `taskComplete()`.
    func prepare(_ strings: [String]) {
        guard Self.isActive else { return }
        let newStrings = strings.filter {
            !$0.isEmpty && cache[$0] == nil && !pending.contains($0)
                && !inFlight.contains($0) && (failureCounts[$0] ?? 0) < Self.maxRetries
        }
        guard !newStrings.isEmpty else { return }
        pending.formUnion(newStrings)
        // While a task is running, suppress generation bumps so we don't
        // config.invalidate() and cancel the active session. The running
        // task calls taskComplete() when done, which handles pending strings.
        guard !taskRunning else { return }
        Task { @MainActor [weak self] in
            self?.generation += 1
        }
    }

    /// Called at the start of `.translationTask` to take the pending batch
    /// atomically with setting `taskRunning`. Doing the two in one call
    /// leaves no gap between them where `prepare()` could trigger
    /// `config.invalidate()`.
    @available(iOS 18.0, *)
    func startTask() -> [String] {
        taskRunning = true
        batchEpoch = languageEpoch
        guard !pending.isEmpty else { return [] }
        let batch = Array(pending)
        pending.removeAll()
        inFlight.formUnion(batch)
        return batch
    }

    /// Apply completed translations to the cache and trigger a view refresh.
    @available(iOS 18.0, *)
    func applyTranslations(_ translations: [String: String], batch: [String]) {
        guard batchEpoch == languageEpoch else { return }
        for (source, translated) in translations {
            cache[source] = translated
        }
        inFlight.subtract(batch)
        if !translations.isEmpty {
            cacheVersion += 1
        }
    }

    /// Handle a cancelled task (e.g. from `config.invalidate()` or view
    /// disappearing). Moves in-flight strings back to pending WITHOUT
    /// counting as a failure and WITHOUT bumping `generation` — the new
    /// task spawned by SwiftUI will pick them up via `startTask()`.
    @available(iOS 18.0, *)
    func requeueBatch(_ batch: [String]) {
        guard batchEpoch == languageEpoch else { return }
        inFlight.subtract(batch)
        let uncached = batch.filter { cache[$0] == nil }
        pending.formUnion(uncached)
    }

    /// Mark a batch as failed with a genuine translation error.
    /// Increments failure counts and re-queues strings that haven't
    /// exceeded the retry limit.
    @available(iOS 18.0, *)
    func failBatch(_ batch: [String]) {
        guard batchEpoch == languageEpoch else { return }
        inFlight.subtract(batch)
        for string in batch where cache[string] == nil {
            failureCounts[string] = (failureCounts[string] ?? 0) + 1
            if (failureCounts[string] ?? 0) < Self.maxRetries {
                pending.insert(string)
            }
        }
    }

    /// Called at the end of every `.translationTask` closure (success,
    /// failure, or cancellation). Clears `taskRunning` and schedules a
    /// deferred `generation` bump if strings are waiting — which triggers
    /// `config.invalidate()` and a new translation cycle AFTER this task
    /// has fully returned.
    func taskComplete() {
        taskRunning = false
        if !pending.isEmpty {
            Task { @MainActor [weak self] in
                self?.generation += 1
            }
        }
    }

    func clearCache() {
        languageEpoch += 1
        cache.removeAll()
        pending.removeAll()
        inFlight.removeAll()
        failureCounts.removeAll()
        // Bump cacheVersion so views re-render, call t() (returning English
        // fallback), and call prepare() again — which queues strings for the
        // new language and triggers the Translation framework (prompting for
        // a language pack download if needed).
        cacheVersion += 1
    }
}

// MARK: - View Modifier

/// Attaches on-device narrative translation to a view hierarchy.
/// On iOS < 18.0 or English locales, this is a transparent no-op.
struct NarrativeTranslationModifier: ViewModifier {
    var translator: NarrativeTranslator
    var languageManager: LanguageManager

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), NarrativeTranslator.isActive {
            NarrativeTranslationContent(translator: translator, languageManager: languageManager) {
                content
            }
        } else {
            content
        }
    }
}

/// Inner view that uses iOS 18.0+ APIs — isolated so the parent modifier
/// compiles on iOS 17.0 without availability issues.
@available(iOS 18.0, *)
private struct NarrativeTranslationContent<Content: View>: View {
    var translator: NarrativeTranslator
    var languageManager: LanguageManager
    @ViewBuilder let content: () -> Content

    @State private var config: TranslationSession.Configuration = {
        let langId = AppDependencies.current.services.languageManager.locale.language.languageCode?.identifier ?? Locale.preferredLanguages.first ?? "en"
        return .init(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: langId)
        )
    }()

    var body: some View {
        content()
            .translationTask(config) { session in
                await Self.runBatch(in: session, translator: translator)
            }
            .onChange(of: translator.generation) { _, _ in
                config.invalidate()
            }
            .onChange(of: languageManager.revision) { _, _ in
                rebuildConfig()
            }
    }

    /// startTask() atomically sets taskRunning and takes the pending batch —
    /// no gap for prepare() to sneak in a generation bump that would
    /// config.invalidate() and cancel this session.
    /// Runs off the main actor: `TranslationSession` and its requests are not
    /// `Sendable`, so the batch is built and consumed here and only the
    /// translator (a main-actor store) is awaited across the boundary.
    nonisolated private static func runBatch(in session: TranslationSession, translator: NarrativeTranslator) async {
        let batch = await translator.startTask()
        guard !batch.isEmpty else {
            await translator.taskComplete()
            return
        }
        do {
            let results = try await translate(batch, in: session)
            await translator.applyTranslations(results, batch: batch)
        } catch is CancellationError {
            await translator.requeueBatch(batch)
        } catch {
            debugLog("[NarrativeTranslator] Batch translation failed: \(error.localizedDescription)")
            await translator.failBatch(batch)
        }
        await translator.taskComplete()
    }

    nonisolated private static func translate(_ batch: [String], in session: TranslationSession) async throws -> [String: String] {
        let responses = try await session.translations(from: batch.enumerated().map { index, text in
            TranslationSession.Request(sourceText: text, clientIdentifier: "\(index)")
        })
        var results: [String: String] = [:]
        for response in responses {
            if let id = response.clientIdentifier,
               let index = Int(id), index < batch.count {
                results[batch[index]] = response.targetText
            }
        }
        return results
    }

    /// When the user switches language (e.g. Japanese → German), rebuild the
    /// config with the new target so the Translation framework prompts for the
    /// correct language pack and translates into the right language.
    private func rebuildConfig() {
        let langId = languageManager.locale.language.languageCode?.identifier ?? "en"
        config = .init(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: langId)
        )
    }
}

extension View {
    /// Attach narrative translation to a view hierarchy.
    /// No-op on English devices or iOS < 18.0.
    @MainActor func narrativeTranslation(_ translator: NarrativeTranslator, languageManager: LanguageManager? = nil) -> some View {
        modifier(NarrativeTranslationModifier(translator: translator, languageManager: languageManager ?? AppDependencies.current.services.languageManager))
    }
}
