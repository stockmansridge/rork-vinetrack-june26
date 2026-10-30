package com.rork.vinetrack.data.auth

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/** Only structured GoTrue refresh-token/session rejection proves that reauthentication is required. */
internal object RefreshRejection {
    fun isDefinitive(status: Int, body: String, json: Json): Boolean {
        if (status !in setOf(400, 401, 403)) return false
        val error = runCatching { json.parseToJsonElement(body) as? JsonObject }.getOrNull()
            ?: return false
        fun stringField(name: String): String? =
            (error[name] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
        // Legacy GoTrue returns a numeric HTTP status in `code` and its actual
        // machine-readable reason in `error_code`. Modern responses instead
        // use a string `code`. Never let numeric 400 mask a rejected session.
        return RefreshRejectionCodes.isDefinitive(
            status, stringField("error_code"), stringField("code"),
        )
    }
}

/** Pure compatibility policy; never classifies by free-form text or HTTP status alone. */
internal object RefreshRejectionCodes {
    private val definitiveCodes = setOf(
        "refresh_token_not_found", "refresh_token_already_used", "session_not_found",
        "session_expired", "user_banned", "user_not_found",
    )

    fun isDefinitive(status: Int, errorCode: String?, code: String?): Boolean {
        if (status !in setOf(400, 401, 403)) return false
        val legacy = errorCode?.takeIf { it.isNotBlank() }
        val modern = code?.takeIf { it.isNotBlank() && it.toIntOrNull() == null }
        // Contradictory machine-readable fields are not authority to revoke.
        if (legacy != null && modern != null && legacy != modern) return false
        return (legacy ?: modern) in definitiveCodes
    }
}
