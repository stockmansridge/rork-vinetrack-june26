import Foundation

/// One entry in a vineyard's reusable spray target library
/// (sql/204 `vineyard_spray_targets`).
///
/// Vineyard-shared, never device- or user-specific: a target added on iOS is
/// offered on Android and in the Admin Portal for the SAME vineyard, and for no
/// other vineyard. Built-in `SprayTarget` values are compiled into the apps and
/// never appear here.
nonisolated struct VineyardSprayTargetRecord: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let vineyardId: UUID
    /// The stable slug written into `spray_jobs.targets` / `spray_records.targets`.
    let identifier: String
    /// The wording the vineyard chose, verbatim.
    let label: String
    let isActive: Bool
    let createdBy: UUID?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case identifier
        case label
        case isActive = "is_active"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: UUID,
        vineyardId: UUID,
        identifier: String,
        label: String,
        isActive: Bool = true,
        createdBy: UUID? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.identifier = identifier
        self.label = label
        self.isActive = isActive
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var tag: SprayTargetTag {
        SprayTargetTag(identifier: identifier, label: label)
    }
}

/// Arguments for `create_vineyard_spray_target`.
///
/// The client-generated id makes an offline replay idempotent; a duplicate
/// active identifier converges on the existing shared entry server-side, so two
/// operators adding "Eutypa Dieback" end up with one library entry rather than
/// one save winning and the other erroring.
nonisolated struct VineyardSprayTargetCreateParams: Codable, Sendable, Equatable {
    let id: UUID
    let vineyardId: UUID
    let identifier: String
    let label: String

    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case vineyardId = "p_vineyard_id"
        case identifier = "p_identifier"
        case label = "p_label"
    }
}
