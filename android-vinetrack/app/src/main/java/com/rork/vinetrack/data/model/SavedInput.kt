package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Reusable vineyard input (seed, fertiliser, compost, biological, soil
 * amendment, etc.) used by seeding / spreading / fertilising trips so a
 * cost-per-unit can be snapshotted onto a trip's mix lines and the
 * [com.rork.vinetrack.data.TripCostEstimator] can compute seed/input cost
 * reliably. Backs `public.saved_inputs` (sql/058), mirroring the iOS
 * `SavedInput` model.
 *
 * Costing is stored in `cost_per_unit` (dollars per [unit]). Null means
 * "not configured" — never treat as $0.
 */
@Serializable
data class SavedInput(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    val name: String = "",
    @SerialName("input_type") val inputType: String = "other",
    val unit: String = "kg",
    @SerialName("cost_per_unit") val costPerUnit: Double? = null,
    val supplier: String? = null,
    val notes: String? = null,
    @SerialName("deleted_at") val deletedAt: String? = null,
) {
    val displayName: String get() = name.trim().takeIf { it.isNotBlank() } ?: "Input"

    /** Human-friendly label for the [inputType] raw value. */
    val inputTypeDisplayName: String get() = savedInputTypeDisplayName(inputType)
}

/** Raw values match the iOS `SavedInputType` enum. */
val savedInputTypes: List<String> = listOf(
    "seed",
    "fertiliser",
    "compost",
    "biological",
    "soil_amendment",
    "other",
)

fun savedInputTypeDisplayName(raw: String): String = when (raw) {
    "seed" -> "Seed"
    "fertiliser" -> "Fertiliser"
    "compost" -> "Compost"
    "biological" -> "Biological"
    "soil_amendment" -> "Soil Amendment"
    else -> "Other"
}

/** Raw values match the iOS `SavedInputUnit` enum. */
val savedInputUnits: List<String> = listOf("kg", "g", "L", "mL", "tonne")
