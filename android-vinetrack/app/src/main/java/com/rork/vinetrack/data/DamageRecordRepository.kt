package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.DamageRecord
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.patch
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
 * Write/read path for block-damage records, mirroring the iOS
 * `DamageRecordSyncService` contract (the `damage_records` table +
 * `soft_delete_damage_record` RPC). RLS scopes everything to the signed-in
 * user's vineyard role: owner/manager/supervisor/operator may insert and update;
 * only owner/manager/supervisor may soft-delete.
 *
 * Online-first with optimistic UI in the view model. The insert/patch bodies use
 * the canonical Supabase column names (and capitalised `damage_type`) so rows
 * round-trip with iOS and the web portal unchanged. Portal-only additive columns
 * are never written from Android so we don't clobber portal-set values with null.
 */
class DamageRecordRepository(private val session: SessionStore) {

    @Serializable
    private data class DamageInsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("paddock_id") val paddockId: String,
        val date: String,
        @SerialName("damage_type") val damageType: String,
        @SerialName("damage_percent") val damagePercent: Double,
        @SerialName("polygon_points") val polygonPoints: List<CoordinatePoint>,
        val notes: String,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class DamagePatch(
        val date: String,
        @SerialName("damage_type") val damageType: String,
        @SerialName("damage_percent") val damagePercent: Double,
        @SerialName("polygon_points") val polygonPoints: List<CoordinatePoint>,
        val notes: String,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    private fun nowIso(): String = Instant.now().toString()

    suspend fun listDamageRecords(vineyardId: String): List<DamageRecord> =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.get(
                SupabaseClient.restUrl(
                    "damage_records?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=date.desc",
                ),
            ) { authHeaders(token) }
            when {
                response.status.isSuccess() -> response.body()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    suspend fun insertDamageRecord(
        record: DamageRecord,
        clientUpdatedAt: String? = null,
    ): DamageRecord = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val now = clientUpdatedAt ?: nowIso()
        val body = DamageInsert(
            id = record.id,
            vineyardId = record.vineyardId,
            paddockId = record.paddockId,
            date = record.date ?: now,
            damageType = record.type.label,
            damagePercent = record.damagePercent,
            polygonPoints = record.polygonPoints ?: emptyList(),
            notes = record.notes,
            createdBy = session.userId,
            clientUpdatedAt = now,
        )
        val response = SupabaseClient.http.post(SupabaseClient.restUrl("damage_records")) {
            authHeaders(token)
            headers { append("Prefer", "return=representation") }
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        firstRow(response)
    }

    suspend fun updateDamageRecord(
        record: DamageRecord,
        clientUpdatedAt: String? = null,
    ): DamageRecord = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val now = clientUpdatedAt ?: nowIso()
        val patch = DamagePatch(
            date = record.date ?: now,
            damageType = record.type.label,
            damagePercent = record.damagePercent,
            polygonPoints = record.polygonPoints ?: emptyList(),
            notes = record.notes,
            clientUpdatedAt = now,
        )
        val response = SupabaseClient.http.patch(SupabaseClient.restUrl("damage_records?id=eq.${record.id}")) {
            authHeaders(token)
            headers { append("Prefer", "return=representation") }
            contentType(ContentType.Application.Json)
            setBody(patch)
        }
        firstRow(response)
    }

    suspend fun softDeleteDamageRecord(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_damage_record")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(SoftDeleteArgs(id))
        }
        when {
            response.status.isSuccess() -> Unit
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    private suspend fun firstRow(response: io.ktor.client.statement.HttpResponse): DamageRecord = when {
        response.status.isSuccess() -> response.body<List<DamageRecord>>().firstOrNull()
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
