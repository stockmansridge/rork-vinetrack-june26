package com.rork.vinetrack.data

/** Immutable GPS observation accepted for an automatic pin placement. */
data class QualifiedLocationFix(
    val latitude: Double,
    val longitude: Double,
    val accuracyMetres: Double,
    val fixTimeEpochMs: Long,
    val fixElapsedRealtimeNanos: Long,
    val bearingDegrees: Double?,
    /**
     * Ground speed in m/s when the fix reports one. Needed to decide whether a
     * travel course is real movement or the noise of a stationary machine — a
     * course is never labelled as operator facing without it.
     */
    val speedMetresPerSecond: Double? = null,
)

/** Identity and time frozen at the initiating tap, before any delayed UI confirmation. */
data class PinCaptureContext(
    val pinId: String,
    val vineyardId: String,
    val tripId: String?,
    val observedAtIso: String,
    val capturedAtIso: String = observedAtIso,
    val captureUserId: String? = null,
    val headingSource: String? = null,
    val headingObservedAtIso: String? = null,
    val observations: List<PinCaptureEvidenceStore.Observation> = emptyList(),
    val aisleLock: PinCaptureEvidenceStore.AisleLock? = null,
    /** Placement resolved once from the trip and block selection that existed at capture. */
    val resolvedPaddockId: String? = null,
    val resolvedRowNumber: Int? = null,
    val resolvedPlacement: PinPlacementResult? = null,
    /** Qualified GPS travel used for both row selection and persistence. */
    val headingDegrees: Double? = null,
    val compassDegrees: Double? = null,
    val compassObservedAtIso: String? = null,
    val geometryRevision: String? = null,
    val geometryHash: String? = null,
)

/** Explicit outcome for a pin-location request; failure never carries coordinates. */
sealed interface PinLocationResult {
    data class Success(val fix: QualifiedLocationFix) : PinLocationResult
    data object PermissionDenied : PinLocationResult
    data object ApproximatePermission : PinLocationResult
    data object ServicesDisabled : PinLocationResult
    data object Stale : PinLocationResult
    data object Inaccurate : PinLocationResult
    data object Invalid : PinLocationResult
    data object Timeout : PinLocationResult
    data object Cancelled : PinLocationResult

    fun operatorMessage(): String = when (this) {
        is Success -> "Location ready"
        PermissionDenied -> "Precise location permission is required. Enable it, then press the pin button again."
        ApproximatePermission -> "Precise location is off. Enable precise location, then press the pin button again."
        ServicesDisabled -> "Location services are off. Turn them on, then press the pin button again."
        Stale -> "The GPS position is stale. Wait for a fresh fix, then press the pin button again."
        Inaccurate -> "GPS accuracy is not yet within 15 m. Wait for accuracy to improve, then press again."
        Invalid -> "The GPS position is invalid. Wait for a new fix, then press the pin button again."
        Timeout -> "A fresh GPS fix was not available. Keep location enabled, then press the pin button again."
        Cancelled -> "The location request was cancelled. Press the pin button again when ready."
    }
}

/** Synchronous source used at the exact instant an automatic-placement action is pressed. */
fun interface PinFixSnapshotSource {
    fun snapshotPinFix(): PinLocationResult
}

/**
 * Tap coordinator with no pending acceptance state. A rejected tap is final: later source
 * updates only warm the next tap and can never complete the rejected one.
 */
class PinTapCaptureCoordinator(private val source: PinFixSnapshotSource) {
    fun captureNow(): PinLocationResult = source.snapshotPinFix()
}

/** Guards callbacks that belong to an already accepted and frozen capture. */
object PinTapCaptureGate {
    fun acceptedFix(contextIsCurrent: Boolean, result: PinLocationResult): QualifiedLocationFix? =
        if (contextIsCurrent) (result as? PinLocationResult.Success)?.fix else null
}

/** PR #6 movement qualification: compass is deliberately not an input. */
object PinTravelDirection {
    data class Course(val degrees: Double, val observedAtEpochMs: Long)

    fun fromObservations(current: QualifiedLocationFix, history: List<QualifiedLocationFix>, capturedAtElapsedNanos: Long = current.fixElapsedRealtimeNanos): Course? {
        val capture = capturedAtElapsedNanos
        if (current.fixElapsedRealtimeNanos <= 0 || capture - current.fixElapsedRealtimeNanos !in 0..5_000_000_000L) return null
        val recent = (history + current).distinctBy { it.fixElapsedRealtimeNanos }.distinctBy { it.fixTimeEpochMs }
            .sortedBy { it.fixElapsedRealtimeNanos }.takeLast(16).filter { fix ->
                val age = capture - fix.fixElapsedRealtimeNanos
                age in 0..15_000_000_000L && fix.accuracyMetres in 0.0..5.0 &&
                    fix.speedMetresPerSecond?.let { it.isFinite() && it >= 1.0 } == true &&
                    fix.bearingDegrees?.let { it.isFinite() && it >= 0 && it < 360 } == true &&
                    fix.latitude in -90.0..90.0 && fix.longitude in -180.0..180.0
            }
        if (recent.size < 3 || recent.last().fixElapsedRealtimeNanos != current.fixElapsedRealtimeNanos) return null
        val first = recent.first()
        val last = recent.last()
        if (last.fixElapsedRealtimeNanos - first.fixElapsedRealtimeNanos < 1_000_000_000L) return null
        val east = recent.sumOf { kotlin.math.sin(Math.toRadians(it.bearingDegrees!!)) }
        val north = recent.sumOf { kotlin.math.cos(Math.toRadians(it.bearingDegrees!!)) }
        val mean = (Math.toDegrees(kotlin.math.atan2(east, north)) + 360) % 360
        fun difference(a: Double, b: Double) = kotlin.math.abs((a - b + 540) % 360 - 180)
        if (recent.any { difference(it.bearingDegrees!!, mean) > 25 }) return null
        val northM = (last.latitude - first.latitude) * 111_320
        val eastM = (last.longitude - first.longitude) * 111_320 * kotlin.math.cos(Math.toRadians((first.latitude + last.latitude) / 2))
        if (kotlin.math.hypot(northM, eastM) < 5) return null
        val displacement = (Math.toDegrees(kotlin.math.atan2(eastM, northM)) + 360) % 360
        if (difference(displacement, mean) > 30) return null
        return Course(mean, last.fixTimeEpochMs)
    }
}

object PinLocationFixValidator {
    const val MAX_AGE_MS: Long = 5_000L
    const val MAX_ACCURACY_METRES: Double = 15.0

    fun validate(
        latitude: Double,
        longitude: Double,
        hasAccuracy: Boolean,
        accuracyMetres: Double,
        fixTimeEpochMs: Long,
        fixElapsedRealtimeNanos: Long,
        nowElapsedRealtimeNanos: Long,
        bearingDegrees: Double?,
        /** Ground speed in m/s when reported; unchanged acceptance rules. */
        speedMetresPerSecond: Double? = null,
    ): PinLocationResult {
        if (!latitude.isFinite() || !longitude.isFinite() ||
            latitude !in -90.0..90.0 || longitude !in -180.0..180.0
        ) return PinLocationResult.Invalid
        if (!hasAccuracy || !accuracyMetres.isFinite() || accuracyMetres < 0.0) {
            return PinLocationResult.Invalid
        }
        if (accuracyMetres > MAX_ACCURACY_METRES) return PinLocationResult.Inaccurate
        if (fixElapsedRealtimeNanos <= 0L || nowElapsedRealtimeNanos < fixElapsedRealtimeNanos) {
            return PinLocationResult.Invalid
        }
        val ageNanos = nowElapsedRealtimeNanos - fixElapsedRealtimeNanos
        if (ageNanos > MAX_AGE_MS * 1_000_000L) return PinLocationResult.Stale
        val validBearing = bearingDegrees?.takeIf { it.isFinite() && it in 0.0..360.0 }
        return PinLocationResult.Success(
            QualifiedLocationFix(
                latitude = latitude,
                longitude = longitude,
                accuracyMetres = accuracyMetres,
                fixTimeEpochMs = fixTimeEpochMs,
                fixElapsedRealtimeNanos = fixElapsedRealtimeNanos,
                bearingDegrees = validBearing,
                speedMetresPerSecond = speedMetresPerSecond?.takeIf { it.isFinite() && it >= 0.0 },
            ),
        )
    }
}
