package com.rork.vinetrack.data.mapalignment

/**
 * Android-only map alignment domain foundation.
 *
 * ## What this is
 *
 * A *display-time* translation that lets the Android satellite basemap be
 * nudged so it lines up with VineTrack's canonical vineyard geometry. Some
 * Android basemap tiles are georeferenced slightly differently to the imagery
 * Portal/iOS operate against, which makes correct canonical rows and pins look
 * offset from the imagery underneath them on this platform only.
 *
 * ## What this is NOT
 *
 * This is **not** a GPS correction system. It does not improve, adjust or
 * second-guess any location fix. It never changes canonical WGS84 data.
 *
 * ## The absolute coordinate invariant
 *
 * The aligned/display coordinate produced here may be used **only** for drawing
 * on the Android map. It must NEVER be written into domain data, persistence,
 * an outbox payload or a sync payload, and must never replace a canonical
 * coordinate. The canonical coordinate always remains the single stored truth
 * for vineyard boundaries, block boundaries, rows, pins, route/path points, GPS
 * capture and map-created geometry.
 *
 * Portal and iOS remain the canonical/master geographic representation of
 * VineTrack vineyard data; nothing in this package exists on those platforms.
 *
 * This first version is deliberately **translation only** — no rotation, scale,
 * skew, affine transform or arbitrary warping. Those will only be considered if
 * field evidence later proves them necessary.
 */

/**
 * An immutable geographic coordinate.
 *
 * The same type is used for a canonical WGS84 coordinate and for a derived
 * Android display coordinate; which one an instance holds is expressed by the
 * transform function that produced it, and by the variable it is stored in.
 * See [MapAlignmentTransform] for the one-way rule about which may be persisted.
 */
data class GeoCoordinate(
    val latitude: Double,
    val longitude: Double,
)

/** Optional classification of what a calibration/reference point was taken against. */
enum class MapAlignmentReferenceType {
    RowEnd,
    BlockCorner,
    Infrastructure,
    Landmark,
    Other,
}

/** Where along a row a reference point was captured. */
enum class MapAlignmentRowPosition {
    Start,
    Midpoint,
    End,
}

/**
 * A calibration/reference point: one physical place, recorded twice.
 *
 * [canonicalCoordinate] is the real GPS coordinate recorded while standing at
 * the location. [selectedMapCoordinate] is where the operator had to tap on the
 * Android satellite image for it to *look* like the same place. The difference
 * between the two is the evidence an alignment is later derived from.
 *
 * Capturing these is a later prompt — this pass only models them. Nothing here
 * is persisted or synced.
 */
data class MapAlignmentReferencePoint(
    val id: String,
    /** The canonical, physically-recorded WGS84 coordinate. Never modified. */
    val canonicalCoordinate: GeoCoordinate,
    /** The matching point the operator selected on the Android satellite image. */
    val selectedMapCoordinate: GeoCoordinate,
    /** Horizontal accuracy of the canonical fix, in metres, when reported. */
    val gpsAccuracyMetres: Double? = null,
    /** Epoch millis at which the canonical coordinate was captured. */
    val capturedAtEpochMillis: Long,
    val referenceType: MapAlignmentReferenceType? = null,
    val description: String? = null,
    val rowNumber: Int? = null,
    val rowPosition: MapAlignmentRowPosition? = null,
) {
    /**
     * Eastward component of this point's observed discrepancy, in metres.
     * Evidence only — it is not automatically applied to anything.
     */
    val observedEastOffsetMetres: Double
        get() = MapAlignmentTransform.eastMetresBetween(canonicalCoordinate, selectedMapCoordinate)

    /** Northward component of this point's observed discrepancy, in metres. */
    val observedNorthOffsetMetres: Double
        get() = MapAlignmentTransform.northMetresBetween(canonicalCoordinate, selectedMapCoordinate)
}

/**
 * A translation-only alignment for one vineyard on Android.
 *
 * [eastOffsetMetres] is positive toward the east, [northOffsetMetres] positive
 * toward the north. A disabled alignment, or one with both offsets at zero, is
 * exactly equivalent to current production behaviour.
 */
data class MapAlignment(
    val id: String,
    val vineyardId: String,
    /** Positive = shift display east. Metres. */
    val eastOffsetMetres: Double = 0.0,
    /** Positive = shift display north. Metres. */
    val northOffsetMetres: Double = 0.0,
    val isEnabled: Boolean = false,
    /** Incremented on every accepted edit, so later persistence can order writes. */
    val version: Int = 1,
    val createdAtEpochMillis: Long? = null,
    val updatedAtEpochMillis: Long? = null,
    val createdByUserId: String? = null,
    val updatedByUserId: String? = null,
) {
    /**
     * True when this alignment cannot move anything — either switched off, or
     * carrying a zero translation. Callers must treat this as "render exactly
     * as production does today".
     */
    val isIdentity: Boolean
        get() = !isEnabled || (eastOffsetMetres == 0.0 && northOffsetMetres == 0.0)

    /** Straight-line magnitude of the translation in metres, ignoring enablement. */
    val magnitudeMetres: Double
        get() = kotlin.math.sqrt(
            eastOffsetMetres * eastOffsetMetres + northOffsetMetres * northOffsetMetres,
        )

    companion object {
        /** The explicit "no alignment" value for a vineyard. Behaviourally invisible. */
        fun none(vineyardId: String, id: String = "none"): MapAlignment =
            MapAlignment(id = id, vineyardId = vineyardId)
    }
}

/**
 * Pure, side-effect-free conversion between canonical WGS84 coordinates and
 * Android display coordinates.
 *
 * No database access, no sync, no persistence, no Android framework types — so
 * it is fully unit-testable and can never mutate app state. Every function
 * returns a NEW [GeoCoordinate]; inputs are immutable and are never modified.
 *
 * ### Direction of travel
 *
 * ```
 * canonical (stored, synced, master)  --toDisplay-->  display (drawing only)
 * display (a map tap)                --toCanonical--> canonical (safe to store)
 * ```
 *
 * A map tap must be converted back with [toCanonical] before the resulting
 * coordinate is allowed anywhere near domain data.
 */
object MapAlignmentTransform {

    /**
     * Metres per degree of latitude. Matches the constant already used by
     * `PinAisleGeometry`'s local metric frame so alignment maths and existing
     * row geometry cannot drift apart. (That constant is private to its own
     * object; this is a deliberate, documented duplicate of the same value, not
     * a second convention.)
     */
    private const val METRES_PER_DEG_LAT = 111_320.0

    /**
     * Guard for the longitude scale. cos(latitude) collapses to zero at the
     * poles, which would divide by ~0 and produce a nonsensical longitude.
     * VineTrack vineyards are nowhere near this limit; the clamp exists purely
     * so a corrupt or extreme input can never yield infinity/NaN.
     */
    private const val MIN_COS_LATITUDE = 1e-6

    private fun metresPerDegLon(latitude: Double): Double {
        val cos = kotlin.math.cos(latitude * Math.PI / 180.0)
        val safeCos = if (kotlin.math.abs(cos) < MIN_COS_LATITUDE) MIN_COS_LATITUDE else kotlin.math.abs(cos)
        return METRES_PER_DEG_LAT * safeCos
    }

    /**
     * Forward transform: canonical WGS84 -> Android map display coordinate.
     *
     * The returned value is for RENDERING ONLY and must never be stored or
     * synced. Returns the input value unchanged when [alignment] is identity,
     * which is what guarantees a zero/disabled alignment is indistinguishable
     * from today's production behaviour.
     */
    fun toDisplay(canonical: GeoCoordinate, alignment: MapAlignment): GeoCoordinate {
        if (alignment.isIdentity) return canonical
        return translate(canonical, alignment.eastOffsetMetres, alignment.northOffsetMetres)
    }

    /**
     * Inverse transform: Android map display coordinate -> canonical WGS84.
     *
     * Exactly inverts [toDisplay]. Required later so a tap on an aligned map
     * resolves to the true canonical coordinate before anything is created.
     */
    fun toCanonical(display: GeoCoordinate, alignment: MapAlignment): GeoCoordinate {
        if (alignment.isIdentity) return display
        return translate(display, -alignment.eastOffsetMetres, -alignment.northOffsetMetres)
    }

    /**
     * Shared translation core.
     *
     * Latitude is resolved FIRST, then the longitude scale is taken from the
     * *resolved* latitude. That ordering is what makes [toCanonical] an exact
     * inverse of [toDisplay]: the forward call scales longitude by the source
     * latitude, and the inverse call reconstructs that same latitude before
     * undoing the longitude shift.
     */
    private fun translate(
        from: GeoCoordinate,
        eastMetres: Double,
        northMetres: Double,
    ): GeoCoordinate {
        val latitude = from.latitude + northMetres / METRES_PER_DEG_LAT
        // Scale longitude on the latitude the ORIGINAL forward call used, which
        // is `from.latitude` going forward and `latitude` coming back.
        val scaleLatitude = if (northMetres >= 0.0) from.latitude else latitude
        val longitude = from.longitude + eastMetres / metresPerDegLon(scaleLatitude)
        return GeoCoordinate(latitude = latitude, longitude = longitude)
    }

    /** Signed eastward metres from [origin] to [target]. Evidence/diagnostics only. */
    fun eastMetresBetween(origin: GeoCoordinate, target: GeoCoordinate): Double =
        (target.longitude - origin.longitude) * metresPerDegLon(origin.latitude)

    /** Signed northward metres from [origin] to [target]. Evidence/diagnostics only. */
    fun northMetresBetween(origin: GeoCoordinate, target: GeoCoordinate): Double =
        (target.latitude - origin.latitude) * METRES_PER_DEG_LAT
}
