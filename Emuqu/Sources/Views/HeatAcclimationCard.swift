import SwiftUI

/// Garmin-style heat-acclimatization readout on the Fitness tab. Observes
/// the shared `HeatAcclimationCache`.
///
/// Unlike a self-hiding card, this stays visible and EXPLAINS itself when it
/// can't show a number — heat tracking needs outdoor workouts with weather
/// recorded at the time, and either can be missing. Saying which ("no outdoor
/// workouts", "no recorded weather") is far more useful than vanishing.
///
/// Heat tracking is off until the user turns it on here, next to the
/// explanation of what it reads. It reads only the weather saved with each
/// workout: no location request, no network. The choice is stored in
/// `UserSettings.heatTrackingEnabled`, and the card's menu turns it back off.
struct HeatAcclimationCard: View {
    @Environment(\.dependencies) var dependencies
    private var cache: HeatAcclimationCache { dependencies.analysis.heatAcclimationCache }
    private var settingsManager: SettingsManager { dependencies.app.settingsManager }
    let temperatureUnit: TemperatureUnit

    var body: some View {
        if settingsManager.settings.heatTrackingEnabled {
            content
                .task { cache.refresh() }
        } else {
            optInCard
        }
    }

    // MARK: - Opt-in

    /// What heat tracking reads, next to the button that turns it on.
    private var optInCard: some View {
        infoCard(
            icon: "thermometer.sun.fill",
            title: String(localized: "Heat acclimatization", bundle: LanguageManager.appBundle),
            message: optInExplanation,
            action: (String(localized: "Turn on heat tracking", bundle: LanguageManager.appBundle), { self.setTracking(true) }),
            showsTrackingMenu: false
        )
    }

    private var optInExplanation: String {
        String(localized: "Heat tracking estimates how adapted you are to heat from the temperature and humidity saved with your outdoor workouts when you recorded them. Workouts without saved weather are left out. Nothing is looked up or sent.", bundle: LanguageManager.appBundle)
    }

    /// Turning off also forgets the readout the cache persisted for cold
    /// launches, which was stored only for this feature.
    private func setTracking(_ enabled: Bool) {
        settingsManager.settings.heatTrackingEnabled = enabled
        if !enabled { HeatAcclimationCache.clearPersistedData() }
    }

    private var trackingMenu: some View {
        Menu {
            Button(String(localized: "Turn off heat tracking", bundle: LanguageManager.appBundle)) {
                setTracking(false)
            }
        } label: {
            Image(systemName: "ellipsis")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(AppTheme.textSecondary)
                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(String(localized: "Heat tracking options", bundle: LanguageManager.appBundle)))
    }

    @ViewBuilder
    private var content: some View {
        switch cache.status {
        case .computing:
            // A real view, NOT EmptyView(): the `.task` that kicks off the
            // first compute is attached to this `content`, and SwiftUI does
            // not run `.task`/`.onAppear` on an `EmptyView` (it produces no
            // render node). Returning EmptyView here left the card stuck in
            // `.computing` forever — refresh never fired, so nothing showed.
            loadingCard
        case let .ready(readout):
            card(readout)
        case .noOutdoorWorkouts:
            noOutdoorWorkoutsCard
        case let .noRecordedWeather(count):
            noRecordedWeatherCard(count)
        }
    }

    private var noOutdoorWorkoutsCard: some View {
        infoCard(
            icon: "figure.run",
            title: String(localized: "Heat acclimatization", bundle: LanguageManager.appBundle),
            message: String(localized: "No outdoor workouts found in Apple Health for the last 60 days. Heat adaptation builds from outdoor training — once there's an outdoor run, ride, walk or hike in Health, it tracks here.", bundle: LanguageManager.appBundle),
            action: nil
        )
    }

    private func noRecordedWeatherCard(_ count: Int) -> some View {
        infoCard(
            icon: "cloud.sun",
            title: String(localized: "Heat acclimatization", bundle: LanguageManager.appBundle),
            message: String(localized: "Found \(count) outdoor workouts.", bundle: LanguageManager.appBundle)
                + " " + String(localized: "None of them has weather saved with it. Weather is saved with outdoor workouts you record in Emuqu when the phone can reach the weather service.", bundle: LanguageManager.appBundle),
            action: nil
        )
    }

    // MARK: - Ready card

    private func card(_ r: HeatAcclimationCache.Readout) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .center, spacing: 16) {
                ring(level: r.level)
                bandCaption(r)
                Spacer(minLength: 0)
            }
            Text(verbatim: coachingLine(r))
                .scaledFont(size: 13)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func bandCaption(_ r: HeatAcclimationCache.Readout) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(r.band.localizedLabel)
                .scaledFont(size: 17, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
            if let adaptedWBGT = r.adaptedWBGT {
                Text(verbatim: adaptedLine(adaptedWBGT))
                    .scaledFont(size: 13)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "thermometer.sun.fill")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(AppTheme.wongAttention)
            Text(String(localized: "Heat acclimatization", bundle: LanguageManager.appBundle))
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(AppTheme.textSecondary)
                .tracking(0.3)
            Spacer(minLength: 0)
            trackingMenu
        }
    }

    // MARK: - Loading state

    /// Shown during the first compute. Must be a non-empty view so the
    /// card's `.task` (which triggers that compute) actually runs.
    private var loadingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "Reading your recent outdoor training…", bundle: LanguageManager.appBundle))
                    .scaledFont(size: 13)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: - Info / empty states

    private func infoCard(
        icon: String,
        title: String,
        message: String,
        action: (label: String, run: () -> Void)?,
        showsTrackingMenu: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            infoCardHeader(icon: icon, title: title, showsTrackingMenu: showsTrackingMenu)
            Text(verbatim: message)
                .scaledFont(size: 13)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            infoCardAction(action)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    @ViewBuilder
    private func infoCardAction(_ action: (label: String, run: () -> Void)?) -> some View {
        if let action {
            Button(action: action.run) {
                Text(verbatim: action.label)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(AppTheme.wongAttentionText)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func infoCardHeader(icon: String, title: String, showsTrackingMenu: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(AppTheme.wongAttention)
            Text(verbatim: title)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(AppTheme.textSecondary)
                .tracking(0.3)
            if showsTrackingMenu {
                Spacer(minLength: 0)
                trackingMenu
            }
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(AppTheme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(AppTheme.wongAttention.opacity(0.22), lineWidth: 1)
            )
    }

    // MARK: - Ring

    private func ring(level: Double) -> some View {
        let frac = min(max(level, 0), 100) / 100.0
        return ZStack {
            Circle()
                .stroke(AppTheme.wongAttention.opacity(0.15), lineWidth: 8)
            Circle()
                .trim(from: 0, to: frac)
                .stroke(
                    AppTheme.wongAttention,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text(verbatim: "\(Int(level.rounded()))%")
                .scaledFont(size: 20, weight: .bold, design: .rounded)
                .foregroundStyle(AppTheme.textPrimary)
        }
        .frame(width: 72, height: 72)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(localized: "Heat acclimatization \(Int(level.rounded())) percent", bundle: LanguageManager.appBundle)))
    }

    // MARK: - Copy

    private func adaptedLine(_ wbgt: Double) -> String {
        let airC = HeatAcclimation.approxAirTempC(fromWBGT: wbgt)
        let shown = temperatureUnit == .fahrenheit ? (airC * 9 / 5 + 32) : airC
        let unit = temperatureUnit == .fahrenheit ? "°F" : "°C"
        return String(localized: "Adapted to heat around \(Int(shown.rounded()))\(unit)", bundle: LanguageManager.appBundle)
    }

    private func coachingLine(_ r: HeatAcclimationCache.Readout) -> String {
        if !r.hasHeatExposure {
            return String(localized: "Your recent outdoor sessions haven't been hot enough to build heat acclimatization yet. Once you're training in real heat — or in the warmer part of the day — this starts climbing.", bundle: LanguageManager.appBundle)
        }
        switch r.daysToTarget {
        case .some(0):
            return String(localized: "You're ready for the summer heat — keep training outdoors a couple of times a week to hold it.", bundle: LanguageManager.appBundle)
        case let .some(n) where n == 1:
            return String(localized: "About one more hot outdoor session to be fully acclimated. Heat adaptation fades within a few weeks off, so keep it up.", bundle: LanguageManager.appBundle)
        case let .some(n):
            return String(localized: "About \(n) more hot outdoor training days to full acclimatization. Adaptation fades within a few weeks without heat, so stay consistent.", bundle: LanguageManager.appBundle)
        case .none:
            return String(localized: "Your recent outdoor sessions aren't hot or long enough to push acclimatization further — train in the warmer part of the day, or longer, to keep adapting.", bundle: LanguageManager.appBundle)
        }
    }
}
