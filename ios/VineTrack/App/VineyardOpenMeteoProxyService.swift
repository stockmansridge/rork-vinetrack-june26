import Foundation
import Supabase

/// Result of the Open-Meteo `backfill_rainfall_gaps` action. Mirrors the
/// JSON contract returned by `supabase/functions/open-meteo-proxy/index.ts`.
nonisolated struct OpenMeteoProxyGapFillResult: Sendable, Equatable {
    public let success: Bool
    public let daysRequested: Int
    public let daysProcessed: Int
    public let rowsUpserted: Int
    public let daysSkippedBetterSource: Int
    public let daysSkippedNoData: Int
    public let errorsCount: Int
    public let fromDate: String?
    public let toDate: String?
    public let latitude: Double?
    public let longitude: Double?
    public let coordsSource: String?
    public let timezone: String?
    public let proxyVersion: String?
}

/// Errors surfaced by the open-meteo-proxy edge function.
nonisolated enum VineyardOpenMeteoProxyError: LocalizedError, Sendable {
    case notAuthenticated
    case forbidden(String)
    case missingCoordinates
    case rateLimited
    case network(String)
    case decoding(String)
    case http(Int, String?)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Sign in to use the Open-Meteo gap fill."
        case .forbidden(let m):
            return m.isEmpty ? "Owner or manager role is required." : m
        case .missingCoordinates:
            return "Vineyard coordinates are required to fetch Open-Meteo rainfall."
        case .rateLimited:
            return "Open-Meteo is rate-limiting requests. Try again later."
        case .network(let m):
            return "Open-Meteo unavailable — \(m)"
        case .decoding(let m):
            return "Open-Meteo response could not be parsed (\(m))."
        case .http(let code, let msg):
            if let msg, !msg.isEmpty { return msg }
            return "Open-Meteo proxy returned HTTP \(code)."
        }
    }
}

/// Client for the `open-meteo-proxy` Supabase Edge Function. Open-Meteo
/// requires no API key — this proxy lives server-side so the device never
/// calls Open-Meteo directly and the "never overwrite Manual / Davis /
/// Weather Underground" rule is enforced centrally.
nonisolated enum VineyardOpenMeteoProxyService {

    private static let functionName = "open-meteo-proxy"

    /// Fills missing rainfall days using the Open-Meteo Archive API.
    /// Owner/Manager only — the proxy enforces the role check using the
    /// caller's JWT. Open-Meteo source rows only — never overwrites
    /// Manual, Davis, or Weather Underground rows.
    static func backfillRainfallGaps(
        vineyardId: UUID,
        days: Int = 365,
        timezone: String? = nil
    ) async throws -> OpenMeteoProxyGapFillResult {
        let clamped = max(1, min(5 * 365, days))
        var payload: [String: Any] = [
            "vineyardId": vineyardId.uuidString,
            "action": "backfill_rainfall_gaps",
            "days": clamped,
        ]
        if let timezone, !timezone.isEmpty {
            payload["timezone"] = timezone
        } else {
            payload["timezone"] = TimeZone.current.identifier
        }
        let json = try await invoke(payload: payload)
        let success = (json["success"] as? Bool) ?? false
        func intVal(_ k: String) -> Int {
            if let n = json[k] as? Int { return n }
            if let n = json[k] as? NSNumber { return n.intValue }
            if let n = json[k] as? Double { return Int(n) }
            return 0
        }
        func dblVal(_ k: String) -> Double? {
            if let n = json[k] as? Double { return n }
            if let n = json[k] as? NSNumber { return n.doubleValue }
            if let n = json[k] as? Int { return Double(n) }
            return nil
        }
        return OpenMeteoProxyGapFillResult(
            success: success,
            daysRequested: intVal("days_requested"),
            daysProcessed: intVal("days_processed"),
            rowsUpserted: intVal("rows_upserted"),
            daysSkippedBetterSource: intVal("days_skipped_better_source"),
            daysSkippedNoData: intVal("days_skipped_no_data"),
            errorsCount: intVal("errors_count"),
            fromDate: json["from_date"] as? String,
            toDate: json["to_date"] as? String,
            latitude: dblVal("latitude"),
            longitude: dblVal("longitude"),
            coordsSource: json["coords_source"] as? String,
            timezone: json["timezone"] as? String,
            proxyVersion: (json["proxy_version"] as? String)
                ?? (json["_proxy_version"] as? String)
        )
    }

    // MARK: - Internals

    private static func invoke(payload: [String: Any]) async throws -> [String: Any] {
        let provider = SupabaseClientProvider.shared
        guard provider.isConfigured else {
            throw VineyardOpenMeteoProxyError.network("Backend not configured")
        }

        let base = AppConfig.supabaseURL.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/functions/v1/\(functionName)") else {
            throw VineyardOpenMeteoProxyError.network("Invalid edge function URL")
        }

        let session = try? await provider.client.auth.session
        guard let token = session?.accessToken, !token.isEmpty else {
            print("[OpenMeteoProxy] notAuthenticated action=\(payload["action"] as? String ?? "-") vineyardId=\(payload["vineyardId"] as? String ?? "-")")
            throw VineyardOpenMeteoProxyError.notAuthenticated
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw VineyardOpenMeteoProxyError.decoding("Could not encode request body")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw VineyardOpenMeteoProxyError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw VineyardOpenMeteoProxyError.network("No HTTP response")
        }

        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let errorMessage = body["error"] as? String

        let action = payload["action"] as? String ?? "-"
        let vid = payload["vineyardId"] as? String ?? "-"
        switch http.statusCode {
        case 200..<300:
            print("[OpenMeteoProxy] vineyardId=\(vid) action=\(action) result=success status=\(http.statusCode)")
            return body
        case 400:
            // The proxy returns 400 with a specific error string when
            // coordinates can't be resolved.
            if let msg = errorMessage,
               msg.lowercased().contains("coordinates") {
                print("[OpenMeteoProxy] vineyardId=\(vid) action=\(action) result=fail status=400 reason=missingCoordinates")
                throw VineyardOpenMeteoProxyError.missingCoordinates
            }
            print("[OpenMeteoProxy] vineyardId=\(vid) action=\(action) result=fail status=400 reason=\(errorMessage ?? "-")")
            throw VineyardOpenMeteoProxyError.http(400, errorMessage)
        case 401:
            print("[OpenMeteoProxy] vineyardId=\(vid) action=\(action) result=fail status=401 reason=notAuthenticated")
            throw VineyardOpenMeteoProxyError.notAuthenticated
        case 403:
            print("[OpenMeteoProxy] vineyardId=\(vid) action=\(action) result=fail status=403 reason=forbidden")
            throw VineyardOpenMeteoProxyError.forbidden(errorMessage ?? "")
        case 429:
            print("[OpenMeteoProxy] vineyardId=\(vid) action=\(action) result=fail status=429 reason=rateLimited")
            throw VineyardOpenMeteoProxyError.rateLimited
        default:
            print("[OpenMeteoProxy] vineyardId=\(vid) action=\(action) result=fail status=\(http.statusCode)")
            throw VineyardOpenMeteoProxyError.http(http.statusCode, errorMessage)
        }
    }
}
