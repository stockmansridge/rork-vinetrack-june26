import Foundation

/// Computed view of the active weather data source for UI labels.
nonisolated struct WeatherSourceStatus: Sendable, Equatable {
    enum Quality: String, Sendable, Equatable {
        case forecastOnly
        case localStation
        case localStationWithMeasuredWetness

        var displayName: String {
            switch self {
            case .forecastOnly: return "Forecast only"
            case .localStation: return "Local station"
            case .localStationWithMeasuredWetness: return "Local station + measured wetness"
            }
        }
    }

    let provider: WeatherProvider
    let quality: Quality
    let primaryLabel: String
    let detailLabel: String
    let lastUpdated: Date?

    /// One-line label for use in advisor / spray screens.
    var compactLabel: String {
        switch provider {
        case .automatic:
            return "Source: Automatic Forecast"
        case .wunderground:
            return "Source: Weather Underground PWS — \(detailLabel)"
        case .davis:
            switch quality {
            case .localStationWithMeasuredWetness:
                return "Source: Davis WeatherLink — \(detailLabel) (measured wetness)"
            case .localStation:
                return "Source: Davis WeatherLink — \(detailLabel)"
            case .forecastOnly:
                return "Source: Automatic Forecast fallback"
            }
        }
    }
}

@MainActor
enum WeatherProviderResolver {

    /// Resolves the effective provider from the saved config.
    /// Falls back to `.automatic` if a configured provider lacks required setup.
    static func resolve(for vineyardId: UUID, weatherStationId: String?) -> WeatherSourceStatus {
        let cfg = WeatherProviderStore.shared.config(for: vineyardId)

        // A vineyard-shared Davis integration counts as a working local
        // source for every member, even on devices that don't hold the
        // credentials locally — fetches go through the server-side proxy.
        let hasShared = cfg.davisIsVineyardShared
            && cfg.davisVineyardHasServerCredentials
            && (cfg.davisStationId?.isEmpty == false)

        switch cfg.provider {
        case .davis:
            // Only count as a working local source when the user actually
            // tested the connection AND we picked a station back, OR the
            // vineyard has a shared, fully-configured Davis integration.
            if (hasShared) ||
               (cfg.davisHasCredentials
                && cfg.davisConnectionTested
                && (cfg.davisStationId?.isEmpty == false)),
               let stationId = cfg.davisStationId,
               !stationId.isEmpty {
                let quality: WeatherSourceStatus.Quality =
                    cfg.davisHasLeafWetnessSensor ? .localStationWithMeasuredWetness : .localStation
                let detail = cfg.davisStationName?.isEmpty == false
                    ? cfg.davisStationName!
                    : stationId
                return WeatherSourceStatus(
                    provider: .davis,
                    quality: quality,
                    primaryLabel: "Davis WeatherLink",
                    detailLabel: detail,
                    lastUpdated: cfg.lastSuccessfulUpdate
                )
            }
            // Davis selected but not yet usable — surface a Davis-flavoured
            // fallback status so the UI can explain the situation.
            let detail: String
            if cfg.davisHasCredentials,
               cfg.davisConnectionTested,
               (cfg.davisStationId ?? "").isEmpty {
                detail = "Connected — select a station"
            } else if cfg.davisHasCredentials {
                detail = "Credentials saved — run Test Connection"
            } else {
                detail = "Not configured — using Automatic Forecast fallback"
            }
            return WeatherSourceStatus(
                provider: .davis,
                quality: .forecastOnly,
                primaryLabel: "Davis WeatherLink",
                detailLabel: detail,
                lastUpdated: cfg.lastSuccessfulUpdate
            )

        case .wunderground:
            if let station = weatherStationId, !station.isEmpty {
                return WeatherSourceStatus(
                    provider: .wunderground,
                    quality: .localStation,
                    primaryLabel: "Weather Underground",
                    detailLabel: station,
                    lastUpdated: cfg.lastSuccessfulUpdate
                )
            }
            return automatic(lastUpdated: cfg.lastSuccessfulUpdate)

        case .automatic:
            return automatic(lastUpdated: cfg.lastSuccessfulUpdate)
        }
    }

    private static func automatic(lastUpdated: Date?) -> WeatherSourceStatus {
        WeatherSourceStatus(
            provider: .automatic,
            quality: .forecastOnly,
            primaryLabel: "Automatic Forecast",
            detailLabel: "Based on vineyard location",
            lastUpdated: lastUpdated
        )
    }
}
