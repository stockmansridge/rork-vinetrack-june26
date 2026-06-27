package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.SavedInput
import io.ktor.client.call.body
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.headers
import io.ktor.client.request.patch
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.util.UUID

/**
 * Write path for the shared Saved Inputs library, mirroring the iOS
 * `saved_inputs` sync contract (sql/058). RLS scopes selects to vineyard
 * members; inserts/updates require owner/manager; hard deletes are blocked
 * client-side, so deletion goes through the `soft_delete_saved_input` RPC.
 *
 * `cost_per_unit` is a plain nullable numeric (dollars per the input's own
 * display unit) and round-trips across platforms unchanged.
 */
class SavedInputRepository(private val session: SessionStore) {

    /** Editable fields surfaced by the Android management form. */
    data class InputForm(
        val name: String,
        val inputType: String,
        val unit: String,
        /** Cost per the input's display unit; null clears it. */
        val costPerUnit: Double?,
        val supplier: String?,
        val notes: String?,
    )

    @Serializable
    private data class InputInsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        val name: String,
        @SerialName("input_type") val inputType: String,
        val unit: String,
        @SerialName("cost_per_unit") val costPerUnit: Double? = null,
        val supplier: String? = null,
        val notes: String? = null,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class InputPatch(
        val name: String,
        @SerialName("input_type") val inputType: String,
        val unit: String,
        @SerialName("cost_per_unit") val costPerUnit: Double? = null,
        val supplier: String? = null,
        val notes: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    private fun nowIso(): String = Instant.now().toString()

    suspend fun create(vineyardId: String, form: InputForm): SavedInput =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val body = InputInsert(
                id = UUID.randomUUID().toString(),
                vineyardId = vineyardId,
                name = form.name,
                inputType = form.inputType,
                unit = form.unit,
                costPerUnit = form.costPerUnit?.takeIf { it > 0 },
                supplier = form.supplier?.ifBlank { null },
                notes = form.notes?.ifBlank { null },
                createdBy = session.userId,
                clientUpdatedAt = nowIso(),
            )
            val response = SupabaseClient.http.post(SupabaseClient.restUrl("saved_inputs")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            firstRow(response)
        }

    suspend fun update(id: String, form: InputForm): SavedInput =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val patch = InputPatch(
                name = form.name,
                inputType = form.inputType,
                unit = form.unit,
                costPerUnit = form.costPerUnit?.takeIf { it > 0 },
                supplier = form.supplier?.ifBlank { null },
                notes = form.notes?.ifBlank { null },
                clientUpdatedAt = nowIso(),
            )
            val response = SupabaseClient.http.patch(SupabaseClient.restUrl("saved_inputs?id=eq.$id")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(patch)
            }
            firstRow(response)
        }

    /** Archive (soft-delete) via the owner/manager-gated server RPC. */
    suspend fun softDelete(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_saved_input")) {
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

    private suspend fun firstRow(response: HttpResponse): SavedInput = when {
        response.status.isSuccess() -> response.body<List<SavedInput>>().firstOrNull()
            ?: throw BackendError.Server(response.status.value, "Empty response")
        response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
        else -> throw BackendError.Server(response.status.value, response.bodyAsText())
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
