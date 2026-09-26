import Foundation

/// Adapts provider detail into the canonical model; the calculator never reads provider payloads.
nonisolated enum SprayForecastPeriodService {
    private static func number(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    private static func periods(from samples: [(String, Int, Double?, Double?, Double?, Double?)]) -> [SprayForecastPeriod] {
        let groups = Dictionary(grouping: samples, by: { "\($0.0):\($0.1)" })
        return groups.values.compactMap { rows in
            guard let row = rows.first else { return nil }
            let temps = rows.compactMap(\.2)
            let winds = rows.compactMap(\.3)
            let humidity = rows.compactMap(\.4)
            let rain = rows.compactMap(\.5)
            return SprayForecastPeriod(date: row.0, startHour: row.1,
                startTimeLocal: String(format: "%02d:00", row.1), endTimeLocal: String(format: "%02d:00", row.1 + 4),
                tempMinC: temps.min(), tempMaxC: temps.max(), windMaxKmh: winds.max(),
                humidityMinPct: humidity.min(), humidityMaxPct: humidity.max(),
                rainMm: rain.isEmpty ? nil : rain.reduce(0, +), sampleCount: rows.count)
        }.sorted { $0.date == $1.date ? $0.startHour < $1.startHour : $0.date < $1.date }
    }

    static func willyWeather(days: [[String: Any]], timezone: TimeZone) -> [SprayForecastPeriod] {
        let iso = ISO8601DateFormatter()
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = timezone
        date.dateFormat = "yyyy-MM-dd"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        var values: [String: (String, Int, Double?, Double?, Double?, Double?)] = [:]
        for day in days {
            for (field, key) in [("temperatureEntries", "temperature"), ("windEntries", "speed"),
                                 ("humidityEntries", "humidity"), ("rainfallEntries", "rainMaxMm")] {
                for entry in day[field] as? [[String: Any]] ?? [] {
                    guard let text = entry["dateTime"] as? String,
                          let instant = iso.date(from: text) else { continue }
                    let hour = calendar.component(.hour, from: instant) / 4 * 4
                    let localDate = date.string(from: instant)
                    let id = "\(localDate):\(hour):\(field):\(text)"
                    let amount = number(entry[key])
                    values[id] = (localDate, hour, field == "temperatureEntries" ? amount : nil,
                                  field == "windEntries" ? amount : nil,
                                  field == "humidityEntries" ? amount : nil,
                                  field == "rainfallEntries" ? amount : nil)
                }
            }
        }
        return periods(from: Array(values.values))
    }

    static func openMeteo(json: [String: Any]) -> [SprayForecastPeriod] {
        guard let zoneName = json["timezone"] as? String, let zone = TimeZone(identifier: zoneName),
              let hourly = json["hourly"] as? [String: Any], let times = hourly["time"] as? [String] else { return [] }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = zone
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = zone
        date.dateFormat = "yyyy-MM-dd"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func value(_ key: String, _ index: Int) -> Double? {
            guard let array = hourly[key] as? [Any], array.indices.contains(index) else { return nil }
            return number(array[index])
        }
        let samples: [(String, Int, Double?, Double?, Double?, Double?)] = times.enumerated().compactMap { index, text in
            guard let instant = parser.date(from: text) else { return nil }
            return (date.string(from: instant), calendar.component(.hour, from: instant) / 4 * 4,
                    value("temperature_2m", index), value("wind_speed_10m", index),
                    value("relative_humidity_2m", index), value("precipitation", index))
        }
        return periods(from: samples)
    }

    static func fetchOpenMeteo(latitude: Double, longitude: Double) async -> [SprayForecastPeriod] {
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&hourly=temperature_2m,wind_speed_10m,relative_humidity_2m,precipitation&forecast_days=5&timezone=auto&wind_speed_unit=kmh&precipitation_unit=mm") else { return [] }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return openMeteo(json: json)
    }
}
