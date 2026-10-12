package com.rork.vinetrack.data.auth

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.MainActivity
import com.rork.vinetrack.data.*
import com.rork.vinetrack.data.model.*
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.http.*
import io.ktor.serialization.kotlinx.json.json
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith

/** Production MainActivity, Login, repositories and Settings on test-Application-only storage. */
@RunWith(AndroidJUnit4::class)
class PopulatedCleanExitActivityTest {
    @get:Rule val compose = createEmptyComposeRule()
    private lateinit var app: CleanExitFixtureApplication
    private lateinit var scenario: ActivityScenario<MainActivity>
    private lateinit var client: HttpClient
    private val account = AtomicReference(A)
    private val logouts = AtomicInteger(0)
    private val requests = java.util.Collections.synchronizedSet(mutableSetOf<String>())
    private val checkpoints = java.util.concurrent.CopyOnWriteArrayList<String>()
    private val pending = java.util.concurrent.ConcurrentHashMap<Int, String>()
    private val responses = java.util.concurrent.CopyOnWriteArrayList<String>()
    private val requestSequence = AtomicInteger(0)
    private val uncaught = AtomicReference<String?>(null)
    private var previousUncaught: Thread.UncaughtExceptionHandler? = null

    private fun checkpoint(stage: String) {
        checkpoints.add(stage)
        android.util.Log.i("CleanExitFixture", stage)
    }

    private fun diagnostic(): String {
        val session = SessionStore(app)
        val identity = when (session.userId) { A -> "A"; B -> "B"; null -> "none"; else -> "unexpected" }
        val tree = runCatching {
            val roots = compose.onAllNodes(isRoot(), useUnmergedTree = true)
            roots.fetchSemanticsNodes().indices.joinToString("\n") { roots[it].printToString() }
        }.getOrElse { "hierarchy unavailable: ${it.javaClass.simpleName}" }
        val files = app.filesDir.walkTopDown().filter { it.isFile }.map { it.relativeTo(app.filesDir).path }.toList()
        val preferences = java.io.File(app.applicationInfo.dataDir, "shared_prefs").listFiles()?.map { it.name }
        return "checkpoints=$checkpoints; session=${session.hasSession}; identity=$identity; " +
            "locked=${session.retentionGuard.isLocked}; finishing=${session.retentionGuard.finishingCleanExit.value}; " +
            "epoch=${session.retentionGuard.identityEpoch.value}; files=$files; preferenceFiles=$preferences; " +
            "pending=$pending; responses=$responses; uncaught=${uncaught.get()}; tree=$tree"
    }

    private fun awaitStage(stage: String, condition: () -> Boolean) {
        checkpoint("waiting.$stage")
        try {
            compose.waitUntil(20_000, condition)
            checkpoint("complete.$stage")
        } catch (failure: Throwable) {
            throw AssertionError("$stage: ${diagnostic()}", failure)
        }
    }
    private val vineyard: String get() = if (account.get() == A) "vineyard-A" else "vineyard-B"

    @Before fun setup() {
        app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
        val previousGuard = SessionStore(app).retentionGuard
        val priorLocked = previousGuard.isLocked
        val priorFinishing = previousGuard.finishingCleanExit.value
        val priorOperations = previousGuard.hasOutstandingOperations()
        app.resetFixture()
        CleanExitDiagnostics.observer = ::checkpoint
        val resetGuard = SessionStore(app).retentionGuard
        checkpoint("fixture.reset.sameGuard.${previousGuard === resetGuard}")
        checkpoint("fixture.beforeReset.locked.$priorLocked.finishing.$priorFinishing.operations.$priorOperations")
        check(!resetGuard.isLocked && !resetGuard.finishingCleanExit.value && !resetGuard.hasOutstandingOperations()) {
            "Fixture retained blocked in-memory admission after preference reset."
        }
        previousUncaught = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            uncaught.set("${thread.name}:${error.javaClass.simpleName}")
            checkpoint("uncaught.${error.javaClass.simpleName}")
            previousUncaught?.uncaughtException(thread, error)
        }
        OnboardingStore(app).markCompleted()
        AppPreferencesStore(app).save(AppPreferences(displayMode = DisplayMode.Light))
        MapPrefsStore(app).save(MapDefaults())
        HomePrefsStore(app).setInfoCardDismissed(true)
        account.set(A)
        client = HttpClient(MockEngine { request ->
            val path = request.url.encodedPath
            requests.add(path)
            val sequence = requestSequence.incrementAndGet()
            pending[sequence] = "${request.method.value} $path"
            val v = vineyard
            val uid = account.get()
            var status = HttpStatusCode.OK
            val body = when {
                path == "/auth/v1/token" -> """{"access_token":"access-$uid","refresh_token":"refresh-$uid","user":{"id":"$uid","email":"synthetic@example.invalid"}}"""
                path == "/auth/v1/logout" -> { logouts.incrementAndGet(); "{}" }
                path == "/rest/v1/vineyard_members" -> """[{"vineyard_id":"$v","role":"operator","user_id":"$uid"}]"""
                path == "/rest/v1/vineyards" -> """[{"id":"$v","name":"Synthetic $v"}]"""
                path == "/rest/v1/profiles" -> "[]"
                path == "/rest/v1/saved_chemicals" && request.method == HttpMethod.Get ->
                    """[{"id":"chemical-$uid","vineyard_id":"$v","name":"Private chemical $uid"}]"""
                path == "/rest/v1/paddocks" -> """[{"id":"block-$uid","vineyard_id":"$v","name":"Private block $uid"}]"""
                path == "/rest/v1/pins" -> """[{"id":"pin-$uid","vineyard_id":"$v","title":"Private pin $uid"}]"""
                path == "/rest/v1/trips" -> """[{"id":"trip-$uid","vineyard_id":"$v","is_active":false,"trip_title":"Private trip $uid"}]"""
                path == "/rest/v1/growth_stage_records" -> """[{"id":"growth-$uid","vineyard_id":"$v","stage_code":"4"}]"""
                path == "/rest/v1/work_tasks" -> """[{"id":"task-$uid","vineyard_id":"$v","notes":"Private task $uid","status":"completed"}]"""
                path == "/rest/v1/rpc/is_system_admin" -> "false"
                path == "/rest/v1/rpc/get_system_feature_flags" -> "[]"
                path == "/rest/v1/rpc/get_my_vinetrack_access" -> """[{"has_supabase_access":true,"can_use_android_app":true,"access_source":"team","solo_check_required":false}]"""
                path == "/rest/v1/rpc/get_my_vineyard_access_matrix" -> """{"account":{"has_any_accessible_vineyard":true},"vineyards":[{"vineyard_id":"$v","has_vineyard_access":true,"membership_role":"operator"}]}"""
                path == "/rest/v1/rpc/get_my_operational_tool_preferences" -> """{"has_preference":false,"visible_tool_ids":[],"hidden_tool_ids":[]}"""
                path.substringAfterLast('/') in emptyTables && request.method == HttpMethod.Get -> "[]"
                else -> { status = HttpStatusCode.ServiceUnavailable; "{}" } // Explicit synthetic failure; never production fallback.
            }
            responses.add("${request.method.value} $path ${status.value}")
            pending.remove(sequence)
            respond(body, status, headersOf("Content-Type", "application/json"))
        }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
        SupabaseClient.installInstrumentationTransport(client)
        checkpoint("activity.launch.begin")
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario.onActivity { checkpoint("activity.created.${it.lifecycle.currentState}") }
    }

    @After fun teardown() {
        if (::app.isInitialized) android.util.Log.i("CleanExitFixture", diagnostic())
        if (::scenario.isInitialized) scenario.close()
        CleanExitDiagnostics.observer = null
        Thread.setDefaultUncaughtExceptionHandler(previousUncaught)
        SupabaseClient.installInstrumentationTransport(null)
        SupabaseClient.sessionRefresher = null
        SupabaseClient.performanceCapture = null
        if (::client.isInitialized) client.close()
        if (::app.isInitialized) app.resetFixture()
    }

    private fun awaitText(text: String) = awaitStage("text.$text") {
        compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()
    }
    private fun signIn() {
        val publicationsBefore = checkpoints.count { it == "vineyard.load.published" }
        awaitText("Email")
        compose.onNodeWithText("Email").performTextInput("synthetic@example.invalid")
        compose.onNodeWithText("Password").performTextInput("synthetic-password")
        checkpoint("signin.submit.${if (account.get() == A) "A" else "B"}")
        compose.onAllNodesWithText("Sign In").onLast().performClick()
        awaitStage("session.admitted") { SessionStore(app).hasSession }
        awaitStage("main.settings.ready") {
            compose.onAllNodes(hasText("Settings") and hasClickAction()).fetchSemanticsNodes().isNotEmpty()
        }
        val cache = DomainCacheRepository(app)
        awaitStage("cache.hydrated") {
            cache.loadPins(account.get(), vineyard)?.isNotEmpty() == true &&
                cache.loadTrips(account.get(), vineyard)?.isNotEmpty() == true &&
                cache.loadGrowth(account.get(), vineyard)?.isNotEmpty() == true &&
                cache.loadWorkTasks(account.get(), vineyard)?.isNotEmpty() == true
        }
        awaitStage("vineyard.load.published") {
            checkpoints.count { it == "vineyard.load.published" } > publicationsBefore &&
                pending.isEmpty() && !SessionStore(app).retentionGuard.hasOutstandingOperations()
        }
        assertTrue(SessionStore(app).hasSession)
    }
    private fun settingsSignOut() {
        checkpoint("settings.navigate.begin")
        compose.onNode(hasText("Settings") and hasClickAction()).performClick()
        awaitText("Sign Out")
        checkpoint("settings.ready")
        compose.onNodeWithText("Sign Out").performScrollTo().performClick()
        checkpoint("settings.signout.clicked")
    }

    @Test fun populatedSettingsExitRecreateRelaunchReturnAThenBIsolatesPrivateCachesAndAuthority() {
        signIn()
        val session = SessionStore(app)
        val old = requireNotNull(session.accountAccess())
        val cache = DomainCacheRepository(app)
        assertEquals("trip-$A", cache.loadTrips(A, "vineyard-A")!!.single().id)
        assertEquals("pin-$A", cache.loadPins(A, "vineyard-A")!!.single().id)
        val before = app.getSharedPreferences("vinetrack_domain_cache", 0).all.toMap()
        val devicePrefs = app.getSharedPreferences("vinetrack_app_prefs", 0).all.toMap()
        val chemicals = app.getSharedPreferences("vinetrack_saved_chemicals_local", 0).all.toMap()
        assertEquals("chemical-$A", SavedChemicalLocalStore(app).load(A, "vineyard-A").single().id)
        settingsSignOut()
        awaitText("Email")
        assertFalse(session.hasSession)
        assertFalse(session.retentionGuard.isLocked)
        assertEquals(before, app.getSharedPreferences("vinetrack_domain_cache", 0).all)
        assertEquals(devicePrefs, app.getSharedPreferences("vinetrack_app_prefs", 0).all)
        assertEquals(chemicals, app.getSharedPreferences("vinetrack_saved_chemicals_local", 0).all)
        checkpoint("activity.recreate.begin")
        scenario.recreate()
        checkpoint("activity.recreate.complete")
        awaitText("Email")
        checkpoint("activity.relaunch.begin")
        scenario.close()
        scenario = ActivityScenario.launch(MainActivity::class.java)
        checkpoint("activity.relaunch.complete")
        awaitText("Email")
        assertNull(SessionStore(app).selectedVineyardId)
        signIn()
        assertFalse(session.withAccountAccess(old) { fail("A authority was revived") })
        assertEquals("chemical-$A", SavedChemicalLocalStore(app).load(A, "vineyard-A").single().id)
        settingsSignOut()
        awaitText("Email")
        account.set(B)
        signIn()
        val bCache = DomainCacheRepository(app)
        assertNull(bCache.loadPins(B, "vineyard-A"))
        assertNull(bCache.loadTrips(B, "vineyard-A"))
        assertEquals("pin-$B", bCache.loadPins(B, "vineyard-B")!!.single().id)
        assertTrue(SavedChemicalLocalStore(app).load(B, "vineyard-A").isEmpty())
        assertEquals("chemical-$B", SavedChemicalLocalStore(app).load(B, "vineyard-B").single().id)
        chemicals.forEach { (key, raw) -> assertEquals(raw, app.getSharedPreferences("vinetrack_saved_chemicals_local", 0).all[key]) }
        compose.onAllNodesWithText("Private chemical $A").assertCountEquals(0)
        assertFalse(session.withAccountAccess(old) { fail("A callback reached B") })
        compose.onAllNodesWithText("Private pin $A").assertCountEquals(0)
        compose.onAllNodesWithText("Private trip $A").assertCountEquals(0)
        assertEquals(B, SessionStore(app).userId)
        assertEquals(2, logouts.get())
    }

    private fun assertRefused(name: String, reason: String, prepare: () -> Unit) {
        signIn()
        val setupSession = SessionStore(app)
        val setupAuthority = requireNotNull(setupSession.accountAccess())
        checkpoint("fixture.prepare.authority.current.${setupSession.isAccountAccessCurrent(setupAuthority)}")
        try {
            prepare()
        } catch (failure: Throwable) {
            checkpoint("fixture.prepare.failed.${failure.javaClass.simpleName}")
            checkpoint("fixture.prepare.afterFailure.authority.current.${setupSession.isAccountAccessCurrent(setupAuthority)}")
            throw AssertionError("Retained-record preparation: ${diagnostic()}", failure)
        }
        val session = SessionStore(app)
        val authority = requireNotNull(session.accountAccess())
        val retained = app.getSharedPreferences(name, 0).all.toMap()
        val cache = app.getSharedPreferences("vinetrack_domain_cache", 0).all.toMap()
        settingsSignOut()
        awaitText("Sign-out paused")
        awaitStage("refusal.$reason") {
            compose.onAllNodesWithText(reason, substring = true).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText(reason, substring = true).assertExists()
        assertEquals(0, logouts.get())
        assertTrue(session.hasSession)
        assertFalse(session.retentionGuard.isLocked)
        assertTrue(session.isAccountAccessCurrent(authority))
        assertEquals(retained, app.getSharedPreferences(name, 0).all)
        assertEquals(cache, app.getSharedPreferences("vinetrack_domain_cache", 0).all)
        compose.onNodeWithText("Keep working").performClick()
        compose.onNode(hasText("Home") and hasClickAction()).performClick()
        assertTrue(session.withAccountAccess(authority) { })
    }

    @Test fun activeTripRefusalKeepsSessionAndSnapshot() = assertRefused("vinetrack_active_trip", "active Trip") {
        assertTrue(ActiveTripStore(app).saveDurably(A, vineyard, Trip("active", vineyard, isActive = true)))
    }
    @Test fun pendingTankActualRefusalKeepsSessionAndRecord() = assertRefused("vinetrack_spray_tank_actuals", "Tank actual") {
        assertTrue(SprayTankActualStore(app).save(SprayTankActual("actual", vineyard, "spray", "trip", "tank", 1,
            waterVolumeL = 120.0, chemicals = emptyList(), confirmedAt = "2026-10-12T00:00:00Z", confirmedBy = A)))
    }
    @Test fun unsynchronisedPinRefusalKeepsSessionAndQueue() = assertRefused("vinetrack_pending_writes", "Pending records") {
        val row = PendingWrite("unsent", "pin", "create", "{\"id\":\"unsent\",\"vineyard_id\":\"$vineyard\"}", "unsent", 1, 1)
        assertTrue(PendingWriteStore(app).save(listOf(row)))
    }
    @Test fun unfinishedPhotoRefusalKeepsSessionAndJpeg() {
        lateinit var file: java.io.File
        lateinit var bytes: ByteArray
        assertRefused("vinetrack_pending_photos", "unfinished photographs") {
            val image = android.graphics.Bitmap.createBitmap(8, 8, android.graphics.Bitmap.Config.ARGB_8888)
            bytes = try { java.io.ByteArrayOutputStream().use { out ->
                check(image.compress(android.graphics.Bitmap.CompressFormat.JPEG, 90, out)); out.toByteArray()
            } } finally { image.recycle() }
            val photo = PendingPhotoRepository(app).enqueue("unsent-pin", vineyard, bytes)
            file = java.io.File(photo.localPath)
        }
        assertArrayEquals(bytes, file.readBytes())
    }
    @Test fun unresolvedDraftRefusalKeepsSessionAndDraft() = assertRefused("vinetrack_local_planning", "unresolved draft") {
        WorkTaskPlanningDraftStore(app).save(WorkTaskPlanningDraft(null, vineyard, A,
            date = "2026-10-12T00:00:00Z", taskType = "pruning", notes = "Retained original intent"))
    }
    @Test fun corruptCacheRefusalKeepsSessionAndUnchangedBytes() = assertRefused("vinetrack_domain_cache", "uncertain cached evidence") {
        check(app.getSharedPreferences("vinetrack_domain_cache", 0).edit().putString("pins_$vineyard", "corrupt-original-evidence").commit())
    }

    companion object {
        private const val A = "11111111-1111-4111-8111-111111111111"
        private const val B = "22222222-2222-4222-8222-222222222222"
        private val emptyTables = setOf("machines", "vineyard_machines", "tractors", "operator_categories", "worker_types", "work_task_paddocks",
            "work_task_labour_lines", "work_task_machine_lines", "work_task_materials", "trip_cost_allocations", "maintenance_logs", "historical_yield_records",
            "damage_records", "yield_estimation_sessions", "tractor_fuel_logs", "spray_records", "spray_jobs", "vineyard_spray_targets", "spray_equipment",
            "saved_chemicals", "picking_records", "clone_catalog", "rootstock_catalog", "vineyard_clones", "vineyard_rootstocks", "app_notices",
            "growth_stage_images", "grape_varieties", "button_configurations", "vineyard_buttons", "custom_pin_types")
    }
}
