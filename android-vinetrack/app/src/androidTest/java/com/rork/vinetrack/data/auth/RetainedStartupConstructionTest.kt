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
import io.ktor.client.engine.mock.respond
import io.ktor.serialization.kotlinx.json.json

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

    @Test fun heldMaintenanceForegroundDoesNotEditCancelOrCreateOfflineWork() {
        constructAndAwaitLogin { vm ->
            instrumentation.runOnMainSync {
                val session = AppViewModel::class.java.getDeclaredField("session").apply { isAccessible = true }.get(vm) as SessionStore
                session.accessToken = "synthetic-not-a-live-token"
                session.userId = "44444444-4444-4444-8444-444444444444"
                val a = "11111111-1111-4111-8111-111111111111"
                val b = "22222222-2222-4222-8222-222222222222"
                val id = "33333333-3333-4333-8333-333333333333"
                val input = com.rork.vinetrack.data.MaintenanceLogRepository.MaintenanceInput(
                    "Original", null, null, 2.0, null, "Retain", "", 1.0, 3.0, "2026-10-24T00:00:00Z")
                val pending = AppViewModel::class.java.getDeclaredField("pendingWrites").apply { isAccessible = true }
                    .get(vm) as com.rork.vinetrack.data.PendingWriteRepository
                val creates = com.rork.vinetrack.data.MaintenanceLogCreateSync(com.rork.vinetrack.data.MaintenanceLogRepository(session), pending)
                creates.enqueue(id, a, input, "2026-10-24T00:00:00Z")
                val originalQueue = pending.list().toList()
                val originalDisk = app.getSharedPreferences("vinetrack_pending_writes", Context.MODE_PRIVATE).all.toMap()
                val original = com.rork.vinetrack.data.model.MaintenanceLog(id = id, vineyardId = a, itemName = "Original", date = input.date)
                @Suppress("UNCHECKED_CAST")
                val state = AppViewModel::class.java.getDeclaredField("_ui").apply { isAccessible = true }
                    .get(vm) as kotlinx.coroutines.flow.MutableStateFlow<com.rork.vinetrack.ui.AppUiState>
                state.value = state.value.copy(selectedVineyardId = b, currentUserId = session.userId,
                    maintenanceLogs = listOf(original), isOnline = false, maintenanceError = null)
                val gate = requireNotNull(com.rork.vinetrack.data.OperationalWrites.authority)
                gate.handleServerCode("VT_READ_ONLY", a)
                gate.verified(b, com.rork.vinetrack.data.VineyardOperationalAccess(true, true), true)
                val scope = requireNotNull(vm.captureMaintenanceEditScope(a))
                var successes = 0
                vm.updateMaintenanceLog(id, input.copy(itemName = "Not admitted"), scope = scope) { if (it) successes++ }
                vm.deleteMaintenanceLog(id) { if (it) successes++ }
                // A new draft belongs to A, not the writable selection B.
                vm.createMaintenanceLog(input, scope = scope) { if (it) successes++ }
                assertEquals(listOf(original), vm.ui.value.maintenanceLogs)
                assertEquals(originalQueue, pending.list())
                assertEquals(originalDisk, app.getSharedPreferences("vinetrack_pending_writes", Context.MODE_PRIVATE).all)
                assertEquals(0, successes)
                gate.verified(a, com.rork.vinetrack.data.VineyardOperationalAccess(true, true), true)
                vm.updateMaintenanceLog(id, input, scope = scope) { if (it) successes++ }
                assertEquals(1, successes)
                assertEquals(originalQueue.single().id, pending.list().single().id)
                assertEquals(originalQueue.single().createdAt, pending.list().single().createdAt)
                assertEquals(originalQueue.single().attemptCount, pending.list().single().attemptCount)
                assertEquals(a, vm.ui.value.maintenanceLogs.single().vineyardId)
            }
        }
    }

    @Test fun maintenanceExpiryDuringOwnershipReadRetainsOriginalAndPublishesNoSuccess() {
        constructAndAwaitLogin { vm ->
            val session = AppViewModel::class.java.getDeclaredField("session").apply { isAccessible = true }.get(vm) as SessionStore
            session.accessToken = "synthetic-not-a-live-token"
            session.userId = "44444444-4444-4444-8444-444444444444"
            val a = "11111111-1111-4111-8111-111111111111"
            val id = "33333333-3333-4333-8333-333333333333"
            val input = com.rork.vinetrack.data.MaintenanceLogRepository.MaintenanceInput(
                "Attempted edit", null, null, 2.0, null, "Retain", "", 1.0, 3.0, "2026-10-24T00:00:00Z")
            val original = com.rork.vinetrack.data.model.MaintenanceLog(id = id, vineyardId = a, itemName = "Original", date = input.date, photoPath = "$a/maintenance/$id/photo.jpg")
            @Suppress("UNCHECKED_CAST")
            val state = AppViewModel::class.java.getDeclaredField("_ui").apply { isAccessible = true }
                .get(vm) as kotlinx.coroutines.flow.MutableStateFlow<com.rork.vinetrack.ui.AppUiState>
            val gate = requireNotNull(com.rork.vinetrack.data.OperationalWrites.authority)
            var mutations = 0
            val client = io.ktor.client.HttpClient(io.ktor.client.engine.mock.MockEngine { request ->
                if (request.method != io.ktor.http.HttpMethod.Get) mutations++
                gate.handleServerCode("VT_READ_ONLY", a)
                respond("[{\"id\":\"$id\",\"vineyard_id\":\"$a\"}]", io.ktor.http.HttpStatusCode.OK,
                    io.ktor.http.headersOf("Content-Type", "application/json"))
            }) { install(io.ktor.client.plugins.contentnegotiation.ContentNegotiation) { json(com.rork.vinetrack.data.SupabaseClient.json) } }
            com.rork.vinetrack.data.SupabaseClient.installInstrumentationTransport(client)
            try {
                for (operation in listOf("create", "update", "delete")) {
                    gate.verified(a, com.rork.vinetrack.data.VineyardOperationalAccess(true, true), true)
                    val completed = CompletableDeferred<Boolean>()
                    instrumentation.runOnMainSync {
                        state.value = state.value.copy(selectedVineyardId = a, currentUserId = session.userId,
                            maintenanceLogs = listOf(original), isOnline = true, maintenanceError = null)
                        when (operation) {
                            "create" -> vm.createMaintenanceLog(input) { completed.complete(it) }
                            "update" -> vm.updateMaintenanceLog(id, input) { completed.complete(it) }
                            else -> vm.deleteMaintenanceLog(id) { completed.complete(it) }
                        }
                    }
                    val success = runBlocking { withTimeout(15_000) { completed.await() } }
                    assertFalse("$operation published success while held", success)
                    assertEquals(listOf(original), vm.ui.value.maintenanceLogs)
                    assertEquals(0, mutations)
                    assertFalse(vm.ui.value.maintenanceBusy)
                    assertNull(app.getSharedPreferences("vinetrack_pending_writes", Context.MODE_PRIVATE).getString("pending_writes_json", null))
                }
            } finally { com.rork.vinetrack.data.SupabaseClient.installInstrumentationTransport(null); client.close() }
        }
    }

    @Test fun maintenanceCreateReceiptDuringExpiryCannotDuplicateStableDraftOnRetry() {
        constructAndAwaitLogin { vm ->
            val session = AppViewModel::class.java.getDeclaredField("session").apply { isAccessible = true }.get(vm) as SessionStore
            session.accessToken = "synthetic-not-a-live-token"
            session.userId = "44444444-4444-4444-8444-444444444444"
            val a = "11111111-1111-4111-8111-111111111111"
            val input = com.rork.vinetrack.data.MaintenanceLogRepository.MaintenanceInput(
                "Original draft", null, null, 2.0, null, "Retain", "", 1.0, 3.0, "2026-10-24T00:00:00Z")
            @Suppress("UNCHECKED_CAST")
            val state = AppViewModel::class.java.getDeclaredField("_ui").apply { isAccessible = true }
                .get(vm) as kotlinx.coroutines.flow.MutableStateFlow<com.rork.vinetrack.ui.AppUiState>
            lateinit var scope: AppViewModel.MaintenanceEditScope
            instrumentation.runOnMainSync {
                state.value = state.value.copy(selectedVineyardId = a, currentUserId = session.userId,
                    maintenanceLogs = emptyList(), isOnline = true)
                scope = requireNotNull(vm.captureMaintenanceEditScope(a))
            }
            val id = scope.draftId
            val stamp = scope.draftUpdatedAt
            val gate = requireNotNull(com.rork.vinetrack.data.OperationalWrites.authority)
            var mutations = 0
            val client = io.ktor.client.HttpClient(io.ktor.client.engine.mock.MockEngine { request ->
                if (request.method == io.ktor.http.HttpMethod.Get) {
                    respond("[]", io.ktor.http.HttpStatusCode.OK, io.ktor.http.headersOf("Content-Type", "application/json"))
                } else {
                    mutations++
                    gate.handleServerCode("VT_READ_ONLY", a)
                    respond("[{\"id\":\"$id\",\"vineyard_id\":\"$a\",\"item_name\":\"Acknowledged original\"}]",
                        io.ktor.http.HttpStatusCode.OK, io.ktor.http.headersOf("Content-Type", "application/json"))
                }
            }) { install(io.ktor.client.plugins.contentnegotiation.ContentNegotiation) { json(com.rork.vinetrack.data.SupabaseClient.json) } }
            com.rork.vinetrack.data.SupabaseClient.installInstrumentationTransport(client)
            try {
                val completed = CompletableDeferred<Boolean>()
                instrumentation.runOnMainSync { vm.createMaintenanceLog(input, scope = scope) { completed.complete(it) } }
                assertFalse(runBlocking { withTimeout(15_000) { completed.await() } })
                val acknowledged = vm.ui.value.maintenanceLogs.single()
                assertEquals(id, acknowledged.id)
                assertEquals("Acknowledged original", acknowledged.itemName)
                gate.verified(a, com.rork.vinetrack.data.VineyardOperationalAccess(true, true), true)
                val retried = CompletableDeferred<Boolean>()
                instrumentation.runOnMainSync { vm.createMaintenanceLog(input, scope = scope) { retried.complete(it) } }
                assertFalse(runBlocking { withTimeout(15_000) { retried.await() } })
                assertEquals(listOf(acknowledged), vm.ui.value.maintenanceLogs)
                assertEquals(1, mutations)
                assertEquals(id, scope.draftId)
                assertEquals(stamp, scope.draftUpdatedAt)
            } finally { com.rork.vinetrack.data.SupabaseClient.installInstrumentationTransport(null); client.close() }
        }
    }

    @Test fun staleMaintenanceSuccessCannotOverwriteNextAccountOrPublishSuccess() {
        constructAndAwaitLogin { vm ->
            val session = AppViewModel::class.java.getDeclaredField("session").apply { isAccessible = true }.get(vm) as SessionStore
            session.accessToken = "synthetic-not-a-live-token"
            session.userId = "44444444-4444-4444-8444-444444444444"
            val a = "11111111-1111-4111-8111-111111111111"
            val b = "22222222-2222-4222-8222-222222222222"
            val id = "33333333-3333-4333-8333-333333333333"
            val input = com.rork.vinetrack.data.MaintenanceLogRepository.MaintenanceInput(
                "Edit", null, null, 2.0, null, "Retain", "", 1.0, 3.0, "2026-10-24T00:00:00Z")
            val original = com.rork.vinetrack.data.model.MaintenanceLog(id = id, vineyardId = a, itemName = "Original")
            val nextAccountRow = original.copy(vineyardId = b, itemName = "Next account")
            @Suppress("UNCHECKED_CAST")
            val state = AppViewModel::class.java.getDeclaredField("_ui").apply { isAccessible = true }
                .get(vm) as kotlinx.coroutines.flow.MutableStateFlow<com.rork.vinetrack.ui.AppUiState>
            var mutations = 0
            val client = io.ktor.client.HttpClient(io.ktor.client.engine.mock.MockEngine { request ->
                if (request.method != io.ktor.http.HttpMethod.Get) {
                    mutations++
                    session.userId = b
                    state.value = state.value.copy(currentUserId = b, selectedVineyardId = b, maintenanceLogs = listOf(nextAccountRow), maintenanceBusy = false)
                }
                respond("[{\"id\":\"$id\",\"vineyard_id\":\"$a\",\"item_name\":\"Server edit\"}]", io.ktor.http.HttpStatusCode.OK,
                    io.ktor.http.headersOf("Content-Type", "application/json"))
            }) { install(io.ktor.client.plugins.contentnegotiation.ContentNegotiation) { json(com.rork.vinetrack.data.SupabaseClient.json) } }
            com.rork.vinetrack.data.SupabaseClient.installInstrumentationTransport(client)
            try {
                val completed = CompletableDeferred<Boolean>()
                instrumentation.runOnMainSync {
                    state.value = state.value.copy(selectedVineyardId = a, currentUserId = session.userId, maintenanceLogs = listOf(original), isOnline = true)
                    vm.updateMaintenanceLog(id, input) { completed.complete(it) }
                }
                val success = runBlocking { withTimeout(15_000) { completed.await() } }
                assertFalse(success)
                assertEquals(1, mutations)
                assertEquals(listOf(nextAccountRow), vm.ui.value.maintenanceLogs)
                assertEquals(b, session.userId)
                assertNull(app.getSharedPreferences("vinetrack_pending_writes", Context.MODE_PRIVATE).getString("pending_writes_json", null))
            } finally { com.rork.vinetrack.data.SupabaseClient.installInstrumentationTransport(null); client.close() }
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
