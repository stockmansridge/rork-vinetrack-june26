package com.rork.vinetrack.data.resistance

import com.rork.vinetrack.data.BackendError
import com.rork.vinetrack.data.SupabaseClient
import com.rork.vinetrack.data.auth.SessionStore
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
 * (sql/196), mirroring `SupabaseResistancePlanRepository.swift`.
 *
 * The wire row is a FLAT projection of the plan: the ordered `positions` document goes
 * across as JSONB exactly as both clients serialise it, and every other field is a
 * column. Epoch milliseconds are converted to ISO-8601 timestamps at this boundary and
 * nowhere else — the domain model stays in epoch ms on both platforms so plan arithmetic
 * never depends on a timezone.
 *
 * `client_updated_at` carries the plan's own `updated_at_epoch_ms`. That is what makes
 * the sql/185 stale-write trigger able to reject a late offline replay: the timestamp
 * the server compares is the moment the GROWER edited, not the moment the request
 * happened to arrive.
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

    override suspend fun upsert(plans: List<ResistancePlan>) = withContext(Dispatchers.IO) {
        if (plans.isEmpty()) return@withContext
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val body = plans.map { it.toRow() }
        val response = SupabaseClient.http.post(SupabaseClient.restUrl("resistance_plans")) {
            authHeaders(token)
            headers {
                // merge-duplicates so an edit and a create use one code path, exactly
                // like every other synced VineTrack entity.
                append("Prefer", "resolution=merge-duplicates,return=minimal")
            }
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        if (!response.status.isSuccess()) {
            if (response.status.value == 401 || response.status.value == 403) {
                throw BackendError.Unauthorized
            }
            throw BackendError.Server(response.status.value, response.bodyAsText())
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
        // created_at / updated_at / deleted_at are server-owned. Only the client's own
        // edit stamp is sent, and it is the plan's real edit time so a late replay is
        // honestly dated and correctly rejected if it is stale.
        clientUpdatedAt = isoFrom(updatedAtEpochMs),
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
        // The plan's authoritative edit time is the client stamp when present: it is what
        // the conflict comparison uses on the next pass, so falling back to the server's
        // updated_at (which moves on every unrelated server-side touch) would make a
        // remote row look newer than it is.
        updatedAtEpochMs = epochFrom(clientUpdatedAt) ?: epochFrom(updatedAt) ?: 0L,
        deletedAtEpochMs = epochFrom(deletedAt),
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
