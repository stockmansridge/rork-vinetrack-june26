package com.rork.vinetrack.data

/** Immutable GPS observation accepted for an automatic pin placement. */
data class QualifiedLocationFix(
    val latitude: Double,
    val longitude: Double,
    val accuracyMetres: Double,
    val fixTimeEpochMs: Long,
    val fixElapsedRealtimeNanos: Long,
    val bearingDegrees: Double?,
)

/** Identity and time frozen at the initiating tap, before any delayed UI confirmation. */
data class PinCaptureContext(
    val pinId: String,
    val vineyardId: String,
    val tripId: String?,
    val observedAtIso: String,
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

/** Pure gate used by the UI to reject unresolved and late tap callbacks. */
object PinTapCaptureGate {
    fun acceptedFix(contextIsCurrent: Boolean, result: PinLocationResult): QualifiedLocationFix? =
        if (contextIsCurrent) (result as? PinLocationResult.Success)?.fix else null
}

/** Pure iOS-parity qualification rules for cached and newly delivered Android fixes. */
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
            ),
        )
    }
}
