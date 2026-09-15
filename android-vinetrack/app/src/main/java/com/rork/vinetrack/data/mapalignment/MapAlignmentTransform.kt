package com.rork.vinetrack.data.mapalignment

/**
 * Pure, side-effect-free conversion between canonical WGS84 coordinates and
 * Android display coordinates.
 *
 * No database access, no sync, no persistence, no Android framework types — so
 * it is fully unit-testable and can never mutate app state. Every function
 * returns a NEW value; inputs are immutable and are never modified.
 *
 * ### Direction of travel, enforced by the type system
 *
 * ```
 * CanonicalCoordinate       --toDisplay-->   AndroidDisplayCoordinate  (drawing only)
 * AndroidDisplayCoordinate  --toCanonical--> CanonicalCoordinate       (safe to store)
 * ```
 *
 * A map tap arrives as an [AndroidDisplayCoordinate] and MUST be converted with
 * [toCanonical] before the resulting coordinate goes anywhere near domain data.
 * Because the two are distinct types, skipping that step is a compile error
 * rather than a silent data-corruption bug.
 *
 * Nothing in this object is wired to a live map in this pass.
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
     * synced. Returns the same position unchanged when [alignment] is identity,
     * which is what guarantees a zero/disabled alignment is indistinguishable
     * from today's production behaviour.
     */
    fun toDisplay(canonical: CanonicalCoordinate, alignment: MapAlignment): AndroidDisplayCoordinate {
        if (alignment.isIdentity) {
            return AndroidDisplayCoordinate(canonical.latitude, canonical.longitude)
        }
        val (latitude, longitude) = translate(
            latitude = canonical.latitude,
            longitude = canonical.longitude,
            eastMetres = alignment.eastOffsetMetres,
            northMetres = alignment.northOffsetMetres,
        )
        return AndroidDisplayCoordinate(latitude = latitude, longitude = longitude)
    }

    /**
     * Inverse transform: Android map display coordinate -> canonical WGS84.
     *
     * Exactly inverts [toDisplay]. Required later so a tap on an aligned map
     * resolves to the true canonical coordinate before anything is created.
     */
    fun toCanonical(display: AndroidDisplayCoordinate, alignment: MapAlignment): CanonicalCoordinate {
        if (alignment.isIdentity) {
            return CanonicalCoordinate(display.latitude, display.longitude)
        }
        val (latitude, longitude) = translate(
            latitude = display.latitude,
            longitude = display.longitude,
            eastMetres = -alignment.eastOffsetMetres,
            northMetres = -alignment.northOffsetMetres,
        )
        return CanonicalCoordinate(latitude = latitude, longitude = longitude)
    }

    /**
     * The observed discrepancy between a physically-recorded canonical position
     * and the display position the operator matched it to. Evidence only.
     *
     * ### Exactly invertible by construction
     *
     * This is the inverse of [translate], so it MUST use the identical latitude
     * convention — see [scaleLatitudeFor]. Previously it always scaled east by
     * the canonical latitude while [translate] uses the *resolved* latitude for a
     * southward move, so a southward observation produced an east offset that
     * did not reconstruct the operator's own display coordinate.
     *
     * Guarantee: feeding this result into an enabled [MapAlignment] and calling
     * [toDisplay] on the same canonical coordinate reproduces [display].
     */
    fun observedOffset(
        canonical: CanonicalCoordinate,
        display: AndroidDisplayCoordinate,
    ): MapAlignmentOffset {
        val northMetres = (display.latitude - canonical.latitude) * METRES_PER_DEG_LAT
        // Same source/resolved/direction triple translate() would see for this move.
        val scaleLatitude = scaleLatitudeFor(
            sourceLatitude = canonical.latitude,
            resolvedLatitude = display.latitude,
            northMetres = northMetres,
        )
        return MapAlignmentOffset(
            eastMetres = (display.longitude - canonical.longitude) * metresPerDegLon(scaleLatitude),
            northMetres = northMetres,
        )
    }

    /**
     * Straight-line distance between two canonical coordinates, in metres,
     * measured in the SAME local east/north frame the rest of this object uses.
     *
     * Provided so calibration separation checks cannot quietly adopt a second
     * distance convention. This is a local vineyard-scale approximation, which
     * is entirely adequate for "are these two reference points well separated?"
     * and is deliberately not a geodesic. It does not replace the production
     * haversine used for route distance.
     */
    fun metresBetween(a: CanonicalCoordinate, b: CanonicalCoordinate): Double {
        val northMetres = (b.latitude - a.latitude) * METRES_PER_DEG_LAT
        val eastMetres = (b.longitude - a.longitude) * metresPerDegLon(
            scaleLatitudeFor(
                sourceLatitude = a.latitude,
                resolvedLatitude = b.latitude,
                northMetres = northMetres,
            ),
        )
        return kotlin.math.sqrt(eastMetres * eastMetres + northMetres * northMetres)
    }

    /**
     * The single latitude convention for the local east/north frame, shared by
     * [translate] and [observedOffset] so a derived offset always round-trips.
     *
     * A northward move scales longitude at the source latitude; a southward move
     * scales at the resolved latitude. Keeping one definition is what makes
     * [toCanonical] an exact inverse of [toDisplay] and makes an offset derived
     * from an observation reproduce that observation.
     */
    private fun scaleLatitudeFor(
        sourceLatitude: Double,
        resolvedLatitude: Double,
        northMetres: Double,
    ): Double = if (northMetres >= 0.0) sourceLatitude else resolvedLatitude

    /**
     * Shared translation core, working on raw degrees so it can serve both
     * directions without either coordinate type leaking into the other.
     *
     * Latitude is resolved FIRST, then the longitude scale is taken from
     * [scaleLatitudeFor]. That ordering is what makes [toCanonical] an exact
     * inverse of [toDisplay]: the forward call scales longitude by the source
     * latitude, and the inverse call reconstructs that same latitude before
     * undoing the longitude shift.
     *
     * Still a local vineyard-scale east/north translation only — no projection
     * library, no rotation/scale/skew.
     */
    private fun translate(
        latitude: Double,
        longitude: Double,
        eastMetres: Double,
        northMetres: Double,
    ): Pair<Double, Double> {
        val resolvedLatitude = latitude + northMetres / METRES_PER_DEG_LAT
        val scaleLatitude = scaleLatitudeFor(
            sourceLatitude = latitude,
            resolvedLatitude = resolvedLatitude,
            northMetres = northMetres,
        )
        val resolvedLongitude = longitude + eastMetres / metresPerDegLon(scaleLatitude)
        return resolvedLatitude to resolvedLongitude
    }
}
