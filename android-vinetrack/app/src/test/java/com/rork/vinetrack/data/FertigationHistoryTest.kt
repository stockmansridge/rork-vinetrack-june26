package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.SprayProgramLanding
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class FertigationHistoryTest {
    private val vineyard = UUID.randomUUID().toString()
    private val sessionId = UUID.randomUUID().toString()
    private val stepId = UUID.randomUUID().toString()
    private val appId = UUID.randomUUID().toString()
    private val productId = UUID.randomUUID().toString()
    private val chemicalId = UUID.randomUUID().toString()
    private val product get() = buildJsonObject { put("id", productId); put("saved_chemical_id", chemicalId); put("product_name", "Frozen nutrient"); put("planned_rate", 3); put("rate_unit", "kg/ha"); put("planned_quantity", 6); put("actual_quantity", JsonNull); put("quantity_unit", "kg"); put("cost_per_unit", 2); put("product_snapshot", buildJsonObject { put("opaque", true) }) }
    private val application get() = buildJsonObject { put("id", appId); put("irrigation_session_id", sessionId); put("program_step_id", stepId); put("program_step_name", "Frozen name"); put("growth_stage_code", "EL12"); put("notes", "Frozen notes"); put("status", "active"); put("products", JsonArray(listOf(product))) }
    private val session get() = IrrigationSessionRow(sessionId, vineyard, UUID.randomUUID().toString(), UUID.randomUUID().toString(), "2026-10-08", vintageYear = 2027, durationMinutes = 60, totalVolumeLitres = 1000.0)
    @Test fun normalExistingSessionCanReceive() {
        val selected = buildJsonObject { put("id", stepId); put("name", "Selected nutrient step"); put("chemical_lines", JsonArray(listOf(buildJsonObject { put("chemical_id", chemicalId); put("name", "Nutrient"); put("rate", 5); put("fertigation_rate_basis", "per_irrigation_cycle"); put("fertigation_rate_unit", "kg") }))) }
        val draft = FertigationSessionDraft().select(selected, FertigationDomain.Totals(null, null))
        val entry = draft.entry(session, "owner"); assertEquals(1, entry.acknowledgedProducts?.size); assertEquals(draft.id, entry.id); assertTrue(entry.existingSession); assertEquals(FertigationLinkedOutbox.Phase.FERTIGATION_PENDING, entry.phase); assertEquals(sessionId, entry.irrigation.id) }
    @Test fun importedExistingSessionCanReceive() {
        val selected = buildJsonObject { put("id", stepId); put("chemical_lines", JsonArray(listOf(buildJsonObject { put("chemical_id", chemicalId); put("name", "Nutrient"); put("rate", 5); put("fertigation_rate_basis", "per_irrigation_cycle"); put("fertigation_rate_unit", "kg") }))) }
        val entry = FertigationSessionDraft().select(selected, FertigationDomain.Totals(null, null)).entry(session.copy(sourceType = "galcon_gsi_import", status = "imported"), "owner"); assertEquals(FertigationLinkedOutbox.Phase.FERTIGATION_PENDING, entry.phase) }
    @Test fun addingNeverRecordsIrrigation() = replay("online")
    @Test fun offlineWritePersistsAcrossRestart() = replay("offline")
    @Test fun retryOnlyUpsertsFertigation() = replay("permanent")
    @Test fun retryPreservesApplicationAndProductUUIDs() = replay("identity")
    @Test fun onePendingApplicationPerSession() {
        var disk: String? = null
        val box = FertigationLinkedOutbox({ disk }, { disk = it })
        val entry = FertigationSessionDraft.from(application).entry(session, "owner")
        box.enqueueExisting(entry)
        assertTrue(runCatching { box.enqueueExisting(entry) }.isFailure)
        assertEquals(1, box.entries().size)
    }
    @Test fun viewEditLoadsExistingValues() { val draft = FertigationSessionDraft.from(application); assertEquals(appId, draft.id); assertEquals(stepId, FertigationDomain.string(checkNotNull(draft.step), "id")); assertEquals("Frozen notes", draft.notes); assertEquals(listOf(product), draft.products); assertEquals(listOf(""), draft.actuals) }
    @Test fun frozenValuesDriveDisplay() { assertTrue(FertigationHistory.rate(product).contains("3")); assertTrue(FertigationHistory.quantity(product, "planned_quantity").contains("6")); assertEquals("Frozen name", FertigationDomain.string(application, "program_step_name")) }
    @Test fun laterProgramEditsDoNotRestateHistory() {
        val draft = FertigationSessionDraft.from(application).select(buildJsonObject { put("id", stepId); put("name", "Renamed today"); put("chemical_lines", JsonArray(emptyList())) }, FertigationDomain.Totals(null, null))
        assertEquals(listOf(product), draft.products); assertEquals("Frozen name", FertigationDomain.string(checkNotNull(draft.step), "name"))
    }
    @Test fun oneIrrigationRowPlusBadge() { val rows = listOf(sessionId); val index = FertigationHistory.index(listOf(application, application), true); assertEquals(1, rows.size); assertEquals(1, index.size); assertNotNull(index[sessionId]) }
    @Test fun bulkHistoryRequestsOnce() = runBlocking {
        var calls = 0
        val repo = FertigationRepository({ true }, { name, _ -> calls++; assertEquals("list_fertigation_applications", name); JsonArray(listOf(application)).toString() })
        val index = repo.historyIndex(vineyard, 2027, true)
        repeat(100) { assertNotNull(index[sessionId]) }; assertEquals(1, calls)
    }
    @Test fun nonAdminHistoryUnchangedAndNoRPC() = runBlocking {
        var calls = 0
        val repo = FertigationRepository({ calls++; false }, { _, _ -> calls++; "null" })
        assertTrue(repo.historyIndex(vineyard, isSystemAdmin = false).isEmpty())
        assertNull(repo.historicalSession(vineyard, sessionId, 2027, false)); assertEquals(0, calls)
    }
    @Test fun nullActualIsNotZero() { assertEquals("Actual not entered", FertigationHistory.quantity(product, "actual_quantity")) }
    @Test fun missingAndZeroCostUnavailable() {
        assertNull(FertigationDomain.frozenCost(JsonObject(product + mapOf("actual_quantity" to JsonPrimitive(4), "cost_per_unit" to JsonNull))))
        assertNull(FertigationDomain.frozenCost(JsonObject(product + mapOf("actual_quantity" to JsonPrimitive(4), "cost_per_unit" to JsonPrimitive(0)))))
    }
    @Test fun programHistoryUsesExactUUID() = runBlocking {
        val repo = FertigationRepository({ true }, { name, params -> assertEquals("list_fertigation_applications", name); assertEquals(JsonPrimitive(stepId), params["p_program_step_id"]); "[]" })
        repo.applications(vineyard, programStepId = stepId, includeReversed = true); Unit
    }
    @Test fun programHistoryIncludesReversed() = runBlocking {
        val repo = FertigationRepository({ true }, { _, params -> assertEquals(JsonPrimitive(true), params["p_include_reversed"]); "[]" })
        repo.applications(vineyard, programStepId = stepId, includeReversed = true); Unit
    }
    @Test fun irrigationReversalReloadsReversedState() = runBlocking {
        var status = "active"; var displayed = "active"
        FertigationHistory.afterIrrigationReversal({ status = "reversed" }, { displayed = status }); assertEquals("reversed", displayed)
    }
    @Test fun reversedRemainsVisibleWhenActiveLookupNull() = runBlocking {
        val reversed = JsonObject(application + ("status" to JsonPrimitive("reversed")))
        val calls = mutableListOf<String>()
        val repo = FertigationRepository({ true }, { name, _ -> calls += name; if (name == "get_irrigation_session_fertigation") "null" else JsonArray(listOf(reversed)).toString() })
        val result = checkNotNull(repo.historicalSession(vineyard, sessionId, 2027, true))
        assertEquals(appId, FertigationDomain.string(result, "id")); assertFalse(FertigationDomain.isEditable(result))
        assertEquals(listOf("get_irrigation_session_fertigation", "list_fertigation_applications"), calls)
    }
    @Test fun reversedIsReadOnly() { val draft = FertigationSessionDraft.from(JsonObject(application + ("status" to JsonPrimitive("reversed")))); assertTrue(draft.isReadOnly); assertTrue(runCatching { draft.payloads() }.isFailure); assertTrue(runCatching { draft.entry(session, "owner") }.isFailure) }
    @Test fun reversalNeverCallsIndependentFertigationReverse() = runBlocking { val calls = mutableListOf<String>(); FertigationHistory.afterIrrigationReversal({ calls += "reverse_irrigation_session" }, { calls += "reload" }); assertEquals(listOf("reverse_irrigation_session", "reload"), calls) }
    @Test fun importedRestrictionDoesNotHideFertigation() { val imported = session.copy(sourceType = "galcon_gsi_import", status = "corrected"); assertTrue(imported.isImported); assertTrue(FertigationSessionDraft.canAttach(vineyard, vineyard, imported.status, true)) }
    @Test fun normalIrrigationWithoutFertigationUnchanged() { val normal = session; assertNull(FertigationHistory.index(emptyList(), true)[normal.id]); assertEquals(1000.0, normal.totalVolumeLitres, 0.0); assertEquals("completed", normal.status); assertFalse(normal.isImported) }
    @Test fun normalProgramMethodsRemainUnchanged() { listOf("Foliar Spray", "Banded Spray", "Spreader").forEach { assertTrue(SprayProgramLanding.canPlanSpray(it)) } }
    @Test fun retainedProductKeepsUUIDOnDeliberateStepChange() {
        val nextId = UUID.randomUUID().toString()
        val draft = FertigationSessionDraft.from(application).select(buildJsonObject { put("id", nextId); put("name", "New step"); put("chemical_lines", JsonArray(listOf(buildJsonObject { put("chemical_id", chemicalId); put("rate", 3); put("fertigation_rate_unit", "kg/ha") }))) }, FertigationDomain.Totals(null, null))
        assertEquals(appId, draft.id); assertEquals(listOf(product), draft.products); assertEquals(nextId, FertigationDomain.string(checkNotNull(draft.step), "id"))
    }
    @Test fun changedProductLineGetsNewSnapshot() {
        val next = buildJsonObject { put("id", UUID.randomUUID().toString()); put("name", "New step"); put("chemical_lines", JsonArray(listOf(buildJsonObject { put("chemical_id", chemicalId); put("name", "Nutrient"); put("rate", 99); put("fertigation_rate_basis", "per_irrigation_cycle"); put("fertigation_rate_unit", "kg") }))) }
        val draft = FertigationSessionDraft.from(application).select(next, FertigationDomain.Totals(null, null))
        assertEquals(appId, draft.id); assertNotEquals(productId, FertigationDomain.string(draft.products[0], "id")); assertEquals(99.0, FertigationDomain.number(draft.products[0], "planned_rate"))
    }
    @Test fun actualOnlyEditPreservesFrozenFields() { val draft = FertigationSessionDraft.from(application).copy(actuals = listOf("4.5")); assertEquals(listOf(JsonObject(product + ("actual_quantity" to JsonPrimitive(4.5)))), draft.payloads()) }
    @Test fun deletedAndReversedSessionsCannotWrite() { val draft = FertigationSessionDraft.from(application); assertTrue(runCatching { draft.entry(session.copy(deletedAt = "2026-10-08"), "owner") }.isFailure); assertTrue(runCatching { draft.entry(session.copy(status = "reversed"), "owner") }.isFailure) }
    private fun replay(mode: String) = runBlocking {
        var disk: String? = null
        val box = FertigationLinkedOutbox({ disk }, { disk = it })
        box.enqueueExisting(FertigationSessionDraft.from(application).entry(session, "owner"))
        var recordCalls = 0; var upsertCalls = 0
        box.flush(vineyard, "owner", record = { recordCalls++; session }, upsert = { entry, products ->
            upsertCalls++; assertEquals(appId, entry.id); assertEquals(JsonPrimitive(productId), products[0]["id"])
            if (mode != "online") throw java.io.IOException("offline")
            application
        }, permanent = { mode == "permanent" })
        val restarted = FertigationLinkedOutbox({ disk }, { disk = it })
        val retained = restarted.entries().single()
        assertTrue(retained.existingSession); assertEquals(appId, retained.id); assertEquals(listOf(product), retained.acknowledgedProducts)
        assertEquals(0, recordCalls); assertEquals(1, upsertCalls)
        if (mode != "online") {
            restarted.retry(appId); assertEquals(FertigationLinkedOutbox.Phase.FERTIGATION_PENDING, restarted.entries().single().phase)
            restarted.flush(vineyard, "owner", record = { recordCalls++; session }, upsert = { entry, products -> upsertCalls++; assertEquals(appId, entry.id); assertEquals(listOf(product), products); application }, permanent = { false })
            assertEquals(0, recordCalls); assertEquals(2, upsertCalls)
        }
        assertEquals(FertigationLinkedOutbox.Phase.ACKNOWLEDGED, restarted.entries().single().phase)
    }
}
