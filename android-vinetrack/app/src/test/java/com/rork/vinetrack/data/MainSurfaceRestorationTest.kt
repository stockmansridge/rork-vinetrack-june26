package com.rork.vinetrack.data

import androidx.lifecycle.SavedStateHandle
import com.rork.vinetrack.ui.main.MainSurface
import com.rork.vinetrack.ui.main.MainTab
import com.rork.vinetrack.ui.main.ToolRoute
import com.rork.vinetrack.ui.main.WorkContextViewModel
import com.rork.vinetrack.ui.screens.PinsViewMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Proves the restored work context is actually CONSUMED, not merely stored.
 *
 * `MainScaffold` renders by exhaustively matching on [MainSurface.of] — that
 * call is the whole of its routing decision, and each surface carries the exact
 * arguments handed to the screen. Driving the same function from a restored
 * [WorkContextViewModel] therefore exercises the real path an operator takes
 * back into the app after Activity or process recreation, without needing a
 * device.
 *
 * What this does NOT cover, and what the on-device pass is for: that Android
 * actually persists and returns the Bundle for a given lifecycle event, and
 * that the screens paint correctly from the arguments asserted here.
 */
class MainSurfaceRestorationTest {

    private fun recreate(handle: SavedStateHandle): WorkContextViewModel =
        WorkContextViewModel(SavedStateHandle(handle.keys().associateWith { handle.get<Any?>(it) }))

    /** The surface MainScaffold would show for this context, right now. */
    private fun surfaceOf(work: WorkContextViewModel): MainSurface = MainSurface.of(work.snapshot())

    // 6. The restored workflow value reaches the real Growth/Repairs UI.
    @Test
    fun `restored growth workflow reopens the launcher in Growth, not the Pins tab`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)
        work.bindIdentity("user-a", "vineyard-b")
        work.setTab(MainTab.Pins)
        work.setLauncherMode("Growth")

        val restored = recreate(handle)
        restored.bindIdentity("user-a", "vineyard-b")

        // The operator is put back into the pin-drop launcher IN GROWTH — the
        // screen has no mode state of its own to fall back to.
        assertEquals(MainSurface.PinLauncher("Growth"), surfaceOf(restored))
    }

    @Test
    fun `restored repairs workflow reopens the launcher in Repairs`() {
        val handle = SavedStateHandle()
        WorkContextViewModel(handle).setLauncherMode("Repairs")

        assertEquals(MainSurface.PinLauncher("Repairs"), surfaceOf(recreate(handle)))
    }

    @Test
    fun `a mode toggled inside the launcher is the mode restored into it`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)
        work.setLauncherMode("Repairs")
        // Exactly what the launcher's toggle does — it has no other mode state.
        work.setLauncherMode("Growth")

        assertEquals(MainSurface.PinLauncher("Growth"), surfaceOf(recreate(handle)))
    }

    @Test
    fun `restored block selection and view mode are handed to the Pins screen`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)
        work.bindIdentity("user-a", "vineyard-b")
        work.setTab(MainTab.Pins)
        work.setPinsBlockIds(setOf("block-7", "block-9"))
        work.setPinsViewMode(PinsViewMode.List)

        val surface = surfaceOf(recreate(handle))

        assertTrue("expected the Pins tab, got $surface", surface is MainSurface.PinsTab)
        val pins = (surface as MainSurface.PinsTab).pins
        assertEquals(setOf("block-7", "block-9"), pins.selectedBlockIds)
        assertEquals(PinsViewMode.List, pins.viewMode)
    }

    @Test
    fun `restored block selection reaches the Pins tool opened over another tab`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)
        work.setTab(MainTab.Home)
        work.setTool(ToolRoute.Pins)
        work.setPinsBlockIds(setOf("block-3"))
        work.setPinsViewMode(PinsViewMode.Stats)

        val surface = surfaceOf(recreate(handle))

        assertEquals(
            MainSurface.Tool(ToolRoute.Pins, null, com.rork.vinetrack.ui.main.PinsInputs(PinsViewMode.Stats, setOf("block-3"))),
            surface,
        )
    }

    @Test
    fun `restored trip HUD launcher reopens over the trip, not a bare HUD`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)
        work.setTab(MainTab.Trip)
        work.setSelectedTripId("trip-9")
        work.setTripHudLauncherMode("Growth")

        assertEquals(MainSurface.TripTab("trip-9", "Growth"), surfaceOf(recreate(handle)))
    }

    @Test
    fun `a vineyard switch drops the old block before the Pins screen sees it`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.bindIdentity("user-a", "vineyard-a")
        work.setTab(MainTab.Pins)
        work.setPinsBlockIds(setOf("block-in-vineyard-a"))

        work.bindIdentity("user-a", "vineyard-b")

        val surface = surfaceOf(work) as MainSurface.PinsTab
        assertTrue(
            "a block from the previous vineyard must never reach the screen",
            surface.pins.selectedBlockIds.isEmpty(),
        )
    }

    @Test
    fun `signing out sends the next session to Home`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.bindIdentity("user-a", "vineyard-b")
        work.setLauncherMode("Growth")

        work.resetForSignOut()

        assertEquals(MainSurface.HomeTab, surfaceOf(work))
    }

    @Test
    fun `overlays outrank the launcher and the launcher outranks a tool`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.setTool(ToolRoute.Growth)
        work.setLauncherMode("Growth")
        assertEquals(MainSurface.PinLauncher("Growth"), surfaceOf(work))

        work.setShowAddPinComposer(true)
        assertEquals(MainSurface.AddPinComposer, surfaceOf(work))

        work.setShowSetupWizard(true)
        assertEquals(MainSurface.SetupWizard, surfaceOf(work))
    }

    @Test
    fun `a fresh install lands on Home`() {
        assertEquals(MainSurface.HomeTab, surfaceOf(WorkContextViewModel(SavedStateHandle())))
    }

    @Test
    fun `an unrecognised saved launcher mode still opens a usable launcher`() {
        val handle = SavedStateHandle()
        WorkContextViewModel(handle).setLauncherMode("something-old")

        // Normalised at the routing boundary so the screen never has to guess.
        assertEquals(MainSurface.PinLauncher("Repairs"), surfaceOf(recreate(handle)))
    }
}
