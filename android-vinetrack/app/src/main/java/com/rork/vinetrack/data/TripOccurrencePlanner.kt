package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockRow
import com.rork.vinetrack.data.model.TripOccurrenceCoverage
import kotlinx.serialization.json.*
import java.util.UUID
import kotlin.math.abs
import kotlin.math.roundToInt

/** Block-qualified preview candidates have no transient occurrence UUIDs. */
object TripOccurrencePlanner {
    data class Candidate(val vineyardId: String, val blockId: String, val blockName: String,
                         val label: Double, val rows: List<PaddockRow>) {
        val key: String get() = "$blockId|$label|${rows.joinToString("|") { it.stableId }}"
        val display: String get() = "$blockName · Path ${TripRowSequencePlanner.formatPath(label)}"
    }

    fun candidates(blocks: List<Paddock>): List<Candidate> = blocks.sortedWith(TripRowSequencePlanner.rowOrderComparator).flatMap { block ->
        val rows = block.rows.orEmpty()
        rows.flatMap { listOf(it.calculationRowNumber - 0.5, it.calculationRowNumber + 0.5) }.distinct().sorted().map { label ->
            Candidate(block.vineyardId, block.id, block.name, label,
                rows.filter { abs(it.calculationRowNumber - label) <= 0.5 }.sortedBy { it.calculationRowNumber })
        }
    }.distinctBy { it.key }

    /** Index-space pattern selection never resolves a label back to a block. */
    fun plan(candidates: List<Candidate>, pattern: TrackingPattern, startKey: String?, higherFirst: Boolean): List<Candidate> {
        if (pattern == TrackingPattern.FREE_DRIVE || candidates.isEmpty()) return emptyList()
        val sorted = if (higherFirst) candidates else candidates.reversed()
        val start = sorted.indexOfFirst { it.key == startKey }.takeIf { it >= 0 } ?: 0
        val ordered = sorted.drop(start) + sorted.take(start)
        if (pattern == TrackingPattern.EVERY_SECOND_ROW) {
            return ordered.filter { ((it.label - ordered.first().label).roundToInt() % 2) == 0 }
        }
        val indices = TripRowSequencePlanner.plannedSequence(ordered.indices.map { it.toDouble() }, pattern, 0.0, true)
        return indices.map { ordered[it.toInt()] }
    }

    fun preview(planned: List<Candidate>, maxItems: Int = 10): String {
        val passes = mutableMapOf<String, Int>()
        val lines = planned.take(maxItems).map { candidate ->
            val pass = (passes[candidate.key] ?: 0) + 1; passes[candidate.key] = pass
            "${candidate.display} · Pass $pass"
        }
        return lines.joinToString(" → ") + if (planned.size > maxItems) " → …" else ""
    }

    /** Mint once at acceptance, then persist this document with the exact create intent. */
    fun commit(candidates: List<Candidate>, vineyardId: String): JsonObject {
        require(candidates.isNotEmpty() && candidates.all { it.vineyardId == vineyardId && it.rows.size <= 2 && it.rows.map { row -> row.stableId }.distinct().size == it.rows.size }) {
            "The selected physical path is ambiguous. Confirm its block and row binding before saving."
        }
        val refs = candidates.distinctBy { it.key }.associate { candidate -> candidate.key to buildJsonObject {
            put("pathId", UUID.randomUUID().toString())
            val resolved = candidate.rows.isNotEmpty() && candidate.rows.all { it.id != null }
            put("rowIds", JsonArray(if (resolved) candidate.rows.map { JsonPrimitive(it.stableId.lowercase()) } else emptyList()))
            put("geometryRevision", if (resolved) "native-snapshot-v1" else "unresolved")
            // Derived legacy IDs retain binding context but never masquerade as admitted geometry.
            put("candidateRowIds", JsonArray(candidate.rows.map { JsonPrimitive(it.stableId.lowercase()) }))
            if (resolved) put("rowSnapshots", JsonArray(candidate.rows.map {
                buildJsonObject {
                    put("id", requireNotNull(it.id)); put("number", it.calculationRowNumber)
                    it.startPoint?.let { point -> put("startPoint", Json.encodeToJsonElement(com.rork.vinetrack.data.model.CoordinatePoint.serializer(), point)) }
                    it.endPoint?.let { point -> put("endPoint", Json.encodeToJsonElement(com.rork.vinetrack.data.model.CoordinatePoint.serializer(), point)) }
                    it.vineCountOverride?.let { count -> put("vineCountOverride", count) }
                }
            }))
            put("boundarySide", when {
                candidate.rows.size != 1 -> "between"
                candidate.label < candidate.rows.first().calculationRowNumber -> "before"
                else -> "after"
            })
        } }
        val passes = mutableMapOf<String, Int>()
        val ids = candidates.map { UUID.randomUUID().toString() }
        return buildJsonObject {
            put("contract", TripOccurrenceCoverage.CONTRACT); put("schemaVersion", 1)
            put("planId", UUID.randomUUID().toString()); put("revision", 0); put("planRevision", 1)
            put("items", JsonArray(candidates.mapIndexed { index, candidate ->
                val pass = (passes[candidate.key] ?: 0) + 1; passes[candidate.key] = pass
                buildJsonObject {
                    put("occurrenceId", ids[index]); put("blockId", candidate.blockId)
                    put("blockNameSnapshot", candidate.blockName); put("pathNumber", candidate.label)
                    put("passOrdinal", pass); put("physicalPathRef", refs.getValue(candidate.key))
                }
            }))
            put("activeOrder", JsonArray(ids.map { JsonPrimitive(it) })); put("retired", JsonArray(emptyList()))
            put("states", JsonObject(ids.associateWith { buildJsonObject {
                put("status", "incomplete"); put("lastOperationId", JsonNull)
                put("source", JsonNull); put("tankSessionIds", JsonArray(emptyList()))
            } }))
            put("plannedCursorId", ids.first()); put("selectedOccurrenceId", JsonNull)
        }.also { TripOccurrenceCoverage.requireDocument(it) }
    }
}
