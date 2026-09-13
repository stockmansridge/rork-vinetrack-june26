package com.rork.vinetrack.data

import android.content.Context
import androidx.core.util.AtomicFile
import com.rork.vinetrack.data.model.Paddock
import java.io.File
import java.security.MessageDigest
import java.util.Locale
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/** Durable immutable evidence outbox for qualified automatic pin observations. */
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
        val resolverVersion: String = "server-geometry-v3",
        val capturedAtIso: String = observationTimeIso,
        val captureUserId: String? = null,
        val headingSource: String? = null,
        val headingObservedAtIso: String? = null,
        val aisleLock: AisleLock? = null,
        val geometryRevision: String? = null,
        val geometryHash: String? = null,
        val observations: List<Observation> = emptyList(),
        val uploaded: Boolean = false,
    )

    @Serializable
    data class Observation(
        @kotlinx.serialization.SerialName("observedAt") val observedAtIso: String,
        val latitude: Double,
        val longitude: Double,
        @kotlinx.serialization.SerialName("horizontalAccuracyM") val accuracyMetres: Double? = null,
        val courseDegrees: Double? = null,
        @kotlinx.serialization.SerialName("speedMps") val speedMetresPerSecond: Double? = null,
    )

    @Serializable
    data class AisleLock(
        val paddockId: String,
        val aisleNumber: Double,
        val supportingObservations: Int,
        @kotlinx.serialization.SerialName("confirmedAt") val confirmedAtIso: String,
    )

    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences("vinetrack_pin_capture_evidence", Context.MODE_PRIVATE)
    private val recoveryFile = AtomicFile(File(appContext.filesDir, "pin_capture_evidence_recovery_v2.json"))
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false }
    private val serializer = ListSerializer(Evidence.serializer())

    fun save(evidence: Evidence): Boolean {
        val existing = load().filterNot { it.pinId == evidence.pinId && it.evidenceRevision == evidence.evidenceRevision }
        return persist(existing + evidence)
    }

    fun markUploaded(pinId: String, evidenceRevision: Int): Boolean = persist(
        load().map {
            if (it.pinId == pinId && it.evidenceRevision == evidenceRevision) it.copy(uploaded = true) else it
        },
    )

    fun pending(): List<Evidence> = load().filterNot { it.uploaded }

    fun load(): List<Evidence> {
        val primary = preferences.getString(KEY, null)?.let { raw ->
            runCatching { json.decodeFromString(serializer, raw) }.getOrDefault(emptyList())
        }.orEmpty()
        val recovery = runCatching {
            if (!recoveryFile.baseFile.exists()) emptyList()
            else recoveryFile.openRead().use { input -> json.decodeFromString(serializer, input.readBytes().decodeToString()) }
        }.getOrDefault(emptyList())
        return (primary + recovery).associateBy { "${it.pinId}#${it.evidenceRevision}" }.values.toList()
    }

    private fun persist(records: List<Evidence>): Boolean {
        val encoded = json.encodeToString(serializer, records)
        if (preferences.edit().putString(KEY, encoded).commit()) {
            runCatching { recoveryFile.delete() }
            return true
        }
        return runCatching {
            val stream = recoveryFile.startWrite()
            try {
                stream.write(encoded.encodeToByteArray())
                recoveryFile.finishWrite(stream)
            } catch (error: Throwable) {
                recoveryFile.failWrite(stream)
                throw error
            }
            true
        }.getOrDefault(false)
    }

    companion object {
        private const val KEY = "pin_capture_evidence_json"

        /** Canonical geometry identity shared byte-for-byte with iOS and SQL. */
        fun geometryIdentity(paddock: Paddock?): Pair<String?, String?> {
            paddock ?: return null to null
            fun number(value: Double): String = String.format(Locale.US, "%.8f", value)
            val polygon = paddock.polygonPoints.orEmpty().joinToString(";") { "${number(it.latitude)},${number(it.longitude)}" }
            val rows = paddock.rows.orEmpty().sortedBy { it.number }.joinToString(";") { row ->
                val start = row.startPoint
                val end = row.endPoint
                "${row.number}:${start?.let { "${number(it.latitude)},${number(it.longitude)}" }.orEmpty()}>${end?.let { "${number(it.latitude)},${number(it.longitude)}" }.orEmpty()}"
            }
            val canonical = "pin-geometry-v1|p=$polygon|r=$rows"
            val digest = MessageDigest.getInstance("SHA-256").digest(canonical.encodeToByteArray()).joinToString("") { "%02x".format(it) }
            return "pin-geometry-v1" to "pin-geometry-v1:$digest"
        }
    }
}
