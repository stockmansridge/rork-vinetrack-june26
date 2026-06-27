package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.HistoricalBlockResult
import com.rork.vinetrack.data.model.HistoricalYieldRecord
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
import java.time.Instant
import java.util.UUID

/**
 * Write path for archived seasonal yield records, mirroring the iOS
 * `historical_yield_records` sync contract (table +
 * `soft_delete_historical_yield_record` RPC). RLS scopes everything to the
 * signed-in user's vineyard role: owner/manager/supervisor/operator may insert
 * and update; only owner/manager/supervisor may soft-delete.
 *
 * Online-first — there is no local queue. Android authors block-level actual
 * yield records directly (one block per record, matching iOS's
 * `RecordActualYieldSheet`) and edits per-block actuals + notes on existing
 * records. `block_results` is a jsonb array with camelCase keys to stay binary
 * compatible with the iOS Codable encoding. Server-managed sync columns are
 * left untouched on edit.
 */
class YieldRepository(private val session: SessionStore) {

    @Serializable
    private data class YieldInsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        val season: String,
        val year: Int,
        @SerialName("archived_at") val archivedAt: String,
        @SerialName("total_yield_tonnes") val totalYieldTonnes: Double,
        @SerialName("total_area_hectares") val totalAreaHectares: Double,
        val notes: String,
        @SerialName("block_results") val blockResults: List<HistoricalBlockResult>,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    /** Edit of the record-owned fields (no created_by/sync changes). */
    @Serializable
    private data class YieldPatch(
        val season: String,
        val year: Int,
        @SerialName("total_yield_tonnes") val totalYieldTonnes: Double,
        @SerialName("total_area_hectares") val totalAreaHectares: Double,
        val notes: String,
        @SerialName("block_results") val blockResults: List<HistoricalBlockResult>,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    /** Fields captured when archiving a single block's actual yield. */
    data class CreateInput(
        val year: Int,
        val season: String,
        val paddockId: String,
        val paddockName: String,
        val areaHectares: Double,
        val totalVines: Int,
        val variety: String?,
        val actualYieldTonnes: Double,
        val notes: String?,
    )

    /**
     * Sampling-derived estimate for a single block, mirroring the iOS yield
     * estimation formula: `yieldKg = totalVines × avgBunchesPerVine ×
     * (bunchWeightGrams / 1000) × damageFactor`, then `tonnes = yieldKg / 1000`.
     * `damageFactor` is in 0..1 where 1.0 = 100% viable (matches iOS).
     */
    data class EstimateInput(
        val year: Int,
        val season: String,
        val paddockId: String,
        val paddockName: String,
        val areaHectares: Double,
        val totalVines: Int,
        val averageBunchesPerVine: Double,
        val averageBunchWeightGrams: Double,
        val damageFactor: Double,
        val samplesRecorded: Int,
        val variety: String?,
        val notes: String?,
    ) {
        /** Estimated tonnes for this block from the sampling inputs. */
        val estimatedTonnes: Double
            get() {
                val totalBunches = totalVines.toDouble() * averageBunchesPerVine
                val yieldKg = totalBunches * (averageBunchWeightGrams / 1000.0) * damageFactor
                return yieldKg / 1000.0
            }

        /** Estimated tonnes per hectare, or 0 when the block has no area. */
        val estimatedPerHectare: Double
            get() = if (areaHectares > 0) estimatedTonnes / areaHectares else 0.0
    }

    private fun nowIso(): String = Instant.now().toString()

    /** Block display name, optionally suffixed with the variety (matches iOS). */
    private fun blockName(paddockName: String, variety: String?): String =
        variety?.takeIf { it.isNotBlank() }?.let { "$paddockName \u2014 $it" } ?: paddockName

    /**
     * Build the optimistic [HistoricalYieldRecord] for an actual-yield create
     * purely (no network). One block per record (mirrors iOS
     * `RecordActualYieldSheet`): the estimated yield equals the recorded actual
     * since no sampling exists. The caller mints [id], [blockResultId] and
     * [archivedAt] up front so the optimistic row, the queued CREATE marker and
     * the eventual insert all share the same identity.
     */
    fun buildActualRecord(
        vineyardId: String,
        input: CreateInput,
        id: String,
        blockResultId: String,
        archivedAt: String,
    ): HistoricalYieldRecord {
        val perHectare = if (input.areaHectares > 0) input.actualYieldTonnes / input.areaHectares else 0.0
        val block = HistoricalBlockResult(
            id = blockResultId,
            paddockId = input.paddockId,
            paddockName = blockName(input.paddockName, input.variety),
            areaHectares = input.areaHectares,
            yieldTonnes = input.actualYieldTonnes,
            yieldPerHectare = perHectare,
            totalVines = input.totalVines,
            actualYieldTonnes = input.actualYieldTonnes,
            actualRecordedAt = archivedAt,
        )
        return HistoricalYieldRecord(
            id = id,
            vineyardId = vineyardId,
            season = input.season.trim(),
            year = input.year,
            archivedAt = archivedAt,
            totalYieldTonnes = input.actualYieldTonnes,
            totalAreaHectares = input.areaHectares,
            notes = input.notes?.trim().orEmpty(),
            blockResults = listOf(block),
        )
    }

    /**
     * Build the optimistic [HistoricalYieldRecord] for an estimate create purely
     * (no network). The single block stores the sampling snapshot plus the
     * computed estimated tonnes; no actual is recorded yet. The caller mints
     * [id], [blockResultId] and [archivedAt] up front for identity stability.
     */
    fun buildEstimateRecord(
        vineyardId: String,
        input: EstimateInput,
        id: String,
        blockResultId: String,
        archivedAt: String,
    ): HistoricalYieldRecord {
        val tonnes = input.estimatedTonnes
        val perHectare = input.estimatedPerHectare
        val block = HistoricalBlockResult(
            id = blockResultId,
            paddockId = input.paddockId,
            paddockName = blockName(input.paddockName, input.variety),
            areaHectares = input.areaHectares,
            yieldTonnes = tonnes,
            yieldPerHectare = perHectare,
            averageBunchesPerVine = input.averageBunchesPerVine,
            averageBunchWeightGrams = input.averageBunchWeightGrams,
            totalVines = input.totalVines,
            samplesRecorded = input.samplesRecorded,
            damageFactor = input.damageFactor,
            actualYieldTonnes = null,
            actualRecordedAt = null,
        )
        return HistoricalYieldRecord(
            id = id,
            vineyardId = vineyardId,
            season = input.season.trim(),
            year = input.year,
            archivedAt = archivedAt,
            totalYieldTonnes = tonnes,
            totalAreaHectares = input.areaHectares,
            notes = input.notes?.trim().orEmpty(),
            blockResults = listOf(block),
        )
    }

    /**
     * Insert a fully-formed yield record. Shared by the online create flows and
     * offline replay ([YieldRecordCreateSync]) so a record's [HistoricalBlockResult]
     * array and totals are preserved byte-for-byte. `created_by` always resolves
     * from the live session, never from a payload; server-managed audit/sync
     * columns are never sent. [clientUpdatedAt] preserves the moment the operator
     * saved the record on replay.
     */
    suspend fun insertYieldRecord(
        record: HistoricalYieldRecord,
        clientUpdatedAt: String,
    ): HistoricalYieldRecord = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val body = YieldInsert(
            id = record.id,
            vineyardId = record.vineyardId,
            season = record.season.trim(),
            year = record.year,
            archivedAt = record.archivedAt ?: clientUpdatedAt,
            totalYieldTonnes = record.totalYieldTonnes,
            totalAreaHectares = record.totalAreaHectares,
            notes = record.notes,
            blockResults = record.blocks,
            createdBy = session.userId,
            clientUpdatedAt = clientUpdatedAt,
        )
        val response = SupabaseClient.http.post(SupabaseClient.restUrl("historical_yield_records")) {
            authHeaders(token)
            headers { append("Prefer", "return=representation") }
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        firstRow(response)
    }

    suspend fun listYieldRecords(vineyardId: String): List<HistoricalYieldRecord> =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.get(
                SupabaseClient.restUrl(
                    "historical_yield_records?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=year.desc,archived_at.desc",
                ),
            ) { authHeaders(token) }
            when {
                response.status.isSuccess() -> response.body()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /**
     * Archive a single block's actual yield. Default online behaviour is
     * unchanged: [id]/[blockResultId] mint fresh UUIDs and [archivedAt]/
     * [clientUpdatedAt] default to the current instant. Offline replay passes the
     * original client-generated identity + timestamps for idempotent, faithful
     * re-insertion. `created_by` always resolves from the live session.
     */
    suspend fun createYieldRecord(
        vineyardId: String,
        input: CreateInput,
        id: String? = null,
        blockResultId: String? = null,
        archivedAt: String? = null,
        clientUpdatedAt: String? = null,
    ): HistoricalYieldRecord {
        val now = nowIso()
        val record = buildActualRecord(
            vineyardId = vineyardId,
            input = input,
            id = id ?: UUID.randomUUID().toString(),
            blockResultId = blockResultId ?: UUID.randomUUID().toString(),
            archivedAt = archivedAt ?: now,
        )
        return insertYieldRecord(record, clientUpdatedAt ?: now)
    }

    /**
     * Create an estimate-only record from sampling inputs. The block result
     * stores the full sampling snapshot (avg bunches/vine, bunch weight, vines,
     * samples, damage factor) plus the computed estimated tonnes; no actual is
     * recorded yet. JSON keys all exist in the iOS `HistoricalBlockResult`
     * Codable contract, so the record round-trips to iOS unchanged.
     */
    /**
     * Create an estimate-only record from sampling inputs. Default online
     * behaviour is unchanged ([id]/[blockResultId] mint UUIDs; timestamps default
     * to now). Offline replay passes the original identity + timestamps. JSON
     * keys all exist in the iOS `HistoricalBlockResult` Codable contract, so the
     * record round-trips to iOS unchanged.
     */
    suspend fun createEstimateRecord(
        vineyardId: String,
        input: EstimateInput,
        id: String? = null,
        blockResultId: String? = null,
        archivedAt: String? = null,
        clientUpdatedAt: String? = null,
    ): HistoricalYieldRecord {
        val now = nowIso()
        val record = buildEstimateRecord(
            vineyardId = vineyardId,
            input = input,
            id = id ?: UUID.randomUUID().toString(),
            blockResultId = blockResultId ?: UUID.randomUUID().toString(),
            archivedAt = archivedAt ?: now,
        )
        return insertYieldRecord(record, clientUpdatedAt ?: now)
    }

    /**
     * Build the updated [HistoricalYieldRecord] for an estimate re-author purely
     * (no network). Recomputes the single block's estimated tonnes/per-hectare
     * from the new sampling inputs while preserving the block id and any recorded
     * actual, and recomputes the record totals. Shared by the online update flow
     * and the offline optimistic snapshot / queued payload so all three carry
     * identical values. Immutable identity (record id, vineyard id, archived-at)
     * is preserved from [record].
     */
    fun buildUpdatedEstimateRecord(
        record: HistoricalYieldRecord,
        input: EstimateInput,
    ): HistoricalYieldRecord {
        val existing = record.blocks.firstOrNull()
        val tonnes = input.estimatedTonnes
        val perHectare = input.estimatedPerHectare
        val block = HistoricalBlockResult(
            id = existing?.id ?: UUID.randomUUID().toString(),
            paddockId = input.paddockId,
            paddockName = blockName(input.paddockName, input.variety),
            areaHectares = input.areaHectares,
            yieldTonnes = tonnes,
            yieldPerHectare = perHectare,
            averageBunchesPerVine = input.averageBunchesPerVine,
            averageBunchWeightGrams = input.averageBunchWeightGrams,
            totalVines = input.totalVines,
            samplesRecorded = input.samplesRecorded,
            damageFactor = input.damageFactor,
            // Preserve any actual already recorded against this block.
            actualYieldTonnes = existing?.actualYieldTonnes,
            actualRecordedAt = existing?.actualRecordedAt,
        )
        return record.copy(
            season = input.season.trim(),
            year = input.year,
            totalYieldTonnes = tonnes,
            totalAreaHectares = input.areaHectares,
            notes = input.notes?.trim().orEmpty(),
            blockResults = listOf(block),
        )
    }

    /**
     * Re-author the estimate on an existing single-block estimate record from
     * new sampling inputs while preserving any recorded actual. Recomputes the
     * block's estimated tonnes/per-hectare and the record totals. [clientUpdatedAt]
     * defaults to now online; offline replay passes the queued stamp.
     */
    suspend fun updateEstimateRecord(
        record: HistoricalYieldRecord,
        input: EstimateInput,
        clientUpdatedAt: String? = null,
    ): HistoricalYieldRecord {
        val updated = buildUpdatedEstimateRecord(record, input)
        return updateYieldRecord(
            id = updated.id,
            season = updated.season,
            year = updated.year,
            totalYieldTonnes = updated.totalYieldTonnes,
            totalAreaHectares = updated.totalAreaHectares,
            notes = updated.notes,
            blockResults = updated.blocks,
            clientUpdatedAt = clientUpdatedAt,
        )
    }

    /**
     * Patch an existing record's editable fields after the caller updates the
     * per-block actuals / notes. The full reconciled `block_results` array and
     * recomputed totals are passed in so the record stays internally consistent.
     */
    suspend fun updateYieldRecord(
        id: String,
        season: String,
        year: Int,
        totalYieldTonnes: Double,
        totalAreaHectares: Double,
        notes: String,
        blockResults: List<HistoricalBlockResult>,
        clientUpdatedAt: String? = null,
    ): HistoricalYieldRecord = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val patch = YieldPatch(
            season = season.trim(),
            year = year,
            totalYieldTonnes = totalYieldTonnes,
            totalAreaHectares = totalAreaHectares,
            notes = notes.trim(),
            blockResults = blockResults,
            clientUpdatedAt = clientUpdatedAt ?: nowIso(),
        )
        val response = SupabaseClient.http.patch(SupabaseClient.restUrl("historical_yield_records?id=eq.$id")) {
            authHeaders(token)
            headers { append("Prefer", "return=representation") }
            contentType(ContentType.Application.Json)
            setBody(patch)
        }
        firstRow(response)
    }

    suspend fun softDeleteYieldRecord(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_historical_yield_record")) {
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

    private suspend fun firstRow(response: io.ktor.client.statement.HttpResponse): HistoricalYieldRecord = when {
        response.status.isSuccess() -> response.body<List<HistoricalYieldRecord>>().firstOrNull()
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
