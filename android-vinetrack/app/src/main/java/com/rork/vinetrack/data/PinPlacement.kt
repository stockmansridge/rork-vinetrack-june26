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
}
