import Foundation

/// How allocated tonnes will be used.
nonisolated enum GrapeAllocationType: String, Codable, CaseIterable, Sendable {
    case ownUse = "own_use"
    case external = "external"

    var displayName: String {
        switch self {
        case .ownUse: "Own Use"
        case .external: "Sale / Commitment"
        }
    }
}

/// Optional per-block split of an allocation (`public.grape_allocation_blocks`,
/// sql/217). One allocation may span multiple blocks; assignment is optional.
nonisolated struct GrapeAllocationBlock: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var paddockId: UUID
    /// Point-in-time snapshot of the block name (no FK — house convention).
    var paddockName: String
    /// Tonnes assigned to this block; nil = unspecified split.
    var quantityTonnes: Double?

    init(id: UUID = UUID(), paddockId: UUID, paddockName: String, quantityTonnes: Double? = nil) {
        self.id = id
        self.paddockId = paddockId
        self.paddockName = paddockName
        self.quantityTonnes = quantityTonnes
    }
}

/// One grape allocation for a vintage (`public.grape_allocations`, sql/217):
/// Own Use (estate wine, home block…) or an external Sale / Commitment.
///
/// NO aggregates are stored — estimated yield, balance and contract values
/// are always derived from the latest Yield Estimate + these rows
/// (`GrapeAllocationCalculator`), so completing a new Bunch Count Trip
/// automatically moves the allocation balance.
///
/// `pricePerTonne` is owner/manager-only: it lives in the RLS-guarded
/// companion table `grape_allocation_financials` and is merged in via
/// `get_grape_allocation_financials`. Lower roles never receive it.
nonisolated struct GrapeAllocation: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    /// Season-end vintage year the allocation belongs to (user-chosen).
    var vintage: Int
    var allocationType: GrapeAllocationType
    var varietyId: UUID?
    /// Stable catalog key (e.g. `pinot_gris`) from the block's variety
    /// allocation, matching the picking-record variety trio convention.
    var varietyKey: String?
    /// Point-in-time display snapshot of the variety name.
    var varietyName: String
    /// Destination / use (winery name for Own Use, optional for external).
    var destinationName: String?
    var quantityTonnes: Double
    var notes: String?
    // External (Sale / Commitment) only — always nil for Own Use.
    /// Link to a saved `GrapePurchaser` (sql/219). Optional: legacy
    /// allocations carry only the snapshot fields below.
    var purchaserId: UUID?
    /// Historical SNAPSHOT of the purchaser details at commitment time —
    /// later edits to the saved purchaser never rewrite these.
    var purchaserName: String?
    var contactName: String?
    var contactEmail: String?
    var contactPhone: String?
    var contactAddress: String?
    /// Owner/manager only — merged from the financial companion; nil for
    /// other roles and for Own Use.
    var pricePerTonne: Double?
    var blocks: [GrapeAllocationBlock]
    var updatedAt: Date?

    init(
        id: UUID = UUID(),
        vineyardId: UUID,
        vintage: Int,
        allocationType: GrapeAllocationType,
        varietyId: UUID? = nil,
        varietyKey: String? = nil,
        varietyName: String,
        destinationName: String? = nil,
        quantityTonnes: Double,
        notes: String? = nil,
        purchaserId: UUID? = nil,
        purchaserName: String? = nil,
        contactName: String? = nil,
        contactEmail: String? = nil,
        contactPhone: String? = nil,
        contactAddress: String? = nil,
        pricePerTonne: Double? = nil,
        blocks: [GrapeAllocationBlock] = [],
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.vintage = vintage
        self.allocationType = allocationType
        self.varietyId = varietyId
        self.varietyKey = varietyKey
        self.varietyName = varietyName
        self.destinationName = destinationName
        self.quantityTonnes = quantityTonnes
        self.notes = notes
        self.purchaserId = purchaserId
        self.purchaserName = purchaserName
        self.contactName = contactName
        self.contactEmail = contactEmail
        self.contactPhone = contactPhone
        self.contactAddress = contactAddress
        self.pricePerTonne = pricePerTonne
        self.blocks = blocks
        self.updatedAt = updatedAt
    }

    /// Individual contract value: this contract's tonnes × ITS $/t. Totals
    /// are sums of these — never an averaged $/t.
    var contractValue: Double? {
        guard allocationType == .external, let price = pricePerTonne else { return nil }
        return quantityTonnes * price
    }
}
