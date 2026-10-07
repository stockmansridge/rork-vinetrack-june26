package com.rork.vinetrack.data

import kotlinx.serialization.json.*
import java.math.BigDecimal
import java.math.RoundingMode
import java.util.UUID

/** SQL 266 linked-irrigation domain; never a Spray Record, Trip or Tank. */
object FertigationDomain {
    enum class Basis(val raw: String, val label: String, val units: List<String>) {
        PER_HECTARE("per_hectare", "Per hectare", listOf("kg/ha", "L/ha")),
        PER_VINE("per_vine", "Per vine", listOf("g/vine", "mL/vine")),
        PER_CYCLE("per_irrigation_cycle", "Per irrigation cycle", listOf("kg", "L")),
    }
    data class Allocation(val areaM2: Double?, val vines: Double?)
    @kotlinx.serialization.Serializable
    data class Totals(val areaHa: Double?, val vines: Double?) {
        companion object {
            fun from(allocations: List<Allocation>): Totals {
                fun total(values: List<Double?>): Double? {
                    if (values.isEmpty() || values.any { it == null || !it.isFinite() || it <= 0 }) return null
                    return values.filterNotNull().sum().takeIf { it.isFinite() }
                }
                return Totals(total(allocations.map { it.areaM2 })?.div(10_000), total(allocations.map { it.vines }))
            }
        }
    }
    data class PlannedQuantity(val quantity: Double?, val unit: String?)

    fun string(raw: JsonObject, key: String): String? = (raw[key] as? JsonPrimitive)?.contentOrNull
    fun number(raw: JsonObject, key: String): Double? = (raw[key] as? JsonPrimitive)?.doubleOrNull
    fun uuid(raw: JsonObject, key: String): UUID? = string(raw, key)?.let { text ->
        if (!text.matches(Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"))) null
        else runCatching { UUID.fromString(text) }.getOrNull()
    }
    fun isSelectable(step: JsonObject, vineyardId: String, isSystemAdmin: Boolean): Boolean =
        isSystemAdmin && uuid(step, "id") != null && string(step, "vineyard_id").equals(vineyardId, true)
            && (step["is_template"] as? JsonPrimitive)?.booleanOrNull == true
            && (step["deleted_at"] == null || step["deleted_at"] == JsonNull)
            && string(step, "operation_type").equals("Fertigation", true)

    fun rateText(line: JsonObject): String {
        val rate = number(line, "rate")?.takeIf { it.isFinite() && it > 0 } ?: return "Rate not set"
        val unit = string(line, "fertigation_rate_unit")?.takeIf { it.isNotEmpty() } ?: return "Rate not set"
        val amount = BigDecimal.valueOf(rate).stripTrailingZeros().toPlainString()
        return "$amount $unit" + if (string(line, "fertigation_rate_basis") == Basis.PER_CYCLE.raw) " per irrigation cycle" else ""
    }
    fun plannedQuantity(line: JsonObject, totals: Totals): PlannedQuantity {
        val rateUnit = string(line, "fertigation_rate_unit")
        val unit = when (rateUnit) { "kg/ha", "g/vine", "kg" -> "kg"; "L/ha", "mL/vine", "L" -> "L"; else -> null }
        val rate = number(line, "rate")?.takeIf { it.isFinite() && it > 0 } ?: return PlannedQuantity(null, unit)
        val basis = Basis.entries.firstOrNull { it.raw == string(line, "fertigation_rate_basis") && rateUnit in it.units }
            ?: return PlannedQuantity(null, unit)
        val result = when (basis) {
            Basis.PER_HECTARE -> totals.areaHa?.let { rate * it }
            Basis.PER_VINE -> totals.vines?.let { rate * it / 1000 }
            Basis.PER_CYCLE -> rate
        }?.takeIf { it.isFinite() && (it * 1000).isFinite() }
        return PlannedQuantity(result?.let { BigDecimal.valueOf(it).setScale(3, RoundingMode.HALF_UP).toDouble() }, unit)
    }
    fun frozenCost(product: JsonObject): Double? {
        val cost = number(product, "cost_per_unit")?.takeIf { it.isFinite() && it > 0 } ?: return null
        val actual = number(product, "actual_quantity")?.takeIf { it.isFinite() && it > 0 } ?: return null
        return (cost * actual).takeIf { it.isFinite() && it > 0 }
    }
    fun isEditable(application: JsonObject): Boolean = string(application, "status") == "active"

    data class DraftProduct(val id: String = UUID.randomUUID().toString(), val line: JsonObject, val actual: String = "") {
        fun payload(totals: Totals, step: JsonObject): JsonObject {
            val text = actual.trim()
            val entered = if (text.isEmpty()) null else text.toDoubleOrNull()
            require(text.isEmpty() || (entered != null && entered.isFinite() && entered >= 0)) {
                "Actual used must be blank or a finite, non-negative quantity."
            }
            val planned = plannedQuantity(line, totals)
            return buildJsonObject {
                put("id", id)
                put("saved_chemical_id", line["savedChemicalId"] ?: line["chemical_id"] ?: JsonNull)
                put("product_name", line["name"] ?: JsonPrimitive(""))
                put("product_category", line["product_category"] ?: JsonNull)
                put("product_form", line["product_form"] ?: JsonNull)
                put("planned_rate", line["rate"] ?: JsonNull)
                put("rate_basis", line["fertigation_rate_basis"] ?: JsonNull)
                put("rate_unit", line["fertigation_rate_unit"] ?: JsonNull)
                put("planned_quantity", planned.quantity?.let(::JsonPrimitive) ?: JsonNull)
                put("actual_quantity", entered?.let(::JsonPrimitive) ?: JsonNull)
                put("quantity_unit", planned.unit?.let(::JsonPrimitive) ?: JsonNull)
                put("cost_per_unit", number(line, "costPerUnit")?.takeIf { it.isFinite() && it > 0 }?.let(::JsonPrimitive) ?: JsonNull)
                put("product_snapshot", buildJsonObject {
                    put("program_step_id", step["id"] ?: JsonNull)
                    put("program_step_name", step["name"] ?: JsonNull)
                    put("growth_stage_code", step["growth_stage_code"] ?: JsonNull)
                    put("saved_chemical_id", line["savedChemicalId"] ?: line["chemical_id"] ?: JsonNull)
                    put("product_name", line["name"] ?: JsonNull)
                    put("rate", line["rate"] ?: JsonNull)
                    put("rate_basis", line["fertigation_rate_basis"] ?: JsonNull)
                    put("rate_unit", line["fertigation_rate_unit"] ?: JsonNull)
                    put("serviced_area_ha", totals.areaHa?.let(::JsonPrimitive) ?: JsonNull)
                    put("serviced_vines", totals.vines?.let(::JsonPrimitive) ?: JsonNull)
                })
            }
        }
    }
}
