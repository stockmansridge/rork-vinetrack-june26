package com.rork.vinetrack.ui.components

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import android.util.LruCache
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import com.google.android.gms.maps.model.Tile
import com.google.android.gms.maps.model.TileProvider
import com.google.maps.android.compose.GoogleMapComposable
import com.google.maps.android.compose.TileOverlay
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/** Required credit line for the Esri World Imagery tile service. */
const val SATELLITE_IMAGERY_ATTRIBUTION = "Imagery: Esri, Maxar, Earthstar Geographics"

private const val TAG = "OverZoomSatellite"
private const val TILE_SIZE = 256

/** Highest zoom level requested from the imagery service directly. */
private const val MAX_NATIVE_ZOOM = 19

/** Lowest zoom level worth falling back to when native tiles are missing. */
private const val MIN_FALLBACK_ZOOM = 12

/**
 * Satellite tile provider with iOS-style "over-zoom".
 *
 * Google's own satellite/hybrid base map hard-stops the camera at the local
 * imagery limit (often z18–19 over rural vineyards), which makes precise
 * boundary-point placement impossible. MapKit on iOS instead keeps zooming and
 * simply upscales the imagery. This provider reproduces that behaviour: beyond
 * the best natively available tile, the parent tile is cropped to the requested
 * quadrant and bilinearly upscaled, so the camera (running on `MapType.NONE`,
 * which has no imagery-based zoom cap) can keep zooming to the SDK maximum.
 *
 * Tiles are served by Esri World Imagery, which permits app use with
 * attribution ([SATELLITE_IMAGERY_ATTRIBUTION]).
 */
class OverZoomSatelliteTileProvider : TileProvider {

    /** Decoded native tiles; parents are reused by all four over-zoomed children. */
    private val cache = LruCache<String, Bitmap>(64)

    override fun getTile(x: Int, y: Int, zoom: Int): Tile? {
        return try {
            val (bitmap, nativeZoom) = bestNativeBitmap(x, y, zoom) ?: return TileProvider.NO_TILE
            val rendered = if (nativeZoom == zoom) bitmap else overZoom(bitmap, x, y, zoom, nativeZoom)
            if (rendered == null) TileProvider.NO_TILE else Tile(TILE_SIZE, TILE_SIZE, encode(rendered))
        } catch (t: Throwable) {
            // Transient (network) failure — returning null lets the SDK retry later.
            Log.w(TAG, "tile $zoom/$x/$y failed: ${t.message}")
            null
        }
    }

    /**
     * Fetches the best natively available tile covering the requested tile,
     * walking down zoom levels when imagery is missing at the preferred one.
     * Returns the bitmap plus the zoom level it was actually fetched at.
     */
    private fun bestNativeBitmap(x: Int, y: Int, zoom: Int): Pair<Bitmap, Int>? {
        var z = minOf(zoom, MAX_NATIVE_ZOOM)
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
     * no imagery for the tile (fallback continues at a lower zoom); throws on
     * transient errors so the SDK retries instead of caching an empty tile.
     */
    private fun fetch(x: Int, y: Int, z: Int): Bitmap? {
        val key = "$z/$y/$x"
        cache.get(key)?.let { return it }
        val url = URL("https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/$z/$y/$x")
        val connection = url.openConnection() as HttpURLConnection
        connection.connectTimeout = 8_000
        connection.readTimeout = 8_000
        try {
            when (val code = connection.responseCode) {
                HttpURLConnection.HTTP_OK -> Unit
                HttpURLConnection.HTTP_NOT_FOUND, HttpURLConnection.HTTP_BAD_REQUEST -> return null
                else -> throw IOException("HTTP $code")
            }
            val bytes = connection.inputStream.use { it.readBytes() }
            if (bytes.isEmpty()) return null
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
            cache.put(key, bitmap)
            return bitmap
        } finally {
            connection.disconnect()
        }
    }

    private fun encode(bitmap: Bitmap): ByteArray {
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
        return out.toByteArray()
    }
}

/**
 * Drop-in satellite base layer for editor maps that need to zoom past Google's
 * satellite imagery limit. Use together with `MapType.NONE` so the camera is
 * not capped by the base map, and show [SATELLITE_IMAGERY_ATTRIBUTION] nearby.
 */
@Composable
@GoogleMapComposable
fun OverZoomSatelliteLayer() {
    val provider = remember { OverZoomSatelliteTileProvider() }
    TileOverlay(tileProvider = provider, zIndex = -1f, fadeIn = true)
}
