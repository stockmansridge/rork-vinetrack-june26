package com.rork.vinetrack.data

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.os.SystemClock
import androidx.core.content.ContextCompat
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import com.rork.vinetrack.data.model.CoordinatePoint
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Foreground GPS path capture for an active trip. Wraps the fused location
 * provider, accumulates [CoordinatePoint]s and a running distance, and emits
 * each accepted fix to the caller.
 *
 * This is the online-first, in-app capture foundation: it only records while
 * the app is in the foreground and the tracker is started. True background
 * tracking (foreground service + notification) is a deferred follow-up.
 */
class LocationTracker(context: Context) : PinFixSnapshotSource {

    private val appContext = context.applicationContext
    private val client = LocationServices.getFusedLocationProviderClient(appContext)

    private var callback: LocationCallback? = null
    private var pinFixCallback: LocationCallback? = null
    private var latestPinFix: QualifiedLocationFix? = null

    /** Points captured this session, in order. */
    val points: MutableList<CoordinatePoint> = mutableListOf()

    /** Running great-circle distance in metres across [points]. */
    var distanceMetres: Double = 0.0
        private set

    /**
     * Latest live movement context for the active trip. Held in memory only —
     * never written to the persisted `path_points` JSON, so old trips and the
     * iOS decoder (lat/lng only) stay compatible. Used downstream to drive the
     * active-trip row-lock and, later, iOS-style trip quick pins.
     */
    data class MovementSample(
        val latitude: Double,
        val longitude: Double,
        /** Device course over ground in degrees (0–360), or null if unknown. */
        val bearingDegrees: Double?,
        /** Ground speed in m/s, or null if the fix carries no speed. */
        val speedMetresPerSecond: Double?,
        /** Horizontal accuracy in metres, or null if unknown. */
        val accuracyMetres: Double?,
        val timestampMs: Long,
    )

    /** Most recent accepted movement sample (in-memory only). */
    var latestSample: MovementSample? = null
        private set

    val hasFinePermission: Boolean
        get() = ContextCompat.checkSelfPermission(
            appContext,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED

    val hasCoarsePermission: Boolean
        get() = ContextCompat.checkSelfPermission(
            appContext,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED

    val hasPermission: Boolean get() = hasFinePermission || hasCoarsePermission

    val areLocationServicesEnabled: Boolean
        get() = (appContext.getSystemService(Context.LOCATION_SERVICE) as? LocationManager)
            ?.isLocationEnabled == true

    /**
     * Begin receiving location updates. [seed] restores points from a resumed
     * trip so distance keeps accumulating. [onUpdate] fires after each accepted
     * fix with the latest point list and total distance.
     */
    @SuppressLint("MissingPermission")
    fun start(
        seed: List<CoordinatePoint>,
        onUpdate: (List<CoordinatePoint>, Double, MovementSample?) -> Unit,
    ) {
        if (!hasPermission) return
        stop()
        points.clear()
        points.addAll(seed)
        distanceMetres = pathLength(points)
        latestSample = null

        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 4000L)
            .setMinUpdateIntervalMillis(2000L)
            .setMinUpdateDistanceMeters(3f)
            .build()

        val cb = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                val loc = result.lastLocation ?: return
                // Reject obviously bad fixes.
                if (loc.hasAccuracy() && loc.accuracy > 50f) return
                // Only carry movement metadata the fix actually provides; nulls
                // are dropped on serialization (explicitNulls = false).
                val bearing = if (loc.hasBearing()) loc.bearing.toDouble() else null
                val speed = if (loc.hasSpeed()) loc.speed.toDouble() else null
                val accuracy = if (loc.hasAccuracy()) loc.accuracy.toDouble() else null
                val point = CoordinatePoint(
                    latitude = loc.latitude,
                    longitude = loc.longitude,
                    bearing = bearing,
                    speed = speed,
                    accuracy = accuracy,
                )
                val sample = MovementSample(
                    latitude = loc.latitude,
                    longitude = loc.longitude,
                    bearingDegrees = bearing,
                    speedMetresPerSecond = speed,
                    accuracyMetres = accuracy,
                    timestampMs = loc.time,
                )
                // Freshness is independent of route geometry. Even a stationary
                // update must replace current-fix state before sub-metre jitter is
                // excluded from the persisted route.
                latestSample = sample
                val last = points.lastOrNull()
                if (last != null) {
                    val step = haversine(last, point)
                    if (step < 1.0) {
                        onUpdate(points.toList(), distanceMetres, sample)
                        return
                    }
                    distanceMetres += step
                }
                points.add(point)
                onUpdate(points.toList(), distanceMetres, sample)
            }
        }
        callback = cb
        client.requestLocationUpdates(request, cb, appContext.mainLooper)
    }

    fun stop() {
        callback?.let { client.removeLocationUpdates(it) }
        callback = null
        latestSample = null
    }

    /**
     * Keep the fused provider warm while the foreground pin launcher is open.
     * This subscription is separate from active-trip route ownership and uses
     * zero minimum displacement so stationary fixes still refresh observation age.
     */
    @SuppressLint("MissingPermission")
    fun startPinFixUpdates(onUpdate: (PinLocationResult) -> Unit = {}) {
        stopPinFixUpdates()
        if (!hasPermission) { onUpdate(PinLocationResult.PermissionDenied); return }
        if (!hasFinePermission) { onUpdate(PinLocationResult.ApproximatePermission); return }
        if (!areLocationServicesEnabled) { onUpdate(PinLocationResult.ServicesDisabled); return }
        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 2_000L)
            .setMinUpdateIntervalMillis(1_000L)
            .setMinUpdateDistanceMeters(0f)
            .build()
        val cb = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                result.locations.forEach { location ->
                    val qualified = location.toPinResult()
                    if (qualified is PinLocationResult.Success) latestPinFix = qualified.fix
                    onUpdate(qualified)
                }
            }
        }
        pinFixCallback = cb
        client.requestLocationUpdates(request, cb, appContext.mainLooper)
    }

    fun stopPinFixUpdates() {
        pinFixCallback?.let { client.removeLocationUpdates(it) }
        pinFixCallback = null
        latestPinFix = null
    }

    /**
     * Synchronously validates only the fix already delivered to this foreground
     * subscription. It never requests or waits for another position.
     */
    override fun snapshotPinFix(): PinLocationResult {
        if (!hasPermission) return PinLocationResult.PermissionDenied
        if (!hasFinePermission) return PinLocationResult.ApproximatePermission
        if (!areLocationServicesEnabled) return PinLocationResult.ServicesDisabled
        val fix = latestPinFix ?: return PinLocationResult.Stale
        return PinLocationFixValidator.validate(
            latitude = fix.latitude,
            longitude = fix.longitude,
            hasAccuracy = true,
            accuracyMetres = fix.accuracyMetres,
            fixTimeEpochMs = fix.fixTimeEpochMs,
            fixElapsedRealtimeNanos = fix.fixElapsedRealtimeNanos,
            nowElapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos(),
            bearingDegrees = fix.bearingDegrees,
            speedMetresPerSecond = fix.speedMetresPerSecond,
        )
    }

    /**
     * Qualified one-shot observation for non-tap tools. A cached fix
     * is accepted only when it is at most five seconds old and accurate to 15 m;
     * otherwise a new high-accuracy fix is requested. Age uses Android's
     * monotonic elapsed-realtime timestamp carried by the Location itself.
     */
    @SuppressLint("MissingPermission")
    suspend fun currentPinLocation(timeoutMs: Long = 8000L): PinLocationResult {
        if (!hasPermission) return PinLocationResult.PermissionDenied
        if (!hasFinePermission) return PinLocationResult.ApproximatePermission
        if (!areLocationServicesEnabled) return PinLocationResult.ServicesDisabled
        latestPinFix?.let { fix ->
            val local = PinLocationFixValidator.validate(
                latitude = fix.latitude,
                longitude = fix.longitude,
                hasAccuracy = true,
                accuracyMetres = fix.accuracyMetres,
                fixTimeEpochMs = fix.fixTimeEpochMs,
                fixElapsedRealtimeNanos = fix.fixElapsedRealtimeNanos,
                nowElapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos(),
                bearingDegrees = fix.bearingDegrees,
                speedMetresPerSecond = fix.speedMetresPerSecond,
            )
            if (local is PinLocationResult.Success) return local
        }
        val cached = lastKnownResult()
        if (cached is PinLocationResult.Success) return cached
        return withTimeoutOrNull(timeoutMs) { freshFixResult() } ?: PinLocationResult.Timeout
    }

    /** Compatibility path for map centring and non-pin tools; now equally strict. */
    suspend fun currentLocation(timeoutMs: Long = 8000L): CoordinatePoint? =
        (currentPinLocation(timeoutMs) as? PinLocationResult.Success)?.fix?.let {
            CoordinatePoint(it.latitude, it.longitude, it.bearingDegrees, accuracy = it.accuracyMetres)
        }

    @SuppressLint("MissingPermission")
    private suspend fun lastKnownResult(): PinLocationResult = suspendCancellableCoroutine { cont ->
        client.lastLocation
            .addOnSuccessListener { location ->
                if (cont.isActive) cont.resume(location?.toPinResult() ?: PinLocationResult.Stale)
            }
            .addOnFailureListener {
                if (cont.isActive) cont.resume(PinLocationResult.Invalid)
            }
    }

    @SuppressLint("MissingPermission")
    private suspend fun freshFixResult(): PinLocationResult = suspendCancellableCoroutine { cont ->
        val cts = CancellationTokenSource()
        client.getCurrentLocation(Priority.PRIORITY_HIGH_ACCURACY, cts.token)
            .addOnSuccessListener { location ->
                if (cont.isActive) cont.resume(location?.toPinResult() ?: PinLocationResult.Timeout)
            }
            .addOnFailureListener {
                if (cont.isActive) cont.resume(PinLocationResult.Invalid)
            }
        cont.invokeOnCancellation { cts.cancel() }
    }

    private fun Location.toPinResult(): PinLocationResult = PinLocationFixValidator.validate(
        latitude = latitude,
        longitude = longitude,
        hasAccuracy = hasAccuracy(),
        accuracyMetres = if (hasAccuracy()) accuracy.toDouble() else Double.NaN,
        fixTimeEpochMs = time,
        fixElapsedRealtimeNanos = elapsedRealtimeNanos,
        nowElapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos(),
        bearingDegrees = if (hasBearing()) bearing.toDouble() else null,
        speedMetresPerSecond = if (hasSpeed()) speed.toDouble() else null,
    )

    private fun pathLength(pts: List<CoordinatePoint>): Double {
        if (pts.size < 2) return 0.0
        var total = 0.0
        for (i in 1 until pts.size) total += haversine(pts[i - 1], pts[i])
        return total
    }

    private fun haversine(a: CoordinatePoint, b: CoordinatePoint): Double {
        val r = 6_371_000.0
        val dLat = Math.toRadians(b.latitude - a.latitude)
        val dLon = Math.toRadians(b.longitude - a.longitude)
        val lat1 = Math.toRadians(a.latitude)
        val lat2 = Math.toRadians(b.latitude)
        val h = sin(dLat / 2) * sin(dLat / 2) +
            cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(h), sqrt(1 - h))
    }
}
