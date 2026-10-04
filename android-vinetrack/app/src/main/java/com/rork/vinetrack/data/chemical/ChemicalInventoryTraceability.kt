package com.rork.vinetrack.data.chemical

import kotlinx.serialization.json.*

/** Audit metadata only; does not influence quantities, costing or registered rates. */
object ChemicalInventoryTraceability {
    fun nullableText(value: String): JsonElement = value.trim().takeIf { it.isNotEmpty() }?.let(::JsonPrimitive) ?: JsonNull
    fun fields(batch: String, batchDate: String?, serial: String): JsonObject = buildJsonObject {
        put("p_batch_number", nullableText(batch))
        put("p_batch_date", batchDate?.let(::JsonPrimitive) ?: JsonNull)
        put("p_serial_number", nullableText(serial))
    }
    fun display(row: CatalogueRow, latest: Boolean = false): List<String> {
        val prefix = if (latest) "latest_" else ""
        return listOf("batch_number" to "Batch / Lot number", "batch_date" to "Production / Batch date", "serial_number" to "Serial number (if applicable)").mapNotNull { (key, label) ->
            row.text(prefix + key)?.takeIf { it.isNotBlank() }?.let { "$label: $it" }
        }
    }
}
