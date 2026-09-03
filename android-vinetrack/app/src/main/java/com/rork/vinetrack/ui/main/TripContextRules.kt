package com.rork.vinetrack.ui.main

/**
 * What the app currently knows about the trip list.
 *
 * Deliberately carries no [com.rork.vinetrack.data.Trip] objects — only IDs —
 * so the trip rules stay pure and testable off-device.
 *
 * [knownIds] being empty means "no evidence", NOT "no trips": immediately after
 * process death the list is empty because nothing has loaded yet, and that is
 * indistinguishable from a vineyard whose trips were all deleted. Every rule
 * below therefore acts only on positive evidence.
 */
data class TripsKnowledge(
    val knownIds: Set<String>,
    val activeIds: Set<String>,
) {
    /** True once the trip list can actually answer questions about a trip. */
    val isInformative: Boolean get() = knownIds.isNotEmpty()

    companion object {
        val Unknown = TripsKnowledge(emptySet(), emptySet())
    }
}

/** The reconciled trip part of the work context. */
data class TripContext(
    val selectedTripId: String?,
    val hudLauncherMode: String?,
)

/**
 * The invariant tying the live-trip HUD launcher to the trip that hosts it.
 *
 * `hudLauncherMode` is only meaningful while there is a selected, *active*
 * trip: the launcher is drawn over that trip's live map. If the trip is gone
 * or has ended, a surviving HUD mode is stale — it would hold the screen awake
 * for a workflow the operator cannot see.
 *
 * Kept pure and separate from [WorkContextViewModel] so the restore-path
 * behaviour can be asserted directly.
 */
object TripContextRules {

    fun reconcile(
        selectedTripId: String?,
        hudLauncherMode: String?,
        knowledge: TripsKnowledge,
    ): TripContext {
        // No trip to host the HUD launcher — it cannot outlive the selection.
        if (selectedTripId == null) return TripContext(null, null)

        // Nothing loaded yet. Restoration runs through here before the trip
        // list arrives, so clearing on absence would destroy exactly the state
        // this pass exists to preserve. Wait for evidence.
        if (!knowledge.isInformative) return TripContext(selectedTripId, hudLauncherMode)

        // The trip is genuinely gone (deleted here or on another device).
        if (selectedTripId !in knowledge.knownIds) return TripContext(null, null)

        // The trip still exists but has ended: its detail view is fine to keep,
        // the live-HUD launcher is not.
        if (selectedTripId !in knowledge.activeIds) return TripContext(selectedTripId, null)

        return TripContext(selectedTripId, hudLauncherMode)
    }
}
