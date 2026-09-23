import Foundation

nonisolated extension WillyWeatherForecastDay {
    func asForecastDay() -> ForecastDay {
        ForecastDay(
            date: date,
            forecastEToMm: et0Mm ?? 0,
            forecastRainMm: rainMm ?? 0,
            forecastWindKmhMax: windKmhMax,
            forecastTempMaxC: tempMaxC,
            forecastTempMinC: tempMinC,
            condition: condition,
            conditionCode: conditionCode,
            conditionKey: conditionKey,
            rainMinMm: rainMinMm,
            rainMaxMm: rainMaxMm,
            rainProbabilityPct: rainProbability
        )
    }
}

nonisolated struct IrrigationForecast: Sendable, Hashable {
    let days: [ForecastDay]
    let source: String
    let timezone: String?
    let rolling24hMm: Double?
    let rolling48hMm: Double?
    let rollingRainSource: String?

    init(days: [ForecastDay], source: String, timezone: String? = nil, rolling24hMm: Double? = nil, rolling48hMm: Double? = nil, rollingRainSource: String? = nil) {
        self.days = days
        self.source = source
        self.timezone = timezone
        self.rolling24hMm = rolling24hMm
        self.rolling48hMm = rolling48hMm
        self.rollingRainSource = rollingRainSource
    }
}

@Observable
class IrrigationForecastService {
    var isLoading: Bool = false
    var errorMessage: String?
    var forecast: IrrigationForecast?
    /// Reason the active forecast fell back to Open-Meteo, if any.
    /// Surfaced in the Weather sources card so users understand why
    /// the configured WillyWeather provider wasn't used.
    var fallbackReason: String?
    /// The provider resolved before fetching. Used by UI to show the
    /// expected source label even while the forecast is loading.
    var resolvedProvider: ForecastProvider = .auto

    /// Fetches an irrigation forecast for the given coordinates. If
    /// `vineyardId` is supplied and the vineyard's `forecastProvider` is
    /// set to WillyWeather (or `auto` with a configured WillyWeather
    /// integration), the WillyWeather edge-function proxy is tried
    /// first. Open-Meteo is used as a transparent fallback so callers
    /// always get a forecast when the network is available.
    func fetchForecast(
        latitude: Double,
        longitude: Double,
        days: Int = 5,
        vineyardId: UUID? = nil
    ) async {
        isLoading = true
        errorMessage = nil
        fallbackReason = nil
        forecast = nil

        let clampedDays = max(1, min(days, 16))

        // Resolve preferred provider for this vineyard. Prefer the
        // server-side preference (shared with Lovable) when available
        // so we don't depend on the local WeatherProviderStore cache
        // being hydrated on this device.
        var provider: ForecastProvider = .openMeteo
        var hasWillyLocation: Bool = false
        if let vid = vineyardId {
            let cfg = WeatherProviderStore.shared.config(for: vid)
            provider = cfg.forecastProvider
            hasWillyLocation = (cfg.willyWeatherLocationId?.isEmpty == false)

            // Refresh from backend (shared source of truth).
            if let backend = try? await VineyardWillyWeatherProxyService
                .getProviderPreference(vineyardId: vid) {
                switch backend {
                case "auto": provider = .auto
                case "open_meteo": provider = .openMeteo
                case "willyweather": provider = .willyWeather
                default: break
                }
            }

            // If we don't yet know the WW location locally, ask the
            // backend integration record. This handles users who set
            // up WillyWeather on another device / in Lovable.
            if !hasWillyLocation, provider != .openMeteo {
                let repo = SupabaseVineyardWeatherIntegrationRepository()
                if let integ = try? await repo.fetch(
                    vineyardId: vid, provider: "willyweather"
                ), let sid = integ.stationId, !sid.isEmpty {
                    hasWillyLocation = true
                    var updated = cfg
                    updated.willyWeatherHasApiKey = true
                    updated.willyWeatherLocationId = sid
                    updated.willyWeatherLocationName = integ.stationName
                    updated.forecastProvider = provider
                    WeatherProviderStore.shared.save(updated, for: vid)
                }
            }
        }
        resolvedProvider = provider

        // 1. Try WillyWeather if preferred / auto with WW configured.
        if let vid = vineyardId, provider != .openMeteo {
            let shouldTryWilly = provider == .willyWeather
                || (provider == .auto && hasWillyLocation)

            if shouldTryWilly {
                do {
                    let result = try await VineyardWillyWeatherProxyService
                        .fetchForecast(vineyardId: vid, days: clampedDays)
                    let mapped: [ForecastDay] = result.days.map { $0.asForecastDay() }
                    if !mapped.isEmpty {
                        forecast = IrrigationForecast(days: mapped, source: result.source, timezone: result.timezone, rolling24hMm: result.rolling24hMm, rolling48hMm: result.rolling48hMm, rollingRainSource: result.rollingRainSource)
                        isLoading = false
                        return
                    }
                    fallbackReason = "WillyWeather returned no forecast days — using Open-Meteo."
                    print("[Forecast] WillyWeather returned empty days, falling back to Open-Meteo.")
                } catch {
                    fallbackReason = "WillyWeather unavailable — using Open-Meteo (\(error.localizedDescription))."
                    if provider == .willyWeather {
                        errorMessage = fallbackReason
                    }
                    print("[Forecast] WillyWeather failed, falling back: \(error.localizedDescription)")
                }
            } else if provider == .willyWeather {
                fallbackReason = "WillyWeather is selected but not yet configured for this vineyard — using Open-Meteo."
            }
        }

        // 2. Open-Meteo fallback.
        await fetchOpenMeteo(latitude: latitude, longitude: longitude, days: clampedDays)
        isLoading = false
    }

    private func fetchOpenMeteo(latitude: Double, longitude: Double, days: Int) async {
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&daily=et0_fao_evapotranspiration,precipitation_sum,windspeed_10m_max,temperature_2m_max,temperature_2m_min&forecast_days=\(days)&timezone=auto&windspeed_unit=kmh"

        guard let url = URL(string: urlString) else {
            errorMessage = "Invalid forecast URL."
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                errorMessage = "Failed to fetch forecast (HTTP \(code))."
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let daily = json["daily"] as? [String: Any],
                  let times = daily["time"] as? [String],
                  let etoValues = daily["et0_fao_evapotranspiration"] as? [Any],
                  let rainValues = daily["precipitation_sum"] as? [Any] else {
                errorMessage = "Forecast response could not be parsed."
                return
            }
            let windValues = daily["windspeed_10m_max"] as? [Any] ?? []
            let tMaxValues = daily["temperature_2m_max"] as? [Any] ?? []
            let tMinValues = daily["temperature_2m_min"] as? [Any] ?? []

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = (json["timezone"] as? String).flatMap(TimeZone.init(identifier:)) ?? TimeZone(secondsFromGMT: 0)!

            var outDays: [ForecastDay] = []
            let count = min(times.count, min(etoValues.count, rainValues.count))
            for i in 0..<count {
                guard let date = formatter.date(from: times[i]) else { continue }
                let eto = Self.parseDouble(etoValues[i]) ?? 0
                let rain = Self.parseDouble(rainValues[i]) ?? 0
                let wind = i < windValues.count ? Self.parseDouble(windValues[i]) : nil
                let tMax = i < tMaxValues.count ? Self.parseDouble(tMaxValues[i]) : nil
                let tMin = i < tMinValues.count ? Self.parseDouble(tMinValues[i]) : nil
                outDays.append(ForecastDay(
                    date: date,
                    forecastEToMm: eto,
                    forecastRainMm: rain,
                    forecastWindKmhMax: wind,
                    forecastTempMaxC: tMax,
                    forecastTempMinC: tMin
                ))
            }

            forecast = IrrigationForecast(days: outDays, source: "Open-Meteo", timezone: json["timezone"] as? String)
        } catch {
            errorMessage = "Could not load forecast: \(error.localizedDescription)"
        }
    }

    private static func parseDouble(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
