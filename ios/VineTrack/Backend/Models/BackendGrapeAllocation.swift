import Foundation

/// Full row of `public.grape_allocations` (sql/217) as returned by PostgREST.
/// `price_per_tonne` never rests on this row — it lives in the owner/manager
/// companion table and is merged via `get_grape_allocation_financials`.
nonisolated struct BackendGrapeAllocation: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let vintage: Int?
    let allocationType: String?
    let varietyId: UUID?
    let varietyKey: String?
    let varietyName: String?
    let destinationName: String?
    let quantityTonnes: Double?
    let notes: String?
    let purchaserName: String?
    let contactName: String?
    let contactEmail: String?
    let contactPhone: String?
    let contactAddress: String?
    let createdBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case vintage
        case allocationType = "allocation_type"
        case varietyId = "variety_id"
        case varietyKey = "variety_key"
        case varietyName = "variety_name"
        case destinationName = "destination_name"
        case quantityTonnes = "quantity_tonnes"
        case notes
        case purchaserName = "purchaser_name"
        case contactName = "contact_name"
        case contactEmail = "contact_email"
        case contactPhone = "contact_phone"
        case contactAddress = "contact_address"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }
}

/// Upsert payload for `public.grape_allocations`.
///
/// `price_per_tonne` IS included: the sql/217 BEFORE trigger routes it into
/// the financial companion (owner/manager writers only) and always nulls the
/// base column, so lower-role writes can neither set nor wipe a price.
nonisolated struct BackendGrapeAllocationUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let vintage: Int
    let allocationType: String
    let varietyId: UUID?
    let varietyKey: String?
    let varietyName: String
    let destinationName: String?
    let quantityTonnes: Double
    let notes: String?
    let purchaserName: String?
    let contactName: String?
    let contactEmail: String?
    let contactPhone: String?
    let contactAddress: String?
    let pricePerTonne: Double?
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case vintage
        case allocationType = "allocation_type"
        case varietyId = "variety_id"
        case varietyKey = "variety_key"
        case varietyName = "variety_name"
        case destinationName = "destination_name"
        case quantityTonnes = "quantity_tonnes"
        case notes
        case purchaserName = "purchaser_name"
        case contactName = "contact_name"
        case contactEmail = "contact_email"
        case contactPhone = "contact_phone"
        case contactAddress = "contact_address"
        case pricePerTonne = "price_per_tonne"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(vineyardId, forKey: .vineyardId)
        try c.encode(vintage, forKey: .vintage)
        try c.encode(allocationType, forKey: .allocationType)
        // Encode nils explicitly so an edit that clears a field also clears
        // the server column on upsert.
        try c.encode(varietyId, forKey: .varietyId)
        try c.encode(varietyKey, forKey: .varietyKey)
        try c.encode(varietyName, forKey: .varietyName)
        try c.encode(destinationName, forKey: .destinationName)
        try c.encode(quantityTonnes, forKey: .quantityTonnes)
        try c.encode(notes, forKey: .notes)
        try c.encode(purchaserName, forKey: .purchaserName)
        try c.encode(contactName, forKey: .contactName)
        try c.encode(contactEmail, forKey: .contactEmail)
        try c.encode(contactPhone, forKey: .contactPhone)
        try c.encode(contactAddress, forKey: .contactAddress)
        try c.encode(pricePerTonne, forKey: .pricePerTonne)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}

/// Row of `public.grape_allocation_blocks` (sql/217).
nonisolated struct BackendGrapeAllocationBlock: Codable, Sendable, Identifiable {
    let id: UUID
    let allocationId: UUID
    let vineyardId: UUID
    let paddockId: UUID
    let paddockName: String?
    let quantityTonnes: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case allocationId = "allocation_id"
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case paddockName = "paddock_name"
        case quantityTonnes = "quantity_tonnes"
    }
}

/// Insert payload for `public.grape_allocation_blocks` (detail rows are
/// replaced wholesale on edit).
nonisolated struct BackendGrapeAllocationBlockInsert: Encodable, Sendable {
    let id: UUID
    let allocationId: UUID
    let vineyardId: UUID
    let paddockId: UUID
    let paddockName: String
    let quantityTonnes: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case allocationId = "allocation_id"
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case paddockName = "paddock_name"
        case quantityTonnes = "quantity_tonnes"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(allocationId, forKey: .allocationId)
        try c.encode(vineyardId, forKey: .vineyardId)
        try c.encode(paddockId, forKey: .paddockId)
        try c.encode(paddockName, forKey: .paddockName)
        try c.encode(quantityTonnes, forKey: .quantityTonnes)
    }
}

/// Owner/manager row from `get_grape_allocation_financials` (42501 for
/// everyone else — callers swallow that and show no money).
nonisolated struct GrapeAllocationFinancialRow: Codable, Sendable {
    let allocationId: UUID
    let pricePerTonne: Double?
    let contractValue: Double?

    nonisolated enum CodingKeys: String, CodingKey {
        case allocationId = "allocation_id"
        case pricePerTonne = "price_per_tonne"
        case contractValue = "contract_value"
    }
}

extension BackendGrapeAllocation {
    static func upsert(from allocation: GrapeAllocation, createdBy: UUID?, clientUpdatedAt: Date) -> BackendGrapeAllocationUpsert {
        let isExternal = allocation.allocationType == .external
        return BackendGrapeAllocationUpsert(
            id: allocation.id,
            vineyardId: allocation.vineyardId,
            vintage: allocation.vintage,
            allocationType: allocation.allocationType.rawValue,
            varietyId: allocation.varietyId,
            varietyKey: allocation.varietyKey,
            varietyName: allocation.varietyName,
            destinationName: allocation.destinationName,
            quantityTonnes: allocation.quantityTonnes,
            notes: allocation.notes,
            purchaserName: isExternal ? allocation.purchaserName : nil,
            contactName: isExternal ? allocation.contactName : nil,
            contactEmail: isExternal ? allocation.contactEmail : nil,
            contactPhone: isExternal ? allocation.contactPhone : nil,
            contactAddress: isExternal ? allocation.contactAddress : nil,
            pricePerTonne: isExternal ? allocation.pricePerTonne : nil,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toGrapeAllocation(blocks: [GrapeAllocationBlock]) -> GrapeAllocation {
        GrapeAllocation(
            id: id,
            vineyardId: vineyardId,
            vintage: vintage ?? 0,
            allocationType: GrapeAllocationType(rawValue: allocationType ?? "") ?? .ownUse,
            varietyId: varietyId,
            varietyKey: varietyKey,
            varietyName: varietyName ?? "",
            destinationName: destinationName,
            quantityTonnes: quantityTonnes ?? 0,
            notes: notes,
            purchaserName: purchaserName,
            contactName: contactName,
            contactEmail: contactEmail,
            contactPhone: contactPhone,
            contactAddress: contactAddress,
            pricePerTonne: nil,
            blocks: blocks,
            updatedAt: updatedAt
        )
    }
}

extension BackendGrapeAllocationBlock {
    func toGrapeAllocationBlock() -> GrapeAllocationBlock {
        GrapeAllocationBlock(
            id: id,
            paddockId: paddockId,
            paddockName: paddockName ?? "",
            quantityTonnes: quantityTonnes
        )
    }
}
