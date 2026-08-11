import Foundation

/// Date helpers for the `picked_at` `date`-typed Postgres column
/// (plain "yyyy-MM-dd" strings, UTC-anchored like `work_date`).
nonisolated enum PickingRecordDate {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func ymd(from date: Date) -> String {
        // Encode the *local calendar day* the user picked, not the UTC day of
        // the timestamp — a 10 Feb pick must stay 10 Feb in the database.
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(from ymd: String) -> Date? {
        formatter.date(from: ymd)
    }
}

/// Full row of `public.picking_records` (sql/180) as returned by PostgREST.
nonisolated struct BackendPickingRecord: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    /// "yyyy-MM-dd" string from the SQL `date` column.
    let pickedAt: String?
    let vintage: Int?
    let paddockId: UUID
    let paddockName: String?
    let varietyId: UUID?
    let varietyKey: String?
    let varietyName: String?
    /// Stable planting-group identity (sql/184). NULL = unlinked (pre-184
    /// rows are never backfilled).
    let plantingGroupKey: String?
    /// Member `paddocks.variety_allocations[].id` snapshot of the group.
    let varietyAllocationIds: [UUID]?
    let clone: String?
    /// Rootstock display snapshot from the planting group (sql/184).
    let rootstock: String?
    let weightKg: Double?
    let sugarValue: Double?
    let sugarUnit: String?
    let ph: Double?
    let taGPerL: Double?
    let purpose: String?
    let sold: Bool?
    let soldTo: String?
    let pricePerTonne: Double?
    /// Server-generated `(weight_kg / 1000) * price_per_tonne` — read-only.
    let grapeValue: Double?
    let notes: String?
    let createdBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case pickedAt = "picked_at"
        case vintage
        case paddockId = "paddock_id"
        case paddockName = "paddock_name"
        case varietyId = "variety_id"
        case varietyKey = "variety_key"
        case varietyName = "variety_name"
        case plantingGroupKey = "planting_group_key"
        case varietyAllocationIds = "variety_allocation_ids"
        case clone
        case rootstock
        case weightKg = "weight_kg"
        case sugarValue = "sugar_value"
        case sugarUnit = "sugar_unit"
        case ph
        case taGPerL = "ta_g_l"
        case purpose
        case sold
        case soldTo = "sold_to"
        case pricePerTonne = "price_per_tonne"
        case grapeValue = "grape_value"
        case notes
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }
}

/// Upsert payload for `public.picking_records`.
///
/// Deliberately OMITS `vintage` (server-derived from `picked_at` via the
/// sql/119 resolver — a client value is never trusted) and `grape_value`
/// (a generated column; including it would make the insert fail).
nonisolated struct BackendPickingRecordUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let pickedAt: String
    let paddockId: UUID
    let paddockName: String
    let varietyId: UUID?
    let varietyKey: String?
    let varietyName: String
    let plantingGroupKey: String?
    let varietyAllocationIds: [UUID]?
    let clone: String?
    let rootstock: String?
    let weightKg: Double
    let sugarValue: Double?
    let sugarUnit: String?
    let ph: Double?
    let taGPerL: Double?
    let purpose: String
    let sold: Bool
    let soldTo: String?
    let pricePerTonne: Double?
    let notes: String
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case pickedAt = "picked_at"
        case paddockId = "paddock_id"
        case paddockName = "paddock_name"
        case varietyId = "variety_id"
        case varietyKey = "variety_key"
        case varietyName = "variety_name"
        case plantingGroupKey = "planting_group_key"
        case varietyAllocationIds = "variety_allocation_ids"
        case clone
        case rootstock
        case weightKg = "weight_kg"
        case sugarValue = "sugar_value"
        case sugarUnit = "sugar_unit"
        case ph
        case taGPerL = "ta_g_l"
        case purpose
        case sold
        case soldTo = "sold_to"
        case pricePerTonne = "price_per_tonne"
        case notes
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(vineyardId, forKey: .vineyardId)
        try c.encode(pickedAt, forKey: .pickedAt)
        try c.encode(paddockId, forKey: .paddockId)
        try c.encode(paddockName, forKey: .paddockName)
        // Encode nils explicitly so an edit that clears a field (e.g. un-sells
        // a pick) also clears the server column on upsert.
        try c.encode(varietyId, forKey: .varietyId)
        try c.encode(varietyKey, forKey: .varietyKey)
        try c.encode(varietyName, forKey: .varietyName)
        try c.encode(plantingGroupKey, forKey: .plantingGroupKey)
        try c.encode(varietyAllocationIds, forKey: .varietyAllocationIds)
        try c.encode(clone, forKey: .clone)
        try c.encode(rootstock, forKey: .rootstock)
        try c.encode(weightKg, forKey: .weightKg)
        try c.encode(sugarValue, forKey: .sugarValue)
        try c.encode(sugarUnit, forKey: .sugarUnit)
        try c.encode(ph, forKey: .ph)
        try c.encode(taGPerL, forKey: .taGPerL)
        try c.encode(purpose, forKey: .purpose)
        try c.encode(sold, forKey: .sold)
        try c.encode(soldTo, forKey: .soldTo)
        try c.encode(pricePerTonne, forKey: .pricePerTonne)
        try c.encode(notes, forKey: .notes)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}

extension BackendPickingRecord {
    static func upsert(from record: PickingRecord, createdBy: UUID?, clientUpdatedAt: Date) -> BackendPickingRecordUpsert {
        BackendPickingRecordUpsert(
            id: record.id,
            vineyardId: record.vineyardId,
            pickedAt: PickingRecordDate.ymd(from: record.pickedAt),
            paddockId: record.paddockId,
            paddockName: record.paddockName,
            varietyId: record.varietyId,
            varietyKey: record.varietyKey,
            varietyName: record.varietyName,
            plantingGroupKey: record.plantingGroupKey,
            varietyAllocationIds: record.varietyAllocationIds,
            clone: record.clone,
            rootstock: record.rootstock,
            weightKg: record.weightKg,
            sugarValue: record.sugarValue,
            sugarUnit: record.sugarUnit,
            ph: record.ph,
            taGPerL: record.taGPerL,
            purpose: record.purpose,
            sold: record.sold,
            soldTo: record.soldTo,
            pricePerTonne: record.pricePerTonne,
            notes: record.notes,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toPickingRecord() -> PickingRecord {
        PickingRecord(
            id: id,
            vineyardId: vineyardId,
            pickedAt: pickedAt.flatMap { PickingRecordDate.date(from: $0) } ?? createdAt ?? Date(),
            vintage: vintage ?? 0,
            paddockId: paddockId,
            paddockName: paddockName ?? "",
            varietyId: varietyId,
            varietyKey: varietyKey,
            varietyName: varietyName ?? "",
            plantingGroupKey: plantingGroupKey,
            varietyAllocationIds: varietyAllocationIds,
            clone: clone,
            rootstock: rootstock,
            weightKg: weightKg ?? 0,
            sugarValue: sugarValue,
            sugarUnit: sugarUnit,
            ph: ph,
            taGPerL: taGPerL,
            purpose: purpose ?? "",
            sold: sold ?? false,
            soldTo: soldTo,
            pricePerTonne: pricePerTonne,
            notes: notes ?? ""
        )
    }
}
