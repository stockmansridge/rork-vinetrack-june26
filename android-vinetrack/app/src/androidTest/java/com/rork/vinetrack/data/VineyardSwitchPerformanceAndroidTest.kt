package com.rork.vinetrack.data

import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.os.Bundle
import android.os.SystemClock
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeUp
import com.rork.vinetrack.ui.screens.HomeDashboard
import com.rork.vinetrack.ui.theme.AppTheme
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.headersOf
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.serialization.kotlinx.json.json
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.SessionPhase
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.util.UUID

/** Actual selection/cache path; isolated local stores, intercepted-only transport, no backend user. */
class VineyardSwitchPerformanceAndroidTest {
    @get:Rule val compose = createComposeRule()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val base = instrumentation.targetContext
    private val prefix = "switch_performance_${UUID.randomUUID()}_"
    private val names = java.util.Collections.synchronizedSet(linkedSetOf<String>())
    private val root = File(base.cacheDir, prefix)
    private val models = ViewModelStore()
    private lateinit var vm: AppViewModel
    private lateinit var app: Application
    private var client: HttpClient? = null
    private val owner = "33333333-3333-4333-8333-333333333333"
    private val a = "11111111-1111-4111-8111-111111111111"
    private val b = "22222222-2222-4222-8222-222222222222"
    @After fun cleanup() {
        VineyardSwitchPerformanceProbe.stop()
        compose.runOnUiThread { models.clear() }
        SupabaseClient.installInstrumentationTransport(null)
        client?.close()
        names.forEach { base.deleteSharedPreferences(prefix + it) }
        root.deleteRecursively()
    }
    @Suppress("UNCHECKED_CAST") private fun state() = AppViewModel::class.java.getDeclaredField("_ui").let {
        it.isAccessible = true; it.get(vm) as MutableStateFlow<AppUiState>
    }
    @Test fun repeatedProductionSwitchAcknowledgesWithinTwoFrames() = exerciseSwitches(false)

    @Test fun mountedHomeScrollsDuringSyntheticRemoteApplication() = exerciseSwitches(true)

    private fun exerciseSwitches(mountHome: Boolean) {
        val wrapped = object : ContextWrapper(base) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
                names.add(name); return base.getSharedPreferences(prefix + name, mode)
            }
            override fun getFilesDir(): File = File(root, "files").apply { mkdirs() }
            override fun getCacheDir(): File = File(root, "cache").apply { mkdirs() }
        }
        app = object : Application() { init { attachBaseContext(wrapped) }; override fun getApplicationContext(): Context = this }
        val timestamp = "2026-10-27T00:00:00Z"
        val json = Json { encodeDefaults = true }
        val remoteBodies = listOf(a, b).associateWith { v -> mapOf(
            "pins" to json.encodeToString(ListSerializer(Pin.serializer()), List(2_000) { Pin("pin-$it", v, title = "Remote synthetic", createdAt = timestamp) }),
            "trips" to json.encodeToString(ListSerializer(Trip.serializer()), List(500) { Trip("trip-$it", v, startTime = timestamp, endTime = timestamp) }),
            "work_tasks" to json.encodeToString(ListSerializer(WorkTask.serializer()), List(500) { WorkTask("task-$it", v, date = timestamp) }),
            "spray_records" to json.encodeToString(ListSerializer(SprayRecord.serializer()), List(250) { SprayRecord("spray-$it", v, date = timestamp) }),
            "paddocks" to json.encodeToString(ListSerializer(Paddock.serializer()), List(100) { Paddock("block-$it", v, "Synthetic $it") }),
        ) }
        val remoteRequests = java.util.concurrent.atomic.AtomicInteger()
        client = HttpClient(MockEngine { request ->
            val v = request.url.parameters["vineyard_id"]?.removePrefix("eq.")
            val body = if (mountHome) remoteBodies[v]?.get(request.url.encodedPath.substringAfterLast('/')) else null
            if (body != null) {
                remoteRequests.incrementAndGet()
                respond(body, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()))
            } else respond("Synthetic: no live transport", HttpStatusCode.ServiceUnavailable)
        }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
        SupabaseClient.installInstrumentationTransport(client)
        compose.runOnUiThread { vm = AppViewModel(app); models.put("performance", vm) }
        compose.waitUntil(5_000) { vm.ui.value.sessionPhase == SessionPhase.SignedOut }
        compose.runOnUiThread {
            val session = AppViewModel::class.java.getDeclaredField("session").let { it.isAccessible = true; it.get(vm) as SessionStore }
            session.save("synthetic-access", "synthetic-refresh", owner, null)
            session.selectedVineyardId = a
            state().value = AppUiState(selectedVineyardId = a, currentUserId = owner,
                sessionPhase = SessionPhase.AuthenticatedOffline, isOnline = false)
        }
        val cache = DomainCacheRepository(app)
        for (v in listOf(a, b)) {
            cache.savePaddocks(owner, v, List(100) { Paddock("block-$it", v, "Synthetic $it") })
            cache.savePins(owner, v, List(2_000) { Pin("pin-$it", v, title = "Synthetic", createdAt = if (mountHome) timestamp else null) })
            cache.saveTrips(owner, v, List(500) { Trip("trip-$it", v, startTime = timestamp, endTime = timestamp) })
            cache.saveWorkTasks(owner, v, List(500) { WorkTask("task-$it", v, date = timestamp) })
            cache.saveSpray(owner, v, List(250) { SprayRecord("spray-$it", v, date = timestamp) })
            check(cache.saveMaintenance(owner, v, List(250) { MaintenanceLog("maintenance-$it", v, date = timestamp) }))
            check(cache.saveYieldSessions(owner, v, List(250) { YieldEstimationSession("yield-$it", v, timestamp) }))
            check(SavedChemicalLocalStore(app).save(owner, v, List(250) { SavedChemical("chemical-$it", v, name = "Synthetic $it") }))
        }
        if (mountHome) compose.setContent {
            AppTheme {
                HomeDashboard(vm = vm, state = vm.ui.collectAsState().value,
                    onOpenTab = {}, onOpenTool = {}, onOpenSetupWizard = {},
                    onOpenObservations = {}, onOpenAddPinAction = {}, onOpenPinsList = {})
            }
        }
        val report = StringBuilder("mountedHome=$mountHome Synthetic A/B/A; per vineyard 2000 pins, 500 trips/tasks, 250 spray/chemicals/maintenance/Yield, 100 blocks\n")
        val acknowledgement = mutableListOf<Double>()
        val mainDerivations = mutableListOf<VineyardSwitchPerformanceProbe.Sample>()
        for ((i, v) in listOf(a, b, a, b, a).withIndex()) {
            VineyardSwitchPerformanceProbe.start()
            val started = SystemClock.elapsedRealtimeNanos()
            compose.runOnUiThread {
                val call = SystemClock.elapsedRealtimeNanos()
                vm.selectVineyard(v)
                acknowledgement.add((SystemClock.elapsedRealtimeNanos() - call) / 1_000_000.0)
                assertEquals(v, vm.ui.value.selectedVineyardId)
                assertTrue(vm.ui.value.pins.all { it.vineyardId == v })
            }
            if (mountHome) {
                compose.onAllNodes(hasScrollAction()).onFirst().performTouchInput { swipeUp(durationMillis = 250) }
            }
            compose.waitUntil(30_000) {
                val s = vm.ui.value
                s.selectedVineyardId == v && s.pins.size == 2_000 && s.workTasks.size == 500 &&
                    s.maintenanceLogs.size == 250 && s.yieldSessions.size == 250 && !s.isLoadingVineyardData
            }
            assertTrue(vm.ui.value.pins.all { it.vineyardId == v })
            val settled = (SystemClock.elapsedRealtimeNanos() - started) / 1_000_000.0
            report.append("switch=$i ackMs=${acknowledgement.last()} settledMs=$settled\n")
            VineyardSwitchPerformanceProbe.stop().forEach {
                report.append("${it.stage} ms=${it.milliseconds} main=${it.mainThread} publications=${it.publications}\n")
                if (it.mainThread && it.stage in setOf("home-vintage-derivation", "home-overview-derivation")) mainDerivations.add(it)
            }
        }
        report.append("remoteRequests=${remoteRequests.get()} pinTitles=${vm.ui.value.pins.map { it.title }.toSet()} pinError=${vm.ui.value.pinError}\n")
        instrumentation.sendStatus(2, Bundle().apply { putString("stream", report.toString()) })
        println(report)
        if (mountHome) {
            assertEquals("All five large remote collections must be requested on every selection", 25, remoteRequests.get())
            assertTrue("Remote response did not reach Home.\n$report", vm.ui.value.pins.all { it.title == "Remote synthetic" })
            assertTrue("Mounted Home must actually compute its summary.\n$report", mainDerivations.isNotEmpty())
            assertTrue("Home derivation exceeded a 16ms UI-thread budget during real application.\n$report",
                mainDerivations.all { it.milliseconds <= 16.0 })
        }
        // A responsiveness requirement, not a claim that total network completion fits a frame.
        assertTrue("Selection blocked the UI for >32ms.\n$report", acknowledgement.all { it <= 32.0 })
    }
}
