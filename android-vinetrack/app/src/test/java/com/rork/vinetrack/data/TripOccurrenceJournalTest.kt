package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.TripOccurrenceCoverage
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class TripOccurrenceJournalTest {
    private val a = "11111111-1111-4111-8111-111111111111"
    private val b = "22222222-2222-4222-8222-222222222222"
    private val scope = TripOccurrenceJournal.Scope("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
    private class Memory : TripOccurrenceJournal.Storage {
        var value: String? = null; var fail = false
        override fun read() = value
        override fun commit(value: String): Boolean { if (fail) return false; this.value = value; return true }
    }
    private fun fixture(otherBlock: Boolean = false): JsonObject = Json.parseToJsonElement("""
        {"contract":"vinetrack.planned-occurrence","schemaVersion":1,"planId":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","revision":0,"planRevision":1,
        "items":[{"occurrenceId":"$a","blockId":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","blockNameSnapshot":"Block X","pathNumber":38.5,"passOrdinal":1,"physicalPathRef":{"pathId":"ffffffff-ffff-4fff-8fff-ffffffffffff","rowIds":[],"geometryRevision":"unresolved"}},
        {"occurrenceId":"$b","blockId":"${if (otherBlock) "99999999-9999-4999-8999-999999999999" else "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"}","blockNameSnapshot":"${if (otherBlock) "Block Y" else "Block X"}","pathNumber":38.5,"passOrdinal":2,"physicalPathRef":{"pathId":"${if (otherBlock) "88888888-8888-4888-8888-888888888888" else "ffffffff-ffff-4fff-8fff-ffffffffffff"}","rowIds":[],"geometryRevision":"unresolved"}}],
        "activeOrder":["$a","$b"],"retired":[],"states":{"$a":{"status":"incomplete","source":null,"lastOperationId":null,"tankSessionIds":[]},"$b":{"status":"incomplete","source":null,"lastOperationId":null,"tankSessionIds":[]}},"plannedCursorId":"$a","selectedOccurrenceId":null,"extension":{"retain":true}}
        """).jsonObject
    private fun journal(storage: Memory = Memory(), otherBlock: Boolean = false): TripOccurrenceJournal =
        TripOccurrenceJournal(storage, scope).also { if (it.load() == null) it.initialize(fixture(otherBlock)) }
    private fun status(j: TripOccurrenceJournal, id: String) = TripOccurrenceCoverage.requireDocument(j.projected(j.load()!!)).status(id)
    private fun ack(op: TripOccurrenceJournal.Operation) = buildJsonObject { put("tripId", scope.tripId); put("operationId", op.id); put("coverage", op.after) }

    @Test fun blockQualifiedPlannerKeepsFourSameLabelPassesAndSubset() {
        val blocks = listOf("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", "99999999-9999-4999-8999-999999999999").mapIndexed { index, id ->
            com.rork.vinetrack.data.model.Paddock(id = id, vineyardId = scope.vineyardId, name = "Block $index", rows = listOf(
                com.rork.vinetrack.data.model.PaddockRow(number = 38), com.rork.vinetrack.data.model.PaddockRow(number = 39)))
        }
        val choices = TripOccurrencePlanner.candidates(blocks).filter { it.label == 38.5 }
        assertEquals(2, choices.size); assertEquals(2, choices.map { it.key }.toSet().size)
        val planned = TripOccurrencePlanner.plan(choices, TrackingPattern.UP_AND_BACK, choices.last().key, true)
        assertEquals(listOf(blocks[1].id, blocks[1].id, blocks[0].id, blocks[0].id), planned.map { it.blockId })
        val coverage = TripOccurrencePlanner.commit(planned, scope.vineyardId)
        val d = TripOccurrenceCoverage.requireDocument(coverage)
        assertEquals(4, d.items.map { it.id }.toSet().size); assertEquals(listOf(1,2,1,2), d.items.map { it.pass })
        assertEquals(listOf(38.5,38.5,38.5,38.5), d.items.map { it.label })
        assertEquals(1, TripOccurrencePlanner.candidates(blocks.take(1)).filter { it.label == 38.5 }.size)
        assertTrue(TripOccurrencePlanner.candidates(blocks).filter { it.label == 38.5 } == choices)
    }

    @Test fun offlineCreateActivationChainRetainsExactIDsAfterRecreationAndProjection() {
        val candidates = listOf(TripOccurrencePlanner.Candidate(scope.vineyardId, "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", "A", 38.5, emptyList()),
            TripOccurrencePlanner.Candidate(scope.vineyardId, "99999999-9999-4999-8999-999999999999", "B", 38.5, emptyList()))
        val coverage = TripOccurrencePlanner.commit(TripOccurrencePlanner.plan(candidates, TrackingPattern.UP_AND_BACK, candidates[0].key, true), scope.vineyardId)
        val initial = TripOccurrenceCoverage.requireDocument(coverage)
        val memory = Memory(); var j = TripOccurrenceJournal(memory, scope)
        val metadata = buildJsonObject { put("id", scope.tripId); put("vineyard_id", scope.vineyardId); put("is_active", false); put("trip_title", "Kept title") }
        val create = j.prepareCreation(metadata, coverage)
        val activate = j.activate(buildJsonObject { put("startTime", "2026-10-14T08:00:00Z"); put("startEngineHours", 123.5) })
        j = TripOccurrenceJournal(memory, scope)
        assertEquals(listOf(create.params, activate.params), j.load()!!.pending.map { it.params })
        assertTrue(runCatching { j.setStatus(initial.order.first(), "done") }.isFailure)
        j.acknowledge(ack(create)); j.acknowledge(ack(activate))
        val projected = Trip(scope.tripId, scope.vineyardId, occurrenceCoverage = coverage, isActive = true).withOccurrenceProjection(j.projected(j.load()!!))
        val restored = Json.decodeFromString(Trip.serializer(), Json.encodeToString(Trip.serializer(), projected))
        assertEquals(initial.order, restored.occurrenceDocument!!.order)
        assertEquals(4, restored.rowSequence.size); assertTrue(restored.completedPaths.orEmpty().isEmpty())
        assertEquals(metadata, j.load()!!.history.first().params["p_trip"])
    }

    @Test fun replacementRetiresDoneEvidenceAndNeverInheritsCoverage() {
        val j = journal(); j.setStatus(a, "done"); j.reorder(listOf(b,a))
        val candidate = TripOccurrencePlanner.Candidate(scope.vineyardId, "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", "Block X", 38.5, emptyList())
        val item = TripOccurrencePlanner.commit(listOf(candidate), scope.vineyardId).getValue("items").jsonArray.single().jsonObject
        val newId = item.getValue("occurrenceId").jsonPrimitive.content
        j.replaceOccurrence(a, item)
        val d = TripOccurrenceCoverage.requireDocument(j.projected(j.load()!!))
        assertEquals(listOf(b,newId), d.order); assertEquals(listOf(a), d.retired)
        assertEquals("done", d.status(a)); assertEquals("incomplete", d.status(newId)); assertEquals("incomplete", d.status(b))
        assertTrue(runCatching { j.replaceOccurrence(b, item) }.isFailure)
    }

    @Test fun linkedRecipeCannotReplayBeforeOccurrenceParentConfirmation() = kotlinx.coroutines.runBlocking {
        val store = InMemoryPendingWriteStore()
        val pending = PendingWriteRepository(store)
        val payload = SprayRecordCreateSync.Payload(id = a, vineyardId = scope.vineyardId,
            date = "2026-10-14", startTime = "2026-10-14T08:00:00Z", tripId = scope.tripId,
            clientUpdatedAt = "2026-10-14T08:00:00Z", requiresOccurrenceParent = true, notes = "Retained recipe notes")
        val encoded = Json.encodeToString(SprayRecordCreateSync.Payload.serializer(), payload)
        pending.enqueue(com.rork.vinetrack.data.model.PendingEntityType.SPRAY_RECORD, com.rork.vinetrack.data.model.PendingOpType.CREATE,
            clientId = a, payloadJson = encoded)
        var calls = 0
        val replay = SprayRecordCreateSync(null, PendingWriteRepository(store), createRemote = {
            calls++; error("No unconfirmed parent may issue HTTP")
        })
        replay.replayAll { fail("Unconfirmed recipe cannot be published") }
        assertEquals(0, calls); assertEquals(encoded, pending.list().single().payloadJson)
        assertEquals(com.rork.vinetrack.data.model.PendingWriteStatus.PENDING, PendingWriteRepository(store).list().single().status)
    }

    @Test fun plannerRejectsCrossVineyardCommit() {
        val candidate = TripOccurrencePlanner.Candidate("99999999-9999-4999-8999-999999999999", "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", "X", 38.5, emptyList())
        assertTrue(runCatching { TripOccurrencePlanner.commit(listOf(candidate), scope.vineyardId) }.isFailure)
    }

    @Test fun aDoneLeavesBIncomplete() { val j = journal(); j.setStatus(a, "done"); assertEquals("done", status(j,a)); assertEquals("incomplete", status(j,b)) }
    @Test fun bDoneLeavesAIncomplete() { val j = journal(); j.setStatus(b, "done"); assertEquals("incomplete", status(j,a)); assertEquals("done", status(j,b)) }
    @Test fun doneSkipAndUndoRemainIndependent() { val j = journal(); val op = j.setStatus(a,"done"); j.setStatus(b,"skipped"); j.undo(op.id); assertEquals("incomplete",status(j,a)); assertEquals("skipped",status(j,b)) }
    @Test fun skipToDoneChangesOnlySelectedOccurrence() { val j = journal(); j.select(b); j.setStatus(b,"skipped"); j.setStatus(b,"done"); assertEquals("incomplete",status(j,a)); assertEquals("done",status(j,b)) }
    @Test fun reorderedIDsAndStatesSurvive() { val j = journal(); j.setStatus(a,"done"); j.reorder(listOf(b,a)); val d=TripOccurrenceCoverage.requireDocument(j.projected(j.load()!!)); assertEquals(listOf(b,a),d.order); assertEquals("done",d.status(a)); assertEquals("incomplete",d.status(b)) }
    @Test fun restartDoneSkipUndoRestoresDone() { val storage=Memory(); var j=journal(storage); j.setStatus(a,"done"); val skip=j.setStatus(a,"skipped"); j=journal(storage); j.undo(skip.id); assertEquals("done",status(j,a)); assertEquals("incomplete",status(j,b)); assertEquals(3,j.load()!!.pending.size) }
    @Test fun delayedDuplicateAcknowledgementPreservesNewerLocalAction() { val j=journal(); val done=j.setStatus(a,"done"); val skip=j.setStatus(a,"skipped"); j.acknowledge(ack(done)); j.acknowledge(ack(done)); assertEquals("skipped",status(j,a)); assertEquals(listOf(skip),j.load()!!.pending); j.acknowledge(ack(skip)); j.acknowledge(ack(done)); assertEquals("skipped",status(j,a)) }
    @Test fun uncertainRetryRetainsExactWireAfterRecreation() { val storage=Memory(); val j=journal(storage); val op=j.setStatus(a,"done"); val recreated=journal(storage); assertEquals(op.params,recreated.load()!!.pending.single().params); assertEquals(op.id,recreated.load()!!.pending.single().id) }
    @Test fun remoteConflictHoldsWithoutRebaseOrLoss() { val j=journal(); val local=j.setStatus(a,"done"); val other=journal(); other.setStatus(b,"skipped"); j.reconcile(other.projected(other.load()!!)); assertNotNull(j.load()!!.heldReason); assertEquals(local.params,j.load()!!.pending.single().params); assertEquals("done",status(j,a)); assertEquals("incomplete",status(j,b)) }
    @Test fun guardRejectionHeldAndNeverNumericSuccess() { val j=journal(); val op=j.setStatus(a,"done"); j.hold("OCCURRENCE_UPDATE_REQUIRED"); assertTrue(j.load()!!.heldReason!!.contains("Update required")); assertEquals(op,j.load()!!.pending.single()); assertEquals("done",status(j,a)) }
    @Test fun sameLabelsDifferentBlocksStaySeparate() { val j=journal(otherBlock=true); j.setStatus(a,"done"); assertEquals("incomplete",status(j,b)); assertEquals(2,TripOccurrenceCoverage.requireDocument(j.projected(j.load()!!)).items.map { it.blockId }.distinct().size) }
    @Test fun failedDurableWritePublishesNoAction() { val storage=Memory(); val j=journal(storage); storage.fail=true; assertTrue(runCatching { j.setStatus(a,"done") }.isFailure); assertEquals("incomplete",status(j,a)); assertTrue(j.load()!!.pending.isEmpty()) }
    @Test fun tripRoundTripAndUnsupportedPreserveRawWithoutNumericFallback() {
        val json=Json { encodeDefaults=true }; val source=Trip(scope.tripId,scope.vineyardId,completedPaths=listOf(38.5),occurrenceCoverage=fixture())
        val restored=json.decodeFromString<Trip>(json.encodeToString(Trip.serializer(),source)); assertEquals(source.occurrenceCoverage,restored.occurrenceCoverage); assertEquals(0,restored.completedRowCount); assertEquals(2,restored.notCompletedRowCount)
        val future=JsonObject(fixture().toMutableMap().also { it["schemaVersion"]=JsonPrimitive(99) }); val held=source.copy(occurrenceCoverage=future)
        assertEquals(TripOccurrenceCoverage.Basis.UPDATE_REQUIRED,held.coverageBasis); assertNotNull(held.coverageMessage); assertEquals(0,held.completedRowCount)
        assertEquals(1,source.copy(occurrenceCoverage=null).completedRowCount)
    }
    private fun recovery(j: TripOccurrenceJournal, op: TripOccurrenceJournal.Operation?, receipts: Boolean = false): JsonObject {
        val coverage = j.projected(j.load()!!)
        val row = op?.let { buildJsonObject {
            put("operationId",it.id); put("tripId",scope.tripId); put("actorId",scope.ownerId)
            put("request",buildJsonObject { put("tripId",scope.tripId); put("expectedRevision",it.params.getValue("p_expected_revision")); put("expectedPlanRevision",it.params.getValue("p_expected_plan_revision")); put("action",it.action) })
            put("result",ack(it)); put("previousState",TripOccurrenceCoverage.requireDocument(it.before).state(a))
            put("resultingState",TripOccurrenceCoverage.requireDocument(it.after).state(a))
        } }
        return buildJsonObject {
            put("contract","vinetrack.occurrence-recovery"); put("schemaVersion",1); put("tripId",scope.tripId); put("vineyardId",scope.vineyardId)
            put("isActive",true); put("coverage",coverage); put("reversibleOperations",JsonArray(listOfNotNull(row)))
            put("receipts",JsonArray(if (receipts) listOfNotNull(row) else emptyList()))
        }
    }
    @Test fun reinstallRecoversActualUndoFromServerLedger() {
        val server=journal(); server.setStatus(a,"done"); val skip=server.setStatus(a,"skipped")
        val restored=TripOccurrenceJournal(Memory(),scope); restored.recover(recovery(server,skip))
        assertEquals(skip.id,restored.undoTarget()!!.id); restored.undo(skip.id)
        assertEquals("done",status(restored,a)); assertEquals("incomplete",status(restored,b))
    }
    @Test fun uncertainAcceptedActionRecoveredByExactReceipt() {
        val j=journal(); val op=j.setStatus(a,"done")
        j.recover(recovery(j,op,receipts=true)); assertTrue(j.load()!!.pending.isEmpty()); assertEquals("done",status(j,a))
        assertEquals(op.id,j.undoTarget()!!.id)
    }
    @Test fun unverifiedReceiptCannotClearPendingWork() {
        val j=journal(); val op=j.setStatus(a,"done"); val response=recovery(j,op,true)
        val bad=JsonObject(response.toMutableMap().also { it["receipts"]=JsonArray(response.getValue("receipts").jsonArray.map { row -> JsonObject(row.jsonObject.toMutableMap().also { r -> r["actorId"]=JsonPrimitive("99999999-9999-4999-8999-999999999999") }) }) })
        assertTrue(runCatching { j.recover(bad) }.isFailure); assertEquals(listOf(op),j.load()!!.pending)
    }
    @Test fun creationAndActivationNeedExactDurableAcknowledgement() {
        val j=TripOccurrenceJournal(Memory(),scope)
        val metadata=buildJsonObject { put("id",scope.tripId); put("vineyard_id",scope.vineyardId); put("is_active",false); put("trip_title","Keep this"); put("seeding_details",buildJsonObject { put("note","retain") }) }
        val create=j.prepareCreation(metadata,fixture()); assertEquals(metadata,create.params["p_trip"])
        assertTrue(runCatching { j.setStatus(a,"done") }.isFailure); assertFalse(j.load()!!.creationConfirmed)
        j.acknowledge(ack(create)); val activation=j.activate(buildJsonObject { put("startTime","2026-10-14T08:00:00Z") })
        assertTrue(runCatching { j.setStatus(a,"done") }.isFailure); j.acknowledge(ack(activation)); j.setStatus(a,"done")
        assertEquals("done",status(j,a))
    }
    @Test fun finalisationFreezesExactOccurrenceReviewAndRetainsPendingActionOrder() {
        val j=journal(); val done=j.setStatus(a,"done"); val skip=j.setStatus(b,"skipped")
        val final=j.finalize(buildJsonObject { put("endTime","2026-10-14T09:00:00Z") })
        assertEquals(listOf(done.id,skip.id,final.id),j.load()!!.pending.map { it.id })
        assertEquals(TripOccurrenceCoverage.requireDocument(skip.after).raw["states"],final.params["p_reviewed_states"])
        assertTrue(runCatching { j.setStatus(a,"incomplete") }.isFailure)
        j.acknowledge(ack(done)); j.acknowledge(ack(skip)); j.acknowledge(ack(final))
        assertFalse(j.load()!!.serverActive!!); assertEquals("done",status(j,a)); assertEquals("skipped",status(j,b))
    }
    @Test fun sharedPostgresTranscriptSurvivesKotlinRecoveryUndoAndFinalReload() {
        val resource=javaClass.classLoader!!.getResourceAsStream("occurrence-recovery-postgres.json") ?: error("Shared PostgreSQL transcript missing")
        val fixtures=resource.bufferedReader().use { Json.parseToJsonElement(it.readText()).jsonObject.getValue("fixtures").jsonArray }
        assertEquals(2,fixtures.size)
        fixtures.forEach { value ->
            val f=value.jsonObject; val fixtureScope=Json.decodeFromJsonElement(TripOccurrenceJournal.Scope.serializer(),f.getValue("scope"))
            val journal=TripOccurrenceJournal(Memory(),fixtureScope); journal.recover(f.getValue("recovery").jsonObject)
            val remote=TripOccurrenceCoverage.requireDocument(journal.projected(journal.load()!!)); val id=remote.items.first().id
            assertEquals(listOf("skipped","incomplete"),remote.items.map { remote.status(it.id) })
            val reversible=journal.undoTarget() ?: error("Actual server ledger operation not recovered")
            journal.undo(reversible.id)
            val local=TripOccurrenceCoverage.requireDocument(journal.projected(journal.load()!!))
            val expected=TripOccurrenceCoverage.requireDocument(f.getValue("undoResult").jsonObject.getValue("coverage"))
            assertEquals(expected.items,local.items); assertEquals(expected.order,local.order)
            assertEquals(expected.items.map { expected.status(it.id) },local.items.map { local.status(it.id) })
            assertEquals("done",local.status(id))
            val trip=Json { ignoreUnknownKeys=true }.decodeFromJsonElement(Trip.serializer(),f.getValue("backendTrip"))
            assertEquals(listOf("done","skipped"),trip.occurrenceDocument!!.items.map { trip.occurrenceDocument!!.status(it.id) })
            assertEquals(1,trip.completedRowCount); assertEquals(1,trip.skippedRowCount); assertTrue(trip.completedPaths!!.isEmpty()); assertFalse(trip.isActive)
        }
    }
    @Test fun v2ReportRowsRetainPassIdentityAndDisplayContext() {
        val json=Json { ignoreUnknownKeys=true }
        val raw="""{"rowNumber":38.5,"blockName":"Block X","status":"Complete","source":"manual","tank":null,"rowIdentity":"$a","occurrenceId":"$a","blockId":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","planId":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","passOrdinal":1,"state":"done","isRetired":false,"tankSessionIds":[],"lastOperationId":null}"""
        val row=json.decodeFromString<com.rork.vinetrack.data.reporting.SprayReportPayloadV1.Row>(raw)
        assertEquals(a,row.occurrenceId); assertEquals("done",row.state); assertEquals("Block X · 38.5 · Pass 1",row.displayLabel)
        assertEquals(row,json.decodeFromString<com.rork.vinetrack.data.reporting.SprayReportPayloadV1.Row>(json.encodeToString(com.rork.vinetrack.data.reporting.SprayReportPayloadV1.Row.serializer(),row)))
    }
    @Test fun unknownFieldsSurviveJournalProjection() { val j=journal(); j.setStatus(a,"done"); assertEquals(fixture()["extension"],j.projected(j.load()!!)["extension"]) }
}
