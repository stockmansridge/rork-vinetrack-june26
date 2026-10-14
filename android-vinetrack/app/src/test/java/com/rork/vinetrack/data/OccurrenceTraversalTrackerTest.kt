package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.TripOccurrenceCoverage
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class OccurrenceTraversalTrackerTest {
    private val a = "00000000-0000-4000-8000-000000000001"
    private val b = "00000000-0000-4000-8000-000000000002"
    private val block = "00000000-0000-4000-8000-000000000003"
    private val physical = "00000000-0000-4000-8000-000000000004"
    private val scope = TripOccurrenceJournal.Scope(block,block,physical)
    private fun document(length: Double = 30.0, differentBlock: Boolean = false, skipped: Boolean = false): JsonObject {
        fun row(x: Double) = buildJsonObject {
            put("number",if (x < 0) 38 else 39)
            put("startPoint",buildJsonObject { put("latitude",0.0);put("longitude",x/111320) })
            put("endPoint",buildJsonObject { put("latitude",length/111320);put("longitude",x/111320) })
        }
        return buildJsonObject {
            put("contract",TripOccurrenceCoverage.CONTRACT); put("schemaVersion",1); put("revision",0);put("planRevision",1);put("planId",physical)
            put("items",JsonArray(listOf(a,b).map { id -> buildJsonObject {
                put("occurrenceId",id);put("blockId",if(differentBlock && id == b) b else block);put("blockNameSnapshot","Block");put("pathNumber",38.5);put("passOrdinal",if(id==a)1 else 2)
                put("physicalPathRef", buildJsonObject { put("pathId",if(differentBlock && id==b)b else physical);put("geometryRevision","native-snapshot-v1");put("rowIds",JsonArray(listOf(JsonPrimitive(a),JsonPrimitive(b))));put("rowSnapshots",JsonArray(listOf(row(-4.0),row(4.0)))) })
            } }))
            put("activeOrder",JsonArray(listOf(JsonPrimitive(a),JsonPrimitive(b))));put("retired",JsonArray(emptyList()));put("selectedOccurrenceId",JsonNull);put("plannedCursorId",a)
            put("states",JsonObject(listOf(a,b).associateWith { buildJsonObject { put("status",if(skipped && it==a)"skipped" else "incomplete");put("source",JsonNull);put("lastOperationId",JsonNull);put("tankSessionIds",JsonArray(emptyList())) } }))
        }
    }
    private fun fix(fraction: Double, index: Int, length: Double = 30.0, x: Double = 0.0, accuracy: Double = 1.0) =
        OccurrenceTraversalTracker.Fix(length*fraction/111320,x/111320,accuracy,100000L+index*3000)
    private fun traverse(t: OccurrenceTraversalTracker, raw: JsonObject = document(), length: Double = 30.0, x: Double = 0.0, accuracy: Double = 1.0): JsonObject? {
        val d=TripOccurrenceCoverage.requireDocument(raw)
        var result: JsonObject?=null
        listOf(.05,.35,.65,.95).forEachIndexed { i,f -> val p=fix(f,i,length,x,accuracy); result=t.observe(d,p,p.timeMs,true) ?: result }
        return result
    }
    @Test fun firstTankReviewPrecedesRecordingAndFillAloneDoesNotAdmitIt() {
        val trip = com.rork.vinetrack.data.model.Trip(id=a,vineyardId=block,isActive=true,tripFunction="spraying",totalTanks=2)
        assertTrue(TankSessionLifecycle.requiresFirstReview(trip))
        val fill = com.rork.vinetrack.data.model.TankSession(id=b,startTime="2026-10-14T08:00:00Z",fillStartTime="2026-10-14T08:00:00Z")
        assertTrue(TankSessionLifecycle.requiresFirstReview(trip.copy(tankSessions=listOf(fill))))
        val started = TankSessionLifecycle.startResult(trip,"2026-10-14T08:01:00Z",38.5,listOf(1,2))!!
        assertFalse(TankSessionLifecycle.requiresFirstReview(started.trip))
        assertNull(TankSessionLifecycle.startResult(started.trip,"2026-10-14T08:02:00Z",38.5,listOf(1,2)))
        val ended = TankSessionLifecycle.end(started.trip,"2026-10-14T08:30:00Z",38.5)
        assertFalse(TankSessionLifecycle.requiresFirstReview(ended))
        assertEquals(2,TankSessionLifecycle.startResult(ended,"2026-10-14T08:35:00Z",38.5,listOf(1,2))!!.tankNumber)
    }
    @Test fun normalFractionalTraversalProducesOneBoundOccurrence() {
        val e=traverse(OccurrenceTraversalTracker())!!
        assertEquals(a,e["occurrenceId"]!!.jsonPrimitive.content);assertEquals(4,e["qualifiedSamples"]!!.jsonPrimitive.int)
        assertTrue(e["longitudinalSpan"]!!.jsonPrimitive.double>=.8)
    }
    @Test fun shortPathStillRequiresFourTraversingObservations() {
        assertNotNull(traverse(OccurrenceTraversalTracker(),document(6.0),6.0))
        val t=OccurrenceTraversalTracker();val d=TripOccurrenceCoverage.requireDocument(document(6.0))
        listOf(.05,.95).forEachIndexed { i,f -> val p=fix(f,i,6.0);assertNull(t.observe(d,p,p.timeMs,true)) }
    }
    @Test fun endpointTouchesPartialAndTransverseCrossingDoNotComplete() {
        for(fractions in listOf(listOf(.92,.93,.94,.95),listOf(.05,.2,.4,.6),listOf(.5,.5,.5,.5))) {
            val t=OccurrenceTraversalTracker();val d=TripOccurrenceCoverage.requireDocument(document())
            fractions.forEachIndexed { i,f -> val p=fix(f,i);assertNull(t.observe(d,p,p.timeMs,true)) }
        }
    }
    @Test fun adjacentPoorAccuracyAndOverlappingBlocksAreRejected() {
        assertNull(traverse(OccurrenceTraversalTracker(),x=5.0));assertNull(traverse(OccurrenceTraversalTracker(),accuracy=8.0))
        assertNull(traverse(OccurrenceTraversalTracker(),document(differentBlock=true)))
    }
    @Test fun staleJumpedReversedAndUnorderedEvidenceResets() {
        val d=TripOccurrenceCoverage.requireDocument(document())
        val t=OccurrenceTraversalTracker();val p=fix(.05,0)
        assertNull(t.observe(d,p,p.timeMs+6000,true));assertNull(t.observe(d,p,p.timeMs,true))
        assertNull(t.observe(d,fix(.95,1).copy(timeMs=p.timeMs+1000),p.timeMs+1000,true))
        assertNull(t.observe(d,fix(.65,2),106000,true));assertNull(t.observe(d,fix(.95,3),109000,true))
    }
    @Test fun pauseResetAndCorrectionNeverBridgeEvidence() {
        val t=OccurrenceTraversalTracker();val d=TripOccurrenceCoverage.requireDocument(document())
        assertNull(t.observe(d,fix(.05,0),100000,true));assertNull(t.observe(d,fix(.35,1),103000,false))
        assertNull(t.observe(d,fix(.65,2),106000,true));assertNull(t.observe(d,fix(.95,3),109000,true))
        t.reset();assertNull(t.observe(d,fix(.95,4),112000,true))
    }
    @Test fun observationTimeBoundaryRejectsQueuedFixesFromBeforeCorrectionOrResume() {
        val t = OccurrenceTraversalTracker(); t.reset(110000)
        assertNull(traverse(t))
        val d = TripOccurrenceCoverage.requireDocument(document())
        val old = fix(.05, 2)
        assertFalse(t.departed(d,a,old,110000))
    }
    @Test fun adjacentContextFollowsGeometryAndCameraNotNumericOrder() {
        val d=TripOccurrenceCoverage.requireDocument(document())
        assertEquals(38.0 to 39.0, OccurrenceTraversalTracker.adjacentLabels(d,a,0.0))
        assertEquals(39.0 to 38.0, OccurrenceTraversalTracker.adjacentLabels(d,a,180.0))
    }
    @Test fun skippedOccurrenceCannotBeAutomaticallyDone() { assertNull(traverse(OccurrenceTraversalTracker(),document(skipped=true))) }
    @Test fun repeatedFinalAndOutOfOrderActionsUseJournalNotNumericMembership() {
        var bytes:String?=null
        val j=TripOccurrenceJournal(object:TripOccurrenceJournal.Storage {override fun read()=bytes;override fun commit(value:String):Boolean {bytes=value;return true}},scope)
        j.initialize(document());j.select(b)
        val evidence=traverse(OccurrenceTraversalTracker(),j.projected(j.load()!!))!!
        j.setStatus(b,"done",source="automatic",evidence=evidence)
        val d=TripOccurrenceCoverage.requireDocument(j.projected(j.load()!!))
        assertEquals("done",d.status(b));assertEquals("incomplete",d.status(a));assertEquals(a,d.targetId)
        j.setStatus(a,"skipped");j.undo(j.undoTarget()!!.id)
        assertEquals("incomplete",TripOccurrenceCoverage.requireDocument(j.projected(j.load()!!)).status(a))
        assertEquals(4,j.load()!!.pending.size)
    }
    @Test fun lastOutstandingPassCompletesWithoutEndingTripOrTank() {
        var bytes:String?=null
        val j=TripOccurrenceJournal(object:TripOccurrenceJournal.Storage {override fun read()=bytes;override fun commit(value:String):Boolean {bytes=value;return true}},scope)
        j.initialize(document());j.setStatus(a,"done")
        val evidence=traverse(OccurrenceTraversalTracker(),j.projected(j.load()!!))!!
        j.setStatus(b,"done",source="automatic",evidence=evidence)
        val d=TripOccurrenceCoverage.requireDocument(j.projected(j.load()!!))
        assertEquals(2,d.count("done"));assertNull(d.targetId)
        assertTrue(j.load()!!.pending.all { it.rpc=="apply_trip_occurrence_action_v1" })
        assertTrue(j.canOperate(j.load()!!))
    }
    @Test fun separateBlocksWithSameLabelChangeOnlyTheTarget() {
        val raw=document(differentBlock=true)
        val shiftedItems=raw.getValue("items").jsonArray.map { item ->
            if(item.jsonObject["occurrenceId"]!!.jsonPrimitive.content!=b)item else {
                val fields=item.jsonObject.toMutableMap();val ref=fields.getValue("physicalPathRef").jsonObject.toMutableMap()
                ref["rowSnapshots"]=JsonArray(ref.getValue("rowSnapshots").jsonArray.map { row ->
                    JsonObject(row.jsonObject.toMutableMap().also { r -> listOf("startPoint","endPoint").forEach { key ->
                        r[key]=JsonObject(r.getValue(key).jsonObject.toMutableMap().also { c -> c["longitude"]=JsonPrimitive(c.getValue("longitude").jsonPrimitive.double+0.001) })
                    } })
                });fields["physicalPathRef"]=JsonObject(ref);JsonObject(fields)
            }
        }
        val shifted=JsonObject(raw.toMutableMap().also { it["items"]=JsonArray(shiftedItems) })
        val evidence=traverse(OccurrenceTraversalTracker(),shifted)!!
        assertEquals(a,evidence["occurrenceId"]!!.jsonPrimitive.content)
        assertEquals("incomplete",TripOccurrenceCoverage.requireDocument(shifted).status(b))
    }
    @Test fun manualSelectionSurvivesJitterThenReleasesAfterSustainedDeparture() {
        val t=OccurrenceTraversalTracker();val d=TripOccurrenceCoverage.requireDocument(document())
        listOf(1.0,-1.0,2.0).forEachIndexed { i,x -> val p=fix(.5,i,x=x);assertFalse(t.departed(d,a,p,p.timeMs)) }
        repeat(3) { i -> val p=fix(.5,i+3,x=12.0);assertFalse(t.departed(d,a,p,p.timeMs)) }
        val p=fix(.5,6,x=12.0);assertTrue(t.departed(d,a,p,p.timeMs))
    }
    @Test fun remainingWorkIgnoresCursorAndReincludesUndoneWorkWhileStopped() {
        val t=OccurrenceTraversalTracker();repeat(4){i->t.recordSpeed(100000+i*3000L,2.0,1.0,100000+i*3000L)}
        assertEquals(30L,t.remainingSeconds(TripOccurrenceCoverage.requireDocument(document()),115000))
        assertEquals(15L,t.remainingSeconds(TripOccurrenceCoverage.requireDocument(document(skipped=true)),115000))
        assertNull(t.remainingSeconds(TripOccurrenceCoverage.requireDocument(document()),400000))
    }
}
