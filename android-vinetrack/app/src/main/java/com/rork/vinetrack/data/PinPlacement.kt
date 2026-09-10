package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Paddock

/**
 * Explicit outcome of the one-shot placement resolution performed at pin
 * commit time. Persisted `snapped_to_row` is true only for [SNAPPED]; every
 * other state records honestly that no snap happened (and why), so a pin can
 * never be saved with partial/ambiguous snap columns.
 */
enum class PinSnapState {
    /** Block + row geometry resolved; all snap columns are populated. */
    SNAPPED,

    /** No usable GPS fix at commit time — nothing was snapped. */
    NO_LOCATION,

    /** A fix existed but fell outside every mapped block. */
    NO_BLOCK,

    /** A block matched but it has no usable row geometry to snap to. */
    NO_ROW_GEOMETRY,

    /**
     * An automatic Left/Right capture whose aisle or facing could not be
     * established (no valid heading, ambiguous position, headland, or no
     * mapped neighbouring row). The raw observation and the operator's own
     * side are kept; no row, driving path or snap is invented.
     */
    UNCONFIRMED_ROW,
}

/**
 * Immutable, self-contained result of resolving a pin's placement exactly
 * once at commit time (Android mirror of the iOS
 * `PinAttachmentResolver.Attachment` value). Every consumer — the network
 * insert payload, the optimistic local pin, the offline outbox payload, the
 * duplicate check, and the user-facing confirmation — reads from this single
 * value, so they can never disagree with each other or with later UI state.
 */
data class PinPlacementResult(
    /** Raw fix the pin was dropped at (null when created without GPS). */
    val latitude: Double?,
    val longitude: Double?,
    /** Block the pin belongs to: the explicit selection, else containment. */
    val paddockId: String?,
    /** Attached vine row (fractional values preserved, e.g. 19.5). */
    val pinRowNumber: Double?,
    /** Operator side carried verbatim ("left"/"right"). */
    val pinSide: String?,
    /** Distance (m) along the attached row from its start point. */
    val alongRowDistanceM: Double?,
    /** Snapped point on the row centreline. */
    val snappedLatitude: Double?,
    val snappedLongitude: Double?,
    /** Why the pin did or didn't snap — always explicit, never implied. */
    val snapState: PinSnapState,
    /**
     * Driving path / aisle the operator occupied at capture (e.g. 32.5).
     * Distinct from [pinRowNumber]: the aisle is where the operator was, the
     * pin row is where the issue is. Null unless geometry established it —
     * never derived by adding 0.5 to a row number.
     */
    val drivingRowNumber: Double? = null,
    /**
     * Exact validated heading used to choose the side, frozen with the rest of
     * the capture. Null when no usable heading was recorded; an absent heading
     * is never turned into 0°/North.
     */
    val headingDegrees: Double? = null,
) {
    /** Persisted `snapped_to_row` value — true only for a confident snap. */
    val snappedToRow: Boolean get() = snapState == PinSnapState.SNAPPED

    /**
     * The snapped geometry as a [RowAttachment.Attachment] for consumers that
     * predate this type (duplicate checker, confirmation labels). Null unless
     * the placement actually snapped.
     */
    fun toAttachment(): RowAttachment.Attachment? {
        if (!snappedToRow) return null
        val row = pinRowNumber ?: return null
        val along = alongRowDistanceM ?: return null
        val lat = snappedLatitude ?: return null
        val lng = snappedLongitude ?: return null
        return RowAttachment.Attachment(
            pinRowNumber = row,
            pinSide = pinSide,
            alongRowDistanceM = along,
            snappedLatitude = lat,
            snappedLongitude = lng,
        )
    }
}

/**
 * Single entry point for resolving a pin's placement. Called exactly once at
 * commit time; the returned [PinPlacementResult] is immutable and flows
 * unchanged into the save payload (online or queued offline).
 */
object PinPlacement {

    /**
     * Resolve placement for a pin dropped at [latitude]/[longitude].
     *
     * Block resolution: an explicitly selected block ([selectedPaddockId])
     * always wins; otherwise the block whose polygon contains the fix is
     * used. Row snapping runs against the resolved block via [RowAttachment].
     * A pin created without a fix resolves to [PinSnapState.NO_LOCATION] and
     * keeps only the explicit block selection.
     */
    fun resolve(
        paddocks: List<Paddock>,
        selectedPaddockId: String?,
        latitude: Double?,
        longitude: Double?,
        side: String?,
    ): PinPlacementResult {
        val cleanSide = side?.trim()?.takeIf { it.isNotBlank() }?.lowercase()
        val explicitId = selectedPaddockId?.takeIf { it.isNotBlank() }
        if (latitude == null || longitude == null) {
            return PinPlacementResult(
                latitude = null,
                longitude = null,
                paddockId = explicitId,
                pinRowNumber = null,
                pinSide = null,
                alongRowDistanceM = null,
                snappedLatitude = null,
                snappedLongitude = null,
                snapState = PinSnapState.NO_LOCATION,
            )
        }
        val paddock = explicitId?.let { id -> paddocks.firstOrNull { it.id == id } }
            ?: paddocks.firstOrNull { RowAttachment.containsPoint(it, latitude, longitude) }
        if (paddock == null) {
            return PinPlacementResult(
                latitude = latitude,
                longitude = longitude,
                paddockId = null,
                pinRowNumber = null,
                pinSide = null,
                alongRowDistanceM = null,
                snappedLatitude = null,
                snappedLongitude = null,
                snapState = PinSnapState.NO_BLOCK,
            )
        }
        val attachment = RowAttachment.resolve(paddock, latitude, longitude, cleanSide)
            ?: return PinPlacementResult(
                latitude = latitude,
                longitude = longitude,
                paddockId = paddock.id,
                pinRowNumber = null,
                pinSide = null,
                alongRowDistanceM = null,
                snappedLatitude = null,
                snappedLongitude = null,
                snapState = PinSnapState.NO_ROW_GEOMETRY,
            )
        return PinPlacementResult(
            latitude = latitude,
            longitude = longitude,
            paddockId = paddock.id,
            pinRowNumber = attachment.pinRowNumber,
            pinSide = attachment.pinSide,
            alongRowDistanceM = attachment.alongRowDistanceM,
            snappedLatitude = attachment.snappedLatitude,
            snappedLongitude = attachment.snappedLongitude,
            snapState = PinSnapState.SNAPPED,
        )
    }

    /**
     * Resolve placement for an AUTOMATIC Left/Right capture (Repairs, Growth,
     * Growth Stage and quick-pin entry points, inside or outside a trip).
     *
     * Block resolution is unchanged. The row attachment, however, follows the
     * core pin-location contract instead of nearest-row copying:
     *  1. identify the aisle physically containing the fix from mapped adjacent
     *     row geometry ([lockedDrivingPath] supplies it when a validated live
     *     trip lock exists for this block),
     *  2. attach to whichever of that aisle's two rows lies on the operator's
     *     [side] for their recorded [headingDegrees],
     *  3. snap onto that selected vine row's own centreline, never the aisle
     *     midline, leaving the raw observation untouched.
     *
     * When the heading is missing/invalid or the aisle is ambiguous the result
     * is [PinSnapState.UNCONFIRMED_ROW]: raw coordinates and the operator's own
     * side are kept and no row, path or snap is invented. Two opposite-side
     * presses at one fix can therefore never resolve to the same row.
     *
     * A capture with NO operator side (Growth Stage observations, which have no
     * Left/Right choice) is not a Left/Right capture at all: it keeps the
     * established side-free nearest-row contract of [resolve] unchanged, and no
     * side, aisle or facing is manufactured for it.
     */
    fun resolveAutomatic(
        paddocks: List<Paddock>,
        selectedPaddockId: String?,
        latitude: Double?,
        longitude: Double?,
        side: String?,
        headingDegrees: Double?,
        lockedDrivingPath: Double? = null,
    ): PinPlacementResult {
        val cleanSide = side?.trim()?.takeIf { it.isNotBlank() }?.lowercase()
            ?.takeIf { it == "left" || it == "right" }
        val explicitId = selectedPaddockId?.takeIf { it.isNotBlank() }
        val heading = PinAisleGeometry.validHeading(headingDegrees)
        if (cleanSide == null) {
            // Side-free observation: unchanged existing contract, plus the
            // validated heading recorded as evidence.
            return resolve(paddocks, selectedPaddockId, latitude, longitude, side)
                .copy(headingDegrees = heading)
        }
        if (latitude == null || longitude == null) {
            return PinPlacementResult(
                latitude = null,
                longitude = null,
                paddockId = explicitId,
                pinRowNumber = null,
                pinSide = null,
                alongRowDistanceM = null,
                snappedLatitude = null,
                snappedLongitude = null,
                snapState = PinSnapState.NO_LOCATION,
                headingDegrees = heading,
            )
        }
        val paddock = explicitId?.let { id -> paddocks.firstOrNull { it.id == id } }
            ?: paddocks.firstOrNull { RowAttachment.containsPoint(it, latitude, longitude) }
        if (paddock == null) {
            return PinPlacementResult(
                latitude = latitude,
                longitude = longitude,
                paddockId = null,
                pinRowNumber = null,
                pinSide = null,
                alongRowDistanceM = null,
                snappedLatitude = null,
                snappedLongitude = null,
                snapState = PinSnapState.NO_BLOCK,
                headingDegrees = heading,
            )
        }

        /** Honest point-only capture: side is recorded evidence, nothing is derived. */
        fun unconfirmed(state: PinSnapState) = PinPlacementResult(
            latitude = latitude,
            longitude = longitude,
            paddockId = paddock.id,
            pinRowNumber = null,
            pinSide = cleanSide,
            alongRowDistanceM = null,
            snappedLatitude = null,
            snappedLongitude = null,
            snapState = state,
            drivingRowNumber = null,
            headingDegrees = heading,
        )

        val hasRowGeometry = paddock.rows
            ?.count { it.startPoint != null && it.endPoint != null }
            ?.let { it >= 2 } == true
        if (!hasRowGeometry) return unconfirmed(PinSnapState.NO_ROW_GEOMETRY)

        // A live trip lock may supply the aisle directly; otherwise derive it
        // from the physically adjacent rows around the fix.
        val lockedRows = lockedDrivingPath?.let { PinAisleGeometry.rowsBoundingPath(paddock, it) }
        val aisleNumber: Double
        val rowPair: Pair<Int, Int>
        if (lockedRows != null && lockedDrivingPath != null) {
            aisleNumber = lockedDrivingPath
            rowPair = lockedRows
        } else {
            val aisle = PinAisleGeometry.aisleContaining(paddock, latitude, longitude)
                ?: return unconfirmed(PinSnapState.UNCONFIRMED_ROW)
            aisleNumber = aisle.aisleNumber
            rowPair = aisle.nearRowNumber to aisle.farRowNumber
        }

        val selection = PinAisleGeometry.rowOnSide(
            paddock = paddock,
            rowNumbers = rowPair,
            latitude = latitude,
            longitude = longitude,
            headingDegrees = heading,
            side = cleanSide,
        ) ?: return unconfirmed(PinSnapState.UNCONFIRMED_ROW)

        return PinPlacementResult(
            latitude = latitude,
            longitude = longitude,
            paddockId = paddock.id,
            pinRowNumber = selection.rowNumber.toDouble(),
            pinSide = cleanSide,
            alongRowDistanceM = selection.alongRowDistanceM,
            snappedLatitude = selection.snappedLatitude,
            snappedLongitude = selection.snappedLongitude,
            snapState = PinSnapState.SNAPPED,
            drivingRowNumber = aisleNumber,
            headingDegrees = heading,
        )
    }
}
