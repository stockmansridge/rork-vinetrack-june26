package com.rork.vinetrack.data

/** Foreground result from the existing Start authority, never inferred from navigation state. */
data class SprayStartOutcome(
    val tripId: String? = null,
    val message: String? = null,
    val operationId: String? = null,
    val inspectionTripIds: List<String> = emptyList(),
    val inspectionRequired: Boolean = false,
    val ownerId: String? = null,
    val vineyardId: String? = null,
) {
    val isStarted: Boolean get() = tripId != null && message == null
}

/** Blank is optional, but malformed or negative input must not silently become blank. */
object SprayStartEngineHours {
    fun parse(text: String): Double? = text.trim().replace(',', '.').toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0 }
    fun isValid(text: String): Boolean = text.isBlank() || parse(text) != null
}
