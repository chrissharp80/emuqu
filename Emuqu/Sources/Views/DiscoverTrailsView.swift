// `@preconcurrency`: CLLocationManager and CLHeading predate Sendable.
@preconcurrency import CoreLocation
import MapKit
import SwiftUI

// MARK: - DiscoverTrailsView
//
// Searches OpenStreetMap (via TrailDiscoveryService) for hiking, MTB,
// and road-cycling trails near the user. Surfaced from the Fitness
// tab's route picker — when the user is already in the "what should
// I run today?" mindset, the entry point is contextually right there
// next to "Load GPX" and "Saved routes".
//
// Two-phase UX:
//   1. Filters sheet — sport, radius, length range, difficulty
//   2. Results list — name + length + ascent + difficulty + distance from
//      you, with map preview on tap and "Use this trail" button
//
// Picking a trail does TWO things:
//   • Binds the parsed trail as `pickedRoute` on the Start flow so the
//     workout starts with the route already attached
//   • Optionally saves it to the user's library (`SavedRouteStore`) so
//     it gets road-name enrichment + future recognition. Default ON
//     because a user who searched for trails is presumably going to
//     want them next time too.
struct DiscoverTrailsView: View {
    @Environment(\.dependencies) var dependencies
    @Environment(\.dismiss) private var dismiss
    @State private var location = SearchLocationProbe()
    private var savedRouteStore: SavedRouteStore { dependencies.location.savedRouteStore }
    /// Called when the user picks a trail and confirms. Receives a
    /// `Route` ready to bind as the workout's planned route.
    let onTrailPicked: (Route) -> Void

    /// Order matters — `saved` appears first so the default tab on open
    /// is the user's own library. The user pointed out: "discover isn't
    /// my daily walk. very misleading to put something i do every day in
    /// a 'discover' tab." Their saved routes get top billing; finding
    /// new trails is the secondary action.
    enum Tab: String, CaseIterable, Identifiable {
        case saved, findNew
        var id: String { rawValue }
        var title: String {
            switch self {
            case .saved: return "My routes"
            case .findNew: return "Find new"
            }
        }
    }

    @State var tab: Tab = .saved
    @State var filters = TrailDiscoveryService.SearchFilters(activity: .hiking)
    @State private var results: [TrailDiscoveryService.DiscoveredTrail] = []
    @State private var isSearching = false
    @State private var errorText: String?
    @State private var savePickToLibrary = true
    @State var radiusKm: Double = 10
    @State var minLengthKm: Double = 0
    @State var maxLengthKm: Double = 30
    /// Min ascent slider (meters). 0 = no min. Filters BOTH the discover
    /// results and the saved-routes list — same filter UX across tabs.
    @State var minAscentMeters: Double = 0
    /// Max ascent slider (meters). Capped at 2000 m which covers most
    /// non-alpine hike/bike routes; alpine users can pick "no max" by
    /// leaving the slider at the right edge.
    @State var maxAscentMeters: Double = 2_000
    @State private var savedSearchText: String = ""

    var body: some View {
        NavigationStack {
            trailsScroll
        }
    }

    private var trailsScroll: some View {
        ScrollView {
            trailsStack
        }
        .background(AppTheme.background)
        .navigationTitle(String(localized: "Pick a route", bundle: LanguageManager.appBundle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            trailsToolbar
        }
        .onAppear {
            location.start()
        }
        .onDisappear {
            location.stop()
        }
    }

    @ToolbarContentBuilder
    private var trailsToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Cancel", bundle: LanguageManager.appBundle)) { dismiss() }
        }
    }

    private var trailsStack: some View {
        VStack(alignment: .leading, spacing: 14) {
            sourcePicker
                .pickerStyle(.segmented)

            locationPrompt
            filtersCard
            searchButton

            errorNotice

            discoverResults
        }
        .padding(16)
    }

    @ViewBuilder
    private var locationPrompt: some View {
        if tab == .findNew {
            discoverIntro
        } else {
            savedIntro
        }
    }

    @ViewBuilder
    private var searchButton: some View {
        if tab == .findNew {
            Button {
                runSearch()
            } label: {
                bodyLabel
            }
            .buttonStyle(.plain)
            .disabled(isSearching || location.currentLocation == nil)
        }
    }

    @ViewBuilder
    private var errorNotice: some View {
        if let err = errorText {
            errorBanner(err)
        }
    }

    @ViewBuilder
    private var discoverResults: some View {
        if tab == .findNew {
            discoverResultRows
            if location.currentLocation == nil {
                locationHint
            }
        } else {
            savedRoutesList
        }
    }

    @ViewBuilder
    private var discoverResultRows: some View {
        if !results.isEmpty {
            Text(String(localized: "Results", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.top, 4)
            ForEach(filteredDiscoverResults) { trail in
                discoverRow(trail)
            }
        }
    }

    private func discoverRow(_ trail: TrailDiscoveryService.DiscoveredTrail) -> some View {
        TrailRow(
            trail: trail,
            userLocation: location.currentLocation,
            onPick: { pickTrail(trail) }
        )
    }

    private var sourcePicker: some View {
        Picker(String(localized: "Source", bundle: LanguageManager.appBundle), selection: $tab) {
            ForEach(Tab.allCases) { t in
                Text(t.title).tag(t)
            }
        }
    }

    private var bodyLabel: some View {
        HStack {
            if isSearching {
                ProgressView().tint(.white)
                Text(String(localized: "Searching…", bundle: LanguageManager.appBundle))
            } else {
                Image(systemName: "magnifyingglass")
                Text(String(localized: "Search trails near me", bundle: LanguageManager.appBundle))
            }
        }
        .font(.subheadline.weight(.medium))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(AppTheme.terracotta)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Subviews

    private var discoverIntro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Find a new route", bundle: LanguageManager.appBundle))
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            Text(String(localized: "Searches OpenStreetMap for named trails near your current location. Pick one and it loads as today's route — plus saves to your library so the AI coach learns the road names + climbs for next time.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var savedIntro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Your saved routes", bundle: LanguageManager.appBundle))
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            Text(String(localized: "Routes you've saved to your library. Tap one to bind as today's route — the coach will recognise the same loop in either direction.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Saved routes filtered by length, ascent, and free-text search.
    /// Same filter UX across both tabs so the user only learns one set
    /// of controls.
    private var filteredSavedRoutes: [SavedRoute] {
        savedRouteStore.routes.filter { route in
            let lenKm = route.totalDistanceMeters / 1_000
            if lenKm < minLengthKm { return false }
            if lenKm > maxLengthKm { return false }
            let ascent = route.totalAscentMeters
            if ascent < minAscentMeters { return false }
            if maxAscentMeters < 1_999 && ascent > maxAscentMeters { return false }
            let q = savedSearchText.trimmingCharacters(in: .whitespaces)
            if !q.isEmpty {
                return route.name.localizedCaseInsensitiveContains(q)
            }
            return true
        }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Discover results filtered by the ascent slider too. The Overpass
    /// query doesn't include elevation natively (we'd need a separate
    /// DEM lookup per trail to know real ascent), so the user-facing
    /// filter applies to length only for discovered trails today —
    /// noted in the slider footer below.
    private var filteredDiscoverResults: [TrailDiscoveryService.DiscoveredTrail] {
        results.filter { trail in
            let lenKm = trail.lengthMeters / 1_000
            if lenKm < minLengthKm { return false }
            if lenKm > maxLengthKm { return false }
            return true
        }
    }

    @ViewBuilder
    private var savedRoutesList: some View {
        savedRoutesStack
    }

    private var savedRoutesStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            savedRouteSearchField
            savedRouteRows
        }
    }

    private var savedRouteSearchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.textSecondary)
            TextField(String(localized: "Search by name", bundle: LanguageManager.appBundle), text: $savedSearchText)
                .font(.caption)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.cardBackground))
    }

    private func savedRouteRow(_ saved: SavedRoute) -> some View {
        SavedRouteRow(saved: saved) { pickSavedRoute(saved) }
    }

    @ViewBuilder
    private var savedRouteRows: some View {
        let routes = filteredSavedRoutes
        if routes.isEmpty {
            emptySavedRoutesNote
        } else {
            ForEach(routes) { saved in
                savedRouteRow(saved)
            }
        }
    }

    /// Two different empties: nothing saved at all, versus nothing matching the
    /// current filters — the fix differs, so the copy does too.
    @ViewBuilder
    private var emptySavedRoutesNote: some View {
        if savedRouteStore.routes.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "tray")
                    .foregroundStyle(AppTheme.textSecondary)
                Text(String(localized: "Nothing saved yet. Run a workout, then tap \"Add to my route library\" on the post-workout summary — or pick a discovered trail (it gets auto-saved).", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(12)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            Text(String(localized: "No saved routes match the current filters. Widen the length / ascent range above.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(12)
                .background(AppTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func pickSavedRoute(_ saved: SavedRoute) {
        let route = saved.toRoute()
        onTrailPicked(route)
        dismiss()
    }

    /// Tap cycles: not-selected → set as min → set as max → cleared. A simple
    /// two-tap UX for "show easy through moderate" without making the user
    /// manage two separate pickers.
    ///
    /// No force-unwrap of `filters.minDifficulty` inside the
    /// second branch. The outer `nil` check would guard it in practice, but the
    /// spec forbids force-unwrap. Bound with `if let` for clarity and
    /// future-proofing.
    func cycleDifficulty(_ d: TrailDiscoveryService.Difficulty) {
        guard let minDifficulty = filters.minDifficulty else {
            filters.minDifficulty = d
            filters.maxDifficulty = d
            return
        }
        let alreadyAnEndpoint = filters.minDifficulty == d || filters.maxDifficulty == d
        if alreadyAnEndpoint {
            filters.minDifficulty = nil
            filters.maxDifficulty = nil
        } else if d > minDifficulty {
            filters.maxDifficulty = d
        } else {
            filters.minDifficulty = d
        }
    }

    static func difficultyColor(_ d: TrailDiscoveryService.Difficulty) -> Color {
        switch d {
        case .easy: return .green
        case .moderate: return .yellow
        case .hard: return .orange
        case .expert: return .red
        case .unknown: return AppTheme.textTertiary
        }
    }

    var ascentRangeLabel: String {
        let conv: (Double) -> Int = unitsAreImperial
            ? { Int(($0 * UnitConstants.feetPerMeter).rounded()) }
            : { Int($0.rounded()) }
        let unit = unitsAreImperial ? "ft" : "m"
        let maxLabel = maxAscentMeters < 1_999 ? "\(conv(maxAscentMeters))" : String(localized: "no max", bundle: LanguageManager.appBundle)
        return "\(conv(minAscentMeters))–\(maxLabel) \(unit)"
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
        }
        .padding(12)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var locationHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "location.slash.fill")
                .foregroundStyle(AppTheme.textSecondary)
            Text(String(localized: "Waiting for a GPS fix. Trail search needs your current location to know where to look. Step outdoors or near a window.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(12)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Logic

    var unitsAreImperial: Bool {
        UnitsPreferenceStore.current.resolved == .imperial
    }

    var lengthRangeLabel: String {
        if unitsAreImperial {
            let lo = minLengthKm * 0.6214
            let hi = maxLengthKm * 0.6214
            return String(format: "%.0f–%.0f mi", locale: .current, lo, hi)
        }
        return "\(Int(minLengthKm))–\(Int(maxLengthKm)) km"
    }

    /// Single value label for the length steppers, in the
    /// user's units. The stepper still stores/steps in km (the trail
    /// search filter is metric); this only formats the displayed number.
    func stepperLengthLabel(_ km: Double) -> String {
        if unitsAreImperial {
            return String(format: "%.0f mi", locale: .current, km * 0.6214)
        }
        return "\(Int(km)) km"
    }

    private func runSearch() {
        guard let loc = location.currentLocation else {
            errorText = String(localized: "Need a GPS fix to search.", bundle: LanguageManager.appBundle)
            return
        }
        let f = serviceFilters()
        errorText = nil
        results = []
        isSearching = true
        Task.detached { await searchAndPublish(near: loc, filters: f) }
    }

    private func searchAndPublish(near loc: CLLocation, filters: TrailDiscoveryService.SearchFilters) async {
        do {
            let trails = try await dependencies.location.trailDiscoveryService.search(near: loc, filters: filters)
            await MainActor.run { finishSearch(trails: trails, error: nil) }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await MainActor.run { finishSearch(trails: nil, error: message) }
        }
    }

    @MainActor
    private func finishSearch(trails: [TrailDiscoveryService.DiscoveredTrail]?, error: String?) {
        if let trails { results = trails }
        errorText = error
        isSearching = false
    }

    /// Translate UI sliders into service-shape filters.
    private func serviceFilters() -> TrailDiscoveryService.SearchFilters {
        var f = filters
        f.radiusMeters = radiusKm * 1000
        f.minLengthMeters = max(0, minLengthKm) * 1000
        f.maxLengthMeters = max(minLengthKm, maxLengthKm) * 1000
        return f
    }

    private func pickTrail(_ trail: TrailDiscoveryService.DiscoveredTrail) {
        // Convert OSM coords → CLLocation track → Route. Use the trail's
        // workout-side sport so SavedRoute matching scopes correctly.
        let track = trail.trackpoints.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
        }
        let route = Route.fromGPX(name: trail.name, track: track)
        // Save to library FIRST (if requested) so road-name enrichment
        // fires before the user has even started the workout. The
        // recogniser's bidirectional matching will then pick this trail
        // up automatically on future runs.
        if savePickToLibrary,
           let polyline = WorkoutAnalyzer.encodePolyline(track: track),
           let saved = makeSavedRoute(name: trail.name, sport: trail.activity.workoutSport, polyline: polyline, route: route) {
            dependencies.location.savedRouteStore.add(saved)
            dependencies.location.savedRouteStore.enrichWithRoadNames(routeID: saved.id)
        }
        onTrailPicked(route)
        dismiss()
    }

    private func makeSavedRoute(name: String, sport: Sport, polyline: Data, route: Route) -> SavedRoute? {
        SavedRoute(
            id: UUID(),
            name: name,
            createdAt: Date(),
            sport: sport,
            encodedPolyline: polyline,
            totalDistanceMeters: route.totalDistanceMeters,
            totalAscentMeters: route.totalAscentMeters,
            totalDescentMeters: route.totalDescentMeters,
            climbCount: route.climbs.count,
            enrichedClimbs: nil  // populated by enrichWithRoadNames after add()
        )
    }
}

// MARK: - Trail row

// MARK: - Saved-route row
//
// Same visual rhythm as TrailRow so the two tabs read like the same
// surface with different sources. Distance + ascent + climb count
// instead of difficulty (saved routes don't carry an OSM difficulty
// rating). Tap-anywhere binds the route as today's pick.
private struct SavedRouteRow: View {
    let saved: SavedRoute
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) { savedRouteCard }
            .buttonStyle(.plain)
    }

    private var savedRouteCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            savedRouteTitleRow
            savedRouteStatsRow
            Text(String(localized: "Saved \(relativeSavedAt)", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var savedRouteTitleRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(saved.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(saved.sport.displayName)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            namedClimbsBadge
        }
    }

    /// Shown when at least one climb on the route resolved to a road name.
    @ViewBuilder
    private var namedClimbsBadge: some View {
        if saved.enrichedClimbs?.contains(where: { $0.roadName != nil }) ?? false {
            Image(systemName: "signpost.right.fill")
                .font(.caption)
                .foregroundStyle(AppTheme.terracotta)
        }
    }

    private var savedRouteStatsRow: some View {
        HStack(spacing: 14) {
            Label(distanceLabel, systemImage: "ruler")
            Label(ascentLabel, systemImage: "mountain.2.fill")
            Label(String(localized: "\(saved.climbCount) climb\(saved.climbCount == 1 ? "" : "s")", bundle: LanguageManager.appBundle), systemImage: "arrow.up.right")
        }
        .font(.caption2)
        .foregroundStyle(AppTheme.textSecondary)
    }

    private var distanceLabel: String {
        UnitsPreferenceStore.current.resolved.formatDistance(meters: saved.totalDistanceMeters)
    }

    private var ascentLabel: String {
        if UnitsPreferenceStore.current.resolved == .imperial {
            return String(format: "↑%d ft", Int((saved.totalAscentMeters * UnitConstants.feetPerMeter).rounded()))
        }
        return String(format: "↑%d m", Int(saved.totalAscentMeters.rounded()))
    }

    private var relativeSavedAt: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: saved.createdAt, relativeTo: Date())
    }
}

private struct TrailRow: View {
    let trail: TrailDiscoveryService.DiscoveredTrail
    let userLocation: CLLocation?
    let onPick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            trailTitleRow
            trailStatsRow
            mapPreview
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            useThisTrailButton
        }
        .padding(12)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var trailTitleRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(trail.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                trailDescriptor
            }
            Spacer()
            difficultyBadge
        }
    }

    @ViewBuilder
    private var trailDescriptor: some View {
        if let descriptor = trail.descriptor {
            Text(descriptor)
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var trailStatsRow: some View {
        HStack(spacing: 14) {
            Label(lengthLabel, systemImage: "ruler")
            distanceFromUserLabel
        }
        .font(.caption2)
        .foregroundStyle(AppTheme.textSecondary)
    }

    @ViewBuilder
    private var distanceFromUserLabel: some View {
        if let userLocation {
            Label(distanceLabel(from: userLocation), systemImage: "location")
        }
    }

    private var useThisTrailButton: some View {
        Button(action: onPick) {
            HStack {
                Image(systemName: "arrow.right.circle.fill")
                Text(String(localized: "Use this trail", bundle: LanguageManager.appBundle))
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(AppTheme.terracotta.opacity(0.12))
            .foregroundStyle(AppTheme.terracotta)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var lengthLabel: String {
        let units = UnitsPreferenceStore.current.resolved
        return units.formatDistance(meters: trail.lengthMeters)
    }

    private func distanceLabel(from loc: CLLocation) -> String {
        let units = UnitsPreferenceStore.current.resolved
        let dist = trail.distanceFrom(loc)
        return String(localized: "\(units.formatDistance(meters: dist)) away", bundle: LanguageManager.appBundle)
    }

    private var difficultyBadge: some View {
        let color: Color = {
            switch trail.difficulty {
            case .easy: return .green
            case .moderate: return .yellow
            case .hard: return .orange
            case .expert: return .red
            case .unknown: return AppTheme.textTertiary
            }
        }()
        return Text(trail.difficulty.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var mapPreview: some View {
        // SwiftUI Map with the trail polyline overlaid. Camera fits
        // automatically via `bounds(for:)` on the coordinate set.
        let region = mapRegion()
        Map(initialPosition: .region(region), interactionModes: []) {
            MapPolyline(coordinates: trail.trackpoints)
                .stroke(AppTheme.terracotta, lineWidth: 3)
        }
        .allowsHitTesting(false)
    }

    private func mapRegion() -> MKCoordinateRegion {
        let lats = trail.trackpoints.map(\.latitude)
        let lons = trail.trackpoints.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max()
        else {
            return MKCoordinateRegion(
                center: trail.centerCoord,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.4, 0.005),
                longitudeDelta: max((maxLon - minLon) * 1.4, 0.005)
            )
        )
    }
}

// MARK: - SearchLocationProbe
//
// Lightweight CoreLocation wrapper just for the discover sheet — gets
// a single fix and drops the request when the sheet closes. We don't
// need continuous tracking for trail search; one location is enough.
@MainActor
@Observable
private final class SearchLocationProbe: NSObject, CLLocationManagerDelegate {
    var currentLocation: CLLocation?
    /// Built on first use: the view constructs this probe as `@State`, and
    /// SwiftUI evaluates that initial value on every parent render.
    @ObservationIgnored private lazy var manager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        return manager
    }()

    func start() {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.requestLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.currentLocation = loc
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No-op — the UI shows a generic "waiting for fix" hint either way.
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            Task { @MainActor in
                manager.requestLocation()
            }
        }
    }
}
