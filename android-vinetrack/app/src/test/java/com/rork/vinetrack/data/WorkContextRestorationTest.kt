package com.rork.vinetrack.data

import androidx.lifecycle.SavedStateHandle
import com.rork.vinetrack.ui.main.MainTab
import com.rork.vinetrack.ui.main.PinWorkflow
import com.rork.vinetrack.ui.main.ToolRoute
import com.rork.vinetrack.ui.main.WorkContextViewModel
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
    fun `growth block and pin workflow survive activity recreation`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)

        // Growth -> selected block -> pin-drop workflow.
        work.setTool(ToolRoute.Growth)
        work.setSelectedBlockId("block-42")
        work.setLauncherMode("Growth")

        val restored = recreate(handle)

        assertEquals(ToolRoute.Growth, restored.tool.value)
        assertEquals("block-42", restored.selectedBlockId.value)
        assertEquals("Growth", restored.launcherMode.value)
        assertEquals(PinWorkflow.Growth, restored.pinWorkflow.value)
    }

    @Test
    fun `repairs block and pin workflow survive activity recreation`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)

        work.setTab(MainTab.Pins)
        work.setSelectedBlockId("block-7")
        work.setLauncherMode("Repairs")

        val restored = recreate(handle)

        assertEquals(MainTab.Pins, restored.tab.value)
        assertEquals("block-7", restored.selectedBlockId.value)
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
        assertNull(work.selectedBlockId.value)
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
        work.setSelectedBlockId("block-42")
        work.setLauncherMode("Growth")
        work.setTripsSelection("trip-9")

        handle.keys().forEach { key ->
            val value = handle.get<Any?>(key)
            assertTrue(
                "saved state must hold only ids/enums/flags, found ${value?.javaClass} for $key",
                value == null || value is String || value is Boolean || value is Int || value is Long,
            )
        }
    }

    @Test
    fun `reset clears the whole work context`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.setTab(MainTab.Program)
        work.setTool(ToolRoute.Yield)
        work.setLauncherMode("Repairs")
        work.setSelectedBlockId("block-1")

        work.reset()

        assertEquals(MainTab.Home, work.tab.value)
        assertNull(work.tool.value)
        assertNull(work.launcherMode.value)
        assertNull(work.selectedBlockId.value)
    }
}
