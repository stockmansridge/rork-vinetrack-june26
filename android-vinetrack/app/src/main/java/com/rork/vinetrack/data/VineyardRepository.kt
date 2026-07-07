package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.AppNotice
import com.rork.vinetrack.data.model.OperatorCategory
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.data.model.GrapeVarietyRow
import com.rork.vinetrack.data.model.FuelPurchase
import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.model.MaintenanceLog
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.SavedInput
import com.rork.vinetrack.data.model.SavedSprayPreset
import com.rork.vinetrack.data.model.SprayEquipment
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.TractorFuelLog
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.Vineyard
import com.rork.vinetrack.data.model.VineyardMachine
import com.rork.vinetrack.data.model.VineyardMember
import com.rork.vinetrack.data.model.WorkTask
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.patch
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Reads vineyard-scoped data from the Supabase PostgREST API, mirroring the
 * iOS `SupabaseVineyardRepository` and related repositories. RLS on the server
 * scopes every query to the signed-in user's memberships.
 */
class VineyardRepository(private val session: SessionStore) {

    suspend fun listMyVineyards(): List<Vineyard> = withContext(Dispatchers.IO) {
        get("vineyards?select=*&deleted_at=is.null&order=name.asc")
    }

    /**
     * Creates a vineyard and makes the caller its owner via the SECURITY
     * DEFINER `create_vineyard_with_owner` RPC — the exact contract used by the
     * iOS `SupabaseVineyardRepository.createVineyard` (`p_name` / `p_country`).
     * Returns the created vineyard row.
     */
    suspend fun createVineyard(name: String, country: String?): Vineyard =
        withContext(Dispatchers.IO) {
            if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("create_vineyard_with_owner")) {
                headers {
                    append("apikey", SupabaseClient.anonKey)
                    append("Authorization", "Bearer $token")
                }
                contentType(ContentType.Application.Json)
                setBody(CreateVineyardArg(name = name, country = country))
            }
            when {
                response.status.isSuccess() -> {
                    val rows: List<Vineyard> = response.body()
                    rows.firstOrNull()
                        ?: throw BackendError.Server(response.status.value, "empty response")
                }
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    suspend fun listPaddocks(vineyardId: String): List<Paddock> = withContext(Dispatchers.IO) {
        get("paddocks?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=name.asc")
    }

    suspend fun listPins(vineyardId: String): List<Pin> = withContext(Dispatchers.IO) {
        get("pins?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=created_at.desc")
    }

    suspend fun listTrips(vineyardId: String): List<Trip> = withContext(Dispatchers.IO) {
        get("trips?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=start_time.desc")
    }

    suspend fun listMachines(vineyardId: String): List<VineyardMachine> = withContext(Dispatchers.IO) {
        get("vineyard_machines?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=name.asc")
    }

    suspend fun listWorkTasks(vineyardId: String): List<WorkTask> = withContext(Dispatchers.IO) {
        get("work_tasks?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&is_archived=eq.false&order=date.desc")
    }

    suspend fun listSprayRecords(vineyardId: String): List<SprayRecord> = withContext(Dispatchers.IO) {
        get("spray_records?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=date.desc")
    }

    suspend fun listSprayEquipment(vineyardId: String): List<SprayEquipment> = withContext(Dispatchers.IO) {
        get("spray_equipment?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=name.asc")
    }

    suspend fun listSavedChemicals(vineyardId: String): List<SavedChemical> = withContext(Dispatchers.IO) {
        get("saved_chemicals?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=name.asc")
    }

    suspend fun listSavedSprayPresets(vineyardId: String): List<SavedSprayPreset> = withContext(Dispatchers.IO) {
        get("saved_spray_presets?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=name.asc")
    }

    suspend fun listSavedInputs(vineyardId: String): List<SavedInput> = withContext(Dispatchers.IO) {
        get("saved_inputs?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=name.asc")
    }

    suspend fun listMaintenanceLogs(vineyardId: String): List<MaintenanceLog> = withContext(Dispatchers.IO) {
        get("maintenance_logs?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=date.desc")
    }

    suspend fun listGrowthStageRecords(vineyardId: String): List<GrowthStageRecord> = withContext(Dispatchers.IO) {
        get("growth_stage_records?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=observed_at.desc")
    }

    suspend fun listFuelLogs(vineyardId: String): List<TractorFuelLog> = withContext(Dispatchers.IO) {
        get("tractor_fuel_logs?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=fill_datetime.desc")
    }

    /**
     * Reads `fuel_purchases` for the vineyard (Stage 3F-3a). Read-only: used to
     * derive a weighted average cost per litre for trip fuel estimates. Android
     * never writes this table.
     */
    suspend fun listFuelPurchases(vineyardId: String): List<FuelPurchase> = withContext(Dispatchers.IO) {
        get("fuel_purchases?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=date.desc")
    }

    suspend fun listOperatorCategories(vineyardId: String): List<OperatorCategory> = withContext(Dispatchers.IO) {
        get("operator_categories?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=name.asc")
    }

    /**
     * Loads currently-active app-wide notices ("system messages") from the
     * `app_notices` table, ordered by priority then recency. Mirrors the iOS
     * `SupabaseAppNoticeRepository.fetchActiveNotices`. Start/end windows are
     * filtered client-side so timezone handling matches the device clock.
     */
    suspend fun listActiveNotices(): List<AppNotice> = withContext(Dispatchers.IO) {
        val rows: List<AppNotice> = get(
            "app_notices?select=*&is_active=eq.true&deleted_at=is.null&order=priority.desc,created_at.desc"
        )
        rows.filter { it.isCurrentlyVisible() }
    }

    /**
     * Loads the active vineyard's team members via the SECURITY DEFINER
     * `get_vineyard_team_members` RPC, which resolves display names + each
     * member's default operator category without weakening profiles RLS
     * (sql/022 + sql/082). Mirrors the iOS `SupabaseTeamRepository.listMembers`.
     */
    suspend fun listTeamMembers(vineyardId: String): List<VineyardMember> = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("get_vineyard_team_members")) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody(VineyardIdArg(vineyardId))
        }
        when {
            response.status.isSuccess() -> response.body()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, "")
        }
    }

    @Serializable
    private data class VineyardIdArg(@SerialName("p_vineyard_id") val vineyardId: String)

    /**
     * Lists the vineyard's grape variety catalog selections via the
     * SECURITY DEFINER `list_vineyard_grape_varieties` RPC (sql/073). Returns
     * built-in selections + custom varieties; any vineyard member may read.
     * Mirrors the iOS `SupabaseGrapeVarietyCatalogRepository.listVineyardVarieties`.
     */
    suspend fun listGrapeVarieties(vineyardId: String): List<GrapeVarietyRow> = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("list_vineyard_grape_varieties")) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody(VineyardIdArg(vineyardId))
        }
        when {
            response.status.isSuccess() -> response.body()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, "")
        }
    }

    /**
     * Upserts a vineyard variety selection via the owner/manager-gated
     * `upsert_vineyard_grape_variety` RPC (sql/073). Pass a built-in [key]
     * (e.g. `pinot_gris`) OR `key = null` plus a [displayName] to create a
     * custom variety — the server derives a stable `custom:<vineyardId>:<slug>`
     * key. Mirrors the iOS `SupabaseGrapeVarietyCatalogRepository.upsertVineyardVariety`.
     *
     * NOTE: We build the body with [buildJsonObject] so `p_variety_key` is
     * always emitted (as JSON `null` when creating a custom variety). The
     * shared [SupabaseClient.json] has `explicitNulls = false`, which would
     * otherwise strip the key and make PostgREST fail to resolve the 5-arg RPC
     * overload — the exact bug the iOS custom encoder guards against.
     */
    suspend fun upsertVineyardVariety(
        vineyardId: String,
        key: String?,
        displayName: String,
        optimalGddOverride: Double?,
        isActive: Boolean = true,
    ): GrapeVarietyRow = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("upsert_vineyard_grape_variety")) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody(buildJsonObject {
                put("p_vineyard_id", vineyardId)
                put("p_variety_key", key)
                put("p_display_name", displayName)
                put("p_optimal_gdd_override", optimalGddOverride)
                put("p_is_active", isActive)
            })
        }
        when {
            response.status.isSuccess() -> response.body()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /**
     * Archives a vineyard variety via `archive_vineyard_grape_variety` (sql/073):
     * hidden from active lists but kept for historical records. Owner/manager
     * only. Mirrors the iOS `archiveVineyardVariety`.
     */
    suspend fun archiveVineyardVariety(id: String): Unit = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("archive_vineyard_grape_variety")) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody(GrapeVarietyArchiveArg(id))
        }
        when {
            response.status.isSuccess() -> Unit
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /**
     * Permanently deletes an unused custom variety via
     * `hard_delete_unused_custom_grape_variety` (sql/089). The RPC is the safety
     * gate — it refuses built-ins and any variety referenced by paddock
     * allocations, growth records, or trip cost rows — and returns a structured
     * status the caller maps to a [GrapeVarietyDeleteOutcome]. Mirrors the iOS
     * `hardDeleteUnusedCustomGrapeVariety` + `CustomGrapeVarietyDeletionOutcome`.
     */
    suspend fun hardDeleteUnusedCustomGrapeVariety(id: String): GrapeVarietyDeleteOutcome =
        withContext(Dispatchers.IO) {
            if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.post(
                SupabaseClient.rpcUrl("hard_delete_unused_custom_grape_variety")
            ) {
                headers {
                    append("apikey", SupabaseClient.anonKey)
                    append("Authorization", "Bearer $token")
                }
                contentType(ContentType.Application.Json)
                setBody(GrapeVarietyHardDeleteArg(id))
            }
            when {
                response.status.isSuccess() -> {
                    val result = response.body<GrapeVarietyHardDeleteResult>()
                    when (result.status) {
                        "hard_deleted" -> GrapeVarietyDeleteOutcome.Deleted
                        "variety_in_use" -> GrapeVarietyDeleteOutcome.InUse(
                            result.message
                                ?: "This grape variety is used by existing vineyard records and cannot be permanently deleted.",
                        )
                        "not_found" -> GrapeVarietyDeleteOutcome.NotFound
                        "not_custom", "system_variety" -> GrapeVarietyDeleteOutcome.NotCustom
                        "not_authorised" -> GrapeVarietyDeleteOutcome.NotAuthorised
                        else -> GrapeVarietyDeleteOutcome.Failed(
                            result.message ?: "Could not delete this grape variety. Please try again.",
                        )
                    }
                }
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /**
     * Updates a vineyard's name and country only (logo_path intentionally left
     * untouched). Mirrors the iOS `SupabaseVineyardRepository.updateVineyard`,
     * which PATCHes `{name, country}` directly. RLS scopes the write to
     * owners/managers of the vineyard.
     */
    suspend fun updateVineyard(id: String, name: String, country: String?): Unit =
        withContext(Dispatchers.IO) {
            if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.patch(SupabaseClient.restUrl("vineyards?id=eq.$id")) {
                headers {
                    append("apikey", SupabaseClient.anonKey)
                    append("Authorization", "Bearer $token")
                }
                contentType(ContentType.Application.Json)
                setBody(VineyardUpdate(name = name, country = country))
            }
            when {
                response.status.isSuccess() -> Unit
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /**
     * Sets or clears the vineyard's `logo_path` and bumps `logo_updated_at` so
     * other devices know to refetch the logo. Mirrors the iOS
     * `SupabaseVineyardRepository.updateVineyardLogoPath`. Returns the new
     * `logo_updated_at` value as reported by the database (or the local stamp
     * sent if the server echoes nothing). RLS scopes the write to
     * owners/managers.
     */
    suspend fun updateVineyardLogoPath(id: String, logoPath: String?): String? =
        withContext(Dispatchers.IO) {
            if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val now = java.time.Instant.now().toString()
            val response = SupabaseClient.http.patch(
                SupabaseClient.restUrl("vineyards?id=eq.$id&select=logo_updated_at")
            ) {
                headers {
                    append("apikey", SupabaseClient.anonKey)
                    append("Authorization", "Bearer $token")
                    append("Prefer", "return=representation")
                }
                contentType(ContentType.Application.Json)
                setBody(VineyardLogoUpdate(logoPath = logoPath, logoUpdatedAt = now))
            }
            when {
                response.status.isSuccess() -> {
                    val rows: List<VineyardLogoUpdateResponse> = response.body()
                    rows.firstOrNull()?.logoUpdatedAt ?: now
                }
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /**
     * Archives a vineyard for the whole team via the owner-gated
     * `archive_vineyard` RPC (mirrors the iOS `archiveVineyard`). The server
     * soft-deletes and detaches members; only the owner may call it.
     */
    suspend fun archiveVineyard(id: String): Unit = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("archive_vineyard")) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody(ArchiveVineyardArg(id))
        }
        when {
            response.status.isSuccess() -> Unit
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /**
     * Persists the vineyard's coordinates, elevation and timezone via the
     * owner/manager-gated `set_vineyard_location` RPC (sql/083). Mirrors the iOS
     * `SupabaseVineyardRepository.setVineyardLocation`. Returns the stored row so
     * callers can reflect server-normalised values.
     */
    suspend fun setVineyardLocation(
        vineyardId: String,
        latitude: Double?,
        longitude: Double?,
        elevationMetres: Double?,
        timezone: String?,
    ): BackendVineyardLocation = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("set_vineyard_location")) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody(
                SetVineyardLocationArg(
                    vineyardId = vineyardId,
                    latitude = latitude,
                    longitude = longitude,
                    elevationMetres = elevationMetres,
                    timezone = timezone?.trim()?.ifBlank { null },
                )
            )
        }
        when {
            response.status.isSuccess() -> {
                val rows: List<BackendVineyardLocation> = response.body()
                rows.firstOrNull() ?: throw BackendError.Server(response.status.value, "empty response")
            }
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    @Serializable
    data class BackendVineyardLocation(
        @SerialName("vineyard_id") val vineyardId: String? = null,
        val latitude: Double? = null,
        val longitude: Double? = null,
        @SerialName("elevation_metres") val elevationMetres: Double? = null,
        val timezone: String? = null,
    )

    @Serializable
    private data class SetVineyardLocationArg(
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_latitude") val latitude: Double?,
        @SerialName("p_longitude") val longitude: Double?,
        @SerialName("p_elevation_metres") val elevationMetres: Double?,
        @SerialName("p_timezone") val timezone: String?,
    )

    @Serializable
    private data class CreateVineyardArg(
        @SerialName("p_name") val name: String,
        @SerialName("p_country") val country: String?,
    )

    @Serializable
    private data class VineyardUpdate(val name: String, val country: String?)

    @Serializable
    private data class VineyardLogoUpdate(
        @SerialName("logo_path") val logoPath: String?,
        @SerialName("logo_updated_at") val logoUpdatedAt: String,
    )

    @Serializable
    private data class VineyardLogoUpdateResponse(
        @SerialName("logo_updated_at") val logoUpdatedAt: String? = null,
    )

    @Serializable
    private data class ArchiveVineyardArg(@SerialName("p_vineyard_id") val vineyardId: String)

    @Serializable
    private data class GrapeVarietyArchiveArg(@SerialName("p_id") val id: String)

    @Serializable
    private data class GrapeVarietyHardDeleteArg(@SerialName("p_variety_id") val id: String)

    /**
     * Mirrors the `jsonb { success, status, message }` returned by
     * `hard_delete_unused_custom_grape_variety` (sql/089).
     */
    @Serializable
    private data class GrapeVarietyHardDeleteResult(
        val success: Boolean = false,
        val status: String = "unknown",
        val message: String? = null,
    )

    private suspend inline fun <reified T> get(path: String): T {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.get(SupabaseClient.restUrl(path)) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
        }
        when {
            response.status.isSuccess() -> return response.body()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, "")
        }
    }
}

/**
 * Clean outcome for the grape-variety hard-delete flow, mirroring the iOS
 * `CustomGrapeVarietyDeletionOutcome`. The UI switches on these to either
 * remove the row, offer an archive-instead fallback, or surface a message.
 */
sealed interface GrapeVarietyDeleteOutcome {
    object Deleted : GrapeVarietyDeleteOutcome
    object NotFound : GrapeVarietyDeleteOutcome
    data class InUse(val message: String) : GrapeVarietyDeleteOutcome
    object NotCustom : GrapeVarietyDeleteOutcome
    object NotAuthorised : GrapeVarietyDeleteOutcome
    data class Failed(val message: String) : GrapeVarietyDeleteOutcome
}
