package com.rork.vinetrack.data

import androidx.lifecycle.SavedStateHandle
import com.rork.vinetrack.ui.components.ScreenAwakeController
import com.rork.vinetrack.ui.main.MainSurface
import com.rork.vinetrack.ui.main.MainTab
import com.rork.vinetrack.ui.main.PinWorkflow
import com.rork.vinetrack.ui.main.TripContextRules
import com.rork.vinetrack.ui.main.TripsKnowledge
import com.rork.vinetrack.ui.main.TripsListKnowledge
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

    /**
     * Trip list state: [active] are recording, [ended] exist but are finished.
     *
     * Defaults to a fresh server read, because that is what the app has once the
     * list has loaded. Provenance is passed explicitly wherever it is the thing
     * under test.
     */
    private fun knowledge(
        active: Set<String> = emptySet(),
        ended: Set<String> = emptySet(),
        listKnowledge: TripsListKnowledge = TripsListKnowledge.Authoritative,
        locallyRemoved: Set<String> = emptySet(),
    ) = TripsKnowledge(
        knownIds = active + ended,
        activeIds = active,
        listKnowledge = listKnowledge,
        locallyRemovedIds = locallyRemoved,
    )

    /** The reconciled (trip, HUD mode) pair, for the pure-rule assertions. */
    private fun reconciled(
        selectedTripId: String?,
        hudLauncherMode: String?,
        knowledge: TripsKnowledge,
    ): Pair<String?, String?> = TripContextRules.reconcile(selectedTripId, hudLauncherMode, knowledge)
        .let { it.selectedTripId to it.hudLauncherMode }

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
        assertEquals("trip-1" to "Growth", reconciled("trip-1", "Growth", unknown))
        // Known and active: change nothing.
        assertEquals("trip-1" to "Growth", reconciled("trip-1", "Growth", knowledge(active = setOf("trip-1"))))
        // Known but ended: keep the trip, drop the live launcher.
        assertEquals("trip-1" to null, reconciled("trip-1", "Growth", knowledge(ended = setOf("trip-1"))))
        // Gone: drop both.
        assertEquals(null to null, reconciled("trip-1", "Growth", knowledge(active = setOf("trip-2"))))
        // A HUD mode without a trip never survives, whatever is known.
        assertEquals(null to null, reconciled(null, "Growth", unknown))
    }

    // ---- Provenance: an empty trip list means nothing without its origin ----
    //
    // The bug these pin down: `isInformative = knownIds.isNotEmpty()` could not
    // tell "trips haven't loaded" from "the server says there are none", so
    // deleting a vineyard's only trip left the selection and the HUD alive.

    // 1. Unknown + empty: initial restoration, nothing may be cleared.
    @Test
    fun `an empty list that has not loaded yet preserves the trip and its HUD`() {
        val handle = SavedStateHandle()
        WorkContextViewModel(handle).enterTripHud("trip-42", "Growth")

        val restored = recreate(handle)
        restored.reconcileTripContext(
            knowledge(listKnowledge = TripsListKnowledge.Unknown),
        )

        assertEquals("trip-42", restored.selectedTripId.value)
        assertEquals(MainSurface.TripTab("trip-42", "Growth"), surfaceOf(restored))
    }

    // 2. Cached + empty: an offline start with nothing cached is not a verdict.
    @Test
    fun `an empty cached list preserves the trip and its HUD`() {
        val handle = SavedStateHandle()
        WorkContextViewModel(handle).enterTripHud("trip-42", "Growth")

        val restored = recreate(handle)
        restored.reconcileTripContext(
            knowledge(listKnowledge = TripsListKnowledge.Cached),
        )

        assertEquals("trip-42", restored.selectedTripId.value)
        assertEquals(MainSurface.TripTab("trip-42", "Growth"), surfaceOf(restored))
    }

    // 3. Cached + non-empty but missing the trip: still not proof of deletion.
    @Test
    fun `a cached list missing the selected trip is not read as a deletion`() {
        val handle = SavedStateHandle()
        WorkContextViewModel(handle).enterTripHud("trip-42", "Growth")

        val restored = recreate(handle)
        // A partial/stale cache legitimately omits trips that still exist.
        restored.reconcileTripContext(
            knowledge(
                active = setOf("trip-99"),
                ended = setOf("trip-7"),
                listKnowledge = TripsListKnowledge.Cached,
            ),
        )

        assertEquals("trip-42", restored.selectedTripId.value)
        assertEquals("Growth", restored.tripHudLauncherMode.value)
        assertEquals(MainSurface.TripTab("trip-42", "Growth"), surfaceOf(restored))
    }

    // 4. Authoritative + empty: the reported bug. The vineyard's ONLY trip was
    //    deleted from another device; a fresh server read correctly returns [].
    @Test
    fun `a fresh empty server list clears the last trip and its HUD`() {
        val handle = SavedStateHandle()
        WorkContextViewModel(handle).enterTripHud("trip-42", "Growth")

        val restored = recreate(handle)
        restored.reconcileTripContext(
            knowledge(listKnowledge = TripsListKnowledge.Authoritative),
        )

        assertNull("a fresh empty result proves the trip is gone", restored.selectedTripId.value)
        assertNull(restored.tripHudLauncherMode.value)
        assertNull(restored.pinWorkflow.value)
        assertFalse("nothing may hold the display awake invisibly", forcesScreenAwake(restored))
        assertEquals(MainSurface.TripTab(null, null), surfaceOf(restored))
    }

    // 5. Authoritative + non-empty, trip absent (the existing trip-99 case,
    //    now stated in terms of provenance).
    @Test
    fun `a fresh server list missing the selected trip clears it and its HUD`() {
        val handle = SavedStateHandle()
        WorkContextViewModel(handle).enterTripHud("trip-42", "Growth")

        val restored = recreate(handle)
        restored.reconcileTripContext(
            knowledge(active = setOf("trip-99"), listKnowledge = TripsListKnowledge.Authoritative),
        )

        assertNull(restored.selectedTripId.value)
        assertNull(restored.tripHudLauncherMode.value)
        assertFalse(forcesScreenAwake(restored))
        assertEquals(MainSurface.TripTab(null, null), surfaceOf(restored))
    }

    // 6. Authoritative, trip present but ended: keep the trip, drop the HUD.
    @Test
    fun `a fresh server list showing the trip ended keeps the trip and clears the HUD`() {
        val handle = SavedStateHandle()
        WorkContextViewModel(handle).enterTripHud("trip-42", "Growth")

        val restored = recreate(handle)
        restored.reconcileTripContext(
            knowledge(ended = setOf("trip-42"), listKnowledge = TripsListKnowledge.Authoritative),
        )

        assertEquals("trip-42", restored.selectedTripId.value)
        assertNull(restored.tripHudLauncherMode.value)
        assertFalse(forcesScreenAwake(restored))
        assertEquals(MainSurface.TripTab("trip-42", null), surfaceOf(restored))
    }

    // 7. Authoritative, trip still active: retain both.
    @Test
    fun `a fresh server list showing the trip still active retains both`() {
        val handle = SavedStateHandle()
        WorkContextViewModel(handle).enterTripHud("trip-42", "Growth")

        val restored = recreate(handle)
        restored.reconcileTripContext(
            knowledge(active = setOf("trip-42"), listKnowledge = TripsListKnowledge.Authoritative),
        )

        assertEquals("trip-42", restored.selectedTripId.value)
        assertEquals("Growth", restored.tripHudLauncherMode.value)
        assertEquals(MainSurface.TripTab("trip-42", "Growth"), surfaceOf(restored))
    }

    // Local evidence still acts immediately, without waiting on the server.
    @Test
    fun `a trip this device deleted clears immediately even on a cached list`() {
        val handle = SavedStateHandle()
        WorkContextViewModel(handle).enterTripHud("trip-42", "Repairs")

        val restored = recreate(handle)
        // Deleted here while offline: the delete marker is queued, so no fresh
        // server list is coming, but this device knows perfectly well it's gone.
        restored.reconcileTripContext(
            knowledge(
                active = setOf("trip-42"),
                listKnowledge = TripsListKnowledge.Cached,
                locallyRemoved = setOf("trip-42"),
            ),
        )

        assertNull(restored.selectedTripId.value)
        assertNull(restored.tripHudLauncherMode.value)
        assertFalse(forcesScreenAwake(restored))
    }

    @Test
    fun `a trip ended on this device drops its HUD immediately on a cached list`() {
        val handle = SavedStateHandle()
        WorkContextViewModel(handle).enterTripHud("trip-42", "Growth")

        val restored = recreate(handle)
        // Ended offline: the row is still "active" on the server, but the local
        // end marker means it is no longer live here — positive local evidence.
        restored.reconcileTripContext(
            knowledge(ended = setOf("trip-42"), listKnowledge = TripsListKnowledge.Cached),
        )

        assertEquals("trip-42", restored.selectedTripId.value)
        assertNull(restored.tripHudLauncherMode.value)
        assertFalse(forcesScreenAwake(restored))
    }

    // The provenance contract as a single table, exercised on the pure rule.
    @Test
    fun `only an authoritative list turns absence into deletion`() {
        val empty = emptySet<String>()

        for (state in listOf(TripsListKnowledge.Unknown, TripsListKnowledge.Cached)) {
            // Empty, not authoritative: preserve.
            assertEquals(
                "$state + empty must preserve",
                "trip-1" to "Growth",
                reconciled("trip-1", "Growth", knowledge(listKnowledge = state)),
            )
            // Non-empty, missing the trip, not authoritative: preserve.
            assertEquals(
                "$state + missing must preserve",
                "trip-1" to "Growth",
                reconciled("trip-1", "Growth", knowledge(active = setOf("trip-2"), listKnowledge = state)),
            )
        }

        val authoritative = TripsListKnowledge.Authoritative
        // Empty AND authoritative: the empty result is itself the evidence.
        assertEquals(
            null to null,
            reconciled("trip-1", "Growth", TripsKnowledge(empty, empty, authoritative)),
        )
        // Present and active: retained.
        assertEquals(
            "trip-1" to "Growth",
            reconciled("trip-1", "Growth", knowledge(active = setOf("trip-1"), listKnowledge = authoritative)),
        )
        // Present and ended: trip kept, launcher dropped.
        assertEquals(
            "trip-1" to null,
            reconciled("trip-1", "Growth", knowledge(ended = setOf("trip-1"), listKnowledge = authoritative)),
        )
        // A HUD mode with no trip is void at every knowledge level.
        for (state in TripsListKnowledge.entries) {
            assertEquals(null to null, reconciled(null, "Growth", knowledge(listKnowledge = state)))
        }
    }
}
