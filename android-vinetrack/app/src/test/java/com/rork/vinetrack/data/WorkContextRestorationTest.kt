package com.rork.vinetrack.data

import androidx.lifecycle.SavedStateHandle
import com.rork.vinetrack.ui.main.MainTab
import com.rork.vinetrack.ui.main.MainSurface
import com.rork.vinetrack.ui.main.TripsKnowledge
import com.rork.vinetrack.ui.main.TripsListKnowledge
import com.rork.vinetrack.ui.main.TripStartNavigation
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
        // The HUD launcher is drawn over a trip's live map, so the trip is part
        // of the workflow — see TripHudRestorationTest for that invariant.
        work.setSelectedTripId("trip-42")
        work.setTripHudLauncherMode("Repairs")

        val restored = recreate(handle)

        assertEquals("trip-42", restored.selectedTripId.value)
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
        work.setSelectedTripId("trip-9")
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
    fun `a newly device-owned active Trip opens its live HUD without a second banner tap`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.bindIdentity("operator", "vineyard-a")
        work.openTab(MainTab.Trip)
        assertTrue(TripStartNavigation.shouldOpenNewlyActive(
            activeTripId = "new-trip", activeTripVineyardId = "vineyard-a",
            deviceOwnedTripId = "new-trip", selectedVineyardId = "vineyard-a",
            userId = "operator", selectedTripId = null, tab = MainTab.Trip,
            tool = null, calculatorOpen = false,
        ))
        work.openCalculatorTrip("new-trip")
        assertEquals(MainTab.Trip, work.tab.value)
        assertEquals("new-trip", work.selectedTripId.value)
        assertEquals("new-trip", recreate(SavedStateHandle(mapOf(
            "work_tab" to work.tab.value.name, "work_selected_trip" to work.selectedTripId.value,
        ))).selectedTripId.value)

        // A deliberate Back clears the selected ID; the caller's
        // active-ID-keyed effect does not rerun until another start.
        work.setSelectedTripId(null)
        assertNull(work.selectedTripId.value)
    }

    @Test
    fun `active Trip auto entry never steals navigation across vineyard or account boundaries`() {
        fun shouldOpen(
            active: String? = "trip-1",
            owner: String? = "trip-1",
            activeVineyard: String? = "vineyard-a",
            selectedVineyard: String? = "vineyard-a",
            user: String? = "operator",
            selected: String? = null,
            tab: MainTab = MainTab.Trip,
            tool: ToolRoute? = null,
            calculatorOpen: Boolean = false,
        ) = TripStartNavigation.shouldOpenNewlyActive(
            activeTripId = active, activeTripVineyardId = activeVineyard,
            deviceOwnedTripId = owner, selectedVineyardId = selectedVineyard,
            userId = user, selectedTripId = selected, tab = tab, tool = tool,
            calculatorOpen = calculatorOpen,
        )
        assertFalse(shouldOpen(active = null))
        assertFalse(shouldOpen(owner = "someone-elses-trip"))
        assertFalse(shouldOpen(activeVineyard = "vineyard-b"))
        assertFalse(shouldOpen(user = null))
        assertFalse(shouldOpen(selected = "history-trip"))
        assertFalse(shouldOpen(tab = MainTab.Home))
        assertFalse(shouldOpen(tab = MainTab.Program, calculatorOpen = false))
        assertFalse(shouldOpen(tool = ToolRoute.Growth))
        assertTrue(shouldOpen(tab = MainTab.Program, calculatorOpen = true))
    }

    @Test
    fun `a confirmed Start enters live Trip even when previous authoritative list is missing it`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)
        work.bindIdentity("operator", "vineyard-a")
        work.openTab(MainTab.Trip)
        val staleList = TripsKnowledge(
            knownIds = setOf("old-trip"), activeIds = emptySet(),
            listKnowledge = TripsListKnowledge.Authoritative,
        )
        work.reconcileTripContext(staleList)

        // Trip creation succeeded locally; a remote list from BEFORE the Start
        // must not evict the exact new destination while the state flow catches up.
        work.openStartedTrip("new-trip")
        assertEquals("new-trip", work.lastPresentedActiveTripId())
        work.reconcileTripContext(staleList)
        assertEquals(MainSurface.TripTab("new-trip", null), MainSurface.of(work.snapshot()))
        assertEquals("new-trip", handle.get<String>("work_pending_started_trip"))

        // Activity recreation keeps the exact target and the handoff latch.
        val restored = recreate(handle)
        assertEquals("new-trip", restored.lastPresentedActiveTripId())
        restored.reconcileTripContext(staleList)
        assertEquals("new-trip", restored.selectedTripId.value)

        val liveList = TripsKnowledge(
            knownIds = setOf("old-trip", "new-trip"), activeIds = setOf("new-trip"),
            listKnowledge = TripsListKnowledge.Authoritative,
        )
        restored.reconcileTripContext(liveList)
        assertEquals("new-trip", restored.selectedTripId.value)
        restored.setSelectedTripId(null) // operator consciously pressed Back
        restored.reconcileTripContext(liveList)
        assertNull(restored.selectedTripId.value)
        assertEquals("new-trip", restored.lastPresentedActiveTripId())
        assertFalse(TripStartNavigation.shouldOpenUnseenActive(
            lastOpenedTripId = recreate(handle).lastPresentedActiveTripId(),
            activeTripId = "new-trip", activeTripVineyardId = "vineyard-a",
            deviceOwnedTripId = "new-trip", selectedVineyardId = "vineyard-a",
            userId = "operator", selectedTripId = null, tab = MainTab.Trip,
            tool = null, calculatorOpen = false,
        ))
    }

    @Test
    fun `a queued spray activated in place is not dropped by a stale inactive snapshot`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)
        work.bindIdentity("operator", "vineyard-a")
        val oldList = TripsKnowledge(
            knownIds = setOf("queued-spray"), activeIds = emptySet(),
            listKnowledge = TripsListKnowledge.Authoritative,
        )
        work.reconcileTripContext(oldList)
        work.setTab(MainTab.Program)
        work.setSelectedTripId("queued-spray") // last displayed as inactive
        work.openStartedTrip("queued-spray") // same original ID, no new trip created
        work.reconcileTripContext(oldList)

        assertEquals(MainTab.Trip, work.tab.value)
        assertEquals("queued-spray", work.selectedTripId.value)
        assertEquals("queued-spray", handle.get<String>("work_pending_started_trip"))
        assertEquals(MainSurface.TripTab("queued-spray", null), MainSurface.of(work.snapshot()))

        // A known active record closes the temporary handoff; Back remains Back.
        work.reconcileTripContext(oldList.copy(activeIds = setOf("queued-spray")))
        assertNull(handle.get<String>("work_pending_started_trip"))
        work.setSelectedTripId(null)
        work.reconcileTripContext(oldList.copy(activeIds = setOf("queued-spray")))
        assertNull(work.selectedTripId.value)
    }

    @Test
    fun `switching identity cancels the confirmed Start destination`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)
        work.bindIdentity("operator", "vineyard-a")
        work.openStartedTrip("trip-in-vineyard-a")
        assertEquals("trip-in-vineyard-a", handle.get<String>("work_pending_started_trip"))
        work.bindIdentity("operator", "vineyard-b")
        assertNull(work.selectedTripId.value)
        assertNull(handle.get<String>("work_pending_started_trip"))
        assertNull(work.lastPresentedActiveTripId())
        assertEquals(MainSurface.TripTab(null, null), MainSurface.of(work.snapshot()))
    }

    @Test
    fun `late device ownership retries auto navigation but Back cannot bounce`() {
        fun shouldOpen(deviceOwner: String?, alreadyOpened: String?): Boolean =
            TripStartNavigation.shouldOpenUnseenActive(
                lastOpenedTripId = alreadyOpened,
                activeTripId = "started-trip",
                activeTripVineyardId = "vineyard-a",
                deviceOwnedTripId = deviceOwner,
                selectedVineyardId = "vineyard-a",
                userId = "operator",
                selectedTripId = null,
                tab = MainTab.Trip,
                tool = null,
                calculatorOpen = false,
            )

        assertFalse(shouldOpen(deviceOwner = null, alreadyOpened = null))
        assertTrue(shouldOpen(deviceOwner = "started-trip", alreadyOpened = null))
        assertFalse(shouldOpen(deviceOwner = "started-trip", alreadyOpened = "started-trip"))
        assertFalse(shouldOpen(deviceOwner = "foreign-trip", alreadyOpened = null))
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
