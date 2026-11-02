package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ChemicalRemovalGuardTest {
    private val a = ChemicalRemovalGuard.Target("owner", "vineyard", "original", "Original product", ChemicalRemovalGuard.Action.ARCHIVE)
    private val b = a.copy(id = "adjacent", name = "Adjacent product")
    private var bytes: String? = null
    private fun guard() = ChemicalRemovalGuard({ bytes }, { bytes = it; true })
    private fun row() = SavedChemical(a.id, a.vineyard, name = a.name)

    @Test fun tenSecondResponseSerialisesTwoAdjacentRowsAndRepeatedTaps() = runTest {
        val guard = guard()
        var dispatches = 0
        fun submit(target: ChemicalRemovalGuard.Target) {
            if (!guard.begin(target)) return
            launch { dispatches++; delay(10_000); guard.finish(target, "Readback confirmed") }
        }
        submit(a)
        assertTrue(guard.state.value.busy)
        repeat(20) { submit(a); submit(b) }
        runCurrent()
        assertEquals(1, dispatches)
        advanceTimeBy(9_999)
        assertEquals(a, guard.state.value.target)
        assertTrue(guard.state.value.busy)
        submit(b)
        advanceTimeBy(1); runCurrent()
        assertNull(guard.state.value.target)
        assertEquals(1, dispatches)
    }
    @Test fun persistedBeforeCallerCanDispatch() {
        val guard = guard(); assertTrue(guard.begin(a))
        assertNotNull(bytes); assertEquals(a, guard().state.value.target)
    }
    @Test fun restartRetainsExactTargetButDoesNotReplayMutation() {
        guard().begin(a)
        val reopened = guard()
        assertEquals(a, reopened.state.value.target); assertFalse(reopened.state.value.busy)
        assertFalse(reopened.begin(b)); assertTrue(reopened.checking(a)); assertFalse(reopened.checking(a))
    }
    @Test fun offlineFailureRetainsIdentityAndLocksAllRows() {
        val guard = guard(); guard.begin(a); guard.hold(a, "Offline")
        assertFalse(guard.state.value.busy); assertFalse(guard.begin(a)); assertFalse(guard.begin(b))
        assertEquals(a, guard().state.value.target)
    }
    @Test fun staleCallbackCannotUnlockAnotherRequest() {
        val guard = guard(); guard.begin(a)
        assertFalse(guard.finish(b, "wrong")); guard.hold(b, "wrong")
        assertEquals(a, guard.state.value.target); assertTrue(guard.state.value.busy)
    }
    @Test fun failedInitialPersistenceNeverAdmitsDispatch() {
        val guard = ChemicalRemovalGuard({ null }, { false })
        assertFalse(guard.begin(a)); assertNull(guard.state.value.target); assertFalse(guard.state.value.busy)
    }
    @Test fun persistenceExceptionDoesNotCrashOrAdmitDispatch() {
        assertFalse(ChemicalRemovalGuard({ null }, { error("disk") }).begin(a))
    }
    @Test fun failedAcknowledgementRetainsOriginalAcrossRestart() {
        var mayClear = false
        val guard = ChemicalRemovalGuard({ bytes }, { if (it == null && !mayClear) false else { bytes = it; true } })
        guard.begin(a); assertFalse(guard.finish(a, "done")); assertEquals(a, guard().state.value.target)
        mayClear = true; assertTrue(guard.finish(a, "done")); assertNull(bytes)
    }
    @Test fun unreadableEvidenceFailsClosedWithoutOverwrite() {
        bytes = "not-json"; val guard = guard()
        assertTrue(guard.state.value.unreadable); assertFalse(guard.begin(a))
        guard.dismissMessage(); assertEquals("not-json", bytes); assertTrue(guard.state.value.unreadable)
    }
    @Test fun accountAndVineyardMustBothMatch() {
        val guard = guard()
        assertTrue(guard.matchesScope(a, a.owner, a.vineyard))
        assertFalse(guard.matchesScope(a, "other", a.vineyard))
        assertFalse(guard.matchesScope(a, a.owner, "other")); assertFalse(guard.matchesScope(a, null, null))
    }
    @Test fun archiveRequiresOriginalArchivedRowNotAbsenceOrAdjacentRow() {
        val guard = guard()
        assertFalse(guard.isConfirmed(a, null)); assertFalse(guard.isConfirmed(a, row()))
        assertTrue(guard.isConfirmed(a, row().copy(deletedAt = "2026-11-02T00:00:00Z")))
        assertTrue(guard.isConfirmed(a, row().copy(isActive = false)))
        assertFalse(guard.isConfirmed(a, row().copy(id = b.id, isActive = false)))
        assertFalse(guard.isConfirmed(a, row().copy(vineyardId = "other", isActive = false)))
    }
    @Test fun permanentDeletionRequiresAbsenceNotArchivedRow() {
        val target = a.copy(action = ChemicalRemovalGuard.Action.DELETE); val guard = guard()
        assertTrue(guard.isConfirmed(target, null)); assertFalse(guard.isConfirmed(target, row().copy(isActive = false)))
    }
    @Test fun reactivationRequiresOriginalActiveNondeletedRow() {
        val target = a.copy(action = ChemicalRemovalGuard.Action.RESTORE); val guard = guard()
        assertFalse(guard.isConfirmed(target, null)); assertFalse(guard.isConfirmed(target, row().copy(isActive = false)))
        assertFalse(guard.isConfirmed(target, row().copy(deletedAt = "date"))); assertTrue(guard.isConfirmed(target, row()))
    }
    @Test fun dismissingMessageCannotDiscardRetainedTarget() {
        val guard = guard(); guard.begin(a); guard.hold(a, "uncertain"); guard.dismissMessage()
        assertEquals(a, guard.state.value.target); assertNotNull(bytes)
    }
}
