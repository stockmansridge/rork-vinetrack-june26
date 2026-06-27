import Foundation
import Supabase

final class SupabaseVineyardRepository: VineyardRepositoryProtocol {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func listMyVineyards() async throws -> [BackendVineyard] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .from("vineyards")
            .select()
            .is("deleted_at", value: nil)
            .order("name", ascending: true)
            .execute()
            .value
    }

    func listAllAccessibleVineyards(includeDeleted: Bool) async throws -> [BackendVineyard] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        if includeDeleted {
            return try await provider.client
                .from("vineyards")
                .select()
                .order("name", ascending: true)
                .execute()
                .value
        } else {
            return try await listMyVineyards()
        }
    }

    func createVineyard(name: String, country: String?) async throws -> BackendVineyard {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard provider.client.auth.currentUser != nil else { throw BackendRepositoryError.missingAuthenticatedUser }
        let vineyards: [BackendVineyard] = try await provider.client
            .rpc("create_vineyard_with_owner", params: CreateVineyardRequest(name: name, country: country))
            .execute()
            .value
        guard let vineyard = vineyards.first else { throw BackendRepositoryError.emptyResponse }
        return vineyard
    }

    /// Updates the vineyard's name and country only. Logo path is intentionally
    /// not touched here — use `updateVineyardLogoPath` for that, otherwise
    /// renaming a vineyard would wipe its synced logo.
    func updateVineyard(_ vineyard: BackendVineyard) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .from("vineyards")
            .update(VineyardUpdate(name: vineyard.name, country: vineyard.country))
            .eq("id", value: vineyard.id.uuidString)
            .execute()
    }

    /// Sets or clears the vineyard's `logo_path` and bumps `logo_updated_at`
    /// so other devices know to refetch the logo. Returns the new
    /// `logo_updated_at` value as reported by the database.
    @discardableResult
    func updateVineyardLogoPath(vineyardId: UUID, logoPath: String?) async throws -> Date? {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let now = Date()
        let response: [VineyardLogoUpdateResponse] = try await provider.client
            .from("vineyards")
            .update(VineyardLogoUpdate(logoPath: logoPath, logoUpdatedAt: now))
            .eq("id", value: vineyardId.uuidString)
            .select("logo_updated_at")
            .execute()
            .value
        return response.first?.logoUpdatedAt ?? now
    }

    func softDeleteVineyard(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .from("vineyards")
            .update(VineyardSoftDelete(deletedAt: Date()))
            .eq("id", value: id.uuidString)
            .execute()
    }

    func archiveVineyard(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .rpc("archive_vineyard", params: ArchiveVineyardRequest(vineyardId: id))
            .execute()
    }

    func accountDeletionPreflight() async throws -> AccountDeletionPreflight {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let result: AccountDeletionPreflight = try await provider.client
            .rpc("account_deletion_preflight")
            .execute()
            .value
        return result
    }

    func submitAccountDeletionRequest(reason: String?) async throws -> AccountDeletionRequestResult {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let result: AccountDeletionRequestResult = try await provider.client
            .rpc("submit_account_deletion_request", params: SubmitDeletionRequest(reason: reason))
            .execute()
            .value
        return result
    }

    func getVineyardLocation(vineyardId: UUID) async throws -> BackendVineyardLocation? {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [BackendVineyardLocation] = try await provider.client
            .rpc("get_vineyard_location", params: GetVineyardLocationRequest(vineyardId: vineyardId))
            .execute()
            .value
        return rows.first
    }

    @discardableResult
    func setVineyardLocation(
        vineyardId: UUID,
        latitude: Double?,
        longitude: Double?,
        elevationMetres: Double?,
        timezone: String?
    ) async throws -> BackendVineyardLocation {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let params = SetVineyardLocationRequest(
            vineyardId: vineyardId,
            latitude: latitude,
            longitude: longitude,
            elevationMetres: elevationMetres,
            timezone: timezone
        )
        let rows: [BackendVineyardLocation] = try await provider.client
            .rpc("set_vineyard_location", params: params)
            .execute()
            .value
        guard let row = rows.first else { throw BackendRepositoryError.emptyResponse }
        return row
    }

    func getVineyardRegionSettings(vineyardId: UUID) async throws -> BackendVineyardRegionSettings? {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [BackendVineyardRegionSettings] = try await provider.client
            .rpc("get_vineyard_region_settings", params: GetVineyardRegionSettingsRequest(vineyardId: vineyardId))
            .execute()
            .value
        return rows.first
    }

    @discardableResult
    func setVineyardRegionSettings(
        _ settings: BackendVineyardRegionSettings
    ) async throws -> BackendVineyardRegionSettings {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let params = SetVineyardRegionSettingsRequest(
            vineyardId: settings.vineyardId,
            countryCode: settings.countryCode,
            currencyCode: settings.currencyCode,
            timezone: settings.timezone,
            areaUnit: settings.areaUnit,
            volumeUnit: settings.volumeUnit,
            distanceUnit: settings.distanceUnit,
            fuelUnit: settings.fuelUnit,
            sprayRateAreaUnit: settings.sprayRateAreaUnit,
            dateFormat: settings.dateFormat,
            terminologyRegion: settings.terminologyRegion
        )
        let rows: [BackendVineyardRegionSettings] = try await provider.client
            .rpc("set_vineyard_region_settings", params: params)
            .execute()
            .value
        guard let row = rows.first else { throw BackendRepositoryError.emptyResponse }
        return row
    }
}

nonisolated private struct GetVineyardLocationRequest: Encodable, Sendable {
    let vineyardId: UUID

    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
    }
}

/// Custom `encode(to:)` so `nil` values are sent as JSON `null` rather than
/// being omitted (PostgREST overload resolution needs all named params to
/// be present — see grape variety `p_variety_key` regression).
nonisolated private struct SetVineyardLocationRequest: Encodable, Sendable {
    let vineyardId: UUID
    let latitude: Double?
    let longitude: Double?
    let elevationMetres: Double?
    let timezone: String?

    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case latitude = "p_latitude"
        case longitude = "p_longitude"
        case elevationMetres = "p_elevation_metres"
        case timezone = "p_timezone"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vineyardId, forKey: .vineyardId)
        try c.encode(latitude, forKey: .latitude)
        try c.encode(longitude, forKey: .longitude)
        try c.encode(elevationMetres, forKey: .elevationMetres)
        try c.encode(timezone, forKey: .timezone)
    }
}

nonisolated private struct GetVineyardRegionSettingsRequest: Encodable, Sendable {
    let vineyardId: UUID

    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
    }
}

/// Custom `encode(to:)` so `nil` values are sent as JSON `null` rather than
/// being omitted (PostgREST overload resolution needs every named param
/// present — same reason as `SetVineyardLocationRequest`).
nonisolated private struct SetVineyardRegionSettingsRequest: Encodable, Sendable {
    let vineyardId: UUID
    let countryCode: String?
    let currencyCode: String?
    let timezone: String?
    let areaUnit: String?
    let volumeUnit: String?
    let distanceUnit: String?
    let fuelUnit: String?
    let sprayRateAreaUnit: String?
    let dateFormat: String?
    let terminologyRegion: String?

    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case countryCode = "p_country_code"
        case currencyCode = "p_currency_code"
        case timezone = "p_timezone"
        case areaUnit = "p_area_unit"
        case volumeUnit = "p_volume_unit"
        case distanceUnit = "p_distance_unit"
        case fuelUnit = "p_fuel_unit"
        case sprayRateAreaUnit = "p_spray_rate_area_unit"
        case dateFormat = "p_date_format"
        case terminologyRegion = "p_terminology_region"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vineyardId, forKey: .vineyardId)
        try c.encode(countryCode, forKey: .countryCode)
        try c.encode(currencyCode, forKey: .currencyCode)
        try c.encode(timezone, forKey: .timezone)
        try c.encode(areaUnit, forKey: .areaUnit)
        try c.encode(volumeUnit, forKey: .volumeUnit)
        try c.encode(distanceUnit, forKey: .distanceUnit)
        try c.encode(fuelUnit, forKey: .fuelUnit)
        try c.encode(sprayRateAreaUnit, forKey: .sprayRateAreaUnit)
        try c.encode(dateFormat, forKey: .dateFormat)
        try c.encode(terminologyRegion, forKey: .terminologyRegion)
    }
}

nonisolated private struct ArchiveVineyardRequest: Encodable, Sendable {
    let vineyardId: UUID

    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
    }
}

nonisolated private struct SubmitDeletionRequest: Encodable, Sendable {
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case reason = "p_reason"
    }
}

nonisolated private struct CreateVineyardRequest: Encodable, Sendable {
    let name: String
    let country: String?

    enum CodingKeys: String, CodingKey {
        case name = "p_name"
        case country = "p_country"
    }
}

nonisolated private struct VineyardUpdate: Encodable, Sendable {
    let name: String
    let country: String?
}

nonisolated private struct VineyardLogoUpdate: Encodable, Sendable {
    let logoPath: String?
    let logoUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case logoPath = "logo_path"
        case logoUpdatedAt = "logo_updated_at"
    }
}

nonisolated private struct VineyardLogoUpdateResponse: Decodable, Sendable {
    let logoUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case logoUpdatedAt = "logo_updated_at"
    }
}

nonisolated private struct VineyardSoftDelete: Encodable, Sendable {
    let deletedAt: Date

    enum CodingKeys: String, CodingKey {
        case deletedAt = "deleted_at"
    }
}
