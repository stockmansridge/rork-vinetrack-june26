package com.rork.vinetrack.data.auth

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.ui.AppRoute
import com.rork.vinetrack.ui.AppViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File

/** Disposable namespaced test Application only. Never a retained owner-install fixture. */
class RetainedStartupConstructionTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val app get() = instrumentation.targetContext.applicationContext as CleanExitFixtureApplication

    @Before fun prepareSyntheticFixture() { app.resetFixture() }

    private fun constructAndAwaitLogin(assertions: (AppViewModel) -> Unit = {}) {
        lateinit var vm: AppViewModel
        instrumentation.runOnMainSync { vm = AppViewModel(app) }
        try {
            runBlocking { withTimeout(15_000) { vm.ui.first { it.route == AppRoute.Login } } }
            assertions(vm)
        } finally { instrumentation.runOnMainSync { vm.viewModelScope.cancel() } }
    }

    @Test fun freshFixtureConstructsAndResolvesSignedOutToLogin() {
        constructAndAwaitLogin { vm ->
            assertEquals(SessionPhase.SignedOut, vm.ui.value.sessionPhase)
            assertNull(vm.pendingSyncReadIssue.value)
            assertNull(vm.pinEvidenceReadIssue.value)
        }
    }

    @Test fun immediateOnlineOnMainWithRetainedReplayScopeConstructsWithoutInitializingReplay() {
        app.immediateOnlineWithoutNetworkManager = true
        val session = SessionStore(app)
        session.accessToken = "synthetic-not-a-live-token"
        session.userId = "synthetic-owner"
        // No refresh token: restoration resolves locally, without a live auth request.
        lateinit var vm: AppViewModel
        instrumentation.runOnMainSync {
            assertFalse(Dispatchers.Main.immediate.isDispatchNeeded(kotlin.coroutines.EmptyCoroutineContext))
            vm = AppViewModel(app)
            val delegate = AppViewModel::class.java.getDeclaredField("replayRunner\$delegate").apply { isAccessible = true }
                .get(vm) as Lazy<*>
            assertFalse("online transport before admission must not even initialize replay", delegate.isInitialized())
            val admission = AppViewModel::class.java.getDeclaredMethod("automaticReplayIdentity").apply { isAccessible = true }
            assertNull(admission.invoke(vm))
        }
        try {
            runBlocking { withTimeout(15_000) { vm.ui.first { it.route == AppRoute.Login && it.isOnline } } }
            assertEquals(SessionPhase.SignedOut, vm.ui.value.sessionPhase)
            assertEquals("synthetic-owner", session.userId)
        } finally {
            instrumentation.runOnMainSync { vm.viewModelScope.cancel() }
            app.immediateOnlineWithoutNetworkManager = false
        }
    }

    @Test fun expiredTankPreviewAndCommandsKeepOriginalDiskDraftAndReconciliationMarker() {
        constructAndAwaitLogin { vm ->
            instrumentation.runOnMainSync {
                val session = AppViewModel::class.java.getDeclaredField("session").apply { isAccessible = true }.get(vm) as SessionStore
                session.accessToken = "synthetic-not-a-live-token"
                session.userId = "tank-fixture-owner"
                val owner = requireNotNull(session.userId)
                val vineyard = "tank-fixture-vineyard-a"
                val original = com.rork.vinetrack.data.model.Trip(
                    id = "tank-fixture-trip", vineyardId = vineyard, paddockName = "Fixture",
                    startTime = "2026-10-24T00:00:00Z", isActive = true, activeTankNumber = 1,
                    tankSessions = listOf(com.rork.vinetrack.data.model.TankSession(
                        "original-session", 1, "2026-10-24T00:01:00Z", endTime = "2026-10-24T00:02:00Z")),
                )
                val disk = com.rork.vinetrack.data.ActiveTripStore(app)
                assertTrue(disk.saveDurably(owner, vineyard, original))
                val frozen = disk.load()
                @Suppress("UNCHECKED_CAST")
                val state = AppViewModel::class.java.getDeclaredField("_ui").apply { isAccessible = true }
                    .get(vm) as kotlinx.coroutines.flow.MutableStateFlow<com.rork.vinetrack.ui.AppUiState>
                state.value = state.value.copy(selectedVineyardId = vineyard, currentUserId = owner,
                    deviceActiveTripId = original.id, trips = listOf(original), isOnline = false,
                    lastReconciledTankTripId = null)
                val previousAuthority = com.rork.vinetrack.data.OperationalWrites.authority
                var ledger = emptyMap<String, String>()
                val gate = com.rork.vinetrack.data.VineyardWriteAuthority({ session.userId }, { ledger }, { ledger = it })
                com.rork.vinetrack.data.OperationalWrites.authority = gate
                try {
                    assertTrue(vm.saveTankMixDraft(original.id, "original-tank", mapOf("water" to "420")))
                    val draftPrefs = app.getSharedPreferences("actual_tank_mix_drafts_v1", Context.MODE_PRIVATE)
                    val originalDraft = draftPrefs.all.toMap()
                    gate.handleServerCode("VT_READ_ONLY", vineyard)
                    assertNull(vm.pendingTankStart(original.id))
                    vm.startTankWithoutRecordedMix(original.id)
                    vm.startFillTimer(original.id)
                    vm.stopFillTimer(original.id)
                    vm.endTankSession(original.id)
                    assertFalse(vm.saveTankMixDraft(original.id, "original-tank", mapOf("water" to "999")))
                    assertEquals(original, vm.ui.value.activeTrip)
                    assertEquals(frozen, disk.load())
                    assertNull(vm.ui.value.lastReconciledTankTripId)
                    assertEquals(originalDraft, draftPrefs.all)
                    gate.verified("tank-fixture-vineyard-b", com.rork.vinetrack.data.VineyardOperationalAccess(true, true), true)
                    assertNull(vm.pendingTankStart(original.id))
                    assertEquals(original, vm.ui.value.activeTrip)
                    assertEquals(frozen, disk.load())
                } finally {
                    com.rork.vinetrack.data.OperationalWrites.authority = previousAuthority
                }
            }
        }
    }

    @Test fun retainedMalformedEvidenceCannotEscapeViewModelConstructionOrBeReplaced() {
        val session = SessionStore(app)
        // Incomplete persisted credentials: restore MUST resolve SignedOut without an auth request.
        session.accessToken = "synthetic-not-a-live-token"
        session.userId = "synthetic-owner"
        val pending = app.getSharedPreferences("vinetrack_pending_writes", Context.MODE_PRIVATE)
        val pins = app.getSharedPreferences("vinetrack_pin_capture_evidence", Context.MODE_PRIVATE)
        val pendingRaw = "[{\"id\":\"retained-original\","
        val pinRaw = "[{\"unknownFutureField\":true}]"
        assertTrue(pending.edit().putString("pending_writes_json", pendingRaw).commit())
        assertTrue(pins.edit().putString("pin_capture_evidence_json", pinRaw).commit())
        val backup = File(app.filesDir, "pin_capture_evidence_recovery_v2.json.bak").apply { writeText("[{torn") }
        val before = backup.readBytes().toList()
        constructAndAwaitLogin { vm ->
            assertEquals(SessionPhase.SignedOut, vm.ui.value.sessionPhase)
            assertNotNull(vm.pendingSyncReadIssue.value)
            assertNotNull(vm.pinEvidenceReadIssue.value)
            assertEquals(pendingRaw, pending.getString("pending_writes_json", null))
            assertEquals(pinRaw, pins.getString("pin_capture_evidence_json", null))
            assertEquals(before, backup.readBytes().toList())
        }
    }
}
