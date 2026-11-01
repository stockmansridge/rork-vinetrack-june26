package com.rork.vinetrack.data.model

import kotlinx.serialization.Serializable

/** Retained operator input only. A draft is never a confirmed tank session or sync operation. */
@Serializable
data class SprayActualInputDraft(
    val key: String,
    val ownerUserId: String,
    val vineyardId: String,
    val text: Map<String, String>,
    val tripId: String? = null,
    val tankId: String? = null,
    val sprayRecordId: String? = null,
) {
    fun hasValidIdentity(): Boolean = key.isNotBlank() && ownerUserId.isNotBlank() && vineyardId.isNotBlank() &&
        if (tripId == null && tankId == null && sprayRecordId == null) key.matches(Regex("review:[0-9a-f]{64}"))
        else !tripId.isNullOrBlank() && !tankId.isNullOrBlank() && !sprayRecordId.isNullOrBlank() && key == "tank:$tripId:$tankId"
}
