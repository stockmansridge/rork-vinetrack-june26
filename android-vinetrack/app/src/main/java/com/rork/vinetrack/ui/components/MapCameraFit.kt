package com.rork.vinetrack.ui.components

import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.LatLngBounds
import com.google.maps.android.compose.CameraPositionState
import kotlin.coroutines.cancellation.CancellationException
import kotlin.math.cos
import kotlin.math.log2

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
 * Camera position centred on [points] with a zoom estimated from their span.
 * Unlike `newLatLngBounds`, this is safe to apply before the map has been laid
 * out, so the camera can be seeded on the vineyard the instant the screen
 * composes instead of showing the world-default (0,0) position while tiles
 * load and the precise bounds fit is still pending. Returns null when no
 * valid coordinates exist.
 */
fun estimatedCameraPosition(
    points: List<LatLng>,
    singlePointZoom: Float = 17f,
): CameraPosition? {
    val valid = points.validMapPoints()
    if (valid.isEmpty()) return null
    val minLat = valid.minOf { it.latitude }
    val maxLat = valid.maxOf { it.latitude }
    val minLng = valid.minOf { it.longitude }
    val maxLng = valid.maxOf { it.longitude }
    val center = LatLng((minLat + maxLat) / 2.0, (minLng + maxLng) / 2.0)
    // Effective angular span, correcting longitude for latitude compression.
    val latSpan = maxLat - minLat
    val lngSpan = (maxLng - minLng) * cos(Math.toRadians(center.latitude)).coerceAtLeast(0.1)
    val span = maxOf(latSpan, lngSpan)
    val zoom = if (span <= 0.0) {
        singlePointZoom
    } else {
        // The world spans 360° at zoom 0 and each level halves the visible
        // span; -1 keeps a comfortable margin around the content.
        (log2(360.0 / span) - 1.0).toFloat().coerceIn(3f, singlePointZoom)
    }
    return CameraPosition.fromLatLngZoom(center, zoom)
}

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
