package com.rork.vinetrack.data

import androidx.lifecycle.SavedStateHandle
import com.rork.vinetrack.ui.components.ScreenAwakeController
import com.rork.vinetrack.ui.main.MainSurface
import com.rork.vinetrack.ui.main.MainTab
import com.rork.vinetrack.ui.main.PinWorkflow
import com.rork.vinetrack.ui.main.TripContextRules
import com.rork.vinetrack.ui.main.TripsKnowledge
import com.rork.vinetrack.ui.main.WorkContextViewModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The live-trip HUD is the one workflow where losing context costs the operator
 * real work: they are in the cab, mid-trip, dropping Repairs/Growth pins, and a
 * recreation must put them back exactly where they were.
 *
 * Two things have to survive together for that to happen — the trip that owns
 * the HUD, and the launcher drawn over it. These tests hold them together, and
 * hold the invariant that the launcher is never restored without its trip.
 */
class TripHudRestorationTest {

    private fun recreate(handle: SavedStateHandle): WorkContextViewModel =
        WorkContextViewModel(SavedStateHandle(handle.keys().associateWith { handle.get<Any?>(it) }))

    /** The screen MainScaffold would show for this context, right now. */
    private fun surfaceOf(work: WorkContextViewModel): MainSurface = MainSurface.of(work.snapshot())

    /** Trip list state: [active] are recording, [ended] exist but are finished. */
    private fun knowledge(active: Set<String> = emptySet(), ended: Set<String> = emptySet()) =
        TripsKnowledge(knownIds = active + ended, activeIds = active)

    /**
     * Whether the display is currently forced on for a pin-drop workflow, the
     * way RootScreen forces it from [WorkContextViewModel.pinWorkflow].
     */
    private fun forcesScreenAwake(work: WorkContextViewModel): Boolean {
        val workflow = work.pinWorkflow.value ?: return false
        val reason = when (workflow) {
            PinWorkflow.Repairs -> ScreenAwakeController.Reason.RepairPinDrop
            PinWorkflow.Growth -> ScreenAwakeController.Reason.GrowthPinDrop
        }
        return ScreenAwakeController.shouldKeepScreenAwake(
            preferenceEnabled = false, // forced scopes must not need the preference
            preferenceScopes = emptySet(),
            forcedScopes = setOf(reason),
        )
    }

    /** Put the operator in the live HUD of an active trip, dropping pins. */
    private fun WorkContextViewModel.enterTripHud(tripId: String, mode: String) {
        setTab(MainTab.Trip)
        setSelectedTripId(tripId)
        setTripHudLauncherMode(mode)
    }

    // 1 & 2. Active trip + HUD launcher survive process death, both modes.
    @Test
    fun `active trip with the Growth HUD launcher is restored whole`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)
        work.bindIdentity("user-a", "vineyard-b")
        work.enterTripHud("trip-42", "Growth")

        val restored = recreate(handle)
        restored.bindIdentity("user-a", "vineyard-b")
        restored.reconcileTripContext(knowledge(active = setOf("trip-42")))

        assertEquals(MainSurface.TripTab("trip-42", "Growth"), surfaceOf(restored))
        assertEquals(PinWorkflow.Growth, restored.pinWorkflow.value)
    }

    @Test
    fun `active trip with the Repairs HUD launcher is restored whole`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)
        work.enterTripHud("trip-42", "Repairs")

        val restored = recreate(handle)
        restored.reconcileTripContext(knowledge(active = setOf("trip-42")))

        assertEquals(MainSurface.TripTab("trip-42", "Repairs"), surfaceOf(restored))
        assertEquals(PinWorkflow.Repairs, restored.pinWorkflow.value)
    }

    @Test
    fun `the HUD launcher survives the window before the trip list has loaded`() {
        // Restoration order: the work context is read back long before trips
        // arrive from the local store. Nothing may be cleared on that evidence.
        val handle = SavedStateHandle()
        WorkContextViewModel(handle).enterTripHud("trip-42", "Growth")

        val restored = recreate(handle)
        restored.reconcileTripContext(TripsKnowledge.Unknown)

        assertEquals(MainSurface.TripTab("trip-42", "Growth"), surfaceOf(restored))

        restored.reconcileTripContext(knowledge(active = setOf("trip-42")))
        assertEquals(MainSurface.TripTab("trip-42", "Growth"), surfaceOf(restored))
    }

    // 3. Stale HUD mode must not hold the screen awake behind a hidden launcher.
    @Test
    fun `a HUD mode with no selected trip is dropped and holds nothing awake`() {
        val handle = SavedStateHandle()
        // A bundle that somehow carries a HUD mode with no trip: the launcher
        // it names is nowhere on screen, so it must count for nothing.
        handle["work_trip_hud_launcher"] = "Growth"
        handle["work_tab"] = MainTab.Trip.name

        val restored = WorkContextViewModel(handle)

        assertNull("no trip means no HUD launcher", restored.pinWorkflow.value)
        assertFalse(forcesScreenAwake(restored))
        assertEquals(MainSurface.TripTab(null, null), surfaceOf(restored))
    }

    @Test
    fun `a HUD mode whose trip has ended is cleared once the trips are known`() {
        val handle = SavedStateHandle()
        WorkContextViewModel(handle).enterTripHud("trip-42", "Growth")

        val restored = recreate(handle)
        // The trip ended while the app was away (ended here, or on another device).
        restored.reconcileTripContext(knowledge(ended = setOf("trip-42")))

        assertNull(restored.tripHudLauncherMode.value)
        assertNull(restored.pinWorkflow.value)
        assertFalse(forcesScreenAwake(restored))
        // The trip itself is still where the operator was — only the live-map
        // launcher is gone, so they land on the trip's detail.
        assertEquals(MainSurface.TripTab("trip-42", null), surfaceOf(restored))
    }

    @Test
    fun `a selected trip that was deleted is cleared along with its HUD`() {
        val handle = SavedStateHandle()
        WorkContextViewModel(handle).enterTripHud("trip-42", "Repairs")

        val restored = recreate(handle)
        restored.reconcileTripContext(knowledge(active = setOf("trip-99"), ended = setOf("trip-7")))

        assertNull(restored.selectedTripId.value)
        assertNull(restored.tripHudLauncherMode.value)
        assertFalse(forcesScreenAwake(restored))
        assertEquals(MainSurface.TripTab(null, null), surfaceOf(restored))
    }

    @Test
    fun `the top-level Repairs launcher is untouched by trip reconciliation`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.setLauncherMode("Repairs")

        // No trips at all — the tab launcher has nothing to do with trips.
        work.reconcileTripContext(TripsKnowledge.Unknown)
        work.reconcileTripContext(knowledge(active = setOf("trip-1")))

        assertEquals("Repairs", work.launcherMode.value)
        assertEquals(PinWorkflow.Repairs, work.pinWorkflow.value)
        assertEquals(MainSurface.PinLauncher("Repairs"), surfaceOf(work))
    }

    // 4. Ordinary Activity recreation (rotation, "Don't keep activities").
    @Test
    fun `the selected trip survives ordinary Activity recreation`() {
        val handle = SavedStateHandle()
        val work = WorkContextViewModel(handle)
        work.setTab(MainTab.Trip)
        work.setSelectedTripId("trip-42")

        val restored = recreate(handle)
        restored.reconcileTripContext(knowledge(ended = setOf("trip-42")))

        assertEquals("trip-42", restored.selectedTripId.value)
        assertEquals(MainSurface.TripTab("trip-42", null), surfaceOf(restored))
    }

    @Test
    fun `opening a trip is not consumed by reading it`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.setTab(MainTab.Trip)
        work.setSelectedTripId("trip-42")

        // The old bug: the screen copied the ID into local state and cleared
        // the shared one, so the next recreation had nothing to restore.
        repeat(3) { surfaceOf(work) }

        assertEquals("trip-42", work.selectedTripId.value)
    }

    // 5. Back out of a trip.
    @Test
    fun `going back from trip detail clears the trip and its HUD launcher`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.enterTripHud("trip-42", "Growth")

        work.setSelectedTripId(null) // what TripDetailView's Back does

        assertNull(work.selectedTripId.value)
        assertNull("the HUD launcher belongs to the trip it was drawn over", work.tripHudLauncherMode.value)
        assertFalse(forcesScreenAwake(work))
        assertEquals(MainSurface.TripTab(null, null), surfaceOf(work))
    }

    @Test
    fun `switching to another trip does not carry the previous trip's HUD launcher`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.enterTripHud("trip-42", "Growth")

        work.setSelectedTripId("trip-77")

        assertEquals("trip-77", work.selectedTripId.value)
        assertNull(work.tripHudLauncherMode.value)
    }

    // 6. Vineyard switch clears trip and HUD together.
    @Test
    fun `switching vineyard clears the selected trip and the HUD launcher together`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.bindIdentity("user-a", "vineyard-a")
        work.enterTripHud("trip-in-vineyard-a", "Growth")

        work.bindIdentity("user-a", "vineyard-b")

        assertNull(work.selectedTripId.value)
        assertNull(work.tripHudLauncherMode.value)
        assertFalse(forcesScreenAwake(work))
    }

    @Test
    fun `signing out clears the selected trip and the HUD launcher`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.bindIdentity("user-a", "vineyard-a")
        work.enterTripHud("trip-42", "Repairs")

        work.resetForSignOut()

        assertNull(work.selectedTripId.value)
        assertNull(work.tripHudLauncherMode.value)
        assertFalse(forcesScreenAwake(work))
    }

    @Test
    fun `a different user cannot inherit the previous user's open trip`() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.bindIdentity("user-a", "vineyard-a")
        work.enterTripHud("trip-42", "Repairs")

        work.bindIdentity("user-b", "vineyard-a")

        assertNull(work.selectedTripId.value)
        assertNull(work.tripHudLauncherMode.value)
    }

    // The pure rule, exercised directly.
    @Test
    fun `the trip context rule only acts on positive evidence`() {
        val unknown = TripsKnowledge.Unknown

        // Nothing known: change nothing.
        assertEquals(
            "trip-1" to "Growth",
            TripContextRules.reconcile("trip-1", "Growth", unknown).let { it.selectedTripId to it.hudLauncherMode },
        )
        // Known and active: change nothing.
        assertEquals(
            "trip-1" to "Growth",
            TripContextRules.reconcile("trip-1", "Growth", knowledge(active = setOf("trip-1")))
                .let { it.selectedTripId to it.hudLauncherMode },
        )
        // Known but ended: keep the trip, drop the live launcher.
        assertEquals(
            "trip-1" to null,
            TripContextRules.reconcile("trip-1", "Growth", knowledge(ended = setOf("trip-1")))
                .let { it.selectedTripId to it.hudLauncherMode },
        )
        // Gone: drop both.
        assertEquals(
            null to null,
            TripContextRules.reconcile("trip-1", "Growth", knowledge(active = setOf("trip-2")))
                .let { it.selectedTripId to it.hudLauncherMode },
        )
        // A HUD mode without a trip never survives, whatever is known.
        assertEquals(
            null to null,
            TripContextRules.reconcile(null, "Growth", unknown).let { it.selectedTripId to it.hudLauncherMode },
        )
    }
}
