package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.LauncherButton
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant

/**
 * Read path for per-vineyard Repairs/Growth launcher button configuration,
 * mirroring the canonical iOS `vineyard_button_configs` contract.
 *
 * The table stores one row per (vineyard_id, config_type) where config_type is
 * `repair_buttons` / `growth_buttons` and `config_data` is a JSONB array of
 * [LauncherButton]. Any vineyard member may read; only owners/managers may
 * write (handled on iOS/portal). Android is read-only for this slice: it renders
 * whatever buttons the team has configured, falling back to the built-in
 * defaults when no row exists.
 */
class ButtonConfigRepository(private val session: SessionStore) {

    @Serializable
    private data class ConfigRow(
        @SerialName("config_type") val configType: String,
        @SerialName("config_data") val configData: List<LauncherButton> = emptyList(),
        @SerialName("deleted_at") val deletedAt: String? = null,
    )

    /** Remote launcher buttons for a vineyard, split by mode. Empty when none configured. */
    data class LauncherButtons(
        val repair: List<LauncherButton> = emptyList(),
        val growth: List<LauncherButton> = emptyList(),
    )

    suspend fun fetch(vineyardId: String): LauncherButtons = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val url = SupabaseClient.restUrl(
            "vineyard_button_configs?vineyard_id=eq.$vineyardId&deleted_at=is.null" +
                "&select=config_type,config_data,deleted_at",
        )
        val response = SupabaseClient.http.get(url) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
        }
        when {
            response.status.isSuccess() -> {
                val rows = response.body<List<ConfigRow>>()
                LauncherButtons(
                    repair = rows.firstOrNull { it.configType == "repair_buttons" }
                        ?.configData?.sortedBy { it.index } ?: emptyList(),
                    growth = rows.firstOrNull { it.configType == "growth_buttons" }
                        ?.configData?.sortedBy { it.index } ?: emptyList(),
                )
            }
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /**
     * Owner/manager write path. Upserts one config row for [vineyardId]/[configType]
     * against the canonical `vineyard_button_configs` contract, mirroring the iOS
     * `BackendButtonConfigUpsert` (last-write-wins via `client_updated_at`).
     *
     * Uses PostgREST `on_conflict=vineyard_id,config_type` with merge-duplicates so
     * an existing row is updated in place (its `id`/`created_at` are preserved by
     * omitting them). RLS restricts insert/update to owners and managers — a
     * non-authorised caller surfaces [BackendError.Unauthorized].
     */
    suspend fun upsert(
        vineyardId: String,
        configType: String,
        buttons: List<LauncherButton>,
        clientUpdatedAt: String? = null,
    ): Unit = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val payload = UpsertRow(
            vineyardId = vineyardId,
            configType = configType,
            configData = buttons,
            createdBy = session.userId,
            clientUpdatedAt = clientUpdatedAt ?: Instant.now().toString(),
        )
        val url = SupabaseClient.restUrl("vineyard_button_configs?on_conflict=vineyard_id,config_type")
        val response = SupabaseClient.http.post(url) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
                append("Prefer", "resolution=merge-duplicates,return=minimal")
            }
            contentType(ContentType.Application.Json)
            setBody(listOf(payload))
        }
        when {
            response.status.isSuccess() -> Unit
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    @Serializable
    private data class UpsertRow(
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("config_type") val configType: String,
        @SerialName("config_data") val configData: List<LauncherButton>,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    private fun requireConfig() {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
    }
}
