package com.rork.vinetrack.data.auth

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

/** Only structured GoTrue refresh-token/session rejection proves that reauthentication is required. */
internal object RefreshRejection {
    private val definitiveCodes = setOf(
        "refresh_token_not_found", "refresh_token_already_used", "session_not_found",
        "session_expired", "user_banned", "user_not_found",
    )

    fun isDefinitive(status: Int, body: String, json: Json): Boolean {
        if (status !in setOf(400, 401, 403)) return false
        val error = runCatching { json.parseToJsonElement(body) as? JsonObject }.getOrNull()
            ?: return false
        val code = runCatching {
            (error["code"] ?: error["error_code"])?.jsonPrimitive?.contentOrNull
        }.getOrNull()
        // A gateway HTML page, generic invalid_grant, permission denial or rate limit is
        // not evidence about the stored refresh token. Never classify by free-form message.
        return code in definitiveCodes
    }
}
