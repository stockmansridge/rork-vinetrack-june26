import Foundation

/// Supabase DTOs for Work Task Material Costs (sql/247).
///
/// Three tables, three read shapes and two write shapes:
///
///  * `public.material_catalogue`   — read only (no client write shape exists,
///    and the database refuses one)
///  * `public.vineyard_materials`   — read + upsert
///  * `public.work_task_materials`  — read + upsert
///
/// Money and quantity cross the wire as JSON numbers backed by `Decimal`, never
/// `Double`. `work_task_materials.total_cost` is a GENERATED column and is
/// therefore read-only: it is decoded for display/verification and never sent.

// MARK: - Shared decoding helpers

nonisolated enum BackendMaterialDecoding {
    /// Postgres `numeric` arrives as a JSON number, but a proxy or a cached
    /// payload may present it as a string. Both land on `Decimal` without
    /// passing through binary floating point.
    static func decimal<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Decimal? {
        if let value = try? c.decodeIfPresent(Decimal.self, forKey: key) { return value }
        if let text = try? c.decodeIfPresent(String.self, forKey: key), !text.isEmpty {
            return Decimal(string: text)
        }
        return nil
    }

    static func date<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Date? {
        if let d = try? c.decodeIfPresent(Date.self, forKey: key) { return d }
        guard let s = try? c.decodeIfPresent(String.self, forKey: key), !s.isEmpty else { return nil }
        return BackendDamageRecordDateParser.parse(s)
    }
}

// MARK: - A. Base catalogue (read only)

nonisolated struct BackendMaterialCatalogueItem: Decodable, Sendable, Identifiable {
    let id: UUID
    let key: String
    let name: String?
    let category: String?
    let defaultUnit: String?
    let sortOrder: Int?
    let isActive: Bool?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, key, name, category
        case defaultUnit = "default_unit"
        case sortOrder = "sort_order"
        case isActive = "is_active"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        key = try c.decode(String.self, forKey: .key)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        defaultUnit = try c.decodeIfPresent(String.self, forKey: .defaultUnit)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive)
        updatedAt = BackendMaterialDecoding.date(c, .updatedAt)
    }

    /// The server row carries the authoritative UUID; the domain model keys off
    /// `key` so a bundled offline entry and its server row are the same item.
    func toCatalogueItem() -> MaterialCatalogueItem {
        MaterialCatalogueItem(
            key: key,
            remoteId: id,
            name: name ?? key,
            category: category ?? MaterialCategoryCatalog.other,
            defaultUnit: MaterialUnitCatalog.normalised(defaultUnit),
            sortOrder: sortOrder ?? 0,
            isActive: isActive ?? true
        )
    }
}

// MARK: - B. Vineyard materials

nonisolated struct BackendVineyardMaterial: Decodable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let baseMaterialId: UUID?
    let name: String?
    let category: String?
    let unit: String?
    let defaultUnitCost: Decimal?
    let isCustom: Bool?
    let isActive: Bool?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, category, unit
        case vineyardId = "vineyard_id"
        case baseMaterialId = "base_material_id"
        case defaultUnitCost = "default_unit_cost"
        case isCustom = "is_custom"
        case isActive = "is_active"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        baseMaterialId = try c.decodeIfPresent(UUID.self, forKey: .baseMaterialId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        defaultUnitCost = BackendMaterialDecoding.decimal(c, .defaultUnitCost)
        isCustom = try c.decodeIfPresent(Bool.self, forKey: .isCustom)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive)
        createdAt = BackendMaterialDecoding.date(c, .createdAt)
        updatedAt = BackendMaterialDecoding.date(c, .updatedAt)
        deletedAt = BackendMaterialDecoding.date(c, .deletedAt)
        clientUpdatedAt = BackendMaterialDecoding.date(c, .clientUpdatedAt)
    }

    /// `baseMaterialKey` is resolved from the synced catalogue so an override
    /// still matches its base item when only the bundled catalogue is loaded.
    func toVineyardMaterial(catalogue: [MaterialCatalogueItem]) -> VineyardMaterial {
        let key = baseMaterialId.flatMap { remoteId in
            catalogue.first(where: { $0.remoteId == remoteId })?.key
        }
        return VineyardMaterial(
            id: id,
            vineyardId: vineyardId,
            baseMaterialId: baseMaterialId,
            baseMaterialKey: key,
            name: name ?? "",
            category: category ?? "",
            unit: MaterialUnitCatalog.normalised(unit),
            defaultUnitCost: defaultUnitCost,
            isCustom: isCustom ?? (baseMaterialId == nil),
            isActive: isActive ?? true
        )
    }
}

nonisolated struct BackendVineyardMaterialUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let baseMaterialId: UUID?
    let name: String
    let category: String
    let unit: String
    let defaultUnitCost: Decimal?
    let isCustom: Bool
    let isActive: Bool
    let createdBy: UUID?
    let updatedBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, category, unit
        case vineyardId = "vineyard_id"
        case baseMaterialId = "base_material_id"
        case defaultUnitCost = "default_unit_cost"
        case isCustom = "is_custom"
        case isActive = "is_active"
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendVineyardMaterial {
    static func upsert(
        from material: VineyardMaterial,
        createdBy: UUID?,
        updatedBy: UUID?,
        clientUpdatedAt: Date
    ) -> BackendVineyardMaterialUpsert {
        BackendVineyardMaterialUpsert(
            id: material.id,
            vineyardId: material.vineyardId,
            // The database's `vineyard_materials_custom_shape` check requires a
            // custom row to carry NO base id and an override to carry one.
            baseMaterialId: material.isCustom ? nil : material.baseMaterialId,
            name: material.name.trimmingCharacters(in: .whitespacesAndNewlines),
            category: material.category,
            unit: MaterialUnitCatalog.normalised(material.unit),
            defaultUnitCost: material.defaultUnitCost.map { max($0, 0) },
            isCustom: material.isCustom,
            isActive: material.isActive,
            createdBy: createdBy,
            updatedBy: updatedBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }
}

// MARK: - C. Work Task materials

nonisolated struct BackendWorkTaskMaterial: Decodable, Sendable, Identifiable {
    let id: UUID
    let workTaskId: UUID
    let vineyardId: UUID
    let baseMaterialId: UUID?
    let vineyardMaterialId: UUID?
    let materialName: String?
    let category: String?
    let unit: String?
    let quantity: Decimal?
    let unitCost: Decimal?
    /// GENERATED column — read for verification, never written.
    let totalCost: Decimal?
    let notes: String?
    let createdBy: UUID?
    let updatedBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, category, unit, quantity, notes
        case workTaskId = "work_task_id"
        case vineyardId = "vineyard_id"
        case baseMaterialId = "base_material_id"
        case vineyardMaterialId = "vineyard_material_id"
        case materialName = "material_name"
        case unitCost = "unit_cost"
        case totalCost = "total_cost"
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        workTaskId = try c.decode(UUID.self, forKey: .workTaskId)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        baseMaterialId = try c.decodeIfPresent(UUID.self, forKey: .baseMaterialId)
        vineyardMaterialId = try c.decodeIfPresent(UUID.self, forKey: .vineyardMaterialId)
        materialName = try c.decodeIfPresent(String.self, forKey: .materialName)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        quantity = BackendMaterialDecoding.decimal(c, .quantity)
        unitCost = BackendMaterialDecoding.decimal(c, .unitCost)
        totalCost = BackendMaterialDecoding.decimal(c, .totalCost)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        updatedBy = try c.decodeIfPresent(UUID.self, forKey: .updatedBy)
        createdAt = BackendMaterialDecoding.date(c, .createdAt)
        updatedAt = BackendMaterialDecoding.date(c, .updatedAt)
        deletedAt = BackendMaterialDecoding.date(c, .deletedAt)
        clientUpdatedAt = BackendMaterialDecoding.date(c, .clientUpdatedAt)
    }
}

nonisolated struct BackendWorkTaskMaterialUpsert: Encodable, Sendable {
    let id: UUID
    let workTaskId: UUID
    let vineyardId: UUID
    let baseMaterialId: UUID?
    let vineyardMaterialId: UUID?
    let materialName: String
    let category: String
    let unit: String
    let quantity: Decimal
    let unitCost: Decimal
    let notes: String
    let createdBy: UUID?
    let updatedBy: UUID?
    let clientUpdatedAt: Date

    // `total_cost` is deliberately absent: it is GENERATED ALWAYS, so the
    // server computes it from the quantity and unit cost sent here and a
    // client can never disagree with the stored total.
    enum CodingKeys: String, CodingKey {
        case id, category, unit, quantity, notes
        case workTaskId = "work_task_id"
        case vineyardId = "vineyard_id"
        case baseMaterialId = "base_material_id"
        case vineyardMaterialId = "vineyard_material_id"
        case materialName = "material_name"
        case unitCost = "unit_cost"
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendWorkTaskMaterial {
    static func upsert(
        from material: WorkTaskMaterial,
        createdBy: UUID?,
        updatedBy: UUID?,
        clientUpdatedAt: Date
    ) -> BackendWorkTaskMaterialUpsert {
        BackendWorkTaskMaterialUpsert(
            id: material.id,
            workTaskId: material.workTaskId,
            vineyardId: material.vineyardId,
            baseMaterialId: material.baseMaterialId,
            vineyardMaterialId: material.vineyardMaterialId,
            materialName: material.materialName.trimmingCharacters(in: .whitespacesAndNewlines),
            category: material.category,
            unit: MaterialUnitCatalog.normalised(material.unit),
            quantity: max(material.quantity, 0),
            unitCost: max(material.unitCost, 0),
            notes: material.notes,
            createdBy: createdBy,
            updatedBy: updatedBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    /// The snapshot fields are taken verbatim from the row. Nothing is
    /// re-derived from today's library, which is what keeps a historical task
    /// cost historical.
    func toWorkTaskMaterial() -> WorkTaskMaterial {
        WorkTaskMaterial(
            id: id,
            workTaskId: workTaskId,
            vineyardId: vineyardId,
            baseMaterialId: baseMaterialId,
            vineyardMaterialId: vineyardMaterialId,
            materialName: materialName ?? "",
            category: category ?? "",
            unit: MaterialUnitCatalog.normalised(unit),
            quantity: quantity ?? 0,
            unitCost: unitCost ?? 0,
            notes: notes ?? ""
        )
    }
}
