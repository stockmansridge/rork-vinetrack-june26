package com.rork.vinetrack.data.spray

import java.text.DecimalFormat

/**
 * Read-only presentation of the operands and results already held by a guided spray plan.
 * This model never feeds the planner, tank construction, or persistence.
 */
data class SprayCalculationReference(
    val canopy: List<Line>,
    val volume: List<Line>,
    val water: List<Line>,
    val products: List<ProductReference>,
) {
    data class Line(
        val id: String,
        val label: String,
        val value: String,
        val workings: String? = null,
    )

    data class ProductReference(
        val id: String,
        val name: String,
        val lines: List<Line>,
    )

    val isEmpty: Boolean
        get() = canopy.isEmpty() && volume.isEmpty() && water.isEmpty() && products.isEmpty()
}

/** Builds display text solely from the existing [SprayGuidedFlow] decision and plan. */
object SprayCalculationReferenceBuilder {
    fun make(flow: SprayGuidedFlow): SprayCalculationReference {
        val plan = flow.plan
        val decision = flow.volumeDecision
        return SprayCalculationReference(
            canopy = canopyLines(decision),
            volume = volumeLines(decision),
            water = waterLines(plan, flow.effectiveCarrierBasis),
            products = productLines(plan, flow.effectiveCarrierBasis),
        )
    }

    private fun canopyLines(decision: SprayVolumeDecision?): List<SprayCalculationReference.Line> {
        val recommendation = decision?.recommendation ?: return emptyList()
        val lines = mutableListOf(
            SprayCalculationReference.Line("canopyType", "Canopy type", recommendation.type.label),
            SprayCalculationReference.Line(
                "canopySize",
                "Canopy size",
                recommendation.size.label,
                recommendation.size.description(recommendation.type),
            ),
            SprayCalculationReference.Line("canopyDensity", "Canopy density", recommendation.density.label),
            SprayCalculationReference.Line(
                "recommendedPer100m",
                "Recommended dilute volume",
                "${trim(recommendation.diluteLitresPer100Metres)} L/100 m",
            ),
        )
        recommendation.rowSpacingMetres?.let { spacing ->
            lines += SprayCalculationReference.Line("rowSpacing", "Row spacing", "${trim(spacing)} m")
        }
        val perHectare = recommendation.diluteLitresPerHectare
        val spacing = recommendation.rowSpacingMetres
        lines += if (perHectare != null && spacing != null) {
            SprayCalculationReference.Line(
                "recommendedPerHa",
                "Recommended per area",
                "${number(perHectare, 1)} L/ha",
                "${trim(recommendation.diluteLitresPer100Metres)} L/100 m × 100 ÷ ${trim(spacing)} m",
            )
        } else {
            SprayCalculationReference.Line(
                "recommendedPerHa",
                "Recommended per area",
                "—",
                "Needs one matching row spacing across the selected blocks",
            )
        }
        return lines
    }

    private fun volumeLines(decision: SprayVolumeDecision?): List<SprayCalculationReference.Line> {
        if (decision?.recommendation == null) return emptyList()
        val selection = when (decision.choice) {
            SprayVolumeChoice.UNDECIDED -> "Not chosen yet"
            SprayVolumeChoice.USE_RECOMMENDED -> "Use recommended"
            SprayVolumeChoice.USE_CUSTOM_SPRAYER_RATE -> "Different sprayer rate"
        }
        val lines = mutableListOf(
            SprayCalculationReference.Line("sprayerSelection", "Sprayer selection", selection),
        )
        decision.actualLitresPerHectare?.let { actual ->
            lines += SprayCalculationReference.Line(
                "actualOutput",
                "Actual sprayer output",
                "${number(actual, 1)} L/ha",
            )
        } ?: decision.actualLitresPer100Metres?.let { actual ->
            lines += SprayCalculationReference.Line(
                "actualOutput",
                "Actual sprayer output",
                "${number(actual, 1)} L/100 m",
            )
        }
        val recommendedHa = decision.recommendedLitresPerHectare
        val actualHa = decision.actualLitresPerHectare
        val recommended100m = decision.recommendedLitresPer100Metres
        val actual100m = decision.actualLitresPer100Metres
        when {
            recommendedHa != null && actualHa != null -> lines += SprayCalculationReference.Line(
                "concentrationFactor",
                "Concentration factor",
                "${number(decision.concentrationFactor, 2)}×",
                "max(1.00, ${number(recommendedHa, 1)} ÷ ${number(actualHa, 1)})",
            )
            recommended100m != null && actual100m != null -> lines += SprayCalculationReference.Line(
                "concentrationFactor",
                "Concentration factor",
                "${number(decision.concentrationFactor, 2)}×",
                "max(1.00, ${number(recommended100m, 1)} ÷ ${number(actual100m, 1)})",
            )
        }
        return lines
    }

    private fun waterLines(
        plan: SprayApplicationPlan,
        selectedBasis: SprayCarrierBasis,
    ): List<SprayCalculationReference.Line> {
        val carrier = plan.carrier
        val treated = plan.treatedAreaHectares ?: plan.grossAreaHectares
        if (selectedBasis == SprayCarrierBasis.MANUAL_TOTAL_VOLUME) {
            val lines = mutableListOf(
                SprayCalculationReference.Line(
                    "totalWater",
                    "Total water",
                    "${number(carrier.totalLitres, 0)} L",
                    "Entered directly — not calculated from a rate or an area",
                ),
                SprayCalculationReference.Line(
                    "treatedArea",
                    "Treated area",
                    "${number(treated, 2)} ha",
                    if (plan.treatedAreaHectares == null) "Whole block area" else "Treated band area",
                ),
            )
            carrier.litresPerHectare?.takeIf { treated > 0.0 }?.let { perHectare ->
                lines += SprayCalculationReference.Line(
                    "impliedPerHa",
                    "Works out to",
                    "${number(perHectare, 1)} L/ha",
                    "${number(carrier.totalLitres, 0)} L ÷ ${number(treated, 2)} ha — for reference only",
                )
            }
            return lines
        }
        val lines = mutableListOf(
            SprayCalculationReference.Line(
                "treatedArea",
                "Treated area",
                "${number(treated, 2)} ha",
                if (plan.treatedAreaHectares == null) "Whole block area" else "Treated band area",
            ),
        )
        val perHectare = carrier.litresPerHectare
        lines += SprayCalculationReference.Line(
            "totalWater",
            "Total water",
            "${number(carrier.totalLitres, 0)} L",
            if (perHectare != null && treated > 0.0) {
                "${number(perHectare, 1)} L/ha × ${number(treated, 2)} ha"
            } else {
                null
            },
        )
        return lines
    }

    private fun productLines(
        plan: SprayApplicationPlan,
        selectedBasis: SprayCarrierBasis,
    ): List<SprayCalculationReference.ProductReference> {
        val factor = plan.carrier.concentrationFactor
        val isManualVolume = selectedBasis == SprayCarrierBasis.MANUAL_TOTAL_VOLUME
        return plan.productLines.map { product ->
            val lines = mutableListOf(
                SprayCalculationReference.Line(
                    "appliedRate",
                    "Applied rate",
                    "${trim(product.rate)} ${product.unit}${product.basis.rateSuffix}",
                ),
            )
            when (product.basis) {
                SprayProductRateBasis.PER_100_LITRES -> {
                    lines += if (isManualVolume) {
                        SprayCalculationReference.Line(
                            "cf",
                            "Concentration factor",
                            "Not used",
                            "Manual spray volume isn't compared to a canopy recommendation",
                        )
                    } else {
                        SprayCalculationReference.Line(
                            "cf",
                            "Concentration factor",
                            "${number(factor, 2)}×",
                        )
                    }
                    product.basisInput?.let { carrier ->
                        lines += SprayCalculationReference.Line(
                            "carrier",
                            "Carrier volume",
                            "${number(carrier, 0)} L",
                        )
                    }
                }
                SprayProductRateBasis.WHOLE_BLOCK_AREA,
                SprayProductRateBasis.TREATED_AREA,
                SprayProductRateBasis.PER_100_METRES,
                -> {
                    product.basisInput?.let { measured ->
                        val decimals = if (product.basis.measuredUnit == "ha") 2 else 0
                        lines += SprayCalculationReference.Line(
                            "measured",
                            "Measured against",
                            "${number(measured, decimals)} ${product.basis.measuredUnit} ${product.basis.measuredNoun}",
                        )
                    }
                    lines += SprayCalculationReference.Line(
                        "cfNotApplied",
                        "Concentration factor",
                        "Not applied",
                        "This rate is measured against ${product.basis.measuredNoun}, not carrier volume",
                    )
                }
            }
            val total = product.totalQuantity
            if (total != null) {
                val workings = product.basisInput?.let { input ->
                    when (product.basis) {
                        SprayProductRateBasis.PER_100_LITRES ->
                            "${trim(product.rate)} × ${number(input, 0)} ÷ 100" +
                                if (!isManualVolume && factor > 1.0) " × ${number(factor, 2)}" else ""
                        SprayProductRateBasis.WHOLE_BLOCK_AREA,
                        SprayProductRateBasis.TREATED_AREA,
                        -> "${trim(product.rate)} × ${number(input, 2)} ${product.basis.measuredUnit}"
                        SprayProductRateBasis.PER_100_METRES ->
                            "${trim(product.rate)} × ${number(input, 0)} ÷ 100"
                    }
                }
                lines += SprayCalculationReference.Line(
                    "total",
                    "Product required",
                    quantity(total, product.unit),
                    workings,
                )
            } else {
                lines += SprayCalculationReference.Line(
                    "total",
                    "Product required",
                    product.unresolvedReason?.title ?: "Unavailable",
                )
            }
            SprayCalculationReference.ProductReference(product.productId, product.name, lines)
        }
    }

    private fun number(value: Double, decimals: Int): String {
        val pattern = if (decimals == 0) "#,##0" else "#,##0.${"0".repeat(decimals)}"
        return DecimalFormat(pattern).format(value)
    }

    private fun trim(value: Double): String = DecimalFormat("#,##0.####").format(value)

    private fun quantity(value: Double, unit: String): String {
        if (unit.equals("mL", ignoreCase = true) && value >= 1000.0) {
            return "${number(value / 1000.0, 2)} L"
        }
        val decimals = when {
            value < 10.0 -> 3
            value < 100.0 -> 2
            else -> 0
        }
        return "${number(value, decimals)} $unit"
    }
}
