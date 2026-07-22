import Foundation
import Supabase

nonisolated struct DailyGDDEntry: Codable, Sendable {
    let date: String
    let gdd: Double
}

nonisolated struct WeatherDailyGDDRecord: Codable, Sendable {
    let station_id: String
    let date: String
    let gdd: Double
    let temp_high: Double?
    let temp_low: Double?
    let base_temp: Double
    let updated_at: String?
}

nonisolated struct DailyTemp: Codable, Sendable {
    let high: Double
    let low: Double
}

nonisolated struct GDDComputeResult: Sendable {
    let gdd: Double
    let daysCovered: Int
    let expectedDays: Int
    let interpolatedDays: Int
    let firstDate: Date?
    let lastDate: Date?
}

/// Configured data source used to populate `temps` for a season GDD
/// calculation. Each case carries the information `DegreeDayService`
/// needs to fetch daily high/low temperatures and a stable cache key.
nonisolated enum GDDSource: Equatable, Sendable, Hashable {
    case weatherUnderground(stationId: String)
    case openMeteoArchive(latitude: Double, longitude: Double)
    case davisWeatherLink(stationId: String)

    /// Stable identifier used as the key in `DegreeDayService.temps`.
    var sourceKey: String {
        switch self {
        case .weatherUnderground(let id):
            return id
        case .openMeteoArchive(let lat, let lon):
            return String(format: "openmeteo:%.4f,%.4f", lat, lon)
        case .davisWeatherLink(let id):
            return "davis:\(id)"
        }
    }

    /// Short label shown in Optimal Ripeness UI.
    var displayName: String {
        switch self {
        case .weatherUnderground: return "Weather Underground"
        case .openMeteoArchive: return "Open-Meteo Archive"
        case .davisWeatherLink: return "Davis WeatherLink"
        }
    }
}

@Observable
@MainActor
class DegreeDayService {
    var isLoading: Bool = false
    var errorMessage: String?
    var seasonGDD: Double?
    var lastUpdated: Date?
    var daysCovered: Int = 0
    var expectedDays: Int = 0
    var interpolatedDays: Int = 0
    var firstDateCovered: Date?
    var lastDateCovered: Date?
    var lastDiagnostics: String?
    var lastStationId: String?
    var lastSeasonStart: Date?
    var lastFetchAttempted: Int = 0
    var lastFetchSucceeded: Int = 0
    var lastFetchStatusSample: String?
    /// The most recent source used to populate `seasonGDD` / temps.
    /// Surfaced in the Optimal Ripeness UI as "GDD source: …".
    var lastSource: GDDSource?

    /// Per-station cache of daily temperatures keyed by yyyyMMdd.
    private var temps: [String: [String: DailyTemp]] = [:]

    private let apiKey: String = AppConfig.wundergroundAPIKey
    private let baseTemp: Double = 10.0
    private let beddCap: Double = 19.0

    private var cacheKey: String { "vinetrack_gdd_temps_cache_v2" }
    private let lastDailySyncKey = "vinetrack_gdd_last_daily_sync"

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let wuDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    init() {
        loadCache()
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return }
        if let decoded = try? JSONDecoder().decode([String: [String: DailyTemp]].self, from: data) {
            temps = decoded
        }
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(temps) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    // MARK: - Unified source-aware entry point

    /// Fetch & compute season GDD for any supported source. The result
    /// is written into `seasonGDD` / `lastSource` and cached temps are
    /// keyed by the source's `sourceKey` so subsequent
    /// `dailyGDDSeries(stationId:)` calls find the same data.
    func fetchSeason(source: GDDSource, seasonStart: Date, useBEDD: Bool = true) async {
        switch source {
        case .weatherUnderground(let id):
            await fetchSeasonGDD(stationId: id, seasonStart: seasonStart, latitude: nil, useBEDD: useBEDD)
            lastSource = .weatherUnderground(stationId: id)
        case .openMeteoArchive(let lat, let lon):
            await fetchSeasonOpenMeteo(latitude: lat, longitude: lon, seasonStart: seasonStart, useBEDD: useBEDD)
        case .davisWeatherLink(let stationId):
            // Davis seasons are best fetched via the vineyard-aware helper
            // below; this entry point is only used when a direct, fully
            // configured Davis client is on this device.
            await fetchSeasonDavis(
                stationId: stationId,
                vineyardId: nil,
                useProxy: false,
                latitude: nil,
                seasonStart: seasonStart,
                useBEDD: useBEDD
            )
        }
    }

    /// Returns `true` when at least one usable daily temperature is
    /// cached for the given source. Callers use this to decide whether
    /// to keep `lastSource` set after a network failure, or fall through
    /// to the next priority source.
    func hasUsableData(for source: GDDSource) -> Bool {
        guard let cached = temps[source.sourceKey] else { return false }
        return !cached.isEmpty
    }

    /// Returns true if today's daily refresh hasn't happened yet for this station.
    func needsDailyRefresh(for stationId: String) -> Bool {
        guard !stationId.isEmpty else { return false }
        let key = "\(lastDailySyncKey)_\(stationId)"
        guard let last = UserDefaults.standard.object(forKey: key) as? Date else { return true }
        return !Calendar.current.isDateInToday(last)
    }

    private func markDailyRefresh(for stationId: String) {
        let key = "\(lastDailySyncKey)_\(stationId)"
        UserDefaults.standard.set(Date(), forKey: key)
    }

    /// Fetch & cache temperatures for the given station from `seasonStart` through yesterday.
    /// Sets the published `seasonGDD` using the supplied latitude / BEDD flag.
    func fetchSeasonGDD(stationId: String, seasonStart: Date, latitude: Double? = nil, useBEDD: Bool = true) async {
        guard !stationId.isEmpty else {
            errorMessage = "No weather station set. Configure one in Vineyard Setup."
            return
        }

        isLoading = true
        errorMessage = nil
        lastStationId = stationId
        lastSeasonStart = seasonStart
        lastFetchAttempted = 0
        lastFetchSucceeded = 0
        lastFetchStatusSample = nil
        var diagnostics: [String] = []
        if apiKey.isEmpty {
            diagnostics.append("Weather Underground API key missing in build.")
        } else {
            diagnostics.append("API key: \(String(apiKey.prefix(4)))… (\(apiKey.count) chars)")
        }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.startOfDay(for: seasonStart)
        guard start <= today else {
            seasonGDD = 0
            daysCovered = 0
            lastUpdated = Date()
            firstDateCovered = nil
            lastDateCovered = nil
            isLoading = false
            return
        }

        var stationTemps = temps[stationId] ?? [:]

        var dates: [Date] = []
        var d = start
        while d < today {
            dates.append(d)
            d = cal.date(byAdding: .day, value: 1, to: d) ?? today
        }

        // 1. Pull existing records from Supabase for this station+season
        #if LEGACY_SUPABASE_ENABLED
        if isSupabaseConfigured {
            let startStr = Self.dateFormatter.string(from: start)
            let endStr = Self.dateFormatter.string(from: today)
            do {
                let records: [WeatherDailyGDDRecord] = try await supabase
                    .from("weather_daily_gdd")
                    .select()
                    .eq("station_id", value: stationId)
                    .gte("date", value: startStr)
                    .lt("date", value: endStr)
                    .execute()
                    .value
                for record in records {
                    let key = compactKey(fromISODate: record.date)
                    if let high = record.temp_high, let low = record.temp_low {
                        stationTemps[key] = DailyTemp(high: high, low: low)
                    }
                }
                diagnostics.append("Supabase cached rows: \(records.count)")
            } catch {
                diagnostics.append("Supabase pull failed: \(error.localizedDescription)")
                print("DegreeDayService: Supabase pull failed: \(error)")
            }
        } else {
            diagnostics.append("Supabase not configured.")
        }
        #else
        diagnostics.append("Supabase not configured.")
        #endif

        // 2. Determine missing dates and fetch from Weather Underground.
        // WU PWS history allows ~1500/day on the free tier, so we can safely
        // pull an entire season in one pass.
        let missingDates: [Date] = dates.filter { stationTemps[Self.wuDateFormatter.string(from: $0)] == nil }
        let maxFetch = 500
        let toFetch = Array(missingDates.suffix(maxFetch))
        diagnostics.append("Season dates: \(dates.count) • missing: \(missingDates.count) • will fetch: \(toFetch.count)")

        var newRecords: [WeatherDailyGDDRecord] = []
        var firstStatusSample: String?
        var failureCounts: [String: Int] = [:]
        if !apiKey.isEmpty {
            for date in toFetch {
                let dateStr = Self.wuDateFormatter.string(from: date)
                lastFetchAttempted += 1
                var outcome = await fetchDailyTemps(stationId: stationId, dateString: dateStr)
                // Retry once after a brief pause if we hit a rate limit
                if outcome.result == nil, outcome.statusDescription.contains("429") {
                    try? await Task.sleep(for: .milliseconds(800))
                    outcome = await fetchDailyTemps(stationId: stationId, dateString: dateStr)
                }
                if let result = outcome.result {
                    lastFetchSucceeded += 1
                    stationTemps[dateStr] = DailyTemp(high: result.high, low: result.low)
                    let plainGDD = max(0, ((result.high + result.low) / 2.0) - baseTemp)
                    newRecords.append(WeatherDailyGDDRecord(
                        station_id: stationId,
                        date: Self.dateFormatter.string(from: date),
                        gdd: plainGDD,
                        temp_high: result.high,
                        temp_low: result.low,
                        base_temp: baseTemp,
                        updated_at: nil
                    ))
                } else {
                    if firstStatusSample == nil {
                        firstStatusSample = outcome.statusDescription
                    }
                    let bucket = Self.failureBucket(outcome.statusDescription)
                    failureCounts[bucket, default: 0] += 1
                }
            }
            lastFetchStatusSample = firstStatusSample
            if lastFetchAttempted > 0 {
                diagnostics.append("WU fetches: \(lastFetchSucceeded)/\(lastFetchAttempted) succeeded")
                if !failureCounts.isEmpty {
                    let summary = failureCounts
                        .sorted { $0.value > $1.value }
                        .map { "\($0.key): \($0.value)" }
                        .joined(separator: ", ")
                    diagnostics.append("Failures — \(summary)")
                }
                if lastFetchSucceeded == 0, firstStatusSample != nil {
                    errorMessage = "Some missing days/records."
                }
            }
        } else if !missingDates.isEmpty {
            errorMessage = "Weather Underground API key not configured."
        }

        // 3. Persist to Supabase in chunks so a large batch doesn't exceed request limits.
        #if LEGACY_SUPABASE_ENABLED
        if isSupabaseConfigured && !newRecords.isEmpty {
            let chunkSize = 100
            var persisted = 0
            var upsertError: String?
            for start in stride(from: 0, to: newRecords.count, by: chunkSize) {
                let end = min(start + chunkSize, newRecords.count)
                let chunk = Array(newRecords[start..<end])
                do {
                    try await supabase
                        .from("weather_daily_gdd")
                        .upsert(chunk, onConflict: "station_id,date")
                        .execute()
                    persisted += chunk.count
                } catch {
                    upsertError = error.localizedDescription
                    print("DegreeDayService: Supabase upsert failed: \(error)")
                    break
                }
            }
            if let upsertError {
                diagnostics.append("Supabase upsert failed after \(persisted) rows: \(upsertError)")
            } else {
                diagnostics.append("Supabase upserted: \(persisted) rows")
            }
        }
        #endif

        temps[stationId] = stationTemps
        saveCache()

        let result = computeGDD(stationId: stationId, from: start, to: today, latitude: latitude, useBEDD: useBEDD)
        seasonGDD = result.gdd
        daysCovered = result.daysCovered
        expectedDays = result.expectedDays
        interpolatedDays = result.interpolatedDays
        firstDateCovered = result.firstDate
        lastDateCovered = result.lastDate
        lastUpdated = Date()
        if result.daysCovered == 0 && errorMessage == nil {
            if apiKey.isEmpty {
                errorMessage = "Weather Underground API key not configured."
            } else if dates.isEmpty {
                errorMessage = "Budburst date is today — no days to accumulate yet."
            } else {
                errorMessage = "No temperature data returned for station \"\(stationId)\". Verify the PWS ID is correct and reporting."
            }
        }
        diagnostics.append("Days with data: \(result.daysCovered) • GDD: \(Int(result.gdd))")
        lastDiagnostics = diagnostics.joined(separator: "\n")
        markDailyRefresh(for: stationId)
        isLoading = false
    }

    /// Compute GDD/BEDD from cached temperatures between two dates (exclusive end).
    /// Missing days are back-filled with the average of up to 3 reported entries on
    /// each side so the accumulation isn't undercounted by sensor gaps.
    func computeGDD(stationId: String, from start: Date, to end: Date, latitude: Double?, useBEDD: Bool) -> GDDComputeResult {
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)
        var allDays: [Date] = []
        var d = startDay
        while d < endDay {
            allDays.append(d)
            d = cal.date(byAdding: .day, value: 1, to: d) ?? endDay
        }

        let expected = allDays.count
        guard let stationTemps = temps[stationId] else {
            return GDDComputeResult(gdd: 0, daysCovered: 0, expectedDays: expected, interpolatedDays: 0, firstDate: nil, lastDate: nil)
        }

        // Build aligned temp array — nil where missing.
        var raw: [DailyTemp?] = allDays.map { stationTemps[Self.wuDateFormatter.string(from: $0)] }
        let reportedCount = raw.compactMap { $0 }.count

        // Interpolate missing entries from up to 3 reported neighbours on each side.
        var interpolated = 0
        var filled = raw
        for i in 0..<filled.count where filled[i] == nil {
            var highs: [Double] = []
            var lows: [Double] = []
            var j = i - 1
            while j >= 0 && highs.count < 3 {
                if let t = raw[j] { highs.append(t.high); lows.append(t.low) }
                j -= 1
            }
            var k = i + 1
            while k < raw.count && highs.count < 6 {
                if let t = raw[k] { highs.append(t.high); lows.append(t.low) }
                k += 1
            }
            guard !highs.isEmpty else { continue }
            let avgHigh = highs.reduce(0, +) / Double(highs.count)
            let avgLow = lows.reduce(0, +) / Double(lows.count)
            filled[i] = DailyTemp(high: avgHigh, low: avgLow)
            interpolated += 1
        }

        var total: Double = 0
        var count: Int = 0
        var first: Date?
        var last: Date?
        for (idx, day) in allDays.enumerated() {
            guard let temp = filled[idx] else { continue }
            let value = useBEDD ? beddDay(high: temp.high, low: temp.low, latitude: latitude, date: day)
                                : max(0, ((temp.high + temp.low) / 2.0) - baseTemp)
            total += value
            count += 1
            if first == nil { first = day }
            last = day
        }
        _ = reportedCount
        return GDDComputeResult(gdd: total, daysCovered: count, expectedDays: expected, interpolatedDays: interpolated, firstDate: first, lastDate: last)
    }

    /// Returns per-day GDD values (with missing days interpolated) plus a running cumulative total.
    func dailyGDDSeries(stationId: String, from start: Date, to end: Date, latitude: Double?, useBEDD: Bool) -> [(date: Date, daily: Double, cumulative: Double, interpolated: Bool)] {
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)
        var allDays: [Date] = []
        var d = startDay
        while d < endDay {
            allDays.append(d)
            d = cal.date(byAdding: .day, value: 1, to: d) ?? endDay
        }
        guard let stationTemps = temps[stationId] else { return [] }
        var raw: [DailyTemp?] = allDays.map { stationTemps[Self.wuDateFormatter.string(from: $0)] }
        var filled = raw
        var interpolatedFlags = Array(repeating: false, count: raw.count)
        for i in 0..<filled.count where filled[i] == nil {
            var highs: [Double] = []
            var lows: [Double] = []
            var j = i - 1
            while j >= 0 && highs.count < 3 {
                if let t = raw[j] { highs.append(t.high); lows.append(t.low) }
                j -= 1
            }
            var k = i + 1
            while k < raw.count && highs.count < 6 {
                if let t = raw[k] { highs.append(t.high); lows.append(t.low) }
                k += 1
            }
            guard !highs.isEmpty else { continue }
            let avgHigh = highs.reduce(0, +) / Double(highs.count)
            let avgLow = lows.reduce(0, +) / Double(lows.count)
            filled[i] = DailyTemp(high: avgHigh, low: avgLow)
            interpolatedFlags[i] = true
        }
        var cumulative: Double = 0
        var result: [(date: Date, daily: Double, cumulative: Double, interpolated: Bool)] = []
        for (idx, day) in allDays.enumerated() {
            guard let temp = filled[idx] else { continue }
            let value = useBEDD ? beddDay(high: temp.high, low: temp.low, latitude: latitude, date: day)
                                : max(0, ((temp.high + temp.low) / 2.0) - baseTemp)
            cumulative += value
            result.append((date: day, daily: value, cumulative: cumulative, interpolated: interpolatedFlags[idx]))
        }
        return result
    }

    private func beddDay(high: Double, low: Double, latitude: Double?, date: Date) -> Double {
        let cappedHigh = min(high, beddCap)
        let cappedLow = min(low, beddCap)
        let mean = (cappedHigh + cappedLow) / 2.0
        var heat = max(0, mean - baseTemp)

        let range = high - low
        if range > 13 {
            heat += (range - 13) * 0.25
        }

        let k = dayLengthFactor(latitude: latitude, date: date)
        return heat * k
    }

    private func dayLengthFactor(latitude: Double?, date: Date) -> Double {
        guard let lat = latitude, abs(lat) <= 66 else { return 1.0 }
        let cal = Calendar(identifier: .gregorian)
        let n = cal.ordinality(of: .day, in: .year, for: date) ?? 1
        let decl = 23.45 * sin((360.0 * Double(284 + n) / 365.0) * .pi / 180.0)
        let latRad = lat * .pi / 180.0
        let declRad = decl * .pi / 180.0
        let cosOmega = -tan(latRad) * tan(declRad)
        let clamped = max(-1.0, min(1.0, cosOmega))
        let omega = acos(clamped) * 180.0 / .pi
        let dayLength = 2.0 * omega / 15.0
        return max(0.5, min(1.5, dayLength / 12.0))
    }

    private func compactKey(fromISODate iso: String) -> String {
        iso.replacingOccurrences(of: "-", with: "")
    }

    private struct DailyTempResult {
        let high: Double
        let low: Double
    }

    private struct FetchOutcome {
        let result: DailyTempResult?
        let statusDescription: String
    }

    private func fetchDailyTemps(stationId: String, dateString: String) async -> FetchOutcome {
        let dailyOutcome = await fetchFromEndpoint(path: "daily", stationId: stationId, dateString: dateString)
        if dailyOutcome.result != nil { return dailyOutcome }
        // Fall back to hourly history and derive high/low — WU's daily summary is often
        // missing for older dates even when the hourly observations exist.
        let hourlyOutcome = await fetchFromEndpoint(path: "all", stationId: stationId, dateString: dateString)
        if hourlyOutcome.result != nil { return hourlyOutcome }
        return dailyOutcome
    }

    private func fetchFromEndpoint(path: String, stationId: String, dateString: String) async -> FetchOutcome {
        let urlString = "https://api.weather.com/v2/pws/history/\(path)?stationId=\(stationId)&format=json&units=m&date=\(dateString)&numericPrecision=decimal&apiKey=\(apiKey)"
        guard let url = URL(string: urlString) else {
            return FetchOutcome(result: nil, statusDescription: "Invalid URL")
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                return FetchOutcome(result: nil, statusDescription: "No HTTP response")
            }
            if http.statusCode == 204 {
                return FetchOutcome(result: nil, statusDescription: "204 No Content")
            }
            if http.statusCode != 200 {
                let body = String(data: data.prefix(120), encoding: .utf8) ?? ""
                return FetchOutcome(result: nil, statusDescription: "HTTP \(http.statusCode) \(body)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return FetchOutcome(result: nil, statusDescription: "Bad JSON")
            }
            let entries = (json["observations"] as? [[String: Any]])
                ?? (json["summaries"] as? [[String: Any]])
                ?? []
            if entries.isEmpty {
                return FetchOutcome(result: nil, statusDescription: "Some missing days/records")
            }

            if path == "daily" {
                let obs = entries[0]
                let metric = (obs["metric"] as? [String: Any]) ?? obs
                let tempHigh = parseDouble(metric["tempHigh"]) ?? parseDouble(metric["tempMax"]) ?? parseDouble(obs["tempHigh"])
                let tempLow = parseDouble(metric["tempLow"]) ?? parseDouble(metric["tempMin"]) ?? parseDouble(obs["tempLow"])
                guard let high = tempHigh, let low = tempLow else {
                    return FetchOutcome(result: nil, statusDescription: "Missing tempHigh/tempLow")
                }
                return FetchOutcome(result: DailyTempResult(high: high, low: low), statusDescription: "200 OK")
            } else {
                // Hourly: derive high/low from all observations.
                var high: Double = -.greatestFiniteMagnitude
                var low: Double = .greatestFiniteMagnitude
                var samples = 0
                for obs in entries {
                    let metric = (obs["metric"] as? [String: Any]) ?? obs
                    let t = parseDouble(metric["tempAvg"])
                        ?? parseDouble(metric["temp"])
                        ?? parseDouble(obs["temp"])
                    let hi = parseDouble(metric["tempHigh"]) ?? t
                    let lo = parseDouble(metric["tempLow"]) ?? t
                    if let hi = hi { high = max(high, hi); samples += 1 }
                    if let lo = lo { low = min(low, lo) }
                }
                guard samples > 0, high > -.greatestFiniteMagnitude, low < .greatestFiniteMagnitude else {
                    return FetchOutcome(result: nil, statusDescription: "Hourly missing temps")
                }
                return FetchOutcome(result: DailyTempResult(high: high, low: low), statusDescription: "200 OK (hourly)")
            }
        } catch {
            return FetchOutcome(result: nil, statusDescription: "Network error: \(error.localizedDescription)")
        }
    }

    private static func failureBucket(_ status: String) -> String {
        if status.contains("429") { return "Rate limited (429)" }
        if status.contains("401") || status.contains("403") { return "Auth error" }
        if status.contains("204") { return "No data (204)" }
        if status.hasPrefix("HTTP 5") { return "WU server error" }
        if status.contains("Empty") || status.contains("204") || status.contains("missing days") { return "Station didn\u{2019}t report" }
        if status.contains("Hourly missing") { return "Hourly data incomplete" }
        if status.contains("Missing tempHigh") { return "Missing temps" }
        if status.contains("Network") { return "Network error" }
        if status.contains("Bad JSON") { return "Bad JSON" }
        return "Other"
    }

    // MARK: - Open-Meteo Archive

    // MARK: - Davis WeatherLink (historic temperatures)

    /// Fetch & compute season GDD using Davis WeatherLink historic
    /// daily min/max temperatures. When `useProxy` is true the call is
    /// routed through the davis-proxy edge function (operators / any
    /// vineyard member). Otherwise direct WeatherLink credentials are
    /// read from the Keychain (owner / manager device).
    ///
    /// On success `lastSource` is set to `.davisWeatherLink(stationId:)`
    /// and the temp cache is keyed by that source's `sourceKey` so the
    /// existing `dailyGDDSeries(stationId:)` lookups work. On failure
    /// the cache is left untouched and `lastSource` remains `nil` so
    /// callers can fall through to a lower-priority source.
    func fetchSeasonDavis(
        stationId: String,
        vineyardId: UUID?,
        useProxy: Bool,
        latitude: Double?,
        seasonStart: Date,
        useBEDD: Bool = true
    ) async {
        guard !stationId.isEmpty else {
            errorMessage = "Davis station is not configured for this vineyard."
            return
        }
        let source = GDDSource.davisWeatherLink(stationId: stationId)
        let key = source.sourceKey
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.startOfDay(for: seasonStart)

        isLoading = true
        errorMessage = nil
        lastStationId = key
        lastSeasonStart = seasonStart
        lastFetchAttempted = 0
        lastFetchSucceeded = 0
        lastFetchStatusSample = nil
        var diagnostics: [String] = ["Davis WeatherLink \(useProxy ? "(shared)" : "(direct)")"]

        guard start <= today else {
            seasonGDD = 0
            daysCovered = 0
            firstDateCovered = nil
            lastDateCovered = nil
            lastSource = source
            lastUpdated = Date()
            isLoading = false
            return
        }

        var stationTemps = temps[key] ?? [:]
        var dates: [Date] = []
        var d = start
        while d < today {
            dates.append(d)
            d = cal.date(byAdding: .day, value: 1, to: d) ?? today
        }
        let missing = dates.filter { stationTemps[Self.wuDateFormatter.string(from: $0)] == nil }
        diagnostics.append("Season dates: \(dates.count) \u{2022} missing: \(missing.count)")

        // Davis historic costs one API call per 24h chunk. To avoid
        // hammering WeatherLink the first time, cap the per-fetch
        // window at 60 days; older days fall through to the
        // higher-priority chain (callers can then layer Open-Meteo in
        // for the long tail).
        if !missing.isEmpty {
            let maxDaysPerFetch = 60
            let toFetch = Array(missing.suffix(maxDaysPerFetch))
            let from = toFetch.first ?? start
            let to = (toFetch.last ?? today).addingTimeInterval(24 * 60 * 60)
            lastFetchAttempted = toFetch.count
            do {
                let result: DavisWeatherLinkService.DavisDailyTemps
                if useProxy {
                    guard let vid = vineyardId else {
                        errorMessage = "Davis vineyard ID missing."
                        isLoading = false
                        return
                    }
                    result = try await VineyardDavisProxyService.fetchHistoricDailyTemps(
                        vineyardId: vid, stationId: stationId, from: from, to: to
                    )
                } else {
                    let apiKey = WeatherKeychain.get(.apiKey) ?? ""
                    let apiSecret = WeatherKeychain.get(.apiSecret) ?? ""
                    guard !apiKey.isEmpty, !apiSecret.isEmpty else {
                        errorMessage = "Davis credentials are not available on this device."
                        isLoading = false
                        return
                    }
                    result = try await DavisWeatherLinkService.fetchDailyTemperatures(
                        apiKey: apiKey, apiSecret: apiSecret,
                        stationId: stationId, from: from, to: to
                    )
                }
                for (day, hi) in result.dailyHighC {
                    let k = Self.wuDateFormatter.string(from: day)
                    let lo = result.dailyLowC[day] ?? hi
                    stationTemps[k] = DailyTemp(high: hi, low: lo)
                }
                lastFetchSucceeded = result.dailyHighC.count
                diagnostics.append("Davis archive rows: \(result.recordCount), days written: \(result.dailyHighC.count)")
            } catch {
                lastFetchStatusSample = error.localizedDescription
                diagnostics.append("Davis fetch failed: \(error.localizedDescription)")
                // Surface the error but DO NOT mark `lastSource = source`.
                // Callers fall through to the next priority source.
                errorMessage = "Davis historical fetch failed: \(error.localizedDescription)"
                lastDiagnostics = diagnostics.joined(separator: "\n")
                isLoading = false
                return
            }
        }

        temps[key] = stationTemps
        saveCache()

        let result = computeGDD(stationId: key, from: start, to: today, latitude: latitude, useBEDD: useBEDD)
        seasonGDD = result.gdd
        daysCovered = result.daysCovered
        expectedDays = result.expectedDays
        interpolatedDays = result.interpolatedDays
        firstDateCovered = result.firstDate
        lastDateCovered = result.lastDate
        lastUpdated = Date()
        lastSource = source
        diagnostics.append("Days with data: \(result.daysCovered) \u{2022} GDD: \(Int(result.gdd))")
        if result.daysCovered == 0 {
            errorMessage = "Davis returned no usable temperatures for this season."
        }
        lastDiagnostics = diagnostics.joined(separator: "\n")
        markDailyRefresh(for: key)
        isLoading = false
    }

    /// Fetches daily min/max temperatures from Open-Meteo Archive for the
    /// given coordinates and computes `seasonGDD`. The temps cache is
    /// keyed by `GDDSource.openMeteoArchive(...).sourceKey` so existing
    /// `dailyGDDSeries(stationId:)` lookups work transparently.
    ///
    /// Open-Meteo Archive lags about 5 days behind today, so any missing
    /// recent days are filled from the forecast endpoint's `past_days`
    /// data.
    func fetchSeasonOpenMeteo(latitude: Double, longitude: Double, seasonStart: Date, useBEDD: Bool = true) async {
        let source = GDDSource.openMeteoArchive(latitude: latitude, longitude: longitude)
        let key = source.sourceKey
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.startOfDay(for: seasonStart)

        isLoading = true
        errorMessage = nil
        lastStationId = key
        lastSeasonStart = seasonStart
        lastFetchAttempted = 0
        lastFetchSucceeded = 0
        lastFetchStatusSample = nil
        var diagnostics: [String] = ["Open-Meteo Archive @ \(String(format: "%.4f,%.4f", latitude, longitude))"]

        guard start <= today else {
            seasonGDD = 0
            daysCovered = 0
            firstDateCovered = nil
            lastDateCovered = nil
            lastSource = source
            lastUpdated = Date()
            isLoading = false
            return
        }

        var stationTemps = temps[key] ?? [:]

        var dates: [Date] = []
        var d = start
        while d < today {
            dates.append(d)
            d = cal.date(byAdding: .day, value: 1, to: d) ?? today
        }

        let missing = dates.filter { stationTemps[Self.wuDateFormatter.string(from: $0)] == nil }
        diagnostics.append("Season dates: \(dates.count) • missing: \(missing.count)")

        if !missing.isEmpty {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(identifier: "UTC")
            fmt.dateFormat = "yyyy-MM-dd"
            let archiveCutoff = cal.date(byAdding: .day, value: -6, to: today) ?? today

            // 1. Archive endpoint for older dates (more authoritative).
            let archiveStart = missing.min() ?? start
            let archiveEnd = min(missing.max() ?? archiveCutoff, archiveCutoff)
            if archiveStart <= archiveEnd {
                let startStr = fmt.string(from: archiveStart)
                let endStr = fmt.string(from: archiveEnd)
                let urlString = "https://archive-api.open-meteo.com/v1/archive?latitude=\(latitude)&longitude=\(longitude)&start_date=\(startStr)&end_date=\(endStr)&daily=temperature_2m_max,temperature_2m_min&timezone=auto"
                if let url = URL(string: urlString) {
                    lastFetchAttempted += 1
                    do {
                        let (data, response) = try await URLSession.shared.data(from: url)
                        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                            let count = applyOpenMeteoDailyTemps(data: data, into: &stationTemps, fmt: fmt)
                            diagnostics.append("Archive rows: \(count)")
                            lastFetchSucceeded += 1
                        } else if let http = response as? HTTPURLResponse {
                            diagnostics.append("Archive HTTP \(http.statusCode)")
                            lastFetchStatusSample = "HTTP \(http.statusCode)"
                        }
                    } catch {
                        diagnostics.append("Archive error: \(error.localizedDescription)")
                        lastFetchStatusSample = error.localizedDescription
                    }
                }
            }

            // 2. Forecast endpoint with `past_days` to fill the recent
            //    days that the archive doesn't yet cover.
            let stillMissing = dates.filter { stationTemps[Self.wuDateFormatter.string(from: $0)] == nil }
            if !stillMissing.isEmpty {
                let earliestStill = stillMissing.min() ?? today
                let daysBack = max(1, min(92, (cal.dateComponents([.day], from: earliestStill, to: today).day ?? 1) + 1))
                let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&daily=temperature_2m_max,temperature_2m_min&past_days=\(daysBack)&forecast_days=1&timezone=auto"
                if let url = URL(string: urlString) {
                    lastFetchAttempted += 1
                    do {
                        let (data, response) = try await URLSession.shared.data(from: url)
                        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                            let count = applyOpenMeteoDailyTemps(data: data, into: &stationTemps, fmt: fmt)
                            diagnostics.append("Forecast past_days rows: \(count)")
                            lastFetchSucceeded += 1
                        } else if let http = response as? HTTPURLResponse {
                            diagnostics.append("Forecast HTTP \(http.statusCode)")
                            lastFetchStatusSample = "HTTP \(http.statusCode)"
                        }
                    } catch {
                        diagnostics.append("Forecast error: \(error.localizedDescription)")
                        lastFetchStatusSample = error.localizedDescription
                    }
                }
            }
        }

        temps[key] = stationTemps
        saveCache()

        let result = computeGDD(stationId: key, from: start, to: today, latitude: latitude, useBEDD: useBEDD)
        seasonGDD = result.gdd
        daysCovered = result.daysCovered
        expectedDays = result.expectedDays
        interpolatedDays = result.interpolatedDays
        firstDateCovered = result.firstDate
        lastDateCovered = result.lastDate
        lastUpdated = Date()
        lastSource = source
        diagnostics.append("Days with data: \(result.daysCovered) • GDD: \(Int(result.gdd))")
        if result.daysCovered == 0 && errorMessage == nil {
            errorMessage = "Open-Meteo did not return any temperatures for this location yet."
        }
        lastDiagnostics = diagnostics.joined(separator: "\n")
        markDailyRefresh(for: key)
        isLoading = false
    }

    /// Parses an Open-Meteo daily JSON payload and writes high/low
    /// readings into the supplied cache. Returns the number of days
    /// applied.
    private func applyOpenMeteoDailyTemps(
        data: Data,
        into stationTemps: inout [String: DailyTemp],
        fmt: DateFormatter
    ) -> Int {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = json["daily"] as? [String: Any],
              let times = daily["time"] as? [String],
              let highs = daily["temperature_2m_max"] as? [Any],
              let lows = daily["temperature_2m_min"] as? [Any] else {
            return 0
        }
        let count = min(times.count, min(highs.count, lows.count))
        var written = 0
        for i in 0..<count {
            guard let date = fmt.date(from: times[i]),
                  let high = parseDouble(highs[i]),
                  let low = parseDouble(lows[i]) else { continue }
            let k = Self.wuDateFormatter.string(from: date)
            stationTemps[k] = DailyTemp(high: high, low: low)
            written += 1
        }
        return written
    }

    private func parseDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}
