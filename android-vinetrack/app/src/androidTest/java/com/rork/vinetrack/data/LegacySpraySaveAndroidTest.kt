package com.rork.vinetrack.data

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.SessionStore
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Real scoped preference persistence, synthetic identity only; no backend or operational effects. */
class LegacySpraySaveAndroidTest {
    private class Installation(base: Context) : ContextWrapper(base) {
        private val prefix = "legacy_test_${UUID.randomUUID()}_"
        private val names = mutableSetOf<String>()
        var failCommit = false
        override fun getApplicationContext(): Context = this
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            names.add(name)
            val prefs = baseContext.getSharedPreferences(prefix + name, mode)
            if (name != LegacySpraySaveStore.PREFERENCES) return prefs
            return object : SharedPreferences by prefs {
                override fun edit(): SharedPreferences.Editor {
                    val delegate = prefs.edit()
                    return object : SharedPreferences.Editor by delegate {
                        override fun putString(key: String?, value: String?): SharedPreferences.Editor {
                            delegate.putString(key, value); return this
                        }
                        override fun commit(): Boolean = if (failCommit) false else delegate.commit()
                    }
                }
            }
        }
        fun dispose() { names.forEach { baseContext.deleteSharedPreferences(prefix + it) } }
    }
    private fun fixture(context: Context): LegacySpraySaveStore.Attempt {
        val actor = UUID.randomUUID().toString()
        val session = SessionStore(context); session.save("synthetic-access", "synthetic-refresh", actor, null)
        val vineyard = UUID.randomUUID().toString(); val trip = UUID.randomUUID().toString()
        val input = SprayRecordRepository.SprayInput("2026-10-15", "2026-10-15T08:00:00Z",
            null, null, null, null, "Original", "Frozen recipe", null, null, null, null, null, null,
            sprayEquipmentId = null, operationType = "foliar_spray", tripId = trip, tanks = emptyList())
        return LegacySpraySaveStore.Attempt(actor, session.retentionGuard.identityEpoch.value,
            LegacySpraySaveStore.TripIntent(trip, vineyard, null, emptyList(), "Original block", "Operator",
                input.startTime, null, actor, "freeDrive", emptyList(), 0, "2026-10-15T08:01:00Z"),
            UUID.randomUUID().toString(), input)
    }
    @Test fun eachUnknownBoundarySurvivesRecreationAndNeverBecomesSuccessOrFreshRetry() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        for (stage in LegacySpraySaveStore.Stage.entries.filter { it != LegacySpraySaveStore.Stage.COMPLETE }) {
            val context = Installation(base)
            try {
                val original = fixture(context); var store = LegacySpraySaveStore(context)
                store.prepare(original)
                for (next in LegacySpraySaveStore.Stage.entries.drop(1).take(stage.ordinal)) store.mark(original, next)
                store = LegacySpraySaveStore(context)
                val recovered = store.pending(original.trip.vineyardId).single()
                assertEquals(original.copy(stage = stage), recovered)
                assertTrue(store.blocks(original.trip.id))
                assertTrue(runCatching { store.prepare(original.copy(recordId = UUID.randomUUID().toString(), trip = original.trip.copy(id = UUID.randomUUID().toString()))) }.isFailure)
                assertTrue(runCatching { store.prepare(original.copy(input = original.input.copy(notes = "Changed"))) }.isFailure)
            } finally { context.dispose() }
        }
    }
    @Test fun durableFailureCannotAdvanceStageOrEraseOriginal() {
        val context = Installation(InstrumentationRegistry.getInstrumentation().targetContext)
        try {
            val original = fixture(context); val store = LegacySpraySaveStore(context)
            context.failCommit = true
            assertTrue(runCatching { store.prepare(original) }.isFailure)
            assertTrue(store.pending(original.trip.vineyardId).isEmpty())
            context.failCommit = false; store.prepare(original)
            context.failCommit = true
            assertTrue(runCatching { store.mark(original, LegacySpraySaveStore.Stage.TRIP_UNKNOWN) }.isFailure)
            assertEquals(original, LegacySpraySaveStore(context).pending(original.trip.vineyardId).single())
        } finally { context.dispose() }
    }
    @Test fun realAndroidSecondaryProcessDeathRetainsExactAttemptAtEveryUnknownBoundary() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        fun launch(id: String, mode: String) {
            context.startActivity(android.content.Intent().setClassName(context.packageName,
                "com.rork.vinetrack.data.LegacySprayProcessProbeActivity")
                .putExtra("case", id).putExtra("mode", mode)
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK or android.content.Intent.FLAG_ACTIVITY_CLEAR_TASK))
        }
        fun result(prefix: String): String {
            fun search(node: android.view.accessibility.AccessibilityNodeInfo?): String? {
                if (node == null) return null
                val text = node.text?.toString()
                if (text?.startsWith(prefix) == true) return text
                for (i in 0 until node.childCount) search(node.getChild(i))?.let { return it }
                return null
            }
            repeat(40) {
                search(instrumentation.uiAutomation.rootInActiveWindow)?.let { return it }
                android.os.SystemClock.sleep(200)
            }
            error("Bounded process probe did not publish $prefix")
        }
        for (stage in LegacySpraySaveStore.Stage.entries.filter { it != LegacySpraySaveStore.Stage.COMPLETE }) {
            val id = UUID.randomUUID().toString()
            launch(id, stage.name)
            val pid = result("LEGACY_RETAINED_").removePrefix("LEGACY_RETAINED_").toInt()
            check(pid != android.os.Process.myPid())
            android.os.Process.killProcess(pid)
            android.os.SystemClock.sleep(400)
            launch(id, "read")
            assertEquals("LEGACY_RECOVERED_${stage.name}", result("LEGACY_RECOVERED_"))
            launch(id, "cleanup")
            assertEquals("LEGACY_CLEANED", result("LEGACY_CLEANED"))
        }
    }

    @Test fun revokedOriginalAccountCannotPublishOrReassignRetainedAttempt() {
        val context = Installation(InstrumentationRegistry.getInstrumentation().targetContext)
        try {
            val original = fixture(context); val store = LegacySpraySaveStore(context)
            store.prepare(original); store.mark(original, LegacySpraySaveStore.Stage.TRIP_UNKNOWN)
            val before = context.getSharedPreferences(LegacySpraySaveStore.PREFERENCES, Context.MODE_PRIVATE).getString("attempts", null)
            val session = SessionStore(context); session.clear()
            assertTrue(runCatching { store.mark(original, LegacySpraySaveStore.Stage.TRIP_CONFIRMED) }.isFailure)
            assertTrue(runCatching { session.save("other", "other", UUID.randomUUID().toString(), null) }.isFailure)
            assertEquals(before, context.getSharedPreferences(LegacySpraySaveStore.PREFERENCES, Context.MODE_PRIVATE).getString("attempts", null))
        } finally { context.dispose() }
    }

    @Test fun provablyUnsentRestartUsesOnlyTheExactOriginalAndCanComplete() = kotlinx.coroutines.runBlocking {
        val context = Installation(InstrumentationRegistry.getInstrumentation().targetContext)
        try {
            val original = fixture(context)
            LegacySpraySaveStore(context).prepare(original)
            val restarted = LegacySpraySaveStore(context)
            val retained = restarted.pending(original.trip.vineyardId).single()
            assertEquals(LegacySpraySaveStore.UNSENT_MESSAGE, LegacySpraySaveStore.status(listOf(retained)))
            var requests = 0
            val result = restarted.sendPrepared(retained, { true }, { trip ->
                requests++
                assertEquals(original.trip, trip)
                assertEquals(LegacySpraySaveStore.Stage.TRIP_UNKNOWN, restarted.pending(trip.vineyardId).single().stage)
                com.rork.vinetrack.data.model.Trip(trip.id, trip.vineyardId)
            }, { item ->
                requests++
                assertEquals(original, item)
                assertEquals(LegacySpraySaveStore.Stage.RECORD_UNKNOWN, restarted.pending(item.trip.vineyardId).single().stage)
                com.rork.vinetrack.data.model.SprayRecord(item.recordId, item.trip.vineyardId, tripId = item.trip.id)
            })
            assertEquals(2, requests)
            assertEquals(original.trip.id, result.first.id)
            assertEquals(original.recordId, result.second.id)
            assertTrue(restarted.pending(original.trip.vineyardId).isEmpty())
            assertFalse(restarted.blocks(original.trip.id))
            assertTrue(runCatching { restarted.sendPrepared(original, { true }, { error("duplicate") }, { error("duplicate") }) }.isFailure)
        } finally { context.dispose() }
    }

    @Test fun uncertainSendIsNeverRetriedAndRevocationCannotReachTransport() = kotlinx.coroutines.runBlocking {
        val context = Installation(InstrumentationRegistry.getInstrumentation().targetContext)
        try {
            val original = fixture(context); val store = LegacySpraySaveStore(context)
            store.prepare(original)
            var requests = 0
            assertTrue(runCatching { store.sendPrepared(original, { false }, { requests++; error("revoked") }, { error("revoked") }) }.isFailure)
            assertEquals(0, requests)
            assertEquals(original, store.pending(original.trip.vineyardId).single())
            assertTrue(runCatching { store.sendPrepared(original, { true }, { requests++; error("lost response") }, { error("not admitted") }) }.isFailure)
            val retained = LegacySpraySaveStore(context).pending(original.trip.vineyardId).single()
            assertEquals(original.copy(stage = LegacySpraySaveStore.Stage.TRIP_UNKNOWN), retained)
            assertEquals(LegacySpraySaveStore.MESSAGE, LegacySpraySaveStore.status(listOf(retained)))
            assertTrue(runCatching { store.sendPrepared(original, { true }, { requests++; error("duplicate") }, { error("duplicate") }) }.isFailure)
            assertEquals(1, requests)
        } finally { context.dispose() }
    }

    @Test fun failedUnsentClaimAndChangedAccountLeaveOriginalWithoutRequests() = kotlinx.coroutines.runBlocking {
        val context = Installation(InstrumentationRegistry.getInstrumentation().targetContext)
        try {
            val original = fixture(context); val store = LegacySpraySaveStore(context)
            store.prepare(original)
            context.failCommit = true
            var requests = 0
            assertTrue(runCatching { store.sendPrepared(original, { true }, { requests++; error("not admitted") }, { error("not admitted") }) }.isFailure)
            assertEquals(0, requests)
            context.failCommit = false
            assertEquals(original, store.pending(original.trip.vineyardId).single())
            SessionStore(context).clear()
            assertTrue(runCatching { LegacySpraySaveStore(context).sendPrepared(original, { true }, { requests++; error("not admitted") }, { error("not admitted") }) }.isFailure)
            assertEquals(0, requests)
        } finally { context.dispose() }
    }

    @Test fun initialEchoMustIncludeOriginalEvidenceAndCannotTreatConflictAsAcknowledgement() {
        val request = buildJsonObject { put("id", "original"); put("amount", 25.75); put("conditions", "Frozen"); put("trip_id", JsonNull) }
        LegacySpraySaveStore.requireEcho(request, request)
        for (changed in listOf(JsonObject(request - "trip_id"), JsonObject(request + ("conditions" to JsonPrimitive("Changed"))),
            JsonObject(request + ("amount" to JsonPrimitive(25.0))))) {
            assertTrue(runCatching { LegacySpraySaveStore.requireEcho(request, changed) }.isFailure)
        }
    }
}
