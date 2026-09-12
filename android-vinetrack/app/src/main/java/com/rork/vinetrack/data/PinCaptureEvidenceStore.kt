package com.rork.vinetrack.data

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/** Durable evidence outbox for qualified automatic pin observations. */
class PinCaptureEvidenceStore(context: Context) {
    @Serializable
    data class Evidence(
        val pinId: String,
        val vineyardId: String,
        val tripId: String?,
        val buttonName: String,
        val mode: String,
        val side: String? = null,
        val latitude: Double,
        val longitude: Double,
        val fixTimeEpochMs: Long,
        val accuracyMetres: Double,
        val observationTimeIso: String,
        val headingDegrees: Double?,
        val paddockId: String?,
        val pinRowNumber: Double?,
        val pinSide: String?,
        val snappedLatitude: Double?,
        val snappedLongitude: Double?,
        val alongRowDistanceMetres: Double?,
        val snappedToRow: Boolean,
        val drivingRowNumber: Double? = null,
        val evidenceRevision: Int = 1,
        val resolverVersion: String = "server-geometry-v2",
        val headingSource: String? = null,
        val headingObservedAtIso: String? = null,
        val geometryRevision: String? = null,
        val geometryHash: String? = null,
        val observations: List<Observation> = emptyList(),
        val uploaded: Boolean = false,
    )

    @Serializable
    data class Observation(
        val observedAtIso: String,
        val latitude: Double,
        val longitude: Double,
        val accuracyMetres: Double,
    )

    private val preferences = context.applicationContext
        .getSharedPreferences("vinetrack_pin_capture_evidence", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val serializer = ListSerializer(Evidence.serializer())

    fun save(evidence: Evidence): Boolean {
        val existing = load().filterNot { it.pinId == evidence.pinId }
        return preferences.edit()
            .putString(KEY, json.encodeToString(serializer, existing + evidence))
            .commit()
    }

    fun markUploaded(pinId: String, evidenceRevision: Int): Boolean {
        val next = load().map {
            if (it.pinId == pinId && it.evidenceRevision == evidenceRevision) it.copy(uploaded = true) else it
        }
        return preferences.edit().putString(KEY, json.encodeToString(serializer, next)).commit()
    }

    fun pending(): List<Evidence> = load().filterNot { it.uploaded }

    fun load(): List<Evidence> = preferences.getString(KEY, null)?.let { raw ->
        runCatching { json.decodeFromString(serializer, raw) }.getOrDefault(emptyList())
    } ?: emptyList()

    private companion object { const val KEY = "pin_capture_evidence_json" }
}
