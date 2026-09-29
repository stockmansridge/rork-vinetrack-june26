package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.SupabaseClient
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
    suspend fun list(ids: List<String>): Map<String, MasterFrontLabel> = withContext(Dispatchers.IO) {
        if (ids.isEmpty()) return@withContext emptyMap()
        val token = SupabaseClient.sessionRefresher?.sessionAccessToken ?: return@withContext emptyMap()
        ids.distinct().chunked(100).flatMap { chunk ->
            val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("get_approved_chemical_media")) {
                headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
                contentType(ContentType.Application.Json)
                setBody(SupabaseClient.json.encodeToString(ListArgs(chunk)))
            }
            if (!response.status.isSuccess()) emptyList()
            else SupabaseClient.json.decodeFromString<List<MasterFrontLabel>>(response.bodyAsText())
        }.associateBy { it.masterChemicalId }
    }

    suspend fun image(path: String): ByteArray? = withContext(Dispatchers.IO) {
        val token = SupabaseClient.sessionRefresher?.sessionAccessToken ?: return@withContext null
        val response = SupabaseClient.http.get(SupabaseClient.storageUrl("object/master-chemical-media/$path")) {
            headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
        }
        if (response.status.isSuccess()) response.bodyAsBytes() else null
    }

    @Serializable private data class ListArgs(val p_master_ids: List<String>)
}
