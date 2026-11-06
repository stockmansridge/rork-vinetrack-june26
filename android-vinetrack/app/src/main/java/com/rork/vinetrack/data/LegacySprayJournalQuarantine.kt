package com.rork.vinetrack.data

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Sets aside legacy spray-save rows that the current app can't read, instead of
 * letting one of them make the whole [LegacySpraySaveStore] unreadable.
 *
 * Before this, a single row in an older format (or one that no longer passed
 * today's validation) made every read throw, so every Free Drive spray Start
 * refused with [LegacySpraySaveStore.MESSAGE] and nothing in the app could
 * clear it. Planned-route Starts already skip this store for the same reason.
 *
 * Nothing is deleted: each entry keeps the store's exact original bytes, and
 * [LegacySpraySaveStore.replayInspection] still inspects them so dependent sync
 * stays held for those trips exactly as before (Issue #41).
 */
object LegacySprayJournalQuarantine {
    @Serializable
    data class Entry(
        val setAsideAtMs: Long,
        /** One support-safe reason per set-aside row: index, stage and error type only. */
        val reasons: List<String>,
        val keptRows: Int,
        /** The store's complete original value, verbatim. */
        val originalBytes: String,
    )

    data class Split<T>(val kept: List<T>, val reasons: List<String>)

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /**
     * Keeps every row that [decode] accepts (strict decode + validation), as long as
     * its trip and record ids are unique among kept rows. Every other row is reported.
     */
    fun <T> split(raw: String, decode: (JsonElement) -> T, ids: (T) -> Pair<String, String>): Split<T> {
        val rows = runCatching { Json.parseToJsonElement(raw) as JsonArray }.getOrElse {
            return Split(emptyList(), listOf("store: unparseable_json_array (${it.javaClass.simpleName})"))
        }
        val decoded = rows.mapIndexed { index, row ->
            index to runCatching { decode(row) }
        }
        val okIds = decoded.mapNotNull { (_, r) -> r.getOrNull()?.let(ids) }
        val dupes = (okIds.map { it.first } + okIds.map { it.second }).groupingBy { it }.eachCount().filterValues { it > 1 }.keys
        val kept = mutableListOf<T>()
        val reasons = mutableListOf<String>()
        decoded.forEach { (index, result) ->
            val value = result.getOrNull()
            when {
                value == null -> reasons += "row $index: ${describe(result.exceptionOrNull())}${identity(rows[index])}"
                ids(value).let { it.first in dupes || it.second in dupes } -> reasons += "row $index: duplicate_identity${identity(rows[index])}"
                else -> kept += value
            }
        }
        return Split(kept, reasons)
    }

    /** Error type plus a short message with any echoed input removed. */
    internal fun describe(error: Throwable?): String {
        if (error == null) return "unknown"
        val stage = if (error is kotlinx.serialization.SerializationException || error is IllegalArgumentException &&
            error.javaClass.name.startsWith("kotlinx.serialization")) "decode" else "validate"
        val message = error.message?.substringBefore("JSON input")?.substringBefore('\n')?.trim()?.take(120)
            ?.takeIf { it.isNotBlank() }
        return "$stage:${error.javaClass.simpleName}" + (message?.let { " ($it)" } ?: "")
    }

    /** Trip/record ids only, when they are well-formed UUIDs. */
    private fun identity(row: JsonElement): String {
        val obj = row as? JsonObject ?: return ""
        fun uuid(e: JsonElement?) = (e as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?.let { runCatching { java.util.UUID.fromString(it).toString() }.getOrNull() }
        val trip = uuid((obj["trip"] as? JsonObject)?.get("id"))
        val record = uuid(obj["recordId"])
        return listOfNotNull(trip?.let { "trip=$it" }, record?.let { "record=$it" })
            .takeIf { it.isNotEmpty() }?.joinToString(" ", prefix = "; ") ?: ""
    }

    /** Never drops earlier evidence: an unreadable earlier log is kept verbatim as its own entry. */
    fun append(existing: String?, entry: Entry): String {
        val earlier = when {
            existing == null -> emptyList()
            else -> runCatching { json.decodeFromString<List<Entry>>(existing) }.getOrElse {
                listOf(Entry(entry.setAsideAtMs, listOf("store: earlier_set_aside_log_unreadable"), 0, existing))
            }
        }
        return json.encodeToString(earlier + entry)
    }

    fun originals(existing: String?): List<String> = read(existing).map { it.originalBytes }

    fun diagnostics(existing: String?): List<String> = read(existing).map { e ->
        "legacy_journal_set_aside_at: ${java.time.Instant.ofEpochMilli(e.setAsideAtMs)}; rows_set_aside: ${e.reasons.size}; rows_kept: ${e.keptRows}; original_bytes_retained: true"
    } + read(existing).flatMap { e -> e.reasons.map { "  set_aside_reason: $it" } }

    private fun read(existing: String?): List<Entry> =
        existing?.let { runCatching { json.decodeFromString<List<Entry>>(it) }.getOrNull() } ?: emptyList()
}
