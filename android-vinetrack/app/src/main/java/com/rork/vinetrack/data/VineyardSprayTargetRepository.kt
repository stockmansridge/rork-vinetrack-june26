package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.spray.VineyardSprayTarget
import com.rork.vinetrack.data.spray.VineyardSprayTargetCreateParams
import io.ktor.client.call.body
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
 * Server-authoritative access to the sql/204 vineyard spray-target RPCs —
 * the shared reusable target vocabulary. Mirrors the iOS
 * `VineyardSprayTargetRepository` and the sql/170 custom-pin-type pattern.
 *
 * Writes go through the SECURITY DEFINER RPC so the database enforces roles
 * (owner/manager/supervisor/operator may add) and the duplicate rule: a
 * duplicate ACTIVE identifier converges on the existing shared entry, and a
 * replay keyed by the same client id returns the existing canonical row.
 */
class VineyardSprayTargetRepository(private val session: SessionStore) {

    @Serializable
    private data class ListArgs(
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_include_inactive") val includeInactive: Boolean = false,
    )

    suspend fun listTargets(vineyardId: String): List<VineyardSprayTarget> =
        rpc("list_vineyard_spray_targets", ListArgs(vineyardId))

    suspend fun createTarget(params: VineyardSprayTargetCreateParams): VineyardSprayTarget =
        rpc("create_vineyard_spray_target", params)

    private suspend inline fun <reified Body, reified Result> rpc(name: String, body: Body): Result =
        withContext(Dispatchers.IO) {
            if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(name)) {
                headers {
                    append("apikey", SupabaseClient.anonKey)
                    append("Authorization", "Bearer $token")
                }
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            when {
                response.status.isSuccess() -> response.body<Result>()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }
}
