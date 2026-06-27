package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.AlertWithStatus
import com.rork.vinetrack.data.model.BackendAlert
import com.rork.vinetrack.data.model.BackendAlertUserStatus
import io.ktor.client.call.body
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

/**
 * Read/action path for the Alerts Centre, mirroring the iOS `AlertService`
 * fetch + mark-status flow. Reads the shared `vineyard_alerts` and
 * `vineyard_alert_user_status` tables and toggles read/dismissed state via the
 * `mark_vineyard_alert_status` RPC (RLS scopes each to the calling user).
 *
 * Alert generation (the heavy weather/disease/irrigation engine) runs on the
 * iOS client and writes to the same tables, so alerts produced anywhere in the
 * team surface here.
 */
class AlertsRepository(private val session: SessionStore) {

    /**
     * Loads non-dismiss-expired alerts for a vineyard joined with the caller's
     * read/dismiss status. Dismissed alerts are filtered out, matching the iOS
     * `activeAlerts` computed property.
     */
    suspend fun fetchActiveAlerts(vineyardId: String): List<AlertWithStatus> = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val userId = session.userId

        val alerts = SupabaseClient.http.get(
            SupabaseClient.restUrl(
                "vineyard_alerts?select=*&vineyard_id=eq.$vineyardId&order=created_at.desc"
            )
        ) { authHeaders(token) }.let { resp ->
            when {
                resp.status.isSuccess() -> resp.body<List<BackendAlert>>()
                resp.status.value == 401 || resp.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(resp.status.value, "")
            }
        }

        if (alerts.isEmpty()) return@withContext emptyList()

        val statusById: Map<String, BackendAlertUserStatus> = if (userId != null) {
            val ids = alerts.joinToString(",") { it.id }
            SupabaseClient.http.get(
                SupabaseClient.restUrl(
                    "vineyard_alert_user_status?select=*&user_id=eq.$userId&alert_id=in.($ids)"
                )
            ) { authHeaders(token) }.let { resp ->
                if (resp.status.isSuccess()) {
                    resp.body<List<BackendAlertUserStatus>>().associateBy { it.alertId }
                } else {
                    emptyMap()
                }
            }
        } else {
            emptyMap()
        }

        alerts
            .map { AlertWithStatus(it, statusById[it.id]) }
            .filter { !it.isDismissed && !isExpired(it.alert) }
    }

    /** Sets read and/or dismissed status for the calling user via RPC. */
    suspend fun markStatus(alertId: String, read: Boolean?, dismissed: Boolean?) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val payload: JsonObject = buildJsonObject {
            put("p_alert_id", JsonPrimitive(alertId))
            put("p_read", if (read == null) JsonPrimitive(null as String?) else JsonPrimitive(read))
            put("p_dismissed", if (dismissed == null) JsonPrimitive(null as String?) else JsonPrimitive(dismissed))
        }
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("mark_vineyard_alert_status")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(payload)
        }
        when {
            response.status.isSuccess() -> Unit
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, "")
        }
    }

    private fun isExpired(alert: BackendAlert): Boolean {
        val expires = alert.expiresAt ?: return false
        // Timestamps are ISO8601; lexical compare against an ISO "now" is a safe
        // ordering for UTC strings, but parse defensively and keep the alert if
        // the value is malformed.
        return try {
            val now = java.time.Instant.now()
            val exp = java.time.Instant.parse(expires.normalizeInstant())
            exp.isBefore(now)
        } catch (_: Exception) {
            false
        }
    }

    private fun requireConfig() {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
    }

    private fun HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }
}

/** Normalizes Postgres timestamptz (space or missing Z) to a parseable instant. */
private fun String.normalizeInstant(): String {
    var s = trim().replace(" ", "T")
    if (!s.endsWith("Z") && !s.contains("+") && !Regex("-\\d{2}:\\d{2}$").containsMatchIn(s)) {
        s += "Z"
    }
    return s
}
