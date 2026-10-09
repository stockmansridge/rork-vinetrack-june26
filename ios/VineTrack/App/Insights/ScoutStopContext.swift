import Foundation

/// Capture-time evidence for one stop. Nil on legacy assessments; never backfilled from today's conditions.
nonisolated struct ScoutStopContext: Codable, Equatable, Sendable {
    let captured_at: String
    let observer_id: String?
    let observer_name: String?
    var is_draft: Bool
    var latitude: Double?
    var longitude: Double?
    var accuracy_metres: Double?
    var location_measured_at: String?
    var weather: VineyardInsightsSyncRepository.WeatherPayload?

    var capturedAt: Date? { VineyardInsightsSyncRepository.parseTimestamp(captured_at) }
    var weatherSnapshot: ScoutWeatherSnapshot? {
        weather.map { ScoutWeatherSnapshot(observedAt: VineyardInsightsSyncRepository.parseTimestamp($0.observed_at),
            capturedAt: VineyardInsightsSyncRepository.parseTimestamp($0.captured_at) ?? capturedAt ?? .distantPast,
            source: $0.source, temperatureCelsius: $0.temperature_c, humidityPercent: $0.humidity_pct,
            windSpeedKph: $0.wind_kph, windGustKph: $0.gust_kph, recentRainfallMm: $0.recent_rainfall_mm,
            isStale: $0.is_stale, isUnavailable: $0.is_unavailable) }
    }

    mutating func setWeather(_ value: ScoutWeatherSnapshot) {
        weather = .init(observed_at: value.observedAt.map(VineyardInsightsSyncRepository.timestamp),
            captured_at: VineyardInsightsSyncRepository.timestamp(value.capturedAt), source: value.source,
            temperature_c: value.temperatureCelsius, humidity_pct: value.humidityPercent,
            wind_kph: value.windSpeedKph, gust_kph: value.windGustKph, recent_rainfall_mm: value.recentRainfallMm,
            is_stale: value.isStale, is_unavailable: value.isUnavailable)
    }
}
