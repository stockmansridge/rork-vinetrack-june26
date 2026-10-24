package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.call.body
import io.ktor.client.request.delete
import io.ktor.client.request.get
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
class PinPhotoRepository(private val session: SessionStore) : PinPhotoObjectGateway {

    fun storagePath(vineyardId: String, pinId: String, revision: String? = null): String =
        pinStoragePath(vineyardId, pinId, revision)

    /**
     * Canonical path for a directly-authored growth-stage record photo. Android
     * growth records have no source pin, so they can't reuse the `pins/` path.
     * The first folder is still the vineyard id, so the shared bucket's
     * membership-based RLS applies unchanged. One photo per record, matching the
     * single pin photo iOS mirrors into `growth_stage_records.photo_paths`.
     */
    override fun growthStoragePath(vineyardId: String, recordId: String, revision: String?): String {
        val filename = revision?.let { "photo-${it.lowercase()}.jpg" } ?: "photo.jpg"
        return "${vineyardId.lowercase()}/growth/${recordId.lowercase()}/$filename"
    }

    /** Upload compressed JPEG bytes, upserting over any existing photo. Returns the object path. */
    override suspend fun upload(vineyardId: String, pinId: String, jpeg: ByteArray, revision: String?): String =
        uploadAtPath(storagePath(vineyardId, pinId, revision), jpeg)

    /** Upload compressed JPEG bytes to an explicit object path, upserting. Returns the path. */
    override suspend fun uploadAtPath(path: String, jpeg: ByteArray): String =
        withContext(Dispatchers.IO) {
            requireConfig()
            mutateObject(path) { vineyard, access ->
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.post(
                SupabaseClient.storageUrl("object/$BUCKET/$path")
            ) {
                attributes.put(SupabaseClient.accountRequestScope, access)
                attributes.put(SupabaseClient.operationalWriteVineyard, vineyard)
                authHeaders(token)
                headers {
                    append("x-upsert", "true")
                    append("cache-control", "3600")
                }
                setBody(ByteArrayContent(jpeg, ContentType.Image.JPEG))
            }
            if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, response.bodyAsText())
            path // Keep a real upload receipt even if authority changed in flight.
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

    /** Download private object bytes for durable offline display caching. */
    suspend fun download(path: String): ByteArray = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.get(SupabaseClient.storageUrl("object/authenticated/$BUCKET/$path")) {
            authHeaders(token)
        }
        when {
            response.status.isSuccess() -> response.body()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /** Remove the stored photo. Gated server-side by the manager-only delete policy. */
    suspend fun delete(path: String) = withContext(Dispatchers.IO) {
        requireConfig()
        mutateObject(path) { vineyard, access ->
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.delete(
                SupabaseClient.storageUrl("object/$BUCKET/$path")
            ) {
                attributes.put(SupabaseClient.accountRequestScope, access)
                attributes.put(SupabaseClient.operationalWriteVineyard, vineyard)
                authHeaders(token)
            }
            if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /** The canonical object key owns its scope, never the selected vineyard.
     * Capture the existing session incarnation so refresh/retry cannot retarget it. */
    private suspend fun <T> mutateObject(path: String, operation: suspend (String, com.rork.vinetrack.data.auth.AuthRetentionGuard.AccountAccess) -> T): T {
        val access = session.accountAccess() ?: throw BackendError.Unauthorized
        val gate = OperationalWrites.authority ?: throw BackendError.Unauthorized
        val vineyard = objectVineyard(path)
        val admission = TripWriteAdmission(
            isAccountCurrent = {
                session.isAccountAccessCurrent(access) && OperationalWrites.authority === gate &&
                    gate.accountBinding() == access.userId
            },
            resolve = { emptyList() },
        )
        return try {
            admission.send(vineyard) { operation(vineyard, access) }
        } catch (error: BackendError.Server) {
            // send classifies the structured expiry code BEFORE ordinary auth mapping.
            if (error.code == 401 || error.code == 403) throw BackendError.Unauthorized
            throw error
        }
    }

    private fun objectVineyard(path: String): String {
        val parts = path.split('/')
        val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
        if (parts.size != 4 || !uuid.matches(parts[0]) || parts[1] !in setOf("pins", "growth") ||
            !uuid.matches(parts[2]) || !Regex("photo(?:-[A-Za-z0-9_-]+)?\\.jpg").matches(parts[3])) {
            throw VineyardWriteAuthority.Restricted("WRITE_SCOPE_UNRESOLVED")
        }
        return parts[0].lowercase(java.util.Locale.ROOT)
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

        internal fun pinStoragePath(vineyardId: String, pinId: String, revision: String? = null): String {
            val filename = revision?.let { "photo-${it.lowercase()}.jpg" } ?: "photo.jpg"
            return "${vineyardId.lowercase()}/pins/${pinId.lowercase()}/$filename"
        }
    }
}
