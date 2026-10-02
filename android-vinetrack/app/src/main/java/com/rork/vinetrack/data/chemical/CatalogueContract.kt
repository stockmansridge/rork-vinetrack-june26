package com.rork.vinetrack.data.chemical

import kotlinx.serialization.json.*
import java.util.Locale

/** Wire data, not a second search or extraction algorithm. */
data class CatalogueRow(val fields: JsonObject) {
    fun text(key: String): String? = (fields[key] as? JsonPrimitive)?.contentOrNull
    fun number(key: String): Double? = (fields[key] as? JsonPrimitive)?.doubleOrNull
    fun bool(key: String): Boolean = (fields[key] as? JsonPrimitive)?.booleanOrNull == true
    fun strings(key: String): List<String> = (fields[key] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()
    fun rows(key: String): List<CatalogueRow> = (fields[key] as? JsonArray)?.mapNotNull { (it as? JsonObject)?.let(::CatalogueRow) }.orEmpty()
    val id: String get() = text("revision_id") ?: text("id") ?: text("saved_chemical_id") ?: text("purchase_id") ?: ""
    val targets: List<String> get() = rows("vineyard_uses").flatMap { it.strings("targets") }.filter { it.isNotBlank() }.distinctBy { it.lowercase(Locale.ROOT) }
    val badge: String get() = if (text("review_status") == "approved") "VineTrack catalogue" else "Pending VineTrack review"
    val isSuccess: Boolean get() = text("status") in listOf("completed", "pending_review", "needs_attention")
    val isTerminal: Boolean get() = isSuccess || text("status") in listOf("failed", "cancelled")
    val groupText: String get() = listOf(text("activity_group_scheme")?.uppercase().orEmpty(), strings("activity_groups").joinToString(" + ")).filter { it.isNotBlank() }.joinToString(" ")
    val inventoryStatus: String get() = when {
        text("tracking_status") == "needs_opening_stock" -> "Opening stock not set"
        bool("out_of_stock") -> "Out of stock"
        bool("low_stock") -> "Low stock"
        else -> "In stock"
    }
    fun rateRows(key: String): List<CatalogueRow> = (fields["default_rate_options"] as? JsonObject)?.let { CatalogueRow(it).rows(key) }.orEmpty()
    val rateText: String get() {
        val amount = text("value") ?: listOfNotNull(text("min_value"), text("max_value")).joinToString("–")
        return listOf(amount, text("unit").orEmpty(), strings("targets").joinToString(", "), text("condition").orEmpty()).filter { it.isNotBlank() }.joinToString(" · ")
    }
    companion object {
        fun manualTargets(problem: String, use: String): String = if (problem.isNotBlank()) problem
            else if (use.trim().lowercase(Locale.ROOT) in listOf("fungicide", "herbicide", "insecticide", "adjuvant", "fertiliser", "fertilizer", "biostimulant")) "" else use
        fun compactManufacturer(name: String): String = name.replace(Regex("(?i)\\s+(?:Australia\\s+)?(?:Pty\\s+)?(?:Ltd|Limited)\\.?$"), "").replace(Regex("(?i)\\s+Australia$"), "")
    }
}
