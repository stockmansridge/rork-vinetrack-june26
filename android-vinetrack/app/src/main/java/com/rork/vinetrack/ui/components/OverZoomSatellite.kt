package com.rork.vinetrack.ui.components

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import android.util.LruCache
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import com.google.android.gms.maps.model.Tile
import com.google.android.gms.maps.model.TileProvider
import com.google.maps.android.compose.GoogleMapComposable
import com.google.maps.android.compose.TileOverlay
import com.rork.vinetrack.data.SatelliteTileHeuristics
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicInteger

/** Required credit line for the Esri World Imagery tile service. */
const val SATELLITE_IMAGERY_ATTRIBUTION = "Imagery: Esri, Maxar, Earthstar Geographics"

private const val TAG = "OverZoomSatellite"
private const val TILE_SIZE = 256

/** Highest zoom level requested from the imagery service directly. */
private const val MAX_NATIVE_ZOOM = 19

/**
 * Lowest zoom level worth falling back to when native tiles are missing. Kept
 * low so a camera that ends up regional (or at the world default) still shows
 * imagery instead of an empty canvas.
 */
private const val MIN_FALLBACK_ZOOM = 3

/** What happened the last time the layer asked for a tile. */
enum class SatelliteTileStatus {
    /** Imagery was served (natively or upscaled from a parent tile). */
    OK,

    /** Network/transport failure — the SDK will retry. */
    NETWORK_ERROR,

    /** The service has no imagery here at any zoom level. */
    NO_IMAGERY,
}

/**
 * Satellite tile provider with iOS-style "over-zoom".
 *
 * Google's own satellite/hybrid base map hard-stops the camera at the local
 * imagery limit (often z18–19 over rural vineyards), which makes precise
 * boundary-point placement impossible. MapKit on iOS instead keeps zooming and
 * simply upscales the imagery. This provider reproduces that behaviour: beyond
 * the best natively available tile, the parent tile is cropped to the requested
 * quadrant and bilinearly upscaled.
 *
 * Two rules keep the map from ever going grey:
 *  1. Esri answers HTTP 200 with a flat "Map data not yet available" grey
 *     placeholder past the local level of detail. Those tiles are detected
 *     ([SatelliteTileHeuristics]) and treated as missing, so the provider walks
 *     down a zoom level and upscales real imagery instead.
 *  2. The highest zoom that actually returned imagery is remembered, so the
 *     placeholder is requested at most once per level instead of on every tile.
 *
 * Tiles are served by Esri World Imagery, which permits app use with
 * attribution ([SATELLITE_IMAGERY_ATTRIBUTION]).
 */
class OverZoomSatelliteTileProvider(
    private val onStatus: (SatelliteTileStatus) -> Unit = {},
) : TileProvider {

    /** Decoded native tiles; parents are reused by all four over-zoomed children. */
    private val cache = LruCache<String, Bitmap>(64)

    /** Tiles the service answered with the grey placeholder. */
    private val unavailable = LruCache<String, Boolean>(512)

    /** Highest zoom that has actually produced imagery in this session. */
    private val learnedMaxZoom = AtomicInteger(MAX_NATIVE_ZOOM)

    override fun getTile(x: Int, y: Int, zoom: Int): Tile? {
        return try {
            val best = bestNativeBitmap(x, y, zoom)
            if (best == null) {
                onStatus(SatelliteTileStatus.NO_IMAGERY)
                return TileProvider.NO_TILE
            }
            val (bitmap, nativeZoom) = best
            val rendered = if (nativeZoom == zoom) bitmap else overZoom(bitmap, x, y, zoom, nativeZoom)
            if (rendered == null) {
                onStatus(SatelliteTileStatus.NO_IMAGERY)
                TileProvider.NO_TILE
            } else {
                onStatus(SatelliteTileStatus.OK)
                Tile(TILE_SIZE, TILE_SIZE, encode(rendered))
            }
        } catch (t: Throwable) {
            // Transient (network) failure — returning null lets the SDK retry.
            Log.w(TAG, "tile $zoom/$x/$y failed: ${t.message}")
            onStatus(SatelliteTileStatus.NETWORK_ERROR)
            null
        }
    }

    /**
     * Fetches the best natively available tile covering the requested tile,
     * walking down zoom levels when imagery is missing (or is the grey "no
     * data" placeholder) at the preferred one. Returns the bitmap plus the zoom
     * level it was actually fetched at.
     */
    private fun bestNativeBitmap(x: Int, y: Int, zoom: Int): Pair<Bitmap, Int>? {
        var z = minOf(zoom, learnedMaxZoom.get())
        while (z >= MIN_FALLBACK_ZOOM) {
            val shift = zoom - z
            val bitmap = fetch(x shr shift, y shr shift, z)
            if (bitmap != null) return bitmap to z
            z--
        }
        return null
    }

    /** Crops the requested quadrant out of an ancestor tile and upscales it. */
    private fun overZoom(parent: Bitmap, x: Int, y: Int, zoom: Int, parentZoom: Int): Bitmap? {
        val dz = zoom - parentZoom
        if (dz <= 0 || dz > 7) return null
        val sub = TILE_SIZE shr dz
        if (sub < 2) return null
        val offX = (x - ((x shr dz) shl dz)) * sub
        val offY = (y - ((y shr dz) shl dz)) * sub
        val cropped = Bitmap.createBitmap(parent, offX, offY, sub, sub)
        return Bitmap.createScaledBitmap(cropped, TILE_SIZE, TILE_SIZE, true)
    }

    /**
     * Downloads and decodes one native tile. Returns null when the service has
     * no imagery for the tile — either a 404 or the grey placeholder image —
     * so the caller keeps falling back; throws on transient errors so the SDK
     * retries instead of caching an empty tile.
     */
    private fun fetch(x: Int, y: Int, z: Int): Bitmap? {
        val key = "$z/$y/$x"
        cache.get(key)?.let { return it }
        if (unavailable.get(key) == true) return null
        val url = URL("https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/$z/$y/$x")
        val connection = url.openConnection() as HttpURLConnection
        connection.connectTimeout = 8_000
        connection.readTimeout = 8_000
        try {
            when (val code = connection.responseCode) {
                HttpURLConnection.HTTP_OK -> Unit
                HttpURLConnection.HTTP_NOT_FOUND, HttpURLConnection.HTTP_BAD_REQUEST -> {
                    unavailable.put(key, true)
                    return null
                }
                else -> throw IOException("HTTP $code")
            }
            val bytes = connection.inputStream.use { it.readBytes() }
            if (bytes.isEmpty()) return null
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
            if (isPlaceholder(bitmap)) {
                // "Map data not yet available" — imagery stops below this zoom.
                unavailable.put(key, true)
                learnedMaxZoom.updateAndGet { current ->
                    if (z <= current) maxOf(z - 1, MIN_FALLBACK_ZOOM) else current
                }
                Log.i(TAG, "no imagery at z$z — upscaling from z${z - 1} instead")
                return null
            }
            cache.put(key, bitmap)
            return bitmap
        } finally {
            connection.disconnect()
        }
    }

    /** Samples the decoded tile and asks the shared heuristic about it. */
    private fun isPlaceholder(bitmap: Bitmap): Boolean {
        val step = 16
        val width = bitmap.width
        val height = bitmap.height
        if (width < step || height < step) return false
        val columns = width / step
        val rows = height / step
        val pixels = IntArray(columns * rows)
        var index = 0
        for (row in 0 until rows) {
            for (column in 0 until columns) {
                pixels[index++] = bitmap.getPixel(column * step, row * step)
            }
        }
        return SatelliteTileHeuristics.isUnavailableTile(pixels)
    }

    private fun encode(bitmap: Bitmap): ByteArray {
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
        return out.toByteArray()
    }
}

/**
 * Drop-in satellite layer for editor maps that need to zoom past Google's
 * satellite imagery limit.
 *
 * Draw it OVER a real Google base map (`MapType.NORMAL`) rather than
 * `MapType.NONE`: when imagery is momentarily unavailable the base map stays
 * visible instead of leaving the user on an empty grey canvas. Show
 * [SATELLITE_IMAGERY_ATTRIBUTION] nearby.
 */
@Composable
@GoogleMapComposable
fun OverZoomSatelliteLayer(onStatus: (SatelliteTileStatus) -> Unit = {}) {
    val listener = rememberUpdatedState(onStatus)
    val provider = remember { OverZoomSatelliteTileProvider { listener.value(it) } }
    TileOverlay(tileProvider = provider, zIndex = -1f, fadeIn = true)
}
