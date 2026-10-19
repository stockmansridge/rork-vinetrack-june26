package com.rork.vinetrack.data

import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.os.Bundle
import android.util.Base64
import java.io.ByteArrayOutputStream
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.material3.Button
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.auth.SessionPhase
import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.LocalRegionFormatter
import com.rork.vinetrack.ui.screens.ActiveTripHud
import com.rork.vinetrack.ui.theme.AppTheme
import io.ktor.client.HttpClient
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.serialization.kotlinx.json.json
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.UUID

/** Production HUD and actions, isolated native storage, intercepted-only HTTP.
 * Map renderer excluded explicitly; these captures cannot prove satellite/GPS/backend correctness.
 */
class LiveTripLayoutAndroidTest {
    @get:Rule val compose = createComposeRule()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val base = instrumentation.targetContext
    private val prefix = "live_ui_${UUID.randomUUID()}_"
    private val names = mutableSetOf<String>()
    private val models = ViewModelStore()
    private val root = File(base.cacheDir, prefix)
    private val vineyard = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val actor = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private val id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private lateinit var vm: AppViewModel
    private var client: HttpClient? = null
    private lateinit var fixtureApplication: Application
    private val showingHud = mutableStateOf(true)
    private val mappedRowFixture = mutableStateOf(false)
    private val streamRowFixture = mutableStateOf(false)
    private var details = 0
    private var ends = 0
    private var route = 0
    private var launches = mutableListOf<String?>()

    @After fun cleanup() {
        instrumentation.runOnMainSync { models.clear() }
        SupabaseClient.installInstrumentationTransport(null)
        client?.close()
        names.forEach { base.deleteSharedPreferences(prefix + it) }
        root.deleteRecursively()
    }
    @Suppress("UNCHECKED_CAST")
    private fun state(): MutableStateFlow<AppUiState> = AppViewModel::class.java.getDeclaredField("_ui").let { it.isAccessible = true; it.get(vm) as MutableStateFlow<AppUiState> }
    private fun fixture(planned: Boolean = true, tanks: Int = 2) = Trip(id, vineyard, paddockName = "Sauv Blanc", isActive = true,
        tripFunction = "spraying", tripTitle = "Spray Record", startTime = "2026-10-17T08:00:00Z", totalDistance = 123.0,
        trackingPattern = if (planned) TrackingPattern.EVERY_SECOND_ROW.rawValue else "freeDrive", rowSequence = if (planned) listOf(0.5, 2.5, 4.5) else emptyList(),
        pathPoints = listOf(CoordinatePoint(-33.28, 149.02), CoordinatePoint(-33.2801, 149.0201)),
        activeTankNumber = 1, totalTanks = tanks, tankSessions = listOf(TankSession("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", 1, "2026-10-17T08:00:00Z")))

    private fun open(trip: Trip = fixture(), width: Int = 360, scale: Float = 1f, imperial: Boolean = false, freshGps: Boolean = true, lifecycleOwner: androidx.lifecycle.LifecycleOwner? = null) {
        val wrapped = object : ContextWrapper(base) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
                names.add(name); return base.getSharedPreferences(prefix + name, mode)
            }
            override fun getFilesDir(): File = File(root, "files").apply { mkdirs() }
            override fun getCacheDir(): File = File(root, "cache").apply { mkdirs() }
        }
        val app = object : Application() { init { attachBaseContext(wrapped) }; override fun getApplicationContext(): Context = this }
        fixtureApplication = app
        client = HttpClient(MockEngine { respond("[]", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json")) }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
        SupabaseClient.installInstrumentationTransport(client)
        instrumentation.runOnMainSync {
            vm = AppViewModel(app); models.put("hud", vm)
        }
        // Complete the empty installation's startup before admitting the isolated synthetic account.
        // Otherwise its delayed restore can legitimately displace this injected presentation fixture.
        compose.waitUntil(5_000) { vm.ui.value.sessionPhase == SessionPhase.SignedOut }
        instrumentation.runOnMainSync {
            val session = AppViewModel::class.java.getDeclaredField("session").let { it.isAccessible = true; it.get(vm) as SessionStore }
            session.apply { save("synthetic-access", "synthetic-refresh", actor, null); selectedVineyardId = vineyard }
            val tanks = (1..(trip.totalTanks ?: 1)).map { SprayTank(UUID.nameUUIDFromBytes("fixture-tank-$it".toByteArray()).toString(), tankNumber = it, waterVolume = 600.0) }
            val spray = SprayRecord("ffffffff-ffff-4fff-8fff-ffffffffffff", vineyard, tripId = id, sprayReference = "Spray Record", tanks = tanks)
            val rendered = trip.occurrenceDocument?.let { document ->
                val journal = TripOccurrenceNativeStore(app).journal(TripOccurrenceJournal.Scope(actor, vineyard, id))
                journal.prepareCreation(buildJsonObject { put("id", id); put("vineyard_id", vineyard); put("is_active", false) }, document.raw)
                journal.activate(buildJsonObject { put("startTime", trip.startTime) })
                trip.withOccurrenceProjection(journal.projected(journal.load()!!))
            } ?: trip
            val actual = SprayTankActual("11111111-1111-4111-8111-111111111111", vineyard, spray.id, id, "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", 1, 581.7,
                emptyList(), "2026-10-17T08:00:00Z", actor)
            val actualStore = AppViewModel::class.java.getDeclaredField("sprayTankActualStore").let { it.isAccessible = true; it.get(vm) as SprayTankActualStore }
            assertTrue(actualStore.save(actual))
            assertTrue(ActiveTripStore(app).saveDurably(actor, vineyard, rendered))
            state().value = AppUiState(selectedVineyardId = vineyard, currentUserId = actor, isOnline = false,
                sessionPhase = SessionPhase.AuthenticatedOffline,
                members = listOf(VineyardMember(vineyardId = vineyard, userId = actor, role = "manager")),
                trips = listOf(rendered), deviceActiveTripId = id, isTracking = true, sprayRecords = listOf(spray),
                sprayTankActuals = listOf(actual),
                latestSpeedMetresPerSecond = 1.3, latestAccuracyMetres = 2.0,
                latestMovementObservedAtMs = if (freshGps) System.currentTimeMillis() else 0L)
        }
        compose.setContent {
            LaunchedEffect(streamRowFixture.value) {
                if (streamRowFixture.value) while (true) {
                    kotlinx.coroutines.delay(1_000)
                    val sample = state().value.rowSideMovementSample
                    if (sample != null) state().value = state().value.copy(rowSideMovementSample = sample.copy(timestampMs = System.currentTimeMillis()))
                }
            }
            val current by vm.ui.collectAsState()
            val density = LocalDensity.current
            var launcher by remember { mutableStateOf<String?>(null) }
            val formatter = RegionFormatter((if (imperial) RegionCountry.UnitedStates else RegionCountry.Australia).recommendedPreset)
            CompositionLocalProvider(androidx.lifecycle.compose.LocalLifecycleOwner provides (lifecycleOwner ?: androidx.lifecycle.compose.LocalLifecycleOwner.current), androidx.compose.ui.platform.LocalContext provides app, LocalDensity provides Density(density.density, scale), LocalRegionFormatter provides formatter) {
                AppTheme(darkTheme = false) {
                    Box(Modifier.width(width.dp).fillMaxHeight()) {
                        if (!showingHud.value) Button(onClick = { showingHud.value = true }) { Text("Return to same Live Trip") }
                        else ActiveTripHud(vm, current, current.trips.first(), 109, { showingHud.value = false }, { details++; showingHud.value = false }, { ends++ }, { route++ }, {},
                            launcher, { launches.add(it); launcher = it }, {}, mapPreview = {
                                Box(Modifier.fillMaxSize().background(Color(0xFF26372D)), contentAlignment = Alignment.Center) {
                                    if (mappedRowFixture.value) {
                                        androidx.compose.foundation.Canvas(Modifier.fillMaxSize()) {
                                            for (fraction in listOf(0.38f, 0.62f)) drawLine(Color(0xFF7FBC86),
                                                androidx.compose.ui.geometry.Offset(size.width * fraction, size.height * 0.18f),
                                                androidx.compose.ui.geometry.Offset(size.width * fraction, size.height * 0.82f), strokeWidth = 5f)
                                            drawCircle(Color(0xFF3898FA), radius = 7.dp.toPx(), center = center)
                                        }
                                        Text("Controlled mapped-row fixture\nSatellite renderer excluded", color = Color.White,
                                            modifier = Modifier.align(Alignment.BottomStart).padding(8.dp), fontSize = androidx.compose.ui.unit.TextUnit.Unspecified)
                                    } else Text("Map renderer excluded\nSynthetic layout fixture", color = Color.White)
                                }
                            })
                    }
                }
            }
        }
        compose.waitForIdle()
        compose.runOnIdle { state().value = state().value.copy(isOnline = false) }
        compose.waitForIdle()
    }
    private fun click(description: String) {
        compose.onNodeWithContentDescription(description).performSemanticsAction(SemanticsActions.OnClick) { it() }
    }
    private fun press(text: String) {
        compose.onNode(hasText(text) and hasClickAction()).performSemanticsAction(SemanticsActions.OnClick) { it() }
    }
    private fun capture(name: String, transportProbe: Boolean = false) {
        val directory = File(base.getExternalFilesDir(null), "live-trip-ui-evidence").apply { mkdirs() }
        val file = File(directory, "$name.png")
        compose.onRoot().captureToImage().asAndroidBitmap().let { bitmap ->
            file.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        }
        val bitmap = android.graphics.BitmapFactory.decodeFile(file.absolutePath)
        val scaled = Bitmap.createScaledBitmap(bitmap, 360, (bitmap.height * 360f / bitmap.width).toInt(), true)
        val transportOnly = transportProbe || InstrumentationRegistry.getArguments().getString("captureLiveTripEvidence") == "true"
        if (transportOnly) {
            var quality = 80
            var bytes: ByteArray
            do {
                bytes = ByteArrayOutputStream().also { scaled.compress(Bitmap.CompressFormat.WEBP_LOSSY, quality, it) }.toByteArray()
                quality -= 10
            } while (bytes.size > 17000 && quality >= 0)
            check(bytes.size <= 17000) { "Evidence packet exceeds retained log limit" }
            Base64.encodeToString(bytes, Base64.NO_WRAP).chunked(1500).forEachIndexed { index, chunk ->
                instrumentation.sendStatus(2, Bundle().apply { putString("stream", "\nLIVE_TRIP_WEBP_CHUNK_${name}_${index}=$chunk\n") })
            }
        }
        if (scaled !== bitmap) scaled.recycle()
        bitmap.recycle()
        if (transportOnly) throw AssertionError("Evidence transport probe only: capture $name is in the retained runner stream. Not a functional test result.")
    }
    private fun visibleActions() {
        compose.onNodeWithContentDescription("Pause").assertIsDisplayed().assertHeightIsAtLeast(48.dp)
        compose.onNodeWithContentDescription("End Trip").assertIsDisplayed().assertHeightIsAtLeast(48.dp)
        val map = compose.onNodeWithTag("live-trip-map").fetchSemanticsNode().boundsInRoot
        val dock = compose.onNodeWithTag("live-trip-dock").fetchSemanticsNode().boundsInRoot
        assertTrue("Map must have useful flexible height: $map", map.height >= 100f)
        assertTrue("Dock must follow, not cover, the map", dock.top >= map.bottom - 1)
        for (description in listOf("Recenter", "Switch to heading-up", "Toggle row labels", "Map type")) {
            compose.onNodeWithContentDescription(description).assertIsDisplayed().assertHeightIsAtLeast(48.dp)
        }
    }
    private fun noClippedText() {
        compose.onAllNodes(hasText("", substring = true), useUnmergedTree = true).fetchSemanticsNodes().forEach { node ->
            val layouts = mutableListOf<TextLayoutResult>()
            node.config.getOrNull(SemanticsActions.GetTextLayoutResult)?.action?.invoke(layouts)
            assertTrue("Clipped production text: ${layouts.map { "${it.layoutInput.text} size=${it.size} width=${it.didOverflowWidth} height=${it.didOverflowHeight} line=${it.layoutInput.style.lineHeight}" }}", layouts.all { layout ->
                !layout.multiParagraph.didExceedMaxLines && (0 until layout.lineCount).all { line ->
                    layout.getLineRight(line) <= layout.size.width + 1f && layout.getLineBottom(line) <= layout.size.height + 1f
                }
            })
        }
    }

    @Test fun plannedRowActiveTankCompactAndActualWater() {
        open(); capture("planned-active-tank")
        visibleActions()
        compose.onNodeWithText("Path 0.5").assertIsDisplayed()
        compose.onNodeWithText("Tank 1 of 2", substring = true).assertIsDisplayed()
        compose.onNodeWithText("Actual 581.7\u00a0L", substring = true).assertIsDisplayed()
        compose.onNodeWithText("Done 0.5").assertIsDisplayed()
        noClippedText()
        compose.onNodeWithContentDescription("Route details").performClick()
        compose.runOnIdle { assertEquals(1, route); assertEquals(0, ends) }
        compose.onNodeWithContentDescription("End Trip").performClick()
        compose.runOnIdle { assertEquals(1, ends); assertEquals(1, state().value.trips.size); assertEquals(1, state().value.trips.single().tankSessions.size) }
    }
    @Test fun freeDriveHasRecordingNotMeaninglessPathButtons() {
        open(fixture(planned = false, tanks = 1)); visibleActions()
        compose.onAllNodesWithText("Free Drive").assertCountEquals(2)
        compose.onNodeWithText("Done", substring = true).assertDoesNotExist()
        compose.onNodeWithText("Position", substring = true).assertDoesNotExist()
        compose.onAllNodesWithText("Not planned").assertCountEquals(2)
        capture("free-drive"); noClippedText()
    }
    @Test fun narrowLargeFontImperialAndStaleGps() {
        open(width = 320, scale = 1.5f, imperial = true, freshGps = false); capture("narrow-large-font-imperial"); visibleActions()
        compose.onNodeWithText("Searching / stale").assertIsDisplayed()
        compose.onNodeWithText("gal", substring = true).assertIsDisplayed()
        capture("narrow-large-font-imperial"); noClippedText()
    }
    @Test fun pauseResumePreservesTripTankAndEvidence() {
        open(); val before = vm.ui.value.trips.single()
        click("Pause")
        compose.onNodeWithContentDescription("Resume").assertIsDisplayed()
        compose.onNodeWithText("Trip paused").assertIsDisplayed()
        compose.onNodeWithText("End tank", substring = true).assertIsNotEnabled()
        capture("paused-trip"); noClippedText()
        click("Resume")
        compose.onNodeWithContentDescription("Pause").assertIsDisplayed()
        compose.runOnIdle {
            val after = vm.ui.value.trips.single()
            assertEquals(before.id, after.id); assertEquals(before.tankSessions, after.tankSessions)
            assertEquals(before.rowSequence, after.rowSequence); assertEquals(before.pathPoints, after.pathPoints)
            assertEquals(1, after.pauseTimestamps.orEmpty().size); assertEquals(1, after.resumeTimestamps.orEmpty().size)
        }
    }
    @Test fun doneSkipUndoRemainAccessibleAndUseProductionLegacyActions() {
        open()
        press("Done 0.5")
        compose.onNodeWithText("Done 2.5").assertIsDisplayed()
        press("Undo")
        compose.onNodeWithText("Done 0.5").assertIsDisplayed()
        compose.onNodeWithContentDescription("Path actions · Skip or select").performClick()
        compose.onNodeWithText("Pause").assertIsDisplayed().assertHeightIsAtLeast(48.dp)
        compose.onNodeWithText("End Trip").assertIsDisplayed().assertHeightIsAtLeast(48.dp)
        compose.onNodeWithText("Skip", substring = true).performClick()
        compose.onNodeWithText("Back to Live Trip").performClick()
        compose.onNodeWithText("Done 2.5").assertIsDisplayed()
        compose.runOnIdle { assertEquals(listOf(0.5), vm.ui.value.trips.single().skippedPaths); assertTrue(vm.ui.value.trips.single().completedPaths.orEmpty().isEmpty()) }
    }
    @Test fun endTankRequiresExistingConfirmationAndCancellationKeepsSession() {
        open()
        compose.onNodeWithText("End tank", substring = true).performClick()
        compose.onNodeWithText("End tank 1?").assertExists()
        compose.onNodeWithText("Cancel").performClick()
        compose.runOnIdle { assertEquals(1, vm.ui.value.trips.single().activeTankNumber); assertNull(vm.ui.value.trips.single().tankSessions.single().endTime) }
        compose.onNodeWithText("End tank", substring = true).performClick()
        press("End tank")
        compose.runOnIdle {
            val trip = vm.ui.value.trips.single()
            assertNull("End tank: ${vm.ui.value.tripError}", trip.activeTankNumber); assertNotNull(trip.tankSessions.single().endTime)
            assertEquals(1, vm.ui.value.sprayTankActuals.size)
        }
    }
    @Test fun occurrencePassSelectionIsGuidanceOnlyThenDoneTargetsOnePass() {
        val candidate = TripOccurrencePlanner.Candidate(vineyard, "dddddddd-dddd-4ddd-8ddd-dddddddddddd", "Sauv Blanc", 38.5, emptyList())
        val coverage = TripOccurrencePlanner.commit(listOf(candidate, candidate), vineyard)
        open(fixture().copy(occurrenceCoverage = coverage, trackingPattern = "upAndBack", rowSequence = listOf(38.5, 38.5)))
        compose.onNodeWithContentDescription("Path actions · Skip or select").performClick()
        compose.onNodeWithText("I'm on this path").performClick()
        compose.onNodeWithText("Sauv Blanc · 38.5 · Pass 2 — incomplete").performClick()
        compose.onNodeWithText("Back to Live Trip").performClick()
        compose.runOnIdle {
            val d = vm.ui.value.trips.single().occurrenceDocument!!
            assertEquals(2, d.items.single { it.id == d.targetId }.pass)
            assertEquals(0, d.count("done"))
        }
        capture("occurrence-selected-pass")
        press("Done 38.5")
        compose.onNodeWithText("Done 38.5?").assertExists()
        press("Confirm")
        compose.runOnIdle {
            val d = vm.ui.value.trips.single().occurrenceDocument!!
            assertEquals("Occurrence action: ${vm.ui.value.tripError}", "incomplete", d.status(d.order[0])); assertEquals("Occurrence action: ${vm.ui.value.tripError}", "done", d.status(d.order[1]))
        }
    }
    @Test fun repairsGrowthReturnDoesNotChangeTripOrTank() {
        open(); val before = vm.ui.value.trips.single()
        for (mode in listOf("Repairs", "Growth")) {
            compose.onNodeWithText(mode).performClick()
            compose.onAllNodesWithContentDescription("Back").onLast().performClick()
            compose.onNodeWithContentDescription("Pause").assertIsDisplayed()
        }
        compose.runOnIdle { assertEquals(before, vm.ui.value.trips.single()); assertEquals(listOf("Repairs", null, "Growth", null), launches) }
    }
    @Test fun disposedHudReturnsToSameOfflineTripWithoutTouchingQueuedWork() {
        open()
        click("Pause")
        val before = vm.ui.value.trips.single()
        val pending = AppViewModel::class.java.getDeclaredField("pendingWrites").let { it.isAccessible = true; it.get(vm) as PendingWriteRepository }
        val queued = pending.writes.value
        assertTrue("Pause must have a real pending offline operation", queued.isNotEmpty())
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("Return to same Live Trip").performClick()
        compose.onNodeWithContentDescription("Resume").assertIsDisplayed()
        compose.runOnIdle {
            assertEquals(before, vm.ui.value.trips.single())
            assertEquals(queued, pending.writes.value)
            assertEquals(id, vm.ui.value.deviceActiveTripId)
            assertEquals(2, vm.ui.value.trips.single().pathPoints.orEmpty().size)
        }
    }
    @Test fun unavailableAndWeakGpsNeverEraseSavedPlannedGuidance() {
        open(freshGps = false)
        compose.onNodeWithText("Searching / stale").assertIsDisplayed()
        compose.onNodeWithText("Path 0.5").assertIsDisplayed()
        compose.runOnIdle { state().value = state().value.copy(latestAccuracyMetres = 35.0, latestMovementObservedAtMs = System.currentTimeMillis()) }
        compose.onNodeWithText("Weak").assertIsDisplayed()
        compose.onNodeWithText("Path 0.5").assertIsDisplayed()
        compose.runOnIdle { assertEquals(0, vm.ui.value.trips.single().sequenceIndex); assertTrue(vm.ui.value.trips.single().completedPaths.orEmpty().isEmpty()) }
    }
    private fun installRowFixture(bearing: Double = 0.0, spacing: Double = 4.0, accuracy: Double = 1.0) {
        fun point(x: Double, y: Double) = CoordinatePoint(y / 111_320.0, x / 111_320.0)
        val block = Paddock("dddddddd-dddd-4ddd-8ddd-dddddddddddd", vineyard, "Mapped Slashing Block", rowWidth = spacing,
            polygonPoints = listOf(point(-2.0, -10.0), point(6.0, -10.0), point(6.0, 110.0), point(-2.0, 110.0)),
            rows = listOf(PaddockRow(number = 12, startPoint = point(0.0, 0.0), endPoint = point(0.0, 100.0)),
                PaddockRow(number = 13, startPoint = point(spacing, 100.0), endPoint = point(spacing, 0.0))))
        compose.runOnIdle {
            mappedRowFixture.value = true
            state().value = state().value.copy(paddocks = listOf(block), rowSideMovementSample = LocationTracker.MovementSample(
                50.0 / 111_320.0, (spacing / 2.0) / 111_320.0, bearing, 1.5, accuracy, System.currentTimeMillis()),
                latestAccuracyMetres = accuracy, latestMovementObservedAtMs = System.currentTimeMillis())
        }
    }
    @Test fun freeDrivePhysicalRowsToggleDirectionPreferenceAndReturnPreserveEvidence() {
        open(fixture(planned = false).copy(tripFunction = "slashing", tripTitle = "Slashing"))
        compose.runOnIdle { streamRowFixture.value = true }
        installRowFixture()
        compose.onNodeWithContentDescription("Travel left: Row 12").assertIsDisplayed()
        compose.onNodeWithContentDescription("Travel right: Row 13").assertIsDisplayed()
        val before = vm.ui.value.trips.single()
        capture("free-drive-physical-row-sides")
        click("Switch to heading-up")
        compose.onNodeWithContentDescription("Travel left: Row 12").assertIsDisplayed()
        click("Toggle row labels")
        compose.onNodeWithContentDescription("Travel left: Row 12").assertDoesNotExist()
        click("Toggle row labels")
        compose.onNodeWithContentDescription("Travel left: Row 12").assertIsDisplayed()
        compose.runOnIdle { AppPreferencesStore(fixtureApplication).save(AppPreferences(rowTrackingEnabled = false)) }
        compose.onNodeWithText("Row labels disabled in Preferences · Row Tracking").assertIsDisplayed()
        compose.onNodeWithContentDescription("Travel left: Row 12").assertDoesNotExist()
        compose.runOnIdle { AppPreferencesStore(fixtureApplication).save(AppPreferences(rowTrackingEnabled = true)) }
        installRowFixture(180.0)
        compose.onNodeWithContentDescription("Travel left: Row 13").assertIsDisplayed()
        compose.onNodeWithContentDescription("Travel right: Row 12").assertIsDisplayed()
        click("Back")
        compose.onNodeWithText("Return to same Live Trip").performClick()
        installRowFixture(180.0)
        compose.onNodeWithContentDescription("Travel right: Row 12").assertIsDisplayed()
        compose.runOnIdle { assertEquals(before, vm.ui.value.trips.single()); assertEquals(id, vm.ui.value.deviceActiveTripId) }
        noClippedText()
    }
    @Test fun narrowRowsGpsGoodStillWaitsAndRecoversWithoutChangingEvidence() {
        open(fixture(planned = false))
        compose.runOnIdle { streamRowFixture.value = true }
        val before = vm.ui.value.trips.single()
        val pending = AppViewModel::class.java.getDeclaredField("pendingWrites").let { it.isAccessible = true; it.get(vm) as PendingWriteRepository }
        val syncBefore = pending.writes.value
        listOf(2.8, 3.0).forEach { spacing ->
            listOf(1.0, 3.0, 5.0, 8.0, 1.0).forEach { accuracy ->
                installRowFixture(spacing = spacing, accuracy = accuracy)
                compose.onNodeWithText("Good").assertIsDisplayed()
                if (accuracy == 1.0) {
                    compose.onNodeWithContentDescription("Travel left: Row 12").assertIsDisplayed()
                    compose.onNodeWithText("Sides follow travel direction, not vehicle facing").assertIsDisplayed()
                } else {
                    compose.onNodeWithContentDescription("Travel left: Row 12").assertDoesNotExist()
                    compose.onNodeWithContentDescription("Travel right: Row 13").assertDoesNotExist()
                    compose.onNodeWithText("Row guidance waiting · GPS cannot distinguish adjacent rows").assertIsDisplayed()
                }
            }
        }
        compose.runOnIdle {
            assertEquals(before, vm.ui.value.trips.single())
            assertEquals(syncBefore, pending.writes.value)
            assertEquals(id, vm.ui.value.deviceActiveTripId)
        }
        noClippedText()
    }
    @Test fun rowSidesStaleLowSpeedAndFreshReturnLeaveSavedActionUntouched() {
        val owner = object : androidx.lifecycle.LifecycleOwner {
            val registry = androidx.lifecycle.LifecycleRegistry(this)
            override val lifecycle: androidx.lifecycle.Lifecycle get() = registry
        }
        instrumentation.runOnMainSync { owner.registry.currentState = androidx.lifecycle.Lifecycle.State.RESUMED }
        open(lifecycleOwner = owner); installRowFixture()
        val before = vm.ui.value.trips.single()
        compose.onNodeWithContentDescription("Travel left: Row 12").assertIsDisplayed()
        compose.runOnIdle { state().value = state().value.copy(rowSideMovementSample = state().value.rowSideMovementSample!!.copy(speedMetresPerSecond = 0.0)) }
        compose.onNodeWithText("Row guidance · waiting for travel direction").assertIsDisplayed()
        compose.onNodeWithContentDescription("Travel left: Row 12").assertDoesNotExist()
        compose.runOnIdle { state().value = state().value.copy(rowSideMovementSample = state().value.rowSideMovementSample!!.copy(timestampMs = 0L)) }
        compose.onNodeWithText("Row guidance · waiting for a reliable fix").assertIsDisplayed()
        installRowFixture()
        compose.onNodeWithContentDescription("Travel right: Row 13").assertIsDisplayed()
        compose.onNodeWithText("Done 0.5").assertIsDisplayed()
        compose.runOnIdle { owner.registry.currentState = androidx.lifecycle.Lifecycle.State.CREATED }
        compose.onNodeWithContentDescription("Travel right: Row 13").assertDoesNotExist()
        compose.runOnIdle { owner.registry.currentState = androidx.lifecycle.Lifecycle.State.RESUMED }
        compose.onNodeWithText("Row guidance · waiting for a reliable fix").assertIsDisplayed()
        installRowFixture()
        compose.onNodeWithContentDescription("Travel left: Row 12").assertIsDisplayed()
        compose.runOnIdle { assertEquals(before, vm.ui.value.trips.single()); assertEquals(id, vm.ui.value.deviceActiveTripId) }
    }
    /** Explicit diagnostic export only; intentional failure is not a functional test result. */
    @Test fun exportPhysicalRowSideEvidenceOnly() {
        if (InstrumentationRegistry.getArguments().getString("class")?.endsWith("#exportPhysicalRowSideEvidenceOnly") != true) return
        open(fixture(planned = false).copy(tripFunction = "slashing", tripTitle = "Slashing"))
        compose.runOnIdle { streamRowFixture.value = true }
        installRowFixture()
        compose.onNodeWithContentDescription("Travel left: Row 12").assertIsDisplayed()
        compose.onNodeWithContentDescription("Travel right: Row 13").assertIsDisplayed()
        capture("free-drive-physical-row-sides", transportProbe = true)
    }
    @Test fun fillingAndSingleTankLargePhone() {
        open(fixture(tanks = 1).copy(activeTankNumber = null, isFillingTank = true, fillingTankNumber = 1,
            tankSessions = listOf(TankSession("22222222-2222-4222-8222-222222222222", 1, fillStartTime = "2026-10-17T08:00:00Z"))), width = 412)
        compose.onAllNodesWithText("Filling tank").onLast().assertIsDisplayed()
        compose.onNodeWithContentDescription("Pause").assertIsDisplayed()
        compose.onNodeWithText("Done 0.5").assertDoesNotExist()
        compose.onNodeWithText("Stop fill", substring = true).assertIsDisplayed()
        capture("filling-tank"); noClippedText()
    }
}
