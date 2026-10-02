package com.rork.vinetrack.data.chemical

import kotlinx.serialization.json.*
import java.math.BigDecimal

object CatalogueInventoryMutation {
    const val PURCHASE = "chemical_inventory_record_purchase_v2"
    const val STOCKTAKE = "chemical_inventory_record_stocktake_v2"
    const val HISTORY = "chemical_inventory_purchase_history_v2"
    val operations = setOf("chemical_inventory_record_purchase", "chemical_inventory_record_stocktake", PURCHASE, STOCKTAKE, "chemical_inventory_mark_finished", "chemical_inventory_set_settings")
    suspend fun perform(systemAdmin: Boolean, operation: String, chemicalId: String,
        mutate: suspend () -> Unit, refresh: suspend (String) -> Unit) {
        check(systemAdmin && operation in operations)
        mutate()
        refresh(chemicalId)
    }
}

/** Capacity metadata is independent of physical stock; multiplication is only a form preview. */
object CatalogueInventoryContainer {
    fun units(form: String, packUnit: String): List<String> = when {
        form.equals("solid", true) -> listOf("kg", "g")
        form.equals("liquid", true) -> listOf("L", "mL")
        packUnit in listOf("kg", "g") -> listOf("kg", "g")
        packUnit in listOf("L", "mL") -> listOf("L", "mL")
        else -> emptyList()
    }
    fun valid(count: Double, size: Double) = count.isFinite() && count > 0 && count % 1.0 == 0.0 && size.isFinite() && size > 0 && (count * size).isFinite()
    fun fields(count: Double, size: Double, unit: String) = buildJsonObject {
        put("p_container_count", count); put("p_container_size", size); put("p_container_unit", unit)
    }
    fun stockFields(quantity: Double, unit: String) = buildJsonObject {
        put("p_current_quantity", quantity); put("p_current_unit", unit)
    }
    fun number(value: Double): String = BigDecimal.valueOf(value).stripTrailingZeros().toPlainString()
    fun preview(count: Double, size: Double, unit: String) = "${number(count)} × ${number(size)} $unit = ${number(count * size)} $unit total"
    fun historyText(row: CatalogueRow): String {
        val aggregate = "${row.number("quantity")?.let(::number) ?: "—"} ${row.text("unit").orEmpty()} total"
        val count = row.number("container_count"); val size = row.number("container_size"); val unit = row.text("container_unit")
        return if (count != null && size != null && unit != null && valid(count, size)) "${number(count)} × ${number(size)} $unit · $aggregate" else aggregate
    }
}
