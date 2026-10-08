package com.rork.vinetrack.data

import kotlinx.serialization.json.*
import java.util.UUID

/** Frozen edit payloads; same-step editing never consults today's Program Step. */
data class FertigationSessionDraft(
    val id: String = UUID.randomUUID().toString(),
    val step: JsonObject? = null,
    val products: List<JsonObject> = emptyList(),
    val actuals: List<String> = emptyList(),
    val notes: String = "",
    val isReadOnly: Boolean = false,
) {
    companion object {
        fun from(application: JsonObject?): FertigationSessionDraft {
            if (application == null) return FertigationSessionDraft()
            val products = (application["products"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
            return FertigationSessionDraft(checkNotNull(FertigationDomain.string(application, "id")), buildJsonObject {
                put("id", application["program_step_id"] ?: JsonNull)
                put("name", application["program_step_name"] ?: JsonNull)
                put("growth_stage_code", application["growth_stage_code"] ?: JsonNull)
            }, products, products.map { FertigationDomain.string(it, "actual_quantity") ?: "" }, FertigationDomain.string(application, "notes") ?: "", !FertigationDomain.isEditable(application))
        }
        fun canAttach(vineyardId: String, selectedVineyardId: String?, status: String, isSystemAdmin: Boolean): Boolean =
            isSystemAdmin && vineyardId.equals(selectedVineyardId, true) && status in listOf("completed", "corrected", "imported", "estimated")
    }
    fun select(selected: JsonObject, totals: FertigationDomain.Totals): FertigationSessionDraft {
        check(!isReadOnly) { "Reversed Fertigation cannot be edited." }
        if (FertigationDomain.string(step ?: JsonObject(emptyMap()), "id") == FertigationDomain.string(selected, "id")) return this
        val remaining = payloads().toMutableList()
        val next = (selected["chemical_lines"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }.map { line ->
            val chemical = FertigationDomain.uuid(line, "savedChemicalId") ?: FertigationDomain.uuid(line, "chemical_id")
            val index = if (chemical == null) -1 else remaining.indexOfFirst { FertigationDomain.uuid(it, "saved_chemical_id") == chemical && FertigationDomain.number(it, "planned_rate") == FertigationDomain.number(line, "rate") && FertigationDomain.string(it, "rate_basis") == FertigationDomain.string(line, "fertigation_rate_basis") && FertigationDomain.string(it, "rate_unit") == FertigationDomain.string(line, "fertigation_rate_unit") }
            if (index >= 0) remaining.removeAt(index) else FertigationDomain.DraftProduct(line = line).payload(totals, selected)
        }
        return copy(step = selected, products = next, actuals = next.map { FertigationDomain.string(it, "actual_quantity") ?: "" })
    }
    fun payloads(): List<JsonObject> {
        check(!isReadOnly) { "Reversed Fertigation cannot be edited." }
        return products.mapIndexed { index, product ->
        val text = actuals[index].trim()
        val value = text.toDoubleOrNull()
        require(text.isEmpty() || (value != null && value.isFinite() && value >= 0)) { "Actual used must be blank or finite and non-negative." }
        JsonObject(product + ("actual_quantity" to (value?.let(::JsonPrimitive) ?: JsonNull)))
    }
    }
    fun entry(session: IrrigationSessionRow, ownerId: String): FertigationLinkedOutbox.Entry {
        check(session.deletedAt == null && !isReadOnly && canAttach(session.vineyardId, session.vineyardId, session.status, true))
        val selected = checkNotNull(step)
        checkNotNull(FertigationDomain.uuid(selected, "id"))
        val reference = PendingIrrigationSession(session.id, session.vineyardId, session.irrigationSystemId, session.valveId, session.valveName ?: "", session.sessionDate, session.durationMinutes, session.calculationMethod)
        return FertigationLinkedOutbox.Entry(id, ownerId, reference, selected, emptyList(), notes,
            phase = FertigationLinkedOutbox.Phase.FERTIGATION_PENDING, acknowledgedProducts = payloads(),
            acknowledgedTotals = FertigationDomain.Totals.from(session.blocks.map { FertigationDomain.Allocation(it.servicedAreaM2, it.servicedVineCount?.toDouble()) }), existingSession = true)
    }
}
