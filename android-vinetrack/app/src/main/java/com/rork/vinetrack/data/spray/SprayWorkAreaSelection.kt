package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.TripOccurrencePlanner
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.util.UUID

/** Operator work intention only; never mutates Trip coverage or creates completion events. */
object SprayWorkAreaSelection {
    data class Choice(val id: String, val title: String, val blockId: String, val ordinal: Int,
        val physicalEvidence: JsonObject, val hasGeometry: Boolean)
    @Serializable data class Selected(val id: String, val choiceId: String, val title: String, val blockId: String,
        val ordinal: Int, val configuration: SprayPassConfiguration, val physicalEvidence: JsonObject) {
        val travelPassCount: Int get() = 1
        val controllerRowEquivalents: Double get() = configuration.rowEquivalents
    }
    fun choices(candidates: List<TripOccurrencePlanner.Candidate>): List<Choice> {
        val counts = mutableMapOf<String, Int>()
        return candidates.map { c ->
            val ordinal = (counts[c.key] ?: 0) + 1; counts[c.key] = ordinal
            val resolved = c.rows.isNotEmpty() && c.rows.all { row -> row.id?.let(SprayPlanningProtocol::uuid) == true &&
                listOf(row.startPoint, row.endPoint).all { it != null && it.latitude.isFinite() && it.longitude.isFinite() &&
                    kotlin.math.abs(it.latitude) <= 90 && kotlin.math.abs(it.longitude) <= 180 } }
            val evidence = buildJsonObject {
                put("blockId", c.blockId); put("pathNumber", c.label)
                put("geometryStatus", if (resolved) "frozen_native_rows" else "unresolved")
                put("rows", JsonArray(c.rows.map { row -> buildJsonObject {
                    put("id", row.stableId); put("storedIdentity", row.id?.let(SprayPlanningProtocol::uuid) == true)
                    put("number", row.calculationRowNumber)
                    put("startLatitude", row.startPoint?.latitude?.let(::JsonPrimitive) ?: JsonNull)
                    put("startLongitude", row.startPoint?.longitude?.let(::JsonPrimitive) ?: JsonNull)
                    put("endLatitude", row.endPoint?.latitude?.let(::JsonPrimitive) ?: JsonNull)
                    put("endLongitude", row.endPoint?.longitude?.let(::JsonPrimitive) ?: JsonNull)
                } }))
            }
            Choice("${c.key}|pass:$ordinal", "${c.display} · Pass $ordinal", c.blockId, ordinal, evidence, resolved)
        }
    }
    fun select(c: Choice, configuration: SprayPassConfiguration): Selected = Selected(UUID.randomUUID().toString(), c.id,
        c.title, c.blockId, c.ordinal, configuration, c.physicalEvidence)
    fun retained(s: Selected, choices: List<Choice>, configuration: SprayPassConfiguration?): Boolean =
        configuration == s.configuration && choices.any { it.id == s.choiceId && it.physicalEvidence == s.physicalEvidence }
    const val ROUTE_MESSAGE = "Route binding unavailable: authoritative whole-pass treatment area and R2 reconciliation are not yet verified. No hectare tolerance or automatic pass allocation has been applied."
}
