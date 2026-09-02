import Foundation

/// Joins the canonical BASE estimate contract (`get_season_yield_base_overview`,
/// sql/221) with the client-side area-weighted damage engine
/// (``SeasonYieldDamage``) to produce everything the yield surfaces display.
///
/// Mirrored by `SeasonYieldProjection.kt` on Android.
///
/// Two rules run through the whole file:
///
///  1. **Damage is applied per BLOCK, then aggregated.** A block's loss
///     fraction is computed once from its own damage records and its own area,
///     then applied to each of that block's planting groups. Variety and
///     vineyard totals are sums of the already-adjusted block figures — a
///     vineyard-wide loss fraction is never computed, and block fractions are
///     never blended.
///  2. **Incomplete means unknown, not zero.** Any canonical figure the DB
///     withheld (`nil`) stays `nil` all the way to the UI, which renders "—".
///     Only ``knownBaseTonnes`` / ``knownAdjustedTonnes`` describe partial
///     progress, and they are never allocatable.
nonisolated enum SeasonYieldProjection {

    // MARK: - Rows

    nonisolated struct GroupRow: Sendable, Equatable, Identifiable {
        var id: String { plantingGroupKey }
        let plantingGroupKey: String
        /// Matches the contract's `variety_identity` so variety aggregation
        /// here and in SQL group the same rows together.
        let varietyIdentity: String
        let displayName: String
        let allocationPercent: Double
        let isEstimateAvailable: Bool
        let baseTonnes: Double?
        /// Base × the BLOCK's remaining-yield multiplier. `nil` mirrors base.
        let adjustedTonnes: Double?
    }

    nonisolated struct BlockRow: Sendable, Equatable, Identifiable {
        var id: UUID { paddockId }
        let paddockId: UUID
        let name: String
        let areaHectares: Double
        /// false = active block with no estimate rows for the vintage yet.
        let hasEstimates: Bool
        let isEstimateComplete: Bool
        let estimateSource: String
        let calculatedAt: Date?
        /// Canonical block base. `nil` = incomplete, show "—".
        let baseTonnes: Double?
        let knownBaseTonnes: Double
        let adjustedTonnes: Double?
        let knownAdjustedTonnes: Double
        /// Always computed, even when Apply Damage is off, so the info sheet
        /// can show what damage WOULD do.
        let damage: SeasonYieldDamage.BlockDamage
        let warnings: [String]
        let groups: [GroupRow]
        let sourceInputs: BackendSeasonYieldSourceInputs?

        /// Tonnes removed by damage, when both a base and damage exist.
        var damageReductionTonnes: Double? {
            guard let baseTonnes else { return nil }
            return baseTonnes - (adjustedTonnes ?? baseTonnes)
        }
    }

    nonisolated struct VarietyRow: Sendable, Equatable, Identifiable {
        var id: String { varietyIdentity }
        let varietyIdentity: String
        let varietyKey: String?
        let displayName: String
        let isUnallocated: Bool
        /// Only true when the WHOLE vineyard is covered.
        let isEstimateComplete: Bool
        let baseTonnes: Double?
        let knownBaseTonnes: Double
        let adjustedTonnes: Double?
        let knownAdjustedTonnes: Double
        let paddockIds: [UUID]
    }

    // MARK: - Result

    nonisolated struct Result: Sendable, Equatable {
        let vineyardId: UUID
        let vintage: Int
        let damageApplied: Bool
        let isEstimateComplete: Bool
        /// The ONLY allocatable crop total. `nil` = show "—".
        let totalBaseTonnes: Double?
        let totalAdjustedTonnes: Double?
        /// Diagnostic "known so far" — never allocate from these.
        let knownBaseTonnes: Double
        let knownAdjustedTonnes: Double
        let estimateSource: String
        let calculatedAt: Date?
        let blocksTotal: Int
        let blocksAvailable: Int
        let blocksUnavailable: Int
        let blocksWithEstimates: Int
        let blocksMissingEstimates: Int
        let blocks: [BlockRow]
        let varieties: [VarietyRow]
        let warnings: [BackendSeasonYieldWarning]

        /// The figure a surface should show as "the crop", honouring the
        /// Apply Damage toggle. `nil` = "—".
        var displayTotalTonnes: Double? {
            damageApplied ? totalAdjustedTonnes : totalBaseTonnes
        }

        /// Names of active blocks with no estimate at all, for the "finish
        /// setting these up" prompt.
        var blocksMissingEstimateNames: [String] {
            warnings
                .filter { $0.code == "estimate_missing_for_active_block" }
                .compactMap { $0.blockName }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }

        /// True when any block excluded a damage record for a bad polygon.
        var hasExcludedDamageRecords: Bool {
            blocks.contains { $0.damage.excludedRecordCount > 0 }
        }

        static func empty(vineyardId: UUID, vintage: Int, damageApplied: Bool) -> Result {
            Result(
                vineyardId: vineyardId,
                vintage: vintage,
                damageApplied: damageApplied,
                isEstimateComplete: false,
                totalBaseTonnes: nil,
                totalAdjustedTonnes: nil,
                knownBaseTonnes: 0,
                knownAdjustedTonnes: 0,
                estimateSource: "none",
                calculatedAt: nil,
                blocksTotal: 0,
                blocksAvailable: 0,
                blocksUnavailable: 0,
                blocksWithEstimates: 0,
                blocksMissingEstimates: 0,
                blocks: [],
                varieties: [],
                warnings: []
            )
        }
    }

    // MARK: - Damage record filtering

    /// Damage records for exactly one vineyard AND one vintage.
    ///
    /// The vintage comes from the server-resolved `damage_records.vintage`
    /// whenever it is present; only an unsynced local record falls back to the
    /// device season resolver. Filtering by anything else would let a frost
    /// from last season quietly reduce this season's crop.
    static func damageRecords(
        _ records: [DamageRecord],
        vineyardId: UUID,
        vintage: Int,
        seasonStartMonth: Int,
        seasonStartDay: Int
    ) -> [DamageRecord] {
        records.filter {
            $0.vineyardId == vineyardId
                && $0.resolvedVintage(
                    seasonStartMonth: seasonStartMonth,
                    seasonStartDay: seasonStartDay
                ) == vintage
        }
    }

    // MARK: - Build

    /// Project the contract onto the display model.
    ///
    /// - Parameters:
    ///   - overview: the canonical BASE contract, verbatim from the RPC.
    ///   - damageRecords: damage already filtered to this vineyard AND vintage.
    ///   - applyDamage: the user's Apply Damage toggle. OFF by default, in
    ///     which case adjusted figures equal base figures — but the per-block
    ///     damage verdict is still computed so the info sheet can show it.
    static func make(
        overview: BackendSeasonYieldOverview,
        damageRecords: [DamageRecord],
        applyDamage: Bool
    ) -> Result {
        let engineRecords = damageRecords.map(\.damageEngineRecord)
        let recordsByBlock = Dictionary(grouping: engineRecords, by: \.paddockId)

        var blocks: [BlockRow] = []
        blocks.reserveCapacity(overview.blocks.count)

        // Adjusted tonnes accumulated per variety identity, built from the
        // per-block figures — never recomputed at variety level.
        var adjustedByVariety: [String: Double] = [:]
        var knownAdjustedByVariety: [String: Double] = [:]
        var varietyIncomplete: Set<String> = []

        for block in overview.blocks {
            let damage = SeasonYieldDamage.blockDamage(
                paddockId: block.paddockId,
                blockAreaHectares: block.areaHectares,
                records: recordsByBlock[block.paddockId] ?? []
            )
            // A block whose area is unknown keeps its base figures: the engine
            // returns a zero loss fraction plus the block_area_unavailable
            // warning rather than guessing.
            let multiplier = applyDamage ? damage.remainingYieldMultiplier : 1.0

            var groupRows: [GroupRow] = []
            groupRows.reserveCapacity(block.groups.count)
            var knownAdjustedForBlock = 0.0

            for group in block.groups {
                let identity = varietyIdentity(for: group)
                let base = group.baseEstimateTonnes
                let adjusted = base.map { $0 * multiplier }

                groupRows.append(
                    GroupRow(
                        plantingGroupKey: group.plantingGroupKey,
                        varietyIdentity: identity,
                        displayName: group.displayName,
                        allocationPercent: group.allocationPercent,
                        isEstimateAvailable: group.isEstimateAvailable,
                        baseTonnes: base,
                        adjustedTonnes: adjusted
                    )
                )

                if group.isEstimateAvailable, let adjusted {
                    knownAdjustedForBlock += adjusted
                    knownAdjustedByVariety[identity, default: 0] += adjusted
                    adjustedByVariety[identity, default: 0] += adjusted
                } else {
                    // An unavailable group makes its variety's canonical total
                    // unknowable, exactly as the DB does for the base figure.
                    varietyIncomplete.insert(identity)
                }
            }

            blocks.append(
                BlockRow(
                    paddockId: block.paddockId,
                    name: block.displayName,
                    areaHectares: block.areaHectares,
                    hasEstimates: block.hasEstimates,
                    isEstimateComplete: block.isEstimateComplete,
                    estimateSource: block.estimateSource,
                    calculatedAt: block.calculatedAt,
                    baseTonnes: block.baseEstimateTonnes,
                    knownBaseTonnes: block.knownBaseEstimateTonnes,
                    adjustedTonnes: block.baseEstimateTonnes.map { $0 * multiplier },
                    knownAdjustedTonnes: knownAdjustedForBlock,
                    damage: damage,
                    warnings: block.setupWarnings + damage.warnings,
                    groups: groupRows,
                    sourceInputs: block.sourceInputs
                )
            )
        }

        let isComplete = overview.isEstimateComplete
        let knownAdjustedTotal = blocks.reduce(0.0) { $0 + $1.knownAdjustedTonnes }

        // The canonical adjusted total exists only when the canonical base
        // total does. Summing "what we happen to know" into the headline
        // figure is exactly the bug the DB contract exists to prevent.
        let totalAdjusted: Double? = (isComplete && overview.totalBaseEstimateTonnes != nil)
            ? knownAdjustedTotal
            : nil

        let varieties: [VarietyRow] = overview.varieties.map { variety in
            let identity = variety.varietyIdentity
            let complete = variety.isEstimateComplete && !varietyIncomplete.contains(identity)
            let knownAdjusted = knownAdjustedByVariety[identity] ?? 0
            return VarietyRow(
                varietyIdentity: identity,
                varietyKey: variety.varietyKey,
                displayName: variety.displayName,
                isUnallocated: variety.isUnallocated,
                isEstimateComplete: complete,
                baseTonnes: variety.baseEstimateTonnes,
                knownBaseTonnes: variety.knownBaseEstimateTonnes,
                adjustedTonnes: (complete && variety.baseEstimateTonnes != nil)
                    ? (adjustedByVariety[identity] ?? 0)
                    : nil,
                knownAdjustedTonnes: knownAdjusted,
                paddockIds: variety.paddockIds
            )
        }

        return Result(
            vineyardId: overview.vineyardId,
            vintage: overview.vintage,
            damageApplied: applyDamage,
            isEstimateComplete: isComplete,
            totalBaseTonnes: overview.totalBaseEstimateTonnes,
            totalAdjustedTonnes: totalAdjusted,
            knownBaseTonnes: overview.knownBaseEstimateTonnes,
            knownAdjustedTonnes: knownAdjustedTotal,
            estimateSource: overview.estimateSource,
            calculatedAt: overview.calculatedAt,
            blocksTotal: overview.blocksTotal,
            blocksAvailable: overview.blocksAvailable,
            blocksUnavailable: overview.blocksUnavailable,
            blocksWithEstimates: overview.blocksWithEstimates,
            blocksMissingEstimates: overview.blocksMissingEstimates,
            blocks: blocks,
            varieties: varieties,
            warnings: overview.setupWarnings
        )
    }

    /// `coalesce(nullif(variety_key, ''), planting_group_key)` — identical to
    /// the SQL contract's `variety_identity`.
    static func varietyIdentity(for group: BackendSeasonYieldGroup) -> String {
        let key = (group.varietyKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? group.plantingGroupKey : key
    }
}
