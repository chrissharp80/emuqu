import CoreLocation
import Foundation

// MARK: - WeatherService
//
// Free, no-API-key current-conditions service for the workout coach.
// Uses Open-Meteo (https://open-meteo.com — free for non-commercial,
// no auth, global coverage, 10–15 km grid resolution).
//
// We fetch ONLY current conditions on workout start + every 30 min,
// keep the result in-memory on a singleton, and hand it off via the
// AI context. Fetches always honor cancellation and never block the
// main thread; failures are silent (the AI just gets `weather = nil`).
//
// Cache TTL is 30 minutes — weather doesn't move faster than that and
// burning the user's data plan with per-tick fetches would be rude.
//
// Why Open-Meteo over NWS:
//   • NWS is US-only. We have international users.
//   • Open-Meteo aggregates multiple national weather services
//     (DWD, MeteoFrance, NWS, etc.) and picks the closest grid point,
//     so quality near observation stations is comparable.
//   • No auth = no key rotation, no rate limit headaches.
@Observable
@MainActor
final class WeatherService {
    static let shared = WeatherService()

    private(set) var current: WorkoutAIContext.WeatherSnapshot?
    private var fetchedAt: Date?
    private var fetchedAtCoord: CLLocationCoordinate2D?
    @ObservationIgnored private var inflightTask: Task<Void, Never>?

    /// How long a snapshot stays valid before we re-fetch. Open-Meteo
    /// updates roughly hourly; 30 minutes balances freshness with
    /// network politeness.
    static let cacheTTL: TimeInterval = 30 * 60

    func refreshIfNeeded(for location: CLLocation?) {
        guard let loc = location, inflightTask == nil, !cacheCovers(loc) else { return }
        let coord = loc.coordinate
        inflightTask = Task { [weak self] in
            defer { self?.clearInflightTask() }
            await self?.fetchAndPublish(at: coord)
        }
    }

    private func fetchAndPublish(at coord: CLLocationCoordinate2D) async {
        guard let snapshot = await Self.fetch(at: coord) else { return }
        await MainActor.run { publish(snapshot, at: coord) }
    }

    /// Hops back to the main actor to release the in-flight slot; `defer` can't
    /// await, so the clear is queued rather than performed inline.
    nonisolated private func clearInflightTask() {
        Task { @MainActor in self.inflightTask = nil }
    }

    @MainActor
    private func publish(_ snapshot: WorkoutAIContext.WeatherSnapshot, at coord: CLLocationCoordinate2D) {
        current = snapshot
        fetchedAt = Date()
        fetchedAtCoord = coord
    }

    /// True when the cached snapshot is still inside its TTL *and* the user
    /// hasn't moved more than 5 km since it was fetched — beyond that they may
    /// be out of the previous grid cell, so re-fetch.
    private func cacheCovers(_ loc: CLLocation) -> Bool {
        guard let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.cacheTTL,
              let prev = fetchedAtCoord else { return false }
        return CLLocation(latitude: prev.latitude, longitude: prev.longitude)
            .distance(from: loc) < 5_000
    }

    /// Documentation: https://open-meteo.com/en/docs
    /// We request the "current" block which is a single sample. No
    /// forecast — we don't need it for live coaching.
    ///
    /// Open-Meteo's forecast is a gridded model at roughly
    /// 1-11 km resolution, so ~11 m precision could not change the answer.
    /// ~1.1 km is still well inside a single grid cell.
    private static func fetch(at coord: CLLocationCoordinate2D) async -> WorkoutAIContext.WeatherSnapshot? {
        let lat = String(format: "%.2f", coord.latitude)
        let lon = String(format: "%.2f", coord.longitude)
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,relative_humidity_2m,apparent_temperature,wind_speed_10m,wind_direction_10m,weather_code&temperature_unit=celsius&wind_speed_unit=kmh"
        guard let url = URL(string: urlString) else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try parse(data: data)
        } catch {
            debugLog("[WeatherService] weather fetch failed: \(error.localizedDescription)", level: .warning)
            return nil
        }
    }

    /// The `current` block Open-Meteo returns for a live-conditions query.
    private struct CurrentResponse: Decodable {
        let current: Current
        struct Current: Decodable {
            let temperature_2m: Double
            let apparent_temperature: Double
            let relative_humidity_2m: Double
            let wind_speed_10m: Double
            let wind_direction_10m: Double
            let weather_code: Int
        }
    }

    private static func parse(data: Data) throws -> WorkoutAIContext.WeatherSnapshot {
        let c = try JSONDecoder().decode(CurrentResponse.self, from: data).current
        return WorkoutAIContext.WeatherSnapshot(
            temperatureC: c.temperature_2m,
            apparentTemperatureC: c.apparent_temperature,
            windKMH: c.wind_speed_10m,
            windDirectionDegrees: c.wind_direction_10m,
            humidityPercent: c.relative_humidity_2m,
            conditions: weatherCodeDescription(c.weather_code),
            observedAt: Date()
        )
    }

    // MARK: - Historical archive (heat-acclimatization)

    /// One hourly historical observation.
    struct HourlyWeather: Sendable {
        let time: Date
        let temperatureC: Double
        let relativeHumidityPercent: Double
        let dewPointC: Double?
        let apparentTemperatureC: Double?
    }

    /// Relative humidity (%) from temperature + dew point via the Magnus
    /// formula (the exact inverse of the saturation-vapor-pressure ratio the
    /// WBGT calc uses). Used as a fallback when the weather source returns a
    /// null humidity reading, so an hour is never dropped from the heat-
    /// acclimation stimulus (dropping null-RH hours silently
    /// understates acclimation).
    static func relativeHumidity(tempC: Double, dewPointC: Double) -> Double {
        let a = 17.27, b = 237.7
        let gammaT = a * tempC / (b + tempC)
        let gammaTd = a * dewPointC / (b + dewPointC)
        return max(0, min(100, 100.0 * exp(gammaTd - gammaT)))
    }

    /// Fetch a RANGE of hourly historical weather in a single call — used by
    /// the heat-acclimatization model to attribute weather to many past
    /// workouts at one location with one network round-trip (rather than a
    /// fetch per workout). Returns [] on failure.
    /// Docs: https://open-meteo.com/en/docs/historical-weather-api
    /// `yyyy-MM-dd` in UTC — the archive endpoint's date format.
    private static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func fetchArchiveRange(
        at coord: CLLocationCoordinate2D,
        startDate: Date,
        endDate: Date
    ) async -> [HourlyWeather] {
        // Historical reanalysis — coarser still than the forecast grid.
        let lat = String(format: "%.2f", coord.latitude)
        let lon = String(format: "%.2f", coord.longitude)
        let start = utcDay(startDate)
        let end = utcDay(endDate)
        let urlString = "https://archive-api.open-meteo.com/v1/archive?latitude=\(lat)&longitude=\(lon)&start_date=\(start)&end_date=\(end)&hourly=temperature_2m,relative_humidity_2m,dew_point_2m,apparent_temperature&temperature_unit=celsius&timeformat=unixtime"
        guard let url = URL(string: urlString) else { return [] }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            return parseArchiveRange(data: data)
        } catch {
            debugLog("[WeatherService] archive-range fetch failed: \(error.localizedDescription)", level: .warning)
            return []
        }
    }

    /// The archive endpoint's `hourly` block. Hoisted out of the parse
    /// function so `archiveHour` can take one column-set as a parameter.
    struct ArchiveHourly: Decodable {
        let time: [Double]
        let temperature_2m: [Double?]
        let relative_humidity_2m: [Double?]
        let dew_point_2m: [Double?]?
        let apparent_temperature: [Double?]
    }

    private static func parseArchiveRange(data: Data) -> [HourlyWeather] {
        struct Response: Decodable {
            let hourly: ArchiveHourly?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let h = decoded.hourly
        else { return [] }
        var out: [HourlyWeather] = []
        out.reserveCapacity(h.time.count)
        for (i, t) in h.time.enumerated() {
            if let hour = archiveHour(h, at: i, time: t) { out.append(hour) }
        }
        return out
    }

    /// One decoded archive hour, or nil when it can't be salvaged.
    ///
    /// Require only temperature; derive RH from dew point
    /// (Magnus) when humidity is null instead of dropping the hour.
    private static func archiveHour(
        _ h: ArchiveHourly,
        at i: Int,
        time t: Double
    ) -> HourlyWeather? {
        guard i < h.temperature_2m.count, let temp = h.temperature_2m[i] else { return nil }
        var dew: Double?
        if let arr = h.dew_point_2m, i < arr.count { dew = arr[i] }
        let rhRaw = i < h.relative_humidity_2m.count ? h.relative_humidity_2m[i] : nil
        guard let rh = rhRaw ?? dew.map({ relativeHumidity(tempC: temp, dewPointC: $0) }) else { return nil }
        return HourlyWeather(
            time: Date(timeIntervalSince1970: t),
            temperatureC: temp,
            relativeHumidityPercent: rh,
            dewPointC: dew,
            apparentTemperatureC: i < h.apparent_temperature.count ? h.apparent_temperature[i] : nil
        )
    }

    /// WMO weather-code mapping per Open-Meteo docs. Source:
    /// https://open-meteo.com/en/docs (search "WMO Weather interpretation codes").
    ///
    /// A lookup table rather than an 18-case `switch` (which SwiftLint counts
    /// as cyclomatic complexity 18):
    /// there is no logic here, only a mapping, and spelling it as
    /// control flow hides that. Expressing it as data removes every branch, keeps the
    /// mapping in one readable block, and builds the table once instead of
    /// walking cases on each call.
    private static let weatherCodeDescriptions: [Int: String] = [
        0: "Clear",
        1: "Mainly clear",
        2: "Partly cloudy",
        3: "Overcast",
        45: "Fog", 48: "Fog",
        51: "Drizzle", 53: "Drizzle", 55: "Drizzle",
        56: "Freezing drizzle", 57: "Freezing drizzle",
        61: "Light rain",
        63: "Rain",
        65: "Heavy rain",
        66: "Freezing rain", 67: "Freezing rain",
        71: "Snow", 73: "Snow", 75: "Snow",
        77: "Snow grains",
        80: "Rain showers", 81: "Rain showers", 82: "Rain showers",
        85: "Snow showers", 86: "Snow showers",
        95: "Thunderstorm",
        96: "Thunderstorm with hail", 99: "Thunderstorm with hail"
    ]

    private static func weatherCodeDescription(_ code: Int) -> String {
        weatherCodeDescriptions[code] ?? "Unknown"
    }
}
