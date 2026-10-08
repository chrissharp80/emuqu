import CoreLocation
import SwiftUI
import UIKit

// MARK: - Get Me Back
//
// Offline-first navigation back to a breadcrumb origin. The user
// engages this at the trailhead; later when they need to come back,
// they tap "Lead me back" and an arrow on screen physically points
// toward the origin. Hold the phone flat (heading is magnetic compass,
// not GPS course), rotate body until the arrow points up the screen,
// walk that direction. Without a valid compass heading the arrow is
// hidden and the bearing from north is shown in words instead.
//
// **Honest accuracy.** When `horizontalAccuracy` is poor (canopy,
// canyon, weak GPS) the arrow visually fuzzes and the accuracy ribbon
// at the top tells the user exactly what's happening. Above 100 m the
// arrow disappears entirely and we display "Wait for a better fix" —
// pointing the user in a wrong direction is worse than not pointing
// them at all.
//
// **AI is optional.** This view runs entirely offline. The breadcrumb
// store is on-device, the arrow math is local, magnetic compass is
// hardware. Network-dependent layers (reverse-geocoded origin label,
// AI commentary, MKDirections turn-by-turn) are bonuses and never
// load-bearing.
//
// **Liability boundary.** Marketing as a safety feature creates
// reliance; the disclaimer modal in the dashboard entry point is
// where we set that expectation. Once they're inside this view, we
// keep them honest about accuracy — we never project false confidence.

struct GetMeBackView: View {
    @Environment(\.dependencies) var dependencies
    private var recorder: BreadcrumbRecorder { dependencies.location.breadcrumbRecorder }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showClearConfirm = false
    @State private var showSOSConfirm = false
    /// The number the SOS confirmation shows, fixed when SOS is tapped so the
    /// call goes to the number the user confirmed even if a geocode lands
    /// while the alert is up.
    @State private var sosDialNumber = GetMeBackView.emergencyNumber(currentCountry: nil)
    /// Voice chat reaches a cloud AI like the chat tab does, so it is held
    /// behind the same disclaimer the chat tab shows on first open.
    @State private var showAIDisclaimer = false
    /// Shown when opening the `tel://` URL fails (e.g. iPad /
    /// non-cellular device): dialling silently no-ops otherwise, leaving
    /// the user in a stress moment thinking the call went through.
    @State private var showDialFailedAlert = false
    /// Whether the user has opened the "settings" pull-down within
    /// this view (brightness slider lives here so it's not in the way
    /// of the primary navigation surface).
    @State private var showSettings = false
    /// User-tunable screen brightness override while this view is on
    /// screen. Default = system brightness; they can drag the slider
    /// to dim and save battery, but the change reverts when the view
    /// dismisses so we don't permanently mess with their phone.
    @State private var brightnessOverride: Double = Double(UIScreen.main.brightness)
    @State private var systemBrightnessAtAppear: CGFloat = UIScreen.main.brightness
    @State private var didSetBrightnessOverride = false

    /// Surface a banner + Settings deep-link when
    /// location authorization is denied / restricted. Without this, the
    /// view shows "Wait for a better GPS fix" forever and the user has
    /// no in-app path to fix it.
    ///
    /// Not `@State ... = CLLocationManager().authorizationStatus`:
    /// a `@State` default expression is evaluated on EVERY construction of the
    /// view struct — SwiftUI keeps only the first value, but the expression
    /// still runs — so a fresh `CLLocationManager` would be built on every
    /// body re-evaluation of the parent, on a screen that re-renders with each
    /// location fix. Read once at appear instead.
    ///
    /// `BreadcrumbRecorder` already publishes this and refreshes it from
    /// `locationManagerDidChangeAuthorization`, which CoreLocation calls when
    /// the user flips permission in Settings — strictly more reliable than
    /// re-reading on a foreground notification.
    private var locationDenied: Bool {
        switch recorder.authorizationStatus {
        case .denied, .restricted: return true
        default: return false
        }
    }

    // MARK: - Derived

    private var trail: BreadcrumbTrail? { recorder.activeTrail }
    private var originFix: BreadcrumbFix? { trail?.origin }
    private var latestLocation: CLLocation? { recorder.latestLocation }
    private var latestHeading: CLHeading? { recorder.latestHeading }

    /// The country the user is in now, from the reverse geocode the ambient
    /// location service keeps current while this screen is open. Nil with no
    /// fix, with no geocode (offline), or when the last geocode is too far
    /// from the current fix to vouch for the country.
    private var currentCountryCode: String? {
        Self.countryCode(of: dependencies.location.roadGeocodingService.current, at: latestLocation)
    }

    /// The number the SOS button dials, for where the user is now.
    private var sosNumber: String {
        Self.emergencyNumber(currentCountry: currentCountryCode)
    }

    /// Distance in meters from the user's current location to the
    /// origin fix. nil when we don't have either side.
    private var distanceToOriginMeters: Double? {
        guard let here = latestLocation, let origin = originFix else { return nil }
        return here.distance(from: origin.asCLLocation)
    }

    /// True bearing in degrees from the user's current location to the
    /// origin. nil when we don't have either. North = 0.
    private var bearingToOriginDegrees: Double? {
        guard let here = latestLocation?.coordinate, let origin = originFix?.coordinate else { return nil }
        return Self.bearing(from: here, to: origin)
    }

    /// The compass has produced a usable true heading. False on devices
    /// without a magnetometer, before the first heading arrives, and while
    /// the reading is invalid (negative heading or accuracy).
    private var hasValidHeading: Bool {
        guard let heading = latestHeading else { return false }
        return heading.trueHeading >= 0 && heading.headingAccuracy >= 0
    }

    /// Arrow rotation = bearing-to-origin minus current device heading.
    /// When the result is 0° the origin is straight ahead (arrow up). Only
    /// meaningful with a valid heading; the arrow is hidden otherwise.
    private var arrowRotationDegrees: Double {
        guard let bearing = bearingToOriginDegrees,
              hasValidHeading,
              let heading = latestHeading?.trueHeading
        else { return 0 }
        let raw = bearing - heading
        // Normalize to (-180, 180] for a clean `Angle` rotation.
        let mod = (raw.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        return mod > 180 ? mod - 360 : mod
    }

    /// Latest accuracy. Nil when there is no fix — handled in `accuracyState`.
    /// Not a `.greatestFiniteMagnitude` sentinel: that is finite, so an
    /// `isFinite` guard downstream does not catch it and `Int()` of it traps.
    /// See `GPSAccuracyLevel`.
    private var currentAccuracyMeters: Double? {
        latestLocation?.horizontalAccuracy
    }

    private var accuracyState: AccuracyState {
        AccuracyState(GPSAccuracyLevel.classify(horizontalAccuracyMetres: currentAccuracyMeters))
    }

    /// Headline text under the arrow. Always honest about which mode
    /// we're in: "wait", "fuzzy", or a real distance.
    private var headlineText: String {
        if recorder.activeTrail == nil {
            return String(localized: "No active trail", bundle: LanguageManager.appBundle)
        }
        if originFix == nil {
            return String(localized: "Waiting for origin fix…", bundle: LanguageManager.appBundle)
        }
        switch accuracyState {
        case .waiting:
            return String(localized: "Wait for a better GPS fix", bundle: LanguageManager.appBundle)
        case .good, .ok, .poor:
            if let dist = distanceToOriginMeters {
                return UnitsPreferenceStore.current.resolved.formatDistance(meters: dist)
            }
            return "—"
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            withLifecycle(withAlerts(trailStack))
        }
    }

    private var trailStack: some View {
        VStack(spacing: 16) {
            if locationDenied {
                locationDeniedBanner
            }
            accuracyRibbon
            Spacer(minLength: 0)
            arrowDial
            headline
            Spacer(minLength: 0)
            actionsRow
            if showSettings {
                settingsPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .navigationTitle(String(localized: "Get Me Back", bundle: LanguageManager.appBundle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { trailToolbar }
    }

    @ToolbarContentBuilder
    private var trailToolbar: some ToolbarContent {
        settingsToolbarItem
        ToolbarItem(placement: .topBarLeading) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) { dismiss() }
        }
    }

    private var settingsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            settingsToggleButton
        }
    }

    private var settingsToggleButton: some View {
        Button {
            withAnimation { showSettings.toggle() }
        } label: {
            Image(systemName: showSettings ? "chevron.up.circle" : "slider.horizontal.3")
        }
        .accessibilityLabel(String(localized: "Settings", bundle: LanguageManager.appBundle))
    }

    private func startVoiceChat() {
        Task { @MainActor in
            await dependencies.assistant.voiceConversationController.start()
        }
    }

    private var aiDisclaimerSheet: some View {
        DisclaimerSheet(
            isPresented: $showAIDisclaimer,
            onAccept: {
                dependencies.assistant.assistantViewModel.hasAcceptedDisclaimer = true
                startVoiceChat()
            }
        )
        .interactiveDismissDisabled()
    }

    /// End-trail, SOS and dial-failure confirmations.
    /// Ending a trail is the one destructive choice here, so it gets its own
    /// function; SOS and the dial-failure notice ride along.
    private func withAlerts(_ content: some View) -> some View {
        withEndTrailAlert(content)
            .sheet(isPresented: $showAIDisclaimer) { aiDisclaimerSheet }
            .alert(String(localized: "Call emergency services?", bundle: LanguageManager.appBundle), isPresented: $showSOSConfirm) {
                Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
                Button(String(localized: "Call emergency services", bundle: LanguageManager.appBundle), role: .destructive) { dialEmergencyServices() }
            } message: {
                Text(verbatim: Self.sosConfirmMessage(dialling: sosDialNumber))
            }
            .alert(String(localized: "Can't place the call", bundle: LanguageManager.appBundle), isPresented: $showDialFailedAlert) {
                Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) {}
            } message: {
                Text(verbatim: Self.dialFailedMessage(dialling: sosDialNumber))
            }
    }

    private func withEndTrailAlert(_ content: some View) -> some View {
        content
            .alert(String(localized: "End this trail?", bundle: LanguageManager.appBundle), isPresented: $showClearConfirm) {
                endTrailAlertActions
            } message: {
                Text(String(localized: "\"End and save\" stops the arrow but keeps the trail in your history, where Flo can look up where it started. \"Discard\" deletes it forever.", bundle: LanguageManager.appBundle))
            }
    }

    @ViewBuilder
    private var endTrailAlertActions: some View {
        Button(String(localized: "Keep going", bundle: LanguageManager.appBundle), role: .cancel) {}
        // Preserve-in-archive is the default destructive
        // action: ends the active session AND keeps the trail
        // in the archive, where the AI can say where it started
        // ("where did I park this morning?"). The archive holds up
        // to 50 trails, newest first.
        Button(String(localized: "End and save", bundle: LanguageManager.appBundle)) {
            recorder.endAndArchive()
            dismiss()
        }
        // Hard delete — only when the user really wants the
        // data gone (e.g. they wandered for 5 minutes by
        // accident and don't want clutter in their archive).
        Button(String(localized: "Discard", bundle: LanguageManager.appBundle), role: .destructive) {
            recorder.clearTrail()
            dismiss()
        }
    }

    private func withLifecycle(_ content: some View) -> some View {
        content
            .onAppear {
                prepareScreenState()
            }
            .onDisappear {
                resetScreenState()
            }
    }

    /// Keep-awake is gated on the user preference (default off so iOS auto-lock
    /// is honoured): they are presumably looking at the screen while walking,
    /// but a 30 s auto-lock set for battery reasons should be respected.
    ///
    /// `AmbientLocationService.start()` runs here rather than in the global
    /// foreground onChange so the "where am I now" answer and the
    /// arrow-back-to-origin display have a warm cache the moment Get-Me-Back is
    /// engaged. A restored trail resumes recording here too.
    private func prepareScreenState() {
        if dependencies.app.settingsManager.settings.shouldKeepScreenOnDuringRecording {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        dependencies.location.ambientLocationService.start()
        // A no-op without a restored trail or while already engaged.
        recorder.resume()
        systemBrightnessAtAppear = UIScreen.main.brightness
        brightnessOverride = Double(systemBrightnessAtAppear)
    }

    /// Always reset, whether or not this view set it — that covers the
    /// toggle-flip-mid-view case. Better to over-reset than leave the screen
    /// pinned awake.
    private func resetScreenState() {
        // Always reset, regardless of whether we set it — covers
        // the toggle-flip-mid-view case where we set the timer
        // to disabled, then the user changed the setting, then
        // navigated away. Better to over-reset than leave the
        // screen pinned awake.
        UIApplication.shared.isIdleTimerDisabled = false
        if didSetBrightnessOverride {
            UIScreen.main.brightness = systemBrightnessAtAppear
            didSetBrightnessOverride = false
        }
    }

    // MARK: - Sub-views

    /// In-app banner shown when location auth is
    /// denied / restricted. Without this the user sees "Wait for a better
    /// GPS fix" forever and has no path to fix it.
    @ViewBuilder
    private var locationDeniedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            locationIsOffSection
            Text(String(localized: "Get Me Back needs location to point you home. Open Settings → Privacy & Security → Location Services → Emuqu and choose While Using the App.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
            openSettingsSection
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
        .cornerRadius(8)
    }

    private var locationIsOffSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "location.slash.fill")
                .foregroundColor(.orange)
            Text(String(localized: "Location is off", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
        }
    }

    private var openSettingsSection: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            Text(String(localized: "Open Settings", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange)
                .cornerRadius(6)
        }
    }

    @ViewBuilder
    private var accuracyRibbon: some View {
        let state = accuracyState
        HStack(spacing: 8) {
            Image(systemName: state.icon)
                .foregroundStyle(state.color)
            Text(state.label(meters: currentAccuracyMeters))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            if let trail = trail {
                let count = trail.fixes.count
                Text(String(localized: "\(count) GPS points", bundle: LanguageManager.appBundle))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(state.color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    /// North-up rose ring with cardinal markers — N at top, so the user knows
    /// the arrow is in compass space, not screen space. Decorative for
    /// VoiceOver: the arrow itself announces direction.
    private var roseRing: some View {
        ZStack {
            // North-up rose ring.
            Circle()
                .strokeBorder(Color.gray.opacity(0.22), lineWidth: 1)
                .frame(width: 240, height: 240)
            // Cardinal markers — N at top so the user knows "the
            // arrow is in compass space, not screen space." Decorative
            // for VoiceOver — the arrow itself announces direction.
            ForEach(Array(Self.cardinalLetters.enumerated()), id: \.offset) { index, label in
                CardinalLabel(label: label, angle: Double(index) * 90)
            }
        }
        .accessibilityHidden(true)
    }

    /// Localized N/E/S/W letters, clockwise from north. One catalog string
    /// split on spaces, because a lone "W" key would collide with watts.
    private static var cardinalLetters: [String] {
        let letters = String(localized: "N E S W", bundle: LanguageManager.appBundle)
            .split(separator: " ").map(String.init)
        return letters.count == 4 ? letters : ["N", "E", "S", "W"]
    }

    private var arrowDial: some View {
        ZStack {
            roseRing
            // The actual arrow. Hidden without a valid compass heading: an
            // arrow pointing "up" would send the user the wrong way.
            CompassArrow(opacity: accuracyState.arrowOpacity, fuzz: accuracyState.fuzzRadius)
                .rotationEffect(.degrees(arrowRotationDegrees))
                .opacity(accuracyState == .waiting || !hasValidHeading ? 0 : 1)
                .animation(.zenInterface(.easeOut(duration: 0.3), reduceMotion: reduceMotion), value: arrowRotationDegrees)
            if accuracyState == .waiting {
                ProgressView().controlSize(.large)
            } else if !hasValidHeading {
                compassUnavailableNote
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(arrowAccessibilityLabel)
    }

    /// Shown in place of the arrow when there is no compass heading. The
    /// bearing from north still lets the user navigate with a real compass
    /// or the sun.
    private var compassUnavailableNote: some View {
        Text(compassUnavailableText)
            .font(.callout.weight(.medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(AppTheme.textSecondary)
            .frame(maxWidth: 180)
    }

    private var compassUnavailableText: String {
        guard let bearing = bearingToOriginDegrees else {
            return String(localized: "Compass unavailable", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Compass unavailable. Your start point is \(Int(bearing.rounded()))° from north.", bundle: LanguageManager.appBundle)
    }

    /// Spoken description of the direction-home arrow for VoiceOver: the
    /// distance to the origin and which way to turn, relative to where the
    /// phone is pointing, so a non-sighted user gets what the arrow shows.
    private var arrowAccessibilityLabel: String {
        if accuracyState == .waiting {
            return String(localized: "Waiting for a better GPS fix", bundle: LanguageManager.appBundle)
        }
        if !hasValidHeading {
            return compassUnavailableText
        }
        let distancePart: String
        if let dist = distanceToOriginMeters {
            distancePart = UnitsPreferenceStore.current.resolved.formatDistance(meters: dist)
        } else {
            distancePart = String(localized: "unknown distance", bundle: LanguageManager.appBundle)
        }
        guard bearingToOriginDegrees != nil else {
            return String(localized: "Origin is \(distancePart) away", bundle: LanguageManager.appBundle)
        }
        return relativeDirectionLabel(distance: distancePart)
    }

    /// `arrowRotationDegrees` is clockwise from straight ahead, so a positive
    /// angle is to the right. Within 15° reads as ahead, beyond 165° as behind.
    private func relativeDirectionLabel(distance: String) -> String {
        let angle = arrowRotationDegrees
        let degrees = Int(abs(angle).rounded())
        if degrees <= 15 {
            return String(localized: "Origin is \(distance) away, straight ahead", bundle: LanguageManager.appBundle)
        }
        if degrees >= 165 {
            return String(localized: "Origin is \(distance) away, behind you", bundle: LanguageManager.appBundle)
        }
        return angle > 0
            ? String(localized: "Origin is \(distance) away, \(degrees)° to your right", bundle: LanguageManager.appBundle)
            : String(localized: "Origin is \(distance) away, \(degrees)° to your left", bundle: LanguageManager.appBundle)
    }

    @ViewBuilder
    private var headline: some View {
        VStack(spacing: 6) {
            Text(headlineText)
                .scaledFont(size: 32, weight: .bold)
                .monospacedDigit()
            originLabel
            if let trail = trail, trail.fixes.count > 1 {
                Text(String(localized: "Walked \(UnitsPreferenceStore.current.resolved.formatDistance(meters: trail.walkedTrailLengthMeters())) out", bundle: LanguageManager.appBundle))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var originLabel: some View {
        if let trail {
            originLabelText(trail)
        }
    }

    private func originLabelText(_ trail: BreadcrumbTrail) -> some View {
        Group {
            if let label = trail.label {
                Text(String(localized: "Back to \(label)", bundle: LanguageManager.appBundle))
            } else if let resolved = trail.resolvedOriginLabel {
                Text(String(localized: "Back to \(resolved)", bundle: LanguageManager.appBundle))
            } else if let origin = trail.origin {
                Text(String(localized: "Origin: \(formatCoord(origin.coordinate))", bundle: LanguageManager.appBundle))
            }
        }
        .font(.caption)
        .foregroundStyle(AppTheme.textSecondary)
        .multilineTextAlignment(.center)
    }

    /// "Talk to AI" while a trail is active. Optional layer per
    /// spec; only active when connectivity exists. The AI sees
    /// `breadcrumb.active` so it can answer "how far back is the trailhead",
    /// "I'm getting tired, should I turn around now", "what direction is home".
    /// Network failures degrade gracefully — the offline arrow keeps working
    /// regardless. Sized at full width because in a stress moment ("I'm lost")
    /// the user should not be hunting for a small button.
    @ViewBuilder
    private var actionsRow: some View {
        VStack(spacing: 8) {
            talkToAIButton

            sosAndClearRow
        }
    }

    private var sosAndClearRow: some View {
        HStack(spacing: 12) {
            sosButton

            clearTrailButton
        }
    }

    private var clearTrailButton: some View {
        Button {
            showClearConfirm = true
        } label: {
            Label(String(localized: "Clear", bundle: LanguageManager.appBundle), systemImage: "trash")
                .frame(maxWidth: .infinity)
                .font(.callout.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(.secondary)
    }

    private var sosButton: some View {
        Button(role: .destructive) {
            sosDialNumber = sosNumber
            showSOSConfirm = true
        } label: {
            Label(String(localized: "SOS", bundle: LanguageManager.appBundle), systemImage: "exclamationmark.triangle.fill")
                .frame(maxWidth: .infinity)
                .font(.callout.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }

    private var talkToAIButton: some View {
        Button {
            if dependencies.assistant.assistantViewModel.hasAcceptedDisclaimer {
                startVoiceChat()
            } else {
                showAIDisclaimer = true
            }
        } label: {
            Label(String(localized: "Talk to AI", bundle: LanguageManager.appBundle), systemImage: "waveform.and.mic")
                .frame(maxWidth: .infinity)
                .font(.callout.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
    }

    @ViewBuilder
    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Screen brightness", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            brightnessSliderRow
            Text(String(localized: "Defaults to your system brightness. Drag down to save battery; reverts when you leave this screen.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(12)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var brightnessSliderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.min")
                .foregroundStyle(AppTheme.textSecondary)
            brightnessSlider
            Image(systemName: "sun.max.fill")
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var brightnessSlider: some View {
        Slider(
            value: Binding(
                get: { brightnessOverride },
                set: { newValue in
                    brightnessOverride = newValue
                    UIScreen.main.brightness = CGFloat(newValue)
                    didSetBrightnessOverride = true
                }
            ),
            in: 0.05 ... 1.0
        )
    }

    // MARK: - Helpers

    private func formatCoord(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.4f, %.4f", locale: LanguageManager.appLocale, c.latitude, c.longitude)
    }

    private func dialEmergencyServices() {
        // No public deep-link to iOS Emergency SOS via satellite (it's
        // gesture-only on the hardware). The best-effort escape hatch is a
        // direct `tel://` to the emergency number where the user is; the alert text
        // tells the user how to invoke satellite SOS via the side-button
        // gesture if cellular is unavailable.
        //
        // `open`'s own result decides, not `canOpenURL`. The latter answers
        // false for any scheme missing from `LSApplicationQueriesSchemes`,
        // `tel` included, so it would report "cannot dial" on every iPhone.
        guard let url = URL(string: "tel://\(sosDialNumber)") else {
            showDialFailedAlert = true
            return
        }
        UIApplication.shared.open(url) { opened in
            // Not opened (iPad, no cellular): tell the user to dial manually
            // rather than silently no-op in an emergency.
            if !opened { showDialFailedAlert = true }
        }
    }

    /// Initial great-circle bearing (forward azimuth, the atan2 formula).
    /// Good enough for the short distances the breadcrumb mode covers — a
    /// few km at most. North = 0, East = 90.
    static func bearing(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Double {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let dLon = (end.longitude - start.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radians = atan2(y, x)
        let degrees = radians * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }
}

// MARK: - Emergency numbers

extension GetMeBackView {
    /// A country's emergency number — the one that reaches rescue and
    /// an ambulance, since a lost hiker needs both. `911` is used only in the
    /// regions listed — hardcoding it would dial a dead number for the app's
    /// international users. `112` is the GSM-standard fallback and routes to
    /// local emergency services on cellular in most countries.
    ///
    /// Official sources for the numbers that differ from 112:
    /// - US and its territories 911: https://www.911.gov/
    /// - CA 911 (police, fire and ambulance):
    ///   https://rcmp.ca/en/bc/corporate-information/newcomers-guide/contact-police
    /// - MX 911 (the single number for medical, security and civil-protection
    ///   emergencies): https://www.gob.mx/911/articulos/numero-unico-de-emergencias-9-1-1
    /// - GB 999 (112 also works): https://www.nhs.uk/nhs-services/urgent-and-emergency-care-services/when-to-call-999/
    /// - IE 999 and 112 run in parallel: https://www.citizensinformation.ie/en/health/health-system/emergency-health-services-in-ireland/
    /// - HK 999 (police, fire and ambulance):
    ///   https://www.hkengage.gov.hk/en/essentials/basics/emergency-ambulance-services
    /// - NZ 111 (police, fire and ambulance):
    ///   https://www.govt.nz/browse/law-crime-and-justice/crimes-and-emergencies/111-emergency-service/
    /// - PH 911 (the unified national hotline for police, fire and medical
    ///   emergencies, run by the Emergency 911 National Office):
    ///   https://e911.gov.ph/emergency-hotline-numbers/ and
    ///   https://pia.gov.ph/news/one-number-for-all-emergencies-unified-911-to-launch-nationwide/
    /// - BR 193 (Corpo de Bombeiros: search for missing people, rescue in
    ///   hostile terrain, falls and other injuries; SAMU 192 takes illness such
    ///   as heart or breathing problems; 112 reaches the military police):
    ///   https://www.defesacivil.pr.gov.br/servicos/APMG/Emergencia/Acionar-Corpo-de-Bombeiros-193-0A30a4rk
    /// - JP 119 (fire and ambulance; police is 110), Fire and Disaster
    ///   Management Agency: https://www.fdma.go.jp/publication/portal/items/portal001_pamphiet_english.pdf
    /// - KR 119 (National Fire Agency: fire, rescue and EMS):
    ///   https://english.seoul.go.kr/seoul-citizens-call-119-every-12-8-seconds/
    /// - TW 119 (fire and ambulance; police is 110):
    ///   https://english.gov.taipei/News_Content.aspx?n=2991F84A4FAF842F&sms=CDDB6BFF96C676A7&s=58A14F503DDDA3D7
    /// - CN 120 (national medical emergency number):
    ///   https://en.nhc.gov.cn/2019-03/05/c_74520.htm
    /// - AU 000 (police, fire and ambulance; 112 reaches the same service):
    ///   https://www.infrastructure.gov.au/emergency-calls
    ///
    /// Poland is not listed: its 112 centres pass each call to the police,
    /// fire service or medical rescue (https://www.nik.gov.pl/aktualnosci/bezpieczenstwo-narodowe/telefon-alarmowy-112.html),
    /// so the default applies.
    static func emergencyNumber(region: String?) -> String {
        switch region {
        case "US", "CA", "MX", "AS", "GU", "PR", "VI", "PH": return "911"
        case "GB", "IE", "HK": return "999"
        case "AU": return "000"
        case "NZ": return "111"
        case "JP", "KR", "TW": return "119"
        case "CN": return "120"
        case "BR": return "193"
        default: return "112"
        }
    }

    /// Numbers every mobile phone treats as an emergency call wherever it is,
    /// with or without a SIM: 3GPP TS 22.101 §10.1.1 requires 112 and 911.
    static let handsetEmergencyNumbers: Set<String> = ["112", "911"]

    /// How far the user may have moved from the point last reverse-geocoded
    /// before its country no longer counts as where they are. A border can be
    /// close, and a national number such as Brazil's 193 does nothing in the
    /// next country.
    static let countryFixRadiusMeters: CLLocationDistance = 5_000

    /// The number the SOS button dials.
    ///
    /// Where the user is decides, not the phone's Region setting: a Region
    /// of Brazil would otherwise dial 193 on a hike in Portugal. With the
    /// current country known (`currentCountry`), its own number. Without it,
    /// the Region's number only when every phone routes it anywhere (911),
    /// and otherwise 112, which does too.
    static func emergencyNumber(
        currentCountry: String?, region: String? = Locale.current.region?.identifier
    ) -> String {
        if let currentCountry { return emergencyNumber(region: currentCountry) }
        let home = emergencyNumber(region: region)
        return handsetEmergencyNumbers.contains(home) ? home : "112"
    }

    /// The country of the last reverse geocode, while the user is still near
    /// the point it was made at. Nil without a fix or a geocode.
    static func countryCode(of context: RoadGeocodingService.RoadContext?, at location: CLLocation?) -> String? {
        guard let context, let location,
              context.isValid(at: location, maxDistanceMeters: countryFixRadiusMeters) else { return nil }
        return context.countryCode?.uppercased()
    }

    /// The number dialled, plus 112 when they differ: 112 reaches local
    /// emergency services from a mobile phone almost everywhere, so it is
    /// the number to try if the first does not connect.
    static func emergencyNumbersShown(dialling number: String) -> String {
        number == "112" ? number : "\(number) / 112"
    }

    /// The SOS confirmation's message: the number dialled and the side-button
    /// Emergency SOS fallback, with satellite SOS stated as conditional. On
    /// hardware that cannot call (`canPlaceCalls` false) it says to call from
    /// a phone instead: an iPad or Mac has no Emergency SOS gesture.
    static func sosConfirmMessage(dialling number: String, canPlaceCalls: Bool = deviceCanPlaceCalls) -> String {
        guard canPlaceCalls else { return callFromAPhoneMessage(dialling: number) }
        return String(format: String(
            localized: """
            This calls emergency services (%@) directly. If you can't place a call, press and hold the side button + a volume button on your iPhone to trigger Emergency SOS. \
            On iPhone 14 or later, Emergency SOS via satellite may work where there's no cellular or Wi-Fi coverage, \
            in supported countries and regions and with a clear view of the sky.
            """,
            bundle: LanguageManager.appBundle
        ), Self.emergencyNumbersShown(dialling: number))
    }

    /// Shown when the call could not be placed. On an iPhone it points to the
    /// side-button Emergency SOS; on hardware that cannot call, to a phone.
    static func dialFailedMessage(dialling number: String, canPlaceCalls: Bool = deviceCanPlaceCalls) -> String {
        guard canPlaceCalls else { return callFromAPhoneMessage(dialling: number) }
        return String(format: String(
            localized: """
            This device can't dial automatically. Dial %@ manually, or press and hold the side button + a volume button to trigger Emergency SOS. \
            On iPhone 14 or later, Emergency SOS via satellite may work where there's no cellular or Wi-Fi coverage, \
            in supported countries and regions and with a clear view of the sky.
            """,
            bundle: LanguageManager.appBundle
        ), Self.emergencyNumbersShown(dialling: number))
    }

    /// The emergency advice for an iPad or Mac, which has no phone and no
    /// Emergency SOS.
    static func callFromAPhoneMessage(dialling number: String) -> String {
        String(format: String(
            localized: "This device can't place phone calls. Call emergency services (%@) from a phone.",
            bundle: LanguageManager.appBundle
        ), Self.emergencyNumbersShown(dialling: number))
    }

    /// False on an iPad or a Mac. This iPhone app runs on iPad in
    /// compatibility mode, where `userInterfaceIdiom` still reports `.phone`,
    /// so the hardware `model` decides; `isiOSAppOnMac` covers a Mac.
    static var deviceCanPlaceCalls: Bool {
        !(ProcessInfo.processInfo.isiOSAppOnMac || UIDevice.current.model.hasPrefix("iPad"))
    }
}

// MARK: - Compass arrow shape

private struct CompassArrow: View {
    let opacity: Double
    let fuzz: CGFloat

    var body: some View {
        ZStack {
            // Soft outer glow grows with fuzz so poor fixes look less crisp
            // visually — a cue that the heading is not trustworthy to a degree.
            arrowShape
                .fill(Color.blue.opacity(0.25))
                .blur(radius: fuzz)
                .frame(width: 60, height: 180)

            arrowShape
                .fill(Color.blue.opacity(opacity))
                .frame(width: 60, height: 180)
        }
        .frame(width: 60, height: 180)
    }

    private var arrowShape: Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: -90))
            p.addLine(to: CGPoint(x: 28, y: 30))
            p.addLine(to: CGPoint(x: 0, y: 10))
            p.addLine(to: CGPoint(x: -28, y: 30))
            p.closeSubpath()
        }
    }
}

private struct CardinalLabel: View {
    let label: String
    /// Degrees clockwise from north.
    let angle: Double
    @ViewBuilder
    var body: some View {
        let offset: CGFloat = 110
        Text(verbatim: label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(AppTheme.textSecondary)
            .offset(y: -offset)
            .rotationEffect(.degrees(angle))
    }
}

// MARK: - Accuracy state

private enum AccuracyState {
    init(_ level: GPSAccuracyLevel) {
        switch level {
        case .good: self = .good
        case .ok: self = .ok
        case .poor: self = .poor
        case .waiting: self = .waiting
        }
    }

    case good, ok, poor, waiting

    var color: Color {
        switch self {
        case .good: return .green
        case .ok: return .yellow
        case .poor: return .orange
        case .waiting: return .red
        }
    }

    var icon: String {
        switch self {
        case .good: return "location.fill"
        case .ok: return "location"
        case .poor: return "location.slash"
        case .waiting: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    var arrowOpacity: Double {
        switch self {
        case .good: return 1.0
        case .ok: return 0.85
        case .poor: return 0.6
        case .waiting: return 0
        }
    }

    var fuzzRadius: CGFloat {
        switch self {
        case .good: return 0
        case .ok: return 1.5
        case .poor: return 5
        case .waiting: return 10
        }
    }

    func label(meters: Double?) -> String {
        // `.waiting` never interpolates a distance, so nothing is converted
        // for it. See `GPSAccuracyLevel.displayMetres`.
        guard let m = GPSAccuracyLevel.displayMetres(meters) else {
            return String(localized: "GPS waiting for a better fix…", bundle: LanguageManager.appBundle)
        }
        switch self {
        case .good: return String(localized: "GPS strong (±\(m)m)", bundle: LanguageManager.appBundle)
        case .ok: return String(localized: "GPS ok (±\(m)m)", bundle: LanguageManager.appBundle)
        case .poor: return String(localized: "GPS poor (±\(m)m) — interpret with care", bundle: LanguageManager.appBundle)
        case .waiting: return String(localized: "GPS waiting for a better fix…", bundle: LanguageManager.appBundle)
        }
    }
}
