package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.model.Pin

/** Stable source identity for an item rendered on the combined Pins surface. */
data class PinPresentationTarget(
    val vineyardId: String,
    val pinId: String?,
    val growthRecordId: String?,
    val kind: Kind,
) {
    enum class Kind { PIN, LINKED_GROWTH, STANDALONE_GROWTH }
}

/** Authoritative photo identity consumed by every combined Pins presentation. */
data class PhotoPresentation(
    val entityId: String,
    val remotePath: String?,
    val remoteIdentity: String?,
)

/** Resolve the backing rows at action time instead of trusting a display copy. */
fun resolvePinPresentationTarget(
    displayId: String,
    pins: List<Pin>,
    growthRecords: List<GrowthStageRecord>,
): PinPresentationTarget? {
    val pin = pins.firstOrNull { it.id == displayId }
    val growth = growthRecords.firstOrNull { record ->
        record.pinId?.takeIf(String::isNotBlank) == displayId ||
            (record.pinId.isNullOrBlank() && record.id == displayId)
    }
    return when {
        pin != null && growth != null -> PinPresentationTarget(
            vineyardId = pin.vineyardId,
            pinId = pin.id,
            growthRecordId = growth.id,
            kind = PinPresentationTarget.Kind.LINKED_GROWTH,
        )
        pin != null -> PinPresentationTarget(pin.vineyardId, pin.id, null, PinPresentationTarget.Kind.PIN)
        growth != null && !growth.pinId.isNullOrBlank() -> PinPresentationTarget(
            vineyardId = growth.vineyardId,
            pinId = growth.pinId,
            growthRecordId = growth.id,
            kind = PinPresentationTarget.Kind.LINKED_GROWTH,
        )
        growth != null -> PinPresentationTarget(
            vineyardId = growth.vineyardId,
            pinId = null,
            growthRecordId = growth.id,
            kind = PinPresentationTarget.Kind.STANDALONE_GROWTH,
        )
        else -> null
    }
}

/**
 * Resolve photo display from the backing record rather than a synthesized Pin.
 * Growth owns linked-growth photo identity and cache storage whenever its
 * representation carries the photo; a plain pin remains authoritative otherwise.
 */
fun resolvePhotoPresentation(
    displayId: String,
    pins: List<Pin>,
    growthRecords: List<GrowthStageRecord>,
): PhotoPresentation {
    val pin = pins.firstOrNull { it.id == displayId }
    val growth = growthRecords.firstOrNull { record ->
        record.pinId?.takeIf(String::isNotBlank) == displayId ||
            (record.pinId.isNullOrBlank() && record.id == displayId)
    }
    val growthPath = growth?.photoPaths?.firstOrNull()?.takeIf(String::isNotBlank)
    if (growth != null && (growthPath != null || pin == null)) {
        return PhotoPresentation(
            entityId = growth.id,
            remotePath = growthPath,
            remoteIdentity = growthPath?.let { PinPhotoSync.growthRemoteIdentity(growth, it) },
        )
    }
    val pinPath = pin?.photoPath?.takeIf(String::isNotBlank)
    if (pin != null) {
        return PhotoPresentation(
            entityId = pin.id,
            remotePath = pinPath,
            remoteIdentity = pinPath?.let { PinPhotoSync.pinRemoteIdentity(pin, it) },
        )
    }
    return PhotoPresentation(entityId = displayId, remotePath = null, remoteIdentity = null)
}
