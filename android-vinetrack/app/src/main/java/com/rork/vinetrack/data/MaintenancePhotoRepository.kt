package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.call.body
import io.ktor.client.request.delete
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.content.ByteArrayContent
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Online-first invoice/receipt photo storage for maintenance logs, mirroring the
 * iOS `MaintenancePhotoStorageService`. Photos live in the private
 * `vineyard-maintenance-photos` bucket at the same canonical path the iOS app
 * uses, so both clients read the same image.
 *
 * Path: `{vineyard_id}/maintenance/{log_id}/photo.jpg` (one photo per log,
 * matching the single `maintenance_logs.photo_path` column). Uploads upsert,
 * reads go through a short-lived signed URL (the bucket is private), and deletes
 * are gated by the bucket's membership-based RLS.
 */
class MaintenancePhotoRepository(private val session: SessionStore) {

    fun storagePath(vineyardId: String, logId: String): String =
        "${vineyardId.lowercase()}/maintenance/${logId.lowercase()}/photo.jpg"

    /** Upload compressed JPEG bytes, upserting over any existing photo. Returns the object path. */
    suspend fun upload(vineyardId: String, logId: String, jpeg: ByteArray): String =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val path = storagePath(vineyardId, logId)
            val response = SupabaseClient.http.post(
                SupabaseClient.storageUrl("object/$BUCKET/$path")
            ) {
                authHeaders(token)
                headers {
                    append("x-upsert", "true")
                    append("cache-control", "3600")
                }
                setBody(ByteArrayContent(jpeg, ContentType.Image.JPEG))
            }
            when {
                response.status.isSuccess() -> path
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /** Mint a short-lived signed URL for a private object so Coil can load it. */
    suspend fun signedUrl(path: String, expiresInSeconds: Int = 3600): String =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.post(
                SupabaseClient.storageUrl("object/sign/$BUCKET/$path")
            ) {
                authHeaders(token)
                contentType(ContentType.Application.Json)
                setBody(SignArgs(expiresInSeconds))
            }
            when {
                response.status.isSuccess() -> {
                    val signed = response.body<SignResponse>().signedURL
                        ?: throw BackendError.Server(response.status.value, "No signed URL returned")
                    SupabaseClient.storageUrl(signed.removePrefix("/"))
                }
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /** Remove the stored photo. Gated server-side by the bucket delete policy. */
    suspend fun delete(path: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.delete(
            SupabaseClient.storageUrl("object/$BUCKET/$path")
        ) {
            authHeaders(token)
        }
        when {
            response.status.isSuccess() -> Unit
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
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

    @Serializable
    private data class SignArgs(val expiresIn: Int)

    @Serializable
    private data class SignResponse(@SerialName("signedURL") val signedURL: String? = null)

    companion object {
        const val BUCKET = "vineyard-maintenance-photos"
    }
}
