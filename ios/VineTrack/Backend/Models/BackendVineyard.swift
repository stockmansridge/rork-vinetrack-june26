import Foundation

nonisolated struct BackendVineyard: Identifiable, Codable, Sendable {
    let id: UUID
    let name: String
    let ownerId: UUID?
    let country: String?
    let logoPath: String?
    let logoUpdatedAt: Date?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let latitude: Double?
    let longitude: Double?
    let elevationMetres: Double?
    let timezone: String?
    /// sql/191 `vineyards.spray_compliance_profile`. Nil when the grower never
    /// chose one, which is NOT the same as choosing Australia — see
    /// `SprayVineyardProfile`, where nil falls back to the country default
    /// without ever writing that fallback back to the database.
    let sprayComplianceProfile: String?
    /// sql/191 `vineyards.spray_carrier_volume_basis`. Nil when never chosen.
    let sprayCarrierVolumeBasis: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case ownerId = "owner_id"
        case country
        case logoPath = "logo_path"
        case logoUpdatedAt = "logo_updated_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case latitude
        case longitude
        case elevationMetres = "elevation_metres"
        case timezone
        case sprayComplianceProfile = "spray_compliance_profile"
        case sprayCarrierVolumeBasis = "spray_carrier_volume_basis"
    }

    nonisolated init(
        id: UUID,
        name: String,
        ownerId: UUID?,
        country: String?,
        logoPath: String?,
        logoUpdatedAt: Date? = nil,
        createdAt: Date?,
        updatedAt: Date?,
        deletedAt: Date?,
        latitude: Double? = nil,
        longitude: Double? = nil,
        elevationMetres: Double? = nil,
        timezone: String? = nil,
        sprayComplianceProfile: String? = nil,
        sprayCarrierVolumeBasis: String? = nil
    ) {
        self.id = id
        self.name = name
        self.ownerId = ownerId
        self.country = country
        self.logoPath = logoPath
        self.logoUpdatedAt = logoUpdatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.latitude = latitude
        self.longitude = longitude
        self.elevationMetres = elevationMetres
        self.timezone = timezone
        self.sprayComplianceProfile = sprayComplianceProfile
        self.sprayCarrierVolumeBasis = sprayCarrierVolumeBasis
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        ownerId = try c.decodeIfPresent(UUID.self, forKey: .ownerId)
        country = try c.decodeIfPresent(String.self, forKey: .country)
        logoPath = try c.decodeIfPresent(String.self, forKey: .logoPath)
        logoUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .logoUpdatedAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        elevationMetres = try c.decodeIfPresent(Double.self, forKey: .elevationMetres)
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone)
        sprayComplianceProfile = try c.decodeIfPresent(String.self, forKey: .sprayComplianceProfile)
        sprayCarrierVolumeBasis = try c.decodeIfPresent(String.self, forKey: .sprayCarrierVolumeBasis)
    }

    /// The vineyard's spray profile as stored, ready for the guided flow.
    ///
    /// Resolution order lives entirely in `SprayVineyardProfile`:
    /// stored value → country-derived compatibility fallback → safe default.
    /// Nothing here writes a resolved fallback back to the database.
    var sprayProfile: SprayVineyardProfile {
        SprayVineyardProfile(
            storedProfile: SprayComplianceProfile(rawValue: sprayComplianceProfile ?? ""),
            storedPolicy: SprayCarrierVolumePolicy(rawValue: sprayCarrierVolumeBasis ?? ""),
            countryCode: country
        )
    }
}
