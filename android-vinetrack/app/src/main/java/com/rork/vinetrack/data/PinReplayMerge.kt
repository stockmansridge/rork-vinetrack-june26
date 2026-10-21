package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Pin

/**
 * Reconcile a replayed/refreshed server pin with the copy already held on the
 * device.
 *
 * A queued payload written before the driving-path column existed replays
 * successfully and comes back WITHOUT that column. Applying such a response
 * verbatim would silently erase location evidence the device already holds, so
 * the merge keeps every locally-known attachment value the server response does
 * not carry, but only for unconfirmed legacy rows. Confirmation revision and
 * then sync version choose complete location authority, including null/false.
 *
 * Local-only work in flight (a photo captured but not yet uploaded, notes typed
 * offline) is likewise retained when the response omits it.
 *
 * See docs/core-pin-location-contract.md.
 */
object PinReplayMerge {

    /** Server pin, refilled with local values it left blank. */
    fun merge(server: Pin, local: Pin?): Pin {
        if (local == null || local.id != server.id || !local.vineyardId.equals(server.vineyardId, true)) return server
        val merged = server.copy(
            // Location evidence: never downgraded to null by a thinner payload.
            paddockId = server.paddockId ?: local.paddockId,
            rowNumber = server.rowNumber ?: local.rowNumber,
            drivingRowNumber = server.drivingRowNumber ?: local.drivingRowNumber,
            pinRowNumber = server.pinRowNumber ?: local.pinRowNumber,
            pinSide = server.pinSide ?: local.pinSide,
            side = server.side ?: local.side,
            alongRowDistanceM = server.alongRowDistanceM ?: local.alongRowDistanceM,
            snappedLatitude = server.snappedLatitude ?: local.snappedLatitude,
            snappedLongitude = server.snappedLongitude ?: local.snappedLongitude,
            snappedToRow = server.snappedToRow || local.snappedToRow,
            heading = server.heading ?: local.heading,
            // The original observation and its capture time are immutable.
            latitude = server.latitude ?: local.latitude,
            longitude = server.longitude ?: local.longitude,
            createdAt = server.createdAt ?: local.createdAt,
            // Work in flight on this device.
            photoPath = server.photoPath ?: local.photoPath,
            notes = server.notes ?: local.notes,
            locationScope = server.locationScope ?: local.locationScope,
            rowSegments = server.rowSegments ?: local.rowSegments,
        )
        // A confirmed row is complete location authority: null/false can be an
        // intentional row-only correction, not a legacy omitted value.
        val authority = confirmedAuthority(server, local) ?: return merged
        return copyConfirmedLocation(merged, authority, local)
    }

    /** Keep candidate content, but independently apply the newest confirmed location. */
    internal fun preservingConfirmedLocation(candidate: Pin, other: Pin?): Pin {
        if (other == null || candidate.id != other.id || !candidate.vineyardId.equals(other.vineyardId, true)) return candidate
        val authority = confirmedAuthority(candidate, other) ?: return candidate
        return copyConfirmedLocation(candidate, authority, other)
    }

    private fun confirmedAuthority(first: Pin, second: Pin): Pin? {
        val a = first.locationConfirmationRevision ?: 0
        val b = second.locationConfirmationRevision ?: 0
        if (maxOf(a, b) <= 0) return null
        return when {
            a > b -> first
            b > a -> second
            (first.syncVersion ?: 0) >= (second.syncVersion ?: 0) -> first
            else -> second
        }
    }

    private fun copyConfirmedLocation(candidate: Pin, authority: Pin, other: Pin): Pin = candidate.copy(
        paddockId = authority.paddockId,
        rowNumber = authority.rowNumber,
        drivingRowNumber = authority.drivingRowNumber,
        pinRowNumber = authority.pinRowNumber,
        pinSide = authority.pinSide,
        side = authority.side,
        alongRowDistanceM = authority.alongRowDistanceM,
        snappedLatitude = authority.snappedLatitude,
        snappedLongitude = authority.snappedLongitude,
        snappedToRow = authority.snappedToRow,
        locationScope = authority.locationScope,
        rowSegments = authority.rowSegments,
        locationConfirmationRevision = authority.locationConfirmationRevision,
        syncVersion = listOfNotNull(candidate.syncVersion, other.syncVersion, authority.syncVersion).maxOrNull(),
    )
}
