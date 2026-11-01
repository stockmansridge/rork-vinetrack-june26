package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.model.chemicalUnitToBase
import java.security.MessageDigest
import java.text.NumberFormat
import java.text.ParsePosition
import java.util.Locale

/** Operator-entered quantities for the tank mixed now. Never modifies the calculated plan. */
data class SprayStartActualAmounts(
    val recipeEvidence: List<String>,
    val tankNumber: Int,
    val waterLitres: Double,
    val chemicalAmountsBase: List<Double>,
) {
    fun amountsFor(tanks: List<SprayTank>): Map<String, Double>? {
        val tank = firstTank(tanks) ?: return null
        if (recipeEvidence != SprayStartRateReview.evidence(tanks) || tankNumber != tank.tankNumber ||
            !waterLitres.isFinite() || waterLitres <= 0 || chemicalAmountsBase.size != tank.chemicals.size ||
            tank.chemicals.map { it.id }.distinct().size != tank.chemicals.size ||
            chemicalAmountsBase.any { !it.isFinite() || it < 0 }) return null
        return tank.chemicals.mapIndexed { index, chemical -> chemical.id to chemicalAmountsBase[index] }.toMap()
    }

    /** Exact trip/tank draft persisted before activation; canonical values survive region changes. */
    fun retainedDraft(tanks: List<SprayTank>): Map<String, String>? {
        val amounts = amountsFor(tanks) ?: return null
        return amounts.mapKeys { (id, _) -> "$CHEMICAL_PREFIX$id" }.mapValues { it.value.toString() } +
            mapOf(WATER_LITRES to waterLitres.toString(), RECIPE_KEY to recipeKey(tanks))
    }

    companion object {
        const val WATER_LITRES = "@waterLitres"
        const val CHEMICAL_PREFIX = "@chemicalBase:"
        const val RECIPE_KEY = "@recipe"

        fun firstTank(tanks: List<SprayTank>): SprayTank? {
            if (tanks.isEmpty() || tanks.any { it.tankNumber <= 0 || it.id.isBlank() } ||
                tanks.map { it.id }.distinct().size != tanks.size ||
                tanks.map { it.tankNumber }.distinct().size != tanks.size) return null
            return tanks.minByOrNull { it.tankNumber }
        }

        fun recipeKey(tanks: List<SprayTank>): String = key(SprayStartRateReview.evidence(tanks))

        /** Length prefixes make the stable key unambiguous even when product names contain separators. */
        fun key(evidence: List<String>): String = MessageDigest.getInstance("SHA-256")
            .digest(evidence.joinToString("") { "${it.length}:$it" }.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

        fun parse(
            tanks: List<SprayTank>,
            text: Map<String, String>,
            waterToLitres: (Double) -> Double = { it },
            locale: Locale = Locale.getDefault(),
        ): SprayStartActualAmounts? {
            val tank = firstTank(tanks) ?: return null
            val water = number(text["water"].orEmpty(), locale)?.let(waterToLitres) ?: return null
            val chemicals = tank.chemicals.mapIndexed { index, chemical ->
                val amount = number(text["chemical:$index"].orEmpty(), locale) ?: return null
                chemicalUnitToBase(chemical.unit, amount)
            }
            return SprayStartActualAmounts(SprayStartRateReview.evidence(tanks), tank.tankNumber, water, chemicals)
                .takeIf { it.amountsFor(tanks) != null }
        }

        fun number(text: String, locale: Locale = Locale.getDefault()): Double? {
            if (text.isBlank() || text != text.trim()) return null
            val position = ParsePosition(0)
            val parsed = NumberFormat.getNumberInstance(locale).parse(text, position)?.toDouble() ?: return null
            if (position.errorIndex >= 0 || position.index != text.length) return null
            return parsed.takeIf { it.isFinite() && it >= 0 }
        }

        fun fromRetainedDraft(tanks: List<SprayTank>, draft: Map<String, String>): SprayStartActualAmounts? {
            val tank = firstTank(tanks) ?: return null
            if (draft[RECIPE_KEY] != recipeKey(tanks)) return null
            val water = draft[WATER_LITRES]?.toDoubleOrNull() ?: return null
            val amounts = tank.chemicals.map { draft["$CHEMICAL_PREFIX${it.id}"]?.toDoubleOrNull() ?: return null }
            return SprayStartActualAmounts(SprayStartRateReview.evidence(tanks), tank.tankNumber, water, amounts)
                .takeIf { it.amountsFor(tanks) != null }
        }

        /** Consume only the exact input that produced a durable confirmation, including later tanks. */
        fun matchesTankDraft(tank: SprayTank, text: Map<String, String>, waterLitres: Double,
            amounts: Map<String, Double>): Boolean {
            if (amounts.keys != tank.chemicals.map { it.id }.toSet()) return false
            if ("water" in text) {
                val locale = text["@locale"]?.let(Locale::forLanguageTag) ?: return false
                val factor = text["@volumeToLitres"]?.toDoubleOrNull()?.takeIf { it.isFinite() && it > 0 } ?: return false
                val water = number(text["water"].orEmpty(), locale)?.times(factor) ?: return false
                if (kotlin.math.abs(water - waterLitres) > 1e-9) return false
                return tank.chemicals.all { chemical ->
                    val entered = number(text[chemical.id].orEmpty(), locale) ?: return@all false
                    chemicalUnitToBase(chemical.unit, entered) == amounts[chemical.id]
                }
            }
            return text[WATER_LITRES]?.toDoubleOrNull() == waterLitres && tank.chemicals.all {
                text["$CHEMICAL_PREFIX${it.id}"]?.toDoubleOrNull() == amounts[it.id]
            }
        }
    }
}
