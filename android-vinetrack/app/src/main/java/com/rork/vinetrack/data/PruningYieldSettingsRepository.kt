package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.PruningYieldSettings
import com.rork.vinetrack.data.sync.SyncRevisionContract
import com.rork.vinetrack.data.sync.VersionedWriteOutcome
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

    private val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }

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
        /**
         * When the grower edited. METADATA under sql/198 — clamped to server `now()` and no
         * longer the concurrency authority. Still sent: the legacy trigger path needs it,
         * and the sql/181 soft-delete resurrection trigger uses a CHANGE in this value to
         * detect a genuine client upsert. That is a change-detector, not an ordering
         * comparison, and removing the field would break un-deleting a block's settings.
         */
        @SerialName("client_updated_at") val clientUpdatedAt: String,
        /**
         * The version this edit was based on — THE concurrency authority (sql/198). Omitted
         * (null) when this device has never been issued one, which sql/198 reads as a create.
         */
        @SerialName("base_revision") val baseRevision: Long? = null,
    )

    /**
     * Upsert a block's saved configuration under the sql/198 revision contract.
     *
     * Shared by the online save flow and the offline replay ([PruningYieldSettingsSync]) so
     * the values are preserved byte-for-byte.
     *
     * Returns [VersionedWriteOutcome.Applied] with the authoritative server row (carrying
     * its NEW `server_revision`), or [VersionedWriteOutcome.Conflict] when another device or
     * the portal has saved since this device last read the row. A conflict is NEVER thrown:
     * a thrown conflict gets classified as a transport failure and retried forever with the
     * same stale `base_revision`.
     */
    suspend fun upsertSettings(
        settings: PruningYieldSettings,
        clientUpdatedAt: String,
    ): VersionedWriteOutcome<PruningYieldSettings> = withContext(Dispatchers.IO) {
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
            baseRevision = settings.serverRevision,
        )
        val response = SupabaseClient.http.post(
            SupabaseClient.restUrl("pruning_yield_settings?on_conflict=vineyard_id,paddock_id"),
        ) {
            authHeaders(token)
            headers {
                append("Prefer", "resolution=merge-duplicates")
                // Mandatory, not an optimisation: the response body is the only place the
                // new `server_revision` appears, and without it the next edit would resend
                // the previous base_revision and be refused for no reason.
                append("Prefer", "return=representation")
            }
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        val text = response.bodyAsText()
        when {
            response.status.isSuccess() -> {
                val row = runCatching { json.decodeFromString<List<PruningYieldSettings>>(text) }
                    .getOrDefault(emptyList())
                    .firstOrNull()
                if (row == null) {
                    // A 2xx with an EMPTY representation is the legacy silent-skip signature
                    // (a BEFORE UPDATE trigger returning NULL). It used to be reported as
                    // success, which is exactly how a grower's calculator settings vanished.
                    // Surfaced as a conflict so the local value is kept.
                    VersionedWriteOutcome.Conflict(
                        rowId = settings.id,
                        baseRevision = settings.serverRevision,
                        serverRevision = null,
                    )
                } else {
                    VersionedWriteOutcome.Applied(row)
                }
            }
            SyncRevisionContract.isRevisionConflict(response.status.value, text) ->
                VersionedWriteOutcome.Conflict(
                    rowId = settings.id,
                    baseRevision = SyncRevisionContract.baseRevisionFrom(text) ?: settings.serverRevision,
                    serverRevision = SyncRevisionContract.serverRevisionFrom(text),
                )
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, text)
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
