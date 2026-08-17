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
    /// Server-issued revision (sql/198). SERVER STATE, never authored by a screen.
    ///
    /// Optional for tolerance, not because the column is: a row last written by a
    /// pre-sql/198 client, or a response from a path that did not project the column, must
    /// DECODE rather than throw. A decode failure here would take out the whole pull.
    let serverRevision: Int64?

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
        case serverRevision = "server_revision"
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
    /// When the grower edited. METADATA under sql/198 — clamped to server `now()` and no
    /// longer the concurrency authority. Still SENT, and removing it would be a real
    /// regression: the sql/181 resurrection trigger detects a genuine client upsert by this
    /// value CHANGING (`new.client_updated_at is distinct from old.client_updated_at`) and
    /// un-deletes a soft-deleted block configuration on that basis. That is a
    /// change-detector, not an ordering comparison.
    let clientUpdatedAt: Date
    /// The version this edit was based on — THE concurrency authority (sql/198).
    ///
    /// Omitted from the JSON when nil, which sql/198 reads as a create. Never derived,
    /// never incremented, never defaulted.
    let baseRevision: Int64?

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
        case baseRevision = "base_revision"
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
        // ALWAYS encoded: the sql/181 resurrection trigger keys off this value changing.
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
        // encodeIfPresent, NOT encode: a row this device has never been issued a revision
        // for must OMIT the key so sql/198 reads the write as a create. An explicit null is
        // a different statement to the server.
        try c.encodeIfPresent(baseRevision, forKey: .baseRevision)
    }
}

extension BackendPruningYieldSettings {
    /// The ONE mapping from a local configuration to a versioned write. `baseRevision` comes
    /// from ``PruningYieldSettings/serverRevision`` and nothing else.
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
            clientUpdatedAt: clientUpdatedAt,
            baseRevision: settings.serverRevision
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
            updatedAt: clientUpdatedAt ?? updatedAt ?? Date(),
            // Carried through so the NEXT edit can assert it as `base_revision`. Nil for a
            // legacy row, which sql/198 then treats as a create — correct, and the row
            // becomes versioned from that write on.
            serverRevision: serverRevision
        )
    }
}
