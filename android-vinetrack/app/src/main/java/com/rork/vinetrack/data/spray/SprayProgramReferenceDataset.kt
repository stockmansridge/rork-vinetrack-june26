package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.GrowthStage
import com.rork.vinetrack.data.model.chemicalUnitFromBase
import com.rork.vinetrack.data.chemical.SprayRegisteredUseRates
import com.rork.vinetrack.data.chemical.SprayRateOrigin
import java.math.BigDecimal

data class SprayProgramReferenceRow(
    val stage: String, val description: String, val name: String, val targets: String,
    val method: String, val equipment: String, val product: String, val rate: String, val notes: String,
) {
    val cells: List<String> get() = listOf(stage, description, name, targets, method, equipment, product, rate, notes)
}

/** Configuration only, identical PDF and CSV dataset; no calculated doses or operational fields. */
object SprayProgramReferenceDataset {
    const val FOOTER = "Program reference only. Always follow the current product label and registration. Application quantities are determined when the spray is planned."
    val headers = listOf("E-L stage", "Growth-stage description", "Program Step", "Targets / purpose", "Application method", "Spray unit", "Product", "Programmed / registered rate", "Program notes / instructions")

    fun rate(product: SprayChemical, step: SprayRecord, chemicals: List<SavedChemical>, targetLabels: Map<String, String>): String {
        val basis = SprayProductRateBasis.legacy(product.rateBasis)
            ?: if (product.ratePerHa <= 0 && product.ratePer100L > 0) SprayProductRateBasis.PER_100_LITRES else SprayProductRateBasis.WHOLE_BLOCK_AREA
        val value = if (basis == SprayProductRateBasis.PER_100_LITRES) product.ratePer100L else product.ratePerHa
        if (value.isFinite() && value > 0) {
            val unit = when (product.unit) { "Litres" -> "L"; "Kg" -> "kg"; else -> product.unit }
            val suffix = if (basis == SprayProductRateBasis.TREATED_AREA) "/treated ha" else basis.rateSuffix
            val number = BigDecimal.valueOf(chemicalUnitFromBase(product.unit, value)).stripTrailingZeros()
            return "${number.setScale(maxOf(2, number.scale())).toPlainString()} $unit$suffix"
        }
        val matches = chemicals.filter {
            if (product.savedChemicalId != null) it.id == product.savedChemicalId
            else SprayProgramProgression.normalizedName(it.name) == SprayProgramProgression.normalizedName(product.name)
        }
        val chemical = matches.singleOrNull() ?: return ""
        val targets = SprayTargetVocabulary.tags(step.targets.orEmpty(), null, targetLabels)
            .map { SprayProgramProgression.normalizedName(it.label) }.toSet()
        if (targets.isEmpty()) return ""
        return SprayRegisteredUseRates.vineyardRates(chemical).filter { rate ->
            rate.origin == SprayRateOrigin.REGISTERED_USE && rate.preset == null && rate.isSelectable &&
                chemical.registeredUses.orEmpty().any { use -> use.isViticultural && (use.directionId ?: use.id) == rate.registeredUseId } &&
                SprayProgramProgression.normalizedName(rate.targetRaw.orEmpty()) in targets
        }.map { "${it.targetRaw.orEmpty()}${it.label.takeIf { label -> label.isNotBlank() }?.let { label -> " — $label" }.orEmpty()}: ${it.labelRangeText ?: it.displayText}${it.condition?.let { condition -> " ($condition)" }.orEmpty()} (registered)" }
            .distinct().sorted().joinToString("; ")
    }

    fun rows(steps: List<SprayRecord>, chemicals: List<SavedChemical>, unitNames: Map<String, String> = emptyMap(), targetLabels: Map<String, String> = emptyMap()): List<SprayProgramReferenceRow> =
        steps.sortedWith(compareBy<SprayRecord> { SprayProgramProgression.stage(it) ?: Int.MAX_VALUE }.thenBy { it.displayLabel }).flatMap { step ->
            val products = step.tanks.orEmpty().flatMap { it.chemicals }.filter { it.name.isNotBlank() }
                .distinctBy { listOf(it.savedChemicalId, it.name, it.unit, it.rateBasis, it.ratePerHa, it.ratePer100L) }
            val lines: List<SprayChemical?> = if (products.isEmpty()) listOf(null) else products
            val stage = SprayProgramProgression.stage(step)
            lines.map { product -> SprayProgramReferenceRow(
                stage = stage?.let { "EL$it" } ?: "Other Program Steps",
                description = stage?.let { GrowthStage.byCode("EL$it")?.displayName }.orEmpty(),
                name = step.displayLabel,
                targets = SprayTargetVocabulary.tags(step.targets.orEmpty(), null, targetLabels).joinToString(" · ") { it.label },
                method = step.operationType.orEmpty(), equipment = unitNames[step.sprayEquipmentId] ?: step.equipmentType.orEmpty(),
                product = product?.name.orEmpty(), rate = product?.let { rate(it, step, chemicals, targetLabels) }.orEmpty(), notes = step.notes.orEmpty(),
            ) }
        }

    fun csv(rows: List<SprayProgramReferenceRow>): String =
        (listOf(headers) + rows.map { it.cells }).joinToString("\r\n") { row ->
            row.joinToString(",") { "\"${it.replace("\"", "\"\"")}\"" }
        } + "\r\n"
}
