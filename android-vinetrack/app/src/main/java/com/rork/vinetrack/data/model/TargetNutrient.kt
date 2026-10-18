package com.rork.vinetrack.data.model

import kotlin.math.floor

/** Local-only Portal c7be056 target nutrient engine. No record or product writes. */
object TargetNutrient {
    val nutrients = listOf("N" to "Nitrogen", "P" to "Phosphorus", "K" to "Potassium", "Ca" to "Calcium", "Mg" to "Magnesium", "S" to "Sulfur", "Fe" to "Iron", "Mn" to "Manganese", "Zn" to "Zinc", "Cu" to "Copper", "B" to "Boron", "Mo" to "Molybdenum", "Cl" to "Chlorine", "Si" to "Silicon", "Co" to "Cobalt", "other" to "Other")
    val oxideKeys = setOf("P", "K", "Ca", "Mg", "S", "Si", "B", "Fe", "Mn", "Zn", "Cu", "Mo", "Co", "other")
    fun canPreview(isSystemAdmin: Boolean) = isSystemAdmin
    fun canSave(mode: String) = mode in setOf("perHectare", "perVine")
    fun number(text: String): Double? = text.replace(',', '.').toDoubleOrNull()?.takeIf { it.isFinite() }
    data class Draft(
        val nutrient: String = "N", val otherName: String = "", val percent: String = "", val target: String = "",
        val perVine: Boolean = true, val analysisBasis: String = "elemental", val concentrationBasis: String = "unknown",
        val density: String = "", val densityReference: String = "",
    ) {
        fun selectNutrient(key: String) = copy(nutrient = key, analysisBasis = if (key in oxideKeys) "unknown" else "elemental")
    }
    data class Result(val rate: Double?, val rateUnit: String, val totalProduct: Double?, val productUnit: String, val totalNutrientKg: Double?, val issues: List<String>)

    /** Unknown/oxide never produces elemental output; missing density offers mass only. */
    fun calculate(draft: Draft, liquid: Boolean, vines: Int?, areaHa: Double?): Result {
        val issues = mutableListOf<String>()
        val percent = number(draft.percent) ?: 0.0
        val target = number(draft.target) ?: 0.0
        if (percent <= 0 || percent > 100) issues += "Enter a nutrient percentage greater than 0 and no more than 100."
        if (target <= 0) issues += "Enter a target nutrient quantity greater than zero."
        if (draft.nutrient == "other" && draft.otherName.isBlank()) issues += "Enter the nutrient name."
        if (draft.analysisBasis != "elemental") issues += "Confirm an elemental percentage. Oxide-labelled analysis is not converted to actual nutrient in this preview."
        if (liquid && draft.concentrationBasis !in setOf("w/w", "w/v")) issues += "Confirm w/w or w/v from the product label. Legacy percentages have no verified concentration basis."
        if (!liquid && draft.concentrationBasis == "w/v") issues += "Weight/volume analysis requires a liquid product."
        val valid = issues.isEmpty()
        val density = number(draft.density)?.takeIf { it > 0 && draft.densityReference.isNotBlank() }
        val volume = liquid && (draft.concentrationBasis == "w/v" || density != null)
        val missingDensity = liquid && draft.concentrationBasis == "w/w" && density == null
        if (missingDensity) issues += "Documented density (kg/L) and its label or technical-sheet source are needed to show litres. Required product mass is shown instead."
        val quantity = if (draft.perVine) vines?.takeIf { it > 0 }?.let { it / 1000.0 } else areaHa?.takeIf { it.isFinite() && it > 0 }
        if (quantity == null) issues += if (draft.perVine) "Select blocks with available vine counts or enter a positive whole vine count." else "Select blocks with usable area or enter a positive treated area."
        val nutrient = if (valid) quantity?.let { target * it } else null
        val divisor = percent / 100 * if (volume && draft.concentrationBasis == "w/w") density ?: 1.0 else 1.0
        val rate = if (valid && !missingDensity) target / divisor else null
        val total = if (valid) nutrient?.div(divisor) else null
        fun rounded(value: Double?) = value?.takeIf { (it * 1000).isFinite() }?.let { floor(it * 1000 + 0.5) / 1000 }
        return Result(rounded(rate), if (draft.perVine) (if (liquid) "mL/vine" else "g/vine") else (if (liquid) "L/ha" else "kg/ha"), rounded(total), if (volume) "L" else "kg", rounded(nutrient), issues)
    }
}
