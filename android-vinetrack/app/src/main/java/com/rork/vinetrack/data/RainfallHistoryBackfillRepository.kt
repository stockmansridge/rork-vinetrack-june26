package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.TimeZone
import kotlin.math.max
import kotlin.math.min

/**
 * Aggregated outcome of a chunked Davis or Weather Underground rainfall
 * backfill loop. Mirrors the iOS `ChunkedRainfallBackfillResult`.
 */
data class ChunkedRainfallBackfillResult(
    val daysRequested: Int,
    val daysProcessed: Int,
    val rowsUpserted: Int,
    val errorsCount: Int,
    val chunksCompleted: Int,
    /** True when a chunk reported `rate_limited` and the loop stopped early. */
    val rateLimited: Boolean,
    /** True when the full requested range was covered. */
    val completed: Boolean,
    /** Offset to resume from on a future retry; null when fully completed. */
    val resumeOffset: Int?,
    val proxyVersion: String?,
    /** Optional station label (WU only). */
    val stationLabel: String?,
)

/** Per-chunk progress snapshot for the UI progress bar. */
data class ChunkedRainfallProgress(
    val daysProcessed: Int,
    val daysRequested: Int,
    val rowsUpsertedTotal: Int,
    val chunksCompleted: Int,
    val rateLimited: Boolean,
)

/** Result of an Open-Meteo `backfill_rainfall_gaps` run. */
data class OpenMeteoGapFillResult(
    val success: Boolean,
    val daysRequested: Int,
    val daysProcessed: Int,
    val rowsUpserted: Int,
    val daysSkippedBetterSource: Int,
    val daysSkippedNoData: Int,
    val errorsCount: Int,
    val proxyVersion: String?,
)

/**
 * Drives long-range chunked rainfall backfills across the three shared edge
 * functions (`davis-proxy`, `wunderground-proxy`, `open-meteo-proxy`). Mirrors
 * the iOS `RainfallHistoryBackfillService`:
 *
 *  - Davis runs in 60-day chunks, Weather Underground in 30-day chunks.
 *  - Each loop stops on a rate-limit and reports a resume offset so the user
 *    can pick up later.
 *  - Open-Meteo only fills days still missing after Manual / Davis / WU.
 *
 * All backfills are owner/manager only (enforced server-side).
 */
class RainfallHistoryBackfillRepository(private val session: SessionStore) {

    private val timezone: String get() = TimeZone.getDefault().id

    // MARK: - Davis

    /**
     * Loop `davis-proxy backfill_rainfall` until the requested range is covered
     * or WeatherLink rate-limits us. Davis chunk size defaults to 60 days.
     */
    suspend fun backfillDavisChunked(
        vineyardId: String,
        stationId: String,
        totalDays: Int = 365,
        chunkDays: Int = 60,
        startOffset: Int = 0,
        onProgress: ((ChunkedRainfallProgress) -> Unit)? = null,
    ): ChunkedRainfallBackfillResult = withContext(Dispatchers.IO) {
        val total = max(1, min(365, totalDays))
        val chunk = max(1, min(60, chunkDays))
        var offset = max(0, min(total, startOffset))

        var processedTotal = 0
        var rowsTotal = 0
        var errorsTotal = 0
        var chunks = 0
        var lastVersion: String? = null
        var rateLimited = false

        while (offset < total) {
            val json = invoke("davis-proxy", buildJsonObject {
                put("vineyardId", vineyardId)
                put("action", "backfill_rainfall")
                put("stationId", stationId)
                put("days", total)
                put("offsetDays", offset)
                put("chunkDays", chunk)
                put("timezone", timezone)
            })
            processedTotal += json.intOf("days_processed")
            rowsTotal += json.intOf("rows_upserted")
            errorsTotal += json.intOf("errors_count")
            chunks += 1
            json.stringOf("proxy_version")?.let { lastVersion = it }

            val chunkRateLimited = json.boolOf("rate_limited")
            val nextOffset = json.intOrNullOf("next_offset_days")
            val more = json.boolOf("more")

            onProgress?.invoke(
                ChunkedRainfallProgress(
                    daysProcessed = processedTotal,
                    daysRequested = total,
                    rowsUpsertedTotal = rowsTotal,
                    chunksCompleted = chunks,
                    rateLimited = chunkRateLimited,
                )
            )

            if (chunkRateLimited) {
                rateLimited = true
                offset = nextOffset ?: (offset + chunk)
                break
            }
            if (nextOffset == null || !more) {
                offset = total
                break
            }
            if (nextOffset <= offset) break
            offset = nextOffset
            delay(250)
        }

        val completed = !rateLimited && offset >= total
        ChunkedRainfallBackfillResult(
            daysRequested = total,
            daysProcessed = processedTotal,
            rowsUpserted = rowsTotal,
            errorsCount = errorsTotal,
            chunksCompleted = chunks,
            rateLimited = rateLimited,
            completed = completed,
            resumeOffset = if (completed) null else offset,
            proxyVersion = lastVersion,
            stationLabel = null,
        )
    }

    // MARK: - Weather Underground

    /**
     * Loop `wunderground-proxy backfill_rainfall` until the requested range is
     * covered or WU rate-limits us. WU chunk size defaults to 30 days.
     */
    suspend fun backfillWundergroundChunked(
        vineyardId: String,
        stationId: String? = null,
        totalDays: Int = 365,
        chunkDays: Int = 30,
        startOffset: Int = 0,
        onProgress: ((ChunkedRainfallProgress) -> Unit)? = null,
    ): ChunkedRainfallBackfillResult = withContext(Dispatchers.IO) {
        val total = max(1, min(365, totalDays))
        val chunk = max(1, min(30, chunkDays))
        var offset = max(0, min(total, startOffset))

        var processedTotal = 0
        var rowsTotal = 0
        var errorsTotal = 0
        var chunks = 0
        var lastVersion: String? = null
        var lastStationLabel: String? = null
        var rateLimited = false

        while (offset < total) {
            val json = invoke("wunderground-proxy", buildJsonObject {
                put("vineyardId", vineyardId)
                put("action", "backfill_rainfall")
                if (stationId != null) put("stationId", stationId)
                put("days", total)
                put("offsetDays", offset)
                put("chunkDays", chunk)
                put("timezone", timezone)
            })
            processedTotal += json.intOf("days_processed")
            rowsTotal += json.intOf("rows_upserted")
            errorsTotal += json.intOf("errors_count")
            chunks += 1
            json.stringOf("proxy_version")?.let { lastVersion = it }
            json.stringOf("station_name")?.takeIf { it.isNotBlank() }?.let { lastStationLabel = it }
            if (lastStationLabel == null) {
                json.stringOf("station_id")?.takeIf { it.isNotBlank() }?.let { lastStationLabel = it }
            }

            val chunkRateLimited = json.boolOf("rate_limited")
            val nextOffset = json.intOrNullOf("next_offset_days")
            val more = json.boolOf("more")

            onProgress?.invoke(
                ChunkedRainfallProgress(
                    daysProcessed = processedTotal,
                    daysRequested = total,
                    rowsUpsertedTotal = rowsTotal,
                    chunksCompleted = chunks,
                    rateLimited = chunkRateLimited,
                )
            )

            if (chunkRateLimited) {
                rateLimited = true
                offset = nextOffset ?: (offset + chunk)
                break
            }
            if (nextOffset == null || !more) {
                offset = total
                break
            }
            if (nextOffset <= offset) break
            offset = nextOffset
            delay(350)
        }

        val completed = !rateLimited && offset >= total
        ChunkedRainfallBackfillResult(
            daysRequested = total,
            daysProcessed = processedTotal,
            rowsUpserted = rowsTotal,
            errorsCount = errorsTotal,
            chunksCompleted = chunks,
            rateLimited = rateLimited,
            completed = completed,
            resumeOffset = if (completed) null else offset,
            proxyVersion = lastVersion,
            stationLabel = lastStationLabel,
        )
    }

    // MARK: - Open-Meteo gap fill

    /** Fill remaining rainfall gaps from the Open-Meteo archive (lowest priority). */
    suspend fun backfillOpenMeteoGaps(
        vineyardId: String,
        days: Int = 365,
    ): OpenMeteoGapFillResult = withContext(Dispatchers.IO) {
        val json = invoke("open-meteo-proxy", buildJsonObject {
            put("vineyardId", vineyardId)
            put("action", "backfill_rainfall_gaps")
            put("days", days)
            put("timezone", timezone)
        })
        OpenMeteoGapFillResult(
            success = json.boolOf("success"),
            daysRequested = json.intOf("days_requested"),
            daysProcessed = json.intOf("days_processed"),
            rowsUpserted = json.intOf("rows_upserted"),
            daysSkippedBetterSource = json.intOf("days_skipped_better_source"),
            daysSkippedNoData = json.intOf("days_skipped_no_data"),
            errorsCount = json.intOf("errors_count"),
            proxyVersion = json.stringOf("proxy_version"),
        )
    }

    // MARK: - HTTP

    private suspend fun invoke(function: String, payload: JsonObject): JsonObject {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.functionUrl(function)) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(payload)
        }
        val text = response.bodyAsText()
        if (response.status.isSuccess()) {
            return SupabaseClient.json.parseToJsonElement(text).jsonObject
        }
        if (response.status.value == 401 || response.status.value == 403) throw BackendError.Unauthorized
        val message = runCatching {
            SupabaseClient.json.parseToJsonElement(text).jsonObject["error"]?.jsonPrimitive?.content
        }.getOrNull()
        throw BackendError.Server(response.status.value, message ?: text)
    }

    private fun JsonObject.intOf(key: String): Int =
        this[key]?.jsonPrimitive?.intOrNull ?: 0

    private fun JsonObject.intOrNullOf(key: String): Int? =
        this[key]?.jsonPrimitive?.intOrNull

    private fun JsonObject.boolOf(key: String): Boolean =
        this[key]?.jsonPrimitive?.let { it.booleanOrNull ?: (it.content.toBooleanStrictOrNull()) } ?: false

    private fun JsonObject.stringOf(key: String): String? =
        this[key]?.jsonPrimitive?.content?.takeIf { it != "null" }

    private fun HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }
}
