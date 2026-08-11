package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.PruningYieldSettings
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

/**
 * Read/write path for the shared per-block Pruning Yield Calculator
 * configuration (`public.pruning_yield_settings`, sql/181), mirroring the iOS
 * `SupabasePruningYieldSettingsSyncRepository` contract.
 *
 * ONE saved configuration per block: the upsert conflict target is the
 * (vineyard_id, paddock_id) unique key — NOT the row id — so editing never
 * duplicates rows and two devices that minted different ids for the same
 * block converge on a single record. RLS scopes everything to vineyard
 * membership (operator+ write; owner/manager/supervisor delete).
 */
class PruningYieldSettingsRepository(private val session: SessionStore) {

    @Serializable
    private data class SettingsUpsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("paddock_id") val paddockId: String,
        @SerialName("prune_method") val pruneMethod: String,
        @SerialName("bunches_per_bud") val bunchesPerBud: Double,
        @SerialName("buds_per_spur") val budsPerSpur: Double,
        @SerialName("spurs_per_vine") val spursPerVine: Double,
        @SerialName("buds_per_cane") val budsPerCane: Double,
        @SerialName("canes_per_vine") val canesPerVine: Double,
        // Encoded even when null so clearing Vines/Ha clears the column.
        @SerialName("vines_per_ha") val vinesPerHa: Double?,
        @SerialName("bunch_weight_grams") val bunchWeightGrams: Double,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    /**
     * Upsert a block's saved configuration. Shared by the online save flow and
     * the offline replay ([PruningYieldSettingsSync]) so the values are
     * preserved byte-for-byte. Returns the server row, or NULL when the
     * sql/185 stale-write guard silently ignored the write because another
     * device/portal already saved a NEWER configuration (the empty
     * `return=representation` body is the guard's signature) — callers must
     * treat the newer server value as authoritative, never retry.
     */
    suspend fun upsertSettings(
        settings: PruningYieldSettings,
        clientUpdatedAt: String,
    ): PruningYieldSettings? = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val body = SettingsUpsert(
            id = settings.id,
            vineyardId = settings.vineyardId,
            paddockId = settings.paddockId,
            pruneMethod = settings.pruneMethod,
            bunchesPerBud = settings.bunchesPerBud,
            budsPerSpur = settings.budsPerSpur,
            spursPerVine = settings.spursPerVine,
            budsPerCane = settings.budsPerCane,
            canesPerVine = settings.canesPerVine,
            vinesPerHa = settings.vinesPerHa,
            bunchWeightGrams = settings.bunchWeightGrams,
            createdBy = session.userId,
            clientUpdatedAt = clientUpdatedAt,
        )
        val response = SupabaseClient.http.post(
            SupabaseClient.restUrl("pruning_yield_settings?on_conflict=vineyard_id,paddock_id"),
        ) {
            authHeaders(token)
            headers {
                append("Prefer", "resolution=merge-duplicates")
                append("Prefer", "return=representation")
            }
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        when {
            // Success with an empty representation = the stale-write guard
            // skipped the UPDATE (sql/185) — a newer edit already won.
            response.status.isSuccess() -> response.body<List<PruningYieldSettings>>().firstOrNull()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    suspend fun listSettings(vineyardId: String): List<PruningYieldSettings> =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.get(
                SupabaseClient.restUrl(
                    "pruning_yield_settings?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null",
                ),
            ) { authHeaders(token) }
            when {
                response.status.isSuccess() -> response.body()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    private suspend fun firstRow(response: io.ktor.client.statement.HttpResponse): PruningYieldSettings = when {
        response.status.isSuccess() -> response.body<List<PruningYieldSettings>>().firstOrNull()
            ?: throw BackendError.Server(response.status.value, "Empty response")
        response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
        else -> throw BackendError.Server(response.status.value, response.bodyAsText())
    }

    private fun requireConfig() {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
    }

    private fun io.ktor.client.request.HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }
}
