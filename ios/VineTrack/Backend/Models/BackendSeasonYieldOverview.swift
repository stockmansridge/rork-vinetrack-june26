import Foundation

/// The canonical BASE seasonal yield estimate contract
/// (`get_season_yield_base_overview`, sql/221).
///
/// Every figure here is UNDAMAGED. The RPC deliberately takes no
/// `apply_damage` argument — damage is applied on top by
/// ``SeasonYieldDamage`` using the damage records this client loaded for the
/// SAME vineyard and vintage.
///
/// Two totals, and they are not interchangeable:
///  * ``totalBaseEstimateTonnes`` — CANONICAL. `nil` whenever any applicable
///    row is still unconfigured OR any active block has no estimate rows.
///    This is the only figure Grape Allocation may allocate from, and a `nil`
///    must render as "—", never as `0 t`.
///  * ``knownBaseEstimateTonnes`` — DIAGNOSTIC "known so far". Safe to show as
///    partial progress, never safe to allocate from.
nonisolated struct BackendSeasonYieldOverview: Codable, Sendable, Equatable {
    let vineyardId: UUID
    let vintage: Int
    /// Canonical crop total. `nil` = not knowable yet — show "—".
    let totalBaseEstimateTonnes: Double?
    /// What is configured so far. Never use for allocation.
    let knownBaseEstimateTonnes: Double
    let isEstimateComplete: Bool
    /// Count of ACTIVE blocks in the vineyard (the completeness denominator).
    let blocksTotal: Int
    let blocksAvailable: Int
    let blocksUnavailable: Int
    let blocksWithEstimates: Int
    let blocksMissingEstimates: Int
    /// Highest-priority source across the vintage: `pruning`, `bunch_count`,
    /// `manual` or `none`.
    let estimateSource: String
    let calculatedAt: Date?
    let varieties: [BackendSeasonYieldVariety]
    let blocks: [BackendSeasonYieldBlock]
    let sourceInputs: BackendSeasonYieldSourceInputsEnvelope?
    let setupWarnings: [BackendSeasonYieldWarning]

    enum CodingKeys: String, CodingKey {
        case vineyardId = "vineyard_id"
        case vintage
        case totalBaseEstimateTonnes = "total_base_estimate_tonnes"
        case knownBaseEstimateTonnes = "known_base_estimate_tonnes"
        case isEstimateComplete = "is_estimate_complete"
        case blocksTotal = "blocks_total"
        case blocksAvailable = "blocks_available"
        case blocksUnavailable = "blocks_unavailable"
        case blocksWithEstimates = "blocks_with_estimates"
        case blocksMissingEstimates = "blocks_missing_estimates"
        case estimateSource = "estimate_source"
        case calculatedAt = "calculated_at"
        case varieties
        case blocks
        case sourceInputs = "source_inputs"
        case setupWarnings = "setup_warnings"
    }
}

/// One canonical variety line for the vintage.
nonisolated struct BackendSeasonYieldVariety: Codable, Sendable, Equatable, Identifiable {
    var id: String { varietyIdentity }
    /// Stable identity: the variety key when known, else the planting group key.
    let varietyIdentity: String
    let varietyKey: String?
    let varietyName: String?
    let isUnallocated: Bool
    let isEstimateAvailable: Bool
    /// Only true when the WHOLE vineyard is covered — an uncovered block may
    /// be planted to this same variety, which would understate it.
    let isEstimateComplete: Bool
    let knownBaseEstimateTonnes: Double
    let baseEstimateTonnes: Double?
    let paddockIds: [UUID]
    let plantingGroupKeys: [String]

    enum CodingKeys: String, CodingKey {
        case varietyIdentity = "variety_identity"
        case varietyKey = "variety_key"
        case varietyName = "variety_name"
        case isUnallocated = "is_unallocated"
        case isEstimateAvailable = "is_estimate_available"
        case isEstimateComplete = "is_estimate_complete"
        case knownBaseEstimateTonnes = "known_base_estimate_tonnes"
        case baseEstimateTonnes = "base_estimate_tonnes"
        case paddockIds = "paddock_ids"
        case plantingGroupKeys = "planting_group_keys"
    }

    var displayName: String {
        let trimmed = (varietyName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unallocated variety" : trimmed
    }
}

/// One active block. Blocks with NO estimate rows are still listed, with
/// `hasEstimates == false` and a `nil` base — never an invented `0 t`.
nonisolated struct BackendSeasonYieldBlock: Codable, Sendable, Equatable, Identifiable {
    var id: UUID { paddockId }
    let paddockId: UUID
    let blockName: String?
    let areaHectares: Double
    let estimateSource: String
    let isEstimateAvailable: Bool
    let isEstimateComplete: Bool
    /// false = this active block has no estimate rows for the vintage yet.
    let hasEstimates: Bool
    let knownBaseEstimateTonnes: Double
    let baseEstimateTonnes: Double?
    let calculatedAt: Date?
    let sourceInputs: BackendSeasonYieldSourceInputs?
    let setupWarnings: [String]
    let groups: [BackendSeasonYieldGroup]

    enum CodingKeys: String, CodingKey {
        case paddockId = "paddock_id"
        case blockName = "block_name"
        case areaHectares = "area_hectares"
        case estimateSource = "estimate_source"
        case isEstimateAvailable = "is_estimate_available"
        case isEstimateComplete = "is_estimate_complete"
        case hasEstimates = "has_estimates"
        case knownBaseEstimateTonnes = "known_base_estimate_tonnes"
        case baseEstimateTonnes = "base_estimate_tonnes"
        case calculatedAt = "calculated_at"
        case sourceInputs = "source_inputs"
        case setupWarnings = "setup_warnings"
        case groups
    }

    var displayName: String {
        let trimmed = (blockName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Block" : trimmed
    }
}

/// One planting group (variety + clone + rootstock) within a block.
nonisolated struct BackendSeasonYieldGroup: Codable, Sendable, Equatable, Identifiable {
    var id: String { plantingGroupKey }
    let estimateId: UUID?
    let plantingGroupKey: String
    let varietyKey: String?
    let varietyName: String?
    let clone: String?
    let rootstock: String?
    let varietyAllocationIds: [UUID]
    /// The group's share of the block, already reconciled to sum to 100%.
    let allocationPercent: Double
    let isUnallocated: Bool
    let estimateSource: String
    let baseEstimateTonnes: Double?
    let isEstimateAvailable: Bool
    let calculatedAt: Date?
    let sourceSessionId: UUID?
    let setupWarnings: [String]

    enum CodingKeys: String, CodingKey {
        case estimateId = "estimate_id"
        case plantingGroupKey = "planting_group_key"
        case varietyKey = "variety_key"
        case varietyName = "variety_name"
        case clone
        case rootstock
        case varietyAllocationIds = "variety_allocation_ids"
        case allocationPercent = "allocation_percent"
        case isUnallocated = "is_unallocated"
        case estimateSource = "estimate_source"
        case baseEstimateTonnes = "base_estimate_tonnes"
        case isEstimateAvailable = "is_estimate_available"
        case calculatedAt = "calculated_at"
        case sourceSessionId = "source_session_id"
        case setupWarnings = "setup_warnings"
    }

    /// Variety + clone + rootstock, e.g. "Shiraz · MV6 · 101-14".
    var displayName: String {
        let name = (varietyName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = [name.isEmpty ? "Unallocated variety" : name]
        if let clone, !clone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(clone) }
        if let rootstock, !rootstock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(rootstock) }
        return parts.joined(separator: " · ")
    }
}

/// The pruning inputs the DB actually used for a block, recorded for audit and
/// surfaced by the block info button.
nonisolated struct BackendSeasonYieldSourceInputs: Codable, Sendable, Equatable {
    let hasPruningSettings: Bool?
    let pruneMethod: String?
    let bunchesPerBud: Double?
    let budsPerSpur: Double?
    let spursPerVine: Double?
    let budsPerCane: Double?
    let canesPerVine: Double?
    let vinesPerHa: Double?
    let bunchWeightGrams: Double?
    let budsPerVine: Double?
    let vineCount: Double?
    /// `block_vine_count_override` or `block_area_x_vines_per_ha`.
    let vineCountBasis: String?
    let vineCountOverride: Double?
    let areaHectares: Double?
    let blockBaseTonnes: Double?
    let allocationPercentTotalOriginal: Double?
    let allocationPercentTotalFinal: Double?
    let allocationPercentNormalized: Bool?
    let allocationGroupCount: Int?
    let formula: String?

    enum CodingKeys: String, CodingKey {
        case hasPruningSettings = "has_pruning_settings"
        case pruneMethod = "prune_method"
        case bunchesPerBud = "bunches_per_bud"
        case budsPerSpur = "buds_per_spur"
        case spursPerVine = "spurs_per_vine"
        case budsPerCane = "buds_per_cane"
        case canesPerVine = "canes_per_vine"
        case vinesPerHa = "vines_per_ha"
        case bunchWeightGrams = "bunch_weight_grams"
        case budsPerVine = "buds_per_vine"
        case vineCount = "vine_count"
        case vineCountBasis = "vine_count_basis"
        case vineCountOverride = "vine_count_override"
        case areaHectares = "area_hectares"
        case blockBaseTonnes = "block_base_tonnes"
        case allocationPercentTotalOriginal = "allocation_percent_total_original"
        case allocationPercentTotalFinal = "allocation_percent_total_final"
        case allocationPercentNormalized = "allocation_percent_normalized"
        case allocationGroupCount = "allocation_group_count"
        case formula
    }
}

nonisolated struct BackendSeasonYieldSourceInputsEnvelope: Codable, Sendable, Equatable {
    let summary: BackendSeasonYieldSummary?

    enum CodingKeys: String, CodingKey { case summary }
}

nonisolated struct BackendSeasonYieldSummary: Codable, Sendable, Equatable {
    let blocksTotal: Int?
    let blocksAvailable: Int?
    let blocksUnavailable: Int?
    let blocksWithEstimates: Int?
    let blocksMissingEstimates: Int?
    let rowsTotal: Int?
    let rowsAvailable: Int?
    let rowsUnavailable: Int?
    let isEstimateComplete: Bool?
    let damageApplied: Bool?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case blocksTotal = "blocks_total"
        case blocksAvailable = "blocks_available"
        case blocksUnavailable = "blocks_unavailable"
        case blocksWithEstimates = "blocks_with_estimates"
        case blocksMissingEstimates = "blocks_missing_estimates"
        case rowsTotal = "rows_total"
        case rowsAvailable = "rows_available"
        case rowsUnavailable = "rows_unavailable"
        case isEstimateComplete = "is_estimate_complete"
        case damageApplied = "damage_applied"
        case note
    }
}

/// A vineyard-level setup warning, naming the block it belongs to when it has
/// one.
nonisolated struct BackendSeasonYieldWarning: Codable, Sendable, Equatable, Identifiable {
    var id: String { "\(code)-\(paddockId?.uuidString ?? "vineyard")" }
    let code: String
    let paddockId: UUID?
    let blockName: String?

    enum CodingKeys: String, CodingKey {
        case code
        case paddockId = "paddock_id"
        case blockName = "block_name"
    }
}

/// Result of `refresh_pruning_yield_estimates` — reported so a caller can tell
/// "nothing to do" from "wrote 12 rows".
nonisolated struct BackendSeasonYieldRefreshResult: Codable, Sendable, Equatable {
    let vineyardId: UUID?
    let vintage: Int?
    let blocksProcessed: Int?
    let rowsWritten: Int?
    let rowsSkippedHigherPriority: Int?
    let rowsRetired: Int?

    enum CodingKeys: String, CodingKey {
        case vineyardId = "vineyard_id"
        case vintage
        case blocksProcessed = "blocks_processed"
        case rowsWritten = "rows_written"
        case rowsSkippedHigherPriority = "rows_skipped_higher_priority"
        case rowsRetired = "rows_retired"
    }
}

// MARK: - Human-readable warning copy

nonisolated enum SeasonYieldWarningCopy {
    /// Plain-English explanation for a setup warning code, for the block info
    /// sheet and the overview warning list.
    static func text(for code: String) -> String {
        switch code {
        case "estimate_missing_for_active_block":
            return "This block has no estimate for the vintage yet. Save its Pruning Yield Calculator settings to include it."
        case "estimate_incomplete":
            return "The crop total isn't usable yet — at least one block is still missing an estimate or an input."
        case "no_estimates_for_vintage":
            return "No blocks have been estimated for this vintage yet."
        case "missing_pruning_settings":
            return "No Pruning Yield Calculator settings saved for this block."
        case "missing_canes_per_vine":
            return "Canes per vine is missing."
        case "missing_buds_per_cane":
            return "Buds per cane is missing."
        case "missing_spurs_per_vine":
            return "Spurs per vine is missing."
        case "missing_buds_per_spur":
            return "Buds per spur is missing."
        case "missing_bunches_per_bud":
            return "Bunches per bud is missing."
        case "missing_bunch_weight_grams":
            return "Average bunch weight is missing."
        case "missing_block_area":
            return "This block has no mapped area, so its vine count can't be derived."
        case "missing_vines_per_ha":
            return "Vines per hectare is missing."
        case "missing_vine_count":
            return "The block's vine count can't be determined from the saved inputs."
        case "allocation_percent_invalid":
            return "A variety allocation has an unreadable percentage and was excluded."
        case "allocation_percent_over_100":
            return "A variety allocation is above 100% on its own."
        case "allocation_missing_variety_identity":
            return "A variety allocation has no identifiable variety and was folded into \"Unallocated variety\"."
        case "block_has_no_variety_allocations":
            return "This block has no variety allocations, so the whole block is treated as unallocated."
        case "block_allocations_over_100_normalized":
            return "Variety allocations added up to more than 100% and were scaled back proportionally."
        case "block_allocations_under_100":
            return "Variety allocations add up to less than 100%; the remainder is \"Unallocated variety\"."
        case SeasonYieldDamage.warningRecordWithoutPolygon:
            return "A damage record has no valid mapped area and was excluded from the damage calculation."
        case SeasonYieldDamage.warningBlockAreaUnavailable:
            return "This block has no mapped area, so recorded damage can't be applied to it."
        default:
            return code.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
