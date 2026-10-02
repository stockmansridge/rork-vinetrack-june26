package com.rork.vinetrack.ui.screens

import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.chemicalUnitFromBase
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import java.util.Locale

/** Display-only projection of stored configuration; never reads application quantities or canopy. */
internal object SprayProgramStepPresentation {
    fun name(record: SprayRecord): String =
        record.sprayReference?.trim()?.takeIf { it.isNotEmpty() } ?: "Untitled Program Step"

    /** Collapse repeated tank copies only when product identity, unit and programmed rates all agree. */
    fun products(record: SprayRecord): List<SprayChemical> = record.tanks.orEmpty()
        .flatMap { it.chemicals }
        .filter { it.name.isNotBlank() }
        .distinctBy {
            listOf(
                it.savedChemicalId, it.name.trim().lowercase(Locale.ROOT),
                it.chemicalSnapshot?.registrationIdentityKey, it.unit, it.rateBasis,
                it.ratePerHa, it.ratePer100L,
            )
        }

    /** Stored base units are restated in the saved product unit, without changing the rate denominator. */
    fun rate(product: SprayChemical): String? {
        val basis = SprayProductRateBasis.legacy(product.rateBasis)
            ?: if (product.ratePerHa <= 0 && product.ratePer100L > 0) {
                SprayProductRateBasis.PER_100_LITRES
            } else {
                SprayProductRateBasis.WHOLE_BLOCK_AREA
            }
        val base = if (basis == SprayProductRateBasis.PER_100_LITRES) product.ratePer100L else product.ratePerHa
        if (!base.isFinite() || base <= 0) return null
        val unit = when (product.unit) {
            "Litres" -> "L"
            "Kg" -> "kg"
            else -> product.unit
        }
        val suffix = if (basis == SprayProductRateBasis.TREATED_AREA) "/treated ha" else basis.rateSuffix
        // Keep the stored basis even when the regional area preference differs.
        return "${String.format(Locale.US, "%.2f", chemicalUnitFromBase(product.unit, base))} $unit$suffix"
    }
}
