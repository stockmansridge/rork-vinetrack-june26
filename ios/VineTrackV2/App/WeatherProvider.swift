import Foundation

/// Legacy single-provider enum. Retained for compatibility with existing
/// call sites and code that maps to the *local observation* role.
nonisolated enum WeatherProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic
    case wunderground
    case davis

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic Forecast"
        case .wunderground: return "Weather Underground PWS"
        case .davis: return "Davis WeatherLink"
        }
    }

    var shortName: String {
        switch self {
        case .automatic: return "Automatic Forecast"
        case .wunderground: return "Weather Underground"
        case .davis: return "Davis WeatherLink"
        }
    }

    var symbol: String {
        switch self {
        case .automatic: return "cloud.sun.fill"
        case .wunderground: return "antenna.radiowaves.left.and.right"
        case .davis: return "sensor.tag.radiowaves.forward.fill"
        }
    }

    var helpCopy: String {
        switch self {
        case .automatic:
            return "No setup required. Uses forecast weather based on vineyard location."
        case .wunderground:
            return "Uses your selected nearby PWS for current/local observations where available."
        case .davis:
            return "Connect your Davis WeatherLink account to use your own station data. If leaf wetness sensors are available, disease risk can use measured wetness instead of estimated wetness."
        }
    }
}

// MARK: - Role-aware providers

/// Forecast data provider — used for forecast rainfall, ET forecast,
/// future temperature/wind, disease forecast risk and irrigation forecast.
nonisolated enum ForecastProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Use WillyWeather when configured, otherwise fall back to Open-Meteo.
    case auto
    case openMeteo
    case willyWeather

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .openMeteo: return "Open-Meteo Forecast"
        case .willyWeather: return "WillyWeather"
        }
    }
    var shortName: String {
        switch self {
        case .auto: return "Auto"
        case .openMeteo: return "Open-Meteo"
        case .willyWeather: return "WillyWeather"
        }
    }
    var symbol: String {
        switch self {
        case .auto: return "sparkles"
        case .openMeteo: return "cloud.sun.fill"
        case .willyWeather: return "sun.rain.fill"
        }
    }
    var helpCopy: String {
        switch self {
        case .auto:
            return "Use WillyWeather when configured, otherwise fall back to Open-Meteo."
        case .openMeteo:
            return "Free global forecast service. Used for future rainfall, ET, temperature, wind and irrigation forecast calculations."
        case .willyWeather:
            return "Australian-focused forecast service backed by the Bureau of Meteorology. Requires a WillyWeather API key."
        }
    }
}

/// Local station observation provider — used for actual recent rainfall,
/// current local conditions, measured leaf wetness and Rainfall Calendar
/// recent history.
nonisolated enum LocalObservationProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    case davis
    case wunderground

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return "None / Automatic"
        case .davis: return "Davis WeatherLink"
        case .wunderground: return "Weather Underground PWS"
        }
    }
    var symbol: String {
        switch self {
        case .none: return "cloud.sun.fill"
        case .davis: return "sensor.tag.radiowaves.forward.fill"
        case .wunderground: return "antenna.radiowaves.left.and.right"
        }
    }
    var helpCopy: String {
        switch self {
        case .none:
            return "No local station. Actual rainfall and current conditions fall back to the historical archive."
        case .davis:
            return "Connect your Davis WeatherLink account to use your own station data. If a leaf wetness sensor is available, disease risk uses measured wetness."
        case .wunderground:
            return "Use a nearby Weather Underground PWS for current/local observations and recent rainfall."
        }
    }
}

/// Historical fallback provider — used when local station history is
/// unavailable or outside the supported live-history window.
nonisolated enum HistoricalFallbackProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case openMeteoArchive

    var id: String { rawValue }
    var displayName: String {
        switch self { case .openMeteoArchive: return "Open-Meteo Archive" }
    }
    var symbol: String { "tray.full.fill" }
    var helpCopy: String {
        "Used when local station history is unavailable or outside the supported live-history window."
    }
}

/// Per-vineyard provider configuration, persisted via UserDefaults
/// (non-secret fields only). Davis credentials live in the Keychain.
nonisolated struct WeatherProviderConfig: Codable, Sendable, Equatable {
    // Role-aware selections.
    var forecastProvider: ForecastProvider = .auto

    // WillyWeather-specific state (only meaningful when willyWeather is
    // configured for this vineyard). The API key never lives on-device;
    // it is stored server-side in vineyard_weather_integrations and the
    // willyweather-proxy edge function reads it via service-role.
    var willyWeatherHasApiKey: Bool = false
    var willyWeatherLocationId: String? = nil
    var willyWeatherLocationName: String? = nil
    var willyWeatherLastTestSuccess: Date? = nil
    var willyWeatherLastTestError: String? = nil
    var localObservationProvider: LocalObservationProvider = .none
    var historicalFallbackProvider: HistoricalFallbackProvider = .openMeteoArchive

    // Davis-specific state (only meaningful when localObservationProvider == .davis)
    var davisStationId: String? = nil
    var davisStationName: String? = nil
    var davisHasCredentials: Bool = false
    var davisLastTestSuccess: Date? = nil
    var davisLastTestError: String? = nil
    var davisDetectedSensors: [String] = []
    var davisHasLeafWetnessSensor: Bool = false
    var davisConnectionTested: Bool = false
    var davisAvailableStations: [DavisStation] = []
    var lastSuccessfulUpdate: Date? = nil

    // Vineyard-shared metadata (populated from
    // `vineyard_weather_integrations` via the role-aware RPC). When true,
    // station + sensor info is the shared source of truth for every member
    // of this vineyard. Credentials are still required on the owner /
    // manager device(s) that perform live fetches.
    var davisIsVineyardShared: Bool = false
    var davisVineyardHasServerCredentials: Bool = false
    var davisVineyardConfiguredBy: UUID? = nil
    var davisVineyardUpdatedAt: Date? = nil

    static let `default` = WeatherProviderConfig()

    /// Compatibility shim: map between the legacy single-provider field
    /// and the new local-observation role.
    var provider: WeatherProvider {
        get {
            switch localObservationProvider {
            case .none: return .automatic
            case .davis: return .davis
            case .wunderground: return .wunderground
            }
        }
        set {
            switch newValue {
            case .automatic: localObservationProvider = .none
            case .davis: localObservationProvider = .davis
            case .wunderground: localObservationProvider = .wunderground
            }
        }
    }

    // MARK: Codable (with legacy migration)

    private enum CodingKeys: String, CodingKey {
        case forecastProvider
        case localObservationProvider
        case historicalFallbackProvider
        case provider // legacy
        case davisStationId
        case davisStationName
        case davisHasCredentials
        case davisLastTestSuccess
        case davisLastTestError
        case davisDetectedSensors
        case davisHasLeafWetnessSensor
        case davisConnectionTested
        case davisAvailableStations
        case lastSuccessfulUpdate
        case davisIsVineyardShared
        case davisVineyardHasServerCredentials
        case davisVineyardConfiguredBy
        case davisVineyardUpdatedAt
        case willyWeatherHasApiKey
        case willyWeatherLocationId
        case willyWeatherLocationName
        case willyWeatherLastTestSuccess
        case willyWeatherLastTestError
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        self.forecastProvider = (try? c.decode(ForecastProvider.self, forKey: .forecastProvider)) ?? .auto
        self.willyWeatherHasApiKey = (try? c.decode(Bool.self, forKey: .willyWeatherHasApiKey)) ?? false
        self.willyWeatherLocationId = try? c.decodeIfPresent(String.self, forKey: .willyWeatherLocationId)
        self.willyWeatherLocationName = try? c.decodeIfPresent(String.self, forKey: .willyWeatherLocationName)
        self.willyWeatherLastTestSuccess = try? c.decodeIfPresent(Date.self, forKey: .willyWeatherLastTestSuccess)
        self.willyWeatherLastTestError = try? c.decodeIfPresent(String.self, forKey: .willyWeatherLastTestError)
        self.historicalFallbackProvider = (try? c.decode(HistoricalFallbackProvider.self, forKey: .historicalFallbackProvider)) ?? .openMeteoArchive

        if let local = try? c.decode(LocalObservationProvider.self, forKey: .localObservationProvider) {
            self.localObservationProvider = local
        } else if let legacy = try? c.decode(WeatherProvider.self, forKey: .provider) {
            // Migrate from old single-provider field.
            switch legacy {
            case .automatic: self.localObservationProvider = .none
            case .davis: self.localObservationProvider = .davis
            case .wunderground: self.localObservationProvider = .wunderground
            }
        } else {
            self.localObservationProvider = .none
        }

        self.davisStationId = try? c.decodeIfPresent(String.self, forKey: .davisStationId)
        self.davisStationName = try? c.decodeIfPresent(String.self, forKey: .davisStationName)
        self.davisHasCredentials = (try? c.decode(Bool.self, forKey: .davisHasCredentials)) ?? false
        self.davisLastTestSuccess = try? c.decodeIfPresent(Date.self, forKey: .davisLastTestSuccess)
        self.davisLastTestError = try? c.decodeIfPresent(String.self, forKey: .davisLastTestError)
        self.davisDetectedSensors = (try? c.decode([String].self, forKey: .davisDetectedSensors)) ?? []
        self.davisHasLeafWetnessSensor = (try? c.decode(Bool.self, forKey: .davisHasLeafWetnessSensor)) ?? false
        self.davisConnectionTested = (try? c.decode(Bool.self, forKey: .davisConnectionTested)) ?? false
        self.davisAvailableStations = (try? c.decode([DavisStation].self, forKey: .davisAvailableStations)) ?? []
        self.lastSuccessfulUpdate = try? c.decodeIfPresent(Date.self, forKey: .lastSuccessfulUpdate)
        self.davisIsVineyardShared = (try? c.decode(Bool.self, forKey: .davisIsVineyardShared)) ?? false
        self.davisVineyardHasServerCredentials = (try? c.decode(Bool.self, forKey: .davisVineyardHasServerCredentials)) ?? false
        self.davisVineyardConfiguredBy = try? c.decodeIfPresent(UUID.self, forKey: .davisVineyardConfiguredBy)
        self.davisVineyardUpdatedAt = try? c.decodeIfPresent(Date.self, forKey: .davisVineyardUpdatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(forecastProvider, forKey: .forecastProvider)
        try c.encode(localObservationProvider, forKey: .localObservationProvider)
        try c.encode(historicalFallbackProvider, forKey: .historicalFallbackProvider)
        // Also write the legacy `provider` key so older app builds still
        // read the right local-observation source after a downgrade.
        try c.encode(provider, forKey: .provider)

        try c.encodeIfPresent(davisStationId, forKey: .davisStationId)
        try c.encodeIfPresent(davisStationName, forKey: .davisStationName)
        try c.encode(davisHasCredentials, forKey: .davisHasCredentials)
        try c.encodeIfPresent(davisLastTestSuccess, forKey: .davisLastTestSuccess)
        try c.encodeIfPresent(davisLastTestError, forKey: .davisLastTestError)
        try c.encode(davisDetectedSensors, forKey: .davisDetectedSensors)
        try c.encode(davisHasLeafWetnessSensor, forKey: .davisHasLeafWetnessSensor)
        try c.encode(davisConnectionTested, forKey: .davisConnectionTested)
        try c.encode(davisAvailableStations, forKey: .davisAvailableStations)
        try c.encodeIfPresent(lastSuccessfulUpdate, forKey: .lastSuccessfulUpdate)
        try c.encode(davisIsVineyardShared, forKey: .davisIsVineyardShared)
        try c.encode(davisVineyardHasServerCredentials, forKey: .davisVineyardHasServerCredentials)
        try c.encodeIfPresent(davisVineyardConfiguredBy, forKey: .davisVineyardConfiguredBy)
        try c.encodeIfPresent(davisVineyardUpdatedAt, forKey: .davisVineyardUpdatedAt)
        try c.encode(willyWeatherHasApiKey, forKey: .willyWeatherHasApiKey)
        try c.encodeIfPresent(willyWeatherLocationId, forKey: .willyWeatherLocationId)
        try c.encodeIfPresent(willyWeatherLocationName, forKey: .willyWeatherLocationName)
        try c.encodeIfPresent(willyWeatherLastTestSuccess, forKey: .willyWeatherLastTestSuccess)
        try c.encodeIfPresent(willyWeatherLastTestError, forKey: .willyWeatherLastTestError)
    }
}

@MainActor
final class WeatherProviderStore {
    static let shared = WeatherProviderStore()

    private let defaults = UserDefaults.standard

    private func key(for vineyardId: UUID) -> String {
        "VineTrack.WeatherProviderConfig.\(vineyardId.uuidString)"
    }

    func config(for vineyardId: UUID) -> WeatherProviderConfig {
        guard let data = defaults.data(forKey: key(for: vineyardId)),
              let cfg = try? JSONDecoder().decode(WeatherProviderConfig.self, from: data)
        else {
            return .default
        }
        return cfg
    }

    func save(_ config: WeatherProviderConfig, for vineyardId: UUID) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: key(for: vineyardId))
    }
}
