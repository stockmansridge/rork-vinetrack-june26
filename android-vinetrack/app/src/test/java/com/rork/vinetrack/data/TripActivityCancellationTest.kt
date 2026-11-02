package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.SprayTankActual
import com.rork.vinetrack.data.model.SprayTankActualChemical
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * P0 Phase A: Cancel Trip recovery contract (client side of sql/281). Fixture identities mirror the
 * incident shape (Trip LOCAL_END_PENDING, one retained actual, missing Tank session) but are synthetic.
 */
class TripActivityCancellationTest {
    @get:Rule val tmp = TemporaryFolder()

    private val owner = "11111111-1111-4111-8111-111111111111"
    private val vineyard = "59973ced-1fb9-42ec-a66d-9eaad3172824"
    private val trip = "3bfb7f81-2ae2-4f33-8fd8-6666b2b45393"
    private val spray = "aaaaaaaa-0000-4000-8000-000000000001"
    private val otherTrip = "bbbbbbbb-0000-4000-8000-000000000002"
    private val opId = "cccccccc-0000-4000-8000-000000000003"

    private fun write(id: String, type: String, clientId: String, status: String = PendingWriteStatus.PENDING) =
        PendingWrite(id = id, entityType = type, opType = "update", payloadJson = "{}", clientId = clientId,
            createdAt = 1, updatedAt = 1, status = status)

    private val actual = SprayTankActual(
        id = "2b07a0ce-2086-441c-9d36-8a387e3e397d", vineyardId = vineyard, sprayRecordId = spray, tripId = trip,
        tankSessionId = "30259f0a-e2e2-41a2-8fbf-4569028a6f45", tankNumber = 1, waterVolumeL = 1234.5,
        chemicals = listOf(SprayTankActualChemical(id = "chem-1", name = "Copper", actualAmountBase = 2.75, unit = "Kg", plannedChemicalId = "plan-1")),
        confirmedAt = "2026-11-01T01:00:00Z", confirmedBy = owner,
    )

    private class MemStorage : TripCancellationIntentStore.Storage {
        val map = linkedMapOf<String, String>(); var failNextCommits = 0
        override fun all() = map.toMap()
        override fun commit(key: String, value: String): Boolean {
            if (failNextCommits > 0) { failNextCommits--; return false }
            map[key] = value; return true
        }
    }

    private inner class FakeLocal : TripActivityCancellationCoordinator.Local {
        val writes = mutableListOf<PendingWrite>()
        val actuals = mutableListOf<SprayTankActual>()
        var journal: String? = "{\"journal\":1}"
        var claim: String? = "{\"tripId\":\"$trip\"}"
        var journalThrows = false
        val log = mutableListOf<String>()
        override fun pendingWrites() = writes.toList()
        override fun removeWriteIfCurrent(expected: PendingWrite): Boolean { log += "rmWrite:${expected.id}"; return writes.remove(expected) }
        override fun localActuals(tripId: String) = actuals.filter { it.tripId == tripId }
        override fun removeActual(id: String): Boolean { log += "rmActual:$id"; return actuals.removeIf { it.id == id } }
        override fun rawJournal(ownerId: String, vineyardId: String, tripId: String): String? {
            if (journalThrows) throw IllegalStateException("unreadable"); return journal
        }
        override fun removeJournal(ownerId: String, vineyardId: String, tripId: String): Boolean { log += "rmJournal"; journal = null; return true }
        override fun activeClaimJson() = claim
        override fun clearActiveClaimIfTrip(ownerId: String, vineyardId: String, tripId: String): Boolean { log += "rmClaim"; claim = null; return true }
    }

    private inner class FakeRemote(private val storage: MemStorage, private val store: () -> TripCancellationIntentStore) : TripActivityCancellationCoordinator.Remote {
        val sent = mutableListOf<TripActivityCancellation.Intent>()
        var cancelResult: (TripActivityCancellation.Intent) -> JsonObject = { receiptFor(it) }
        var readResult: JsonObject? = null
        var intentStateAtSend: TripActivityCancellation.State? = null
        override suspend fun cancel(intent: TripActivityCancellation.Intent): JsonObject {
            sent += intent
            intentStateAtSend = store().find(intent.tripId)?.state
            return cancelResult(intent)
        }
        override suspend fun readReceipt(tripId: String, vineyardId: String) = readResult
    }

    private fun receiptFor(i: TripActivityCancellation.Intent, op: String = i.operationId, classification: String = i.classification) = buildJsonObject {
        put("status", "CANCELLED_ACKED"); put("trip_id", i.tripId); put("vineyard_id", i.vineyardId)
        put("operation_id", op); put("application_classification", classification); put("server_revision", 7)
        if (classification == "applied") put("compliance_archive_id", "dddddddd-0000-4000-8000-000000000004")
    }

    private data class Harness(
        val storage: MemStorage, val store: TripCancellationIntentStore, val local: FakeLocal,
        val remote: FakeRemote, val coordinator: TripActivityCancellationCoordinator, val evidenceDir: java.io.File,
    )

    private fun harness(): Harness {
        val storage = MemStorage()
        val store = TripCancellationIntentStore(storage)
        val local = FakeLocal()
        val remote = FakeRemote(storage) { store }
        val dir = tmp.newFolder("evidence")
        val coordinator = TripActivityCancellationCoordinator(store, TripCancellationEvidenceWriter(dir), remote, local,
            now = { 1000L }, newOperationId = { opId })
        return Harness(storage, store, local, remote, coordinator, dir)
    }

    private fun request(c: TripActivityCancellation.Classification, confirmed: Boolean = false) =
        TripActivityCancellation.Request(owner, vineyard, trip, c, confirmed)

    // ---- eligibility --------------------------------------------------------------------------

    @Test fun eligibilityRequiresAuthRoleLocalEndAndExactClaim() {
        fun e(role: String? = "owner", user: String? = owner, cOwner: String? = owner, cVy: String? = vineyard, cTrip: String? = trip, pending: Boolean = true) =
            TripActivityCancellation.eligibility(role, user, cOwner, cVy, cTrip, trip, vineyard, pending).code
        assertNull(e())
        assertNull(e(role = "Supervisor"))
        assertEquals("TRIP_CANCEL_AUTH_REQUIRED", e(user = null))
        assertEquals("TRIP_CANCEL_FORBIDDEN", e(role = "operator"))
        assertEquals("TRIP_CANCEL_FORBIDDEN", e(role = null))
        assertEquals("TRIP_CANCEL_NOT_LOCAL_END_PENDING", e(pending = false))
        assertEquals("TRIP_CANCEL_NOT_DEVICE_CLAIM", e(cTrip = otherTrip))
        assertEquals("TRIP_CANCEL_CLAIM_OWNER_MISMATCH", e(cOwner = "someone-else"))
        assertEquals("TRIP_CANCEL_CLAIM_VINEYARD_MISMATCH", e(cVy = "59973CED-1FB9-42EC-A66D-9EAAD3172824"))
    }

    // ---- planner ------------------------------------------------------------------------------

    @Test fun plannerMatchesOnlyThisTripAndItsSprayRecordAndRefusesInFlight() {
        val writes = listOf(
            write("w1", PendingEntityType.TRIP_TANK, trip),
            write("w2", PendingEntityType.TRIP_END, trip, PendingWriteStatus.BLOCKED),
            write("w3", PendingEntityType.SPRAY_RECORD, spray),
            write("w4", PendingEntityType.TRIP_TANK, otherTrip),
            write("w5", PendingEntityType.SPRAY_RECORD, "other-spray"),
            write("w6", PendingEntityType.TRIP_GPS, trip, PendingWriteStatus.SYNCED),
            write("w7", PendingEntityType.PIN, trip),
        )
        val ready = TripActivityCancellation.plan(writes, trip, listOf(spray)) as TripActivityCancellation.Plan.Ready
        assertEquals(listOf("w1", "w2", "w3"), ready.writes.map { it.id })
        val refused = TripActivityCancellation.plan(writes + write("w8", PendingEntityType.TRIP_GPS, trip, PendingWriteStatus.IN_PROGRESS), trip, listOf(spray))
        assertEquals(TripActivityCancellation.Plan.Refused("TRIP_CANCEL_WRITE_IN_FLIGHT", listOf("w8")), refused)
    }

    // ---- receipt verification -----------------------------------------------------------------

    @Test fun receiptVerificationChecksEveryIdentityField() {
        val intent = TripActivityCancellation.Intent(opId, owner, vineyard, trip, "applied", listOf(spray), emptyList(),
            JsonObject(emptyMap()), null, "/x", TripActivityCancellation.State.REQUESTED, 1)
        val good = receiptFor(intent)
        assertEquals(TripActivityCancellation.ReceiptCheck.Valid, TripActivityCancellation.verifyReceipt(good, intent))
        fun bad(key: String, value: String?) = JsonObject(good.toMutableMap().apply { if (value == null) remove(key) else put(key, JsonPrimitive(value)) })
        listOf("status" to "PENDING", "trip_id" to otherTrip, "vineyard_id" to "x", "operation_id" to "other-op",
            "application_classification" to "not_applied").forEach { (k, v) ->
            val r = TripActivityCancellation.verifyReceipt(bad(k, v), intent)
            assertTrue("$k should be invalid", r is TripActivityCancellation.ReceiptCheck.Invalid)
        }
        assertEquals(TripActivityCancellation.ReceiptCheck.Invalid("compliance_archive_id"),
            TripActivityCancellation.verifyReceipt(bad("compliance_archive_id", null), intent))
        assertEquals(TripActivityCancellation.ReceiptCheck.Invalid("server_revision"),
            TripActivityCancellation.verifyReceipt(JsonObject(good + ("server_revision" to JsonPrimitive(0))), intent))
        // Another device's durable receipt for the same Trip/vineyard is authoritative.
        assertEquals(TripActivityCancellation.ReceiptCheck.Valid,
            TripActivityCancellation.verifyReceipt(bad("operation_id", "other-op"), intent, acceptOtherOperation = true))
        assertEquals("TRIP_CANCEL_FORBIDDEN", TripActivityCancellation.serverCode("{\"message\":\"TRIP_CANCEL_FORBIDDEN: user x\"}"))
        assertNull(TripActivityCancellation.serverCode("{\"message\":\"boom\"}"))
    }

    @Test fun complianceFactsAreVerbatimRecordedActuals() {
        val facts = TripActivityCancellation.complianceFacts(trip, vineyard, listOf(actual))
        val tank = facts["tanks"]!!.jsonArray.single().jsonObject
        assertEquals("1234.5", tank["water_volume_l"]!!.jsonPrimitive.content)
        assertEquals(actual.tankSessionId, tank["tank_session_id"]!!.jsonPrimitive.content)
        val chem = tank["chemicals"]!!.jsonArray.single().jsonObject
        assertEquals("2.75", chem["actual_amount_base"]!!.jsonPrimitive.content)
        assertEquals("Kg", chem["unit"]!!.jsonPrimitive.content)
        assertEquals("plan-1", chem["planned_chemical_id"]!!.jsonPrimitive.content)
    }

    // ---- coordinator --------------------------------------------------------------------------

    @Test fun unknownClassificationIsHeldAndNothingIsSentOrRemoved() = runBlocking {
        val h = harness(); h.local.actuals += actual
        val out = h.coordinator.cancel(request(TripActivityCancellation.Classification.UNKNOWN), listOf(spray))
        assertEquals(TripActivityCancellationCoordinator.Outcome.Refused("TRIP_CANCEL_CLASSIFICATION_UNKNOWN_HELD"), out)
        assertTrue(h.remote.sent.isEmpty()); assertTrue(h.storage.map.isEmpty()); assertEquals(1, h.local.actuals.size)
    }

    @Test fun notAppliedWithRecordedActualsNeedsExplicitConfirmation() = runBlocking {
        val h = harness(); h.local.actuals += actual
        val out = h.coordinator.cancel(request(TripActivityCancellation.Classification.NOT_APPLIED), listOf(spray))
        assertEquals(TripActivityCancellationCoordinator.Outcome.Refused("TRIP_CANCEL_LOCAL_ACTUALS_REQUIRE_CONFIRMATION"), out)
        assertTrue(h.remote.sent.isEmpty())
    }

    @Test fun unreadableJournalRefusesInsteadOfRecordingAbsent() = runBlocking {
        val h = harness(); h.local.journalThrows = true
        val out = h.coordinator.cancel(request(TripActivityCancellation.Classification.NOT_APPLIED), listOf(spray))
        assertEquals(TripActivityCancellationCoordinator.Outcome.Refused("TRIP_CANCEL_EVIDENCE_UNREADABLE"), out)
        assertTrue(h.remote.sent.isEmpty()); assertTrue(h.evidenceDir.listFiles()!!.isEmpty())
    }

    @Test fun appliedWithoutRecordedActualsIsRefusedBeforeRequest() = runBlocking {
        val h = harness()
        val out = h.coordinator.cancel(request(TripActivityCancellation.Classification.APPLIED), listOf(spray))
        assertEquals(TripActivityCancellationCoordinator.Outcome.Refused("TRIP_CANCEL_COMPLIANCE_FACTS_REQUIRED"), out)
        assertTrue(h.remote.sent.isEmpty()); assertTrue(h.storage.map.isEmpty())
    }

    @Test fun inFlightWriteRefusesBeforeEvidenceOrRequest() = runBlocking {
        val h = harness(); h.local.writes += write("w1", PendingEntityType.TRIP_END, trip, PendingWriteStatus.IN_PROGRESS)
        val out = h.coordinator.cancel(request(TripActivityCancellation.Classification.NOT_APPLIED), listOf(spray))
        assertEquals(TripActivityCancellationCoordinator.Outcome.Refused("TRIP_CANCEL_WRITE_IN_FLIGHT"), out)
        assertTrue(h.remote.sent.isEmpty()); assertEquals(1, h.local.writes.size)
    }

    @Test fun appliedHappyPathSavesEvidenceThenIntentThenAcksBeforeExactCleanup() = runBlocking {
        val h = harness()
        h.local.actuals += actual
        val unrelated = write("u1", PendingEntityType.TRIP_TANK, otherTrip)
        h.local.writes += listOf(write("w1", PendingEntityType.TRIP_END, trip, PendingWriteStatus.BLOCKED),
            write("w2", PendingEntityType.SPRAY_RECORD, spray), unrelated)
        val out = h.coordinator.cancel(request(TripActivityCancellation.Classification.APPLIED), listOf(spray))
        assertTrue(out is TripActivityCancellationCoordinator.Outcome.Acked && out.cleaned)
        // Intent was durably REQUESTED before the request left the device.
        assertEquals(TripActivityCancellation.State.REQUESTED, h.remote.intentStateAtSend)
        val sent = h.remote.sent.single()
        assertEquals(opId, sent.operationId); assertEquals("applied", sent.classification)
        assertEquals("2.75", sent.complianceFacts!!["tanks"]!!.jsonArray[0].jsonObject["chemicals"]!!.jsonArray[0].jsonObject["actual_amount_base"]!!.jsonPrimitive.content)
        // Evidence retained on disk with original bytes.
        val evidence = Json.parseToJsonElement(java.io.File(h.evidenceDir, "$opId.json").readText()).jsonObject
        assertEquals("{\"journal\":1}", evidence["occurrence_journal_raw"]!!.jsonPrimitive.content)
        assertEquals(1, evidence["local_tank_actuals"]!!.jsonArray.size)
        assertEquals(2, evidence["matching_pending_writes"]!!.jsonArray.size)
        // Only this Trip's dependents removed; unrelated Trip queue untouched.
        assertEquals(listOf(unrelated), h.local.writes)
        assertTrue(h.local.actuals.isEmpty()); assertNull(h.local.journal); assertNull(h.local.claim)
        assertEquals(TripActivityCancellation.State.CLEANED, h.store.find(trip)!!.state)
        assertFalse(h.store.holdsTrip(trip))
    }

    @Test fun ackCommitFailureRemovesNothing() = runBlocking {
        val h = harness(); h.local.actuals += actual
        h.local.writes += write("w1", PendingEntityType.TRIP_END, trip)
        h.remote.cancelResult = { h.storage.failNextCommits = 1; receiptFor(it) }
        val out = h.coordinator.cancel(request(TripActivityCancellation.Classification.APPLIED), listOf(spray))
        assertEquals(TripActivityCancellationCoordinator.Outcome.Pending("TRIP_CANCEL_ACK_NOT_SAVED"), out)
        assertEquals(1, h.local.writes.size); assertEquals(1, h.local.actuals.size); assertTrue(h.local.log.isEmpty())
        assertTrue(h.store.holdsTrip(trip))
    }

    @Test fun lostResponseReadsBackThenReplaysSameOperationId() = runBlocking {
        val h = harness()
        h.local.writes += write("w1", PendingEntityType.TRIP_END, trip)
        h.remote.cancelResult = { throw java.io.IOException("socket closed") }
        val first = h.coordinator.cancel(request(TripActivityCancellation.Classification.NOT_APPLIED), listOf(spray))
        assertEquals(TripActivityCancellationCoordinator.Outcome.Pending("TRIP_CANCEL_RESPONSE_UNKNOWN"), first)
        assertTrue(h.store.holdsTrip(trip)); assertEquals(1, h.local.writes.size)
        // Restart: readback absent -> replay with the SAME operation id.
        h.remote.cancelResult = { receiptFor(it) }
        h.remote.readResult = null
        val results = h.coordinator.reconcileAll()
        assertTrue((results.single().second as TripActivityCancellationCoordinator.Outcome.Acked).cleaned)
        assertEquals(listOf(opId, opId), h.remote.sent.map { it.operationId })
        assertTrue(h.local.writes.isEmpty())
    }

    @Test fun lostResponseResolvedByReadbackWithoutResend() = runBlocking {
        val h = harness()
        h.remote.cancelResult = { throw java.io.IOException("timeout") }
        h.coordinator.cancel(request(TripActivityCancellation.Classification.NOT_APPLIED), listOf(spray))
        h.remote.readResult = receiptFor(h.store.find(trip)!!)
        val out = h.coordinator.reconcile(h.store.find(trip)!!)
        assertTrue(out is TripActivityCancellationCoordinator.Outcome.Acked)
        assertEquals(1, h.remote.sent.size)
    }

    @Test fun definitiveRefusalLeavesAllLocalDataAndReleasesHold() = runBlocking {
        val h = harness(); h.local.actuals += actual
        h.local.writes += write("w1", PendingEntityType.TRIP_END, trip)
        h.remote.cancelResult = { throw TripActivityCancellationCoordinator.ServerRefusal(400, "TRIP_CANCEL_SERVER_ACTUALS_REQUIRE_APPLIED_REVIEW") }
        val out = h.coordinator.cancel(request(TripActivityCancellation.Classification.NOT_APPLIED, confirmed = true), listOf(spray))
        assertEquals(TripActivityCancellationCoordinator.Outcome.Refused("TRIP_CANCEL_SERVER_ACTUALS_REQUIRE_APPLIED_REVIEW"), out)
        assertEquals(1, h.local.writes.size); assertEquals(1, h.local.actuals.size); assertTrue(h.local.log.isEmpty())
        assertEquals(TripActivityCancellation.State.REFUSED, h.store.find(trip)!!.state)
        assertFalse(h.store.holdsTrip(trip))
        assertTrue(java.io.File(h.evidenceDir, "$opId.json").exists())
    }

    @Test fun alreadyCancelledByOtherOperationAcceptsServerReceipt() = runBlocking {
        val h = harness(); h.local.writes += write("w1", PendingEntityType.TRIP_END, trip)
        h.remote.cancelResult = { throw TripActivityCancellationCoordinator.ServerRefusal(409, "TRIP_CANCEL_ALREADY_CANCELLED_OTHER_OPERATION") }
        h.remote.readResult = buildJsonObject {
            put("status", "CANCELLED_ACKED"); put("trip_id", trip); put("vineyard_id", vineyard)
            put("operation_id", "eeeeeeee-0000-4000-8000-000000000005"); put("application_classification", "applied")
            put("server_revision", 3); put("compliance_archive_id", "x")
        }
        val out = h.coordinator.cancel(request(TripActivityCancellation.Classification.NOT_APPLIED), listOf(spray))
        assertTrue(out is TripActivityCancellationCoordinator.Outcome.Acked && out.cleaned)
        assertTrue(h.local.writes.isEmpty())
    }

    @Test fun mismatchedReceiptIsHeldAndNothingRemoved() = runBlocking {
        val h = harness(); h.local.writes += write("w1", PendingEntityType.TRIP_END, trip)
        h.remote.cancelResult = { receiptFor(it, classification = "applied") }
        val out = h.coordinator.cancel(request(TripActivityCancellation.Classification.NOT_APPLIED), listOf(spray))
        assertEquals(TripActivityCancellationCoordinator.Outcome.Refused("TRIP_CANCEL_RECEIPT_MISMATCH"), out)
        assertEquals(1, h.local.writes.size)
        assertEquals("TRIP_CANCEL_RECEIPT_MISMATCH_CLASSIFICATION", h.store.find(trip)!!.lastCode)
        assertTrue(h.store.holdsTrip(trip))
    }

    @Test fun ackedButIncompleteCleanupIsFinishedOnReconcile() = runBlocking {
        val h = harness()
        val held = write("w1", PendingEntityType.TRIP_END, trip)
        h.local.writes += held
        // First cleanup sees an IN_PROGRESS row appear after ack (concurrent replay) -> not cleaned.
        h.remote.cancelResult = {
            h.local.writes.clear(); h.local.writes += held.copy(status = PendingWriteStatus.IN_PROGRESS); receiptFor(it)
        }
        val out = h.coordinator.cancel(request(TripActivityCancellation.Classification.NOT_APPLIED), listOf(spray))
        assertTrue(out is TripActivityCancellationCoordinator.Outcome.Acked && !out.cleaned)
        assertEquals(TripActivityCancellation.State.ACKED, h.store.find(trip)!!.state)
        assertTrue(h.store.holdsTrip(trip))
        h.local.writes.clear(); h.local.writes += held
        val again = h.coordinator.reconcileAll().single().second
        assertTrue(again is TripActivityCancellationCoordinator.Outcome.Acked && again.cleaned)
        assertTrue(h.local.writes.isEmpty())
        assertEquals(TripActivityCancellation.State.CLEANED, h.store.find(trip)!!.state)
    }
}
