package com.rork.vinetrack.data

import androidx.test.platform.app.InstrumentationRegistry
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.runner.RunWith
import org.junit.After
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.TripOccurrenceCoverage
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Real production SharedPreferences journal with isolated synthetic accounts, no backend calls. */
@RunWith(AndroidJUnit4::class)
class TripOccurrencePersistenceAndroidTest {
    private class Installation(base: Context) : ContextWrapper(base) {
        private val prefix = "occurrence_${UUID.randomUUID()}_"
        private val names = mutableSetOf<String>()
        override fun getApplicationContext(): Context = this
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            names.add(name)
            return baseContext.getSharedPreferences(prefix + name, mode)
        }
        fun dispose() { names.forEach { baseContext.deleteSharedPreferences(prefix + it) } }
    }
    private val context = Installation(InstrumentationRegistry.getInstrumentation().targetContext)
    @After fun dispose() { context.dispose() }
    private val a="11111111-1111-4111-8111-111111111111"
    private val b="22222222-2222-4222-8222-222222222222"
    private fun fixture(): JsonObject {
        val block="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        val items=listOf(a,b).mapIndexed { index,id -> buildJsonObject {
            put("occurrenceId",id); put("blockId",block); put("blockNameSnapshot","Block X"); put("pathNumber",38.5); put("passOrdinal",index+1)
            put("physicalPathRef",buildJsonObject { put("pathId","ffffffff-ffff-4fff-8fff-ffffffffffff"); put("rowIds",JsonArray(emptyList())); put("geometryRevision","unresolved") })
        } }
        return buildJsonObject {
            put("contract",TripOccurrenceCoverage.CONTRACT); put("schemaVersion",1); put("planId","dddddddd-dddd-4ddd-8ddd-dddddddddddd"); put("revision",0); put("planRevision",1)
            put("items",JsonArray(items)); put("activeOrder",JsonArray(listOf(a,b).map(::JsonPrimitive))); put("retired",JsonArray(emptyList()))
            put("states",buildJsonObject { listOf(a,b).forEach { id -> put(id,buildJsonObject { put("status","incomplete"); put("source",JsonNull); put("lastOperationId",JsonNull); put("tankSessionIds",JsonArray(emptyList())) }) } })
            put("plannedCursorId",a); put("selectedOccurrenceId",JsonNull)
        }
    }
    @Test fun plannerToProductionCreatePayloadAndActivationKeepsFourIDsOnDisk() {
        val owner = UUID.randomUUID().toString(); val session = SessionStore(context)
        session.save("synthetic-access", "synthetic-refresh", owner, null)
        val scope = TripOccurrenceJournal.Scope(owner, UUID.randomUUID().toString(), UUID.randomUUID().toString())
        val candidates = listOf(
            TripOccurrencePlanner.Candidate(scope.vineyardId, UUID.randomUUID().toString(), "A", 38.5, emptyList()),
            TripOccurrencePlanner.Candidate(scope.vineyardId, UUID.randomUUID().toString(), "B", 38.5, emptyList()))
        val raw = TripOccurrencePlanner.commit(TripOccurrencePlanner.plan(candidates, TrackingPattern.UP_AND_BACK, candidates[0].key, true), scope.vineyardId)
        val ids = TripOccurrenceCoverage.requireDocument(raw).order
        val trip = com.rork.vinetrack.data.model.Trip(id = scope.tripId, vineyardId = scope.vineyardId,
            paddockIds = candidates.map { it.blockId }, occurrenceCoverage = raw, rowSequence = List(4) { 38.5 },
            startTime = "2026-10-14T08:00:00Z", clientUpdatedAt = "2026-10-14T08:00:00Z", tripTitle = "Retained setup",
            currentRowNumber = 38.5, nextRowNumber = 38.5)
        var j = TripOccurrenceNativeStore(context).journal(scope)
        TripRepository(session).preparePlannedCreation(trip, j)
        val create = j.load()!!.pending.single()
        val activate = j.activate(buildJsonObject { put("startTime", "2026-10-14T09:00:00Z") })
        j = TripOccurrenceNativeStore(context).journal(scope)
        assertEquals(listOf(create.params, activate.params), j.load()!!.pending.map { it.params })
        assertEquals(ids, TripOccurrenceCoverage.requireDocument(j.projected(j.load()!!)).order)
        assertEquals(JsonPrimitive("Retained setup"), create.params["p_trip"]!!.jsonObject["trip_title"])
        j.acknowledge(buildJsonObject { put("tripId", scope.tripId); put("operationId", create.id); put("coverage", create.after) })
        j.acknowledge(buildJsonObject { put("tripId", scope.tripId); put("operationId", activate.id); put("coverage", activate.after) })
        val active = trip.copy(isActive = true).withOccurrenceProjection(j.projected(j.load()!!))
        assertEquals(ids, active.occurrenceDocument!!.order)
        assertTrue(active.completedPaths.orEmpty().isEmpty()); assertEquals(4, active.notCompletedRowCount)
    }

    @Test fun realPreferenceOfflineCreateActivationActionsReviewSurviveBeforeReceipts() {
        val owner = UUID.randomUUID().toString(); SessionStore(context).save("synthetic-access", "synthetic-refresh", owner, null)
        val scope = TripOccurrenceJournal.Scope(owner, UUID.randomUUID().toString(), UUID.randomUUID().toString())
        var j = TripOccurrenceNativeStore(context).journal(scope)
        val create = j.prepareCreation(buildJsonObject { put("id", scope.tripId); put("vineyard_id", scope.vineyardId); put("is_active", false) }, fixture())
        val activation = j.activate(buildJsonObject { put("startTime", "2026-10-14T08:00:00Z") })
        val done = j.setStatus(a, "done"); val skip = j.setStatus(a, "skipped")
        j = TripOccurrenceNativeStore(context).journal(scope)
        assertTrue(j.canOperate(j.load()!!)); assertEquals(skip.id, j.undoTarget()!!.id)
        val undo = j.undo(skip.id); val other = j.setStatus(b, "skipped")
        val final = j.finalize(buildJsonObject { put("endTime", "2026-10-14T09:00:00Z") })
        val exact = listOf(create, activation, done, skip, undo, other, final)
        j = TripOccurrenceNativeStore(context).journal(scope)
        assertEquals(exact.map { it.params }, j.load()!!.pending.map { it.params })
        assertFalse(j.canOperate(j.load()!!))
        exact.forEach { op ->
            j.acknowledge(buildJsonObject { put("tripId", scope.tripId); put("operationId", op.id); put("coverage", op.after) })
            val d = TripOccurrenceCoverage.requireDocument(j.projected(j.load()!!))
            assertEquals("done", d.status(a)); assertEquals("skipped", d.status(b))
        }
        assertTrue(j.load()!!.pending.isEmpty()); assertFalse(j.load()!!.serverActive!!)
    }

    @Test fun realPreferenceRecreationPreservesDoneSkipUndoAndExactRetry() {
        val owner=UUID.randomUUID().toString(); SessionStore(context).save("synthetic-access","synthetic-refresh",owner,null)
        val scope=TripOccurrenceJournal.Scope(owner,UUID.randomUUID().toString(),UUID.randomUUID().toString())
        var journal=TripOccurrenceNativeStore(context).journal(scope); journal.initialize(fixture())
        val done=journal.setStatus(a,"done"); val skip=journal.setStatus(a,"skipped"); journal.setStatus(b,"skipped")
        journal=TripOccurrenceNativeStore(context).journal(scope); journal.undo(skip.id)
        val state=journal.load()!!; val d=TripOccurrenceCoverage.requireDocument(journal.projected(state))
        assertEquals("done",d.status(a)); assertEquals("skipped",d.status(b)); assertEquals(done.params,state.pending.first().params)
        assertEquals(skip.id,state.history[1].id); assertEquals(4,state.pending.size)
    }
    @Test fun realPreferenceLifecycleRequestsSurviveRecreationBeforeAcknowledgement() {
        val owner=UUID.randomUUID().toString(); SessionStore(context).save("synthetic-access","synthetic-refresh",owner,null)
        val scope=TripOccurrenceJournal.Scope(owner,UUID.randomUUID().toString(),UUID.randomUUID().toString())
        var j=TripOccurrenceNativeStore(context).journal(scope)
        val metadata=buildJsonObject { put("id",scope.tripId); put("vineyard_id",scope.vineyardId); put("is_active",false); put("trip_title","Retained title") }
        val create=j.prepareCreation(metadata,fixture()); j=TripOccurrenceNativeStore(context).journal(scope)
        assertEquals(create.params,j.load()!!.pending.first().params); assertFalse(j.load()!!.creationConfirmed)
        assertTrue(runCatching { j.setStatus(a,"done") }.isFailure)
        j.acknowledge(buildJsonObject { put("tripId",scope.tripId); put("operationId",create.id); put("coverage",create.after) })
        val activation=j.activate(buildJsonObject { put("startTime","2026-10-14T08:00:00Z") })
        j=TripOccurrenceNativeStore(context).journal(scope); assertEquals(activation.params,j.load()!!.pending.single().params)
        j.acknowledge(buildJsonObject { put("tripId",scope.tripId); put("operationId",activation.id); put("coverage",activation.after) })
        j.setStatus(a,"done"); val final=j.finalize(buildJsonObject { put("endTime","2026-10-14T09:00:00Z") })
        j=TripOccurrenceNativeStore(context).journal(scope); assertEquals(final.params,j.load()!!.pending.last().params)
        assertEquals("done",TripOccurrenceCoverage.requireDocument(j.projected(j.load()!!)).status(a))
        assertNull(j.undoTarget())
    }
    @Test fun oldAccountCannotCommitDelayedOccurrenceAcknowledgement() {
        val session=SessionStore(context); val owner=UUID.randomUUID().toString(); session.save("access-one","refresh-one",owner,null)
        val scope=TripOccurrenceJournal.Scope(owner,UUID.randomUUID().toString(),UUID.randomUUID().toString())
        val j=TripOccurrenceNativeStore(context).journal(scope); j.initialize(fixture()); val op=j.setStatus(a,"done")
        assertTrue(runCatching { session.save("access-two","refresh-two",UUID.randomUUID().toString(),null) }.isFailure)
        assertTrue(session.retentionGuard.isLocked)
        val result=buildJsonObject { put("tripId",scope.tripId); put("operationId",op.id); put("coverage",op.after) }
        assertTrue(runCatching { j.acknowledge(result) }.isFailure)
        val retained = context.getSharedPreferences("trip_occurrence_journals_v1", Context.MODE_PRIVATE)
            .getString("${scope.ownerId}/${scope.vineyardId}/${scope.tripId}", null) ?: error("Retained scoped journal missing")
        assertEquals(op.id, Json.parseToJsonElement(retained).jsonObject.getValue("pending").jsonArray.single().jsonObject.getValue("id").jsonPrimitive.content)
    }
    @Test fun realPreferenceDelayedAckCannotRestoreOlderCoverage() {
        val owner=UUID.randomUUID().toString(); SessionStore(context).save("synthetic-access","synthetic-refresh",owner,null)
        val scope=TripOccurrenceJournal.Scope(owner,UUID.randomUUID().toString(),UUID.randomUUID().toString())
        val journal=TripOccurrenceNativeStore(context).journal(scope); journal.initialize(fixture())
        val done=journal.setStatus(a,"done"); val skip=journal.setStatus(a,"skipped")
        val ack=buildJsonObject { put("tripId",scope.tripId); put("operationId",done.id); put("coverage",done.after) }
        journal.acknowledge(ack)
        val restored=TripOccurrenceNativeStore(context).journal(scope); restored.acknowledge(ack)
        val state=restored.load()!!
        assertEquals("skipped",TripOccurrenceCoverage.requireDocument(restored.projected(state)).status(a)); assertEquals(listOf(skip),state.pending)
        restored.hold("OCCURRENCE_REVISION_CONFLICT")
        assertNotNull(TripOccurrenceNativeStore(context).journal(scope).load()!!.heldReason)
    }
}
