package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.model.SprayRecord
import kotlinx.serialization.Serializable

/** The narrow SQL 259 response; not an editable Spray PATCH. */
@Serializable
data class SprayCompletionResponse(
    val sprayRecordId: String,
    val endTime: String,
    val completionSource: String,
    val serverConfirmed: Boolean,
    val updatedAt: String,
    val updatedBy: String? = null,
    val clientUpdatedAt: String? = null,
    val syncVersion: Long,
) {
    fun applyingTo(local: SprayRecord): SprayRecord {
        require(serverConfirmed && sprayRecordId == local.id && endTime.isNotBlank() &&
            completionSource in setOf("existing", "trip_end", "server_now"))
        return local.copy(endTime = endTime, syncVersion = syncVersion)
    }
}

/** Carries a canonical navigation target after an ACTIVE_TRIP race, without editing a Trip. */
class SprayCompletionRejected(val code: String, val tripId: String? = null) :
    IllegalStateException(SprayCompletionErrors.message(code))

object SprayCompletionErrors {
    fun message(code: String): String = when (code) {
        "ACTIVE_TRIP" -> "This spray still has an active Trip. End the Trip to complete the spray."
        "UNLINKED_CONFIRMATION_REQUIRED" -> "No linked Trip is available. Mark this spray complete now?"
        "MANUAL_SPRAY_WORKFLOW_REQUIRED" -> "Manual spray records must be managed through the manual spray workflow."
        else -> "Unable to complete this spray. Check your connection and permissions, sync and try again."
    }
}
