package com.rork.vinetrack.data.mapalignment

/**
 * Android-only map alignment domain foundation.
 *
 * ## Fixed V1 product rules
 *
 * These are settled product decisions, not implementation preferences. Do not
 * relax them without an explicit product decision:
 *
 * * **Android only.** Nothing in this package exists on iOS or Portal.
 * * **System Admin preview only** until the feature is explicitly released.
 * * **Portal and iOS remain VineTrack's canonical/master geographic
 *   representation.** Android never becomes the source of geographic truth.
 * * **Map Alignment corrects Android map presentation only.** It is a drawing
 *   concern, not a data concern.
 * * **Canonical WGS84 data remains unchanged.** No vineyard, block, row, pin,
 *   route or historical coordinate is ever rewritten by this feature.
 * * **Alignment is scoped to an Android installation** — see [MapAlignmentScope].
 *   It is never a vineyard-wide correction imposed on every Android device.
 * * **Vineyard alignment is the normal scope.**
 * * **Block alignment is an optional override.**
 * * **Block override takes precedence over vineyard alignment** — see
 *   [MapAlignmentResolver].
 * * **Translation only in V1.** No rotation, scale, skew, affine transform or
 *   arbitrary warping.
 * * **Satellite/hybrid presentation is the intended future use.** Do not assume
 *   standard vector maps need correction; the observed discrepancy is with
 *   aerial imagery georeferencing.
 * * **No historical coordinate remediation is performed.** This feature never
 *   goes back and "fixes" previously captured data.
 *
 * ## What this is
 *
 * A *display-time* translation that lets the Android satellite basemap be
 * nudged so it lines up with VineTrack's canonical vineyard geometry, on the
 * one installation that is seeing the mismatch.
 *
 * ## What this is NOT
 *
 * This is **not** a GPS correction system. It does not improve, adjust or
 * second-guess any location fix.
 *
 * ## The absolute coordinate invariant
 *
 * **Android display coordinates can never become stored VineTrack geographic
 * truth.** An [AndroidDisplayCoordinate] may be used only for drawing on the
 * Android map. It must never be written into domain data, persistence, an
 * outbox payload or a sync payload. The type system now enforces the boundary:
 * a display coordinate cannot be handed to code expecting a
 * [CanonicalCoordinate] without an explicit, deliberate conversion.
 */

/**
 * A canonical WGS84 coordinate — VineTrack's stored geographic truth.
 *
 * This is the only kind of coordinate that may be persisted, synced or treated
 * as the real-world position of anything. It is deliberately a *different type*
 * from [AndroidDisplayCoordinate] so the compiler, rather than developer
 * discipline, prevents a display coordinate being stored by mistake.
 */
data class CanonicalCoordinate(
    val latitude: Double,
    val longitude: Double,
) {
    /**
     * Apply an alignment to produce the position this coordinate should be
     * DRAWN at on the Android map. The result is presentation-only.
     */
    fun toDisplay(alignment: MapAlignment): AndroidDisplayCoordinate =
        MapAlignmentTransform.toDisplay(this, alignment)
}

/**
 * A coordinate in the *aligned Android map's* frame of reference.
 *
 * Purely a rendering/interaction value: where something is drawn, or where the
 * operator tapped on the shifted imagery. It is NOT a real-world position and
 * must never be persisted, synced, compared against canonical geometry or fed
 * into row/aisle/duplicate logic. Convert with [toCanonical] first.
 */
data class AndroidDisplayCoordinate(
    val latitude: Double,
    val longitude: Double,
) {
    /**
     * Convert a display position (typically a map tap) back to the canonical
     * coordinate it truly represents. This is the ONLY legitimate route from
     * display space into anything that may be stored.
     */
    fun toCanonical(alignment: MapAlignment): CanonicalCoordinate =
        MapAlignmentTransform.toCanonical(this, alignment)
}

/**
 * Identifies exactly what an alignment applies to.
 *
 * An alignment is always tied to ONE Android installation. That is the whole
 * point: the imagery offset one operator sees on one device must never silently
 * become a vineyard-wide correction applied to every Android device, and it
 * must never reach iOS or Portal.
 *
 * @property androidInstallationId VineTrack's opaque per-installation
 *   identifier (`AndroidInstallationIdentity`). A random UUID stored on the
 *   device — never a hardware identifier, advertising ID, email or user ID.
 * @property vineyardId the vineyard the alignment applies within. Always
 *   present: alignment is meaningless without a vineyard's geometry.
 * @property blockId optional block override. When null this is the vineyard's
 *   normal alignment; when set it applies to that block only and takes
 *   precedence over the vineyard alignment.
 */
data class MapAlignmentScope(
    val androidInstallationId: String,
    val vineyardId: String,
    val blockId: String? = null,
) {
    /** True when this is the optional per-block override rather than the vineyard default. */
    val isBlockOverride: Boolean get() = blockId != null

    /** The vineyard-level scope for the same installation and vineyard. */
    fun asVineyardScope(): MapAlignmentScope = if (blockId == null) this else copy(blockId = null)
}

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

/** An east/north translation in metres. Positive is east and north respectively. */
data class MapAlignmentOffset(
    val eastMetres: Double,
    val northMetres: Double,
) {
    val magnitudeMetres: Double
        get() = kotlin.math.sqrt(eastMetres * eastMetres + northMetres * northMetres)

    companion object {
        val ZERO = MapAlignmentOffset(0.0, 0.0)
    }
}

/**
 * A calibration/reference point: one physical place, recorded twice.
 *
 * [canonicalCoordinate] is the real GPS coordinate recorded while standing at
 * the location — canonical truth. [selectedMapCoordinate] is where the operator
 * had to tap on the Android satellite image for it to *look* like the same
 * place — display space. The two are deliberately different types so they can
 * never be transposed or confused.
 *
 * ## Why these are retained individually
 *
 * The derived east/north offsets are a summary, and a summary is not evidence.
 * Individual points are kept so we can later support recalculation, quality
 * assessment, diagnostics, and detecting whether Google's imagery shifts over
 * time. Never reduce a calibration to just its two offset numbers.
 *
 * @property scope the scope this point was captured for, so evidence always
 *   travels with the installation/vineyard/block it belongs to.
 * @property alignmentId the alignment this point contributed to, when one has
 *   been computed from it. Null while a calibration is still being collected.
 *
 * Capturing these is a later prompt — this pass only models them. Nothing here
 * is persisted or synced.
 */
data class MapAlignmentReferencePoint(
    val id: String,
    /** Scope that owns this evidence. */
    val scope: MapAlignmentScope,
    /** The canonical, physically-recorded WGS84 coordinate. Never modified. */
    val canonicalCoordinate: CanonicalCoordinate,
    /** The matching point the operator selected on the Android satellite image. */
    val selectedMapCoordinate: AndroidDisplayCoordinate,
    /** Horizontal accuracy of the canonical fix, in metres, when reported. */
    val gpsAccuracyMetres: Double? = null,
    /** Epoch millis at which the canonical coordinate was captured. */
    val capturedAtEpochMillis: Long,
    /** The alignment computed from this point, once one exists. */
    val alignmentId: String? = null,
    val referenceType: MapAlignmentReferenceType? = null,
    val description: String? = null,
    val rowNumber: Int? = null,
    val rowPosition: MapAlignmentRowPosition? = null,
) {
    /**
     * This point's observed discrepancy. Evidence only — it is not
     * automatically applied to anything.
     */
    val observedOffset: MapAlignmentOffset
        get() = MapAlignmentTransform.observedOffset(canonicalCoordinate, selectedMapCoordinate)

    /** Eastward component of the observed discrepancy, in metres. */
    val observedEastOffsetMetres: Double get() = observedOffset.eastMetres

    /** Northward component of the observed discrepancy, in metres. */
    val observedNorthOffsetMetres: Double get() = observedOffset.northMetres
}

/**
 * A translation-only alignment for one [MapAlignmentScope] on Android.
 *
 * [eastOffsetMetres] is positive toward the east, [northOffsetMetres] positive
 * toward the north. A disabled alignment, or one with both offsets at zero, is
 * exactly equivalent to current production behaviour.
 *
 * ### Persistence boundary
 *
 * TODO(map-alignment): When alignment persistence is introduced, writes must be
 * authorised at the authoritative write layer (server RPC / RLS on the owning
 * table) and must NOT rely solely on the cached UI System Admin flag
 * (`AppUiState.isSystemAdmin`). That cached flag is fine for deciding what to
 * show and what to navigate to, but it is client state and can be stale; it is
 * not an authorisation decision. Server/RPC/RLS enforcement is the final
 * authority. No persistence exists in this pass.
 */
data class MapAlignment(
    val id: String,
    /** Exactly what this alignment applies to. See [MapAlignmentScope]. */
    val scope: MapAlignmentScope,
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
    /** Convenience accessors for the scope this alignment belongs to. */
    val vineyardId: String get() = scope.vineyardId
    val blockId: String? get() = scope.blockId
    val androidInstallationId: String get() = scope.androidInstallationId

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

    val offset: MapAlignmentOffset
        get() = MapAlignmentOffset(eastOffsetMetres, northOffsetMetres)

    companion object {
        /** The explicit "no alignment" value for a scope. Behaviourally invisible. */
        fun none(scope: MapAlignmentScope, id: String = "none"): MapAlignment =
            MapAlignment(id = id, scope = scope)
    }
}

/**
 * An alignment together with the calibration evidence that produced it.
 *
 * Kept as a distinct aggregate so reference points are never discarded once an
 * alignment is derived — they remain available for recalculation, quality
 * assessment, diagnostics and detecting imagery drift over time.
 */
data class MapAlignmentCalibration(
    val alignment: MapAlignment,
    val referencePoints: List<MapAlignmentReferencePoint> = emptyList(),
) {
    /** Reference points that belong to this alignment's own scope. */
    val pointsInScope: List<MapAlignmentReferencePoint>
        get() = referencePoints.filter { it.scope == alignment.scope }

    /**
     * Per-point residual against the applied alignment, in metres: how far each
     * point still disagrees after the translation. Diagnostics only.
     */
    fun residuals(): List<MapAlignmentOffset> = referencePoints.map { point ->
        MapAlignmentOffset(
            eastMetres = point.observedOffset.eastMetres - alignment.eastOffsetMetres,
            northMetres = point.observedOffset.northMetres - alignment.northOffsetMetres,
        )
    }
}
