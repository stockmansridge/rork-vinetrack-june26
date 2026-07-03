package com.rork.vinetrack.ui.components

import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.LatLngBounds
import com.google.maps.android.compose.CameraPositionState
import kotlin.coroutines.cancellation.CancellationException

/**
 * True when [lat]/[lng] form a plausible real-world coordinate. Rejects null
 * island (0,0) which shows up when a device writes an empty GPS fix.
 */
fun isValidMapCoordinate(lat: Double?, lng: Double?): Boolean {
    return lat != null && lng != null &&
        lat in -90.0..90.0 && lng in -180.0..180.0 &&
        !(lat == 0.0 && lng == 0.0)
}

/** Filters out invalid / null-island coordinates before camera framing. */
fun List<LatLng>.validMapPoints(): List<LatLng> =
    filter { isValidMapCoordinate(it.latitude, it.longitude) }

/**
 * Frames the camera on [points]: fits bounds when there are several points and
 * centres at [singlePointZoom] for a single point. Invalid coordinates are
 * ignored. Must be called only after the GoogleMap has loaded (`onMapLoaded`) —
 * `newLatLngBounds` throws if the map has no measured size. If the bounds
 * update is still rejected, falls back to centring on the bounds centre so the
 * camera never stays at the world-default position.
 */
suspend fun CameraPositionState.fitToContent(
    points: List<LatLng>,
    paddingPx: Int = 120,
    singlePointZoom: Float = 17f,
    animate: Boolean = false,
) {
    val valid = points.validMapPoints()
    if (valid.isEmpty()) return

    suspend fun apply(update: com.google.android.gms.maps.CameraUpdate): Boolean {
        return try {
            if (animate) animate(update, 600) else move(update)
            true
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            false
        }
    }

    if (valid.size == 1) {
        apply(CameraUpdateFactory.newLatLngZoom(valid.first(), singlePointZoom))
        return
    }

    val bounds = try {
        LatLngBounds.builder().apply { valid.forEach { include(it) } }.build()
    } catch (_: Exception) {
        return
    }
    if (!apply(CameraUpdateFactory.newLatLngBounds(bounds, paddingPx))) {
        // Map not measured yet — at least centre on the content.
        apply(CameraUpdateFactory.newLatLngZoom(bounds.center, singlePointZoom))
    }
}
