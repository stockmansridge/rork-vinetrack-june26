import Foundation

/// One individual picking event — the Detailed mode of Record Actual Yield.
///
/// A Block + Variety + Vintage may have MANY picking records in the same
/// vintage; the actual yield for that combination is the SUM of their weights
/// (`SUM(weight_kg) / 1000` tonnes). Mirrors `public.picking_records`
/// (sql/180).
///
/// Aggregation precedence (canonical, shared with Android and the portal):
/// when picking records exist for a Block + Variety + Vintage, their summed
/// weight IS the actual yield for that combination — a Basic manually entered
/// actual for the same combination is superseded, never added on top.
///
/// `vintage` is server-authoritative (derived from `pickedAt` + the shared
/// season settings, sql/119); the local value is a mirror computed with
/// `VintageResolver` for offline display and grouping.
nonisolated struct PickingRecord: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    /// Picking date (date-only semantics; stored as SQL `date`).
    var pickedAt: Date
    /// Season-end vintage year, e.g. 2027 for a Feb 2027 pick under a 1 July
    /// season start. Server-derived; mirrored locally via `VintageResolver`.
    var vintage: Int
    var paddockId: UUID
    /// Point-in-time snapshot of the block name.
    var paddockName: String
    var varietyId: UUID?
    /// Stable catalog key (e.g. `pinot_gris`) carried from the block's
    /// `PaddockVarietyAllocation` — trusted across devices/id drift.
    var varietyKey: String?
    /// Point-in-time snapshot of the variety display name.
    var varietyName: String
    /// Stable PLANTING-GROUP identity (sql/184): `PlantingGroup.key` of the
    /// variety/clone/rootstock snapshots, scoped per block. A group is the
    /// set of `paddocks.variety_allocations[]` sections sharing Block +
    /// Variety + Clone + Rootstock — one block can carry several identical
    /// sections, so a single allocation id could never represent the pick.
    /// Server-canonicalised on every write. nil = not linked (historical
    /// rows are never backfilled by guessing; linking is always explicit).
    var plantingGroupKey: String?
    /// Member allocation ids of the planting group at entry time (block-
    /// config order). `[]` = linked group whose member allocations have no
    /// minted ids. nil = not linked. Point-in-time snapshot, no FK.
    var varietyAllocationIds: [UUID]?
    /// Reference-only clone designation from the block allocation (e.g. `MV6`).
    var clone: String?
    /// Reference-only rootstock display snapshot from the block allocation
    /// (e.g. `Richter 110`). Same point-in-time semantics as `clone`.
    var rootstock: String?
    var weightKg: Double
    /// Sugar measurement value in the unit recorded at entry time.
    var sugarValue: Double?
    /// `"brix"` or `"baume"` — ALWAYS stored with the value so later vineyard
    /// preference changes never reinterpret historical records.
    var sugarUnit: String?
    var ph: Double?
    /// Titratable acidity in g/L.
    var taGPerL: Double?
    var purpose: String
    var sold: Bool
    var soldTo: String?
    var pricePerTonne: Double?
    var notes: String

    var tonnes: Double { weightKg / 1000.0 }

    /// Grape value for a sold pick: `tonnes × price_per_tonne`. Mirrors the
    /// server's generated `grape_value` column — never entered manually.
    var grapeValue: Double? {
        guard sold, let price = pricePerTonne else { return nil }
        return tonnes * price
    }

    var sugarMeasurement: SugarMeasurementUnit? {
        guard let raw = sugarUnit else { return nil }
        return SugarMeasurementUnit(rawValue: raw)
    }

    init(
        id: UUID = UUID(),
        vineyardId: UUID,
        pickedAt: Date,
        vintage: Int,
        paddockId: UUID,
        paddockName: String,
        varietyId: UUID? = nil,
        varietyKey: String? = nil,
        varietyName: String = "",
        plantingGroupKey: String? = nil,
        varietyAllocationIds: [UUID]? = nil,
        clone: String? = nil,
        rootstock: String? = nil,
        weightKg: Double,
        sugarValue: Double? = nil,
        sugarUnit: String? = nil,
        ph: Double? = nil,
        taGPerL: Double? = nil,
        purpose: String = "",
        sold: Bool = false,
        soldTo: String? = nil,
        pricePerTonne: Double? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.pickedAt = pickedAt
        self.vintage = vintage
        self.paddockId = paddockId
        self.paddockName = paddockName
        self.varietyId = varietyId
        self.varietyKey = varietyKey
        self.varietyName = varietyName
        self.plantingGroupKey = plantingGroupKey
        self.varietyAllocationIds = varietyAllocationIds
        self.clone = clone
        self.rootstock = rootstock
        self.weightKg = weightKg
        self.sugarValue = sugarValue
        self.sugarUnit = sugarUnit
        self.ph = ph
        self.taGPerL = taGPerL
        self.purpose = purpose
        self.sold = sold
        self.soldTo = soldTo
        self.pricePerTonne = pricePerTonne
        self.notes = notes
    }
}

/// Planting-group identity helpers (sql/184). The key algorithm is shared
/// byte-for-byte with Android (`plantingGroupKey`), the Portal and the SQL
/// function `public.planting_group_key` — see
/// docs/picking-records-allocation-identity-contract.md §3.
nonisolated enum PlantingGroup {
    /// lowercase(trim(collapse internal whitespace)); "" for nil.
    static func normalise(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    /// `norm(variety)|norm(clone)|norm(rootstock)` — scoped per block via the
    /// record's `paddockId`, which is deliberately NOT part of the key.
    static func key(varietyName: String?, clone: String?, rootstock: String?) -> String {
        [normalise(varietyName), normalise(clone), normalise(rootstock)].joined(separator: "|")
    }
}

/// Canonical aggregation of picking records into actual yield, shared by all
/// yield surfaces. Mirrors the server view `public.picking_yield_totals`.
nonisolated enum PickingYieldAggregator {

    /// Aggregation key: one actual-yield bucket per Block + Variety + Vintage.
    struct Key: Hashable, Sendable {
        let paddockId: UUID
        /// Case/whitespace-insensitive variety identity.
        let varietyKey: String
        let vintage: Int
    }

    struct Total: Sendable, Identifiable {
        var paddockId: UUID
        var paddockName: String
        var varietyName: String
        var vintage: Int
        var pickCount: Int
        var totalWeightKg: Double
        var firstPickedAt: Date
        var lastPickedAt: Date
        var totalGrapeValue: Double?

        var id: String {
            "\(paddockId.uuidString)|\(PickingYieldAggregator.normalisedVariety(varietyName))|\(vintage)"
        }

        var actualYieldTonnes: Double { totalWeightKg / 1000.0 }
    }

    static func normalisedVariety(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Sum picking records into Block + Variety + Vintage totals.
    static func totals(for records: [PickingRecord]) -> [Total] {
        var buckets: [Key: Total] = [:]
        for record in records {
            let key = Key(
                paddockId: record.paddockId,
                varietyKey: normalisedVariety(record.varietyName),
                vintage: record.vintage
            )
            if var existing = buckets[key] {
                existing.pickCount += 1
                existing.totalWeightKg += record.weightKg
                existing.firstPickedAt = min(existing.firstPickedAt, record.pickedAt)
                existing.lastPickedAt = max(existing.lastPickedAt, record.pickedAt)
                if let value = record.grapeValue {
                    existing.totalGrapeValue = (existing.totalGrapeValue ?? 0) + value
                }
                buckets[key] = existing
            } else {
                buckets[key] = Total(
                    paddockId: record.paddockId,
                    paddockName: record.paddockName,
                    varietyName: record.varietyName,
                    vintage: record.vintage,
                    pickCount: 1,
                    totalWeightKg: record.weightKg,
                    firstPickedAt: record.pickedAt,
                    lastPickedAt: record.pickedAt,
                    totalGrapeValue: record.grapeValue
                )
            }
        }
        return buckets.values.sorted {
            ($0.vintage, $0.paddockName, $0.varietyName) > ($1.vintage, $1.paddockName, $1.varietyName)
        }
    }

    /// Per-planting-group breakdown of ONE Block + Variety + Vintage bucket
    /// (sql/184). Groups partition the bucket's picks by `plantingGroupKey`;
    /// the nil bucket collects unlinked picks. The sum of all group weights
    /// always reconciles exactly to the bucket total by construction.
    struct PlantingGroupTotal: Sendable, Identifiable {
        /// Canonical group key, or nil for the unlinked bucket.
        var groupKey: String?
        /// Display snapshots from the group's picks (first non-nil wins).
        var clone: String?
        var rootstock: String?
        var pickCount: Int
        var totalWeightKg: Double

        var actualYieldTonnes: Double { totalWeightKg / 1000.0 }
        var id: String { groupKey ?? "unlinked" }
    }

    /// Partition one bucket's records into planting-group sub-totals.
    /// Linked groups keep first-appearance order; the unlinked bucket, if
    /// any, is always last.
    static func plantingGroupTotals(for records: [PickingRecord]) -> [PlantingGroupTotal] {
        var order: [String] = []
        var linked: [String: PlantingGroupTotal] = [:]
        var unlinked: PlantingGroupTotal?
        for record in records {
            if let key = record.plantingGroupKey {
                if var existing = linked[key] {
                    existing.pickCount += 1
                    existing.totalWeightKg += record.weightKg
                    if existing.clone == nil { existing.clone = record.clone }
                    if existing.rootstock == nil { existing.rootstock = record.rootstock }
                    linked[key] = existing
                } else {
                    order.append(key)
                    linked[key] = PlantingGroupTotal(
                        groupKey: key,
                        clone: record.clone,
                        rootstock: record.rootstock,
                        pickCount: 1,
                        totalWeightKg: record.weightKg
                    )
                }
            } else if var existing = unlinked {
                existing.pickCount += 1
                existing.totalWeightKg += record.weightKg
                unlinked = existing
            } else {
                unlinked = PlantingGroupTotal(
                    groupKey: nil,
                    clone: nil,
                    rootstock: nil,
                    pickCount: 1,
                    totalWeightKg: record.weightKg
                )
            }
        }
        var result = order.compactMap { linked[$0] }
        if let unlinked { result.append(unlinked) }
        return result
    }

    /// Detailed-derived actual yield tonnes for one Block + Variety + Vintage,
    /// or nil when no picking records exist for that combination (in which
    /// case a Basic manually entered actual, if any, remains authoritative).
    static func detailedActualTonnes(
        records: [PickingRecord],
        paddockId: UUID,
        varietyName: String?,
        vintage: Int
    ) -> Double? {
        let varietyFilter = varietyName.map(normalisedVariety)
        let matching = records.filter { record in
            guard record.paddockId == paddockId, record.vintage == vintage else { return false }
            guard let varietyFilter, !varietyFilter.isEmpty else { return true }
            return normalisedVariety(record.varietyName) == varietyFilter
        }
        guard !matching.isEmpty else { return nil }
        return matching.reduce(0.0) { $0 + $1.weightKg } / 1000.0
    }
}
