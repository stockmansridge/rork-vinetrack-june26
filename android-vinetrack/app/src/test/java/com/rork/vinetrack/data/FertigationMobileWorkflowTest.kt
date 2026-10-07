package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.SprayProgramLanding
import com.rork.vinetrack.data.spray.SprayProgramProductDraft
import com.rork.vinetrack.data.spray.SprayProgramStepDraft
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class FertigationMobileWorkflowTest {
    @Test fun fertigationCannotPlanSpray() { assertFalse(SprayProgramLanding.canPlanSpray("Fertigation")) }
    @Test fun unknownCannotPlanSpray() { assertFalse(SprayProgramLanding.canPlanSpray("Autonomous Future Method")) }
    @Test fun normalSprayAllowListUnchanged() {
        listOf("Foliar Spray", "Banded Spray", "Spreader").forEach { assertTrue(SprayProgramLanding.canPlanSpray(it)) }
    }
    @Test fun actualEditorRoundTripKeepsSavedUnitAndUnknownJSON() {
        val chemicalId = UUID.randomUUID().toString()
        val line = buildJsonObject { put("chemical_id", chemicalId); put("name", "Nutrient"); put("rate", 10); put("fertigation_rate_basis", "per_hectare"); put("fertigation_rate_unit", "kg/ha"); put("future", buildJsonObject { put("array", JsonArray(listOf(JsonNull, JsonPrimitive(true)))) }) }
        val product = checkNotNull(SprayProgramProductDraft.fromWireLine(0, line))
        val draft = SprayProgramStepDraft(UUID.randomUUID().toString(), true, name = "EL12 Nutrients", growthStageCode = "EL12", operationType = "Fertigation", equipmentId = "old-equipment", tractorId = "old-tractor", notes = "Draft notes", products = listOf(product.copy(rate = 12.0)))
        val wire = draft.chemicalLines()[0].jsonObject
        assertEquals("kg/ha", wire["fertigation_rate_unit"]?.jsonPrimitive?.content)
        assertEquals("per_hectare", wire["fertigation_rate_basis"]?.jsonPrimitive?.content)
        assertEquals(line["future"], wire["future"])
        assertEquals(chemicalId, wire["chemical_id"]?.jsonPrimitive?.content)
        assertEquals(12.0, wire["rate"]?.jsonPrimitive?.doubleOrNull)
        val payload = draft.portalPayload(null)
        listOf("equipment_id", "tractor_id", "target", "water_volume", "spray_rate_per_ha", "concentration_factor").forEach { assertEquals(JsonNull, payload[it]) }
        assertEquals(JsonArray(emptyList()), payload["targets"])
        assertEquals("Draft notes", payload["notes"]?.jsonPrimitive?.content)
    }
    @Test fun controlsRequireAdminAndCanonicalTemplate() {
        assertFalse(SprayProgramLanding.programMethods(false, true).contains("Fertigation"))
        assertFalse(SprayProgramLanding.programMethods(true, false).contains("Fertigation"))
        assertTrue(SprayProgramLanding.programMethods(true, true).contains("Fertigation"))
    }
    @Test fun chemicalSearchReturnKeepsDraftAndNewUUIDWithoutRateInference() {
        val chemical = com.rork.vinetrack.data.model.SavedChemical(UUID.randomUUID().toString(), UUID.randomUUID().toString(), name = "New nutrient", unit = "Litres")
        val first = SprayProgramProductDraft(name = "First", rate = 10.0, fertigationRateBasis = "per_vine", fertigationRateUnit = "g/vine")
        val second = SprayProgramProductDraft(name = "Second", rate = 20.0)
        val draft = SprayProgramStepDraft("step", true, name = "Name", growthStageCode = "EL12", notes = "Draft notes", operationType = "Fertigation", products = listOf(first, second))
        val returned = draft.copy(products = draft.products.map { if (it.lineKey == second.lineKey) it.replacedFertigationWith(chemical) else it })
        assertEquals("Name", returned.name); assertEquals("EL12", returned.growthStageCode); assertEquals("Draft notes", returned.notes)
        assertEquals(first, returned.products[0]); assertEquals(second.lineKey, returned.products[1].lineKey)
        assertEquals(chemical.id, returned.chemicalLines()[1].jsonObject["chemical_id"]?.jsonPrimitive?.content)
        assertNull(returned.products[1].fertigationRateBasis); assertNull(returned.products[1].fertigationRateUnit)
    }
    @Test fun noLocalFertigationTemplate() {
        assertNotNull(SprayProgramStepDraft("id", false, name = "Name", operationType = "Fertigation").validationError)
    }
    @Test fun onlineSuccessWritesInOrder() = replayScenario("online")
    @Test fun fertigationFailureRetriesOnlyDependentAfterRestart() = replayScenario("fertigationFailure")
    @Test fun offlineSurvivesRestartAndReplaysInOrder() = replayScenario("offline")
    @Test fun permanentFailureIsRetainedUntilExplicitRetry() = replayScenario("permanent")
    @Test fun wrongAcknowledgementNeverReleasesDependency() = replayScenario("wrongAck")
    @Test fun differentAccountCannotReplay() = replayScenario("otherOwner")

    private fun replayScenario(scenario: String) = runBlocking {
        val vineyard = UUID.randomUUID().toString(); val owner = UUID.randomUUID().toString()
        val sessionId = UUID.randomUUID().toString(); val applicationId = UUID.randomUUID().toString(); val productId = UUID.randomUUID().toString()
        val pending = PendingIrrigationSession(sessionId, vineyard, "system", "valve", sessionDate = "2026-10-07", durationMinutes = 60, calculationMethod = "total_volume", totalVolumeLitres = 1000.0)
        val line = buildJsonObject { put("name", "N"); put("rate", 10); put("fertigation_rate_basis", "per_hectare"); put("fertigation_rate_unit", "kg/ha") }
        val step = buildJsonObject { put("id", UUID.randomUUID().toString()); put("name", "Frozen step") }
        val entry = FertigationLinkedOutbox.Entry(applicationId, owner, pending, step, listOf(FertigationLinkedOutbox.Product(productId, line, "")), "Frozen notes")
        var persisted: String? = null
        val outbox = FertigationLinkedOutbox({ persisted }, { persisted = it })
        outbox.enqueue(entry); outbox.enqueue(entry)
        assertEquals(1, outbox.entries().size)
        val saved = IrrigationSessionRow(if (scenario == "wrongAck") "wrong" else sessionId, vineyard, "system", "valve", "2026-10-07", status = "completed")
        val calls = mutableListOf<String>()
        outbox.flush(vineyard, if (scenario == "otherOwner") "another-user" else owner, record = {
            calls.add("irrigation")
            if (scenario == "offline") throw java.io.IOException("offline")
            saved
        }, upsert = { e, products ->
            calls.add("fertigation")
            assertEquals(FertigationLinkedOutbox.Phase.FERTIGATION_PENDING, FertigationLinkedOutbox({ persisted }, { persisted = it }).entries().first().phase)
            assertEquals(productId, products[0]["id"]?.jsonPrimitive?.content)
            assertEquals(JsonNull, products[0]["actual_quantity"])
            assertEquals(JsonNull, products[0]["planned_quantity"])
            if (scenario == "fertigationFailure" || scenario == "permanent") throw java.io.IOException("failed")
            buildJsonObject { put("id", e.id); put("irrigation_session_id", sessionId) }
        }, permanent = { scenario == "permanent" })
        if (scenario == "otherOwner") { assertTrue(calls.isEmpty()); return@runBlocking }
        if (scenario == "wrongAck") { assertEquals(listOf("irrigation"), calls); return@runBlocking }
        assertEquals(if (scenario == "offline") listOf("irrigation") else listOf("irrigation", "fertigation"), calls)
        val restarted = FertigationLinkedOutbox({ persisted }, { persisted = it })
        assertEquals(productId, restarted.entries().first().products[0].id)
        if (scenario == "permanent") {
            restarted.flush(vineyard, owner, record = { fail("Must not recreate irrigation"); saved }, upsert = { _, _ -> fail("Must not auto retry permanent rejection"); JsonObject(emptyMap()) }, permanent = { false })
            assertEquals(FertigationLinkedOutbox.Phase.PERMANENT_ERROR, restarted.entries().first().phase)
            restarted.retry(applicationId)
        }
        val resumed = mutableListOf<String>()
        restarted.flush(vineyard, owner, record = { resumed.add("irrigation"); saved }, upsert = { e, _ -> resumed.add("fertigation"); buildJsonObject { put("id", e.id); put("irrigation_session_id", sessionId) } }, permanent = { false })
        assertEquals(when (scenario) { "online" -> emptyList(); "offline" -> listOf("irrigation", "fertigation"); else -> listOf("fertigation") }, resumed)
        assertEquals(FertigationLinkedOutbox.Phase.ACKNOWLEDGED, restarted.entries().first().phase)
        restarted.flush(vineyard, owner, record = { fail("Repeated replay must not write"); saved }, upsert = { _, _ -> fail("Repeated replay must not write"); JsonObject(emptyMap()) }, permanent = { false })
    }
}
