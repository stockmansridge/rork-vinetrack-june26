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
        val compassDegrees: Double? = null,
        val compassObservedAtIso: String? = null,
        val unresolvedReason: String? = null,
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
    private val fieldAccess = com.rork.vinetrack.data.auth.FieldStoreAccess(context)
    private val preferences = fieldAccess.preferences(appContext.getSharedPreferences("vinetrack_pin_capture_evidence", Context.MODE_PRIVATE))
    private val recoveryFile = AtomicFile(File(appContext.filesDir, "pin_capture_evidence_recovery_v2.json"))
    private val json = Json { ignoreUnknownKeys = false; encodeDefaults = true; explicitNulls = false }
    private val serializer = ListSerializer(Evidence.serializer())

    private val _readIssue = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)
    val readIssue: kotlinx.coroutines.flow.StateFlow<String?> = _readIssue

    /** A held result is not an authoritative empty store and must never be persisted. */
    fun loadForRecovery(): LocalEvidenceRead<Evidence> = readForRecovery { load() }.also {
        _readIssue.value = it.issue
    }

    fun save(evidence: Evidence): Boolean = fieldAccess.admitted { synchronized(evidenceLock) {
        val read = loadForRecovery()
        if (read.issue != null) return@synchronized false
        val existing = read.items
        val original = existing.firstOrNull { it.pinId == evidence.pinId && it.evidenceRevision == evidence.evidenceRevision }
        if (original != null) return@synchronized (original.copy(uploaded = false) == evidence.copy(uploaded = false) && persist(existing))
        persist(existing + evidence)
    } }

    fun markUploaded(pinId: String, evidenceRevision: Int): Boolean = fieldAccess.admitted { synchronized(evidenceLock) {
        val read = loadForRecovery()
        if (read.issue != null) return@synchronized false
        persist(read.items.map {
            if (it.pinId == pinId && it.evidenceRevision == evidenceRevision) it.copy(uploaded = true) else it
        })
    } }

    fun pending(): List<Evidence> {
        val read = loadForRecovery()
        check(read.issue == null) { read.issue.orEmpty() }
        return read.items.filterNot { it.uploaded }
    }

    fun load(): List<Evidence> = fieldAccess.admitted { synchronized(evidenceLock) {
        val base = recoveryFile.baseFile
        val raw = preferences.getString(KEY, null)
        // A failed commit can publish acknowledgement flags in preference memory.
        // Keep observations, but do not trust those flags until a durable commit.
        val primary = if (raw != null && raw == unprovenPrimaryRaw) {
            json.encodeToString(serializer, json.decodeFromString(serializer, raw).map { it.copy(uploaded = false) })
        } else raw
        readRetainedEvidence(primary, listOf(base, File(base.path + ".bak"), File(base.path + ".new")))
    } }

    /** Capture all AtomicFile candidates and acknowledgement proof before suspension. */
    internal fun freezeForRecovery(): () -> List<Evidence> = fieldAccess.admitted { synchronized(evidenceLock) {
        val raw = preferences.getString(KEY, null)
        val unproven = raw != null && raw == unprovenPrimaryRaw
        val base = recoveryFile.baseFile
        val retained = listOf(base, File(base.path + ".bak"), File(base.path + ".new")).map {
            if (it.exists()) it.readText() else null
        }
        val decode: () -> List<Evidence> = { decodeRetainedEvidence(raw, retained, unproven) }
        decode
    } }

    private fun persist(records: List<Evidence>): Boolean = fieldAccess.admitted {
        val encoded = json.encodeToString(serializer, records)
        unprovenPrimaryRaw = encoded
        if (runCatching { preferences.edit().putString(KEY, encoded).commit() }.getOrDefault(false)) {
            unprovenPrimaryRaw = null
            runCatching { recoveryFile.delete() }
            return@admitted true
        }
        // Never truncate the sole surviving recovery evidence after a failed
        // primary commit. A later successful primary commit can consolidate it.
        val base = recoveryFile.baseFile
        if (listOf(base, File(base.path + ".bak"), File(base.path + ".new")).any { it.exists() }) return@admitted false
        runCatching {
            val stream = recoveryFile.startWrite()
            try {
                stream.write(encoded.encodeToByteArray())
                recoveryFile.finishWrite(stream)
            } catch (error: Throwable) {
                recoveryFile.failWrite(stream)
                throw error
            }
            unprovenPrimaryRaw = null
            true
        }.getOrDefault(false)
    }

    companion object {
        private const val KEY = "pin_capture_evidence_json"
        private val evidenceLock = Any()
        private var unprovenPrimaryRaw: String? = null

        /** Side-effect-free AtomicFile recovery read: retain base, backup and
         * interrupted-new bytes until their combined evidence is durably saved.
         * Uploaded is acknowledgement metadata, not an immutable observation conflict.
         * A torn or conflicting source holds this evidence store, never replaces it.
         */
        internal fun readForRecovery(read: () -> List<Evidence>): LocalEvidenceRead<Evidence> = try {
            LocalEvidenceRead(read())
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            LocalEvidenceRead(emptyList(), "Saved pin capture evidence needs recovery review. Original sources were retained; automatic sync is paused. Do not clear app data.")
        }

        internal fun readRetainedEvidence(primary: String?, files: List<File>): List<Evidence> {
            // A newer unknown evidence field cannot be safely re-encoded by
            // this build. Hold its original sources rather than discard fields.
            return decodeRetainedEvidence(primary, files.map { if (it.exists()) it.readText() else null }, false)
        }

        internal fun decodeRetainedEvidence(primary: String?, retained: List<String?>, unproven: Boolean): List<Evidence> {
            val codec = Json { ignoreUnknownKeys = false; encodeDefaults = true; explicitNulls = false }
            fun decode(raw: String) = codec.decodeFromString(ListSerializer(Evidence.serializer()), raw)
            val primaryRows = primary?.let(::decode).orEmpty().let { rows ->
                if (unproven) rows.map { it.copy(uploaded = false) } else rows
            }
            val candidates = primaryRows + retained.filterNotNull().flatMap(::decode)
            return candidates.groupBy { it.pinId to it.evidenceRevision }.values.map { versions ->
                check(versions.map { it.copy(uploaded = false) }.distinct().size == 1) {
                    "Conflicting capture evidence needs recovery review. Original sources were retained."
                }
                versions.first().copy(uploaded = versions.any { it.uploaded })
            }
        }

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
