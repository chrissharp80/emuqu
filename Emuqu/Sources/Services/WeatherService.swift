import CoreLocation
import Foundation

// MARK: - WeatherService
//
// Current conditions for the workout coach and for the weather saved with
// each outdoor workout. Source: MET Norway Locationforecast 2.0, compact
// variant (https://api.met.no/weatherapi/locationforecast/2.0/documentation).
// Its data is licensed CC BY 4.0, which allows commercial use with
// attribution, so the app credits "Weather data: MET Norway (CC BY 4.0)".
//
// MET Norway's terms (https://api.met.no/doc/TermsOfService) and how this
// file meets them:
//   • Identify the app with a User-Agent naming it and a contact: `userAgent`.
//   • At most 4 decimals in coordinates: 2 are sent (about 1 km).
//   • Don't repeat a request before the response's `Expires` time, nor more
//     than once every 10 minutes: `cacheCovers` and `minimumRequestInterval`.
//   • Send If-Modified-Since when asking again for the same place: a 304
//     keeps the forecast already held.
//
// Fetches never block the main thread; failures are logged and leave
// `current` as it was (the assistant gets `weather = nil` once it ages out).
@Observable
@MainActor
final class WeatherService {
    static let shared = WeatherService()

    /// The last snapshot, or nil once it is older than `maxSnapshotAge`.
    /// Without the age limit, yesterday's weather in another city was
    /// archived onto an offline workout today and fed heat acclimation.
    var current: WorkoutAIContext.WeatherSnapshot? {
        guard let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.maxSnapshotAge else { return nil }
        return snapshot
    }

    private var snapshot: WorkoutAIContext.WeatherSnapshot?
    private var fetchedAt: Date?
    private var fetchedAtCoord: CLLocationCoordinate2D?
    @ObservationIgnored private var forecast: MetNorwayForecast?
    @ObservationIgnored private var lastRequestAt: Date?
    @ObservationIgnored private var inflightTask: Task<Void, Never>?

    /// How long a snapshot stays valid before we re-fetch, unless MET
    /// Norway's `Expires` header says the forecast stays current for longer.
    static let cacheTTL: TimeInterval = 30 * 60

    /// MET Norway asks for no more than one request every 10 minutes. A failed
    /// request counts too, so a phone out of coverage doesn't retry every tick.
    static let minimumRequestInterval: TimeInterval = 10 * 60

    /// How long a snapshot that could not be refreshed still describes the
    /// conditions: long enough to cover a long workout out of coverage.
    static let maxSnapshotAge: TimeInterval = 3 * 3600

    /// MET Norway rejects requests without an identifying User-Agent.
    static let userAgent = "Emuqu/\(Bundle.main.appVersion) github.com/chrissharp80/emuqu"

    func refreshIfNeeded(for location: CLLocation?) {
        guard let loc = location, inflightTask == nil, !cacheCovers(loc) else { return }
        let coord = Self.rounded(loc.coordinate)
        let ifModifiedSince = isSamePlace(coord) ? forecast?.lastModified : nil
        lastRequestAt = Date()
        inflightTask = Task { [weak self] in
            defer { self?.clearInflightTask() }
            let outcome = await Self.fetch(at: coord, ifModifiedSince: ifModifiedSince)
            self?.apply(outcome, at: coord)
        }
    }

    /// Hops back to the main actor to release the in-flight slot; `defer` can't
    /// await, so the clear is queued rather than performed inline.
    nonisolated private func clearInflightTask() {
        Task { @MainActor in self.inflightTask = nil }
    }

    private func apply(_ outcome: FetchOutcome, at coord: CLLocationCoordinate2D) {
        switch outcome {
        case let .fresh(newForecast):
            forecast = newForecast
        case let .notModified(expires):
            forecast?.expires = expires
        case .failed:
            return
        }
        guard let snapshot = forecast?.snapshot(at: Date()) else { return }
        self.snapshot = snapshot
        fetchedAt = Date()
        fetchedAtCoord = coord
    }

    /// True while a new request would break MET Norway's terms or fetch
    /// nothing new: within 10 minutes of the last request, or still inside the
    /// cache window (30 minutes, or later if `Expires` says so) for a place
    /// within 5 km of the last one. Beyond 5 km the user may be in another
    /// grid cell, so the forecast for the new place is fetched.
    private func cacheCovers(_ loc: CLLocation) -> Bool {
        if let lastRequestAt, Date().timeIntervalSince(lastRequestAt) < Self.minimumRequestInterval {
            return true
        }
        guard let fetchedAt, let prev = fetchedAtCoord,
              CLLocation(latitude: prev.latitude, longitude: prev.longitude).distance(from: loc) < 5_000
        else { return false }
        let validUntil = max(fetchedAt.addingTimeInterval(Self.cacheTTL), forecast?.expires ?? .distantPast)
        return Date() < validUntil
    }

    private func isSamePlace(_ coord: CLLocationCoordinate2D) -> Bool {
        guard let prev = fetchedAtCoord else { return false }
        return prev.latitude == coord.latitude && prev.longitude == coord.longitude
    }

    /// Two decimal places, about 1.1 km. MET Norway's model grid is coarser
    /// than that, so finer coordinates could not change the answer and would
    /// only send a more exact position.
    private static func rounded(_ coord: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (coord.latitude * 100).rounded() / 100,
            longitude: (coord.longitude * 100).rounded() / 100
        )
    }

    // MARK: - Network

    enum FetchOutcome {
        case fresh(MetNorwayForecast)
        case notModified(expires: Date?)
        case failed
    }

    private static func fetch(at coord: CLLocationCoordinate2D, ifModifiedSince: String?) async -> FetchOutcome {
        guard let request = request(at: coord, ifModifiedSince: ifModifiedSince) else { return .failed }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return try outcome(data: data, response: response)
        } catch {
            debugLog("[WeatherService] weather fetch failed: \(error.localizedDescription)", level: .warning)
            return .failed
        }
    }

    private static func request(at coord: CLLocationCoordinate2D, ifModifiedSince: String?) -> URLRequest? {
        var components = URLComponents(string: "https://api.met.no/weatherapi/locationforecast/2.0/compact")
        components?.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.2f", coord.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.2f", coord.longitude))
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        // Caching is done here, against `Expires`; the URL cache would hide a
        // 304 behind a synthesized 200.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let ifModifiedSince {
            request.setValue(ifModifiedSince, forHTTPHeaderField: "If-Modified-Since")
        }
        return request
    }

    private static let expiresHeader = "Expires"
    private static let lastModifiedHeader = "Last-Modified"

    private static func outcome(data: Data, response: URLResponse) throws -> FetchOutcome {
        guard let http = response as? HTTPURLResponse else { return .failed }
        let expires = http.value(forHTTPHeaderField: Self.expiresHeader).flatMap(MetNorwayForecast.httpDate)
        switch http.statusCode {
        case 200:
            return .fresh(MetNorwayForecast(
                hours: try MetNorwayForecast.parse(data),
                lastModified: http.value(forHTTPHeaderField: Self.lastModifiedHeader),
                expires: expires
            ))
        case 304:
            return .notModified(expires: expires)
        default:
            debugLog("[WeatherService] MET Norway HTTP \(http.statusCode)", level: .warning)
            return .failed
        }
    }

    // MARK: - Conditions in the app's language

    /// A stored condition in the app's language. Snapshots keep the English
    /// description (see `MetNorwayForecast.conditions(forSymbol:)`), which the
    /// assistant reads and which stays the same if the user changes language,
    /// so screens translate it when they show it. Older workouts carry names
    /// from the previous weather source, such as "Drizzle", so those stay
    /// translated too.
    nonisolated static func localizedConditions(_ english: String) -> String {
        localizedConditionNames()[english] ?? english
    }

    nonisolated private static func localizedConditionNames() -> [String: String] {
        let b = LanguageManager.appBundle
        return [
            "Clear": String(localized: "Clear sky", bundle: b), "Mainly clear": String(localized: "Mainly clear", bundle: b),
            "Partly cloudy": String(localized: "Partly cloudy", bundle: b), "Overcast": String(localized: "Overcast", bundle: b),
            "Fog": String(localized: "Fog", bundle: b), "Drizzle": String(localized: "Drizzle", bundle: b),
            "Freezing drizzle": String(localized: "Freezing drizzle", bundle: b), "Light rain": String(localized: "Light rain", bundle: b),
            "Rain": String(localized: "Rain", bundle: b), "Heavy rain": String(localized: "Heavy rain", bundle: b),
            "Freezing rain": String(localized: "Freezing rain", bundle: b), "Snow": String(localized: "Snow", bundle: b),
            "Snow grains": String(localized: "Snow grains", bundle: b), "Rain showers": String(localized: "Rain showers", bundle: b),
            "Snow showers": String(localized: "Snow showers", bundle: b), "Thunderstorm": String(localized: "Thunderstorm", bundle: b),
            "Thunderstorm with hail": String(localized: "Thunderstorm with hail", bundle: b),
            "Sleet": String(localized: "Sleet", bundle: b), "Sleet showers": String(localized: "Sleet showers", bundle: b),
            "Unknown": String(localized: "Unknown", bundle: b)
        ]
    }
}

// MARK: - MET Norway forecast

/// The hourly steps of one Locationforecast "compact" response, plus the
/// response headers that govern when it may be fetched again.
struct MetNorwayForecast: Equatable {
    /// One forecast step with every field a weather snapshot needs.
    struct Hour: Equatable {
        let time: Date
        let temperatureC: Double
        let humidityPercent: Double
        let windMetresPerSecond: Double
        let windFromDegrees: Double
        let symbolCode: String?
    }

    let hours: [Hour]
    /// Echoed back as If-Modified-Since on the next request for the same place.
    let lastModified: String?
    var expires: Date?

    /// The step nearest `date` as a snapshot, or nil when the nearest step is
    /// more than 3 hours away (a forecast held far longer than it was meant to
    /// be). MET Norway gives no apparent ("feels like") temperature, so that
    /// field is nil rather than invented.
    func snapshot(at date: Date) -> WorkoutAIContext.WeatherSnapshot? {
        let distance = { (hour: Hour) in abs(hour.time.timeIntervalSince(date)) }
        guard let hour = hours.min(by: { distance($0) < distance($1) }), distance(hour) <= 3 * 3600 else { return nil }
        return WorkoutAIContext.WeatherSnapshot(
            temperatureC: hour.temperatureC,
            apparentTemperatureC: nil,
            windKMH: hour.windMetresPerSecond * 3.6,
            windDirectionDegrees: hour.windFromDegrees,
            humidityPercent: hour.humidityPercent,
            conditions: Self.conditions(forSymbol: hour.symbolCode),
            observedAt: date
        )
    }

    // MARK: Parsing

    /// The steps that carry temperature, humidity and wind. A step missing
    /// any of them is skipped rather than filled with a guess.
    static func parse(_ data: Data) throws -> [Hour] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let steps = try decoder.decode(Response.self, from: data).properties.timeseries
        return steps.compactMap(hour(from:))
    }

    private static func hour(from step: Response.Step) -> Hour? {
        let details = step.data.instant.details
        guard let temperature = details.air_temperature,
              let humidity = details.relative_humidity,
              let wind = details.wind_speed,
              let direction = details.wind_from_direction else { return nil }
        let symbol = step.data.next_1_hours?.summary.symbol_code ?? step.data.next_6_hours?.summary.symbol_code
        return Hour(
            time: step.time,
            temperatureC: temperature,
            humidityPercent: humidity,
            windMetresPerSecond: wind,
            windFromDegrees: direction,
            symbolCode: symbol
        )
    }

    private struct Response: Decodable {
        let properties: Properties
        struct Properties: Decodable { let timeseries: [Step] }
        struct Step: Decodable {
            let time: Date
            let data: StepData
        }
        struct StepData: Decodable {
            let instant: Instant
            let next_1_hours: Period?
            let next_6_hours: Period?
        }
        struct Instant: Decodable { let details: Details }
        struct Details: Decodable {
            let air_temperature: Double?
            let relative_humidity: Double?
            let wind_speed: Double?
            let wind_from_direction: Double?
        }
        struct Period: Decodable { let summary: Summary }
        struct Summary: Decodable { let symbol_code: String }
    }

    /// An HTTP date such as `Sat, 03 Oct 2026 12:31:07 GMT`, the format of
    /// MET Norway's `Expires` header.
    static func httpDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }

    // MARK: Conditions

    /// English condition name for a MET Norway symbol code such as
    /// `lightrainshowers_day`. The `_day` / `_night` / `_polartwilight`
    /// suffix only picks an icon, so it is dropped; every "…andthunder" code
    /// is a thunderstorm. Names match `WeatherService.localizedConditions`.
    static func conditions(forSymbol symbol: String?) -> String {
        guard let symbol, let base = symbol.split(separator: "_").first.map(String.init) else { return "Unknown" }
        if base.contains("thunder") { return "Thunderstorm" }
        return symbolConditions[base] ?? "Unknown"
    }

    /// Symbol codes from https://api.met.no/weatherapi/weathericon/2.0/documentation,
    /// suffix removed. A table rather than a `switch`: it is a mapping, not logic.
    private static let symbolConditions: [String: String] = [
        "clearsky": "Clear",
        "fair": "Mainly clear",
        "partlycloudy": "Partly cloudy",
        "cloudy": "Overcast",
        "fog": "Fog",
        "lightrain": "Light rain", "rain": "Rain", "heavyrain": "Heavy rain",
        "lightrainshowers": "Rain showers", "rainshowers": "Rain showers", "heavyrainshowers": "Rain showers",
        "lightsleet": "Sleet", "sleet": "Sleet", "heavysleet": "Sleet",
        "lightsleetshowers": "Sleet showers", "sleetshowers": "Sleet showers", "heavysleetshowers": "Sleet showers",
        "lightsnow": "Snow", "snow": "Snow", "heavysnow": "Snow",
        "lightsnowshowers": "Snow showers", "snowshowers": "Snow showers", "heavysnowshowers": "Snow showers"
    ]
}
