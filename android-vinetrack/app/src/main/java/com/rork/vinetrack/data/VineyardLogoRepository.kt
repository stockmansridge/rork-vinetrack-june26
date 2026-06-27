package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.call.body
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsBytes
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
 * Online-first storage for the per-vineyard logo, mirroring the iOS
 * `VineyardLogoStorageService`. Logos live in the private `vineyard-logos`
 * bucket at the canonical path `{vineyard_id}/logo.jpg`, so the iOS app, the
 * Lovable portal and Android all read/write the same object.
 *
 * Uploads upsert, reads go through a short-lived signed URL (the bucket is
 * private) so Coil can load the image, and uploads/deletes are gated by the
 * owner/manager-only storage RLS policies (sql/010).
 */
class VineyardLogoRepository(private val session: SessionStore) {

    fun storagePath(vineyardId: String): String =
        "${vineyardId.lowercase()}/logo.jpg"

    /** Upload compressed JPEG bytes, upserting over any existing logo. Returns the object path. */
    suspend fun upload(vineyardId: String, jpeg: ByteArray): String = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val path = storagePath(vineyardId)
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

    /** Mint a short-lived signed URL for the private logo so Coil can load it. */
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

    /**
     * Download the raw logo bytes for [path]. Used to render the logo into
     * locally generated PDFs (which need actual image data, not a URL) and to
     * cache a decoded bitmap for the dashboard. Mirrors the iOS
     * `VineyardLogoStorageService.downloadLogo` byte fetch.
     */
    suspend fun download(path: String): ByteArray = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.get(
            SupabaseClient.storageUrl("object/$BUCKET/$path")
        ) {
            authHeaders(token)
        }
        when {
            response.status.isSuccess() -> response.bodyAsBytes()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /** Remove the stored logo. Gated server-side by the manager-only delete policy. */
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
        const val BUCKET = "vineyard-logos"
    }
}
