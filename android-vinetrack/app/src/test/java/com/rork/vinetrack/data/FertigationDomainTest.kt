package com.rork.vinetrack.data

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class FertigationDomainTest {
    private val vineyardId = "11111111-1111-4111-8111-111111111111"
    private val stepId = "22222222-2222-4222-8222-222222222222"

    @Test fun deniedAdminMakesNoFertigationRequests() = runBlocking {
        var calls = 0
        val repo = FertigationRepository({ false }) { _, _ -> calls++; "{}" }
        try { repo.capabilities(vineyardId); fail("Gate accepted non-admin") }
        catch (e: IllegalStateException) { assertEquals("System Admin required.", e.message) }
        assertEquals(0, calls)
    }
    @Test fun stepSelectionRequiresAdminTemplateVineyardAndMethod() {
        val raw = buildJsonObject {
            put("id", stepId); put("vineyard_id", vineyardId); put("is_template", true); put("operation_type", "Fertigation")
        }
        assertTrue(FertigationDomain.isSelectable(raw, vineyardId, true))
        assertFalse(FertigationDomain.isSelectable(raw, vineyardId, false))
        assertFalse(FertigationDomain.isSelectable(raw, stepId, true))
        assertFalse(FertigationDomain.isSelectable(JsonObject(raw + ("is_template" to JsonPrimitive(false))), vineyardId, true))
        assertFalse(FertigationDomain.isSelectable(JsonObject(raw + ("operation_type" to JsonPrimitive("Foliar Spray"))), vineyardId, true))
        assertFalse(FertigationDomain.isSelectable(JsonObject(raw + ("deleted_at" to JsonPrimitive("2026-10-07"))), vineyardId, true))
    }
    @Test fun canonicalRpcNamesAndNullParameters() = runBlocking {
        val requests = mutableListOf<Pair<String, JsonObject>>()
        val repo = FertigationRepository({ true }) { name, params ->
            requests += name to params
            when (name) { "list_fertigation_applications", "list_fertigation_program_steps" -> "[]"; "get_irrigation_session_fertigation" -> "null"; else -> "{}" }
        }
        repo.capabilities(vineyardId); repo.programSteps(vineyardId); repo.sessionApplication(vineyardId, stepId)
        repo.applications(vineyardId, programStepId = stepId, includeReversed = true)
        repo.upsert(stepId, vineyardId, stepId, stepId, null, null, null, emptyList())
        repo.reverse(stepId, null)
        assertEquals(listOf("get_fertigation_capabilities", "list_fertigation_program_steps", "get_irrigation_session_fertigation", "list_fertigation_applications", "upsert_fertigation_application", "reverse_fertigation_application"), requests.map { it.first })
        assertEquals(JsonPrimitive(stepId), requests[3].second["p_program_step_id"])
        assertEquals(JsonNull, requests[3].second["p_vintage_year"])
        assertEquals(JsonNull, requests[4].second["p_notes"])
    }
    @Test fun hectaresUseOnlyAuthoritativeAllocations() {
        val line = buildJsonObject { put("rate", 10); put("fertigation_rate_basis", "per_hectare"); put("fertigation_rate_unit", "kg/ha") }
        val result = FertigationDomain.plannedQuantity(line, FertigationDomain.Totals.from(listOf(FertigationDomain.Allocation(9620.0, 4500.0))))
        assertEquals(9.62, result.quantity!!, 0.00001); assertEquals("kg", result.unit)
    }
    @Test fun gramsPerVineBecomeKilograms() {
        val line = buildJsonObject { put("rate", 25); put("fertigation_rate_basis", "per_vine"); put("fertigation_rate_unit", "g/vine") }
        val result = FertigationDomain.plannedQuantity(line, FertigationDomain.Totals.from(listOf(FertigationDomain.Allocation(9620.0, 4500.0))))
        assertEquals(112.5, result.quantity!!, 0.00001); assertEquals("kg", result.unit)
    }
    @Test fun millilitresPerVineBecomeLitres() {
        val line = buildJsonObject { put("rate", 25); put("fertigation_rate_basis", "per_vine"); put("fertigation_rate_unit", "mL/vine") }
        val result = FertigationDomain.plannedQuantity(line, FertigationDomain.Totals.from(listOf(FertigationDomain.Allocation(9620.0, 4500.0))))
        assertEquals(112.5, result.quantity!!, 0.00001); assertEquals("L", result.unit)
    }
    @Test fun cycleDoesNotNeedGeometry() {
        val line = buildJsonObject { put("rate", 50); put("fertigation_rate_basis", "per_irrigation_cycle"); put("fertigation_rate_unit", "kg") }
        assertEquals(50.0, FertigationDomain.plannedQuantity(line, FertigationDomain.Totals.from(emptyList())).quantity!!, 0.00001)
    }
    @Test fun missingAllocationIsNullNotZero() {
        val totals = FertigationDomain.Totals.from(listOf(FertigationDomain.Allocation(9620.0, 4500.0), FertigationDomain.Allocation(null, null)))
        assertNull(totals.areaHa); assertNull(totals.vines)
        assertNull(FertigationDomain.Totals.from(emptyList()).areaHa)
        assertNull(FertigationDomain.Totals.from(listOf(FertigationDomain.Allocation(0.0, 0.0))).vines)
    }
    @Test fun sprayBasisCannotBeInferred() {
        val line = buildJsonObject { put("rate", 10); put("unit", "L/100 L") }
        assertNull(FertigationDomain.plannedQuantity(line, FertigationDomain.Totals(1.0, 1000.0)).quantity)
        assertEquals("Rate not set", FertigationDomain.rateText(line))
    }
    @Test fun savedUnitNotProductFormAndUnknownJsonKeysSurvive() {
        val line = buildJsonObject {
            put("chemical_id", stepId); put("rate", 10); put("fertigation_rate_basis", "per_hectare"); put("fertigation_rate_unit", "kg/ha")
            put("product_form", "liquid"); put("future_key", buildJsonObject { put("nested", JsonArray(listOf(JsonNull, JsonPrimitive(true)))) })
        }
        val decoded = Json.parseToJsonElement(line.toString()).jsonObject
        assertEquals(line, decoded); assertEquals("10 kg/ha", FertigationDomain.rateText(decoded))
    }
    @Test fun actualSeparateAndIdsStableAcrossPayloadRetries() {
        val line = buildJsonObject { put("chemical_id", stepId); put("name", "Nutrient"); put("rate", 10); put("fertigation_rate_basis", "per_hectare"); put("fertigation_rate_unit", "kg/ha") }
        val draft = FertigationDomain.DraftProduct(line = line)
        val totals = FertigationDomain.Totals(0.962, 4500.0)
        val step = buildJsonObject { put("id", stepId) }
        val first = draft.payload(totals, step)
        assertEquals(JsonPrimitive(9.62), first["planned_quantity"]); assertEquals(JsonNull, first["actual_quantity"])
        val second = draft.copy(actual = "8.5").payload(totals, step)
        assertEquals(first["id"], second["id"]); assertEquals(JsonPrimitive(stepId), second["saved_chemical_id"])
        assertEquals(first["planned_quantity"], second["planned_quantity"]); assertEquals(JsonPrimitive(8.5), second["actual_quantity"])
    }
    @Test fun costUnavailableAndReversedReadOnly() {
        assertNull(FertigationDomain.frozenCost(buildJsonObject { put("cost_per_unit", 0); put("actual_quantity", 10) }))
        assertEquals(20.0, FertigationDomain.frozenCost(buildJsonObject { put("cost_per_unit", 2); put("actual_quantity", 10) })!!, 0.0001)
        assertFalse(FertigationDomain.isEditable(buildJsonObject { put("status", "reversed") }))
        assertFalse(FertigationDomain.isEditable(buildJsonObject {}))
    }
}
