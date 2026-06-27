import Foundation
import Supabase

/// Status of a single server-side write performed by the davis-proxy
/// edge function during a `current` action. Returned in the response
/// body so the iOS UI can confirm exactly which writes succeeded
/// without depending on Edge Function log access.
nonisolated struct DavisProxyWriteStatus: Sendable, Equatable {
    public let attempted: Bool
    public let success: Bool
    public let code: String?
    public let message: String?
}

/// Server-side diagnostics returned by the davis-proxy `current` action.
/// Reports whether `vineyard_weather_observations` and `rainfall_daily`
/// were written, plus the vineyard-local date and parsed rain value used.
nonisolated struct DavisProxyCurrentDiagnostics: Sendable, Equatable {
    public let observations: DavisProxyWriteStatus
    public let rainfallDaily: DavisProxyWriteStatus
    public let rainfallDate: String?
    public let rainTodayMm: Double?
    public let stationId: String?
    public let stationName: String?
    public let timezone: String?
    /// Deployed proxy build identifier, taken from `_proxy.version` (or
    /// the top-level `_proxy_version` fallback). Lets the UI prove which
    /// edge function code is actually serving requests.
    public let version: String?
}

/// Bundles the parsed current conditions with the server-side proxy
/// diagnostics for a `current` action.
nonisolated struct DavisProxyCurrentResult: Sendable {
    public let conditions: DavisCurrentConditions
    public let diagnostics: DavisProxyCurrentDiagnostics?
}

/// Result of a `backfill_rainfall` action: how many days were
/// requested and processed, how many `rainfall_daily` rows were
/// upserted, and a sanitized errors count. Mirrors the JSON contract
/// returned by the davis-proxy edge function so the iOS UI can show
/// an honest summary without depending on Edge Function logs.
nonisolated struct DavisProxyBackfillResult: Sendable, Equatable {
    public let success: Bool
    public let daysRequested: Int
    public let daysProcessed: Int
    public let rowsUpserted: Int
    public let errorsCount: Int
    public let timezone: String?
    /// Offset (in days back from yesterday) this chunk started at.
    public let offsetDays: Int
    /// Chunk size used by the proxy for this call.
    public let chunkDays: Int
    /// Number of days actually included in this slice.
    public let sliceLength: Int
    /// Offset to use on the next call to continue the backfill, or nil
    /// if the requested range is complete (or processing was halted by
    /// a rate limit).
    public let nextOffsetDays: Int?
    /// True when the proxy still has more days to process for the
    /// requested range and was not rate-limited.
    public let more: Bool
    /// True when the proxy stopped early because WeatherLink rate-limited
    /// the historic endpoint. The chunk contains whatever was processed
    /// before the limit hit.
    public let rateLimited: Bool
    /// Deployed proxy build identifier from `proxy_version`.
    public let proxyVersion: String?
}

/// Errors surfaced by the davis-proxy edge function.
nonisolated enum VineyardDavisProxyError: LocalizedError, Sendable {
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
            return "Sign in to use the vineyard's Davis WeatherLink connection."
        case .forbidden(let m):
            return m.isEmpty ? "You don't have permission for this Davis action." : m
        case .notConfigured:
            return "Davis WeatherLink setup is incomplete for this vineyard."
        case .rateLimited:
            return "WeatherLink rate limit reached. Showing archive rainfall for now."
        case .network(let m):
            return "WeatherLink unavailable — \(m)"
        case .decoding(let m):
            return "WeatherLink response could not be parsed (\(m))."
        case .http(let code, let msg):
            if let msg, !msg.isEmpty { return msg }
            return "WeatherLink proxy returned HTTP \(code)."
        }
    }
}

/// Client for the `davis-proxy` Supabase Edge Function. Used by *every*
/// vineyard member (owner, manager, operator) once the vineyard has a
/// shared Davis WeatherLink integration. Operators never hold the API
/// secret; the edge function reads vineyard credentials with the
/// service-role key after verifying membership.
nonisolated enum VineyardDavisProxyService {

    private static let functionName = "davis-proxy"

    /// Per WeatherLink v2 docs the historic endpoint accepts a 24h window
    /// per call, so longer ranges are chunked the same way as the direct
    /// Davis client.
    private static let historicChunkSeconds: TimeInterval = 24 * 60 * 60

    // MARK: - Public API

    /// Lists stations available to the vineyard's stored credentials.
    static func fetchStations(vineyardId: UUID) async throws -> [DavisStation] {
        let json = try await invoke(
            payload: [
                "vineyardId": vineyardId.uuidString,
                "action": "stations",
            ]
        )
        guard let arr = json["stations"] as? [[String: Any]] else {
            throw VineyardDavisProxyError.decoding("Missing 'stations' array")
        }
        return arr.compactMap(DavisWeatherLinkService.parseStationDict)
    }

    /// Test-connection variant for owner/manager who is verifying a key
    /// pair *before* saving it to the vineyard integration. The proxy
    /// only honours this for owner/manager callers.
    static func testConnection(
        vineyardId: UUID,
        apiKey: String,
        apiSecret: String
    ) async throws -> [DavisStation] {
        let json = try await invoke(
            payload: [
                "vineyardId": vineyardId.uuidString,
                "action": "test",
                "apiKey": apiKey,
                "apiSecret": apiSecret,
            ]
        )
        guard let arr = json["stations"] as? [[String: Any]] else {
            throw VineyardDavisProxyError.decoding("Missing 'stations' array")
        }
        return arr.compactMap(DavisWeatherLinkService.parseStationDict)
    }

    /// Fetches the latest current conditions + sensor summary for the
    /// vineyard's selected (or supplied) station.
    static func fetchCurrentConditions(
        vineyardId: UUID,
        stationId: String
    ) async throws -> DavisCurrentConditions {
        let result = try await fetchCurrentConditionsWithDiagnostics(
            vineyardId: vineyardId, stationId: stationId
        )
        return result.conditions
    }

    /// Variant of ``fetchCurrentConditions(vineyardId:stationId:)`` that
    /// also returns the server-side write diagnostics. Use this from
    /// places that need to confirm `rainfall_daily` and
    /// `vineyard_weather_observations` writes succeeded (e.g. the
    /// "Refresh Davis now" button).
    static func fetchCurrentConditionsWithDiagnostics(
        vineyardId: UUID,
        stationId: String
    ) async throws -> DavisProxyCurrentResult {
        guard !stationId.isEmpty else { throw VineyardDavisProxyError.notConfigured }
        let json = try await invoke(
            payload: [
                "vineyardId": vineyardId.uuidString,
                "action": "current",
                "stationId": stationId,
            ]
        )
        let conditions = DavisWeatherLinkService.parseCurrentConditionsJSON(
            json,
            fallbackStationId: stationId
        )
        let topLevelVersion = json["_proxy_version"] as? String
        let diagnostics = parseProxyDiagnostics(json["_proxy"], topLevelVersion: topLevelVersion)
        return DavisProxyCurrentResult(conditions: conditions, diagnostics: diagnostics)
    }

    /// Parses the `_proxy` diagnostics block returned by the edge
    /// function. Returns nil when an older proxy build (no `_proxy` key)
    /// is deployed, so callers can fall back to a generic message.
    private static func parseProxyDiagnostics(
        _ raw: Any?,
        topLevelVersion: String? = nil
    ) -> DavisProxyCurrentDiagnostics? {
        guard let dict = raw as? [String: Any] else {
            // Even an old proxy without a `_proxy` block may now stamp
            // `_proxy_version` at the top level. Surface that on its own
            // so the UI can still prove which build is live.
            if let v = topLevelVersion {
                return DavisProxyCurrentDiagnostics(
                    observations: DavisProxyWriteStatus(attempted: false, success: false, code: nil, message: nil),
                    rainfallDaily: DavisProxyWriteStatus(attempted: false, success: false, code: nil, message: nil),
                    rainfallDate: nil, rainTodayMm: nil,
                    stationId: nil, stationName: nil, timezone: nil,
                    version: v
                )
            }
            return nil
        }
        func parseStatus(_ v: Any?) -> DavisProxyWriteStatus {
            let d = (v as? [String: Any]) ?? [:]
            return DavisProxyWriteStatus(
                attempted: (d["attempted"] as? Bool) ?? false,
                success: (d["success"] as? Bool) ?? false,
                code: d["code"] as? String,
                message: d["message"] as? String
            )
        }
        let obs = parseStatus(dict["observations"])
        let rainBlock = (dict["rainfall_daily"] as? [String: Any]) ?? [:]
        let rain = DavisProxyWriteStatus(
            attempted: (rainBlock["attempted"] as? Bool) ?? false,
            success: (rainBlock["success"] as? Bool) ?? false,
            code: rainBlock["code"] as? String,
            message: rainBlock["message"] as? String
        )
        let rainDate = rainBlock["date"] as? String
        let rainMm: Double? = {
            if let n = rainBlock["rain_today_mm"] as? Double { return n }
            if let n = rainBlock["rain_today_mm"] as? NSNumber { return n.doubleValue }
            return nil
        }()
        let version = (dict["version"] as? String) ?? topLevelVersion
        return DavisProxyCurrentDiagnostics(
            observations: obs,
            rainfallDaily: rain,
            rainfallDate: rainDate,
            rainTodayMm: rainMm,
            stationId: dict["station_id"] as? String,
            stationName: dict["station_name"] as? String,
            timezone: dict["timezone"] as? String,
            version: version
        )
    }

    /// Fetches archive rainfall and aggregates to daily totals (mm) using
    /// `Calendar.current`. Splits the requested window into 24h chunks to
    /// satisfy the WeatherLink v2 historic endpoint limit.
    static func fetchHistoricRainfall(
        vineyardId: UUID,
        stationId: String,
        from: Date,
        to: Date
    ) async throws -> DavisDailyRainfall {
        guard !stationId.isEmpty else { throw VineyardDavisProxyError.notConfigured }
        guard from < to else {
            return DavisDailyRainfall(
                dailyMm: [:], totalMm: 0, recordCount: 0,
                coveredFrom: from, coveredTo: to
            )
        }

        var chunks: [(start: Date, end: Date)] = []
        var cur = from
        while cur < to {
            let next = min(cur.addingTimeInterval(historicChunkSeconds), to)
            chunks.append((cur, next))
            cur = next
        }

        var perRecord: [(ts: Date, mm: Double)] = []
        for chunk in chunks {
            let json = try await invoke(
                payload: [
                    "vineyardId": vineyardId.uuidString,
                    "action": "historic",
                    "stationId": stationId,
                    "startEpoch": Int(chunk.start.timeIntervalSince1970),
                    "endEpoch": Int(chunk.end.timeIntervalSince1970),
                ]
            )
            guard let sensors = json["sensors"] as? [[String: Any]] else {
                throw VineyardDavisProxyError.decoding("Missing 'sensors' array in historic")
            }
            let parsed = DavisWeatherLinkService.parseHistoricRainfall(sensorsArr: sensors)
            for (d, mm) in parsed { perRecord.append((d, mm)) }
        }

        let cal = Calendar.current
        var daily: [Date: Double] = [:]
        for (ts, mm) in perRecord {
            let key = cal.startOfDay(for: ts)
            daily[key, default: 0] += mm
        }
        let total = daily.values.reduce(0, +)
        return DavisDailyRainfall(
            dailyMm: daily,
            totalMm: total,
            recordCount: perRecord.count,
            coveredFrom: from,
            coveredTo: to
        )
    }

    /// Fetches archive temperature records and aggregates to daily
    /// high/low (Celsius) using `Calendar.current`. Splits the window
    /// into 24-hour chunks to satisfy the WeatherLink v2 historic
    /// endpoint limit. Calls go through the davis-proxy edge function
    /// so operators without API credentials can still use the vineyard's
    /// shared Davis station for GDD calculations.
    static func fetchHistoricDailyTemps(
        vineyardId: UUID,
        stationId: String,
        from: Date,
        to: Date
    ) async throws -> DavisWeatherLinkService.DavisDailyTemps {
        guard !stationId.isEmpty else { throw VineyardDavisProxyError.notConfigured }
        guard from < to else {
            return DavisWeatherLinkService.DavisDailyTemps(dailyHighC: [:], dailyLowC: [:], recordCount: 0)
        }

        var chunks: [(start: Date, end: Date)] = []
        var cur = from
        while cur < to {
            let next = min(cur.addingTimeInterval(historicChunkSeconds), to)
            chunks.append((cur, next))
            cur = next
        }

        var perRecord: [(ts: Date, hiF: Double, loF: Double)] = []
        for chunk in chunks {
            let json = try await invoke(
                payload: [
                    "vineyardId": vineyardId.uuidString,
                    "action": "historic",
                    "stationId": stationId,
                    "startEpoch": Int(chunk.start.timeIntervalSince1970),
                    "endEpoch": Int(chunk.end.timeIntervalSince1970),
                ]
            )
            guard let sensors = json["sensors"] as? [[String: Any]] else {
                throw VineyardDavisProxyError.decoding("Missing 'sensors' array in historic")
            }
            let parsed = DavisWeatherLinkService.parseHistoricTemperatures(sensorsArr: sensors)
            for r in parsed { perRecord.append((r.0, r.1, r.2)) }
        }

        let cal = Calendar.current
        var highs: [Date: Double] = [:]
        var lows: [Date: Double] = [:]
        for (ts, hiF, loF) in perRecord {
            let key = cal.startOfDay(for: ts)
            let hiC = (hiF - 32) * 5 / 9
            let loC = (loF - 32) * 5 / 9
            highs[key] = max(highs[key] ?? -.greatestFiniteMagnitude, hiC)
            lows[key] = min(lows[key] ?? .greatestFiniteMagnitude, loC)
        }
        return DavisWeatherLinkService.DavisDailyTemps(
            dailyHighC: highs,
            dailyLowC: lows,
            recordCount: perRecord.count
        )
    }

    /// Backfills the past `days` of vineyard-local rainfall into
    /// `rainfall_daily` via the davis-proxy edge function. Owner /
    /// manager only — the proxy enforces the role check using the
    /// caller's JWT. Davis credentials never leave the server.
    static func backfillRainfall(
        vineyardId: UUID,
        stationId: String,
        days: Int = 14,
        offsetDays: Int = 0,
        chunkDays: Int? = nil
    ) async throws -> DavisProxyBackfillResult {
        guard !stationId.isEmpty else { throw VineyardDavisProxyError.notConfigured }
        let clamped = max(1, min(365, days))
        let clampedOffset = max(0, min(clamped, offsetDays))
        var payload: [String: Any] = [
            "vineyardId": vineyardId.uuidString,
            "action": "backfill_rainfall",
            "stationId": stationId,
            "days": clamped,
            "offsetDays": clampedOffset,
        ]
        if let chunkDays {
            payload["chunkDays"] = max(1, min(60, chunkDays))
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
        return DavisProxyBackfillResult(
            success: success,
            daysRequested: intVal("days_requested"),
            daysProcessed: intVal("days_processed"),
            rowsUpserted: intVal("rows_upserted"),
            errorsCount: intVal("errors_count"),
            timezone: json["timezone"] as? String,
            offsetDays: intVal("offset_days"),
            chunkDays: intVal("chunk_days"),
            sliceLength: intVal("slice_length"),
            nextOffsetDays: nextOffset,
            more: (json["more"] as? Bool) ?? false,
            rateLimited: (json["rate_limited"] as? Bool) ?? false,
            proxyVersion: json["proxy_version"] as? String
        )
    }

    // MARK: - Internals

    /// Posts `payload` as JSON to the davis-proxy edge function and returns
    /// the parsed response object. Throws a typed
    /// `VineyardDavisProxyError` so callers can render appropriate UX.
    private static func invoke(
        payload: [String: Any]
    ) async throws -> [String: Any] {
        let provider = SupabaseClientProvider.shared
        guard provider.isConfigured else {
            throw VineyardDavisProxyError.network("Backend not configured")
        }

        let base = AppConfig.supabaseURL.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/functions/v1/\(functionName)") else {
            throw VineyardDavisProxyError.network("Invalid edge function URL")
        }

        // Caller JWT (if signed in). The edge function rejects anonymous
        // access, so we surface a clearer "not authenticated" error when
        // we can't get a session token.
        let session = try? await provider.client.auth.session
        guard let token = session?.accessToken, !token.isEmpty else {
            print("[DavisProxy] notAuthenticated action=\(payload["action"] as? String ?? "-") vineyardId=\(payload["vineyardId"] as? String ?? "-")")
            throw VineyardDavisProxyError.notAuthenticated
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw VineyardDavisProxyError.decoding("Could not encode request body")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw VineyardDavisProxyError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw VineyardDavisProxyError.network("No HTTP response")
        }

        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let errorMessage = body["error"] as? String

        let action = payload["action"] as? String ?? "-"
        let vid = payload["vineyardId"] as? String ?? "-"
        let stationId = payload["stationId"] as? String ?? "-"
        switch http.statusCode {
        case 200..<300:
            print("[DavisProxy] vineyardId=\(vid) provider=davis action=\(action) stationId=\(stationId) result=success status=\(http.statusCode)")
            return body
        case 401:
            print("[DavisProxy] vineyardId=\(vid) provider=davis action=\(action) result=fail status=401 reason=notAuthenticated")
            throw VineyardDavisProxyError.notAuthenticated
        case 403:
            print("[DavisProxy] vineyardId=\(vid) provider=davis action=\(action) result=fail status=403 reason=forbidden")
            throw VineyardDavisProxyError.forbidden(errorMessage ?? "")
        case 404:
            print("[DavisProxy] vineyardId=\(vid) provider=davis action=\(action) result=fail status=404 reason=notConfigured")
            throw VineyardDavisProxyError.notConfigured
        case 429:
            print("[DavisProxy] vineyardId=\(vid) provider=davis action=\(action) result=fail status=429 reason=rateLimited")
            throw VineyardDavisProxyError.rateLimited
        default:
            print("[DavisProxy] vineyardId=\(vid) provider=davis action=\(action) result=fail status=\(http.statusCode)")
            throw VineyardDavisProxyError.http(http.statusCode, errorMessage)
        }
    }
}
