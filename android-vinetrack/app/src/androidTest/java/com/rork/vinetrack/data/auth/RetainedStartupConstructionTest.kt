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
