import CoreLocation
import MapKit
import SwiftUI

// MARK: - WorkoutPreflightView
//
// The Fitness tab's pre-flight ("plan + start") surface. **Single
// ScrollView, no nesting.** Reads its state from the
// `WorkoutPlanModel` injected via `.environment(_:)` so a parent
// re-render cannot wipe state mid-flow.
//
// Layout, top to bottom (per UX research — Strava / Polar Beat /
// Apple Watch Workout / AllTrails / Komoot all converged on this):
//
//   1. Sport chips, horizontal — single tap, never a navigation step
//   2. Strap status pill, top-right — colored badge, NEVER blocks the
//      screen, tap opens sensor-management sheet (not modal planning)
//   3. Route card — segmented "My routes / Find new", default My routes,
//      mini map preview, tap-to-pick. Empty state when nothing saved.
//   4. Coaching DisclosureGroup — collapsed by default, one-line
//      summary when collapsed. Holds intervals + zone + threshold
//      cues so the casual user isn't overwhelmed
//   5. Start button, directly under the sport row — dominant CTA, tap
//      fires the strap-aware start sequence (kicks reconnect if needed, waits
//      briefly, then starts). Disabled while in flight.
//
// **What this design fixes** vs the broken inline experiment:
//   • State lives on @Observable model, not @State on the view, so
//     parent re-renders can't reset sport / route / threshold picks
//   • Single ScrollView — no nested-scroll .onAppear suppression
//   • Strap is a pill, not a gate — user can plan from the couch
//   • Single Start button with explicit in-flight gate — can't
//     double-fire and produce "already in progress"
struct WorkoutPreflightView: View {
    @Environment(\.dependencies) var dependencies
    @Environment(WorkoutPlanModel.self) private var plan
    var collector: RRCollector
    /// The live workout recorder. The Start button reads its `phase`, so the
    /// body re-renders when recording transitions.
    var recorder: WorkoutRecorder
    let onStart: (Sport, Int?, WorkoutRecorder.HRSource, IntervalPlan?, [WorkoutThreshold], Route?) -> Void

    var body: some View {
        // Ordered per the Nintendo-joystick
        // playbook (research doc §"discipline of demotion"). Start is
        // the dominant CTA and sits immediately below the sport row;
        // route + coaching are progressive-disclosure surfaces beneath
        // it. Indoor sports never need a route, and most casual users
        // never need the coaching panel — both should be one tap away,
        // not in your face. Putting the route card
        // (with map preview, picker, GPX import) right under the sport
        // chips dominates the screen for sessions that don't use it.
        VStack(alignment: .leading, spacing: 14) {
            sportRow
            startButton
            routeDisclosure
            coachingDisclosure
        }
    }

    // MARK: - Section 1: sport row (chips + strap pill)

    private var sportRow: some View {
        HStack(alignment: .center, spacing: 12) {
            sportChips
            StrapStatusPill()
                .environment(collector.polarManager)
        }
    }

    private var sportChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            sportChipRow
        }
    }

    private var sportChipRow: some View {
        HStack(spacing: 6) {
            sportChipList
        }
    }

    private var sportChipList: some View {
        ForEach(Sport.allCases) { sport in
            sportChip(sport)
        }
    }

    private func sportChip(_ sport: Sport) -> some View {
        SportChip(sport: sport, isSelected: plan.selectedSport == sport) {
            plan.selectedSport = sport
        }
    }

    // MARK: - Section 2: route disclosure (collapsed by default)
    //
    // Not the top-of-screen card the original design called for: that design dominates
    // the page for indoor sports + casual users who don't pre-pick
    // routes. A disclosure instead, which:
    //   • Auto-expands when a route is already selected (user sees
    //     their pick at a glance)
    //   • Shows a one-line summary when collapsed: "Today's route ·
    //     [Route name]" or "Today's route · None"
    //   • Surfaces the picker + Find-a-Trail + GPX import inside the
    //     expanded body
    // Casual sleepy-user joystick test still passes: tap sport, tap
    // start, done. No route required.

    private var routeDisclosure: some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { plan.routeExpanded || plan.selectedRoute != nil },
                set: { plan.routeExpanded = $0 }
            )
        ) {
            routeDisclosureBody
                .padding(.top, 8)
        } label: {
            routeDisclosureLabel
        }
        .tint(AppTheme.fitnessAccent)
        .padding(12)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var routeDisclosureBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let route = plan.selectedRoute {
                BoundRouteSummary(route: route)
            } else {
                RoutePicker(plan: plan)
            }
        }
    }

    private var routeDisclosureLabel: some View {
        HStack {
            Image(systemName: "map.fill")
                .foregroundStyle(AppTheme.fitnessAccent)
            Text(String(localized: "Today's route", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Text(routeSummary)
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            clearRouteButton
        }
    }

    @ViewBuilder
    private var clearRouteButton: some View {
        if plan.selectedRoute != nil {
            Button(String(localized: "Clear", bundle: LanguageManager.appBundle)) {
                plan.selectedRoute = nil
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(AppTheme.textTertiary)
        }
    }

    /// One-line summary shown next to the collapsed disclosure label.
    /// Mirrors the `coachingSummary` pattern.
    private var routeSummary: String {
        if let route = plan.selectedRoute {
            return route.name
        }
        return String(localized: "None", bundle: LanguageManager.appBundle)
    }

    // MARK: - Section 3: coaching DisclosureGroup

    private var coachingRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            IntervalsRow(plan: plan)
            Divider()
            TargetZoneRow(plan: plan)
            Divider()
            ThresholdsRow(plan: plan)
        }
        .padding(.top, 8)
    }

    private var coachingDisclosure: some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { plan.coachingExpanded },
                set: { plan.coachingExpanded = $0 }
            )
        ) {
            coachingRows
        } label: {
            coachingDisclosureLabel
        }
        // fitnessAccent, not terracotta. The terracotta
        // color reads as warning/destructive on a fitness surface; the
        // user wants the page to feel like the cool-blue Coach tab.
        // Coaching is an action affordance, not a warning.
        .tint(AppTheme.fitnessAccent)
        .padding(12)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var coachingDisclosureLabel: some View {
        HStack {
            Image(systemName: "ear.badge.waveform")
                .foregroundStyle(AppTheme.fitnessAccent)
            Text(String(localized: "Coaching", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Text(coachingSummary)
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    /// Single-line summary that surfaces under the collapsed
    /// DisclosureGroup label so the user knows what's set without
    /// expanding. "Off" when nothing's configured.
    private var coachingSummary: String {
        var parts: [String] = []
        if let z = plan.selectedTargetZone { parts.append("Z\(z)") }
        if let p = plan.selectedPlan { parts.append(p.displayName) }
        if !plan.selectedThresholds.isEmpty {
            parts.append(String(localized: "\(plan.selectedThresholds.count) cues", bundle: LanguageManager.appBundle))
        }
        return parts.isEmpty ? String(localized: "Off", bundle: LanguageManager.appBundle) : parts.joined(separator: " · ")
    }

    // MARK: - Start button

    private var startButton: some View {
        let phase = recorder.phase
        let canTap = plan.canStart(recorderPhase: phase)
        return Button {
            // Stamp the tap time so the recorder can compute
            // total tap-to-voice latency. Anything > 1 s here is a bug we
            // need to chase. The recorder reads this in `start()`.
            dependencies.collection.workoutStartLatencyTracker.recordTap()
            Task { await runStartSequence() }
        } label: {
            startButtonLabel(canTap: canTap)
        }
        .buttonStyle(.plain)
        .disabled(!canTap)
        .accessibilityIdentifier("fitness.start")
    }

    private func startButtonLabel(canTap: Bool) -> some View {
        HStack {
            if plan.startInProgress {
                ProgressView().tint(.white)
                Text(plan.startProgressLabel.isEmpty ? String(localized: "Starting…", bundle: LanguageManager.appBundle) : plan.startProgressLabel)
                    .fontWeight(.semibold)
            } else {
                Image(systemName: "play.fill")
                Text(startCTALabel)
                    .fontWeight(.semibold)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 60) // 60pt full-width
        // Sport-color background (varies per
        // selected sport). Falls back to fitnessAccent if a sport
        // has no defined color. Disabled state stays neutral.
        .background(canTap ? plan.selectedSport.themeColor : Color.gray.opacity(0.4))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    private var startCTALabel: String {
        let verb: String = {
            switch plan.selectedSport {
            case .walk, .hike: return String(localized: "Start \(plan.selectedSport.localizedName)", bundle: LanguageManager.appBundle)
            case .run, .trailRun: return String(localized: "Start \(plan.selectedSport.localizedName)", bundle: LanguageManager.appBundle)
            case .bike, .indoorBike: return String(localized: "Start \(plan.selectedSport.localizedName)", bundle: LanguageManager.appBundle)
            case .treadmill: return String(localized: "Start Treadmill", bundle: LanguageManager.appBundle)
            case .row: return String(localized: "Start Row", bundle: LanguageManager.appBundle)
            case .airBike, .crossFit: return String(localized: "Start \(plan.selectedSport.localizedName)", bundle: LanguageManager.appBundle)
            }
        }()
        return verb
    }

    // MARK: - Start sequence

    /// Strap-aware start: kicks Polar reconnect if the user has a
    /// paired device that's currently disconnected, then calls the supplied
    /// start callback with the resolved source. Falls back to Watch if the
    /// strap can't come back. Gates the button so the user can't double-fire.
    ///
    /// Two-stage guard — `startInProgress` prevents double-fire from a rapid
    /// second tap during the strap-reconnect window; `recorder.phase` prevents
    /// firing AT ALL when a workout is already mid-flight (e.g. user came from
    /// background while already recording, or the body switch to
    /// FitnessRecordingView hadn't propagated yet). Either being false silently
    /// exits — we never throw `alreadyRecording` to the user from a mis-timed
    /// tap.
    private func runStartSequence() async {
        guard plan.canStart(recorderPhase: recorder.phase) else { return }
        plan.startInProgress = true
        defer { plan.startInProgress = false }
        let source = resolveSourceAndReconnect()
        // Hand off to the recorder via the callback the tab provided.
        // The tab handles the routing to FitnessRecordingView.
        onStart(
            plan.selectedSport,
            plan.selectedTargetZone,
            source,
            plan.selectedPlan,
            plan.selectedThresholds,
            plan.selectedRoute
        )
    }

    /// No connect-poll. User direction:
    /// "Fitness apps just start the workout. why can't this one?" Apple Fitness
    /// / Strava / Garmin Connect all start the timer the instant the user taps;
    /// the sensor connects in the background and HR appears when it appears.
    /// A flow that blocks the start button for up to 4.6 seconds
    /// (`Connecting H10…` poll + 600 ms fallback wait) reads to the user as
    /// the app being broken.
    ///
    /// Kick off the reconnect attempt fire-and-forget (no wait), and hand
    /// the source through to the recorder as-is. The recorder tolerates a
    /// disconnected-but-paired strap (see `WorkoutRecorder.start`); it
    /// schedules `startStreaming` once the connection lands rather than
    /// throwing. HR/RR start flowing when the strap is ready — usually within
    /// 1–2 seconds — and the workout timer never pauses for it.
    private func resolveSourceAndReconnect() -> WorkoutRecorder.HRSource {
        let polar = collector.polarManager
        let source = plan.resolvedSource(
            strapConnected: polar.connectionState == .connected,
            hasKnownStrap: !polar.knownDevices.isEmpty
        )
        if source == .strap, polar.connectionState != .connected, !polar.knownDevices.isEmpty {
            polar.connectToLastDevice()
        }
        return source
    }
}

// MARK: - Sport chip

private struct SportChip: View {
    let sport: Sport
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            chipLabel
        }
        .buttonStyle(.plain)
        // Keyed to the sport, not its display name. A UI
        // test selected these chips with `label CONTAINS "Run"`, which is both
        // localized and ambiguous ("Run" also matches "Trail Run").
        .accessibilityIdentifier("fitness.sport.\(sport.rawValue)")
    }

    @ViewBuilder
    private var chipLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: sport.icon)
                .font(.caption)
            Text(sport.localizedName)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? AppTheme.fitnessAccent : AppTheme.cardBackground)
        .foregroundStyle(isSelected ? .white : AppTheme.textPrimary)
        .clipShape(Capsule())
        .overlay(
            Capsule().strokeBorder(
                isSelected ? .clear : AppTheme.fitnessAccent.opacity(0.3),
                lineWidth: 1
            )
        )
    }
}

// MARK: - Strap status pill
//
// Colour-coded — green when connected and heart rate is arriving, amber
// when paired-but-not-connected or connected with no heart rate yet, gray
// when no strap paired. Tap opens the sensor-management sheet, which says
// which. Never blocks anything.

private struct StrapStatusPill: View {
    @Environment(PolarManager.self) var polarManager
    @Environment(WorkoutPlanModel.self) private var plan

    var body: some View {
        Button {
            plan.sensorSheetPresented = true
        } label: {
            pillLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("fitness.strapPill")
    }

    private var pillLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.18))
        .foregroundStyle(color)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 1))
        // 44pt touch target around the small capsule.
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    /// Connected-but-no-beats gets its own glyph, so the state isn't carried
    /// by colour alone.
    private var icon: String {
        switch polarManager.connectionState {
        case .connected:
            polarManager.feedStatus == .live ? "sensor.tag.radiowaves.forward.fill" : "exclamationmark.triangle.fill"
        default:
            polarManager.knownDevices.isEmpty ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right"
        }
    }

    /// The short label plus, once connected, whether heart rate is arriving.
    private var accessibilityText: String {
        guard polarManager.connectionState == .connected else { return label }
        let status = ConnectionStatusBadge.content(
            state: .connected, feed: polarManager.feedStatus, heartRate: polarManager.currentHeartRate
        ).text
        return label + ", " + status
    }

    private var label: String {
        switch polarManager.connectionState {
        case .connected:
            // The connected model, from `connectedDeviceType`. Short label,
            // no "Polar" prefix — the pill is small and "Polar Verity Sense"
            // wraps. Falls back to "Strap" when the type isn't resolved yet
            // (briefly, between connect and the device-info read).
            switch polarManager.connectedDeviceType {
            case .h10: return "H10"
            case .veritySense: return "Verity"
            case nil: return String(localized: "Strap", bundle: LanguageManager.appBundle)
            }
        case .connecting: return String(localized: "Connecting…", bundle: LanguageManager.appBundle)
        case .scanning: return String(localized: "Scanning…", bundle: LanguageManager.appBundle)
        case .disconnected:
            return polarManager.knownDevices.isEmpty ? String(localized: "No strap", bundle: LanguageManager.appBundle) : String(localized: "Tap to connect", bundle: LanguageManager.appBundle)
        }
    }

    /// Connected is green only once beats are arriving; a strap still setting
    /// up reads orange, as the Record tab's badge does.
    private var color: Color {
        switch polarManager.connectionState {
        case .connected:
            return ConnectionStatusBadge.content(
                state: .connected, feed: polarManager.feedStatus, heartRate: polarManager.currentHeartRate
            ).color
        case .connecting, .scanning: return .blue
        case .disconnected:
            return polarManager.knownDevices.isEmpty ? .gray : .orange
        }
    }
}

// MARK: - Bound route summary (when a route IS picked)

private struct BoundRouteSummary: View {
    let route: Route

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            mapPreview
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 14) {
                Label(distanceLabel, systemImage: "ruler")
                Label(ascentLabel, systemImage: "mountain.2.fill")
                Label(String(localized: "\(route.climbs.count) climbs", bundle: LanguageManager.appBundle), systemImage: "arrow.up.right")
            }
            .font(.caption2)
            .foregroundStyle(AppTheme.textSecondary)
            Text(route.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
        }
    }

    private var distanceLabel: String {
        UnitsPreferenceStore.current.resolved.formatDistance(meters: route.totalDistanceMeters)
    }

    private var ascentLabel: String {
        if UnitsPreferenceStore.current.resolved == .imperial {
            return String(format: "↑%d ft", Int((route.totalAscentMeters * UnitConstants.feetPerMeter).rounded()))
        }
        return String(format: "↑%d m", Int(route.totalAscentMeters.rounded()))
    }

    @ViewBuilder
    private var mapPreview: some View {
        let coords = route.trackpoints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        if coords.count >= 2 {
            Map(initialPosition: .region(region(for: coords)), interactionModes: []) {
                MapPolyline(coordinates: coords)
                    .stroke(AppTheme.fitnessAccent, lineWidth: 3)
            }
            .allowsHitTesting(false)
        } else {
            Color.gray.opacity(0.2)
        }
    }

    private func region(for coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        MapBoundsHelper.region(for: coords, paddingFactor: 1.4, minimumDelta: 0.005)
    }
}

// MARK: - Route picker (when no route is bound)
//
// Renders saved routes prominently if any exist (per research:
// "saved routes lead, discover follows"). Empty state shows the
// "Find a trail" button as the dominant CTA.

private struct RoutePicker: View {
    @Environment(\.dependencies) var dependencies
    let plan: WorkoutPlanModel
    private var savedStore: SavedRouteStore { dependencies.location.savedRouteStore }
    @State private var showingDiscoverSheet = false
    @State private var showingGPXImporter = false
    @State private var gpxImportError: String?

    var body: some View {
        withRouteImporters(pickerStack)
    }

    private var pickerStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            let saved = savedStore.routes(for: plan.selectedSport)
            savedRoutesSection(saved)
            routeActionButtons
            Text(String(localized: "Or just go — record now, save the path as a route at the end.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    // The two ways a route can arrive from outside the picker: the trail
    // discovery sheet and a GPX file. Both land on `plan.selectedRoute`.
    private func withRouteImporters(_ content: some View) -> some View {
        content
            .sheet(isPresented: $showingDiscoverSheet) {
                DiscoverTrailsView { route in
                    plan.selectedRoute = route
                }
            }
            .fileImporter(
                isPresented: $showingGPXImporter,
                allowedContentTypes: [.init(filenameExtension: "gpx") ?? .data, .xml, .data],
                allowsMultipleSelection: false
            ) { result in
                importGPX(result)
            }
            .alert(
                String(localized: "Import failed", bundle: LanguageManager.appBundle),
                isPresented: Binding(get: { gpxImportError != nil }, set: { if !$0 { gpxImportError = nil } })
            ) { gpxErrorDismiss } message: { Text(gpxImportError ?? "") }
    }

    private var gpxErrorDismiss: some View {
        Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) { gpxImportError = nil }
    }

    /// GPX arrives as a security-scoped URL; the access has to be released on
    /// every path out, which is why the `defer` sits beside the open.
    private func importGPX(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let parsed = try GPXImporter.parse(data: data, defaultSport: plan.selectedSport)
            let name = url.deletingPathExtension().lastPathComponent
            plan.selectedRoute = Route.fromGPX(name: name, track: parsed.track)
        } catch {
            debugLog("[Preflight] GPX import failed: \(error)")
            gpxImportError = String(localized: "Couldn't read that GPX file. Check that it contains a track and try again.", bundle: LanguageManager.appBundle)
        }
    }

    private var routeActionButtons: some View {
        HStack(spacing: 8) {
            findTrailButton
                // The trail search. A UI test was looking
                // for a button labelled "Discover", copy this control has not
                // carried in some time; it reported the feature as "not
                // exposed in this build" and skipped every run.
                .accessibilityIdentifier("fitness.findTrail")
            gpxImportButton
        }
    }

    private var gpxImportButton: some View {
        Button {
            showingGPXImporter = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.fill")
                Text(String(localized: "GPX", bundle: LanguageManager.appBundle))
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: 80)
            .padding(.vertical, 8)
            .background(AppTheme.background.opacity(0.5))
            .foregroundStyle(AppTheme.textSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var findTrailButton: some View {
        Button {
            showingDiscoverSheet = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "binoculars.fill")
                Text(String(localized: "Find a trail", bundle: LanguageManager.appBundle))
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(AppTheme.fitnessAccent.opacity(0.12))
            .foregroundStyle(AppTheme.fitnessAccent)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func savedRoutesSection(_ saved: [SavedRoute]) -> some View {
        if !saved.isEmpty {
            Text(String(localized: "My routes for \(plan.selectedSport.localizedName.lowercased())", bundle: LanguageManager.appBundle))
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)
            savedRouteCarousel(saved)
        } else {
            Text(String(localized: "No saved routes for \(plan.selectedSport.localizedName.lowercased()) yet. Save your first walk at the end and it appears here.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func savedRouteCarousel(_ saved: [SavedRoute]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            savedRouteRow(saved)
        }
    }

    private func savedRouteRow(_ saved: [SavedRoute]) -> some View {
        LazyHStack(spacing: 8) {
            savedRouteCards(saved)
        }
    }

    private func savedRouteCards(_ saved: [SavedRoute]) -> some View {
        ForEach(saved.prefix(8)) { savedRoute in
            savedRouteCard(savedRoute)
        }
    }

    private func savedRouteCard(_ savedRoute: SavedRoute) -> some View {
        SavedRouteCarouselCard(saved: savedRoute) {
            plan.selectedRoute = savedRoute.toRoute()
        }
    }
}

private struct SavedRouteCarouselCard: View {
    let saved: SavedRoute
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            cardBody
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(saved.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
            metricsLine
        }
        .padding(8)
        .frame(width: 140, alignment: .leading)
        .background(AppTheme.background.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(AppTheme.fitnessAccent.opacity(0.3), lineWidth: 1)
        )
    }

    private var metricsLine: some View {
        HStack(spacing: 6) {
            Text(distanceLabel)
            Text(String(localized: "·", bundle: LanguageManager.appBundle))
            Text(ascentLabel)
        }
        .font(.caption2)
        .foregroundStyle(AppTheme.textSecondary)
    }

    private var distanceLabel: String {
        UnitsPreferenceStore.current.resolved.formatDistance(meters: saved.totalDistanceMeters)
    }

    private var ascentLabel: String {
        UnitsPreferenceStore.current.resolved == .imperial
            ? "↑\(Int((saved.totalAscentMeters * UnitConstants.feetPerMeter).rounded()))ft"
            : "↑\(Int(saved.totalAscentMeters.rounded()))m"
    }
}

// MARK: - Coaching sub-rows

private struct IntervalsRow: View {
    let plan: WorkoutPlanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Structured intervals", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)
            intervalChips
        }
    }

    private var intervalChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            intervalChipRow
        }
    }

    private var intervalChipRow: some View {
        HStack(spacing: 6) {
            chip(label: String(localized: "Free-form", bundle: LanguageManager.appBundle), isSelected: plan.selectedPlan == nil) {
                plan.selectedPlan = nil
            }
            intervalPresetChips
        }
    }

    private var intervalPresetChips: some View {
        ForEach(IntervalPlan.presets) { preset in
            chip(label: preset.displayName, isSelected: plan.selectedPlan?.id == preset.id) {
                plan.selectedPlan = preset
            }
        }
    }

    private func chip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? AppTheme.fitnessAccent : AppTheme.background.opacity(0.5))
                .foregroundStyle(isSelected ? .white : AppTheme.textSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct TargetZoneRow: View {
    let plan: WorkoutPlanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Target HR zone", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)
            zoneChipRow
        }
    }

    private var zoneChipRow: some View {
        HStack(spacing: 6) {
            chip(label: String(localized: "Off", bundle: LanguageManager.appBundle), zone: nil)
            ForEach(1 ... 5, id: \.self) { z in
                chip(label: "Z\(z)", zone: z)
            }
        }
    }

    private func chip(label: String, zone: Int?) -> some View {
        let isSelected = plan.selectedTargetZone == zone
        return Button {
            plan.selectedTargetZone = zone
        } label: {
            Text(label)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? AppTheme.fitnessAccent : AppTheme.background.opacity(0.5))
                .foregroundStyle(isSelected ? .white : AppTheme.textSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ThresholdsRow: View {
    @Bindable var plan: WorkoutPlanModel
    @State private var plainText: String = ""
    /// Set when the last text tried could not be read as a cue; cleared as
    /// soon as the text changes.
    @State private var cueUnrecognized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Smart cues", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)
            cueList
            cueEntryRow
            unrecognizedCueNote
        }
        .onChange(of: plainText) { _, _ in cueUnrecognized = false }
    }

    @ViewBuilder
    private var unrecognizedCueNote: some View {
        if cueUnrecognized {
            Text(String(localized: "Couldn't read that cue. Include a number with a time, distance, climb, grade or heart rate, as in the example.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.wongAttentionText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cueEntryRow: some View {
        HStack(spacing: 6) {
            TextField(String(localized: "e.g. tell me when 30 minutes have passed", bundle: LanguageManager.appBundle), text: $plainText, axis: .vertical)
                .lineLimit(1 ... 2)
                .font(.caption2)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.background.opacity(0.5)))
            addCueButton
        }
    }

    private var addCueButton: some View {
        Button {
            addThreshold()
        } label: {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(plainText.trimmingCharacters(in: .whitespaces).isEmpty
                    ? AppTheme.textTertiary
                    : AppTheme.fitnessAccent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Add cue", bundle: LanguageManager.appBundle))
        .disabled(plainText.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var cueList: some View {
        ForEach(plan.selectedThresholds) { t in
            cueRow(t)
        }
    }

    private func cueRow(_ t: WorkoutThreshold) -> some View {
        HStack {
            Text(summary(of: t))
                .font(.caption2)
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            removeCueButton(t)
        }
    }

    private func removeCueButton(_ t: WorkoutThreshold) -> some View {
        Button {
            plan.selectedThresholds.removeAll { $0.id == t.id }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(AppTheme.textTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Remove cue", bundle: LanguageManager.appBundle))
    }

    /// Only text the cue engine can evaluate is saved. Unparsed text used to
    /// be kept as a natural-language cue, which nothing ever fires.
    private func addThreshold() {
        let raw = plainText.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        guard let new = WorkoutThreshold.parsePlainText(raw) else {
            cueUnrecognized = true
            return
        }
        plan.selectedThresholds.append(new)
        plainText = ""
    }

    private func summary(of t: WorkoutThreshold) -> String {
        if t.metric == .naturalLanguage {
            return "🗣 \(t.naturalLanguageText ?? t.userCue ?? "")"
        }
        let op = t.condition == .greaterThan ? String(localized: "above", bundle: LanguageManager.appBundle) : String(localized: "below", bundle: LanguageManager.appBundle)
        return String(localized: "\(t.metric.rawValue) \(op) \(Int(t.value)) for \(t.debounceSec)s", bundle: LanguageManager.appBundle)
    }
}

// MARK: - Sport theme colors
//
// Per-sport color identity for the Start button background. Lives in a
// SwiftUI extension so the `Sport` model stays Foundation-only. Picked
// from the existing AppTheme palette so the colors track the user's
// theme switch.
extension Sport {
    @MainActor var themeColor: Color {
        switch self {
        case .run: return AppTheme.terracotta            // warm coral — the canonical "Run" color
        case .trailRun: return AppTheme.wongAttention   // brighter coral for trail
        case .walk: return AppTheme.sage                 // calm green — walks are easy
        case .hike: return AppTheme.wongOptimal         // forest teal-green for hikes
        case .bike: return AppTheme.primary              // user's accent for cycling
        case .indoorBike: return AppTheme.primaryDark   // dimmer accent for indoor
        case .treadmill: return AppTheme.primaryLight
        case .row: return AppTheme.dustyRose
        case .airBike: return AppTheme.primaryDark   // reuse indoor-cycling accent
        case .crossFit: return AppTheme.dustyRose    // reuse rowing accent
        }
    }
}
