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
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
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
    private var includeHistorical = false
    private var combinedRecovery = false
    private var historicalBytes: Map<String, Map<String, *>>? = null
    private val historical = "55555555-5555-4555-8555-555555555555"
    private val season = "77777777-7777-4777-8777-777777777777"
    private val block = "88888888-8888-4888-8888-888888888888"
    private val entry = "99999999-9999-4999-8999-999999999999"
    private val codec = kotlinx.serialization.json.Json { encodeDefaults = true }
    private val seasonRow get() = PruningSyncRepository.SeasonRow(season, historical, block, seasonYear = 2026)
    private val settingsRow get() = PruningYieldSettings(season, historical, block, bunchesPerBud = 1.7)
    private val entryRow get() = PruningSyncRepository.EntryRow(entry, historical, season, block,
        entryDate = "2026-08-10", createdBy = A, createdAt = "2026-08-10T00:00:00Z",
        updatedAt = "2026-08-10T01:00:00Z", notes = "original entry")
    private val segmentRow get() = PruningSyncRepository.SegmentRow(
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", season, rowNumber = 1, segmentNumber = 2,
        completed = true, pruningEntryId = entry)
    private val labourRow get() = PruningActivityLabourLine(entry, entry, historical, workerCount = 2, hoursPerWorker = 3.0)
    private val canonical get() = PruningActivityCanonical(activity = PruningActivityCanonical.CanonicalActivity(
        id = entry, vineyardId = historical, entryDate = "2026-08-10", workerOrCrew = "Crew", method = "spur",
        notes = "original activity", seasonYear = 2026, createdBy = A,
        createdAt = "2026-08-10T00:00:00Z", updatedAt = "2026-08-10T01:00:00Z", isReversed = false))
    private var retainedContractBytes: Map<String, Map<String, *>>? = null
    private var retainedLogoBytes: Map<String, List<Byte>>? = null
    private val requests = java.util.Collections.synchronizedSet(mutableSetOf<String>())
    private val checkpoints = java.util.concurrent.CopyOnWriteArrayList<String>()
    private val pending = java.util.concurrent.ConcurrentHashMap<Int, String>()
    private val responses = java.util.concurrent.CopyOnWriteArrayList<String>()
    private val unhandled = java.util.concurrent.CopyOnWriteArrayList<String>()
    private val operationalWrites = java.util.concurrent.CopyOnWriteArrayList<String>()
    private var diagnosticWorker: Thread? = null
    private val requestSequence = AtomicInteger(0)
    private val uncaught = AtomicReference<String?>(null)
    private var previousUncaught: Thread.UncaughtExceptionHandler? = null

    private fun checkpoint(stage: String) {
        checkpoints.add(stage)
        android.util.Log.i("CleanExitFixture", stage)
        if (stage == "field.commit.contended") {
            val stack = Thread.currentThread().stackTrace.joinToString("\n")
            checkpoints.add("contention.stack=$stack")
        }
    }

    private fun diagnostic(): String {
        val session = SessionStore(app)
        val identity = when (session.userId) { A -> "A"; B -> "B"; null -> "none"; else -> "unexpected" }
        // Never query Compose semantics here: failures can already be waiting for Compose idle.
        val main = android.os.Looper.getMainLooper().thread
        val mainStack = main.stackTrace.joinToString("\n")
        val files = app.filesDir.walkTopDown().filter { it.isFile }.map { it.relativeTo(app.filesDir).path }.toList()
        val preferences = java.io.File(app.applicationInfo.dataDir, "shared_prefs").listFiles()?.map { it.name }
        return "checkpoints=${checkpoints.filterNot { it == "field.commit.waiting" }}; session=${session.hasSession}; identity=$identity; " +
            "locked=${session.retentionGuard.isLocked}; finishing=${session.retentionGuard.finishingCleanExit.value}; " +
            "epoch=${session.retentionGuard.identityEpoch.value}; files=$files; preferenceFiles=$preferences; " +
            "pending=$pending; responseCount=${responses.size}; lastResponses=${responses.takeLast(6)}; unhandled=${unhandled.distinct()}; uncaught=${uncaught.get()}; mainState=${main.state}; mainStack=$mainStack"
    }

    private fun awaitStage(stage: String, timeoutMillis: Long = 20_000, condition: () -> Boolean) {
        checkpoint("waiting.$stage")
        try {
            compose.waitUntil(timeoutMillis, condition)
            checkpoint("complete.$stage")
        } catch (failure: Throwable) {
            throw AssertionError("$stage: ${diagnostic()}", failure)
        }
    }
    private val vineyard: String get() = if (account.get() == A) "33333333-3333-4333-8333-333333333333" else "44444444-4444-4444-8444-444444444444"

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
        client = fixtureClient()
        SupabaseClient.installInstrumentationTransport(client)
        AuthRecoveryRepository.installInstrumentationTransport { fixtureClient() }
        checkpoint("activity.launch.begin")
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario.onActivity { checkpoint("activity.created.${it.lifecycle.currentState}") }
    }

    /** Each repository owns an independent engine; closing recovery must not close app transport. */
    private fun fixtureClient(): HttpClient = HttpClient(MockEngine { request ->
            val path = request.url.encodedPath
            requests.add(path)
            val sequence = requestSequence.incrementAndGet()
            pending[sequence] = "${request.method.value} $path"
            val v = vineyard
            val uid = account.get()
            var status = HttpStatusCode.OK
            val body = when {
                path == "/rest/v1/rpc/record_my_client_activity" -> {
                    // Existing app telemetry is explicitly rejected, never sent to a backend.
                    // It is not a field-operation acknowledgement or a diagnostics upload.
                    status = HttpStatusCode.ServiceUnavailable
                    "{}"
                }
                request.method != HttpMethod.Get && path.startsWith("/rest/v1/") &&
                    path !in readOnlyRpcs -> {
                    operationalWrites.add("${request.method.value} $path")
                    status = HttpStatusCode.MethodNotAllowed
                    "{}"
                }
                path == "/auth/v1/token" -> """{"access_token":"access-$uid","refresh_token":"refresh-$uid","user":{"id":"$uid","email":"synthetic@example.invalid"}}"""
                path == "/auth/v1/user" -> """{"id":"$uid","email":"synthetic@example.invalid"}"""
                path == "/auth/v1/logout" -> { logouts.incrementAndGet(); "{}" }
                path == "/rest/v1/vineyard_members" -> if (includeHistorical)
                    """[{"vineyard_id":"$v","role":"operator","user_id":"$uid"},{"vineyard_id":"55555555-5555-4555-8555-555555555555","role":"operator","user_id":"$uid"}]"""
                    else """[{"vineyard_id":"$v","role":"operator","user_id":"$uid"}]"""
                combinedRecovery && path == "/rest/v1/vineyards" && request.url.parameters["id"] == "eq.$historical" ->
                    """[{"id":"$historical","timezone":"Australia/Sydney"}]"""
                combinedRecovery && path == "/rest/v1/pruning_seasons" && request.url.parameters["vineyard_id"] == "eq.$historical" -> codec.encodeToString(listOf(seasonRow))
                combinedRecovery && path == "/rest/v1/pruning_entries" && request.url.parameters["vineyard_id"] == "eq.$historical" -> codec.encodeToString(listOf(entryRow))
                combinedRecovery && path == "/rest/v1/pruning_row_segments" -> codec.encodeToString(listOf(segmentRow))
                combinedRecovery && path == "/rest/v1/pruning_activity_labour_lines" && request.url.parameters["vineyard_id"] == "eq.$historical" -> codec.encodeToString(listOf(labourRow))
                combinedRecovery && path == "/rest/v1/pruning_yield_settings" && request.url.parameters["vineyard_id"] == "eq.$historical" -> codec.encodeToString(listOf(settingsRow))
                combinedRecovery && path == "/rest/v1/rpc/get_pruning_activity" -> codec.encodeToString(canonical)
                path == "/rest/v1/vineyards" -> if (includeHistorical)
                    """[{"id":"$v","name":"Synthetic $v"},{"id":"55555555-5555-4555-8555-555555555555","name":"Historical fixture"}]"""
                    else """[{"id":"$v","name":"Synthetic $v"}]"""
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
                else -> {
                    unhandled.add("${request.method.value} $path")
                    status = HttpStatusCode.ServiceUnavailable; "{}"
                } // Explicit synthetic failure; never production fallback.
            }
            responses.add("${request.method.value} $path ${status.value}")
            pending.remove(sequence)
            respond(body, status, headersOf("Content-Type", "application/json"))
        }) { install(ContentNegotiation) { json(SupabaseClient.json) } }

    @After fun teardown() {
        diagnosticWorker?.interrupt()
        diagnosticWorker?.join(2_000)
        if (::app.isInitialized) android.util.Log.i("CleanExitFixture", diagnostic())
        if (::scenario.isInitialized) scenario.close()
        CleanExitDiagnostics.observer = null
        Thread.setDefaultUncaughtExceptionHandler(previousUncaught)
        SupabaseClient.installInstrumentationTransport(null)
        AuthRecoveryRepository.installInstrumentationTransport(null)
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
        // Await the ordinary load publication before inspecting its durable caches.
        awaitStage("vineyard.load.published", timeoutMillis = 60_000) {
            checkpoints.count { it == "vineyard.load.published" } > publicationsBefore &&
                pending.isEmpty() && !SessionStore(app).retentionGuard.hasOutstandingOperations()
        }
        val cache = DomainCacheRepository(app)
        awaitStage("cache.hydrated") {
            cache.loadPins(account.get(), vineyard)?.isNotEmpty() == true &&
                cache.loadTrips(account.get(), vineyard)?.isNotEmpty() == true &&
                cache.loadGrowth(account.get(), vineyard)?.isNotEmpty() == true &&
                cache.loadWorkTasks(account.get(), vineyard)?.isNotEmpty() == true &&
                SavedChemicalLocalStore(app).load(account.get(), vineyard).isNotEmpty()
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

    private fun retainDraft(): Map<String, *> {
        val draft = WorkTaskPlanningDraft(null, "33333333-3333-4333-8333-333333333333", A, date = "2026-11-05", taskType = "pruning",
            assignmentName = "Greg Horner", durationText = "1", notes = "Need bamboo and loose tie onto it", creationId = "original-creation")
        WorkTaskPlanningDraftStore(app).save(draft)
        return app.getSharedPreferences("vinetrack_local_planning", 0).all.toMap()
    }

    private fun retainProductionContracts() {
        includeHistorical = true
        val draft = WorkTaskPlanningDraft("task-$A", "33333333-3333-4333-8333-333333333333", A, date = "2026-11-05T00:00:00Z", taskType = "pruning",
            externalId = "original-greg-resource", assignmentName = "Greg Horner", durationText = "1", notes = "Need bamboo and loose tie onto it",
            baselineJson = """{"id":"task-$A","vineyard_id":"33333333-3333-4333-8333-333333333333","sync_version":1}""")
        val drafts = WorkTaskPlanningDraftStore(app)
        drafts.save(draft)
        val intent = WorkTaskWriteContract.planning(draft, "task-$A", java.time.LocalDate.parse("2026-11-05"),
            java.time.Instant.parse("2026-10-31T00:00:00Z"), null, "", 0.0)
        drafts.saveIntent(intent)
        drafts.saveRecovery(TaskWriteRecovery(original = intent))
        val queue = PendingWriteRepository(app)
        val write = PinCreateSync(queue).enqueue(PinRepository.PinInput("original-queued-pin", "55555555-5555-4555-8555-555555555555", createdBy = A))
        queue.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Synthetic retained review hold")
        val cache = DomainCacheRepository(app)
        cache.savePins(A, "55555555-5555-4555-8555-555555555555", listOf(Pin("historical-pin", "55555555-5555-4555-8555-555555555555", createdBy = A)))
        cache.saveTrips(A, "55555555-5555-4555-8555-555555555555", listOf(Trip("historical-trip", "55555555-5555-4555-8555-555555555555", operatorUserId = A)))
        assertTrue(RecoverySnapshotStore.captureBeforeMutation(app, "55555555-5555-4555-8555-555555555555").isPreserved)
        val receipt = RecoverySnapshotStore.TombstoneReceipt(A,
            PendingWrite("historical-delete", "pin", "delete", "{\"pinId\":\"historical-deleted-pin\"}", "historical-deleted-pin", 1, 1, status = "blocked"),
            PinDeleteSync.DeleteState("historical-deleted-pin", "55555555-5555-4555-8555-555555555555", "2026-10-30T00:00:00Z"))
        assertTrue(RecoverySnapshotStore(app).preserveTombstone(receipt))
        val image = android.graphics.Bitmap.createBitmap(2, 2, android.graphics.Bitmap.Config.ARGB_8888)
        val jpeg = java.io.ByteArrayOutputStream().also { image.compress(android.graphics.Bitmap.CompressFormat.JPEG, 90, it) }.toByteArray()
        image.recycle()
        assertTrue(VineyardLogoCache(app).save("55555555-5555-4555-8555-555555555555", jpeg, "55555555-5555-4555-8555-555555555555/logos/original.jpg", null))
        retainedLogoBytes = logoBytes()
        retainedContractBytes = listOf("vinetrack_pending_writes", "vinetrack_recovery_snapshots_v2", "vinetrack_local_planning")
            .associateWith { app.getSharedPreferences(it, 0).all.toMap() }
    }

    private fun logoBytes(): Map<String, List<Byte>> = java.io.File(app.filesDir, "vineyard_logos/55555555-5555-4555-8555-555555555555")
        .listFiles().orEmpty().associate { it.name to it.readBytes().toList() }

    private fun assertContractBytes() {
        historicalBytes?.forEach { (name, values) -> values.forEach { (key, raw) ->
            assertEquals("$name historical entry changed", raw, app.getSharedPreferences(name, 0).all[key])
        } }
        retainedContractBytes?.forEach { (name, values) -> assertEquals(name, values, app.getSharedPreferences(name, 0).all) }
        retainedLogoBytes?.let { assertEquals("Retained production logo changed", it, logoBytes()) }
    }

    private fun retainCombinedStores() {
        combinedRecovery = true
        check(SavedChemicalLocalStore(app).save(A, historical,
            listOf(SavedChemical("historical-chemical", historical, name = "Retained chemical", ratePerHa = 1.5))))
        val chemicals = app.getSharedPreferences("vinetrack_saved_chemicals_local", 0)
        val old = JsonArray(codec.parseToJsonElement(chemicals.getString("$A|$historical", null)!!).jsonArray.map {
            JsonObject(it.jsonObject - "vineyard_preferred_rate")
        })
        check(chemicals.edit().putString("$A|$historical", old.toString()).commit())
        check(DomainCacheStore(app).saveYieldSessions(historical, listOf(YieldEstimationSession(
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", historical, "2026-11-01T00:00:00Z",
            sampleSites = listOf(SampleSite("sample", block, "Retained block", 1, -33.0, 149.0, 1,
                BunchCountEntry(12.0, "2026-11-01T00:00:00Z", A))))), 1L))
        PruningStore(app).apply {
            saveSetups(historical, listOf(seasonRow.toModel()))
            saveEntries(historical, listOf(entryRow.toModel(listOf(PruningSegment(1, 2)), 2026,
                java.time.ZoneId.of("Australia/Sydney"))))
            saveActivities(historical, listOf(PruningAllocationEditor.adoptCanonical(
                PruningActivityDraft(entry, historical, "2026-08-10", enteredBy = A,
                    createdAtMs = java.time.Instant.parse("2026-08-10T00:00:00Z").toEpochMilli(),
                    updatedAtMs = java.time.Instant.parse("2026-08-10T01:00:00Z").toEpochMilli()),
                canonical, java.time.ZoneId.of("Australia/Sydney"))))
            saveLabourLines(historical, listOf(labourRow))
        }
        PruningYieldSettingsStore(app).save(historical, listOf(settingsRow))
        val actuals = SprayTankActualStore(app)
        val actual = SprayTankActual(id = "historical-actual", vineyardId = historical, sprayRecordId = "historical-spray",
            tripId = "historical-trip", tankSessionId = "historical-tank", tankNumber = 1, waterVolumeL = 343.8,
            chemicals = listOf(SprayTankActualChemical("line", name = "Retained chemical", actualAmountBase = 700.0, unit = "Kg")),
            confirmedAt = "2026-11-01T00:00:00Z", confirmedBy = A)
        check(actuals.save(actual))
        // Synthetic already-acknowledged fixture; pending confirmations are checked separately by the repository test.
        check(actuals.markSynced(actual.id))
        check(actuals.saveInputDraft(SprayActualInputDraft("tank:historical-trip:historical-tank", A, historical,
            mapOf("water" to "343.8", "line" to "0.700"), "historical-trip", "historical-tank", "historical-spray")))
        retainedContractBytes = retainedContractBytes.orEmpty() + listOf("vinetrack_pruning", "vinetrack_pruning_yield_settings", "vinetrack_spray_tank_actuals")
            .associateWith { app.getSharedPreferences(it, 0).all.toMap() }
        historicalBytes = listOf("vinetrack_domain_cache", "vinetrack_saved_chemicals_local").associateWith { name ->
            app.getSharedPreferences(name, 0).all.filterKeys { it.contains(historical) }
        }
        assertTrue(historicalBytes!!.values.all { it.isNotEmpty() })
    }

    private fun recoverThroughForm(wrongAccountFirst: Boolean = false, productionContracts: Boolean = false, combined: Boolean = false): Map<String, *> {
        signIn()
        val session = SessionStore(app)
        val obsolete = requireNotNull(session.accountAccess())
        retainDraft()
        if (productionContracts) retainProductionContracts()
        if (combined) { check(productionContracts); retainCombinedStores() }
        val draftBefore = app.getSharedPreferences("vinetrack_local_planning", 0).all.toMap()
        val evidence = AccountTransitionEvidence(app)
        val assessment = evidence.inspect(A)
        if (combined) {
            assertNull("Local-only inspection must not substitute for server pruning proof", assessment)
            assertEquals("PRUNING_SERVER_CONFIRMATION_REQUIRED", evidence.failureDiagnostic?.rule)
        } else assertNotNull("Populated recovery rejected at ${evidence.failureCategory}; keys=${app.getSharedPreferences(evidence.failureCategory, 0).all.keys}; files=${app.filesDir.walkTopDown().filter { it.isFile }.map { it.relativeTo(app.filesDir).path }.toList()}", assessment)
        scenario.close()
        session.clear()
        scenario = ActivityScenario.launch(MainActivity::class.java)
        awaitText("Local work protected")
        compose.onAllNodes(hasText("Settings") and hasClickAction()).assertCountEquals(0)
        fun submit() {
            compose.onNodeWithText("Account email").performTextReplacement("synthetic@example.invalid")
            compose.onNodeWithText("Password").performTextInput("synthetic-password")
            compose.onNodeWithText("Restore original account").performScrollTo().performClick()
        }
        if (wrongAccountFirst) {
            account.set(B)
            submit()
            awaitStage("recovery.wrong-account.IDENTITY") {
                compose.onAllNodesWithText("Recovery stage: IDENTITY.", substring = true).fetchSemanticsNodes().isNotEmpty()
            }
            assertTrue(session.retentionGuard.isLocked)
            assertContractBytes()
            assertEquals(draftBefore, app.getSharedPreferences("vinetrack_local_planning", 0).all)
            compose.onAllNodes(hasText("Home") and hasClickAction()).assertCountEquals(0)
            account.set(A)
        }
        submit()
        awaitStage("recovery.home") { compose.onAllNodes(hasText("Home") and hasClickAction()).fetchSemanticsNodes().isNotEmpty() }
        awaitStage("recovery.loaded", timeoutMillis = 60_000) { pending.isEmpty() && checkpoints.count { it == "vineyard.load.published" } >= 2 }
        assertFalse(session.withAccountAccess(obsolete) { fail("Obsolete session authority returned") })
        assertEquals(draftBefore, app.getSharedPreferences("vinetrack_local_planning", 0).all)
        assertEquals("original-creation", WorkTaskPlanningDraftStore(app).load(A, "33333333-3333-4333-8333-333333333333", null)?.creationId)
        assertEquals("block-$A", DomainCacheRepository(app).loadPaddocks(A, "33333333-3333-4333-8333-333333333333")!!.single().id)
        assertOriginalIdentityAndNoOperationalWrites()
        return draftBefore
    }

    private fun assertOriginalIdentityAndNoOperationalWrites() {
        assertContractBytes()
        assertEquals(A, SessionStore(app).userId)
        assertEquals("task-$A", DomainCacheRepository(app).loadWorkTasks(A, "33333333-3333-4333-8333-333333333333")!!.single().id)
        assertEquals("trip-$A", DomainCacheRepository(app).loadTrips(A, "33333333-3333-4333-8333-333333333333")!!.single().id)
        assertTrue("Unexpected operational writes: $operationalWrites", operationalWrites.isEmpty())
    }

    /** Samples wall time, main heartbeat/stacks and native screen without Compose synchronisation. */
    @OptIn(androidx.compose.runtime.ExperimentalComposeRuntimeApi::class)
    private fun watchEditor(label: String) {
        diagnosticWorker = Thread({
            try {
                repeat(3) { sample ->
                    Thread.sleep(2_000)
                    val latch = java.util.concurrent.CountDownLatch(1)
                    android.os.Handler(android.os.Looper.getMainLooper()).post { latch.countDown() }
                    val responsive = latch.await(500, java.util.concurrent.TimeUnit.MILLISECONDS)
                    val recomposers = androidx.compose.runtime.Recomposer.runningRecomposers.value.map { info ->
                        val internals = runCatching {
                            val outer = info.javaClass.getDeclaredField("this\$0").apply { isAccessible = true }.get(info)
                            fun value(name: String): Any? = outer.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(outer)
                            val clock = value("broadcastFrameClock")!!
                            "broadcastAwaiters=${clock.javaClass.getMethod("getHasAwaiters").invoke(clock)},invalidations=${value("compositionInvalidations")},snapshotInvalidations=${value("snapshotInvalidations")},concurrent=${value("concurrentCompositionsOutstanding")}"
                        }.getOrElse { "probe=${it.javaClass.simpleName}" }
                        "pending=${info.hasPendingWork},changes=${info.changeCount},$internals"
                    }
                    val details = "EDITOR_DIAGNOSTIC $label sample=$sample mainHeartbeat=$responsive clockMs=${compose.mainClock.currentTime} recomposers=$recomposers pending=$pending responses=${responses.size} checkpoints=${checkpoints.size} mainStack=${android.os.Looper.getMainLooper().thread.stackTrace.joinToString(" > ")}"
                    android.util.Log.i("CleanExitFixture", details)
                    val instrumentation = InstrumentationRegistry.getInstrumentation()
                    instrumentation.sendStatus(2, android.os.Bundle().apply { putString("stream", "\n$details\n") })
                    if (sample == 1) {
                        instrumentation.uiAutomation.takeScreenshot()?.let { bitmap ->
                            val directory = java.io.File(app.getExternalFilesDir(null), "recovery-editor-evidence").apply { mkdirs() }
                            java.io.File(directory, "$label.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
                            val scaled = android.graphics.Bitmap.createScaledBitmap(bitmap, 180, bitmap.height * 180 / bitmap.width, true)
                            val bytes = java.io.ByteArrayOutputStream().also { scaled.compress(android.graphics.Bitmap.CompressFormat.WEBP_LOSSY, 20, it) }.toByteArray()
                            android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP).chunked(1500).forEachIndexed { index, chunk ->
                                instrumentation.sendStatus(2, android.os.Bundle().apply { putString("stream", "\nRECOVERY_SCREEN_${label}_${index}=$chunk\n") })
                            }
                            if (scaled !== bitmap) scaled.recycle()
                            bitmap.recycle()
                        }
                    }
                }
            } catch (_: InterruptedException) { /* Test finished; no background work leaks. */ }
        }, "recovery-editor-diagnostic").apply { isDaemon = true; start() }
    }

    private fun openTaskEditor(label: String) {
        compose.onNodeWithText("Work Tasks").performScrollTo().performClick()
        awaitText("Log a New Task")
        compose.onNodeWithText("Log a New Task").performScrollTo().performClick()
        watchEditor(label)
        awaitText("No block")
    }

    @Test fun ordinarySignInPopulatedTaskEditorDiagnostic() {
        signIn()
        val before = retainDraft()
        openTaskEditor("ordinary")
        assertEquals(before, app.getSharedPreferences("vinetrack_local_planning", 0).all)
    }

    @Test fun recoveryFormPopulatedTaskEditorDiagnostic() {
        val before = recoverThroughForm()
        openTaskEditor("recovered")
        assertEquals(before, app.getSharedPreferences("vinetrack_local_planning", 0).all)
    }

    @Test fun recoveryFormHomeBlocksAndReopenPreserveDraft() {
        val before = recoverThroughForm(wrongAccountFirst = true, productionContracts = true)
        scenario.close()
        scenario = ActivityScenario.launch(MainActivity::class.java)
        awaitStage("reopen.home") { compose.onAllNodes(hasText("Home") and hasClickAction()).fetchSemanticsNodes().isNotEmpty() }
        compose.onAllNodesWithText("Local work protected").assertCountEquals(0)
        assertEquals(before, app.getSharedPreferences("vinetrack_local_planning", 0).all)
        assertFalse(SessionStore(app).retentionGuard.isLocked)
        assertEquals("block-$A", DomainCacheRepository(app).loadPaddocks(A, "33333333-3333-4333-8333-333333333333")!!.single().id)
        assertOriginalIdentityAndNoOperationalWrites()
    }

    @Test fun combinedChemicalYieldPruningSnapshotAndActualsRecoverThroughFormAndReopen() {
        recoverThroughForm(wrongAccountFirst = true, productionContracts = true, combined = true)
        scenario.close()
        scenario = ActivityScenario.launch(MainActivity::class.java)
        awaitStage("combined.reopen.home") { compose.onAllNodes(hasText("Home") and hasClickAction()).fetchSemanticsNodes().isNotEmpty() }
        awaitStage("combined.reopen.loaded", timeoutMillis = 60_000) { pending.isEmpty() && checkpoints.count { it == "vineyard.load.published" } >= 3 }
        compose.onAllNodesWithText("Local work protected").assertCountEquals(0)
        assertOriginalIdentityAndNoOperationalWrites()
        assertEquals(1.5, SavedChemicalLocalStore(app).load(A, historical).single().ratePerHa!!, 0.0)
        assertEquals(12.0, DomainCacheStore(app).loadYieldSessions(historical).single().sampleSites.single().bunchCountEntry!!.bunchesPerVine, 0.0)
        assertEquals(1, PruningStore(app).loadEntries(historical).size)
        assertEquals(1, PruningStore(app).loadActivities(historical).size)
        assertEquals(listOf(labourRow), PruningStore(app).loadLabourLines(historical))
        assertEquals(listOf(settingsRow), PruningYieldSettingsStore(app).load(historical))
        assertEquals("historical-trip", RecoverySnapshotStore(app).load(historical)!!.cachedTrips.single().id)
        val actuals = SprayTankActualStore(app)
        assertEquals(343.8, actuals.load().single().waterVolumeL!!, 0.0)
        assertEquals(700.0, actuals.load().single().chemicals.single().actualAmountBase!!, 0.0)
        assertEquals("0.700", actuals.inputDraft(A, historical, "tank:historical-trip:historical-tank")!!.text["line"])
        assertTrue(requests.contains("/rest/v1/rpc/get_pruning_activity"))
        assertContractBytes()
    }

    @Test fun recoveredHomeWorkTaskSelectsExistingBlock() {
        val before = recoverThroughForm(productionContracts = true)
        openTaskEditor("task-selection")
        compose.onNodeWithText("Block", substring = false).performScrollTo().performClick()
        compose.onNodeWithText("Private block $A", substring = false).assertExists().performClick()
        compose.onNodeWithContentDescription("Selected").assertExists()
        // Confirm the field itself changed, not just the presence of a menu option.
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
        compose.onNode(hasText("Private block $A") and hasText("Block")).assertExists()
        assertEquals(before, app.getSharedPreferences("vinetrack_local_planning", 0).all)
        assertOriginalIdentityAndNoOperationalWrites()
    }

    @Test fun lockedRecoveryCopiesPreciseSafeDiagnosticsWithoutAnotherSignIn() {
        signIn()
        val raw = "[{\"private-note-secret\":\"never-copy-this\"}]"
        val prefs = app.getSharedPreferences("vinetrack_pending_writes", 0)
        check(prefs.edit().putString("pending_writes_json", raw).commit())
        scenario.close()
        SessionStore(app).clear()
        scenario = ActivityScenario.launch(MainActivity::class.java)
        awaitText("Local work protected")
        compose.onNodeWithText("Account email").performTextReplacement("synthetic@example.invalid")
        compose.onNodeWithText("Password").performTextInput("synthetic-password")
        compose.onNodeWithText("Restore original account").performClick()
        awaitStage("retained.failure.visible") {
            compose.onAllNodesWithText("Recovery stage: RETAINED_EVIDENCE.", substring = true).fetchSemanticsNodes().isNotEmpty()
        }
        fun copyAndCheck(stage: String) {
            val tokenCalls = responses.count { it.startsWith("POST /auth/v1/token ") }
            compose.onNodeWithText("Copy recovery diagnostics").performScrollTo().performClick()
            awaitStage("diagnostics.copied") {
                compose.onAllNodesWithText("Recovery diagnostics copied.", substring = true).fetchSemanticsNodes().isNotEmpty()
            }
            var text = ""
            scenario.onActivity {
                val clipboard = it.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                text = clipboard.primaryClip!!.getItemAt(0).text.toString()
            }
            assertTrue(text, text.contains("Recovery stage: $stage"))
            assertTrue(text, text.contains("Store/category: vinetrack_pending_writes"))
            assertTrue(text, text.contains("Validation rule: DECODE_SCHEMA"))
            assertTrue(text, text.contains("Version code: ${com.rork.vinetrack.BuildConfig.VERSION_CODE}"))
            listOf(A, B, "never-copy-this", "private-note-secret", "synthetic-password", "synthetic@example.invalid").forEach { assertFalse(text.contains(it)) }
            assertEquals(tokenCalls, responses.count { it.startsWith("POST /auth/v1/token ") })
            assertEquals(raw, prefs.getString("pending_writes_json", null))
            assertTrue(SessionStore(app).retentionGuard.isLocked)
            compose.onAllNodes(hasText("Home") and hasClickAction()).assertCountEquals(0)
        }
        copyAndCheck("RETAINED_EVIDENCE")
        scenario.close()
        scenario = ActivityScenario.launch(MainActivity::class.java)
        awaitText("Local work protected")
        copyAndCheck("LOCKED")
        assertTrue(operationalWrites.isEmpty())
    }

    @Test fun recoveryExistingTaskEditorRetainsOriginalRequestAndFields() {
        recoverThroughForm(productionContracts = true)
        compose.onNodeWithText("Work Tasks").performScrollTo().performClick()
        awaitText("Task Log")
        compose.onNodeWithText("Task Log").performScrollTo().performClick()
        awaitText("Task")
        compose.onNode(hasText("Task", substring = false) and hasText("No block", substring = false)).performScrollTo().performClick()
        compose.onNodeWithContentDescription("Edit task").performClick()
        awaitText("Check saved task")
        compose.onNodeWithText("Assigned to: Greg Horner").assertExists()
        compose.onNodeWithText("Need bamboo and loose tie onto it", substring = false).assertExists()
        compose.onNode(hasText("1") and hasText("Duration (hours, optional)")).assertExists()
        assertContractBytes()
        assertEquals("task-$A", WorkTaskPlanningDraftStore(app).load(A, "33333333-3333-4333-8333-333333333333", "task-$A")?.taskId)
        assertEquals(TaskWritePhase.UNKNOWN, WorkTaskPlanningDraftStore(app).loadIntent(A, "33333333-3333-4333-8333-333333333333", "task-$A")?.let {
            WorkTaskPlanningDraftStore(app).recovery(it)?.phase
        })
        assertOriginalIdentityAndNoOperationalWrites()
    }

    @Test fun recoveredHomeTripSelectsExistingBlock() {
        val before = recoverThroughForm(productionContracts = true)
        compose.onNode(hasText("Trip") and hasClickAction()).performClick()
        awaitText("  Start Trip")
        compose.onNodeWithText("  Start Trip").assertIsDisplayed().performClick()
        awaitText("Start a Trip")
        compose.onNodeWithText("Maintenance Trip", substring = false).performClick()
        awaitText("No blocks selected")
        compose.onNodeWithText("No blocks selected", substring = false).performScrollTo().performClick()
        compose.onNodeWithText("Private block $A", substring = false).performClick()
        compose.onNode(isToggleable() and hasAnyAncestor(hasText("Private block $A"))).assertIsOn()
        compose.onNodeWithText("Done", substring = false).performClick()
        compose.onNodeWithText("Private block $A", substring = false).assertExists()
        compose.onAllNodesWithText("No blocks selected", substring = false).assertCountEquals(0)
        assertEquals(before, app.getSharedPreferences("vinetrack_local_planning", 0).all)
        assertFalse(SessionStore(app).retentionGuard.isLocked)
        assertOriginalIdentityAndNoOperationalWrites()
    }

    @Test fun populatedSettingsExitRecreateRelaunchReturnAThenBIsolatesPrivateCachesAndAuthority() {
        signIn()
        val session = SessionStore(app)
        val old = requireNotNull(session.accountAccess())
        val cache = DomainCacheRepository(app)
        assertEquals("trip-$A", cache.loadTrips(A, "33333333-3333-4333-8333-333333333333")!!.single().id)
        assertEquals("pin-$A", cache.loadPins(A, "33333333-3333-4333-8333-333333333333")!!.single().id)
        val before = app.getSharedPreferences("vinetrack_domain_cache", 0).all.toMap()
        val devicePrefs = app.getSharedPreferences("vinetrack_app_prefs", 0).all.toMap()
        val chemicals = app.getSharedPreferences("vinetrack_saved_chemicals_local", 0).all.toMap()
        assertEquals("chemical-$A", SavedChemicalLocalStore(app).load(A, "33333333-3333-4333-8333-333333333333").single().id)
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
        assertEquals("chemical-$A", SavedChemicalLocalStore(app).load(A, "33333333-3333-4333-8333-333333333333").single().id)
        settingsSignOut()
        awaitText("Email")
        account.set(B)
        signIn()
        val bCache = DomainCacheRepository(app)
        assertNull(bCache.loadPins(B, "33333333-3333-4333-8333-333333333333"))
        assertNull(bCache.loadTrips(B, "33333333-3333-4333-8333-333333333333"))
        assertEquals("pin-$B", bCache.loadPins(B, "44444444-4444-4444-8444-444444444444")!!.single().id)
        assertTrue(SavedChemicalLocalStore(app).load(B, "33333333-3333-4333-8333-333333333333").isEmpty())
        assertEquals("chemical-$B", SavedChemicalLocalStore(app).load(B, "44444444-4444-4444-8444-444444444444").single().id)
        chemicals.forEach { (key, raw) -> assertEquals(raw, app.getSharedPreferences("vinetrack_saved_chemicals_local", 0).all[key]) }
        compose.onAllNodesWithText("Private chemical $A").assertCountEquals(0)
        assertFalse(session.withAccountAccess(old) { fail("A callback reached B") })
        compose.onAllNodesWithText("Private pin $A").assertCountEquals(0)
        compose.onAllNodesWithText("Private trip $A").assertCountEquals(0)
        assertEquals(B, SessionStore(app).userId)
        assertEquals(2, logouts.get())
    }

    @Test fun completedPhotoEmptyDirectoryAllowsSignedOutStartupAndSafeAThenBLogin() {
        signIn()
        val session = SessionStore(app)
        val old = requireNotNull(session.accountAccess())
        val image = android.graphics.Bitmap.createBitmap(8, 8, android.graphics.Bitmap.Config.ARGB_8888)
        val bytes = try { java.io.ByteArrayOutputStream().use { out ->
            check(image.compress(android.graphics.Bitmap.CompressFormat.JPEG, 90, out)); out.toByteArray()
        } } finally { image.recycle() }
        val photos = PendingPhotoRepository(app)
        val photo = photos.enqueue("completed-private-photo-A", vineyard, bytes)
        assertArrayEquals(bytes, java.io.File(photo.localPath).readBytes())
        assertEquals(photo, PendingPhotoRepository(app).list().single())
        assertTrue(photos.removeIfCurrent(photo.id, photo.revision))
        val directory = java.io.File(app.filesDir, "pending_pin_photos")
        fun assertEmptyPhotoEvidence() {
            assertTrue(directory.isDirectory)
            val files = requireNotNull(directory.listFiles())
            assertEquals("Retained photo files: ${files.map { it.name }}", 0, files.size)
            val fresh = PendingPhotoRepository(app)
            assertTrue(fresh.list().isEmpty())
            assertEquals(0, fresh.currentPendingCount())
            assertNull(fresh.latestFile(photo.clientPinId))
            assertNull(fresh.displaySource(photo.clientPinId, null, null).localPath)
            assertTrue(PendingPhotoStore(app).loadCompletedCache().isEmpty())
        }
        assertEmptyPhotoEvidence()
        settingsSignOut()
        awaitText("Email")
        assertFalse(session.hasSession)
        assertFalse(session.retentionGuard.isLocked)
        scenario.recreate()
        awaitText("Email")
        scenario.close()
        scenario = ActivityScenario.launch(MainActivity::class.java)
        awaitText("Email")
        assertEmptyPhotoEvidence()
        assertNull(uncaught.get())
        assertFalse(checkpoints.any { it.contains("FieldAccessRevoked") })
        signIn()
        assertEquals(A, SessionStore(app).userId)
        assertEmptyPhotoEvidence()
        assertFalse(session.withAccountAccess(old) { fail("Old A photo authority revived") })
        settingsSignOut()
        awaitText("Email")
        account.set(B)
        signIn()
        assertEquals(B, SessionStore(app).userId)
        assertEmptyPhotoEvidence()
        assertNull(DomainCacheRepository(app).loadPins(B, "33333333-3333-4333-8333-333333333333"))
        compose.onAllNodesWithText("Private pin $A").assertCountEquals(0)
        assertFalse(session.withAccountAccess(old) { fail("A photo callback reached B") })
        assertEquals(2, logouts.get())
        assertNull(uncaught.get())
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
        val row = PendingWrite("unsent", "pin", "create", """{"id":"unsent","vineyard_id":"$vineyard"}""", "unsent", 1, 1)
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
        private val readOnlyRpcs = setOf("is_system_admin", "get_system_feature_flags", "get_my_vinetrack_access",
            "get_my_vineyard_access_matrix", "get_my_operational_tool_preferences", "get_app_release_policy",
            "get_canopy_reference_images_v1", "get_vineyard_team_members", "get_grape_clone_catalog",
            "get_pruning_vineyard_summary", "get_pruning_activity", "list_pruning_activities", "get_vineyard_yield_sampling_settings",
            "list_vineyard_spray_targets", "list_vineyard_grape_varieties", "get_rootstock_catalog",
            "list_vineyard_grape_clones", "list_vineyard_rootstocks", "get_vineyard_region_settings",
            "get_vineyard_season_settings").map { "/rest/v1/rpc/$it" }.toSet()
        private const val A = "11111111-1111-4111-8111-111111111111"
        private const val B = "22222222-2222-4222-8222-222222222222"
        private val emptyTables = setOf("machines", "vineyard_machines", "tractors", "operator_categories", "worker_types", "work_task_paddocks",
            "work_task_labour_lines", "work_task_machine_lines", "work_task_materials", "trip_cost_allocations", "maintenance_logs", "historical_yield_records",
            "damage_records", "yield_estimation_sessions", "tractor_fuel_logs", "spray_records", "spray_jobs", "vineyard_spray_targets", "spray_equipment",
            "saved_chemicals", "picking_records", "clone_catalog", "rootstock_catalog", "vineyard_clones", "vineyard_rootstocks", "app_notices",
            "growth_stage_images", "grape_varieties", "button_configurations", "vineyard_buttons", "custom_pin_types")
    }
}
