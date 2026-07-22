import Foundation

// MARK: - Models

nonisolated struct DavisStation: Sendable, Hashable, Identifiable, Codable {
    let stationId: String
    let stationIdUuid: String?
    let name: String
    let latitude: Double?
    let longitude: Double?
    let timezone: String?
    let active: Bool?

    var id: String { stationId }
}

nonisolated struct DavisSensorSummary: Sendable, Hashable, Codable {
    let hasTemperatureHumidity: Bool
    let hasRain: Bool
    let hasWind: Bool
    let hasLeafWetness: Bool
    let hasSoilMoisture: Bool
    let detectedFields: [String]
    let detectedSensorTypes: [Int]
    let detectedDataStructureTypes: [Int]
    /// Total number of sensor blocks parsed from the WeatherLink response.
    var sensorBlockCount: Int = 0
    /// Sensor blocks whose `data` array was missing or empty.
    var emptyDataBlockCount: Int = 0
    /// Sensor block sensor_type → data_structure_type pairs (sorted, unique),
    /// useful for diagnosing parser issues without exposing raw data.
    var blockSummaries: [String] = []

    /// Friendly list rendered in the settings UI.
    var displayList: [String] {
        var items: [String] = []
        if hasTemperatureHumidity { items.append("Temperature / Humidity") }
        if hasRain { items.append("Rainfall") }
        if hasWind { items.append("Wind") }
        if hasLeafWetness { items.append("Leaf wetness") }
        if hasSoilMoisture { items.append("Soil moisture") }
        return items
    }

    static let empty = DavisSensorSummary(
        hasTemperatureHumidity: false,
        hasRain: false,
        hasWind: false,
        hasLeafWetness: false,
        hasSoilMoisture: false,
        detectedFields: [],
        detectedSensorTypes: [],
        detectedDataStructureTypes: [],
        sensorBlockCount: 0,
        emptyDataBlockCount: 0,
        blockSummaries: []
    )
}

/// Daily rainfall totals (mm) aggregated from WeatherLink v2 historic
/// archive records. Keys are start-of-day in `Calendar.current`.
nonisolated struct DavisDailyRainfall: Sendable, Hashable {
    let dailyMm: [Date: Double]
    let totalMm: Double
    let recordCount: Int
    let coveredFrom: Date
    let coveredTo: Date
}

nonisolated struct DavisCurrentConditions: Sendable, Hashable {
    let stationId: String
    let generatedAt: Date
    /// Mapped current observations (best-effort; nil when not reported by the
    /// station). Davis returns imperial units; conversions happen here so
    /// callers always work in metric.
    let temperatureC: Double?
    let humidityPercent: Double?
    let rainMmLastHour: Double?
    let windKph: Double?
    /// `true`/`false` only when the station has a leaf-wetness sensor and the
    /// API returned a numeric reading; `nil` otherwise.
    let measuredLeafWetness: Bool?
    let sensors: DavisSensorSummary
}

nonisolated enum DavisWeatherLinkError: LocalizedError, Sendable {
    case missingCredentials
    case invalidCredentials
    case noStations
    case network(String)
    case decoding(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Save your Davis API Key and Secret first."
        case .invalidCredentials:
            return "Could not connect to WeatherLink. Check your API Key and API Secret."
        case .noStations:
            return "Connected, but no stations were returned for this WeatherLink account."
        case .network(let m):
            return "WeatherLink unavailable — \(m)"
        case .decoding(let m):
            return "WeatherLink response could not be parsed (\(m))."
        case .http(let code):
            if code == 401 || code == 403 {
                return "Could not connect to WeatherLink. Check your API Key and API Secret."
            }
            return "WeatherLink returned HTTP \(code)."
        }
    }
}

// MARK: - Service

/// Davis WeatherLink v2 client.
/// API Key is sent as the `api-key` query parameter; API Secret is sent in
/// the `X-Api-Secret` header. Neither is logged or persisted outside the
/// device Keychain.
nonisolated enum DavisWeatherLinkService {

    private static let baseURL = "https://api.weatherlink.com/v2"

    /// Validates credentials and returns the available stations. Use this for
    /// the Test Connection action.
    static func testConnection(apiKey: String, apiSecret: String) async throws -> [DavisStation] {
        try await fetchStations(apiKey: apiKey, apiSecret: apiSecret)
    }

    /// GET /v2/stations
    static func fetchStations(apiKey: String, apiSecret: String) async throws -> [DavisStation] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedSecret.isEmpty else {
            throw DavisWeatherLinkError.missingCredentials
        }
        let data = try await get(path: "/stations", apiKey: trimmedKey, apiSecret: trimmedSecret)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let array = json["stations"] as? [[String: Any]] else {
            throw DavisWeatherLinkError.decoding("Missing 'stations' array")
        }
        let stations = array.compactMap(parseStationDict)
        if stations.isEmpty { throw DavisWeatherLinkError.noStations }
        return stations
    }

    /// GET /v2/current/{station-id}
    static func fetchCurrentConditions(
        apiKey: String,
        apiSecret: String,
        stationId: String
    ) async throws -> DavisCurrentConditions {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedSecret.isEmpty, !stationId.isEmpty else {
            throw DavisWeatherLinkError.missingCredentials
        }
        let data = try await get(
            path: "/current/\(stationId)",
            apiKey: trimmedKey,
            apiSecret: trimmedSecret
        )
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DavisWeatherLinkError.decoding("Invalid JSON")
        }
        return parseCurrentConditionsJSON(json, fallbackStationId: stationId)
    }

    /// Parses a WeatherLink v2 `/current/{station-id}` response (already
    /// decoded as a JSON object). Used by both the direct Davis client and
    /// the vineyard-shared proxy path.
    static func parseCurrentConditionsJSON(
        _ json: [String: Any],
        fallbackStationId: String
    ) -> DavisCurrentConditions {
        let resolvedStationId: String = {
            if let n = json["station_id"] as? Int { return String(n) }
            if let s = json["station_id"] as? String { return s }
            return fallbackStationId
        }()
        let generatedAt: Date = {
            if let n = parseAnyDouble(json["generated_at"] ?? 0) { return Date(timeIntervalSince1970: n) }
            return Date()
        }()

        let sensorsArr = (json["sensors"] as? [[String: Any]]) ?? []
        let summary = detectSensors(sensorsArr: sensorsArr)

        var temperatureF: Double?
        var humidity: Double?
        var rainMm: Double?
        var windKph: Double?
        var leafWetnessReading: Double?

        for sensor in sensorsArr {
            guard let dataArr = sensor["data"] as? [[String: Any]],
                  let latest = dataArr.last else { continue }

            for (rawKey, value) in latest {
                let key = rawKey.lowercased()
                guard let v = parseAnyDouble(value) else { continue }

                // Outdoor air temperature/humidity (skip indoor, soil, leaf-temp).
                // Broadened aliases cover both DSt 10/17/23 current-condition
                // shapes and historic-style avg fields.
                if temperatureF == nil,
                   (key == "temp" || key == "temp_out" || key == "temp_out_last"
                    || key == "temp_avg" || key == "temp_avg_last" || key == "temp_last") {
                    temperatureF = v
                }
                if humidity == nil,
                   (key == "hum" || key == "hum_out" || key == "hum_last"
                    || key == "hum_avg" || key == "hum_avg_last") {
                    humidity = v
                }

                // Rainfall — prefer last 60 min metric/imperial fields if present,
                // then fall back through 15 min, daily, storm fields.
                if rainMm == nil {
                    if key.contains("rainfall_last_60_min_mm") {
                        rainMm = v
                    } else if key.contains("rainfall_last_60_min_in") {
                        rainMm = v * 25.4
                    } else if key == "rain_rate_last_mm" || key == "rainfall_last_15_min_mm" {
                        rainMm = v
                    } else if key == "rain_rate_last_in" || key == "rainfall_last_15_min_in" {
                        rainMm = v * 25.4
                    } else if key == "rain_rate_hi_mm" || key == "rainfall_daily_mm"
                                || key == "rain_storm_mm" || key == "rain_day_mm" {
                        rainMm = v
                    } else if key == "rain_rate_hi_in" || key == "rainfall_daily_in"
                                || key == "rain_storm_in" || key == "rain_day_in" {
                        rainMm = v * 25.4
                    }
                }

                // Wind — average over recent window if available. Broadened
                // to cover historic-style avg + 2-min variants. Davis reports mph.
                if windKph == nil,
                   (key == "wind_speed"
                    || key == "wind_speed_last"
                    || key == "wind_speed_avg"
                    || key.contains("wind_speed_avg_last_10_min")
                    || key.contains("wind_speed_avg_last_2_min")
                    || key.contains("wind_speed_hi_last_10_min")
                    || key.contains("wind_speed_last")) {
                    windKph = v * 1.60934
                }

                // Leaf wetness — Davis fields look like wet_leaf_last_*, leaf_wetness_*, etc.
                if leafWetnessReading == nil, isLeafWetnessKey(key) {
                    leafWetnessReading = v
                }
            }
        }

        let measuredLeafWetness: Bool? = {
            guard summary.hasLeafWetness, let reading = leafWetnessReading else { return nil }
            // Davis leaf wetness scale is 0..15. Industry threshold ~7.
            return reading >= 7
        }()

        let temperatureC: Double? = temperatureF.map { ($0 - 32) * 5 / 9 }

        return DavisCurrentConditions(
            stationId: resolvedStationId,
            generatedAt: generatedAt,
            temperatureC: temperatureC,
            humidityPercent: humidity,
            rainMmLastHour: rainMm,
            windKph: windKph,
            measuredLeafWetness: measuredLeafWetness,
            sensors: summary
        )
    }

    // MARK: - Sensor detection

    /// Davis sensor_type codes that identify ISS / outdoor station variants.
    /// These imply the station physically supports outdoor temperature,
    /// humidity, wind and rain even when the current-conditions response
    /// contains empty `data` arrays. Source: Davis WeatherLink v2 sensor
    /// catalogue (field guides for ISS, Vantage Pro2, Vue, EnviroMonitor).
    static let issSensorTypes: Set<Int> = [23, 37, 43, 45, 46, 48, 55]

    /// Sensor types that should never count as outdoor T/H/wind/rain.
    /// 27 = WeatherLink Live barometer / internal console block.
    static let internalSensorTypes: Set<Int> = [27]

    /// Inspects WeatherLink current-conditions sensor blocks and reports which
    /// sensor types are present. Detection is two-layered:
    /// 1. Field-based: when `data[]` contains the actual current-condition
    ///    field names, mark the matching capability.
    /// 2. Sensor-type fallback: when `data[]` is empty or missing fields,
    ///    infer capability from known Davis sensor_type codes (ISS family
    ///    implies T/H + wind + rain). Internal/console blocks are excluded.
    static func detectSensors(sensorsArr: [[String: Any]]) -> DavisSensorSummary {
        var hasTH = false
        var hasRain = false
        var hasWind = false
        var hasLW = false
        var hasSoil = false
        var fields: Set<String> = []
        var sensorTypes: Set<Int> = []
        var dataStructTypes: Set<Int> = []
        var sensorBlockCount = 0
        var emptyDataBlockCount = 0
        var blockSummaries: Set<String> = []

        for sensor in sensorsArr {
            sensorBlockCount += 1
            let sensorType = sensor["sensor_type"] as? Int
            let dataStruct = sensor["data_structure_type"] as? Int
            if let st = sensorType { sensorTypes.insert(st) }
            if let ds = dataStruct { dataStructTypes.insert(ds) }
            blockSummaries.insert("st=\(sensorType.map(String.init) ?? "?") dst=\(dataStruct.map(String.init) ?? "?")")

            // Sensor-type fallback: ISS-family stations imply outdoor T/H,
            // wind, rain — even when data[] is empty for that snapshot.
            if let st = sensorType, issSensorTypes.contains(st) {
                hasTH = true
                hasWind = true
                hasRain = true
            }
            // Davis sensor type 242 = Leaf & Soil Moisture/Temp ISS.
            if let st = sensorType, st == 242 {
                hasLW = true
                hasSoil = true
            }

            let dataArr = (sensor["data"] as? [[String: Any]]) ?? []
            if dataArr.isEmpty { emptyDataBlockCount += 1 }

            // Skip field scanning entirely for known internal/console blocks
            // so indoor temp/hum cannot be mistaken for outdoor readings.
            if let st = sensorType, internalSensorTypes.contains(st) { continue }

            for entry in dataArr {
                for rawKey in entry.keys {
                    fields.insert(rawKey)
                    let key = rawKey.lowercased()

                    // Outdoor air T/H — exclude indoor / soil / leaf-temp variants.
                    if (key.contains("temp") || key.contains("hum") || key.contains("dew")) &&
                        !key.contains("soil") && !key.contains("leaf") &&
                        !key.hasPrefix("temp_in") && !key.hasPrefix("hum_in") &&
                        !key.contains("_in_") {
                        hasTH = true
                    }
                    if key.contains("rain") || key.contains("rainfall") {
                        hasRain = true
                    }
                    if key.contains("wind") {
                        hasWind = true
                    }
                    if isLeafWetnessKey(key) {
                        hasLW = true
                    }
                    if key.contains("soil_moisture") || key.contains("moist_soil") {
                        hasSoil = true
                    }
                }
            }
        }

        return DavisSensorSummary(
            hasTemperatureHumidity: hasTH,
            hasRain: hasRain,
            hasWind: hasWind,
            hasLeafWetness: hasLW,
            hasSoilMoisture: hasSoil,
            detectedFields: Array(fields).sorted(),
            detectedSensorTypes: Array(sensorTypes).sorted(),
            detectedDataStructureTypes: Array(dataStructTypes).sorted(),
            sensorBlockCount: sensorBlockCount,
            emptyDataBlockCount: emptyDataBlockCount,
            blockSummaries: Array(blockSummaries).sorted()
        )
    }

    // MARK: - Internals

    private static func isLeafWetnessKey(_ key: String) -> Bool {
        // Common Davis WeatherLink field names for leaf wetness:
        // wet_leaf_last_1, wet_leaf_last_2, leaf_wetness, leaf_wetness_*,
        // leaf_wetness_last_*, wet_leaf_at_*.
        if key.contains("leaf_wetness") { return true }
        if key.contains("wet_leaf") { return true }
        if key.contains("leaf_wet") { return true }
        return false
    }

    static func parseStationDict(_ dict: [String: Any]) -> DavisStation? {
        let stationId: String
        if let n = dict["station_id"] as? Int {
            stationId = String(n)
        } else if let s = dict["station_id"] as? String {
            stationId = s
        } else if let n = dict["station_id"] as? NSNumber {
            stationId = n.stringValue
        } else {
            return nil
        }
        let name = (dict["station_name"] as? String) ?? "Davis Station \(stationId)"
        let active: Bool? = {
            if let b = dict["active"] as? Bool { return b }
            if let i = dict["active"] as? Int { return i != 0 }
            return nil
        }()
        return DavisStation(
            stationId: stationId,
            stationIdUuid: dict["station_id_uuid"] as? String,
            name: name,
            latitude: parseAnyDouble(dict["latitude"] ?? 0),
            longitude: parseAnyDouble(dict["longitude"] ?? 0),
            timezone: dict["time_zone"] as? String,
            active: active
        )
    }

    private static func get(
        path: String,
        apiKey: String,
        apiSecret: String,
        extraQuery: [URLQueryItem] = []
    ) async throws -> Data {
        guard var components = URLComponents(string: baseURL + path) else {
            throw DavisWeatherLinkError.network("Invalid URL")
        }
        var items: [URLQueryItem] = [URLQueryItem(name: "api-key", value: apiKey)]
        items.append(contentsOf: extraQuery)
        components.queryItems = items
        guard let url = components.url else {
            throw DavisWeatherLinkError.network("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiSecret, forHTTPHeaderField: "X-Api-Secret")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DavisWeatherLinkError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DavisWeatherLinkError.network("No HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw DavisWeatherLinkError.invalidCredentials
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DavisWeatherLinkError.http(http.statusCode)
        }
        return data
    }

    // MARK: - Historic rainfall

    /// Per WeatherLink v2 docs, the historic endpoint accepts a window of up
    /// to 24 hours per call. We chunk longer windows into 24h calls.
    private static let historicChunkSeconds: TimeInterval = 24 * 60 * 60

    /// Fetches archive (interval) rainfall and aggregates to daily totals (mm)
    /// using `Calendar.current` (device timezone). Splits the requested window
    /// into 24-hour chunks to satisfy the WeatherLink v2 historic limit.
    ///
    /// Cumulative running totals (`rainfall_year_*`, `rainfall_monthly_*`,
    /// `rainfall_daily_*`, `rainfall_storm_*`) are deliberately ignored — only
    /// per-interval `rainfall_mm` / `rainfall_in` fields are summed.
    static func fetchDailyRainfall(
        apiKey: String,
        apiSecret: String,
        stationId: String,
        from: Date,
        to: Date,
        maxConcurrent: Int = 4
    ) async throws -> DavisDailyRainfall {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedSecret.isEmpty, !stationId.isEmpty else {
            throw DavisWeatherLinkError.missingCredentials
        }
        guard from < to else {
            return DavisDailyRainfall(dailyMm: [:], totalMm: 0, recordCount: 0,
                                      coveredFrom: from, coveredTo: to)
        }

        var chunks: [(start: Date, end: Date)] = []
        var cur = from
        while cur < to {
            let next = min(cur.addingTimeInterval(historicChunkSeconds), to)
            chunks.append((cur, next))
            cur = next
        }

        let limit = max(1, min(maxConcurrent, 6))
        var perRecord: [(ts: Date, mm: Double)] = []

        try await withThrowingTaskGroup(of: [(Date, Double)].self) { group in
            var index = 0
            var inFlight = 0
            while index < chunks.count {
                while inFlight < limit && index < chunks.count {
                    let chunk = chunks[index]
                    index += 1
                    inFlight += 1
                    group.addTask {
                        try await fetchHistoricRainfallChunk(
                            apiKey: trimmedKey,
                            apiSecret: trimmedSecret,
                            stationId: stationId,
                            startEpoch: Int(chunk.start.timeIntervalSince1970),
                            endEpoch: Int(chunk.end.timeIntervalSince1970)
                        )
                    }
                }
                if let res = try await group.next() {
                    perRecord.append(contentsOf: res)
                    inFlight -= 1
                }
            }
            for try await res in group {
                perRecord.append(contentsOf: res)
            }
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

    /// Convenience: total rainfall for the last `days` days plus the daily
    /// breakdown.
    static func fetchRecentRainfall(
        apiKey: String,
        apiSecret: String,
        stationId: String,
        days: Int
    ) async throws -> DavisDailyRainfall {
        let cal = Calendar.current
        let to = Date()
        let startOfToday = cal.startOfDay(for: to)
        let from = cal.date(byAdding: .day, value: -max(1, days), to: startOfToday)
            ?? to.addingTimeInterval(-Double(max(1, days)) * 86400)
        return try await fetchDailyRainfall(
            apiKey: apiKey,
            apiSecret: apiSecret,
            stationId: stationId,
            from: from,
            to: to
        )
    }

    private static func fetchHistoricRainfallChunk(
        apiKey: String,
        apiSecret: String,
        stationId: String,
        startEpoch: Int,
        endEpoch: Int
    ) async throws -> [(Date, Double)] {
        let extra = [
            URLQueryItem(name: "start-timestamp", value: String(startEpoch)),
            URLQueryItem(name: "end-timestamp", value: String(endEpoch))
        ]
        let data = try await get(
            path: "/historic/\(stationId)",
            apiKey: apiKey,
            apiSecret: apiSecret,
            extraQuery: extra
        )
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sensors = json["sensors"] as? [[String: Any]] else {
            throw DavisWeatherLinkError.decoding("Missing 'sensors' array in historic")
        }
        return parseHistoricRainfall(sensorsArr: sensors)
    }

    // MARK: - Historic temperatures (for GDD)

    /// Aggregated daily min/max temperatures (Celsius) parsed from a
    /// WeatherLink v2 historic response. Keys are start-of-day in
    /// `Calendar.current`.
    nonisolated struct DavisDailyTemps: Sendable {
        let dailyHighC: [Date: Double]
        let dailyLowC: [Date: Double]
        let recordCount: Int
    }

    /// Fetches archive temperature records and aggregates to daily
    /// high/low (Celsius) using `Calendar.current`. Splits the window
    /// into 24-hour chunks to satisfy the WeatherLink v2 historic
    /// endpoint limit.
    static func fetchDailyTemperatures(
        apiKey: String,
        apiSecret: String,
        stationId: String,
        from: Date,
        to: Date,
        maxConcurrent: Int = 4
    ) async throws -> DavisDailyTemps {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedSecret.isEmpty, !stationId.isEmpty else {
            throw DavisWeatherLinkError.missingCredentials
        }
        guard from < to else {
            return DavisDailyTemps(dailyHighC: [:], dailyLowC: [:], recordCount: 0)
        }

        var chunks: [(start: Date, end: Date)] = []
        var cur = from
        while cur < to {
            let next = min(cur.addingTimeInterval(historicChunkSeconds), to)
            chunks.append((cur, next))
            cur = next
        }

        let limit = max(1, min(maxConcurrent, 6))
        var perRecord: [(ts: Date, highF: Double, lowF: Double)] = []

        try await withThrowingTaskGroup(of: [(Date, Double, Double)].self) { group in
            var index = 0
            var inFlight = 0
            while index < chunks.count {
                while inFlight < limit && index < chunks.count {
                    let chunk = chunks[index]
                    index += 1
                    inFlight += 1
                    group.addTask {
                        try await fetchHistoricTemperaturesChunk(
                            apiKey: trimmedKey,
                            apiSecret: trimmedSecret,
                            stationId: stationId,
                            startEpoch: Int(chunk.start.timeIntervalSince1970),
                            endEpoch: Int(chunk.end.timeIntervalSince1970)
                        )
                    }
                }
                if let res = try await group.next() {
                    for r in res { perRecord.append((r.0, r.1, r.2)) }
                    inFlight -= 1
                }
            }
            for try await res in group {
                for r in res { perRecord.append((r.0, r.1, r.2)) }
            }
        }

        let cal = Calendar.current
        var highs: [Date: Double] = [:]
        var lows: [Date: Double] = [:]
        for (ts, hiF, loF) in perRecord {
            let key = cal.startOfDay(for: ts)
            let hiC = (hiF - 32) * 5 / 9
            let loC = (loF - 32) * 5 / 9
            if let existing = highs[key] {
                highs[key] = max(existing, hiC)
            } else {
                highs[key] = hiC
            }
            if let existing = lows[key] {
                lows[key] = min(existing, loC)
            } else {
                lows[key] = loC
            }
        }
        return DavisDailyTemps(dailyHighC: highs, dailyLowC: lows, recordCount: perRecord.count)
    }

    private static func fetchHistoricTemperaturesChunk(
        apiKey: String,
        apiSecret: String,
        stationId: String,
        startEpoch: Int,
        endEpoch: Int
    ) async throws -> [(Date, Double, Double)] {
        let extra = [
            URLQueryItem(name: "start-timestamp", value: String(startEpoch)),
            URLQueryItem(name: "end-timestamp", value: String(endEpoch))
        ]
        let data = try await get(
            path: "/historic/\(stationId)",
            apiKey: apiKey,
            apiSecret: apiSecret,
            extraQuery: extra
        )
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sensors = json["sensors"] as? [[String: Any]] else {
            throw DavisWeatherLinkError.decoding("Missing 'sensors' array in historic")
        }
        return parseHistoricTemperatures(sensorsArr: sensors)
    }

    /// Parses per-interval outdoor temperature high/low values (in F) from
    /// a WeatherLink v2 historic response. Returns `(timestamp, hiF, loF)`
    /// per archive record that reports outdoor temperature.
    static func parseHistoricTemperatures(sensorsArr: [[String: Any]]) -> [(Date, Double, Double)] {
        var out: [(Date, Double, Double)] = []
        for sensor in sensorsArr {
            // Skip console / internal blocks so indoor temp can't pollute outdoor highs/lows.
            if let st = sensor["sensor_type"] as? Int, internalSensorTypes.contains(st) { continue }
            guard let dataArr = sensor["data"] as? [[String: Any]] else { continue }
            for entry in dataArr {
                guard let ts = parseAnyDouble(entry["ts"] ?? 0), ts > 0 else { continue }
                // Pull outdoor high/low — prefer explicit hi/lo, then avg.
                let hi = parseAnyDouble(entry["temp_hi"] ?? entry["temp_out_hi"] ?? entry["temp_last_hi"] ?? 0)
                    ?? parseAnyDouble(entry["temp_avg"] ?? entry["temp_out_avg"] ?? entry["temp_last"] ?? 0)
                let lo = parseAnyDouble(entry["temp_lo"] ?? entry["temp_out_lo"] ?? entry["temp_last_lo"] ?? 0)
                    ?? parseAnyDouble(entry["temp_avg"] ?? entry["temp_out_avg"] ?? entry["temp_last"] ?? 0)
                guard let hiF = hi, let loF = lo,
                      hiF.isFinite, loF.isFinite,
                      hiF > -100, hiF < 200, loF > -100, loF < 200 else { continue }
                out.append((Date(timeIntervalSince1970: ts), max(hiF, loF), min(hiF, loF)))
            }
        }
        return out
    }

    /// Parses interval rainfall fields from a WeatherLink v2 historic
    /// response. Returns `(timestamp, mm)` per archive record.
    static func parseHistoricRainfall(sensorsArr: [[String: Any]]) -> [(Date, Double)] {
        var out: [(Date, Double)] = []
        for sensor in sensorsArr {
            guard let dataArr = sensor["data"] as? [[String: Any]] else { continue }
            for entry in dataArr {
                guard let ts = parseAnyDouble(entry["ts"] ?? 0), ts > 0 else { continue }
                var mm: Double?
                // Prefer metric per-interval field, then imperial.
                if let v = parseAnyDouble(entry["rainfall_mm"] ?? 0),
                   !isCumulativeFieldPresent(entry: entry, preferredKey: "rainfall_mm") {
                    mm = v
                } else if let v = parseAnyDouble(entry["rainfall_in"] ?? 0),
                          !isCumulativeFieldPresent(entry: entry, preferredKey: "rainfall_in") {
                    mm = v * 25.4
                }
                if let value = mm, value.isFinite, value >= 0 {
                    out.append((Date(timeIntervalSince1970: ts), value))
                }
            }
        }
        return out
    }

    /// Helper: ensures the field we read is the per-interval rain key, not a
    /// running counter. Currently we only inspect the chosen key directly.
    private static func isCumulativeFieldPresent(entry: [String: Any], preferredKey: String) -> Bool {
        let key = preferredKey.lowercased()
        return key.contains("year") || key.contains("month") || key.contains("daily") || key.contains("storm")
    }

    static func parseAnyDouble(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
