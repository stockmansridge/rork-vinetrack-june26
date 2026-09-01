import Foundation

/// Row of `public.grape_purchasers` (sql/219) as returned by PostgREST.
/// Deliberately small — a winery contact book entry, never financial data.
nonisolated struct BackendGrapePurchaser: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let wineryName: String?
    let contactName: String?
    let contactEmail: String?
    let contactPhone: String?
    let contactAddress: String?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case wineryName = "winery_name"
        case contactName = "contact_name"
        case contactEmail = "contact_email"
        case contactPhone = "contact_phone"
        case contactAddress = "contact_address"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

/// Upsert payload for `public.grape_purchasers`. Nils are encoded explicitly
/// so an edit that clears a contact field also clears the server column.
nonisolated struct BackendGrapePurchaserUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let wineryName: String
    let contactName: String?
    let contactEmail: String?
    let contactPhone: String?
    let contactAddress: String?
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case wineryName = "winery_name"
        case contactName = "contact_name"
        case contactEmail = "contact_email"
        case contactPhone = "contact_phone"
        case contactAddress = "contact_address"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(vineyardId, forKey: .vineyardId)
        try c.encode(wineryName, forKey: .wineryName)
        try c.encode(contactName, forKey: .contactName)
        try c.encode(contactEmail, forKey: .contactEmail)
        try c.encode(contactPhone, forKey: .contactPhone)
        try c.encode(contactAddress, forKey: .contactAddress)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}

extension BackendGrapePurchaser {
    static func upsert(from purchaser: GrapePurchaser, createdBy: UUID?, clientUpdatedAt: Date) -> BackendGrapePurchaserUpsert {
        BackendGrapePurchaserUpsert(
            id: purchaser.id,
            vineyardId: purchaser.vineyardId,
            wineryName: purchaser.wineryName,
            contactName: purchaser.contactName,
            contactEmail: purchaser.contactEmail,
            contactPhone: purchaser.contactPhone,
            contactAddress: purchaser.contactAddress,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toGrapePurchaser() -> GrapePurchaser {
        GrapePurchaser(
            id: id,
            vineyardId: vineyardId,
            wineryName: wineryName ?? "",
            contactName: contactName,
            contactEmail: contactEmail,
            contactPhone: contactPhone,
            contactAddress: contactAddress,
            updatedAt: updatedAt
        )
    }
}
