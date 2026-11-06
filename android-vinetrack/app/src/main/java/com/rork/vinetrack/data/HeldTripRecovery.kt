package com.rork.vinetrack.data

/**
 * Explains why this device refuses to start a new Trip when no active Trip is
 * on screen.
 *
 * [ActiveTripStore] keeps the single on-device Trip claim until every queued
 * change for it (including a locally ended Trip's TRIP_END) has synced. The
 * active-Trip view, however, hides a Trip that was ended on this device, one
 * owned by another vineyard or account, or one that could not be restored.
 * Without this, the operator sees a Start Trip button that always refuses
 * ("you already have an active trip") and no way to find that Trip.
 *
 * Read-only: classifying never clears, replaces or replays anything. The
 * retained claim stays authoritative until its own sync finishes.
 */
object HeldTripRecovery {

    enum class Reason {
        /** Ended on this device; the end (and its route/rows/tanks) is still syncing. */
        END_SYNCING,
        /** The saved active Trip belongs to a different vineyard than the selected one. */
        OTHER_VINEYARD,
        /** The saved active Trip was started by a different signed-in account. */
        OTHER_ACCOUNT,
        /** A claim exists but its saved Trip could not be read. */
        UNREADABLE,
        /** Same account and vineyard, still active, but not restored into the Trip list. */
        NOT_SHOWN,
    }

    data class Held(
        val reason: Reason,
        val tripId: String?,
        val vineyardId: String?,
        val tripLabel: String?,
        val startTime: String?,
        val savedAtMs: Long?,
    )

    /**
     * @param hasClaim [ActiveTripStore.hasActiveClaim] — true when a new Trip is refused.
     * @param snapshot the decoded claim, or null when none / unreadable.
     * @param visibleActiveTripId the Trip shown as active right now ([com.rork.vinetrack.ui.AppUiState.activeTrip]).
     * @param endedLocally true when this Trip has an unresolved TRIP_END marker or
     *   is in the session's locally-ended set.
     */
    fun classify(
        hasClaim: Boolean,
        snapshot: ActiveTripStore.Snapshot?,
        signedInUserId: String?,
        selectedVineyardId: String?,
        visibleActiveTripId: String?,
        endedLocally: Boolean,
    ): Held? {
        if (!hasClaim) return null
        if (snapshot == null) return Held(Reason.UNREADABLE, null, null, null, null, null)
        val trip = snapshot.trip
        if (!trip.isActive) return null
        if (trip.id == visibleActiveTripId && !endedLocally) return null
        val reason = when {
            snapshot.ownerUserId != signedInUserId -> Reason.OTHER_ACCOUNT
            snapshot.vineyardId != selectedVineyardId -> Reason.OTHER_VINEYARD
            endedLocally -> Reason.END_SYNCING
            else -> Reason.NOT_SHOWN
        }
        return Held(reason, trip.id, snapshot.vineyardId, trip.displayLabel, trip.startTime, snapshot.savedAt)
    }

    /** Message shown when Start Trip is refused. Always points at the recovery card. */
    fun startBlockedMessage(held: Held, vineyardName: String?): String = when (held.reason) {
        Reason.END_SYNCING ->
            "Your last Trip was ended on this device and is still syncing. A new Trip can start once it has synced. " +
                "Open Trips and tap Sync now on the \"Trip still syncing\" card."
        Reason.OTHER_VINEYARD ->
            "Trip already in progress in ${vineyardName ?: "another vineyard"}. Tap Open Trip on the Trips screen to go back to it, then finish it before starting another."
        Reason.OTHER_ACCOUNT ->
            "Trip already in progress. This device already has an active Trip started by another account. Sign back in as the operator who started it, or finish that Trip before starting another."
        Reason.UNREADABLE ->
            "Saved Trip evidence could not be read. Keep this installation and recover/sync the original Trip before starting another. Copy diagnostics from the Trips screen and send them to support."
        Reason.NOT_SHOWN ->
            "Trip already in progress on this device. Tap Open Trip on the Trips screen to restore it, then finish it before starting another."
    }

    fun cardTitle(reason: Reason): String = when (reason) {
        Reason.END_SYNCING -> "Trip still syncing"
        Reason.OTHER_VINEYARD -> "Trip in progress in another vineyard"
        Reason.OTHER_ACCOUNT -> "Trip started by another account"
        Reason.UNREADABLE -> "Saved Trip needs recovery"
        Reason.NOT_SHOWN -> "Trip in progress"
    }

    fun cardMessage(reason: Reason, vineyardName: String?): String = when (reason) {
        Reason.END_SYNCING ->
            "This Trip was ended on this device. Its route, rows and labour are saved here and will upload when connected. " +
                "You can start a new Trip once it has synced. Do not uninstall the app or clear its data."
        Reason.OTHER_VINEYARD ->
            "This device has an active Trip in ${vineyardName ?: "another vineyard"}. Open it to continue or finish it."
        Reason.OTHER_ACCOUNT ->
            "This device has an active Trip started by another account. Sign in as that operator to finish it."
        Reason.UNREADABLE ->
            "A Trip saved on this device couldn't be read. Its data is kept. Do not uninstall the app or clear its data. Copy diagnostics and send them to support."
        Reason.NOT_SHOWN ->
            "This device has an active Trip that isn't showing yet. Tap Open Trip to reload it."
    }
}
