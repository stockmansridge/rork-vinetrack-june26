import Foundation

protocol VineyardRepositoryProtocol: Sendable {
    func listMyVineyards() async throws -> [BackendVineyard]
    /// List every vineyard the current user can see, optionally including
    /// soft-deleted ones (RLS gates the result). Used by the admin trip audit.
    func listAllAccessibleVineyards(includeDeleted: Bool) async throws -> [BackendVineyard]
    func createVineyard(name: String, country: String?) async throws -> BackendVineyard
    func updateVineyard(_ vineyard: BackendVineyard) async throws
    func updateVineyardLogoPath(vineyardId: UUID, logoPath: String?) async throws -> Date?
    func softDeleteVineyard(id: UUID) async throws
    func archiveVineyard(id: UUID) async throws
    func accountDeletionPreflight() async throws -> AccountDeletionPreflight
    func submitAccountDeletionRequest(reason: String?) async throws -> AccountDeletionRequestResult

    /// Fetch the vineyard-scoped location (lat/long/elevation/timezone) from
    /// `public.vineyards` via `get_vineyard_location`. Returns nil if the
    /// caller is not a member (RPC throws) or the vineyard has no row.
    func getVineyardLocation(vineyardId: UUID) async throws -> BackendVineyardLocation?

    /// Owner/manager only. Writes all four location fields atomically.
    /// Passing `nil` for a field clears it server-side.
    @discardableResult
    func setVineyardLocation(
        vineyardId: UUID,
        latitude: Double?,
        longitude: Double?,
        elevationMetres: Double?,
        timezone: String?
    ) async throws -> BackendVineyardLocation

    /// Fetch the vineyard-scoped organisation region settings (country/units/
    /// date format/terminology + shared timezone) from `public.vineyards` via
    /// `get_vineyard_region_settings`. Returns nil if the caller is not a
    /// member (RPC throws) or the vineyard has no row. Any NULL field is left
    /// nil so the client can fall back to Australian defaults.
    func getVineyardRegionSettings(vineyardId: UUID) async throws -> BackendVineyardRegionSettings?

    /// Owner/manager only. Writes all region fields atomically.
    /// Passing `nil`/empty for a field clears it server-side.
    @discardableResult
    func setVineyardRegionSettings(
        _ settings: BackendVineyardRegionSettings
    ) async throws -> BackendVineyardRegionSettings
}

nonisolated struct BackendVineyardLocation: Decodable, Sendable {
    let vineyardId: UUID
    let latitude: Double?
    let longitude: Double?
    let elevationMetres: Double?
    let timezone: String?

    enum CodingKeys: String, CodingKey {
        case vineyardId = "vineyard_id"
        case latitude
        case longitude
        case elevationMetres = "elevation_metres"
        case timezone
    }
}

/// Server-side organisation region settings for a vineyard. Mirrors the nine
/// additive columns from sql/099 plus the shared `timezone` (sql/080). Every
/// field is optional because columns are nullable; nil means "use the local
/// Australian default".
nonisolated struct BackendVineyardRegionSettings: Codable, Sendable {
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
        case vineyardId = "vineyard_id"
        case countryCode = "country_code"
        case currencyCode = "currency_code"
        case timezone
        case areaUnit = "area_unit"
        case volumeUnit = "volume_unit"
        case distanceUnit = "distance_unit"
        case fuelUnit = "fuel_unit"
        case sprayRateAreaUnit = "spray_rate_area_unit"
        case dateFormat = "date_format"
        case terminologyRegion = "terminology_region"
    }

    /// True when the server has no region values at all — used to decide
    /// whether a one-time local→server backfill is warranted.
    var isAllNull: Bool {
        [countryCode, currencyCode, timezone, areaUnit, volumeUnit, distanceUnit,
         fuelUnit, sprayRateAreaUnit, dateFormat, terminologyRegion]
            .allSatisfy { ($0 ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

nonisolated struct AccountDeletionPreflight: Decodable, Sendable {
    let ownedVineyards: [OwnedVineyard]
    let blockerCount: Int
    let safeToDelete: Bool

    nonisolated struct OwnedVineyard: Decodable, Sendable, Identifiable {
        let vineyardId: UUID
        let vineyardName: String
        let otherActiveMembers: Int
        let transferRequired: Bool

        var id: UUID { vineyardId }

        enum CodingKeys: String, CodingKey {
            case vineyardId = "vineyard_id"
            case vineyardName = "vineyard_name"
            case otherActiveMembers = "other_active_members"
            case transferRequired = "transfer_required"
        }
    }

    enum CodingKeys: String, CodingKey {
        case ownedVineyards = "owned_vineyards"
        case blockerCount = "blocker_count"
        case safeToDelete = "safe_to_delete"
    }
}

nonisolated struct AccountDeletionRequestResult: Decodable, Sendable {
    let submitted: Bool
    let blockerCount: Int?
    let message: String?
    let requestId: UUID?

    enum CodingKeys: String, CodingKey {
        case submitted
        case blockerCount = "blocker_count"
        case message
        case requestId = "request_id"
    }
}
