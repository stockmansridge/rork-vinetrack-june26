package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.PruningBlockSetup
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningSegment
import io.ktor.client.call.body
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * Supabase data layer for the Pruning Tracker, mirroring the iOS
 * `SupabasePruningSyncRepository` contract (sql/109):
 *
 * * `pruning_seasons` — normal merge-duplicates upsert keyed by the
 *   deterministic season id; soft delete via `soft_delete_pruning_season`.
 * * `pruning_entries` + `pruning_row_segments` — READ-ONLY tables for
 *   clients; every write goes through the idempotent `record_pruning_entry`
 *   RPC (replay-safe: a quarter completed first on another device stays with
 *   that device's entry) or the explicit `delete_pruning_entry` RPC.
 */
class PruningSyncRepository(private val session: SessionStore) {

    @Serializable
    data class SeasonRow(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("paddock_id") val paddockId: String,
        @SerialName("season_year") val seasonYear: Int = 0,
        @SerialName("start_date") val startDate: String? = null,
        @SerialName("due_date") val dueDate: String? = null,
        @SerialName("pruning_method") val pruningMethod: String? = null,
        @SerialName("assigned_crew") val assignedCrew: String? = null,
        @SerialName("working_days") val workingDays: List<Int> = listOf(1, 2, 3, 4, 5),
        @SerialName("manual_row_count") val manualRowCount: Int? = null,
        @SerialName("estimated_labour_hours") val estimatedLabourHours: Double? = null,
        val notes: String? = null,
        @SerialName("deleted_at") val deletedAt: String? = null,
        @SerialName("updated_at") val updatedAt: String? = null,
    ) {
        fun toModel(): PruningBlockSetup = PruningBlockSetup(
            id = id,
            vineyardId = vineyardId,
            paddockId = paddockId,
            seasonYear = seasonYear,
            startDate = startDate?.take(10),
            dueDate = dueDate?.take(10),
            method = pruningMethod ?: "spur",
            crew = assignedCrew.orEmpty(),
            workingDays = workingDays,
            rowCountOverride = manualRowCount,
            estimatedLabourHours = estimatedLabourHours,
            notes = notes.orEmpty(),
        )
    }

    @Serializable
    private data class SeasonUpsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("paddock_id") val paddockId: String,
        @SerialName("season_year") val seasonYear: Int,
        @SerialName("start_date") val startDate: String? = null,
        @SerialName("due_date") val dueDate: String? = null,
        @SerialName("pruning_method") val pruningMethod: String,
        @SerialName("assigned_crew") val assignedCrew: String,
        @SerialName("working_days") val workingDays: List<Int>,
        @SerialName("manual_row_count") val manualRowCount: Int? = null,
        @SerialName("estimated_labour_hours") val estimatedLabourHours: Double? = null,
        val notes: String,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    data class EntryRow(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("pruning_season_id") val pruningSeasonId: String,
        @SerialName("paddock_id") val paddockId: String,
        @SerialName("entry_date") val entryDate: String? = null,
        @SerialName("worker_or_crew") val workerOrCrew: String? = null,
        @SerialName("labour_hours") val labourHours: Double? = null,
        @SerialName("start_time") val startTime: String? = null,
        @SerialName("finish_time") val finishTime: String? = null,
        @SerialName("pruning_method") val pruningMethod: String? = null,
        val notes: String? = null,
        @SerialName("row_equivalents_completed") val rowEquivalentsCompleted: Double? = null,
        @SerialName("estimated_vines_completed") val estimatedVinesCompleted: Int? = null,
        @SerialName("created_at") val createdAt: String? = null,
        @SerialName("deleted_at") val deletedAt: String? = null,
    ) {
        /** Segments are attributed separately from `pruning_row_segments`. */
        fun toModel(segments: List<PruningSegment>): PruningEntry = PruningEntry(
            id = id,
            vineyardId = vineyardId,
            paddockId = paddockId,
            seasonId = pruningSeasonId,
            date = entryDate?.take(10) ?: createdAt?.take(10) ?: LocalDate.now().toString(),
            segments = segments,
            worker = workerOrCrew.orEmpty(),
            labourHours = labourHours,
            startTime = toLocalHhmm(startTime),
            finishTime = toLocalHhmm(finishTime),
            method = pruningMethod ?: "spur",
            notes = notes.orEmpty(),
            estimatedVines = estimatedVinesCompleted ?: 0,
            createdAtMs = parseInstantMs(createdAt),
        )
    }

    @Serializable
    data class SegmentRow(
        val id: String,
        @SerialName("pruning_season_id") val pruningSeasonId: String,
        /** Stable paddock row id (sql/112); null for manual-fallback rows. */
        @SerialName("paddock_row_id") val paddockRowId: String? = null,
        @SerialName("row_number") val rowNumber: Int = 0,
        @SerialName("row_label") val rowLabel: String? = null,
        @SerialName("segment_number") val segmentNumber: Int = 0,
        val completed: Boolean = false,
        @SerialName("pruning_entry_id") val pruningEntryId: String? = null,
    )

    @Serializable
    private data class SegmentArg(
        val row: Int,
        val segment: Int,
        /** Stable paddock row id — the real identity for configured rows. */
        @SerialName("row_id") val rowId: String? = null,
        /** Display label snapshot for history/reporting. */
        val label: String? = null,
    )

    @Serializable
    private data class RecordEntryArgs(
        @SerialName("p_id") val id: String,
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_season_id") val seasonId: String,
        @SerialName("p_paddock_id") val paddockId: String,
        @SerialName("p_season_year") val seasonYear: Int,
        @SerialName("p_entry_date") val entryDate: String,
        @SerialName("p_worker") val worker: String,
        @SerialName("p_labour_hours") val labourHours: Double? = null,
        @SerialName("p_start_time") val startTime: String? = null,
        @SerialName("p_finish_time") val finishTime: String? = null,
        @SerialName("p_method") val method: String,
        @SerialName("p_notes") val notes: String,
        @SerialName("p_estimated_vines") val estimatedVines: Int,
        @SerialName("p_client_updated_at") val clientUpdatedAt: String,
        @SerialName("p_segments") val segments: List<SegmentArg>,
    )

    @Serializable
    private data class IdArgs(@SerialName("p_id") val id: String)

    // MARK: Reads

    suspend fun fetchSeasons(vineyardId: String): List<SeasonRow> =
        getList("pruning_seasons?vineyard_id=eq.$vineyardId&order=updated_at.asc")

    suspend fun fetchEntries(vineyardId: String): List<EntryRow> =
        getList("pruning_entries?vineyard_id=eq.$vineyardId&order=updated_at.asc")

    suspend fun fetchSegments(vineyardId: String): List<SegmentRow> =
        getList("pruning_row_segments?vineyard_id=eq.$vineyardId&completed=eq.true")

    // MARK: Writes

    suspend fun upsertSeason(setup: PruningBlockSetup) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val body = SeasonUpsert(
            id = setup.id,
            vineyardId = setup.vineyardId,
            paddockId = setup.paddockId,
            seasonYear = setup.seasonYear,
            startDate = setup.startDate,
            dueDate = setup.dueDate,
            pruningMethod = setup.method,
            assignedCrew = setup.crew,
            workingDays = setup.workingDays,
            manualRowCount = setup.rowCountOverride,
            estimatedLabourHours = setup.estimatedLabourHours,
            notes = setup.notes,
            createdBy = session.userId,
            clientUpdatedAt = Instant.now().toString(),
        )
        val response = SupabaseClient.http.post(SupabaseClient.restUrl("pruning_seasons?on_conflict=id")) {
            authHeaders(token)
            headers { append("Prefer", "resolution=merge-duplicates") }
            contentType(ContentType.Application.Json)
            setBody(listOf(body))
        }
        requireSuccess(response)
    }

    /** Idempotent — safe to replay from the offline queue. */
    suspend fun recordEntry(entry: PruningEntry) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val seasonYear = runCatching { LocalDate.parse(entry.date).year }
            .getOrDefault(LocalDate.now().year)
        val args = RecordEntryArgs(
            id = entry.id,
            vineyardId = entry.vineyardId,
            seasonId = entry.seasonId,
            paddockId = entry.paddockId,
            seasonYear = seasonYear,
            entryDate = entry.date,
            worker = entry.worker,
            labourHours = entry.labourHours,
            startTime = toInstantString(entry.date, entry.startTime),
            finishTime = toInstantString(entry.date, entry.finishTime),
            method = entry.method,
            notes = entry.notes,
            estimatedVines = entry.estimatedVines,
            clientUpdatedAt = Instant.now().toString(),
            segments = entry.segments.map {
                SegmentArg(row = it.row, segment = it.quarter, rowId = it.rowId, label = it.row.toString())
            },
        )
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("record_pruning_entry")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(args)
        }
        requireSuccess(response)
    }

    /** The ONLY way completed quarters revert (explicit authorised action). */
    suspend fun deleteEntry(entryId: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("delete_pruning_entry")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(IdArgs(entryId))
        }
        requireSuccess(response)
    }

    suspend fun softDeleteSeason(seasonId: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_pruning_season")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(IdArgs(seasonId))
        }
        requireSuccess(response)
    }

    // MARK: Plumbing

    private suspend inline fun <reified T> getList(pathAndQuery: String): List<T> =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.get(SupabaseClient.restUrl(pathAndQuery)) {
                authHeaders(token)
            }
            when {
                response.status.isSuccess() -> response.body<List<T>>()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    private suspend fun requireSuccess(response: HttpResponse) {
        when {
            response.status.isSuccess() -> Unit
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    private fun requireConfig() {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
    }

    private fun HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }

    companion object {
        private fun toInstantString(date: String, hhmm: String?): String? {
            if (hhmm.isNullOrBlank()) return null
            return runCatching {
                LocalDateTime.of(LocalDate.parse(date), LocalTime.parse(hhmm))
                    .atZone(ZoneId.systemDefault())
                    .toInstant()
                    .toString()
            }.getOrNull()
        }

        private fun toLocalHhmm(instant: String?): String? {
            if (instant.isNullOrBlank()) return null
            return runCatching {
                OffsetDateTime.parse(instant)
                    .atZoneSameInstant(ZoneId.systemDefault())
                    .toLocalTime()
                    .format(DateTimeFormatter.ofPattern("HH:mm"))
            }.getOrNull()
        }

        private fun parseInstantMs(instant: String?): Long {
            if (instant.isNullOrBlank()) return 0L
            return runCatching { OffsetDateTime.parse(instant).toInstant().toEpochMilli() }.getOrDefault(0L)
        }
    }
}
