package com.rork.vinetrack.data.auth

import com.rork.vinetrack.data.PruningSyncRepository
import com.rork.vinetrack.data.model.*
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.*
import java.time.ZoneId

/** Read-only original-account recovery. Membership alone never attributes a local draft.
 * Populated caches need matching server projections, using ONLY the isolated recovery client.
 * No cache, queue, record, receipt, resource intent or server row is changed here.
 */
internal object PruningRecoveryVerifier {
    val stores = setOf("vinetrack_pruning", "vinetrack_pruning_yield_settings")
    private val local = Json { ignoreUnknownKeys = false; encodeDefaults = true }
    private val remote = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    private fun key(id: String) = id.lowercase(java.util.Locale.ROOT)
    private fun requireId(id: String): String { check(uuid.matches(id)); return key(id) }
    private fun fail(store: String, rule: String): Nothing = throw EvidenceContractFailure(
        RecoveryEvidenceDiagnostic(store, rule))

    data class Snapshot(val values: Map<String, Map<String, *>>)
    class Proof private constructor(
        private val owner: String, private val epoch: Long,
        private val snapshot: Snapshot, private val vineyards: Set<String>,
    ) {
        fun inspect(name: String, values: Map<String, *>, original: String, currentEpoch: Long): Set<String> {
            if (original != owner || currentEpoch != epoch || values != snapshot.values[name])
                fail(name, "PRUNING_RECOVERY_EVIDENCE_CHANGED")
            return vineyards
        }
        companion object {
            internal fun verified(owner: String, epoch: Long, snapshot: Snapshot, vineyards: Set<String>) =
                Proof(owner, epoch, snapshot, vineyards)
        }
    }

    private data class Slice(val store: String, val name: String, val vineyard: String, val raw: String)
    private fun slices(snapshot: Snapshot): List<Slice> = snapshot.values.flatMap { (store, values) ->
        if (store !in stores) fail(store, "PRUNING_UNKNOWN_STORE")
        values.map { (name, value) ->
            val prefixes = if (store == "vinetrack_pruning")
                listOf("setups_v2_", "entries_v2_", "activities_v1_", "activity_labour_v1_") else listOf("settings_")
            val prefix = prefixes.singleOrNull { name.startsWith(it) }
                ?: fail(store, "PRUNING_UNKNOWN_KEY_VERSION")
            val vineyard = runCatching { requireId(name.removePrefix(prefix)) }.getOrElse {
                fail(store, "PRUNING_INVALID_VINEYARD_SCOPE")
            }
            if (value !is String) fail(store, "PRUNING_INVALID_VALUE_TYPE")
            Slice(store, prefix, vineyard, value)
        }
    }

    /** Empty KNOWN arrays can be assessed locally; populated or unreadable ones need proof. */
    fun inspectWithoutProof(name: String, values: Map<String, *>): Set<String> {
        val selected = slices(Snapshot(mapOf(name to values)))
        selected.forEach { slice ->
            val data = runCatching { local.parseToJsonElement(slice.raw) }.getOrNull()
            if (data !is JsonArray || data.isNotEmpty()) fail(name, "PRUNING_SERVER_CONFIRMATION_REQUIRED")
        }
        return selected.mapTo(mutableSetOf()) { it.vineyard }
    }

    private fun <T> decode(slice: Slice, serializer: KSerializer<T>): List<T> = try {
        local.decodeFromString(ListSerializer(serializer), slice.raw)
    } catch (_: Exception) { fail(slice.store, "PRUNING_RETAINED_SCHEMA_INVALID") }

    // Canonicalize UUID spelling in identity fields only. Notes, names, dates, amounts,
    // ordering (except the mathematical set of row quarters) and unknown fields stay exact.
    private val ids = setOf("id", "vineyardId", "vineyard_id", "paddockId", "paddock_id", "rowId",
        "allocationId", "seasonId", "serverSeasonId", "workTaskId", "work_task_id", "pruningActivityId",
        "pruning_activity_id", "enteredBy", "created_by", "worker_user_id", "external_resource_id")
    private fun normal(value: JsonElement, field: String? = null): JsonElement = when (value) {
        is JsonObject -> {
            val entries = value.entries.map { (name, child) ->
                val nameKey = if (field == "allocations") requireId(name) else name
                nameKey to normal(child, name)
            }
            check(entries.map { it.first }.distinct().size == entries.size)
            JsonObject(entries.toMap())
        }
        is JsonArray -> {
            val children = value.map { normal(it) }
            if (field == "segments") {
                check(children.distinct().size == children.size)
                JsonArray(children.sortedBy { it.toString() })
            } else JsonArray(children)
        }
        is JsonPrimitive -> if (field in ids && value.isString && uuid.matches(value.content)) JsonPrimitive(key(value.content)) else value
        else -> value
    }
    private fun <T> equal(serializer: KSerializer<T>, first: T, second: T): Boolean =
        normal(local.encodeToJsonElement(serializer, first)) == normal(local.encodeToJsonElement(serializer, second))

    private fun auditMillis(value: String): Long = java.time.OffsetDateTime.parse(value).toInstant().toEpochMilli()

    /** Independent projection: never use adoptCanonical's draft fallbacks as evidence.
     * Only display focus and separately verified resource receipts are local-only fields.
     * Missing audit or business evidence must remain held, not manufactured.
     */
    private fun activityProjection(retained: PruningActivityDraft, canonical: PruningActivityCanonical,
        timezone: ZoneId): PruningActivityDraft {
        val parent = checkNotNull(canonical.activity)
        val date = checkNotNull(parent.entryDate)
        java.time.LocalDate.parse(date)
        val reversed = checkNotNull(parent.isReversed)
        check(reversed == (parent.reversedAt != null))
        val allocations = canonical.allocations.map { allocation ->
            val paddock = requireId(allocation.paddockId)
            check(allocation.isReversed == reversed)
            checkNotNull(allocation.pruningSeasonId).let(::requireId)
            checkNotNull(allocation.seasonYear)
            paddock to BlockPruningSelection(
                paddockId = paddock, allocationId = requireId(allocation.id),
                blockName = allocation.blockName,
                segments = allocation.segments.map { PruningSegment(it.row, it.segment, it.rowId) },
                estimatedVines = allocation.estimatedVines,
                serverSeasonId = allocation.pruningSeasonId, serverSeasonYear = allocation.seasonYear)
        }
        check(allocations.map { it.first }.distinct().size == allocations.size)
        return PruningActivityDraft(
            id = requireId(checkNotNull(parent.id)), vineyardId = requireId(checkNotNull(parent.vineyardId)),
            date = date, worker = checkNotNull(parent.workerOrCrew), method = checkNotNull(parent.method),
            startTime = PruningWorkTiming.wall(parent.startTime, timezone),
            finishTime = PruningWorkTiming.wall(parent.finishTime, timezone),
            workTiming = PruningWorkTiming.fromServer(date, parent.startTime, parent.finishTime, timezone),
            labourHours = parent.labourHours, hourlyRate = parent.hourlyRate,
            notes = checkNotNull(parent.notes), workTaskId = parent.workTaskId,
            allocations = allocations.toMap(), focusedPaddockId = retained.focusedPaddockId,
            createdAtMs = auditMillis(checkNotNull(parent.createdAt)),
            updatedAtMs = auditMillis(checkNotNull(parent.updatedAt)),
            enteredBy = requireId(checkNotNull(parent.createdBy)),
            reversedAtMs = parent.reversedAt?.let(::auditMillis) ?: 0L,
            serverAcknowledged = true, serverSeasonYear = checkNotNull(parent.seasonYear), vintageYear = parent.vintageYear,
            resourceSnapshot = retained.resourceSnapshot, resourceLink = retained.resourceLink)
    }

    /** Call only after /auth/user and current live-vineyard membership have been checked.
     * get and rpc are read-only transport callbacks; no ordinary session is installed yet.
     */
    suspend fun verify(owner: String, epoch: Long, snapshot: Snapshot, permitted: Set<String>,
        get: suspend (String) -> JsonElement, rpc: suspend (String, JsonObject) -> JsonElement): Proof {
        requireId(owner)
        val selected = slices(snapshot)
        check(selected.map { Triple(it.store, it.name, it.vineyard) }.distinct().size == selected.size)
        val allowed = permitted.mapTo(mutableSetOf()) { requireId(it) }
        selected.forEach { if (it.vineyard !in allowed) fail(it.store, "PRUNING_VINEYARD_ACCESS_REVOKED") }
        val tables = mutableMapOf<Pair<String, String>, JsonArray>()
        suspend fun table(name: String, vineyard: String): JsonArray {
            val index = name to vineyard
            tables[index]?.let { return it }
            val result = mutableListOf<JsonElement>()
            // Explicit paging: never mistake the default 1,000-row API cap for a full snapshot.
            repeat(100) { page ->
                val rows = get("$name?select=*&vineyard_id=eq.$vineyard&order=id.asc&limit=1000&offset=${page * 1000}") as? JsonArray
                    ?: error("Invalid server response")
                result.addAll(rows)
                if (rows.size < 1000) return JsonArray(result).also { tables[index] = it }
            }
            error("Server snapshot exceeds recovery bound")
        }
        val zones = mutableMapOf<String, ZoneId>()
        suspend fun zone(vineyard: String): ZoneId = zones[vineyard] ?: run {
            val rows = get("vineyards?select=id,timezone&id=eq.$vineyard&deleted_at=is.null") as? JsonArray ?: error("Missing vineyard")
            val row = rows.single() as JsonObject
            check(requireId(row.getValue("id").jsonPrimitive.content) == vineyard)
            ZoneId.of(row["timezone"]?.jsonPrimitive?.contentOrNull ?: "UTC").also { zones[vineyard] = it }
        }
        for (slice in selected) try {
            val raw = local.parseToJsonElement(slice.raw) as? JsonArray ?: error("Invalid cache")
            if (raw.isEmpty()) continue
            // Prevent duplicate or alias-colliding records before comparison.
            val ids = raw.map { requireId((it as JsonObject).getValue("id").jsonPrimitive.content) }
            check(ids.distinct().size == ids.size)
            raw.forEach { encoded ->
                val row = encoded as JsonObject
                val scope = row["vineyardId"] ?: row["vineyard_id"] ?: error("Missing scope")
                check(requireId(scope.jsonPrimitive.content) == slice.vineyard)
            }
            when (slice.name) {
                "setups_v2_" -> {
                    val rows = remote.decodeFromJsonElement(ListSerializer(PruningSyncRepository.SeasonRow.serializer()), table("pruning_seasons", slice.vineyard))
                    decode(slice, PruningBlockSetup.serializer()).forEach { retained ->
                        val found = rows.single { key(it.id) == key(retained.id) && key(it.vineyardId) == slice.vineyard }
                        check(found.deletedAt == null && !found.isArchived && equal(PruningBlockSetup.serializer(), retained, found.toModel()))
                    }
                }
                "settings_" -> {
                    val rows = remote.decodeFromJsonElement(ListSerializer(PruningYieldSettings.serializer()), table("pruning_yield_settings", slice.vineyard))
                    decode(slice, PruningYieldSettings.serializer()).forEach { retained ->
                        val found = rows.single { key(it.id) == key(retained.id) && key(it.vineyardId) == slice.vineyard }
                        check(equal(PruningYieldSettings.serializer(), retained, found))
                    }
                }
                "activity_labour_v1_" -> {
                    val rows = remote.decodeFromJsonElement(ListSerializer(PruningActivityLabourLine.serializer()), table("pruning_activity_labour_lines", slice.vineyard))
                    decode(slice, PruningActivityLabourLine.serializer()).forEach { retained ->
                        val found = rows.single { key(it.id) == key(retained.id) && key(it.vineyardId) == slice.vineyard }
                        check(equal(PruningActivityLabourLine.serializer(), retained, found))
                    }
                }
                "entries_v2_" -> {
                    val rows = remote.decodeFromJsonElement(ListSerializer(PruningSyncRepository.EntryRow.serializer()), table("pruning_entries", slice.vineyard))
                    val seasons = remote.decodeFromJsonElement(ListSerializer(PruningSyncRepository.SeasonRow.serializer()), table("pruning_seasons", slice.vineyard))
                    val segments = remote.decodeFromJsonElement(ListSerializer(PruningSyncRepository.SegmentRow.serializer()), table("pruning_row_segments", slice.vineyard))
                    val timezone = zone(slice.vineyard)
                    decode(slice, PruningEntry.serializer()).forEach { retained ->
                        val found = rows.single { key(it.id) == key(retained.id) && key(it.vineyardId) == slice.vineyard }
                        val season = seasons.single { key(it.id) == key(found.pruningSeasonId) && key(it.vineyardId) == slice.vineyard }
                        val quarters = segments.filter { it.completed && it.pruningEntryId?.let(::key) == key(found.id) }
                            .map { PruningSegment(it.rowNumber, it.segmentNumber, it.paddockRowId) }
                        check(equal(PruningEntry.serializer(), retained, found.toModel(quarters, season.seasonYear, timezone)))
                    }
                }
                "activities_v1_" -> {
                    val timezone = zone(slice.vineyard)
                    decode(slice, PruningActivityDraft.serializer()).forEach { retained ->
                        check(retained.serverAcknowledged && retained.resourceLink?.isPending != true)
                        val canonical = remote.decodeFromJsonElement(PruningActivityCanonical.serializer(), rpc("get_pruning_activity",
                            buildJsonObject { put("p_activity_id", requireId(retained.id)) }))
                        val parent = checkNotNull(canonical.activity)
                        check(parent.id?.let(::requireId) == key(retained.id) && parent.vineyardId?.let(::requireId) == slice.vineyard)
                        check(parent.entryDate != null && parent.workerOrCrew != null && parent.method != null && parent.notes != null)
                        check((parent.isReversed == true) == retained.isReversed)
                        if (retained.enteredBy != null) check(parent.createdBy?.let(::key) == key(retained.enteredBy))
                        val projected = activityProjection(retained, canonical, timezone)
                        check(equal(PruningActivityDraft.serializer(), retained, projected))
                        if (retained.resourceSnapshot != null || retained.resourceLink != null) {
                            val snapshots = get("pruning_activities?select=id,vineyard_id,client_updated_at,external_resource_id,worker_user_id,deleted_at&id=eq.${requireId(retained.id)}&vineyard_id=eq.${slice.vineyard}") as? JsonArray ?: error("Missing resource")
                            val current = remote.decodeFromJsonElement(PruningResourceSnapshot.serializer(), snapshots.single())
                            check(key(current.id) == key(retained.id) && key(current.vineyardId) == slice.vineyard)
                            check(current.deletedAt?.let(::auditMillis) == parent.reversedAt?.let(::auditMillis))
                            retained.resourceSnapshot?.let { check(equal(PruningResourceSnapshot.serializer(), it, current)) }
                            retained.resourceLink?.let {
                                check(it.acknowledged && it.conflict == null && it.failure == null && key(it.authoredBy) == key(owner))
                                requireId(it.generation)
                                it.expected?.let { expected ->
                                    check(requireId(expected.id) == key(retained.id) && requireId(expected.vineyardId) == slice.vineyard)
                                }
                                check(it.externalResourceId == current.externalResourceId && it.workerUserId == current.workerUserId && it.name == parent.workerOrCrew)
                            }
                        }
                    }
                }
                else -> error("Unknown store")
            }
        } catch (failure: EvidenceContractFailure) { throw failure }
          catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
          catch (_: Exception) { fail(slice.store, "PRUNING_SERVER_EVIDENCE_MISMATCH") }
        return Proof.verified(owner, epoch, snapshot, selected.mapTo(mutableSetOf()) { it.vineyard })
    }
}
