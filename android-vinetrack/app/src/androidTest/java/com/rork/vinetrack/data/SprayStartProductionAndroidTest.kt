package com.rork.vinetrack.data

import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.serialization.kotlinx.json.json
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.*
import io.ktor.http.content.TextContent
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Actual ViewModel/repository Start entry, isolated native storage + intercepted HTTP only.
 * Not authenticated backend acceptance, physical GPS, or screen/navigation evidence.
 */
class SprayStartProductionAndroidTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val base = instrumentation.targetContext
    private val prefix = "spray_start_${UUID.randomUUID()}_"
    private val names = mutableSetOf<String>()
    private val root = File(base.cacheDir, prefix)
    private val models = ViewModelStore()
    private val actor = UUID.randomUUID().toString()
    private val vineyard = UUID.randomUUID().toString()
    private var client: HttpClient? = null
    private lateinit var app: Application
    private lateinit var vm: AppViewModel
    private var savedRequest: JsonObject? = null
    private var savedTrip: JsonObject? = null
    private var savedRecord: JsonObject? = null
    private var creates = 0
    private var recoveries = 0
    private var failReload = false
    private var mode = "accepted"
    private var hold: CompletableDeferred<Unit>? = null

    @After fun cleanup() {
        instrumentation.runOnMainSync { models.clear() }
        SupabaseClient.installInstrumentationTransport(null)
        client?.close()
        names.forEach { base.deleteSharedPreferences(prefix + it) }
        root.deleteRecursively()
    }

    private fun setup() {
        val wrapped = object : ContextWrapper(base) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
                names.add(name); return base.getSharedPreferences(prefix + name, mode)
            }
            override fun getFilesDir(): File = File(root, "files").apply { mkdirs() }
            override fun getCacheDir(): File = File(root, "cache").apply { mkdirs() }
        }
        app = object : Application() { init { attachBaseContext(wrapped) }; override fun getApplicationContext(): Context = this }
        client = HttpClient(MockEngine { request ->
            val path = request.url.encodedPath
            val jsonHeaders = headersOf(HttpHeaders.ContentType, "application/json")
            when {
                path.endsWith("/rpc/save_legacy_spray_pair_v1") || path.endsWith("/rpc/recover_legacy_spray_pair_v1") -> {
                    val body = Json.parseToJsonElement((request.body as TextContent).text).jsonObject
                    if (path.endsWith("/save_legacy_spray_pair_v1")) {
                        creates++; savedRequest = body
                        savedTrip = body.getValue("p_trip").jsonObject
                        savedRecord = body.getValue("p_record").jsonObject
                        hold?.await()
                        if (mode == "lost") error("Synthetic lost response after commitment")
                    } else {
                        recoveries++; assertEquals(savedRequest, body)
                    }
                    if (mode == "unavailable") respond("{}", HttpStatusCode.ServiceUnavailable, jsonHeaders)
                    else respond(buildJsonObject {
                        put("version", 1); put("status", if (mode == "rejected") "rejected" else "accepted")
                        put("operation_id", body.getValue("p_operation_id"))
                        put("trip_id", savedTrip!!.getValue("id")); put("vineyard_id", vineyard)
                        put("spray_record_id", savedRecord!!.getValue("id")); put("request_sha256", "a".repeat(64))
                        put("committed_at", "2026-10-16T08:00:01Z")
                        if (mode == "rejected") put("code", "validation_or_reference_conflict")
                    }.toString(), HttpStatusCode.OK, jsonHeaders)
                }
                path.endsWith("/trips") && request.method == HttpMethod.Get -> {
                    if (failReload) { failReload = false; respond("{}", HttpStatusCode.ServiceUnavailable, jsonHeaders) }
                    else respond(JsonArray(listOfNotNull(savedTrip)).toString(), HttpStatusCode.OK, jsonHeaders)
                }
                path.endsWith("/trips") && request.method == HttpMethod.Patch -> {
                    val patch = Json.parseToJsonElement((request.body as TextContent).text).jsonObject
                    savedTrip = JsonObject(savedTrip.orEmpty() + patch)
                    respond(JsonArray(listOfNotNull(savedTrip)).toString(), HttpStatusCode.OK, jsonHeaders)
                }
                path.endsWith("/spray_records") -> respond(JsonArray(listOfNotNull(savedRecord)).toString(), HttpStatusCode.OK, jsonHeaders)
                else -> respond("[]", HttpStatusCode.OK, jsonHeaders) // No live-service fallback.
            }
        }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
        SupabaseClient.installInstrumentationTransport(client)
        instrumentation.runOnMainSync {
            vm = AppViewModel(app); models.put("start", vm)
            session().save("synthetic-access", "synthetic-refresh", actor, null)
            state().value = AppUiState(selectedVineyardId = vineyard, currentUserId = actor, isOnline = true,
                members = listOf(VineyardMember(vineyardId = vineyard, userId = actor, role = "manager")))
        }
    }

    private fun session(): SessionStore = AppViewModel::class.java.getDeclaredField("session").let { it.isAccessible = true; it.get(vm) as SessionStore }
    @Suppress("UNCHECKED_CAST")
    private fun state(): MutableStateFlow<AppUiState> = AppViewModel::class.java.getDeclaredField("_ui").let { it.isAccessible = true; it.get(vm) as MutableStateFlow<AppUiState> }
    private fun input(): SprayRecordRepository.SprayInput = SprayRecordRepository.SprayInput(
        "2026-10-16", "2026-10-16T08:00:00Z", null, null, null, null, "Isolated Start", "Unchanged recipe", null, null, null, null, null, null,
        sprayEquipmentId = null, operationType = "foliar_spray", tripId = null, tanks = listOf(SprayTank("original-tank", tankNumber = 1, waterVolume = 420.0,
            chemicals = listOf(SprayChemical("original-chemical", name = "Fixture", volumePerTank = 1500.0, ratePerHa = 750.0, unit = "g")))))

    private fun start(hours: Double? = null): SprayStartOutcome {
        val done = CountDownLatch(1); val outcome = AtomicReference<SprayStartOutcome>()
        instrumentation.runOnMainSync { vm.startSprayJobNow(input(), null, emptyList(), "Fixture", startEngineHours = hours) { outcome.set(it); done.countDown() } }
        assertTrue("Start callback did not finish", done.await(20, TimeUnit.SECONDS))
        return requireNotNull(outcome.get())
    }

    private fun assertActivation(hours: Double?) {
        val outcome = start(hours)
        assertTrue(outcome.message, outcome.isStarted)
        val active = requireNotNull(ActiveTripStore(app).load())
        assertEquals(outcome.tripId, active.trip.id); assertEquals(actor, active.ownerUserId)
        assertEquals(hours, active.trip.startEngineHours)
        assertEquals(savedTrip!!.getValue("id").jsonPrimitive.content, active.trip.id)
        assertEquals(1, creates)
        assertTrue(vm.requiresFirstTankReview(active.trip))
        assertFalse("Do not bypass required Tank 1 Actual confirmation", vm.ui.value.isTracking)
    }
    @Test fun blankHoursActivateOriginalAndKeepFirstTankGpsSafetyGate() { setup(); assertActivation(null) }
    @Test fun validHoursActivateOriginalAndPreserveValue() {
        setup(); assertActivation(123.5)
        val original = requireNotNull(ActiveTripStore(app).load())
        var callbacks = 0
        instrumentation.runOnMainSync { vm.startSprayJob(original.trip.id, 999.0) { ok -> assertTrue("Return to original owned Trip failed: ${vm.ui.value.sprayError}", ok); callbacks++ } }
        assertEquals("Return callback count", 1, callbacks)
        val returned = requireNotNull(ActiveTripStore(app).load())
        assertEquals(original.ownerUserId, returned.ownerUserId)
        assertEquals(original.trip.id, returned.trip.id)
        assertTrue(returned.trip.isActive); assertNull(returned.trip.endTime)
        assertEquals(original.trip.startEngineHours, returned.trip.startEngineHours)
        assertEquals(original.trip.pathPoints.orEmpty(), returned.trip.pathPoints.orEmpty())
        assertEquals(original.trip.tankSessions, returned.trip.tankSessions)
        assertEquals(1, creates) // Returning to an already-owned trip is not another activation or tracker.
    }

    @Test fun changedRouteCannotEscapeAnUncertainOriginalLegacyStart() {
        mode = "lost"; setup()
        assertFalse(start().isStarted)
        val original = requireNotNull(LegacySpraySaveStore(app).retainedStart(vineyard))
        val done = CountDownLatch(1); val result = AtomicReference<SprayStartOutcome>()
        instrumentation.runOnMainSync {
            vm.startSprayJobNow(input(), null, emptyList(), "Fixture",
                rowPlan = com.rork.vinetrack.ui.SprayJobRowPlan("sequential", listOf(1.5), 1)) { result.set(it); done.countDown() }
        }
        assertTrue(done.await(20, TimeUnit.SECONDS))
        assertFalse("Changed route unexpectedly started", result.get().isStarted); assertTrue("Missing original identity: ${result.get().message}", result.get().message!!.contains(original.trip.id))
        assertEquals(1, creates)
    }
    @Test fun olderAcceptedPairWithoutStartDiscriminatorCannotBeRemintedOnCalculatorRetry() {
        setup()
        val done = CountDownLatch(1)
        instrumentation.runOnMainSync {
            vm.createSprayJobForLater(input(), null, emptyList(), "Fixture") { ok -> assertTrue(ok); done.countDown() }
        }
        assertTrue(done.await(20, TimeUnit.SECONDS))
        val originalId = savedTrip!!.getValue("id").jsonPrimitive.content
        val result = start()
        assertFalse(result.isStarted); assertTrue(result.message!!.contains(originalId))
        assertTrue(result.message!!.contains("earlier app flow"))
        assertEquals(1, creates); assertNull(ActiveTripStore(app).load())
    }

    @Test fun rejectedReceiptDoesNotActivateOrDiscardOriginal() {
        mode = "rejected"; setup()
        val outcome = start()
        assertFalse(outcome.isStarted); assertTrue(outcome.message!!.contains("validation_or_reference_conflict"))
        assertNull(ActiveTripStore(app).load())
        assertEquals(savedTrip!!.getValue("id").jsonPrimitive.content, LegacySpraySaveStore(app).retainedStart(vineyard)?.trip?.id)
        assertFalse(start().isStarted); assertEquals(1, creates)
    }
    @Test fun acceptedButReloadFailedRetriesOriginalWithoutAnotherCreate() {
        failReload = true; setup()
        val first = start(123.5)
        assertFalse(first.isStarted); assertTrue(first.message!!.contains("reload is pending"))
        val original = requireNotNull(LegacySpraySaveStore(app).retainedStart(vineyard))
        val recovered = start(999.0)
        assertTrue(recovered.message, recovered.isStarted); assertEquals(original.trip.id, recovered.tripId)
        assertEquals(123.5, ActiveTripStore(app).load()!!.trip.startEngineHours!!, 0.0)
        assertEquals(1, creates); assertEquals(1, recoveries)
    }
    @Test fun lostResponseUsesRecoveryOnlyAndKeepsOriginalOperation() {
        mode = "lost"; setup()
        assertFalse(start().isStarted)
        val original = requireNotNull(LegacySpraySaveStore(app).retainedStart(vineyard))
        mode = "accepted"
        val recovered = start()
        assertTrue(recovered.message, recovered.isStarted); assertEquals(original.trip.id, recovered.tripId)
        assertEquals(1, creates); assertEquals(1, recoveries)
    }
    @Test fun viewModelRecreationRecoversLostOriginalFromNativeStoreWithoutCreateReplay() {
        mode = "lost"; setup()
        assertFalse(start(42.0).isStarted)
        val original = requireNotNull(LegacySpraySaveStore(app).retainedStart(vineyard))
        mode = "accepted"
        instrumentation.runOnMainSync { models.clear(); vm = AppViewModel(app); models.put("restored-start", vm) }
        kotlinx.coroutines.runBlocking {
            kotlinx.coroutines.withTimeout(15_000) {
                vm.ui.first { it.route != com.rork.vinetrack.ui.AppRoute.Restoring && it.route != com.rork.vinetrack.ui.AppRoute.VineyardLoading }
            }
        }
        instrumentation.runOnMainSync {
            state().value = AppUiState(selectedVineyardId = vineyard, currentUserId = actor, isOnline = true,
                members = listOf(VineyardMember(vineyardId = vineyard, userId = actor, role = "manager")))
        }
        val recovered = start(999.0)
        assertTrue(recovered.message, recovered.isStarted); assertEquals(original.trip.id, recovered.tripId)
        assertEquals(42.0, ActiveTripStore(app).load()!!.trip.startEngineHours!!, 0.0)
        assertEquals(1, creates)
    }

    @Test fun heldHistoricalGpsMarkerAloneDoesNotBlockStartOrLoseItsPayload() {
        setup()
        val pending = AppViewModel::class.java.getDeclaredField("pendingWrites").let { it.isAccessible = true; it.get(vm) as PendingWriteRepository }
        val original = pending.enqueue(PendingEntityType.TRIP_GPS, PendingOpType.UPDATE,
            "{\"tripId\":\"synthetic-history\",\"retainedEvidence\":\"do-not-rewrite\"}", "synthetic-history")
        pending.updateStatus(original.id, PendingWriteStatus.BLOCKED, "Historical GPS evidence retained for review")
        val outcome = start()
        assertTrue(outcome.message, outcome.isStarted)
        val retained = pending.list().single { it.id == original.id }
        assertEquals(original.payloadJson, retained.payloadJson)
        assertEquals(PendingWriteStatus.BLOCKED, retained.status)
        assertEquals(1, creates)
    }

    @Test fun unavailableBackendExplainsUncertaintyAndRetainsOriginal() {
        mode = "unavailable"; setup()
        val outcome = start()
        assertFalse(outcome.isStarted); assertTrue(outcome.message!!.contains("could not confirm"))
        assertTrue(LegacySpraySaveStore(app).retainedStart(vineyard)!!.rpcClaimed)
        assertNull(ActiveTripStore(app).load())
    }
    @Test fun repeatedPressesShareOneOriginalRequest() {
        hold = CompletableDeferred(); setup()
        val done = CountDownLatch(1); val result = AtomicReference<SprayStartOutcome>()
        instrumentation.runOnMainSync { vm.startSprayJobNow(input(), null, emptyList(), "Fixture") { result.set(it); done.countDown() } }
        val second = start()
        assertFalse(second.isStarted); assertTrue(second.message!!.contains("already in progress"))
        hold!!.complete(Unit)
        assertTrue(done.await(20, TimeUnit.SECONDS)); assertTrue(result.get().isStarted); assertEquals(1, creates)
    }
    @Test fun retainedActiveClaimBlocksAnotherStartWithoutTouchingItsEvidence() {
        setup()
        val original = Trip(UUID.randomUUID().toString(), vineyard, isActive = true,
            pathPoints = listOf(CoordinatePoint(-33.0, 149.0)))
        assertTrue(ActiveTripStore(app).claimIfAvailable(actor, vineyard, original))
        val outcome = start()
        assertFalse(outcome.isStarted); assertTrue(outcome.message!!.contains("already in progress"))
        assertEquals(original, ActiveTripStore(app).load()?.trip); assertEquals(0, creates)
    }
    @Test fun offlineStartKeepsDraftAndExplainsOnlineRequirement() {
        setup()
        instrumentation.runOnMainSync { state().value = state().value.copy(isOnline = false) }
        val outcome = start()
        assertFalse(outcome.isStarted); assertTrue(outcome.message!!.contains("online connection"))
        assertEquals(0, creates); assertNull(LegacySpraySaveStore(app).retainedStart(vineyard))
    }
}
