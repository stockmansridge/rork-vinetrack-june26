package com.rork.vinetrack.data

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/** Local-only evidence for qualified automatic pin observations; never uploaded. */
class PinCaptureEvidenceStore(context: Context) {
    @Serializable
    data class Evidence(
        val pinId: String,
        val vineyardId: String,
        val tripId: String?,
        val buttonName: String,
        val mode: String,
        val side: String,
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

    fun load(): List<Evidence> = preferences.getString(KEY, null)?.let { raw ->
        runCatching { json.decodeFromString(serializer, raw) }.getOrDefault(emptyList())
    } ?: emptyList()

    private companion object { const val KEY = "pin_capture_evidence_json" }
}
