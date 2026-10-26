package com.rork.vinetrack.data

import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.SavedStateHandle
import com.rork.vinetrack.ui.main.*
import com.rork.vinetrack.ui.screens.SpraysScreen
import com.rork.vinetrack.ui.screens.TripsScreen
import org.junit.Rule
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.auth.SessionPhase
import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.data.spray.*
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
    @get:Rule val compose = createComposeRule()
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
    private var loseActivationResponse = false
    private var activationRequests = 0
    private var mode = "accepted"
    private var hold: CompletableDeferred<Unit>? = null

    @After fun cleanup() {
        instrumentation.runOnMainSync { models.clear() }
        SupabaseClient.installInstrumentationTransport(null)
        client?.close()
        names.forEach { base.deleteSharedPreferences(prefix + it) }
        root.deleteRecursively()
    }

    private fun setup(forCalculatorUi: Boolean = false) {
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
                forCalculatorUi && path.endsWith("/vineyard_members") -> respond("[{\"vineyard_id\":\"$vineyard\",\"user_id\":\"$actor\",\"role\":\"manager\"}]", HttpStatusCode.OK, jsonHeaders)
                forCalculatorUi && path.endsWith("/vineyards") -> respond("[{\"id\":\"$vineyard\",\"name\":\"Fixture\",\"timezone\":\"Australia/Sydney\"}]", HttpStatusCode.OK, jsonHeaders)
                path.endsWith("/rpc/save_legacy_spray_pair_v1") || path.endsWith("/rpc/recover_legacy_spray_pair_v1") -> {
                    val body = Json.parseToJsonElement((request.body as TextContent).text).jsonObject
                    if (path.endsWith("/save_legacy_spray_pair_v1")) {
                        creates++; savedRequest = body
                        savedTrip = body.getValue("p_trip").jsonObject
                        savedRecord = body.getValue("p_record").jsonObject
                        hold?.await()
                        if (mode == "lost") error("Synthetic lost response after commitment")
                        if (mode == "read_only") return@MockEngine respond(
                            "{\"code\":\"VT_READ_ONLY\"}", HttpStatusCode.Forbidden, jsonHeaders)
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
                    if (failReload && savedTrip != null) { failReload = false; respond("{}", HttpStatusCode.ServiceUnavailable, jsonHeaders) }
                    else respond(JsonArray(listOfNotNull(savedTrip)).toString(), HttpStatusCode.OK, jsonHeaders)
                }
                path.endsWith("/trips") && request.method == HttpMethod.Patch -> {
                    val patch = Json.parseToJsonElement((request.body as TextContent).text).jsonObject
                    savedTrip = JsonObject(savedTrip.orEmpty() + patch)
                    if (patch["is_active"]?.jsonPrimitive?.booleanOrNull == true) {
                        activationRequests++
                        if (loseActivationResponse) { loseActivationResponse = false; error("Synthetic lost activation response after commitment") }
                    }
                    respond(JsonArray(listOfNotNull(savedTrip)).toString(), HttpStatusCode.OK, jsonHeaders)
                }
                path.endsWith("/spray_records") -> respond(JsonArray(listOfNotNull(savedRecord)).toString(), HttpStatusCode.OK, jsonHeaders)
                else -> respond("[]", HttpStatusCode.OK, jsonHeaders) // No live-service fallback.
            }
        }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
        SupabaseClient.installInstrumentationTransport(client)
        instrumentation.runOnMainSync {
            if (forCalculatorUi) SessionStore(app).apply {
                save("synthetic-access", "synthetic-refresh", actor, null)
                selectedVineyardId = vineyard
            }
            vm = AppViewModel(app); models.put("start", vm)
        }
        if (!forCalculatorUi) {
            // Finish the genuine signed-out restore before installing this test's synthetic
            // session. Otherwise startup can revoke it during the paired-save suspension.
            compose.waitUntil(10_000) { vm.ui.value.sessionPhase == SessionPhase.SignedOut }
        }
        instrumentation.runOnMainSync {
            session().save("synthetic-access", "synthetic-refresh", actor, null)
            session().selectedVineyardId = vineyard
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

    private val productId = UUID.randomUUID().toString()
    private val blockId = UUID.randomUUID().toString()
    private val firstClock = "2026-10-15T23:59:55Z"
    private val retryClock = "2026-10-16T00:00:05Z" // Same vineyard day in Sydney, different UTC dates.

    private fun calculatorInput(clock: String): SprayRecordRepository.SprayInput {
        val chemical = SavedChemical(productId, vineyard, name = "Snapshot fixture", unit = "g", chemicalGroup = "11")
        val block = Paddock(blockId, vineyard, "Calculation fixture", polygonPoints = listOf(
            CoordinatePoint(-33.0, 149.0), CoordinatePoint(-33.001, 149.0),
            CoordinatePoint(-33.001, 149.001), CoordinatePoint(-33.0, 149.001)))
        val flow = SprayGuidedFlow(SprayGuidedInputs(
            blocks = listOf(SprayBlockInput(block.id, grossAreaHectares = block.areaHectares)),
            targets = setOf(SprayTarget.POWDERY_MILDEW), sprayHeadTarget = SprayHeadTarget.FULL_CANOPY,
            isGrowthStageAssigned = true, isEquipmentSelected = true, isEquipmentConfirmed = true,
            carrierBasis = SprayCarrierBasis.MANUAL_TOTAL_VOLUME, manualTotalLitres = 420.0, tankCapacityLitres = 2000.0,
            products = listOf(SprayProductLineInput(productId, chemical.name, "g", SprayProductRateBasis.WHOLE_BLOCK_AREA, 750.0)),
        ))
        val plan = flow.plan
        return SprayCalculatorInputBuilder.build(input().copy(operationType = "Foliar Spray", tanks = emptyList(),
            applicationGeometry = requireNotNull(flow.snapshot)), clock,
            listOf(SprayCalculatorInputBuilder.Product(productId,
                com.rork.vinetrack.data.spray.SprayProductRateBasis.WHOLE_BLOCK_AREA,
                750.0, "g", true, null, false)), listOf(chemical)) { snapshots ->
            SprayGuidedTankBuilder.build(plan, plan.carrier.litresPerHectare ?: 0.0, snapshots = snapshots)
        }.also {
            assertEquals(clock, it.date); assertEquals(clock, it.startTime)
            val snapshot = requireNotNull(it.tanks.single().chemicals.single().chemicalSnapshot)
            assertEquals(clock, snapshot.capturedAt); assertEquals(750.0, snapshot.appliedRate!!, 0.0)
        }
    }

    private fun start(hours: Double? = null, draft: SprayRecordRepository.SprayInput = input(),
        blocks: List<String> = if (draft.applicationGeometry != null) listOf(blockId) else emptyList()): SprayStartOutcome {
        val done = CountDownLatch(1); val outcome = AtomicReference<SprayStartOutcome>()
        instrumentation.runOnMainSync { vm.startSprayJobNow(draft, blocks.firstOrNull(), blocks, "Fixture", startEngineHours = hours) { outcome.set(it); done.countDown() } }
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
    private var uiGeneration by mutableStateOf(0)
    private var showUi by mutableStateOf(true)
    private var navigationCallbacks = 0
    private lateinit var work: WorkContextViewModel

    private fun openCalculatorJourney() {
        setup(forCalculatorUi = true)
        instrumentation.uiAutomation.grantRuntimePermission(base.packageName, android.Manifest.permission.ACCESS_COARSE_LOCATION)
        instrumentation.uiAutomation.grantRuntimePermission(base.packageName, android.Manifest.permission.ACCESS_FINE_LOCATION)
        val equipmentId = UUID.randomUUID().toString()
        val prefillId = UUID.randomUUID().toString()
        val sourceId = UUID.randomUUID().toString()
        val draft = calculatorInput(firstClock).copy(sprayEquipmentId = equipmentId)
        val recordRepo = SprayRecordRepository(session())
        val prefill = SupabaseClient.json.decodeFromJsonElement(SprayRecord.serializer(),
            recordRepo.legacyReceiptInsert(vineyard, draft.copy(tripId = sourceId), prefillId, firstClock, actor))
            .copy(templateGrowthStageCode = "EL4", programCalculatorInputs = SprayProgramCalculatorInputs(
                carrierBasis = SprayCarrierBasis.MANUAL_TOTAL_VOLUME.raw))
        compose.runOnUiThread {
            state().value = state().value.copy(
                sprayRecords = listOf(prefill),
                trips = listOf(Trip(sourceId, vineyard, paddockId = blockId, paddockIds = listOf(blockId), isActive = false)),
                paddocks = listOf(Paddock(blockId, vineyard, "Calculation fixture", polygonPoints = listOf(
                    CoordinatePoint(-33.0, 149.0), CoordinatePoint(-33.001, 149.0),
                    CoordinatePoint(-33.001, 149.001), CoordinatePoint(-33.0, 149.001)))),
                sprayEquipment = listOf(SprayEquipment(equipmentId, vineyard, "Fixture sprayer", 2000.0)),
                savedChemicals = listOf(SavedChemical(productId, vineyard, name = "Snapshot fixture", unit = "g", chemicalGroup = "11")),
            )
            work = WorkContextViewModel(SavedStateHandle()); work.setTab(MainTab.Program)
        }
        val references = state().value
        compose.setContent {
            MaterialTheme {
                val live by vm.ui.collectAsState()
                // Reference catalog/geometry are synthetic input props; incidental startup [] responses must not erase them.
                val current = live.copy(savedChemicals = references.savedChemicals, paddocks = references.paddocks,
                    sprayEquipment = references.sprayEquipment,
                    sprayRecords = live.sprayRecords + references.sprayRecords.filter { old -> live.sprayRecords.none { it.id == old.id } },
                    trips = live.trips + references.trips.filter { old -> live.trips.none { it.id == old.id } })
                val selected by work.selectedTripId.collectAsState()
                val tab by work.tab.collectAsState()
                if (showUi) key(uiGeneration) {
                    CalculatorStartDestination(vm, current, work)
                    if (tab == MainTab.Trip) CompositionLocalProvider(androidx.compose.ui.platform.LocalInspectionMode provides true) {
                        // Google's Compose preview branch excludes the emulator's microG map renderer only.
                        // TripDetail, Actual dialog, callbacks, commit and real LocationTracker remain production code.
                        TripsScreen(vm, current, selectedTripId = selected,
                            onSelectedTripIdChange = work::setSelectedTripId)
                    } else SpraysScreen(vm, current, initialOpenCalculator = true, initialCalculatorPrefillId = prefillId,
                        onOpenTrip = { navigationCallbacks++; work.openCalculatorTrip(it) })
                }
            }
        }
        compose.mainClock.autoAdvance = true
        tick()
        compose.onNodeWithText("Equipment", substring = false).performScrollTo().performClick()
        tick()
        compose.onNode(hasText("Confirm equipment", substring = true) and hasClickAction()).performScrollTo().performClick()
        tick()
        compose.onNode(hasScrollToNodeAction()).performScrollToNode(hasText("Create Spray Job & View Tank Mix", substring = true))
        compose.onNodeWithText("Create Spray Job & View Tank Mix", substring = true).assertIsEnabled().performClick()
        tick()
    }

    private fun tick() { compose.mainClock.advanceTimeBy(600); compose.waitForIdle() }
    private fun pressCalculatorStart(hours: String? = null) {
        try {
            compose.onNode(hasScrollToNodeAction()).performScrollToNode(hasText("Start Spray Trip", substring = true))
        } catch (failure: AssertionError) {
            throw AssertionError("Calculator Start unavailable; outcome=${vm.calculatorStartOutcome.value}; error=${vm.ui.value.sprayError}; tree=${compose.onRoot().printToString()}", failure)
        }
        compose.onNodeWithText("Start Spray Trip", substring = true).performClick(); tick()
        if (hours != null) {
            compose.onNodeWithText("Start engine hours (optional)").performTextInput(hours)
            tick()
        }
        // Exercise the production Button's accessibility action, not an IME-obscured screen coordinate.
        compose.onNode(hasText("Start Trip") and hasClickAction()).performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.OnClick) { it() }
        tick()
    }
    private fun awaitTankDestination(hours: Double?) {
        compose.waitUntil(20_000) { work.selectedTripId.value != null || vm.calculatorStartOutcome.value?.message != null }
        assertNotNull("Navigation missing: ${vm.calculatorStartOutcome.value}; error=${vm.ui.value.sprayError}", work.selectedTripId.value)
        tick()
        val id = requireNotNull(work.selectedTripId.value)
        assertEquals(savedTrip!!.getValue("id").jsonPrimitive.content, id)
        assertEquals(id, vm.ui.value.activeTrip?.id)
        assertEquals(hours, vm.ui.value.activeTrip?.startEngineHours)
        compose.onNodeWithText("Confirm Actual Tank Mix").assertExists()
        assertFalse(vm.ui.value.isTracking); assertEquals(1, creates)
        assertNull("Destination must acknowledge only after TripDetail is composed", vm.calculatorStartOutcome.value)
    }

    @Test(timeout = 90_000) fun calculatorButtonBlankHoursReachesTankThenRecording() {
        openCalculatorJourney(); pressCalculatorStart(); awaitTankDestination(null)
        assertEquals(1, navigationCallbacks)
        compose.onNodeWithText("Start recording").performClick(); tick()
        assertTrue(vm.ui.value.isTracking)
        assertFalse(vm.requiresFirstTankReview(vm.ui.value.activeTrip!!))
        assertEquals(1, vm.ui.value.activeTrip!!.tankSessions.size)
        compose.onNodeWithText("Confirm Actual Tank Mix").assertDoesNotExist()
    }

    @Test(timeout = 90_000) fun calculatorButtonValidHoursAcceptedReloadFailureStillOpensOriginalTank() {
        openCalculatorJourney(); failReload = true
        pressCalculatorStart("123.5"); awaitTankDestination(123.5)
        assertEquals(1, navigationCallbacks); assertEquals(1, recoveries)
        val original = storedAttempts().single()
        assertFrozen(original)
        assertEquals(123.5, original.startEngineHours!!, 0.0)
    }

    @Test(timeout = 90_000) fun calculatorButtonLostReceiptRetryPreservesOriginalAndNavigatesOnce() {
        openCalculatorJourney(); mode = "lost"; pressCalculatorStart("123.5")
        compose.waitUntil(20_000) { vm.calculatorStartOutcome.value?.message != null }; tick()
        val original = LegacySpraySaveStore(app).retainedStart(vineyard)
            ?: error("Expected retained lost receipt, outcome=${vm.calculatorStartOutcome.value}, creates=$creates")
        assertEquals(0, navigationCallbacks); assertNull(work.selectedTripId.value)
        compose.onNode(hasScrollToNodeAction()).performScrollToNode(hasText("Inspect retained Start"))
        compose.onNodeWithText("Inspect retained Start").assertExists()
        mode = "accepted"; failReload = true
        pressCalculatorStart("999"); awaitTankDestination(123.5)
        assertEquals(1, creates); assertEquals(1, recoveries); assertEquals(1, navigationCallbacks); assertFrozen(original)
    }

    @Test(timeout = 90_000) fun calculatorButtonDelayedResultSurvivesDisposedUiWithoutReactivation() {
        openCalculatorJourney(); hold = CompletableDeferred()
        pressCalculatorStart("123.5")
        compose.waitUntil(20_000) { creates == 1 }
        compose.runOnUiThread { showUi = false }; tick()
        hold!!.complete(Unit)
        compose.waitUntil(20_000) { vm.calculatorStartOutcome.value?.isStarted == true }
        val originalId = vm.calculatorStartOutcome.value!!.tripId
        assertEquals(0, navigationCallbacks); assertNull(work.selectedTripId.value)
        compose.runOnUiThread { uiGeneration++; showUi = true }; tick()
        awaitTankDestination(123.5)
        assertEquals(originalId, work.selectedTripId.value); assertEquals(0, navigationCallbacks)
        val before = vm.ui.value.activeTrip!!
        compose.runOnUiThread { uiGeneration++ }; tick()
        assertEquals(originalId, work.selectedTripId.value); assertEquals(1, creates)
        assertEquals(before.startTime, vm.ui.value.activeTrip!!.startTime)
        assertEquals(before.startEngineHours, vm.ui.value.activeTrip!!.startEngineHours)
    }

    @Test(timeout = 90_000) fun calculatorButtonLostActivationRestoresSameTankDestination() {
        openCalculatorJourney(); loseActivationResponse = true
        pressCalculatorStart("123.5"); awaitTankDestination(123.5)
        compose.waitUntil(20_000) { activationRequests == 1 }; tick()
        val id = requireNotNull(work.selectedTripId.value)
        val original = storedAttempts().single()
        compose.runOnUiThread { uiGeneration++ }; tick()
        compose.onNodeWithText("Confirm Actual Tank Mix").assertExists()
        assertEquals(id, work.selectedTripId.value); assertEquals(1, creates)
        assertEquals(1, navigationCallbacks); assertEquals(1, activationRequests)
        assertEquals(original, storedAttempts().single()); assertFalse(vm.ui.value.isTracking)
        val pending = AppViewModel::class.java.getDeclaredField("pendingWrites").let { it.isAccessible = true; it.get(vm) as PendingWriteRepository }
        compose.waitUntil(20_000) { pending.list().none { it.entityType == PendingEntityType.TRIP_START && it.clientId == id && it.status == PendingWriteStatus.IN_PROGRESS } }
        pending.list().singleOrNull { it.entityType == PendingEntityType.TRIP_START && it.clientId == id }?.let { marker ->
            compose.runOnUiThread { assertTrue(vm.retryPendingSyncItem(marker.id)) }
        }
        compose.waitUntil(20_000) { pending.list().none { it.entityType == PendingEntityType.TRIP_START && it.clientId == id } }
        assertEquals(1, activationRequests); assertEquals(id, work.selectedTripId.value)
    }

    @Test(timeout = 90_000) fun calculatorButtonOlderAcceptedOpensInspectionWithoutAdoption() {
        openCalculatorJourney(); mode = "lost"; pressCalculatorStart()
        compose.waitUntil(20_000) { vm.calculatorStartOutcome.value?.message != null }; tick()
        val store = LegacySpraySaveStore(app)
        val attempt = requireNotNull(store.retainedStart(vineyard)); mode = "accepted"
        val access = requireNotNull(session().accountAccess())
        kotlinx.coroutines.runBlocking { assertTrue(store.sendReceipt(attempt, { true }) { rpc, request ->
            LegacySprayPairReceipt.transport(session(), access, rpc, request)
        }) }
        // Synthetic older-version fixture, derived from this real button's exact request + verified receipt.
        val older = storedAttempts().single().copy(startRequested = false, startEngineHours = null)
        app.getSharedPreferences(LegacySpraySaveStore.PREFERENCES, Context.MODE_PRIVATE).edit()
            .putString("attempts", Json { encodeDefaults = true }.encodeToString(kotlinx.serialization.builtins.ListSerializer(LegacySpraySaveStore.Attempt.serializer()), listOf(older))).commit()
        assertNull("Synthetic older fixture must decode", store.retainedStart(vineyard))
        assertEquals(listOf(older), store.olderAcceptedMatch(vineyard, older.input, older.trip.paddockIds, older.trip.trackingPattern))
        pressCalculatorStart(); compose.waitUntil(20_000) { vm.calculatorStartOutcome.value?.message != null }; tick()
        assertTrue("Expected older inspection: ${vm.calculatorStartOutcome.value}", vm.calculatorStartOutcome.value!!.inspectionTripIds.contains(older.trip.id))
        compose.onNodeWithText("Inspect retained Start").assertExists()
        compose.onNodeWithText("Trip: ${older.trip.id}").assertExists()
        assertNull(work.selectedTripId.value); assertNull(ActiveTripStore(app).load())
        assertEquals(1, creates); assertEquals(listOf(older), storedAttempts())
    }

    @Test(timeout = 90_000) fun calculatorButtonBlockedReceiptShowsInspectionWithOriginalIdentity() {
        openCalculatorJourney(); mode = "unavailable"; pressCalculatorStart()
        compose.waitUntil(20_000) { vm.calculatorStartOutcome.value?.message != null }; tick()
        val outcome = vm.calculatorStartOutcome.value!!
        assertNotNull(outcome.operationId); assertTrue(outcome.inspectionTripIds.isNotEmpty())
        compose.onNode(hasScrollToNodeAction()).performScrollToNode(hasText("Inspect retained Start"))
        compose.onNodeWithText("Inspect retained Start").performClick(); tick()
        compose.onNodeWithText("Operation: ${outcome.operationId}").assertExists()
        compose.onNodeWithText("Trip: ${outcome.inspectionTripIds.single()}").assertExists()
        assertNull(work.selectedTripId.value); assertNull(ActiveTripStore(app).load()); assertEquals(1, creates)
        compose.onNodeWithText("Return to retained setup").performClick(); tick()
        compose.onNodeWithText("Start Spray Trip", substring = true).assertExists()
    }

    @Test fun expiredCalculatorStartDoesNotPrepareOrSendReplacementWork() {
        setup()
        val draft = input()
        val frozen = SupabaseClient.json.encodeToString(SprayRecordRepository.SprayInput.serializer(), draft)
        val attempts = app.getSharedPreferences(LegacySpraySaveStore.PREFERENCES, Context.MODE_PRIVATE)
        val before = attempts.all.toMap()
        requireNotNull(OperationalWrites.authority).handleServerCode("VT_READ_ONLY", vineyard)
        val outcome = start(draft = draft)
        assertFalse(outcome.isStarted)
        assertEquals("Known expiry must not initiate a new journal", before, attempts.all)
        assertEquals(0, creates)
        assertEquals(0, activationRequests)
        assertEquals(0, recoveries)
        assertNull(ActiveTripStore(app).load())
        assertEquals(frozen, SupabaseClient.json.encodeToString(SprayRecordRepository.SprayInput.serializer(), draft))
    }

    @Test fun receiptReadOnlyRestoresUnclaimedOriginalAndStillAllowsRecoveryRead() {
        setup(); mode = "read_only"
        assertFalse(start().isStarted)
        val original = storedAttempts().single()
        assertFalse(original.rpcClaimed); assertNull(original.candidate); assertNull(original.verified)
        val gate = requireNotNull(OperationalWrites.authority)
        assertNotNull(gate.heldReason(vineyard))
        val frozen = storedAttempts()
        kotlinx.coroutines.runBlocking {
            val access = requireNotNull(session().accountAccess())
            try {
                LegacySprayPairReceipt.transport(session(), access, "save_legacy_spray_pair_v1", requireNotNull(original.rpc))
                fail("Independent held save reached transport")
            } catch (_: VineyardWriteAuthority.Restricted) { }
            assertEquals(1, creates)
            mode = "accepted"
            val receipt = LegacySprayPairReceipt.transport(session(), access, "recover_legacy_spray_pair_v1", requireNotNull(original.rpc))
            receipt.validate(original)
        }
        assertEquals(1, recoveries); assertEquals(frozen, storedAttempts())
        assertFalse(start().isStarted); assertEquals(frozen, storedAttempts()); assertEquals(1, creates)
        assertNull(ActiveTripStore(app).load())
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

    private fun storedAttempts(): List<LegacySpraySaveStore.Attempt> = SupabaseClient.json.decodeFromString(
        app.getSharedPreferences(LegacySpraySaveStore.PREFERENCES, Context.MODE_PRIVATE).getString("attempts", null)!!)

    private fun assertFrozen(original: LegacySpraySaveStore.Attempt) {
        val after = storedAttempts().single { it.recordId == original.recordId }
        assertEquals(original.rpc, after.rpc)
        assertEquals(original.rpc!!.operation, after.rpc!!.operation)
        assertEquals(original.recordId, after.recordId); assertEquals(original.trip, after.trip)
        assertEquals(original.input, after.input); assertEquals(original.startEngineHours, after.startEngineHours)
        assertEquals(original.rpc!!.record, savedRequest!!.getValue("p_record"))
    }

    @Test fun timestampedCalculatorAcceptedReloadFailureRecoversFrozenOriginal() {
        failReload = true; setup()
        assertFalse(start(123.5, calculatorInput(firstClock)).isStarted)
        val original = requireNotNull(LegacySpraySaveStore(app).retainedStart(vineyard))
        val recovered = start(999.0, calculatorInput(retryClock))
        assertTrue(recovered.message, recovered.isStarted); assertEquals(original.trip.id, recovered.tripId)
        assertEquals(123.5, ActiveTripStore(app).load()!!.trip.startEngineHours!!, 0.0)
        assertEquals(1, creates); assertEquals(1, recoveries); assertFrozen(original)
        assertFalse(vm.ui.value.isTracking); assertTrue(vm.requiresFirstTankReview(ActiveTripStore(app).load()!!.trip))
    }

    @Test fun timestampedCalculatorLostResponseRecoversFrozenOriginal() {
        mode = "lost"; setup()
        assertFalse(start(null, calculatorInput(firstClock)).isStarted)
        val original = requireNotNull(LegacySpraySaveStore(app).retainedStart(vineyard))
        mode = "accepted"
        val recovered = start(999.0, calculatorInput(retryClock))
        assertTrue(recovered.message, recovered.isStarted); assertEquals(original.trip.id, recovered.tripId)
        assertNull(ActiveTripStore(app).load()!!.trip.startEngineHours)
        assertEquals(1, creates); assertEquals(1, recoveries); assertFrozen(original)
    }

    @Test fun timestampedCalculatorOlderAcceptedIsInspectionNotIdentityProof() {
        setup()
        instrumentation.runOnMainSync { state().value = state().value.copy(vineyards = listOf(Vineyard(vineyard, "Fixture", timezone = "Australia/Sydney"))) }
        val done = CountDownLatch(1)
        instrumentation.runOnMainSync { vm.createSprayJobForLater(calculatorInput(firstClock), blockId, listOf(blockId), "Fixture") {
            assertTrue(it); done.countDown()
        } }
        assertTrue(done.await(20, TimeUnit.SECONDS))
        val originalId = savedTrip!!.getValue("id").jsonPrimitive.content
        val frozen = savedRequest
        val retained = storedAttempts()
        val outcome = start(null, calculatorInput(retryClock))
        assertFalse("Ambiguous older acceptance must not create or auto-activate", outcome.isStarted)
        assertTrue(outcome.message, outcome.message!!.contains(originalId))
        assertEquals(1, creates); assertEquals(frozen, savedRequest); assertNull(ActiveTripStore(app).load())
        assertEquals(retained, storedAttempts())
        assertTrue(outcome.message!!.contains("separate job")); assertTrue(outcome.message!!.contains("Save for Later"))
    }

    @Test fun timestampedCalculatorChangedEvidenceCannotResumeAcceptedOriginal() {
        failReload = true; setup()
        assertFalse(start(12.25, calculatorInput(firstClock)).isStarted)
        val original = requireNotNull(LegacySpraySaveStore(app).retainedStart(vineyard))
        val retry = calculatorInput(retryClock)
        val tank = retry.tanks.single(); val chemical = tank.chemicals.single(); val snapshot = chemical.chemicalSnapshot!!
        fun withChemical(value: SprayChemical) = retry.copy(tanks = listOf(tank.copy(chemicals = listOf(value))))
        val changes = listOf(
            "product identity" to withChemical(chemical.copy(savedChemicalId = UUID.randomUUID().toString())),
            "product name" to withChemical(chemical.copy(name = "Different")),
            "rate" to withChemical(chemical.copy(ratePerHa = 751.0)),
            "quantity" to withChemical(chemical.copy(volumePerTank = chemical.volumePerTank + 1)),
            "water" to retry.copy(tanks = listOf(tank.copy(waterVolume = tank.waterVolume + 1))),
            "equipment" to retry.copy(sprayEquipmentId = UUID.randomUUID().toString()),
            "tractor" to retry.copy(tractorId = UUID.randomUUID().toString()),
            "snapshot presence" to withChemical(chemical.copy(chemicalSnapshot = null)),
            "classification" to withChemical(chemical.copy(chemicalSnapshot = snapshot.copy(activityGroupCodes = listOf("3")))),
            "registration" to withChemical(chemical.copy(chemicalSnapshot = snapshot.copy(registrationIdentityKey = "AU:changed"))),
            "provenance" to withChemical(chemical.copy(chemicalSnapshot = snapshot.copy(rateEntryMethod = "canonical"))),
            "snapshot rate" to withChemical(chemical.copy(chemicalSnapshot = snapshot.copy(appliedRate = 751.0))),
            "non-generated clock" to withChemical(chemical.copy(chemicalSnapshot = snapshot.copy(capturedAt = "2026-01-01T00:00:00Z"))),
            "foreign parent" to retry.copy(tripId = UUID.randomUUID().toString()),
        )
        changes.forEach { (label, changed) ->
            assertFalse("Changed $label matched", original.matchesStartInput(changed))
            val outcome = start(999.0, changed)
            assertFalse("Changed $label resumed", outcome.isStarted)
            assertTrue(outcome.message, outcome.message!!.contains(original.trip.id))
            assertFrozen(original)
        }
        val differentBlock = start(999.0, retry, listOf(UUID.randomUUID().toString()))
        assertFalse(differentBlock.isStarted); assertTrue(differentBlock.message!!.contains(original.trip.id))
        assertEquals(1, creates); assertEquals(1, recoveries); assertNull(ActiveTripStore(app).load())
        assertFrozen(original)
    }

    private fun saveCalculator(draft: SprayRecordRepository.SprayInput): String {
        val done = CountDownLatch(1); val result = AtomicReference<Boolean>()
        instrumentation.runOnMainSync { vm.createSprayJobForLater(draft, blockId, listOf(blockId), "Fixture") {
            result.set(it); done.countDown()
        } }
        assertTrue(done.await(20, TimeUnit.SECONDS)); assertTrue(vm.ui.value.sprayError, result.get())
        return savedTrip!!.getValue("id").jsonPrimitive.content
    }

    @Test fun timestampedCalculatorChangedLostResponseStaysHeldThenUnchangedRecovers() {
        mode = "lost"; setup()
        assertFalse(start(12.25, calculatorInput(firstClock)).isStarted)
        val original = requireNotNull(LegacySpraySaveStore(app).retainedStart(vineyard))
        mode = "accepted"
        val draft = calculatorInput(retryClock)
        assertFalse(start(999.0, draft.copy(sprayEquipmentId = UUID.randomUUID().toString())).isStarted)
        assertFalse(start(999.0, draft, listOf(UUID.randomUUID().toString())).isStarted)
        assertEquals(0, recoveries); assertFrozen(original); assertNull(ActiveTripStore(app).load())
        val recovered = start(999.0, draft)
        assertTrue(recovered.message, recovered.isStarted); assertEquals(original.trip.id, recovered.tripId)
        assertEquals(12.25, ActiveTripStore(app).load()!!.trip.startEngineHours!!, 0.0)
        assertEquals(1, creates); assertEquals(1, recoveries); assertFrozen(original)
    }

    @Test fun olderAcceptedAmbiguityListsAllAndSeparateSavedJobCanStart() {
        setup()
        instrumentation.runOnMainSync { state().value = state().value.copy(vineyards = listOf(Vineyard(vineyard, "Fixture", timezone = "Australia/Sydney"))) }
        val firstId = saveCalculator(calculatorInput(firstClock))
        val secondId = saveCalculator(calculatorInput(retryClock))
        assertNotEquals(firstId, secondId)
        val originals = storedAttempts()
        val outcome = start(999.0, calculatorInput("2026-10-16T00:01:05Z"))
        assertFalse(outcome.isStarted)
        assertTrue(outcome.message!!.contains(firstId)); assertTrue(outcome.message!!.contains(secondId))
        assertEquals(2, creates); assertEquals(originals, storedAttempts()); assertNull(ActiveTripStore(app).load())
        // Explicit Save for Later is not denied by recipe/day ambiguity; the operator chooses its new UUID.
        val separateId = saveCalculator(calculatorInput("2026-10-16T00:02:05Z"))
        assertNotEquals(firstId, separateId); assertNotEquals(secondId, separateId)
        val done = CountDownLatch(1); val started = AtomicReference<Boolean>()
        instrumentation.runOnMainSync { vm.startSprayJob(separateId, 77.0) { started.set(it); done.countDown() } }
        assertTrue(done.await(20, TimeUnit.SECONDS)); assertTrue(vm.ui.value.sprayError, started.get())
        assertEquals(separateId, ActiveTripStore(app).load()!!.trip.id)
        assertEquals(77.0, ActiveTripStore(app).load()!!.trip.startEngineHours!!, 0.0)
        assertEquals(originals, storedAttempts().filter { it.trip.id != separateId })
        assertEquals(3, creates); assertFalse(vm.ui.value.isTracking)
    }

    @Test fun olderAcceptedUsesParentIdentityAndVineyardDayWithoutRewritingHistory() {
        setup()
        saveCalculator(calculatorInput("2026-10-16T12:59:55Z"))
        val original = storedAttempts().single()
        val store = LegacySpraySaveStore(app)
        val sameLocalDay = calculatorInput("2026-10-16T12:59:59Z")
        assertEquals(listOf(original), store.olderAcceptedMatch(vineyard, sameLocalDay, listOf(blockId), "freeDrive", "Australia/Sydney"))
        val nextLocalDay = calculatorInput("2026-10-16T13:00:05Z")
        assertTrue(store.olderAcceptedMatch(vineyard, nextLocalDay, listOf(blockId), "freeDrive", "Australia/Sydney").isEmpty())
        // Explicit original parent is held for inspection even on another day and with edited equipment.
        assertEquals(listOf(original), store.olderAcceptedMatch(vineyard,
            nextLocalDay.copy(tripId = original.trip.id, sprayEquipmentId = UUID.randomUUID().toString()),
            listOf(blockId), "freeDrive", "Australia/Sydney"))
        assertTrue(store.olderAcceptedMatch(vineyard, sameLocalDay.copy(tripId = UUID.randomUUID().toString()),
            emptyList(), "freeDrive", "Australia/Sydney").isEmpty())
        // Unknown timezone is conservatively ambiguous, never device-zone identity or automatic adoption.
        assertEquals(listOf(original), store.olderAcceptedMatch(vineyard, nextLocalDay, listOf(blockId), "freeDrive"))
        assertEquals(listOf(original), storedAttempts())
    }

    @Test fun olderAcceptedGenuineRecipeChangesAreNotMisidentifiedAsOriginal() {
        setup(); saveCalculator(calculatorInput(firstClock))
        val original = storedAttempts().single(); val draft = calculatorInput(retryClock)
        val tank = draft.tanks.single(); val chemical = tank.chemicals.single()
        val store = LegacySpraySaveStore(app)
        val changes = listOf(
            draft.copy(sprayEquipmentId = UUID.randomUUID().toString()),
            draft.copy(tanks = listOf(tank.copy(waterVolume = tank.waterVolume + 1))),
            draft.copy(tanks = listOf(tank.copy(chemicals = listOf(chemical.copy(ratePerHa = 751.0))))),
            draft.copy(tanks = listOf(tank.copy(chemicals = listOf(chemical.copy(volumePerTank = chemical.volumePerTank + 1))))),
            draft.copy(tanks = listOf(tank.copy(chemicals = listOf(chemical.copy(savedChemicalId = UUID.randomUUID().toString()))))),
        )
        changes.forEach { assertTrue(store.olderAcceptedMatch(vineyard, it, listOf(blockId), "freeDrive", "Australia/Sydney").isEmpty()) }
        assertTrue(store.olderAcceptedMatch(vineyard, draft, listOf(UUID.randomUUID().toString()), "freeDrive", "Australia/Sydney").isEmpty())
        assertEquals(listOf(original), storedAttempts()); assertEquals(1, creates)
    }

    @Test fun rejectedReceiptDoesNotActivateOrDiscardOriginal() {
        mode = "rejected"; setup()
        val outcome = start()
        assertFalse(outcome.isStarted); assertTrue(outcome.message!!.contains("validation_or_reference_conflict"))
        assertNull(ActiveTripStore(app).load())
        assertEquals(savedTrip!!.getValue("id").jsonPrimitive.content, LegacySpraySaveStore(app).retainedStart(vineyard)?.trip?.id)
        assertFalse(start().isStarted); assertEquals(1, creates)
    }
    @Test fun acceptedButReloadFailedStartsVerifiedOriginalWithoutAnotherCreate() {
        failReload = true; setup()
        val first = start(123.5)
        // Accepted contract: metadata hydration is not a prerequisite after exact
        // immutable receipt verification. Recover only this frozen Start, not history.
        assertTrue(first.message, first.isStarted)
        assertFalse("The injected post-acceptance reload failure was not exercised", failReload)
        val original = storedAttempts().single()
        assertTrue(original.startRequested); assertTrue(original.startCompleted)
        assertEquals("accepted", original.verified?.status)
        requireNotNull(original.verified).validate(original)
        assertEquals(original.candidate, original.verified)
        assertEquals(original.trip.id, first.tripId)
        assertEquals(original.rpc?.operation, first.operationId)
        assertEquals(actor, original.actorId); assertEquals(vineyard, original.trip.vineyardId)
        val active = requireNotNull(ActiveTripStore(app).load())
        assertEquals(original.trip.id, active.trip.id); assertEquals(actor, active.ownerUserId)
        assertEquals(123.5, active.trip.startEngineHours!!, 0.0)
        assertTrue(vm.requiresFirstTankReview(active.trip))
        assertFalse("Receipt fallback must not bypass Tank 1 GPS safety", vm.ui.value.isTracking)
        val pending = AppViewModel::class.java.getDeclaredField("pendingWrites").let {
            it.isAccessible = true; it.get(vm) as PendingWriteRepository
        }
        val activation = pending.list().filter { it.entityType == PendingEntityType.TRIP_START && it.clientId == original.trip.id }
        assertEquals("Local-first activation must retain exactly one original marker", 1, activation.size)
        val payload = SupabaseClient.json.decodeFromString(TripStartSync.Payload.serializer(), activation.single().payloadJson)
        assertTrue(payload.activateExisting); assertEquals(original.trip.id, payload.tripId)
        assertEquals(vineyard, payload.vineyardId); assertEquals(123.5, payload.startEngineHours!!, 0.0)
        val sentActivations = activationRequests
        // A completed Start returns through the existing saved-Trip entry, not a new
        // calculator creation (which correctly refuses while a recording is owned).
        var callbacks = 0
        instrumentation.runOnMainSync {
            vm.startSprayJob(original.trip.id, 999.0) { ok ->
                assertTrue("Return to verified original failed: ${vm.ui.value.sprayError}", ok)
                callbacks++
            }
        }
        assertEquals(1, callbacks)
        assertEquals(active, ActiveTripStore(app).load())
        assertEquals(listOf(original), storedAttempts())
        assertEquals(1, creates); assertEquals(1, recoveries)
        assertEquals(sentActivations, activationRequests)
        assertEquals(activation, pending.list().filter { it.entityType == PendingEntityType.TRIP_START && it.clientId == original.trip.id })
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
