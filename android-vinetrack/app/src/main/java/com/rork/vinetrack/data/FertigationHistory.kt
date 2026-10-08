package com.rork.vinetrack.data

import kotlinx.serialization.json.JsonObject

/** Bulk decoration never adds irrigation rows, and resolves reversed history without an active lookup. */
object FertigationHistory {
    fun index(applications: List<JsonObject>, isSystemAdmin: Boolean): Map<String, JsonObject> {
        if (!isSystemAdmin) return emptyMap()
        val result = mutableMapOf<String, JsonObject>()
        applications.forEach { application ->
            FertigationDomain.string(application, "irrigation_session_id")?.lowercase()?.let { session ->
                if (result[session] == null || FertigationDomain.isEditable(application)) result[session] = application
            }
        }
        return result
    }
    /** Irrigation is the sole reversal authority; refresh only after it succeeds. */
    suspend fun afterIrrigationReversal(reverse: suspend () -> Unit, reload: suspend () -> Unit) {
        reverse()
        reload()
    }
    fun quantity(product: JsonObject, key: String): String {
        val value = FertigationDomain.number(product, key)?.takeIf { it.isFinite() }
            ?: return if (key == "actual_quantity") "Actual not entered" else "Unavailable"
        return "$value ${FertigationDomain.string(product, "quantity_unit") ?: ""}"
    }
    fun rate(product: JsonObject): String = FertigationDomain.number(product, "planned_rate")?.let {
        "$it ${FertigationDomain.string(product, "rate_unit") ?: ""}"
    } ?: "Rate not set"
}
