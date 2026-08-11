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
    /// Stable id of the `paddocks.variety_allocations[]` entry this pick was
    /// recorded against (sql/183). Block + Variety + Clone + Rootstock is NOT
    /// unique — one block can carry two plantings of the same variety with
    /// identical clone and rootstock — so this id is the only exact planting
    /// identity. nil = not linked (historical rows are never backfilled by
    /// guessing; linking only happens through an explicit selection).
    var varietyAllocationId: UUID?
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
        varietyAllocationId: UUID? = nil,
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
        self.varietyAllocationId = varietyAllocationId
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
