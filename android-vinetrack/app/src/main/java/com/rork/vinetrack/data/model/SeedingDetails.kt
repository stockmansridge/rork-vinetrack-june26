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
}
