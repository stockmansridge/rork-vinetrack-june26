package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.AuthRetentionGuard
import com.rork.vinetrack.ui.auth.ProtectedWorkRecoveryViewModel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.Assert.*
import org.junit.Test

/** Authentication-only UI acceptance with fake verification; no live credentials or server claims. */
@OptIn(ExperimentalCoroutinesApi::class)
class AuthRecoverySurfaceTest {
    @Test fun verifiedIdentityShowsExplicitHoldAndDoesNotUnlockRecords() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        try {
            val guard = AuthRetentionGuard({ true }, { true })
            var requests = 0
            val vm = ProtectedWorkRecoveryViewModel { _, _ -> requests++ }
            vm.verify("synthetic@example.invalid", "synthetic-password")
            assertEquals(1, requests)
            assertFalse(vm.state.value.isBusy)
            assertTrue(vm.state.value.message!!.contains("Account verified"))
            assertTrue(vm.state.value.message!!.contains("still protected"))
            assertTrue(guard.isLocked)
            assertNull(guard.captureAccount("verified-account"))
            assertFalse(vm.state.value.toString().contains("synthetic-password"))
            assertFalse(vm.state.value.toString().contains("synthetic@example.invalid"))
        } finally { Dispatchers.resetMain() }
    }

    @Test fun failedVerificationCanBeRetriedAndDoesNotExposeRawServerError() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        try {
            var requests = 0
            val vm = ProtectedWorkRecoveryViewModel { _, _ ->
                requests++
                if (requests == 1) error("private-server-detail")
            }
            vm.verify("synthetic@example.invalid", "synthetic-password")
            assertFalse(vm.state.value.isBusy)
            assertFalse(vm.state.value.message!!.contains("private-server-detail"))
            vm.verify("synthetic@example.invalid", "synthetic-password")
            assertEquals(2, requests)
            assertTrue(vm.state.value.message!!.contains("Account verified"))
        } finally { Dispatchers.resetMain() }
    }

    @Test fun duplicateSubmitCannotStartASecondVerification() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        try {
            val release = CompletableDeferred<Unit>()
            var requests = 0
            val vm = ProtectedWorkRecoveryViewModel { _, _ -> requests++; release.await() }
            vm.verify("synthetic@example.invalid", "synthetic-password")
            assertTrue(vm.state.value.isBusy)
            vm.verify("other@example.invalid", "other-password")
            assertEquals(1, requests)
            release.complete(Unit)
            assertFalse(vm.state.value.isBusy)
        } finally { Dispatchers.resetMain() }
    }
}
