import Foundation

// MARK: - Models

/// Daily rainfall totals (mm) aggregated from Weather Underground PWS
/// daily history. Keys are start-of-day in `Calendar.current`.
nonisolated struct WURainfallHistory: Sendable, Hashable {
    let dailyMm: [Date: Double]
    let totalMm: Double
    let recordCount: Int
    let coveredFrom: Date
    let coveredTo: Date
}

nonisolated enum WeatherUndergroundError: LocalizedError, Sendable {
    case missingAPIKey
    case missingStation
    case network(String)
    case decoding(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Weather Underground API key isn't configured on this device."
        case .missingStation:
            return "Select a Weather Underground PWS station first."
        case .network(let m): return "Weather Underground unavailable — \(m)"
        case .decoding(let m): return "Weather Underground response could not be parsed (\(m))."
        case .http(let code):
            if code == 401 || code == 403 {
                return "Weather Underground rejected the API key (HTTP \(code))."
            }
            return "Weather Underground returned HTTP \(code)."
        }
    }
}

// MARK: - Service

/// Weather Underground PWS rainfall history client.
///
/// Uses the `v2/pws/history/daily` endpoint which returns a single day's
/// summary per request. We parallelise with a small concurrency limit and
/// aggregate to per-day totals (mm).
///
/// Cumulative running totals (`precipTotal` is already a daily total in
/// the metric block, not a year/month counter) are mapped directly.
nonisolated enum WeatherUndergroundRainfallService {

    private static let baseURL = "https://api.weather.com/v2/pws"

    /// Fetches per-day rainfall totals for [from, to] inclusive.
    static func fetchDailyRainfall(
        apiKey: String,
        stationId: String,
        from: Date,
        to: Date,
        maxConcurrent: Int = 4
    ) async throws -> WURainfallHistory {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStation = stationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw WeatherUndergroundError.missingAPIKey }
        guard !trimmedStation.isEmpty else { throw WeatherUndergroundError.missingStation }

        let cal = Calendar.current
        let startDay = cal.startOfDay(for: from)
        let endDay = cal.startOfDay(for: to)
        guard startDay <= endDay else {
            return WURainfallHistory(dailyMm: [:], totalMm: 0, recordCount: 0,
                                     coveredFrom: from, coveredTo: to)
        }

        // Build the list of dates to fetch (one call per day).
        var days: [Date] = []
        var cur = startDay
        while cur <= endDay {
            days.append(cur)
            guard let next = cal.date(byAdding: .day, value: 1, to: cur) else { break }
            cur = next
        }

        let limit = max(1, min(maxConcurrent, 6))
        var perDay: [Date: Double] = [:]
        var firstError: Error?

        try await withThrowingTaskGroup(of: (Date, Double?).self) { group in
            var index = 0
            var inFlight = 0
            while index < days.count {
                while inFlight < limit && index < days.count {
                    let day = days[index]
                    index += 1
                    inFlight += 1
                    group.addTask {
                        do {
                            let mm = try await fetchDailySummary(
                                apiKey: trimmedKey,
                                stationId: trimmedStation,
                                date: day
                            )
                            return (day, mm)
                        } catch {
                            // Swallow per-day failures — we'll still return
                            // whatever we got. Bubble up the first one if
                            // every day failed.
                            return (day, nil)
                        }
                    }
                }
                if let res = try await group.next() {
                    if let mm = res.1 {
                        perDay[res.0] = mm
                    }
                    inFlight -= 1
                }
            }
            for try await res in group {
                if let mm = res.1 {
                    perDay[res.0] = mm
                }
            }
        }

        if perDay.isEmpty, let firstError {
            throw firstError
        }
        if perDay.isEmpty {
            // No data and no surfaced error — treat as upstream failure so
            // callers can fall back.
            throw WeatherUndergroundError.network("No observations returned for the requested window.")
        }

        let total = perDay.values.reduce(0, +)
        return WURainfallHistory(
            dailyMm: perDay,
            totalMm: total,
            recordCount: perDay.count,
            coveredFrom: startDay,
            coveredTo: endDay
        )
    }

    /// Convenience — last `days` days of rainfall.
    static func fetchRecentRainfall(
        apiKey: String,
        stationId: String,
        days: Int
    ) async throws -> WURainfallHistory {
        let cal = Calendar.current
        let to = Date()
        let startOfToday = cal.startOfDay(for: to)
        let from = cal.date(byAdding: .day, value: -max(1, days), to: startOfToday)
            ?? to.addingTimeInterval(-Double(max(1, days)) * 86400)
        return try await fetchDailyRainfall(
            apiKey: apiKey,
            stationId: stationId,
            from: from,
            to: to
        )
    }

    // MARK: - Single-day fetch

    private static func fetchDailySummary(
        apiKey: String,
        stationId: String,
        date: Date
    ) async throws -> Double? {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyyMMdd"
        let dateStr = fmt.string(from: date)

        guard var components = URLComponents(string: "\(baseURL)/history/daily") else {
            throw WeatherUndergroundError.network("Invalid URL")
        }
        components.queryItems = [
            URLQueryItem(name: "stationId", value: stationId),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "units", value: "m"),
            URLQueryItem(name: "date", value: dateStr),
            URLQueryItem(name: "numericPrecision", value: "decimal"),
            URLQueryItem(name: "apiKey", value: apiKey),
        ]
        guard let url = components.url else {
            throw WeatherUndergroundError.network("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw WeatherUndergroundError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw WeatherUndergroundError.network("No HTTP response")
        }
        // 204 No Content = no observations for this day; treat as 0 mm rather
        // than failing — WU returns 204 for stations that were offline.
        if http.statusCode == 204 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw WeatherUndergroundError.http(http.statusCode)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw WeatherUndergroundError.decoding("Invalid JSON")
        }
        guard let observations = json["observations"] as? [[String: Any]] else {
            return nil
        }

        // Daily summary endpoint returns one observation per day, but if WU
        // ever returns multiple sub-day rows we sum the precipTotal values.
        var dayMm: Double = 0
        var found = false
        for obs in observations {
            let metric = (obs["metric"] as? [String: Any]) ?? [:]
            // `precipTotal` from the daily endpoint is a per-day total, so
            // we take the max across rows (WU sometimes repeats the same
            // running total). For the conventional single-row response this
            // simply equals that row's value.
            if let v = parseDouble(metric["precipTotal"]) {
                dayMm = max(dayMm, v)
                found = true
            } else if let v = parseDouble(obs["precipTotal"]) {
                // Imperial fallback — convert inches to mm.
                dayMm = max(dayMm, v * 25.4)
                found = true
            }
        }
        return found ? dayMm : nil
    }

    private static func parseDouble(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        if value is NSNull { return nil }
        return nil
    }
}
