package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.GrowthStageImage
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
import java.time.Instant

/**
 * Online-first storage + metadata for per-vineyard custom E-L growth-stage
 * reference images, mirroring the iOS `GrowthStageImageSyncService` /
 * `ELStageImageStorageService`. The JPEG lives in the private
 * `vineyard-el-stage-images` bucket at `{vineyard_id}/el-stages/{stage_code}.jpg`
 * and a row in `vineyard_growth_stage_images` records the object path so iOS,
 * Lovable and Android all read/write the same images.
 *
 * Uploads + the metadata upsert + the soft-delete RPC are all gated server-side
 * by the owner/manager-only RLS policies (sql/013), so non-managers get a 401/403
 * and the UI stays read-only for them.
 */
class GrowthStageImageRepository(private val session: SessionStore) {

    /** Canonical bucket path, matching iOS `ELStageImageStorage.path`. */
    fun storagePath(vineyardId: String, stageCode: String): String {
        val safe = stageCode.replace("/", "_").replace(" ", "_")
        return "${vineyardId.lowercase()}/el-stages/$safe.jpg"
    }

    private fun nowIso(): String = Instant.now().toString()

    // MARK: - Metadata table

    /** Fetch all non-deleted custom stage-image rows for a vineyard. */
    suspend fun listImages(vineyardId: String): List<GrowthStageImage> =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.get(
                SupabaseClient.restUrl(
                    "vineyard_growth_stage_images?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=updated_at.desc",
                ),
            ) { authHeaders(token) }
            when {
                response.status.isSuccess() -> response.body()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /**
     * Upsert the metadata row for a stage image (conflict on the unique
     * `(vineyard_id, stage_code)`), returning the stored row. Gated by the
     * manager-only insert/update policies.
     */
    suspend fun upsertImage(
        vineyardId: String,
        stageCode: String,
        imagePath: String,
    ): GrowthStageImage = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val body = ImageUpsert(
            vineyardId = vineyardId,
            stageCode = stageCode,
            imagePath = imagePath,
            createdBy = session.userId,
            clientUpdatedAt = nowIso(),
        )
        val response = SupabaseClient.http.post(
            SupabaseClient.restUrl("vineyard_growth_stage_images?on_conflict=vineyard_id,stage_code"),
        ) {
            authHeaders(token)
            headers {
                append("Prefer", "return=representation,resolution=merge-duplicates")
            }
            contentType(ContentType.Application.Json)
            setBody(listOf(body))
        }
        when {
            response.status.isSuccess() -> response.body<List<GrowthStageImage>>().firstOrNull()
                ?: throw BackendError.Server(response.status.value, "Empty response")
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /** Soft-delete the metadata row via the manager-gated RPC. */
    suspend fun softDeleteImage(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(
            SupabaseClient.rpcUrl("soft_delete_growth_stage_image"),
        ) {
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

    // MARK: - Storage object

    /** Upload compressed JPEG bytes, upserting over any existing object. Returns the path. */
    suspend fun uploadObject(vineyardId: String, stageCode: String, jpeg: ByteArray): String =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val path = storagePath(vineyardId, stageCode)
            val response = SupabaseClient.http.post(
                SupabaseClient.storageUrl("object/$BUCKET/$path"),
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

    /** Mint a short-lived signed URL so Coil can load the private image. */
    suspend fun signedUrl(path: String, expiresInSeconds: Int = 3600): String =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.post(
                SupabaseClient.storageUrl("object/sign/$BUCKET/$path"),
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

    /** Download raw image bytes (used to decode a thumbnail/preview bitmap). */
    suspend fun download(path: String): ByteArray = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.get(SupabaseClient.storageUrl("object/$BUCKET/$path")) {
            authHeaders(token)
        }
        when {
            response.status.isSuccess() -> response.bodyAsBytes()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /** Remove the stored object. Gated server-side by the manager-only delete policy. */
    suspend fun deleteObject(path: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.delete(SupabaseClient.storageUrl("object/$BUCKET/$path")) {
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
    private data class ImageUpsert(
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("stage_code") val stageCode: String,
        @SerialName("image_path") val imagePath: String,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_image_id") val imageId: String)

    @Serializable
    private data class SignArgs(val expiresIn: Int)

    @Serializable
    private data class SignResponse(@SerialName("signedURL") val signedURL: String? = null)

    companion object {
        const val BUCKET = "vineyard-el-stage-images"
    }
}
