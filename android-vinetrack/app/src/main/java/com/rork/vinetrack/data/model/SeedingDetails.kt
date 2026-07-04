package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Structured Seeding Details payload attached to a [Trip] when the trip is a
 * seeding job. Persisted as JSONB at `trips.seeding_details` (sql/038),
 * mirroring the iOS `SeedingDetails` contract. All nested keys are snake_case
 * and every field is optional so old/empty records stay readable.
 */
@Serializable
data class SeedingBox(
    @SerialName("mix_name") val mixName: String? = null,
    @SerialName("rate_per_ha") val ratePerHa: Double? = null,
    @SerialName("shutter_slide") val shutterSlide: String? = null,
    @SerialName("bottom_flap") val bottomFlap: String? = null,
    @SerialName("metering_wheel") val meteringWheel: String? = null,
    @SerialName("seed_volume_kg") val seedVolumeKg: Double? = null,
    @SerialName("gearbox_setting") val gearboxSetting: Double? = null,
) {
    val hasAnyValue: Boolean
        get() = !mixName.isNullOrBlank() ||
            ratePerHa != null ||
            !shutterSlide.isNullOrBlank() ||
            !bottomFlap.isNullOrBlank() ||
            !meteringWheel.isNullOrBlank() ||
            seedVolumeKg != null ||
            gearboxSetting != null

    /**
     * Stricter than [hasAnyValue] — ignores default shutter/flap/wheel settings
     * so an empty box isn't treated as a useful previous setup just because
     * defaults were persisted (iOS `SeedingBox.hasMeaningfulValue` parity).
     */
    val hasMeaningfulValue: Boolean
        get() = !mixName.isNullOrBlank() ||
            (ratePerHa ?: 0.0) > 0 ||
            (seedVolumeKg ?: 0.0) > 0 ||
            (gearboxSetting ?: 0.0) > 0
}

@Serializable
data class SeedingMixLine(
    val id: String,
    val name: String? = null,
    @SerialName("percent_of_mix") val percentOfMix: Double? = null,
    @SerialName("seed_box") val seedBox: String? = null,
    @SerialName("kg_per_ha") val kgPerHa: Double? = null,
    @SerialName("supplier_manufacturer") val supplierManufacturer: String? = null,
    /** Optional link into the shared Saved Inputs library. */
    @SerialName("saved_input_id") val savedInputId: String? = null,
    @SerialName("input_type") val inputType: String? = null,
    val unit: String? = null,
    /** Total amount used on this trip in [unit]. */
    @SerialName("amount_used") val amountUsed: Double? = null,
    /** Cost-per-unit snapshot at recording time. Null = not configured. */
    @SerialName("cost_per_unit") val costPerUnit: Double? = null,
) {
    val hasAnyValue: Boolean
        get() = !name.isNullOrBlank() ||
            percentOfMix != null ||
            !seedBox.isNullOrBlank() ||
            kgPerHa != null ||
            !supplierManufacturer.isNullOrBlank() ||
            savedInputId != null ||
            amountUsed != null ||
            costPerUnit != null
}

@Serializable
data class SeedingDetails(
    @SerialName("front_box") val frontBox: SeedingBox? = null,
    @SerialName("back_box") val backBox: SeedingBox? = null,
    @SerialName("sowing_depth_cm") val sowingDepthCm: Double? = null,
    @SerialName("mix_lines") val mixLines: List<SeedingMixLine>? = null,
) {
    /** True when at least one field has a meaningful value entered. */
    val hasAnyValue: Boolean
        get() = frontBox?.hasAnyValue == true ||
            backBox?.hasAnyValue == true ||
            sowingDepthCm != null ||
            mixLines?.any { it.hasAnyValue } == true

    /**
     * True only when at least one genuinely useful, operator-entered value
     * exists — default-only box settings do NOT count (iOS parity). Gates the
     * "Copy from previous seeding job" quality note on the Start Trip sheet.
     */
    val hasMeaningfulValue: Boolean
        get() = frontBox?.hasMeaningfulValue == true ||
            backBox?.hasMeaningfulValue == true ||
            (sowingDepthCm ?: 0.0) > 0 ||
            mixLines?.any { it.hasAnyValue } == true
}

/**
 * Returns [lines] with any missing `percentOfMix` populated from `kgPerHa` as a
 * percentage of the total kg/ha for the same seed box. Operator-entered
 * percentages are preserved unchanged (iOS `fillCalculatedPercentOfMix` parity).
 */
fun fillCalculatedPercentOfMix(lines: List<SeedingMixLine>): List<SeedingMixLine> {
    if (lines.isEmpty()) return lines
    val totals = mutableMapOf<String, Double>()
    for (line in lines) {
        val kg = line.kgPerHa ?: continue
        if (kg <= 0) continue
        val key = line.seedBox?.takeIf { it.isNotEmpty() } ?: "_unspecified"
        totals[key] = (totals[key] ?: 0.0) + kg
    }
    return lines.map { line ->
        val kg = line.kgPerHa
        if (line.percentOfMix == null && kg != null && kg > 0) {
            val key = line.seedBox?.takeIf { it.isNotEmpty() } ?: "_unspecified"
            val total = totals[key]
            if (total != null && total > 0) {
                val pct = (kg / total) * 100.0
                line.copy(percentOfMix = kotlin.math.round(pct * 10) / 10)
            } else {
                line
            }
        } else {
            line
        }
    }
}
