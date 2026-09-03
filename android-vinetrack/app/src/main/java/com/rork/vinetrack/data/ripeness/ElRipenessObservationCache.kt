package com.rork.vinetrack.data.ripeness

import android.content.Context
import android.util.Log
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

/**
 * One cached observation. Stored flat and verbatim — every timestamp stays a
 * String so the contract's day-key slice behaves identically on replay.
 */
@Serializable
data class ElRipenessCachedRecord(
    val id: String,
    val vineyardId: String? = null,
    val paddockId: String? = null,
    val stageCode: String? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val date: String? = null,
    val observedAt: String? = null,
    val completedAt: String? = null,
    val createdAt: String? = null,
    val deletedAt: String? = null,
    val placementAssigned: Boolean? = null,
    val pinId: String? = null,
) {
    val rawRecord: ElRipenessHeatmap.RawRecord
        get() = ElRipenessHeatmap.RawRecord(
            id = id,
            vineyardId = vineyardId,
            paddockId = paddockId,
            stageCode = stageCode,
            latitude = latitude,
            longitude = longitude,
            date = date,
            observedAt = observedAt,
            completedAt = completedAt,
            createdAt = createdAt,
            deletedAt = deletedAt,
        )

    val sourceRecord: ElRipenessObservationAdapter.SourceRecord
        get() = ElRipenessObservationAdapter.SourceRecord(
            record = rawRecord,
            origin = ElRipenessObservationAdapter.Origin.CACHED,
            placementAssigned = placementAssigned,
            pinId = pinId,
        )

    companion object {
        fun from(source: ElRipenessObservationAdapter.SourceRecord): ElRipenessCachedRecord {
            val r = source.record
            return ElRipenessCachedRecord(
                id = r.id,
                vineyardId = r.vineyardId,
                paddockId = r.paddockId,
                stageCode = r.stageCode,
                latitude = r.latitude,
                longitude = r.longitude,
                date = r.date,
                observedAt = r.observedAt,
                completedAt = r.completedAt,
                createdAt = r.createdAt,
                deletedAt = r.deletedAt,
                placementAssigned = source.placementAssigned,
                pinId = source.pinId,
            )
        }
    }
}

/** A block polygon captured alongside the observations it was drawn with. */
@Serializable
data class ElRipenessCachedBlock(
    val id: String,
    val name: String? = null,
    val polygon: List<List<Double>> = emptyList(),
) {
    val blockInput: ElRipenessHeatmap.BlockInput
        get() = ElRipenessHeatmap.BlockInput(
            id = id,
            name = name,
            polygon = polygon.mapNotNull {
                if (it.size >= 2) ElRipenessHeatmap.LatLng(it[0], it[1]) else null
            },
        )

    companion object {
        fun from(input: ElRipenessHeatmap.BlockInput): ElRipenessCachedBlock =
            ElRipenessCachedBlock(
                id = input.id,
                name = input.name,
                polygon = input.polygon.map { listOf(it.lat, it.lng) },
            )
    }
}

/** Everything needed to redraw the heatmap with no network at all. */
@Serializable
data class ElRipenessCachePayload(
    val vineyardId: String,
    val cachedAtEpochMs: Long,
    val records: List<ElRipenessCachedRecord> = emptyList(),
    val blocks: List<ElRipenessCachedBlock> = emptyList(),
) {
    val sourceRecords: List<ElRipenessObservationAdapter.SourceRecord>
        get() = records.map { it.sourceRecord }

    val blockInputs: List<ElRipenessHeatmap.BlockInput>
        get() = blocks.map { it.blockInput }
}

/** Storage seam so tests can drive the model without touching disk. */
interface ElRipenessObservationCaching {
    fun load(vineyardId: String): ElRipenessCachePayload?
    fun save(payload: ElRipenessCachePayload)
    fun clear(vineyardId: String)
}

/**
 * On-disk JSON cache, one file per vineyard.
 *
 * Mirrors the Swift `ELRipenessObservationCache`. Failures are swallowed and
 * logged without payload contents: a corrupt or unreadable cache must degrade
 * to "no cache", never crash the screen.
 */
class ElRipenessObservationCache(context: Context) : ElRipenessObservationCaching {

    private val appContext = context.applicationContext

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }

    private val directory: File
        get() = File(appContext.filesDir, DIRECTORY).apply { if (!exists()) mkdirs() }

    private fun file(vineyardId: String): File =
        File(directory, "${vineyardId.lowercase()}.json")

    override fun load(vineyardId: String): ElRipenessCachePayload? = try {
        val f = file(vineyardId)
        if (f.exists()) json.decodeFromString<ElRipenessCachePayload>(f.readText()) else null
    } catch (e: Exception) {
        Log.w(TAG, "Ripeness cache unreadable, ignoring: ${e.javaClass.simpleName}")
        null
    }

    override fun save(payload: ElRipenessCachePayload) {
        try {
            file(payload.vineyardId).writeText(json.encodeToString(payload))
        } catch (e: Exception) {
            Log.w(TAG, "Ripeness cache not written: ${e.javaClass.simpleName}")
        }
    }

    override fun clear(vineyardId: String) {
        try {
            file(vineyardId).delete()
        } catch (e: Exception) {
            Log.w(TAG, "Ripeness cache not cleared: ${e.javaClass.simpleName}")
        }
    }

    private companion object {
        const val DIRECTORY = "ripeness-heatmap"
        const val TAG = "VineTrackRipeness"
    }
}
