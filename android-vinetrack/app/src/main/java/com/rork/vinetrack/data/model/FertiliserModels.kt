package com.rork.vinetrack.data.model

import kotlinx.serialization.Serializable

/**
 * Fertiliser product categories — the library is not just synthetic granular
 * fertilisers. Keys match the iOS `FertiliserCategory` cases.
 */
object FertiliserCategories {
    val all: List<Pair<String, String>> = listOf(
        "compost" to "Compost",
        "manure" to "Manure",
        "biofertiliser" to "Biofertiliser",
        "compostTea" to "Compost tea",
        "seaweed" to "Seaweed",
        "fishHydrolysate" to "Fish hydrolysate",
        "humic" to "Humic products",
        "pelletised" to "Pelletised fertiliser",
        "foliar" to "Foliar nutrition",
        "conventional" to "Conventional fertiliser",
        "other" to "Other amendments",
    )

    fun label(key: String): String = all.firstOrNull { it.first == key }?.second ?: "Other"
}

/**
 * A saved fertiliser product, mirroring the chemical library pattern and the
 * iOS `FertiliserProduct` model. `form` is "solid" or "liquid";
 * `analysisBasis` is "elemental" or "oxide" (P₂O₅/K₂O label values).
 */
@Serializable
data class FertiliserProduct(
    val id: String,
    val vineyardId: String,
    val name: String = "",
    val manufacturer: String = "",
    val form: String = "solid",
    val category: String = "conventional",
    /** Pack size in kg (solid) or L (liquid). */
    val packSize: Double = 25.0,
    val pricePerPack: Double? = null,
    /** kg per litre, for liquid products where relevant. */
    val density: Double? = null,
    val nitrogenPercent: Double? = null,
    val phosphorusPercent: Double? = null,
    val potassiumPercent: Double? = null,
    val analysisBasis: String = "elemental",
    val organicCertified: Boolean = false,
    val applicationNotes: String = "",
    /** Stock on hand, in packs. */
    val inventoryPacks: Double? = null,
) {
    val isLiquid: Boolean get() = form == "liquid"
    val unit: String get() = if (isLiquid) "L" else "kg"
    val perVineUnit: String get() = if (isLiquid) "mL" else "g"

    val analysisSummary: String?
        get() {
            val parts = mutableListOf<String>()
            nitrogenPercent?.takeIf { it > 0 }?.let { parts.add("N ${trim(it)}") }
            phosphorusPercent?.takeIf { it > 0 }?.let { parts.add("P ${trim(it)}") }
            potassiumPercent?.takeIf { it > 0 }?.let { parts.add("K ${trim(it)}") }
            return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
        }

    private fun trim(value: Double): String =
        if (value % 1.0 == 0.0) value.toInt().toString() else "%.1f".format(value)
}

/**
 * A saved calculation — either a planned work task ("planned") or a completed
 * fertiliser application record ("completed"). Mode is "perHectare" or
 * "perVine". Mirrors the iOS `FertiliserRecord`.
 */
/**
 * Per-block share of a multi-block calculation (`fertiliser_record_allocations`),
 * so block-level costing and reporting stay accurate.
 */
@Serializable
data class FertiliserAllocation(
    val id: String,
    val paddockId: String,
    val areaHectares: Double = 0.0,
    val vineCount: Int = 0,
    val rate: Double = 0.0,
    val productRequired: Double = 0.0,
    val allocatedCost: Double? = null,
)

@Serializable
data class FertiliserRecord(
    val id: String,
    val vineyardId: String,
    /** ISO date, yyyy-MM-dd. */
    val date: String,
    val status: String = "planned",
    val mode: String = "perHectare",
    val productId: String? = null,
    val productName: String = "",
    val form: String = "solid",
    val paddockIds: List<String> = emptyList(),
    val blockNames: List<String> = emptyList(),
    val areaHectares: Double = 0.0,
    val vineCount: Int = 0,
    /** kg/ha or L/ha (per-hectare mode); g/vine or mL/vine (per-vine mode). */
    val rate: Double = 0.0,
    /** Total product in kg or L. */
    val totalProduct: Double = 0.0,
    val packSize: Double? = null,
    val productCost: Double? = null,
    val labourMachineryCost: Double? = null,
    val notes: String = "",
    /** Per-block breakdown for multi-block calculations. */
    val allocations: List<FertiliserAllocation> = emptyList(),
    val createdAtMs: Long = 0L,
) {
    val isLiquid: Boolean get() = form == "liquid"
    val unit: String get() = if (isLiquid) "L" else "kg"

    val rateUnit: String
        get() = if (mode == "perVine") {
            if (isLiquid) "mL/vine" else "g/vine"
        } else {
            if (isLiquid) "L/ha" else "kg/ha"
        }

    val totalCost: Double?
        get() = when {
            productCost != null && labourMachineryCost != null -> productCost + labourMachineryCost
            productCost != null -> productCost
            labourMachineryCost != null -> labourMachineryCost
            else -> null
        }
}

/** Pure calculation helpers — mirrors the iOS `FertiliserCalculator`. */
object FertiliserCalc {

    /** Per-hectare mode: required product = treated hectares × rate. */
    fun totalForPerHectare(areaHectares: Double, ratePerHa: Double): Double =
        maxOf(areaHectares, 0.0) * maxOf(ratePerHa, 0.0)

    /** Per-vine mode: total = vines × grams (or mL) per vine, returned in kg (or L). */
    fun totalForPerVine(vineCount: Int, ratePerVine: Double): Double =
        maxOf(vineCount, 0) * maxOf(ratePerVine, 0.0) / 1_000.0

    fun packsRequired(total: Double, packSize: Double): Double? =
        if (packSize > 0) total / packSize else null

    /** Pro-rata product cost for the amount actually used. */
    fun productCost(total: Double, packSize: Double, pricePerPack: Double?): Double? {
        if (pricePerPack == null || packSize <= 0) return null
        return total / packSize * pricePerPack
    }
}
