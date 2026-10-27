package com.rork.vinetrack.data

import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import com.rork.vinetrack.ui.screens.LocalYieldMapPreview
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.auth.SessionPhase
import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.screens.YieldEstimationScreen
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.Json
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.util.UUID

/** Production Compose flow + actual view-model durable save, isolated files/preferences and intercepted-only HTTP. */
class YieldTripNavigationAndroidTest {
    @get:Rule val compose = createComposeRule()
    private val base = InstrumentationRegistry.getInstrumentation().targetContext
    private val prefix = "yield_navigation_${UUID.randomUUID()}_"
    private val names = java.util.Collections.synchronizedSet(linkedSetOf<String>())
    private val root = File(base.cacheDir, prefix)
    private val models = ViewModelStore()
    private var client: HttpClient? = null
    private lateinit var app: Application
    private lateinit var vm: AppViewModel
    private val vineyard = "11111111-1111-4111-8111-111111111111"
    private val block = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val trip = "99999999-9999-4999-8999-999999999999"
    @After fun cleanup() {
        compose.runOnUiThread { models.clear() }
        SupabaseClient.installInstrumentationTransport(null); client?.close()
        names.forEach { base.deleteSharedPreferences(prefix + it) }; root.deleteRecursively()
    }
    @Suppress("UNCHECKED_CAST")
    private fun state() = AppViewModel::class.java.getDeclaredField("_ui").let { it.isAccessible = true; it.get(vm) as MutableStateFlow<AppUiState> }
    private fun open() {
        val wrapped = object : ContextWrapper(base) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences { names.add(name); return base.getSharedPreferences(prefix + name, mode) }
            override fun getFilesDir(): File = File(root, "files").apply { mkdirs() }
            override fun getCacheDir(): File = File(root, "cache").apply { mkdirs() }
        }
        app = object : Application() { init { attachBaseContext(wrapped) }; override fun getApplicationContext(): Context = this }
        client = HttpClient(MockEngine { respond("Synthetic: no live transport", HttpStatusCode.ServiceUnavailable) })
        SupabaseClient.installInstrumentationTransport(client)
        compose.runOnUiThread { vm = AppViewModel(app); models.put("yield", vm) }
        compose.waitUntil(5_000) { vm.ui.value.sessionPhase == SessionPhase.SignedOut }
        compose.runOnUiThread {
            val session = AppViewModel::class.java.getDeclaredField("session").let { it.isAccessible = true; it.get(vm) as SessionStore }
            session.save("synthetic-access", "synthetic-refresh", "22222222-2222-4222-8222-222222222222", null)
            session.selectedVineyardId = vineyard
            val d = 100.0 / 111320
            val p = Paddock(block, vineyard, "Synthetic Yield Block", vineCountOverride = 1000,
                polygonPoints = listOf(CoordinatePoint(0.0, 0.0), CoordinatePoint(d, 0.0), CoordinatePoint(d, d), CoordinatePoint(0.0, d)),
                varietyAllocations = listOf(PaddockVarietyAllocation(varietyKey = "shiraz", name = "Shiraz", percent = 100.0)))
            val draft = YieldEstimationSession(trip, vineyard, "2026-10-27T00:00:00Z", selectedPaddockIds = listOf(block),
                sampleSites = listOf(SampleSite("site", block, rowNumber = 1, latitude = d / 2, longitude = d / 2, siteIndex = 1,
                    bunchCountEntry = BunchCountEntry(20.0, "2026-10-27T00:01:00Z"))), blockBunchWeightsKg = mapOf(block to 0.15))
            state().value = AppUiState(selectedVineyardId = vineyard, currentUserId = session.userId, paddocks = listOf(p), yieldSessions = listOf(draft), isOnline = false)
        }
        compose.setContent {
            val ui by vm.ui.collectAsState()
            CompositionLocalProvider(LocalContext provides app, LocalYieldMapPreview provides { Text("Map renderer excluded from navigation test") }) { MaterialTheme { YieldEstimationScreen(vm, ui, onBack = { fail("Yield workflow escaped trips list") }) } }
        }
    }
    @Test fun resumeAndBackReturnsToTripsNotYieldRoot() {
        open(); compose.onNodeWithTag("yield.resume").performScrollTo().performClick()
        compose.onNodeWithText("Bunch Count Trip").assertExists()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("Bunch Count Trips").assertExists()
        compose.onNodeWithTag("yield.resume").assertExists()
    }
    @Test fun completionRefreshesListAndReopensCompletedFromDurableIntent() {
        open(); compose.onNodeWithTag("yield.resume").performScrollTo().performClick()
        compose.onNodeWithText("Complete Estimation").performClick()
        compose.onNodeWithText("Save Bunch Count Trip").performScrollTo().performClick()
        compose.onNodeWithText("Save Trip", substring = false).performClick()
        compose.onNodeWithText("Bunch Count Trips").assertExists(); compose.onNodeWithTag("yield.resume").assertDoesNotExist()
        val pending = PendingWriteRepository(app).list().single { it.entityType == PendingEntityType.YIELD_SESSION }
        val saved = Json { ignoreUnknownKeys = true }.decodeFromString(YieldSessionSaveSync.Payload.serializer(), pending.payloadJson).session
        assertEquals(trip, saved.id); assertTrue(saved.isCompleted); assertNotNull(saved.completedAt)
        assertEquals(20.0, saved.sampleSites.single().bunchCountEntry!!.bunchesPerVine, 0.0)
        // Re-created repository above proves on-disk completion, then a normal list tap proves rendered read-only reopen.
        compose.onNodeWithTag("yield.completed.$trip").performScrollTo().performClick()
        compose.onNodeWithText("Bunch Count Trip").assertExists()
        compose.onNodeWithText("Save Bunch Count Trip").assertDoesNotExist()
        compose.onNodeWithText("Historical trip weight", substring = true).assertExists()
        compose.onNodeWithContentDescription("Back").performClick(); compose.onNodeWithText("Bunch Count Trips").assertExists()
    }
}
