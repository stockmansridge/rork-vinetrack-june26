package com.rork.vinetrack.data

import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.viewModelScope
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.SessionPhase
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.ui.*
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.*
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.serialization.kotlinx.json.json
import io.ktor.http.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.util.UUID

/** Production ViewModel + local stores, synthetic identity and intercepted transport only. */
class HomeHydrationAndroidTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val base = instrumentation.targetContext
    private val prefix = "home_hydration_${UUID.randomUUID()}_"
    private val names = java.util.Collections.synchronizedSet(mutableSetOf<String>())
    private val root = File(base.cacheDir, prefix)
    private val models = ViewModelStore()
    private lateinit var vm: AppViewModel
    private lateinit var app: Application
    private lateinit var client: HttpClient
    private val owner = "33333333-3333-4333-8333-333333333333"
    private val a = "11111111-1111-4111-8111-111111111111"
    private val b = "22222222-2222-4222-8222-222222222222"
    @Volatile private var online = false
    @Volatile private var failReferences = false
    @Volatile private var missingBRig = false
    private var blockNextA = java.util.concurrent.atomic.AtomicBoolean(false)
    private val blocked = CompletableDeferred<Unit>()
    private val release = CompletableDeferred<Unit>()
    private val json = kotlinx.serialization.json.Json { encodeDefaults = true }
    private fun blocks(v: String) = List(if (v == a) 8 else 3) {
        val height = 100.0 / 111_320.0
        val width = (if (v == a) 7625.0 else 10000.0) / (100.0 * 111_320.0)
        Paddock("$v-block-$it", v, "Synthetic $it", vineCountOverride = if (v == a) 2760 else 1000,
            polygonPoints = listOf(CoordinatePoint(-height / 2, 0.0), CoordinatePoint(height / 2, 0.0),
                CoordinatePoint(height / 2, width), CoordinatePoint(-height / 2, width)))
    }
    private fun machines(v: String) = listOf(VineyardMachine("$v-tractor", v, "Synthetic tractor", machineType = "tractor"))
    private fun rigs(v: String) = listOf(SprayEquipment("$v-rig", v, "Synthetic rig"))
    private inline fun <reified T> body(rows: List<T>) = json.encodeToString(kotlinx.serialization.builtins.ListSerializer(kotlinx.serialization.serializer<T>()), rows)
    private fun cache(v: String, references: Boolean = true) {
        val cache = DomainCacheRepository(app)
        cache.saveVineyards(owner, listOf(Vineyard(a, "Stockmans-style fixture"), Vineyard(b, "JH-style fixture")))
        cache.savePaddocks(owner, v, blocks(v))
        cache.savePins(owner, v, emptyList())
        cache.saveTrips(owner, v, emptyList())
        cache.saveSpray(owner, v, emptyList())
        if (references) {
            cache.saveMachines(owner, v, machines(v))
            cache.saveSprayEquipment(owner, v, rigs(v))
        }
    }
    @Suppress("UNCHECKED_CAST") private fun state() = AppViewModel::class.java.getDeclaredField("_ui").let {
        it.isAccessible = true; it.get(vm) as MutableStateFlow<AppUiState>
    }
    private fun wizard(s: AppUiState): Boolean = Class.forName("com.rork.vinetrack.ui.screens.HomeDashboardKt")
        .getDeclaredMethod("shouldShowSetupWizard", AppUiState::class.java).let { it.isAccessible = true; it.invoke(null, s) as Boolean }
    private fun onMain(block: () -> Unit) = instrumentation.runOnMainSync(block)
    private fun awaitSettled(v: String) = runBlocking {
        withTimeout(30_000) { while (vm.ui.value.selectedVineyardId != v || vm.ui.value.isLoadingVineyardData) yieldAndWait() }
    }
    private suspend fun yieldAndWait() { delay(10) }
    @Before fun setup() {
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
            val table = request.url.encodedPath.substringAfterLast('/')
            val v = request.url.parameters["vineyard_id"]?.removePrefix("eq.") ?: a
            // Equipment is now the first authoritative read. Suspend that boundary
            // rather than waiting for a later historical/field request to be reached.
            if (table == "vineyard_machines" && v == a && blockNextA.compareAndSet(true, false)) {
                blocked.complete(Unit); release.await()
            }
            if (!online || (failReferences && table in setOf("vineyard_machines", "spray_equipment"))) {
                respond("Synthetic outage", HttpStatusCode.ServiceUnavailable)
            } else {
                // Repaired reference reads continue until an empty keyset page.
                // Do not return the first page again for id=gt.<last-id>.
                val payload = if (request.url.parameters["id"]?.startsWith("gt.") == true) "[]" else when (table) {
                    "paddocks" -> body(blocks(v))
                    "vineyard_machines" -> body(machines(v))
                    "spray_equipment" -> body(if (v == b && missingBRig) emptyList() else rigs(v))
                    "get_my_operational_tool_preferences" -> "{}"
                    else -> "[]"
                }
                respond(payload, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()))
            }
        }) {
            install(ContentNegotiation) { json(SupabaseClient.json) }
        }
        SupabaseClient.installInstrumentationTransport(client)
        onMain { vm = AppViewModel(app); models.put("home", vm) }
        runBlocking { withTimeout(5_000) { while (vm.ui.value.sessionPhase != SessionPhase.SignedOut) yieldAndWait() } }
        onMain {
            val session = AppViewModel::class.java.getDeclaredField("session").let { it.isAccessible = true; it.get(vm) as SessionStore }
            session.save("synthetic-access", "synthetic-refresh", owner, null)
            session.userCreatedAt = java.time.Instant.now().toString()
            session.selectedVineyardId = a
            state().value = AppUiState(selectedVineyardId = a, currentUserId = owner, sessionPhase = SessionPhase.AuthenticatedOffline, isOnline = false)
        }
    }
    @After fun cleanup() {
        release.complete(Unit)
        onMain { models.clear() }
        SupabaseClient.installInstrumentationTransport(null)
        client.close()
        names.toList().forEach { base.deleteSharedPreferences(prefix + it) }
        root.deleteRecursively()
    }
    @Test fun homeSyncPresentationUsesCurrentVineyardQueuesWithoutMutatingHydrationOrWrites() {
        online = true
        val pending = AppViewModel::class.java.getDeclaredField("pendingWrites").let {
            it.isAccessible = true; it.get(vm) as PendingWriteRepository
        }
        val savedA = pending.enqueue("presentation_probe", "create", "{\"vineyard_id\":\"$a\"}", "saved-a")
        val savedB = pending.enqueue("presentation_probe", "create", "{\"vineyard_id\":\"$b\"}", "saved-b")
        pending.updateStatus(savedB.id, PendingWriteStatus.BLOCKED, "Synthetic needs attention")
        val original = pending.list()
        onMain { state().value = state().value.copy(isOnline = true) }
        for (v in listOf(a, b, a)) {
            onMain {
                vm.selectVineyard(v)
                assertEquals("Syncing", vm.homeSyncStatus(vm.ui.value).label)
                assertNull(vm.ui.value.cachedFieldDataLastSyncedAt)
            }
            awaitSettled(v)
            val current = vm.ui.value
            assertEquals(if (v == a) "1 waiting" else "Needs attention", vm.homeSyncStatus(current).label)
            assertEquals(if (v == a) 8 else 3, current.paddocks.size)
            assertEquals(HomeReadKnowledge.Fresh, current.machinesKnowledge)
            assertEquals(HomeReadKnowledge.Fresh, current.sprayEquipmentKnowledge)
            assertFalse(current.isUsingCachedFieldData)
            assertNull(current.cachedFieldDataLastSyncedAt)
            assertEquals(original, pending.list())
            onMain {
                val beforePresentation = vm.ui.value
                vm.homeSyncStatus(beforePresentation)
                assertEquals(beforePresentation, vm.ui.value)
            }
        }
        val oldAccount = vm.ui.value.copy(currentUserId = "different-user")
        assertEquals("Not synced", vm.homeSyncStatus(oldAccount).label)
        val oldVineyard = vm.ui.value.copy(selectedVineyardId = b)
        assertEquals("Not synced", vm.homeSyncStatus(oldVineyard).label)
        assertEquals("pending", savedA.status)
    }

    @Test fun unknownDataMustNotPromptForSetup() {
        assertFalse("Unloaded setup is unknown, not missing", wizard(vm.ui.value))
    }
    @Test fun selectionImmediatelyInvalidatesPreviousCachedPresentation() {
        onMain {
            state().value = state().value.copy(isUsingCachedFieldData = true, cachedFieldDataLastSyncedAt = 42L)
            vm.selectVineyard(b)
            assertEquals(b, vm.ui.value.selectedVineyardId)
            assertFalse("Previous vineyard cached banner leaked", vm.ui.value.isUsingCachedFieldData)
            assertNull(vm.ui.value.cachedFieldDataLastSyncedAt)
        }
        awaitSettled(b)
    }
    @Test fun configuredOnlineVineyardPublishesSummarySetupAndTools() {
        online = true
        onMain { vm.selectVineyard(a) }
        awaitSettled(a)
        val s = vm.ui.value
        assertEquals(8, s.paddocks.size)
        assertEquals(6.1, s.totalHectares, 0.0001)
        assertEquals(22_080, s.paddocks.sumOf { it.summaryVineCount })
        assertEquals(HomeReadKnowledge.Fresh, s.blocksKnowledge)
        assertEquals(HomeReadKnowledge.Fresh, s.machinesKnowledge)
        assertEquals(HomeReadKnowledge.Fresh, s.sprayEquipmentKnowledge)
        assertFalse(wizard(s))
        assertTrue(vm.operationalToolLayout.value.isReady)
        assertFalse(s.isUsingCachedFieldData)
        assertNull(s.cachedFieldDataLastSyncedAt)
    }
    @Test fun failedVineyardBootstrapUsesCacheAndRefreshRecovers() {
        cache(a)
        onMain {
            state().value = state().value.copy(route = AppRoute.BiometricLock)
            vm.onBiometricUnlocked()
        }
        runBlocking { withTimeout(30_000) {
            while (vm.ui.value.paddocks.size != 8 || vm.ui.value.isLoadingVineyardData) yieldAndWait()
        } }
        assertEquals(AppRoute.Main, vm.ui.value.route)
        assertTrue(vm.operationalToolLayout.value.isReady)
        assertFalse(wizard(vm.ui.value))
        assertEquals(1, vm.ui.value.machines.size)
        assertEquals(1, vm.ui.value.sprayEquipment.size)
        assertTrue(vm.ui.value.isUsingCachedFieldData)
        assertNotNull(vm.ui.value.cachedFieldDataLastSyncedAt)
        online = true
        onMain { vm.refresh() }
        runBlocking { withTimeout(30_000) { while (vm.ui.value.blocksKnowledge != HomeReadKnowledge.Fresh || vm.ui.value.isLoadingVineyardData) yieldAndWait() } }
        assertFalse(vm.ui.value.isUsingCachedFieldData)
        assertNull(vm.ui.value.cachedFieldDataLastSyncedAt)
        assertFalse(wizard(vm.ui.value))
    }
    @Test fun transientReferenceFailuresWithoutCacheStayUnknownNotMissing() {
        online = true; failReferences = true
        onMain { vm.selectVineyard(a) }
        awaitSettled(a)
        assertEquals(8, vm.ui.value.paddocks.size)
        assertEquals(HomeReadKnowledge.Unknown, vm.ui.value.machinesKnowledge)
        assertEquals(HomeReadKnowledge.Unknown, vm.ui.value.sprayEquipmentKnowledge)
        assertFalse(wizard(vm.ui.value))
    }
    @Test fun repeatedSwitchAndLateOldResponseCannotWin() {
        cache(a); cache(b); online = true; missingBRig = true
        blockNextA.set(true)
        val before = vm.viewModelScope.coroutineContext[Job]!!.children.toSet()
        onMain { vm.selectVineyard(a) }
        runBlocking { withTimeout(10_000) { blocked.await() } }
        val oldLoads = vm.viewModelScope.coroutineContext[Job]!!.children.filter { it !in before }.toList()
        for (v in listOf(b, a, b)) {
            onMain { vm.selectVineyard(v) }
            awaitSettled(v)
            val s = vm.ui.value
            assertEquals(if (v == a) 8 else 3, s.paddocks.size)
            assertTrue(s.paddocks.all { it.vineyardId == v })
            assertTrue(s.machines.all { it.vineyardId == v })
            assertTrue(s.sprayEquipment.all { it.vineyardId == v })
            assertEquals(if (v == b) 0 else 1, s.sprayEquipment.size)
            assertEquals("Only B has a server-confirmed missing rig", v == b, wizard(s))
        }
        release.complete(Unit)
        // Drain the superseded production load rather than relying on a sleep.
        runBlocking { withTimeout(10_000) { oldLoads.joinAll() } }
        instrumentation.waitForIdleSync()
        assertEquals(b, vm.ui.value.selectedVineyardId)
        assertEquals(3, vm.ui.value.paddocks.size)
        assertTrue(wizard(vm.ui.value))
        assertTrue(vm.ui.value.sprayEquipment.isEmpty())
        assertFalse(vm.ui.value.isUsingCachedFieldData)
    }
    @Test fun noCacheIsUnknownUntilResultAndThenActualDataAppears() {
        blockNextA.set(true); online = true
        onMain { vm.selectVineyard(a) }
        runBlocking { withTimeout(10_000) { blocked.await() } }
        assertEquals(HomeReadKnowledge.Unknown, vm.ui.value.blocksKnowledge)
        assertTrue(vm.ui.value.isLoadingVineyardData)
        assertFalse(wizard(vm.ui.value))
        release.complete(Unit)
        awaitSettled(a)
        assertEquals(HomeReadKnowledge.Fresh, vm.ui.value.blocksKnowledge)
        assertEquals(8, vm.ui.value.paddocks.size)
        assertFalse(wizard(vm.ui.value))
    }
    @Test fun cachedCustomToolsDensitySurvivesSwitchAndStoreRecreationWithoutLeakingAccounts() {
        val prefs = app.getSharedPreferences("vinetrack_operational_tools", Context.MODE_PRIVATE)
        prefs.edit().putString("layout_$owner", "{\"visible\":[\"trips\",\"pins\"],\"hidden\":[\"spray\"],\"pending\":true}")
            .putBoolean("half_height_$owner", true).commit()
        onMain { vm.selectVineyard(a) }
        awaitSettled(a)
        assertTrue(vm.operationalToolLayout.value.isReady)
        assertEquals(listOf("trips", "pins"), vm.operationalToolLayout.value.visibleToolIds)
        assertEquals(listOf("spray"), vm.operationalToolLayout.value.hiddenToolIds)
        assertTrue(vm.operationalToolsHalfHeight.value)
        onMain { vm.selectVineyard(b) }
        awaitSettled(b)
        assertTrue(vm.operationalToolsHalfHeight.value)
        val session = AppViewModel::class.java.getDeclaredField("session").let { it.isAccessible = true; it.get(vm) as SessionStore }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        try {
            lateinit var store: OperationalToolLayoutStore
            onMain {
                store = OperationalToolLayoutStore(app, session, scope)
                store.configure(owner)
                assertTrue(store.halfHeight.value)
                assertEquals(listOf("trips", "pins"), store.layout.value.visibleToolIds)
                store.setHalfHeight(false)
                store.signOut()
                store.configure(owner)
                assertFalse(store.halfHeight.value)
                store.signOut()
                store.configure("different-synthetic-owner")
                assertTrue(store.layout.value.isReady)
                assertTrue(store.layout.value.visibleToolIds.isEmpty())
                assertTrue(store.layout.value.hiddenToolIds.isEmpty())
                assertFalse(store.halfHeight.value)
            }
        } finally { scope.cancel() }
    }
}
