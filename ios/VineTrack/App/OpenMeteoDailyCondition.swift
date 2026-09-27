import Foundation

/// Condition-only completion from the same Open-Meteo request used for spray detail.
nonisolated struct OpenMeteoDailyCondition: Sendable, Equatable {
    let description: String
    let key: String

    static func from(code: Int) -> Self? {
        let value: (String, String)
        switch code {
        case 0: value = ("Clear", "clear")
        case 1: value = ("Mainly clear", "clear")
        case 2: value = ("Partly cloudy", "partly_cloudy")
        case 3: value = ("Overcast", "cloudy")
        case 45, 48: value = ("Fog", "fog")
        case 51...57: value = ("Drizzle", "drizzle")
        case 61...67, 80...82: value = ("Rain", "rain")
        case 71...77, 85, 86: value = ("Snow", "snow")
        case 95...99: value = ("Thunderstorms", "storm")
        default: return nil
        }
        return Self(description: value.0, key: value.1)
    }

    static func byDate(json: [String: Any]) -> [String: Self] {
        guard let daily = json["daily"] as? [String: Any],
              let dates = daily["time"] as? [String],
              let codes = daily["weather_code"] as? [Any] else { return [:] }
        var result: [String: Self] = [:]
        for (index, date) in dates.enumerated() where codes.indices.contains(index) {
            guard let code = codes[index] as? NSNumber, let condition = from(code: code.intValue) else { continue }
            result[date] = condition
        }
        return result
    }

    static func supplement(_ days: [ForecastDay], with conditions: [String: Self], timezone: TimeZone) -> [ForecastDay] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        return days.map { day in
            guard [day.condition, day.conditionKey, day.conditionCode].allSatisfy({ $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }),
                  let supplemental = conditions[formatter.string(from: day.date)] else { return day }
            return ForecastDay(date: day.date, forecastEToMm: day.forecastEToMm,
                forecastRainMm: day.forecastRainMm, forecastWindKmhMax: day.forecastWindKmhMax,
                forecastTempMaxC: day.forecastTempMaxC, forecastTempMinC: day.forecastTempMinC,
                condition: supplemental.description, conditionCode: day.conditionCode,
                conditionKey: supplemental.key, conditionSource: "Open-Meteo",
                rainMinMm: day.rainMinMm, rainMaxMm: day.rainMaxMm,
                rainProbabilityPct: day.rainProbabilityPct)
        }
    }
}
