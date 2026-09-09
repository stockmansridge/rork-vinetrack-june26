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
