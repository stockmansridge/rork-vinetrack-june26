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
 * not carry. The server always wins wherever it actually states a value.
 *
 * Local-only work in flight (a photo captured but not yet uploaded, notes typed
 * offline) is likewise retained when the response omits it.
 *
 * See docs/core-pin-location-contract.md.
 */
object PinReplayMerge {

    /** Server pin, refilled with local values it left blank. */
    fun merge(server: Pin, local: Pin?): Pin {
        if (local == null || local.id != server.id) return server
        return server.copy(
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
    }
}
