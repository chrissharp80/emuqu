import SwiftUI

/// Garmin-style heat-acclimatization readout for the Load & Trajectory
/// surface. Observes the shared `HeatAcclimationCache`.
///
/// Unlike a self-hiding card, this stays visible and EXPLAINS itself when it
/// can't show a number — heat tracking depends on outdoor workouts in Apple
/// Health, a location to look up the weather you trained in, and a network
/// fetch, and any of those can be missing on a given device. Surfacing the
/// blocker ("enable location", "no outdoor workouts") is far more useful
/// than vanishing.
struct HeatAcclimationCard: View {
    @Environment(\.dependencies) var dependencies
    private var cache: HeatAcclimationCache { dependencies.analysis.heatAcclimationCache }
    let temperatureUnit: TemperatureUnit

    var body: some View {
        content
            .task {
                dependencies.location.ambientLocationService.start()
                cache.refresh()
                await sleepQuietly(3_000_000_000, context: "body")
                cache.refresh()
            }
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
        case let .needsLocation(count):
            needsLocationCard(count)
        case let .weatherUnavailable(count):
            weatherUnavailableCard(count)
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

    private func needsLocationCard(_ count: Int) -> some View {
        infoCard(
            icon: "location.magnifyingglass",
            title: String(localized: "Heat acclimatization", bundle: LanguageManager.appBundle),
            message: String(localized: "Found \(count) outdoor workout\(count == 1 ? "" : "s"), but couldn't pin a location to look up the weather you trained in. Reopen this screen in a moment — it retries automatically.", bundle: LanguageManager.appBundle),
            action: (String(localized: "Retry now", bundle: LanguageManager.appBundle), { self.cache.refresh() })
        )
    }

    private func weatherUnavailableCard(_ count: Int) -> some View {
        infoCard(
            icon: "wifi.slash",
            title: String(localized: "Heat acclimatization", bundle: LanguageManager.appBundle),
            message: String(localized: "Found \(count) outdoor workout\(count == 1 ? "" : "s") but couldn't load the historical weather. Check your connection and tap Retry.", bundle: LanguageManager.appBundle),
            action: (String(localized: "Retry now", bundle: LanguageManager.appBundle), { self.cache.refresh() })
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
            Text(verbatim: r.band.label)
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
        action: (label: String, run: () -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            infoCardHeader(icon: icon, title: title)
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
                    .foregroundStyle(AppTheme.wongAttention)
            }
            .buttonStyle(.plain)
        }
    }

    private func infoCardHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(AppTheme.wongAttention)
            Text(verbatim: title)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(AppTheme.textSecondary)
                .tracking(0.3)
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
