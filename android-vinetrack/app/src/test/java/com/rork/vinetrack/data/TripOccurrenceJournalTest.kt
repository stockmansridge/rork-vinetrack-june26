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
    @Test fun unknownFieldsSurviveJournalProjection() { val j=journal(); j.setStatus(a,"done"); assertEquals(fixture()["extension"],j.projected(j.load()!!)["extension"]) }
}
