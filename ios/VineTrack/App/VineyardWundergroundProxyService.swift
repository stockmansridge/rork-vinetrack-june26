import Foundation
import Supabase

/// Result of a Weather Underground `backfill_rainfall` action.
/// Mirrors the JSON contract returned by the wunderground-proxy edge
/// function so the iOS UI can show an honest summary.
nonisolated struct WundergroundProxyBackfillResult: Sendable, Equatable {
    public let success: Bool
    public let daysRequested: Int
    public let daysProcessed: Int
    public let rowsUpserted: Int
    public let errorsCount: Int
    public let stationId: String?
    public let stationName: String?
    public let timezone: String?
    public let proxyVersion: String?
    /// Offset (in days back from yesterday) this chunk started at.
    public let offsetDays: Int
    /// Chunk size used by the proxy for this call.
    public let chunkDays: Int
    /// Number of days actually included in this slice.
    public let sliceLength: Int
    /// Offset to pass on the next call to continue the backfill, or nil
    /// if the requested range is complete (or processing was halted by
    /// a rate limit).
    public let nextOffsetDays: Int?
    /// True when the proxy still has more days to process for the
    /// requested range and was not rate-limited.
    public let more: Bool
    /// True when the proxy stopped early because Weather Underground
    /// rate-limited the history endpoint.
    public let rateLimited: Bool
}

/// Errors surfaced by the wunderground-proxy edge function.
nonisolated enum VineyardWundergroundProxyError: LocalizedError, Sendable {
    case notAuthenticated
    case forbidden(String)
    case notConfigured
    case rateLimited
    case network(String)
    case decoding(String)
    case http(Int, String?)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Sign in to use the vineyard's Weather Underground connection."
        case .forbidden(let m):
            return m.isEmpty ? "You don't have permission for this Weather Underground action." : m
        case .notConfigured:
            return "Add a Weather Underground station ID first."
        case .rateLimited:
            return "Weather Underground rate limit reached. Try again later."
        case .network(let m):
            return "Weather Underground unavailable — \(m)"
        case .decoding(let m):
            return "Weather Underground response could not be parsed (\(m))."
        case .http(let code, let msg):
            if let msg, !msg.isEmpty { return msg }
            return "Weather Underground proxy returned HTTP \(code)."
        }
    }
}

/// Client for the `wunderground-proxy` Supabase Edge Function. The
/// platform-wide WUNDERGROUND_API_KEY secret is held server-side; this
/// client only sends the vineyard ID and (optional) station override.
nonisolated enum VineyardWundergroundProxyService {

    private static let functionName = "wunderground-proxy"

    /// Backfills the past `days` of vineyard-local rainfall into
    /// `rainfall_daily` via the wunderground-proxy edge function. Owner
    /// /manager only — the proxy enforces the role check using the
    /// caller's JWT. WU rows only — never overwrites Manual or Davis rows.
    static func backfillRainfall(
        vineyardId: UUID,
        stationId: String? = nil,
        days: Int = 14,
        offsetDays: Int = 0,
        chunkDays: Int? = nil
    ) async throws -> WundergroundProxyBackfillResult {
        let clamped = max(1, min(365, days))
        let clampedOffset = max(0, min(clamped, offsetDays))
        var payload: [String: Any] = [
            "vineyardId": vineyardId.uuidString,
            "action": "backfill_rainfall",
            "days": clamped,
            "offsetDays": clampedOffset,
        ]
        if let stationId, !stationId.isEmpty {
            payload["stationId"] = stationId
        }
        if let chunkDays {
            payload["chunkDays"] = max(1, min(30, chunkDays))
        }
        let json = try await invoke(payload: payload)
        let success = (json["success"] as? Bool) ?? false
        func intVal(_ k: String) -> Int {
            if let n = json[k] as? Int { return n }
            if let n = json[k] as? NSNumber { return n.intValue }
            if let n = json[k] as? Double { return Int(n) }
            return 0
        }
        let nextOffset: Int? = {
            if let n = json["next_offset_days"] as? Int { return n }
            if let n = json["next_offset_days"] as? NSNumber { return n.intValue }
            return nil
        }()
        return WundergroundProxyBackfillResult(
            success: success,
            daysRequested: intVal("days_requested"),
            daysProcessed: intVal("days_processed"),
            rowsUpserted: intVal("rows_upserted"),
            errorsCount: intVal("errors_count"),
            stationId: json["station_id"] as? String,
            stationName: json["station_name"] as? String,
            timezone: json["timezone"] as? String,
            proxyVersion: (json["proxy_version"] as? String)
                ?? (json["_proxy_version"] as? String),
            offsetDays: intVal("offset_days"),
            chunkDays: intVal("chunk_days"),
            sliceLength: intVal("slice_length"),
            nextOffsetDays: nextOffset,
            more: (json["more"] as? Bool) ?? false,
            rateLimited: (json["rate_limited"] as? Bool) ?? false
        )
    }

    // MARK: - Internals

    private static func invoke(
        payload: [String: Any]
    ) async throws -> [String: Any] {
        let provider = SupabaseClientProvider.shared
        guard provider.isConfigured else {
            throw VineyardWundergroundProxyError.network("Backend not configured")
        }

        let base = AppConfig.supabaseURL.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/functions/v1/\(functionName)") else {
            throw VineyardWundergroundProxyError.network("Invalid edge function URL")
        }

        let session = try? await provider.client.auth.session
        guard let token = session?.accessToken, !token.isEmpty else {
            print("[WundergroundProxy] notAuthenticated action=\(payload["action"] as? String ?? "-") vineyardId=\(payload["vineyardId"] as? String ?? "-")")
            throw VineyardWundergroundProxyError.notAuthenticated
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
            throw VineyardWundergroundProxyError.decoding("Could not encode request body")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw VineyardWundergroundProxyError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw VineyardWundergroundProxyError.network("No HTTP response")
        }

        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let errorMessage = body["error"] as? String

        let action = payload["action"] as? String ?? "-"
        let vid = payload["vineyardId"] as? String ?? "-"
        switch http.statusCode {
        case 200..<300:
            print("[WundergroundProxy] vineyardId=\(vid) action=\(action) result=success status=\(http.statusCode)")
            return body
        case 401:
            print("[WundergroundProxy] vineyardId=\(vid) action=\(action) result=fail status=401 reason=notAuthenticated")
            throw VineyardWundergroundProxyError.notAuthenticated
        case 403:
            print("[WundergroundProxy] vineyardId=\(vid) action=\(action) result=fail status=403 reason=forbidden")
            throw VineyardWundergroundProxyError.forbidden(errorMessage ?? "")
        case 404:
            print("[WundergroundProxy] vineyardId=\(vid) action=\(action) result=fail status=404 reason=notConfigured")
            throw VineyardWundergroundProxyError.notConfigured
        case 429:
            print("[WundergroundProxy] vineyardId=\(vid) action=\(action) result=fail status=429 reason=rateLimited")
            throw VineyardWundergroundProxyError.rateLimited
        default:
            print("[WundergroundProxy] vineyardId=\(vid) action=\(action) result=fail status=\(http.statusCode)")
            throw VineyardWundergroundProxyError.http(http.statusCode, errorMessage)
        }
    }
}
