package com.rork.vinetrack.data.model

import com.rork.vinetrack.data.SeasonYieldProjection
import java.text.Normalizer
import java.util.Locale

/** Read-only block attribution, intentionally independent of financial block splitting. */
object GrapeAllocationHierarchy {
    // Portal src/lib/varietyResolver.ts, scoped to allocation presentation, not stored identities.
    private val portalNames = listOf(
        "Cabernet Sauvignon" to listOf("cab sauv", "cabernet sauv", "cab", "cabernet"),
        "Cabernet Franc" to listOf("cab franc", "cab frnc", "cab fr", "cabernet fr"),
        "Merlot" to listOf("mer"), "Shiraz" to listOf("syrah"),
        "Pinot Noir" to listOf("pinot n", "p noir", "pn"),
        "Pinot Gris" to listOf("pinot grigio", "pinot gris grigio", "pinot gris / grigio", "p gris", "pg", "pinot_grigio"),
        "Pinot Meunier" to listOf("meunier"), "Chardonnay" to listOf("chard"),
        "Sauvignon Blanc" to listOf("sauv blanc", "savvy b", "sb", "sauvignon b"),
        "Semillon" to listOf("sem", "sémillon"), "Riesling" to listOf("ries"),
        "Gruner Veltliner" to listOf("grüner veltliner", "gruner", "grüner", "gv"),
        "Tempranillo" to listOf("temp"), "Primitivo" to listOf("zinfandel", "zin"),
        "Nebbiolo" to listOf("nebb"), "Sangiovese" to listOf("sangio"), "Grenache" to listOf("garnacha"),
        "Mourvedre" to listOf("mourvèdre", "monastrell", "mataro"), "Viognier" to listOf("vio"),
        "Verdelho" to emptyList(), "Vermentino" to emptyList(), "Marsanne" to emptyList(), "Roussanne" to emptyList(),
        "Petit Verdot" to listOf("pv"), "Malbec" to emptyList(), "Barbera" to emptyList(), "Montepulciano" to emptyList(),
        "Fiano" to emptyList(), "Arneis" to emptyList(), "Gewurztraminer" to listOf("gewürztraminer", "gewurz"),
    )
    private fun builtinKey(raw: String): String = Normalizer.normalize(raw.lowercase(Locale.ROOT), Normalizer.Form.NFKD)
        .replace(Regex("[\\u0300-\\u036f]"), "").replace(Regex("[^a-z0-9]+"), " ").trim()
    private val builtinNames: Map<String, String> = buildMap {
        portalNames.forEach { (name, aliases) -> (listOf(name) + aliases).forEach { put(builtinKey(it), name) } }
    }
    fun varietyKey(raw: String): String = builtinNames[builtinKey(raw)]?.lowercase(Locale.ROOT)
        ?: raw.trim().replace(Regex("\\s+"), " ").lowercase(Locale.ROOT).ifEmpty { "__unspecified__" }
    fun varietyLabel(raw: String): String {
        builtinNames[builtinKey(raw)]?.let { return it }
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return "Unspecified variety"
        return if (trimmed != trimmed.lowercase(Locale.ROOT)) trimmed
        else Regex("\\b\\p{L}").replace(trimmed) { it.value.uppercase(Locale.ROOT) }
    }

    /** Preserve each source before legacy normalization can erase custom punctuation. */
    fun supply(projection: SeasonYieldProjection.Result?): List<GrapeAllocationCalculator.CanonicalSupply> =
        projection?.varieties.orEmpty().map { variety ->
            GrapeAllocationCalculator.CanonicalSupply(varietyKey(variety.displayName), variety.displayName,
                if (projection?.damageApplied == true) variety.adjustedTonnes else variety.baseTonnes,
                if (projection?.damageApplied == true) variety.knownAdjustedTonnes else variety.knownBaseTonnes,
                variety.isEstimateComplete)
        }

    fun varietyRows(supply: List<GrapeAllocationCalculator.CanonicalSupply>, allocations: List<GrapeAllocation>,
                    vineyardId: String?, vintage: Int): List<GrapeAllocationCalculator.CanonicalVarietyRow> {
        val estimates = supply.groupBy { varietyKey(it.displayName) }
        val allocated = allocations.filter { it.vineyardId.equals(vineyardId, true) && it.vintage == vintage && it.deletedAt == null }
            .groupBy { varietyKey(it.varietyName) }
        return (estimates.keys + allocated.keys).map { key ->
            val sources = estimates[key].orEmpty()
            val records = allocated[key].orEmpty()
            GrapeAllocationCalculator.CanonicalVarietyRow(key,
                varietyLabel(sources.firstOrNull()?.displayName ?: records.firstOrNull()?.varietyName.orEmpty()),
                if (sources.isNotEmpty() && sources.all { it.tonnes != null }) sources.sumOf { it.tonnes ?: 0.0 } else null,
                sources.sumOf { it.knownTonnes }, sources.isNotEmpty() && sources.all { it.isEstimateComplete },
                records.filter { !it.isExternal }.sumOf { it.quantityTonnes }, records.filter { it.isExternal }.sumOf { it.quantityTonnes })
        }.sortedWith(compareByDescending<GrapeAllocationCalculator.CanonicalVarietyRow> { it.estimatedTonnes ?: Double.NEGATIVE_INFINITY }
            .thenBy { it.displayName.lowercase(Locale.ROOT) })
    }

    data class Estimate(val paddockId: String, val varietyName: String, val tonnes: Double?)
    data class BlockRow(
        val paddockId: String?,
        val name: String,
        val estimatedTonnes: Double?,
        val ownUseTonnes: Double = 0.0,
        val externalTonnes: Double = 0.0,
        val allocationIds: List<String> = emptyList(),
        val hasUnspecifiedQuantity: Boolean = false,
    ) {
        val key: String get() = paddockId ?: "no-block"
        val allocatedTonnes: Double get() = ownUseTonnes + externalTonnes
        val balanceTonnes: Double? get() = estimatedTonnes?.minus(allocatedTonnes)
    }

    fun estimates(projection: SeasonYieldProjection.Result?): List<Estimate> = projection?.blocks.orEmpty().flatMap { block ->
        block.groups.map { group ->
            Estimate(block.paddockId, group.displayName,
                if (!group.isEstimateAvailable) null else if (projection?.damageApplied == true) group.adjustedTonnes else group.baseTonnes)
        }
    }

    /** Duplicate links merge by UUID. Missing multi-block amounts never get an invented split.
     * A signed residual also reconciles legacy over-assigned records without mutating them. */
    fun rows(
        varietyKey: String, vineyardId: String, vintage: Int,
        allocations: List<GrapeAllocation>, estimates: List<Estimate>, blockNames: Map<String, String>,
    ): List<BlockRow> {
        val rows = linkedMapOf<String, BlockRow>()
        val names = blockNames.mapKeys { it.key.lowercase() }
        fun ensure(id: String?): String {
            val key = id?.lowercase() ?: "no-block"
            rows.getOrPut(key) { BlockRow(id?.lowercase(), if (id == null) "No block specified" else names[key] ?: "Unknown block", null) }
            return key
        }
        val seen = mutableSetOf<String>()
        estimates.filter { varietyKey(it.varietyName) == varietyKey }.forEach { estimate ->
            val key = ensure(estimate.paddockId)
            val row = rows.getValue(key)
            rows[key] = row.copy(estimatedTonnes = if (seen.add(key)) estimate.tonnes
                else if (row.estimatedTonnes != null && estimate.tonnes != null) row.estimatedTonnes + estimate.tonnes else null)
        }
        fun add(id: String?, allocation: GrapeAllocation, tonnes: Double, unspecified: Boolean = false) {
            val key = ensure(id)
            val row = rows.getValue(key)
            rows[key] = row.copy(
                ownUseTonnes = row.ownUseTonnes + if (allocation.isExternal) 0.0 else tonnes,
                externalTonnes = row.externalTonnes + if (allocation.isExternal) tonnes else 0.0,
                allocationIds = (row.allocationIds + allocation.id).distinct(),
                hasUnspecifiedQuantity = row.hasUnspecifiedQuantity || unspecified,
            )
        }
        allocations.filter { it.vineyardId.equals(vineyardId, true) && it.vintage == vintage && it.deletedAt == null && varietyKey(it.varietyName) == varietyKey }.forEach { allocation ->
            val links = allocation.blocks.filter { it.paddockId.isNotBlank() && it.vineyardId.equals(vineyardId, true) && it.allocationId.equals(allocation.id, true) }.groupBy { it.paddockId.lowercase() }
            var assigned = 0.0
            links.forEach { (id, details) ->
                val quantities = details.mapNotNull { it.quantityTonnes }.filter { it.isFinite() }
                val tonnes = if (quantities.isNotEmpty()) quantities.sum() else if (links.size == 1) allocation.quantityTonnes else null
                add(id, allocation, tonnes ?: 0.0, tonnes == null)
                assigned += tonnes ?: 0.0
            }
            val remainder = allocation.quantityTonnes - assigned
            if (remainder != 0.0 || links.isEmpty()) add(null, allocation, remainder)
        }
        return rows.values.sortedWith(compareBy<BlockRow> { it.paddockId == null }.thenBy { it.name.lowercase() }.thenBy { it.key })
    }
}
