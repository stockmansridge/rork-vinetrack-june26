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
 * Online-first photo storage for operational pins, mirroring the iOS
 * `PinPhotoStorageService`. Repair/observation photos live in the private
 * `vineyard-pin-photos` bucket at the same canonical path the iOS app and the
 * Lovable portal use, so the three clients read the same image.
 *
 * Path: `{vineyard_id}/pins/{pin_id}/photo.jpg` (one photo per pin, matching
 * the single `pins.photo_path` column). Uploads upsert, reads go through a
 * short-lived signed URL (the bucket is private), and deletes are gated by the
 * existing manager-only storage RLS policy.
 */
class PinPhotoRepository(private val session: SessionStore) {

    fun storagePath(vineyardId: String, pinId: String): String =
        "${vineyardId.lowercase()}/pins/${pinId.lowercase()}/photo.jpg"

    /**
     * Canonical path for a directly-authored growth-stage record photo. Android
     * growth records have no source pin, so they can't reuse the `pins/` path.
     * The first folder is still the vineyard id, so the shared bucket's
     * membership-based RLS applies unchanged. One photo per record, matching the
     * single pin photo iOS mirrors into `growth_stage_records.photo_paths`.
     */
    fun growthStoragePath(vineyardId: String, recordId: String): String =
        "${vineyardId.lowercase()}/growth/${recordId.lowercase()}/photo.jpg"

    /** Upload compressed JPEG bytes, upserting over any existing photo. Returns the object path. */
    suspend fun upload(vineyardId: String, pinId: String, jpeg: ByteArray): String =
        uploadAtPath(storagePath(vineyardId, pinId), jpeg)

    /** Upload compressed JPEG bytes to an explicit object path, upserting. Returns the path. */
    suspend fun uploadAtPath(path: String, jpeg: ByteArray): String =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
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
                    // Supabase returns a path like "/object/sign/...&token=..."
                    SupabaseClient.storageUrl(signed.removePrefix("/"))
                }
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /** Remove the stored photo. Gated server-side by the manager-only delete policy. */
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
        const val BUCKET = "vineyard-pin-photos"
    }
}
