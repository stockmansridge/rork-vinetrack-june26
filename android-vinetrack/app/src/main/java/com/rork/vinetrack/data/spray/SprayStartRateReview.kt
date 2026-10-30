package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.model.chemicalUnitFromBase
import java.math.BigDecimal

object SprayStartRateReview {
    fun basis(product: SprayChemical): SprayProductRateBasis = SprayProductRateBasis.legacy(product.rateBasis)
        ?: if (product.ratePerHa <= 0 && product.ratePer100L > 0) SprayProductRateBasis.PER_100_LITRES
        else SprayProductRateBasis.WHOLE_BLOCK_AREA

    fun actualRate(product: SprayChemical, waterLitres: Double): Double? {
        fun display(value: Double) = if (product.quantityBasis == "display") value else chemicalUnitFromBase(product.unit, value)
        val value = if (basis(product) == SprayProductRateBasis.PER_100_LITRES) {
            if (!waterLitres.isFinite() || waterLitres <= 0) return null
            display(product.volumePerTank) / waterLitres * 100.0
        } else display(product.ratePerHa)
        return value.takeIf { it.isFinite() && it > 0 }
    }

    fun evidence(tanks: List<SprayTank>): List<String> = listOf("tanks", tanks.size.toString()) + tanks.flatMap { tank ->
        listOf("tank", tank.chemicals.size.toString(), tank.rowApplications.size.toString(), tank.tankNumber.toString(), tank.waterVolume.toString(), tank.sprayRatePerHa.toString(), tank.concentrationFactor.toString()) +
            tank.chemicals.flatMap { product -> listOf(product.savedChemicalId.orEmpty(), product.name, product.unit,
                basis(product).raw, product.ratePerHa.toString(), product.ratePer100L.toString(), product.volumePerTank.toString(), product.quantityBasis ?: "base") } +
            tank.rowApplications.flatMap { listOf(it.startRow.toString(), it.endRow.toString()) }
    }

    fun lines(tanks: List<SprayTank>): List<String> = tanks.flatMap { tank -> tank.chemicals.map { product ->
        val rate = actualRate(product, tank.waterVolume)?.let { BigDecimal.valueOf(it).stripTrailingZeros().toPlainString() } ?: "Needs a valid rate"
        val suffix = when (basis(product)) {
            SprayProductRateBasis.WHOLE_BLOCK_AREA -> "/whole block ha"
            SprayProductRateBasis.TREATED_AREA -> "/treated ha"
            SprayProductRateBasis.PER_100_LITRES -> "/100 L mixed water"
            SprayProductRateBasis.PER_100_METRES -> "/100 m"
        }
        "${product.name}: $rate ${product.unit}$suffix"
    } }.distinct()

    fun isReviewable(tanks: List<SprayTank>): Boolean = tanks.isNotEmpty() && tanks.all { tank ->
        tank.waterVolume.isFinite() && tank.waterVolume > 0 && tank.chemicals.isNotEmpty() && tank.chemicals.all { product ->
            product.name.isNotBlank() && product.volumePerTank.isFinite() && product.volumePerTank > 0 && actualRate(product, tank.waterVolume) != null
        }
    }
}
