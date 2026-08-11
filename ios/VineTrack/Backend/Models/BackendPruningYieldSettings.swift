import Foundation

/// Full row of `public.pruning_yield_settings` (sql/181) as returned by
/// PostgREST — the shared per-block Pruning Yield Calculator configuration.
nonisolated struct BackendPruningYieldSettings: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let paddockId: UUID
    let pruneMethod: String?
    let bunchesPerBud: Double?
    let budsPerSpur: Double?
    let spursPerVine: Double?
    let budsPerCane: Double?
    let canesPerVine: Double?
    let vinesPerHa: Double?
    let bunchWeightGrams: Double?
    let createdBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case pruneMethod = "prune_method"
        case bunchesPerBud = "bunches_per_bud"
        case budsPerSpur = "buds_per_spur"
        case spursPerVine = "spurs_per_vine"
        case budsPerCane = "buds_per_cane"
        case canesPerVine = "canes_per_vine"
        case vinesPerHa = "vines_per_ha"
        case bunchWeightGrams = "bunch_weight_grams"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }
}

/// Upsert payload for `public.pruning_yield_settings`.
///
/// Pushed with `on_conflict=vineyard_id,paddock_id` so one block converges on
/// ONE shared record even when two devices minted different row ids.
nonisolated struct BackendPruningYieldSettingsUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let paddockId: UUID
    let pruneMethod: String
    let bunchesPerBud: Double
    let budsPerSpur: Double
    let spursPerVine: Double
    let budsPerCane: Double
    let canesPerVine: Double
    let vinesPerHa: Double?
    let bunchWeightGrams: Double
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case pruneMethod = "prune_method"
        case bunchesPerBud = "bunches_per_bud"
        case budsPerSpur = "buds_per_spur"
        case spursPerVine = "spurs_per_vine"
        case budsPerCane = "buds_per_cane"
        case canesPerVine = "canes_per_vine"
        case vinesPerHa = "vines_per_ha"
        case bunchWeightGrams = "bunch_weight_grams"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(vineyardId, forKey: .vineyardId)
        try c.encode(paddockId, forKey: .paddockId)
        try c.encode(pruneMethod, forKey: .pruneMethod)
        try c.encode(bunchesPerBud, forKey: .bunchesPerBud)
        try c.encode(budsPerSpur, forKey: .budsPerSpur)
        try c.encode(spursPerVine, forKey: .spursPerVine)
        try c.encode(budsPerCane, forKey: .budsPerCane)
        try c.encode(canesPerVine, forKey: .canesPerVine)
        // Encode nil explicitly so clearing Vines/Ha also clears the column.
        try c.encode(vinesPerHa, forKey: .vinesPerHa)
        try c.encode(bunchWeightGrams, forKey: .bunchWeightGrams)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}

extension BackendPruningYieldSettings {
    static func upsert(from settings: PruningYieldSettings, createdBy: UUID?, clientUpdatedAt: Date) -> BackendPruningYieldSettingsUpsert {
        BackendPruningYieldSettingsUpsert(
            id: settings.id,
            vineyardId: settings.vineyardId,
            paddockId: settings.paddockId,
            pruneMethod: settings.pruneMethod,
            bunchesPerBud: settings.bunchesPerBud,
            budsPerSpur: settings.budsPerSpur,
            spursPerVine: settings.spursPerVine,
            budsPerCane: settings.budsPerCane,
            canesPerVine: settings.canesPerVine,
            vinesPerHa: settings.vinesPerHa,
            bunchWeightGrams: settings.bunchWeightGrams,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toPruningYieldSettings() -> PruningYieldSettings {
        PruningYieldSettings(
            id: id,
            vineyardId: vineyardId,
            paddockId: paddockId,
            pruneMethod: (pruneMethod ?? PruningYieldDefaults.pruneMethod).lowercased() == "cane" ? "cane" : "spur",
            bunchesPerBud: bunchesPerBud ?? PruningYieldDefaults.bunchesPerBud,
            budsPerSpur: budsPerSpur ?? PruningYieldDefaults.budsPerSpur,
            spursPerVine: spursPerVine ?? PruningYieldDefaults.spursPerVine,
            budsPerCane: budsPerCane ?? PruningYieldDefaults.budsPerCane,
            canesPerVine: canesPerVine ?? PruningYieldDefaults.canesPerVine,
            vinesPerHa: vinesPerHa,
            bunchWeightGrams: bunchWeightGrams ?? PruningYieldDefaults.bunchWeightGrams,
            updatedAt: clientUpdatedAt ?? updatedAt ?? Date()
        )
    }
}
