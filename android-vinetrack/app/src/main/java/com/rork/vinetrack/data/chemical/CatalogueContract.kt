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
    val groupText: String get() = if (text("resistance_classification_state")?.lowercase(Locale.ROOT) in listOf("not_applicable", "unresolved")) "" else resistanceText(text("activity_group_scheme"), strings("activity_groups"))
    val resistanceWarning: String? get() = if (text("resistance_classification_state")?.lowercase(Locale.ROOT) == "unresolved") "Resistance group unknown" else null
    val inventoryStatus: String get() = when {
        text("tracking_status") == "needs_opening_stock" -> "Opening stock not set"
        text("tracking_status") == "finished" -> "Finished"
        text("tracking_status") == "out_of_stock" || bool("out_of_stock") -> "Out of stock"
        text("tracking_status") == "low_stock" || bool("low_stock") -> "Low stock"
        else -> "In stock"
    }
    fun rateRows(key: String): List<CatalogueRow> = (fields["default_rate_options"] as? JsonObject)?.let { CatalogueRow(it).rows(key) }.orEmpty()
    /** Presentation only; never select a dose or reconstruct registered options. */
    fun registeredRateLines(key: String): List<String> = rateRows(key).map { rate ->
        val amount = rate.number("value")?.let(::displayNumber) ?: listOfNotNull(rate.number("min_value"), rate.number("max_value")).joinToString("–", transform = ::displayNumber)
        val unit = rate.text("unit").orEmpty()
        val basis = if (unit.contains("/")) "" else if (key == "per_hectare") "/ha" else "/100 L"
        val dose = if (amount.isEmpty()) rate.text("raw_text").orEmpty() else "$amount $unit$basis"
        listOf(dose, rate.strings("targets").joinToString(", "), rate.text("condition").orEmpty(), rate.strings("methods").joinToString(" · ")).filter(String::isNotBlank).joinToString(" · ")
    }.filter(String::isNotBlank)
    val activeIngredientLines: List<String> get() = rows("active_ingredients").mapNotNull { active ->
        val name = active.text("name")?.takeIf(String::isNotBlank) ?: return@mapNotNull null
        listOf(name, active.number("concentration")?.let(::displayNumber).orEmpty(), active.text("concentration_unit").orEmpty()).filter(String::isNotBlank).joinToString(" ")
    }
    val rateText: String get() {
        val amount = text("value") ?: listOfNotNull(text("min_value"), text("max_value")).joinToString("–")
        return listOf(amount, text("unit").orEmpty(), strings("targets").joinToString(", "), text("condition").orEmpty()).filter { it.isNotBlank() }.joinToString(" · ")
    }
    companion object {
        private fun displayNumber(number: Double): String = java.math.BigDecimal.valueOf(number).stripTrailingZeros().toPlainString()
        fun resistanceText(scheme: String?, codes: List<String>): String {
            val label = scheme?.trim()?.uppercase(Locale.ROOT).orEmpty()
            if (label !in listOf("FRAC", "HRAC", "IRAC")) return ""
            val meaningful = codes.map(String::trim).filter { it.isNotEmpty() && it.uppercase(Locale.ROOT) !in listOf("NOT_APPLICABLE", "UNRESOLVED", "CLASSIFIED") }
            return if (meaningful.isEmpty()) "" else "$label ${meaningful.joinToString(" + ")}"
        }
        fun manualTargets(problem: String, use: String): String = if (problem.isNotBlank()) problem
            else if (use.trim().lowercase(Locale.ROOT) in listOf("fungicide", "herbicide", "insecticide", "adjuvant", "fertiliser", "fertilizer", "biostimulant")) "" else use
        fun compactManufacturer(name: String): String = name.replace(Regex("(?i)\\s+(?:Australia\\s+)?(?:Pty\\s+)?(?:Ltd|Limited)\\.?$"), "").replace(Regex("(?i)\\s+Australia$"), "")
    }
}
