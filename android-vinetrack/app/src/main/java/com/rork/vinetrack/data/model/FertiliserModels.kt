package com.rork.vinetrack.data.model

import kotlinx.serialization.Serializable

/**
 * Unified saved-product categories (`saved_chemicals.product_category`,
 * sql/111). The shared library covers spray chemicals AND fertiliser/nutrient
 * products. Keys match the iOS `ProductCategory` cases and are shared with the
 * portal. "" = uncategorised — every legacy spray chemical.
 */
object ProductCategories {
    val all: List<Pair<String, String>> = listOf(
        "fungicide" to "Fungicide",
        "insecticide" to "Insecticide",
        "herbicide" to "Herbicide",
        "adjuvant" to "Adjuvant",
        "growthRegulator" to "Growth regulator",
        "foliarNutrient" to "Foliar nutrient",
        "granularFertiliser" to "Granular fertiliser",
        "liquidFertiliser" to "Liquid fertiliser",
        "fertigation" to "Fertigation product",
        "compost" to "Compost",
        "manure" to "Manure",
        "biofertiliser" to "Biofertiliser",
        "compostTea" to "Compost tea",
        "seaweed" to "Seaweed",
        "fishHydrolysate" to "Fish hydrolysate",
        "humicFulvic" to "Humic / fulvic product",
        "soilAmendment" to "Soil amendment",
        "other" to "Other",
    )

    /** Categories the Fertiliser Calculator shows by default. */
    val fertiliserKeys: Set<String> = setOf(
        "foliarNutrient", "granularFertiliser", "liquidFertiliser", "fertigation",
        "compost", "manure", "biofertiliser", "compostTea", "seaweed",
        "fishHydrolysate", "humicFulvic", "soilAmendment",
    )

    fun label(key: String): String =
        all.firstOrNull { it.first == key }?.second ?: (key.takeIf { it.isNotBlank() } ?: "Uncategorised")

    fun isFertiliser(key: String): Boolean = key in fertiliserKeys
}

/**
 * Fertiliser view of a shared saved product ([SavedChemical], sql/111). The
 * Fertiliser Calculator reads its product library from the saved chemical
 * database — these helpers derive the fertiliser-specific values.
 */
val SavedChemical.isFertiliserProduct: Boolean
    get() = ProductCategories.isFertiliser(productCategory)

/** Solid/liquid for fertiliser maths — explicit form first, unit fallback. */
val SavedChemical.isFertiliserLiquid: Boolean
    get() = when (productForm) {
        "liquid" -> true
        "solid" -> false
        else -> unit == "Litres" || unit == "mL"
    }

val SavedChemical.fertiliserUnit: String get() = if (isFertiliserLiquid) "L" else "kg"
val SavedChemical.fertiliserPerVineUnit: String get() = if (isFertiliserLiquid) "mL" else "g"

/** Short N-P-K summary, e.g. "N 20 · P 5 · K 10"; null when no analysis stored. */
val SavedChemical.analysisSummary: String?
    get() {
        fun trim(value: Double): String =
            if (value % 1.0 == 0.0) value.toInt().toString() else "%.1f".format(value)
        val parts = mutableListOf<String>()
        nitrogenPercent?.takeIf { it > 0 }?.let { parts.add("N ${trim(it)}") }
        phosphorusPercent?.takeIf { it > 0 }?.let { parts.add("P ${trim(it)}") }
        potassiumPercent?.takeIf { it > 0 }?.let { parts.add("K ${trim(it)}") }
        return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
    }

/**
 * A saved calculation — either a planned work task ("planned") or a completed
 * fertiliser application record ("completed"). Mode is "perHectare" or
 * "perVine". `productId` references the shared saved chemical/product library
 * (`saved_chemicals.id`); `productName`, `form` and `packSize` are historical
 * snapshots taken at calculation time. Mirrors the iOS `FertiliserRecord`.
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
