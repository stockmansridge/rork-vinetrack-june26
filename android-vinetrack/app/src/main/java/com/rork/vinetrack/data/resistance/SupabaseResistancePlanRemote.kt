package com.rork.vinetrack.data.resistance

import com.rork.vinetrack.data.BackendError
import com.rork.vinetrack.data.SupabaseClient
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.sync.SyncRevisionContract
import com.rork.vinetrack.data.sync.VersionedWriteOutcome
import io.ktor.client.call.body
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.get
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
import kotlinx.serialization.json.Json
import java.time.Instant

/**
 * Server implementation of [ResistancePlanRemote] against `public.resistance_plans`
 * (sql/196 + sql/198), mirroring `SupabaseResistancePlanRepository.swift`.
 *
 * The wire row is a FLAT projection of the plan: the ordered `positions` document goes
 * across as JSONB exactly as both clients serialise it, and every other field is a
 * column. Epoch milliseconds are converted to ISO-8601 timestamps at this boundary and
 * nowhere else — the domain model stays in epoch ms on both platforms so plan arithmetic
 * never depends on a timezone.
 *
 * CONCURRENCY (sql/198). Two fields, two different jobs, and conflating them is the bug
 * this class was rewritten to remove:
 *
 *  * `base_revision` — the `server_revision` this edit was based on. THE CONCURRENCY
 *    AUTHORITY. Sent only for a plan the server has already issued a revision for.
 *  * `client_updated_at` — when the grower edited. Metadata for display and audit. Still
 *    sent (old clients and the legacy trigger path need it) but it no longer decides
 *    anything, and the server now clamps it to `now()` so a fast device clock cannot lock
 *    other writers out of the row.
 */
class SupabaseResistancePlanRemote(
    private val session: SessionStore,
) : ResistancePlanRemote {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false }

    /**
     * The row shape. `positions` is carried as the already-encoded JSON element so the
     * document is byte-identical to what the local cache holds and what iOS writes.
     */
    @Serializable
    private data class Row(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("season_id") val seasonId: String,
        @SerialName("season_start_year") val seasonStartYear: Int? = null,
        val disease: String,
        val jurisdiction: String = "AU",
        val crop: String = "grape",
        @SerialName("block_ids") val blockIds: List<String>? = null,
        val positions: List<ResistancePlannedPosition> = emptyList(),
        val notes: String? = null,
        @SerialName("ruleset_id") val rulesetId: String? = null,
        @SerialName("ruleset_version") val rulesetVersion: String? = null,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("created_at") val createdAt: String? = null,
        @SerialName("updated_at") val updatedAt: String? = null,
        @SerialName("deleted_at") val deletedAt: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String? = null,
        /**
         * Server-issued revision (sql/198). Nullable for tolerance, not because the column
         * is: a row written through a path that did not project it, or a response from a
         * pre-198 environment, must decode rather than throw.
         */
        @SerialName("server_revision") val serverRevision: Long? = null,
        /**
         * The version this write is based on. WRITE-ONLY — sql/198 always stores NULL, so
         * it never comes back and must never be read back.
         */
        @SerialName("base_revision") val baseRevision: Long? = null,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    override suspend fun fetchAll(vineyardId: String): List<ResistancePlan> =
        withContext(Dispatchers.IO) {
            val token = session.accessToken ?: throw BackendError.Unauthorized
            // Tombstones included on purpose — see ResistancePlanRemote.fetchAll.
            val response = SupabaseClient.http.get(
                SupabaseClient.restUrl("resistance_plans?vineyard_id=eq.$vineyardId&select=*"),
            ) { authHeaders(token) }

            when {
                response.status.isSuccess() -> response.body<List<Row>>().map { it.toPlan() }
                response.status.value == 401 || response.status.value == 403 ->
                    throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /**
     * One request PER PLAN, deliberately.
     *
     * A multi-row upsert is a single transaction, so one REVISION_CONFLICT would abort the
     * write of every other plan in the batch — edits that were perfectly valid would be
     * stranded because an unrelated plan lost a race. Plans are a handful per vineyard per
     * season, so the extra round trips cost little and buy per-row conflict isolation.
     */
    override suspend fun upsert(
        plans: List<ResistancePlan>,
    ): List<VersionedWriteOutcome<ResistancePlan>> = withContext(Dispatchers.IO) {
        plans.map { writeOne(it) }
    }

    private suspend fun writeOne(plan: ResistancePlan): VersionedWriteOutcome<ResistancePlan> {
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.restUrl("resistance_plans")) {
            authHeaders(token)
            headers {
                // merge-duplicates so an edit and a create use one code path, exactly
                // like every other synced VineTrack entity.
                //
                // return=representation, NOT return=minimal: the response body is the only
                // place the new `server_revision` appears. With `minimal` this device could
                // never learn what version its own edit became, would resend the previous
                // base_revision on the next edit, and would be refused forever. This is the
                // one place where an extra payload is not optional.
                append("Prefer", "resolution=merge-duplicates,return=representation")
            }
            contentType(ContentType.Application.Json)
            setBody(listOf(plan.toRow()))
        }
        val body = response.bodyAsText()
        return when {
            response.status.isSuccess() -> {
                val rows = runCatching { json.decodeFromString<List<Row>>(body) }.getOrDefault(emptyList())
                val row = rows.firstOrNull()
                if (row == null) {
                    // A 2xx with NO row is the legacy silent-skip signature (a BEFORE
                    // UPDATE trigger returning NULL). Under sql/198 a versioned write
                    // cannot land here — it raises instead — but an old-path write still
                    // can, and reporting it as success is precisely the bug that lost
                    // growers' edits. Surfaced as a conflict so the local copy is kept.
                    VersionedWriteOutcome.Conflict(
                        rowId = plan.id,
                        baseRevision = plan.serverRevision,
                        serverRevision = null,
                    )
                } else {
                    VersionedWriteOutcome.Applied(row.toPlan())
                }
            }
            SyncRevisionContract.isRevisionConflict(response.status.value, body) ->
                VersionedWriteOutcome.Conflict(
                    rowId = plan.id,
                    baseRevision = SyncRevisionContract.baseRevisionFrom(body) ?: plan.serverRevision,
                    serverRevision = SyncRevisionContract.serverRevisionFrom(body),
                )
            response.status.value == 401 || response.status.value == 403 ->
                throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, body)
        }
    }

    override suspend fun softDelete(planId: String) = withContext(Dispatchers.IO) {
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(
            SupabaseClient.restUrl("rpc/soft_delete_resistance_plan"),
        ) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(SoftDeleteArgs(planId))
        }
        if (!response.status.isSuccess()) {
            if (response.status.value == 401 || response.status.value == 403) {
                throw BackendError.Unauthorized
            }
            throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    // ------------------------------------------------------------------
    // Mapping
    // ------------------------------------------------------------------

    private fun ResistancePlan.toRow(): Row = Row(
        id = id,
        vineyardId = vineyardId,
        seasonId = seasonId,
        seasonStartYear = seasonStartYear,
        disease = disease.raw,
        jurisdiction = jurisdiction.raw,
        crop = crop.raw,
        blockIds = blockIds.ifEmpty { null },
        positions = positions,
        notes = notes,
        rulesetId = rulesetId,
        rulesetVersion = rulesetVersion,
        createdBy = createdBy ?: session.userId,
        // created_at / updated_at / deleted_at are server-owned.
        //
        // client_updated_at is the grower's real edit time. It is METADATA now: sql/198
        // clamps it to server now() and no longer lets it decide who wins.
        clientUpdatedAt = isoFrom(updatedAtEpochMs),
        // base_revision is the concurrency authority, and is sent ONLY when this device
        // actually knows a server revision. For a never-synced plan it stays null, which
        // sql/198 reads as a create — inventing a number here (0, or 1, or "probably 1")
        // would assert a version this device never read.
        //
        // server_revision is NOT sent: it is server-owned and the bump trigger overwrites
        // whatever a client supplies, so sending it would be a lie with no effect.
        baseRevision = serverRevision,
    )

    private fun Row.toPlan(): ResistancePlan = ResistancePlan(
        id = id,
        vineyardId = vineyardId,
        seasonId = seasonId,
        seasonStartYear = seasonStartYear ?: seasonStartYearFrom(seasonId),
        disease = ResistanceDisease.entries.firstOrNull { it.raw == disease }
            ?: ResistanceDisease.POWDERY_MILDEW,
        jurisdiction = ResistanceJurisdiction.entries.firstOrNull { it.raw == jurisdiction }
            ?: ResistanceJurisdiction.UNKNOWN,
        crop = ResistanceCrop.entries.firstOrNull { it.raw == crop } ?: ResistanceCrop.GRAPE,
        blockIds = blockIds ?: emptyList(),
        positions = positions,
        notes = notes,
        rulesetId = rulesetId,
        rulesetVersion = rulesetVersion,
        createdBy = createdBy,
        createdAtEpochMs = epochFrom(createdAt) ?: 0L,
        // The grower's edit time, for display and ordering in the list. No longer a
        // concurrency signal — `serverRevision` is.
        updatedAtEpochMs = epochFrom(clientUpdatedAt) ?: epochFrom(updatedAt) ?: 0L,
        deletedAtEpochMs = epochFrom(deletedAt),
        serverRevision = serverRevision,
    )

    private fun isoFrom(epochMs: Long): String = Instant.ofEpochMilli(epochMs).toString()

    private fun epochFrom(iso: String?): Long? {
        val raw = iso?.takeIf { it.isNotBlank() } ?: return null
        return runCatching { Instant.parse(raw).toEpochMilli() }
            .recoverCatching {
                // PostgREST returns `2026-07-22T01:02:03.456789` without a zone for some
                // column configurations. Treat it as UTC rather than dropping the plan.
                Instant.parse(raw.trimEnd('Z') + "Z").toEpochMilli()
            }
            .getOrNull()
    }

    /** "2026/27" -> 2026, so a legacy row without the column still sorts correctly. */
    private fun seasonStartYearFrom(seasonId: String): Int =
        seasonId.take(4).toIntOrNull() ?: 0

    private fun HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }
}
