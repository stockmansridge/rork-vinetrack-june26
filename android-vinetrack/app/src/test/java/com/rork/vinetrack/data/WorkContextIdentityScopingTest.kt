package com.rork.vinetrack.data

import androidx.lifecycle.SavedStateHandle
import com.rork.vinetrack.ui.main.MainTab
import com.rork.vinetrack.ui.main.ToolRoute
import com.rork.vinetrack.ui.main.WorkContextBinding
import com.rork.vinetrack.ui.main.WorkContextViewModel
import com.rork.vinetrack.ui.screens.PinsViewMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The work context belongs to ONE user working ONE vineyard. It must survive
 * every lifecycle event for that identity, and must not survive a change of
 * identity.
 *
 * The hard case is that those two requirements look identical from inside a
 * naive `LaunchedEffect(userId) { reset() }`: the first bind after process
 * death and the first bind after a user switch both "see a user id arrive".
 * Binding information is therefore part of the saved state itself, so the two
 * can be told apart — and these tests exist to keep them apart.
 */
class WorkContextIdentityScopingTest {

    private fun recreate(handle: SavedStateHandle): Pair<WorkContextViewModel, SavedStateHandle> {
        val carried = SavedStateHandle(handle.keys().associateWith { handle.get<Any?>(it) })
        return WorkContextViewModel(carried) to carried
    }

    /** Put the operator deep inside a Growth pin-drop workflow on one block. */
    private fun WorkContextViewModel.enterGrowthWorkflow() {
        setTab(MainTab.Pins)
        setTool(ToolRoute.Growth)
        setLauncherMode("Growth")
        setPinsBlockIds(setOf("block-7"))
        setPinsViewMode(PinsViewMode.List)
    }

    // 1. Same user + same vineyard + process recreation -> context remains.
    @Test
    fun `same user and vineyard across process recreation keeps the growth workflow`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)
        work.bindIdentity("user-a", "vineyard-b")
        work.enterGrowthWorkflow()

        // Process death: the ViewModel is destroyed, only the Bundle survives.
        val (restored, _) = recreate(handle)
        val binding = restored.bindIdentity("user-a", "vineyard-b")

        assertEquals(WorkContextBinding.Retained, binding)
        assertEquals(MainTab.Pins, restored.tab.value)
        assertEquals(ToolRoute.Growth, restored.tool.value)
        assertEquals("Growth", restored.launcherMode.value)
        assertEquals(setOf("block-7"), restored.pinsBlockIds.value)
        assertEquals(PinsViewMode.List, restored.pinsViewMode.value)
    }

    @Test
    fun `restoration binds before the vineyard has resolved without losing the block`() {
        // Real restore order: the user is known first and the active vineyard
        // arrives a moment later, once the local store has been read.
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)
        work.bindIdentity("user-a", "vineyard-b")
        work.enterGrowthWorkflow()

        val (restored, _) = recreate(handle)
        assertEquals(WorkContextBinding.Retained, restored.bindIdentity("user-a", null))
        assertEquals(WorkContextBinding.Retained, restored.bindIdentity("user-a", "vineyard-b"))

        assertEquals(setOf("block-7"), restored.pinsBlockIds.value)
        assertEquals("Growth", restored.launcherMode.value)
    }

    @Test
    fun `binding while still restoring writes nothing`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)
        work.enterGrowthWorkflow()

        // No authenticated user yet — a hydration race must not be read as a
        // new identity, nor clear anything.
        assertEquals(WorkContextBinding.Unbound, work.bindIdentity(null, null))
        assertEquals(WorkContextBinding.Unbound, work.bindIdentity(null, "vineyard-b"))

        assertEquals(setOf("block-7"), work.pinsBlockIds.value)
        assertEquals("Growth", work.launcherMode.value)
        assertEquals(null to null, work.boundIdentity())
    }

    // 2. Explicit logout -> work context clears.
    @Test
    fun `explicit logout clears the work context and its binding`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.bindIdentity("user-a", "vineyard-b")
        work.enterGrowthWorkflow()

        work.resetForSignOut()

        assertEquals(MainTab.Home, work.tab.value)
        assertNull(work.tool.value)
        assertNull(work.launcherMode.value)
        assertTrue(work.pinsBlockIds.value.isEmpty())
        assertEquals(PinsViewMode.Map, work.pinsViewMode.value)
        assertEquals(null to null, work.boundIdentity())
    }

    // 3. User A logs out, User B logs in, same Activity.
    @Test
    fun `user B cannot inherit user A's tab tool or block state`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.bindIdentity("user-a", "vineyard-b")
        work.enterGrowthWorkflow()

        work.resetForSignOut()
        val binding = work.bindIdentity("user-b", "vineyard-z")

        assertEquals(WorkContextBinding.Retained, binding) // nothing left to clear
        assertEquals(MainTab.Home, work.tab.value)
        assertNull(work.tool.value)
        assertNull(work.launcherMode.value)
        assertTrue(work.pinsBlockIds.value.isEmpty())
        assertEquals("user-b" to "vineyard-z", work.boundIdentity())
    }

    @Test
    fun `a different user is cleared even if the logout reset never ran`() {
        // Defence in depth: if any future path swaps users without going
        // through logout, the binding still catches it.
        val work = WorkContextViewModel(SavedStateHandle())
        work.bindIdentity("user-a", "vineyard-b")
        work.enterGrowthWorkflow()

        val binding = work.bindIdentity("user-b", "vineyard-b")

        assertEquals(WorkContextBinding.UserChanged, binding)
        assertEquals(MainTab.Home, work.tab.value)
        assertNull(work.tool.value)
        assertNull(work.launcherMode.value)
        assertTrue(work.pinsBlockIds.value.isEmpty())
        assertEquals("user-b" to "vineyard-b", work.boundIdentity())
    }

    // 4. Vineyard A block -> switch to Vineyard B -> block discarded.
    @Test
    fun `switching vineyard discards the previous vineyard's block selection`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.bindIdentity("user-a", "vineyard-a")
        work.setPinsBlockIds(setOf("block-in-vineyard-a"))
        work.setSelectedTripId("trip-in-vineyard-a")
        work.setProgramCalculatorPrefill("spray-in-vineyard-a")
        work.setTripHudLauncherMode("Repairs")

        val binding = work.bindIdentity("user-a", "vineyard-b")

        assertEquals(WorkContextBinding.VineyardChanged, binding)
        assertTrue("block IDs belong to the old vineyard", work.pinsBlockIds.value.isEmpty())
        assertNull(work.selectedTripId.value)
        assertNull(work.programCalculatorPrefill.value)
        assertNull(work.tripHudLauncherMode.value)
    }

    @Test
    fun `switching vineyard keeps the operator on a safe top-level tool`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.bindIdentity("user-a", "vineyard-a")
        work.setTab(MainTab.Pins)
        work.setTool(ToolRoute.Growth)
        work.setLauncherMode("Growth")
        work.setPinsBlockIds(setOf("block-in-vineyard-a"))

        work.bindIdentity("user-a", "vineyard-b")

        // Repairs/Growth means the same thing in any vineyard, so the operator
        // is not thrown out of the workflow — only the old vineyard's data goes.
        assertEquals(MainTab.Pins, work.tab.value)
        assertEquals(ToolRoute.Growth, work.tool.value)
        assertEquals("Growth", work.launcherMode.value)
        assertTrue(work.pinsBlockIds.value.isEmpty())
    }

    // 5. Same vineyard rehydrated -> nothing cleared.
    @Test
    fun `rehydrating the same vineyard does not clear the block or work context`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.bindIdentity("user-a", "vineyard-b")
        work.enterGrowthWorkflow()
        work.setSelectedTripId("trip-1")

        // Cache read, network refresh, reconnect, foreground revalidation —
        // each re-publishes the same identity.
        repeat(5) {
            assertEquals(WorkContextBinding.Retained, work.bindIdentity("user-a", "vineyard-b"))
        }

        assertEquals(setOf("block-7"), work.pinsBlockIds.value)
        assertEquals("trip-1", work.selectedTripId.value)
        assertEquals("Growth", work.launcherMode.value)
        assertEquals(PinsViewMode.List, work.pinsViewMode.value)
    }

    @Test
    fun `switching away and back does not resurrect the first vineyard's block`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.bindIdentity("user-a", "vineyard-a")
        work.setPinsBlockIds(setOf("block-a"))

        work.bindIdentity("user-a", "vineyard-b")
        work.setPinsBlockIds(setOf("block-b"))
        work.bindIdentity("user-a", "vineyard-a")

        assertTrue(work.pinsBlockIds.value.isEmpty())
    }

    @Test
    fun `the identity binding itself survives recreation`() {
        val handle = SavedStateHandle()
        WorkContextViewModel(handle).bindIdentity("user-a", "vineyard-b")

        val (restored, _) = recreate(handle)

        assertEquals("user-a" to "vineyard-b", restored.boundIdentity())
    }
}
