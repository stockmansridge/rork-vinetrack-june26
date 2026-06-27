import Foundation
import Supabase

// MARK: - Models

/// Non-secret view of a vineyard weather integration. Returned by the
/// `get_vineyard_weather_integration` RPC. The api_key / api_secret values
/// are never exposed via this struct — only flags indicating whether they
/// are present, plus a `caller_role` hint so the UI can decide whether to
/// show owner/manager-only controls.
nonisolated struct VineyardWeatherIntegration: Codable, Sendable, Hashable {
    let id: UUID
    let vineyardId: UUID
    let provider: String
    let hasApiKey: Bool
    let hasApiSecret: Bool
    let stationId: String?
    let stationName: String?
    let stationLatitude: Double?
    let stationLongitude: Double?
    let hasLeafWetness: Bool
    let hasRain: Bool
    let hasWind: Bool
    let hasTemperatureHumidity: Bool
    let detectedSensors: [String]
    let configuredBy: UUID?
    let updatedAt: Date?
    let lastTestedAt: Date?
    let lastTestStatus: String?
    let isActive: Bool
    let callerRole: String?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case provider
        case hasApiKey = "has_api_key"
        case hasApiSecret = "has_api_secret"
        case stationId = "station_id"
        case stationName = "station_name"
        case stationLatitude = "station_latitude"
        case stationLongitude = "station_longitude"
        case hasLeafWetness = "has_leaf_wetness"
        case hasRain = "has_rain"
        case hasWind = "has_wind"
        case hasTemperatureHumidity = "has_temperature_humidity"
        case detectedSensors = "detected_sensors"
        case configuredBy = "configured_by"
        case updatedAt = "updated_at"
        case lastTestedAt = "last_tested_at"
        case lastTestStatus = "last_test_status"
        case isActive = "is_active"
        case callerRole = "caller_role"
    }

    var isFullyConfigured: Bool {
        hasApiKey && hasApiSecret && (stationId?.isEmpty == false)
    }
}

nonisolated struct VineyardWeatherIntegrationRevealed: Codable, Sendable, Hashable {
    let apiKey: String?
    let apiSecret: String?

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case apiSecret = "api_secret"
    }
}

// MARK: - Save payload

nonisolated struct VineyardWeatherIntegrationSave: Codable, Sendable {
    let p_vineyard_id: UUID
    let p_provider: String
    let p_api_key: String?
    let p_api_secret: String?
    let p_station_id: String?
    let p_station_name: String?
    let p_station_latitude: Double?
    let p_station_longitude: Double?
    let p_has_leaf_wetness: Bool?
    let p_has_rain: Bool?
    let p_has_wind: Bool?
    let p_has_temperature_humidity: Bool?
    let p_detected_sensors: [String]?
    let p_last_tested_at: Date?
    let p_last_test_status: String?
    let p_is_active: Bool?
}

nonisolated struct VineyardWeatherIntegrationLookup: Codable, Sendable {
    let p_vineyard_id: UUID
    let p_provider: String
}

// MARK: - Repository

protocol VineyardWeatherIntegrationRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, provider: String) async throws -> VineyardWeatherIntegration?
    func save(_ payload: VineyardWeatherIntegrationSave) async throws
    func delete(vineyardId: UUID, provider: String) async throws
    func revealCredentials(vineyardId: UUID, provider: String) async throws -> VineyardWeatherIntegrationRevealed
}

final class SupabaseVineyardWeatherIntegrationRepository:
    VineyardWeatherIntegrationRepositoryProtocol
{
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func fetch(vineyardId: UUID, provider providerName: String) async throws
        -> VineyardWeatherIntegration?
    {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        let rows: [VineyardWeatherIntegration] = try await provider.client
            .rpc(
                "get_vineyard_weather_integration",
                params: VineyardWeatherIntegrationLookup(
                    p_vineyard_id: vineyardId,
                    p_provider: providerName
                )
            )
            .execute()
            .value
        return rows.first
    }

    func save(_ payload: VineyardWeatherIntegrationSave) async throws {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        try await provider.client
            .rpc("save_vineyard_weather_integration", params: payload)
            .execute()
    }

    func delete(vineyardId: UUID, provider providerName: String) async throws {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        try await provider.client
            .rpc(
                "delete_vineyard_weather_integration",
                params: VineyardWeatherIntegrationLookup(
                    p_vineyard_id: vineyardId,
                    p_provider: providerName
                )
            )
            .execute()
    }

    func revealCredentials(vineyardId: UUID, provider providerName: String) async throws
        -> VineyardWeatherIntegrationRevealed
    {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        let rows: [VineyardWeatherIntegrationRevealed] = try await provider.client
            .rpc(
                "reveal_vineyard_weather_integration_credentials",
                params: VineyardWeatherIntegrationLookup(
                    p_vineyard_id: vineyardId,
                    p_provider: providerName
                )
            )
            .execute()
            .value
        return rows.first ?? VineyardWeatherIntegrationRevealed(apiKey: nil, apiSecret: nil)
    }
}
