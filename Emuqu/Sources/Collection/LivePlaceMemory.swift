import CoreLocation
import Foundation

/// `PlaceHistory` for the workout in progress: the past GPS workouts near
/// where it started, read once off the main actor, and from them, every
/// `refreshInterval`, the climb ahead and the past passes over the user's
/// spot. The tick loop only reads the last answer, so nothing here costs the
/// main actor more than starting a task.
@MainActor
final class LivePlaceMemory {
    /// The climb ahead the past passes agree on, or nil (no heading, no
    /// history here, or no agreement).
    private(set) var climbAhead: PlaceHistory.ClimbAhead?
    /// The past passes over the spot the user is on.
    private(set) var visitsHere: PlaceHistory.Visits?

    static let refreshInterval: TimeInterval = 5

    /// Nil until the history near the start has been read.
    private var tracks: [PlaceHistory.Track]?
    private var loading = false
    private var refreshing = false
    private var lastRefreshAt: Date?
    /// Bumped by `reset()`, so an answer for the last workout that lands
    /// after a new one started is dropped.
    private var generation = 0

    /// Forget the last workout's history and answers.
    func reset() {
        generation += 1
        (tracks, climbAhead, visitsHere, lastRefreshAt) = (nil, nil, nil, nil)
        (loading, refreshing) = (false, false)
    }

    /// Read the history on the first fix, then refresh the answers at most
    /// every `refreshInterval`. `heading` is the GPS course; with none (the
    /// user is standing still) there is no direction to look ahead in.
    func update(location: CLLocation?, heading: Double?, sessionStart: Date, archive: SessionArchive, now: Date = Date()) {
        guard let location else { return }
        guard let tracks else {
            load(near: location, excluding: sessionStart, archive: archive)
            return
        }
        guard !tracks.isEmpty, !refreshing else { return }
        if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < Self.refreshInterval { return }
        refresh(tracks: tracks, location: location, heading: heading, now: now)
    }

    private func load(near location: CLLocation, excluding sessionStart: Date, archive: SessionArchive) {
        guard !loading else { return }
        loading = true
        let generation = generation
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                PlaceHistory.load(from: archive, near: location, excluding: sessionStart)
            }.value
            guard let self, self.generation == generation else { return }
            self.tracks = loaded
            self.loading = false
        }
    }

    private func refresh(tracks: [PlaceHistory.Track], location: CLLocation, heading: Double?, now: Date) {
        (refreshing, lastRefreshAt) = (true, now)
        let generation = generation
        Task { [weak self] in
            let answers = await Task.detached(priority: .utility) {
                PlaceHistory.answers(in: tracks, at: location, heading: heading)
            }.value
            guard let self, self.generation == generation else { return }
            (self.climbAhead, self.visitsHere, self.refreshing) = (answers.climbAhead, answers.visits, false)
        }
    }
}
