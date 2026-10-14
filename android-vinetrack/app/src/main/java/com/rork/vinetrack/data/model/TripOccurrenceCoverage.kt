package com.rork.vinetrack.data.model

import kotlinx.serialization.json.*
import java.util.UUID

/** Raw-preserving reader: non-null malformed/future documents are never legacy. */
object TripOccurrenceCoverage {
    const val CONTRACT = "vinetrack.planned-occurrence"
    enum class Basis { LEGACY, OCCURRENCE, UPDATE_REQUIRED }
    data class Item(val id: String, val blockId: String, val blockName: String, val label: Double, val pass: Int)
    data class Document(val raw: JsonObject, val planId: String, val revision: Long, val planRevision: Long,
                        val items: List<Item>, val order: List<String>, val retired: List<String>) {
        fun state(id: String): JsonObject = raw.getValue("states").jsonObject.getValue(id).jsonObject
        fun status(id: String): String = state(id).getValue("status").jsonPrimitive.content
        val targetId: String? get() = raw["selectedOccurrenceId"].textOrNull() ?: raw["plannedCursorId"].textOrNull()
        fun count(status: String): Int = order.count { status(it) == status }
    }
    fun basis(raw: JsonElement?): Basis = when {
        raw == null || raw == JsonNull -> Basis.LEGACY
        read(raw) != null -> Basis.OCCURRENCE
        else -> Basis.UPDATE_REQUIRED
    }
    fun read(raw: JsonElement?): Document? = runCatching {
        val d = raw!!.jsonObject
        require(d["contract"].textOrNull() == CONTRACT && d["schemaVersion"]?.jsonPrimitive?.int == 1)
        val plan = d.getValue("planId").jsonPrimitive.content.also(::canonicalUUID)
        val revision = d.getValue("revision").jsonPrimitive.long.also { require(it >= 0) }
        val planRevision = d.getValue("planRevision").jsonPrimitive.long.also { require(it >= 1) }
        val items = d.getValue("items").jsonArray.map { value ->
            val i = value.jsonObject
            val ref = i.getValue("physicalPathRef").jsonObject
            canonicalUUID(ref.getValue("pathId").jsonPrimitive.content)
            val rows = ref.getValue("rowIds").jsonArray.map { it.jsonPrimitive.content.also(::canonicalUUID) }
            require(rows.distinct().size == rows.size)
            Item(i.getValue("occurrenceId").jsonPrimitive.content.also(::canonicalUUID),
                i.getValue("blockId").jsonPrimitive.content.also(::canonicalUUID),
                i.getValue("blockNameSnapshot").jsonPrimitive.content,
                i.getValue("pathNumber").jsonPrimitive.double.also { require(it.isFinite()) },
                i.getValue("passOrdinal").jsonPrimitive.int.also { require(it > 0) })
        }
        require(items.isNotEmpty() && items.size <= 5000 && items.map { it.id }.distinct().size == items.size)
        val order = d.getValue("activeOrder").jsonArray.map { it.jsonPrimitive.content }
        val retired = d.getValue("retired").jsonArray.map { it.jsonPrimitive.content }
        require((order + retired).size == items.size && (order + retired).toSet() == items.map { it.id }.toSet())
        val states = d.getValue("states").jsonObject
        require(states.keys == items.map { it.id }.toSet())
        states.values.forEach { value ->
            val state = value.jsonObject
            require(state["status"].textOrNull() in listOf("incomplete", "done", "skipped"))
            state["lastOperationId"].textOrNull()?.let(::canonicalUUID)
            require(state["source"].textOrNull() in listOf(null, "manual", "automatic", "endReview", "correction"))
            state.getValue("tankSessionIds").jsonArray.forEach { canonicalUUID(it.jsonPrimitive.content) }
        }
        listOf("selectedOccurrenceId", "plannedCursorId").forEach { key ->
            d[key].textOrNull()?.let { require(it in order) }
        }
        Document(d, plan, revision, planRevision, items, order, retired)
    }.getOrNull()

    fun requireDocument(raw: JsonElement): Document = read(raw)
        ?: error("Occurrence coverage requires an updated client or reconciliation. Numeric coverage was not used.")

    private fun canonicalUUID(value: String) { require(UUID.fromString(value).toString() == value) }
}

internal fun JsonElement?.textOrNull(): String? = (this as? JsonPrimitive)?.takeUnless { it is JsonNull }?.content
