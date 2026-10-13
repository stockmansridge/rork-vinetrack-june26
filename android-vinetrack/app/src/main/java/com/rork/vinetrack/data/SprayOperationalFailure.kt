package com.rork.vinetrack.data

import java.io.IOException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Client containment only: a server denial or unknown response never grants execution. */
object SprayOperationalFailure {
    enum class CreateConflict { COMPLIANCE_REJECTION, REVISION_OR_DATA_CONFLICT, UNVERIFIED }

    fun isComplianceRejection(error: BackendError.Server): Boolean {
        val body = runCatching { Json.parseToJsonElement(error.body).jsonObject }.getOrNull() ?: return false
        val code = runCatching { body["code"]?.jsonPrimitive?.content }.getOrNull()
        val message = runCatching { body["message"]?.jsonPrimitive?.content }.getOrNull().orEmpty()
        return code == "23514" || message.startsWith("SPRAY_LABEL_")
    }

    fun createConflict(error: BackendError.Server): CreateConflict = when {
        isComplianceRejection(error) -> CreateConflict.COMPLIANCE_REJECTION
        runCatching { Json.parseToJsonElement(error.body).jsonObject["code"]?.jsonPrimitive?.content }
            .getOrNull() in setOf("PT409", "23505", "23503", "REVISION_CONFLICT") -> CreateConflict.REVISION_OR_DATA_CONFLICT
        else -> CreateConflict.UNVERIFIED
    }

    fun canStartOffline(tripFunction: String?, error: Exception): Boolean {
        if (tripFunction?.trim()?.lowercase() in setOf("spraying", "spray")) return false
        return when (error) {
            is BackendError.Server -> !isComplianceRejection(error) && error.code in 500..599
            is BackendError.Network, is IOException -> true
            else -> false
        }
    }

    const val SPRAY_START_MESSAGE = "Start this spray from a validated saved recipe or the Spray Calculator. Generic/offline start does not authorise spraying."
}
