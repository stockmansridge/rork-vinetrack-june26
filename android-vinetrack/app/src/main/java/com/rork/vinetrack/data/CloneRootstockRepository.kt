package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.CloneCatalogEntry
import com.rork.vinetrack.data.model.RootstockCatalogEntry
import com.rork.vinetrack.data.model.VineyardCloneRow
import com.rork.vinetrack.data.model.VineyardRootstockRow
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
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Shared clone + rootstock catalogue access (sql/182), mirroring the iOS
 * `SupabaseCloneRootstockCatalogRepository`. Global catalogues are readable
 * by any authenticated user; vineyard custom records are member-scoped via
 * SECURITY DEFINER RPCs (owner/manager to write).
 */
class CloneRootstockRepository(private val session: SessionStore) {

    @Serializable
    private data class VineyardIdArg(@SerialName("p_vineyard_id") val vineyardId: String)

    @Serializable
    private data class IdArg(@SerialName("p_id") val id: String)

    /** Global built-in clone catalogue (`get_grape_clone_catalog`). */
    suspend fun getCloneCatalog(): List<CloneCatalogEntry> =
        rpc<VineyardIdArg, List<CloneCatalogEntry>>("get_grape_clone_catalog", null)

    /** Global built-in rootstock catalogue (`get_rootstock_catalog`). */
    suspend fun getRootstockCatalog(): List<RootstockCatalogEntry> =
        rpc<VineyardIdArg, List<RootstockCatalogEntry>>("get_rootstock_catalog", null)

    suspend fun listVineyardClones(vineyardId: String): List<VineyardCloneRow> =
        rpc("list_vineyard_grape_clones", VineyardIdArg(vineyardId))

    suspend fun listVineyardRootstocks(vineyardId: String): List<VineyardRootstockRow> =
        rpc("list_vineyard_rootstocks", VineyardIdArg(vineyardId))

    /**
     * Creates/updates a vineyard-scoped CUSTOM clone via
     * `upsert_vineyard_grape_clone`. The parent variety key is REQUIRED —
     * a built-in key (`shiraz`) or the vineyard's `custom:<vid>:<slug>`
     * variety key. The server derives a stable
     * `custom:<vid>:<varietySlug>:<slug>` clone key. Owner/manager only.
     */
    suspend fun upsertVineyardClone(
        vineyardId: String,
        varietyKey: String,
        displayName: String,
        isActive: Boolean = true,
    ): VineyardCloneRow = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("upsert_vineyard_grape_clone")) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody(buildJsonObject {
                put("p_vineyard_id", vineyardId)
                put("p_variety_key", varietyKey)
                put("p_display_name", displayName)
                put("p_is_active", isActive)
            })
        }
        when {
            response.status.isSuccess() -> response.body()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /** Creates/updates a vineyard-scoped CUSTOM rootstock. Owner/manager only. */
    suspend fun upsertVineyardRootstock(
        vineyardId: String,
        displayName: String,
        isActive: Boolean = true,
    ): VineyardRootstockRow = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("upsert_vineyard_rootstock")) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody(buildJsonObject {
                put("p_vineyard_id", vineyardId)
                put("p_display_name", displayName)
                put("p_is_active", isActive)
            })
        }
        when {
            response.status.isSuccess() -> response.body()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    suspend fun archiveVineyardClone(id: String): VineyardCloneRow =
        rpc("archive_vineyard_grape_clone", IdArg(id))

    suspend fun archiveVineyardRootstock(id: String): VineyardRootstockRow =
        rpc("archive_vineyard_rootstock", IdArg(id))

    private suspend inline fun <reified B, reified T> rpc(name: String, arg: B?): T =
        withContext(Dispatchers.IO) {
            if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(name)) {
                headers {
                    append("apikey", SupabaseClient.anonKey)
                    append("Authorization", "Bearer $token")
                }
                contentType(ContentType.Application.Json)
                if (arg != null) setBody(arg) else setBody(buildJsonObject {})
            }
            when {
                response.status.isSuccess() -> response.body()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }
}
