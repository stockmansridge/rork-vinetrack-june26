import Foundation
import CoreLocation
import Supabase
import PostgREST

/// Backend-safe current-weather fetcher.
///
/// Calls the `weather-current` Supabase Edge Function which holds the
/// `WUNDERGROUND_API_KEY` secret server-side. The API key never ships
/// inside the iOS app.
///
/// As a transitional fallback, if `AppConfig.wundergroundAPIKey` is
/// populated (via Info.plist or UserDefaults during development) the
/// service will call Weather Underground directly. In production the
/// Edge Function path is used.
nonisolated struct WeatherCurrentService: Sendable {

    /// Safe, member-readable snapshot returned by
    /// `public.get_vineyard_current_weather` RPC. Never contains
    /// Davis credentials or auth headers.
    nonisolated struct CachedSnapshot: Sendable {
        let source: String
        let stationId: String?
        let stationName: String?
        let observedAt: Date?
        let temperatureC: Double?
        let humidityPct: Double?
        let windSpeedKmh: Double?
        let windDirectionDeg: Double?
        let rainTodayMm: Double?
        let rainRateMmPerHr: Double?
        let leafWetness: Double?
        let isStale: Bool
        /// 'ok', 'no_data', 'not_configured'.
        let status: String
        let message: String
    }

    nonisolated struct Snapshot: Sendable {
        let temperatureC: Double?
        let windSpeedKmh: Double?
        let windDirection: String
        let humidityPercent: Double?
        let observedAt: Date
        let stationId: String?
        let source: String
    }

    nonisolated enum WeatherFetchError: Error, LocalizedError, Sendable {
        case missingAPIKey
        case noNearbyStation
        case noObservations
        case network(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Weather service is not configured. Please try again later or enter weather manually."
            case .noNearbyStation:
                return "No nearby weather station found. Enter weather manually."
            case .noObservations:
                return "No current observations returned. Try again or enter weather manually."
            case .network(let m):
                return "Weather fetch failed: \(m)"
            }
        }
    }

    func fetch(coordinate: CLLocationCoordinate2D, stationId: String? = nil) async throws -> Snapshot {
        // Prefer the Edge Function (server-side API key).
        if AppConfig.isSupabaseConfigured {
            do {
                return try await fetchViaEdgeFunction(coordinate: coordinate, stationId: stationId)
            } catch WeatherFetchError.missingAPIKey {
                // fall through to direct call only if a local key is present
            }
        }

        // Transitional fallback: direct call using a dev-only key.
        let apiKey = AppConfig.wundergroundAPIKey
        guard !apiKey.isEmpty else { throw WeatherFetchError.missingAPIKey }
        let resolvedStation: String
        if let stationId, !stationId.isEmpty {
            resolvedStation = stationId
        } else {
            resolvedStation = try await nearestStationId(coordinate: coordinate, apiKey: apiKey)
        }
        return try await currentObservation(stationId: resolvedStation, apiKey: apiKey)
    }

    // MARK: - Edge Function path

    nonisolated private struct EdgeFunctionResponse: Decodable, Sendable {
        let temperatureC: Double?
        let windSpeedKmh: Double?
        let windDirection: String?
        let humidityPercent: Double?
        let observedAt: String?
        let stationId: String?
        let source: String?
    }

    nonisolated private struct EdgeFunctionError: Decodable, Sendable {
        let error: String?
    }

    private func fetchViaEdgeFunction(
        coordinate: CLLocationCoordinate2D,
        stationId: String?
    ) async throws -> Snapshot {
        let base = AppConfig.supabaseURL.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/functions/v1/weather-current") else {
            throw WeatherFetchError.network("Invalid edge function URL")
        }
        let anonKey = AppConfig.supabaseAnonKey
        guard !anonKey.isEmpty else { throw WeatherFetchError.missingAPIKey }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")

        var payload: [String: Any] = [
            "lat": coordinate.latitude,
            "lon": coordinate.longitude,
        ]
        if let stationId, !stationId.isEmpty {
            payload["stationId"] = stationId
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw WeatherFetchError.network("No HTTP response")
        }

        if http.statusCode == 500 {
            if let err = try? JSONDecoder().decode(EdgeFunctionError.self, from: data),
               let msg = err.error,
               msg.contains("WUNDERGROUND_API_KEY") {
                throw WeatherFetchError.missingAPIKey
            }
        }
        if http.statusCode == 404 {
            throw WeatherFetchError.noObservations
        }
        guard (200..<300).contains(http.statusCode) else {
            if let err = try? JSONDecoder().decode(EdgeFunctionError.self, from: data),
               let msg = err.error {
                throw WeatherFetchError.network(msg)
            }
            throw WeatherFetchError.network("HTTP \(http.statusCode)")
        }

        let decoded = try JSONDecoder().decode(EdgeFunctionResponse.self, from: data)
        let observedAt: Date = {
            if let s = decoded.observedAt,
               let d = ISO8601DateFormatter().date(from: s) { return d }
            return Date()
        }()
        return Snapshot(
            temperatureC: decoded.temperatureC,
            windSpeedKmh: decoded.windSpeedKmh,
            windDirection: decoded.windDirection ?? "",
            humidityPercent: decoded.humidityPercent,
            observedAt: observedAt,
            stationId: decoded.stationId,
            source: decoded.source ?? "Weather Underground PWS"
        )
    }

    // MARK: - Direct fallback (dev only)

    private func nearestStationId(coordinate: CLLocationCoordinate2D, apiKey: String) async throws -> String {
        let lat = String(format: "%.5f", coordinate.latitude)
        let lon = String(format: "%.5f", coordinate.longitude)
        let urlString = "https://api.weather.com/v3/location/near?geocode=\(lat),\(lon)&product=pws&format=json&apiKey=\(apiKey)"
        guard let url = URL(string: urlString) else { throw WeatherFetchError.network("Invalid URL") }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw WeatherFetchError.network("No HTTP response") }
        if http.statusCode == 204 { throw WeatherFetchError.noNearbyStation }
        guard http.statusCode == 200 else {
            throw WeatherFetchError.network("HTTP \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let location = json["location"] as? [String: Any],
              let stations = location["stationId"] as? [String],
              let first = stations.first else {
            throw WeatherFetchError.noNearbyStation
        }
        return first
    }

    private func currentObservation(stationId: String, apiKey: String) async throws -> Snapshot {
        let urlString = "https://api.weather.com/v2/pws/observations/current?stationId=\(stationId)&format=json&units=m&numericPrecision=decimal&apiKey=\(apiKey)"
        guard let url = URL(string: urlString) else { throw WeatherFetchError.network("Invalid URL") }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw WeatherFetchError.network("No HTTP response") }
        if http.statusCode == 204 { throw WeatherFetchError.noObservations }
        guard http.statusCode == 200 else {
            throw WeatherFetchError.network("HTTP \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let observations = json["observations"] as? [[String: Any]],
              let obs = observations.first else {
            throw WeatherFetchError.noObservations
        }

        let metric = (obs["metric"] as? [String: Any]) ?? [:]
        let temp = parseDouble(metric["temp"]) ?? parseDouble(obs["temp"])
        let wind = parseDouble(metric["windSpeed"]) ?? parseDouble(obs["windSpeed"])
        let humidity = parseDouble(obs["humidity"]) ?? parseDouble(metric["humidity"])
        let winddirDeg = parseDouble(obs["winddir"]) ?? parseDouble(metric["winddir"])
        let direction = winddirDeg.map { Self.compassDirection(degrees: $0) } ?? ""

        let observedAt: Date = {
            if let s = obs["obsTimeUtc"] as? String,
               let d = ISO8601DateFormatter().date(from: s) {
                return d
            }
            return Date()
        }()

        return Snapshot(
            temperatureC: temp,
            windSpeedKmh: wind,
            windDirection: direction,
            humidityPercent: humidity,
            observedAt: observedAt,
            stationId: stationId,
            source: "Weather Underground PWS"
        )
    }

    private func parseDouble(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    // MARK: - Cached current weather (RPC)

    /// Calls `public.get_vineyard_current_weather(p_vineyard_id)` and
    /// returns the latest cached observation for the vineyard. The RPC
    /// is cache-only and never exposes Davis credentials. Returns nil
    /// if Supabase is not configured or the RPC call fails.
    func fetchCachedCurrent(vineyardId: UUID) async throws -> CachedSnapshot? {
        let provider = SupabaseClientProvider.shared
        guard provider.isConfigured else { return nil }
        let rows: [CurrentWeatherRow] = try await provider.client
            .rpc("get_vineyard_current_weather",
                 params: GetCurrentWeatherParams(pVineyardId: vineyardId))
            .execute()
            .value
        guard let row = rows.first else { return nil }
        return CachedSnapshot(
            source: row.source ?? "davis_weatherlink",
            stationId: row.stationId,
            stationName: row.stationName,
            observedAt: row.observedAt,
            temperatureC: row.temperatureC,
            humidityPct: row.humidityPct,
            windSpeedKmh: row.windSpeedKmh,
            windDirectionDeg: row.windDirectionDeg,
            rainTodayMm: row.rainTodayMm,
            rainRateMmPerHr: row.rainRateMmPerHr,
            leafWetness: row.leafWetness,
            isStale: row.isStale ?? false,
            status: row.status ?? "unavailable",
            message: row.message ?? ""
        )
    }

    nonisolated private struct GetCurrentWeatherParams: Encodable, Sendable {
        let pVineyardId: UUID
        enum CodingKeys: String, CodingKey { case pVineyardId = "p_vineyard_id" }
    }

    nonisolated private struct CurrentWeatherRow: Decodable, Sendable {
        let source: String?
        let stationId: String?
        let stationName: String?
        let observedAt: Date?
        let temperatureC: Double?
        let humidityPct: Double?
        let windSpeedKmh: Double?
        let windDirectionDeg: Double?
        let rainTodayMm: Double?
        let rainRateMmPerHr: Double?
        let leafWetness: Double?
        let isStale: Bool?
        let status: String?
        let message: String?
        enum CodingKeys: String, CodingKey {
            case source
            case stationId = "station_id"
            case stationName = "station_name"
            case observedAt = "observed_at"
            case temperatureC = "temperature_c"
            case humidityPct = "humidity_pct"
            case windSpeedKmh = "wind_speed_kmh"
            case windDirectionDeg = "wind_direction_deg"
            case rainTodayMm = "rain_today_mm"
            case rainRateMmPerHr = "rain_rate_mm_per_hr"
            case leafWetness = "leaf_wetness"
            case isStale = "is_stale"
            case status, message
        }
    }

    static func compassDirection(degrees: Double) -> String {
        let dirs = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                    "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let normalized = ((degrees.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        let idx = Int((normalized / 22.5).rounded()) % 16
        return dirs[idx]
    }
}
