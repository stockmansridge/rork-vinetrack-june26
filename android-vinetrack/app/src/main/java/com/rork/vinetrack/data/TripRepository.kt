package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.SeedingDetails
import com.rork.vinetrack.data.model.TankSession
import com.rork.vinetrack.data.model.Trip
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.put
import java.time.Instant
import java.util.UUID

/**
 * Write path for operational trips, mirroring the iOS trip sync contract
 * (`trips` table + `soft_delete_trip` RPC). RLS scopes everything to the
 * signed-in user's vineyard role: owner/manager/supervisor/operator may
 * insert and update; only owner/manager/supervisor may soft-delete.
 *
 * Online-first — there is no local queue yet. Every mutation sends only the
 * columns Android edits, leaving the iOS-managed JSONB fields it doesn't
 * touch (tank_sessions, row_sequence, seeding_details, etc.) intact.
 */
class TripRepository(private val session: SessionStore) {

    /** Insert payload when starting a new trip. */
    @Serializable
    data class TripInsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("paddock_id") val paddockId: String? = null,
        @SerialName("paddock_name") val paddockName: String? = null,
        @SerialName("paddock_ids") val paddockIds: List<String> = emptyList(),
        @SerialName("start_time") val startTime: String,
        @SerialName("is_active") val isActive: Boolean,
        @SerialName("is_paused") val isPaused: Boolean = false,
        @SerialName("person_name") val personName: String? = null,
        @SerialName("trip_function") val tripFunction: String? = null,
        @SerialName("trip_title") val tripTitle: String? = null,
        @SerialName("machine_id") val machineId: String? = null,
        @SerialName("tractor_id") val tractorId: String? = null,
        @SerialName("work_task_id") val workTaskId: String? = null,
        @SerialName("operator_user_id") val operatorUserId: String? = null,
        @SerialName("operator_category_id") val operatorCategoryId: String? = null,
        @SerialName("total_distance") val totalDistance: Double = 0.0,
        @SerialName("path_points") val pathPoints: List<CoordinatePoint> = emptyList(),
        @SerialName("start_engine_hours") val startEngineHours: Double? = null,
        @SerialName("seeding_details") val seedingDetails: SeedingDetails? = null,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    /**
     * Insert payload for a historical (already-finished) trip created during a
     * CSV import. Unlike [TripInsert] this is inactive with explicit start/end
     * times so the imported spray record can attach block + operator the same
     * way iOS does (`SprayProgramCSVService.importRows`).
     */
    @Serializable
    private data class ImportedTripInsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("paddock_id") val paddockId: String? = null,
        @SerialName("paddock_name") val paddockName: String? = null,
        @SerialName("start_time") val startTime: String,
        @SerialName("end_time") val endTime: String? = null,
        @SerialName("is_active") val isActive: Boolean = false,
        @SerialName("is_paused") val isPaused: Boolean = false,
        @SerialName("person_name") val personName: String? = null,
        @SerialName("trip_function") val tripFunction: String? = null,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    /** Metadata edit (start-sheet details) without disturbing live progress. */
    @Serializable
    private data class TripMetadataPatch(
        @SerialName("paddock_id") val paddockId: String? = null,
        @SerialName("paddock_name") val paddockName: String? = null,
        @SerialName("paddock_ids") val paddockIds: List<String> = emptyList(),
        @SerialName("person_name") val personName: String? = null,
        @SerialName("trip_function") val tripFunction: String? = null,
        @SerialName("trip_title") val tripTitle: String? = null,
        @SerialName("machine_id") val machineId: String? = null,
        @SerialName("work_task_id") val workTaskId: String? = null,
        @SerialName("operator_user_id") val operatorUserId: String? = null,
        @SerialName("operator_category_id") val operatorCategoryId: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    /**
     * Safe scalar trip-detail patch (Tier-A Stage B-1). Carries only the
     * metadata scalars plus the live `is_paused` and optional
     * `start_engine_hours` columns and the sync stamp — never path points,
     * coverage arrays, tank sessions, row-plan, trip start/end or delete
     * fields. This is the write shape [updateTripMetadataFields] replays for a
     * queued offline metadata/pause/engine-hour edit. Hand-built as a
     * JsonObject in the method so nullable fields are sent as explicit JSON
     * `null` to clear them (the shared client drops nulls otherwise).
     */

    /** Live progress autosave while a trip is active. */
    @Serializable
    private data class TripProgressPatch(
        @SerialName("path_points") val pathPoints: List<CoordinatePoint>,
        @SerialName("total_distance") val totalDistance: Double,
        @SerialName("is_paused") val isPaused: Boolean,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    /**
     * Patch that activates an existing inactive trip (e.g. starting a calculator
     * "Not Started" spray job). Resets the start time to now and clears the
     * paused flag while leaving paddock/function/equipment fields untouched.
     */
    @Serializable
    private data class TripStartPatch(
        @SerialName("is_active") val isActive: Boolean = true,
        @SerialName("is_paused") val isPaused: Boolean = false,
        @SerialName("start_time") val startTime: String,
        @SerialName("end_time") val endTime: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    /** Final patch when ending a trip. */
    @Serializable
    private data class TripEndPatch(
        @SerialName("is_active") val isActive: Boolean = false,
        @SerialName("is_paused") val isPaused: Boolean = false,
        @SerialName("end_time") val endTime: String,
        @SerialName("total_distance") val totalDistance: Double,
        @SerialName("path_points") val pathPoints: List<CoordinatePoint>,
        @SerialName("completion_notes") val completionNotes: String? = null,
        @SerialName("end_engine_hours") val endEngineHours: Double? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    /**
     * Dedicated patch for an optional start engine-hour reading (Stage 3F-1).
     * Written only when the operator enters a start reading, never by GPS
     * autosave or coverage patches. Touches only this one column plus sync ts.
     */
    @Serializable
    private data class TripStartEngineHoursPatch(
        @SerialName("start_engine_hours") val startEngineHours: Double,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    /**
     * Row-plan patch (Stage 3A). Writes only the planned row-sequence fields so
     * it never disturbs live progress autosave ([TripProgressPatch]) or the
     * iOS-managed JSONB it doesn't own. `total_tanks` is optional and only sent
     * when supplied. `completed_paths`/`skipped_paths` are intentionally left
     * untouched here — coverage updates land in a later stage.
     */
    @Serializable
    private data class TripRowPlanPatch(
        @SerialName("tracking_pattern") val trackingPattern: String,
        @SerialName("row_sequence") val rowSequence: List<Double>,
        @SerialName("sequence_index") val sequenceIndex: Int,
        @SerialName("current_row_number") val currentRowNumber: Double? = null,
        @SerialName("next_row_number") val nextRowNumber: Double? = null,
        @SerialName("total_tanks") val totalTanks: Int? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    /**
     * Coverage patch (Stage 3D-1). Writes only the operator-driven row coverage
     * fields — `completed_paths`, `skipped_paths`, `sequence_index` and the
     * derived current/next row numbers — on an explicit Mark complete / Skip /
     * Undo tap. Deliberately separate from [TripProgressPatch] so it never
     * disturbs live GPS autosave, path points, distance, pause state, the
     * row-plan setup fields, or trip start/end fields.
     */
    @Serializable
    private data class TripCoveragePatch(
        @SerialName("completed_paths") val completedPaths: List<Double>,
        @SerialName("skipped_paths") val skippedPaths: List<Double>,
        @SerialName("sequence_index") val sequenceIndex: Int,
        @SerialName("current_row_number") val currentRowNumber: Double? = null,
        @SerialName("next_row_number") val nextRowNumber: Double? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    /**
     * Tank fill-timer patch (Stage 3F-2a). Writes only the tank-session JSONB
     * array plus the live tank-state columns, mirroring the iOS
     * `trips.tank_sessions` contract. Deliberately separate from progress,
     * coverage, row-plan, engine-hour and start/end patches so it never
     * disturbs GPS autosave or any field it doesn't own. No live controls call
     * this yet — it makes the data shape write-ready for Stage 3F-2b.
     */

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_trip_id") val tripId: String)

    private fun nowIso(): String = Instant.now().toString()

    /**
     * Create a new active trip row. When [id] is supplied (Tier-A Stage B-3-1)
     * it is used as the server row id verbatim, so an offline-started trip and
     * its queued [com.rork.vinetrack.data.model.PendingEntityType.TRIP_START]
     * marker share the same final id (the id doubles as the idempotency key on
     * replay). When [id] is null a fresh UUID is generated as before — the
     * online happy path is behaviourally unchanged. Likewise [startTime] /
     * [clientUpdatedAt] default to now but can be passed so a replayed offline
     * start preserves the original start instant. No schema/RLS/RPC change.
     */
    suspend fun createTrip(
        vineyardId: String,
        paddockId: String?,
        paddockName: String?,
        personName: String?,
        tripFunction: String?,
        tripTitle: String?,
        machineId: String? = null,
        tractorId: String? = null,
        workTaskId: String? = null,
        operatorUserId: String? = null,
        operatorCategoryId: String? = null,
        startEngineHours: Double? = null,
        paddockIds: List<String> = emptyList(),
        id: String? = null,
        startTime: String? = null,
        clientUpdatedAt: String? = null,
        seedingDetails: SeedingDetails? = null,
    ): Trip = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val now = nowIso()
        val body = TripInsert(
            id = id ?: UUID.randomUUID().toString(),
            vineyardId = vineyardId,
            paddockId = paddockId,
            paddockName = paddockName,
            paddockIds = paddockIds,
            startTime = startTime ?: now,
            isActive = true,
            personName = personName,
            tripFunction = tripFunction,
            tripTitle = tripTitle,
            machineId = machineId,
            tractorId = tractorId,
            workTaskId = workTaskId,
            operatorUserId = operatorUserId,
            operatorCategoryId = operatorCategoryId,
            startEngineHours = startEngineHours,
            seedingDetails = seedingDetails,
            createdBy = session.userId,
            clientUpdatedAt = clientUpdatedAt ?: now,
        )
        val response = SupabaseClient.http.post(SupabaseClient.restUrl("trips")) {
            authHeaders(token)
            headers { append("Prefer", "return=representation") }
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        firstRow(response)
    }

    /**
     * Create an inactive, already-finished trip to carry an imported spray
     * record's block + operator. Mirrors the iOS importer, which makes a
     * spraying trip dated to the record's date.
     */
    suspend fun createImportedTrip(
        vineyardId: String,
        paddockId: String?,
        paddockName: String?,
        personName: String?,
        startTime: String,
        endTime: String?,
    ): Trip = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val now = nowIso()
        val body = ImportedTripInsert(
            id = UUID.randomUUID().toString(),
            vineyardId = vineyardId,
            paddockId = paddockId,
            paddockName = paddockName,
            startTime = startTime,
            endTime = endTime,
            personName = personName,
            tripFunction = "spraying",
            createdBy = session.userId,
            clientUpdatedAt = now,
        )
        val response = SupabaseClient.http.post(SupabaseClient.restUrl("trips")) {
            authHeaders(token)
            headers { append("Prefer", "return=representation") }
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        firstRow(response)
    }

    suspend fun updateMetadata(
        id: String,
        paddockId: String?,
        paddockName: String?,
        personName: String?,
        tripFunction: String?,
        tripTitle: String?,
        machineId: String? = null,
        workTaskId: String? = null,
        operatorUserId: String? = null,
        operatorCategoryId: String? = null,
        paddockIds: List<String> = emptyList(),
    ): Trip = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val patch = TripMetadataPatch(
            paddockId = paddockId,
            paddockName = paddockName,
            paddockIds = paddockIds,
            personName = personName,
            tripFunction = tripFunction,
            tripTitle = tripTitle,
            machineId = machineId,
            workTaskId = workTaskId,
            operatorUserId = operatorUserId,
            operatorCategoryId = operatorCategoryId,
            clientUpdatedAt = nowIso(),
        )
        patchTrip(id, patch, token)
    }

    /**
     * Activate an inactive trip in place, mirroring the manual trip-start
     * contract: `is_active = true`, fresh `start_time`, cleared end time and
     * paused flag. Used to start a calculator-created "Not Started" spray job
     * without creating a duplicate trip.
     */
    suspend fun activateTrip(id: String): Trip = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val now = nowIso()
        val patch = TripStartPatch(startTime = now, clientUpdatedAt = now)
        patchTrip(id, patch, token)
    }

    /**
     * Persist a planned row sequence onto an existing trip (Stage 3A). Sends
     * only the row-plan columns, leaving live progress, paths, and coverage
     * intact. `currentRowNumber`/`nextRowNumber` default to the first two paths
     * of the sequence when not supplied so a freshly planned trip resolves to a
     * sensible starting position; Free Drive passes an empty sequence.
     */
    suspend fun updateTripRowPlan(
        id: String,
        trackingPattern: String,
        rowSequence: List<Double>,
        sequenceIndex: Int = 0,
        currentRowNumber: Double? = null,
        nextRowNumber: Double? = null,
        totalTanks: Int? = null,
    ): Trip = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val resolvedCurrent = currentRowNumber ?: rowSequence.getOrNull(0)
        val resolvedNext = nextRowNumber ?: rowSequence.getOrNull(1)
        val patch = TripRowPlanPatch(
            trackingPattern = trackingPattern,
            rowSequence = rowSequence,
            sequenceIndex = sequenceIndex,
            currentRowNumber = resolvedCurrent,
            nextRowNumber = resolvedNext,
            totalTanks = totalTanks,
            clientUpdatedAt = nowIso(),
        )
        patchTrip(id, patch, token)
    }

    /**
     * Persist an explicit, operator-driven row-coverage update (Stage 3D-1).
     * Sends only the coverage columns so it never clobbers live progress, the
     * row-plan setup, or any iOS-managed fields on a shared trip. Called once
     * per Mark complete / Skip / Undo tap — there is no automatic completion.
     */
    suspend fun updateTripCoverage(
        id: String,
        completedPaths: List<Double>,
        skippedPaths: List<Double>,
        sequenceIndex: Int,
        currentRowNumber: Double?,
        nextRowNumber: Double?,
    ): Trip = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val patch = TripCoveragePatch(
            completedPaths = completedPaths,
            skippedPaths = skippedPaths,
            sequenceIndex = sequenceIndex,
            currentRowNumber = currentRowNumber,
            nextRowNumber = nextRowNumber,
            clientUpdatedAt = nowIso(),
        )
        patchTrip(id, patch, token)
    }

    suspend fun saveProgress(
        id: String,
        pathPoints: List<CoordinatePoint>,
        totalDistance: Double,
        isPaused: Boolean,
    ): Trip = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val patch = TripProgressPatch(
            pathPoints = pathPoints,
            totalDistance = totalDistance,
            isPaused = isPaused,
            clientUpdatedAt = nowIso(),
        )
        patchTrip(id, patch, token)
    }

    /**
     * Finalise a trip. [endTime] defaults to now for the live online end path;
     * the Tier-A Stage B-2-1 offline-end replay passes the operator's original
     * requested end time so a deferred end records when the work actually
     * finished, not when it later synced.
     */
    suspend fun endTrip(
        id: String,
        pathPoints: List<CoordinatePoint>,
        totalDistance: Double,
        completionNotes: String?,
        endEngineHours: Double? = null,
        endTime: String? = null,
    ): Trip = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val now = nowIso()
        val patch = TripEndPatch(
            endTime = endTime ?: now,
            totalDistance = totalDistance,
            pathPoints = pathPoints,
            completionNotes = completionNotes,
            endEngineHours = endEngineHours,
            clientUpdatedAt = now,
        )
        patchTrip(id, patch, token)
    }

    /**
     * Persist an optional start engine-hour reading on an existing trip
     * (Stage 3F-1). Used when a trip was activated without a start reading
     * (e.g. calculator Start now). Sends only the one column.
     */
    suspend fun updateStartEngineHours(id: String, startEngineHours: Double): Trip =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val patch = TripStartEngineHoursPatch(
                startEngineHours = startEngineHours,
                clientUpdatedAt = nowIso(),
            )
            patchTrip(id, patch, token)
        }

    /**
     * Persist tank fill-timer sessions and live tank state on a trip
     * (Stage 3F-2a). Targets only the tank-session columns plus the sync
     * timestamp; never touches GPS progress, row coverage, engine hours or
     * trip start/end fields. Not wired to UI yet — the data shape is write-ready
     * for the upcoming live Start/End Tank controls.
     */
    suspend fun updateTripTankSessions(
        id: String,
        tankSessions: List<TankSession>,
        activeTankNumber: Int?,
        isFillingTank: Boolean,
        fillingTankNumber: Int?,
    ): Trip = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        // Hand-built JsonObject so nullable live-state columns are sent as an
        // explicit JSON `null` to clear them server-side. The shared client uses
        // `explicitNulls = false`, which would otherwise drop a null
        // `active_tank_number` from the body and leave the stale value in the DB
        // (e.g. after End Tank the trip would still look like a tank is active).
        val patch: JsonObject = buildJsonObject {
            put("tank_sessions", SupabaseClient.json.encodeToJsonElement(tankSessions))
            put("active_tank_number", activeTankNumber?.let { JsonPrimitive(it) } ?: JsonNull)
            put("is_filling_tank", JsonPrimitive(isFillingTank))
            put("filling_tank_number", fillingTankNumber?.let { JsonPrimitive(it) } ?: JsonNull)
            put("client_updated_at", JsonPrimitive(nowIso()))
        }
        patchTrip(id, patch, token)
    }

    /**
     * Read a single live trip row including its conflict metadata
     * (`client_updated_at`, `is_active`, `deleted_at`) for the Stage B-1
     * metadata-edit replay stale-guard. Returns null when the trip is missing
     * or soft-deleted so the caller can block an edit against a vanished trip.
     */
    suspend fun fetchTrip(id: String): Trip? = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.get(
            SupabaseClient.restUrl("trips?id=eq.$id&deleted_at=is.null&select=*"),
        ) {
            authHeaders(token)
        }
        when {
            response.status.isSuccess() -> response.body<List<Trip>>().firstOrNull()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /**
     * Patch only the safe scalar trip-detail fields (Tier-A Stage B-1):
     * metadata scalars, the live `is_paused` flag, and an optional
     * `start_engine_hours` reading, plus the queued `client_updated_at` stamp.
     * Never touches path points, total distance, coverage arrays, row-plan,
     * tank sessions, trip start/end or delete fields, so a queued offline edit
     * can never clobber newer live progress on a shared trip. Nullable metadata
     * is sent as explicit JSON `null` so cleared fields actually clear
     * server-side (the shared client uses `explicitNulls = false`).
     * `startEngineHours` is only included when non-null — the queue never
     * clears an already-recorded reading.
     */
    suspend fun updateTripMetadataFields(
        id: String,
        paddockId: String?,
        paddockName: String?,
        personName: String?,
        tripFunction: String?,
        tripTitle: String?,
        machineId: String?,
        workTaskId: String?,
        operatorUserId: String?,
        operatorCategoryId: String?,
        isPaused: Boolean,
        startEngineHours: Double?,
        clientUpdatedAt: String,
        paddockIds: List<String> = emptyList(),
    ): Trip = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val patch: JsonObject = buildJsonObject {
            put("paddock_id", paddockId?.let { JsonPrimitive(it) } ?: JsonNull)
            put("paddock_name", paddockName?.let { JsonPrimitive(it) } ?: JsonNull)
            put(
                "paddock_ids",
                buildJsonArray { paddockIds.forEach { add(JsonPrimitive(it)) } },
            )
            put("person_name", personName?.let { JsonPrimitive(it) } ?: JsonNull)
            put("trip_function", tripFunction?.let { JsonPrimitive(it) } ?: JsonNull)
            put("trip_title", tripTitle?.let { JsonPrimitive(it) } ?: JsonNull)
            put("machine_id", machineId?.let { JsonPrimitive(it) } ?: JsonNull)
            put("work_task_id", workTaskId?.let { JsonPrimitive(it) } ?: JsonNull)
            put("operator_user_id", operatorUserId?.let { JsonPrimitive(it) } ?: JsonNull)
            put("operator_category_id", operatorCategoryId?.let { JsonPrimitive(it) } ?: JsonNull)
            put("is_paused", JsonPrimitive(isPaused))
            if (startEngineHours != null) put("start_engine_hours", JsonPrimitive(startEngineHours))
            put("client_updated_at", JsonPrimitive(clientUpdatedAt))
        }
        patchTrip(id, patch, token)
    }

    /**
     * Persist the structured seeding payload onto a trip. Writes only the
     * `seeding_details` JSONB column plus the sync stamp, so it never disturbs
     * live progress, coverage, row-plan or any other iOS-managed field. A null
     * [details] clears the column. Mirrors the iOS `trips.seeding_details`
     * contract (sql/038).
     */
    suspend fun updateSeedingDetails(
        id: String,
        details: SeedingDetails?,
        clientUpdatedAt: String? = null,
    ): Trip =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val patch: JsonObject = buildJsonObject {
                put(
                    "seeding_details",
                    details?.let { SupabaseClient.json.encodeToJsonElement(it) } ?: JsonNull,
                )
                put("client_updated_at", JsonPrimitive(clientUpdatedAt ?: nowIso()))
            }
            patchTrip(id, patch, token)
        }

    suspend fun softDeleteTrip(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_trip")) {
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

    private suspend inline fun <reified T> patchTrip(
        id: String,
        patch: T,
        token: String,
    ): Trip {
        val response = SupabaseClient.http.patch(SupabaseClient.restUrl("trips?id=eq.$id")) {
            authHeaders(token)
            headers { append("Prefer", "return=representation") }
            contentType(ContentType.Application.Json)
            setBody(patch)
        }
        return firstRow(response)
    }

    private suspend fun firstRow(response: io.ktor.client.statement.HttpResponse): Trip = when {
        response.status.isSuccess() -> response.body<List<Trip>>().firstOrNull()
            ?: throw BackendError.Server(response.status.value, "Empty response")
        response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
        else -> throw BackendError.Server(response.status.value, response.bodyAsText())
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
}
