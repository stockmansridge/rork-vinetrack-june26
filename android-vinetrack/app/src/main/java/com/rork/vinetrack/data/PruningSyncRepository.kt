package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.PruningActivityCanonical
import com.rork.vinetrack.data.model.PruningActivityDraft
import com.rork.vinetrack.data.model.PruningBlockSetup
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningSeasonIds
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
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
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

    /**
     * PostgREST resolves RPC functions by the EXACT set of provided argument
     * names — a missing key only resolves when the SQL parameter has a
     * default. The shared [SupabaseClient.json] uses `explicitNulls = false`,
     * which silently DROPPED `p_labour_hours` / `p_start_time` /
     * `p_finish_time` for entries recorded without hours or times, producing
     * a 12-argument call the server could not match (PGRST202 "Could not
     * find the function") that wedged the entry in the offline queue
     * forever. RPC bodies are therefore encoded with explicit nulls so the
     * call shape never varies with which optional fields are filled in.
     */
    private val rpcJson = Json {
        encodeDefaults = true
        explicitNulls = true
    }

    /** Lenient decoder for RPC JSON responses. */
    private val resultJson = Json { ignoreUnknownKeys = true }

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
        @SerialName("work_task_id") val workTaskId: String? = null,
        /** Parent activity (sql/166); the server back-fills legacy rows with their own id. */
        @SerialName("pruning_activity_id") val pruningActivityId: String? = null,
        @SerialName("allocation_index") val allocationIndex: Int? = null,
        @SerialName("created_at") val createdAt: String? = null,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("updated_at") val updatedAt: String? = null,
        @SerialName("deleted_at") val deletedAt: String? = null,
    ) {
        /**
         * Segments are attributed separately from `pruning_row_segments`.
         *
         * [serverSeasonYear] is `pruning_seasons.season_year` of this row's own
         * season as the SERVER has it — the pulled row IS the server's
         * acknowledgement, so it doubles as the canonical-season confirmation
         * used by [PruningSyncIntegrity].
         */
        fun toModel(segments: List<PruningSegment>, serverSeasonYear: Int? = null): PruningEntry = PruningEntry(
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
            workTaskId = workTaskId,
            pruningActivityId = pruningActivityId,
            allocationIndex = allocationIndex ?: 0,
            createdAtMs = parseInstantMs(createdAt),
            updatedAtMs = parseInstantMs(updatedAt),
            enteredBy = createdBy,
            reversedAtMs = parseInstantMs(deletedAt),
            serverSeasonId = pruningSeasonId,
            serverSeasonYear = serverSeasonYear,
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

    /** One quarter as the RPCs expect it: {row, segment, row_id, label}. */
    @Serializable
    data class SegmentArg(
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
        /** Optional Work Task link (sql/113). */
        @SerialName("p_work_task_id") val workTaskId: String? = null,
    )

    @Serializable
    private data class UpdateEntryArgs(
        @SerialName("p_entry_id") val entryId: String,
        @SerialName("p_entry_date") val entryDate: String,
        @SerialName("p_worker") val worker: String,
        @SerialName("p_labour_hours") val labourHours: Double? = null,
        @SerialName("p_start_time") val startTime: String? = null,
        @SerialName("p_finish_time") val finishTime: String? = null,
        @SerialName("p_method") val method: String,
        @SerialName("p_notes") val notes: String,
        @SerialName("p_estimated_vines") val estimatedVines: Int,
        @SerialName("p_segments") val segments: List<SegmentArg>,
        @SerialName("p_work_task_id") val workTaskId: String? = null,
        @SerialName("p_clear_work_task") val clearWorkTask: Boolean = false,
        @SerialName("p_client_updated_at") val clientUpdatedAt: String,
    )

    /** One quarter the edit could not attribute (owned by another entry). */
    @Serializable
    data class UpdateEntryConflict(
        val row: Int? = null,
        val segment: Int? = null,
        val reason: String? = null,
    )

    /**
     * Structured response of `record_pruning_entry` (sql/161). The server
     * resolves the CANONICAL season from the entry date and returns it, so the
     * client adopts the server's row instead of keeping its own guess.
     */
    @Serializable
    data class RecordEntryResult(
        @SerialName("entry_id") val entryId: String? = null,
        @SerialName("season_id") val seasonId: String? = null,
        @SerialName("season_year") val seasonYear: Int? = null,
        @SerialName("season_year_requested") val seasonYearRequested: Int? = null,
        /** True when the server used a season other than the requested one. */
        @SerialName("season_corrected") val seasonCorrected: Boolean? = null,
        /** True when an ALREADY-STORED entry sits under a non-canonical season. */
        @SerialName("season_mismatch") val seasonMismatch: Boolean? = null,
        @SerialName("vintage_year") val vintageYear: Int? = null,
        val requested: Int? = null,
        val attributed: Int? = null,
        val deleted: Boolean? = null,
    )

    /**
     * Structured response of `update_pruning_entry` (sql/120 + sql/161). A date
     * edit that crosses a pruning year re-points the entry server-side and
     * reports the canonical season it now belongs to, which the client adopts.
     */
    @Serializable
    data class UpdateEntryResult(
        @SerialName("entry_id") val entryId: String? = null,
        @SerialName("season_id") val seasonId: String? = null,
        @SerialName("season_year") val seasonYear: Int? = null,
        /** True when the edited date moved the entry to another season. */
        @SerialName("season_changed") val seasonChanged: Boolean? = null,
        @SerialName("vintage_year") val vintageYear: Int? = null,
        val requested: Int? = null,
        val attributed: Int? = null,
        val removed: Int? = null,
        val added: Int? = null,
        val conflicts: List<UpdateEntryConflict> = emptyList(),
        @SerialName("work_task_conflict") val workTaskConflict: Boolean? = null,
        /** "entry_not_found" (create hasn't landed — retry) or "entry_reversed". */
        val error: String? = null,
        /** True when a newer edit already applied — this edit is obsolete. */
        val stale: Boolean? = null,
    )

    // MARK: Multi-block activities (sql/166)

    /**
     * ACTIVITY-level payload. Labour, timing, rate, notes and the Work Task
     * link appear here EXACTLY ONCE and are never repeated per block.
     *
     * Encoded with explicit nulls: `update_pruning_activity` distinguishes an
     * absent key ("leave unchanged") from an explicit null ("clear it"), so a
     * full-desired-state edit must always send every key.
     */
    @Serializable
    data class ActivityPayload(
        @SerialName("entry_date") val entryDate: String,
        @SerialName("worker_or_crew") val workerOrCrew: String,
        val method: String,
        @SerialName("start_time") val startTime: String? = null,
        @SerialName("finish_time") val finishTime: String? = null,
        @SerialName("labour_hours") val labourHours: Double? = null,
        @SerialName("hourly_rate") val hourlyRate: Double? = null,
        val notes: String = "",
        @SerialName("work_task_id") val workTaskId: String? = null,
        @SerialName("clear_work_task") val clearWorkTask: Boolean = false,
    )

    /** ALLOCATION-level payload — one block, its own rows/quarters and vines. */
    @Serializable
    data class AllocationPayload(
        val id: String,
        @SerialName("paddock_id") val paddockId: String,
        val segments: List<SegmentArg>,
        val quarters: Int,
        @SerialName("estimated_vines") val estimatedVines: Int,
    )

    @Serializable
    private data class RecordActivityArgs(
        @SerialName("p_activity_id") val activityId: String,
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_activity") val activity: ActivityPayload,
        @SerialName("p_allocations") val allocations: List<AllocationPayload>,
        @SerialName("p_client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class UpdateActivityArgs(
        @SerialName("p_activity_id") val activityId: String,
        @SerialName("p_activity") val activity: ActivityPayload,
        @SerialName("p_allocations") val allocations: List<AllocationPayload>,
        @SerialName("p_client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class ReverseActivityArgs(
        @SerialName("p_activity_id") val activityId: String,
        @SerialName("p_reason") val reason: String? = null,
    )

    @Serializable
    private data class ActivityIdArgs(@SerialName("p_activity_id") val activityId: String)

    @Serializable
    private data class ListActivitiesArgs(
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_include_reversed") val includeReversed: Boolean = true,
        @SerialName("p_limit") val limit: Int = 500,
    )

    /** One quarter an activity write could not attribute, with its block. */
    @Serializable
    data class ActivityConflict(
        @SerialName("paddock_id") val paddockId: String? = null,
        val row: Int? = null,
        val segment: Int? = null,
        val reason: String? = null,
    )

    @Serializable
    data class AllocationResult(
        @SerialName("allocation_id") val allocationId: String? = null,
        @SerialName("paddock_id") val paddockId: String? = null,
        @SerialName("allocation_index") val allocationIndex: Int? = null,
        @SerialName("pruning_season_id") val pruningSeasonId: String? = null,
        @SerialName("season_year") val seasonYear: Int? = null,
        @SerialName("vintage_year") val vintageYear: Int? = null,
        @SerialName("season_changed") val seasonChanged: Boolean? = null,
        val requested: Int? = null,
        val attributed: Int? = null,
        val removed: Int? = null,
        @SerialName("duplicates_removed") val duplicatesRemoved: Int? = null,
        val conflicts: List<ActivityConflict> = emptyList(),
    )

    @Serializable
    data class RemovedAllocation(
        @SerialName("allocation_id") val allocationId: String? = null,
        @SerialName("paddock_id") val paddockId: String? = null,
    )

    /**
     * Structured response of every activity RPC (sql/166). [canonical] is the
     * COMPLETE server state — activity, every allocation, each allocation's
     * canonical season and vintage, and the activity totals — which the client
     * adopts wholesale instead of merging field by field.
     */
    @Serializable
    data class ActivityResult(
        @SerialName("activity_id") val activityId: String? = null,
        val created: Boolean? = null,
        val reversed: Boolean? = null,
        @SerialName("already_reversed") val alreadyReversed: Boolean? = null,
        @SerialName("allocations_reversed") val allocationsReversed: Int? = null,
        @SerialName("quarters_released") val quartersReleased: Int? = null,
        @SerialName("allocation_results") val allocationResults: List<AllocationResult> = emptyList(),
        @SerialName("removed_allocations") val removedAllocations: List<RemovedAllocation> = emptyList(),
        val conflicts: List<ActivityConflict> = emptyList(),
        @SerialName("work_task_conflict") val workTaskConflict: Boolean? = null,
        /** "activity_not_found" (create hasn't landed — retry) or "activity_reversed". */
        val error: String? = null,
        /** True when a newer edit already applied — this edit is obsolete. */
        val stale: Boolean? = null,
        val canonical: PruningActivityCanonical? = null,
    )

    @Serializable
    private data class IdArgs(@SerialName("p_id") val id: String)

    @Serializable
    private data class SummaryArgs(@SerialName("p_vineyard_id") val vineyardId: String)

    /**
     * Decoded response of the authoritative `get_pruning_vineyard_summary`
     * RPC (sql/115). Fetched online purely to verify that the local offline
     * calculation matches the server contract; unavailability never blocks
     * the field workflow.
     */
    @Serializable
    data class ServerSummary(
        @SerialName("season_year") val seasonYear: Int? = null,
        @SerialName("display_percent") val displayPercent: Int? = null,
        @SerialName("total_vines") val totalVines: Long? = null,
        @SerialName("vines_pruned") val vinesPruned: Long? = null,
        @SerialName("vines_remaining") val vinesRemaining: Long? = null,
        @SerialName("vines_per_day_exact") val vinesPerDayExact: Double? = null,
        @SerialName("vines_per_labour_hour_exact") val vinesPerLabourHourExact: Double? = null,
        @SerialName("labour_hours") val labourHours: Double? = null,
        /** yyyy-MM-dd in the vineyard's timezone. */
        @SerialName("projected_completion_date") val projectedCompletionDate: String? = null,
        @SerialName("blocks_complete") val blocksComplete: Int? = null,
        @SerialName("blocks_at_risk") val blocksAtRisk: Int? = null,
        @SerialName("completed_row_equivalents") val completedRowEquivalents: Double? = null,
        @SerialName("total_row_equivalents") val totalRowEquivalents: Double? = null,
    )

    // MARK: Reads

    suspend fun fetchSeasons(vineyardId: String): List<SeasonRow> =
        getList("pruning_seasons?vineyard_id=eq.$vineyardId&order=updated_at.asc")

    suspend fun fetchEntries(vineyardId: String): List<EntryRow> =
        getList("pruning_entries?vineyard_id=eq.$vineyardId&order=updated_at.asc")

    suspend fun fetchSegments(vineyardId: String): List<SegmentRow> =
        getList("pruning_row_segments?vineyard_id=eq.$vineyardId&completed=eq.true")

    /** Fetches the authoritative SQL 115 summary for the online parity check. */
    suspend fun fetchVineyardSummary(vineyardId: String): ServerSummary = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("get_pruning_vineyard_summary")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(SummaryArgs(vineyardId))
        }
        when {
            response.status.isSuccess() -> response.body<ServerSummary>()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

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

    /**
     * Idempotent — safe to replay from the offline queue. Returns the
     * canonical season the server resolved from the entry date (sql/161);
     * a server older than 161 simply omits the fields.
     */
    suspend fun recordEntry(entry: PruningEntry): RecordEntryResult = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        // CANONICAL (sql/161): the season year is the year of the WORK, taken
        // from the entry date. The server re-derives it; this is sent for
        // diagnostics and for servers older than SQL 161.
        val seasonYear = PruningSeasonIds.seasonYearFor(entry.date)
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
            workTaskId = entry.workTaskId,
        )
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("record_pruning_entry")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            // Raw pre-encoded body: all 16 keys always present, nulls explicit.
            setBody(rpcJson.encodeToString(RecordEntryArgs.serializer(), args))
        }
        when {
            response.status.isSuccess() ->
                runCatching {
                    resultJson.decodeFromString(RecordEntryResult.serializer(), response.bodyAsText())
                }.getOrDefault(RecordEntryResult(entryId = entry.id))
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /**
     * Transaction-safe edit through `update_pruning_entry` (sql/120) — the
     * ONLY way an existing entry, its quarters and totals change. Sends the
     * FULL desired state (idempotent, LWW on client_updated_at); all 13 keys
     * always present with explicit nulls so the call shape never varies.
     *
     * [clientUpdatedAt] must be the timestamp of the EDIT itself (queued
     * offline or performed now) — never the replay time — so a delayed retry
     * can never overwrite a newer edit made on another device.
     */
    suspend fun updateEntry(
        entry: PruningEntry,
        clientUpdatedAt: String = Instant.now().toString(),
    ): UpdateEntryResult = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val args = UpdateEntryArgs(
            entryId = entry.id,
            entryDate = entry.date,
            worker = entry.worker,
            labourHours = entry.labourHours,
            startTime = toInstantString(entry.date, entry.startTime),
            finishTime = toInstantString(entry.date, entry.finishTime),
            method = entry.method,
            notes = entry.notes,
            estimatedVines = entry.estimatedVines,
            segments = entry.segments.map {
                SegmentArg(row = it.row, segment = it.quarter, rowId = it.rowId, label = it.row.toString())
            },
            workTaskId = entry.workTaskId,
            // A nil link on an edit means the link was removed (clearing an
            // already-null link server-side is a harmless no-op).
            clearWorkTask = entry.workTaskId == null,
            clientUpdatedAt = clientUpdatedAt,
        )
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("update_pruning_entry")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(rpcJson.encodeToString(UpdateEntryArgs.serializer(), args))
        }
        when {
            response.status.isSuccess() -> resultJson.decodeFromString(UpdateEntryResult.serializer(), response.bodyAsText())
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /**
     * Creates a multi-block pruning activity through `record_pruning_activity`
     * (sql/166). Idempotent on the stable client activity id: replaying the
     * same draft can never create a second parent or duplicate an allocation,
     * and a failed allocation rolls the WHOLE activity back server-side.
     */
    suspend fun recordActivity(
        draft: PruningActivityDraft,
        clientUpdatedAt: String = Instant.now().toString(),
    ): ActivityResult = withContext(Dispatchers.IO) {
        postActivity(
            "record_pruning_activity",
            rpcJson.encodeToString(
                RecordActivityArgs.serializer(),
                RecordActivityArgs(
                    activityId = draft.id,
                    vineyardId = draft.vineyardId,
                    activity = activityPayload(draft),
                    allocations = allocationPayloads(draft),
                    clientUpdatedAt = clientUpdatedAt,
                ),
            ),
        )
    }

    /**
     * Full desired state of an existing activity through
     * `update_pruning_activity` (sql/166): adds a block, removes a block,
     * changes rows/quarters, changes the date (re-resolving EVERY allocation's
     * season) or changes labour without touching allocations. LWW on
     * [clientUpdatedAt] — pass the timestamp of the EDIT, never the replay time.
     */
    suspend fun updateActivity(
        draft: PruningActivityDraft,
        clientUpdatedAt: String = Instant.now().toString(),
    ): ActivityResult = withContext(Dispatchers.IO) {
        postActivity(
            "update_pruning_activity",
            rpcJson.encodeToString(
                UpdateActivityArgs.serializer(),
                UpdateActivityArgs(
                    activityId = draft.id,
                    activity = activityPayload(draft),
                    allocations = allocationPayloads(draft),
                    clientUpdatedAt = clientUpdatedAt,
                ),
            ),
        )
    }

    /** Reverses the parent activity as ONE operation; every allocation inherits it. */
    suspend fun reverseActivity(activityId: String, reason: String? = null): ActivityResult =
        withContext(Dispatchers.IO) {
            postActivity(
                "reverse_pruning_activity",
                rpcJson.encodeToString(
                    ReverseActivityArgs.serializer(),
                    ReverseActivityArgs(activityId = activityId, reason = reason),
                ),
            )
        }

    /** Canonical read-back of one activity (`get_pruning_activity`). */
    suspend fun fetchActivity(activityId: String): PruningActivityCanonical? =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("get_pruning_activity")) {
                authHeaders(token)
                contentType(ContentType.Application.Json)
                setBody(ActivityIdArgs(activityId))
            }
            when {
                response.status.isSuccess() -> runCatching {
                    resultJson.decodeFromString(PruningActivityCanonical.serializer(), response.bodyAsText())
                }.getOrNull()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /**
     * Every activity of the vineyard with all its allocations
     * (`list_pruning_activities`). One parent record per element — the list the
     * Tracker history and the mobile Activity Report render.
     */
    suspend fun fetchActivities(
        vineyardId: String,
        includeReversed: Boolean = true,
        limit: Int = 500,
    ): List<PruningActivityCanonical> = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("list_pruning_activities")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(ListActivitiesArgs(vineyardId, includeReversed, limit))
        }
        when {
            response.status.isSuccess() -> runCatching {
                resultJson.decodeFromString(
                    ListSerializer(PruningActivityCanonical.serializer()),
                    response.bodyAsText(),
                )
            }.getOrDefault(emptyList())
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
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

    private suspend fun postActivity(function: String, body: String): ActivityResult {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(function)) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        return when {
            response.status.isSuccess() ->
                resultJson.decodeFromString(ActivityResult.serializer(), response.bodyAsText())
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

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
        /**
         * The activity payload — labour, timing, rate, notes and the task link
         * exactly once. Never derived per block.
         */
        fun activityPayload(draft: PruningActivityDraft): ActivityPayload = ActivityPayload(
            entryDate = draft.date,
            workerOrCrew = draft.worker,
            method = draft.method,
            startTime = toInstantString(draft.date, draft.startTime),
            finishTime = toInstantString(draft.date, draft.finishTime),
            labourHours = draft.labourHours,
            hourlyRate = draft.hourlyRate,
            notes = draft.notes,
            workTaskId = draft.workTaskId,
            // A null link on a full-state edit means the link was removed.
            clearWorkTask = draft.workTaskId == null,
        )

        /**
         * Every block allocation, each carrying its OWN paddock id, quarters
         * and vine estimate. Allocation ids are the deterministic
         * (activity, block) ids so an offline retry recreates the same rows.
         */
        fun allocationPayloads(draft: PruningActivityDraft): List<AllocationPayload> =
            draft.activeAllocations.map { alloc ->
                AllocationPayload(
                    id = alloc.allocationIdFor(draft.id),
                    paddockId = alloc.paddockId,
                    segments = alloc.segments.map {
                        SegmentArg(
                            row = it.row,
                            segment = it.quarter,
                            rowId = it.rowId,
                            label = it.row.toString(),
                        )
                    },
                    quarters = alloc.quarters,
                    estimatedVines = alloc.estimatedVines,
                )
            }

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
