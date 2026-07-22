import Foundation
import Supabase

/// One day of normalised forecast data from the willyweather-proxy edge
/// function. Mirrors the JSON contract in
/// `supabase/functions/willyweather-proxy/index.ts`.
nonisolated struct WillyWeatherForecastDay: Sendable, Equatable {
    public let date: Date
    public let rainMm: Double?
    public let rainProbability: Double?
    public let tempMinC: Double?
    public let tempMaxC: Double?
    public let windKmhMax: Double?
    public let et0Mm: Double?
}

nonisolated struct WillyWeatherForecastResult: Sendable, Equatable {
    public let source: String
    public let locationId: String?
    public let locationName: String?
    public let days: [WillyWeatherForecastDay]
}

nonisolated struct WillyWeatherLocation: Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let region: String?
    public let state: String?
    public let postcode: String?
    public let latitude: Double?
    public let longitude: Double?
    public let distanceKm: Double?
}

nonisolated enum VineyardWillyWeatherProxyError: LocalizedError, Sendable {
    case notAuthenticated
    case forbidden(String)
    case notConfigured
    case noLocation
    case network(String)
    case decoding(String)
    case http(Int, String?)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Sign in to use WillyWeather."
        case .forbidden(let m):
            return m.isEmpty ? "Owner or manager role is required." : m
        case .notConfigured:
            return "WillyWeather is not configured for this vineyard."
        case .noLocation:
            return "Pick a WillyWeather location for this vineyard."
        case .network(let m):
            return "WillyWeather unavailable — \(m)"
        case .decoding(let m):
            return "WillyWeather response could not be parsed (\(m))."
        case .http(let code, let msg):
            if let msg, !msg.isEmpty { return msg }
            return "WillyWeather proxy returned HTTP \(code)."
        }
    }
}

/// Client for the `willyweather-proxy` Supabase Edge Function. The API
/// key never enters the iOS bundle — it lives server-side under
/// `vineyard_weather_integrations` (provider = 'willyweather') and the
/// edge function reads it via the service role.
nonisolated enum VineyardWillyWeatherProxyService {

    private static let functionName = "willyweather-proxy"

    /// Read the vineyard-level forecast provider preference
    /// (auto / open_meteo / willyweather). Shared with Lovable.
    static func getProviderPreference(vineyardId: UUID) async throws -> String {
        let json = try await invoke(payload: [
            "vineyardId": vineyardId.uuidString,
            "action": "get_provider_preference",
        ])
        return (json["provider"] as? String) ?? "auto"
    }

    /// Write the vineyard-level forecast provider preference. Owner/manager only.
    static func setProviderPreference(vineyardId: UUID, provider: String) async throws {
        _ = try await invoke(payload: [
            "vineyardId": vineyardId.uuidString,
            "action": "set_provider_preference",
            "provider": provider,
        ])
    }

    static func setLocation(
        vineyardId: UUID,
        location: WillyWeatherLocation
    ) async throws {
        var payload: [String: Any] = [
            "vineyardId": vineyardId.uuidString,
            "action": "set_location",
            "locationId": location.id,
            "locationName": location.name,
        ]
        if let lat = location.latitude { payload["latitude"] = lat }
        if let lon = location.longitude { payload["longitude"] = lon }
        _ = try await invoke(payload: payload)
    }

    static func delete(vineyardId: UUID) async throws {
        _ = try await invoke(payload: [
            "vineyardId": vineyardId.uuidString,
            "action": "delete",
        ])
    }

    static func testConnection(vineyardId: UUID) async throws -> Bool {
        let json = try await invoke(payload: [
            "vineyardId": vineyardId.uuidString,
            "action": "test_connection",
        ])
        return (json["success"] as? Bool) ?? false
    }

    static func searchLocations(
        vineyardId: UUID,
        query: String? = nil,
        lat: Double? = nil,
        lon: Double? = nil
    ) async throws -> [WillyWeatherLocation] {
        let result = try await searchLocationsDetailed(
            vineyardId: vineyardId, query: query, lat: lat, lon: lon
        )
        return result.locations
    }

    /// Same as `searchLocations` but also surfaces the optional `reason`
    /// string returned by the proxy (e.g. `no_nearest_match`). Lets the
    /// caller show a precise message when nearest-match auto-resolution
    /// fails.
    static func searchLocationsDetailed(
        vineyardId: UUID,
        query: String? = nil,
        lat: Double? = nil,
        lon: Double? = nil
    ) async throws -> (locations: [WillyWeatherLocation], reason: String?) {
        var payload: [String: Any] = [
            "vineyardId": vineyardId.uuidString,
            "action": "search_locations",
        ]
        if let query, !query.isEmpty { payload["query"] = query }
        if let lat { payload["lat"] = lat }
        if let lon { payload["lon"] = lon }

        let json = try await invoke(payload: payload)
        let arr = json["locations"] as? [[String: Any]] ?? []
        let locations = arr.compactMap { raw -> WillyWeatherLocation? in
            guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
            return WillyWeatherLocation(
                id: id,
                name: (raw["name"] as? String) ?? "",
                region: raw["region"] as? String,
                state: raw["state"] as? String,
                postcode: raw["postcode"] as? String,
                latitude: doubleVal(raw["latitude"]),
                longitude: doubleVal(raw["longitude"]),
                distanceKm: doubleVal(raw["distanceKm"])
            )
        }
        return (locations, json["reason"] as? String)
    }

    static func fetchForecast(
        vineyardId: UUID,
        days: Int = 5
    ) async throws -> WillyWeatherForecastResult {
        let clamped = max(1, min(days, 7))
        let json = try await invoke(payload: [
            "vineyardId": vineyardId.uuidString,
            "action": "fetch_forecast",
            "days": clamped,
        ])
        let rawDays = json["days"] as? [[String: Any]] ?? []
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone.current
        let parsedDays: [WillyWeatherForecastDay] = rawDays.compactMap { d in
            guard let dateStr = d["date"] as? String,
                  let date = fmt.date(from: dateStr) else { return nil }
            return WillyWeatherForecastDay(
                date: date,
                rainMm: doubleVal(d["rain_mm"]),
                rainProbability: doubleVal(d["rain_probability"]),
                tempMinC: doubleVal(d["temp_min_c"]),
                tempMaxC: doubleVal(d["temp_max_c"]),
                windKmhMax: doubleVal(d["wind_kmh_max"]),
                et0Mm: doubleVal(d["et0_mm"])
            )
        }
        return WillyWeatherForecastResult(
            source: (json["source"] as? String) ?? "WillyWeather",
            locationId: json["location_id"] as? String,
            locationName: json["location_name"] as? String,
            days: parsedDays
        )
    }

    // MARK: - Internals

    private static func doubleVal(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func invoke(payload: [String: Any]) async throws -> [String: Any] {
        let provider = SupabaseClientProvider.shared
        guard provider.isConfigured else {
            throw VineyardWillyWeatherProxyError.network("Backend not configured")
        }

        let base = AppConfig.supabaseURL.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/functions/v1/\(functionName)") else {
            throw VineyardWillyWeatherProxyError.network("Invalid edge function URL")
        }

        let session = try? await provider.client.auth.session
        guard let token = session?.accessToken, !token.isEmpty else {
            throw VineyardWillyWeatherProxyError.notAuthenticated
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw VineyardWillyWeatherProxyError.decoding("Could not encode request body")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw VineyardWillyWeatherProxyError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw VineyardWillyWeatherProxyError.network("No HTTP response")
        }

        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let errorMessage = body["error"] as? String

        let action = payload["action"] as? String ?? "-"
        let vid = payload["vineyardId"] as? String ?? "-"
        switch http.statusCode {
        case 200..<300:
            print("[WillyWeatherProxy] vineyardId=\(vid) action=\(action) result=success status=\(http.statusCode)")
            return body
        case 400:
            if let msg = errorMessage?.lowercased() {
                if msg.contains("not configured") {
                    throw VineyardWillyWeatherProxyError.notConfigured
                }
                if msg.contains("location is not selected") || msg.contains("location is not") {
                    throw VineyardWillyWeatherProxyError.noLocation
                }
            }
            print("[WillyWeatherProxy] vineyardId=\(vid) action=\(action) result=fail status=400 reason=\(errorMessage ?? "-")")
            throw VineyardWillyWeatherProxyError.http(400, errorMessage)
        case 401:
            throw VineyardWillyWeatherProxyError.notAuthenticated
        case 403:
            throw VineyardWillyWeatherProxyError.forbidden(errorMessage ?? "")
        default:
            print("[WillyWeatherProxy] vineyardId=\(vid) action=\(action) result=fail status=\(http.statusCode) reason=\(errorMessage ?? "-")")
            throw VineyardWillyWeatherProxyError.http(http.statusCode, errorMessage)
        }
    }
}
