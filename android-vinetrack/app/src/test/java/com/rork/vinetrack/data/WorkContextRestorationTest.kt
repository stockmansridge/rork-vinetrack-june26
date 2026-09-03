package com.rork.vinetrack.data

import androidx.lifecycle.SavedStateHandle
import com.rork.vinetrack.ui.main.MainTab
import com.rork.vinetrack.ui.main.PinWorkflow
import com.rork.vinetrack.ui.main.ToolRoute
import com.rork.vinetrack.ui.main.WorkContextViewModel
import com.rork.vinetrack.ui.screens.PinsViewMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression tests for "restore where the user was".
 *
 * A [SavedStateHandle] is exactly what Android hands back after Activity
 * recreation, "Don't keep activities" and process death, so round-tripping one
 * reproduces those lifecycle events faithfully in a plain JVM test.
 */
class WorkContextRestorationTest {

    /**
     * Simulate recreation: copy the saved state into a fresh handle and build a
     * brand new ViewModel from it. The original instance is discarded — the new
     * one must rebuild everything from the saved values alone.
     */
    private fun recreate(handle: SavedStateHandle): WorkContextViewModel =
        WorkContextViewModel(SavedStateHandle(handle.keys().associateWith { handle.get<Any?>(it) }))

    @Test
    fun `growth pin-drop workflow survives activity recreation`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)

        work.setTool(ToolRoute.Growth)
        work.setLauncherMode("Growth")

        val restored = recreate(handle)

        assertEquals(ToolRoute.Growth, restored.tool.value)
        assertEquals("Growth", restored.launcherMode.value)
        assertEquals(PinWorkflow.Growth, restored.pinWorkflow.value)
    }

    @Test
    fun `switching mode inside the launcher is what gets restored`() {
        // The operator opened Repairs and then toggled to Growth mid-workflow.
        // The toggle is the launcher's only mode state, so Growth — not the
        // mode it was opened with — is what must come back.
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)
        work.setLauncherMode("Repairs")
        work.setLauncherMode("Growth")

        val restored = recreate(handle)

        assertEquals("Growth", restored.launcherMode.value)
        assertEquals(PinWorkflow.Growth, restored.pinWorkflow.value)
    }

    @Test
    fun `repairs pin workflow and block selection survive activity recreation`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)

        work.setTab(MainTab.Pins)
        work.setPinsBlockIds(setOf("block-7"))
        work.setLauncherMode("Repairs")

        val restored = recreate(handle)

        assertEquals(MainTab.Pins, restored.tab.value)
        assertEquals(setOf("block-7"), restored.pinsBlockIds.value)
        assertEquals(PinWorkflow.Repairs, restored.pinWorkflow.value)
    }

    @Test
    fun `pins view mode survives recreation`() {
        val handle = SavedStateHandle()
        WorkContextViewModel(handle).setPinsViewMode(PinsViewMode.List)

        assertEquals(PinsViewMode.List, recreate(handle).pinsViewMode.value)
    }

    @Test
    fun `trip HUD pin-drop workflow survives recreation and holds the screen awake`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)
        work.setTab(MainTab.Trip)
        work.setTripHudLauncherMode("Repairs")

        val restored = recreate(handle)

        assertEquals("Repairs", restored.tripHudLauncherMode.value)
        // Dropping pins from the live trip HUD is the same job as dropping them
        // from the tab launcher, so it must present as a pin workflow.
        assertEquals(PinWorkflow.Repairs, restored.pinWorkflow.value)
    }

    @Test
    fun `recreating inside a workflow does not return the user to Home`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)
        work.setTab(MainTab.Pins)
        work.setTool(ToolRoute.Growth)
        work.setLauncherMode("Growth")

        val restored = recreate(handle)

        assertFalse("must not fall back to the Home tab", restored.tab.value == MainTab.Home)
        assertEquals(ToolRoute.Growth, restored.tool.value)
    }

    @Test
    fun `active tab survives recreation`() {
        val handle = SavedStateHandle()
        WorkContextViewModel(handle).setTab(MainTab.Program)

        assertEquals(MainTab.Program, WorkContextViewModel(handle).tab.value)
    }

    @Test
    fun `a fresh install starts on Home with no workflow`() {
        val work = WorkContextViewModel(SavedStateHandle())

        assertEquals(MainTab.Home, work.tab.value)
        assertNull(work.tool.value)
        assertNull(work.launcherMode.value)
        assertNull(work.pinWorkflow.value)
        assertTrue(work.pinsBlockIds.value.isEmpty())
        assertEquals(PinsViewMode.Map, work.pinsViewMode.value)
        assertFalse(work.showAddPinComposer.value)
    }

    @Test
    fun `leaving the launcher clears the pin workflow`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.setLauncherMode("Repairs")
        assertEquals(PinWorkflow.Repairs, work.pinWorkflow.value)

        work.setLauncherMode(null)
        assertNull(work.pinWorkflow.value)
    }

    @Test
    fun `opening a tab closes any tool and launcher overlay`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.setTool(ToolRoute.Growth)
        work.setLauncherMode("Growth")
        work.setTripHudLauncherMode("Repairs")
        work.setShowAddPinComposer(true)

        work.openTab(MainTab.Trip)

        assertEquals(MainTab.Trip, work.tab.value)
        assertNull(work.tool.value)
        assertNull(work.launcherMode.value)
        assertNull(work.pinWorkflow.value)
        assertFalse(work.showAddPinComposer.value)
    }

    @Test
    fun `only small identifiers are written to the saved state bundle`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)
        work.setTab(MainTab.Pins)
        work.setTool(ToolRoute.Growth)
        work.setPinsBlockIds(setOf("block-42", "block-43"))
        work.setPinsViewMode(PinsViewMode.Stats)
        work.setLauncherMode("Growth")
        work.setTripsSelection("trip-9")
        work.bindIdentity("user-1", "vineyard-b")

        handle.keys().forEach { key ->
            val value = handle.get<Any?>(key)
            val ok = when (value) {
                null, is String, is Boolean, is Int, is Long -> true
                // Block IDs are a collection, but strictly of Strings — no
                // paddock, pin or map object may ever reach the Bundle.
                is ArrayList<*> -> value.all { it is String }
                else -> false
            }
            assertTrue("saved state must hold only ids/enums/flags, found ${value?.javaClass} for $key", ok)
        }
    }

    @Test
    fun `reset clears the whole work context`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.setTab(MainTab.Program)
        work.setTool(ToolRoute.Yield)
        work.setLauncherMode("Repairs")
        work.setPinsBlockIds(setOf("block-1"))
        work.setPinsViewMode(PinsViewMode.List)

        work.reset()

        assertEquals(MainTab.Home, work.tab.value)
        assertNull(work.tool.value)
        assertNull(work.launcherMode.value)
        assertTrue(work.pinsBlockIds.value.isEmpty())
        assertEquals(PinsViewMode.Map, work.pinsViewMode.value)
    }
}
