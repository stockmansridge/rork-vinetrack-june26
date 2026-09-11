package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Paddock
import kotlin.math.abs

/**
 * Observation-backed aisle identity for automatic pin capture outside trips.
 * History establishes only an aisle; the current accepted raw fix is never
 * averaged or replaced and remains the sole source for snapping and persistence.
 */
object PinAisleObservationLock {
    const val MAX_OBSERVATIONS: Int = 16
    const val MAX_AGE_MS: Long = 20_000L
    const val SUPPORT_REQUIRED: Int = 3
    const val CONTRADICTIONS_REQUIRED: Int = 3

    data class Evidence(
        val observedAtElapsedRealtimeNanos: Long,
        val paddockId: String?,
        val aisleNumber: Double?,
        val isQualified: Boolean,
    )

    data class Lock(
        val paddockId: String,
        val aisleNumber: Double,
        val supportingObservations: Int,
        /** Latest separately delivered observation that confirmed this aisle. */
        val confirmedAtElapsedRealtimeNanos: Long,
    )

    /**
     * Monotonic provider time is sample identity. Fresh stationary fixes remain
     * distinct; replayed, out-of-order, stale, and future samples are rejected.
     */
    fun acceptsObservation(
        observedAtElapsedRealtimeNanos: Long,
        previousObservedAtElapsedRealtimeNanos: Long?,
        receivedAtElapsedRealtimeNanos: Long,
    ): Boolean {
        if (observedAtElapsedRealtimeNanos <= 0L || receivedAtElapsedRealtimeNanos < observedAtElapsedRealtimeNanos) return false
        val ageMs = (receivedAtElapsedRealtimeNanos - observedAtElapsedRealtimeNanos) / 1_000_000L
        if (ageMs > PinLocationFixValidator.MAX_AGE_MS) return false
        return previousObservedAtElapsedRealtimeNanos == null ||
            observedAtElapsedRealtimeNanos > previousObservedAtElapsedRealtimeNanos
    }

    fun resolve(evidence: List<Evidence>, captureElapsedRealtimeNanos: Long): Lock? {
        val recent = evidence
            .filter { ageMs(it.observedAtElapsedRealtimeNanos, captureElapsedRealtimeNanos) <= MAX_AGE_MS }
            .takeLast(MAX_OBSERVATIONS)

        var block: String? = null
        var locked: Double? = null
        var candidate: Double? = null
        var candidateCount = 0
        var supportCount = 0
        var contradiction: Double? = null
        var contradictionCount = 0
        var confirmedAt: Long? = null

        recent.forEach { item ->
            val itemBlock = item.paddockId
            val aisle = item.aisleNumber
            if (itemBlock == null || aisle == null) {
                block = null
                locked = null
                candidate = null
                candidateCount = 0
                supportCount = 0
                contradiction = null
                contradictionCount = 0
                confirmedAt = null
                return@forEach
            }
            if (block != itemBlock) {
                block = itemBlock
                locked = null
                candidate = null
                candidateCount = 0
                supportCount = 0
                contradiction = null
                contradictionCount = 0
                confirmedAt = null
            }

            val currentLock = locked
            if (currentLock != null) {
                if (sameAisle(currentLock, aisle)) {
                    if (item.isQualified) {
                        supportCount = (supportCount + 1).coerceAtMost(MAX_OBSERVATIONS)
                        confirmedAt = item.observedAtElapsedRealtimeNanos
                    }
                    contradiction = null
                    contradictionCount = 0
                } else if (item.isQualified) {
                    if (contradiction?.let { sameAisle(it, aisle) } == true) contradictionCount += 1
                    else {
                        contradiction = aisle
                        contradictionCount = 1
                    }
                    if (contradictionCount >= CONTRADICTIONS_REQUIRED) {
                        locked = aisle
                        candidate = aisle
                        candidateCount = contradictionCount
                        supportCount = contradictionCount
                        confirmedAt = item.observedAtElapsedRealtimeNanos
                        contradiction = null
                        contradictionCount = 0
                    }
                }
            } else if (item.isQualified) {
                if (candidate?.let { sameAisle(it, aisle) } == true) candidateCount += 1
                else {
                    candidate = aisle
                    candidateCount = 1
                }
                if (candidateCount >= SUPPORT_REQUIRED) {
                    locked = aisle
                    supportCount = candidateCount
                    confirmedAt = item.observedAtElapsedRealtimeNanos
                }
            }
        }

        val finalBlock = block ?: return null
        val finalAisle = locked ?: return null
        val finalConfirmedAt = confirmedAt ?: return null
        if (supportCount < SUPPORT_REQUIRED) return null
        return Lock(finalBlock, finalAisle, supportCount, finalConfirmedAt)
    }

    fun resolve(fixes: List<QualifiedLocationFix>, current: QualifiedLocationFix, paddock: Paddock?): Lock? {
        paddock ?: return null
        val evidence = fixes
            .filter { it.fixElapsedRealtimeNanos <= current.fixElapsedRealtimeNanos }
            .takeLast(MAX_OBSERVATIONS)
            .map { fix ->
                val inside = RowAttachment.containsPoint(paddock, fix.latitude, fix.longitude)
                val approximate = if (inside) PinAisleGeometry.approximateAisle(paddock, fix.latitude, fix.longitude) else null
                val qualified = if (inside) {
                    PinAisleGeometry.aisleContaining(paddock, fix.latitude, fix.longitude, fix.accuracyMetres)
                } else null
                Evidence(
                    observedAtElapsedRealtimeNanos = fix.fixElapsedRealtimeNanos,
                    paddockId = paddock.id.takeIf { inside },
                    aisleNumber = approximate?.aisleNumber,
                    isQualified = qualified?.aisleNumber == approximate?.aisleNumber,
                )
            }
        val lock = resolve(evidence, current.fixElapsedRealtimeNanos) ?: return null
        return lock.takeIf { isValid(it, current, paddock) }
    }

    /**
     * Validate complete lock scope at the frozen press. One or two lateral
     * contradictions may be tolerated only while the current accepted fix stays
     * inside the same block and within mapped row longitudinal extent.
     */
    fun isValid(lock: Lock?, current: QualifiedLocationFix, paddock: Paddock?): Boolean {
        lock ?: return false
        paddock ?: return false
        if (lock.paddockId != paddock.id) return false
        if (ageMs(lock.confirmedAtElapsedRealtimeNanos, current.fixElapsedRealtimeNanos) > MAX_AGE_MS) return false
        if (!RowAttachment.containsPoint(paddock, current.latitude, current.longitude)) return false
        if (PinAisleGeometry.rowsBoundingPath(paddock, lock.aisleNumber) == null) return false
        return PinAisleGeometry.approximateAisle(paddock, current.latitude, current.longitude) != null
    }

    private fun ageMs(observed: Long, capture: Long): Long {
        if (observed <= 0L || capture < observed) return Long.MAX_VALUE
        return (capture - observed) / 1_000_000L
    }

    private fun sameAisle(lhs: Double, rhs: Double): Boolean = abs(lhs - rhs) < 0.01
}
