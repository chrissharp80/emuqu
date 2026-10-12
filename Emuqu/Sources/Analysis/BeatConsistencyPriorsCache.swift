import Foundation

/// Process-lifetime cache of per-session `BeatConsistency.Features`.
///
/// # The problem this exists to solve
///
/// `HRVDetailV2View` builds the Beat Consistency baseline by walking the
/// 18–28 most recent overnight sessions and calling
/// `BeatConsistency.score(rr:flags:sleepStartMs:sleepEndMs:baseline:nil)`
/// on each one. That requires the FULL session (rrSeries decoded), which
/// means 18 × `archive.retrieve()` per view open: SHA256 verify + AES-GCM
/// decrypt + JSON-decode of ~700 KB to several MB of rrSeries blob. At
/// ~300 ms each, a single tap onto HRV detail does 5–10 seconds of disk
/// I/O while the BC card sits showing the misleading intermediate state
/// "Calibrating — 0 of 14 nights" (an empty `priorBaselineFeatures` →
/// nil baseline → `.calibrating(0, 14)` from the scorer).
///
/// User report: backed out and re-entered HRV view three
/// times in a row, each entry paid the full 5–10 s tax because nothing
/// persisted between view destructions. The diagnostic log proved the
/// work was completing correctly (`accepted=18 rejected={...} cancelled=false`)
/// but the view's `@State priorBaselineFeatures` reset to `[]` on
/// every new view instance.
///
/// # What this cache does
///
/// Per-session `Features` are immutable by definition — the inputs
/// (rrSeries, sleep boundaries, artifact flags) are written once at
/// session acceptance and never mutate. So we cache them by `sessionId`
/// for the app's lifetime, invalidating only on a generic archive-
/// change signal (delete / merge / CloudKit pull). After the first
/// view open populates the cache, subsequent opens are zero archive
/// reads.
///
/// # Concurrency
///
/// `@MainActor` because the only consumers are SwiftUI views that
/// already run on main. The cache is read and written from
/// `HRVDetailV2View.task` before/after the off-main retrieve pass; the
/// view captures the @MainActor-isolated state up front, dispatches the
/// detached compute, then writes results back on main.
@MainActor
final class BeatConsistencyPriorsCache {
    static let shared = BeatConsistencyPriorsCache()

    private var entries: [UUID: BeatConsistency.Features] = [:]
    /// Sessions already decoded that yield no features (no RR series, or too
    /// few valid windows to feed the baseline). Immutable like the features,
    /// so remembering them stops every warm-up from decrypting the same
    /// short or artifact-heavy nights again. Capped at `entryCap` like the
    /// features, oldest dropped first (`featurelessOrder`).
    private var featureless: Set<UUID> = []
    /// Insertion order for `featureless`, oldest first; what is persisted.
    private var featurelessOrder: [UUID] = []
    private var notificationToken: NSObjectProtocol?

    /// Insertion order for `entries`, oldest first, so the bounded-cap
    /// eviction in `store` drops the least-recently added session rather
    /// than an arbitrary dictionary slot. Persisted with the entries, so it
    /// survives a relaunch.
    private var entryOrder: [UUID] = []

    /// Upper bound on cached per-session features. The baseline walk only
    /// ever touches the 18–28 most recent overnight sessions, so this cap
    /// is never reached in normal use — it only prevents the in-memory (and
    /// on-disk) cache from growing without limit over a long-lived install.
    private static let entryCap = 200

    /// On-disk persistence. Per-session features are immutable
    /// (a night's RR / sleep / flags are written once at acceptance), so once
    /// computed they NEVER need recomputing. With an in-memory-only cache,
    /// the ~21 s cold walk of up-to-28 sessions' rrSeries
    /// (decrypt + multi-MB JSON decode each — a user's exported log timed
    /// it at 21.7 s) re-runs on EVERY launch, and a wholesale invalidation
    /// re-runs it on every archive change too; the Beat Consistency card is
    /// effectively never ready. Persisting to disk means that walk happens AT
    /// MOST ONCE EVER per session; every later open (this launch or a future
    /// one) loads tiny precomputed features and the baseline is instant.
    private let diskURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("beat_consistency_priors.json")
    }()

    /// Sibling file for `featureless`, so the old features file keeps its
    /// format.
    private var featurelessURL: URL {
        diskURL.deletingLastPathComponent().appendingPathComponent("beat_consistency_priors_featureless.json")
    }

    private init() {
        loadFromDisk()
        loadFeaturelessFromDisk()
    }

    /// Wire up the archive-change listener once the collector exists.
    /// Called from `RRCollector.setupBindings()`. Calling it again replaces
    /// the prior observer.
    ///
    /// Observe the RAW `.flowRecoveryArchiveChanged`
    /// notification (which carries the changed session's id in `object`)
    /// instead of `ArchiveSignal.version` (a coalesced counter that loses
    /// the id). Per-session `BeatConsistency.Features` are IMMUTABLE — a
    /// session's RR / sleep / artifact inputs are written once at acceptance
    /// — so a write to ANOTHER session must not wipe this one's cached
    /// features. A `$version` sink dropping the whole cache on every
    /// bump means a workout finalizing (dozens of archive writes across
    /// recording + scoring + CloudKit sync) repeatedly nukes the entire
    /// overnight-priors cache, and the Beat Consistency card re-walks
    /// ~17 sessions × ~1.3 s = ~21 s on EVERY open during/after a workout
    /// (user report "beat consistency still spins"; the exported
    /// log showed back-to-back 21 s `accepted=17` walks). Invalidate
    /// ONLY the session that actually changed.
    ///
    /// A nil object does not drop the whole cache. The
    /// legacy broadcast `ArchiveSignal.notifyChanged()` posts `object: nil`
    /// and is still called after routine SINGLE-session actions (tagging a
    /// session in MainTabView, deleting one reading in HistoryView,
    /// Fitness-tab edits — ~13 call sites), so treating nil as "bulk
    /// change" nukes the whole disk cache several times per normal day of
    /// use and forces the next HRV-tab open back into the ~21 s full
    /// re-walk ("beat consistency
    /// still doesn't work right"). Features are immutable per session id,
    /// so a coarse "something changed somewhere" signal only ever requires
    /// DROPPING entries whose sessions no longer exist (single delete,
    /// delete-all); everything still present in the archive stays valid.
    /// `reconcile(against:)` does exactly that, keeping the cache warm.
    /// `signal` is not read but kept in the signature so the single
    /// `RRCollector` call site stays simple.
    func bindToArchiveSignal(_: ArchiveSignal, archive: SessionArchive) {
        boundArchive = archive
        if let existing = notificationToken {
            NotificationCenter.default.removeObserver(existing)
        }
        notificationToken = makeArchiveObserver()
    }

    /// Capture only `[weak self]` — capturing the non-Sendable
    /// SessionArchive in this @Sendable observer closure is a strict-
    /// concurrency warning; the archive is read back from the
    /// @MainActor-isolated property inside the MainActor task instead
    /// (same pattern as every other observer in the codebase).
    ///
    /// `queue: nil`, not `.main`. A non-nil queue makes
    /// `post` block the posting thread until the block finishes on that queue.
    /// Archive writes post from background threads, so `.main` added a
    /// synchronous main-queue round-trip to every write (and deadlocked when
    /// main was itself waiting on those writes). Reading `note.object` on the
    /// posting thread before hopping is if anything more correct — the
    /// `Notification` is not Sendable and must not cross the Task boundary.
    /// See `ArchiveSignal.init`.
    private func makeArchiveObserver() -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .flowRecoveryArchiveChanged,
            object: nil,
            queue: nil
        ) { [weak self] note in
            let changedId = note.object as? UUID
            Task { @MainActor in self?.applyArchiveChange(changedId) }
        }
    }

    /// A specific id invalidates just that entry; a nil object means "something
    /// changed" and the whole cache is reconciled.
    @MainActor
    private func applyArchiveChange(_ changedId: UUID?) {
        guard let changedId else {
            reconcileAgainstBoundArchive()
            return
        }
        invalidate(changedId)
    }

    /// The archive this cache reconciles against; set once at bind time
    /// from RRCollector's wiring layer.
    private weak var boundArchive: SessionArchive?

    /// Drop cached entries for sessions that no longer exist in the
    /// archive index. Cheap (in-memory id-set diff) and safe to run on
    /// every coarse change signal — entries for live sessions are never
    /// touched because per-session features are immutable.
    private func reconcileAgainstBoundArchive() {
        guard let archive = boundArchive else { return }
        let liveIds = Set(archive.entries.map(\.sessionId))
        let stale = entries.keys.filter { !liveIds.contains($0) }
        let staleFeatureless = featureless.subtracting(liveIds)
        guard !stale.isEmpty || !staleFeatureless.isEmpty else { return }
        let staleSet = Set(stale)
        for id in stale { entries.removeValue(forKey: id) }
        entryOrder.removeAll { staleSet.contains($0) }
        featureless.subtract(staleFeatureless)
        featurelessOrder.removeAll { staleFeatureless.contains($0) }
        persistToDisk()
    }

    /// Returns the cached features for the session, or nil if not cached.
    func features(for sessionId: UUID) -> BeatConsistency.Features? {
        entries[sessionId]
    }

    /// Store features computed for a session, persisting through to disk.
    func store(_ features: BeatConsistency.Features, for sessionId: UUID) {
        if entries[sessionId] == nil {
            entryOrder.append(sessionId)
        }
        entries[sessionId] = features
        // Bounded cap: evict oldest entries so the cache can't grow without
        // limit over a long-lived install.
        while entryOrder.count > Self.entryCap {
            let oldest = entryOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        persistToDisk()
    }

    /// Drop the cached features for a single session (e.g. after the
    /// session is reanalysed and its windowing inputs may have changed).
    func invalidate(_ sessionId: UUID) {
        let hadFeatures = entries.removeValue(forKey: sessionId) != nil
        let wasFeatureless = featureless.remove(sessionId) != nil
        guard hadFeatures || wasFeatureless else { return }
        entryOrder.removeAll { $0 == sessionId }
        featurelessOrder.removeAll { $0 == sessionId }
        persistToDisk()
    }

    // MARK: - Background warm-up (deduped, lifecycle-independent)

    /// The single in-flight walk, if any. Owned by the cache (a process-
    /// lifetime singleton), NOT by a view — so it runs to completion and
    /// persists every night even if the view that requested it is torn down
    /// mid-walk. Running the walk inside the view's
    /// `.task` wrapped in `withTaskCancellationHandler` means each teardown
    /// KILLS the walk before it can store — a user's log showed
    /// `cancelled=true accepted=1` on repeat with `cache hits=0` forever
    /// (the dashboard recreates the detail view constantly during a 60 s
    /// CloudKit full sync). Owning the walk here + persisting each night
    /// incrementally makes progress monotonic and unkillable.
    private var walkTask: Task<Void, Never>?

    /// Ids waiting for the walk, in request order. A request that arrives
    /// while a walk runs joins this queue rather than being dropped, so a
    /// second night's priors are warmed by the same walk.
    private var queuedIds: [UUID] = []

    /// True while a warm-up walk is running.
    var isWarming: Bool { walkTask != nil }

    /// Compute + persist features for any of `ids` not already cached.
    /// Fire-and-forget and DEDUPED — only one walk runs at a time, so
    /// re-entrant view opens never pile concurrent `archive.retrieve` passes
    /// onto the same lock (the documented deadlock); ids requested while it
    /// runs are queued onto it. Each night is decoded off-main and its
    /// features persisted IMMEDIATELY, so an interrupted or slow launch
    /// still accumulates progress that survives to the next open.
    func startWarm(_ ids: [UUID], archive: SessionArchive) {
        let missing = ids.filter { entries[$0] == nil && !featureless.contains($0) && !queuedIds.contains($0) }
        queuedIds += missing
        guard walkTask == nil, !queuedIds.isEmpty else { return }
        let archiveCapture = archive
        walkTask = Task { [weak self] in
            await self?.drainQueue(archive: archiveCapture)
            self?.walkTask = nil
        }
    }

    /// Warms queued ids one at a time until the queue is empty, including
    /// ids queued while the walk was running.
    private func drainQueue(archive: SessionArchive) async {
        while !queuedIds.isEmpty {
            let id = queuedIds.removeFirst()
            await warmOne(id, archive: archive)
        }
    }

    /// What one night's decode produced.
    private enum WarmOutcome: Sendable {
        case features(BeatConsistency.Features)
        /// Decoded, but the night cannot feed the baseline.
        case featureless
        /// Not readable now (missing or failed to decrypt); retried next walk.
        case unavailable
    }

    /// Decode off-main and persist to disk immediately, so progress survives an
    /// interrupted walk. Already-cached ids are skipped. A session deleted
    /// while it was being decoded (a purge whose change notice has already
    /// reconciled the cache) is not stored: its RR-derived features would
    /// outlive it on disk.
    private func warmOne(_ id: UUID, archive: SessionArchive) async {
        guard entries[id] == nil, !featureless.contains(id) else { return }
        let outcome = await Task.detached(priority: .utility) { () -> WarmOutcome in
            guard let prior = try? archive.retrieve(id) else { return .unavailable }
            return Self.baselineFeatures(from: prior).map(WarmOutcome.features) ?? WarmOutcome.featureless
        }.value
        guard archive.exists(id) else { return }
        switch outcome {
        case let .features(features): store(features, for: id)
        case .featureless: markFeatureless(id)
        case .unavailable: break
        }
    }

    /// Remember a featureless session, dropping the oldest beyond `entryCap`.
    private func markFeatureless(_ id: UUID) {
        guard featureless.insert(id).inserted else { return }
        featurelessOrder.append(id)
        while featurelessOrder.count > Self.entryCap {
            featureless.remove(featurelessOrder.removeFirst())
        }
        persistToDisk()
    }

    /// Score one night's beat consistency. Nil when the session carries no RR
    /// series, or when too few windows were valid for it to feed the baseline.
    nonisolated private static func baselineFeatures(from prior: HRVSession) -> BeatConsistency.Features? {
        guard let series = prior.rrSeries, !series.points.isEmpty else { return nil }
        let result = BeatConsistency.score(
            rr: series.points,
            flags: prior.artifactFlags ?? [],
            sleepStartMs: prior.sleepStartMs ?? 0,
            sleepEndMs: prior.sleepEndMs ?? Int64(series.durationMs),
            baseline: nil
        )
        // Only nights with enough valid windows feed the baseline.
        return result.state.feedsBaseline ? result.nightlyFeatureMedians : nil
    }

    // MARK: - Disk persistence

    /// The features file: the cached entries, oldest first, so the eviction
    /// order survives a relaunch. Also reads the earlier format, a
    /// `[UUID: Features]` dictionary with no order, which is taken in
    /// whatever order it decodes (once; the next write saves the order).
    private struct StoredEntries: Codable {
        struct Entry: Codable {
            let id: UUID
            let features: BeatConsistency.Features
        }

        let entries: [Entry]

        init(entries: [Entry]) {
            self.entries = entries
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            do {
                entries = try container.decode([Entry].self)
            } catch {
                let legacy = try container.decode([UUID: BeatConsistency.Features].self)
                entries = legacy.map { Entry(id: $0.key, features: $0.value) }
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(entries)
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: diskURL),
              let decoded = try? JSONDecoder().decode(StoredEntries.self, from: data)
        else { return }
        let kept = decoded.entries.suffix(Self.entryCap)
        entries = Dictionary(kept.map { ($0.id, $0.features) }, uniquingKeysWith: { _, newer in newer })
        entryOrder = kept.map(\.id).filter { entries[$0] != nil }
    }

    /// A missing file is the normal first-launch case and stays silent.
    private func loadFeaturelessFromDisk() {
        guard FileManager.default.fileExists(atPath: featurelessURL.path) else { return }
        let url = featurelessURL
        guard let ids = attempt("beatConsistencyPriors.loadFeatureless", {
            try JSONDecoder().decode([UUID].self, from: Data(contentsOf: url))
        }) else { return }
        featurelessOrder = Array(ids.suffix(Self.entryCap))
        featureless = Set(featurelessOrder)
    }

    /// The most recent queued disk write. Each new write waits for it, so
    /// writes land in the order they were made and an older snapshot can
    /// never overwrite a newer one (or recreate a file after a purge
    /// emptied the cache).
    private var pendingWrite: Task<Void, Never>?

    /// Snapshot + write off the main actor. Entries are tiny (3 doubles ×
    /// up to ~28 sessions), so the file write goes to a background task to
    /// keep the main actor clean.
    private func persistToDisk() {
        let snapshot = StoredEntries(entries: entryOrder.compactMap { id in
            entries[id].map { StoredEntries.Entry(id: id, features: $0) }
        })
        let featurelessSnapshot = featurelessOrder
        let (url, featurelessURL) = (diskURL, featurelessURL)
        let previous = pendingWrite
        pendingWrite = Task.detached(priority: .utility) {
            await previous?.value
            Self.write(snapshot, to: url)
            Self.write(featurelessSnapshot, to: featurelessURL)
        }
    }

    nonisolated private static func write(_ snapshot: some Encodable, to url: URL) {
        guard let data = attempt("beatConsistencyPriors.encode", { try JSONEncoder().encode(snapshot) }) else { return }
        do {
            // Explicit protection class on this RR-derived cache, matching
            // the archive/backup writers. CUFUA (not `.complete`) so a
            // background/locked write can't fail the way `.complete` did.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            debugLog("[BeatConsistencyPriorsCache] persist failed: \(error)", level: .warning)
        }
    }
}
