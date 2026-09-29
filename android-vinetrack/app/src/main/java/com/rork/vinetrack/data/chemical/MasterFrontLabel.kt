package com.rork.vinetrack.data.chemical

import android.content.Context
import java.io.File
import java.security.MessageDigest
import com.rork.vinetrack.data.SupabaseClient
import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsBytes
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** The same approved-only, versioned projection used by iOS and Portal. */
@Serializable
data class MasterFrontLabel(
    @SerialName("master_chemical_id") val masterChemicalId: String,
    @SerialName("registration_identity_key") val registrationIdentityKey: String,
    @SerialName("document_sha256") val documentSha256: String,
    @SerialName("source_url") val sourceUrl: String,
    @SerialName("document_version") val documentVersion: String? = null,
    @SerialName("physical_page") val physicalPage: Int,
    @SerialName("pdf_path") val pdfPath: String,
    @SerialName("full_image_path") val fullImagePath: String,
    @SerialName("thumbnail_path") val thumbnailPath: String,
) {
    fun belongsTo(id: String?, identity: String?): Boolean = id != null && identity != null &&
        id == masterChemicalId && identity == registrationIdentityKey &&
        documentSha256.matches(Regex("[a-f0-9]{64}")) && physicalPage > 0 &&
        thumbnailPath == "${id.lowercase()}/$documentSha256/thumb-p$physicalPage.webp" &&
        fullImagePath == "${id.lowercase()}/$documentSha256/front-p$physicalPage.png"
}

class MasterFrontLabelRepository {
    companion object {
        private var appContext: Context? = null
        fun initialize(context: Context) { appContext = context.applicationContext }
    }

    private fun cacheKey(path: String): String = MessageDigest.getInstance("SHA-256")
        .digest(path.toByteArray()).joinToString("") { "%02x".format(it) }

    private fun cached(ids: List<String>): Map<String, MasterFrontLabel> {
        val context = appContext ?: return emptyMap()
        val user = SessionStore(context).userId ?: return emptyMap()
        val prefs = context.getSharedPreferences("master_front_label_v1", Context.MODE_PRIVATE)
        return ids.mapNotNull { id ->
            val row = runCatching { SupabaseClient.json.decodeFromString<MasterFrontLabel>(prefs.getString("$user|$id", "")!!) }.getOrNull()
            row?.takeIf { it.belongsTo(id, it.registrationIdentityKey) }?.let { id to it }
        }.toMap()
    }

    suspend fun list(ids: List<String>): Map<String, MasterFrontLabel> = withContext(Dispatchers.IO) {
        if (ids.isEmpty()) return@withContext emptyMap()
        val token = SupabaseClient.sessionRefresher?.sessionAccessToken ?: return@withContext emptyMap()
        val user = appContext?.let { SessionStore(it).userId } ?: return@withContext emptyMap()
        val unique = ids.distinct()
        try {
            val rows = unique.chunked(100).flatMap { chunk ->
                val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("get_approved_chemical_media")) {
                    headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
                    contentType(ContentType.Application.Json)
                    setBody(SupabaseClient.json.encodeToString(ListArgs(chunk)))
                }
                if (response.status.value == 401 || response.status.value == 403) return@withContext emptyMap()
                if (!response.status.isSuccess()) error("Media projection unavailable")
                SupabaseClient.json.decodeFromString<List<MasterFrontLabel>>(response.bodyAsText())
            }.filter { it.masterChemicalId in unique && it.belongsTo(it.masterChemicalId, it.registrationIdentityKey) }
                .associateBy { it.masterChemicalId }
            appContext?.getSharedPreferences("master_front_label_v1", Context.MODE_PRIVATE)?.edit()?.also { editor ->
                unique.forEach { id ->
                    rows[id]?.let { editor.putString("$user|$id", SupabaseClient.json.encodeToString(it)) } ?: editor.remove("$user|$id")
                }
                editor.commit()
            }
            rows
        } catch (_: Exception) { cached(unique) }
    }

    suspend fun image(path: String, thumbnail: Boolean = false): ByteArray? = withContext(Dispatchers.IO) {
        val token = SupabaseClient.sessionRefresher?.sessionAccessToken ?: return@withContext null
        val valid = Regex("[0-9a-f-]{36}/[0-9a-f]{64}/thumb-p[1-9][0-9]*\\.webp").matches(path)
        val file = appContext?.let { File(File(it.filesDir, "master-label-thumbnails"), cacheKey(path)) }
        if (thumbnail && valid && file?.isFile == true) return@withContext file.readBytes()
        try {
            val response = SupabaseClient.http.get(SupabaseClient.storageUrl("object/master-chemical-media/$path")) {
                headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
            }
            if (!response.status.isSuccess()) return@withContext null
            val bytes = response.bodyAsBytes()
            if (thumbnail && valid && bytes.size in 1..262144 && file != null) {
                file.parentFile?.mkdirs()
                file.writeBytes(bytes)
            }
            bytes
        } catch (_: Exception) { null }
    }

    @Serializable private data class ListArgs(val p_master_ids: List<String>)
}
