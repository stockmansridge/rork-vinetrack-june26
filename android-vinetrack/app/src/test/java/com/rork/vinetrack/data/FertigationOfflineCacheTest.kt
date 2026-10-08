package com.rork.vinetrack.data

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.UUID

class FertigationOfflineCacheTest {
    @Test fun accountSwitchDuringFetchCannotPersistResponse() = runBlocking {
        val owner = UUID.randomUUID().toString(); val vineyard = UUID.randomUUID().toString()
        val persisted = mutableMapOf<String, String>()
        val cache = FertigationProgramStepCache({ persisted[it] }, { key, raw -> persisted[key] = raw })
        var stillCurrent = true
        try {
            cache.load(owner, vineyard, { true }, { stillCurrent = false; emptyList() }, { stillCurrent })
            fail("Account switch must cancel persistence")
        } catch (_: kotlinx.coroutines.CancellationException) { }
        assertNull(persisted["fertigation_steps_${owner}_${vineyard}"])
    }
    @Test fun successfulOnlineFetchPersists() = cacheScenario("online")
    @Test fun restartOfflineReloadsCanonicalList() = cacheScenario("restart")
    @Test fun vineyardIsolation() = cacheScenario("vineyard")
    @Test fun accountIsolation() = cacheScenario("account")
    @Test fun nonAdminCannotReadCacheAndDenialSurvivesRestart() = cacheScenario("denied")
    @Test fun firstOfflineWithoutCacheLeavesOrdinaryIrrigationUsable() = cacheScenario("firstOffline")
    @Test fun exactUUIDProductsBasisUnitAndUnknownKeysSurvive() = cacheScenario("exact")
    @Test fun invalidResponseDoesNotReplaceCache() = cacheScenario("invalidResponse")
    @Test fun successfulEmptyResponseReplacesCache() = cacheScenario("emptyResponse")
    private fun cacheScenario(scenario: String) = runBlocking {
        val owner = UUID.randomUUID().toString(); val vineyard = UUID.randomUUID().toString()
        val stepId = UUID.randomUUID().toString(); val chemicalId = UUID.randomUUID().toString()
        val line = buildJsonObject { put("chemical_id", chemicalId); put("name", "N"); put("rate", 12.345); put("fertigation_rate_basis", "per_vine"); put("fertigation_rate_unit", "mL/vine"); put("unknown", JsonArray(listOf(JsonNull, JsonPrimitive(true)))) }
        val step = buildJsonObject { put("id", stepId); put("vineyard_id", vineyard); put("is_template", true); put("operation_type", "Fertigation"); put("chemical_lines", JsonArray(listOf(line))) }
        val persisted = mutableMapOf<String, String>()
        val cache = FertigationProgramStepCache({ persisted[it] }, { key, raw -> persisted[key] = raw })
        val repository = FertigationRepository({ true }, { name, _ -> assertEquals("list_fertigation_program_steps", name); JsonArray(listOf(step)).toString() })
        if (scenario != "firstOffline") {
            val online = checkNotNull(cache.load(owner, vineyard, { true }, { repository.programSteps(vineyard) }))
            assertFalse(online.isCached); assertEquals(listOf(step), online.steps)
            val disk = Json.decodeFromString<FertigationProgramStepCache.Snapshot>(checkNotNull(persisted["fertigation_steps_${owner}_${vineyard}"]))
            assertEquals(listOf(step), disk.steps)
        }
        if (scenario == "denied") {
            try { cache.load(owner, vineyard, { false }, { fail("Non-admin must not fetch"); emptyList() }); fail("Expected denial") }
            catch (e: IllegalStateException) { assertEquals("System Admin required.", e.message) }
        }
        if (scenario == "invalidResponse") {
            val invalid = JsonObject(step + ("vineyard_id" to JsonPrimitive(UUID.randomUUID().toString())))
            val retained = checkNotNull(cache.load(owner, vineyard, { true }, { listOf(invalid) }))
            assertTrue(retained.isCached); assertEquals(listOf(step), retained.steps)
        }
        if (scenario == "emptyResponse") cache.load(owner, vineyard, { true }, { emptyList() })
        val restarted = FertigationProgramStepCache({ persisted[it] }, { key, raw -> persisted[key] = raw })
        val offline = restarted.load(if (scenario == "account") UUID.randomUUID().toString() else owner,
            if (scenario == "vineyard") UUID.randomUUID().toString() else vineyard,
            { throw IOException("offline") }, { fail("No request without admin confirmation"); emptyList() })
        if (scenario in listOf("account", "vineyard", "denied", "firstOffline")) {
            assertNull(offline)
            assertEquals(1000.0, IrrigationLocalCalc.totalVolume("total_volume", null, 60, null, null, 1000.0), 0.001)
        } else if (scenario == "emptyResponse") assertTrue(checkNotNull(offline).steps.isEmpty())
        else { assertTrue(checkNotNull(offline).isCached); assertEquals(listOf(step), offline.steps); assertEquals(JsonArray(listOf(line)), offline.steps[0]["chemical_lines"]) }
    }
    @Test fun staleCachedStepRejectionRetainsIrrigationAndRetryNeverRecreatesSession() = runBlocking {
        val owner = UUID.randomUUID().toString(); val vineyard = UUID.randomUUID().toString()
        val sessionId = UUID.randomUUID().toString(); val appId = UUID.randomUUID().toString()
        val line = buildJsonObject { put("name", "N"); put("rate", 1); put("fertigation_rate_basis", "per_irrigation_cycle"); put("fertigation_rate_unit", "kg") }
        val step = buildJsonObject { put("id", UUID.randomUUID().toString()); put("vineyard_id", vineyard); put("is_template", true); put("operation_type", "Fertigation"); put("chemical_lines", JsonArray(listOf(line))) }
        val persisted = mutableMapOf<String, String>()
        val cache = FertigationProgramStepCache({ persisted[it] }, { key, raw -> persisted[key] = raw })
        cache.load(owner, vineyard, { true }, { listOf(step) })
        val offline = checkNotNull(FertigationProgramStepCache({ persisted[it] }, { key, raw -> persisted[key] = raw }).load(owner, vineyard, { throw IOException("offline") }, { emptyList() }))
        val pending = PendingIrrigationSession(sessionId, vineyard, "system", "valve", sessionDate = "2026-10-08", durationMinutes = 60, calculationMethod = "total_volume", totalVolumeLitres = 1000.0)
        var outboxRaw: String? = null
        val outbox = FertigationLinkedOutbox({ outboxRaw }, { outboxRaw = it })
        val product = FertigationLinkedOutbox.Product(UUID.randomUUID().toString(), offline.steps[0]["chemical_lines"]!!.jsonArray[0].jsonObject, "")
        outbox.enqueue(FertigationLinkedOutbox.Entry(appId, owner, pending, offline.steps[0], listOf(product), null))
        val saved = IrrigationSessionRow(sessionId, vineyard, "system", "valve", "2026-10-08", status = "completed")
        var irrigationWrites = 0
        outbox.flush(vineyard, owner, record = { irrigationWrites++; saved }, upsert = { _, _ -> throw FertigationPermanentFailure() }, permanent = { it is FertigationPermanentFailure })
        val rejected = outbox.entries().single()
        assertEquals(FertigationLinkedOutbox.Phase.PERMANENT_ERROR, rejected.phase)
        assertNotNull(rejected.acknowledgedTotals); assertEquals(sessionId, rejected.irrigation.id)
        assertTrue(rejected.message.contains("needs attention"))
        val restarted = FertigationLinkedOutbox({ outboxRaw }, { outboxRaw = it })
        restarted.retry(appId)
        assertEquals(FertigationLinkedOutbox.Phase.FERTIGATION_PENDING, restarted.entries().single().phase)
        restarted.flush(vineyard, owner, record = { irrigationWrites++; saved }, upsert = { entry, products ->
            assertEquals(appId, entry.id); assertEquals(sessionId, entry.irrigation.id); assertEquals(product.id, products[0]["id"]!!.jsonPrimitive.content)
            throw FertigationPermanentFailure()
        }, permanent = { it is FertigationPermanentFailure })
        assertEquals(1, irrigationWrites)
        assertEquals(FertigationLinkedOutbox.Phase.PERMANENT_ERROR, restarted.entries().single().phase)
    }
}
