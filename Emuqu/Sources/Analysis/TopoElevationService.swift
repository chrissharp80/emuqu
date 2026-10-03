import CoreLocation
import Foundation

// MARK: - Topo Elevation Service
//
// Real terrain elevation from a Digital Elevation Model lookup service.
// This is how Strava, Garmin Connect, TrainingPeaks handle elevation
// for GPS-only activities without barometer data: they send the GPS
// coords to their own DEM and read back the actual terrain elevation
// at each point, NOT the noisy GPS altitude.
//
// The approach Strava documents ("Elevation on Strava FAQs"):
//   1. Look up terrain elevation for each GPS coordinate from a DEM.
//   2. Count an up-segment as gain only once it clears a sustained-climb
//      threshold — protects against DEM resolution artefacts at
//      transitions between data tiles. Strava uses 10 m without a
//      barometer; this service uses 15 m (see `elevations` for the
//      calibration).
//
// We use **OpenTopoData** (https://www.opentopodata.org/): USGS NED 10 m
// for US coordinates, NASA SRTM 30 m elsewhere.
//   • Free public endpoint, no API key
//   • Up to 100 coordinates per request
//   • 1000 requests / day / IP public tier (ample for personal use)
//   • Self-hostable if the public endpoint goes down
//
// Open-Meteo Elevation was the first candidate but uses Copernicus
// GLO-90 (90 m resolution) — coarser, which flattens short hills.
// 30 m DEM catches more real terrain detail. When the SRTM endpoint
// is rate-limited we fall back to Open-Meteo 90 m as a graceful
// degrade rather than silently producing noise-math results.
//
// Failure handling: if every service fails, we SURFACE the error to
// the caller rather than silently switching to GPS-altitude smoothing.
// Noise-math guesses are the exact thing this service exists to
// replace — falling back to them defeats the purpose.
enum TopoElevationService {
    /// Result for one resolved workout track.
    struct Result {
        /// Total climb (metres). Sum of positive elevation deltas.
        let gainMeters: Double
        /// Total descent (metres). Sum of |negative| elevation deltas.
        let lossMeters: Double
        /// Per-coordinate elevations returned by the service, in the
        /// same order as the `sampledCoordinates` indices we sent.
        let elevations: [Double]
        /// The track indices we sampled — not every fix was queried
        /// (we downsample to stay under the 100-point-per-request
        /// limit). Indices map to the caller's original `track` array.
        let sampledIndices: [Int]
    }

    enum ServiceError: Error {
        case badResponse(String)
        case emptyTrack
        case networkError(Error)
    }

    /// Query terrain elevation for the given GPS track and compute
    /// sustained-climb gain / loss. Downsamples the track to at most
    /// `maxSamples` points spread uniformly across the series so we
    /// stay under the service's 100 coords/request cap.
    ///
    /// Threshold is 15 m sustained-climb. Empirical calibration against
    /// iPhone barometric apps (iSmoothRun / Apple Fitness / FITIV all
    /// agreed at ~395 ft on a Riverton-area 105-ft-terrain-range loop):
    ///   • SRTM 30 m + 10 m threshold → 495 ft (+25 % overcount)
    ///   • NED 10 m + 10 m threshold → 485 ft (still +22 %)
    ///   • NED 10 m + 15 m threshold → 371 ft (matches within 6 %)
    /// Strava's published "10 m without barometer" rule is calibrated
    /// against their own basemap which is barometer-pooled; raw SRTM /
    /// NED DEMs need a higher threshold to get the same physical
    /// answer because their vertical quantization is coarser.
    ///
    /// For *future* recordings, the app uses CMAltimeter barometric
    /// altitude (±0.5 m) directly — this retroactive DEM-based path is
    /// a fallback only for pre-barometer-fix sessions.
    ///
    /// - Parameter sustainedClimbThreshold: Metres of continuous climb
    ///   required before committing a run to gain. 15 m is the
    ///   empirically-calibrated default, and the only value the app uses.
    static func elevations(
        for track: [CLLocation],
        maxSamples: Int = 100,
        sustainedClimbThreshold: Double = 15.0
    ) async throws -> Result {
        guard !track.isEmpty else { throw ServiceError.emptyTrack }
        let sampledIndices = downsampleIndices(count: track.count, target: maxSamples)
        let coords = sampledIndices.map { track[$0].coordinate }
        let elevations = try await fetchElevations(for: coords)
        guard elevations.count == coords.count else {
            throw ServiceError.badResponse("Elevation count mismatch: got \(elevations.count), expected \(coords.count)")
        }
        let climb = sustainedClimb(in: elevations, threshold: sustainedClimbThreshold)
        return Result(
            gainMeters: climb.gain,
            lossMeters: climb.loss,
            elevations: elevations,
            sampledIndices: sampledIndices
        )
    }

    /// Sustained-climb accumulation for DEM data. Same-sign deltas are summed
    /// into a run, and a run is only committed to gain/loss once its magnitude
    /// crosses the threshold — see the `elevations` doc comment for why 15 m is
    /// the empirically-calibrated default.
    /// `internal` so the accumulation can be tested directly. This produces
    /// the elevation gain shown on every workout and feeds grade-adjusted
    /// pace.
    ///
    /// A FLAT step is not a direction change. Treating
    /// `sign == 0` as a reversal would commit the run in progress and
    /// start a new one. DEM elevations are quantised — OpenTopoData returns
    /// discrete metres — so equal consecutive samples are routine mid-climb,
    /// and each flat step would chop a sustained climb into fragments the
    /// threshold then discarded one by one. A quantised 20 m climb
    /// (0,0,5,5,10,10,15,15,20,20) reported ZERO gain at a 10 m threshold.
    static func sustainedClimb(
        in elevations: [Double],
        threshold: Double
    ) -> (gain: Double, loss: Double) {
        // `1 ..< 0` is an invalid range and traps. The public `elevations(_:)`
        // path cannot produce an empty array, so this is a latent trap rather
        // than a live crash — but the function is callable on its own.
        guard elevations.count > 1 else { return (0, 0) }

        var state = ClimbRun()
        for i in 1 ..< elevations.count {
            state.step(
                by: elevations[i] - elevations[i - 1],
                threshold: threshold
            )
        }
        state.finish(threshold: threshold)
        return (state.gain, state.loss)
    }

    /// Accumulates consecutive same-direction elevation changes into runs,
    /// committing each to gain or loss once it clears the threshold.
    private struct ClimbRun {
        private(set) var gain = 0.0
        private(set) var loss = 0.0
        private var runSum = 0.0
        private var runSign = 0

        mutating func step(by delta: Double, threshold: Double) {
            let sign = delta > 0 ? 1 : (delta < 0 ? -1 : 0)
            if sign == 0 { return }                      // flat: not a reversal
            if runSign == 0 {                            // first graded step
                runSum = delta
                runSign = sign
            } else if sign == runSign {                  // same way: accumulate
                runSum += delta
            } else {                                     // genuine reversal
                commit(threshold: threshold)
                runSum = delta
                runSign = sign
            }
        }

        mutating func finish(threshold: Double) {
            commit(threshold: threshold)
        }

        private mutating func commit(threshold: Double) {
            guard abs(runSum) >= threshold else { return }
            if runSum > 0 { gain += runSum } else { loss += -runSum }
        }
    }

    /// Evenly-spaced indices into a series of length `count`.
    static func downsampleIndices(count: Int, target: Int) -> [Int] {
        guard count > target, target > 1 else { return Array(0 ..< count) }
        var out: [Int] = []
        out.reserveCapacity(target)
        let step = Double(count - 1) / Double(target - 1)
        for i in 0 ..< target {
            out.append(Int((Double(i) * step).rounded()))
        }
        // Keep first + last exactly.
        if out.first != 0 { out[0] = 0 }
        if out.last != count - 1 { out[out.count - 1] = count - 1 }
        return out
    }

    /// DEM-dataset cascade. For US coords prefer USGS NED 10 m (higher
    /// resolution than SRTM 30 m — matches barometric truth more closely
    /// on rolling-neighborhood terrain). For non-US, SRTM 30 m. Falls
    /// back to Open-Meteo GLO-90 when both OpenTopoData datasets are
    /// unavailable.
    ///
    /// Empirical calibration against iSmoothRun / Apple Fitness / FITIV
    /// (all barometric) on a Riverton-area rolling-hills walk: SRTM
    /// 30 m with 10 m threshold overcounts by ~25 %; NED 10 m with a
    /// 15 m threshold matches barometric gain within ~5 %.
    private static func fetchElevations(for coords: [CLLocationCoordinate2D]) async throws -> [Double] {
        // Try NED 10m first (US-only, higher resolution). It returns HTTP
        // 400 for points outside US; fall through to SRTM on any error.
        if let coord = coords.first, isLikelyUS(coord: coord) {
            if let values = try? await fetchFromOpenTopoData(coords: coords, dataset: "ned10m") {
                return values
            }
        }
        do {
            return try await fetchFromOpenTopoData(coords: coords, dataset: "srtm30m")
        } catch {
            debugLog("[TopoElevation] OpenTopoData failed (\(error)), falling back to Open-Meteo", level: .warning)
            return try await fetchFromOpenMeteo(coords: coords)
        }
    }

    /// Cheap bounding-box check for "is this point in the continental US
    /// or Alaska / Hawaii?" — NED 10m coverage area. No need to call a
    /// proper geocoder; wrong answers just mean we fall through to SRTM.
    private static func isLikelyUS(coord: CLLocationCoordinate2D) -> Bool {
        let lat = coord.latitude, lon = coord.longitude
        // Continental US
        if (24 ... 50).contains(lat), (-125 ... -66).contains(lon) { return true }
        // Alaska
        if (54 ... 72).contains(lat), (-170 ... -130).contains(lon) { return true }
        // Hawaii
        if (18 ... 23).contains(lat), (-162 ... -154).contains(lon) { return true }
        return false
    }

    /// Generic OpenTopoData query. Dataset is the URL path segment
    /// (`srtm30m`, `ned10m`, `aster30m`, etc.).
    /// Docs: https://www.opentopodata.org/
    private static func fetchFromOpenTopoData(coords: [CLLocationCoordinate2D], dataset: String) async throws -> [Double] {
        // NOT %.6f, which is ~11 cm. These coordinates are the user's actual
        // workout route, sent to a third party in a URL query string (and so
        // into its access logs), and the FIRST point of a track is typically a
        // home address. OpenTopoData's finest dataset is 10 m (`ned10m`, most
        // are 30 m), so 11 cm is ~100x finer than anything the service can
        // resolve — precision that buys nothing and leaks everything.
        // %.4f is ~11 m: still finer than the elevation data itself.
        let locations = coords.map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) }
            .joined(separator: "|")
        // URLComponents init? returns nil for invalid strings, and
        // `dataset` is caller-supplied, so throw a typed error rather than
        // force-unwrap.
        let url = try openTopoDataURL(dataset: dataset, locations: locations)
        let data = try await fetchJSON(from: url, label: "OpenTopoData \(dataset)")
        return try decodeOpenTopoData(data, expecting: coords.count, dataset: dataset)
    }

    /// Builds the query URL, throwing a typed error rather than force-unwrapping
    /// the optional `URLComponents` / `url`.
    private static func openTopoDataURL(dataset: String, locations: String) throws -> URL {
        guard var components = URLComponents(string: "https://api.opentopodata.org/v1/\(dataset)") else {
            throw ServiceError.badResponse("Invalid OpenTopoData URL components (dataset=\(dataset))")
        }
        components.queryItems = [URLQueryItem(name: "locations", value: locations)]
        guard let url = components.url else {
            throw ServiceError.badResponse("Could not build OpenTopoData URL (\(dataset))")
        }
        return url
    }

    /// One bounded GET, with network and HTTP failures mapped onto typed errors.
    private static func fetchJSON(from url: URL, label: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw ServiceError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw ServiceError.badResponse("\(label) HTTP error")
        }
        return data
    }

    private static func decodeOpenTopoData(_ data: Data, expecting count: Int, dataset: String) throws -> [Double] {
        struct Envelope: Decodable {
            struct Point: Decodable { let elevation: Double? }
            let results: [Point]
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        let values = env.results.compactMap(\.elevation)
        guard values.count == count else {
            throw ServiceError.badResponse("OpenTopoData \(dataset) count mismatch \(values.count)/\(count)")
        }
        return values
    }

    /// Open-Meteo (Copernicus GLO-90) — used as fallback. Coarser (90 m)
    /// but faster and higher daily rate limit.
    /// Docs: https://open-meteo.com/en/docs/elevation-api
    private static func fetchFromOpenMeteo(coords: [CLLocationCoordinate2D]) async throws -> [Double] {
        // Same reasoning as `fetchFromOpenTopoData` above — Open-Meteo's
        // elevation product is a 90 m DEM, so ~11 m is already oversampled.
        let latStr = coords.map { String(format: "%.4f", $0.latitude) }.joined(separator: ",")
        let lonStr = coords.map { String(format: "%.4f", $0.longitude) }.joined(separator: ",")

        // Hard-coded URL string is well-formed but spec
        // forbids force-unwrap; throw a typed error if init? returns
        // nil (would only happen on URL spec change).
        let url = try openMeteoURL(latStr: latStr, lonStr: lonStr)
        let data = try await fetchOpenMeteoJSON(from: url)
        struct Envelope: Decodable { let elevation: [Double] }
        return try JSONDecoder().decode(Envelope.self, from: data).elevation
    }

    /// Builds the query URL, throwing a typed error rather than force-unwrapping
    /// the optional `URLComponents` / `url`.
    private static func openMeteoURL(latStr: String, lonStr: String) throws -> URL {
        guard var components = URLComponents(string: "https://api.open-meteo.com/v1/elevation") else {
            throw ServiceError.badResponse("Invalid Open-Meteo URL components")
        }
        components.queryItems = [
            URLQueryItem(name: "latitude", value: latStr),
            URLQueryItem(name: "longitude", value: lonStr)
        ]
        guard let url = components.url else {
            throw ServiceError.badResponse("Could not build Open-Meteo URL")
        }
        return url
    }

    /// Open-Meteo returns a readable error body, which is worth surfacing —
    /// hence its own fetch rather than the shared `fetchJSON`.
    private static func fetchOpenMeteoJSON(from url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw ServiceError.networkError(error)
        }
        let http = response as? HTTPURLResponse
        guard let http, (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let code = http?.statusCode ?? -1
            throw ServiceError.badResponse("Open-Meteo HTTP \(code): \(body.prefix(200))")
        }
        return data
    }
}
