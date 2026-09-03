package com.rork.vinetrack.ui.main

/**
 * How much the app can trust the current trip list.
 *
 * The distinction that matters is provenance, not size: an empty list means
 * completely different things depending on where it came from, and only a
 * fresh server read can prove that a missing trip was actually deleted.
 */
enum class TripsListKnowledge {
    /** Nothing trustworthy has loaded yet (process death, first frame, sign-in). */
    Unknown,

    /**
     * A cached / stale / partially-restored list. Good enough to render, never
     * proof of absence: it can legitimately be missing a trip that still exists
     * on the server, so a missing trip must NOT be treated as deleted.
     */
    Cached,

    /**
     * A successful fresh server read — including a legitimately empty result.
     * This is the only state in which absence is evidence of deletion.
     */
    Authoritative,
}

/**
 * What the app currently knows about the trip list.
 *
 * Deliberately carries no [com.rork.vinetrack.data.Trip] objects — only IDs and
 * provenance — so the trip rules stay pure and testable off-device.
 *
 * Provenance is carried explicitly in [listKnowledge] rather than inferred from
 * whether [knownIds] is empty. The old `knownIds.isNotEmpty()` heuristic could
 * not tell "trips haven't loaded yet" from "the server authoritatively returned
 * zero trips", so deleting a vineyard's ONLY trip left a stale selected trip and
 * a stale HUD launcher alive — invisibly holding the screen awake. It also
 * treated any non-empty cached list as proof that a missing trip was deleted,
 * which it is not.
 */
data class TripsKnowledge(
    val knownIds: Set<String>,
    val activeIds: Set<String>,
    val listKnowledge: TripsListKnowledge,
    /**
     * Trips this device itself removed (an optimistic or queued offline delete).
     * Genuine local positive evidence, so it acts immediately without waiting
     * for a server round-trip — a locally deleted trip is gone even offline.
     */
    val locallyRemovedIds: Set<String> = emptySet(),
) {
    /** True only when a missing trip can be trusted to mean a deleted trip. */
    val provesAbsence: Boolean get() = listKnowledge == TripsListKnowledge.Authoritative

    companion object {
        val Unknown = TripsKnowledge(emptySet(), emptySet(), TripsListKnowledge.Unknown)
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

        // This device deleted it. Local evidence is positive and immediate, so
        // it doesn't wait on a server read (the delete may still be queued).
        if (selectedTripId in knowledge.locallyRemovedIds) return TripContext(null, null)

        // Present in the list: the list itself is the evidence, whatever its
        // provenance. A cached list that CONTAINS the trip still tells the truth
        // about whether it is active, so a locally-ended trip drops its live
        // launcher immediately, offline included.
        if (selectedTripId in knowledge.knownIds) {
            // Exists but has ended: its detail view is fine to keep, the
            // live-HUD launcher is not.
            if (selectedTripId !in knowledge.activeIds) return TripContext(selectedTripId, null)
            return TripContext(selectedTripId, hudLauncherMode)
        }

        // Absent from the list. Only a fresh server result can prove that means
        // deleted — and a fresh EMPTY result proves it just as well as a fresh
        // non-empty one, which is exactly the last-trip-deleted case.
        if (knowledge.provesAbsence) return TripContext(null, null)

        // Unknown or cached: absence is not proof. Restoration runs through here
        // before the trip list arrives, so clearing now would destroy exactly
        // the state this pass exists to preserve. Wait for evidence.
        return TripContext(selectedTripId, hudLauncherMode)
    }
}
