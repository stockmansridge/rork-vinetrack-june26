package com.rork.vinetrack.data.model

import com.rork.vinetrack.data.YieldVintageReport
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient

/**
 * One grape allocation for a vintage (`public.grape_allocations`, sql/217):
 * Own Use (estate wine, home block…) or an external Sale / Commitment.
 * Mirrors the iOS `GrapeAllocation` contract.
 *
 * NO aggregates are stored — estimated yield, balance and contract values are
 * always derived from the latest Yield Estimate + these rows
 * ([GrapeAllocationCalculator]), so completing a new Bunch Count Trip
 * automatically moves the allocation balance.
 *
 * [pricePerTonne] is owner/manager-only: the server routes it into the
 * RLS-guarded companion table `grape_allocation_financials`, the base column
 * always reads NULL, and it is merged locally from
 * `get_grape_allocation_financials`. Lower roles never receive it.
 */
@Serializable
data class GrapeAllocation(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    /** Season-end vintage year the allocation belongs to (user-chosen). */
    val vintage: Int = 0,
    /** `own_use` or `external`. */
    @SerialName("allocation_type") val allocationType: String = TYPE_OWN_USE,
    @SerialName("variety_id") val varietyId: String? = null,
    @SerialName("variety_key") val varietyKey: String? = null,
    @SerialName("variety_name") val varietyName: String = "",
    @SerialName("destination_name") val destinationName: String? = null,
    @SerialName("quantity_tonnes") val quantityTonnes: Double = 0.0,
    val notes: String? = null,
    @SerialName("purchaser_name") val purchaserName: String? = null,
    @SerialName("contact_name") val contactName: String? = null,
    @SerialName("contact_email") val contactEmail: String? = null,
    @SerialName("contact_phone") val contactPhone: String? = null,
    @SerialName("contact_address") val contactAddress: String? = null,
    /** Merged locally for owner/manager; the base column is always NULL. */
    @SerialName("price_per_tonne") val pricePerTonne: Double? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
    @SerialName("deleted_at") val deletedAt: String? = null,
    /** Block splits merged locally from `grape_allocation_blocks`. */
    @Transient val blocks: List<GrapeAllocationBlock> = emptyList(),
) {
    val isExternal: Boolean get() = allocationType == TYPE_EXTERNAL

    /**
     * Individual contract value: this contract's tonnes × ITS $/t. Totals are
     * sums of these — never an averaged $/t.
     */
    val contractValue: Double?
        get() = if (isExternal && pricePerTonne != null) quantityTonnes * pricePerTonne else null

    companion object {
        const val TYPE_OWN_USE = "own_use"
        const val TYPE_EXTERNAL = "external"
    }
}

/**
 * Optional per-block split of an allocation
 * (`public.grape_allocation_blocks`, sql/217). One allocation may span
 * multiple blocks; assignment is optional.
 */
@Serializable
data class GrapeAllocationBlock(
    val id: String,
    @SerialName("allocation_id") val allocationId: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("paddock_id") val paddockId: String,
    /** Point-in-time snapshot of the block name (no FK — house convention). */
    @SerialName("paddock_name") val paddockName: String = "",
    /** Tonnes assigned to this block; null = unspecified split. */
    @SerialName("quantity_tonnes") val quantityTonnes: Double? = null,
)

/**
 * Owner/manager row from `get_grape_allocation_financials` (42501 for every
 * other role — callers swallow that and show no money).
 */
@Serializable
data class GrapeAllocationFinancialRow(
    @SerialName("allocation_id") val allocationId: String,
    @SerialName("price_per_tonne") val pricePerTonne: Double? = null,
    @SerialName("contract_value") val contractValue: Double? = null,
)

/**
 * Grape Allocation derivations, shared contract with iOS
 * (`GrapeAllocationCalculator` in `GrapeAllocationLogic.swift`) so both
 * platforms pin the same rules:
 *
 *  * Supply comes from the CURRENT Yield Estimate — [YieldVintageReport]'s
 *    latest-completed-trip rows — never from a second stored source, so a
 *    newly completed Bunch Count Trip automatically moves every balance.
 *  * A block-level estimate is split across the block's variety allocations
 *    by percent share (the `varietyArea` share rule).
 *  * Balance = Estimated − Own Use − External; a NEGATIVE balance is a
 *    Shortfall, never clamped.
 *  * Money: every contract's value is tonnes × THAT contract's $/t, and
 *    totals are sums of individual contract values — an averaged $/t is
 *    never used.
 */
object GrapeAllocationCalculator {

    /** Tolerance below which a negative balance is floating-point noise. */
    const val SHORTFALL_TOLERANCE = 0.0005

    data class VarietySupply(val displayName: String, val tonnes: Double)

    /**
     * Estimated tonnes per canonical variety for the vintage. Each block's
     * latest-trip estimate (`displayTonnes` — damage-respecting) is split
     * across the block's named variety allocations by percent share.
     * Blocks with no named variety fall under "Unspecified".
     */
    fun varietyEstimates(
        estimateRows: List<YieldVintageReport.EstimateRow>,
        paddocks: List<Paddock>,
    ): Map<String, VarietySupply> {
        val paddockById = paddocks.associateBy { it.id.lowercase() }
        val result = mutableMapOf<String, VarietySupply>()

        fun add(name: String, tonnes: Double) {
            val key = canonicalVarietyName(name)
            val existing = result[key]
            result[key] = VarietySupply(existing?.displayName ?: name, (existing?.tonnes ?: 0.0) + tonnes)
        }

        for (row in estimateRows) {
            val allocations = paddockById[row.paddockId.lowercase()]?.varietyAllocations.orEmpty()
                .filter { !it.displayName.isNullOrBlank() }
            if (allocations.isEmpty()) {
                add("Unspecified", row.displayTonnes)
                continue
            }
            val totalPct = allocations.sumOf { it.displayPercent ?: 0.0 }
            for (allocation in allocations) {
                val share = if (totalPct > 0) (allocation.displayPercent ?: 0.0) / totalPct
                else 1.0 / allocations.size
                add(allocation.displayName ?: "", row.displayTonnes * share)
            }
        }
        return result
    }

    data class VarietyRow(
        /** Canonical (normalised) variety identity used for matching. */
        val varietyKey: String,
        val displayName: String,
        val estimatedTonnes: Double,
        val ownUseTonnes: Double,
        val externalTonnes: Double,
    ) {
        val balanceTonnes: Double get() = estimatedTonnes - ownUseTonnes - externalTonnes
        val isShortfall: Boolean get() = balanceTonnes < -SHORTFALL_TOLERANCE
    }

    /**
     * One row per variety that has an estimate OR an allocation in the
     * vintage, sorted by estimated tonnes descending then name.
     */
    fun varietyRows(
        estimates: Map<String, VarietySupply>,
        allocations: List<GrapeAllocation>,
        vintage: Int,
    ): List<VarietyRow> {
        val names = mutableMapOf<String, String>()
        val own = mutableMapOf<String, Double>()
        val external = mutableMapOf<String, Double>()

        estimates.forEach { (key, value) -> names[key] = value.displayName }
        allocations.filter { it.vintage == vintage }.forEach { allocation ->
            val key = canonicalVarietyName(allocation.varietyName)
            names.getOrPut(key) { allocation.varietyName }
            if (allocation.isExternal) {
                external[key] = (external[key] ?: 0.0) + allocation.quantityTonnes
            } else {
                own[key] = (own[key] ?: 0.0) + allocation.quantityTonnes
            }
        }

        return names.map { (key, displayName) ->
            VarietyRow(
                varietyKey = key,
                displayName = displayName,
                estimatedTonnes = estimates[key]?.tonnes ?: 0.0,
                ownUseTonnes = own[key] ?: 0.0,
                externalTonnes = external[key] ?: 0.0,
            )
        }.sortedWith(
            compareByDescending<VarietyRow> { it.estimatedTonnes }
                .thenBy { it.displayName.lowercase() },
        )
    }

    data class Summary(
        val estimatedTonnes: Double,
        val ownUseTonnes: Double,
        val committedTonnes: Double,
    ) {
        /** Positive = Available, negative = Shortfall. */
        val balanceTonnes: Double get() = estimatedTonnes - ownUseTonnes - committedTonnes
        val isShortfall: Boolean get() = balanceTonnes < -SHORTFALL_TOLERANCE
    }

    fun summary(
        estimates: Map<String, VarietySupply>,
        allocations: List<GrapeAllocation>,
        vintage: Int,
    ): Summary {
        val inVintage = allocations.filter { it.vintage == vintage }
        return Summary(
            estimatedTonnes = estimates.values.sumOf { it.tonnes },
            ownUseTonnes = inVintage.filter { !it.isExternal }.sumOf { it.quantityTonnes },
            committedTonnes = inVintage.filter { it.isExternal }.sumOf { it.quantityTonnes },
        )
    }

    /**
     * Vintage total contracted income: the SUM of individual contract values
     * (tonnes × that contract's $/t). Contracts without a price contribute
     * nothing.
     */
    fun totalContractedIncome(allocations: List<GrapeAllocation>, vintage: Int): Double =
        allocations.filter { it.vintage == vintage }.mapNotNull { it.contractValue }.sum()

    data class IncomeLine(val label: String, val tonnes: Double, val value: Double)

    /** Income grouped by purchaser, individual contract values summed. */
    fun incomeByPurchaser(allocations: List<GrapeAllocation>, vintage: Int): List<IncomeLine> =
        groupIncome(allocations, vintage) { allocation ->
            allocation.purchaserName?.trim().orEmpty().ifEmpty { "Unnamed purchaser" }
        }

    /** Income grouped by variety, individual contract values summed. */
    fun incomeByVariety(allocations: List<GrapeAllocation>, vintage: Int): List<IncomeLine> =
        groupIncome(allocations, vintage) { it.varietyName }

    /**
     * Income attributed to blocks. A contract's value is distributed across
     * its assigned blocks proportionally by the block quantities when given
     * (missing block quantities share the remaining tonnes equally);
     * contracts with no block assignment land under "Unassigned".
     */
    fun incomeByBlock(allocations: List<GrapeAllocation>, vintage: Int): List<IncomeLine> {
        val tonnes = mutableMapOf<String, Double>()
        val values = mutableMapOf<String, Double>()
        allocations.filter { it.vintage == vintage }.forEach { allocation ->
            val price = allocation.pricePerTonne
            if (!allocation.isExternal || price == null) return@forEach
            blockTonnesSplit(allocation).forEach { (label, splitTonnes) ->
                tonnes[label] = (tonnes[label] ?: 0.0) + splitTonnes
                values[label] = (values[label] ?: 0.0) + splitTonnes * price
            }
        }
        return values.map { (label, value) -> IncomeLine(label, tonnes[label] ?: 0.0, value) }
            .sortedWith(compareByDescending<IncomeLine> { it.value }.thenBy { it.label.lowercase() })
    }

    /**
     * Split of a contract's tonnes across its blocks: explicit block
     * quantities are honoured; blocks without a quantity share whatever
     * remains equally (never negative); no blocks = all "Unassigned".
     */
    fun blockTonnesSplit(allocation: GrapeAllocation): List<Pair<String, Double>> {
        if (allocation.blocks.isEmpty()) return listOf("Unassigned" to allocation.quantityTonnes)
        val specified = allocation.blocks.mapNotNull { it.quantityTonnes }.sum()
        val unspecified = allocation.blocks.filter { it.quantityTonnes == null }
        val remainder = (allocation.quantityTonnes - specified).coerceAtLeast(0.0)
        val perUnspecified = if (unspecified.isEmpty()) 0.0 else remainder / unspecified.size
        return allocation.blocks.map { block ->
            val label = block.paddockName.ifBlank { "Block" }
            label to (block.quantityTonnes ?: perUnspecified)
        }
    }

    private fun groupIncome(
        allocations: List<GrapeAllocation>,
        vintage: Int,
        label: (GrapeAllocation) -> String,
    ): List<IncomeLine> {
        val tonnes = mutableMapOf<String, Double>()
        val values = mutableMapOf<String, Double>()
        allocations.filter { it.vintage == vintage }.forEach { allocation ->
            val value = allocation.contractValue ?: return@forEach
            val key = label(allocation)
            tonnes[key] = (tonnes[key] ?: 0.0) + allocation.quantityTonnes
            values[key] = (values[key] ?: 0.0) + value
        }
        return values.map { (key, value) -> IncomeLine(key, tonnes[key] ?: 0.0, value) }
            .sortedWith(compareByDescending<IncomeLine> { it.value }.thenBy { it.label.lowercase() })
    }
}
