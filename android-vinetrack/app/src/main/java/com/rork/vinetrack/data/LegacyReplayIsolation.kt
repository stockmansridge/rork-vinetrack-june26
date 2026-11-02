package com.rork.vinetrack.data

import kotlinx.serialization.json.*
import java.util.UUID

/** Read-only index, NOT a migration/receipt. Unknown content is never rewritten or sent. */
object LegacyReplayIsolation {
    data class Held(val index: Int, val owner: String?, val vineyard: String?, val trip: String?,
        val record: String?, val references: Set<String>, val code: String)
    data class Inspection(val held: List<Held>, val fingerprint: String) {
        fun blocker(tripId: String?, recordId: String? = null): String? {
            val ids = listOfNotNull(tripId, recordId).map(::id).toSet()
            if (held.any { h -> ids.any { it in h.references } }) return "LEGACY_SAME_TRIP_CONFLICT"
            if (held.any { it.trip == null || it.record == null || it.owner == null || it.vineyard == null })
                return "LEGACY_IDENTITY_UNRESOLVED"
            return null
        }
        fun blocksPayload(clientId: String, payload: String): Boolean {
            if (blocker(clientId) != null) return true
            val objectPayload = runCatching { Json.parseToJsonElement(payload) as JsonObject }.getOrNull() ?: return true
            val refs = references(objectPayload)
            return held.any { h -> listOfNotNull(h.trip, h.record).any { it in refs } }
        }
    }
    private fun id(value: String): String = value.trim().lowercase()
    private fun uuid(value: JsonElement?): String? = (value as? JsonPrimitive)?.takeIf { it.isString }
        ?.content?.let { runCatching { UUID.fromString(it).toString() }.getOrNull() }
    fun references(value: JsonElement): Set<String> = when (value) {
        is JsonObject -> value.values.flatMap { references(it) }.toSet()
        is JsonArray -> value.flatMap { references(it) }.toSet()
        else -> setOfNotNull(uuid(value))
    }
    /** `accepted` must strictly decode and validate the entire item before returning true. */
    fun inspect(raw: String?, accepted: (JsonElement) -> Boolean): Inspection {
        val hash = java.security.MessageDigest.getInstance("SHA-256").digest((raw ?: "").toByteArray())
            .joinToString("") { "%02x".format(it) }
        if (raw == null) return Inspection(emptyList(), hash)
        val rows = runCatching { Json.parseToJsonElement(raw) as JsonArray }.getOrNull()
            ?: return Inspection(listOf(Held(-1, null, null, null, null, emptySet(), "LEGACY_JOURNAL_READ_FAILURE")), hash)
        val tripIds = rows.mapNotNull { uuid(((it as? JsonObject)?.get("trip") as? JsonObject)?.get("id")) }
        val recordIds = rows.mapNotNull { uuid((it as? JsonObject)?.get("recordId")) }
        val duplicates = (tripIds + recordIds).groupingBy { it }.eachCount().filterValues { it > 1 }.keys
        val held = rows.mapIndexedNotNull { index, row ->
            val obj = row as? JsonObject
            val trip = obj?.get("trip") as? JsonObject
            val owner = uuid(obj?.get("actorId"))
            val vineyard = uuid(trip?.get("vineyardId"))
            val tripId = uuid(trip?.get("id"))
            val record = uuid(obj?.get("recordId"))
            val valid = tripId !in duplicates && record !in duplicates && runCatching { accepted(row) }.getOrDefault(false)
            if (valid) null else Held(index, owner, vineyard, tripId, record, references(row), "LEGACY_ORIGINAL_HELD")
        }
        return Inspection(held, hash)
    }
}
