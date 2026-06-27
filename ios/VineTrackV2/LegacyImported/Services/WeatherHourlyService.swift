import Foundation

/// A single hourly weather observation/forecast used by disease risk models.
///
/// The wetness signal is deliberately a *proxy*. Weather Underground and
/// Open-Meteo do not provide measured leaf wetness; we estimate it from
/// rainfall, relative humidity and the temperature/dew-point spread.
///
/// If a future ag-weather provider supplies a measured leaf wetness flag,
/// populate `measuredLeafWetness`; the proxy is then bypassed.
nonisolated struct WeatherHour: Sendable, Hashable, Identifiable {
    let date: Date
    let temperatureC: Double
    let dewPointC: Double?
    let humidityPercent: Double?
    let precipitationMm: Double
    /// Optional measured leaf wetness from an ag-weather provider.
    /// When non-nil this overrides the proxy computation.
    let measuredLeafWetness: Bool?

    var id: Date { date }

    /// `true` when the hour is considered wet.
    /// Returns the measured value when provided; otherwise the estimated
    /// proxy: rain > 0 mm OR RH >= 90% OR (T - dewPoint) <= 2°C.
    var isWetHour: Bool {
        if let measured = measuredLeafWetness { return measured }
        if precipitationMm > 0 { return true }
        if let h = humidityPercent, h >= 90 { return true }
        if let dp = dewPointC, (temperatureC - dp) <= 2 { return true }
        return false
    }

    /// Whether this hour's wetness comes from a measured sensor (true) or
    /// the humidity/dew-point proxy (false).
    var isWetnessMeasured: Bool { measuredLeafWetness != nil }
}

nonisolated struct HourlyForecast: Sendable, Hashable {
    let hours: [WeatherHour]
    let source: String
    /// `true` if any hour reports measured leaf wetness from an ag-weather
    /// provider. Currently always false — we use an estimated proxy.
    let hasMeasuredLeafWetness: Bool
}

/// Fetches hourly weather (temperature, dew point, RH, precipitation) used
/// for disease-risk modelling. Uses Open-Meteo today; structured so a future
/// ag-weather provider can supply measured leaf wetness.
@Observable
class WeatherHourlyService {
    var isLoading: Bool = false
    var errorMessage: String?
    var forecast: HourlyForecast?
    /// Configured forecast provider for the current vineyard
    /// (auto / openMeteo / willyWeather). Updated by
    /// `fetchWithDavisOverride` before the network call so UI can
    /// show the expected source even while loading.
    var resolvedProvider: ForecastProvider = .auto
    /// Provider that actually supplied the hourly data. Currently
    /// always Open-Meteo for hourly disease modelling — WillyWeather
    /// does not yet expose hourly through the proxy.
    var effectiveProvider: ForecastProvider = .openMeteo
    /// User-facing reason describing why the configured provider was
    /// not used for hourly data (e.g. WillyWeather hourly unavailable).
    var fallbackReason: String?

    func fetch(
        latitude: Double,
        longitude: Double,
        pastDays: Int = 2,
        forecastDays: Int = 3
    ) async {
        isLoading = true
        errorMessage = nil

        let past = max(0, min(pastDays, 5))
        let ahead = max(1, min(forecastDays, 7))
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&hourly=temperature_2m,dew_point_2m,relative_humidity_2m,precipitation&past_days=\(past)&forecast_days=\(ahead)&timezone=auto"

        guard let url = URL(string: urlString) else {
            errorMessage = "Invalid hourly forecast URL."
            isLoading = false
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                errorMessage = "Failed to fetch hourly forecast (HTTP \(code))."
                isLoading = false
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hourly = json["hourly"] as? [String: Any],
                  let times = hourly["time"] as? [String],
                  let temps = hourly["temperature_2m"] as? [Any] else {
                errorMessage = "Hourly forecast response could not be parsed."
                isLoading = false
                return
            }

            let dews = hourly["dew_point_2m"] as? [Any] ?? []
            let rhs = hourly["relative_humidity_2m"] as? [Any] ?? []
            let precs = hourly["precipitation"] as? [Any] ?? []

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate,
                                       .withColonSeparatorInTime]
            // Open-Meteo returns local "yyyy-MM-ddTHH:mm" without timezone
            let local = DateFormatter()
            local.dateFormat = "yyyy-MM-dd'T'HH:mm"
            local.timeZone = TimeZone.current
            local.locale = Locale(identifier: "en_US_POSIX")

            var hours: [WeatherHour] = []
            let count = min(times.count, temps.count)
            for i in 0..<count {
                let timeString = times[i]
                let date = local.date(from: timeString) ?? formatter.date(from: timeString)
                guard let date else { continue }
                guard let t = Self.parseDouble(temps[i]) else { continue }
                let dp = i < dews.count ? Self.parseDouble(dews[i]) : nil
                let rh = i < rhs.count ? Self.parseDouble(rhs[i]) : nil
                let p = i < precs.count ? (Self.parseDouble(precs[i]) ?? 0) : 0
                hours.append(WeatherHour(
                    date: date,
                    temperatureC: t,
                    dewPointC: dp,
                    humidityPercent: rh,
                    precipitationMm: p,
                    measuredLeafWetness: nil
                ))
            }

            forecast = HourlyForecast(
                hours: hours,
                source: "Open-Meteo",
                hasMeasuredLeafWetness: false
            )
        } catch {
            errorMessage = "Could not load hourly forecast: \(error.localizedDescription)"
        }

        isLoading = false
    }

    /// Fetches the forecast and, when Davis WeatherLink is configured for the
    /// vineyard with a leaf wetness sensor, overrides the most recent hours'
    /// wetness with the measured reading. Falls back silently to the proxy if
    /// Davis is not configured or the call fails.
    func fetchWithDavisOverride(
        latitude: Double,
        longitude: Double,
        pastDays: Int = 2,
        forecastDays: Int = 3,
        vineyardId: UUID?
    ) async {
        // Resolve the same forecast provider used by Dashboard /
        // Irrigation Advisor so Disease Risk respects the vineyard
        // setting. WillyWeather does not currently expose hourly data
        // through the proxy, so hourly disease modelling always uses
        // Open-Meteo. We surface this transparently via
        // `effectiveProvider` and `fallbackReason`.
        var resolved: ForecastProvider = .auto
        if let vid = vineyardId {
            let cfg = WeatherProviderStore.shared.config(for: vid)
            resolved = cfg.forecastProvider
            if let backend = try? await VineyardWillyWeatherProxyService
                .getProviderPreference(vineyardId: vid) {
                switch backend {
                case "auto": resolved = .auto
                case "open_meteo": resolved = .openMeteo
                case "willyweather": resolved = .willyWeather
                default: break
                }
            }
        }
        resolvedProvider = resolved
        effectiveProvider = .openMeteo
        switch resolved {
        case .willyWeather:
            fallbackReason = "WillyWeather hourly data is not available — using Open-Meteo for disease risk hourly inputs."
        case .auto, .openMeteo:
            fallbackReason = nil
        }

        await fetch(
            latitude: latitude,
            longitude: longitude,
            pastDays: pastDays,
            forecastDays: forecastDays
        )
        guard let vid = vineyardId else { return }
        await applyDavisMeasuredWetness(for: vid)
    }

    /// If Davis is the configured provider, has tested credentials, a
    /// selected station and a leaf wetness sensor, fetches current conditions
    /// and overrides `measuredLeafWetness` on hours within the last 2 hours.
    func applyDavisMeasuredWetness(for vineyardId: UUID) async {
        guard let forecast = self.forecast, !forecast.hours.isEmpty else { return }
        await VineyardWeatherIntegrationCache.shared.ensureLoaded(for: vineyardId)
        let cfg = WeatherProviderStore.shared.config(for: vineyardId)
        guard cfg.provider == .davis,
              cfg.davisHasLeafWetnessSensor,
              let stationId = cfg.davisStationId, !stationId.isEmpty else {
            return
        }

        // Prefer the vineyard-shared proxy when the integration is
        // configured for the vineyard (works for owner, manager AND
        // operators). Fall back to local Keychain credentials only if
        // the proxy isn't usable yet.
        let useProxy = cfg.davisIsVineyardShared
            && cfg.davisVineyardHasServerCredentials

        let current: DavisCurrentConditions
        do {
            if useProxy {
                current = try await VineyardDavisProxyService.fetchCurrentConditions(
                    vineyardId: vineyardId,
                    stationId: stationId
                )
            } else {
                guard cfg.davisHasCredentials,
                      cfg.davisConnectionTested,
                      let apiKey = WeatherKeychain.get(.apiKey),
                      let apiSecret = WeatherKeychain.get(.apiSecret) else {
                    return
                }
                current = try await DavisWeatherLinkService.fetchCurrentConditions(
                    apiKey: apiKey,
                    apiSecret: apiSecret,
                    stationId: stationId
                )
            }
        } catch {
            // Non-blocking: estimated wetness proxy continues to apply.
            return
        }

        guard let measured = current.measuredLeafWetness else { return }
        let now = Date()
        let earliest = now.addingTimeInterval(-2 * 3600)
        let latest = now.addingTimeInterval(60 * 60)
        let updated: [WeatherHour] = forecast.hours.map { h in
            guard h.date >= earliest, h.date <= latest else { return h }
            return WeatherHour(
                date: h.date,
                temperatureC: h.temperatureC,
                dewPointC: h.dewPointC,
                humidityPercent: h.humidityPercent,
                precipitationMm: h.precipitationMm,
                measuredLeafWetness: measured
            )
        }
        self.forecast = HourlyForecast(
            hours: updated,
            source: forecast.source + " + Davis WeatherLink",
            hasMeasuredLeafWetness: true
        )
    }

    private static func parseDouble(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
